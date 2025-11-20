function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

-- Create a table to store all open projects
local projects = {}

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

local rout_proj = FindProjectByName("ROUTING")

if not rout_proj then return end

local playback_mode = GetPlaybackMode()

local command = playback_mode == "rec" and 1013 or 1007

local rout_playstate = reaper.GetPlayStateEx(rout_proj)

if rout_proj and rout_playstate ~= 5 then reaper.Main_OnCommandEx(command, 0, rout_proj) end
