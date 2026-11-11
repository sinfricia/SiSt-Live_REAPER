-- @noindex
-- SiSt-Live Setlist. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   # SiSt-Live Setlist
--   A Tool to manage REAPER project tabs. Designed to be used as a setlist manager in a live environment.
--
--   Logging: the shared SiSt-Live log (lib/SiSt-Live_Log.lua), component "Setlist". Debug lines appear
--   while "DEBUG Toggle Logging" is on. Warnings always go to <resource path>/Data/SiSt-Live/SiSt-Live.log,
--   and to the console too, except in show mode.
--
--   Current list and autosave (both in <resource path>/Data): the current list (SiSt-Live_Setlist_current.rsl) is the
--   live state, written after every change; closing and reopening the Setlist within a REAPER run keeps it. The first
--   start in a new REAPER run starts from the open projects. Every time the whole list is replaced (that start,
--   Reset, Restore, Load Setlist) the old list is kept as the autosave (SiSt-Live_Setlist_autosave.rsl), and
--   "Restore" brings it back (it swaps, so a second press goes back).
--
--   Below the list: a status line (number of projects, total time) and the command area, groups of buttons (LIST,
--   INSERT, ZOOM) with a divider between them.
--
--   Window: right-click on an entry for the entry's menu, anywhere else for the window menu (docking and the
--   default position). The window remembers its position per edit/show mode: put it where you want it in
--   each mode once. "Save as default position" stores a position you can always go back to.
--
--   Libraries: the lib folder of the package (Scripts/SiSt-Live/lib), put on the module path by the first line below.
--   Setup and the self-test check that all of them are there.
--
--   Edit/show mode: the list follows the current project in both modes, except when you click a project in the
--   list in edit mode. Switching to show mode also jumps to it. Nothing is locked in either mode;
--   destructive actions (removing entries, closing projects, Reset, loading) always ask for confirmation. An arrow at the list edge
--   points to the current project when it is out of view.
--
--   Parts (all in Setlist/): Data.lua (entries, text format, files), Sync.lua (REAPER's project tabs), Actions.lua (what
--   the user can do to the list), State.lua (what the parts share), UI/ (ViewState, List, ListInput, CommandArea, Ask).
--   This script is the glue: Init, and Frame once per frame.

local scriptDir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = scriptDir .. "../lib/?.lua;" .. scriptDir .. "../?.lua;" .. package.path -- the package's lib folder, and Setlist.* modules

-- Shared SiSt-Live libraries (part of the package: Setup and the self-test check that they are all there)
local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Theme, Window, Widgets = require("Gui.Theme"), require("Gui.Window"), require("Gui.Widgets")
local Mode = require("SiSt-Live_Mode")

local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local ProjectInfo = require("Setlist.ProjectInfo")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")
local ListInput = require("Setlist.UI.ListInput")
local CommandArea = require("Setlist.UI.CommandArea")
local Ask = require("Setlist.UI.Ask")
local DuplicateWarning = require("Setlist.UI.DuplicateWarning")

local gui = ViewState.gui

local WINDOW_TITLE = "SiSt-Live Setlist"

local pollMode = nil -- returned by Mode.watch() in Init; call once per frame to pick up mode changes

--------------------------
------- MAIN FLOW --------
--------------------------

local function check_dependencies()
   if reaper.APIExists('JS_Dialog_BrowseForOpenFiles') then return true end

   local ret = reaper.MB(
      "This script requires the JS_ReaScriptAPI extension.\n\nClick OK to open ReaPack and install it, then restart the script.",
      "Missing dependency", 1)

   if ret == 1 then
      if reaper.APIExists('ReaPack_BrowsePackages') then
         reaper.ReaPack_BrowsePackages('js_ReaScriptAPI: API functions for ReaScripts')
      else
         reaper.MB(
            "Couldn't find ReaPack. Visit https://reapack.com/ for installation instructions, or get JS_ReaScriptAPI from https://forum.cockos.com/showthread.php?t=212174",
            "ReaPack missing", 0)
      end
   end

   return false
end

-- True while REAPER renders. REAPER then has an extra instance of the project being rendered, which the project
-- check below would take for a project that is open twice ("DUPLICATE PROJECTS FOUND" during a render).
-- Same check as in Region Looping (defered).lua; becomes a shared helper in step 7.
local function is_rendering()
   return reaper.EnumProjects(0x40000000) ~= nil
end

local wasRendering = false

-- Window callbacks (see lib/Gui/Window.lua). Zoom and scroll position are saved with the window.
local function on_window_open(w)
   gui.zoomLevel = w.state.zoomLevel or 0
   gui.scrollOffset = w.state.scrollOffset or 0
   List.apply_zoom(gui.zoomLevel) -- needs the open window (font metrics)
end

