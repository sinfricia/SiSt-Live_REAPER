# SiSt-Live: completed tasks

Newest first. Open findings move into the roadmap item that fixes them. Why things are done this way:
Docs/design-decisions.md.

## 2026-11-11 - Step 4e: Setlist cleanup
Review round 2026-11-11. No behaviour change, except the divider line (Sina asked for it during the step; one commit).
- **The shared `gui` table (86 fields) is gone.** The mouse is only `State.win.mouse` (the click flags and `gui.lastClickDownPos`
  copies are removed: `left`, `right`, `left_pressed`, `press_x/y`). `ViewState` now has `CFG` (constants, read as `CFG.x`, no
  more fall-through), `view` (zoom, scroll, display offset, follow flags, mode, selection), `drag` (entry drag and scrollbar drag),
  `input` (click bookkeeping, double click, text edit) and `lay` (this frame's sizes). The new UI/ListLayout.lua works out
  `small`, `panel_h`, `list_h`, `visible_rows`, `max_scroll` once per frame (`ListLayout.compute` is pure and tested, 10 checks).
  The two draw scratch flags moved into List.lua as `mark`.
- **snake_case in all Setlist code** (about 240 names, e.g. `drop_idx`, `list_idx`, `tab_idx`, `scroll_offset`). Kept on purpose:
  the window's saved `zoomLevel` / `scrollOffset`, and `listIdx` / `tabIdx` in `TRANSIENT_FIELDS` (older saved lists).
- **Tests out of the production files:** Setlist/Tests/{Data,Sync,List,ListLayout,ViewState,ProjectInfo}_test.lua (about 700
  lines out of Data, Sync, List, ViewState, ProjectInfo). `Data.encode_value` is exported for its test. The main script's
  SELFTEST_COLLECT block requires them; Setup's @provides lists them. 251 -> 261 Setlist checks (self-test 682 passed).
- **UI (Sina):** the divider between two linked (indented) text entries is indented too.
- Docs: design-decisions "Setlist view state", setlist-design file list and test location.

## 2026-11-11 - Step 4d: review fixes
From the code review after step 4 (Sina approved the plan and the decision; one commit).
- **Layout tests:** lib/SiSt-Live_Tests.lua declared `local Layout` twice, so the layout mode effect's tests never ran; the
  mode effect is now `LayoutEffect`. Both layout components run (16 checks each).
- **Small docked Setlist (decision A):** the list is always drawn; below the smallest size the status line and the command bar
  are left out (`gui.small`, `gui.panelH`), a "..." sign in the corner opens all commands as a menu
  (`CommandArea.draw_compact`), a question is still drawn over the list. "Window Too Small" is gone.
- **Menu labels:** `Window.menu_label` (used by `Window.build_menu`) turns `|` into a look-alike and puts a space before a
  leading `#`, `!`, `<`, `>`, so entry texts and project names can no longer shift the menu choices.
- **Restore button:** `Data.has_autosave` reads the file once and `Data.archive_list` keeps the flag up to date (it was a file
  read every frame).
- **Self-test:** a crashing diagnostics function is a failed row, not just an info line (SelfTest.count counts it).
- **Region Looper:** the marker keeps the final-pass colour from "next pass is final" until the end (it lasted one frame).
- **No forced minimum size:** `Window:enforce_min_size` (js_ReaScriptAPI, made a floating window bigger again) is removed, it
  flickered; a window below the smallest size gets the compact view like a docked one.
- `Sync.plan_load` works on a copy of `remove`; Save Setlist writes through `Data.write_text_atomic`.
- **Follow-scroll (Sina, 2026-11-11):** the active project goes to the top row together with the text entries right above it
  that are not linked to the project before; the previous project is no longer shown (`List.follow_scroll_offset`).
- **Shift-drag linking** works when the entry does not move (dropped on its neighbour), for one entry and for a selection.
- New: Debug/SiSt-Live_DEBUG Screenshot Setlist.lua (js_ReaScriptAPI GDI/LICE, not installed): saves the Setlist window as
  Data/SiSt Libraries/Setlist screenshot.png, so Claude can look at drawing changes.
- **File > Open into an existing tab** keeps the project pointer, so the entry kept its old name: `Sync.is_synced` now compares the
  tab's file path too (`Sync.project_pointers` returns the paths as a second result) and `Sync.follow_tabs` updates path and name.
- After testing: the drop line also shows for a Shift drop that does not move the entry; the scroll-to-current arrow sits at the
  real bottom of the list; zoom 60% to 200%; in a small window text entries do not wrap (long lines get "...") and project lengths
  go sooner; the "..." sign and the overflow line use the active project's colour.
- Not needed: `Widgets.wrap_text` already cut at UTF-8 character borders.

## 2026-11-11 - Step 4 complete (the Setlist)
- Step 4 = 4b + 4c (current list, autosave, command area), then the redesign 4a in pieces: (a) the split into parts, (b) silent
  sync and the load flow, (c) row indicators, (d) linked and multi-line text entries, (e) multi-selection, (f) responsiveness
  (entries below). Design: Docs/setlist-design.md.
- The two open items were decided: the project length stays "position of the last marker" (GetProjectLength checked: the same
  for projects with markers, no use without), and the live test keeps opening its projects itself, because it has to replace
  the loopback test's unsaved projects without asking ("noprompt"); the Setlist's real load code with real tabs is covered
  by "DEBUG Run Setlist Scenarios" (49 checks). See Docs/design-decisions.md.
- Self-test: 668 passed; scenarios: 49.

## 2026-11-11 - Step 4a (f): responsiveness
- New `lib/Gui/Layout.lua` (pure, tested): `Layout.pack` puts the sections of a bar in one row (natural, compact, the last
  ones left out with an indicator and a menu at the right edge), `Layout.pick` takes the first text variant that fits. Used by
  the command area and the status line (the right text shortens, the chips get the rest).
- Project names give way with "..." in a narrow window (chips first, then the length), the header title and the load dialog list
  texts too; tooltips wrap to the window; `Widgets.fit_text` no longer cuts a UTF-8 character; `Widgets.wrap_text` is shared.
- The smallest size comes from the layout (about 240 x 250): `Window:enforce_min_size` makes a floating window bigger again (js_ReaScriptAPI);
  docked, the Setlist only says "Window Too Small" and what it needs.
- List rows start 12 px from the edge (was 15); mouse positions come from `win.mouse`. Loop chips: a project's markers are read
  once and again when its state change count or its number of markers and regions changes (the count alone does not
  change when a region is added).
- Self-test: 662 passed; scenarios: 49.

## 2026-11-11 - Step 4a (e): multi-selection, Shift-drag linking
- Selection (`gui.selection`): Ctrl+click, Shift+click, accent tint and border, batch right-click menu (Color, Unlink, Close
  Projects, Delete Text Entries; one confirmation each), group drag (`Actions.drop_selection`, tabs follow, Ctrl copies the
  text entries). Entries that disappear leave the selection.
- Shift while dragging a text entry links it to the entry the mouse is over (`Actions.drop_entry` link / hoveredIdx); the drop
  line takes the link colour. Fixed: a drop at the very top or the end of the list (and in the empty space below) works.
- Later in the same session: a click anywhere clears the selection; Ctrl / Shift on a selected entry waits for a drag (Ctrl+drag
  copies a selection, Shift+drag links text entries, also several); text groups dropped inside a link group join it; delete
  confirmations dropped (text and missing entries, batch); the active project's dot is replaced by squares while something
  is selected; fixed the drag highlight hiding the "next project" mark and a press on a selected project jumping to it.
- The Setlist uses the theme's regular Roboto (title: Medium); button labels are centered by `Widgets.text` itself.
- Self-test: 652 passed; scenarios: 49 (group drag with real tabs: 192 cases against a model, 98 random cases with linked
  text entries, Shift drops, text groups).

## 2026-11-11 - Step 4a (d): linked text entries, editing in place, several lines
- Linked text entries (`link` field "above" / "below", `Data.link_chain / link_block / block_of / join_block`): linking
  through text entries in between, blocks that move with their project in drag and drop and in the tab order, joining by
  dropping inside a block, links dropped when the project closes or is not kept by a load. Drawn indented (by the number
  column) with a line at the left edge and hooks into the first and last entry. Tests: Data, Sync (follow_tabs, plan_load).
- Editing in place with a multi-line `Gui/TextField` (Shift+Enter, Up/Down/Home/End by lines, soft wrap while typing,
  `TextField.wrap_lines`); the Rename dialog and the Insert dialog are gone.
- Text entries: "--" at the number's place, 80% font size, faint default tint; several lines (line breaks and wrapping to
  the window, closer line step). The list is measured in rows (`List.layout`, `entry_rows`, `entry_at_row`), so scrolling,
  scrollbar, follow-scroll and dragging work with tall entries.
