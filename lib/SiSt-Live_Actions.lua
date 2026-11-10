-- @noindex
-- SiSt-Live actions: SiSt-Live's own scripts, where they are installed and how other scripts find them.
-- (The general tools, looking up a script by file name, registering it, checking native actions, are in
-- lib/Actions.lua.)
--
-- SiSt-Live's scripts get their command IDs from REAPER when they are added to the action list, so the IDs differ per
-- installation. They are looked up by the script's FILE NAME, below <resource path>/Scripts/SiSt-Live:
--   Actions.script_command(id)        command ID of a script in Actions.SCRIPTS, e.g. "mode"
--   Actions.file_command(file)        the same for any package file, e.g. "Transport/SiSt-Live_Start Show.lua"
--   Actions.register(file)            adds a package script to the action list (Setup does this for every [main]
--                                     script of the package; REAPER rewrites reaper-kb.ini itself)
-- Both lookups return the command ID, or nil + reason + kind ("not_installed", "missing", "ambiguous"). A lookup only
-- looks: a script that is installed but not in the action list is reported ("run SiSt-Live: Setup"), nothing is added.
--
-- Adding a script: one line in Actions.SCRIPTS (and the package header in Setup/SiSt-Live_Setup.lua).
--
-- Self test: Actions.self_test() returns a list of { name, ok }. Uses fake REAPER functions (SelfTest.with_reaper).

local General = require("Actions")

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

--- Command ID of a script by its file, relative to the package folder ("Transport/x.lua"), or nil + reason + kind.
--- Only looks: nothing is added to the action list (see the top of this file).
function Actions.file_command(file)
  local path = Actions.join_path(reaper.GetResourcePath(), file, package.config:sub(1, 1))
  if not reaper.file_exists(path) then return nil, "not installed: " .. path, "not_installed" end
  local cmd, why, kind = General.find_script(General.base_name(file))
  if cmd then return cmd end
  if kind == "missing" then why = why .. " (run SiSt-Live: Setup)" end
  return nil, why, kind
end

--- Command ID of a SiSt-Live script in Actions.SCRIPTS, or nil + reason + kind.
function Actions.script_command(id)
  local file = Actions.SCRIPTS[id]
  if not file then return nil, "unknown script '" .. tostring(id) .. "'", "unknown" end
  return Actions.file_command(file)
end

--- Adds a package script (path relative to the package folder) to the action list. Returns its command ID, or nil +
--- reason. Call it only for a script that is missing: adding makes REAPER rewrite reaper-kb.ini.
function Actions.register(file)
  local path = Actions.join_path(reaper.GetResourcePath(), file, package.config:sub(1, 1))
  if not reaper.file_exists(path) then return nil, "not installed: " .. path end
  return General.register(path)
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

  -- a fake action list: { cmd, name, named ID }
  local list = {
    { 55918, "Script: SiSt-Live_Toggle Edit-Show Mode.lua", "RS1111" },
    { 55920, "Skript: SiSt-Live_Setlist.lua", "RS2222" },
    { 55921, "Script: SiSt-Live_Twice.lua", "RS3333" },
    { 55922, "Script: SiSt-Live_Twice.lua", "RS4444" },
  }
  local installed = { ["Toggle Edit"] = true, ["Setlist"] = true, ["Twice"] = true, ["Start Show"] = true }
  local added = {}
  local fakes = {
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
      list[#list + 1] = { 60000, "Script: " .. General.base_name(path), "RS9999" }
      return 60000
    end,
  }

  check("join_path: resource path, package folder and file, with the separator",
    Actions.join_path("C:/R", "Modes/x.lua", "\\") == "C:\\R\\Scripts\\SiSt-Live\\Modes\\x.lua")

  require("SelfTest").with_reaper(fakes, function()
    check("file_command: found by file name, whatever the folder",
      Actions.file_command("Modes/SiSt-Live_Toggle Edit-Show Mode.lua") == 55918
      and Actions.file_command("Elsewhere/SiSt-Live_Toggle Edit-Show Mode.lua") == 55918)
    check("script_command: found by its id", Actions.script_command("mode") == 55918)
    local none, why, kind = Actions.file_command("Transport/SiSt-Live_Start Show.lua")
    check("file_command: installed but not in the action list says to run Setup",
      none == nil and kind == "missing" and why:find("run SiSt-Live: Setup", 1, true) ~= nil)
    local not_installed, why2, kind2 = Actions.file_command("Status Display/SiSt-Live_Status Display.lua")
    check("file_command: not installed", not_installed == nil and kind2 == "not_installed"
      and why2:find("not installed", 1, true) ~= nil)
    local twice, _, kind3 = Actions.file_command("Twice/SiSt-Live_Twice.lua")
    check("file_command: two script actions with one file name are ambiguous", twice == nil and kind3 == "ambiguous")
    local unknown, why4 = Actions.script_command("nope")
    check("script_command: unknown id", unknown == nil and why4:find("unknown", 1, true) ~= nil)
    check("lookup only looks: nothing was added", #added == 0)

    local new = Actions.register("Transport/SiSt-Live_Start Show.lua")
    check("register: adds the script, the next lookup finds it",
      new == 60000 and #added == 1 and Actions.file_command("Transport/SiSt-Live_Start Show.lua") == 60000)
    check("register: a script that is not installed is not added",
      Actions.register("Status Display/SiSt-Live_Status Display.lua") == nil and #added == 1)
  end)

  local all_listed = true
  for _, id in ipairs(Actions.SCRIPT_ORDER) do all_listed = all_listed and Actions.SCRIPTS[id] ~= nil end
  check("every script in the diagnostics order exists", all_listed)
  return results
end

return Actions
