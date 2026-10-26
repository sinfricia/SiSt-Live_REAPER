# SiSt-Live: completed tasks

Newest first. Open findings move into the roadmap item that fixes them. Why things are done this way:
Docs/design-decisions.md.

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
  gives infinity). No fallback to GetProjectLength (re-check in step 7).
- Dropped: 1.6 (Start Song region match "contains" is fine; rethink in step 6), 1.8 (REAPER already moves
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
  Setlist goes into the resolver redesign (step 7).

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
  self-tests.lua (temporary; moves to SiSt Libraries in 5a).
- Changed: DEBUG Run Self-Test (registers + runs SiSt-Live's list); Setlist (SelfTestResults(), Alt start
  prints FAIL lines + summary); Status Display, Toolbar, Setup use the SELFTEST_COLLECT switch instead of their
  own *_SELFTEST_ONLY globals; Setup registers the test list and provides the new lib files.
- Coverage exceptions: lib/SiSt-Live_Tests.lua (the list itself), lib/SiSt-Live_Toolbar.lua (deleted in step 2).
- Result: 724 passed, only the 3 known config FAILs.

## 2026-10-20 - 0.1 Action reference checks
- lib/ActionReferenceChecks.lua (read only, future shared module): config check in "DEBUG Run Self-Test" (named
  command IDs in reaper-kb.ini, reaper-menu.ini, reaper-mouse.ini, S&M_Cyclactions.ini, S&M.ini must exist;
  script files too; unused registered scripts with missing files listed).
- Debug/SiSt-Live_DEBUG Check action markers.lua (not shipped; moves to Batch Project Tools in 5c).
- Findings (fixed in roadmap step 2): toolbar 32 button, cycle action steps, unused entries with missing files.

## 2026-10-20 - Step -1 Prepare
- Repo pushed, tag `pre-refactor` set, .ini files backed up, roadmap saved.
