-- @noindex
--[[
SiSt-Live Setlist: List

The list in the window: drawing it (rows, scrollbar, header, status line, the arrow that points to an off-screen
current project), finding the entry under the mouse, and the pure scroll and zoom math behind it. It only draws and
looks things up; changing the list is Actions.lua, reading gestures is ListInput.lua.

  draw()                                    the whole window except the command area
  entry_at_mouse(at_last_click_pos)            the entry under the mouse and its list position
  update_display_offset(snap), offscreen_indicator(), draw_scrollbar()
  compute_zoom(level), apply_zoom(level), zoom_step(step)
  follow_scroll_offset, max_scroll, manual_max_scroll, apply_manual_scroll, should_follow, find_project_row,
  offscreen_direction, smooth_step          pure scroll math (tested)
  pad_number, mouse_in_rect, point_in_rect  small helpers

Tests: Setlist/Tests/List_test.lua.
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

local view, drag, input, lay, CFG, MODE = ViewState.view, ViewState.drag, ViewState.input, ViewState.lay, ViewState.CFG, ViewState.MODE
local ENTRY = Data.ENTRY

-- Marks while the rows of one frame are drawn (List.draw resets them): the current project was drawn, and the entry
-- after it is the "next project".
local mark = { current_drawn = false, next_pending = false }

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
   Theme.set_font(lay.proj_len_text_size)
   local lw, lh = gfx.measurestr(chip.letter)
   local as = chip.arrow and math.max(3, math.floor(lh / 4)) or 0
   return 6 + (chip.arrow and (as * 2 + 4) or 0) + lw + 6
end

-- Draws the chip of a row (a down arrow and the letter); returns its left edge. right: where the chip ends.
local function draw_chip(chip, right, y)
   Theme.set_font(lay.proj_len_text_size) -- the size of the length next to it
   local lw, lh = gfx.measurestr(chip.letter or "M")
   local h = lh + 4
   local as = chip.arrow and math.max(3, math.floor(lh / 4)) or 0
   local w = 6 + (chip.arrow and (as * 2 + 4) or 0) + lw + 6
   local x, cy = right - w, y + math.floor((lay.line_height - h) / 2)
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

function List.pad_number(number_str, num_digits)
   local padding_length = num_digits - #number_str

   if padding_length > 0 then
      number_str = string.rep("0", padding_length) .. number_str
   end

   return number_str
end

function List.mouse_in_rect(x, y, w, h)
   return State.win.mouse.x >= x and State.win.mouse.x <= x + w and State.win.mouse.y >= y and State.win.mouse.y <= y + h
end

function List.point_in_rect(x, y, w, h, px, py)
   return px >= x and px <= x + w and py >= y and py <= y + h
end

-- Pure calculation: sizes for a zoom level, always derived from the base sizes in CFG.
-- Returns clamped_level, entry_text_size, proj_len_text_size, line_padding
function List.compute_zoom(level)
   level = clamp(level, CFG.min_zoom_level, CFG.max_zoom_level)
   return level,
       CFG.entry_text_size + level,
       CFG.proj_len_text_size + level / 2,
       CFG.line_padding + level * 2
end

function List.apply_zoom(level)
   view.zoom_level, lay.entry_text_size, lay.proj_len_text_size, lay.line_padding = List.compute_zoom(level)
   lay.text_entry_size = math.max(8, math.floor(lay.entry_text_size * CFG.text_entry_scale + 0.5))

   Theme.set_font(lay.entry_text_size)
   lay.line_height = gfx.texth + lay.line_padding
   -- the lines of a text entry are closer together than the rows of the list (the text stays together)
   Theme.set_font(lay.text_entry_size)
   lay.text_line_step = math.min(lay.line_height, math.floor(gfx.texth + math.max(2, lay.line_padding / 4)))
   Theme.set_font(lay.entry_text_size)
   log:debug("Zoom level is now " .. view.zoom_level)
end

-- Zoom one step in (+1) or out (-1). Alt resets the zoom.
-- Holding a zoom button repeats this (Widgets.button repeat_every), so there is no throttling here.
function List.zoom_step(step)
   if State.win.mouse.alt then List.apply_zoom(0) else List.apply_zoom(view.zoom_level + step) end
end

-- Rows -------------------------------------------------------------------------------------------------------------
-- The list is measured in rows (one row = lay.line_height): an entry is one row high, except a text entry with several
-- lines, which is as many rows high as it has lines. Scrolling, the scrollbar and the visible count are in rows.

--- Pure. Breaks the text into lines that are at most max_w wide (see Widgets.wrap_text).
List.wrap_text = Widgets.wrap_text

local number_cache = {}

--- The width of the number column: where a project has its number (and a text entry its "--"), the name starts after it.
function List.number_width()
   local digits = math.floor(math.log(math.max(State.tab_count or 1, 1), 10) + 1)
   local key = digits .. "|" .. lay.entry_text_size
   if number_cache.key ~= key then
      Theme.set_font(lay.entry_text_size)
      number_cache.key, number_cache.width = key, gfx.measurestr(string.rep("0", digits) .. ". ")
   end
   return number_cache.width
end

--- How far a text entry is indented: a linked one starts where the project names start, so its "--" is lined up with them.
function List.link_indent(entry)
   if entry.type == ENTRY.TEXT and lay.link_rows and lay.link_rows[entry] then return List.number_width() end
   return 0
end

--- The height of a text entry's extra lines as a fraction of a row (they are closer together than rows).
function List.row_gap()
   if lay.text_line_step and lay.line_height and lay.line_height > 0 then return lay.text_line_step / lay.line_height end
   return 1
end

local wrap_cache = setmetatable({}, { __mode = "k" }) -- text entry -> { key, lines }

--- What a text entry shows: its lines (wrapped to the window) and the width of the number column (where a project has its
--- number, a text entry has "--"; its text starts after it). Wrapping needs the window: with none (w = 0) only the line
--- breaks of the text count.
function List.text_lines(entry)
   local name = entry.name or ""
   if gfx.w == nil or gfx.w <= 0 or lay.small then return List.wrap_text(name, math.huge, function() return 0 end), 0 end

   local num_w = List.number_width()
   local indent = List.link_indent(entry)
   local key = table.concat({ name, tostring(lay.small), gfx.w, CFG.scroll_w, lay.entry_text_size, lay.text_entry_size, num_w, indent }, "|")
   local c = wrap_cache[entry]
   if c and c.key == key then return c.lines, num_w end

   Theme.set_font(lay.text_entry_size)
   local avail = gfx.w - CFG.scroll_w - (CFG.left_border + CFG.entry_indent + indent) - num_w - 12
   local lines = List.wrap_text(name, math.max(avail, 20), function(s) return (gfx.measurestr(s)) end)
   wrap_cache[entry] = { key = key, lines = lines }
   return lines, num_w
end

--- How many rows high an entry is.
function List.entry_rows(entry)
   if type(entry) == "table" and entry.type == ENTRY.TEXT and entry.name then
      local n
      if input.edit and input.edit.entry == entry then -- the entry grows while it is edited: the lines the field drew last
         local lines = input.edit.field.vlines
         if lines then
            n = #lines
         else
            local _, breaks = input.edit.field.text:gsub("\n", "")
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

function List.entry_at_mouse(find_at_last_click_pos)
   if not find_at_last_click_pos then
      find_at_last_click_pos = false
   end

   local mouse_is_over_list = State.win.mouse.y < lay.list_h + CFG.title_height - CFG.drag_threshold and
       State.win.mouse.y > CFG.title_height and State.win.mouse.x < gfx.w - CFG.scroll_w and State.win.mouse.x > CFG.left_border

   if not mouse_is_over_list then
      return nil, nil
   end

   local starts = List.layout(State.list)
   for i, entry in ipairs(State.list) do
      local h = List.entry_rows(entry) * lay.line_height
      local y_start = CFG.title_height + (starts[i] - view.scroll_offset) * lay.line_height
      local y_end = y_start + h

      if y_end > CFG.title_height then -- (not scrolled out at the top)
         if y_end > lay.list_h + CFG.title_height then return nil, nil end -- only return entry if fully visible.

         local mouse_is_over_entry
         if find_at_last_click_pos then
            mouse_is_over_entry = List.point_in_rect(0, y_start, gfx.w - CFG.scroll_w, h,
               State.win.mouse.press_x, State.win.mouse.press_y)
         else
            mouse_is_over_entry = List.mouse_in_rect(0, y_start, gfx.w - CFG.scroll_w, h)
         end

         if mouse_is_over_entry then return entry, i end
      end
   end

   return nil, nil
end

-- Pure function. Returns the scroll offset (0-based, in rows scrolled out at the top) for the current project: the top row
-- is the first of the text entries right above it that do not belong to the project before (link "above"), or the project
-- itself when there are none. The previous project is not shown. Returns nil if current_list_idx isn't in the list.
function List.follow_scroll_offset(list, current_list_idx, max_scroll)
   if not current_list_idx or current_list_idx < 1 or current_list_idx > #list then return nil end

   local starts = List.layout(list)
   local first = current_list_idx
   for i = current_list_idx - 1, 1, -1 do
      if list[i].type ~= ENTRY.TEXT or list[i].link == "above" then break end
      first = i
   end
   local offset = starts[first]

   return clamp(offset, 0, max_scroll or offset)
end

-- Pure function. How far the list may scroll. Normally that's "last entry at the bottom", but to let
-- the top row of the LAST project (its text entries above it) reach the top the range is extended (the rows below stay empty).
-- A list that fits completely never scrolls.
function List.max_scroll(list, num_visible_entries)
   local _, total_rows = List.layout(list)
   local natural_max = math.max(0, total_rows - num_visible_entries)
   if natural_max == 0 then return 0 end

   for i = #list, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         return math.max(natural_max, List.follow_scroll_offset(list, i) or 0) -- no max_scroll given: unclamped
      end
   end
   return natural_max
end

-- Pure function. The range for manual scrolling (wheel, scrollbar, dragging): the last entry may reach the
-- bottom of the window, but there is never an empty row below it.
function List.manual_max_scroll(list, num_visible_entries)
   local _, total_rows = List.layout(list)
   return math.max(0, total_rows - num_visible_entries)
end

-- Pure function. Scrolls by delta rows (positive = down) in the manual range.
-- Smooth after a follow-scroll: if the view currently shows empty rows beyond the manual range, scrolling up
-- moves it from where it is (it does not snap back first), and scrolling down simply stays where it is.
function List.apply_manual_scroll(offset, delta, manual_max)
   local upper_limit = math.max(manual_max, offset)
   return clamp(offset + delta, 0, upper_limit)
end

-- Pure function. Should a change of the current project scroll the list? Always, except when the project was
-- selected by clicking it in the list while in edit mode: the list must not move away from where you work.
function List.should_follow(mode, changed_from_list)
   return not (mode == MODE.EDIT and changed_from_list)
end

-- Pure function. List index of the first project entry for proj, or nil.
function List.find_project_row(list, proj)
   if not proj then return nil end
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT and entry.proj == proj then return i end
   end
   return nil
end

-- Pure function. Where the entry at list_idx is relative to the visible rows:
-- -1 = scrolled out at the top, 1 = below the visible rows, 0 = visible (or list_idx unknown).
function List.offscreen_direction(list, list_idx, scrollOffset, num_visible)
   if not list_idx then return 0 end
   local starts = List.layout(list)
   local first = starts[list_idx]
   if not first then return 0 end
   if first + List.entry_rows(list[list_idx]) <= scrollOffset then return -1 end
   if first >= scrollOffset + num_visible then return 1 end
   return 0
end

-- Pure function. One animation step of the drawn scroll position towards the target (exponential ease-out).
-- No current value or time_constant <= 0 jumps straight to the target. Snaps once closer than 0.01 rows.
function List.smooth_step(current, target, dt, time_constant)
   if current == nil or not time_constant or time_constant <= 0 then return target end
   if dt <= 0 then return current end

   local new = current + (target - current) * (1 - math.exp(-dt / time_constant))
   if math.abs(target - new) < 0.01 then return target end
   return new
end

-- Moves the drawn scroll position towards view.scroll_offset. snap = true ends any animation at once
-- (used whenever the user scrolls, clicks or drags, so what is drawn is always what the mouse hits).
function List.update_display_offset(snap)
   local now = reaper.time_precise()
   local dt = math.min(now - (view.last_anim_time or now), 0.1) -- a stalled frame doesn't skip the animation
   view.last_anim_time = now

   if snap then
      view.display_offset = view.scroll_offset
   else
      view.display_offset = List.smooth_step(view.display_offset, view.scroll_offset, dt, CFG.smooth_scroll_time)
   end
end

-- Draws an arrow at the top or bottom edge of the list when the current project is out of view.
-- Clicking it jumps back to the current project (in both modes).
function List.offscreen_indicator()
   if drag.active then return end

   local dir = List.offscreen_direction(State.list, List.find_project_row(State.list, State.current_proj),
      view.scroll_offset, lay.visible_rows)
   if dir == 0 then return end

   local w, h = CFG.offscreen_indicator_w, CFG.offscreen_indicator_h
   local x = math.floor((gfx.w - CFG.scroll_w - w) / 2)
   local list_bottom = CFG.title_height + lay.list_h -- (the list reaches the panel; a last row may be cut)
   local y = dir < 0 and CFG.title_height + 2 or list_bottom - h - 2

   gfx.set(table.unpack(CFG.offscreen_indicator_color))
   gfx.rect(x, y, w, h, true)

   local cx, tri_w, tri_h = x + w / 2, h * 0.9, h * 0.5
   local top = y + (h - tri_h) / 2
   gfx.set(0, 0, 0, 0.8)
   if dir < 0 then
      gfx.triangle(cx - tri_w / 2, top + tri_h, cx + tri_w / 2, top + tri_h, cx, top)
   else
      gfx.triangle(cx - tri_w / 2, top, cx + tri_w / 2, top, cx, top + tri_h)
   end

   local pressed_now = State.win.mouse.left_pressed
   if pressed_now and not input.left_click_handled
       and List.point_in_rect(x, y, w, h, State.win.mouse.press_x, State.win.mouse.press_y) then
      input.left_click_handled = true -- the entry under the arrow is not selected
      input.press_on_indicator = true -- and not dragged
      view.follow_pending = true    -- the jump happens when the mouse is released
      log:debug("Off-screen arrow clicked: jumping to the current project")
   end
end

function List.draw_scrollbar()
   local _, setlist_length = List.layout(State.list) -- rows
   if setlist_length <= lay.visible_rows then return end

   local scroll_track_height = lay.list_h + CFG.title_height
   lay.scroll_h = scroll_track_height * (lay.visible_rows / setlist_length)
   local offset = view.display_offset or view.scroll_offset
   lay.scroll_y = clamp(offset / math.max(lay.max_scroll, 1), 0, 1) * (scroll_track_height - lay.scroll_h)

   -- Scroll Track
   Theme.set("button")
   gfx.rect(gfx.w - CFG.scroll_w, 0, CFG.scroll_w, scroll_track_height)

   -- Scroll Thumb
   Theme.set("muted")
   gfx.rect(gfx.w - CFG.scroll_w + 2, lay.scroll_y, CFG.scroll_w - 4, lay.scroll_h)

   return lay.scroll_y, lay.scroll_h
end

-- next_entry: the entry below this one (nil for the last): the divider under a linked text entry that is followed by another
-- one starts at the same indent, so the linked entries stay together.
local function draw_entry(y, entry, next_entry)
   if not entry or not y then return end
   local highlight = entry.highlight
   local h = List.entry_rows(entry) * lay.line_height -- (a text entry with several lines is several rows high)
   local indent = List.link_indent(entry)

   -- the current project and the one after it are found whatever else the row is (a dragged current project must not
   -- lose the "next project" mark of the entry after it)
   local is_current, is_next = false, false
   if entry.proj ~= nil and entry.proj == State.current_proj and not mark.current_drawn then
      is_current = true
      mark.current_drawn = true
      mark.next_pending = true
   elseif mark.next_pending and entry.type == ENTRY.PROJECT then
      is_next = true
      mark.next_pending = false
   end

   if drag.active and drag.threshold_reached and
       (entry.list_idx == drag.list_idx or (drag.group and view.selection[entry])) then
      highlight = CFG.drag_highlight
   elseif is_current then
      highlight = CFG.active_proj_highlight
   elseif is_next then
      highlight = CFG.next_proj_highlight
   end

   highlight = highlight or CFG.entry_highlights[entry.type]

   if highlight then
      gfx.set(table.unpack(highlight))
      gfx.rect(CFG.left_border + indent, y + 2, gfx.w - CFG.scroll_w - indent, h - 4)
   end

   if view.selection[entry] then -- selected: a tint and a border in the accent colour
      Theme.set("accent", 0.2)
      gfx.rect(CFG.left_border + indent, y + 2, gfx.w - CFG.scroll_w - indent, h - 4)
      Theme.set("accent", 0.9)
      gfx.rect(CFG.left_border + indent, y + 2, gfx.w - CFG.scroll_w - indent, h - 4, false)
   end

   Theme.set("line")
   local divider_x = CFG.left_border
   if indent > 0 and next_entry and List.link_indent(next_entry) > 0 then divider_x = CFG.left_border + indent end
   gfx.line(divider_x, y + h, gfx.w - CFG.scroll_w, y + h - 1)

   -- a line at the left edge joins a project with the text entries linked to it; at the first and the last entry of the
   -- group it turns into a hook towards the entry (the linked text entries are indented, the hook reaches their edge)
   local link = lay.link_rows and lay.link_rows[entry]
   if link then
      Theme.set("accent", 0.9)
      local mid = y + h / 2
      local top = link.first and mid - 1 or y
      local bottom = link.last and mid + 1 or y + h
      gfx.rect(1, top, 2, bottom - top)
      if link.first or link.last then
         local reach = entry.type == ENTRY.TEXT and (CFG.left_border + indent - 3) or 9
         gfx.rect(1, mid - 1, math.max(4, reach - 1), 2)
      end
   end

   -- The marks at the left, over the link line: the white dot of the active project; with a selection it is the selected
   -- entries that are marked (a square in the colour of the border, white for the active project), the active project
   -- keeps no dot then
   do
      local radius = CFG.left_border / 2
      -- centred on the left edge of the entry (after its indent), where the dot of the active project always was
      local cx = CFG.left_border + indent
      local cy = y + h / 2 -- the vertical middle of the entry: where the link hook touches it
      local active = entry.proj ~= nil and entry.proj == State.current_proj
      if view.selection[entry] then
         if active then Theme.set("text") else Theme.set("accent") end
         local size = CFG.left_border + 1
         gfx.rect(math.floor(cx - size / 2), math.floor(cy - size / 2), size, size)
      elseif active and next(view.selection) == nil then
         Theme.set("text")
         gfx.circle(cx, cy, radius, true, true)
      end
   end

   -- what the song's markers say (the chips before the length: end handler, loop regions)
   local info =entry.type == ENTRY.PROJECT and not entry.name:find("_.*ROUTING") and entry.path ~= "Unsaved Project"
       and ProjectInfo.read(entry.proj) or nil

   -------------------
   -- draw entry text
   local text_alpha -- text uses the theme's text color, nil = not drawn
   local entry_str
   gfx.x = CFG.left_border + CFG.entry_indent
   Theme.set_font(lay.entry_text_size)
   if entry.type == ENTRY.PROJECT then
      text_alpha = 1
      local display_idx = tostring(entry.tab_idx or entry.list_idx)
      display_idx = List.pad_number(display_idx, math.floor(math.log(State.tab_count, 10) + 1)) .. ". "

      --draw selected project indicator


      -- (a tab closed a moment ago has a stale pointer until the list has followed the tabs)
      local play_state = entry.proj and reaper.ValidatePtr(entry.proj, "ReaProject*") and
      reaper.GetPlayStateEx(entry.proj) or 0
      if play_state > 0 then
         -- draw pos indicator
         local proj_len = Sync.project_length(entry.proj)

         if proj_len > 0 then -- no end marker = no length: no position to show
            local play_pos = reaper.GetPlayPositionEx(entry.proj)
            local r, g, b, a = table.unpack(CFG.play_pos_color)
            gfx.set(r, g, b, a)

            local x = (gfx.w - CFG.scroll_w - CFG.entry_indent) * play_pos / proj_len + 5
            gfx.rect(x, y, CFG.left_border, lay.line_height)

            a = 0.2
            gfx.set(r, g, b, a)

            gfx.rect(CFG.left_border, y, x, lay.line_height)
         end


         -- draw project playstate indicator
         local display_idx_width = gfx.measurestr(display_idx)

         local pass, passes, stopped = ProjectInfo.loop_pass(entry.proj)
         if pass and (play_state == 1 or play_state == 5) then
            -- looping: "L2" in place of the symbol, yellow when playing (red when recording); "L3→" once the loop was
            -- stopped (the song moves on after this pass). The title starts after it, so a long label pushes it right.
            local x0 = CFG.left_border + CFG.entry_indent
            local label = stopped and "L →" or ("L" .. pass)
            local color = play_state == 5 and CFG.transport_colors[5] or { 1.0, 0.82, 0.05, 1 }
            gfx.set(table.unpack(color))
            local label_w, label_h = gfx.measurestr(label)
            gfx.x, gfx.y = x0, y + (lay.line_height - label_h) / 2
            gfx.drawstr(label)
            gfx.x = x0 + math.max(display_idx_width, label_w + 8)
            display_idx = ""
         elseif play_state == 1 then
            gfx.x = gfx.x + display_idx_width
            display_idx = ""
            gfx.set(table.unpack(CFG.transport_colors[play_state]))

            local triangle_h = lay.line_height * 0.5
            local triangle_w = clamp(triangle_h * 0.8, 0, display_idx_width * 0.8)

            local icon_lrpadding = (display_idx_width - triangle_w) / 2 - 5
            local icon_top_padding = (lay.line_height - triangle_h) / 2
            gfx.triangle(
               CFG.left_border + CFG.entry_indent + triangle_w, y + lay.line_height / 2,
               CFG.left_border + CFG.entry_indent + icon_lrpadding, y + icon_top_padding,
               CFG.left_border + CFG.entry_indent + icon_lrpadding, y + icon_top_padding + triangle_h)
         elseif play_state == 5 then
            gfx.x = gfx.x + display_idx_width
            display_idx = ""

            local icon_radius = clamp(lay.line_height * 0.5 / 2 - 2, 0, display_idx_width / 2 * 0.8)

            gfx.set(table.unpack(CFG.transport_colors[play_state]))
            gfx.circle(CFG.left_border + CFG.entry_indent + icon_radius, y + lay.line_height / 2, icon_radius, true,
               true)
         end
      end
      entry_str = display_idx .. (entry.name or "")
   elseif entry.type == ENTRY.TEXT then
      -- "--" where a project has its number, the text (a bit smaller) where the project names start, one row per line
      local x0 = CFG.left_border + CFG.entry_indent + indent
      local lines, num_w = List.text_lines(entry)
      local editing = input.edit and input.edit.entry == entry
      if num_w == 0 then
         Theme.set_font(lay.entry_text_size)
         num_w = gfx.measurestr("00. ")
      end
      Theme.set_font(lay.text_entry_size)
      Theme.set("text", CFG.text_entry_alpha)
      local _, line_h = gfx.measurestr("Ag")
      local step = lay.text_line_step or lay.line_height
      local top = (lay.line_height - step) / 2 -- the lines are a block, centred in the entry
      gfx.x, gfx.y = x0, y + top + (step - line_h) / 2
      gfx.drawstr("--")
      if editing then
         -- being edited: the text is a text field (ListInput.handle_edit acts on what happened)
         input.edit_event = TextField.draw(State.win, input.edit.field, x0 + num_w - TextField.PAD, y + 1,
            gfx.w - CFG.scroll_w - (x0 + num_w) + TextField.PAD - 4, h - 2,
            { size = lay.text_entry_size, line_h = step, top_pad = top - 1 })
      else
         for k, line in ipairs(lines) do
            gfx.x, gfx.y = x0 + num_w, y + top + (k - 1) * step + (step - line_h) / 2
            if lay.small then -- (no wrapping in a small window: a line that is too long gets "...")
               line = Widgets.fit_text(line, gfx.w - CFG.scroll_w - (x0 + num_w) - CFG.row_margin, function(s) return (gfx.measurestr(s)) end)
            end
            gfx.drawstr(line)
         end
      end
      Theme.set_font(lay.entry_text_size)
      entry_str = ""
   elseif entry.type == ENTRY.MISSING then
      text_alpha = CFG.text_entry_alpha
      entry_str = "?  " .. (entry.name or "")
   end


   -- The right part of a project row (length, chips) is drawn first: the name gives way to it. In a narrow window the
   -- chips go first, then the length, so that at least about five characters of the name stay.
   local name_x = gfx.x
   local name_right = gfx.w - CFG.scroll_w - CFG.row_margin
   if entry.type == ENTRY.PROJECT and not entry.name:find("_.*ROUTING") then
      local min_name = lay.entry_text_size * (lay.small and 12 or 5) -- (small window: the length goes sooner)
      local proj_len = Sync.project_length(entry.proj)
      local proj_len_str = proj_len > 0 and Data.format_time(proj_len) or "--:--" -- no end marker: no length

      Theme.set_font(lay.proj_len_text_size)
      local str_w, str_h = gfx.measurestr(proj_len_str)
      local length_x = name_right - str_w
      if length_x - name_x >= min_name then
         gfx.x, gfx.y = length_x, y + (lay.line_height - str_h) / 2
         Theme.set("text") -- (not the colour of what was drawn before, e.g. the transport state)
         gfx.drawstr(proj_len_str)
         name_right = length_x - 10

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

   if text_alpha and entry_str ~= "" then
      Theme.set_font(lay.entry_text_size)
      entry_str = Widgets.fit_text(entry_str, name_right - name_x, function(s) return (gfx.measurestr(s)) end)
      local _, str_h = gfx.measurestr(entry_str)
      gfx.x, gfx.y = name_x, y + (lay.line_height - str_h) / 2
      Theme.set("text", text_alpha)
      gfx.drawstr(entry_str)
   end
end

function List.draw()
   gfx.clear = Theme.clear_color()

   -- Draw Entries. While a follow-scroll animates, view.display_offset is fractional: the rows are drawn shifted
   -- by the fraction and one extra row is drawn. The backgrounds painted below hide what sticks out.
   local offset = view.display_offset or view.scroll_offset
   local starts = List.layout(State.list)

   lay.link_rows = Data.linked_rows(State.list)
   for i, entry in ipairs(State.list) do
      -- (the entries that are at least partly in the view, plus one row below)
      if starts[i] + List.entry_rows(entry) > offset and starts[i] <= offset + lay.visible_rows then
         draw_entry(CFG.title_height + (starts[i] - offset) * lay.line_height, entry, State.list[i + 1])
      end
   end

   mark.next_pending = false
   mark.current_drawn = false

   Theme.set("background")
   gfx.rect(0, 0, gfx.w, CFG.title_height)
   gfx.rect(0, gfx.h - lay.panel_h, gfx.w, lay.panel_h)

   -- Draw Title: the shared SiSt-Live header (teal, fixed size: CFG.title_height - 12 = Widgets.HEADER_H)
   local header_h = CFG.title_height - 12
   if State.job then
      -- loading: the header fills while the projects open
      Widgets.header("", 3, 3, gfx.w - 6, header_h, "accent")
      Widgets.box(3, 3, math.floor((gfx.w - 6) * State.job.done / math.max(1, State.job.total)), header_h, "accent", 0.6)
      Widgets.text(string.format("Loading %d / %d", State.job.done, State.job.total), 3, 3, gfx.w - 6, header_h,
         { size = Widgets.header_text_size(header_h), align = "center", color = "text", face = Theme.TITLE_FACE })
   else
      local title = State.name and ((State.modified and "*" or "") .. State.name) or TITLE
      Widgets.header(title, 3, 3, gfx.w - 6, header_h, "accent")
   end

   -- Status line under the list (what the list holds), a faint divider above it, the strong command bar divider below
   -- (not in a window that is too small for the panel: lay.panel_h is 0 then and the list takes the room)
   if lay.panel_h > 0 then
   local projects = #Data.project_entries(State.list)
   local time = Data.format_time(State.total_time)
   local noun = projects .. (projects == 1 and " project" or " projects")
   Theme.set("line")
   gfx.rect(0, gfx.h - CFG.ctrl_panel_size, gfx.w, 1)
   Theme.set_font(15)
   Theme.set("muted")
   -- the long form, then shorter ones: at most half the window, the left part (chips) gets the rest
   local function measure(s) return (gfx.measurestr(s)) end
   local str = Layout.pick({ noun .. "  |  " .. time .. " total", noun .. "  |  " .. time, projects .. "  |  " .. time, time },
      math.floor(gfx.w / 2) - CFG.row_margin, measure)
   lay.status_right_w = measure(str)
   gfx.x, gfx.y = gfx.w - CFG.row_margin - lay.status_right_w, gfx.h - CFG.ctrl_panel_size + 5
   gfx.drawstr(str)

   Theme.set("text", 0.6)
   gfx.rect(0, gfx.h - CFG.ctrl_panel_size + CFG.status_h, gfx.w, CFG.drop_indicator_thickness - 2)
   end

   -- Draw a line indicating where the project would be dropped if dragging

   if drag.active and drag.drop_idx and (drag.drop_dir or drag.direction) then
      -- (a linking drop (Shift) onto the neighbour shows the line too, although the entry stays where it is)
      local is_drag_far_enough = drag.drop_idx ~= drag.list_idx or drag.drop_link

      if is_drag_far_enough then
         -- at the end of the entry it is dropped after (dragged down), at the start of the one it is dropped before
         local starts = List.layout(State.list)
         local row = starts[drag.drop_idx] or 0
         if (drag.drop_dir or drag.direction) == 1 and drag.drop_idx > 1 then row = row + List.entry_rows(State.list[drag.drop_idx]) end
         local drop_ystart = CFG.title_height + (row - view.scroll_offset) * lay.line_height

         -- Draw drop indicator line as a rectangle (in the colour of the link line when the drop will link)
         if drag.drop_link then Theme.set("accent", 0.95) else Theme.set("text", 0.6) end
         gfx.rect(5, drop_ystart - 2, gfx.w - 10, CFG.drop_indicator_thickness)
      end
   end
end

return List
