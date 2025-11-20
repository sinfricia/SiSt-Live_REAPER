local VSDEBUG = dofile("c:/Users/sinas/.vscode/extensions/antoinebalaine.reascript-docs-0.1.15/debugger/LoadDebug.lua")

function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

-----------------------------
---- CONSTANTS/VARIABLES ----
-----------------------------

local reaperPath = reaper.GetResourcePath()
local templatePath = reaperPath .. "/TrackTemplates"
local trackTemplates = {
   FXmute = { path = templatePath .. "/IVS_FXmute.RTrackTemplate", trCount = 1, firstTr = "auto fx mute", lastTr = "auto fx mute" },
   dcaAndMonitoring = { path = templatePath .. "/IVS_DCA and Monitoring.RTrackTemplate", trCount = 29, firstTr = "AUTO DCAs", lastTr = "__tizi" },
   oldFXauto = { path = templatePath .. "/IVS_oldFXAuto.RTrackTemplate", trCount = 3, firstTr = "auto tap delay", lastTr = "auto doubler" },
   newFXauto = { path = templatePath .. "/IVS_newFXAuto.RTrackTemplate", trCount = 6, firstTr = "auto delay sends BV (via Custom Control)", lastTr = "auto slap" },
   FXAuto = { path = templatePath .. "/IVS_FXAuto.RTrackTemplate", trCount = 10, firstTr = "AUTO FX", lastTr = "auto doubler" },
}
local undoString = "SiSt-Live_Workflows"

------------------
----- UTILITY ----
------------------
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

function FindProjectByName(keyword)
   local index = 0
   local project = reaper.EnumProjects(index)
   while project do
      local proj_name = reaper.GetProjectName(project)
      if proj_name:find(keyword) then
         return project
      end
      index = index + 1
      project = reaper.EnumProjects(index)
   end
   return nil
end

-- Helper: Convert RGB to native color
function RgbToNativeColor(r, g, b)
   return reaper.ColorToNative(r, g, b) | 0x1000000
end

function IsInTable(item, table)
   for _, it in ipairs(table) do
      if it == item then return true end
   end
   return false
end

