# SiSt-Live: completed tasks

Newest first. Open findings move into the roadmap item that fixes them. Why things are done this way:
Docs/design-decisions.md.

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
