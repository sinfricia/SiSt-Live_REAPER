-- @noindex
--[[
SiSt-Live Setlist: LoadDialog

Loading a setlist replaces the current list. The dialog shows the current list and lets the user mark what to keep: the
open projects that are not in the loaded setlist (otherwise they are closed) and the text entries (otherwise they are
removed). The projects that are in the loaded setlist stay open, and the text entries it has too are replaced by its own:
both are shown for context only, so a text entry can be found next to its project. Nothing is kept by default; the checkbox in the header row sets everything, and a swipe over
several checkboxes sets them all alike. Without anything to decide the setlist loads right away. The old list is kept as
the autosave (Restore brings it back).

  open(loaded, name)    loaded: the entries of the setlist, name: its file name for the title (or nil, for the autosave)
]]

local Dialog, Widgets = require("Gui.Dialog"), require("Gui.Widgets")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")

local gui = ViewState.gui
local ENTRY = Data.ENTRY

local LoadDialog = {}

local function file_exists(path) return reaper.file_exists(path) end

function LoadDialog.open(loaded, name)
   local tabs = Sync.open_projects()
   local extra = {} -- project pointer -> true, for the open projects that are not in the loaded setlist
   local extras = {} -- the open projects that are not in the loaded setlist (empty unsaved tabs are closed without asking)
   for _, t in ipairs(Sync.diff(loaded, tabs).tab_only) do
      if not Sync.is_empty_unsaved(t.tab.proj) then
         extras[#extras + 1] = t
         extra[t.tab.proj] = true
      end
   end
   local identical = Sync.identical_texts(State.list, loaded) -- text entries the loaded setlist has too

   -- the current list in its order: text entries and extras to decide about, the other projects for context
   local items, rows, listed = {}, {}, {}
   local function add_item(key, text, kind)
      local item = { key = key, row = { text = text, kind = kind, checked = false } }
      items[#items + 1] = item
      rows[#rows + 1] = item.row
   end
   for _, entry in ipairs(State.list) do
      if entry.type == ENTRY.TEXT then
         if identical[entry] then
            rows[#rows + 1] = { text = entry.name, style = "muted", kind = "Text Entry", note = "In Setlist", indent = true }
         else
            add_item(entry, entry.name, "Text Entry")
         end
      elseif entry.type == ENTRY.PROJECT then
         if entry.proj and extra[entry.proj] then
            listed[entry.proj] = true
            add_item(entry.proj, entry.name, "Project")
         elseif not Sync.is_empty_unsaved(entry.proj) then
            rows[#rows + 1] = { text = entry.name, style = "muted", kind = "Project", note = "In Setlist", indent = true }
         end
      end
   end
   for _, t in ipairs(extras) do -- extras that the current list does not know yet
      if not listed[t.tab.proj] then add_item(t.tab.proj, t.tab.name, "Project") end
   end

   if #items == 0 then
      Actions.start_load(Sync.plan_load(loaded, tabs, State.list, {}, file_exists, Sync.is_empty_unsaved), name)
      gui.followPending = true
      return
   end

   -- the header row: its checkbox sets every row (true: all kept, false: none, a dash: some)
   local header = { header = true, text = "Current List", kind = "Type", checked = false, note = "Mark What to Keep" }
   header.on_toggle = function()
      local keep = header.checked ~= true
      for _, item in ipairs(items) do item.row.checked = keep end
   end
   table.insert(rows, 1, header)

   local spec = {
      title = name and ("Load Setlist: " .. name) or "Restore the Autosave",
      row = true,
      buttons = { { id = "load", label = "Load Setlist", primary = true }, { id = "cancel", label = "Cancel" } },
   }
   local list_state = {}

   State.dialog = {
      draw = function(w)
         local lay = Dialog.frame(spec, { fill = true, max_w = 760 })
         local c = lay.content
         local kept = 0
         for _, item in ipairs(items) do
            local keep = item.row.checked
            if keep then kept = kept + 1 end
            item.row.note = keep and "Keep" or "Remove"
            item.row.note_style = keep and "ok" or "error"
            item.row.bg = keep and "ok" or "error"
         end
         if kept == #items then header.checked = true
         elseif kept == 0 then header.checked = false
         else header.checked = "mixed" end
         Widgets.list_view(w, list_state, rows, c.x, c.y, c.w, c.h)
         return Dialog.buttons(w, spec, lay)
      end,
      on_choice = function(id)
         State.dialog = nil
         if id ~= "load" then return end
         local remove = {}
         for _, item in ipairs(items) do
            if not item.row.checked then remove[item.key] = true end
         end
         Actions.start_load(Sync.plan_load(loaded, Sync.open_projects(), State.list, remove, file_exists,
            Sync.is_empty_unsaved), name)
         gui.followPending = true
      end,
   }
end

return LoadDialog
