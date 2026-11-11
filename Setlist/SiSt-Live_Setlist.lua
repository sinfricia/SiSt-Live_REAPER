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
--   the user can do to the list), State.lua (what the parts share), UI/ (ViewState, ListLayout, List, ListInput, CommandArea, Ask), Tests/.
--   This script is the glue: Init, and Frame once per frame.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. script_dir .. "../?.lua;" .. package.path -- the package's lib folder, and Setlist.* modules

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
local ListLayout = require("Setlist.UI.ListLayout")
local List = require("Setlist.UI.List")
local ListInput = require("Setlist.UI.ListInput")
local CommandArea = require("Setlist.UI.CommandArea")
local Ask = require("Setlist.UI.Ask")
local DuplicateWarning = require("Setlist.UI.DuplicateWarning")

local view, drag, input, lay = ViewState.view, ViewState.drag, ViewState.input, ViewState.lay

local WINDOW_TITLE = "SiSt-Live Setlist"

local poll_mode = nil -- returned by Mode.watch() in Init; call once per frame to pick up mode changes

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

local was_rendering = false

-- Window callbacks (see lib/Gui/Window.lua). Zoom and scroll position are saved with the window.
local function on_window_open(w)
   view.zoom_level = w.state.zoomLevel or 0
   view.scroll_offset = w.state.scrollOffset or 0
   List.apply_zoom(view.zoom_level) -- needs the open window (font metrics)
end

local function on_window_close(w)
   w.state.zoomLevel = view.zoom_level
   w.state.scrollOffset = view.scroll_offset
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
      poll_mode() -- picks up edit/show changes (callback errors are logged, not thrown)
      w:set_mode(view.mode) -- the window saves / restores its position per mode

      local rendering = is_rendering()
      if rendering ~= was_rendering then
         log:info("rendering %s: project check %s", rendering and "started" or "finished", rendering and "paused" or "resumed")
         was_rendering = rendering
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

      -- Mouse state: kept by the Window (w.mouse). What is left here is the Setlist's own bookkeeping of a press.
      local m = w.mouse
      if m.left_pressed then log:debug("Left click detected at position: " .. m.press_x .. "," .. m.press_y) end
      if not m.left then
         input.left_click_handled = false
         input.press_on_indicator = false
      end
      if not m.right then input.right_click_handled = false end
      if not m.left and not m.right then drag.scrolling = false end


      -- The sizes for this window width and zoom (see UI/ListLayout.lua). The command bar's own layout comes first: it
      -- tells how small the window may get before the command bar is replaced by a menu.
      CommandArea.update()
      ListLayout.update()

      -- Follow-scroll: whenever the active project changes (tab click in REAPER or click in the list),
      -- bring the previous project to the top row. Not when a project was clicked in the list in edit mode.
      if State.last_project ~= State.current_proj then
         local from_list = State.current_proj ~= nil and State.current_proj == view.list_click_target
         if List.should_follow(view.mode, from_list) then
            view.follow_pending = true
         else
            log:debug("Project selected in the list in edit mode: not scrolling")
         end
      end
      view.list_click_target = nil -- set by ListInput.handle_click at the end of a frame, used once in the next one

      local _, total_rows = List.layout(State.list)
      if total_rows <= lay.visible_rows and view.scroll_offset ~= 0 then
         view.scroll_offset = 0
         log:debug("Scroll set to 0 because all entries are visible.")
      elseif view.follow_pending and not (m.left or drag.active or drag.scrolling) then
         local list_idx = Data.tab_to_list_idx(State.list, Sync.tab_index(State.current_proj) or -1)
         local offset = List.follow_scroll_offset(State.list, list_idx, lay.follow_max_scroll)
         if offset then
            view.scroll_offset = offset
            log:debug("Following current project (" .. view.mode .. " mode): list_idx " .. list_idx .. ", scroll_offset = " ..
               offset .. " (follow range " .. lay.follow_max_scroll .. ", manual range " .. lay.max_scroll .. ", " ..
               lay.visible_rows .. " rows visible, zoom " .. view.zoom_level .. ")")
         end
         view.follow_pending = false
      end

      -- Any user scrolling, click or drag ends a running scroll animation right away
      local user_input = m.wheel ~= 0 or m.left or m.right or drag.active or
          drag.scrolling

      if not modal then
         ListInput.handle_scrollbar()
         ListInput.handle_wheel()
      end
      List.update_display_offset(user_input)
      List.draw()
      List.draw_scrollbar()
      if not modal then ListInput.handle_edit() end

      if modal then
         -- the question is drawn over the list; nothing else reacts until it is answered
         drag.active, drag.drop_idx = false, nil
         if State.dialog then
            local choice = State.dialog.draw(w)
            if choice then State.dialog.on_choice(choice) end
         end
         Widgets.tooltip_end(w)
         return
      end

      List.offscreen_indicator()

      if lay.small then
         CommandArea.draw_compact()
      else
         CommandArea.draw()
         CommandArea.draw_status()
      end
      Theme.set_font(lay.entry_text_size)

      if not input.edit then -- (while a text entry is edited, the mouse belongs to its field)
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
   poll_mode = Mode.watch(ViewState.on_shared_mode_changed) -- sets the list mode before the first frame
   log:info("following the shared mode - list mode: %s", view.mode)

   State.tab_count = Sync.open_count()

   local test_mode = Data.is_test_mode()
   local first_run = Data.is_first_run()
   local current, invalid, current_str, source = {}, {}, "", ""

   if test_mode then
      log:info("test mode (live test): the saved lists are neither read nor written")
   else
      current, invalid, current_str, source = Data.read_list_file(Data.current_list_path(), "current list", Sync.find_open_tab)
   end

   local action = Data.startup_action(next(current) ~= nil, first_run, test_mode)
   log:info("start: " .. action .. (first_run and " (first start since REAPER was opened)" or ""))

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
         State.notice_restorable = Data.archive_list(current_str)
         State.notice = "Projects Changed While Setlist Closed: " .. changes
      end
      if next(State.list) then Actions.follow_tabs() end
   elseif first_run and next(current) then
      -- a new REAPER run starts from the open projects; the list of the last run stays available as the autosave
      Data.archive_list(current_str)
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
   State.win:set_mode(view.mode) -- open at this mode's position

   if State.quit then return false end -- a startup dialog was cancelled: don't open the window

   State.win:run(frame) -- opens the window. Closing (also REAPER quitting) saves its state and the current list
   return true
end

-- Test-only switch (see lib/SelfTest.lua): hand over the tests (Setlist/Tests/) instead of opening the window
if rawget(_G, "SELFTEST_COLLECT") then
   for _, part in ipairs({
      { "Setlist data", "Setlist/Data.lua", "Data" },
      { "Setlist sync", "Setlist/Sync.lua", "Sync" },
      { "Setlist view state", "Setlist/UI/ViewState.lua", "ViewState" },
      { "Setlist list", "Setlist/UI/List.lua", "List" },
      { "Setlist list layout", "Setlist/UI/ListLayout.lua", "ListLayout" },
      { "Setlist project info", "Setlist/ProjectInfo.lua", "ProjectInfo" },
   }) do
      table.insert(SELFTEST_COLLECT, { name = part[1], file = part[2], self_test = require("Setlist.Tests." .. part[3] .. "_test").self_test })
   end
else
   init()
end
