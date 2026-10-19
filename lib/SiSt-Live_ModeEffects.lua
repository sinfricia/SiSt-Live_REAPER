-- @noindex
-- SiSt-Live mode effects: what happens in REAPER when the mode changes (theme, ...).
--
-- An effect brings REAPER into the state that belongs to a mode. Effects must be idempotent:
-- applying the same mode twice changes nothing the second time. That's what makes it safe to
-- run them from the toggle action, the "Apply current mode" action or at startup.
--
-- Effects live in lib/ModeEffects/, the folder named after this library. Other libraries with
-- plugin-like parts can follow the same pattern: lib/SiSt-Live_<Name>.lua + lib/<Name>/.
--
-- Adding an effect:
--   1. Create lib/ModeEffects/SiSt-Live_ModeEffect_<Name>.lua following the contract below.
--   2. Add "ModeEffects.SiSt-Live_ModeEffect_<Name>" to ModeEffects.MODULES (the order there is the
--      run order). require turns the dot into a folder separator, so no extra path setup is needed.
--   3. Add it to @provides in the package file (Setup/SiSt-Live_Setup.lua) and to the DEBUG
--      self-test runner.
--
-- Effect contract:
--   Effect.name               short id, e.g. "theme". Used for status keys and log lines.
--   Effect.apply(mode, api)   api is the reaper table (or a fake one in tests). Returns
--                               "ok", message       REAPER was changed
--                               "skipped", message  nothing to do (already in that state, not configured)
--                             or throws an error (use error(msg, 0) for a clean message): failed.
--   Effect.settings           optional: list of settings shown in "SiSt-Live: Configure modes"
--                             (contract in SiSt-Live_SettingsDialog.lua)
--   Effect.check_actions(api) optional: live check of native command IDs, list of { name, ok }
--   Effect.diagnostics(api)   optional: { label, value } rows
--   Effect.self_test()        optional: list of { name, ok }
--
-- Status: every run stores one status per effect in ExtState (not persisted). Any script, e.g. a
-- future status window, reads it with ModeEffects.get_status(name) / ModeEffects.get_last_run().
--
-- Failures never block the mode switch and never stop the other effects. They are logged as
-- warnings in edit mode. In show mode they only go to the debug log, because a warning opens the
-- REAPER console, which must not pop up on stage. The stored status always has them.

local Log  = require("SiSt-Live_Log")
local Mode = require("SiSt-Live_Mode")

local log = Log.get("ModeEffects")

local ModeEffects = {}

ModeEffects.SECTION           = "SiSt-Live"
ModeEffects.KEY_STATUS_PREFIX = "effect_status_" -- + effect name
ModeEffects.KEY_LAST_RUN      = "effects_last_run"

-- Results
ModeEffects.OK      = "ok"
ModeEffects.SKIPPED = "skipped"
ModeEffects.FAILED  = "failed"

-- Registry: one line per effect, in run order.
ModeEffects.MODULES = {
  "ModeEffects.SiSt-Live_ModeEffect_Theme",
  "ModeEffects.SiSt-Live_ModeEffect_Screenset", -- before Layout: a window set may bring its own layouts
  "ModeEffects.SiSt-Live_ModeEffect_Fullscreen", -- after Screenset, so a window set can't undo it
  "ModeEffects.SiSt-Live_ModeEffect_Layout",    -- last: layout names depend on the loaded theme, and
                                                -- its assigned layouts always win over the screenset's
  "ModeEffects.SiSt-Live_ModeEffect_KeySection", -- independent of the others
  "ModeEffects.SiSt-Live_ModeEffect_Locking",    -- independent of the others
  "ModeEffects.SiSt-Live_ModeEffect_Windows",    -- last: windows open into the final screenset and layouts
}

-- Helpers ---------------------------------------------------------------
local function first_line(v)
  return (tostring(v):match("^[^\r\n]*"))
end

local function is_valid_mode(mode)
  return mode == Mode.SHOW or mode == Mode.EDIT
end

-- Status encoding (pure) ------------------------------------------------
-- "<result>|<mode>|<unix time>|<message>". The message is last, so it may contain "|".
function ModeEffects.encode_status(status)
  return ("%s|%s|%d|%s"):format(status.result, status.mode or "", status.time or 0,
    first_line(status.message or ""))
