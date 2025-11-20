function Msg(input)
    local str = tostring(input)
    reaper.ShowConsoleMsg(str .. "\n")
end

-- Function to find a project tab by name
function FindProjectByName(keyword)
    local index = 0
    local project = reaper.EnumProjects(index)
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

-- Function to mute/unmute tracks with a specific keyword in their name
function SetMuteTracksWithName(project, track_keyword, mute)
    local track_count = reaper.CountTracks(project)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(project, i)
        local _, track_name = reaper.GetTrackName(track)
        if track_name:find(track_keyword) then
            reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute) -- Set mute/unmute
        end
    end
end

-- Main script logic
local _, _, _, _, _, _, val, _ = reaper.get_action_context()

if val == 127 or val == 0 then
    local keyword = "ROUTING"    -- Keyword to find the project
    local track_keyword = "AUTO" -- Keyword to find tracks
    local project = FindProjectByName(keyword)

    if project then
        reaper.Undo_BeginBlock()                                        -- Begin undo block
        if val == 127 then
            SetMuteTracksWithName(project, track_keyword, 1)            -- Mute
        elseif val == 0 then
            SetMuteTracksWithName(project, track_keyword, 0)            -- Unmute
        end
        reaper.Undo_EndBlock("Mute/Unmute tracks based on MIDI CC", -1) -- End undo block
    else
        reaper.ShowMessageBox("No project found with the name containing '" .. keyword .. "'", "Error", 0)
    end
else
    reaper.ShowMessageBox("Script not triggered by MIDI CC message or no value provided.", "Error", 0)
end
