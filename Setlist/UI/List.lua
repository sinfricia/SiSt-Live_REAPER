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
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local ViewState = require("Setlist.UI.ViewState")

local gui, CFG, MODE = ViewState.gui, ViewState.CFG, ViewState.MODE
local ENTRY = Data.ENTRY

local TITLE = "Setlist"

local List = {}

local function clamp(val, min, max)
   return math.max(min, math.min(max, val))
end

function List.pad_number(numberStr, numDigits)
   local paddingLength = numDigits - #numberStr

   if paddingLength > 0 then
      numberStr = string.rep("0", paddingLength) .. numberStr
   end

   return numberStr
end

function List.mouse_in_rect(x, y, w, h)
   return gfx.mouse_x >= x and gfx.mouse_x <= x + w and gfx.mouse_y >= y and gfx.mouse_y <= y + h
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

   Theme.set_font(gui.entryTextSize)
   gui.lineHeight = gfx.texth + gui.linePadding
   log:debug("Zoom level is now " .. gui.zoomLevel)
end

-- Zoom one step in (+1) or out (-1). Alt resets the zoom.
-- Holding a zoom button repeats this (Widgets.button repeat_every), so there is no throttling here.
function List.zoom_step(step)
   if State.win.mouse.alt then List.apply_zoom(0) else List.apply_zoom(gui.zoomLevel + step) end
end

function List.entry_at_mouse(findAtLastClickPos)
   if not findAtLastClickPos then
      findAtLastClickPos = false
   end

   local mouseIsOverList = gfx.mouse_y < gui.listH + gui.titleHeight - gui.dragThreshold and
       gfx.mouse_y > gui.titleHeight and gfx.mouse_x < gfx.w - gui.scrollW and gfx.mouse_x > gui.leftBorder

   if not mouseIsOverList then
      return nil, nil
   end

   local entryUnderMouse = nil
   local idxUnderMouse = nil
   for i, _ in ipairs(State.list) do
      local yStart = gui.titleHeight + (i - 1) * gui.lineHeight
      local yEnd = yStart + gui.lineHeight

      if yEnd > gui.listH + gui.titleHeight then return nil, nil end -- only return entry if fully visible.

      local mouseIsOverEntry

      if findAtLastClickPos then
         mouseIsOverEntry = List.point_in_rect(0, yStart, gfx.w - gui.scrollW, gui.lineHeight,
            gui.lastClickDownPos.x, gui.lastClickDownPos.y)
      else
         mouseIsOverEntry = List.mouse_in_rect(0, yStart, gfx.w - gui.scrollW, gui.lineHeight)
      end

      if mouseIsOverEntry then
         idxUnderMouse = i + gui.scrollOffset
         entryUnderMouse = State.list[idxUnderMouse]
         break
      end
   end

   if not entryUnderMouse or idxUnderMouse > #State.list then
      return nil, nil
   end

   return entryUnderMouse, idxUnderMouse
end

-- Pure function. Returns the scroll offset (0-based, number of entries scrolled out at the top) that puts the
-- previous PROJECT entry in the top row, so the current project and every text entry between the two stay visible.
-- If there is no previous project the list starts at the top. Returns nil if currentListIdx isn't in the list.
function List.follow_scroll_offset(list, currentListIdx, maxScroll)
   if not currentListIdx or currentListIdx < 1 or currentListIdx > #list then return nil end

   local offset = 0
   for i = currentListIdx - 1, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         offset = i - 1
         break
      end
   end

   return clamp(offset, 0, maxScroll or offset)
end

