-- @noindex
-- Actions: finding and checking REAPER actions. General: nothing in here is specific to one package.
-- (SiSt-Live's own list of scripts and where they are installed is lib/SiSt-Live_Actions.lua.)
--
-- 1. REAPER's own (native) actions. Their command IDs practically never change, their names sometimes
--    do (a REAPER update rewords an action). So the ID is trusted at run time (nothing is checked before an
--    effect runs one) and the name is NOT compared. The on-demand check:
--      Actions.native_name(cmd)           current name of a native action, or nil if REAPER has no such action
--      Actions.check_native(label, list)  for a self-test: ONE line for a group of actions that belong together
--                                         ("window sets: 10 actions exist"); a missing action fails it and is
--                                         listed. Run the self-test after a REAPER update.
--
-- 2. Scripts. Their command IDs are given by REAPER when a script is added to the action list, so they differ per
--    installation. They are looked up by the script's FILE NAME:
--      Actions.find_script(file_name)     command ID, or nil + reason + kind ("missing" or "ambiguous")
--    A lookup only looks: it reads the action list (reaper.kbd_enumerateActions: about 4 ms for all ~7000 actions;
--    a script action is named "Script: <file name>"), nothing is added, no file is written. Results are remembered
--    for the rest of the script run.
--      Actions.register(path)             adds a script (full path) to the action list. Call it only for a script
--                                         that is missing: adding makes REAPER rewrite reaper-kb.ini.
--
-- Self test: Actions.self_test() returns a list of { name, ok }. Uses fake REAPER functions (SelfTest.with_reaper).

local Actions = {}

-- Native actions ---------------------------------------------------------------------

--- Current name of a native action, or nil if REAPER has no action with that ID.
function Actions.native_name(cmd)
  local name = reaper.kbd_getTextFromCmd(cmd, 0)
  if name == nil or name == "" then return nil end
  return name
end

--- Live check for a self-test: one row for a group of native actions that belong together.
--- label: "window sets"; list: { { cmd = 40454, what = "load window set #01" }, ... }.
--- Returns { { name, ok } }: "window sets: 10 actions exist", or "window sets: 2 of 10 actions MISSING: 40455 (load
--- window set #02), ...". Runs nothing.
function Actions.check_native(label, list)
  local missing = {}
  for _, a in ipairs(list) do
    if not Actions.native_name(a.cmd) then missing[#missing + 1] = ("%d (%s)"):format(a.cmd, a.what or "?") end
  end
  if #missing == 0 then
    return { { name = ("%s: %d action%s exist"):format(label, #list, #list == 1 and "" or "s"), ok = true } }
  end
  return { { name = ("%s: %d of %d actions MISSING: %s"):format(label, #missing, #list, table.concat(missing, ", ")),
    ok = false } }
end

-- Scripts ---------------------------------------------------------------------

--- Pure. File name of a path: "Modes/SiSt-Live_X.lua" -> "SiSt-Live_X.lua".
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

--- Command ID of the script action with this file name ("SiSt-Live_X.lua"), or nil + reason + kind: "missing"
--- (not in the action list) or "ambiguous" (more than one script action has this file name).
function Actions.find_script(file_name)
  local found = script_actions()[file_name]
  if not found then return nil, "not in the action list: " .. file_name, "missing" end
  if #found > 1 then return nil, "more than one script action is named " .. file_name, "ambiguous" end
  return found[1]
end

--- Adds a script (full path) to the action list. Returns its command ID, or nil + reason.
function Actions.register(path)
  local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
  lists[reaper] = nil -- the action list changed
  if type(cmd) ~= "number" or cmd <= 0 then return nil, "could not add to the action list: " .. path end
  return cmd
end

-- Self test ------------------------------------------------------------------

function Actions.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local names = { [40346] = "View: Toggle fullscreen (renamed in a REAPER update)" }

  -- a fake action list: { cmd, name, named ID }
  local list = {
    { 40346, "View: Toggle fullscreen", "" },
    { 55918, "Script: SiSt-Live_Toggle Edit-Show Mode.lua", "RS1111" },
    { 55919, "Custom: SiSt-Live_Toggle Edit-Show Mode.lua", "c0ffee" }, -- a custom action, not the script
    { 55920, "Skript: SiSt-Live_Setlist.lua", "RS2222" },               -- translated word before the colon
    { 55921, "Script: SiSt-Live_Twice.lua", "RS3333" },
    { 55922, "Script: SiSt-Live_Twice.lua", "RS4444" },                  -- same file name in two folders
  }
  local added = {}
  local fakes = {
    kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
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

  require("SelfTest").with_reaper(fakes, function()
    -- native
    check("native: existing action, whatever its name", Actions.native_name(40346) == names[40346]
      and Actions.native_name(99999) == nil)
    local good = Actions.check_native("fullscreen", { { cmd = 40346, what = "fullscreen" } })
    check("native check: one line for the group, a renamed action passes",
      #good == 1 and good[1].ok and good[1].name == "fullscreen: 1 action exist")
    local bad = Actions.check_native("things", { { cmd = 40346, what = "fullscreen" }, { cmd = 99999, what = "gone" },
      { cmd = 99998, what = "also gone" } })
    check("native check: a missing action fails the group line and is listed",
      #bad == 1 and not bad[1].ok and bad[1].name:find("2 of 3 actions MISSING", 1, true) ~= nil
      and bad[1].name:find("99999 (gone)", 1, true) ~= nil and bad[1].name:find("99998", 1, true) ~= nil)

    -- scripts: looked up by file name in the action list
    check("find_script: found by file name", Actions.find_script("SiSt-Live_Toggle Edit-Show Mode.lua") == 55918)
    check("find_script: a custom action with the same name is not the script",
      Actions.find_script("SiSt-Live_Toggle Edit-Show Mode.lua") ~= 55919)
    check("find_script: translated word before the colon is fine", Actions.find_script("SiSt-Live_Setlist.lua") == 55920)
    local none, why, kind = Actions.find_script("SiSt-Live_Start Show.lua")
    check("find_script: not in the action list", none == nil and kind == "missing" and why:find("Start Show", 1, true) ~= nil)
    local twice, why2, kind2 = Actions.find_script("SiSt-Live_Twice.lua")
    check("find_script: two script actions with one file name are ambiguous",
      twice == nil and kind2 == "ambiguous" and why2:find("more than one", 1, true) ~= nil)
    check("lookup only looks: nothing was added", #added == 0)

    -- registering
    local new = Actions.register("R/Scripts/SiSt-Live/Transport/SiSt-Live_Start Show.lua")
    check("register: adds the script, the next lookup finds it",
      new == 60000 and #added == 1 and Actions.find_script("SiSt-Live_Start Show.lua") == 60000)
  end)

  check("base_name: file name of a path", Actions.base_name("Modes/x y.lua") == "x y.lua"
    and Actions.base_name("a\\b\\c.lua") == "c.lua" and Actions.base_name("c.lua") == "c.lua")
  return results
end

return Actions
