function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local toggleState

function SendMidiMessage(device_name_keyword, msg_type, midi_ch, value1, value2) -- see msg_types table for msg_type syntax
   -- Find the first MIDI output that contains device_name_keyword (case-insensitive)
   device_name_keyword = device_name_keyword:lower()
   local numOuts = reaper.GetNumMIDIOutputs()
   local device_idx = -1

   for i = 0, numOuts - 1 do
      local retval, name = reaper.GetMIDIOutputName(i, "")

      if retval and name:lower():find(device_name_keyword) then
         device_idx = i

         break
      end
   end

   if device_idx == -1 then
      reaper.ShowMessageBox("No MIDI output found with '" .. device_name_keyword .. "' in its name.", "Error", 0)
      return
   end

   -- Build MIDI message

   local MSG_TYPES = {
      note_off = 0x80,
      note_on = 0x90,
      CC = 0xB0
   }

   local msg1 = MSG_TYPES[msg_type] + midi_ch
   local msg2 = value1
   local msg3 = value2

   -- Mode 16 + device index = hardware MIDI output
   local mode = 16 + device_idx

   reaper.StuffMIDIMessage(mode, msg1, msg2, msg3)
end

function ToggleMuteLockRecordForTracksWithName(track_keyword, state)
   local track_count = reaper.CountTracks(0)
   for i = 0, track_count - 1 do
      local track = reaper.GetTrack(0, i)
      local _, track_name = reaper.GetTrackName(track)
      if not track_name then return 0 end
      track_name = string.lower(track_name)

      if track_name:find(track_keyword) then
         local cmdID = 41312 + toggleState
         reaper.SetOnlyTrackSelected(track)
         if toggleState == 1 then
            reaper.Main_OnCommand(cmdID, 0)
            reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state ~ 1)

            if reaper.GetProjectName(0):find("ROUTING") then
               reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
            end
         else
            reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state ~ 1)
            reaper.Main_OnCommand(cmdID, 0)
         end
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

function ApplyActionToAllProjects(action, ...) -- Function to execute the action on selected projects
   --pass reaper action_id or function + arguments
   if type(action) == "string" then
      action = reaper.NamedCommandLookup(action)
   end

   reaper.PreventUIRefresh(-1)
   local main_project = reaper.EnumProjects(-1)

   local idx = 0
   while true do
      local proj = reaper.EnumProjects(idx)
      if proj == nil then break end -- No more projects

      reaper.SelectProjectInstance(proj)

      if type(action) == "number" then
         reaper.Main_OnCommand(action, 0)
      elseif type(action) == "function" then
         action(...)
      end
      idx = idx + 1
   end

   reaper.SelectProjectInstance(main_project)
   reaper.PreventUIRefresh(1)
end

function Main()
   local _, _, _, cmdID, _, _, val, _ = reaper.get_action_context()

   local prev_toggle_state = reaper.GetToggleCommandState(cmdID)

   if val == 127 then
      if prev_toggle_state == 1 then
         return
      end
      toggleState = SetToggleState(1)
   elseif val == 0 then
      if prev_toggle_state == 0 then
         return
      end
      toggleState = SetToggleState(0)
   else --not triggered by Midi
      toggleState = SetToggleState()
   end

   ApplyActionToAllProjects(ToggleMuteLockRecordForTracksWithName, "auto ansage levels", toggleState)

   -- Midi feedback for Midi Device. Use at own risk. If midi mapping is moved around terrible things could happen.
   --[[    if val ~= 127 and val ~= 0 then
      SendMidiMessage("wing midi control", "note_on", 5, 4, 127)
   end ]]
end

reaper.Undo_BeginBlock()
Main()
reaper.Undo_EndBlock("Toggle 'Auto Ansage Levels'", -1)