local function on_window_close(w)
   w.state.zoomLevel = gui.zoomLevel
   w.state.scrollOffset = gui.scrollOffset
   if not State.quit then Data.save_current_list(State.list) end
end

-- Called by the Window once per frame. The Window runs the loop, handles closing and saves its state.
local function frame(w)
   if State.quit then
      log:info("closing %s", WINDOW_TITLE)
      w:request_close()
   else
      Widgets.tooltip_begin(w)
      State.last_project = State.current_proj
      State.current_proj = reaper.EnumProjects(-1)

      State.tab_count = Sync.open_count()
      pollMode() -- picks up edit/show changes (callback errors are logged, not thrown)
      w:set_mode(gui.mode) -- the window saves / restores its position per mode

      local rendering = is_rendering()
      if rendering ~= wasRendering then
         log:info("rendering %s: project check %s", rendering and "started" or "finished", rendering and "paused" or "resumed")
         wasRendering = rendering
      end

      -- The open tabs are the truth: whatever happens to them in REAPER (opened, closed, moved), the list follows.
      -- Not while REAPER renders, and not while a question is open (it keeps the list as it was when it was asked).
      if State.job then Actions.step_job() end -- a load opens its projects one per frame
      local modal = State.dialog ~= nil or State.job ~= nil
      if not rendering and not modal then
         if not Sync.is_synced(State.list, Sync.project_pointers()) then Actions.follow_tabs() end
         DuplicateWarning.check()
         modal = State.dialog ~= nil
      end

      -- Mouse state: read once per frame by the Window (w.mouse), copied into the names used below
      local m = w.mouse
      gui.prevRightClick, gui.rightClick = gui.rightClick, m.right
      gui.prevLeftClick, gui.leftClick = gui.leftClick, m.left
      if m.left_pressed or m.right_pressed then
         gui.lastClickDownPos = { x = m.press_x, y = m.press_y }
         if m.left_pressed then log:debug("Left click detected at position: " .. m.press_x .. "," .. m.press_y) end
      end

      if not gui.leftClick then
         gui.leftClickHandled = false
         gui.pressOnIndicator = false
      end
      if not gui.rightClick then gui.rightClickHandled = false end
      if not m.left and not m.right then gui.draggingScroll = false end


      -- The layout for this window width. Below the smallest size the command bar is usable in (a small docked window, or a
      -- floating one made small): the list stays, the status line and command bar are left out, and a sign in the corner
      -- opens the commands as a menu (CommandArea.draw_compact). A question stays visible.
      CommandArea.update()
      gui.small = gfx.w < gui.minWindowW or gfx.h < gui.minWindowH
      gui.panelH = gui.small and 0 or gui.ctrlPanelSize

      gui.listH = gfx.h - gui.panelH - gui.titleHeight
      gui.numVisibleEntries = math.max(1, math.floor(gui.listH / gui.lineHeight))
      gui.maxScroll = List.manual_max_scroll(State.list, gui.numVisibleEntries)
      gui.followMaxScroll = List.max_scroll(State.list, gui.numVisibleEntries)

      -- Follow-scroll: whenever the active project changes (tab click in REAPER or click in the list),
      -- bring the previous project to the top row. Not when a project was clicked in the list in edit mode.
      if State.last_project ~= State.current_proj then
         local fromList = State.current_proj ~= nil and State.current_proj == gui.listClickTarget
         if List.should_follow(gui.mode, fromList) then
            gui.followPending = true
         else
            log:debug("Project selected in the list in edit mode: not scrolling")
         end
      end
      gui.listClickTarget = nil -- set by ListInput.handle_click at the end of a frame, used once in the next one

      local _, totalRows = List.layout(State.list)
      if totalRows <= gui.numVisibleEntries and gui.scrollOffset ~= 0 then
         gui.scrollOffset = 0
         log:debug("Scroll set to 0 because all entries are visible.")
      elseif gui.followPending and not (gui.leftClick or gui.draggingEntry or gui.draggingScroll) then
         local listIdx = Data.tab_to_list_idx(State.list, Sync.tab_index(State.current_proj) or -1)
         local offset = List.follow_scroll_offset(State.list, listIdx, gui.followMaxScroll)
         if offset then
            gui.scrollOffset = offset
            log:debug("Following current project (" .. gui.mode .. " mode): listIdx " .. listIdx .. ", scrollOffset = " ..
               offset .. " (follow range " .. gui.followMaxScroll .. ", manual range " .. gui.maxScroll .. ", " ..
               gui.numVisibleEntries .. " rows visible, zoom " .. gui.zoomLevel .. ")")
         end
         gui.followPending = false
      end

      -- Any user scrolling, click or drag ends a running scroll animation right away
      local userInput = m.wheel ~= 0 or gui.leftClick or gui.rightClick or gui.draggingEntry or
          gui.draggingScroll

      if not modal then
         ListInput.handle_scrollbar()
         ListInput.handle_wheel()
      end
      List.update_display_offset(userInput)
      List.draw()
      List.draw_scrollbar()
      if not modal then ListInput.handle_edit() end

      if modal then
         -- the question is drawn over the list; nothing else reacts until it is answered
         gui.draggingEntry, gui.dropIdx = false, nil
         if State.dialog then
            local choice = State.dialog.draw(w)
            if choice then State.dialog.on_choice(choice) end
         end
         Widgets.tooltip_end(w)
         return
      end

      List.offscreen_indicator()

      if gui.small then
         CommandArea.draw_compact()
      else
         CommandArea.draw()
         CommandArea.draw_status()
      end
      Theme.set_font(gui.entryTextSize)

      if not gui.edit then -- (while a text entry is edited, the mouse belongs to its field)
         ListInput.handle_click()
         ListInput.handle_drag()
      end
      Widgets.tooltip_end(w)
   end
