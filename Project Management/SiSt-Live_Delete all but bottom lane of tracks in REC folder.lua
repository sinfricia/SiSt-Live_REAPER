-- @noindex

function SelectTracksByKeyword(track_keyword, exclusive, precise, isFolder, fullSearch, proj)
   if not proj then proj = 0 end

   if exclusive then
      reaper.Main_OnCommandEx(40297, 0, proj) --Track: Unselect (clear selection of) all tracks
   end

   local tracks_with_keyword = {}
   local tracks_to_select = {}
   local track_count = reaper.CountTracks(proj)
   for i = 0, track_count - 1 do
      local track = reaper.GetTrack(proj, i)
      local _, track_name = reaper.GetTrackName(track)

      local condition = track_keyword == track_name
      if not precise then
         condition = track_name:find(track_keyword)
      end

      if condition then
         reaper.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
         table.insert(tracks_with_keyword, track)
         if isFolder then
            reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_SWS_SELCHILDREN"), 0, proj)
            local sel_tr_count = reaper.CountSelectedTracks(proj)
            for i = 0, sel_tr_count - 1 do
               local tr = reaper.GetSelectedTrack(proj, i)
               table.insert(tracks_to_select, tr)
            end
         else
            table.insert(tracks_to_select, track)
         end

         if not fullSearch then
            return tracks_to_select, tracks_with_keyword
         end
      end
   end

   reaper.Main_OnCommandEx(40297, 0, proj) --Track: Unselect (clear selection of) all tracks
   for _, tr in pairs(tracks_to_select) do
      reaper.SetTrackSelected(tr, 1)
   end

   return tracks_to_select, tracks_with_keyword
end

function Main()
   local recTracks = SelectTracksByKeyword("REC", true, false, true, false)

   if not next(recTracks) then
      reaper.MB("No tracks found in REC folder.", "Error", 0)
      return
   end
   reaper.Main_OnCommand(42689, 0) --Track lanes: Delete lanes with no media items

   local numLanes = reaper.GetMediaTrackInfo_Value(recTracks[1], "I_NUMFIXEDLANES")

   for _, tr in ipairs(recTracks) do
      local currNumLanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
      if currNumLanes ~= numLanes then
         reaper.MB("Not all tracks have the same number of lanes. Please check before running the script again.", "Error",
            0)
         return
      end
   end


   for i = 1, numLanes - 1 do
      reaper.Main_OnCommand(42501, 0) --Track lanes: Delete lane at top of track (including media items)
   end

   reaper.Main_OnCommand(42801, 0) --Track lanes: Reset all lane names
   reaper.Main_OnCommand(42799, 0) --Track lanes: Play all lanes
   reaper.UpdateItemLanes(0)
end

reaper.Undo_BeginBlock()
Main()
reaper.Undo_EndBlock("Delete all but bottom lane of tracks in REC folder", -1)
