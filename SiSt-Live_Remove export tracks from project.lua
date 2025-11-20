local trCount = reaper.CountTracks()

local exportTracks = {}
for i = 0, trCount - 1 do
   local tr = reaper.GetTrack(0, i)

   local _, trName = reaper.GetTrackName(tr)
   local trNameLower = string.lower(trName)
   local parentTr = reaper.GetParentTrack(tr)
   local parentName = ""
   if parentTr then
      _, parentName = reaper.GetTrackName(parentTr)
   end
   local parentNameLower = string.lower(parentName)


   if trNameLower:find("^export") or parentNameLower:find("^export") then
      table.insert(exportTracks, tr)
   end
end

for _, tr in ipairs(exportTracks) do
   reaper.DeleteTrack(tr)
end
