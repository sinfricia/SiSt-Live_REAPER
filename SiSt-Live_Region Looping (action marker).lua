-- ReaScript Name: Live Loop by Region Name
-- Description: Loops regions with names like "LOOP 3" when playhead enters them
-- Author: ChatGPT/SiSt
-- Version: 1.0

function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

reaper.set_action_options(3)
reaper.ClearConsole()

-- STATE
local looping = false
local loopCount = 0
local targetLoops = 0
local loopStart, loopEnd = 0, 0
local prevPlayPos = 0
local lastLoopEnd = 0
local loopRgnIdx, loopRgnName = nil, ""
local start_proj, _ = reaper.EnumProjects(-1)


-- UTILITY
function GetNextLoopRegion(playPos)
   local _, numMarkers, numRegions = reaper.CountProjectMarkers(0)
   local total = numMarkers + numRegions

   for i = 0, total - 1 do
      local retval, isRegion, rgnStart, rgnEnd, name, index = reaper.EnumProjectMarkers(i)
      if isRegion and rgnEnd > playPos then
         local loopCount = name:match("^LOOP%s+(%d+)")
         if loopCount then
            loopRgnIdx = index
            loopRgnName = name
            return tonumber(loopCount), rgnStart, rgnEnd
         end
      end
   end

   return nil
end

-- MAIN LOOP FUNCTION
function Main()
   local curr_proj, _ = reaper.EnumProjects(-1)
   if curr_proj ~= start_proj then
      return
   end

   local playPos = reaper.GetPlayPositionEx()

   if reaper.GetPlayState() < 1 or reaper.GetPlayState() == 2 or (looping and playPos < loopStart) then
      if looping then
         reaper.SetProjectMarker(loopRgnIdx, true, loopStart, loopEnd, loopRgnName)
         reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
         reaper.GetSetRepeat(0)
         targetLoops = 0
         loopCount = 0
         loopStart, loopEnd = 0, 0
         prevPlayPos = 0
         lastLoopEnd = 0
         looping = false
         return
      end
      goto skip
   end

   if looping and reaper.GetSetRepeat(-1) == 0 then
      return
   end

   if not looping and playPos > lastLoopEnd then
      if lastLoopEnd > 0 then
         reaper.SetProjectMarker(loopRgnIdx, true, loopStart, loopEnd, loopRgnName)
         loopStart = 0
         loopEnd = 0
         return
      end

      -- Not currently looping: look for next region
      local loops, startPos, endPos = GetNextLoopRegion(playPos)
      if loops > 1 then
         if playPos >= startPos and playPos < endPos then
            -- Entered loop region
            looping = true
            loopCount = 1
            targetLoops = loops
            loopStart = startPos
            loopEnd = endPos
            reaper.GetSet_LoopTimeRange(true, false, loopStart, loopEnd, false)
            reaper.GetSetRepeat(1) -- enable repeat
            --local newRgnName = "LOOP " .. tostring(loopCount) .. " of " .. tostring(targetLoops)
            --reaper.SetProjectMarker(loopRgnIdx, true, loopStart, loopEnd, newRgnName)
         end
      end
   else
      -- Already looping
      if playPos < prevPlayPos then
         loopCount = loopCount + 1
         --local newRgnName = "LOOP " .. tostring(loopCount) .. " of " .. tostring(targetLoops)
         --reaper.SetProjectMarker(loopRgnIdx, true, loopStart, loopEnd, newRgnName)


         if loopCount == targetLoops then
            reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
            reaper.GetSetRepeat(0)
            targetLoops = 0
            loopCount = 0
            prevPlayPos = 0
            lastLoopEnd = loopEnd
            looping = false
         end
      end
   end

   prevPlayPos = playPos
   ::skip::

   reaper.defer(Main)
end

reaper.Undo_BeginBlock()
local curr_proj, _ = reaper.EnumProjects(-1)
Curr_proj_name = reaper.GetProjectName(curr_proj)
Msg(Curr_proj_name)

Main()

reaper.atexit(
   function()
      if looping then
         reaper.SetProjectMarker2(start_proj, loopRgnIdx, true, loopStart, loopEnd, loopRgnName)
         reaper.GetSet_LoopTimeRange2(start_proj, true, false, 0, 0, false)
         reaper.GetSetRepeatEx(start_proj, 0)
         targetLoops = 0
         loopCount = 0
         loopStart, loopEnd = 0, 0
         prevPlayPos = 0
         lastLoopEnd = 0
         looping = false
      end
   end
)

reaper.Undo_EndBlock("Region Looping", -1)
