-- @noindex

function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

-- Function to find a project tab by name
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

-- Function to mute/unmute tracks with a specific keyword in their name
function SetMuteTracksWithName(project, track_keyword, mute)
   local track_count = reaper.CountTracks(project)
   for i = 0, track_count - 1 do
      local track = reaper.GetTrack(project, i)
      local _, track_name = reaper.GetTrackName(track)
      if track_name:find(track_keyword) then
         reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute) -- Set mute/unmute
      end
   end
end

function SetToggleState(set)
   local toggleState
   if set then
      toggleState = set
   end
   local _, _, secID, cmdID = reaper.get_action_context()
   local prevToggleState = reaper.GetToggleCommandState(cmdID)

   if prevToggleState ~= 1 and prevToggleState ~= 0 then
      toggleState = 0
   else
      toggleState = prevToggleState ~ 1
   end

   reaper.SetToggleCommandState(secID, cmdID, toggleState)
   reaper.RefreshToolbar2(secID, cmdID)
   return toggleState
end

function Main()
   local _, _, _, _, _, _, val, _ = reaper.get_action_context()

   local toggleState
   if val == 127 then
      toggleState = SetToggleState(1)
   elseif val == 0 then
      toggleState = SetToggleState(0)
   else --not triggered by Midi
      toggleState = SetToggleState()
   end

   local project_keyword = "ROUTING"    -- Keyword to find the project
   local track_keyword = "SamplePlayer" -- Keyword to find tracks
   local project = FindProjectByName(project_keyword)

   if project then
      reaper.Undo_BeginBlock()

      SetMuteTracksWithName(project, track_keyword, toggleState)

      reaper.Undo_EndBlock("Toggle mute on SamplePlayer in Routing project", -1)
   else
      reaper.ShowMessageBox("No project found with the name containing '" .. project_keyword .. "'", "Error", 0)
   end
end

Main()
