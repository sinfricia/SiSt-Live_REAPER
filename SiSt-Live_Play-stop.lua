function Msg(input)
    local str = tostring(input)
    reaper.ShowConsoleMsg(str .. "\n")
end

-- Function to find a project tab by name
function FindProjectByName(keyword)
    local index = 0
    local project, _ = reaper.EnumProjects(index)
    while project do
        local proj_name = reaper.GetProjectName(project)
        if proj_name:find(keyword) then
            return project
        end
        index = index + 1
        project = reaper.EnumProjects(index)
    end
    return nil
end

local rout_proj = FindProjectByName("ROUTING")
local curr_proj = reaper.EnumProjects(-1)
local stop_states = { [0] = true, [2] = true, [6] = true }

if not rout_proj then goto skip end

if rout_proj ~= curr_proj then
    local rout_playstate = reaper.GetPlayStateEx(rout_proj)
    local rout_proj_is_not_running = stop_states[rout_playstate] or false
    if rout_proj_is_not_running then
        reaper.Main_OnCommandEx(1007, 0, rout_proj) --play
    end
end

::skip::

local playstate = reaper.GetPlayState()

local proj_is_not_running = stop_states[playstate] or false

if proj_is_not_running then
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS6e8c689104921020fedc41c31c49e266ebf1f76e"), 0) --Script: SiSt-Live_Stop all projects (ignore Routing project).lua
    reaper.Main_OnCommandEx(1007, 0, 0)                                                                --play
else
    reaper.Main_OnCommandEx(1016, 0, 0)                                                                --stop
end
