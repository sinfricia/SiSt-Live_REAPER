# SiSt-Live roadmap

What's still to do. Reasons and rules: Docs/design-decisions.md. Finished work: Docs/completed-tasks.md
(a finished step's section moves there; the Status keeps the list of done steps).

## Status

- Done: step -1, step 0, step 1, step 1b, step 2, step 2b, step 3a, step 3 (2026-11-10, last part: simplify the
  live test; see completed tasks), step 4 (the Setlist: 4b, 4c, then the redesign 4a, 2026-11-11), step 4d (review fixes,
  2026-11-11).
- Next: step 4e (Setlist cleanup), then step 5.
- Bug fix 2026-11-10: Start Show "No" now switches recording off (see completed tasks).

## Step 4e: Setlist cleanup (review round 2026-11-11)

No behaviour change; the Setlist code gets easier to read and change.
- Split the shared `gui` table (86 fields): mouse state only from Window's `w.mouse`, layout numbers from one
  per-frame layout function, real state (scroll, drag, selection, zoom) in ViewState.
- One naming style (snake_case) in the Setlist code.
- Tests out of the production files (e.g. Setlist/Data.lua) into their own files.

## Step 5: General repo and SiSt-Local

- Before the ID migration: the config files (.ini) under version control (local git repo in the config folder,
  only the files we own, allow-list in .gitignore), so the rewrite leaves a history.
- DECISIONS first: index name and categories (fixes install paths and _RS IDs for good), working copy location,
  SiSt-Local packaging, may SiSt-Local use the SiSt Libraries (then the kDrive check uses Gui popup_menu).
  Needs access to the repo on the main install.
- DECISION moved here from 6a: namespace for the shared modules (e.g. require("SiSt.Log")), because generic names
  already collide (two Layout modules). With it, a naming cleanup: three Actions modules (lib/Actions,
  lib/SiSt-Live_Actions, Setlist/Actions), two Layout modules, generic lib names that could clash on the module path.
- SiSt-Local into the repo, published via ReaPack.
- ID migration script: old -> new _RS IDs in custom actions, toolbars, keys, MIDI, mouse modifiers, cycle
  actions. REAPER closed, backup first, once per installation, reference check before and after.
- __startup.lua loads the kDrive check and Apply current mode by path: update them if the scripts move.
- Test the Project End Handlers right away (they use "Move edit cursor..." from SiSt-Local).
- Candidate shared function: project start/end respecting time 0 / =START / end markers (4+ users). To check.

## Step 6: Extract packages

- 6a SiSt Libraries published (pure move + VERSION; Setup checks the repo is installed), with the two global
  actions. The module namespace is decided in step 5.
- 6b SiSt-Live uses them (loader checks VERSION).
- 6c Batch Project Tools (design approved first): BatchProjects.run_action({cmds}, {projects, restore_tab});
  "Apply action to project tabs" with SEVERAL actions run in the chosen order; "Create 'apply to all' action"
  (also with several actions); replace the toolbar 1 button, archive the old version, move the action-marker
  check here. "Stop all projects" can be a created action; SiSt-Live keeps its "ignore Routing" version.
- 6d Toolbar package: works without SiSt-Live; move toolbar_show/edit settings and window positions.
  DECISION: package name.

## Step 7: Older SiSt-Live scripts

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
- Routing project not found by name (2026-11-10): a flag in the project's own ExtState (saved in the .rpp, no
  paths, no naming rule), set with a toggle action that shows its state for the current project. Must be clearly
  visible: "ROUTING" badge on its Setlist entry, shown in the Status Display. The name check stays as a fallback
  for existing projects. Everything also works without a routing project (Start Show then starts/records none).
  Lives in the shared helper that replaces FindProjectByName.

## Step 8: Setup and installation (2026-11-10)

After step 6: what Setup installs depends on the package split. Ends with the clean-install test, then 1.0.
- Setup checks the minimum REAPER version (the required extensions SWS, js_ReaScriptAPI and ReaPack are checked since
  2026-11-10; ReaImGui is not a dependency, Sina, 2026-11-10).
- Setup adds the needed ReaPack repositories and installs what's missing. Verify first: ReaPack's scripting API
  can add/sync repositories; can it install single packages or only whole repositories?
- ReaPack itself: a script can't install it (nothing runs without it). The portable config ships it; for a fresh
  REAPER one manual step. Look at a startup-step download only if that's not enough (not before 1.0).
