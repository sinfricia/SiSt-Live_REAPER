-- @noindex
--[[
SiSt-Live Setlist: ViewState

How the list window looks (CFG: sizes, colors, timings) and what it is doing right now (gui: zoom, scrolling, dragging,
mouse and double-click tracking, the list mode). Reads of gui.<key> that are not set fall through to CFG.

  ViewState.gui, ViewState.CFG, ViewState.MODE ("show" / "edit"), ViewState.MOD (modifier key masks)
  to_list_mode(libMode, lib), set_mode(newMode), on_shared_mode_changed(new, old): follow the shared edit/show mode

Self test: ViewState.self_test() returns a list of { name, ok }.
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

--- GUI CONFIG ---
-- Constants only. Never written to at runtime. Reads of gui.<key> fall through to this table.
local CFG = {
   ctrlPanelSize = 112, -- status line + command area (statusH + cmdPad + headingH + buttonH + cmdPad)
   buttonFontSize = 17,
   statusH = 24,   -- status line right under the list
   cmdPad = 12,    -- space above the section names and below the buttons of the command area
   headingH = 24,  -- section names (20 px of text row, 4 px to the buttons)
   titleHeight = 56,
   leftBorder = 5,
   entryIndent = 7,      -- (leftBorder + entryIndent = 12: the margin of the rest of the window)
   rowMargin = 12,      -- the space right of a row's length (and of every other part of the window)


   -- Base sizes at zoom level 0. The zoomed values live in gui (see ApplyZoom).
   entryTextSize = 24,
   projLenTextSize = 16,
   linePadding = 18,

   minZoomLevel = -8,
   maxZoomLevel = 16,
   zoomDelay = 0.10, -- seconds between zoom steps while a zoom button is held

   activeProjHighlight = { 0.57, 0.97, 0.9, 0.7 },
   nextProjHighlight = { 0.25, 0.67, 0.6, 0.3 },
   dragHighlight = { 1, 0.8, 0.4, 0.7 },
   entryHighlights = {
      [ENTRY.MISSING] = { 1, 0, 0, 0.6 },    --red
      [ENTRY.TEXT] = { 1, 1, 1, 0.05 },      -- just a bit brighter than the background (coloured entries have their own)
      -- projects have no default highlight
   },
   textEntryAlpha = 0.9,                      -- text entries: theme text color, slightly faded
   textEntryScale = 0.8,                      -- text entries are written at this fraction of the project font size

   transportColors = {
      { 0.14, 0.99, 0.22, 1 }, --play
      {},
      {},
      {},
      { 0.89, 0.24, 0.23, 1 } -- record
   },
   playPosColor = { 0.95, 0.82, 0.45, 0.6 },

   dragThreshold = 6, -- pixels the mouse must move before a drag starts
   dropIndicatorThickness = 4,
   dragScrollMargin = 1, -- Margin in which list scrolls while dragging entry
   dragScrollSpeed = 0.3,

   scrollW = 20,

   doubleClickThreshold = 0.30,                 -- seconds between two clicks to qualify as double click


   smoothScrollTime = 0.08,                     -- time constant (seconds) of the animated follow-scroll. 0 = jump instantly

   offscreenIndicatorW = 44,                    -- arrow shown at the list edge when the current project is out of view
   offscreenIndicatorH = 18,
   offscreenIndicatorColor = { 0.57, 0.97, 0.9, 0.9 },

   buttonW = 140,
   buttonH = 40,
}

--- GUI STATE ---
-- Everything that changes at runtime. Missing keys are looked up in CFG.
local gui = setmetatable({
   -- Saved with the window (Window extra_keys, copied in OnWindowOpen / OnWindowClose)
   zoomLevel = 0,
   scrollOffset = 0,
   selection = {},      -- the selected entries (set: entry -> true), Ctrl+click / Shift+click
   selAnchor = nil,     -- the entry a Shift+click selects from (the last one clicked)

   -- Derived layout values (calculated in ApplyZoom, OnWindowOpen and Frame)
   lineHeight = 0,
   listH = 0,
   entryTextSize = CFG.entryTextSize,
   textEntrySize = math.floor(CFG.entryTextSize * 0.8 + 0.5),
   projLenTextSize = CFG.projLenTextSize,
   linePadding = CFG.linePadding,

   -- Mouse state
   leftClick = false,
   rightClick = false,
   prevLeftClick = false,
   prevRightClick = false,
   leftClickHandled = false,
   rightClickHandled = false,
   lastClickDownPos = { x = 0, y = 0 },

   -- Double-click tracking
   lastClickTime = 0,   -- timestamp of last click (reaper.time_precise)
   lastClickIdx = nil,  -- list index of last clicked entry
   doubleClick = false, -- true only on frame where second click detected

   -- Scrolling
   numVisibleEntries = 0,
   scrollH = 0,
   scrollY = 0,
   maxScroll = 0,       -- MANUAL range (wheel, scrollbar, drag): last entry at the bottom of the window
   followMaxScroll = 0, -- FOLLOW range (autoscroll): may leave empty rows at the end of the list
   scrollBarGrabStart = 0,
   scrollBarGrabOffset = 0,
   draggingScroll = false,
   fractionalScrollOffset = 0, --used for scrolling while dragging an entry to allow fractional scrolling speeds

   -- Drag & drop
   draggingEntry = false,
   dragEntryListIdx = 0,
   dropIdx = nil,
   dragDirection = 0,
   dragStartY = 0,
   dragThreshReached = nil,

   -- Follow-scroll (keeps the current project near the top of the list)
   mode = MODE.SHOW,         -- set from the shared Mode library (see OnSharedModeChanged).
   followPending = true,     -- true = scroll to the current project as soon as possible (also on startup)
   listClickTarget = nil,    -- project just selected by clicking it in the list (no follow in edit mode)
   displayOffset = nil,      -- drawn scroll position (may be fractional while animating). nil = not started yet
   lastAnimTime = nil,
   pressOnIndicator = false, -- the current mouse press started on the off-screen arrow (no drag from it)

   -- Drawing helpers
   isNextProj = false,    -- used to draw special highlight for project that comes after current in list
   currProjDrawn = false, --used to handle situations where the same project is open multiple times.
}, { __index = CFG })

ViewState.gui, ViewState.CFG, ViewState.MODE, ViewState.MOD = gui, CFG, MODE, MOD

-- The mode of the list ------------------------------------------------------------------------------------------

-- Pure function. Maps a value of the shared Mode library to MODE. Anything unknown gives nil.
-- lib: the library's constants ({ SHOW = ..., EDIT = ... }). Defaults to "show" / "edit".
function ViewState.to_list_mode(libMode, lib)
   lib = lib or { SHOW = "show", EDIT = "edit" }
   if libMode ~= nil and libMode == lib.SHOW then return MODE.SHOW end
   if libMode ~= nil and libMode == lib.EDIT then return MODE.EDIT end
   return nil
end

-- Applies a list mode. Switching to show mode jumps to the current project right away.
-- Returns true if the mode changed.
function ViewState.set_mode(newMode)
   if not newMode or newMode == gui.mode then return false end

   local oldMode = gui.mode
   gui.mode = newMode
   if newMode == MODE.SHOW then
      gui.followPending = true
   end
   log:info("list mode: %s -> %s", tostring(oldMode), newMode)
   return true
end

-- Callback for Mode.watch(): runs once at startup, then on every change of the shared mode.
function ViewState.on_shared_mode_changed(newLibMode, oldLibMode)
   local listMode = ViewState.to_list_mode(newLibMode, Mode)
   if not listMode then
      log:warn("unknown shared mode '%s', keeping %s", tostring(newLibMode), tostring(gui.mode))
      return
   end
   ViewState.set_mode(listMode)
end

-- Self test ---------------------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("ToListMode", function(t)
   t.eq(ViewState.to_list_mode(""), nil, "empty")
   t.eq(ViewState.to_list_mode("garbage"), nil, "garbage")
   t.eq(ViewState.to_list_mode(nil), nil, "nil")
   local lib = { SHOW = "live", EDIT = "prep" }
   t.eq(ViewState.to_list_mode("live", lib), MODE.SHOW, "uses the library's own values")
   t.eq(ViewState.to_list_mode("prep", lib), MODE.EDIT, "uses the library's own values (edit)")
   t.eq(ViewState.to_list_mode("show", lib), nil, "does not assume the default strings")
   t.eq(ViewState.to_list_mode(nil, {}), nil, "nil never matches a missing constant")
end)

define("SetListMode / OnSharedModeChanged", function(t)
   local savedMode, savedPending = gui.mode, gui.followPending

   gui.mode, gui.followPending = MODE.SHOW, false
   t.ok(ViewState.set_mode(MODE.EDIT), "show -> edit reports a change")
   t.eq(gui.followPending, false, "entering edit mode does not request a scroll")
   t.ok(not ViewState.set_mode(MODE.EDIT), "same mode again: no change")
   t.ok(not ViewState.set_mode(nil), "nil is ignored")
   t.eq(gui.mode, MODE.EDIT, "nil leaves the mode alone")
   t.ok(ViewState.set_mode(MODE.SHOW), "edit -> show reports a change")
   t.eq(gui.followPending, true, "back in show mode: jump to the current project")

   ViewState.on_shared_mode_changed(Mode.EDIT, nil)
   t.eq(gui.mode, MODE.EDIT, "callback: shared edit -> list edit")
   ViewState.on_shared_mode_changed("garbage", Mode.EDIT)
   t.eq(gui.mode, MODE.EDIT, "callback: unknown value keeps the current mode")
   ViewState.on_shared_mode_changed(Mode.SHOW, Mode.EDIT)
   t.eq(gui.mode, MODE.SHOW, "callback: shared show -> list show")

   gui.mode, gui.followPending = savedMode, savedPending
end)

function ViewState.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return ViewState
