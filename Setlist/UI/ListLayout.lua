-- @noindex
--[[
SiSt-Live Setlist: ListLayout

The sizes of the window for this frame, worked out in one place: whether the window is too small for the command bar,
the height of the list, how many rows are visible and how far the list may scroll. The results are the fields of
ViewState.lay (the sizes that depend on the zoom are set by List.apply_zoom).

  compute(win_w, win_h, min_w, min_h, line_height)    pure: small, panel_h, list_h, visible_rows
  update()                                             once per frame, after CommandArea.update(): fills ViewState.lay

Tests: Setlist/Tests/ListLayout_test.lua.
]]

local State = require("Setlist.State")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")

local lay, CFG = ViewState.lay, ViewState.CFG

local ListLayout = {}

--- Pure. Below the smallest size the command bar is usable in (a small docked window, or a floating one made small) the
--- list stays, the status line and command bar are left out (panel_h = 0), and a sign in the corner opens the commands as
--- a menu (CommandArea.draw_compact).
function ListLayout.compute(win_w, win_h, min_w, min_h, line_height)
   local small = win_w < min_w or win_h < min_h
   local panel_h = small and 0 or CFG.ctrl_panel_size
   local list_h = win_h - panel_h - CFG.title_height
   return {
      small = small,
      panel_h = panel_h,
      list_h = list_h,
      visible_rows = math.max(1, math.floor(list_h / line_height)),
   }
end

function ListLayout.update()
   local sizes = ListLayout.compute(gfx.w, gfx.h, lay.min_window_w, lay.min_window_h, lay.line_height)
   lay.small, lay.panel_h, lay.list_h, lay.visible_rows = sizes.small, sizes.panel_h, sizes.list_h, sizes.visible_rows
   lay.max_scroll = List.manual_max_scroll(State.list, lay.visible_rows)
   lay.follow_max_scroll = List.max_scroll(State.list, lay.visible_rows)
end

return ListLayout
