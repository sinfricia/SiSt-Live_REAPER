-- @noindex
-- SiSt-Live: DEBUG List audio and MIDI devices
-- Read only. Prints every audio input/output channel and every MIDI input/output device REAPER knows, with its
-- index and name, to the console. Used to find out how REAPER names its internal loopbacks (step 1b: loopback
-- test). Changes nothing.
--
-- Temporary home: not part of the package (not in Setup's @provides).

local out = {}
local function line(fmt, ...) out[#out + 1] = fmt:format(...) end

line("=== Audio and MIDI devices (%s) ===", os.date("%Y-%m-%d %H:%M:%S"))
local _, mode = reaper.GetAudioDeviceInfo("MODE")
local _, ident_in = reaper.GetAudioDeviceInfo("IDENT_IN")
local _, ident_out = reaper.GetAudioDeviceInfo("IDENT_OUT")
local _, srate = reaper.GetAudioDeviceInfo("SRATE")
line("Audio device: mode %s, in %s, out %s, %s Hz", tostring(mode), tostring(ident_in), tostring(ident_out),
  tostring(srate))
local ok_lb, loopback_size = reaper.get_config_var_string("loopback_size")
line("loopback_size (reaper.ini): %s", ok_lb and loopback_size or "?")

-- Audio channels: also probe past the reported counts, in case loopback channels come after the hardware ones
local function audio(label, count, name_of)
  line("")
  line("%s: GetNum... = %d", label, count)
  local blank = 0
  for i = 0, count + 128 do
    local name = name_of(i)
    if name and name ~= "" then
      line("  %3d%s  %s", i, i >= count and " (past count)" or "", name)
      blank = 0
    else
      blank = blank + 1
      if i >= count and blank >= 16 then break end -- 16 empty in a row after the count: stop probing
    end
  end
end
audio("Audio inputs", reaper.GetNumAudioInputs(), reaper.GetInputChannelName)
audio("Audio outputs", reaper.GetNumAudioOutputs(), reaper.GetOutputChannelName)

-- MIDI devices: GetNum... is the highest device number + 1; disabled/missing devices return false
local function midi(label, count, name_of)
  line("")
  line("%s: GetNum... = %d", label, count)
  for i = 0, count - 1 do
    local present, name = name_of(i, "") -- the second argument is the name buffer REAPER expects
    if (name and name ~= "") or present then
      line("  %3d  %s%s", i, tostring(name), present and "" or "  (not enabled / not present)")
    end
  end
end
midi("MIDI inputs", reaper.GetNumMIDIInputs(), reaper.GetMIDIInputName)
midi("MIDI outputs", reaper.GetNumMIDIOutputs(), reaper.GetMIDIOutputName)

reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
reaper.defer(function() end) -- no undo point
