-- @noindex

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
      CC = 0xB0,
      program_change = 0xC0
   }

   local msg1 = MSG_TYPES[msg_type] + midi_ch
   local msg2 = value1
   local msg3 = value2

   -- Mode 16 + device index = hardware MIDI output
   local mode = 16 + device_idx

   reaper.StuffMIDIMessage(mode, msg1, msg2, msg3)
end

SendMidiMessage("wing midi control", "program_change", 7, 117, 0)
