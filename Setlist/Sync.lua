-- @noindex
--[[
SiSt-Live Setlist: Sync

Everything about the list and REAPER's project tabs: reading the open tabs, moving, closing and ordering them, and the
pure part that compares the list with the tabs. The list itself and its files are in Data.lua; nothing here keeps state.

  Reading      open_count, open_projects, project_pointers, find_project, find_open_tab, tab_index, project_length,
               total_length
  Changing     move_tab, order_tabs, close_project, close_blocker, is_empty_unsaved
  Loading      plan_load (pure: what loading a setlist does to the list and the tabs)
  Comparing    is_synced, diff, follow_tabs, duplicates (pure). The rule: the project entries of the list and the open
               tabs are the same projects in the same order (text and missing entries sit anywhere in between). While the
               Setlist runs, the tabs are the truth and the list follows them.

Tests: Setlist/Tests/Sync_test.lua.
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
         list_idx = idx + 1, -- position in the list, 1 based
         tab_idx = idx,      -- project tab position, 0 based
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

function Sync.find_project(path, duplicate_number)
   if not duplicate_number then
      duplicate_number = 0
   end
   local idx = 0

   log:debug("Getting project from path")
   log:debug("  Looking for (duplicate) instance " .. duplicate_number)
   while true do
      local proj, proj_path = reaper.EnumProjects(idx)
      if not proj then
         log:debug("    Not found. Project not open.")
         return nil
      end
      if path == proj_path then
         if duplicate_number == 0 then
            log:debug("    Found at tab idx [%d]", idx)
            return proj
         else
            duplicate_number = duplicate_number - 1
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

function Sync.tab_index(target_proj)
   local idx = 0
   while true do
      local proj = reaper.EnumProjects(idx)
      if not proj then return end
      if proj == target_proj then
         return idx
      end
      idx = idx + 1
   end
end

function Sync.project_length(proj) -- used because reaper.GetProjectLength was unreliable...
   -- a tab closed a moment ago leaves a stale pointer in the list until the list has followed the tabs (not while a
   -- dialog is open)
   if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return 0 end
   local marker_count = reaper.CountProjectMarkers(proj)

   for i = marker_count - 1, 0, -1 do
      local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers2(proj, i)
      if retval and not isrgn then
         return pos
      end
   end

   return 0
end

-- All open project tabs, in tab order.
function Sync.project_pointers()
   local ptrs, paths = {}, {}
   while true do
      local proj, path = reaper.EnumProjects(#ptrs)
      if not proj then break end
      ptrs[#ptrs + 1] = proj
      paths[#ptrs] = path
   end
   return ptrs, paths -- (the file paths of the tabs too, "" for an unsaved project)
end

--- True for a tab that is nothing yet: not saved to a file, no tracks, no unsaved changes (the blank tab REAPER starts
--- with, or a new tab). The Setlist may close such a tab by itself.
function Sync.is_empty_unsaved(proj)
   if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return false end
   local idx = Sync.tab_index(proj)
   if not idx then return false end
   local _, path = reaper.EnumProjects(idx)
   if path ~= "" then return false end
   return reaper.CountTracks(proj) == 0 and reaper.IsProjectDirty(proj) == 0
end

--- Why a tab must not be closed ("is the last open project", "is recording", "is playing"), or nil if it may be.
--- tab_count: the number of open tabs.
function Sync.close_blocker(proj, tab_count)
   if tab_count <= 1 then return "is the last open project" end
   local state = reaper.GetPlayStateEx(proj)
   if state & 4 ~= 0 then return "is recording" end
   if state & 1 ~= 0 then return "is playing" end
   return nil
end

-- Changing the tabs --------------------------------------------------------------------------------

--- Moves the tab of a project to tab position target_idx (0-based, at most tab_count) with REAPER's "move tab" action.
function Sync.move_tab(target_proj, target_idx, tab_count)
   if not target_proj then return end

   local start_idx = Sync.tab_index(target_proj)
   if not target_idx or not start_idx then return end

   target_idx = math.max(0, math.min(tab_count, target_idx))

   log:debug("Starting move for '" ..
      reaper.GetProjectName(target_proj) .. "' from tab_idx [" .. start_idx .. "] to [" .. target_idx .. "]")

   local move_direction = 0

   if target_idx > start_idx then
      move_direction = 1  -- Move right (down with drag&drop)
   elseif target_idx < start_idx then
      move_direction = -1 -- Move left (down with drag&drop)
   else
      log:debug("Aborted move: target_idx == start_idx")
      return -- No movement
   end

   log:debug("  move_direction: " .. move_direction)

   local tab_move_cmd_id = { [-1] = CMD.TAB_MOVE_LEFT, [1] = CMD.TAB_MOVE_RIGHT }

   log:debug("  Number of move commands: " .. (target_idx - start_idx) * move_direction)
   for i = 1, (target_idx - start_idx) * move_direction do
      log:debug("    Move " .. i)

      reaper.Main_OnCommandEx(tab_move_cmd_id[move_direction], 0, target_proj) --Project tabs: Move project tab left/right by one
   end
end

--- Puts the tabs in the order of the list's project entries (and sets their tab_idx).
function Sync.order_tabs(list, tab_count)
   log:debug("Starting project tab sort...")

   for i, entry in ipairs(Data.project_entries(list)) do
      Sync.move_tab(entry.proj, i - 1, tab_count)
      entry.tab_idx = i - 1
   end
end

function Sync.close_project(proj)
   local prev_proj = reaper.EnumProjects(-1) -- remember which tab was active
   reaper.SelectProjectInstance(proj)
   reaper.Main_OnCommand(CMD.CLOSE_PROJ_TAB, 0)
   if prev_proj ~= proj and reaper.ValidatePtr(prev_proj, "ReaProject*") then
      reaper.SelectProjectInstance(prev_proj) -- go back to the tab the user was on
   end
end

-- Comparing the list with the tabs ----------------------------------------------------------------

-- Matching: an entry belongs to a tab first by the project pointer (entry.proj == tab.proj), then, for what is left, by
-- path in order (the n-th entry of a path with the n-th tab of that path). So a project that was closed and opened again
-- is the same entry, and the same file open twice is simply two entries and two tabs.

--- Cheap check for every frame: do the project entries have exactly the pointers of the open tabs, in tab order?
--- tab_projs: the open projects in tab order (Sync.project_pointers). tab_paths (its second result, optional): their file
--- paths, so a file opened into a tab (File > Open keeps the pointer) is noticed too.
local normalized = {} -- (every frame: the same strings again and again)
local function same_file(entry_path, tab_path)
   if tab_path == "" then return entry_path == "Unsaved Project" end
   if entry_path == tab_path then return true end
   normalized[entry_path] = normalized[entry_path] or Data.normalize_path(entry_path)
   normalized[tab_path] = normalized[tab_path] or Data.normalize_path(tab_path)
   return normalized[entry_path] == normalized[tab_path]
end

function Sync.is_synced(list, tab_projs, tab_paths)
   local n = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         if entry.proj == nil or entry.proj ~= tab_projs[n] then return false end
         if tab_paths and not same_file(entry.path or "", tab_paths[n] or "") then return false end
      end
   end
   return n == #tab_projs
end

--- Compares the project entries with the tabs (tabs: Sync.open_projects()). Returns:
---   list_only      entries without a tab (list order)
---   tab_only       tabs without an entry: { tab = <tab entry>, tab_idx = <0-based tab index> } (tab order)
---   matched        { entry = <entry>, tab = <tab entry>, tab_idx = <0-based> } for every entry that has a tab (list order)
---   order_changed  the matched entries are not in tab order
---   in_sync        nothing in list_only / tab_only and the order is right
function Sync.diff(list, tabs)
   local d = { list_only = {}, tab_only = {}, matched = {}, order_changed = false }
   local entries = Data.project_entries(list)
   local tab_of = {}  -- entry -> tab number (1-based)
   local taken = {}   -- tab number -> true

   local by_proj = {}
   for ti, tab in ipairs(tabs) do
      if tab.proj ~= nil then by_proj[tab.proj] = ti end
   end
   for _, e in ipairs(entries) do
      local ti = e.proj ~= nil and by_proj[e.proj] or nil
      if ti and not taken[ti] then
         tab_of[e] = ti
         taken[ti] = true
      end
   end

   local tab_paths = nil -- normalized only when needed (the usual case needs no strings)
   for _, e in ipairs(entries) do
      if not tab_of[e] then
         if not tab_paths then
            tab_paths = {}
            for ti, tab in ipairs(tabs) do tab_paths[ti] = Data.normalize_path(tab.path) end
         end
         local want = Data.normalize_path(e.path)
         for ti = 1, #tabs do
            if not taken[ti] and tab_paths[ti] == want then
               tab_of[e] = ti
               taken[ti] = true
               break
            end
         end
      end
   end

   local last = 0
   for _, e in ipairs(entries) do
      local ti = tab_of[e]
      if ti then
         d.matched[#d.matched + 1] = { entry = e, tab = tabs[ti], tab_idx = ti - 1 }
         if ti < last then d.order_changed = true end
         last = ti
      else
         d.list_only[#d.list_only + 1] = e
      end
   end
   for ti, tab in ipairs(tabs) do
      if not taken[ti] then d.tab_only[#d.tab_only + 1] = { tab = tab, tab_idx = ti - 1 } end
   end

   d.in_sync = #d.list_only == 0 and #d.tab_only == 0 and not d.order_changed
   return d
end

--- The list made to follow the tabs: a NEW list in which
---   - entries without a tab are gone,
---   - the project entries follow the tab order (text and missing entries keep their positions),
---   - every tab without an entry is added right after the entry of the tab before it (before the first project entry
---     if it is the first tab).
--- Matched entries get their current pointer (entry.proj = tab.proj), so a project that was closed and opened again keeps
--- its entry. d: Sync.diff(list, tabs), computed when not given.
function Sync.follow_tabs(list, tabs, d)
   d = d or Sync.diff(list, tabs)

   local dropped = {}
   for _, e in ipairs(d.list_only) do dropped[e] = true end
   -- the text entries linked to a project that is gone lose their link (they stay, as free text entries)
   for i, e in ipairs(list) do
      if dropped[e] then
         local first, last = Data.link_block(list, i)
         for k = first, last do
            if k ~= i then list[k].link = nil end
         end
      end
   end
   local result = {}
   for _, e in ipairs(list) do
      if not dropped[e] then result[#result + 1] = e end
   end

   -- the matched entries in tab order, laid into the places of the project entries
   local entry_at = {} -- 0-based tab index -> entry
   for _, m in ipairs(d.matched) do
      m.entry.proj = m.tab.proj
      if not same_file(m.entry.path or "", m.tab.path == "Unsaved Project" and "" or m.tab.path or "") then
         m.entry.path, m.entry.name = m.tab.path, m.tab.name -- (another file was opened into the tab, or it was saved)
      end
      entry_at[m.tab_idx] = m.entry
   end
   local ordered = {}
   for ti = 0, #tabs - 1 do
      if entry_at[ti] then ordered[#ordered + 1] = entry_at[ti] end
   end
   -- A project moves with the text entries linked to it (its block): the blocks are laid into the places of the
   -- project entries, everything else keeps its place.
   local blocks, attached = {}, {}
   for i, e in ipairs(result) do
      if e.type == ENTRY.PROJECT then
         local first, last = Data.link_block(result, i)
         local block = {}
         for k = first, last do
            block[#block + 1] = result[k]
            if k ~= i then attached[result[k]] = true end
         end
         blocks[e] = block
      end
   end
   local flat, n = {}, 0
   for _, e in ipairs(result) do
      if e.type == ENTRY.PROJECT then
         n = n + 1
         for _, member in ipairs(blocks[ordered[n]] or { ordered[n] }) do flat[#flat + 1] = member end
      elseif not attached[e] then
         flat[#flat + 1] = e
      end
   end
   result = flat

   -- the tabs that have no entry, each after the block of the tab before it
   for _, t in ipairs(d.tab_only) do
      entry_at[t.tab_idx] = t.tab
      local pos = nil
      local before = entry_at[t.tab_idx - 1]
      if before then
         for i, e in ipairs(result) do
            if e == before then
               local _, last = Data.link_block(result, i)
               pos = last + 1
               break
            end
         end
      else
         for i, e in ipairs(result) do
            if e.type == ENTRY.PROJECT then
               pos = Data.link_block(result, i)
               break
            end
         end
      end
      table.insert(result, pos or (#result + 1), t.tab)
   end

   return result
end

--- The text entries of `current` that the loaded setlist has too (same text and color; the n-th identical one of the
--- current list matches the n-th of the loaded one). They are replaced by the loaded ones, so there is nothing to decide
--- about them. Returns a set keyed by the current list's text entry.
function Sync.identical_texts(current, loaded)
   local function key(e) return (e.name or "") .. "|" .. table.concat(e.highlight or {}, ",") end
   local available = {}
   for _, e in ipairs(loaded) do
      if e.type == ENTRY.TEXT then
         local k = key(e)
         available[k] = (available[k] or 0) + 1
      end
   end
   local identical = {}
   for _, e in ipairs(current) do
      if e.type == ENTRY.TEXT then
         local k = key(e)
         if (available[k] or 0) > 0 then
            available[k] = available[k] - 1
            identical[e] = true
         end
      end
   end
   return identical
end

--- What loading a setlist does. Pure: nothing is changed, Actions.start_load applies the result.
---   loaded   the entries of the setlist that is loaded (project, text, missing entries)
---   tabs     the open tabs, Sync.open_projects()
---   current  the current list. Its text entries and the open projects that are not in `loaded` (the "extras") are what
---            the user decides about, except the text entries that `loaded` has too (identical_texts): those are replaced.
---            The rest of the current list is replaced.
---   remove   what the user marked for removal: a set keyed by the extra's project pointer, or by the current list's
---            text entry (the entry table itself). Everything else of the extras and the text entries is kept.
---   file_exists(path) -> bool, to tell the projects that can be opened from the ones whose file is gone
---   is_empty(proj) -> bool, optional: the extras it is true for (empty unsaved tabs) are closed without asking
--- Returns { list, to_open, missing, to_close, diff }:
---   list      the new list: the kept entries of the current list (in their order), then the loaded entries
---   to_open   loaded project entries without an open tab whose file exists
---   missing   loaded project entries without an open tab and without a file
---   to_close  the tab entries of the extras marked for removal
---   diff      Sync.diff(loaded, tabs)
function Sync.plan_load(loaded, tabs, current, remove, file_exists, is_empty)
   local d = Sync.diff(loaded, tabs)
   local plan = { diff = d, to_open = {}, missing = {}, to_close = {}, list = {} }

   local marked = remove
   remove = {} -- (a copy: empty tabs are added below, the caller's table stays as it was)
   for k, v in pairs(marked) do remove[k] = v end

   local extra_by_proj = {}
   for _, t in ipairs(d.tab_only) do
      extra_by_proj[t.tab.proj] = t.tab
      if is_empty and is_empty(t.tab.proj) then remove[t.tab.proj] = true end -- an empty tab is not worth a question
      if remove[t.tab.proj] then plan.to_close[#plan.to_close + 1] = t.tab end
   end

   local identical = Sync.identical_texts(current, loaded)
   local placed = {}
   for _, e in ipairs(current) do
      if e.type == ENTRY.TEXT then
         if not remove[e] and not identical[e] then plan.list[#plan.list + 1] = e end
      elseif e.type == ENTRY.PROJECT and e.proj and extra_by_proj[e.proj] then
         placed[e.proj] = true
         if not remove[e.proj] then plan.list[#plan.list + 1] = e end
      end
   end
   for _, t in ipairs(d.tab_only) do -- extras that the current list does not know yet
      if not placed[t.tab.proj] and not remove[t.tab.proj] then plan.list[#plan.list + 1] = t.tab end
   end

   -- a kept text entry keeps its link only while the project it is linked to is kept too (a copy without the link
   -- otherwise: the plan changes nothing in the current list)
   local kept = {}
   for _, e in ipairs(plan.list) do kept[e] = true end
   local anchor_of = {}
   for i, e in ipairs(current) do
      if e.type == ENTRY.TEXT and e.link then
         local _, _, anchor = Data.block_of(current, i)
         anchor_of[e] = anchor and current[anchor] or nil
      end
   end
   for i, e in ipairs(plan.list) do
      if e.type == ENTRY.TEXT and e.link and not (anchor_of[e] and kept[anchor_of[e]]) then
         local copy = {}
         for k, v in pairs(e) do copy[k] = v end
         copy.link = nil
         plan.list[i] = copy
      end
   end

   for _, e in ipairs(loaded) do plan.list[#plan.list + 1] = e end

   for _, e in ipairs(d.list_only) do
      if file_exists(e.path) then
         plan.to_open[#plan.to_open + 1] = e
      else
         plan.missing[#plan.missing + 1] = e
      end
   end
   return plan
end

--- A short description of what a diff found, for the notice after a restart: "2 new, 1 gone, reordered". nil if nothing.
function Sync.change_summary(d)
   local parts = {}
   if #d.tab_only > 0 then parts[#parts + 1] = #d.tab_only .. " new" end
   if #d.list_only > 0 then parts[#parts + 1] = #d.list_only .. " gone" end
   if d.order_changed then parts[#parts + 1] = "reordered" end
   if #parts == 0 then return nil end
   return table.concat(parts, ", ")
end

--- Files that are open in more than one tab: a list of { path, count, tabs = {0-based tab indexes} }, in order of first
--- appearance. Unsaved projects (no path) never count.
function Sync.duplicates(tabs)
   local groups, order = {}, {}
   for ti, tab in ipairs(tabs) do
      local path = tab.path
      if path and path ~= "" and path ~= "Unsaved Project" then
         local key = Data.normalize_path(path)
         local g = groups[key]
         if not g then
            g = { path = path, count = 0, tabs = {} }
            groups[key] = g
            order[#order + 1] = g
         end
         g.count = g.count + 1
         g.tabs[#g.tabs + 1] = ti - 1
      end
   end
   local out = {}
   for _, g in ipairs(order) do
      if g.count > 1 then out[#out + 1] = g end
   end
   return out
end

return Sync
