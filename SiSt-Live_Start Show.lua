function Msg(input)
    local str = tostring(input)
    reaper.ShowConsoleMsg(str .. "\n")
end

function Wait(seconds)
    local start = os.clock()
    while os.clock() - start < seconds do
        -- Busy-waiting loop
    end
end

-- Create a table to store all open projects
local projects = {}

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

function GetAllOpenProjects()
    local idx = 0
    while true do
        local proj = reaper.EnumProjects(idx)
        if proj == nil then break end -- No more projects
        projects[#projects + 1] = proj
        idx = idx + 1
    end
end

function SelectTracksByKeyword(track_keyword, exclusive, precise, isFolder, fullSearch)
    if exclusive then
        reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks
    end

    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetTrackName(track)

        local condition = track_keyword == track_name
        if not precise then
            condition = track_name:find(track_keyword) and true or false
        end

        if condition then
            reaper.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)

            if isFolder then
                reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_SELCHILDREN"), 0)
                fullSearch = false
            end

            if not fullSearch then
                return
            end
        end
    end
end

function ApplyActionToAllProjects(input)
    local actions = {}

    if type(input) == "table" then
        for _, action in ipairs(input) do
            local actionID = tonumber(action) -- Try to interpret input as a numeric ID
            if not actionID then
                -- If not a number, try to resolve it as a command name
                actionID = reaper.NamedCommandLookup(action)
                if actionID == 0 then
                    reaper.ShowMessageBox("Invalid command name entered.", "Error", 0)
                    return
                end
                table.insert(actions, actionID)
            end
        end
    else
        local actionID = tonumber(input) -- Try to interpret input as a numeric ID
        if not actionID then
            -- If not a number, try to resolve it as a command name
            actionID = reaper.NamedCommandLookup(input)
            if actionID == 0 then
                reaper.ShowMessageBox("Invalid command name entered.", "Error", 0)
                return
            end
            table.insert(actions, actionID)
        end
    end


    for i, proj in ipairs(projects) do
        reaper.SelectProjectInstance(proj)
        reaper.PreventUIRefresh(1)
        for _, actionID in ipairs(actions) do
            reaper.Main_OnCommandEx(actionID, 0, proj)
        end
        reaper.PreventUIRefresh(-1)
    end
end

GetAllOpenProjects()

local ACTIONS_TO_PERFORM = {
    1016,                                          -- stop
    40339,                                         -- unmute all tracks
    40340,                                         -- unsolo all tracks
    40042,                                         -- Transport: Go to start of project
    "_RS89c077bb64df764fc3d0c549de8588223d04cf01", -- Script: SiSt-Live_Select all tracks in REC folder.lua
    "_XENAKIOS_SELTRAX_RECARMED",
    40297,                                         -- unselect all tracks
    40020,                                         -- Time selection: Remove (unselect) time selection and loop points
    "_SWS_UNSETREPEAT",
    "_RSe9dc92b9cc47367a8dec0df4b41110e3e0c60ca2", -- Script: SiSt-Live_Set zoom level for playback.lua
    "_RSb432af972108e3f8f68688c31f67262bfc187262", -- Script: SiSt-Live_Remove export tracks from project.lua


}

ApplyActionToAllProjects(ACTIONS_TO_PERFORM)



-- HANDLE ROUTING PROKECT
local rout_proj = FindProjectByName("ROUTING")
if not rout_proj then
    reaper.ShowMessageBox("There seems to be no open Routing Project!", "WARNING!", 0)
    return
end

reaper.SelectProjectInstance(rout_proj)

reaper.PreventUIRefresh(1)
local retval = reaper.ShowMessageBox("Do you want to enable recording?", "Recording reminder!", 4)
local rec_toggle_id = reaper.NamedCommandLookup("_RSa9686300d4ed1b32912b2918386a4fe072559b3a")
local rec_state = reaper.GetToggleCommandState(rec_toggle_id)
if retval == 6 and rec_state == 0 then
    reaper.Main_OnCommand(rec_toggle_id, 0)
end
reaper.RefreshToolbar2(0, rec_toggle_id)

reaper.Main_OnCommandEx(3182, 0, rout_proj)                                                                     -- move project tab to position one
reaper.Main_OnCommandEx(40296, 0, rout_proj)                                                                    -- Track: Select all tracks
reaper.Main_OnCommandEx(40493, 0, rout_proj)                                                                    -- Track: Set track record monitor to on
reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_RS89c077bb64df764fc3d0c549de8588223d04cf01"), 0, rout_proj) -- Script: SiSt-Live_Select all tracks in REC folder.lua
reaper.Main_OnCommandEx(40492, 0, rout_proj)                                                                    -- Track: Set track record monitor to off

SelectTracksByKeyword("SamplePlayer", true)
reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_XENAKIOS_SELTRAX_RECARMED"), 0, rout_proj) -- Xenakios/SWS: Set selected tracks record armed


reaper.Main_OnCommandEx(40297, 0, rout_proj) -- Track: Unselect (clear selection of) all tracks
--reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_15b5927a46511843a1986ef219a57cb6"), 0, rout_proj)           -- Custom: SiSt-Live_Default project view
reaper.PreventUIRefresh(-1)
Wait(0.5)

reaper.Main_OnCommand(40861, 0)                                                                    -- Project tabs: Switch to next project tab
reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS033cb8751211a98df38410989a57f220990c758d"), 0) -- Script: SiSt_Move edit cursor to project start respecting time 0 and start marker.lua

--HANDLE LOOPING
local loop_script = reaper.NamedCommandLookup("_RS4b8f2fbad573fedb9c49f9ecfde963356869420f")
local loop_state = reaper.GetToggleCommandState(loop_script)
if loop_state ~= 1 then
    reaper.Main_OnCommand(loop_script, 0)
end

reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS78e7a74beb2c3630990fd8cc7195aa0c55b9eacb"), 0) -- Script: SiSt_Live_Play or record routing project.lua