- Required devices (generalized WING detection): a setting with name patterns (e.g. "WING" MIDI in/out). Both
  problems happen today: (1) device not enabled in the preferences -> check and say exactly what to enable
  (enabling needs reaper.ini + restart; automatic only if the check isn't enough); (2) the routing project points
  at the wrong device (MIDI ports are stored by device number, which differs per machine) -> a "fix routing"
  action re-points the routing project's hardware MIDI ins/outs to the device matching the pattern.
- Clean-install test: fresh portable REAPER -> ReaPack -> Setup -> self-test.
- SiSt-Live 1.0: rebuild index.xml, remove old entries.

## To be implemented (planned, no fixed slot yet)

- Later: "right track in the routing session" per function (needs a naming scheme; MIDI by name first).
- Review the Status Display (2026-11-10): kept as it is for now (mode, mode switch, failed mode effects, missing
  libraries). Probably becomes a show health monitor (play/rec mode, devices, routing project running, disk space,
  problems from all components); decide what to show after step 8, when we know what Setup checks. Includes the
  old item "reporting channel to the Status Display; possibly run the checks at startup".
- Pre-commit check script (review round 2026-11-11): `luac -p` on changed files plus a scan for a `local` declared
  twice in one file (would have caught the Layout test bug). Runs without REAPER.
- Frame-time check (review round 2026-11-11): in debug mode the Setlist, Toolbar, Status Display and Region Looper
  log their slowest frame per minute, so per-frame regressions show up.
- Configuration window (setting descriptions + Gui), replacing the text dialog. The per-mode setting descriptions
  (decided 2026-11-10 to build them together with this window, not before: nothing needs them earlier) declare each
  setting as data (on/off, number with range, choice, custom with "take current"), storage per mode once with the
  same ExtState keys and text formats as today; keep the Windows effect's "never set = default" vs "empty = none". Needs a checkbox widget (also for
  the live test's test selection). "Take current" buttons and a "Save current look" button use the effects'
  take_current functions (built 2026-11-10). Also starts the tests (Sina, 2026-11-10): a test selection and "Run
  tests" incl. the live test; Setup's summary becomes its first section. Only then remove the DEBUG actions from the
  action list, one by one (approval for each; check what points at them first; the files stay in Debug/ so Claude
  can run them). "Check action markers" stays a separate action the user runs (about the open projects, not the
  config; moves to Batch Project Tools in 6c). Reuses the shared Gui code (Layout, the menu escaping from 4d)
  instead of own copies.
- Toolbar button for "Save current look for current mode" (Sina, 2026-11-10: later; reaper-menu.ini, REAPER closed).
- Workflows (home: Batch Project Tools, 2026-11-10; after 6c and the configuration window): general operations
  with parameters, run through BatchProjects on chosen projects: rename tracks, add tracks, change existing tracks
  (inserts / FX, automation); the functions in Project Management/SiSt-Live_Workflows.lua are the starting list.
  Invivas specifics (IVS_* templates, track names) only as saved presets, not code. GUI: pick operation, fill in
  parameters, pick projects, run. Absorbs the project export workflow (track template import, today
  Rendering/SiSt-Live_Import IVS_export track template.lua; easier batch rendering).
- Readable action markers (2026-11-10; after the action lookup by file name, step 3): today a marker must be
  `!<command ID>`, unreadable `_RS...` for scripts and broken when a script moves. Design decided then: (a)
  background script runs readable markers during playback, or (b) a tool keeps a readable label next to the ID
  and repairs the ID by file name (markers stay native). Leaning (b): native markers keep working if a script
  fails. Fits the action-marker check (Batch Project Tools).
- Project End Handlers as scripts (Sina, 2026-11-10): the three custom actions ("SiSt-Live_Project End Handler",
  "- NO STOP", "- move to previous project") become scripts. Every action marker that calls them (`!_ee13...` etc.
  in the song projects) must be updated to the new IDs, so this needs a marker rewrite over all projects (with the
  readable action markers tool / action-marker check) and the MIDI shortcuts (ch 16 notes 4 and 5) re-pointed.
  Separate goal from readable action markers; if both come close together, rewrite the markers only once.
- Shortcuts review (config work, any time, together with Sina): transport shortcuts in edit mode, MIDI editor;
  close to REAPER defaults where sensible. Pairs with the show-protection decision (step 3) and with version
  control for the config files.
- Debug logging per component: debug output only for chosen components (logger names already exist); the switch
  stores "all" or a list. After step 3/6a.
- Better problem messages than reaper.MB (copyable, formatted): short MB + details in console/log, or a small
  Gui message window. Never a modal dialog in show mode from background code.
- Web interface (WIP), incl. its bugs: Save open project info uses project.name instead of projName
  (OpenProjects always empty); Remote - Select project with empty ExtState; Save open project info crashes for a
  project path without a folder part (`project_path:match("^.+[\\/](.+)$")` returns nil, then `:gsub` on nil).

## Ideas (not decided whether we do them)

- Show control: setlist entries that send MIDI (later OSC), can be triggered by MIDI, and run REAPER actions;
  linkable to projects like text entries. Start MIDI only. Not before step 4 is done.
- TO BE DISCUSSED: how the config is distributed (whole portable install, config file, ReaPack). (Version control
  for the config files is planned in step 5.)

## Open decisions (at their step)

- 5: index name + categories, working copy, SiSt-Local packaging, may SiSt-Local use the SiSt Libraries?
  Namespace for the shared modules.
- 6c: Batch Project Tools design.
- 6d: Toolbar package name.
- 7: Start Song start condition (preferred: playhead before =START instead of the "SONG ANNOUNCEMENT" region).
- 8: can ReaPack's API install single packages?
- Later: readable action markers design (a or b); what the Status Display shows; config distribution.
