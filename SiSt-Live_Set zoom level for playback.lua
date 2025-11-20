local r = reaper

local v_zoom_value = 60 -- in pixels
local h_zoom_value = 40 -- in time

local tr_count = r.CountTracks(0)

for i = 0, tr_count - 1 do
   local tr = r.GetTrack(0, i)
   r.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", v_zoom_value)
end

r.TrackList_AdjustWindows(0)
r.UpdateArrange()


local cursor_pos = r.GetCursorPosition()
r.BR_SetArrangeView(0, cursor_pos - h_zoom_value / 2, cursor_pos + h_zoom_value / 2)

r.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_TVPAGEHOME"), 0)
