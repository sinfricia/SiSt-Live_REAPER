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
}
State.last_project = State.current_proj

--- The open projects as list entries, in tab order. Also refreshes total_time (shown in the status line).
function State.read_open_projects()
   local list = Sync.open_projects()
   State.total_time = Sync.total_length(list)
   return list
end

return State
