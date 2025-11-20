-- Script to toggle between "play" and "rec" in ExtState with the key "playback_mode"
-- Also sets the toggle state for the script

-- Define ExtState section and key
local section = "SiSt-Live"
local key = "playback_mode"

-- Get the command ID of this script
local _, _, sectionID, cmdID = reaper.get_action_context()

-- Get current value from ExtState
local currentValue = reaper.GetExtState(section, key)

-- Initialize to "play" if the value does not exist
if currentValue == "" then
    currentValue = "play"
end

-- Determine the new value
local newValue
if currentValue == "play" then
    newValue = "rec"
    reaper.SetToggleCommandState(sectionID, cmdID, 1) -- Set toggle state to 1 (rec)
else
    newValue = "play"
    reaper.SetToggleCommandState(sectionID, cmdID, 0) -- Set toggle state to 0 (play)
end

-- Set the new value in ExtState
reaper.SetExtState(section, key, newValue, true) -- 'true' ensures the value is saved persistently

-- Refresh toggle state for UI
reaper.RefreshToolbar2(sectionID, cmdID)

-- Show a message in REAPER's console (optional)
--reaper.ShowConsoleMsg("SiSt-Live playback_mode set to: " .. newValue .. "\n")