end

local function init()
   if not check_dependencies() then return false end
   Theme.use_reaper_font("user_font0") -- the font of the REAPER theme (the regular Roboto) for the whole Setlist
   Theme.TITLE_FACE = Theme.reaper_font_face("lb_font") -- and the medium one for its title

   -- Starts following the shared edit/show mode (Mode.watch calls on_shared_mode_changed once right away).
   pollMode = Mode.watch(ViewState.on_shared_mode_changed) -- sets the list mode before the first frame
   log:info("following the shared mode - list mode: %s", gui.mode)

   State.tab_count = Sync.open_count()

   local testMode = Data.is_test_mode()
   local firstRun = Data.is_first_run()
   local current, invalid, currentStr, source = {}, {}, "", ""

   if testMode then
      log:info("test mode (live test): the saved lists are neither read nor written")
   else
      current, invalid, currentStr, source = Data.read_list_file(Data.current_list_path(), "current list", Sync.find_open_tab)
   end

   local action = Data.startup_action(next(current) ~= nil, firstRun, testMode)
   log:info("start: " .. action .. (firstRun and " (first start since REAPER was opened)" or ""))

   Data.mark_session_started()

   if action == "keep" then
      -- restarted within the same REAPER run: the list is kept and follows the open tabs. If they changed while the
      -- Setlist was closed, the list as it was stays available as the autosave, and the status line says so.
      Ask.invalid_entries(current, invalid, source)
      State.list = current
      local tabs = {} -- unsaved projects are never saved in the list, so they are no change
      for _, tab in ipairs(State.read_open_projects()) do
         if tab.path ~= "Unsaved Project" then tabs[#tabs + 1] = tab end
      end
      local changes = Sync.change_summary(Sync.diff(current, tabs))
      if changes then
         State.notice_restorable = Data.archive_list(currentStr)
         State.notice = "Projects Changed While Setlist Closed: " .. changes
      end
      if next(State.list) then Actions.follow_tabs() end
   elseif firstRun and next(current) then
      -- a new REAPER run starts from the open projects; the list of the last run stays available as the autosave
      Data.archive_list(currentStr)
   end

   if not next(State.list) then
      log:info("building the list from the open projects")
      State.list = State.read_open_projects()
      Actions.commit()
   end

   State.win = Window.new{
      name = Data.EXT_SECTION, -- same section and "WindowState" key as before: the saved state is kept
      title = WINDOW_TITLE,
      defaults = { ww = 400, wh = 300, wx = 200, wy = 200, dockState = 0, zoomLevel = 0, scrollOffset = 0 },
      extra_keys = { "zoomLevel", "scrollOffset" },
      on_open = on_window_open,
      on_close = on_window_close, -- also writes the current list
      debug = function(text) log:debug("window: %s", text) end,
   }
   State.win:set_mode(gui.mode) -- open at this mode's position

   if State.quit then return false end -- a startup dialog was cancelled: don't open the window

   State.win:run(frame) -- opens the window. Closing (also REAPER quitting) saves its state and the current list
   return true
end

-- Test-only switch (see lib/SelfTest.lua): hand over the tests instead of opening the window
if rawget(_G, "SELFTEST_COLLECT") then
   for _, part in ipairs({
      { "Setlist data", "Setlist/Data.lua", Data },
      { "Setlist sync", "Setlist/Sync.lua", Sync },
      { "Setlist view state", "Setlist/UI/ViewState.lua", ViewState },
      { "Setlist list", "Setlist/UI/List.lua", List },
      { "Setlist project info", "Setlist/ProjectInfo.lua", ProjectInfo },
   }) do
      table.insert(SELFTEST_COLLECT, { name = part[1], file = part[2], self_test = part[3].self_test })
   end
else
   init()
end
