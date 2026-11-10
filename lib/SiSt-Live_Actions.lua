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
--    A script that is in the action list is found in reaper-kb.ini (read only) and its named ID turned into
--    the command ID. Only a script that isn't there yet is added with reaper.AddRemoveReaScript: adding makes
--    REAPER rewrite reaper-kb.ini, even for a script that is already in the list. Results are remembered for
--    the rest of the script run.
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

--- Pure. Named ID ("_RS...") of the script at `path` (full path) in the main section of reaper-kb.ini, or nil.
--- kb_text: the file's text. REAPER stores the paths relative to <resource path>/Scripts (or full), with or
--- without quotes. Separators and case are ignored.
function Actions.find_registered(kb_text, resource_path, path)
  local function norm(p) return (p:gsub("[/\\]+", "/"):lower()) end
  local wanted = norm(path)
  local scripts = norm(resource_path .. "/Scripts/")
  for line in ((kb_text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local id, stored = line:match('^SCR%s+%S+%s+0%s+(%S+)%s+"[^"]*"%s+(.-)%s*$')
    if id and stored ~= "" then
      stored = norm(stored:match('^"(.*)"$') or stored)
      if stored == wanted or scripts .. stored == wanted then return "_" .. id end
    end
  end
  return nil
end

local function read_kb(api)
  local f = io.open(api.GetResourcePath() .. package.config:sub(1, 1) .. "reaper-kb.ini", "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local cache = {} -- path -> command ID (only for the real REAPER api)

--- Command ID of a script by its file, relative to the package folder ("Transport/x.lua"), or nil + reason.
--- Finds it in the action list; adds it only if it isn't there yet (see the top of this file).
function Actions.file_command(file, api)
  api = api or reaper
  local path = Actions.join_path(api.GetResourcePath(), file, package.config:sub(1, 1))
  if api == reaper and cache[path] then return cache[path] end
  if not api.file_exists(path) then return nil, "not installed: " .. path end
  local named = Actions.find_registered(read_kb(api), api.GetResourcePath(), path)
  local cmd = named and api.NamedCommandLookup(named) or 0
  if type(cmd) ~= "number" or cmd <= 0 then cmd = api.AddRemoveReaScript(true, 0, path, true) end
  if type(cmd) ~= "number" or cmd <= 0 then return nil, "could not get an action for " .. path end
  if api == reaper then cache[path] = cmd end
  return cmd
end

--- Command ID of a SiSt-Live script in Actions.SCRIPTS, or nil + reason.
function Actions.script_command(id, api)
  local file = Actions.SCRIPTS[id]
  if not file then return nil, "unknown script '" .. tostring(id) .. "'" end
  return Actions.file_command(file, api)
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

  -- finding a script in reaper-kb.ini (registering instead would make REAPER rewrite the file on every run)
  local kb = table.concat({
    'SCR 4 32060 RSmidi "Custom: x.lua" "SiSt-Live/Modes/x.lua"',
    'SCR 4 0 RSquoted "Custom: x.lua" "SiSt-Live/Modes/x.lua"',
    'SCR 4 0 RSplain "Custom: y.lua" SiSt-Live/Transport/y.lua',
    'SCR 4 0 RSfull "Custom: z.lua" "D:\\Other\\z.lua"',
  }, "\r\n")
  check("find_registered: main section only, quoted path, separators and case ignored",
    Actions.find_registered(kb, "C:\\R", "c:\\r\\Scripts\\SiSt-Live\\MODES\\x.lua") == "_RSquoted")
  check("find_registered: path without quotes, full path",
    Actions.find_registered(kb, "C:/R", "C:/R/Scripts/SiSt-Live/Transport/y.lua") == "_RSplain"
    and Actions.find_registered(kb, "C:/R", "d:/other/z.lua") == "_RSfull"
    and Actions.find_registered(kb, "C:/R", "C:/R/Scripts/SiSt-Live/Modes/other.lua") == nil)
  local all_listed = true
  for _, id in ipairs(Actions.SCRIPT_ORDER) do all_listed = all_listed and Actions.SCRIPTS[id] ~= nil end
  check("every script in the diagnostics order exists", all_listed)
  return results
end

return Actions
