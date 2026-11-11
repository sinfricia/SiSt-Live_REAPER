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
- Window title: "Setlist" by default; once a setlist is loaded or saved, its file name, with a `*` in front of it when the
  list differs from the file. All labels, titles and buttons are in Title Case; text that is a sentence stays a sentence.

## Behaviour

**While the Setlist runs, the open tabs are the truth.** The list follows them silently, in the same frame:
- a project opened in REAPER is added at its tab position, a closed project's entry is removed (no leftover, no undo:
  REAPER asks to save changes), a moved tab reorders the list, a project replaced in a tab (File > Open, Save As)
  updates its entry. Text entries keep their positions; linked ones move with their project.
- A project open in more than one tab gets a warning ("Warning: Project Open More Than Once") with "Keep Them Open" /
  "Close the Extra Tabs". "Keep" is remembered for those tabs (their pointers) for as long as at least two of them stay
  open; a tab of the same file that joins them, or a new duplicate after they are gone, asks again. A second instance is
  allowed but not a regular case.

**Loading a setlist** (always preparation, never during a show; refused while any project plays or records):
- The dialog shows the current list in its own order. The text entries and the open projects that are not in the loaded
  setlist (the "extras") have a checkbox: checked means keep, unchecked means remove (text entries) or close (projects);
  nothing is kept by default. Rows are tinted green (keep) or red (remove), with a "Type" column ("Project" / "Text
  Entry"). The projects that stay open and the text entries the loaded setlist has too (same text and color; it replaces
  them) are shown grey as "In Setlist", without a checkbox, so a text entry is found next to its project. The checkbox in
  the header row sets everything (a dash: only some); a swipe over several checkboxes sets them alike. Buttons: Load
  Setlist, Cancel. Kept projects and text entries go to the start of the list in their order.
- Without anything to decide there is no dialog: the setlist loads right away. Empty unsaved tabs (no file, no tracks, no
  changes) are closed without asking. Missing projects are opened in any case.
- The loaded file's text entries are kept. The replaced list becomes the autosave. The projects open one per frame and
  the closing is a step as well: the header fills with the accent color ("Loading 3 / 12") until everything is done.
- Missing files become **missing entries** without a dialog (an entry saved as missing whose file exists again becomes a
  project when a list is loaded); the status line shows a red "N Missing" chip at its left that scrolls to the first one when clicked.
- **Restore** goes through the same dialog with the autosave as the loaded setlist (the current list becomes the
  autosave, so a second Restore goes back). **Reset** asks for confirmation. First start in a new REAPER run: the list starts
  from the open projects, the last run's list becomes the autosave; a restart of the Setlist within a REAPER run keeps the
  list and follows the tabs; if they changed meanwhile, the previous list is kept as the autosave and the status line
  says so (a click on it runs Restore).

**Paths:** a setlist stores absolute paths. When loading, a project is first looked up by file name in the setlist file's
own folder (not in subfolders: archived copies may live there), then at the stored path.

**Text entries:** free by default, optionally **linked** to the project above or below. Content: labels, reminders,
instructions. They look the same; the user colors them (no default color, only a faint tint).
- **Linking:** right-click: Link to Project Above / Below, Unlink. Text entries in between are linked too, in the same
  direction (`Data.link_chain`). The field is `link = "above" | "below"` in the setlist file; a link that does not reach a
  project through linked text entries is ignored (`Data.block_of`). A project and its linked text entries are a **block**
  that moves as one: dragging the project, reordering tabs (`Sync.follow_tabs`), a new tab goes after the block of the tab
  before it. A text entry dropped between the entries of a block joins it (`Data.join_block`); dropped anywhere else, or
  dragged on its own out of a block, it is free. A project dropped onto one of its own text entries moves past it and the
  entries on its other side switch direction. When a project closes its text entries stay, unlinked; when a setlist is
  loaded, kept text entries keep their link only if their project is kept.
- **Editing in place:** double-click (or Edit Text in the menu) turns the text into a field (Gui/TextField, multi-line):
  Enter keeps, Esc cancels, a click elsewhere keeps, Shift+Enter is a new line, empty is not kept. The Text Entry button
  inserts "New Text" after the active project's block and starts editing it (cancelled or empty: gone again).
- **Several lines:** a text entry is one row high plus a closer line step per extra line (manual line breaks and soft
  wrapping at the window width, also while typing). The list is measured in rows (fractions allowed): scrolling,
  scrollbar, follow-scroll and drag positions work on `List.layout`.

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
  - Transport: green triangle = playing, red dot = recording (as today). **Looping**: the same slot shows `L2` (loop pass)
    instead, yellow while playing and red while recording; once the loop was stopped (the current or next pass is the
    last) `L →`. The title moves right when the label is wider than the number slot. No tooltip there. The Region Looper
    publishes the pass as "<pass>/<passes>[!]" in the project's ExtState `SiSt-Live` / `LoopPass` (`!` = stopped);
    `ProjectInfo.loop_pass` reads it. (Tried and dropped: a bar for the loop region on the row's timeline, a number of
    passes: too much noise.)
  - Chips before the length, in the size of the length text, only what differs from normal: `A` (no stop at the end, with
    a small down arrow), `M` (manual: no end handler, nothing happens at the end, with the arrow), `L` (yellow: the
    project has one or more loop regions). The normal end stays unmarked. Hover tooltips explain them.
  - Tooltips (`Widgets.tooltip_begin / tooltip / tooltip_end`): a light box with a thin dark border, shown after the mouse
    rests 0.6 s.
- **Text entries:** "--" where a project has its number, the text 80% of the project font size, starting where project
  names start; a linked one is indented by the number column (its "--" lines up with the names). A line at the left edge
  joins a block, with a hook into its first and last entry (option C of the quiz).
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
  UI/ViewState.lua        look (sizes, colors) and view state (zoom, scrolling, dragging), the list mode
  UI/List.lua             drawing the list, scrollbar, header, status line; scroll and zoom math
  UI/ListInput.lua        gestures in the list: clicks, drag and drop, entry menus, wheel, scrollbar
  UI/CommandArea.lua      the buttons below the list, the notice after a restart
  UI/LoadDialog.lua       the question when loading: what to keep of the current list
  UI/DuplicateWarning.lua the warning for a project open in more than one tab
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
- "Modified": the list differs from the last loaded or saved file (compared by the text of the list; built).
- Layout of the Setlist's own list rows: they start 15 px from the edge, the rest of the window uses a 12 px margin.
