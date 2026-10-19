local r = reaper

function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

function MuteHwOut1and2()
   local trCount = reaper.CountTracks(0)

   for i = 0, trCount do
      local tr
      if i == trCount then
         tr = reaper.GetMasterTrack(0)
      else
         tr = r.GetTrack(0, i)
      end

      local outCount = r.GetTrackNumSends(tr, 1)

      for j = 0, outCount - 1 do
         local currOut = r.GetTrackSendInfo_Value(tr, 1, j, "I_DSTCHAN")
         if currOut == 0 or currOut == 1024 or currOut == 1025 then
            r.SetTrackSendInfo_Value(tr, 1, j, "B_MUTE", 1)
         end
      end
   end
end

MuteHwOut1and2()
