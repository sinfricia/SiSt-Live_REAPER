-- @noindex
-- SiSt-Live actions: the command IDs the suite runs, in one place.
--
-- Two kinds:
--
-- 1. REAPER's own (native) actions. Their command IDs practically never change, their names sometimes
--    do (a REAPER update rewords an action). So the ID is trusted and the name is NOT compared:
--      Actions.require_native(cmd, api)  before running: fails only if REAPER has no action with that ID
--      Actions.check_native(list, api)   for "DEBUG Run Self-Test": every ID with its current name, so
--                                        after a REAPER update you can see at a glance what each ID is.
--                                        Only a missing action counts as failed.
--
-- 2. SiSt-Live's own scripts. Their command IDs are given by REAPER when a script is added to the action
--    list, so they differ per installation. They are looked up by the script's file:
--      Actions.script_command(id, api)   command ID of a script in Actions.SCRIPTS, e.g. "mode"
--    The files are where the SiSt-Live package installs them, below <resource path>/Scripts/SiSt-Live.
--    reaper.AddRemoveReaScript returns the command ID of a script that is in the action list (and adds it
--    if it isn't yet). Results are remembered for the rest of the script run.
--    Adding a script: one line in Actions.SCRIPTS.
--
-- Self test: Actions.self_test() returns a list of { name, ok }. Uses a fake REAPER api.

local Actions = {}

Actions.PACKAGE_DIR = "SiSt-Live" -- below <resource path>/Scripts

-- SiSt-Live scripts other scripts need to run or whose toolbar button they light. Paths with "/".
Actions.SCRIPTS = {
  setlist = "Setlist/SiSt-Live_Setlist.lua",
  status  = "Status Display/SiSt-Live_Status Display.lua",
  toolbar = "Toolbar/SiSt-Live_Toolbar.lua",
  mode    = "Modes/SiSt-Live_Toggle Edit-Show Mode.lua",
  debug   = "Debug/SiSt-Live_DEBUG Toggle Logging.lua",
}
Actions.SCRIPT_ORDER = { "setlist", "status", "toolbar", "mode", "debug" } -- for diagnostics

-- Native actions ---------------------------------------------------------------------

--- Current name of a native action, or nil if REAPER has no action with that ID.
function Actions.native_name(cmd, api)
  api = api or reaper
  local name = api.kbd_getTextFromCmd(cmd, 0)
  if name == nil or name == "" then return nil end
  return name
end

--- Use before running a native action. Returns its name; throws a clean error if it doesn't exist.
--- what: short description for the error ("Toggle fullscreen").
function Actions.require_native(cmd, api, what)
  local name = Actions.native_name(cmd, api)
  if not name then
    error(("REAPER has no action %d%s (run DEBUG Run Self-Test)"):format(cmd,
      what and (" (" .. what .. ")") or ""), 0)
  end
  return name
end

--- Live check for "DEBUG Run Self-Test". list: { { cmd = 40346, what = "Toggle fullscreen" }, ... }.
--- Returns { name, ok } per action: name shows the ID, what it is for and REAPER's current name.
function Actions.check_native(list, api)
  api = api or reaper
  local results = {}
  for _, a in ipairs(list) do
    local name = Actions.native_name(a.cmd, api)
    results[#results + 1] = {
      name = ("%d (%s) = %s"):format(a.cmd, a.what or "?", name or "NO SUCH ACTION"),
      ok = name ~= nil,
    }
  end
  return results
end

-- SiSt-Live scripts ---------------------------------------------------------------------

--- Pure. Full path of a package script. sep: path separator ("\\" on Windows).
function Actions.join_path(resource_path, file, sep)
  sep = sep or "/"
  local parts = { resource_path, "Scripts", Actions.PACKAGE_DIR, file }
  return (table.concat(parts, "/"):gsub("[/\\]+", sep))
end

function Actions.script_path(id, api)
  api = api or reaper
  local file = Actions.SCRIPTS[id]
  if not file then return nil end
  return Actions.join_path(api.GetResourcePath(), file, package.config:sub(1, 1))
end

local cache = {} -- id -> command ID (only for the real REAPER api)

--- Command ID of a SiSt-Live script, or nil + reason.
function Actions.script_command(id, api)
  api = api or reaper
  if api == reaper and cache[id] then return cache[id] end
  local path = Actions.script_path(id, api)
  if not path then return nil, "unknown script '" .. tostring(id) .. "'" end
  if not api.file_exists(path) then return nil, "not installed: " .. path end
  local cmd = api.AddRemoveReaScript(true, 0, path, true)
  if type(cmd) ~= "number" or cmd <= 0 then return nil, "could not get an action for " .. path end
  if api == reaper then cache[id] = cmd end
  return cmd
end

-- Diagnostics & self test ------------------------------------------------------------------

function Actions.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, id in ipairs(Actions.SCRIPT_ORDER) do
    local cmd, err = Actions.script_command(id, api)
    rows[#rows + 1] = { "script " .. id, cmd and ("action %d"):format(cmd) or err }
  end
  return rows
end

function Actions.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local names = { [40346] = "View: Toggle fullscreen (renamed in a REAPER update)" }
  local api = {
    kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
    GetResourcePath = function() return "R" end,
    file_exists = function(p) return p:find("Status Display", 1, true) == nil end, -- status not installed
    AddRemoveReaScript = function(_, _, path) return path:find("Toggle Edit", 1, true) and 55926 or 1234 end,
  }

  -- native
  check("native: existing action, whatever its name", Actions.native_name(40346, api) ~= nil
    and Actions.require_native(40346, api) == names[40346])
  local ok, err = pcall(Actions.require_native, 99999, api, "Something")
  check("native: missing action fails with the ID", not ok and tostring(err):find("99999", 1, true) ~= nil
    and tostring(err):find("Something", 1, true) ~= nil)
  local rows = Actions.check_native({ { cmd = 40346, what = "fullscreen" }, { cmd = 99999, what = "gone" } }, api)
  check("native check: a renamed action passes, a missing one fails", rows[1].ok and not rows[2].ok
    and rows[1].name:find("renamed", 1, true) ~= nil and rows[2].name:find("NO SUCH ACTION", 1, true) ~= nil)

  -- scripts
  check("join_path: separators", Actions.join_path("C:\\R", "Modes/x.lua", "\\") == "C:\\R\\Scripts\\SiSt-Live\\Modes\\x.lua"
    and Actions.join_path("/r/", "a/b.lua", "/") == "/r/Scripts/SiSt-Live/a/b.lua")
  check("script_command: found by its file", Actions.script_command("mode", api) == 55926)
  local none, why = Actions.script_command("status", api)
  check("script_command: not installed", none == nil and why:find("not installed", 1, true) ~= nil)
  check("script_command: unknown id", select(2, Actions.script_command("nope", api)):find("unknown", 1, true) ~= nil)
  local all_listed = true
  for _, id in ipairs(Actions.SCRIPT_ORDER) do all_listed = all_listed and Actions.SCRIPTS[id] ~= nil end
  check("every script in the diagnostics order exists", all_listed)
  return results
end

return Actions
