-- @noindex
--[[
SiSt-Live Setlist: CommandArea

The buttons below the list, in sections with a centered name and a divider after each (List: Save, Load, Reset, Restore;
Insert: Text Entry; Zoom: percent = reset, + above -). Each button asks what needs asking (UI/Ask.lua) and then calls an
action (Actions.lua). The layout is fixed for now: no adapting to the window width.

  draw()      draws the area and runs the action of a clicked button; called once per frame by Frame
]]

local Widgets, Theme = require("Gui.Widgets"), require("Gui.Theme")
local Data = require("Setlist.Data")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")
local ListInput = require("Setlist.UI.ListInput")
local Ask = require("Setlist.UI.Ask")
local LoadDialog = require("Setlist.UI.LoadDialog")

local gui, CFG = ViewState.gui, ViewState.CFG

local CommandArea = {}

local SETLIST_FILTER = "ReaSetlist (.rsl)\0*.rsl;*.RSL\0Reaper Project List (.rpl)\0*.rpl;*.RPL\0\0"

-- Commands ------------------------------------------------------------------------------------------------------

local function save()
   local path = Ask.save_file("Save Setlist", "setlist.rsl")
   if not path then return end
   local ok = Actions.save_to_file(path)
   if ok then
      reaper.MB("Setlist saved to\n" .. path, "Save Setlist to File", 0)
   else
      reaper.MB("Failed to open file for writing:\n" .. path, "Save Setlist to File", 0)
   end
   return ok
end

-- Loading, restoring and resetting replace the whole list: not while a project plays or records.
local function refuse_while_playing()
   if not Actions.playback_blocker() then return false end
   reaper.MB("Playback or recording is still running.\n\nStop the transport in all projects first, then try again.",
      "Transport Is Running", 0)
   return true
end

local function load()
   if refuse_while_playing() then return false end
   local path = Ask.open_file("Open Setlist", SETLIST_FILTER)
   if not path then return false end
   local loaded, invalid = Actions.read_setlist_file(path)
   if not loaded then
      reaper.MB("Failed to open file:\n" .. path, "Load Setlist from File", 0)
      return false
   end
   Ask.invalid_entries(loaded, invalid, "from " .. path)
   if not next(loaded) then return false end
   LoadDialog.open(loaded, (path:match("([^/\\]+)$"):gsub("%.%w+$", "")))
   return true
end

