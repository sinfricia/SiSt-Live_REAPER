-- @noindex
--[[
SiSt-Live Setlist: ViewState

How the list window looks (CFG: sizes, colors, timings) and what it is doing right now, in four groups: view (zoom,
scroll position, mode, selection), drag (dragging entries and the scrollbar), input (clicks and the text edit in
progress) and lay (this frame's sizes). The mouse itself is State.win.mouse (the Window keeps it).

  ViewState.view, .drag, .input, .lay, ViewState.CFG, ViewState.MODE ("show" / "edit"), ViewState.MOD (modifier key masks)
  to_list_mode(lib_mode, lib), set_mode(new_mode), on_shared_mode_changed(new, old): follow the shared edit/show mode

Tests: Setlist/Tests/ViewState_test.lua.
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Mode = require("SiSt-Live_Mode")
local Data = require("Setlist.Data")

local ViewState = {}

local ENTRY = Data.ENTRY

-- Operating modes, set from the shared SiSt-Live Mode library. Switching to SHOW jumps to the current project.
-- Following the current project on project changes happens in both modes.
local MODE = { SHOW = "show", EDIT = "edit" }

-- Keyboard modifier bit masks (same layout for gfx.mouse_cap and JS_Mouse_GetState)
local MOD = { CTRL = 4, SHIFT = 8, ALT = 16 }

--- CONFIG ---
-- Constants only, never written to at runtime. Read as CFG.<key>.
local CFG = {
   ctrl_panel_size = 112, -- status line + command area (status_h + cmd_pad + heading_h + button_h + cmd_pad)
   button_font_size = 17,
   status_h = 24,   -- status line right under the list
   cmd_pad = 12,    -- space above the section names and below the buttons of the command area
   heading_h = 24,  -- section names (20 px of text row, 4 px to the buttons)
   title_height = 56,
   left_border = 5,
   entry_indent = 7,      -- (left_border + entry_indent = 12: the margin of the rest of the window)
   row_margin = 12,      -- the space right of a row's length (and of every other part of the window)


   -- Base sizes at zoom level 0. The zoomed values are in lay (see List.apply_zoom).
   entry_text_size = 24,
   proj_len_text_size = 16,
   line_padding = 18,

   min_zoom_level = -9.6, -- 60% (entry size 14.4 of 24)
   max_zoom_level = 24,   -- 200%
   zoom_delay = 0.10, -- seconds between zoom steps while a zoom button is held

   active_proj_highlight = { 0.57, 0.97, 0.9, 0.7 },
   next_proj_highlight = { 0.25, 0.67, 0.6, 0.3 },
   drag_highlight = { 1, 0.8, 0.4, 0.7 },
   entry_highlights = {
      [ENTRY.MISSING] = { 1, 0, 0, 0.6 },    --red
      [ENTRY.TEXT] = { 1, 1, 1, 0.05 },      -- just a bit brighter than the background (coloured entries have their own)
      -- projects have no default highlight
   },
   text_entry_alpha = 0.9,                      -- text entries: theme text color, slightly faded
   text_entry_scale = 0.8,                      -- text entries are written at this fraction of the project font size

   transport_colors = {
      { 0.14, 0.99, 0.22, 1 }, --play
      {},
      {},
      {},
      { 0.89, 0.24, 0.23, 1 } -- record
   },
   play_pos_color = { 0.95, 0.82, 0.45, 0.6 },

   drag_threshold = 6, -- pixels the mouse must move before a drag starts
   drop_indicator_thickness = 4,
   drag_scroll_margin = 1, -- Margin in which list scrolls while dragging entry
   drag_scroll_speed = 0.3,

   scroll_w = 20,

   double_click_threshold = 0.30,                 -- seconds between two clicks to qualify as double click


   smooth_scroll_time = 0.08,                     -- time constant (seconds) of the animated follow-scroll. 0 = jump instantly

   offscreen_indicator_w = 44,                    -- arrow shown at the list edge when the current project is out of view
   offscreen_indicator_h = 18,
   offscreen_indicator_color = { 0.57, 0.97, 0.9, 0.9 },

   button_w = 140,
   button_h = 40,
}

--- STATE ---
-- What changes at runtime, in groups by what it is about. Nothing here is a layout number (that is lay) or the mouse
-- (that is State.win.mouse, kept by the Window).

-- The list as the user sees it: zoom, scroll position, mode, selection. zoom_level and scroll_offset are saved with the
-- window (see on_window_open / on_window_close in the Setlist script).
local view = {
   zoom_level = 0,
   scroll_offset = 0,
   display_offset = nil,   -- drawn scroll position (may be fractional while animating). nil = not started yet
   last_anim_time = nil,
   follow_pending = true,  -- true = scroll to the current project as soon as possible (also on startup)
   list_click_target = nil, -- project just selected by clicking it in the list (no follow in edit mode)
   mode = MODE.SHOW,       -- set from the shared Mode library (see on_shared_mode_changed)
   selection = {},         -- the selected entries (set: entry -> true), Ctrl+click / Shift+click
   sel_anchor = nil,       -- the entry a Shift+click selects from (the last one clicked)
}

-- A drag of one or more entries, and a drag of the scrollbar.
local drag = {
   active = false,          -- an entry is being dragged
   list_idx = 0,            -- list position of the dragged entry
   drop_idx = nil,          -- where it would be dropped
   direction = 0,           -- 1 = dragged down, -1 = dragged up
   start_y = 0,
   threshold_reached = nil, -- the mouse moved far enough for it to be a drag
   drop_hover = nil,        -- the entry the mouse is over
   drop_dir = nil,
   drop_link = nil,         -- Shift: the drop links the text entry
   group = nil,             -- the whole selection moves
   texts_only = nil,        -- only text entries are dragged (they can be linked)
   fractional_scroll = 0,   -- auto-scroll while dragging an entry (fractional speeds)
   scrolling = false,       -- the scrollbar thumb is dragged
   scrollbar_grab_start = 0,
   scrollbar_grab_offset = 0,
}

-- What a click or a text edit is in the middle of.
local input = {
   left_click_handled = false,
   right_click_handled = false,
   press_on_indicator = false, -- the current mouse press started on the off-screen arrow (no drag from it)
   last_click_time = 0,     -- timestamp of the last click on an entry (reaper.time_precise)
   last_click_idx = nil,    -- list index of that entry
   double_click = false,    -- true only on the frame where the second click was seen
   pending_clear = nil,     -- a plain press on a selected entry that waits to see whether it is a drag
   pending_mod = nil,       -- the same for a Ctrl / Shift press
   edit = nil,              -- the text entry being edited: { entry, is_new, field }
   edit_event = nil,        -- what the text field reported this frame
}

-- This frame's sizes, in pixels and rows. The zoomed sizes are set by List.apply_zoom, the rest once per frame by
-- ListLayout.update (so nothing else has to work them out).
local lay = {
   line_height = 0,
   text_line_step = nil,    -- the lines of a text entry are closer together than the rows of the list
   text_entry_size = math.floor(CFG.entry_text_size * 0.8 + 0.5),
   entry_text_size = CFG.entry_text_size,
   proj_len_text_size = CFG.proj_len_text_size,
   line_padding = CFG.line_padding,
   list_h = 0,
   panel_h = CFG.ctrl_panel_size, -- the height of the status line + command bar: 0 in a window that is too small for it
   small = false,           -- the window is smaller than the command bar can be used in (docked, or no js_ReaScriptAPI)
   min_window_w = nil,      -- the smallest size the command bar is usable in (CommandArea.update)
   min_window_h = nil,
   visible_rows = 0,
   max_scroll = 0,          -- MANUAL range (wheel, scrollbar, drag): last entry at the bottom of the window
   follow_max_scroll = 0,   -- FOLLOW range (autoscroll): may leave empty rows at the end of the list
   scroll_h = 0,            -- the scrollbar thumb (List.draw_scrollbar)
   scroll_y = 0,
   link_rows = nil,         -- entry -> link marks of this frame (Data.linked_rows)
   status_right_w = nil,    -- width of the counts on the right of the status line
}

ViewState.view, ViewState.drag, ViewState.input, ViewState.lay = view, drag, input, lay
ViewState.CFG, ViewState.MODE, ViewState.MOD = CFG, MODE, MOD

-- The mode of the list ------------------------------------------------------------------------------------------

-- Pure function. Maps a value of the shared Mode library to MODE. Anything unknown gives nil.
-- lib: the library's constants ({ SHOW = ..., EDIT = ... }). Defaults to "show" / "edit".
function ViewState.to_list_mode(lib_mode, lib)
   lib = lib or { SHOW = "show", EDIT = "edit" }
   if lib_mode ~= nil and lib_mode == lib.SHOW then return MODE.SHOW end
   if lib_mode ~= nil and lib_mode == lib.EDIT then return MODE.EDIT end
   return nil
end

-- Applies a list mode. Switching to show mode jumps to the current project right away.
-- Returns true if the mode changed.
function ViewState.set_mode(new_mode)
   if not new_mode or new_mode == view.mode then return false end

   local old_mode = view.mode
   view.mode = new_mode
   if new_mode == MODE.SHOW then
      view.follow_pending = true
   end
   log:info("list mode: %s -> %s", tostring(old_mode), new_mode)
   return true
end

-- Callback for Mode.watch(): runs once at startup, then on every change of the shared mode.
function ViewState.on_shared_mode_changed(new_lib_mode, old_lib_mode)
   local list_mode = ViewState.to_list_mode(new_lib_mode, Mode)
   if not list_mode then
      log:warn("unknown shared mode '%s', keeping %s", tostring(new_lib_mode), tostring(view.mode))
      return
   end
   ViewState.set_mode(list_mode)
end

return ViewState
