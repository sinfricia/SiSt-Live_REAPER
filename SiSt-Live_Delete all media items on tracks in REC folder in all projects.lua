function Msg(input)
    local str = tostring(input)
    reaper.ShowConsoleMsg(str .. "\n")
end

-- Main script
reaper.Undo_BeginBlock() -- Begin undo block

local function ProcessProject(proj)
    reaper.SelectProjectInstance(proj)

    local trackCount = reaper.CountTracks(proj)

    for i = 0, trackCount - 1 do
        local track = reaper.GetTrack(proj, i)
        if track then
            -- Check if the track is named "REC" and is a folder track
            local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            local isFolder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1

            if isFolder and trackName == "REC" then
                reaper.SetOnlyTrackSelected(track)
                reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_SWS_SELCHILDREN2"), 0, proj) -- _SWS_SELCHILDREN2
                reaper.Main_OnCommandEx(42796, 0, proj)                                        -- Track lanes: Delete all lanes (including media items)
                reaper.Main_OnCommandEx(40297, 0, proj)                                        -- Track: Unselect (clear selection of) all tracks
            end
        end
    end
end

local curr_proj = reaper.EnumProjects(-1)

-- Iterate through all open projects
local projectIndex = 0
while true do
    local proj = reaper.EnumProjects(projectIndex)
    if not proj then break end -- No more projects
    ProcessProject(proj)
    projectIndex = projectIndex + 1
end

reaper.SelectProjectInstance(curr_proj)

reaper.Undo_EndBlock("Delete items on tracks in REC folder", -1) -- End undo block
reaper.UpdateArrange()                                           -- Refresh the arrangement view