-- Pure function. How far the list may scroll. Normally that's "last entry at the bottom", but to let the
-- previous project of the LAST project reach the top row the range is extended (the rows below stay empty).
-- A list that fits completely never scrolls.
function List.max_scroll(list, numVisibleEntries)
   local naturalMax = math.max(0, #list - numVisibleEntries)
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
   return math.max(0, #list - numVisibleEntries)
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
function List.offscreen_direction(listIdx, scrollOffset, numVisible)
   if not listIdx then return 0 end
   if listIdx <= scrollOffset then return -1 end
   if listIdx > scrollOffset + numVisible then return 1 end
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

   local dir = List.offscreen_direction(List.find_project_row(State.list, State.current_proj), gui.scrollOffset, gui.numVisibleEntries)
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
   local setlistLength = #State.list
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

   if gui.draggingEntry and entry.listIdx == gui.dragEntryListIdx and gui.dragThreshReached then
      highlight = gui.dragHighlight
   elseif entry.proj == State.current_proj and not gui.currProjDrawn then
      highlight = gui.activeProjHighlight
      gui.currProjDrawn = true
      gui.isNextProj = true
   elseif gui.isNextProj and entry.type == ENTRY.PROJECT then
      highlight = gui.nextProjHighlight
      gui.isNextProj = false
   end

   highlight = highlight or gui.entryHighlights[entry.type]

   if highlight then
      gfx.set(table.unpack(highlight))
      gfx.rect(gui.leftBorder, y + 2, gfx.w - gui.scrollW, gui.lineHeight - 4)
   end

   Theme.set("line")
   gfx.line(gui.leftBorder, y + gui.lineHeight, gfx.w - gui.scrollW, y + gui.lineHeight - 1)

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
      if entry.proj == State.current_proj then
         Theme.set("text")
         local radius = gui.leftBorder / 2
         gfx.circle(gui.leftBorder, y + (gui.lineHeight - radius * 2) / 2 + 1, radius, true, true)
      end


      -- (a tab closed a moment ago has a stale pointer until the list has followed the tabs)
      local playState = entry.proj and reaper.ValidatePtr(entry.proj, "ReaProject*") and reaper.GetPlayStateEx(entry.proj) or 0
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

         if playState == 1 then
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
      textAlpha = gui.textEntryAlpha
      entryStr = "--  " .. (entry.name or "")
   elseif entry.type == ENTRY.MISSING then
      textAlpha = gui.textEntryAlpha
      entryStr = "?  " .. (entry.name or "")
   end


   local _, strH = gfx.measurestr(entryStr)
   gfx.y = y + (gui.lineHeight - strH) / 2

   if textAlpha and entryStr then
      Theme.set("text", textAlpha)
      gfx.drawstr(entryStr)
   end

   ----------------------
   --Project Length Stuff
   if entry.type == ENTRY.PROJECT then
      if entry.name:find("_.*ROUTING") then return end

      -- proj length
      local projLen = Sync.project_length(entry.proj)

      local projLenStr = projLen > 0 and Data.format_time(projLen) or "--:--" -- no end marker: no length

      Theme.set_font(gui.projLenTextSize)
      local strW, strH = gfx.measurestr(projLenStr)
      gfx.x = gfx.w - gui.scrollW - strW - gui.entryIndent
      gfx.y = y + (gui.lineHeight - strH) / 2

      gfx.drawstr(projLenStr)
   end
end

function List.draw()
   gfx.clear = Theme.clear_color()

   -- Draw Entries. While a follow-scroll animates, gui.displayOffset is fractional: the rows are drawn shifted
   -- by the fraction and one extra row is drawn. The backgrounds painted below hide what sticks out.
   local offset = gui.displayOffset or gui.scrollOffset
   local firstIdx = math.floor(offset)
   local frac = offset - firstIdx
   local rows = gui.numVisibleEntries + (frac > 0 and 1 or 0)

   for i = 1, rows do
      local idx = i + firstIdx
      if idx > #State.list then break end
      if idx >= 1 then
         draw_entry(gui.titleHeight + (i - 1 - frac) * gui.lineHeight, State.list[idx])
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
         { size = Widgets.header_text_size(headerH), align = "center", color = "text" })
   else
      local title = State.name and ((State.modified and "*" or "") .. State.name) or TITLE
      Widgets.header(title, 3, 3, gfx.w - 6, headerH, "accent")
   end

   -- Status line under the list (what the list holds), a faint divider above it, the strong command bar divider below
   local projects = #Data.project_entries(State.list)
   local str = projects .. (projects == 1 and " project" or " projects") .. "  |  " ..
       Data.format_time(State.total_time) .. " total"
   Theme.set("line")
   gfx.rect(0, gfx.h - gui.ctrlPanelSize, gfx.w, 1)
   Theme.set_font(15)
   Theme.set("muted")
   gfx.x, gfx.y = gfx.w - 12 - gfx.measurestr(str), gfx.h - gui.ctrlPanelSize + 5
   gfx.drawstr(str)

   Theme.set("text", 0.6)
   gfx.rect(0, gfx.h - gui.ctrlPanelSize + gui.statusH, gfx.w, gui.dropIndicatorThickness - 2)

   -- Draw a line indicating where the project would be dropped if dragging

   if gui.draggingEntry and gui.dropIdx and gui.dragDirection then
      local isDragFarEnough = gui.dropIdx ~= gui.dragEntryListIdx and
          (gui.dropIdx > gui.dragEntryListIdx or gui.dropIdx < gui.dragEntryListIdx)

      if isDragFarEnough then
         local dropYstart

         if gui.dropIdx == 1 then
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset - 1) * gui.lineHeight
         elseif gui.dragDirection == 1 then
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset) * gui.lineHeight
         else
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset - 1) * gui.lineHeight
         end

         -- Draw drop indicator line as a rectangle
         Theme.set("text", 0.6)
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
   t.eq(List.follow_scroll_offset({ { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }, 2, 0), 0, "short list: maxScroll 0")
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
   t.eq(List.offscreen_direction(5, 5, 5), -1, "just above")
   t.eq(List.offscreen_direction(6, 5, 5), 0, "first visible row")
   t.eq(List.offscreen_direction(10, 5, 5), 0, "last visible row")
   t.eq(List.offscreen_direction(11, 5, 5), 1, "just below")
   t.eq(List.offscreen_direction(nil, 5, 5), 0, "unknown project: no arrow")
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
