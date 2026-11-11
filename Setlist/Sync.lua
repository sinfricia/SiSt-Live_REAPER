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
   -- a tab closed a moment ago leaves a stale pointer in the list until the list has followed the tabs (not while a
   -- dialog is open)
   if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return 0 end
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

-- Matching: an entry belongs to a tab first by the project pointer (entry.proj == tab.proj), then, for what is left, by
-- path in order (the n-th entry of a path with the n-th tab of that path). So a project that was closed and opened again
-- is the same entry, and the same file open twice is simply two entries and two tabs.

--- Cheap check for every frame: do the project entries have exactly the pointers of the open tabs, in tab order?
--- tab_projs: the open projects in tab order (Sync.project_pointers).
function Sync.is_synced(list, tab_projs)
   local n = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         if entry.proj == nil or entry.proj ~= tab_projs[n] then return false end
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
   local result = {}
   for _, e in ipairs(list) do
      if not dropped[e] then result[#result + 1] = e end
   end

   -- the matched entries in tab order, laid into the places of the project entries
   local entry_at = {} -- 0-based tab index -> entry
   for _, m in ipairs(d.matched) do
      m.entry.proj = m.tab.proj
      entry_at[m.tab_idx] = m.entry
   end
   local ordered = {}
   for ti = 0, #tabs - 1 do
      if entry_at[ti] then ordered[#ordered + 1] = entry_at[ti] end
   end
   local n = 0
   for i, e in ipairs(result) do
      if e.type == ENTRY.PROJECT then
         n = n + 1
         result[i] = ordered[n]
      end
   end

   -- the tabs that have no entry, each after the entry of the tab before it
   for _, t in ipairs(d.tab_only) do
      entry_at[t.tab_idx] = t.tab
      local pos = nil
      local before = entry_at[t.tab_idx - 1]
      if before then
         for i, e in ipairs(result) do
            if e == before then pos = i + 1 break end
         end
      else
         for i, e in ipairs(result) do
            if e.type == ENTRY.PROJECT then pos = i break end
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

-- Self test ---------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("is_synced / diff / follow_tabs / duplicates", function(t)
   local ENTRY = Data.ENTRY
   local function proj(path, p) return { type = ENTRY.PROJECT, path = path, proj = p } end
   local function tab(path, p) return { type = ENTRY.PROJECT, path = path, proj = p, name = path } end
   local function text(s) return { type = ENTRY.TEXT, path = s } end
   local function paths(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = e.path end
      return table.concat(out, ",")
   end
   local A, B, C = {}, {}, {}

   -- is_synced
   t.ok(Sync.is_synced({ proj("a", A), text("t"), proj("b", B) }, { A, B }), "is_synced: same pointers, same order, text in between")
   t.ok(not Sync.is_synced({ proj("b", B), proj("a", A) }, { A, B }), "is_synced: different order")
   t.ok(not Sync.is_synced({ proj("a", A) }, { A, B }), "is_synced: tab without entry")
   t.ok(not Sync.is_synced({ proj("a", A), proj("b", B) }, { A }), "is_synced: entry without tab")
   t.ok(not Sync.is_synced({ proj("a", nil) }, { A }), "is_synced: entry without pointer")
   t.ok(Sync.is_synced({ text("t") }, {}), "is_synced: no projects at all")
   t.ok(Sync.is_synced({ { type = ENTRY.MISSING, path = "x" }, proj("a", A) }, { A }), "is_synced: missing entries are not projects")

   -- diff
   local d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("b", B) })
   t.ok(d.in_sync and #d.matched == 2, "diff: equal is in sync")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("b", B), tab("a", A) })
   t.ok(d.order_changed and not d.in_sync and #d.list_only == 0 and #d.tab_only == 0, "diff: only the order differs")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A) })
   t.ok(#d.list_only == 1 and d.list_only[1].path == "b" and #d.tab_only == 0, "diff: tab closed: the entry has no tab")
   d = Sync.diff({ proj("a", A) }, { tab("a", A), tab("c", C) })
   t.ok(#d.tab_only == 1 and d.tab_only[1].tab.path == "c" and d.tab_only[1].tab_idx == 1 and #d.list_only == 0,
      "diff: tab opened: the tab has no entry")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("b", {}) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0 and #d.matched == 2, "diff: same file, new pointer (closed and opened again) is the same entry")
   d = Sync.diff({ proj("C:\\x\\a.rpp", nil) }, { tab("C:/x/a.rpp", A) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0, "diff: paths match whatever the slashes")
   d = Sync.diff({ proj("a", A), proj("a", nil) }, { tab("a", A), tab("a", B) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0 and d.matched[2].tab_idx == 1, "diff: the same file twice is two entries for two tabs")
   d = Sync.diff({ proj("a", A), proj("a", nil) }, { tab("a", A) })
   t.ok(#d.list_only == 1 and #d.tab_only == 0, "diff: the same file twice in the list, once open: one entry has no tab")
   d = Sync.diff({ text("t"), { type = ENTRY.MISSING, path = "gone" } }, { tab("a", A) })
   t.ok(#d.list_only == 0 and #d.tab_only == 1, "diff: text and missing entries are never compared")
   t.ok(Sync.diff({}, {}).in_sync, "diff: nothing and nothing is in sync")

   -- follow_tabs
   local list = { proj("a", A), text("break"), proj("b", B), proj("c", C) }
   local r = Sync.follow_tabs(list, { tab("c", C), tab("a", A), tab("b", B) })
   t.eq(paths(r), "c,break,a,b", "follow_tabs: reorder keeps text in place")
   t.eq(paths(list), "a,break,b,c", "follow_tabs: the input list is not changed")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("a", A) })
   t.eq(paths(r), "a,break", "follow_tabs: entry of a closed tab is removed, text stays")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("a", A), tab("n", C), tab("b", B) })
   t.eq(paths(r), "a,n,break,b", "follow_tabs: a new tab goes after the entry of the tab before it")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("n", C), tab("a", A), tab("b", B) })
   t.eq(paths(r), "n,a,break,b", "follow_tabs: a new first tab goes before the first project")
   r = Sync.follow_tabs({ proj("a", A) }, { tab("a", A), tab("n", B), tab("m", C) })
   t.eq(paths(r), "a,n,m", "follow_tabs: several new tabs keep their tab order")
   r = Sync.follow_tabs({ text("t") }, { tab("n", A) })
   t.eq(paths(r), "t,n", "follow_tabs: a list of only text gets the project after it")
   r = Sync.follow_tabs({}, { tab("a", A), tab("b", B) })
   t.eq(paths(r), "a,b", "follow_tabs: an empty list becomes the tabs")
   local reopened, new_ptr = proj("a", {}), {}
   r = Sync.follow_tabs({ reopened }, { tab("a", new_ptr) })
   t.ok(r[1] == reopened and reopened.proj == new_ptr, "follow_tabs: a reopened project keeps its entry and gets the new pointer")
   r = Sync.follow_tabs({ proj("a", A), proj("b", B) }, { tab("b", B), tab("x", C), tab("a", A) })
   t.eq(paths(r), "b,x,a", "follow_tabs: reorder and new tab together")
   local tabs2 = { tab("b", B), tab("x", C), tab("a", A) }
   r = Sync.follow_tabs({ proj("a", A), text("t"), proj("b", B) }, tabs2)
   t.ok(Sync.is_synced(r, { B, C, A }) and Sync.diff(r, tabs2).in_sync, "follow_tabs: the result is in sync")

   -- duplicates
   local dups = Sync.duplicates({ tab("a", A), tab("b", B), tab("A", C), tab("a", {}) })
   t.ok(#dups == 1 and dups[1].count == 2 and dups[1].tabs[1] == 0 and dups[1].tabs[2] == 3, "duplicates: found by path")
   t.ok(#Sync.duplicates({ tab("C:\\x\\a.rpp", A), tab("C:/x/a.rpp", B) }) == 1, "duplicates: slashes do not matter")
   t.ok(#Sync.duplicates({ tab("Unsaved Project", A), tab("Unsaved Project", B) }) == 0, "duplicates: unsaved projects may be open many times")
   t.ok(#Sync.duplicates({ tab("a", A), tab("b", B) }) == 0, "duplicates: none")

   -- change_summary
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A) }, { tab("a", A) })), nil, "change_summary: nothing changed")
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("c", C) })), "1 new, 1 gone", "change_summary: new and gone")
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A), proj("b", B) }, { tab("b", B), tab("a", A) })), "reordered", "change_summary: reordered")
end)

