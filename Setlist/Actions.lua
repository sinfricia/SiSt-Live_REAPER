-- @noindex
--[[
SiSt-Live Setlist: Actions

What the user can do to the list. Every function here changes State.list (and the tabs where needed) and saves the
current list; none of them draws anything or asks a question: the UI asks (UI/Ask.lua), then calls the action with the
answer. So the same code serves a button, a menu and a test.

  commit()                          after every change: refresh the index fields and save the current list
  insert_text(name), rename_text(entry, name), color_text(entry, r, g, b), duplicate_text(idx), delete_entry(idx)
  drop_entry(dragIdx, dropIdx, direction, duplicate)    a drag and drop in the list (moves the tab of a project)
  close_project(entry), replace_project(entry, path)
  reset()                           the list becomes the open projects (the old list is kept as the autosave)
  read_autosave(), restore(list, invalid, source)       bring the autosave back (the current list becomes the autosave)
  load_from_file(path), save_to_file(path)

reset, restore and load_from_file replace the whole list: the old one is kept as the autosave first (Data.archive_list).
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local Resolver = require("Setlist.Resolver")

local ENTRY = Data.ENTRY

local Actions = {}

-- Call after EVERY change to the list (insert, delete, rename, move...). It refreshes the index fields and saves, so a
-- crash never loses edits.
function Actions.commit()
   Data.update_indexes(State.list)
   Data.save_current_list(State.list)
end

-- Text entries --------------------------------------------------------------------------------------------------

function Actions.insert_text(name)
   table.insert(State.list, { name = name, path = name, type = ENTRY.TEXT })
   Actions.commit()
end

function Actions.rename_text(entry, name)
   entry.name = name
   Actions.commit()
end

function Actions.color_text(entry, r, g, b)
   log:debug("Text Highlight set to color: " .. r .. "," .. g .. "," .. b)
   entry.highlight = { r, g, b, 0.4 }
   Actions.commit()
end

function Actions.duplicate_text(idx)
   log:debug("Duplicating Text Item: " .. State.list[idx].name)
   table.insert(State.list, idx + 1, Data.copy_table(State.list[idx]))
   Actions.commit()
end

function Actions.delete_entry(idx)
   log:debug("Removing [" .. idx .. "]: " .. tostring(State.list[idx].path))
   table.remove(State.list, idx)
   Actions.commit()
end

-- Projects ------------------------------------------------------------------------------------------------------

-- Closes the tab. The list follows the tabs by itself (see the sync check in Frame).
function Actions.close_project(entry)
   Sync.close_project(entry.proj)
end

-- The entry now points at another project file: opens it in a new tab at the entry's place and closes the old tab.
function Actions.replace_project(entry, path)
   local list = State.list
   reaper.Main_OnCommand(Sync.CMD.NEW_PROJ_TAB, 0)
   if reaper.file_exists(path) then
      reaper.Main_openProject(path)
   else
      reaper.MB("Selected file couldn't be loaded", "Error", 0)
   end

   local tabIdx = entry.tabIdx
   if not tabIdx then
      tabIdx = Data.list_to_tab_idx(list, entry.listIdx, State.tab_count)
   end

   Sync.move_tab(reaper.EnumProjects(-1), tabIdx, State.tab_count)

   if entry.proj then
      Sync.close_project(entry.proj)
   end

   local target = list[entry.listIdx]
   target.type = ENTRY.PROJECT
   target.proj = reaper.EnumProjects(-1)
   target.path = path
   target.name = Data.project_name(path)
   target.tabIdx = Data.list_to_tab_idx(list, entry.listIdx, State.tab_count)
   Actions.commit()
end

-- A drag and drop in the list. dragIdx: the entry that was dragged, dropIdx: where it was dropped, direction: 1 when it
-- was dragged down the list, -1 up. duplicate: copy a text entry instead of moving it. A project entry also moves its tab.
function Actions.drop_entry(dragIdx, dropIdx, direction, duplicate)
   local list = State.list
   local dragEntry = list[dragIdx]

   if direction == 1 then
      dropIdx = dropIdx + 1
   end

   if dragEntry.type == ENTRY.TEXT and duplicate then
      log:debug("Duplicating Text Item: " .. dragEntry.name)
      local copy = Data.copy_table(dragEntry)
      copy.listIdx = dropIdx
      table.insert(list, dropIdx, copy)
      log:debug("Inserted duplicate at idx " .. copy.listIdx)
   else
      if dragEntry.type == ENTRY.PROJECT then
         local newTabIdx = Data.list_to_tab_idx(list, dropIdx, State.tab_count)
         Sync.move_tab(dragEntry.proj, newTabIdx, State.tab_count)
      end

      if direction == 1 then
         table.insert(list, dropIdx, dragEntry)
         table.remove(list, dragIdx)
      else
         table.remove(list, dragIdx)
         table.insert(list, dropIdx, dragEntry)
      end
   end

   Actions.commit()
end

-- Replacing the whole list ----------------------------------------------------------------------------------------

function Actions.reset()
   Data.archive_list(Data.list_to_text(State.list, "\n"))
   State.list = State.read_open_projects()
   Actions.commit()
end

-- The autosave as entries: list, invalid lines, where it came from. An empty list when there is none.
function Actions.read_autosave()
   local list, invalid, _, source = Data.read_list_file(Data.autosave_path(), "autosave", Sync.find_open_tab)
   return list, invalid, source
end

-- Replaces the list with the autosave (read_autosave's result); the old list becomes the autosave.
function Actions.restore(list, invalid, source)
   local oldText = Data.list_to_text(State.list, "\n")
   local restored = Resolver.ApplyListFromFile(list, invalid, source) or {}
   if State.quit then return end
   Data.archive_list(oldText)
   State.list = restored
   Actions.commit()
end

-- Replaces the list with a setlist file; the old list becomes the autosave. Returns false if the file couldn't be read.
function Actions.load_from_file(path)
   local oldText = Data.list_to_text(State.list, "\n")
   local loaded = Resolver.load_file(path)
   if not loaded then return false end
   if not State.quit then Data.archive_list(oldText) end
   State.list = loaded
   if not State.quit then Actions.commit() end
   return true
end

-- Writes the list to a setlist file. Returns true, or false and the reason.
function Actions.save_to_file(path)
   local file, err = io.open(path, "w")
   if not file then return false, err end
   file:write(Data.list_to_text(State.list, "\n"))
   file:close()
   return true
end

return Actions
