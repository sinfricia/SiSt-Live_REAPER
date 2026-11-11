-- @noindex
--[[
SiSt-Live Setlist: State

What the Setlist's parts share while it runs. One table, required by every part that needs it:

  list          the entries (see Data.lua), in list order
  win           the Window object (created in Init)
  tab_count     number of open project tabs, refreshed every frame
  current_proj  the project of the active tab; last_project: the one of the frame before
  total_time    total length of the open projects in seconds (status line)
  quit          true: close the window and don't write the current list (a startup question was answered with "quit")
  name          the file name of the setlist that was loaded or saved last (the window title), or nil
  saved_text    the text of that setlist as it was then; modified: the list differs from it (shown as a "*" in front of the title)
  job           a load that is still opening projects, one per frame: { plan, queue, total, done, name, prev } or nil
  dialog        the question that is open, or nil: { draw = function(win) -> choice id or nil, on_choice = function(id) }.
                While it is open the window only reacts to it.
  notice        text for the status line, or nil (e.g. "Changed while the Setlist was closed: 2 new."); notice_restorable:
                a click on it restores the previous list (it was kept as the autosave)

The view's own state (scrolling, zoom, dragging, colors) is in UI/ViewState.lua.
]]

local Sync = require("Setlist.Sync")

local State = {
   list = {},
   win = nil,
   tab_count = 0,
   current_proj = reaper.EnumProjects(-1),
   last_project = nil,
   total_time = 0,
   quit = false,
   name = nil,
   saved_text = nil,
   modified = false,
   job = nil,
   dialog = nil,
   notice = nil,
   notice_restorable = false,
}
State.last_project = State.current_proj

--- The open projects as list entries, in tab order. Also refreshes total_time (shown in the status line).
function State.read_open_projects()
   local list = Sync.open_projects()
   State.total_time = Sync.total_length(list)
   return list
end

return State
