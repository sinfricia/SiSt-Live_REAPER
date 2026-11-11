-- @noindex
--[[
SiSt-Live Setlist: Actions

What the user can do to the list. Every function here changes State.list (and the tabs where needed) and saves the
current list; none of them draws anything or asks a question: the UI asks (UI/Ask.lua), then calls the action with the
answer. So the same code serves a button, a menu and a test.

  commit()                          after every change: refresh the index fields and save the current list
  follow_tabs()                     the list follows the open tabs (opened, closed, moved projects)
  insert_text(name), rename_text(entry, name), color_text(entry, r, g, b), duplicate_text(idx), delete_entry(idx)
  drop_entry(dragIdx, dropIdx, direction, duplicate)    a drag and drop in the list (moves the tab of a project)
  close_project(entry), replace_project(entry, path)
  reset()                           the list becomes the open projects (the old list is kept as the autosave)
  read_setlist_file(path), read_autosave()          the entries of a setlist file / of the autosave
  revive_missing(list)                              missing entries whose file is back become projects again
  start_load(plan, name), step_job()                load a setlist (Sync.plan_load): opens its projects one per frame
  save_to_file(path)
  playback_blocker()                                the name of a project that plays or records, or nil

reset and start_load replace the whole list: the old one is kept as the autosave first (Data.archive_list).
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")

local ENTRY = Data.ENTRY

local Actions = {}

-- Call after EVERY change to the list (insert, delete, rename, move...). It refreshes the index fields and saves, so a
-- crash never loses edits.
function Actions.commit()
   Data.update_indexes(State.list)
   Data.save_current_list(State.list)
   State.modified = State.name ~= nil and Data.list_to_text(State.list, "\n") ~= State.saved_text
end

-- The list follows the open tabs: projects opened in REAPER are added at their tab position, closed ones are removed,
-- moved ones are reordered, text entries stay. Returns the Sync.diff that was applied.
function Actions.follow_tabs()
   local tabs = State.read_open_projects()
   local d = Sync.diff(State.list, tabs)
   State.list = Sync.follow_tabs(State.list, tabs, d)
   Actions.commit()
   return d
end

-- Text entries --------------------------------------------------------------------------------------------------

-- Inserts a text entry after the active project and the text entries linked to it (at the end when there is none).
-- Returns the new entry.
function Actions.insert_text(name)
   local at = #State.list + 1
   for i, entry in ipairs(State.list) do
      if entry.proj and entry.proj == State.current_proj then
         local _, last = Data.link_block(State.list, i)
         at = last + 1
         break
      end
   end
   local entry = { name = name, path = name, type = ENTRY.TEXT }
   table.insert(State.list, at, entry)
   Actions.commit()
   return entry
end

-- (the path of a text entry is its text)
function Actions.rename_text(entry, name)
   entry.name, entry.path = name, name
   Actions.commit()
end

-- Links the text entry at idx to the project above / below it (dir "above" / "below"). Returns false, and changes
-- nothing, when no project is right there (Data.can_link).
function Actions.link_text(idx, dir)
   local chain = Data.link_chain(State.list, idx, dir)
   if not chain then return false end
   for _, i in ipairs(chain) do State.list[i].link = dir end -- the text entries in between are linked too
   Actions.commit()
   return true
end

function Actions.unlink_text(idx)
   State.list[idx].link = nil
   Actions.commit()
end

function Actions.color_text(entry, r, g, b)
   log:debug("Text Highlight set to color: " .. r .. "," .. g .. "," .. b)
   entry.highlight = { r, g, b, 0.4 }
   Actions.commit()
end

function Actions.duplicate_text(idx)
   log:debug("Duplicating Text Item: " .. State.list[idx].name)
   local copy = Data.copy_table(State.list[idx])
   copy.link = nil
   table.insert(State.list, idx + 1, copy)
   Actions.commit()
end

function Actions.delete_entry(idx)
   log:debug("Removing [" .. idx .. "]: " .. tostring(State.list[idx].path))
   table.remove(State.list, idx)
   Actions.commit()
end

-- The k text entries now at list[at .. at+k-1] (without a link) get linked: dropped between two entries of a project's block
-- they join that block; otherwise, with link (Shift), they are linked to the entry the mouse is over (ref, which the drop
-- line is next to): the group of that text entry, or the project on the side of the drop line, through the text entries
-- in between (above the entry they link to: "below", and the other way round).
local function link_inserted(list, at, k, direction, ref, link)
   for _, dir in ipairs({ "above", "below" }) do
      for i = at, at + k - 1 do list[i].link = dir end
      local first, last = Data.block_of(list, at)
      if first and first < at and at + k - 1 < last then return end
   end
   for i = at, at + k - 1 do list[i].link = nil end
   if not link then return end

   if ref and ref.type == ENTRY.TEXT and ref.link then
      for i = at, at + k - 1 do list[i].link = ref.link end
      if Data.block_of(list, at) and Data.block_of(list, at + k - 1) then return end
      for i = at, at + k - 1 do list[i].link = nil end
   end

   local side = direction == -1 and "below" or "above"
   if list[at + k] == ref then side = "below" elseif list[at - 1] == ref then side = "above" end
   local from, to, step = at, at + k - 1, 1
   if side == "below" then from, to, step = at + k - 1, at, -1 end -- nearest to the project first
   for i = from, to, step do
      for _, j in ipairs(Data.link_chain(list, i, side) or {}) do list[j].link = side end
   end
end

-- Several entries at once (entries: entry tables) -----------------------------------------------------------------

function Actions.color_texts(entries, r, g, b)
   for _, e in ipairs(entries) do
      if e.type == ENTRY.TEXT then e.highlight = { r, g, b, 0.4 } end
   end
   Actions.commit()
end

function Actions.unlink_texts(entries)
   for _, e in ipairs(entries) do e.link = nil end
   Actions.commit()
end

-- Removes these entries from the list (text and missing entries; projects are closed with close_projects).
function Actions.delete_entries(entries)
   local gone = {}
   for _, e in ipairs(entries) do gone[e] = true end
   local kept = {}
   for _, e in ipairs(State.list) do
      if not gone[e] then kept[#kept + 1] = e end
   end
   State.list = kept
   Actions.commit()
end

-- A drag and drop of several selected entries (selected: entry tables) to where dropIdx / direction say (see drop_entry).
-- A selected project takes the text entries linked to it along; a selected text entry whose project does not move loses
-- its link. Dropped on one of the moving entries: nothing happens. copy: only the text entries are copied. The tabs follow.
function Actions.drop_selection(selected, dropIdx, direction, copy, link, hoveredIdx)
   local list = State.list
   local sel = {}
   for _, e in ipairs(selected) do sel[e] = true end

   if copy then
      local copies = {}
      for _, e in ipairs(list) do
         if sel[e] and e.type == ENTRY.TEXT then
            local c = Data.copy_table(e)
            c.link = nil
            copies[#copies + 1] = c
         end
      end
      local ref = list[hoveredIdx or dropIdx]
      local at = direction == 1 and dropIdx + 1 or dropIdx
      for i, c in ipairs(copies) do table.insert(list, at + i - 1, c) end
      if #copies > 0 then link_inserted(list, at, #copies, direction, ref, link) end
      Actions.commit()
      return
   end

   local moving, via_block = {}, {}
   for i, e in ipairs(list) do
      if sel[e] then
         moving[e] = true
         if e.type == ENTRY.PROJECT then
            local first, last = Data.link_block(list, i)
            for k = first, last do
               moving[list[k]] = true
               if k ~= i then via_block[list[k]] = true end
            end
         end
      end
   end
   -- dropped on itself: nothing (but a linking drop (Shift) onto an entry that does not move still links)
   if moving[list[dropIdx]] and not (link and hoveredIdx and not moving[list[hoveredIdx]]) then return end

   local only_texts = true
   for e in pairs(moving) do
      if e.type ~= ENTRY.TEXT then only_texts = false break end
   end
   if only_texts then
      -- text entries only: dropped between the entries of a block they join it, with Shift they are linked to the entry
      -- the mouse is over (see link_inserted)
      local ref = list[hoveredIdx or dropIdx]
      local target = direction == 1 and dropIdx + 1 or dropIdx
      local moved, kept, before = {}, {}, 0
      for i, e in ipairs(list) do
         if moving[e] then
            moved[#moved + 1] = e
            e.link = nil
            if i < target then before = before + 1 end
         else
            kept[#kept + 1] = e
         end
      end
      local at = target - before
      for i, e in ipairs(moved) do table.insert(kept, at + i - 1, e) end
      State.list = kept
      link_inserted(kept, at, #moved, direction, ref, link)
      Actions.commit()
      return
   end

   -- outside of the block of the entry it is dropped on
   local bfirst, blast = Data.block_of(list, dropIdx)
   local target = direction == 1 and (blast or dropIdx) + 1 or (bfirst or dropIdx)

   local moved, kept, before = {}, {}, 0
   for i, e in ipairs(list) do
      if moving[e] then
         moved[#moved + 1] = e
         if i < target then before = before + 1 end
         if e.type == ENTRY.TEXT and not via_block[e] then e.link = nil end
      else
         kept[#kept + 1] = e
      end
   end
   local at = target - before
   for i, e in ipairs(moved) do table.insert(kept, at + i - 1, e) end
   State.list = kept

   Actions.commit() -- (the indexes)
   for _, e in ipairs(moved) do
      if e.type == ENTRY.PROJECT then
         Sync.order_tabs(State.list, State.tab_count)
         break
      end
   end
   Actions.commit()
end

-- Projects ------------------------------------------------------------------------------------------------------

-- Closes the tab. The list follows the tabs by itself (see the sync check in Frame).
function Actions.close_project(entry)
   Sync.close_project(entry.proj)
end

-- Closes these tabs (project pointers), except the ones that must not be closed (playing, recording, the last one), and
-- lets the list follow. Returns how many were closed.
function Actions.close_projects(projs)
   local closed = 0
   for _, proj in ipairs(projs) do
      local why = Sync.close_blocker(proj, State.tab_count)
      if why then
         log:warn("not closing a project that %s", why)
      else
         Sync.close_project(proj)
         State.tab_count = Sync.open_count()
         closed = closed + 1
      end
   end
   Actions.follow_tabs()
   return closed
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
-- link: a text entry is linked to the entry the mouse is over (hoveredIdx, the drop line is next to it): the project it is,
-- or the group of the text entry it is, or else the project on the side of the drop line.
function Actions.drop_entry(dragIdx, dropIdx, direction, duplicate, link, hoveredIdx)
   local list = State.list
   local dragEntry = list[dragIdx]

   if dragEntry.type == ENTRY.TEXT and duplicate then
      log:debug("Duplicating Text Item: " .. dragEntry.name)
      local copy = Data.copy_table(dragEntry)
      copy.link = nil
      local ref = list[hoveredIdx or dropIdx]
      local at = direction == 1 and dropIdx + 1 or dropIdx
      table.insert(list, at, copy)
      link_inserted(list, at, 1, direction, ref, link)
      log:debug("Inserted duplicate at idx " .. at)
   elseif dragEntry.type == ENTRY.PROJECT then
      -- A project moves with the text entries linked to it, and never into another project's block.
      local first, last = Data.link_block(list, dragIdx)
      if dropIdx == dragIdx then return end

      if dropIdx >= first and dropIdx <= last then
         -- dropped on one of its own text entries: the project moves past it, and the entries on its other side are
         -- linked the other way round
         local block = {}
         for k = first, last do
            if k ~= dragIdx then block[#block + 1] = list[k] end
         end
         local ref = list[dropIdx]
         local at = 1
         for i, e in ipairs(block) do
            if e == ref then at = direction == 1 and i + 1 or i break end
         end
         table.insert(block, at, dragEntry)
         for i, e in ipairs(block) do
            list[first + i - 1] = e
            if e ~= dragEntry then e.link = (i < at) and "below" or "above" end
         end
      else
         local bfirst, blast = Data.block_of(list, dropIdx)
         local target = direction == 1 and (blast or dropIdx) + 1 or (bfirst or dropIdx)
         local moved = {}
         for k = first, last do moved[#moved + 1] = list[k] end
         for k = last, first, -1 do table.remove(list, k) end
         if target > last then target = target - #moved end
         for i, e in ipairs(moved) do table.insert(list, target + i - 1, e) end

         local newTabIdx = 0 -- the tab goes where the project is now in the list
         for i = 1, target + (dragIdx - first) - 1 do
            if list[i].type == ENTRY.PROJECT then newTabIdx = newTabIdx + 1 end
         end
         Sync.move_tab(dragEntry.proj, newTabIdx, State.tab_count)
      end
   else
      -- Any other entry moves alone: after the entry it was dropped on (dragged down) or before it (dragged up). Dropped
      -- between the entries of a project's block it joins that block, anywhere else it is not linked.
      local ref = list[hoveredIdx or dropIdx] -- the entry the mouse is over
      if dropIdx == dragIdx then
         -- stays where it is; with link (Shift) it is still linked to the entry it was dropped on
         if not (link and dragEntry.type == ENTRY.TEXT and ref ~= dragEntry) then return end
         dragEntry.link = nil
         link_inserted(list, dragIdx, 1, direction, ref, true)
         Actions.commit()
         return
      end
      table.remove(list, dragIdx)
      local target = direction == 1 and dropIdx + 1 or dropIdx
      if dropIdx > dragIdx then target = target - 1 end
      table.insert(list, target, dragEntry)
      link_inserted(list, target, 1, direction, ref, link)
   end

   Actions.commit()
end

-- Replacing the whole list ----------------------------------------------------------------------------------------

-- The name of a project that is playing or recording, or nil. Loading and resetting are refused then.
function Actions.playback_blocker()
   for _, proj in ipairs(Sync.project_pointers()) do
      if reaper.GetPlayStateEx(proj) & 5 ~= 0 then return reaper.GetProjectName(proj) end
   end
   return nil
end

function Actions.reset()
   Data.archive_list(Data.list_to_text(State.list, "\n"))
   State.list = State.read_open_projects()
   State.name, State.saved_text = nil, nil
   Actions.commit()
end

-- Missing entries whose file is there again become project entries (a list that was saved while a project was missing
-- must load that project once it is back). Used when a list is loaded, where projects get opened.
function Actions.revive_missing(list)
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.MISSING and reaper.file_exists(entry.path) then
         log:info("'%s' is available again", entry.path)
         entry.type = ENTRY.PROJECT
      end
   end
end

-- The autosave as entries: list, invalid lines, where it came from. An empty list when there is none.
function Actions.read_autosave()
   local list, invalid, _, source = Data.read_list_file(Data.autosave_path(), "autosave", Sync.find_open_tab)
   Actions.revive_missing(list)
   return list, invalid, source
end

-- Reads a setlist file: the entries and the lines that could not be read, or nil if the file could not be opened.
-- A project is first looked for next to the setlist file (by file name), then at the stored path; entries of projects
-- that are open get their `proj`.
function Actions.read_setlist_file(path)
   local file = io.open(path, "r")
   if not file then return nil end

   local text = ""
   for line in file:lines() do
      line = line:match("^%s*(.-)%s*$") -- trim whitespace
      if line ~= "" then text = text .. line .. "\n" end
   end
   file:close()

   local list, invalid = Data.text_to_list(text, "\n")
   local seen = {}
   for _, entry in ipairs(list) do
      if entry.type ~= ENTRY.TEXT then -- text entries have no file behind them
         entry.path = Data.sanitize_path(Data.find_next_to_setlist(path, entry.path))
         if entry.type == ENTRY.PROJECT then
            local nth = seen[entry.path] or 0
            seen[entry.path] = nth + 1
            entry.proj, entry.tabIdx = Sync.find_open_tab(entry.path, nth)
         end
      end
   end
   Actions.revive_missing(list)
   return list, invalid
end

-- Starts loading what Sync.plan_load planned: the old list is kept as the autosave, the new list is in place at once
-- (entries of projects that are not open yet have no tab), and the projects open one per frame (step_job, called by
-- Frame), so the header can show the progress. name: the setlist's file name for the title, or nil.
function Actions.start_load(plan, name)
   Data.archive_list(Data.list_to_text(State.list, "\n"))

   for _, m in ipairs(plan.diff.matched) do m.entry.proj = m.tab.proj end
   for _, entry in ipairs(plan.missing) do
      log:warn("file not found, the entry is marked as missing: %s", entry.path)
      entry.type = ENTRY.MISSING
      entry.proj = nil
   end

   State.list = plan.list
   local queue = {} -- the steps: open a project, then close a tab
   for _, entry in ipairs(plan.to_open) do queue[#queue + 1] = { open = entry } end
   for _, tab in ipairs(plan.to_close) do queue[#queue + 1] = { close = tab } end
   State.job = { plan = plan, queue = queue, total = #queue, done = 0, name = name, prev = reaper.EnumProjects(-1) }
   Actions.step_job() -- nothing to open: the load is finished right away
end

-- One step of a load: opens the next project or closes the next tab; after the last step puts the tabs in the order of
-- the list and finishes. Does nothing when no load is running.
function Actions.step_job()
   local job = State.job
   if not job then return end

   local step = table.remove(job.queue, 1)
   if step and step.open then
      reaper.Main_OnCommand(Sync.CMD.NEW_PROJ_TAB, 0)
      reaper.Main_openProject(step.open.path)
      step.open.proj = reaper.EnumProjects(-1)
   elseif step and step.close then
      local tab = step.close
      local why = Sync.close_blocker(tab.proj, State.tab_count)
      if why then
         log:warn("kept '%s' open: it %s", tab.name or tab.path, why)
         State.list[#State.list + 1] = tab
      else
         Sync.close_project(tab.proj)
      end
   end
   if step then
      job.done = job.done + 1
      State.tab_count = Sync.open_count()
   end
   if #job.queue > 0 then return end

   Sync.order_tabs(State.list, State.tab_count)
   if job.prev and reaper.ValidatePtr(job.prev, "ReaProject*") then reaper.SelectProjectInstance(job.prev) end

   State.job = nil
   Data.update_indexes(State.list)
   State.name = job.name
   State.saved_text = job.name and Data.list_to_text(State.list, "\n") or nil
   Actions.commit()
end

-- Writes the list to a setlist file; its name becomes the window title. Returns true, or false and the reason.
function Actions.save_to_file(path)
   local text = Data.list_to_text(State.list, "\n")
   local written, err = Data.write_text_atomic(path, text) -- (a failed save never leaves half a file)
   if not written then return false, err end
   State.name = path:match("([^/\\]+)$"):gsub("%.%w+$", "")
   State.saved_text = text
   State.modified = false
   return true
end

return Actions
