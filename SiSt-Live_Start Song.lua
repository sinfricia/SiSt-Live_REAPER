function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local COMMANDS = {
   40020,                                                                    --Time selection: Remove (unselect) time selection and loop points
   reaper.NamedCommandLookup("_RS033cb8751211a98df38410989a57f220990c758d"), --Script: SiSt_Move edit cursor to project start respecting time 0 and start marker.lua
   reaper.NamedCommandLookup("_RSe9dc92b9cc47367a8dec0df4b41110e3e0c60ca2"), --Script: SiSt-Live_Set zoom level for playback.lua
   40340,                                                                    -- Unsolo all tracks
   reaper.NamedCommandLookup("_RS6e8c689104921020fedc41c31c49e266ebf1f76e"), --Script: SiSt-Live_Stop all projects (ignore Routing project).lua
   reaper.NamedCommandLookup("_RSb555b86a2d8f62d6e0a533af71712cb18eb86167"), --Script: SiSt-Live_Play or record current project.lua
}


local function GetRegionInfoByName(keyword, exact)
   local _, numMarkers = reaper.CountProjectMarkers(0)

   for i = 0, numMarkers - 1 do
      local rv, isRgn, pos, rgnEnd, name, idxNumber, idx = reaper.EnumProjectMarkers(i)

      if isRgn then
         local isMatch = name == keyword and exact or name:find(keyword)

         if isMatch then
            return pos, rgnEnd, name, idxNumber, idx
         end
      end
   end
   return nil
end

local function IsPlayheadInRegion(rgnName)
   local pos, rgnEnd = GetRegionInfoByName(rgnName, true)

   local playPos = reaper.GetPlayPosition()

   if playPos >= pos and playPos <= rgnEnd then
      return true
   else
      return false
   end
end



if reaper.GetPlayState() == 0 or reaper.GetPlayState() & 2 == 2 or IsPlayheadInRegion("SONG ANNOUNCEMENT") then
   reaper.PreventUIRefresh(1)
   for _, cmd in ipairs(COMMANDS) do
      reaper.Main_OnCommand(cmd, 0)
   end
   reaper.PreventUIRefresh(-1)
end
