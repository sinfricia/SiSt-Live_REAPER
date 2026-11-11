# SiSt-Live: instructions for Claude

REAPER Lua scripts (ReaScript) for a live playback system. This repo is Scripts/SiSt-Live inside the portable
REAPER config; the config-wide rules (working with Sina, folders, .ini files) are in the config folder's
CLAUDE.md.

Read first: Docs/system-overview.md (how the system works), Docs/roadmap.md (plan + status),
Docs/design-decisions.md (rules and reasons). Only when needed: Docs/completed-tasks.md (history),
Docs/setlist-design.md (Setlist work).
REAPER API: Docs/reference/ (the .htm REAPER generates, not in git). Search signatures there; never guess.

## Sessions
- Start: `git status` in this repo must be clean, `git fsck`; read the roadmap status.
- End of a step: Sina tests (see Testing), then Claude updates the docs (roadmap status, completed tasks),
  commits and pushes.
- When a step is finished, its section moves out of Docs/roadmap.md in the same commit that adds its entry to
  Docs/completed-tasks.md (the Status line keeps the list of done steps).
- Commits: one approved piece = one commit (a big step may have several), with its docs changes in the same commit. Small doc fixes in between (renumbering, tidying) wait for the end of the session or the next step and are committed together, unless Sina asks for one right away.
- Commit messages are plain: no Co-Authored-By line and no Claude session link (Sina, 2026-11-10).

## Code
- Call reaper.X / gfx.X directly, never store `reaper` in a local (tests swap the global). Hot loops only,
  after measuring: copy single functions into locals inside that function (design decisions).
- No new _RS IDs in code: scripts are found by file name (design decisions, Action IDs).
- New file: add it to @provides in Setup/SiSt-Live_Setup.lua; a new lib file also gets an entry in
  lib/SiSt-Live_Tests.lua.
- Tests only where Docs/design-decisions.md (Testing) says they are worth it. They live in the component's own Tests/
  folder (Setlist/Tests/), not in the production files.
- Syntax-check every changed Lua file before handing it over.
- Naming rules: Docs/design-decisions.md (Naming).

## Code style
- New code: snake_case for functions, locals and fields (camelCase is old code; don't spread it).
- Pure functions for logic and layout (tested where worth it), thin drawing and input code around them.
- Shared code only once two places use it; until then it stays next to its user (design decisions, Shared code).
- One fix in the shared mechanism over special cases in callers (e.g. escape menu labels in Window.build_menu).
- No file I/O or full scans in a defer loop's frame; keep a flag and update it where the file changes.
- Text from users or projects (entry text, project names) is data: escape it where it reaches menus or patterns.

## Testing
Done = "DEBUG Run Self-Test" green + "DEBUG Run Live Test" green + Docs/Show checklist.md.
Must work after every step: the three Project End Handler custom actions, Start Show, Start Song,
mode switch both ways. Self-test report: Data/SiSt Libraries/Self-test report.txt in the config folder
(read it, don't ask Sina to paste it). A diagnostics error in the report is a failure, even when the summary
says 0 failed.
Claude starts the self-test itself: `reaper.exe -nonewinst "<config>/Scripts/SiSt-Live/Debug/SiSt-Live_DEBUG Run
Self-Test.lua"` (runs in the open REAPER; its window jumps). Never start tests while a show is running.
Live test the same way with `Debug/SiSt-Live_DEBUG Run Live Test unattended.lua` (show workflow only, no loopbacks,
no questions; refused if foreign projects are open). Report: Data/SiSt Libraries/Live test report.txt; wait for one
newer than the start time (a run takes about 1 minute).
After drawing changes, look at the Setlist yourself: `Debug/SiSt-Live_DEBUG Screenshot Setlist.lua` (same way) saves
Data/SiSt Libraries/Setlist screenshot.png of the open Setlist window (restart the Setlist first to load the new code).
While working, run the self-test after changes. Run the live test only once, right before a commit, after Sina has
agreed to commit.
