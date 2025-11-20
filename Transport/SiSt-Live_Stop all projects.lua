-- @noindex

-- Create a table to store all open projects
local projects = {}

-- Function to collect all open projects
function GetAllOpenProjects()
    local idx = 0
    while true do
        local proj = reaper.EnumProjects(idx)
        if proj == nil then break end -- No more projects
        projects[#projects + 1] = proj
        idx = idx + 1
    end
end

-- Function to apply an action to all open projects
function ApplyActionToAllProjects(input)
    local actionID = tonumber(input) -- Try to interpret input as a numeric ID
    if not actionID then
        -- If not a number, try to resolve it as a command name
        actionID = reaper.NamedCommandLookup(input)
        if actionID == 0 then
            reaper.ShowMessageBox("Invalid command name entered.", "Error", 0)
            return
        end
    end

    for i, proj in ipairs(projects) do
        reaper.Main_OnCommandEx(actionID, 0, proj)
    end
end

GetAllOpenProjects()

ApplyActionToAllProjects(1016) -- stop