end

--- Returns { result, mode, time, message } or nil for empty / malformed strings.
function ModeEffects.decode_status(str)
  local result, mode, time, message = (str or ""):match("^(%a+)|([^|]*)|(%d+)|(.*)$")
  if not result then return nil end
  return { result = result, mode = mode, time = tonumber(time), message = message }
end

-- Loading ---------------------------------------------------------------
--- Loads the effect modules. A module that can't be loaded or doesn't follow the contract is
--- returned as { name = <module>, load_error = <reason> }, so it shows up as a failed effect
--- instead of breaking the others. req: replaceable require (tests).
function ModeEffects.load(modules, req)
  modules = modules or ModeEffects.MODULES
  req = req or require
  local effects = {}
  for _, module_name in ipairs(modules) do
    local ok, effect = pcall(req, module_name)
    if ok and type(effect) == "table" and type(effect.name) == "string"
        and type(effect.apply) == "function" then
      effects[#effects + 1] = effect
    else
      local reason = ok and "does not follow the effect contract (needs name and apply)"
          or first_line(effect)
      effects[#effects + 1] = { name = module_name, load_error = reason }
    end
  end
  return effects
end

-- Running ---------------------------------------------------------------
-- Returns result, message, traceback (traceback only on errors).
local function run_one(effect, mode, api)
  if effect.load_error then
    return ModeEffects.FAILED, "could not load: " .. effect.load_error
  end

  local trace
  local ok, result, message = xpcall(effect.apply, function(err)
    trace = debug.traceback(tostring(err), 2)
    return err
  end, mode, api)

  if not ok then return ModeEffects.FAILED, first_line(result), trace end
  if result ~= ModeEffects.OK and result ~= ModeEffects.SKIPPED then
    return ModeEffects.FAILED, ('returned %q instead of "ok" or "skipped"'):format(tostring(result))
  end
  return result, tostring(message or "")
end

--- Makes REAPER match `mode`: runs every effect, stores its status and logs it.
--- opts.api: reaper table to use (default: reaper). opts.effects: effect list (default: MODULES).
--- Returns results ({ name, result, mode, time, message } per effect, in run order) and the
--- number of failures. Throws only for an invalid mode (a programming error).
function ModeEffects.apply_all(mode, opts)
  opts = opts or {}
  local api = opts.api or reaper
  if not is_valid_mode(mode) then
    error(("ModeEffects.apply_all: invalid mode %s"):format(tostring(mode)), 2)
  end

  local effects = opts.effects or ModeEffects.load()
  local now = os.time()
  local results, failed = {}, 0

  for _, effect in ipairs(effects) do
    local result, message, trace = run_one(effect, mode, api)
    local status = { name = effect.name, result = result, mode = mode, time = now, message = message }
    results[#results + 1] = status

    if result == ModeEffects.FAILED then
      failed = failed + 1
      local report = mode == Mode.SHOW and log.debug or log.warn -- no console popup on stage
      report(log, "%s failed (%s mode): %s", effect.name, mode, trace or message)
    else
      log:debug("%s: %s - %s", effect.name, result, message)
    end

    api.SetExtState(ModeEffects.SECTION, ModeEffects.KEY_STATUS_PREFIX .. effect.name,
      ModeEffects.encode_status(status), false)
  end

  api.SetExtState(ModeEffects.SECTION, ModeEffects.KEY_LAST_RUN,
    ("%s|%d|%d|%d"):format(mode, now, #results - failed, failed), false)
  log:debug("applied %s mode: %d effects, %d failed", mode, #results, failed)

  return results, failed
end

-- Reading the status (for status displays) ------------------------------
--- Names of all registered effects, in run order.
function ModeEffects.names()
  local names = {}
  for _, effect in ipairs(ModeEffects.load()) do names[#names + 1] = effect.name end
  return names
end

--- Last stored status of one effect, or nil if it hasn't run in this REAPER session.
function ModeEffects.get_status(name, api)
  api = api or reaper
  return ModeEffects.decode_status(api.GetExtState(ModeEffects.SECTION, ModeEffects.KEY_STATUS_PREFIX .. name))
end

--- Summary of the last run: { mode, time, ok_count, failed_count }, or nil.
--- ok_count counts every effect that did not fail (changed or skipped).
function ModeEffects.get_last_run(api)
  api = api or reaper
  local mode, time, ok_count, failed_count =
      api.GetExtState(ModeEffects.SECTION, ModeEffects.KEY_LAST_RUN):match("^([^|]*)|(%d+)|(%d+)|(%d+)$")
  if not mode then return nil end
  return { mode = mode, time = tonumber(time), ok_count = tonumber(ok_count), failed_count = tonumber(failed_count) }
end

-- Diagnostics & self-test -----------------------------------------------
function ModeEffects.diagnostics()
  local rows = {}
  local last = ModeEffects.get_last_run()
  rows[#rows + 1] = { "last run", last and ("%s mode at %s, %d failed"):format(
    last.mode, os.date("%H:%M:%S", last.time), last.failed_count) or "(not run in this session)" }

  for _, name in ipairs(ModeEffects.names()) do
    local s = ModeEffects.get_status(name)
    rows[#rows + 1] = { "effect " .. name, s and ("%s (%s mode): %s"):format(s.result, s.mode, s.message)
      or "(not run in this session)" }
  end
  return rows
end

--- Built-in self-test. Uses fake effects and a fake ExtState: touches nothing in REAPER.
function ModeEffects.self_test()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local ext = {}
  local api = {
    GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
    SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  }

  -- status encoding
  local s = { result = "failed", mode = "show", time = 1700000000, message = "a|b\nsecond line" }
  local d = ModeEffects.decode_status(ModeEffects.encode_status(s))
  check("status round trip keeps | in the message",
    d and d.result == "failed" and d.mode == "show" and d.time == 1700000000 and d.message == "a|b")
  check("status: empty or garbage decodes to nil",
    ModeEffects.decode_status("") == nil and ModeEffects.decode_status("garbage") == nil)

  -- loading
  local fake_modules = {
    good    = { name = "good", apply = function() return "ok", "" end },
    nonsense = { foo = 1 },
  }
  local function fake_require(m)
    if fake_modules[m] then return fake_modules[m] end
    error("module '" .. m .. "' not found:\n\tno file ...", 0) -- like require: no position prefix
  end
  local loaded = ModeEffects.load({ "good", "missing", "nonsense" }, fake_require)
  check("load: valid module loaded", loaded[1] == fake_modules.good)
  check("load: missing module reported, first line only",
    loaded[2].name == "missing" and loaded[2].load_error == "module 'missing' not found:")
  check("load: module without apply reported", loaded[3].load_error ~= nil)
  check("registry modules are all loadable", (function()
    for _, e in ipairs(ModeEffects.load()) do if e.load_error then return false end end
    return true
  end)())

  -- running
  local order = {}
  local effects = {
    { name = "changes", apply = function(mode) order[#order + 1] = "changes"; return "ok", "did " .. mode end },
    { name = "throws",  apply = function() order[#order + 1] = "throws"; error("boom", 0) end },
    { name = "nothing", apply = function() order[#order + 1] = "nothing"; return "skipped", "already" end },
    { name = "bad",     apply = function() order[#order + 1] = "bad"; return true end },
    { name = "broken",  load_error = "not found" },
  }

  Log.set_sink(function() end) -- the failures below are expected: keep the console quiet
  local res, failed = ModeEffects.apply_all(Mode.EDIT, { api = api, effects = effects })
  local threw = not pcall(ModeEffects.apply_all, "nope", { api = api, effects = {} })
  Log.set_sink(nil)

  check("all effects run, in order, even after a failure",
    table.concat(order, ",") == "changes,throws,nothing,bad")
  check("results: ok / failed / skipped / failed / failed",
    #res == 5 and res[1].result == "ok" and res[2].result == "failed" and res[3].result == "skipped"
    and res[4].result == "failed" and res[5].result == "failed")
  check("failure count", failed == 3)
  check("mode is passed to the effect", res[1].message == "did edit")
  check("error message is kept", res[2].message == "boom")

  local stored = ModeEffects.get_status("throws", api)
  check("status stored per effect", stored and stored.result == "failed" and stored.mode == "edit")
  local last = ModeEffects.get_last_run(api)
  check("last run summary stored", last and last.mode == "edit" and last.ok_count == 2 and last.failed_count == 3)
  check("invalid mode is rejected", threw)

  return results
end

return ModeEffects
