-- @noindex
--[[
SiSt-Live Setlist: CommandArea

The buttons below the list, in sections with a centered name and a divider after each (LIST: Save, Load, Reset, Restore;
INSERT: Text Entry; ZOOM: percent = reset, + above -). Each button asks what needs asking (UI/Ask.lua) and then calls an
action (Actions.lua). The layout is fixed for now: no adapting to the window width.

  draw()      draws the area and runs the action of a clicked button; called once per frame by Frame
]]

local Widgets, Theme = require("Gui.Widgets"), require("Gui.Theme")
local Data = require("Setlist.Data")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")
local Ask = require("Setlist.UI.Ask")

local gui, CFG = ViewState.gui, ViewState.CFG

local CommandArea = {}

local SETLIST_FILTER = "ReaSetlist (.rsl)\0*.rsl;*.RSL\0Reaper Project List (.rpl)\0*.rpl;*.RPL\0\0"

-- Commands ------------------------------------------------------------------------------------------------------

local function save()
   local path = Ask.save_file("Save Setlist", "setlist.rsl")
   if not path then return end
   local ok = Actions.save_to_file(path)
   if ok then
      reaper.MB("Setlist saved to\n" .. path, "Save setlist to file", 0)
   else
      reaper.MB("Failed to open file for writing:\n" .. path, "Save setlist to file", 0)
   end
end

local function load()
   if not Ask.confirm_in_show_mode("Load a setlist from a file?\n\nYour current list is replaced (it is kept as the autosave).",
      "Load setlist") then
      return
   end
   local path = Ask.open_file("Open Setlist", SETLIST_FILTER)
   if path then Actions.load_from_file(path) end
   gui.followPending = true
end

local function reset()
   local open = State.read_open_projects()
   if not Ask.confirm("Reset the setlist?\n\nYour current list (" .. Data.describe_list(State.list) ..
      ") is replaced by the " .. #open .. " open projects.\nYou can bring it back with Restore.", "Reset setlist") then
      return
   end
   Actions.reset()
   gui.followPending = true
end

local function restore()
   local list, invalid, source = Actions.read_autosave()
   if not next(list) then
      reaper.MB("There is no autosave to load.", "Restore", 0)
      return
   end
   if not Ask.confirm("Load the autosave?\n\nYour current list (" .. Data.describe_list(State.list) ..
      ") is replaced by the autosave (" .. Data.describe_list(list) ..
      ").\nYou can bring your current list back with Restore.", "Restore") then
      return
   end
   Actions.restore(list, invalid, source)
   if not State.quit then gui.followPending = true end
end

local function insert_text()
   local name = Ask.text("Insert Text Note", "Enter label:", "")
   if name then Actions.insert_text(name) end
end

local function run(id)
   if id == "restore" then restore()
   elseif id == "reset" then reset()
   elseif id == "save" then save()
   elseif id == "load" then load()
   elseif id == "text" then insert_text()
   elseif id == "zoom_out" then List.zoom_step(-1)
   elseif id == "zoom_in" then List.zoom_step(1)
   elseif id == "zoom_reset" then List.apply_zoom(0)
   end
end

-- Layout --------------------------------------------------------------------------------------------------------

local function zoom_percent_label()
   return math.floor(gui.entryTextSize / CFG.entryTextSize * 100 + 0.5) .. "%"
end

-- half = 1 / 2: the item is the upper / lower half of a stacked pair (same column, half the height each)
local function groups()
   return {
      { title = "LIST", items = {
         { id = "save", label = "Save" },
         { id = "load", label = "Load" },
         { id = "reset", label = "Reset" },
         { id = "restore", label = "Restore", disabled = not Data.has_autosave() },
      } },
      { title = "INSERT", items = {
         { id = "text", label = "Text Entry" },
      } },
      { title = "ZOOM", align = "right", items = {
         { id = "zoom_reset", label = zoom_percent_label(), w = 68 },
         { id = "zoom_in", label = "+", w = 34, half = 1, repeat_every = gui.zoomDelay },
         { id = "zoom_out", label = "-", w = 34, half = 2, repeat_every = gui.zoomDelay },
      } },
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
         local opts = { size = gui.buttonFontSize, disabled = it.disabled, repeat_every = it.repeat_every }
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

return CommandArea
