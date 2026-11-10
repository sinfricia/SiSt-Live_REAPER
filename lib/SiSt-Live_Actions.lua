-- @noindex
-- SiSt-Live actions: the command IDs the suite runs, in one place.
--
-- Two kinds:
--
-- 1. REAPER's own (native) actions. Their command IDs practically never change, their names sometimes
--    do (a REAPER update rewords an action). So the ID is trusted and the name is NOT compared:
--      Actions.require_native(cmd)       before running: fails only if REAPER has no action with that ID
--      Actions.check_native(list)        for "DEBUG Run Self-Test": every ID with its current name, so
--                                        after a REAPER update you can see at a glance what each ID is.
--                                        Only a missing action counts as failed.
--
-- 2. SiSt-Live's own scripts. Their command IDs are given by REAPER when a script is added to the action
--    list, so they differ per installation. They are looked up by the script's FILE NAME:
--      Actions.script_command(id)        command ID of a script in Actions.SCRIPTS, e.g. "mode"
--      Actions.file_command(file)        the same for any package file, e.g. "Transport/SiSt-Live_Start Show.lua"
--    A lookup only looks: it reads the action list (reaper.kbd_enumerateActions: about 4 ms for all ~7000 actions;
--    a script action is named "Script: <file name>"), nothing is added, no file is written. A script that is not in
--    the action list is reported ("run SiSt-Live: Setup"). Two script actions with the same file name are reported
--    as ambiguous. Results are remembered for the rest of the script run.
--      Actions.register(file)            adds a package script to the action list (Setup does this for every
--                                        [main] script of the package; REAPER rewrites reaper-kb.ini itself)
--    The files are where the SiSt-Live package installs them, below <resource path>/Scripts/SiSt-Live.
--    Adding a script: one line in Actions.SCRIPTS.
--
-- Self test: Actions.self_test() returns a list of { name, ok }. Uses fake REAPER functions (SelfTest.with_reaper).

local Actions = {}

Actions.PACKAGE_DIR = "SiSt-Live" -- below <resource path>/Scripts

-- SiSt-Live scripts other scripts need to run or whose toolbar button they light. Paths with "/".
Actions.SCRIPTS = {
  setlist = "Setlist/SiSt-Live_Setlist.lua",
  status  = "Status Display/SiSt-Live_Status Display.lua",
  toolbar = "Toolbar/SiSt-Live_Toolbar.lua",
  mode    = "Modes/SiSt-Live_Toggle Edit-Show Mode.lua",
  debug   = "Debug/SiSt-Live_DEBUG Toggle Logging.lua",
  arrow   = "Modes/SiSt-Live_Lock mouse cursor to arrow in arrange view.lua",
}
Actions.SCRIPT_ORDER = { "setlist", "status", "toolbar", "mode", "debug", "arrow" } -- for diagnostics

-- Native actions ---------------------------------------------------------------------

--- Current name of a native action, or nil if REAPER has no action with that ID.
function Actions.native_name(cmd)
  local name = reaper.kbd_getTextFromCmd(cmd, 0)
  if name == nil or name == "" then return nil end
  return name
end

--- Use before running a native action. Returns its name; throws a clean error if it doesn't exist.
--- what: short description for the error ("Toggle fullscreen").
function Actions.require_native(cmd, what)
  local name = Actions.native_name(cmd)
  if not name then
    error(("REAPER has no action %d%s (run DEBUG Run Self-Test)"):format(cmd,
      what and (" (" .. what .. ")") or ""), 0)
  end
  return name
end

--- Live check for "DEBUG Run Self-Test". list: { { cmd = 40346, what = "Toggle fullscreen" }, ... }.
--- Returns { name, ok } per action: name shows the ID, what it is for and REAPER's current name.
function Actions.check_native(list)
  local results = {}
  for _, a in ipairs(list) do
    local name = Actions.native_name(a.cmd)
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

function Actions.script_path(id)
  local file = Actions.SCRIPTS[id]
  if not file then return nil end
  return Actions.join_path(reaper.GetResourcePath(), file, package.config:sub(1, 1))
