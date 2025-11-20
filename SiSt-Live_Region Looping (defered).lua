-- @description Automated region looping
-- @version 1.0.0
-- @author sinfricia
-- @changelog
--   Initial release
-- @about
--   Automatically loop regions named "LOOP <num_loops>" while playing. If <num_loops> is -1 or omitted, loop infinitely until disabled.
--   See script code for user options like muting specific tracks while looping or adding a final pass after disabling looping.

local r = reaper

-- USER OPTIONS
local loopMarkerColor = r.ColorToNative(255, 255, 0)|0x1000000
local finalPassMarkerColor = r.ColorToNative(255, 180, 24)|0x1000000
local loopMarkerIdx = 0
local addFinalLoopPass = true                             --when looping infinitely add one pass after repeat is disabled
local lockTimeSelectionWhileLooping = true
local tracksToProcessWhileLooping = { "cue", "timecode" } --tracks with these name will be muted while looping and unmuted again on last loop pass
local numTracksToProcess = #tracksToProcessWhileLooping
local ENABLE_TAKE_SWITCHING_FOR_REC_ITEMS = true
local debug = false
---------------
---
---CONFIG
---
local extname = "SiSt-Live"
local key = "RegionLooping"

function Msg(input)
   if not debug then return end

   local function valToStr(v, indent)
      indent = indent or ""
      if type(v) == "table" then
         local out = "{\n"
         for k, val in pairs(v) do
            out = out .. indent .. "  [" .. tostring(k) .. "] = " .. valToStr(val, indent .. "  ") .. ",\n"
         end
         return out .. indent .. "}"
      else
         return tostring(v)
      end
   end

   reaper.ShowConsoleMsg(valToStr(input) .. "\n")
end

r.ClearConsole()

local playingProjects = {}
local projectLookup = {} -- reverse lookup for fast membership check

function FindTrackByName(project, name)
   local trCount = r.CountTracks(project)
   for i = 0, trCount - 1 do
      local track = r.GetTrack(project, i)

      if not track then return nil end

      local _, trackName = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      if trackName:lower() == name:lower() then
         return track
      end
   end
   return nil -- Not found
end

function InitializePlayingProjTable(proj)
   local playingProj = {}
   playingProj.proj = proj
   playingProj.looping = false
   playingProj.loopCount = 0
   playingProj.numLoops = 0
   playingProj.loopStart = 0
   playingProj.loopEnd = 0
   playingProj.isLastPass = false
   playingProj.prevPlayPos = 0
   r.SetProjExtState(proj, extname, key, "false") -- initialize ExtState in case PostLoopCleanup couldn't run correctly

   -- Store REC-folder items that start at loop start and per-item current take index
   playingProj.recItems = {}

   playingProj.trToProcess = {}
   for i = 1, numTracksToProcess do
      local tr = FindTrackByName(proj, tracksToProcessWhileLooping[i])

      if tr then
         playingProj.trToProcess[i] = {}
         playingProj.trToProcess[i].tr = tr
         playingProj.trToProcess[i].value = r.GetMediaTrackInfo_Value(tr, "B_MUTE")
      end
   end

   return playingProj
end

function GetChildrenOfTr(proj, targetTr)
   local childTracks = {}
   local trCount = r.CountTracks(proj)
   for i = 0, trCount - 1 do
      local tr = r.GetTrack(proj, i)

      if not tr then goto skip end
      local parent = r.GetParentTrack(tr)
      if parent == targetTr then
         table.insert(childTracks, tr)
      end

      ::skip::
   end
   Msg("TRACKS:")
   Msg(childTracks)
   return childTracks
end

function GetPlayingLanes(tr)
   local numLanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
   local playingLanes = {}
   for i = 0, numLanes - 1 do
      local isPlaying = reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. i)
      if isPlaying == 1 or isPlaying == 2 then
         playingLanes[i] = true
      end
   end


   local lanesEnabled = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE")
   if not next(playingLanes) or not not lanesEnabled == 2 then
      Msg("No playing lanes or lanes disabled")
      return -1
   else
      Msg("PlayingLanes:")
      Msg(playingLanes)
      return playingLanes
   end
end

function GetPlayingItemsStartingAtPos(tr, pos, tol)
   tol = 1                                  --small tolerance to avoid rounding issues

   local playingLanes = GetPlayingLanes(tr) -- = -1 if no playing lanes

   local playingItems = {}

   local itemCount = reaper.CountTrackMediaItems(tr)
   for i = 0, itemCount - 1 do
      local item = reaper.GetTrackMediaItem(tr, i)
      local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if math.abs(ipos - pos) <= tol then
         local itemLane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
         if playingLanes == -1 or playingLanes[itemLane] then
            table.insert(playingItems, item)
         end
      end
   end

   Msg("PLAYING ITEMS:")
   Msg(playingItems)
   return playingItems
end

