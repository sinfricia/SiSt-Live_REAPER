local function GetPlaybackMode()
    -- Define ExtState section and key
    local section = "SiSt-Live"
    local key = "playback_mode"

    -- Get the current value from ExtState
    local currentValue = reaper.GetExtState(section, key)

    -- Return "play" if the value does not exist or is empty
    if currentValue == "" then
        return "play"
    end

    return currentValue
end

local playback_mode = GetPlaybackMode()

local command = playback_mode == "play" and 1007 or (playback_mode == "rec" and 1013)

local playstate = reaper.GetPlayState()

if playstate ~= 5 then reaper.Main_OnCommandEx(command, 0, 0) end
