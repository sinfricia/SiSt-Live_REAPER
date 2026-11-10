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
function Windows.get_assignment(mode)
  if not reaper.HasExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode) then return Windows.DEFAULTS[mode] end
  local v = reaper.GetExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode)
  if v == Windows.OPEN or v == Windows.RESTORE then return v end
  return nil
end

--- value: "open", "restore" or nil for none (stored as "", so the default no longer applies).
function Windows.set_assignment(mode, value)
  reaper.SetExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode, value or "", true) -- persistent
end

-- Windows -----------------------------------------------------------------
--- Command ID of a window's script, or nil + reason.
function Windows.command(w)
  return Actions.script_command(w.id)
end

--- true if the window is open (its action's toggle state is on).
function Windows.is_open(cmd)
  return reaper.GetToggleCommandStateEx(0, cmd) == 1
end

local function get_opened()
  return Windows.decode_ids(reaper.GetExtState(Windows.SECTION, Windows.KEY_OPENED))
end

local function set_opened(set)
  reaper.SetExtState(Windows.SECTION, Windows.KEY_OPENED, Windows.encode_ids(set), false) -- not persisted
end

local function open_all()
  local opened, done, problems = get_opened(), {}, {}
  for _, w in ipairs(Windows.WINDOWS) do
    local cmd, err = Windows.command(w)
    if not cmd then
      problems[#problems + 1] = w.label .. " " .. err
    elseif not Windows.is_open(cmd) then
      reaper.Main_OnCommand(cmd, 0)
      opened[w.id] = true
      done[#done + 1] = w.label
    end
  end
  set_opened(opened)
  return done, problems
end

local function restore_all()
  local opened, done, problems = get_opened(), {}, {}
  for _, w in ipairs(Windows.WINDOWS) do
    if opened[w.id] then
      local cmd, err = Windows.command(w)
      if not cmd then
        problems[#problems + 1] = w.label .. " " .. err
      else
        if Windows.is_open(cmd) then
          reaper.Main_OnCommand(cmd, 0) -- running the action of an open window closes it
          done[#done + 1] = w.label
        end
        opened[w.id] = nil -- closed now, or by hand before: either way no longer ours
      end
    end
  end
  set_opened(opened)
  return done, problems
end

-- Effect ------------------------------------------------------------------
function Windows.apply(mode)
  local what = Windows.get_assignment(mode)
  if not what then return "skipped", ("no windows setting for %s mode"):format(mode) end

  local done, problems
  if what == Windows.OPEN then done, problems = open_all() else done, problems = restore_all() end

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
    get    = function(mode) return Windows.get_assignment(mode) end,
    format = function(v) return v or "" end,
    parse  = function(text)
      local v, err = Windows.parse(text)
      if v == nil then return false, "windows: " .. err end
      if v == "none" then return true, nil end
      return true, v
    end,
    set    = function(mode, v) Windows.set_assignment(mode, v) end,
  },
}

-- Diagnostics & self-test -------------------------------------------------
--- Live check: every window's script is installed. Registers nothing (only checks the files).
function Windows.check_actions()
  local results = {}
  for _, w in ipairs(Windows.WINDOWS) do
    local path = Actions.script_path(w.id) or ("(unknown script " .. w.id .. ")")
    results[#results + 1] = { name = w.label .. " script at " .. path, ok = reaper.file_exists(path) }
  end
  return results
end

function Windows.diagnostics()
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local configured = reaper.HasExtState(Windows.SECTION, Windows.KEY_PREFIX .. mode)
    rows[#rows + 1] = { mode .. " windows",
      (Windows.get_assignment(mode) or "(none)") .. (configured and "" or " (default)") }
  end
  for _, w in ipairs(Windows.WINDOWS) do
    local cmd, err = Windows.command(w)
    rows[#rows + 1] = { w.id, cmd and ("action %d, %s"):format(cmd, Windows.is_open(cmd) and "open" or "closed")
      or err }
  end
  local opened = reaper.GetExtState(Windows.SECTION, Windows.KEY_OPENED)
  rows[#rows + 1] = { "opened by mode", opened ~= "" and opened or "(none)" }
  return rows
end

-- Uses fake REAPER functions: never opens or closes a real window.
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
  local with_reaper = require("SelfTest").with_reaper
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
    local runs, open = {}, {}
    local list, files = {}, {}
    for i, w in ipairs(Windows.WINDOWS) do
      local path = Actions.join_path("R", Actions.SCRIPTS[w.id], sep)
      if not (opts.missing and opts.missing[w.id]) then files[path] = true end
      list[#list + 1] = { 1000 + i, "Script: " .. Actions.base_name(Actions.SCRIPTS[w.id]), "RS" .. i }
    end
    local fakes = {
      GetResourcePath = function() return "R" end,
      file_exists = function(p) return files[p] == true end,
      kbd_enumerateActions = function(_, i) local e = list[i + 1]; if e then return e[1], e[2] end return 0, "" end,
      ReverseNamedCommandLookup = function(cmd)
        for _, e in ipairs(list) do if e[1] == cmd then return e[3] end end
      end,
      GetToggleCommandStateEx = function(section, cmd) return open[cmd] and 1 or 0 end,
      Main_OnCommand = function(cmd)
        runs[#runs + 1] = cmd
        open[cmd] = not open[cmd]
      end,
    }
    return fakes, runs, open
  end

  -- pure helpers
  check("every window is a known SiSt-Live script", (function()
    for _, w in ipairs(real_windows) do if not Actions.SCRIPTS[w.id] then return false end end
    return true
  end)())
  check("parse: open / restore / empty / garbage", Windows.parse(" Open ") == "open"
    and Windows.parse("restore") == "restore" and Windows.parse("") == "none" and Windows.parse("x") == nil)

  -- defaults and settings
  local fakes, runs, open = fake()
  check("never configured: show opens, edit restores",
    with_reaper(fakes, Windows.get_assignment, "show") == "open"
    and with_reaper(fakes, Windows.get_assignment, "edit") == "restore")
  with_reaper(fakes, Windows.set_assignment, "show", nil)
  check("empty setting turns the default off", with_reaper(fakes, Windows.get_assignment, "show") == nil
    and (with_reaper(fakes, Windows.apply, "show")) == "skipped" and #runs == 0)
  with_reaper(fakes, Windows.set_assignment, "show", "open")

  -- show: open both, remember them
  with_reaper(fakes, Windows.apply, "show")
  check("show twice: nothing more opened (idempotent)",
    (with_reaper(fakes, Windows.apply, "show")) == "skipped" and #runs == 2)

  -- edit: close what show opened
  with_reaper(fakes, Windows.apply, "edit")
  check("edit twice: nothing to close", (with_reaper(fakes, Windows.apply, "edit")) == "skipped" and #runs == 4)

  -- a window that was already open stays open
  fakes, runs, open = fake()
  open[1001] = true -- setlist was open before the show
  with_reaper(fakes, Windows.apply, "show")
  check("show: only the closed window is opened", #runs == 1 and runs[1] == 1002)
  with_reaper(fakes, Windows.apply, "edit")
  check("edit: the window that was open before stays open", open[1001] and not open[1002] and #runs == 2)

  -- closed by hand during the show: not reopened or toggled by edit
  fakes, runs, open = fake()
  with_reaper(fakes, Windows.apply, "show")
  open[1002] = false -- user closed the status display
  with_reaper(fakes, Windows.apply, "edit")
  check("edit: a window closed by hand is not toggled open again", not open[1002] and not open[1001] and #runs == 3)

  -- restart: nothing remembered, nothing closed
  fakes, runs, open = fake()
  open[1001] = true
  check("edit after a restart: nothing closed",
    (with_reaper(fakes, Windows.apply, "edit")) == "skipped" and open[1001] and #runs == 0)

  -- missing script: the other window still opens, the effect fails with a clear message
  fakes, runs, open = fake({ missing = { status = true } })
  local ok, err = pcall(with_reaper, fakes, Windows.apply, "show")
  check("missing script: fails, names it, opens the others",
    not ok and tostring(err):find("Status Display not installed", 1, true) ~= nil and open[1001] and #runs == 1)
  check("live check reports the missing script",
    with_reaper(fakes, Windows.check_actions)[1].ok and not with_reaper(fakes, Windows.check_actions)[2].ok)

  Windows.WINDOWS = real_windows

  return results
end

return Windows