function GetTrackItems(track)
   local items = {}
   local count = reaper.CountTrackMediaItems(track)
   for i = 0, count - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      items[#items + 1] = item
   end
   return items
end

--------------------
----- WORKFLOW -----
--------------------
function NormalizeIAndSetMonoItemsOnTrack(trackName)
   reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks
   reaper.Main_OnCommand(40289, 0) --Track: Unselect (clear selection of) all items


   SelectTracksByKeyword(trackName, true, true)
   reaper.Main_OnCommand(40421, 0) --Item: Select all items in track
   reaper.Main_OnCommand(40179, 0) --Item properties: Set take channel mode to mono (left)
   reaper.Main_OnCommand(42460, 0) --Item properties: Normalize items (peak/RMS/LUFS)...

   undoString = "Normalize and set items to mono on track '" .. trackName .. "'"
end

function ChangeItemVolumesOnTrack(trackName, dbChange, isFolder)
   dbChange = math.floor(dbChange)
   reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks
   reaper.Main_OnCommand(40289, 0) --Track: Unselect (clear selection of) all items


   SelectTracksByKeyword(trackName, true, true, isFolder)

   reaper.Main_OnCommand(40421, 0) --Item: Select all items in track
   local cmdID = 41924             --Item: Nudge items volume -1dB
   -- if dbChange > 0 then cmdID = 41925 end --Item: Nudge items volume +1dB -> for some reason it's not working...

   if dbChange > 0 then
      cmdID = reaper.NamedCommandLookup("_XENAKIOS_NUDGEITEMVOLUP") -- set to nudge 0.5dB...
      dbChange = dbChange * 2
   end

   for i = 1, math.abs(dbChange) do
      reaper.Main_OnCommand(cmdID, 0)
   end

   undoString = "Change Item Volumes On Track/ In Folder '" .. trackName .. "' by " .. dbChange .. "dB"
end

function RemoveTrack(trackName)
   SelectTracksByKeyword(trackName, true)
   reaper.Main_OnCommand(40005, 0) --Track: Remove tracks

   undoString = "Remove track '" .. trackName .. "'"
end

function PasteTrackWithRoutingFromProj(projName, trackKeyword, idx)
   local copyProj = FindProjectByName(projName)
   if not idx then idx = 0 end

   if not copyProj then return end


   local track = SelectTracksByKeyword(trackKeyword, true, true, false, false, copyProj)

   if not next(track) then return end

   local cmdCopy = reaper.NamedCommandLookup("_S&M_COPYSNDRCV1")  --SWS/S&M: Copy selected tracks (with routing)
   local cmdPaste = reaper.NamedCommandLookup("_S&M_PASTSNDRCV1") --SWS/S&M: Paste tracks (with routing) or items


   local pasteProj = reaper.EnumProjects(-1)
   reaper.SelectProjectInstance(copyProj)
   reaper.Main_OnCommandEx(cmdCopy, 0, copyProj)

   reaper.SelectProjectInstance(pasteProj)
   reaper.Main_OnCommandEx(cmdPaste, 0, pasteProj)

   reaper.ReorderSelectedTracks(idx, 0)

   undoString = "Copy track '" .. trackKeyword .. "' from project '" .. projName .. "' with routing"
end

function ReplaceInTrackName(keyword, replaceString)
   local tracksToRename = SelectTracksByKeyword(keyword)

   if not next(tracksToRename) then return end
   for _, tr in ipairs(tracksToRename) do
      local _, trName = reaper.GetTrackName(tr)
      local newTrName = trName
      if trName:find(keyword) then
         newTrName = trName:gsub(keyword, replaceString)
      end

      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", newTrName, 1)
   end

   undoString = "Replace In Track Name: '" .. keyword .. "' with '" .. replaceString .. "'"
end

function ToggleAllEnvelopesInLanes(trackName)
   SelectTracksByKeyword(trackName, true)
   reaper.Main_OnCommand(40891, 0) --Envelope: Toggle display all visible envelopes in lanes for tracks

   undoString = "Toggle all envelopes in lane for track '" .. trackName .. "'"
end

function UpdateTracksFromTemplateKeepingEnvelopes(template)
   -- loads track template from path (see table at start of file), updates tracks in project from it, then copies og envelopes to new tracks

   local focusArrange = reaper.NamedCommandLookup("_BR_FOCUS_ARRANGE_WND")
   reaper.Main_OnCommand(focusArrange, 0)

   --check if first and last track of template exist
   SelectTracksByKeyword(template.firstTr, true, true)
   if reaper.CountSelectedTracks == 0 then return end

   SelectTracksByKeyword(template.lastTr, true, true)
   if reaper.CountSelectedTracks == 0 then return end

   reaper.Main_openProject(template.path)

   reaper.Main_OnCommand(40297, 0) --Track: Unselect (clear selection of) all tracks

   SelectTracksByKeyword(template.firstTr, true, true)
   local addNextTrToSel = reaper.NamedCommandLookup("_XENAKIOS_SELNEXTTRACKKEEP")

   local ogTracks = {}
   ogTracks[0] = reaper.GetSelectedTrack(0, 0)
   for i = 1, template.trCount - 1 do
      reaper.Main_OnCommand(addNextTrToSel, 0)
      ogTracks[i] = reaper.GetSelectedTrack(0, i)
   end

   reaper.Main_OnCommand(42406, 0) --Razor edit: Clear all areas

   local razorToProject = reaper.NamedCommandLookup("_RS089629f5ff069a6159ad22b57702fa8227dcbb26")
   reaper.Main_OnCommand(razorToProject, 0)

   reaper.Main_OnCommand(41383, 0) --Edit: Copy items/tracks/envelope points (depending on focus) within time selection, if any (smart copy)
   reaper.Main_OnCommand(40285, 0) --Track: Go to next track

   reaper.SetEditCurPos(0, true, false)


   reaper.Main_OnCommand(42398, 0) --Item: Paste items/tracks
   reaper.Main_OnCommand(42406, 0) --Razor edit: Clear all areas

   for i = 0, template.trCount - 1 do
      reaper.DeleteTrack(ogTracks[i])
   end

   SelectTracksByKeyword(template.firstTr, true, true)

   for i = 0, template.trCount - 1 do
      local currTrack = reaper.GetSelectedTrack(0, 0)
      local isMuted = reaper.GetMediaTrackInfo_Value(currTrack, "B_MUTE")

      -- remove envelopes for muted tracks
      local removeAllEnv = reaper.NamedCommandLookup("_S&M_REMOVE_ALLENVS")
      if isMuted == 1 then
         reaper.Main_OnCommand(removeAllEnv, 0)
      end

      -- remove edge points created when copying
      local projLenght = reaper.GetProjectLength(0)
      for i = 0, reaper.CountTrackEnvelopes(currTrack) - 1 do
         local env = reaper.GetTrackEnvelope(currTrack, i)

         if env then
            reaper.DeleteEnvelopePointRange(env, projLenght - 0.05, projLenght + 0.05)
         end
      end

      reaper.Main_OnCommand(40285, 0) --Track: Go to next track
   end

   reaper.Main_OnCommand(40697, 0) -- Remove items/tracks/envelope points (depending on focus)

   undoString = "Update tracks from template keeping envelopes"
end

function AddNewFXToProj()
   -- used to add new tracks for Desk FX automation (via Midi CC) to a project from template "FXAuto"
   -- while leaving any tracks present in the template "oldFXauto" untouched
   SelectTracksByKeyword(trackTemplates.oldFXauto.firstTr, true)
   reaper.Main_OnCommand(40286, 0) -- Track: Go to previous track
   reaper.Main_openProject(trackTemplates.FXAuto.path)

   SelectTracksByKeyword(trackTemplates.oldFXauto.firstTr, true)
   local addNextTrackToSel = reaper.NamedCommandLookup("_XENAKIOS_SELNEXTTRACKKEEP")

   for i = 1, trackTemplates.oldFXauto.trCount - 1 do
      reaper.Main_OnCommand(addNextTrackToSel, 0)
   end

   reaper.Main_OnCommand(40005, 0) --Track: Remove tracks

   local makeLastInFolder = reaper.NamedCommandLookup("_S&M_FOLDER_LAST")

   SelectTracksByKeyword(trackTemplates.oldFXauto.firstTr, true, true)
   reaper.Main_OnCommand(40286, 0) -- Track: Go to previous track
   reaper.Main_OnCommand(1041, 0)  --Track: Cycle track folder state

   SelectTracksByKeyword(trackTemplates.FXAuto.lastTr, true, true)
   reaper.Main_OnCommand(makeLastInFolder, 0)

   undoString = "Add new FX automation tracks to project from template"
end

function UpdateTracksFromTemplateKeepingItems(template)
   -- !!before using, store template in slot 2!!
   SelectTracksByKeyword(template.firstTr, true)

   local addNextTrToSel = reaper.NamedCommandLookup("_XENAKIOS_SELNEXTTRACKKEEP")

   for i = 1, template.trCount - 1 do
      reaper.Main_OnCommand(addNextTrToSel, 0)
   end

   local applyTemplate2 = reaper.NamedCommandLookup("_S&M_APPLY_TRTEMPLATE2")
   reaper.Main_OnCommand(applyTemplate2, 0)

   undoString = "Update tracks from templat keeping items"
end

function UpdateTracksFromTemplate(template)
   -- before using, store template in slot 2
   SelectTracksByKeyword(template.firstTr, true, true)

   local addNextTrToSel = reaper.NamedCommandLookup("_XENAKIOS_SELNEXTTRACKKEEP")

   for i = 1, template.trCount - 1 do
      reaper.Main_OnCommand(addNextTrToSel, 0)
   end

   local applyTemplate2 = reaper.NamedCommandLookup("_S&M_APPLY_TRTEMPLATE_ITEMSENVS2")
   reaper.Main_OnCommand(applyTemplate2, 0)

   undoString = "Update tracks from template"
end

function ReinsertAllTimecodeGenerators()
   -- USER OPTION: Set to false to disable coloring new items
   reaper.ClearConsole()
   local colorNewItem = true
   local color_r = 255
   local color_g = 255
   local color_b = 0

   reaper.Main_OnCommand(40289, 0) --Item: Unselect (clear selection of) all items
   local selectAllLtc = reaper.NamedCommandLookup("_BR_SEL_ALL_ITEMS_TIMECODE")
   reaper.Main_OnCommand(selectAllLtc, 0)

   reaper.Main_OnCommand(40309, 0) -- Set ripple editing off


   local numSelItems = reaper.CountSelectedMediaItems(0)


   local timecodeItems = {}
   for i = 0, numSelItems - 1 do
      timecodeItems[i] = reaper.GetSelectedMediaItem(0, i)
   end

   for i = numSelItems - 1, 0, -1 do
      local item = timecodeItems[i]
      local _, chunk = reaper.GetItemStateChunk(item, "", false)

      -- Extract <SOURCE LTC ...>
      local source_chunk = chunk:match("<SOURCE LTC(.-)\n%s*>")
      if not source_chunk then goto continue end

      local startTime = source_chunk:match("STARTTIME%s+([%-%d%.]+)")
      local framerateNum, framerateDrop = source_chunk:match("FRAMERATE%s+([%d/.]+)%s+(%d)")

      if not startTime or not framerateNum then
         Msg("Timecode generator with invalid timecode detected:")
         Msg("Project: " .. reaper.GetProjectName(reaper.EnumProjects(-1)))
         goto continue
      end



      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local track = reaper.GetMediaItemTrack(item)

      reaper.DeleteTrackMediaItem(track, item) -- Delete old generator

      reaper.SetOnlyTrackSelected(track)
      reaper.GetSet_LoopTimeRange(true, false, pos, pos + len, false)
      reaper.SetEditCurPos(pos, true, false)

      reaper.Main_OnCommand(40208, 0) -- Insert new timecode generator

      reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

      -- Find new item based on position/length
      local newItem = reaper.GetSelectedMediaItem(0, 0)

      if newItem then
         local _, new_chunk = reaper.GetItemStateChunk(newItem, "", false)

         -- Replace LTC source parameters
         new_chunk = new_chunk:gsub(
            "<SOURCE LTC.-\n%s*>",
            string.format(
               "<SOURCE LTC\nSTARTTIME %s\nFRAMERATE %s %s\nSEND 0\nUSERDATA 0 0 0 0\n>",
               startTime, framerateNum, framerateDrop
            )
         )

         reaper.SetItemStateChunk(newItem, new_chunk, false)

         -- Color item (if enabled)
         if colorNewItem then
            local color = RgbToNativeColor(color_r, color_g, color_b)
            reaper.SetMediaItemInfo_Value(newItem, "I_CUSTOMCOLOR", color)
         end
      end
      reaper.SetEditCurPos(pos, true, false)

      ::continue::
   end


   undoString = "Reinsert all timecode generators"
end

function SetProjectFramerate(framerate, dropframe)
   --[[ Dropframe:
      -0, integer framerate-settings
      -1, 29.97DF when projfrbase is set to 30
      -2, 23.976 fps when projfrbase is set to 24
      -2, 29.97ND when projfrbase is set to 30  ]]

   --local dropframeLookup = { "0", "29.97DF", "23.976", "29.97ND" }
   reaper.SNM_SetIntConfigVar("projfrbase", framerate)
   reaper.SNM_SetIntConfigVar("projfrdrop", dropframe)
   --local retval, dropFrame_new = reaper.TimeMap_curFrameRate(0)
end

----------------------
----- MAIN LOGIC -----
----------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)


--NormalizeIAndSetMonoItemsOnTrack("cue")
--ChangeItemVolumesOnTrack("DOUBLES", 3, true)
RemoveTrack("auto ansage levels")
--PasteTrackWithRoutingFromProj("Song Template", "16ch guide", 1)
--ReplaceInTrackName("dFX", "DCA 16")
--AddNewFXToProj()
--UpdateTracksFromTemplateKeepingEnvelopes(trackTemplates.oldFXauto)
--UpdateTracksFromTemplateKeepingItems(trackTemplates.FXmute) -- before using, store template in slot 2
--UpdateTracksFromTemplate(trackTemplates.newFXauto)
--ReinsertAllTimecodeGenerators()
--SetProjectFramerate(25, 0)


reaper.PreventUIRefresh(-1)

reaper.UpdateArrange()
reaper.Undo_EndBlock(undoString, -1)
