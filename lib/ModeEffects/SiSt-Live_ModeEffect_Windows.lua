-- @noindex
-- SiSt-Live mode effect: opens SiSt-Live windows (setlist, status display, toolbar) per mode.
--
-- Per mode one setting, "windows":
--   open     open every window in Windows.WINDOWS that is closed, and remember which ones were
--            opened by this effect
--   restore  close the windows this effect opened (if they are still open). Windows that were
--            already open before, or that you opened yourself, stay open
--   (empty)  leave the windows alone
-- Never configured: show mode = open, edit mode = restore. An empty field in "Configure modes"
-- turns it off for that mode.
--
-- Which windows the effect opened is kept in ExtState that is NOT persisted: after a REAPER
-- restart nothing is closed by mistake.
--
-- Idempotent: "open" twice opens nothing the second time; "restore" twice closes nothing.
--
-- How windows are found: each window is a script of the SiSt-Live package; its command ID comes from
-- SiSt-Live_Actions.lua (looked up by the script's file). The window's toolbar toggle state tells
-- whether it is open (the Gui Window library sets it). Running the action of an open window closes it.
--
-- Adding a window: one line in Windows.WINDOWS (its id must be in Actions.SCRIPTS).
--
-- Runs last (see ModeEffects.MODULES): the screenset is loaded and the layouts are set before
-- the windows open, so they open into the final docker arrangement.
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.

local Actions = require("SiSt-Live_Actions")

local Windows = { name = "windows" }

Windows.SECTION           = "SiSt-Live"
Windows.KEY_PREFIX        = "windows_"            -- + mode. Value: "open", "restore", "" = none
Windows.KEY_OPENED        = "windows_opened_by_mode" -- comma separated window ids (not persisted)

Windows.OPEN    = "open"
Windows.RESTORE = "restore"
Windows.DEFAULTS = { show = "open", edit = "restore" } -- used while a mode was never configured

-- id: short name (log, ExtState) and the script's id in Actions.SCRIPTS
Windows.WINDOWS = {
  { id = "setlist", label = "Setlist" },
  { id = "status",  label = "Status Display" },
  { id = "toolbar", label = "Toolbar" },
}

-- Pure helpers ------------------------------------------------------------
--- "open" / "restore" (case and spaces ignored) -> the value; empty -> "none"; else nil + error.
function Windows.parse(input)
  local s = (input or ""):lower():match("^%s*(.-)%s*$")
  if s == "" then return "none" end
  if s == Windows.OPEN or s == Windows.RESTORE then return s end
  return nil, ("'%s' is not 'open' or 'restore'"):format(input)
end

--- "a,b" <-> { a = true, b = true }, ids in Windows.WINDOWS order
function Windows.decode_ids(str)
  local set = {}
  for id in (str or ""):gmatch("[^,%s]+") do set[id] = true end
  return set
end

function Windows.encode_ids(set)
  local ids = {}
  for _, w in ipairs(Windows.WINDOWS) do
    if set[w.id] then ids[#ids + 1] = w.id end
  end
  return table.concat(ids, ",")
end

-- Assignments -------------------------------------------------------------
--- "open", "restore" or nil (none). A mode that was never configured gets its default.
function Windows.get_assignment(mode, api)
  api = api or reaper
  if not api.HasExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode) then return Windows.DEFAULTS[mode] end
  local v = api.GetExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode)
  if v == Windows.OPEN or v == Windows.RESTORE then return v end
  return nil
end

--- value: "open", "restore" or nil for none (stored as "", so the default no longer applies).
function Windows.set_assignment(mode, value, api)
  api = api or reaper
  api.SetExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode, value or "", true) -- persistent
end

-- Windows -----------------------------------------------------------------
--- Command ID of a window's script, or nil + reason.
function Windows.command(w, api)
  return Actions.script_command(w.id, api)
end

