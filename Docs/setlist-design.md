# SiSt-Live Setlist: design

Written 2026-11-11 from the design quiz with Sina (thread "Setlist redesign"). This is what we agreed to build; open
points are at the end. Build order: Docs/roadmap.md, step 4a. Rules and reasons elsewhere: Docs/design-decisions.md.

## What the Setlist is

- The song order of a show, and a navigator for the open project tabs. **Tab order = song order**; the Setlist can move
  tabs (drag an entry), and moving tabs in REAPER reorders the list.
- It is a display and navigator: jumping to a project (click) does not affect playback. Playback flow at the end of a
  song belongs to the Project End Handlers, not to the Setlist.
- Typical size: 10 to 30 projects open, at most 40 to 50. One setlist file per show, reused for similar shows.
- A "stage view" / differentiation between edit/show mode may come later.

## Words (use these on screen and in code)

- **project**: a song's REAPER project (a tab). **entry**: one row of the list. **project entry**, **text entry**
  (a missing project is a *missing entry*).
- **setlist**: the .rsl file (Save / Load). **current list**: the live list, saved continuously. **autosave**: the list
  that was replaced last, kept for **Restore**. **Reset**: the list becomes the open projects again.
- Window title: "Setlist" by default; once a setlist is loaded or saved, its file name, with `*` when the list differs
  from the file.

## Behaviour

**While the Setlist runs, the open tabs are the truth.** The list follows them silently, in the same frame:
- a project opened in REAPER is added at its tab position, a closed project's entry is removed (no leftover, no undo:
  REAPER asks to save changes), a moved tab reorders the list, a project replaced in a tab (File > Open, Save As)
  updates its entry. Text entries keep their positions; linked ones move with their project.
- A project open in more than one tab gets a warning, once, with "Keep them open" / "Close the extra tabs". "Keep" is
  remembered for exactly those tabs (their pointers) until one of them closes; a later duplicate asks again. A second
  instance is allowed but not a regular case.

**Loading a setlist** (always preparation, never during a show; refused while any project plays or records):
- Open projects that are not in the loaded setlist (the "extras") are listed in a dialog, each with a checkbox
  **Close** (default: all marked for closing) so the user chooses what to keep, plus "Close all" / "Keep all", **Load
  setlist** and **Cancel loading**. Kept extras go to the start of the list in their tab order. Missing projects are
  opened in any case. Without extras there is no dialog: the setlist just loads, with the header progress.
- Playing or recording projects cannot be an issue, because loading is refused while anything plays or records.
- The loaded file's text entries are kept; the current list's text entries are replaced. The replaced list becomes the
  autosave. Progress: the header fills with the accent color with "3 / 12" over the title while projects open.
- Missing files become **missing entries** without a dialog; the status line shows a red "N missing" chip that scrolls
  to the first one when clicked.
- **Restore** swaps the current list and the autosave (greyed out without an autosave). **Reset** and **Restore** ask
  for confirmation. First start in a new REAPER run: the list starts from the open projects, the last run's list
  becomes the autosave; a restart of the Setlist within a REAPER run keeps the list.

**Paths:** a setlist stores absolute paths. When loading, a project is first looked up by file name in the setlist file's
own folder (not in subfolders: archived copies may live there), then at the stored path.

**Text entries:** free by default, optionally **linked** to the project above or below (moves with it). They all look
the same; the user colors them. One line to begin with, wrapping later. Content: labels, reminders, instructions. Use custom text entry widget.

**Jumping:** a click on a project entry selects its tab, in both modes. "Queue Project" goes away for now.
**Selection (4e):** Ctrl+click / Shift+click with a clear selected state; plain click still jumps. Multi selection should allow batch reording, coloring, closing (deleting for text items)

## Look

- **Header:** the title as above, and the loading progress. **Status line** (under the list, above the command area):
  the missing chip on the left, "N projects | mm:ss total" on the right. The strong divider separates it from the
  command area; a faint one separates it from the list.
- **Command area** (built): sections LIST (Save, Load, Reset, Restore), INSERT (Text Entry), ZOOM (percent = reset, + above
  -), names centered, a divider after each section. Fixed layout for now.
- **Row:** number or transport indicator, name, then the indicator slot, then the length (mm:ss, "--:--" without an end
  marker). Highlights: current project, next project, text entries, drag.
  - Transport: green triangle = playing, red dot = recording (as today). **Looping**: the same slot shows `L2` (loop pass
    count) instead, in green while playing and red while recording. The loop region is also drawn as a faint yellow
    band on the row's progress track (the row is the project's timeline), also when no loop is running.
  - Indicator slot, only what differs from normal, as chips: `A` = no stop at the end (continues on its own), `M` =
    manual (no end handler, nothing happens at the end), each with a down arrow drawn as a shape. The normal end stays
    unmarked. Hover tooltips explain them.
- **Linked text entries:** a thin colored line on the left joins the linked rows (option C of the quiz).
- Text sizes and spacing: one rhythm (margin 12, buttons 8 apart, sections 28 apart).

## Code structure (decided 2026-11-11)

The rule: **the UI only reads the mouse, draws and asks questions; it never changes the list or the tabs itself.** It calls an
action. Each file says at its top what it holds.
```
Setlist/
  SiSt-Live_Setlist.lua   the glue: Init, and Frame once per frame
  Data.lua                entries, the .rsl text format, paths, list/tab index math, the current-list and autosave files
  Sync.lua                REAPER's project tabs (read, move, close) and the pure comparison of list and tabs
  Actions.lua             what the user can do to the list (insert, rename, drop, reset, restore, load, save, ...)
  State.lua               what the parts share: the list, the window, tab count, current project
  Resolver.lua            the OLD conflict resolver, temporary until the new sync replaces it
  UI/ViewState.lua        look (sizes, colors) and view state (zoom, scrolling, dragging), the list mode
  UI/List.lua             drawing the list, scrollbar, header, status line; scroll and zoom math
  UI/ListInput.lua        gestures in the list: clicks, drag and drop, entry menus, wheel, scrollbar
  UI/CommandArea.lua      the buttons below the list
  UI/Ask.lua              every dialog (questions, text input, colors, file dialogs)
```
Tests live with the code they test (`self_test()` per module, registered by the main script); `SelfTest.cases()` gives
the `t.eq` / `t.ok` style.

## Open points

- Responsiveness to the window width and a minimum window size: one pass after all planned changes (Sina). The command area
  is fixed until then. Collision handling in the Gui library (text that shortens with "...", a row placement helper)
  belongs to that pass.
- Wrapping of long text entries: rows of different heights change scrolling, follow-scroll and the scrollbar.
- Drag and drop, follow-scroll, the selected / next highlight: not discussed, they stay as they are.
- What the old conflict dialogs (still used by Restore and a restart within a REAPER run) become: replaced by the
  silent follow plus the load dialog.
- "Modified": the list differs from the last loaded or saved file (compared by content, ignoring runtime fields).
