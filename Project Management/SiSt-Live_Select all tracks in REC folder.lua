-- @noindex

function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local trackCount = reaper.CountTracks(0)

reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks

for i = 0, trackCount - 1 do
   local track = reaper.GetTrack(0, i)
   if track then
      -- Check if the track is named "REC" and is a folder track
      local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      local isFolder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1

      if isFolder and trackName == "REC" then
         reaper.SetOnlyTrackSelected(track)
         reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_SELCHILDREN"), 0) -- _SWS_SELCHILDREN
      end
   end
end
