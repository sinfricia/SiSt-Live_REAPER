function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

------OPTIONS------
local useOnlyGenericTemplate = false
local GenericTemplateName = "IVS_Export"
-------------------

function FileExists(path)
   local f = io.open(path, "r")
   if f then
      f:close()
      return true
   else
      return false
   end
end

function HasProjExport()
   local exisitingExportFound = false
   local trCount = reaper.CountTracks(0)

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
         exisitingExportFound = true
         break
      end
   end

   return exisitingExportFound
end

function Main()
   if HasProjExport() then
      reaper.MB("Project already contains Export Tracks.", "Error", 0)
      return
   end

   local shiftState = reaper.JS_Mouse_GetState(8) -- check if shift key is pressed

   local proj = reaper.EnumProjects(-1)
   local projName = reaper.GetProjectName(proj):gsub("%.[^%.]+$", "")


   local templateNameSong = GenericTemplateName .. "_" .. projName
   local ReaperPath = reaper.GetResourcePath()
   local templateFolder = ReaperPath .. "//TrackTemplates//IVS_Export//"
   local templateFile = templateFolder .. templateNameSong .. ".RTrackTemplate"


   if not FileExists(templateFile) or useOnlyGenericTemplate or shiftState == 8 then
      templateFile = templateFolder .. GenericTemplateName .. ".RTrackTemplate"
      --Msg("Using generic template")
   end

   reaper.Main_OnCommand(40296, 0) -- select all tracks
   reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_SELLASTOFSELTRAX"), 0)

   reaper.Main_openProject(templateFile)

   reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWSSNAPSHOT_CLEARFILT"), 0)
   reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWSSNAPSHOT_SEND"), 0)
   reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWSSNAPSHOT_GET1"), 0)
   reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_SELFIRSTOFSELTRAX"), 0)
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

Main()
reaper.PreventUIRefresh(-1)

reaper.UpdateArrange()
reaper.Undo_EndBlock("Import IVS_Export track template", -1)