function SetItemsActiveTake(itemOrItems, takeIdx)
   if not itemOrItems then return 0 end

   local changed = 0
   local items = {}

   -- Normalize input
   if reaper.ValidatePtr2(0, itemOrItems, "MediaItem*") then
      items[1] = itemOrItems
   elseif type(itemOrItems) == "table" and next(itemOrItems) then
      items = itemOrItems
   else
      return 0
   end

   Msg("Switching items to take " .. takeIdx)

   for _, item in ipairs(items) do
      if reaper.ValidatePtr2(0, item, "MediaItem*") then
         local allTakesPlay = reaper.GetMediaItemInfo_Value(item, "B_ALLTAKESPLAY")
         if allTakesPlay ~= 1 then
            local takeCount = reaper.CountTakes(item)
            if takeCount > 0 then
               local idx = takeIdx % takeCount
               local currentTake = reaper.GetActiveTake(item)
               local currentIdx = -1

               if currentTake then
                  for i = 0, takeCount - 1 do
                     if reaper.GetTake(item, i) == currentTake then
                        currentIdx = i
                        break
                     end
                  end
               end

               -- Only change if different
               if currentIdx ~= idx then
                  local newTake = reaper.GetTake(item, idx)
                  if newTake then
                     reaper.SetActiveTake(newTake)
                     changed = changed + 1
                  end
               end
            end
         end
      end
   end

   return changed
end

function PostLoopCleanup(playingProj)
   local proj = playingProj.proj
   if not reaper.ValidatePtr(proj, "ReaProject*") then return end
   r.GetSet_LoopTimeRange2(proj, true, false, 0, 0, false)
   r.GetSetRepeatEx(proj, 0)
   playingProj.looping = false
   playingProj.numLoops = 0
   playingProj.loopCount = 0
   playingProj.loopStart = 0
   playingProj.loopEnd = 0
   playingProj.isLastPass = false
   playingProj.prevPlayPos = 0
   r.SetProjExtState(proj, extname, key, "false")

   for i = 1, #playingProj.trToProcess do
      r.SetMediaTrackInfo_Value(playingProj.trToProcess[i].tr, "B_MUTE", playingProj.trToProcess[i].value)
   end

   if playingProj.loopMarkerIdx then
      r.DeleteProjectMarker(proj, playingProj.loopMarkerIdx, 0)
   end

   -- clear rec items list
   playingProj.recItems = {}
   Msg("Performed post loop cleanup")
   return playingProj
end

function UpdatePlayingProjects()
   local openProjects = {}
   local i = 0
   while true do
      local proj = r.EnumProjects(i)
      if not proj then break end
      openProjects[proj] = true
      i = i + 1
   end

   -- Remove closed or stopped projects
   local j = 1
   while j <= #playingProjects do
      local proj = playingProjects[j].proj
      if proj and openProjects[proj] and r.GetPlayStateEx(proj) > 0 then
         j = j + 1
      else
         if proj then projectLookup[proj] = nil end
         PostLoopCleanup(playingProjects[j])
         table.remove(playingProjects, j)
         -- don't increment j (table shrinks)
      end
   end

   -- Add new active projects
   i = 0
   while true do
      local proj = r.EnumProjects(i)
      if not proj then break end

      local projName = r.GetProjectName(proj)
      local isRoutingProj = projName:find("ROUTING")
      if r.GetPlayStateEx(proj) > 0 and not projectLookup[proj] and not isRoutingProj then
         table.insert(playingProjects, InitializePlayingProjTable(proj))
         projectLookup[proj] = true
      end
      i = i + 1
   end
end

function GetNextLoopRegion(playPos, proj)
   if not proj then proj = 0 end

   local _, numMarkers, numRegions = r.CountProjectMarkers(proj)
   numMarkers = numMarkers or 0
   numRegions = numRegions or 0

   local total = numMarkers + numRegions

   for i = 0, total - 1 do
      local retval, isRegion, rgnStart, rgnEnd, name, idx = r.EnumProjectMarkers2(proj, i)

      if not retval then goto skip end

      local playPosInRegion = playPos >= rgnStart and playPos < rgnEnd
      if retval and isRegion and playPosInRegion then
         if not name:find("^LOOP") then goto skip end

         local numLoops = tonumber(name:match("^LOOP%s+(%d+)$"))

         if not numLoops or numLoops < 1 then numLoops = -1 end

         return numLoops, rgnStart, rgnEnd, idx
      end

      ::skip::
   end

   return nil
end

