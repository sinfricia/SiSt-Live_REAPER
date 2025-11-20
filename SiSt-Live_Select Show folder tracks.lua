function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local trackCount = reaper.CountTracks(0)

reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks


for i = 0, trackCount - 1 do
   local track = reaper.GetTrack(0, i)
   if track then
      -- Check if the track is named "Show" and is a folder track
      local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      local isFolder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
      
      local isShowFolder = trackName:find("SHOW") or trackName:find("Show")

      if isFolder and isShowFolder then
         reaper.SetTrackSelected(track, 1)
      end
   end
end