local function reset()
   if refuse_while_playing() then return false end
   local open = State.read_open_projects()
   if not Ask.confirm("Reset the setlist?\n\nYour current list (" .. Data.describe_list(State.list) ..
          ") is replaced by the " .. #open .. " open projects.\nYou can bring it back with Restore.", "Reset Setlist") then
      return false
   end
   Actions.reset()
   gui.followPending = true
   return true
end

local function restore()
   if refuse_while_playing() then return false end
   local list, invalid, source = Actions.read_autosave()
   if not next(list) then
      reaper.MB("There is no autosave to load.", "Restore", 0)
      return false
   end
   Ask.invalid_entries(list, invalid, "from the " .. source)
   if not next(list) then return false end
   LoadDialog.open(list, nil)
   return true
end

local function insert_text()
   -- the new entry goes after the active project and its row turns into a text field right away
   local entry = Actions.insert_text("New Text")
   gui.followPending = true
   ListInput.start_edit(entry, true)
end

local function run(id)
   local did -- the list commands report whether they went through (a refusal leaves the notice in place)
   if id == "restore" then
      did = restore()
   elseif id == "reset" then
      did = reset()
   elseif id == "save" then
      did = save()
   elseif id == "load" then
      did = load()
   elseif id == "text" then
      insert_text()
   elseif id == "zoom_out" then
      List.zoom_step(-1)
   elseif id == "zoom_in" then
      List.zoom_step(1)
   elseif id == "zoom_reset" then
      List.apply_zoom(0)
   end
   if did then State.notice, State.notice_restorable = nil, false end
end

-- Layout --------------------------------------------------------------------------------------------------------

local function zoom_percent_label()
   return math.floor(gui.entryTextSize / CFG.entryTextSize * 100 + 0.5) .. "%"
end

-- half = 1 / 2: the item is the upper / lower half of a stacked pair (same column, half the height each)
local function groups()
   return {
      {
         title = "List",
         items = {
            { id = "save",  label = "Save",  tip = "Save the setlist to a file." },
            { id = "load",  label = "Load",  tip = "Load a setlist from a file." },
            { id = "reset", label = "Reset", tip = "Replace the list with the open projects." },
            {
               id = "restore",
               label = "Restore",
               disabled = not Data.has_autosave(),
               tip =
               "Bring back the list that was replaced last.\nThe current list takes its place, so a second Restore goes back."
            },
         }
      },
      {
         title = "Insert",
         items = {
            { id = "text", label = "Text Entry", tip = "Insert text entry after current project." },
         }
      },
      {
         title = "Zoom",
         align = "right",
         items = {
            { id = "zoom_reset", label = zoom_percent_label(), w = 68, tip = "Reset Zoom." },
            { id = "zoom_in",    label = "+",                  w = 34, half = 1,           repeat_every = gui.zoomDelay, tip = "Zoom in." },
            { id = "zoom_out",   label = "-",                  w = 34, half = 2,           repeat_every = gui.zoomDelay, tip = "Zoom out." },
         }
      },
   }
end

-- Proportions: one rhythm for everything. Margin 12, buttons 8 apart, sections 28 apart with the divider in the middle,
-- buttons of a group equally wide, 12 px above the section names and below the buttons. Fixed: no adapting to the
-- window width yet.
function CommandArea.draw()
   local margin, gap, groupGap = 12, 8, 28
   local top = gfx.h - gui.ctrlPanelSize + gui.statusH + gui.cmdPad
   local y = top + gui.headingH
   local h = gui.buttonH
   Theme.set_font(gui.buttonFontSize)

   local sections = groups()
   -- natural text widths; buttons without a fixed width get the widest one of their group
   for _, g in ipairs(sections) do
      g.textW = 0
      for _, it in ipairs(g.items) do
         if not it.w then g.textW = math.max(g.textW, gfx.measurestr(it.label)) end
      end
   end
   local pad = 11 -- space left and right of the text inside a button
   for _, g in ipairs(sections) do
      g.w = 0
      local first = true
      for _, it in ipairs(g.items) do
         it.bw = it.w or math.floor(g.textW + pad * 2)
         if it.half ~= 2 then -- the lower half shares the column of the upper one
            g.w = g.w + it.bw + (first and 0 or gap)
            first = false
         end
      end
   end

   local x = margin
   for gi, g in ipairs(sections) do
      local gx = g.align == "right" and (gfx.w - margin - g.w) or x
      Widgets.text(g.title, gx, top, g.w, gui.headingH - 4, { size = 15, color = "muted", align = "center" })
      local bx = gx
      for _, it in ipairs(g.items) do
         local opts = {
            size = gui.buttonFontSize,
            disabled = it.disabled,
            repeat_every = it.repeat_every,
            tooltip = it
                .tip
         }
         local by, bh = y, h
         if it.half then
            opts.size = gui.buttonFontSize * 0.9
            bh = math.floor((h - 2) / 2)
            if it.half == 2 then by = y + bh + 2 end
            bx = it.half == 2 and (bx - it.bw - gap) or bx -- the lower half goes under the upper one
         end
         if Widgets.button(State.win, it.label, bx, by, it.bw, bh, opts) then run(it.id) end
         bx = bx + it.bw + gap
      end
      if g.align ~= "right" then
         x = gx + g.w + groupGap
         if gi < #sections then
            -- divider at the end of the section, in the middle of the gap
            Theme.set("line")
            gfx.rect(gx + g.w + groupGap / 2, top, 1, gui.headingH + h)
         end
      end
   end
end

-- The left part of the status line: the chip with the number of missing entries (a click scrolls to the first one) and
-- the notice (State.notice; a click on it restores the previous list). The right part holds the counts and the time.
function CommandArea.draw_status()
   local x = 0 -- (where the next chip goes: flush with the left edge)
   Theme.set_font(15)

   local missing, first = Data.missing_entries(State.list)
   if missing > 0 then
      -- flush with the left edge of the window and the full height of the status line, red like a missing entry in the list
      local label = missing .. " Missing"
      local w = gfx.measurestr(label) + 24
      local cy, ch = gfx.h - gui.ctrlPanelSize + 1, gui.statusH - 1
      local over, _, clicked = Widgets.button_state(State.win.mouse, 0, cy, w, ch)
      local red = gui.entryHighlights[Data.ENTRY.MISSING]
      Widgets.box(0, cy, w, ch, red, over and 0.85 or red[4])
      Widgets.text(label, 0, cy, w, ch, { size = 15, align = "center" })
      if clicked then
         gui.scrollOffset = math.max(0, math.min(gui.maxScroll, (List.layout(State.list))[first] or 0))
         gui.followPending = false
      end
      x = w + 6
   end

   if State.notice then
      -- a chip like the missing one, in the accent colour; a click restores the previous list (when it was kept) or
      -- dismisses the notice. A refused restore (something plays) keeps it.
      local room = gfx.w - 200 - x -- the right part holds the counts and the time
      if room < 80 then return end
      local cy, ch = gfx.h - gui.ctrlPanelSize + 1, gui.statusH - 1
      local text = Widgets.fit_text(State.notice, room - 24, function(s) return (gfx.measurestr(s)) end)
      local w = gfx.measurestr(text) + 24
      local over, _, clicked = Widgets.button_state(State.win.mouse, x, cy, w, ch)
      local teal = { 0.25, 0.67, 0.60 }
      Widgets.box(x, cy, w, ch, teal, over and 0.8 or 0.55)
      Widgets.text(text, x, cy, w, ch, { size = 15, align = "center" })
      Widgets.tooltip(State.win,
         State.notice_restorable and "The previous list was kept as the autosave.\nClick to restore it."
         or "Click to dismiss.", x, cy, w, ch)
      if clicked then
         if State.notice_restorable then
            if restore() then State.notice, State.notice_restorable = nil, false end
         else
            State.notice = nil
         end
      end
   end
end

return CommandArea
