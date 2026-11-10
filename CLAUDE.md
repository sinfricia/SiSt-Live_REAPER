# SiSt-Live: instructions for Claude

REAPER Lua scripts (ReaScript) for a live playback system. This repo is Scripts/SiSt-Live inside the portable
REAPER config; the config-wide rules (working with Sina, folders, .ini files) are in the config folder's
CLAUDE.md.

Read first: Docs/system-overview.md (how the system works), Docs/roadmap.md (plan + status),
Docs/design-decisions.md (rules and reasons), Docs/completed-tasks.md (history).
REAPER API: Docs/reference/ (generated, not in git). Look signatures up there; never guess.

## Sessions
- Start: `git status` in this repo must be clean, `git fsck`; read the roadmap status.
- End of a step: Sina tests (see Testing), then Claude updates the docs (roadmap status, completed tasks),
  commits (one step = one commit) and pushes.
- When a step is finished, its section moves out of Docs/roadmap.md in the same commit that adds its entry to
  Docs/completed-tasks.md (the Status line keeps the list of done steps).
- Commits: one step = one commit, with its docs changes in the same commit. Small doc fixes in between (renumbering, tidying) wait for the end of the session or the next step and are committed together, unless Sina asks for one right away.

## Code
- Call reaper.X / gfx.X directly, never store `reaper` in a local (tests swap the global). Hot loops only,
  after measuring: copy single functions into locals inside that function (design decisions).
- No new _RS IDs in code: scripts are found by file name (design decisions, Action IDs).
- New file: add it to @provides in Setup/SiSt-Live_Setup.lua; a new lib file also gets an entry in
  lib/SiSt-Live_Tests.lua.
- Tests only where Docs/design-decisions.md (Testing) says they are worth it.
- Syntax-check every changed Lua file before handing it over.
- Naming rules: Docs/design-decisions.md (Naming).

## Testing
Done = "DEBUG Run Self-Test" green + "DEBUG Run Live Test" green + Docs/Show checklist.md.
Must work after every step: the three Project End Handler custom actions, Start Show, Start Song,
mode switch both ways. Self-test report: Data/SiSt Libraries/Self-test report.txt in the config folder
(read it, don't ask Sina to paste it).
Claude starts the self-test itself: `reaper.exe -nonewinst "<config>/Scripts/SiSt-Live/Debug/SiSt-Live_DEBUG Run
Self-Test.lua"` (runs in the open REAPER; its window jumps). Never start tests while a show is running.
Live test the same way with `Debug/SiSt-Live_DEBUG Run Live Test unattended.lua` (show workflow only, no loopbacks,
no questions; refused if foreign projects are open). Report: Data/SiSt Libraries/Live test report.txt; wait for one
newer than the start time (a run takes about 1 minute).
While working, run the self-test after changes. Run the live test only once, right before a commit, after Sina has
agreed to commit.