- Self-test: 650 passed. Real-tab scenarios (drag with blocks) added to "DEBUG Run Setlist Scenarios". No live test.

## 2026-11-11 - Step 4a (c): row indicators, tooltips and status chips
- Rows: chips before the length (`A` no stop, `M` manual, `L` loop regions; `UI/List.lua`, reading `Setlist/ProjectInfo.lua`
  which parses a project's markers and regions, cached by the project's state change count). While looping, the transport
  slot shows `L<pass>` (yellow playing, red recording) and `L →` on the last pass.
- Region Looper edited (Sina agreed): publishes the pass to the project ExtState (`SiSt-Live` / `LoopPass`, "2/3", "!" =
  stopped); also fixed the loop marker in the project, which never got its pass number (it was passed the wrong object).
  The running Looper action must be toggled off and on to load the change. New "SiSt-Live: DEBUG Looper State" action
  writes what the Looper publishes to Data/SiSt Libraries/Looper state.txt.
- Tooltip system in lib/Gui/Widgets (rest 0.6 s, native-looking box); used for the chips and the command buttons.
- Status line: red "N Missing" chip (click scrolls to the first), the restart notice as a teal chip "Projects Changed
  While Setlist Closed: ..." (click restores the previous list; stays when the restore is refused, e.g. while playing).
- Duplicate warning: the "keep open" choice survives closing and reopening the Setlist. A new text entry is inserted after
  the active project. Fixed: an entry stayed orange after a drag was released over itself.
- Self-test: 576 passed. No live test (Setlist only).

## 2026-11-11 - Step 4a (b): silent sync and the load flow
- The old conflict resolver (380 lines, four chained dialogs) is gone. While the Setlist runs, the open tabs are the truth:
  `Sync.diff` / `Sync.follow_tabs` (pure, tested) make the list follow opened, closed, moved and replaced projects in the
  same frame, no question. A restart within a REAPER run keeps the list and follows the tabs; if they changed meanwhile the
  previous list is kept as the autosave and the status line offers a click to restore it.
- A project open more than once: "Warning: Project Open More Than Once", Keep Them Open / Close the Extra Tabs; "keep"
  is remembered by project pointers (UI/DuplicateWarning.lua).
