-- @noindex
-- Tests of Setlist/UI/List.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local Log = require("SiSt-Live_Log")
local Data = require("Setlist.Data")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")
local lay, CFG, MODE = ViewState.lay, ViewState.CFG, ViewState.MODE
local ENTRY = Data.ENTRY

local Tests = {}

-- Self test ---------------------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("Clamp / PadNumberStringWithZeroes", function(t)
   t.eq(List.pad_number("123", 2), "123", "never truncated")
end)

define("Zoom calculation", function(t)
   t.eq((List.compute_zoom(1000)), CFG.max_zoom_level, "clamped to max")
   t.eq((List.compute_zoom(-1000)), CFG.min_zoom_level, "clamped to min")
end)

define("GetFollowScrollOffset", function(t)
   -- 1:T0 2:P1 3:T1 4:T2 5:P2 6:P3 7:T3
   local list = {
      { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.TEXT },
      { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
   }
   t.eq(List.follow_scroll_offset(list, 2, 10), 0, "first project: nothing above it, start at the top")
   t.eq(List.follow_scroll_offset(list, 5, 10), 2,
      "the free text entries above the project are at the top, the previous project is not shown")
   t.eq(List.follow_scroll_offset(list, 6, 10), 5, "no text entries above: the project itself is in the top row")
   t.eq(List.follow_scroll_offset(list, 6, 3), 3, "clamped to max_scroll near the end of the list")
   t.eq(List.follow_scroll_offset({ { type = ENTRY.PROJECT }, { type = ENTRY.TEXT, link = "above" }, { type = ENTRY.TEXT },
      { type = ENTRY.TEXT, link = "below" }, { type = ENTRY.PROJECT } }, 5, 10), 2,
      "text entries linked to the project above stay out, the free one and the one linked below are shown")
   t.eq(List.follow_scroll_offset(list, 0, 10), nil, "idx 0 (tab not in list)")
   t.eq(List.follow_scroll_offset(list, 8, 10), nil, "idx past the end")
   t.eq(List.follow_scroll_offset({ { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }, 2, 0), 0,
      "short list: max_scroll 0")
end)

define("GetMaxScroll", function(t)
   local function projects(n)
      local l = {}
      for i = 1, n do l[i] = { type = ENTRY.PROJECT } end
      return l
   end
   t.eq(List.max_scroll(projects(5), 10), 0, "list that fits never scrolls")
   t.eq(List.max_scroll(projects(20), 9), 19, "20 projects: the last project (idx 20) can reach the top row")
   t.eq(List.max_scroll(projects(12), 10), 11, "list only 2 longer than the window still scrolls far enough")
   local with_texts = projects(3)
   for i = 4, 9 do with_texts[i] = { type = ENTRY.TEXT } end
   t.eq(List.max_scroll(with_texts, 4), 5, "trailing text entries: normal range is enough")
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
   local saved_step = lay.text_line_step
   lay.text_line_step = nil -- (no window: a line is a whole row)
   local list = { { type = ENTRY.PROJECT }, { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.TEXT, name = "x" },
      { type = ENTRY.TEXT, name = "1\n2\n3" }, { type = ENTRY.PROJECT } }
   t.eq({ List.entry_rows(list[1]), List.entry_rows(list[2]), List.entry_rows(list[4]) }, { 1, 2, 3 }, "rows per entry")
   t.eq({ List.layout(list) }, { { 0, 1, 3, 4, 7 }, 8 }, "where the entries start and the total")
   t.eq({ List.entry_at_row(list, 0), List.entry_at_row(list, 2), List.entry_at_row(list, 3), List.entry_at_row(list, 6),
      List.entry_at_row(list, 7), List.entry_at_row(list, 99) }, { 1, 2, 3, 4, 5, 5 }, "the entry at a row")
   t.eq(List.follow_scroll_offset({ { type = ENTRY.PROJECT }, { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.PROJECT },
      { type = ENTRY.PROJECT } }, 4, 100), 4, "follow-scroll counts rows: the last project starts at row 4")
   lay.text_line_step = saved_step
end)

define("Closer lines in text entries", function(t)
   local saved_step, saved_h = lay.text_line_step, lay.line_height
   lay.text_line_step, lay.line_height = 30, 50
   t.eq(List.entry_rows({ type = ENTRY.TEXT, name = "a" }), 1, "one line: one row")
   t.eq(List.entry_rows({ type = ENTRY.TEXT, name = "a\nb\nc" }), 1 + 2 * 0.6, "more lines: each adds 30/50 of a row")
   t.eq({ List.layout({ { type = ENTRY.TEXT, name = "a\nb" }, { type = ENTRY.PROJECT } }) }, { { 0, 1.6 }, 2.6 },
      "the next entry starts after the tall one")
   lay.text_line_step, lay.line_height = saved_step, saved_h
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

function Tests.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Tests
