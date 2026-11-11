-- @noindex
--[[
SiSt-Live Setlist: CommandArea

The buttons below the list, in sections with a centered name and a divider after each (List: Save, Load, Reset, Restore;
Insert: Text Entry; Zoom: percent = reset, + above -). Each button asks what needs asking (UI/Ask.lua) and then calls an
action (Actions.lua). The layout adapts to the window width (lib/Gui/Layout.lua), always in one row: natural sizes, then compact ones (less
space inside and between the buttons), then the last sections are left out and a line at the right edge says so (a click on
it opens a menu with their commands).

  update()    works out the layout for the window width; first thing in the frame (and the smallest window)
  draw()      draws the area and runs the action of a clicked button; called once per frame by Frame
]]

local Widgets, Theme = require("Gui.Widgets"), require("Gui.Theme")
local Data = require("Setlist.Data")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")
local Layout = require("Gui.Layout")
local Window = require("Gui.Window")
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
            { id = "text", label = "Text Entry", menu = "Insert Text Entry", tip = "Insert text entry after current project." },
         }
      },
      {
         title = "Zoom",
         align = "right",
         items = {
            { id = "zoom_reset", label = zoom_percent_label(), menu = "Reset Zoom", w = 68, compact_w = 56, tip = "Reset Zoom." },
            { id = "zoom_in",    label = "+",                  menu = "Zoom In", w = 34, compact_w = 28, half = 1, repeat_every = gui.zoomDelay, tip = "Zoom in." },
            { id = "zoom_out",   label = "-",                  menu = "Zoom Out", w = 34, compact_w = 28, half = 2, repeat_every = gui.zoomDelay, tip = "Zoom out." },
         }
      },
   }
end

-- Proportions: one rhythm for everything. Margin 12, buttons 8 apart, sections 28 apart with the divider in the middle,
-- buttons of a group equally wide, 12 px above the section names and below the buttons. When the window is too narrow:
-- compact (6 px inside the buttons instead of 11, 4 apart, sections 14 apart, every button as wide as its text), then
-- the last sections are left out: Zoom first, then Insert (the first section, List, always stays).
local MARGIN, OVERFLOW_W = 12, 10
local NATURAL = { pad = 11, gap = 8, group_gap = 28 }
local COMPACT = { pad = 6, gap = 4, group_gap = 14, compact = true }

local current -- the layout of this frame: { plan = Layout.pack(...), sections = groups with their widths }

-- The width of a group and of each of its buttons, for the natural or the compact sizes.
local function group_widths(g, mode)
   local widths, total, first = {}, 0, true
   local text_w = 0
   if not mode.compact then -- natural: the buttons of a group are as wide as the widest
      for _, it in ipairs(g.items) do
         if not it.w then text_w = math.max(text_w, gfx.measurestr(it.label)) end
      end
   end
   for _, it in ipairs(g.items) do
      local bw
      if it.w then
         bw = mode.compact and (it.compact_w or it.w) or it.w
      elseif mode.compact then
         bw = math.floor(gfx.measurestr(it.label) + mode.pad * 2)
      else
         bw = math.floor(text_w + mode.pad * 2)
      end
      widths[it] = bw
      if it.half ~= 2 then -- the lower half shares the column of the upper one
         total = total + bw + (first and 0 or mode.gap)
         first = false
      end
   end
   return total, widths
end

function CommandArea.update()
   Theme.set_font(gui.buttonFontSize)
   local sections, specs = groups(), {}
   for i, g in ipairs(sections) do
      g.nat_w, g.nat_widths = group_widths(g, NATURAL)
      g.cmp_w, g.cmp_widths = group_widths(g, COMPACT)
      specs[i] = { w = g.nat_w, compact_w = g.cmp_w, align = g.align }
   end
   current = {
      plan = Layout.pack(specs, gfx.w, { margin = MARGIN, gap = NATURAL.group_gap, compact_gap = COMPACT.group_gap,
         overflow_w = OVERFLOW_W }),
      sections = sections,
   }
   -- the smallest window the Setlist is usable in: the first section and the indicator, and the header, two rows and the panel
   gui.minWindowW = Layout.min_width(specs, MARGIN, OVERFLOW_W)
   gui.minWindowH = gui.titleHeight + 2 * gui.lineHeight + gui.ctrlPanelSize
end

-- The commands of the sections that were left out, as a menu at the mouse.
local function show_hidden_menu(hidden)
   local items = {}
   for _, index in ipairs(hidden) do
      for _, it in ipairs(current.sections[index].items) do
         items[#items + 1] = { label = it.menu or it.label, disabled = it.disabled, action = function() run(it.id) end }
      end
   end
   gfx.x, gfx.y = State.win.mouse.x, State.win.mouse.y
   local menu, actions = Window.build_menu(items)
   local choice = gfx.showmenu(menu)
   if choice > 0 and actions[choice] then actions[choice]() end
end

function CommandArea.draw()
   if not current then CommandArea.update() end
   local plan = current.plan
   local mode = plan.compact and COMPACT or NATURAL
   Theme.set_font(gui.buttonFontSize)

   local top = gfx.h - gui.ctrlPanelSize + gui.statusH + gui.cmdPad
   local y, h = top + gui.headingH, gui.buttonH
   for k, place in ipairs(plan.items) do
      local g = current.sections[place.index]
      local widths = plan.compact and g.cmp_widths or g.nat_widths
      Widgets.text(g.title, place.x, top, place.w, gui.headingH - 4, { size = 15, color = "muted", align = "center" })
      local bx = place.x
      for _, it in ipairs(g.items) do
         local opts = {
            size = gui.buttonFontSize,
            disabled = it.disabled,
            repeat_every = it.repeat_every,
            tooltip = it.tip
         }
         local by, bh, bw = y, h, widths[it]
         if it.half then
            opts.size = gui.buttonFontSize * 0.9
            bh = math.floor((h - 2) / 2)
            if it.half == 2 then by = y + bh + 2 end
            bx = it.half == 2 and (bx - bw - mode.gap) or bx -- the lower half goes under the upper one
         end
         if Widgets.button(State.win, it.label, bx, by, bw, bh, opts) then run(it.id) end
         bx = bx + bw + mode.gap
      end
      if g.align ~= "right" and k < #plan.items then
         -- divider at the end of the section, in the middle of the gap
         Theme.set("line")
         gfx.rect(place.x + place.w + mode.group_gap / 2, top, 1, gui.headingH + h)
      end
   end

   -- sections that did not fit: a line at the right edge of the bar; a click opens their commands as a menu
   if #plan.hidden > 0 then
      local x, ih = plan.overflow_x, gui.headingH + h
      local over, _, clicked = Widgets.button_state(State.win.mouse, x, top, OVERFLOW_W, ih)
      Theme.set("accent", over and 1 or 0.7)
      gfx.rect(x + OVERFLOW_W - 6, top + 4, 5, ih - 8)
      Widgets.tooltip(State.win, "More buttons are hidden: widen the window,\nor click here for a menu with them.", x, top, OVERFLOW_W, ih)
      if clicked then show_hidden_menu(plan.hidden) end
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
      local w = gfx.measurestr(label) + 24 -- (the chip is flush with the edge and always whole: it is short)
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
      local room = gfx.w - (gui.statusRightW or 200) - 24 - x -- the right part holds the counts and the time
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