- Loading (and Restore): UI/LoadDialog.lua shows the current list with Keep checkboxes (text entries and open projects that
  are not in the loaded setlist; identical text entries and projects that stay are context rows), tri-state header
  checkbox, swipe select, Type column, green/red rows; `Sync.plan_load` decides (pure, tested); the projects open and close
  one per frame with progress in the header (`Actions.start_load` / `step_job`); refused while a project plays or records;
  empty unsaved tabs are closed without asking; entries saved as missing become projects again when their file is back.
- Window title: the setlist's name with a `*` in front when modified. Everything labelled in Title Case. New library
  parts in lib/Gui: Dialog (panel with buttons, modal in the window), Widgets.list_view (scrolling rows with checkbox
  rows, tint, header rows, swipe select) and checkbox drawing.
- New "SiSt-Live: DEBUG Run Setlist Scenarios": runs the real sync and load code against real tabs (generated test projects
  in a temp folder, other open projects stay untouched); 31 checks. Smoke runs of the drawing code against a fake REAPER
  were done by hand.
- Self-test: 549 passed. No live test (Sina, 2026-11-11).

## 2026-11-11 - Step 4a (a): the Setlist split into parts
- The 3,150-line Setlist script is now a 282-line glue script (Init, Frame) plus Setlist/Data.lua (entries, .rsl text
  format, paths, index math, current-list and autosave files), Sync.lua (REAPER's project tabs, pure comparison),
  Actions.lua (what the user can do to the list), State.lua (shared state), Resolver.lua (the OLD conflict resolver,
  temporary) and UI/ViewState, List, ListInput, CommandArea, Ask. Rule: the UI only reads the mouse, draws and asks;
  it never changes the list or the tabs. Structure and reasons: Docs/setlist-design.md ("Code structure").
- Tests moved with their code (Data 68, Sync 10, ViewState 17, List 42 checks), registered by the main script. New
  `SelfTest.cases()` in the shared test library (the `t.eq` / `t.ok` style, with tests).
- Behaviour: unchanged except Queue Project is gone; the right-click menus use Window.build_menu; the index lookups no
  longer log. The index lookups are plain functions (no global cache), `Data.text_to_list` takes a callback to find
  the open tab of an entry.
- Checked without the window: no undefined globals, every Module.function used exists, a run of drawing, clicks, menus
  and actions against a fake REAPER. Sina tested the window.
- Self-test: 478 passed. No live test.

## 2026-11-11 - Step 4b + 4c: current list, autosave, command area, no locking in show mode
- Two files in Data/: `SiSt-Live_Setlist_current.rsl` is the live list (written after every change; the old "autosave"),
  `SiSt-Live_Setlist_autosave.rsl` is the list that was replaced, kept for rescue. Written when the whole list is replaced
  (first start in a new REAPER run, Reset, Restore, Load Setlist). `WorthArchiving` (tested): never an empty list, and a
  list without text entries never overwrites an autosave that has some. The old clean-start backup file and the EXT_STATE
  fallback are gone; an old autosave file simply becomes the first autosave.
- Startup without a question: restart within the same REAPER run keeps the list (conflict handling with the open
  projects as before, until the Setlist design is redone); the first start in a new run starts from the open projects.
  `GetStartupAction` (tested). Shift / Ctrl / Alt launch modifiers and the in-script self-test runner removed (window
  menu has "Return to default position"; the self-test runs via Setup / DEBUG action). Test mode unchanged.
- Command area, fixed layout, below the list: a faint divider, the status line (projects | total time, right aligned),
  the strong divider, then sections with centered names and a divider after each: LIST (Save, Load, Reset, Restore),
  INSERT (Text Entry), ZOOM (percent = reset, + above - as half-height buttons). Buttons of a section are equally wide.
  Reset and Restore ask for confirmation and keep the replaced list as the autosave; Restore swaps the two lists and is
  greyed out without an autosave.
- Show mode no longer locks anything. It asks for confirmation before deleting a text entry, removing a missing entry,
  closing a project from the entry menu and loading a setlist from a file (`ConfirmInShowMode`).
- Findings: tried a rebuilt conflict resolver (sync module, dialog panel, tabs/list view) and a responsive command bar
  (wrapping, collapsing groups); dropped both on purpose until the Setlist design is settled (see roadmap, step 4a).
- Self-test: 466 passed. No live test (Sina, 2026-11-11).

## 2026-11-10 - Step 3: Simplify the live test (step 3 complete)
- Split: Debug/SiSt-Live_DEBUG Run Live Test.lua (1,224 -> 254 lines: menu, test folder, closing projects,
  unattended mode, the scenario) + Debug/LiveTest/Show.lua (show workflow, recordings), Looper.lua (Region Looper),
  Loopback.lua (audio + MIDI loopbacks, melodies unchanged), Helpers.lua (shared helpers and the routing / songs
  state). Tests and behaviour unchanged.
- No literal action IDs: Start Song, Play or record and Toggle playback mode by file name; the three Project End
  Handler custom actions by name with the new general `Actions.find_custom(name)` (tested; missing / ambiguous
  reported). Native IDs (Stop, Play, New tab, Close tab, Close all) stay numbers.
- Shared code: the live test's file listings use `SelfTest.list_files` (now always a fresh listing, so new
  recordings are never missed); its relative path helper became `SelfTest.relative_path` (tested). The folder
  picker and "close all projects" stay in the live test: no second user (shared-code rule; roadmap text said to
  move them).
- One FX name each, from this config's FX lists: "JS: Tone Generator", "ReaSynth (Cockos)".
- Roadmap: "Project End Handlers as scripts" (Sina, 2026-11-10), incl. updating every action marker.
- Self-test: 466 passed (53 scenarios, 457 checks, 9 live checks). Live test: 98 passed; loopback test (menu, run by
  Sina): passed.