function ProcessLoop(playingProj)
   local proj = playingProj.proj

   local playPos = r.GetPlayPositionEx(proj)

   if not playingProj.looping then
      local numLoops, startPos, endPos = GetNextLoopRegion(playPos, proj)
      if not numLoops or not startPos or not endPos then return end

      if playPos >= startPos then
         Msg("Starting Loop")
         -- Entered loop region, start loop
         r.GetSet_LoopTimeRange2(proj, true, false, startPos, endPos, false)
         r.GetSetRepeatEx(proj, 1) -- enable repeat

         playingProj.looping = true
         playingProj.loopCount = 1
         playingProj.numLoops = numLoops
         playingProj.loopStart = startPos
         playingProj.loopEnd = endPos
         r.SetProjExtState(proj, extname, key, "true")

         for i = 1, #playingProj.trToProcess do
            r.SetMediaTrackInfo_Value(playingProj.trToProcess[i].tr, "B_MUTE", 1)
         end

         -- Advance REC-folder item takes on each loop
         if r.GetPlayStateEx(proj) == 1 and ENABLE_TAKE_SWITCHING_FOR_REC_ITEMS then
            local recParent = FindTrackByName(proj, "rec")
            local recTracks = GetChildrenOfTr(proj, recParent)
            playingProj.loopItems = {}
            for _, tr in ipairs(recTracks) do
               for _, item in ipairs(GetPlayingItemsStartingAtPos(tr, startPos)) do
                  table.insert(playingProj.loopItems, item)
                  SetItemsActiveTake(item, 0)
               end
            end
         end

         playingProj.loopMarkerIdx = r.AddProjectMarker2(proj, false, startPos, 0, "1", loopMarkerIdx, loopMarkerColor)
      end
   else
      -- Currently looping
      local playPosInLoop = playPos >= playingProj.loopStart and playPos < playingProj.loopEnd

      if not playPosInLoop then
         PostLoopCleanup(playingProj)
         return
      end

      if lockTimeSelectionWhileLooping and not playingProj.isLastPass then
         r.GetSet_LoopTimeRange2(proj, true, false, playingProj.loopStart, playingProj.loopEnd, false)
      end

      local newLoopMarkerName = ""
      local newMarkerColor = playingProj.isLastPass and finalPassMarkerColor or loopMarkerColor
      local rv, extStateVal = r.GetProjExtState(proj, extname, key)
      if not rv then
         r.SetProjExtState(proj, extname, key, "true")
         extStateVal = "true"
      end

      -- Handle repeat being disabled manually or via extState switch
      if (r.GetSetRepeatEx(proj, -1) == 0 or extStateVal == "false") and not playingProj.isLastPass then
         if addFinalLoopPass and not playingProj.finalPassAdded then
            playingProj.numLoops = playingProj.loopCount + 1
            r.GetSetRepeatEx(proj, 1)
            newLoopMarkerName = tostring(playingProj.loopCount) .. " - Next pass is final!"
            newMarkerColor = finalPassMarkerColor
            playingProj.finalPassAdded = true
            Msg("Repeat disabled manually or via extState")
            Msg("Next pass is final!")
         elseif not addFinalLoopPass or extStateVal == "true" then
            Msg("Loop disabled! Exiting after current pass.")
            r.GetSetRepeatEx(proj, 0)
            playingProj.isLastPass = true
         end
      end

      -- Handle new loop pass
      if playPos < playingProj.prevPlayPos then
         Msg("looping... Pass " .. playingProj.loopCount .. "/" .. playingProj.numLoops)
         playingProj.loopCount = playingProj.loopCount + 1

         -- We're in last loop -> disable loop
         if playingProj.loopCount == playingProj.numLoops then
            playingProj.isLastPass = true
         end

         newLoopMarkerName = tostring(playingProj.loopCount)
         -- Advance REC-folder item takes on each repetition (only when playing, not recording)
         if r.GetPlayStateEx(proj) == 1 and playingProj.loopItems and ENABLE_TAKE_SWITCHING_FOR_REC_ITEMS then
            SetItemsActiveTake(playingProj.loopItems, playingProj.loopCount - 1)
         end
      end

      --Handle last pass
      if playingProj.isLastPass then
         r.GetSetRepeatEx(proj, 0)
         r.GetSet_LoopTimeRange2(proj, true, false, 0, 0, false)
         playingProj.finalPassAdded = false

         for i = 1, #playingProj.trToProcess do
            r.SetMediaTrackInfo_Value(playingProj.trToProcess[i].tr, "B_MUTE", playingProj.trToProcess[i].value)
         end

         newLoopMarkerName = tostring(playingProj.loopCount) .. " - playing last pass"
      end

      r.SetProjectMarker3(playingProj, playingProj.loopMarkerIdx, false, playingProj.loopStart, 0,
         newLoopMarkerName, newMarkerColor)
   end

   playingProj.prevPlayPos = playPos
end

function Main()
   UpdatePlayingProjects()

   for i = 1, #playingProjects do
      ProcessLoop(playingProjects[i])
   end

   --[[    if debug then
      --r.ClearConsole()
      for i, playingProj in ipairs(playingProjects) do
         Msg("Tracked Project [" .. (i - 1) .. "] is active")
         Msg("Looping: " .. tostring(playingProj.looping))
         Msg("numLoops: " .. tostring(playingProj.numLoops))
         Msg("loopCount: " .. tostring(playingProj.loopCount))
         Msg("isLastPass: " .. tostring(playingProj.loopCount == playingProj.numLoops))
      end
   end ]]

   r.defer(Main)
end

function SetButtonState(set)
   local is_new_value, filename, sec, cmd, mode, resolution, val = r.get_action_context()
   r.SetToggleCommandState(sec, cmd, set or 0)
   --r.RefreshToolbar2( sec, cmd )
end

r.set_action_options(1)
SetButtonState(1)
Main()

r.atexit(
   function()
      Msg("Exiting...")
      SetButtonState(0)
      for _, p in ipairs(playingProjects) do
         PostLoopCleanup(p)
      end
      reaper.defer(function() end)
   end
)
