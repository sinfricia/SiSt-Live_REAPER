# SiSt-Live roadmap

What's still to do, in order. Reasons and rules: Docs/design-decisions.md. Finished work:
Docs/completed-tasks.md.

## Status

- Done: step -1, step 0, step 1, step 1b, step 2, step 2b.
- Next: step 3.

## Step 1b: Live test extensions - DONE 2026-10-25 (see completed tasks)

- Later: "right track in the routing session" per function (needs a naming scheme; MIDI by name first).

## Step 2: Cleanup - DONE 2026-10-26 (see completed tasks)

- Done by Claude (2026-10-26): Setlist dead code and typos; __startup.lua Auto Ansage call removed; coverage
  exception for lib/SiSt-Live_Toolbar.lua removed.
- For Sina (list given 2026-10-26):
  - git mv to _Archive: Toggle Auto Ansage (deprecated), Sync WING custom control states (test only), DEBUG Main
    Toolbar Switch Test, Apply action ImGui Rewrite, Apply action (create action). Keep "Apply action to all open
    projects" until 5c replaces it (Floating toolbar 1 uses it).
  - git rm lib/SiSt-Live_Toolbar.lua (unused old copy of ToolbarSource).
  - action-list entries with missing files: removed 2026-10-26 (Claude, in reaper-kb.ini with REAPER closed;
    the mpl script's on-disk edit was overwritten by the running REAPER). Backup: reaper-kb.ini-backup.
  - cycle action "SiSt-Live_Loop current region 4x (action marker)": fixed (Sina, 2026-10-26).
  - Lock/Unlock Session custom actions renamed to "SiSt-Live_Lock/Unlock all items (except in REC folder),
    envelopes, time selection, tempo and markers (deprecated)" (Claude, 2026-10-26; command IDs unchanged).
  - reaper-extstate.ini: cleaned 2026-10-26 (Claude, REAPER closed; backup reaper-extstate.ini-backup). Only
    sections a registered script or SiSt-Live reads are kept; removed: old SiSt-Live keys, [ProjectList] /
    [CustomProjectListSection] docking leftovers (the web remote writes ProjectList non-persistently), 23 sections
    of third-party scripts that are not in the action list.
  - Floating toolbar 32: already fixed (item 0 = Setlist).

## Step 2b: Line endings - DONE 2026-10-26 (see completed tasks)

- .gitattributes: LF for all text files. Check `git config core.autocrlf` first, so git doesn't convert back.
- Normalize once (`git add --renormalize .`) in a commit of its own, nothing else in it.
- Also check in this first Claude Code session (started in the config folder): are both CLAUDE.md files read
  from the start? Can REAPER run a script in the open instance from the command line (then Claude Code can
  start the self-test and read its report)?

## Step 3: Simplify and prepare generalization (behaviour unchanged)

- Tests: strict fakes SelfTest.with_reaper / with_gfx (an unfaked call fails; built-in ExtState and clock); api.X
  -> reaper.X module by module with unchanged assertions; then trim tests by the rule "what deserves a test";
  ActionReferenceChecks.check() switches to with_reaper.
- Self-test count: 729 passed on 2026-10-26 (15:03 run, report overwritten), 728 since (0 failed both times).
  No code change explains it; check while reworking the tests.
- Self-test must not write config files: today it registers its scripts (AddRemoveReaScript with commit) on every
  run, and that makes REAPER rewrite reaper-kb.ini (confirmed 2026-10-26). Look the actions up first; register only
  when missing.
- One loader line per script, replacing the "optional library" fallbacks and the Setlist's 3-folder lib search;
  a broken install gets one clear message. The loader auto-registers the test list.
- Mode effects can't load or run: one uniform message (log + dialog in show mode) for every place that switches
  the mode (via the loader / Mode library); then remove the special dialog from the toggle action.
- Gui: Zoom (repeated in Setlist, Status Display, Toolbar); popup_menu (menu at the mouse without a window, built
  on Window.build_menu; the live test uses it).
- Action IDs (see design decisions): lookup by file name (verify the API first), per-package declaration table,
  one on-demand check in Self-Test; remove Actions.require_native from the Screenset, Fullscreen, KeySection
  and Locking effects; script registration moves to Setup; split Actions into general part + SiSt-Live's table.
- Per-project mode effects with ownership (2026-10-25; only if still needed after the show protection decision): a
  per-project effect (today: locking) notes in each
  project's own ExtState (saved in the .rpp) that SiSt-Live changed it and the state before; going back restores
  exactly that, also for projects opened later in edit mode (Setlist / Status Display watch the projects). Only
  undoes what SiSt-Live did. Generic helper in ModeEffects, so future per-project effects use the same pattern.
- DECISION: show protection, more global than per-project locking. Preferred (Sina, 2026-10-25): a new mode
  effect "mouse modifiers" + the SHOW keyboard section: in show mode, mouse modifiers that change something are
  removed (global, not per project; later clicks could also do useful show things). To do first: confirm
  GetMouseModifier / SetMouseModifier cover the needed contexts; keep the edit modifiers safe if REAPER crashes
  or closes in show mode (fixed edit/show mouse maps as files in the config, or save before switching); list
  together what counts as "changing" (select allowed? move, trim, fades, envelopes blocked). Then decide whether
  locking is still needed at all (if not, no ownership needed for it). Other options: show screenset without an
  editable arrange view; lock every project that becomes active. (Change watch: dropped, overkill.)
- Per-mode setting descriptions (on/off, number with range, choice, custom with "take current"), storage per mode
  once; keep the Windows effect's "never set = default" vs "empty = none"; the text dialog becomes one renderer,
  usable by the future configuration window.
- Remove Window debug scaffolding (size_suffix, remembered_size, client_w/h) and the Log debug-flag cache.
- Window.parse_state: pattern parser instead of load(), tested against real stored values.
- Make shared candidates general: Theme.configure (show/edit accents), Log.configure (show-mode console rule,
  file, section).
- Global debug switch for all packages; SiSt-Live's mode sets a global "quiet console" flag that Log respects.
- VS Code debugger helper (SiSt Libraries, next to Log; 2026-10-25): finds the newest
  .vscode/extensions/antoinebalaine.reascript-docs-*/debugger/LoadDebug.lua in the user folder (no user name or
  version in code), attaches only when a switch is on (off by default, e.g. second entry in "Debug logging
  on/off"), never in show mode. Called by the loader, so every script can be debugged without extra lines.
  First check how LoadDebug.lua behaves when VS Code isn't listening and when loaded twice.
- Setup becomes the entry point for checks (installation, tests, action markers); then remove the DEBUG actions
  one by one (approval for each).
- Status Display / Toolbar debug-on-open test runs switch to SelfTest.
- Editor setup: REAPER/ImGui Lua definition files in the repo, .vscode/settings.json points at them relatively.
- TO BE DISCUSSED: static analysis (a tool reads the code without running it and reports e.g. variables used
  before they exist or misspelled names; would have caught the `songs` bug). Decide whether it is worth it.
- After the loader and the action lookup: simplify the live test. Action IDs by file name instead of 8 literal
  IDs; general helpers (relative paths, file lists, folder picker, close all projects) into the libraries; one FX
  name each for Tone Generator / ReaSynth; split into a short main file + LiveTest/Loopback.lua, Show.lua,
  Looper.lua. The melodies stay.
- DECISION: rename ExtState sections to the naming rule (Sist-Live_Setlist, SiSt-Live_Status) with a one-time
  migration, or leave them?

## Step 4: General repo and SiSt-Local

- DECISIONS first: index name and categories (fixes install paths and _RS IDs for good), working copy location,
  SiSt-Local packaging, may SiSt-Local use the SiSt Libraries (then the kDrive check uses Gui popup_menu).
  Needs access to the repo on the main install.
- SiSt-Local into the repo, published via ReaPack.
- ID migration script: old -> new _RS IDs in custom actions, toolbars, keys, MIDI, mouse modifiers, cycle
  actions. REAPER closed, backup first, once per installation, reference check before and after.
- __startup.lua loads the kDrive check and Apply current mode by path: update them if the scripts move.
- Test the Project End Handlers right away (they use "Move edit cursor..." from SiSt-Local).
- Candidate shared function: project start/end respecting time 0 / =START / end markers (4+ users). To check.

## Step 5: Extract packages

- 5a SiSt Libraries published (pure move + VERSION; Setup checks the repo is installed), with the two global
  actions. DECISION: namespace for the modules (e.g. require("SiSt.SelfTest")) so generic names can't clash?
- 5b SiSt-Live uses them (loader checks VERSION).
- 5c Batch Project Tools (design approved first): BatchProjects.run_action({cmds}, {projects, restore_tab});
  "Apply action to project tabs" with SEVERAL actions run in the chosen order; "Create 'apply to all' action"
  (also with several actions); replace the toolbar 1 button, archive the old version, move the action-marker
  check here. "Stop all projects" can be a created action; SiSt-Live keeps its "ignore Routing" version.
- 5d Toolbar package: works without SiSt-Live; move toolbar_show/edit settings and window positions.
  DECISION: package name.

## Step 6: Older SiSt-Live scripts

- Shared IsRendering() helper for the Setlist and the Region Looper (today one copy each).
- Use BatchProjects and Actions instead of copied helpers (FindProjectByName x6, GetPlaybackMode x3,
  SendMidiMessage x2, ApplyActionToAllProjects x4) and _RS literals (incl. __startup.lua).
- Replace the busy-wait in Start Show.
- Start Song: remove the misleading `exact` parameter (the match is always case-insensitive "contains").
  DECISION: start condition without a fixed region name. Preferred (Sina, 2026-10-25): by position - Start Song
  may start while the playhead is before the =START marker (no special region needed). Alternatives: region
  name as a setting, or a naming convention.
- Duplicates (Stop all / ignore Routing, Play / Play-stop, delete top / bottom lane) -> shared function + thin
  action files that KEEP THEIR FILE NAMES.
- Region Looper (both versions) into Setup's @provides.

## Step 7: Setlist

- Redesign the conflict resolver (Sina, 2026-10-25). There should never be a reason to close the Setlist because of a
  conflict: Cancel must not close it (today it does). Dialogs stay, also in show mode.
- First tests recording the current behaviour of the project-tab check (incl. the wrong-removal case).
- Split into data (parse/serialize/autosave), sync (pure, tested) and view; use win.mouse.
- Right-click menus use Window.build_menu.
- Project length: test again whether reaper.GetProjectLength is reliable now (the code says it wasn't; API may
  have changed) and decide on a fallback for projects without an end marker.
- The live test loads the test setlist through the Setlist's own loading code.

## Later / ideas

- Configuration window (setting descriptions + Gui), replacing the text dialog. Needs a checkbox widget (also for
  the live test's test selection).
- Project export workflow: more control over which track template gets imported (today
  Rendering/SiSt-Live_Import IVS_export track template.lua), easier batch rendering. Likely builds on 5c.
- SiSt-Live_Workflows: rework so repetitive tasks can be applied to many projects very easily. Overlaps with 5c:
  decide then whether it becomes part of Batch Project Tools.
- Debug logging per component: debug output only for chosen components (logger names already exist); the switch
  stores "all" or a list. After step 3/5a.
- Better problem messages than reaper.MB (copyable, formatted): short MB + details in console/log, or a small
  Gui message window. Never a modal dialog in show mode from background code.
- Reporting channel to the Status Display; possibly run the checks at startup and show
  problems there.
- Web interface (WIP), incl. its bugs: Save open project info uses project.name instead of projName
  (OpenProjects always empty); Remote - Select project with empty ExtState.
- SiSt-Live 1.0: rebuild index.xml, remove old entries.
- Before 1.0: clean-install test (fresh portable REAPER -> ReaPack -> Setup -> self-test).
- Setup checks the minimum REAPER version and the required extensions (SWS, js_ReaScriptAPI, ReaImGui).
- TO BE DISCUSSED: how the config is distributed (whole portable install, config file, ReaPack), and whether the
  config files (reaper-kb.ini etc.) get version control (today config changes leave no history).

## Open decisions (at their step)

- 3: static analysis? (to be discussed)
- Later: config distribution and version control for the config files (to be discussed)

- 3: rename ExtState sections (with migration)?
- 4: index name + categories, working copy, SiSt-Local packaging, may SiSt-Local use the SiSt Libraries?
- 5a: namespace for the shared modules?
- 5c: Batch Project Tools design.
- 3: show protection (preferred: mouse-modifier effect + SHOW keyboard; is locking still needed?).
- 5d: Toolbar package name.
- 6: Start Song start condition (preferred: playhead before =START instead of the "SONG ANNOUNCEMENT" region).