## 2026-11-10 - Step 3: Setup as the entry point for checks
- The debug-on-open test runners of the Status Display, Toolbar and Setup are gone (their tests run in the
  self-test anyway). With debug on, the Status Display still logs its theme colors.
- "SiSt-Live: Setup" now: files installed, scripts added to the action list (as before), required extensions (one
  API function each: SWS `CF_GetSWSVersion`, js_ReaScriptAPI `JS_ReaScriptAPI_Version`, ReaPack `ReaPack_GetOwner`,
  each listed with what needs it), then the self-test (about 1 s), all in one summary dialog with "Open the full
  self-test report?" (SWS CF_ShellExecute; without SWS the path is shown). The self-test is skipped while playing or
  recording (it switches the mode for a moment). Nothing goes to the console: `SelfTest.run_suites` has
  `opts.console = false` and also returns the report path.
- Not in Setup (Sina, 2026-11-10): "Check action markers" (about the open projects, run by hand) and the live test.
  ReaImGui is not a dependency.
- The DEBUG actions stay until the configuration window can start the tests (Sina, 2026-11-10; roadmap).
- Self-test: 463 passed (53 scenarios, 454 checks, 9 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Logging in one go
- New general lib/Log.lua (moved from lib/SiSt-Live_Log.lua, nothing SiSt-Live-specific left): ONE debug switch for
  all packages (ExtState "SiSt Libraries" / debug) and a "quiet console" flag ("SiSt Libraries" / quiet_console): when
  on, warnings and errors go only to the file; debug output still prints. Neither is persisted. `Log.configure{
  file_dir, file_name, on_debug_change, diagnostics }`; default file Data/SiSt Libraries/SiSt Libraries.log.
- lib/SiSt-Live_Log.lua is now a wrapper: loads Log, configures SiSt-Live's file (Data/SiSt-Live/SiSt-Live.log) and
  the "DEBUG Toggle Logging" button, returns Log. The scripts that load it are unchanged.
- Mode sets the quiet flag together with the mode button (`sync_outputs`): on in show mode. Log no longer reads the
  mode. Same behaviour as before (the stage guard was "show mode and debug off").
- Gui Theme: general accents only (accent = the teal used for focus and default headers, toggle, ok, error);
  `Theme.configure{ accents }` adds a package's colors (Status Display: show, edit, live). An accent carries its
  header strength (`header = 0.60`), so Widgets.HEADER_AMOUNT is gone. Colors unchanged.
- Fix (save current look): the layouts line lists only the sections that change, in words: "mcp (not set) -> (theme
  default)" instead of the whole old and new setting (Sina, 2026-11-10).
