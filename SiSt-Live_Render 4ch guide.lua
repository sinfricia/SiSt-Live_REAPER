function SelectTracksByKeyword(name)
   local trackCount = reaper.CountTracks(0)
   for i = 0, trackCount - 1 do
      local track = reaper.GetTrack(0, i)
      if track then
         local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)

         if trackName == name then
            reaper.SetOnlyTrackSelected(track)
         end
      end
   end
end

reaper.Undo_BeginBlock()
SelectTracksByKeyword("4ch guide")

local show_track = reaper.NamedCommandLookup("_SWSTL_BOTH") --SWS: Show selected track(s) in TCP and MCP

reaper.Main_OnCommand(show_track, 0)
reaper.Main_OnCommand(41313, 0)                                                                      --unlock track controls
reaper.Main_OnCommand(40339, 0)                                                                      --unmute all tracks

local apply_render_preset = reaper.NamedCommandLookup("_RS3e813a26f056748422f219b8fabf7dbe13779577") --Script: Apply render preset - IVS_4chGuide.lua

reaper.Main_OnCommand(apply_render_preset, 0)

reaper.Main_OnCommand(41823, 0) --File: Add project to render queue, using the most recent render settings
--reaper.Main_OnCommand(42230, 0) --File: Render project, using the most recent render settings, auto-close render dialog

reaper.Main_OnCommand(40730, 0) --mute tracks
reaper.Main_OnCommand(41312, 0) --lock track controls
reaper.Main_OnCommand(41593, 0) --Track: Hide tracks in TCP and mixer

reaper.UpdateArrange()
reaper.Undo_EndBlock("Prepare '4ch guide' render (and add to render queue)", -1)

--reaper.Main_OnCommand(41207, 0) --Render all queued renders
