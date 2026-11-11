-- @noindex
--[[
SiSt-Live Setlist: List

The list in the window: drawing it (rows, scrollbar, header, status line, the arrow that points to an off-screen
current project), finding the entry under the mouse, and the pure scroll and zoom math behind it. It only draws and
looks things up; changing the list is Actions.lua, reading gestures is ListInput.lua.

  draw()                                    the whole window except the command area
  entry_at_mouse(atLastClickPos)            the entry under the mouse and its list position
  update_display_offset(snap), offscreen_indicator(), draw_scrollbar()
  compute_zoom(level), apply_zoom(level), zoom_step(step)
  follow_scroll_offset, max_scroll, manual_max_scroll, apply_manual_scroll, should_follow, find_project_row,
  offscreen_direction, smooth_step          pure scroll math (tested)
  pad_number, mouse_in_rect, point_in_rect  small helpers

Self test: List.self_test() returns a list of { name, ok }.
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Theme, Widgets = require("Gui.Theme"), require("Gui.Widgets")
local TextField = require("Gui.TextField")
local Layout = require("Gui.Layout")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local ProjectInfo = require("Setlist.ProjectInfo")
local ViewState = require("Setlist.UI.ViewState")

local gui, CFG, MODE = ViewState.gui, ViewState.CFG, ViewState.MODE
local ENTRY = Data.ENTRY

local TITLE = "Setlist"

local List = {}

local function clamp(val, min, max)
   return math.max(min, math.min(max, val))
end

-- The chips right before a row's length: how the song ends. Only what differs from the normal case is shown.
local END_CHIPS = {
   no_stop = {
      arrow = true,
      letter = "A",
      color = { 0.25, 0.67, 0.60 },
      tip = "A: Automatic. At the end of the song the next song starts without stopping (Project End Handler - NO STOP)."
   },
   manual = {
      arrow = true,
      letter = "M",
      color = { 1.0, 0.6, 0.2 },
      tip = "M: Manual. Nothing happens at the end of this song, the next one has to be started by hand."
   },
}

-- The width of a chip (the font of the length next to it).
local LOOP_CHIP = { letter = "L", color = { 1.0, 0.82, 0.05 }, tip = "This project has one or more loop regions." }

local function chip_width(chip)
   Theme.set_font(gui.projLenTextSize)
   local lw, lh = gfx.measurestr(chip.letter)
   local as = chip.arrow and math.max(3, math.floor(lh / 4)) or 0
   return 6 + (chip.arrow and (as * 2 + 4) or 0) + lw + 6
end

-- Draws the chip of a row (a down arrow and the letter); returns its left edge. right: where the chip ends.
local function draw_chip(chip, right, y)
   Theme.set_font(gui.projLenTextSize) -- the size of the length next to it
   local lw, lh = gfx.measurestr(chip.letter or "M")
   local h = lh + 4
   local as = chip.arrow and math.max(3, math.floor(lh / 4)) or 0
   local w = 6 + (chip.arrow and (as * 2 + 4) or 0) + lw + 6
   local x, cy = right - w, y + math.floor((gui.lineHeight - h) / 2)
   Widgets.box(x, cy, w, h, chip.color, 0.4)
   gfx.set(chip.color[1], chip.color[2], chip.color[3], 1)
   gfx.rect(x, cy, w, 1)
   gfx.rect(x, cy + h - 1, w, 1)
   Theme.set("text")
   local tx = x + 6
   if chip.arrow then -- the arrow, close to the letter
      gfx.triangle(tx, cy + math.floor(h / 2) - math.floor(as / 2), tx + as * 2, cy + math.floor(h / 2) - math.floor(as / 2),
         tx + as, cy + math.floor(h / 2) + math.ceil(as / 2) + 1)
      tx = tx + as * 2 + 4
   end
   gfx.x, gfx.y = tx, cy + math.floor((h - lh) / 2)
   gfx.drawstr(chip.letter)
   Widgets.tooltip(State.win, chip.tip, x, cy, w, h)
   return x
end

function List.pad_number(numberStr, numDigits)
   local paddingLength = numDigits - #numberStr

   if paddingLength > 0 then
      numberStr = string.rep("0", paddingLength) .. numberStr
   end

   return numberStr
end

function List.mouse_in_rect(x, y, w, h)
   return State.win.mouse.x >= x and State.win.mouse.x <= x + w and State.win.mouse.y >= y and State.win.mouse.y <= y + h
end

function List.point_in_rect(x, y, w, h, px, py)
   return px >= x and px <= x + w and py >= y and py <= y + h
end

-- Pure calculation: sizes for a zoom level, always derived from the base sizes in CFG.
-- Returns clampedLevel, entryTextSize, projLenTextSize, linePadding
function List.compute_zoom(level)
   level = clamp(level, CFG.minZoomLevel, CFG.maxZoomLevel)
   return level,
       CFG.entryTextSize + level,
       CFG.projLenTextSize + level / 2,
       CFG.linePadding + level * 2
end

function List.apply_zoom(level)
   gui.zoomLevel, gui.entryTextSize, gui.projLenTextSize, gui.linePadding = List.compute_zoom(level)
   gui.textEntrySize = math.max(8, math.floor(gui.entryTextSize * gui.textEntryScale + 0.5))

   Theme.set_font(gui.entryTextSize)
   gui.lineHeight = gfx.texth + gui.linePadding
   -- the lines of a text entry are closer together than the rows of the list (the text stays together)
   Theme.set_font(gui.textEntrySize)
   gui.textLineStep = math.min(gui.lineHeight, math.floor(gfx.texth + math.max(2, gui.linePadding / 4)))
   Theme.set_font(gui.entryTextSize)
   log:debug("Zoom level is now " .. gui.zoomLevel)
end

-- Zoom one step in (+1) or out (-1). Alt resets the zoom.
-- Holding a zoom button repeats this (Widgets.button repeat_every), so there is no throttling here.
function List.zoom_step(step)
   if State.win.mouse.alt then List.apply_zoom(0) else List.apply_zoom(gui.zoomLevel + step) end
end

-- Rows -------------------------------------------------------------------------------------------------------------
-- The list is measured in rows (one row = gui.lineHeight): an entry is one row high, except a text entry with several
-- lines, which is as many rows high as it has lines. Scrolling, the scrollbar and the visible count are in rows.

--- Pure. Breaks the text into lines that are at most max_w wide (see Widgets.wrap_text).
List.wrap_text = Widgets.wrap_text

local number_cache = {}

--- The width of the number column: where a project has its number (and a text entry its "--"), the name starts after it.
function List.number_width()
   local digits = math.floor(math.log(math.max(State.tab_count or 1, 1), 10) + 1)
   local key = digits .. "|" .. gui.entryTextSize
   if number_cache.key ~= key then
      Theme.set_font(gui.entryTextSize)
      number_cache.key, number_cache.width = key, gfx.measurestr(string.rep("0", digits) .. ". ")
   end
   return number_cache.width
end

--- How far a text entry is indented: a linked one starts where the project names start, so its "--" is lined up with them.
function List.link_indent(entry)
   if entry.type == ENTRY.TEXT and gui.linkRows and gui.linkRows[entry] then return List.number_width() end
   return 0
end

--- The height of a text entry's extra lines as a fraction of a row (they are closer together than rows).
function List.row_gap()
   if gui.textLineStep and gui.lineHeight and gui.lineHeight > 0 then return gui.textLineStep / gui.lineHeight end
   return 1
end

local wrap_cache = setmetatable({}, { __mode = "k" }) -- text entry -> { key, lines }

--- What a text entry shows: its lines (wrapped to the window) and the width of the number column (where a project has its
--- number, a text entry has "--"; its text starts after it). Wrapping needs the window: with none (w = 0) only the line
--- breaks of the text count.
function List.text_lines(entry)
   local name = entry.name or ""
   if gfx.w == nil or gfx.w <= 0 then return List.wrap_text(name, math.huge, function() return 0 end), 0 end

   local numW = List.number_width()
   local indent = List.link_indent(entry)
   local key = table.concat({ name, gfx.w, gui.scrollW, gui.entryTextSize, gui.textEntrySize, numW, indent }, "|")
   local c = wrap_cache[entry]
   if c and c.key == key then return c.lines, numW end

   Theme.set_font(gui.textEntrySize)
   local avail = gfx.w - gui.scrollW - (gui.leftBorder + gui.entryIndent + indent) - numW - 12
   local lines = List.wrap_text(name, math.max(avail, 20), function(s) return (gfx.measurestr(s)) end)
   wrap_cache[entry] = { key = key, lines = lines }
   return lines, numW
end

--- How many rows high an entry is.
function List.entry_rows(entry)
   if type(entry) == "table" and entry.type == ENTRY.TEXT and entry.name then
      local n
      if gui.edit and gui.edit.entry == entry then -- the entry grows while it is edited: the lines the field drew last
         local lines = gui.edit.field.vlines
         if lines then
            n = #lines
         else
            local _, breaks = gui.edit.field.text:gsub("\n", "")
            n = breaks + 1
         end
      else
         n = #List.text_lines(entry)
      end
      return 1 + (n - 1) * List.row_gap()
   end
   return 1
end

--- starts[i] = the number of rows above entry i (the 0-based row where it begins); and the total number of rows.
function List.layout(list)
   local starts, row = {}, 0
   for i, entry in ipairs(list) do
      starts[i] = row
      row = row + List.entry_rows(entry)
   end
   return starts, row
end

--- The position of the entry that covers the 0-based row (the last one for a row below the list).
function List.entry_at_row(list, row)
   local top = 0
   for i, entry in ipairs(list) do
      top = top + List.entry_rows(entry)
      if row < top then return i end
   end
   return #list
end

function List.entry_at_mouse(findAtLastClickPos)
   if not findAtLastClickPos then
      findAtLastClickPos = false
   end

   local mouseIsOverList = State.win.mouse.y < gui.listH + gui.titleHeight - gui.dragThreshold and
       State.win.mouse.y > gui.titleHeight and State.win.mouse.x < gfx.w - gui.scrollW and State.win.mouse.x > gui.leftBorder

   if not mouseIsOverList then
      return nil, nil
   end

   local starts = List.layout(State.list)
   for i, entry in ipairs(State.list) do
      local h = List.entry_rows(entry) * gui.lineHeight
      local yStart = gui.titleHeight + (starts[i] - gui.scrollOffset) * gui.lineHeight
      local yEnd = yStart + h

      if yEnd > gui.titleHeight then -- (not scrolled out at the top)
         if yEnd > gui.listH + gui.titleHeight then return nil, nil end -- only return entry if fully visible.

         local mouseIsOverEntry
         if findAtLastClickPos then
            mouseIsOverEntry = List.point_in_rect(0, yStart, gfx.w - gui.scrollW, h,
               gui.lastClickDownPos.x, gui.lastClickDownPos.y)
         else
            mouseIsOverEntry = List.mouse_in_rect(0, yStart, gfx.w - gui.scrollW, h)
         end

         if mouseIsOverEntry then return entry, i end
      end
   end

   return nil, nil
end

-- Pure function. Returns the scroll offset (0-based, number of entries scrolled out at the top) that puts the
-- previous PROJECT entry in the top row, so the current project and every text entry between the two stay visible.
-- If there is no previous project the list starts at the top. Returns nil if currentListIdx isn't in the list.
function List.follow_scroll_offset(list, currentListIdx, maxScroll)
   if not currentListIdx or currentListIdx < 1 or currentListIdx > #list then return nil end

   local offset = 0
   local starts = List.layout(list)
   for i = currentListIdx - 1, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         offset = starts[i]
         break
      end
   end

   return clamp(offset, 0, maxScroll or offset)
end

-- Pure function. How far the list may scroll. Normally that's "last entry at the bottom", but to let the
-- previous project of the LAST project reach the top row the range is extended (the rows below stay empty).
-- A list that fits completely never scrolls.
function List.max_scroll(list, numVisibleEntries)
   local _, totalRows = List.layout(list)
   local naturalMax = math.max(0, totalRows - numVisibleEntries)
   if naturalMax == 0 then return 0 end

   for i = #list, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         return math.max(naturalMax, List.follow_scroll_offset(list, i) or 0) -- no maxScroll given: unclamped
      end
   end
   return naturalMax
end

-- Pure function. The range for manual scrolling (wheel, scrollbar, dragging): the last entry may reach the
-- bottom of the window, but there is never an empty row below it.
function List.manual_max_scroll(list, numVisibleEntries)
   local _, totalRows = List.layout(list)
   return math.max(0, totalRows - numVisibleEntries)
end

-- Pure function. Scrolls by delta rows (positive = down) in the manual range.
-- Smooth after a follow-scroll: if the view currently shows empty rows beyond the manual range, scrolling up
-- moves it from where it is (it does not snap back first), and scrolling down simply stays where it is.
function List.apply_manual_scroll(offset, delta, manualMax)
   local upperLimit = math.max(manualMax, offset)
   return clamp(offset + delta, 0, upperLimit)
end

-- Pure function. Should a change of the current project scroll the list? Always, except when the project was
-- selected by clicking it in the list while in edit mode: the list must not move away from where you work.
function List.should_follow(mode, changedFromList)
   return not (mode == MODE.EDIT and changedFromList)
end

-- Pure function. List index of the first project entry for proj, or nil.
function List.find_project_row(list, proj)
   if not proj then return nil end
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT and entry.proj == proj then return i end
   end
   return nil
end

-- Pure function. Where the entry at listIdx is relative to the visible rows:
-- -1 = scrolled out at the top, 1 = below the visible rows, 0 = visible (or listIdx unknown).
function List.offscreen_direction(list, listIdx, scrollOffset, numVisible)
   if not listIdx then return 0 end
   local starts = List.layout(list)
   local first = starts[listIdx]
   if not first then return 0 end
   if first + List.entry_rows(list[listIdx]) <= scrollOffset then return -1 end
   if first >= scrollOffset + numVisible then return 1 end
   return 0
end

-- Pure function. One animation step of the drawn scroll position towards the target (exponential ease-out).
-- No current value or timeConstant <= 0 jumps straight to the target. Snaps once closer than 0.01 rows.
function List.smooth_step(current, target, dt, timeConstant)
   if current == nil or not timeConstant or timeConstant <= 0 then return target end
   if dt <= 0 then return current end

   local new = current + (target - current) * (1 - math.exp(-dt / timeConstant))
   if math.abs(target - new) < 0.01 then return target end
   return new
end

-- Moves the drawn scroll position towards gui.scrollOffset. snap = true ends any animation at once
-- (used whenever the user scrolls, clicks or drags, so what is drawn is always what the mouse hits).
function List.update_display_offset(snap)
   local now = reaper.time_precise()
   local dt = math.min(now - (gui.lastAnimTime or now), 0.1) -- a stalled frame doesn't skip the animation
   gui.lastAnimTime = now

   if snap then
      gui.displayOffset = gui.scrollOffset
   else
      gui.displayOffset = List.smooth_step(gui.displayOffset, gui.scrollOffset, dt, gui.smoothScrollTime)
   end
end

-- Draws an arrow at the top or bottom edge of the list when the current project is out of view.
-- Clicking it jumps back to the current project (in both modes).
function List.offscreen_indicator()
   if gui.draggingEntry then return end

   local dir = List.offscreen_direction(State.list, List.find_project_row(State.list, State.current_proj),
      gui.scrollOffset, gui.numVisibleEntries)
   if dir == 0 then return end

   local w, h = gui.offscreenIndicatorW, gui.offscreenIndicatorH
   local x = math.floor((gfx.w - gui.scrollW - w) / 2)
   local listBottom = gui.titleHeight + gui.numVisibleEntries * gui.lineHeight
   local y = dir < 0 and gui.titleHeight + 2 or listBottom - h - 2

   gfx.set(table.unpack(gui.offscreenIndicatorColor))
   gfx.rect(x, y, w, h, true)

   local cx, triW, triH = x + w / 2, h * 0.9, h * 0.5
   local top = y + (h - triH) / 2
   gfx.set(0, 0, 0, 0.8)
   if dir < 0 then
      gfx.triangle(cx - triW / 2, top + triH, cx + triW / 2, top + triH, cx, top)
   else
      gfx.triangle(cx - triW / 2, top, cx + triW / 2, top, cx, top + triH)
   end

   local pressedNow = gui.leftClick and not gui.prevLeftClick
   if pressedNow and not gui.leftClickHandled
       and List.point_in_rect(x, y, w, h, gui.lastClickDownPos.x, gui.lastClickDownPos.y) then
      gui.leftClickHandled = true -- the entry under the arrow is not selected
      gui.pressOnIndicator = true -- and not dragged
      gui.followPending = true    -- the jump happens when the mouse is released
      log:debug("Off-screen arrow clicked: jumping to the current project")
   end
end

function List.draw_scrollbar()
   local _, setlistLength = List.layout(State.list) -- rows
   if setlistLength <= gui.numVisibleEntries then return end

   local scrollTrackHeight = gui.listH + gui.titleHeight
   gui.scrollH = scrollTrackHeight * (gui.numVisibleEntries / setlistLength)
   local offset = gui.displayOffset or gui.scrollOffset
   gui.scrollY = clamp(offset / math.max(gui.maxScroll, 1), 0, 1) * (scrollTrackHeight - gui.scrollH)

   -- Scroll Track
   Theme.set("button")
   gfx.rect(gfx.w - gui.scrollW, 0, gui.scrollW, scrollTrackHeight)

   -- Scroll Thumb
   Theme.set("muted")
   gfx.rect(gfx.w - gui.scrollW + 2, gui.scrollY, gui.scrollW - 4, gui.scrollH)

   return gui.scrollY, gui.scrollH
end

local function draw_entry(y, entry)
   if not entry or not y then return end
   local highlight = entry.highlight
   local h = List.entry_rows(entry) * gui.lineHeight -- (a text entry with several lines is several rows high)
   local indent = List.link_indent(entry)

   -- the current project and the one after it are found whatever else the row is (a dragged current project must not
   -- lose the "next project" mark of the entry after it)
   local is_current, is_next = false, false
   if entry.proj ~= nil and entry.proj == State.current_proj and not gui.currProjDrawn then
      is_current = true
      gui.currProjDrawn = true
      gui.isNextProj = true
   elseif gui.isNextProj and entry.type == ENTRY.PROJECT then
      is_next = true
      gui.isNextProj = false
   end

   if gui.draggingEntry and gui.dragThreshReached and
       (entry.listIdx == gui.dragEntryListIdx or (gui.dragGroup and gui.selection[entry])) then
      highlight = gui.dragHighlight
   elseif is_current then
      highlight = gui.activeProjHighlight
   elseif is_next then
      highlight = gui.nextProjHighlight
   end

   highlight = highlight or gui.entryHighlights[entry.type]

   if highlight then
      gfx.set(table.unpack(highlight))
      gfx.rect(gui.leftBorder + indent, y + 2, gfx.w - gui.scrollW - indent, h - 4)
   end

   if gui.selection[entry] then -- selected: a tint and a border in the accent colour
      Theme.set("accent", 0.2)
      gfx.rect(gui.leftBorder + indent, y + 2, gfx.w - gui.scrollW - indent, h - 4)
      Theme.set("accent", 0.9)
      gfx.rect(gui.leftBorder + indent, y + 2, gfx.w - gui.scrollW - indent, h - 4, false)
   end

   Theme.set("line")
   gfx.line(gui.leftBorder, y + h, gfx.w - gui.scrollW, y + h - 1)

   -- a line at the left edge joins a project with the text entries linked to it; at the first and the last entry of the
   -- group it turns into a hook towards the entry (the linked text entries are indented, the hook reaches their edge)
   local link = gui.linkRows and gui.linkRows[entry]
   if link then
      Theme.set("accent", 0.9)
      local mid = y + h / 2
      local top = link.first and mid - 1 or y
      local bottom = link.last and mid + 1 or y + h
      gfx.rect(1, top, 2, bottom - top)
      if link.first or link.last then
         local reach = entry.type == ENTRY.TEXT and (gui.leftBorder + indent - 3) or 9
         gfx.rect(1, mid - 1, math.max(4, reach - 1), 2)
      end
   end

   -- The marks at the left, over the link line: the white dot of the active project; with a selection it is the selected
   -- entries that are marked (a square in the colour of the border, white for the active project), the active project
   -- keeps no dot then
   do
      local radius = gui.leftBorder / 2
      -- centred on the left edge of the entry (after its indent), where the dot of the active project always was
      local cx = gui.leftBorder + indent
      local cy = y + h / 2 -- the vertical middle of the entry: where the link hook touches it
      local active = entry.proj ~= nil and entry.proj == State.current_proj
      if gui.selection[entry] then
         if active then Theme.set("text") else Theme.set("accent") end
         local size = gui.leftBorder + 1
         gfx.rect(math.floor(cx - size / 2), math.floor(cy - size / 2), size, size)
      elseif active and next(gui.selection) == nil then
         Theme.set("text")
         gfx.circle(cx, cy, radius, true, true)
      end
   end

   -- what the song's markers say (the chips before the length: end handler, loop regions)
   local info =entry.type == ENTRY.PROJECT and not entry.name:find("_.*ROUTING") and entry.path ~= "Unsaved Project"
       and ProjectInfo.read(entry.proj) or nil

   -------------------
   -- draw entry text
   local textAlpha -- text uses the theme's text color, nil = not drawn
   local entryStr
   gfx.x = gui.leftBorder + gui.entryIndent
   Theme.set_font(gui.entryTextSize)
   if entry.type == ENTRY.PROJECT then
      textAlpha = 1
      local displayIdx = tostring(entry.tabIdx or entry.listIdx)
      displayIdx = List.pad_number(displayIdx, math.floor(math.log(State.tab_count, 10) + 1)) .. ". "

      --draw selected project indicator


      -- (a tab closed a moment ago has a stale pointer until the list has followed the tabs)
      local playState = entry.proj and reaper.ValidatePtr(entry.proj, "ReaProject*") and
      reaper.GetPlayStateEx(entry.proj) or 0
      if playState > 0 then
         -- draw pos indicator
         local projLen = Sync.project_length(entry.proj)

         if projLen > 0 then -- no end marker = no length: no position to show
            local playPos = reaper.GetPlayPositionEx(entry.proj)
            local r, g, b, a = table.unpack(gui.playPosColor)
            gfx.set(r, g, b, a)

            local x = (gfx.w - gui.scrollW - gui.entryIndent) * playPos / projLen + 5
            gfx.rect(x, y, gui.leftBorder, gui.lineHeight)

            a = 0.2
            gfx.set(r, g, b, a)

            gfx.rect(gui.leftBorder, y, x, gui.lineHeight)
         end


         -- draw project playstate indicator
         local displayIdxWidth = gfx.measurestr(displayIdx)

         local pass, passes, stopped = ProjectInfo.loop_pass(entry.proj)
         if pass and (playState == 1 or playState == 5) then
            -- looping: "L2" in place of the symbol, yellow when playing (red when recording); "L3→" once the loop was
            -- stopped (the song moves on after this pass). The title starts after it, so a long label pushes it right.
            local x0 = gui.leftBorder + gui.entryIndent
            local label = stopped and "L →" or ("L" .. pass)
            local color = playState == 5 and gui.transportColors[5] or { 1.0, 0.82, 0.05, 1 }
            gfx.set(table.unpack(color))
            local labelW, labelH = gfx.measurestr(label)
            gfx.x, gfx.y = x0, y + (gui.lineHeight - labelH) / 2
            gfx.drawstr(label)
            gfx.x = x0 + math.max(displayIdxWidth, labelW + 8)
            displayIdx = ""
         elseif playState == 1 then
            gfx.x = gfx.x + displayIdxWidth
            displayIdx = ""
            gfx.set(table.unpack(gui.transportColors[playState]))

            local triangleH = gui.lineHeight * 0.5
            local triangleW = clamp(triangleH * 0.8, 0, displayIdxWidth * 0.8)

            local iconLRPadding = (displayIdxWidth - triangleW) / 2 - 5
            local iconTopPadding = (gui.lineHeight - triangleH) / 2
            gfx.triangle(
               gui.leftBorder + gui.entryIndent + triangleW, y + gui.lineHeight / 2,
               gui.leftBorder + gui.entryIndent + iconLRPadding, y + iconTopPadding,
               gui.leftBorder + gui.entryIndent + iconLRPadding, y + iconTopPadding + triangleH)
         elseif playState == 5 then
            gfx.x = gfx.x + displayIdxWidth
            displayIdx = ""

            local iconRadius = clamp(gui.lineHeight * 0.5 / 2 - 2, 0, displayIdxWidth / 2 * 0.8)

            gfx.set(table.unpack(gui.transportColors[playState]))
            gfx.circle(gui.leftBorder + gui.entryIndent + iconRadius, y + gui.lineHeight / 2, iconRadius, true,
               true)
         end
      end
      entryStr = displayIdx .. (entry.name or "")
   elseif entry.type == ENTRY.TEXT then
      -- "--" where a project has its number, the text (a bit smaller) where the project names start, one row per line
      local x0 = gui.leftBorder + gui.entryIndent + indent
      local lines, numW = List.text_lines(entry)
      local editing = gui.edit and gui.edit.entry == entry
      if numW == 0 then
         Theme.set_font(gui.entryTextSize)
         numW = gfx.measurestr("00. ")
      end
      Theme.set_font(gui.textEntrySize)
      Theme.set("text", gui.textEntryAlpha)
      local _, lineH = gfx.measurestr("Ag")
      local step = gui.textLineStep or gui.lineHeight
      local top = (gui.lineHeight - step) / 2 -- the lines are a block, centred in the entry
      gfx.x, gfx.y = x0, y + top + (step - lineH) / 2
      gfx.drawstr("--")
      if editing then
         -- being edited: the text is a text field (ListInput.handle_edit acts on what happened)
         gui.editEvent = TextField.draw(State.win, gui.edit.field, x0 + numW - TextField.PAD, y + 1,
            gfx.w - gui.scrollW - (x0 + numW) + TextField.PAD - 4, h - 2,
            { size = gui.textEntrySize, line_h = step, top_pad = top - 1 })
      else
         for k, line in ipairs(lines) do
            gfx.x, gfx.y = x0 + numW, y + top + (k - 1) * step + (step - lineH) / 2
            gfx.drawstr(line)
         end
      end
      Theme.set_font(gui.entryTextSize)
      entryStr = ""
   elseif entry.type == ENTRY.MISSING then
      textAlpha = gui.textEntryAlpha
      entryStr = "?  " .. (entry.name or "")
   end


   -- The right part of a project row (length, chips) is drawn first: the name gives way to it. In a narrow window the
   -- chips go first, then the length, so that at least about five characters of the name stay.
   local name_x = gfx.x
   local name_right = gfx.w - gui.scrollW - gui.rowMargin
   if entry.type == ENTRY.PROJECT and not entry.name:find("_.*ROUTING") then
      local min_name = gui.entryTextSize * 5
      local projLen = Sync.project_length(entry.proj)
      local projLenStr = projLen > 0 and Data.format_time(projLen) or "--:--" -- no end marker: no length

      Theme.set_font(gui.projLenTextSize)
      local strW, strH = gfx.measurestr(projLenStr)
      local lengthX = name_right - strW
      if lengthX - name_x >= min_name then
         gfx.x, gfx.y = lengthX, y + (gui.lineHeight - strH) / 2
         Theme.set("text") -- (not the colour of what was drawn before, e.g. the transport state)
         gfx.drawstr(projLenStr)
         name_right = lengthX - 10

         local chips = {}
         local end_chip = info and END_CHIPS[info.end_kind]
         if end_chip then chips[#chips + 1] = end_chip end
         if info and #info.loops > 0 then chips[#chips + 1] = LOOP_CHIP end
         local chips_w = 0
         for _, chip in ipairs(chips) do chips_w = chips_w + chip_width(chip) + 6 end
         if #chips > 0 and name_right - chips_w - name_x >= min_name then
            local right = name_right
            for _, chip in ipairs(chips) do right = draw_chip(chip, right, y) - 6 end
            name_right = right + 6 - 10
         end
      end
   end

   if textAlpha and entryStr ~= "" then
      Theme.set_font(gui.entryTextSize)
      entryStr = Widgets.fit_text(entryStr, name_right - name_x, function(s) return (gfx.measurestr(s)) end)
      local _, strH = gfx.measurestr(entryStr)
      gfx.x, gfx.y = name_x, y + (gui.lineHeight - strH) / 2
      Theme.set("text", textAlpha)
      gfx.drawstr(entryStr)
   end
end

--- What the window shows when it is smaller than the Setlist can be used in (gui.minWindowW / H): only how big it has to be.
function List.draw_too_small()
   gfx.clear = Theme.clear_color()
   Theme.set("background")
   gfx.rect(0, 0, gfx.w, gfx.h)
   local text = "Window Too Small\n\nMake it at least " .. math.ceil(gui.minWindowW) .. " x " .. math.ceil(gui.minWindowH) ..
       " pixels."
   Theme.set_font(16)
   local lines = Widgets.wrap_text(text, math.max(40, gfx.w - 24), function(s) return (gfx.measurestr(s)) end)
   local line_h = 22
   local top = math.floor((gfx.h - #lines * line_h) / 2)
   for i, line in ipairs(lines) do
      Widgets.text(line, 12, top + (i - 1) * line_h, gfx.w - 24, line_h, { size = 16, align = "center", color = i == 1 and "text" or "muted" })
   end
end

function List.draw()
   gfx.clear = Theme.clear_color()

   -- Draw Entries. While a follow-scroll animates, gui.displayOffset is fractional: the rows are drawn shifted
   -- by the fraction and one extra row is drawn. The backgrounds painted below hide what sticks out.
   local offset = gui.displayOffset or gui.scrollOffset
   local starts = List.layout(State.list)

   gui.linkRows = Data.linked_rows(State.list)
   for i, entry in ipairs(State.list) do
      -- (the entries that are at least partly in the view, plus one row below)
      if starts[i] + List.entry_rows(entry) > offset and starts[i] <= offset + gui.numVisibleEntries then
         draw_entry(gui.titleHeight + (starts[i] - offset) * gui.lineHeight, entry)
      end
   end

   gui.isNextProj = false
   gui.currProjDrawn = false

   Theme.set("background")
   gfx.rect(0, 0, gfx.w, gui.titleHeight)
   gfx.rect(0, gfx.h - gui.ctrlPanelSize, gfx.w, gui.ctrlPanelSize)

   -- Draw Title: the shared SiSt-Live header (teal, fixed size: gui.titleHeight - 12 = Widgets.HEADER_H)
   local headerH = gui.titleHeight - 12
   if State.job then
      -- loading: the header fills while the projects open
      Widgets.header("", 3, 3, gfx.w - 6, headerH, "accent")
      Widgets.box(3, 3, math.floor((gfx.w - 6) * State.job.done / math.max(1, State.job.total)), headerH, "accent", 0.6)
      Widgets.text(string.format("Loading %d / %d", State.job.done, State.job.total), 3, 3, gfx.w - 6, headerH,
         { size = Widgets.header_text_size(headerH), align = "center", color = "text", face = Theme.TITLE_FACE })
   else
      local title = State.name and ((State.modified and "*" or "") .. State.name) or TITLE
      Widgets.header(title, 3, 3, gfx.w - 6, headerH, "accent")
   end

   -- Status line under the list (what the list holds), a faint divider above it, the strong command bar divider below
   local projects = #Data.project_entries(State.list)
   local time = Data.format_time(State.total_time)
   local noun = projects .. (projects == 1 and " project" or " projects")
   Theme.set("line")
   gfx.rect(0, gfx.h - gui.ctrlPanelSize, gfx.w, 1)
   Theme.set_font(15)
   Theme.set("muted")
   -- the long form, then shorter ones: at most half the window, the left part (chips) gets the rest
   local function measure(s) return (gfx.measurestr(s)) end
   local str = Layout.pick({ noun .. "  |  " .. time .. " total", noun .. "  |  " .. time, projects .. "  |  " .. time, time },
      math.floor(gfx.w / 2) - gui.rowMargin, measure)
   gui.statusRightW = measure(str)
   gfx.x, gfx.y = gfx.w - gui.rowMargin - gui.statusRightW, gfx.h - gui.ctrlPanelSize + 5
   gfx.drawstr(str)

   Theme.set("text", 0.6)
   gfx.rect(0, gfx.h - gui.ctrlPanelSize + gui.statusH, gfx.w, gui.dropIndicatorThickness - 2)

   -- Draw a line indicating where the project would be dropped if dragging

   if gui.draggingEntry and gui.dropIdx and (gui.dropDir or gui.dragDirection) then
      local isDragFarEnough = gui.dropIdx ~= gui.dragEntryListIdx and
          (gui.dropIdx > gui.dragEntryListIdx or gui.dropIdx < gui.dragEntryListIdx)

      if isDragFarEnough then
         -- at the end of the entry it is dropped after (dragged down), at the start of the one it is dropped before
         local starts = List.layout(State.list)
         local row = starts[gui.dropIdx] or 0
         if (gui.dropDir or gui.dragDirection) == 1 and gui.dropIdx > 1 then row = row + List.entry_rows(State.list[gui.dropIdx]) end
         local dropYstart = gui.titleHeight + (row - gui.scrollOffset) * gui.lineHeight

         -- Draw drop indicator line as a rectangle (in the colour of the link line when the drop will link)
         if gui.dropLink then Theme.set("accent", 0.95) else Theme.set("text", 0.6) end
         gfx.rect(5, dropYstart - 2, gfx.w - 10, gui.dropIndicatorThickness)
      end
   end
end

-- Self test ---------------------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("Clamp / PadNumberStringWithZeroes", function(t)
   t.eq(List.pad_number("123", 2), "123", "never truncated")
end)

define("Zoom calculation", function(t)
   t.eq((List.compute_zoom(1000)), CFG.maxZoomLevel, "clamped to max")
   t.eq((List.compute_zoom(-1000)), CFG.minZoomLevel, "clamped to min")
end)

define("GetFollowScrollOffset", function(t)
   -- 1:T0 2:P1 3:T1 4:T2 5:P2 6:P3 7:T3
   local list = {
      { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.TEXT },
      { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
   }
   t.eq(List.follow_scroll_offset(list, 2, 10), 0, "first project: nothing above it, start at the top")
   t.eq(List.follow_scroll_offset(list, 5, 10), 1,
      "previous project (idx 2) goes to the top row, texts below it stay visible")
   t.eq(List.follow_scroll_offset(list, 6, 10), 4, "directly following project: previous project in top row")
   t.eq(List.follow_scroll_offset(list, 6, 3), 3, "clamped to maxScroll near the end of the list")
   t.eq(List.follow_scroll_offset(list, 0, 10), nil, "idx 0 (tab not in list)")
   t.eq(List.follow_scroll_offset(list, 8, 10), nil, "idx past the end")
   t.eq(List.follow_scroll_offset({ { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }, 2, 0), 0,
      "short list: maxScroll 0")
end)

define("GetMaxScroll", function(t)
   local function projects(n)
      local l = {}
      for i = 1, n do l[i] = { type = ENTRY.PROJECT } end
      return l
   end
   t.eq(List.max_scroll(projects(5), 10), 0, "list that fits never scrolls")
   t.eq(List.max_scroll(projects(20), 9), 18, "20 projects: last project's predecessor (idx 19) can reach the top row")
   t.eq(List.max_scroll(projects(12), 10), 10, "list only 2 longer than the window still scrolls far enough")
   local withTexts = projects(3)
   for i = 4, 9 do withTexts[i] = { type = ENTRY.TEXT } end
   t.eq(List.max_scroll(withTexts, 4), 5, "trailing text entries: normal range is enough")
   t.eq(List.max_scroll({}, 5), 0, "empty list")
end)

define("Manual scrolling range", function(t)
   t.eq(List.manual_max_scroll({ 1, 2, 3, 4, 5 }, 3), 2, "last entry at the bottom")
   t.eq(List.manual_max_scroll({ 1, 2 }, 5), 0, "fits: no scrolling")
   t.eq(List.manual_max_scroll({ 1, { type = ENTRY.TEXT, name = "a\nb\nc" }, 3 }, 3), 2, "a three-line text entry counts as three rows")

   t.eq(List.apply_manual_scroll(3, 1, 8), 4, "normal scroll down")
   t.eq(List.apply_manual_scroll(3, -5, 8), 0, "clamped at the top")
   t.eq(List.apply_manual_scroll(7, 4, 8), 8, "clamped at the manual maximum")
   -- view was left beyond the manual range by the follow-scroll (empty rows showing)
   t.eq(List.apply_manual_scroll(18, -1, 11), 17, "scrolling up starts from where the view is: smooth, no snap")
   t.eq(List.apply_manual_scroll(18, 1, 11), 18, "scrolling down does not go further")
   t.eq(List.apply_manual_scroll(13, -2, 11), 11, "comes back into the manual range step by step")
   t.eq(List.apply_manual_scroll(11, 1, 11), 11, "manual maximum is a hard stop once reached")
end)

define("ShouldFollowProjectChange", function(t)
   t.ok(List.should_follow(MODE.SHOW, false), "show mode, tab changed in REAPER")
   t.ok(List.should_follow(MODE.SHOW, true), "show mode, clicked in the list")
   t.ok(List.should_follow(MODE.EDIT, false), "edit mode, tab changed in REAPER")
   t.ok(not List.should_follow(MODE.EDIT, true), "edit mode, clicked in the list: list stays")
end)

define("FindProjListIdx / GetOffscreenDirection", function(t)
   local list = {
      { type = ENTRY.TEXT,    proj = "a" }, { type = ENTRY.PROJECT, proj = "a" }, { type = ENTRY.TEXT },
      { type = ENTRY.PROJECT, proj = "b" }, { type = ENTRY.PROJECT, proj = "a" },
   }
   t.eq(List.find_project_row(list, "a"), 2, "first project entry, text entries ignored")
   t.eq(List.find_project_row(list, "zzz"), nil, "not in list")
   t.eq(List.find_project_row(list, nil), nil, "nil project")

   -- rows 6..10 visible (scrollOffset 5, 5 rows)
   local rows = {}
   for i = 1, 12 do rows[i] = { type = ENTRY.PROJECT } end
   t.eq(List.offscreen_direction(rows, 5, 5, 5), -1, "just above")
   t.eq(List.offscreen_direction(rows, 6, 5, 5), 0, "first visible row")
   t.eq(List.offscreen_direction(rows, 10, 5, 5), 0, "last visible row")
   t.eq(List.offscreen_direction(rows, 11, 5, 5), 1, "just below")
   t.eq(List.offscreen_direction(rows, nil, 5, 5), 0, "unknown project: no arrow")
   rows[5] = { type = ENTRY.TEXT, name = "one\ntwo\nthree" } -- rows 4..6 (0-based)
   t.eq(List.offscreen_direction(rows, 5, 5, 5), 0, "a tall entry that is partly in view counts as visible")
   t.eq(List.offscreen_direction(rows, 5, 7, 5), -1, "...and is gone once its last row is above")
end)

define("wrap_text", function(t)
   local function m(s) return #s * 10 end -- every character 10 wide
   t.eq(List.wrap_text("one two three", 1000, m), { "one two three" }, "fits: one line")
   t.eq(List.wrap_text("one two three", 80, m), { "one two", "three" }, "breaks at a space")
   t.eq(List.wrap_text("a\nb", 1000, m), { "a", "b" }, "line breaks stay")
   t.eq(List.wrap_text("", 100, m), { "" }, "empty text: one empty line")
   t.eq(List.wrap_text("abcdefghij", 40, m), { "abcd", "efgh", "ij" }, "a word wider than the line is cut")
   t.eq(List.wrap_text("ab cdefghij", 40, m), { "ab", "cdef", "ghij" }, "a long word starts on a new line, then is cut")
   t.eq(List.wrap_text("a  b", 1000, m), { "a  b" }, "double spaces are kept when it fits")
   t.eq(List.wrap_text("x\n\ny", 1000, m), { "x", "", "y" }, "empty lines stay")
end)

define("Rows of multi-line entries", function(t)
   local saved_step = gui.textLineStep
   gui.textLineStep = nil -- (no window: a line is a whole row)
   local list = { { type = ENTRY.PROJECT }, { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.TEXT, name = "x" },
      { type = ENTRY.TEXT, name = "1\n2\n3" }, { type = ENTRY.PROJECT } }
   t.eq({ List.entry_rows(list[1]), List.entry_rows(list[2]), List.entry_rows(list[4]) }, { 1, 2, 3 }, "rows per entry")
   t.eq({ List.layout(list) }, { { 0, 1, 3, 4, 7 }, 8 }, "where the entries start and the total")
   t.eq({ List.entry_at_row(list, 0), List.entry_at_row(list, 2), List.entry_at_row(list, 3), List.entry_at_row(list, 6),
      List.entry_at_row(list, 7), List.entry_at_row(list, 99) }, { 1, 2, 3, 4, 5, 5 }, "the entry at a row")
   t.eq(List.follow_scroll_offset({ { type = ENTRY.PROJECT }, { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.PROJECT },
      { type = ENTRY.PROJECT } }, 4, 100), 3, "follow-scroll counts rows: the previous project of the last one starts at row 3")
   gui.textLineStep = saved_step
end)

define("Closer lines in text entries", function(t)
   local saved_step, saved_h = gui.textLineStep, gui.lineHeight
   gui.textLineStep, gui.lineHeight = 30, 50
   t.eq(List.entry_rows({ type = ENTRY.TEXT, name = "a" }), 1, "one line: one row")
   t.eq(List.entry_rows({ type = ENTRY.TEXT, name = "a\nb\nc" }), 1 + 2 * 0.6, "more lines: each adds 30/50 of a row")
   t.eq({ List.layout({ { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.PROJECT } }) }, { { 0, 1.6 }, 2.6 },
      "the next entry starts after the tall one")
   gui.textLineStep, gui.lineHeight = saved_step, saved_h
end)

define("StepSmoothScroll", function(t)
   t.eq(List.smooth_step(nil, 7, 0.016, 0.08), 7, "first frame jumps")
   t.eq(List.smooth_step(0, 7, 0.016, 0), 7, "time constant 0 disables the animation")
   t.eq(List.smooth_step(3, 7, 0, 0.08), 3, "no time passed: no movement")
   local v = List.smooth_step(0, 10, 0.016, 0.08)
   t.ok(v > 0 and v < 10, "moves towards the target without reaching it in one frame")
   local x = 0
   for _ = 1, 120 do x = List.smooth_step(x, 10, 1 / 60, 0.08) end
   t.eq(x, 10, "settles exactly on the target within two seconds")
   t.eq(List.smooth_step(9.995, 10, 0.016, 0.08), 10, "snaps when closer than 0.01 rows")
end)

function List.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return List