define("plan_load", function(t)
   local ENTRY = Data.ENTRY
   local function proj(path, p) return { type = ENTRY.PROJECT, path = path, proj = p, name = path } end
   local function text(s) return { type = ENTRY.TEXT, path = s, name = s } end
   local function paths(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = e.path end
      return table.concat(out, ",")
   end
   local A, B, C, D = {}, {}, {}, {}
   local exists = function(path) return path ~= "gone" end

   local loaded = { proj("a", nil), text("L1"), proj("b", nil), proj("gone", nil) }
   local x_entry, y_entry = proj("x", C), proj("y", D)
   local b_entry = proj("b", B)
   local tabs = { b_entry, x_entry, y_entry }
   local note, break_note = text("note"), text("break")
   local current = { x_entry, note, b_entry, break_note, y_entry }

   local plan = Sync.plan_load(loaded, tabs, current, {}, exists)
   t.eq(paths(plan.list), "x,note,break,y,a,L1,b,gone", "everything kept: the kept entries in the order of the current list, then the loaded ones")
   t.eq(paths(plan.to_open), "a", "to_open: the loaded project with no tab and an existing file")
   t.eq(paths(plan.missing), "gone", "missing: no tab and no file")
   t.eq(#plan.to_close, 0, "nothing marked: nothing is closed")

   plan = Sync.plan_load(loaded, tabs, current, { [C] = true, [D] = true, [note] = true, [break_note] = true }, exists)
   t.eq(paths(plan.list), "a,L1,b,gone", "everything marked: only the loaded setlist remains")
   t.eq(paths(plan.to_close), "x,y", "the marked extras are closed, in tab order")

   plan = Sync.plan_load(loaded, tabs, current, { [C] = true, [break_note] = true }, exists)
   t.eq(paths(plan.list), "note,y,a,L1,b,gone", "a mix: x and the break removed, the note and y kept")
   t.eq(paths(plan.to_close), "x", "only x is closed")

   -- identical text entries are replaced by the loaded ones, not kept next to them
   local loaded_with_note = { proj("a", nil), text("note"), proj("b", nil) }
   plan = Sync.plan_load(loaded_with_note, tabs, current, {}, exists)
   t.eq(paths(plan.list), "x,break,y,a,note,b", "an identical text entry is replaced by the loaded one (only one 'note' remains)")
   local ident = Sync.identical_texts(current, loaded_with_note)
   t.ok(ident[note] and not ident[break_note], "identical_texts: found by text")
   local colored = text("note"); colored.highlight = { 1, 0, 0, 0.4 }
   t.ok(not Sync.identical_texts({ colored }, loaded_with_note)[colored], "identical_texts: a different color is not identical")
   local twice = Sync.identical_texts({ text("note"), text("note") }, loaded_with_note)
   local count = 0
   for _ in pairs(twice) do count = count + 1 end
   t.eq(count, 1, "identical_texts: two in the current list, one in the loaded: only one matches")

   -- an empty unsaved tab is closed without being asked about
   local blank = proj("Unsaved Project", {})
   plan = Sync.plan_load(loaded_with_note, { b_entry, blank }, { b_entry, blank }, {}, exists, function(p) return p == blank.proj end)
   t.eq(#plan.to_close, 1, "an empty unsaved tab is closed")
   t.eq(paths(plan.list), "a,note,b", "... and does not stay in the list")

   plan = Sync.plan_load({ proj("b", nil) }, tabs, { b_entry }, {}, exists)
   t.eq(paths(plan.list), "x,y,b", "an extra the current list does not know is added after the kept entries")

   plan = Sync.plan_load({ proj("a", nil) }, {}, {}, {}, exists)
   t.eq(paths(plan.to_open), "a", "nothing open: everything of the setlist is opened")
   plan = Sync.plan_load({}, {}, {}, {}, exists)
   t.eq(#plan.list, 0, "nothing at all: an empty list")
end)

function Sync.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Sync
