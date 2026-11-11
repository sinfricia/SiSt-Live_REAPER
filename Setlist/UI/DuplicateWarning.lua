-- @noindex
--[[
SiSt-Live Setlist: DuplicateWarning

A project open in more than one tab is almost never wanted, so the Setlist asks: keep them, or close the extra tabs.
"Keep" is remembered for those tabs (their project pointers) for as long as at least two of them stay open. A tab of the
same file that joins them asks again. When the duplicates are gone and the file is opened twice again it asks again too.
A second instance is allowed, it just isn't a regular case.

  check()     called every frame while no question is open; asks (State.dialog) when there is a new duplicate
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Dialog = require("Gui.Dialog")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")

local DuplicateWarning = {}

-- Duplicates the user chose to keep: a list of sets { [proj] = true }, each with at least two tabs. Kept in REAPER's
-- non-persistent ExtState as well (the pointers as text), so closing and reopening the Setlist does not ask again.
local kept = nil
local checked_count = nil -- the number of tabs the check last ran for

local EXT_SECTION, EXT_KEY = "SiSt-Live_Setlist", "KeptDuplicates"

local function save_kept()
   local sets = {}
   for _, set in ipairs(kept) do
      local ptrs = {}
      for proj in pairs(set) do ptrs[#ptrs + 1] = tostring(proj) end
      sets[#sets + 1] = table.concat(ptrs, ",")
   end
   reaper.SetExtState(EXT_SECTION, EXT_KEY, table.concat(sets, ";"), false)
end

-- The kept sets from the ExtState; tabs: Sync.open_projects() (to turn the pointer texts back into pointers).
local function load_kept(tabs)
   local by_text = {}
   for _, tab in ipairs(tabs) do by_text[tostring(tab.proj)] = tab.proj end
   kept = {}
   for group in reaper.GetExtState(EXT_SECTION, EXT_KEY):gmatch("[^;]+") do
      local set = {}
      for ptr in group:gmatch("[^,]+") do
         if by_text[ptr] then set[by_text[ptr]] = true end
      end
      kept[#kept + 1] = set
   end
end

-- The projects of a duplicate group (Sync.duplicates), as a set.
local function proj_set(group, tabs)
   local set = {}
   for _, idx in ipairs(group.tabs) do set[tabs[idx + 1].proj] = true end
   return set
end

-- How many projects of the group are in the kept set.
local function shared(set, kept_set)
   local n = 0
   for p in pairs(set) do if kept_set[p] then n = n + 1 end end
   return n
end

local function count(set)
   local n = 0
   for _ in pairs(set) do n = n + 1 end
   return n
end

function DuplicateWarning.check()
   if State.tab_count == checked_count then return end
   checked_count = State.tab_count

   local tabs = Sync.open_projects()
   local groups = Sync.duplicates(tabs)
   if not kept then load_kept(tabs) end

   -- a kept set shrinks to the tabs that are still open and is forgotten when fewer than two are left; a group is
   -- known when all its tabs are in a kept set (a new tab of the same file makes it a new group to ask about)
   local open = {}
   for _, tab in ipairs(tabs) do open[tab.proj] = true end
   local still = {}
   for _, k in ipairs(kept) do
      local set = {}
      for p in pairs(k) do if open[p] then set[p] = true end end
      if shared(set, set) >= 2 then still[#still + 1] = set end
   end
   kept = still
   save_kept()

   local fresh = {}
   for _, g in ipairs(groups) do
      local set, known = proj_set(g, tabs), false
      for _, k in ipairs(kept) do
         if shared(set, k) == count(set) then known = true break end
      end
      if not known then fresh[#fresh + 1] = g end
   end
   if #fresh == 0 then return end

   local body = { "These projects are open in more than one tab:", "" }
   for _, g in ipairs(fresh) do
      body[#body + 1] = { text = string.format("%s  (%d tabs)", Data.project_name(g.path), g.count), style = "muted" }
   end
   log:info("%d project(s) open more than once", #fresh)

   local spec = {
      title = "Warning: Project Open More Than Once",
      accent = "error",
      row = true,
      button_w = 190,
      body = body,
      buttons = {
         { id = "keep", label = "Keep Them Open", primary = true },
         { id = "close", label = "Close the Extra Tabs" },
      },
   }
   State.dialog = {
      draw = function(win) return Dialog.draw(win, spec) end,
      on_choice = function(id)
         State.dialog = nil
         if id == "keep" then
            for _, g in ipairs(fresh) do kept[#kept + 1] = proj_set(g, tabs) end
            save_kept()
            return
         end
         local extra = {}
         for _, g in ipairs(fresh) do
            for n = 2, #g.tabs do extra[#extra + 1] = tabs[g.tabs[n] + 1].proj end
         end
         Actions.close_projects(extra)
      end,
   }
end

return DuplicateWarning