- Self-test: 460 passed (53 scenarios, 451 checks, 9 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Save current look for a mode
- New action "SiSt-Live: Save current look for current mode" (Modes/): one confirmation lists what it stores for the
  current mode (theme: old -> new, layouts: old -> new, "screenset #NN: overwritten with the current windows and
  dockers"), plus what is left as it is and problems. Yes stores, No changes nothing; nothing is re-applied. No
  autosave of the look (a window closed by accident on stage would become the show look).
- Effect contract: optional `take_current(mode)` looks only and returns `{ text, note?, save }` or `nil, reason`;
  errors become problem lines. Theme (loaded theme file, same rules as "current"), Layout (tcp, trans, mcp),
  Screenset (runs "Screenset: Save window set #NN", IDs 40474-40483, into the mode's slot; no slot set -> left alone
  with "set one in Configure modes first", Sina, 2026-11-10). `ModeEffects.take_current` / `describe_take` /
  `save_taken` collect, describe and save. Typing "current" for the theme uses the same `Theme.current_ref`.
- The screenset action check is now two lines: "window sets (load)" and "window sets (save)".
- Not done (Sina: later): toolbar button. The configuration window will call the same functions.
- Self-test: 455 passed (53 scenarios, 446 checks, 9 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Action IDs, part 2 (native actions, split)
- `Actions.require_native` is gone: the Screenset, Fullscreen and KeySection effects run their native action by its
  fixed ID without checking first (Sina, 2026-11-10: native IDs are trusted; a vanished one is rare). The self-test
  still checks them on demand, now ONE line per group: "window sets: 10 actions exist", "keyboard sections: 17
  actions exist", "fullscreen: 1 action exist"; a missing action fails its group line and is listed. Each effect
  keeps declaring its own native actions (no central table; the design decision text is narrowed).
- `Actions` is split: `lib/Actions.lua` is general (native name and group check, `find_script(file name)`,
  `register(path)`, nothing SiSt-Live-specific), `lib/SiSt-Live_Actions.lua` has SiSt-Live's script list, the package
  folder and the file/script lookups with their messages. Lookups return nil + reason + kind ("not_installed",
  "missing", "ambiguous"); Setup registers on "missing".
- Self-test: 439 passed (53 scenarios, 431 checks, 8 live checks; the live checks were 33 single lines before).
  Live test: 98 passed.

## 2026-11-10 - Step 3: Action IDs, part 1 (lookup and registration)
- `Actions.file_command` / `script_command` find a script by its file name in the action list with
  `reaper.kbd_enumerateActions` (measured: 6,942 actions in 4 ms; script actions are named "Script: <file>.lua", their
  named ID starts with "RS", custom actions don't). The reaper-kb.ini parsing (`find_registered`, `read_kb`) and its
  tests are gone. A lookup only looks: it never adds anything. Messages: "not installed", "not in the action list (run
  SiSt-Live: Setup)", "more than one script action is named ...".
- `Actions.register(file)` adds a script to the action list. Setup calls it for every [main] script of its header that
  is missing and lists the added ones (and failures) in its report. When Claude adds a script during development, it
  runs Setup in the open REAPER.
- Tests: Actions (found by name in any folder, translated word before the colon, custom action ignored, not in the
  list, not installed, ambiguous, lookup adds nothing, register), Setup (scripts_to_register, report), the Windows
  effect's fakes use the action list.
- Self-test: 460 passed (52 scenarios, 427 checks, 33 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Gui Zoom
- New lib/Gui/Zoom.lua: clamp / scale / scaled (10% per level, range -5 to 15 or its own), Ctrl + mouse wheel, and the
  ready-made "Zoom" submenu (Zoom in, Zoom out, Reset zoom). Status Display and Toolbar use it and lost their copies. The
  right-click menus of both now show one "Zoom" submenu instead of three entries (visible change, Sina agreed).
- `Window.build_menu` supports submenus (`{ label, submenu = { items } }`, `>` / `<` in the gfx.showmenu string, entries
  numbered in menu order). Not supported: submenus inside submenus; the last entry of a submenu must be a normal item.
- The Setlist keeps its own zoom (different range and sizes; no behaviour change possible without the 4a rework).
- popup_menu (menu at the mouse without a window) dropped: its only users are the live test and a SiSt-Local script.
  The Setlist's right-click menus move to Window.build_menu in step 4a.
- Self-test: 451 passed (52 scenarios, 418 checks, 33 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Window.parse_state without load()
- `Window.parse_state` reads the stored window text ("{dockState=769.0,wx=1063.0,...}") with a text pattern instead of
  running it as Lua code (`load`). Only the allowed number keys are kept; a value that is not a number (a string, a
  call) is ignored and nothing is ever run; text without braces gives nil. It was the only place that ran stored text.
  Other structured ExtState / file values use their own pattern parsers (ModeEffects status, Windows ids, test
  registry, the Setlist autosave file, the mouse state file). New tests with real stored values, odd numbers and a
  save-then-load round trip.
- Self-test: 439 passed (51 scenarios, 406 checks, 33 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: Window debug scaffolding and Log cache removed
- Window: `size_suffix`, `remembered_size` and `client_w/h` are gone (they only added the docker size, "(420x300)", to
  debug log lines). The log lines now say "docker 3" or "floating 200,150 320x170".
- Log: the debug flag is no longer cached. Measured in Sina's REAPER: `GetExtState` costs 0.13 microseconds per call
  (100,000 calls in 0.013 s), so every log call reads the flag directly. Removed: the timer, `Log.CACHE_TTL`,
  `Log.refresh()` (use `Log.is_debug()`) and the "cache TTL" diagnostics row. A change of the switch is seen at once.
- Self-test: 434 passed. Live test: 98 passed.

## 2026-11-10 - Step 3: ExtState section rename
- Only one section broke the naming rule: the Setlist's "Sist-Live_Setlist" is now "SiSt-Live_Setlist" (Setlist and live
  test). The Status Display ("SiSt-Live_Status") and Toolbar ("SiSt-Live_Toolbar") already followed it. No migration
  code (it would stay in the Setlist forever for four keys): the saved window state was moved by hand in
  reaper-extstate.ini with REAPER closed (backup first). The setlist autosave was not part of it.

## 2026-11-10 - Step 3: show protection (mouse mode effect), editor, static analysis
- New mode effect "mouse" (lib/ModeEffects/SiSt-Live_ModeEffect_Mouse.lua). Show mode: saves the current
  assignments of the blocked contexts to Data/SiSt-Live/mouse-edit-state.txt, then sets every key combination to "No
  action". Edit mode: restores from the file and deletes it. The file is written and read back BEFORE anything is
  blocked and never overwritten while it exists; after a crash in show mode the next start (edit mode, __startup.lua)
  restores it. The edit state is simply the current Preferences > Mouse Modifiers, nothing else to maintain; changes to
  a blocked context made in show mode are overwritten by the restore. Settings: "SHOW mouse" = block, "EDIT mouse" =
  restore (Configure modes; empty = leave alone). Blocked (list at the top of the effect file): item (drag, click,
  double-click, edge, fade, lower half), crossfade, envelopes, ruler drag, empty-track drag, arrange right-drag.
  Not blocked: lanes, middle-drag scrolling, MIDI editor, clicks in ruler / track area / cursor handle (edit cursor;
  with Sina's seek settings these don't move the play position, tested 2026-11-10).
- Probe in the open REAPER (backed up the ini first): "No action" reads back as "0", a restore from a dump is exact
  for all slots; side effect: REAPER then lists previously implicit default slots explicitly in reaper-mouse.ini
  (same behaviour, longer file).
- Arrow cursor: while the mouse is blocked the arrange view shows the plain arrow. Script "SiSt-Live: Lock mouse
  cursor to arrow in arrange view" (Modes/), started by the mouse effect, ends when the state file is gone. It blocks
  WM_SETCURSOR on the arrange view (JS_WindowMessage_Intercept) and sets the arrow while the mouse is inside;
  setting the arrow every frame alone flickered (tested 2026-11-10). A short flicker when a modifier key is pressed
  or released is accepted. Windows only for now (Windows cursor number); where it can't work the script ends
  and the block still works. The code is part of the mouse effect file (`Mouse.arrow_*`) because nothing else uses
  it. Custom cursor images (.cur in the Cursors folder) can't follow the mode: REAPER needs a restart for them.
- Known and accepted: clicking an item still selects it (built into REAPER, not a mouse modifier).
- Locking removed in the same commit (Sina, 2026-11-10): the Locking effect, its tests, its Setup entry and the
  startup exception are gone, so the per-project ownership idea is dropped. Its old settings `locking_show` /
  `locking_edit` stay unused in reaper-extstate.ini. Project locking that is already on in a project stays on until
  switched off by hand. `ModeEffects.apply_all`'s `except` option has no caller any more (kept, tested).
  "Clear time selection and loop points" stays: it is used by custom actions.
- Editor: nothing to do in the repo (the ReaScript extension writes .vscode/settings.json itself, per machine);
  static analysis dropped after a trial (93 warnings, 92 noise); no VS Code debugger helper. Design decisions, "Editor".
- Self-test: 434 passed (51 scenarios, 401 checks, 33 live checks; the Locking effect's tests are gone, the arrow cursor tests are new). Live test: 99 passed.

## 2026-11-10 - Step 3: uniform mode-effects message
- New `Mode.apply(mode, opts)`: sets the mode, then runs the mode effects. Every place that switches or re-applies
  the mode uses it (Toggle Edit-Show Mode, Apply current mode, Configure modes, the Status Display's mode and
  "Apply again" buttons). `ModeEffects.apply_and_report` and the toggle action's special dialog are gone. The
  effects library is loaded inside Mode.apply (it needs Mode itself), so a missing or broken effects file never
  stops the switch.
- Rule (Sina, 2026-11-10): failed effects, or effects that can't run at all, are always logged. Edit mode: only
  the log (it prints to the console, which opens by itself; no dialog). Show mode: ONE dialog that names the log
  (the console stays closed on stage). Behaviour change: a single failed effect no longer shows a dialog in edit
  mode (since step 1.2 it did).
- Removed the dead library guards in Status Display, Toolbar and Setlist. The Setlist now requires its libraries at
  the top like the other windows (stand-in logger, `LoadSharedLibs`, 5 guards gone; `StartModeWatch` starts the
  mode watch). Toolbar lost its empty `lib_problems` list.
- New Mode test: effects that can't run still switch the mode; dialog in show mode only.
- Self-test: 433 passed (51 scenarios, 385 checks, 48 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3: loader (module path)
- Every script that uses the libraries starts with ONE line that puts lib/ on the module path (measured: each
  script run has its own Lua state and REAPER's default path only covers the config folder, so Setup or
  __startup.lua can't do it for the others). No loader file, no file check and no test registration at script
  start (a half-synced config is a risk of Sina's kDrive setup, not of the product); Setup and the self-test check
  the files. Design decisions: "Module path", "Working on several machines".
- Setlist: the 3-folder lib search is gone (only ../lib, like all scripts) and a missing library no longer leaves it
  running in show mode only. Status Display and Toolbar lost their "optional library" fallbacks. Test removed:
  GetSharedLibSearchDirs.
- "DEBUG Run Self-Test" and Setup register the test list (as before).
- New rule (CLAUDE.md): self-test while working, live test once right before the commit.
- The now-unneeded `if Mode then` / `if Log then` guards were removed in the mode-effects message step (above).
- Self-test: 431 passed (51 scenarios, 383 checks, 48 live checks). Live test: 98 passed.

## 2026-11-10 - Step 3a: tests Claude can run
- Self-test no longer writes config files: Actions.file_command / find_registered read reaper-kb.ini (read only);
  AddRemoveReaScript only for a script that is missing from the action list (it made REAPER rewrite
  reaper-kb.ini on every run). Claude starts the self-test and the live test itself (`reaper.exe -nonewinst`),
  never while a show runs.
- Unattended live test: Debug/SiSt-Live_DEBUG Run Live Test unattended.lua (not in the action list or package).
  Show workflow only, no loopbacks, no questions, never closes projects (refuses and says why), test projects stay
  open. It loads the live test with loadfile and passes "unattended" as the argument. A refused live test start
  (also the manual one) is now written to Live test report.txt, not only the console.
- Report: "N passed (S scenarios, T checks, K live checks)"; a scenario is a named group of checks ("[Group] text" in the check name), or the whole component. The live checks depend on the machine's config (keyboard effect,
  locking, screenset, windows), which probably explains 729 -> 728 (not proven).
- Strict fakes: SelfTest.with_reaper / with_gfx (an unfaked call fails, ExtState built in, real clock passes
  through, the real global always comes back). The `api` parameter is gone from 15 lib modules; code calls
  reaper.X / gfx.X directly. Actions caches command IDs per reaper table. ActionReferenceChecks.check() asks
  REAPER itself.
- Tests trimmed by "what deserves a test": 682 -> 387 tests (the Setlist's own tests wait for step 4a). The Setlist
  no longer re-runs the Gui library's tests.
- Self-test: 435 passed (387 checks, 48 live checks). Live test: 98 passed (show workflow only).

## 2026-11-10 - Roadmap steps renumbered
- Roadmap steps renumbered to match the order of work: Setlist 7->4, General repo 4->5, Extract
  packages 5->6 (5a-5d -> 6a-6d), Older scripts 6->7.

## 2026-11-10 - Bug fix: Start Show "No" left recording on
- Cause: Start Show only toggled the playback mode when the answer was Yes and the mode was "play"; with the mode
  still "rec" (e.g. from a rehearsal), No changed nothing and the routing project recorded anyway.
- Fix: the answer sets the mode both ways (Yes = rec, No = play); toggles only if the saved ExtState
  `playback_mode` differs (no longer the toolbar toggle state, which only matched because __startup.lua syncs it).
- Live test: the play round switches to "rec" before Start Show, so the "answered No" check proves No turns it off.
- Self-test: 728 passed. Live test: 152 passed (Sina, 2026-11-10).

## 2026-10-26 - Step 2b: line endings (first Claude Code session)
- Cause: core.autocrlf=true from Git for Windows' system config, so git checked files out as CRLF while the repo
  (GitHub) stored LF. Fix: .gitattributes `* text=auto eol=lf` (overrides autocrlf and goes with the repo to every
  machine). Renormalize changed nothing else; working tree checked out again: all 81 files LF.
- Repo repair: git fsck found one missing object (an old version of "Select all tracks in REC folder.lua", commit
  ddff44d), most likely lost when kDrive synced the loose object files. Copied from a clone of GitHub; git gc
  packed the 305 loose objects into one pack file.
- Claude Code started in the config folder reads both CLAUDE.md files.
- `reaper.exe -nonewinst "<script>.lua"` runs a script in the open REAPER: no second instance, not added to the
  action list. So Claude can start the self-test and read its report. Side effect: REAPER moves its window each
  time, so only in edit mode.
- Self-test: 728 passed. Live test: 152 passed.

## 2026-10-26 - Review round, switch to Claude Code
- Review of the work so far, the workflow and the tooling. Decisions: coding moves to Claude Code (started in the
  repo, CLAUDE.md holds the working rules); Docs/ in the repo is the only documentation (claude.ai project copies
  removed); new Docs/system-overview.md; approval per step; workflow order, no hurry; packaging plan confirmed
  (components are used on other configs and by others). New roadmap items: 2b line endings, live test
  simplification, clean-install test, Setup checks REAPER version/extensions; to be discussed: static analysis,
  config distribution/version control.

## 2026-10-26 - Step 2: cleanup (config part)
- Archived 5 scripts, deleted lib/SiSt-Live_Toolbar.lua (Sina). Config, with REAPER closed and *.ini-backup
  copies: 14 action-list entries with missing files removed from reaper-kb.ini (the mpl script edits the file
  on disk, and the running REAPER wrote it back); Lock/Unlock Session custom actions renamed "... all items
  (except in REC folder), envelopes, time selection, tempo and markers (deprecated)"; reaper-extstate.ini
  reduced to the sections something still reads; cycle action fixed (Sina). Self-test: 729 passed.
- Archived (git mv to _Archive): Toggle Auto Ansage, Sync WING custom control states, DEBUG Main Toolbar Switch
  Test, Apply action ImGui Rewrite, Apply action (create action). "Apply action to all open projects" stays until
  6c replaces it (Floating toolbar 1 uses it).
- Details: Lock/Unlock command IDs unchanged; cycle action = "SiSt-Live_Loop current region 4x (action marker)";
  reaper-extstate.ini lost old SiSt-Live keys, the [ProjectList] / [CustomProjectListSection] docking leftovers
  (the web remote writes ProjectList non-persistently) and 23 sections of third-party scripts not in the action
  list. Floating toolbar 32 was already fixed (item 0 = Setlist).

## 2026-10-26 - Step 2: cleanup (code part)
- Setlist: removed dead code (displayTabIdx - always true, gui.minHeight/minWidth, gui.autoscrolling - written,
  never read, own FileExists -> reaper.file_exists); CountEntryOccurrences no longer shadows `table`; renamed
  HandleIInvalid... -> HandleInvalid..., setlistLenght -> setlistLength; dialog typos ("mismatch", "conflict",
  "File not found"). Behaviour unchanged.
- __startup.lua: dead Auto Ansage call removed (the script is archived).
- SiSt-Live_Tests.lua: coverage exception for lib/SiSt-Live_Toolbar.lua removed (the file is deleted).

## 2026-10-25 - Step 1b: live test extensions
- Test selection: the live test menu shows the tests as check items (remembered); "Run selected tests" runs
  the ticked ones in one report. Order: loopbacks, then show workflow.
- Loopback test: two unsaved projects ("LB OUT" tone generator, "LB IN" receiving tracks heard on the main outs),
  both playing. Audio: REAPER's internal loopbacks = track input / hardware output 768 + n (512 is ReaRoute);
  one send per loopback, all active, volume 1 only on the one under test (a loopback nobody writes to repeats
  its last audio); 0.2 s per loopback, one melody note each; an input counts only if its meter rises. MIDI:
  pairs found by the names "LB<n> OUT / IN", one note of an A major scale per loopback through ReaSynth (ch 1,
  no shortcut fires). Tone -35 dB, silent until the level is set; FX windows closed. Offers to stop for
  inspection if it failed and the show test follows.
- Show workflow test: Region Looper (first LOOP region, starts the looper if needed, next pass, Stop loop with one
  final pass, end); only the routing project and the active song play; projects opened into the loopback tabs
  ("noprompt:"); Setlist test mode (ExtState "TestMode": autosave neither read nor written).
- SelfTest: quiet steps, progress window (top center, amber, shows the step before running it; closing it stops
  the test), after_report (the close question comes after the report, with the result).
- Debug/SiSt-Live_DEBUG List audio and MIDI devices.lua (read only).

## 2026-10-25 - Step 1 complete (bug fixes)
- 1.7 REAPER starts in edit mode: __startup.lua runs Apply current mode with "startup" (always edit, all effects
  except locking, which stays as saved per project). ModeEffects option `except` (skipped with a reason, self-test).
  Tested first: projects are already open when __startup.lua runs.
- 1.5 Setlist: projects without an end marker show "--:--" and no progress indicator (no crash before: Lua's /
  gives infinity). No fallback to GetProjectLength (re-check in step 4).
- Dropped: 1.6 (Start Song region match "contains" is fine; rethink in step 7), 1.8 (REAPER already moves
  off-screen gfx windows onto the screen).
- Found on the way: files written twice from the same staging path arrived as the old version (not kDrive).
- Docs moved into the repo (Docs/), kept in the claude.ai project as well.

## 2026-10-25 - 1.4 Toolbar "off" indicator
- `or nil` removed from the toggle expression: toggle buttons that are off show the dim indicator bar.

## 2026-10-25 - 1.3 Workflows without the fixed debugger path
- Removed the dofile of the VS Code debugger (one laptop's path, one extension version). Proper debugger support
  is planned in step 3.

## 2026-10-25 - 1.2 Mode-effect failures are visible
- Failed effects are logged as warning/error (log file; the console stays closed on stage) instead of debug.
- ModeEffects.apply_and_report: used by every place that switches or re-applies the mode (Toggle, Apply current
  mode, Status Display mode/retry buttons, Configure modes); a dialog lists failed effects with the log path.
- Toggle action: dialog in show mode if the effects can't run at all (uniform handling: step 3 loader).
- Theme effect: checks that the file exists before "already active" (REAPER keeps reporting a renamed or deleted
  theme as loaded); new self-test for it.
- Log self-test fix written again (kDrive had put back the old version).

## 2026-10-25 - 1.9 Setlist pauses its project check while rendering
- IsRendering() (reaper.EnumProjects(0x40000000)) in the Setlist: no conflict check / tab-order sync during a
  render, so the render instance isn't taken for a duplicate project. Debug log on start/finish. Tested by Sina.
- 1.1 dropped: Setlist conflict dialogs stay in show mode (they need immediate action); Cancel closing the
  Setlist goes into the resolver redesign (step 4).

## 2026-10-21 - kDrive conflict check v1.0.1
- At startup (quiet), added folders that don't exist on this computer are skipped silently (the folder list
  travels with the config); run by hand they are still reported.

## 2026-10-20 - 0.4 Show checklist + 0.5 Live test (one commit)
- Debug/Show checklist.md: only what the tests can't see (looks, no pop-ups/console, REAPER restart; recording,
  rendering, Region Looper when the step touched them).
- Debug/SiSt-Live_DEBUG Run Live Test.lua: menu (Run / Choose test folder, folder stored relative to the
  config). Closes other projects (asks first), opens every .rpp of the test folder in alphabetical order, checks
  their action markers, edit -> show, then twice (playback mode play, then rec): Start Show, Start Song, end
  marker Project End Handler, move to previous project, end marker NO STOP; show -> edit. Rec round: Start Show
  records routing, Start Song and NO STOP record, the other end handlers only play. Cleanup: stop, playback mode
  play, edit mode, recorded items removed and their files deleted. Report: Data/SiSt Libraries/Live test
  report.txt.
- Test projects: one with "ROUTING" in the name; at least three songs with =START (not at 0) and the end marker
  >= 60 s after =START; one song (not the last) with the Project End Handler marker, another with NO STOP; they
  record into the test folder.
- lib/SelfTest.lua: run_scenario (run / wait / check steps, required steps, cleanup rows), configurable report
  file name, computer name removed from the report header.

## 2026-10-20 - 0.3 dropped
- Computer name in the log file: written, then reverted (not relevant).

## 2026-10-20 - Log self-test fix
- The "debug off" test no longer fails when debug logging was on before the test.

## 2026-10-20 - 0.2b kDrive conflict check (SiSt-Local)
- Scripts/SiSt-Local/SiSt_Check kDrive conflict copies.lua: standalone, read only. Always checks the whole config
  incl. .git. By hand: menu (Check now / Add folder... / Remove folder), result in the console. Added folders:
  only inside kDrive (picker starts there), confirmation after adding, full paths in ExtState. No automated
  tests.
- __startup.lua runs it quietly: loadfile(path)("quiet") (no global; a missing file doesn't break the rest of
  the startup); console only if something is found.

## 2026-10-20 - 0.2a Fail counter
- ActionReferenceChecks.results(): one FAIL row per broken reference; "references checked" moved to the
  diagnostics.

## 2026-10-20 - 0.2 Self-Test on one generic runner
- New: lib/SelfTest.lua, lib/SiSt-Live_Tests.lua (SiSt-Live's test list), Debug/SiSt-Live_DEBUG Run all
  self-tests.lua (temporary; moves to SiSt Libraries in 6a).
- Changed: DEBUG Run Self-Test (registers + runs SiSt-Live's list); Setlist (SelfTestResults(), Alt start
  prints FAIL lines + summary); Status Display, Toolbar, Setup use the SELFTEST_COLLECT switch instead of their
  own *_SELFTEST_ONLY globals; Setup registers the test list and provides the new lib files.
- Coverage exceptions: lib/SiSt-Live_Tests.lua (the list itself), lib/SiSt-Live_Toolbar.lua (deleted in step 2).
- Result: 724 passed, only the 3 known config FAILs.

## 2026-10-20 - 0.1 Action reference checks
- lib/ActionReferenceChecks.lua (read only, future shared module): config check in "DEBUG Run Self-Test" (named
  command IDs in reaper-kb.ini, reaper-menu.ini, reaper-mouse.ini, S&M_Cyclactions.ini, S&M.ini must exist;
  script files too; unused registered scripts with missing files listed).
- Debug/SiSt-Live_DEBUG Check action markers.lua (not shipped; moves to Batch Project Tools in 6c).
- Findings (fixed in roadmap step 2): toolbar 32 button, cycle action steps, unused entries with missing files.

## 2026-10-20 - Step -1 Prepare
- Repo pushed, tag `pre-refactor` set, .ini files backed up, roadmap saved.
