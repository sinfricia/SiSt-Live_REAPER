-- @noindex
--[[
SiSt-Live Setlist: Resolver (TEMPORARY)

The old conflict resolver, moved here unchanged so that Actions.lua and the main script can use it while the rest of the
Setlist is split up. It is replaced by the silent follow and the load dialog (see Docs/setlist-design.md) and then deleted.
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")

local ENTRY = Data.ENTRY

local Resolver = {}

-- How many times ResolveConflictsWithOpenProj may run by itself before it shows the error dialog
local MAX_RESOLVE_ATTEMPTS = 3

function Resolver.PrintListPaths(list)
   if not Log.is_debug() then return end

   for _, entry in ipairs(list) do
      log:debug("  [%s] (tabIdx [%s]): %s", entry.listIdx or -1, entry.tabIdx or -1, tostring(entry.path))
   end
end

function Resolver.HandleInvalidSetlistStringEntries(validEntries, invalidEntries, context)
   if not context then context = "" end
   local msg = "Couldn't resolve the following entries while loading " .. context .. ":\n\n"
   local title = "Invalid entries found while parsing"
   if validEntries then
      if not next(validEntries) then
         msg = "Couldn't resolve ANY of following entries while loading " .. context .. ":\n\n"
         title = "Error loading from " .. context
      end
   end

   for _, v in ipairs(invalidEntries) do
      msg = msg .. v .. "\n"
   end

   reaper.MB(msg, title, 0)
end

function Resolver.CountEntryOccurrences(entries, entry)
   local count = 0
   for _, occurrence in ipairs(entries) do
      if Data.normalize_path(occurrence.path) == Data.normalize_path(entry.path) then
         count = count + 1
      end
   end
   return count
end

-- Checks a setlist against currently open projects and resolves conflicts.
-- attempt (internal): which pass this is. If a pass ends with the list and the open tabs still disagreeing in
-- length, up to MAX_RESOLVE_ATTEMPTS passes are made automatically before the user is bothered.
function Resolver.ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt)
   attempt = attempt or 1
   log:debug("Conflict resolver: searching for conflicts between list and open projects (pass %d)", attempt)

   if not next(list) then
      log:debug("  Setlist empty, building from open projects")
      return State.read_open_projects()
   end

   local openProjList = State.read_open_projects()

   -- check if any open projects are not in list or vice versa
   local missingInList = {}
   local missingInOpenProjects = {}
   local missingInListStr, missingInOpenProjStr, duplicateProjStr = "\n\n", "\n\n", "\n\n" --only used for message box


   -- build lookup table for projects in list
   local listPaths = {}
   local listDuplicateTracker = {}
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         if not listDuplicateTracker[entry.path] then
            listDuplicateTracker[entry.path] = 0
         else
            listDuplicateTracker[entry.path] = listDuplicateTracker[entry.path] + 1
         end

         listPaths[entry.path] = entry
      end
   end

   -- build lookup table for openProjects and check for projects not in list
   local openPaths = {}
   local duplicateProjects = {}
   local openDuplicateTracker = {}
   for _, entry in ipairs(openProjList) do
      if openPaths[entry.path] and listPaths[entry.path] then
         table.insert(duplicateProjects, entry)
         duplicateProjStr = duplicateProjStr .. entry.path .. " - (duplicate " .. #duplicateProjects .. ")\n"

         if not openDuplicateTracker[entry.path] then
            openDuplicateTracker[entry.path] = 1
         else
            openDuplicateTracker[entry.path] = openDuplicateTracker[entry.path] + 1
         end

         log:debug("Found duplicate no. %d for path %s", openDuplicateTracker[entry.path], entry.path)
      end

      openPaths[entry.path] = entry

      if entry.type == ENTRY.PROJECT and (not listPaths[entry.path]) then
         table.insert(missingInList, entry)
         missingInListStr = missingInListStr .. entry.path .. "\n"
      end
   end

   -- check for entries not in openProjects
   local nextIsDuplicate = {}
   for _, entry in ipairs(list) do
      if not openPaths[entry.path] and entry.type == ENTRY.PROJECT and not nextIsDuplicate[entry.path] then
         table.insert(missingInOpenProjects, entry)
         missingInOpenProjStr = missingInOpenProjStr .. entry.path .. "\n"
         nextIsDuplicate[entry.path] = true
      end
   end

   if Log.is_debug() then
      log:debug("  Open projects: ")
      for _, entry in ipairs(openProjList) do
         log:debug("    " .. entry.path)
      end

      log:debug("  Entries in list: ")
      for _, entry in ipairs(list) do
         log:debug("    " .. entry.path)
      end

      if next(missingInList) then
         log:debug("  Missing in list: ")
         for _, entry in ipairs(missingInList) do
            log:debug("    " .. entry.path)
         end
      end

      if next(missingInOpenProjects) then
         log:debug("  Missing in open projects: ")
         for _, entry in ipairs(missingInOpenProjects) do
            log:debug("    [" .. entry.listIdx .. "]: " .. entry.path)
         end
      end
   end


   -- handle projects that are open in multiple tabs
   if next(duplicateProjects) then
      local msg = "WARNING! The following projects are opened multiple times:" ..
          duplicateProjStr ..
          "\nAre you sure you want that? Clicking 'No' will close all duplicates."

      -- On a retry pass the user has already answered this: duplicates that are still open mean "keep them"
      local ret = attempt > 1 and 6 or reaper.MB(msg, "SETLIST - DUPLICATE PROJECTS FOUND", 3)

      log:debug("Processing duplicate open projects... ")


      if ret == 6 then
         for _, entry in ipairs(duplicateProjects) do
            local duplicateCount = Resolver.CountEntryOccurrences(duplicateProjects, entry)
            local duplicatesInList = Resolver.CountEntryOccurrences(list, entry) - 1

            if duplicatesInList == -1 then
               duplicatesInList = 0
            end

            log:debug("Inserting " ..
               duplicateCount - duplicatesInList ..
               " duplicates of " .. entry.name .. " into list. (If 0 that means all duplicates are already in list.)")

            for i = 1, duplicateCount - duplicatesInList do
               local newEntryIdx = Data.tab_to_list_idx(list, entry.tabIdx)
               log:debug("  Duplicate " .. i .. " (tabIdx [" .. entry.tabIdx .. "]) = at listIdx [" .. newEntryIdx .. "]")
               entry.listIdx = newEntryIdx
               table.insert(list, newEntryIdx, entry)
               list[newEntryIdx].tabIdx = Data.list_to_tab_idx(list, newEntryIdx, State.tab_count)
            end
         end
      elseif ret == 7 then
         for _, entry in ipairs(duplicateProjects) do
            reaper.SelectProjectInstance(entry.proj)
            reaper.Main_OnCommand(Sync.CMD.CLOSE_PROJ_TAB, 0) --Close current project tab
         end
      else
         State.quit = true
         return list
      end

      -- remove unprocessed duplicate entries in list
      for _, entry in ipairs(duplicateProjects) do
         local duplicateCount = Resolver.CountEntryOccurrences(duplicateProjects, entry)
         local duplicatesInList = Resolver.CountEntryOccurrences(list, entry) - 1

         if entry.path == "Unsaved Project" then
            log:debug("DuplicateCount: " .. duplicateCount)
            log:debug("DuplicatesInList: " .. duplicatesInList)
         end
         if duplicatesInList > duplicateCount then
            for i = #list, 1, -1 do
               if list[i].path == entry.path and list[i].proj == nil then
                  table.remove(list, i)
                  listDuplicateTracker[entry.path] = listDuplicateTracker[entry.path] - 1
               end
            end
         end
      end

      Data.update_indexes(State.list)
   end

   -- find additional duplicate entries in list that are not opened and add them to table for next check
   log:debug("Processing duplicates in list that don't correspond to open projects")
   for path, duplicateNumber in pairs(listDuplicateTracker) do
      if duplicateNumber > 0 then
         if openDuplicateTracker[path] then
            duplicateNumber = duplicateNumber - openDuplicateTracker[path]
         end
         log:debug("  " .. path .. " has " .. duplicateNumber .. " unprocessed duplicates in list.")
      end
      local numFoundDuplicate = 0
      for j = #list, 1, -1 do
         if numFoundDuplicate >= duplicateNumber then break end

         local entry = list[j]
         if entry.path == path then
            table.insert(missingInOpenProjects, #missingInOpenProjects + 1, entry)
            numFoundDuplicate = numFoundDuplicate + 1

            missingInOpenProjStr = missingInOpenProjStr .. entry.path .. " - (duplicate #" .. numFoundDuplicate .. ")\n"
            log:debug("  Added to missing in open projects: ")
            log:debug("    [" .. entry.listIdx .. "]: " .. entry.path)
         end
      end
   end

   local openedFileCount = 0
   -- handle projects not open but in list
   if next(missingInOpenProjects) then
      local msg = "The following projects are in the loaded setlist but are not currently open:" ..
          missingInOpenProjStr ..
          "\nDo you want to open these projects? Clicking 'No' will remove them from the list."

      local ret
      if silent then
         ret = 7
      elseif isLoadFile or attempt > 1 then -- on a retry pass the user has already answered: don't ask again
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      log:debug("Processing projects in list but not open... ")
      if ret == 6 then
         -- Open projects on list
         for _, entry in ipairs(missingInOpenProjects) do
            if reaper.file_exists(entry.path) then
               reaper.Main_OnCommand(Sync.CMD.NEW_PROJ_TAB, 0) --New project tab
               reaper.Main_openProject(entry.path)
               State.tab_count = State.tab_count + 1

               entry.tabIdx = Data.list_to_tab_idx(list, entry.listIdx, State.tab_count)
               State.current_proj = reaper.EnumProjects(-1)

               list[entry.listIdx].proj = State.current_proj
               list[entry.listIdx].tabIdx = entry.tabIdx

               Sync.move_tab(State.current_proj, entry.tabIdx, State.tab_count)
               table.insert(openProjList, #openProjList + 1, entry)
            else
               local msg = "The following file was not found. Entry will be added but action needs to be taken:\n\n" ..
                   entry.path
               reaper.MB(msg, "File not found", 0)

               list[entry.listIdx].type = ENTRY.MISSING
            end
         end
         openedFileCount = #missingInOpenProjects
      elseif ret == 7 then
         local numRemoved = 0
         for _, entry in ipairs(missingInOpenProjects) do
            log:debug("  removing [" .. entry.listIdx .. "]: " .. entry.path)

            table.remove(list, entry.listIdx - numRemoved)
            numRemoved = numRemoved + 1
         end
      else
         State.quit = true
         return list
      end
   end

   -- handle projects not in list but open
   if next(missingInList) then
      local msg = "The following projects are currently open but not in the loaded setlist:" ..
          missingInListStr ..
          "\nDo you want to add the projects to the setlist? Clicking 'No' will close them."

      local ret
      if silent or attempt > 1 then
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      log:debug("Processing open projects not in list...")
      Resolver.PrintListPaths(list)


      if ret == 6 then -- Clicked Yes
         -- Add new projects to the list

         for _, entry in ipairs(missingInList) do
            entry.tabIdx = entry.tabIdx + openedFileCount
            local newEntryIdx = Data.tab_to_list_idx(list, entry.tabIdx)
            log:debug("  adding to list: [" .. newEntryIdx .. "] (tabIdx = " .. entry.tabIdx .. ") " .. entry.path)
            table.insert(list, newEntryIdx, entry)
         end
      elseif ret == 7 then -- Clicked No
         for _, entry in ipairs(missingInList) do
            if State.tab_count == 1 then
               reaper.MB("Can't close last open project. Adding it to list.", "Warning", 0)
               table.insert(list, entry)
               break
            end


            reaper.SelectProjectInstance(entry.proj)
            local playState = reaper.GetPlayState()
            log:debug("  play state of the project to close: %d", playState)
            if playState & 4 == 4 then
               reaper.MB("Can't close project while it is recording. Adding it to list.", "Warning", 0)
               table.insert(list, entry)
               goto continue_close_loop
            elseif playState > 0 then
               ret = reaper.MB(
                  "Are you sure you want to close this project while it's playing?\n\nPressing 'No' will add it to the list",
                  "Warning", 4)
               if ret == 7 then
                  table.insert(list, entry)
                  goto continue_close_loop
               end
            end
            reaper.Main_OnCommand(Sync.CMD.CLOSE_PROJ_TAB, 0) --Close current project tab
            State.tab_count = State.tab_count - 1
         end
         ::continue_close_loop::
      else
         State.quit = true
         return list
      end

      Resolver.PrintListPaths(list)
   end


   local projEntriesInList = Data.project_entries(list)
   openProjList = State.read_open_projects()


   --Check for order mismatch
   log:debug("Checking for order mismatch between open projects and list...")
   log:debug("OpenProjList:")
   Resolver.PrintListPaths(openProjList)
   log:debug("projEntriesInList:")
   Resolver.PrintListPaths(projEntriesInList)

   local orderConflict = false
   if #openProjList ~= #projEntriesInList then
      if attempt < MAX_RESOLVE_ATTEMPTS then
         -- Earlier phases (opening/closing tabs, removing duplicates) can leave the counts out of step for one
         -- pass. The list is already partly fixed, so another pass normally finishes the job without any dialog.
         log:info("Length mismatch after pass " .. attempt .. " (" .. #openProjList .. " tabs vs " ..
            #projEntriesInList .. " entries). Running resolver again.")
         return Resolver.ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt + 1)
      end

      local str = #openProjList > #projEntriesInList and "openProj > list" or "openProj < projEntriesInList"
      local ret = reaper.MB(
         "Something went wrong with conflict resolutions. Unequal lengths of openProjList and projEntriesInList: " ..
         str .. ": " .. #openProjList .. " vs " .. #projEntriesInList .. "\nDo you want to run ConclictResolver again?",
         "Error in conflict resolution", 2)

      if ret == 3 then
         State.quit = true
         return {}
      elseif ret == 4 then
         return Resolver.ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt + 1)
      else
         return {}
      end
   end

   for i = 1, #openProjList do
      if not openProjList[i] or not projEntriesInList[i] then
         reaper.MB("Error with resolving conflicts! Aborting", "Error", 0)
         State.list = State.read_open_projects()
         return
      end
      local proj1 = openProjList[i].proj
      local proj2 = projEntriesInList[i].proj

      if proj1 ~= proj2 and openProjList[i].path ~= projEntriesInList[i].path then
         log:debug("  Mismatch at tab index " .. i - 1)
         orderConflict = true
         break
      end
   end

   if orderConflict then
      local msg =
      "Order mismatch detected between setlist and open projects!\n\nSync setlist -> project tabs?\nClicking 'No' will sync project tabs -> setlist."

      local ret
      if silent or isLoadFile then
         ret = 6
      else
         ret = reaper.MB(msg, "Desync detected", 3)
      end

      if ret == 6 then
         Sync.order_tabs(list, State.tab_count)
      elseif ret == 7 then
         list = Sync.follow_tab_order(list)
      else
         State.quit = true
         return list
      end
   end

   Data.update_indexes(list)

   return list
end

-- Uses a parsed list file (current list or autosave): reports invalid entries, then checks it against the open
-- projects (opens missing projects, asks about conflicts). Returns the resulting setlist.
function Resolver.ApplyListFromFile(list, invalidEntries, source)
   if next(invalidEntries) then
      Resolver.HandleInvalidSetlistStringEntries(list, invalidEntries, "from " .. source)
   end

   if next(list) then
      return Resolver.ResolveConflictsWithOpenProj(list, false)
   end
   return {}
end

-- Reads a setlist file, finds its projects (next to the file, then at the stored path) and resolves the list against
-- the open projects. Returns the resulting list, or nil if the file could not be opened.
function Resolver.load_file(loadPath)
   local file = io.open(loadPath, "r")
   if not file then
      reaper.MB("Failed to open file:\n" .. loadPath, "Load setlist from file", 0)
      return nil
   end

   local setlistStr = ""
   for line in file:lines() do
      line = line:match("^%s*(.-)%s*$") -- trim whitespace
      if line ~= "" then
         setlistStr = setlistStr .. line .. "\n"
      end
   end

   file:close()

   local fileList, invalidEntries = Data.text_to_list(setlistStr, "\n", Sync.find_open_tab)

   log:debug("Checking if files exists in setlist directory")
   for i = 1, #fileList do
      if fileList[i].type ~= ENTRY.TEXT then -- text entries have no file behind them
         local path = Data.find_next_to_setlist(loadPath, fileList[i].path)
         fileList[i].path = Data.sanitize_path(path)
         fileList[i].proj = Sync.find_project(fileList[i].path)
      end
   end

   local list = Resolver.ResolveConflictsWithOpenProj(fileList, false, true)

   if not next(invalidEntries) then
      reaper.MB("Loaded setlist from\n" .. loadPath, "Load setlist from file", 0)
   else
      Resolver.HandleInvalidSetlistStringEntries(fileList, invalidEntries, "from " .. loadPath)
   end
   return list
end

return Resolver