--- true if the window is open (its action's toggle state is on).
function Windows.is_open(cmd, api)
  return api.GetToggleCommandStateEx(0, cmd) == 1
end

local function get_opened(api)
  return Windows.decode_ids(api.GetExtState(Windows.SECTION, Windows.KEY_OPENED))
end

local function set_opened(set, api)
  api.SetExtState(Windows.SECTION, Windows.KEY_OPENED, Windows.encode_ids(set), false) -- not persisted
end

local function open_all(api)
  local opened, done, problems = get_opened(api), {}, {}
  for _, w in ipairs(Windows.WINDOWS) do
    local cmd, err = Windows.command(w, api)
    if not cmd then
      problems[#problems + 1] = w.label .. " " .. err
    elseif not Windows.is_open(cmd, api) then
      api.Main_OnCommand(cmd, 0)
      opened[w.id] = true
      done[#done + 1] = w.label
    end
  end
  set_opened(opened, api)
  return done, problems
end

local function restore_all(api)
  local opened, done, problems = get_opened(api), {}, {}
  for _, w in ipairs(Windows.WINDOWS) do
    if opened[w.id] then
      local cmd, err = Windows.command(w, api)
      if not cmd then
        problems[#problems + 1] = w.label .. " " .. err
      else
        if Windows.is_open(cmd, api) then
          api.Main_OnCommand(cmd, 0) -- running the action of an open window closes it
          done[#done + 1] = w.label
        end
        opened[w.id] = nil -- closed now, or by hand before: either way no longer ours
      end
    end
  end
  set_opened(opened, api)
  return done, problems
end

-- Effect ------------------------------------------------------------------
function Windows.apply(mode, api)
  local what = Windows.get_assignment(mode, api)
  if not what then return "skipped", ("no windows setting for %s mode"):format(mode) end

  local done, problems
  if what == Windows.OPEN then done, problems = open_all(api) else done, problems = restore_all(api) end

  local verb = what == Windows.OPEN and "opened" or "closed"
  if #problems > 0 then
    error(("%s%s"):format(#done > 0 and (verb .. " " .. table.concat(done, ", ") .. "; ") or "",
      table.concat(problems, "; ")), 0)
  end
  if #done == 0 then
    return "skipped", what == Windows.OPEN and "all windows already open" or "nothing to close"
  end
  return "ok", verb .. " " .. table.concat(done, ", ")
end

-- Settings ----------------------------------------------------------------
-- Field text: "open" or "restore", empty = leave the windows alone.
Windows.settings = {
  {
    label  = "windows",
    get    = function(mode, api) return Windows.get_assignment(mode, api) end,
    format = function(v) return v or "" end,
    parse  = function(text)
      local v, err = Windows.parse(text)
      if v == nil then return false, "windows: " .. err end
      if v == "none" then return true, nil end
      return true, v
    end,
    set    = function(mode, v, api) Windows.set_assignment(mode, v, api) end,
  },
}

-- Diagnostics & self-test -------------------------------------------------
--- Live check: every window's script is installed. Registers nothing (only checks the files).
function Windows.check_actions(api)
  api = api or reaper
  local results = {}
  for _, w in ipairs(Windows.WINDOWS) do
    local path = Actions.script_path(w.id, api) or ("(unknown script " .. w.id .. ")")
    results[#results + 1] = { name = w.label .. " script at " .. path, ok = api.file_exists(path) }
  end
  return results
end

function Windows.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local configured = api.HasExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode)
    rows[#rows + 1] = { mode .. " windows",
      (Windows.get_assignment(mode, api) or "(none)") .. (configured and "" or " (default)") }
  end
  for _, w in ipairs(Windows.WINDOWS) do
    local cmd, err = Windows.command(w, api)
    rows[#rows + 1] = { w.id, cmd and ("action %d, %s"):format(cmd, Windows.is_open(cmd, api) and "open" or "closed")
      or err }
  end
  local opened = api.GetExtState(Windows.SECTION, Windows.KEY_OPENED)
  rows[#rows + 1] = { "opened by mode", opened ~= "" and opened or "(none)" }
  return rows
end

-- Uses a fake REAPER API: never opens or closes a real window.
local run_self_test -- defined below

--- Built-in self-test. Restores the real window list even if a test crashes.
function Windows.self_test()
  local real_windows = Windows.WINDOWS
  local ok, results = pcall(run_self_test)
  Windows.WINDOWS = real_windows
  if not ok then error(results, 0) end
  return results
end

run_self_test = function()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  -- The tests use a fixed list of two windows, so adding a window doesn't change them
  local real_windows = Windows.WINDOWS
  Windows.WINDOWS = {
    { id = "setlist", label = "Setlist" },
    { id = "status",  label = "Status Display" },
  }

  local sep = package.config:sub(1, 1)
  local function fake(opts)
    opts = opts or {}
    local ext, runs, open = {}, {}, {}
    local cmds, files = {}, {}
    for i, w in ipairs(Windows.WINDOWS) do
      local path = Actions.join_path("R", Actions.SCRIPTS[w.id], sep)
      if not (opts.missing and opts.missing[w.id]) then files[path] = true end
      cmds[path] = 1000 + i
    end
    local api
    api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      HasExtState = function(s, k) return ext[s .. "/" .. k] ~= nil end,
      GetResourcePath = function() return "R" end,
      file_exists = function(p) return files[p] == true end,
      AddRemoveReaScript = function(add, section, path) return cmds[path] or 0 end,
      GetToggleCommandStateEx = function(section, cmd) return open[cmd] and 1 or 0 end,
      Main_OnCommand = function(cmd)
        runs[#runs + 1] = cmd
        open[cmd] = not open[cmd]
      end,
    }
    return api, runs, open
  end

  -- pure helpers
  check("every window is a known SiSt-Live script", (function()
    for _, w in ipairs(real_windows) do if not Actions.SCRIPTS[w.id] then return false end end
    return true
  end)())
  check("parse: open / restore / empty / garbage", Windows.parse(" Open ") == "open"
    and Windows.parse("restore") == "restore" and Windows.parse("") == "none" and Windows.parse("x") == nil)
  check("ids: encode keeps the WINDOWS order",
    Windows.encode_ids(Windows.decode_ids("status, setlist,unknown")) == "setlist,status")

  -- defaults and settings
  local api, runs, open = fake()
  check("never configured: show opens, edit restores",
    Windows.get_assignment("show", api) == "open" and Windows.get_assignment("edit", api) == "restore")
  Windows.set_assignment("show", nil, api)
  check("empty setting turns the default off", Windows.get_assignment("show", api) == nil
    and (Windows.apply("show", api)) == "skipped" and #runs == 0)
  Windows.set_assignment("show", "open", api)

  -- show: open both, remember them
  local r, msg = Windows.apply("show", api)
  check("show: opens the closed windows", r == "ok" and #runs == 2 and open[1001] and open[1002]
    and msg:find("Setlist", 1, true) ~= nil)
  check("show: opened windows remembered", api.GetExtState(Windows.SECTION, Windows.KEY_OPENED) == "setlist,status")
  check("show twice: nothing more opened (idempotent)", (Windows.apply("show", api)) == "skipped" and #runs == 2)

  -- edit: close what show opened
  r = Windows.apply("edit", api)
  check("edit: closes the windows opened by show", r == "ok" and #runs == 4 and not open[1001] and not open[1002])
  check("edit: memory cleared", api.GetExtState(Windows.SECTION, Windows.KEY_OPENED) == "")
  check("edit twice: nothing to close", (Windows.apply("edit", api)) == "skipped" and #runs == 4)

  -- a window that was already open stays open
  api, runs, open = fake()
  open[1001] = true -- setlist was open before the show
  Windows.apply("show", api)
  check("show: only the closed window is opened", #runs == 1 and runs[1] == 1002)
  Windows.apply("edit", api)
  check("edit: the window that was open before stays open", open[1001] and not open[1002] and #runs == 2)

  -- closed by hand during the show: not reopened or toggled by edit
  api, runs, open = fake()
  Windows.apply("show", api)
  open[1002] = false -- user closed the status display
  Windows.apply("edit", api)
  check("edit: a window closed by hand is not toggled open again", not open[1002] and not open[1001] and #runs == 3)

  -- restart: nothing remembered, nothing closed
  api, runs, open = fake()
  open[1001] = true
  check("edit after a restart: nothing closed", (Windows.apply("edit", api)) == "skipped" and open[1001] and #runs == 0)

  -- missing script: the other window still opens, the effect fails with a clear message
  api, runs, open = fake({ missing = { status = true } })
  local ok, err = pcall(Windows.apply, "show", api)
  check("missing script: fails, names it, opens the others",
    not ok and tostring(err):find("Status Display not installed", 1, true) ~= nil and open[1001] and #runs == 1)
  check("live check reports the missing script",
    Windows.check_actions(api)[1].ok and not Windows.check_actions(api)[2].ok)

  local ws = Windows.settings[1]
  check("setting: parse / format", select(2, ws.parse("open")) == "open" and select(2, ws.parse("")) == nil
    and not ws.parse("x") and ws.format("restore") == "restore" and ws.format(nil) == "")

  Windows.WINDOWS = real_windows
  local ids = {}
  for _, w in ipairs(Windows.WINDOWS) do ids[#ids + 1] = w.id end
  check("window list: setlist, status, toolbar", table.concat(ids, ",") == "setlist,status,toolbar")

  return results
end

return Windows