end

--- Pure. File name of a package path: "Modes/SiSt-Live_X.lua" -> "SiSt-Live_X.lua".
function Actions.base_name(file)
  return (file:match("([^/\\]+)$"))
end

-- The script actions of the action list: file name -> { command IDs }. One list per `reaper` table: a test swaps
-- in its own fake reaper, so it never sees the real IDs and never leaves fake ones behind (weak keys: a fake's
-- list goes with the fake).
local lists = setmetatable({}, { __mode = "k" })

local function script_actions()
  if lists[reaper] then return lists[reaper] end
  local by_file = {}
  local i = 0
  while true do
    local cmd, name = reaper.kbd_enumerateActions(0, i)
    if not cmd or cmd == 0 then break end
    -- "Script: <file>.lua". The word before the colon may be translated, so only ": " and a Lua file are matched;
    -- a custom action can't be mistaken for a script because a script's named ID starts with "RS".
    local file = name and name:match("^[^:]+:%s(.+%.lua)$")
    if file and (reaper.ReverseNamedCommandLookup(cmd) or ""):sub(1, 2) == "RS" then
      by_file[file] = by_file[file] or {}
      table.insert(by_file[file], cmd)
    end
    i = i + 1
  end
  lists[reaper] = by_file
  return by_file
end

--- Command ID of a script by its file, relative to the package folder ("Transport/x.lua"), or nil + reason.
--- Only looks: nothing is added to the action list (see the top of this file).
function Actions.file_command(file)
  local path = Actions.join_path(reaper.GetResourcePath(), file, package.config:sub(1, 1))
  if not reaper.file_exists(path) then return nil, "not installed: " .. path end
  local base = Actions.base_name(file)
  local found = script_actions()[base]
  if not found then return nil, "not in the action list (run SiSt-Live: Setup): " .. base end
  if #found > 1 then return nil, "more than one script action is named " .. base end
  return found[1]
end

--- Command ID of a SiSt-Live script in Actions.SCRIPTS, or nil + reason.
function Actions.script_command(id)
  local file = Actions.SCRIPTS[id]
  if not file then return nil, "unknown script '" .. tostring(id) .. "'" end
  return Actions.file_command(file)
end

--- Adds a package script (path relative to the package folder) to the action list. Returns its command ID, or nil +
--- reason. Call it only for a script that is missing: adding makes REAPER rewrite reaper-kb.ini.
function Actions.register(file)
  local path = Actions.join_path(reaper.GetResourcePath(), file, package.config:sub(1, 1))
  if not reaper.file_exists(path) then return nil, "not installed: " .. path end
  local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
  lists[reaper] = nil -- the action list changed
  if type(cmd) ~= "number" or cmd <= 0 then return nil, "could not add to the action list: " .. path end
  return cmd
end

-- Diagnostics & self test ------------------------------------------------------------------

