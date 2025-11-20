function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local index = reaper.GetExtState("SiSt-Live_WebRemote", "SelectedProj")

if index then
   local project = reaper.EnumProjects(tonumber(index))
   reaper.SelectProjectInstance(project)
end
