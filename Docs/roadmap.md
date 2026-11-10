# SiSt-Live roadmap

What's still to do. Reasons and rules: Docs/design-decisions.md. Finished work: Docs/completed-tasks.md
(a finished step's section moves there; the Status keeps the list of done steps).

## Status

- Done: step -1, step 0, step 1, step 1b, step 2, step 2b, step 3a, step 3 loader (module path line), step 3 mode-effects message (Mode.apply), step 3 mouse mode effect (show protection).
- Next: the rest of step 3, then step 4.
- Bug fix 2026-11-10: Start Show "No" now switches recording off (see completed tasks).

## Step 3: Simplify and prepare generalization (behaviour unchanged)

### Rest of step 3

In this order (decided 2026-11-10): decisions first, core cleanups before the things that build on them, the live
test and the DEBUG actions last. Done so far: editor setup (nothing to do in the repo), static analysis (dropped),
show protection decision (the mouse mode effect, see completed tasks).

1. Gui: Zoom (repeated in Setlist, Status Display, Toolbar); popup_menu (menu at the mouse without a window, built
   on Window.build_menu; the live test uses it).
2. Action IDs (see design decisions): lookup by file name (verify the API first; test SWS CF_EnumerateActions as
   the lookup, its script names are "Script: <file>.lua", with reaper-kb.ini as the fallback, today's way; Sina
   wants that tested only at this step), per-package declaration table, one on-demand check in Self-Test; remove
   Actions.require_native from the Screenset, Fullscreen and KeySection effects; the self-test then reports the native
   actions as one line per group ("10 window set actions ok"), not one line per action (Sina, 2026-11-10); split Actions into
   general part + SiSt-Live's table. Script registration moves to Setup (belongs with item 6).
3. Per-mode setting descriptions (on/off, number with range, choice, custom with "take current"), storage per
   mode once; keep the Windows effect's "never set = default" vs "empty = none"; the text dialog becomes one
   renderer, usable by the future configuration window.
4. Save current look for a mode (2026-11-10; builds on 3): one action/button "Save current state as SHOW (EDIT)
   mode" takes the current theme, TCP / MCP / transport layouts and screenset (saves the window set into the
   mode's slot) into the current mode's settings, built on "take current". Later also a button in the
   configuration window. NO autosave of theme/layouts/screenset (a window closed by accident on stage would
   become the new show look); SiSt-Live window positions keep autosaving as today.
5. Logging in one go: make shared candidates general (Theme.configure: show/edit accents; Log.configure:
   show-mode console rule, file, section); global debug switch for all packages, SiSt-Live's mode sets a global
   "quiet console" flag that Log respects. (The VS Code debugger helper was dropped, 2026-11-10: see design
   decisions, "Editor".)
6. Setup as the entry point for checks, in this order: Status Display / Toolbar debug-on-open test runs switch to
    SelfTest; Setup becomes the entry point for checks (installation, tests, action markers) and registers the
    scripts in the action list (from 2); then remove the DEBUG actions one by one (approval for each).
7. After 2: simplify the live test. Action IDs by file name instead of 8 literal IDs; general helpers (relative
    paths, file lists, folder picker, close all projects) into the libraries; one FX name each for Tone Generator
    / ReaSynth; split into a short main file + LiveTest/Loopback.lua, Show.lua, Looper.lua. The melodies stay.


## Step 4: Setlist

### 4a: rework (behaviour unchanged except the conflict resolver)
First, so every feature below is built once on the new structure.

- Redesign the conflict resolver (Sina, 2026-10-25). There should never be a reason to close the Setlist because of a
  conflict: Cancel must not close it (today it does). Dialogs stay, also in show mode.
- First tests recording the current behaviour of the project-tab check (incl. the wrong-removal case).
- Split into data (parse/serialize/autosave), sync (pure, tested) and view; use win.mouse.
- Right-click menus use Window.build_menu.
- Project length: test again whether reaper.GetProjectLength is reliable now (the code says it wasn't; API may
  have changed) and decide on a fallback for projects without an end marker.
- The live test loads the test setlist through the Setlist's own loading code.

### 4b-4f: features (each its own commit, decided 2026-11-10)
- 4b No locking in show mode: everything works in show mode; destructive actions (remove entry, reset, load
  setlist) ask for confirmation while in show mode.
- 4c Autosave: no question and no automatic load at start (loading also asks to open the previous projects).
  The Setlist starts from the open projects; "Restore last setlist" in the menu brings the previous session's
  list back (and offers to open missing projects). The previous session's autosave must survive the first change
  of the new session (own file until the next session). "Reset setlist" in the menu. All launch modifiers removed
  (Shift = autosave, Ctrl = window state -> "Return to default position", Alt = self-tests -> step 3 self-test).
- 4d Text entries edited in place in the list, no popup (lib/Gui TextField, built for this).
- 4e Multi-selection of entries (move / remove several).
- 4f Indicators per project: loop, no stop at end, no end (manual next), with tooltips. One shared "what does
  this project do at its end" scan (LOOP regions, which Project End Handler the end marker calls), also used by
  the action-marker check.

## Step 5: General repo and SiSt-Local

- DECISIONS first: index name and categories (fixes install paths and _RS IDs for good), working copy location,
  SiSt-Local packaging, may SiSt-Local use the SiSt Libraries (then the kDrive check uses Gui popup_menu).
  Needs access to the repo on the main install.
- SiSt-Local into the repo, published via ReaPack.
- ID migration script: old -> new _RS IDs in custom actions, toolbars, keys, MIDI, mouse modifiers, cycle
  actions. REAPER closed, backup first, once per installation, reference check before and after.
- __startup.lua loads the kDrive check and Apply current mode by path: update them if the scripts move.
- Test the Project End Handlers right away (they use "Move edit cursor..." from SiSt-Local).
- Candidate shared function: project start/end respecting time 0 / =START / end markers (4+ users). To check.

## Step 6: Extract packages

- 6a SiSt Libraries published (pure move + VERSION; Setup checks the repo is installed), with the two global
  actions. DECISION: namespace for the modules (e.g. require("SiSt.SelfTest")) so generic names can't clash?
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
- Setup checks the minimum REAPER version and the required extensions (SWS, js_ReaScriptAPI, ReaImGui).
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
- Setlist: link text entries to projects (2026-11-10): a linked text entry moves with its project when
  reordering; an unlinked one keeps its place in the list.
- Configuration window (setting descriptions + Gui), replacing the text dialog. Needs a checkbox widget (also for
  the live test's test selection).
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
- TO BE DISCUSSED: how the config is distributed (whole portable install, config file, ReaPack), and whether the
  config files (reaper-kb.ini etc.) get version control (today config changes leave no history).

## Open decisions (at their step)

- 5: index name + categories, working copy, SiSt-Local packaging, may SiSt-Local use the SiSt Libraries?
- 6a: namespace for the shared modules?
- 6c: Batch Project Tools design.
- 6d: Toolbar package name.
- 7: Start Song start condition (preferred: playhead before =START instead of the "SONG ANNOUNCEMENT" region).
- 8: can ReaPack's API install single packages?
- Later: readable action markers design (a or b); what the Status Display shows; config distribution and version
  control for the config files.