function Actions.diagnostics()
  local rows = {}
  for _, id in ipairs(Actions.SCRIPT_ORDER) do
    local cmd, err = Actions.script_command(id)
    rows[#rows + 1] = { "script " .. id, cmd and ("action %d"):format(cmd) or err }
  end
  return rows
end

function Actions.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local names = { [40346] = "View: Toggle fullscreen (renamed in a REAPER update)" }

  -- a fake action list: { cmd, name, named ID }
  local function fake(extra)
    local list = {
      { 40346, "View: Toggle fullscreen", "" },
      { 55918, "Script: SiSt-Live_Toggle Edit-Show Mode.lua", "RS1111" },
      { 55919, "Custom: SiSt-Live_Toggle Edit-Show Mode.lua", "c0ffee" }, -- a custom action, not the script
      { 55920, "Skript: SiSt-Live_Setlist.lua", "RS2222" },               -- translated word before the colon
      { 55921, "Script: SiSt-Live_Twice.lua", "RS3333" },
      { 55922, "Script: SiSt-Live_Twice.lua", "RS4444" },                  -- same file name in two folders
    }
    for _, e in ipairs(extra or {}) do list[#list + 1] = e end
    local installed = { ["Toggle Edit"] = true, ["Setlist"] = true, ["Twice"] = true, ["Start Show"] = true, ["arrow"] = true }
    local added = {}
    local fakes = {
      kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
      GetResourcePath = function() return "R" end,
      file_exists = function(p)
        for key in pairs(installed) do if p:find(key, 1, true) then return true end end
        return false
      end,
      kbd_enumerateActions = function(_, i) local e = list[i + 1]; if e then return e[1], e[2] end return 0, "" end,
      ReverseNamedCommandLookup = function(cmd)
        for _, e in ipairs(list) do if e[1] == cmd then return e[3] end end
      end,
      AddRemoveReaScript = function(_, _, path)
        added[#added + 1] = path
        list[#list + 1] = { 60000, "Script: " .. Actions.base_name(path), "RS9999" }
        return 60000
      end,
    }
    return fakes, added
  end

  local with_reaper = require("SelfTest").with_reaper
  local fakes, added = fake()
  with_reaper(fakes, function()
    -- native
    check("native: existing action, whatever its name", Actions.native_name(40346) ~= nil
      and Actions.require_native(40346) == names[40346])
    local ok, err = pcall(Actions.require_native, 99999, "Something")
    check("native: missing action fails with the ID", not ok and tostring(err):find("99999", 1, true) ~= nil
      and tostring(err):find("Something", 1, true) ~= nil)
    local rows = Actions.check_native({ { cmd = 40346, what = "fullscreen" }, { cmd = 99999, what = "gone" } })
    check("native check: a renamed action passes, a missing one fails", rows[1].ok and not rows[2].ok
      and rows[1].name:find("renamed", 1, true) ~= nil and rows[2].name:find("NO SUCH ACTION", 1, true) ~= nil)

    -- scripts: looked up by file name in the action list
    check("script_command: found by file name, whatever the folder", Actions.file_command("Modes/SiSt-Live_Toggle Edit-Show Mode.lua") == 55918
      and Actions.file_command("Elsewhere/SiSt-Live_Toggle Edit-Show Mode.lua") == 55918)
    check("script_command: a custom action with the same name is not the script",
      Actions.script_command("mode") == 55918)
    check("script_command: translated word before the colon is fine", Actions.file_command("Setlist/SiSt-Live_Setlist.lua") == 55920)
    local none, why = Actions.file_command("Transport/SiSt-Live_Start Show.lua")
    check("script_command: installed but not in the action list says to run Setup",
      none == nil and why:find("run SiSt-Live: Setup", 1, true) ~= nil)
    local not_installed, why2 = Actions.file_command("Status Display/SiSt-Live_Status Display.lua")
    check("script_command: not installed", not_installed == nil and why2:find("not installed", 1, true) ~= nil)
    local twice, why3 = Actions.file_command("Twice/SiSt-Live_Twice.lua")
    check("script_command: two script actions with one file name are ambiguous",
      twice == nil and why3:find("more than one", 1, true) ~= nil)
    check("script_command: unknown id", select(2, Actions.script_command("nope")):find("unknown", 1, true) ~= nil)
    check("lookup only looks: nothing was added", #added == 0)

    -- registering
    local new, new_why = Actions.register("Transport/SiSt-Live_Start Show.lua")
    check("register: adds the script, the next lookup finds it",
      new == 60000 and #added == 1 and Actions.file_command("Transport/SiSt-Live_Start Show.lua") == 60000 and new_why == nil)
    check("register: a script that is not installed is not added",
      Actions.register("Status Display/SiSt-Live_Status Display.lua") == nil and #added == 1)
  end)

  local all_listed = true
  for _, id in ipairs(Actions.SCRIPT_ORDER) do all_listed = all_listed and Actions.SCRIPTS[id] ~= nil end
  check("every script in the diagnostics order exists", all_listed)
  check("base_name: file name of a path", Actions.base_name("Modes/x y.lua") == "x y.lua"
    and Actions.base_name("a\\b\\c.lua") == "c.lua" and Actions.base_name("c.lua") == "c.lua")
  return results
end

return Actions
