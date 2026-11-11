-- @noindex
-- Diagnostic: what the Region Looper publishes. Run it while a loop plays; the report is
-- Data/SiSt Libraries/Looper state.txt (in the config folder).
local out = {}
local function log(s) out[#out + 1] = s end

local cmd = reaper.NamedCommandLookup("_RS4b8f2fbad573fedb9c49f9ecfde963356869420f")
log("Region Looper action (command " .. tostring(cmd) .. "), toggle state: " .. tostring(reaper.GetToggleCommandState(cmd)) ..
   " (1 = running, 0 = not running, -1 = no state)")
log("PublishLoopPass defined in the running Looper: not visible from here; 'LoopPass' being found below proves it.")

local i = 0
while true do
   local proj, path = reaper.EnumProjects(i)
   if not proj then break end
   local _, name = reaper.GetSetProjectInfo_String(proj, "PROJECT_NAME", "", false)
   local rv1, v1 = reaper.GetProjExtState(proj, "SiSt-Live", "LoopPass")
   local rv2, v2 = reaper.GetProjExtState(proj, "SiSt-Live", "RegionLooping")
   local loops = {}
   for m = 0, reaper.CountProjectMarkers(proj) - 1 do
      local _, isrgn, pos, rgnend, mname = reaper.EnumProjectMarkers2(proj, m)
      if isrgn and mname:find("^LOOP") then loops[#loops + 1] = mname .. " " .. string.format("%.1f-%.1f", pos, rgnend) end
   end
   log(string.format("[%d] %s | playState %d | pos %.1f | LoopPass: found=%d [%s] | RegionLooping: found=%d [%s] | loop regions: %s",
      i + 1, name, reaper.GetPlayStateEx(proj), reaper.GetPlayPositionEx(proj), rv1, v1, rv2, v2,
      #loops > 0 and table.concat(loops, ", ") or "none"))
   i = i + 1
end

local dir = reaper.GetResourcePath() .. "/Data/SiSt Libraries/"
local f = io.open(dir .. "Looper state.txt", "wb")
if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. table.concat(out, "\n") .. "\n") f:close() end
