# SiSt-Live: instructions for Claude

REAPER Lua scripts (ReaScript) for a live playback system. This repo is Scripts/SiSt-Live inside a portable
REAPER config (synced via kDrive; the rest of the config is not in git). .claude/settings.json gives access to
the whole config folder (../..).

Read first: Docs/system-overview.md (how the system works), Docs/roadmap.md (plan + status),
Docs/design-decisions.md (rules and reasons), Docs/completed-tasks.md (history).
REAPER API: Docs/reference/ (generated, not in git). Look signatures up there; never guess.

## Working with Sina
- Approval per step: once a roadmap step is approved, implement it completely. Ask first before: anything
  outside the step; every behaviour change (one at a time, never batched); config files (.ini); anything
  outside this repo.
- Explain decisions, changes and trade-offs in detail, in plain language. Routine tool steps: one line.
  Lead with the result or decision, details after.
- Start simple, add complexity only when needed. Sina wants to understand every step.
- Check before concluding: read the script / file / API before giving advice about it.
- NEVER change anything in the Invivas WING Show folder (kDrive: ST Projekte/B_Invivas/WING Showfiles).

## Sessions
- Start: `git status` must be clean, `git fsck`; read the roadmap status.
- End of a step: Sina tests (see Testing), then Claude updates the docs (roadmap status, completed tasks),
  commits (one step = one commit) and pushes.

## Code
- Call reaper.X / gfx.X directly, never store `reaper` in a local (tests swap the global). Hot loops only,
  after measuring: copy single functions into locals inside that function (design decisions).
- No new _RS IDs in code: scripts are found by file name (design decisions, Action IDs).
- New file: add it to @provides in Setup/SiSt-Live_Setup.lua; a new lib file also gets an entry in
  lib/SiSt-Live_Tests.lua.
- Tests only where Docs/design-decisions.md (Testing) says they are worth it.
- Syntax-check every changed Lua file before handing it over.
- Naming rules: Docs/design-decisions.md (Naming).

## REAPER config files
- reaper-kb.ini, reaper-menu.ini, reaper-extstate.ini, S&M_Cyclactions.ini: edit only with REAPER CLOSED
  (REAPER rewrites them from memory); copy to <file>-backup first.
- Moving or renaming a script changes its _RS ID: run the reference check (Self-Test) before and after.
- __startup.lua and Scripts/SiSt-Local live outside this repo.

## Testing
Done = "DEBUG Run Self-Test" green + "DEBUG Run Live Test" green + Debug/Show checklist.md.
Must work after every step: the three Project End Handler custom actions, Start Show, Start Song,
mode switch both ways. Self-test report: Data/SiSt Libraries/Self-test report.txt (read it, don't ask
Sina to paste it).
