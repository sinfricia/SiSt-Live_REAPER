-- @noindex
--[[
SiSt-Live Setlist: Sync

Everything about the list and REAPER's project tabs: reading the open tabs, moving, closing and ordering them, and the
pure part that compares the list with the tabs. The list itself and its files are in Data.lua; nothing here keeps state.

  Reading      open_count, open_projects, project_pointers, find_project, find_open_tab, tab_index, project_length,
               total_length
  Changing     move_tab, order_tabs, close_project
  Comparing    is_in_order, reorder_by_tabs, follow_tab_order (pure: the list follows the order of the tabs)

Self test: Sync.self_test() returns a list of { name, ok }.
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Data = require("Setlist.Data")

local Sync = {}

local ENTRY = Data.ENTRY

-- Native REAPER actions
Sync.CMD = {
   NEW_PROJ_TAB = 40859,   -- File: New project tab
   CLOSE_PROJ_TAB = 40860, -- File: Close current project tab
   TAB_MOVE_LEFT = 3242,   -- Project tabs: Move project tab left by one
   TAB_MOVE_RIGHT = 3243,  -- Project tabs: Move project tab right by one
}
local CMD = Sync.CMD

-- Reading the tabs -------------------------------------------------------------------------------

--- The number of open project tabs.
function Sync.open_count()
   local count = 0
   while reaper.EnumProjects(count) do count = count + 1 end
   return count
end

--- The open tabs as list entries, in tab order (an unsaved project is called "Unsaved Project").
function Sync.open_projects()
   local list = {}
   while true do
      local idx = #list
      local proj, path = reaper.EnumProjects(idx)
      if not proj then break end

      local name
      if path == "" then
         name = "Unsaved Project"
         path = name
      else
         name = Data.project_name(path)
      end

      list[#list + 1] = {
         name = name,
         path = path,
         proj = proj,
         listIdx = idx + 1, -- position in the list, 1 based
         tabIdx = idx,      -- project tab position, 0 based
         type = ENTRY.PROJECT,
      }
   end
   return list
end

--- The summed length of the projects of a list of entries (see project_length).
function Sync.total_length(list)
   local total = 0
   for _, entry in ipairs(list) do
      total = total + Sync.project_length(entry.proj)
   end
   return total
end

function Sync.find_project(path, duplicateNumber)
   if not duplicateNumber then
      duplicateNumber = 0
   end
   local idx = 0

   log:debug("Getting project from path")
   log:debug("  Looking for (duplicate) instance " .. duplicateNumber)
   while true do
      local proj, projPath = reaper.EnumProjects(idx)
      if not proj then
         log:debug("    Not found. Project not open.")
         return nil
      end
      if path == projPath then
         if duplicateNumber == 0 then
            log:debug("    Found at tab idx [%d]", idx)
            return proj
         else
            duplicateNumber = duplicateNumber - 1
         end
      end
      idx = idx + 1
   end
end

-- The open tab for the n-th (0-based) project with this path: its pointer and tab index. Used when reading a list.
function Sync.find_open_tab(path, nth)
   local proj = Sync.find_project(path, nth)
   return proj, proj and Sync.tab_index(proj) or nil
end

function Sync.tab_index(targetProj)
   local idx = 0
   while true do
      local proj = reaper.EnumProjects(idx)
      if not proj then return end
      if proj == targetProj then
         return idx
      end
      idx = idx + 1
   end
end

function Sync.project_length(proj) -- used because reaper.GetProjectLength was unreliable...
   local markerCount = reaper.CountProjectMarkers(proj)

   for i = markerCount - 1, 0, -1 do
      local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers2(proj, i)
      if retval and not isrgn then
         return pos
      end
   end

   return 0
end

-- All open project tabs, in tab order.
function Sync.project_pointers()
   local ptrs = {}
   while true do
      local proj = reaper.EnumProjects(#ptrs)
      if not proj then break end
      ptrs[#ptrs + 1] = proj
   end
   return ptrs
end

-- Changing the tabs --------------------------------------------------------------------------------

--- Moves the tab of a project to tab position target_idx (0-based, at most tab_count) with REAPER's "move tab" action.
function Sync.move_tab(targetProj, targetIdx, tab_count)
   if not targetProj then return end

   local startIdx = Sync.tab_index(targetProj)
   if not targetIdx or not startIdx then return end

   targetIdx = math.max(0, math.min(tab_count, targetIdx))

   log:debug("Starting move for '" ..
      reaper.GetProjectName(targetProj) .. "' from tabIdx [" .. startIdx .. "] to [" .. targetIdx .. "]")

   local moveDirection = 0

   if targetIdx > startIdx then
      moveDirection = 1  -- Move right (down with drag&drop)
   elseif targetIdx < startIdx then
      moveDirection = -1 -- Move left (down with drag&drop)
   else
      log:debug("Aborted move: targetIdx == startIdx")
      return -- No movement
   end

   log:debug("  moveDirection: " .. moveDirection)

   local tabMoveCmdID = { [-1] = CMD.TAB_MOVE_LEFT, [1] = CMD.TAB_MOVE_RIGHT }

   log:debug("  Number of move commands: " .. (targetIdx - startIdx) * moveDirection)
   for i = 1, (targetIdx - startIdx) * moveDirection do
      log:debug("    Move " .. i)

      reaper.Main_OnCommandEx(tabMoveCmdID[moveDirection], 0, targetProj) --Project tabs: Move project tab left/right by one
   end
end

--- Puts the tabs in the order of the list's project entries (and sets their tabIdx).
function Sync.order_tabs(list, tab_count)
   log:debug("Starting project tab sort...")

   for i, entry in ipairs(Data.project_entries(list)) do
      Sync.move_tab(entry.proj, i - 1, tab_count)
      entry.tabIdx = i - 1
   end
end

function Sync.close_project(proj)
   local prevProj = reaper.EnumProjects(-1) -- remember which tab was active
   reaper.SelectProjectInstance(proj)
   reaper.Main_OnCommand(CMD.CLOSE_PROJ_TAB, 0)
   if prevProj ~= proj and reaper.ValidatePtr(prevProj, "ReaProject*") then
      reaper.SelectProjectInstance(prevProj) -- go back to the tab the user was on
   end
end

-- Comparing the list with the tabs ----------------------------------------------------------------

-- True if the project entries of the list are in the same order as the given tabs.
function Sync.is_in_order(list, tabProjs)
   local n = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         if entry.proj ~= tabProjs[n] then return false end
      end
   end
   return true
end

-- Pure function: returns a NEW list where text/missing entries keep their positions and the
-- project entries are re-ordered to match tabProjs (tab order). Does not modify the input.
-- Returns (list, true) on success, or (originalList, false) if the entries can't be matched
-- unambiguously (count mismatch, entry without proj, same project twice).
function Sync.reorder_by_tabs(list, tabProjs)
   local entryByProj = {}
   local projEntryCount = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         if not entry.proj or entryByProj[entry.proj] then return list, false end
         entryByProj[entry.proj] = entry
         projEntryCount = projEntryCount + 1
      end
   end

   if projEntryCount ~= #tabProjs then return list, false end

   local orderedEntries = {}
   for i, proj in ipairs(tabProjs) do
      if not entryByProj[proj] then return list, false end
      orderedEntries[i] = entryByProj[proj]
   end

   local result = {}
   local n = 0
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         result[i] = orderedEntries[n]
      else
         result[i] = entry
      end
   end

   return result, true
end

-- Returns the list re-ordered to match the current tab order. Assign the result: list = Update...(list)
function Sync.follow_tab_order(list, tabProjs)
   log:debug("Updating setlist from open projects...")
   local result, ok = Sync.reorder_by_tabs(list, tabProjs or Sync.project_pointers())
   if not ok then log:warn("could not match list entries to open tabs unambiguously, list left unchanged") end
   return result
end

-- Self test ---------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("Sync.reorder_by_tabs", function(t)
   local T1, T2 = { type = ENTRY.TEXT, name = "T1" }, { type = ENTRY.TEXT, name = "T2" }
   local A = { type = ENTRY.PROJECT, proj = "a", name = "A" }
   local B = { type = ENTRY.PROJECT, proj = "b", name = "B" }
   local C = { type = ENTRY.PROJECT, proj = "c", name = "C" }
   local list = { T1, A, T2, B, C }

   local result, ok = Sync.reorder_by_tabs(list, { "c", "a", "b" })
   t.eq({ result[1].name, result[2].name, result[3].name, result[4].name, result[5].name },
      { "T1", "C", "T2", "A", "B" }, "text entries stay, projects follow tab order")
   t.eq({ list[2].name, list[4].name, list[5].name }, { "A", "B", "C" }, "input list is not modified")

   local same, okSame = Sync.reorder_by_tabs(list, { "a", "b", "c" })
   t.ok(okSame, "already ordered")
   t.eq(same[2].name, "A", "order unchanged")

   local r1, ok1 = Sync.reorder_by_tabs(list, { "a", "b" })
   t.ok(not ok1 and r1 == list, "count mismatch leaves list untouched")
   local r2, ok2 = Sync.reorder_by_tabs(list, { "a", "b", "zzz" })
   t.ok(not ok2 and r2 == list, "unknown tab leaves list untouched")
   local r3, ok3 = Sync.reorder_by_tabs({ { type = ENTRY.PROJECT, name = "no proj" } }, { "a" })
   t.ok(not ok3, "entry without proj is refused")
   local dup = { A, { type = ENTRY.PROJECT, proj = "a", name = "A2" } }
   local _, ok4 = Sync.reorder_by_tabs(dup, { "a", "a" })
   t.ok(not ok4, "same proj twice is refused")
end)

define("Sync.is_in_order", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT, proj = "a" }, { type = ENTRY.PROJECT, proj = "b" } }
   t.ok(Sync.is_in_order(list, { "a", "b" }), "in sync")
   t.ok(not Sync.is_in_order(list, { "b", "a" }), "swapped")
end)

function Sync.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Sync
