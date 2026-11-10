-- @noindex
-- Live test: loopbacks (description at the top of the main file, Debug/SiSt-Live_DEBUG Run Live Test.lua).
-- REAPER's internal loopbacks (not ReaRoute). Audio: track inputs and hardware outputs from 768 on are the loopback
-- channels (as in the routing and song projects: REC 768 = loopback 1), 1:1, count = reaper.ini loopback_size.
-- MIDI: loopback devices look like normal MIDI devices; found by Sina's naming scheme "LB<n> OUT ..." /
-- "LB<n> IN ..." (same n = one pair). A track's MIDI input = 4096 + device * 32 (+ channel, 0 = all).
-- Two projects, like the show: "LB OUT" sends (tone generator), "LB IN" receives and plays what arrives on the
-- main outs. Both must play (stopped background projects don't run in this config).

local H = require("LiveTest.Helpers")

local Loopback = {}

local LOOPBACK_FIRST = 768                   -- first internal loopback channel (track input / hardware output)
local MIDI_LOOPBACK  = "^LB(%d+)%s+(%a+)"    -- naming scheme: number and OUT / IN
local MIDI_INPUT     = 4096                  -- I_RECINPUT flag for a MIDI input (+ device * 32, channel 0 = all)
local TONE_DB        = -35                   -- test tone level (the tone generator's default is too loud)
local TONE_HZ        = 440                   -- first test tone: A4. The MIDI test plays a scale from one octave below.
local TONE_NOTE      = 69                    -- MIDI note of TONE_HZ
local MAJOR_SCALE    = { 0, 2, 4, 5, 7, 9, 11 }
local SYNTH_VOL      = 0.05                  -- receiving ReaSynth tracks: about -26 dB
local SIGNAL_MIN     = 0.001                 -- linear peak (-60 dB): above = a signal arrives
local SETTLE_WAIT    = 0.5                   -- s, before the first channel: everything must be silent
local AUDIO_WAIT     = 0.2                   -- s, tone on one loopback (one melody note), then the meters are read
local MIDI_WAIT      = 0.5                   -- s, note length (heard), then checked
local RISE           = 1.2                   -- another input "receives" only if its meter rose by this factor
                                             -- (a meter still falling from the previous note is not a signal)
-- Melody for the audio loopbacks, one note per loopback (MIDI note numbers, repeats if there are more loopbacks)
local MELODY = { 69, 73, 76, 81, 80, 76, 73, 71, 69, 71, 73, 74, 76, 74, 73, 71,
                 69, 73, 76, 78, 81, 80, 78, 76, 74, 73, 71, 73, 69, 68, 69, 69 }
local function note_hz(note) return 440 * 2 ^ ((note - 69) / 12) end
-- Test notes on channel 1 at velocity 100. Action shortcuts use channel 16, so they trigger nothing.
local NOTE_ON, NOTE_OFF, TEST_VEL = 0x90, 0x80, 100
local TONE_FX  = "JS: Tone Generator"
local SYNTH_FX = "ReaSynth (Cockos)"

local lb = { receivers = {}, synths = {} } -- the two test projects, the sender track and the receiving tracks

local function loopback_size()
  local ok, value = reaper.get_config_var_string("loopback_size")
  return ok and tonumber(value) or 0
end

--- Note of the i-th MIDI loopback: a major scale from one octave below the tone generator's note.
local function scale_note(i)
  local octave, degree = (i - 1) // #MAJOR_SCALE, (i - 1) % #MAJOR_SCALE + 1
  return TONE_NOTE - 12 + octave * 12 + MAJOR_SCALE[degree]
end

--- Loopback MIDI devices by number: { [n] = { OUT = {idx, name, present}, IN = {...} } } and the sorted numbers.
local function midi_loopbacks()
  local by_n, numbers = {}, {}
  local function scan(count, name_of, key)
    for i = 0, count - 1 do
      local present, name = name_of(i, "")
      local n, dir = (name or ""):match(MIDI_LOOPBACK)
      if n and dir:upper() == key then
        n = tonumber(n)
        if not by_n[n] then by_n[n] = {}; numbers[#numbers + 1] = n end
        by_n[n][key] = { idx = i, name = name, present = present }
      end
    end
  end
  scan(reaper.GetNumMIDIOutputs(), reaper.GetMIDIOutputName, "OUT")
  scan(reaper.GetNumMIDIInputs(), reaper.GetMIDIInputName, "IN")
  table.sort(numbers)
  return by_n, numbers
end

local function peak(tr) return math.max(reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1)) end
local function inputs_with_signal()
  local list = {}
  for n, tr in ipairs(lb.receivers) do if peak(tr) > SIGNAL_MIN then list[#list + 1] = n end end
  return list
end

function Loopback.stop_projects()
  for _, proj in ipairs({ lb.tx, lb.rx }) do
    if H.valid(proj) then
      reaper.Main_OnCommandEx(H.STOP, 0, proj)
      for i = 0, reaper.CountTracks(proj) - 1 do
        reaper.SetMediaTrackInfo_Value(reaper.GetTrack(proj, i), "I_RECARM", 0)
      end
    end
  end
  lb.tx, lb.rx = nil, nil -- done: the tabs may be reused by the show workflow test
end

--- A new track in proj (any tab may be active).
local function new_track(proj, idx, name)
  if reaper.InsertTrackInProject then
    reaper.InsertTrackInProject(proj, idx, 0)
  else
    reaper.SelectProjectInstance(proj)
    reaper.InsertTrackAtIndex(idx, false)
  end
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

local function add_fx(tr, fx_name)
  local fx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
  if fx >= 0 then
    reaper.TrackFX_Show(tr, fx, 2) -- no floating FX window during the test
    reaper.TrackFX_Show(tr, fx, 0) -- and no FX chain window
  end
  return fx
end

--- Sets the first parameter whose name contains one of the words. Returns { name, value } or nil.
local function set_param(tr, fx, words, value)
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pname = reaper.TrackFX_GetParamName(tr, fx, p, "")
    for _, w in ipairs(words) do
      if pname:lower():find(w, 1, true) then
        reaper.TrackFX_SetParam(tr, fx, p, value)
        return { name = pname, index = p, value = (reaper.TrackFX_GetParam(tr, fx, p)) }
      end
    end
  end
end

--- The empty unsaved tab left after closing the projects, otherwise a new tab.
local function empty_project()
  local current, file = reaper.EnumProjects(-1)
  if file == "" and reaper.CountTracks(current) == 0 and current ~= lb.rx then return current end
  reaper.Main_OnCommand(H.NEW_TAB, 0)
  local proj = reaper.EnumProjects(-1)
  if proj == current then error("could not open a new project tab for the test", 0) end
  return proj
end

function Loopback.steps(sel)
  local size = loopback_size()
  local by_n, numbers = midi_loopbacks()

  local steps = {
    { name = "Loopback test projects",
      required = true,
      run = function()
        -- LB IN: what arrives on the loopbacks, played on the main outs
        lb.rx = empty_project()
        lb.receivers, lb.synths = {}, {}
        for n = 1, size do -- audio: input = loopback n (mono), armed with monitoring, never records
          local tr = new_track(lb.rx, n - 1, "LB in " .. n)
          reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", LOOPBACK_FIRST + n - 1)
          reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 2) -- record: none
          reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
          reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
          lb.receivers[n] = tr
        end
        for i, n in ipairs(numbers) do -- MIDI: input = LB<n> IN, ReaSynth, quiet
          local pair = by_n[n]
          if pair.IN and pair.IN.present then
            local tr = new_track(lb.rx, reaper.CountTracks(lb.rx), "LB MIDI in " .. n)
            reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", MIDI_INPUT + pair.IN.idx * 32)
            reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 2)
            reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
            reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
            reaper.SetMediaTrackInfo_Value(tr, "D_VOL", SYNTH_VOL)
            lb.synths[n] = add_fx(tr, SYNTH_FX)
          end
        end

        -- LB OUT: the tone generator, sent to one loopback at a time (not to the main outs). Silent until the
        -- level is set: the tone generator starts at full volume.
        lb.tx = empty_project()
        local tr = new_track(lb.tx, 0, "LB test tone")
        reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 0)
        reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
        lb.sender = tr
        lb.fx = add_fx(tr, TONE_FX)
        if lb.fx >= 0 then
          lb.level = set_param(tr, lb.fx, { "vol", "db" }, TONE_DB)
          lb.freq = set_param(tr, lb.fx, { "freq" }, TONE_HZ)
        end
        -- One hardware send per loopback, all active, volume 0 except the loopback under test: a loopback nobody
        -- writes to keeps repeating its last audio (seen 2026-10-25), so every loopback is always written.
        lb.sends = {}
        for n = 1, size do
          local send = reaper.CreateTrackSend(tr, nil)
          reaper.SetTrackSendInfo_Value(tr, 1, send, "D_VOL", 0)
          reaper.SetTrackSendInfo_Value(tr, 1, send, "I_SRCCHAN", 1024)                          -- mono, ch 1
          reaper.SetTrackSendInfo_Value(tr, 1, send, "I_DSTCHAN", 1024 | (LOOPBACK_FIRST + n - 1)) -- mono, loopback n
          lb.sends[n] = send
        end
        if lb.level then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1) end -- level set: unmute (else silent)

        -- Both play: stopped background projects don't run
        reaper.Main_OnCommandEx(H.PLAY, 0, lb.rx)
        reaper.Main_OnCommandEx(H.PLAY, 0, lb.tx)
      end,
      wait = 1,
      check = function()
        local synths_ok = true
        for _, fx in pairs(lb.synths) do synths_ok = synths_ok and fx >= 0 end
        return {
          { name = ("loopback_size: %d audio loopback channels"):format(size), ok = size > 0 },
          { name = ("LB IN project: %d tracks (%d audio + %d MIDI)"):format(reaper.CountTracks(lb.rx), size,
              #numbers), ok = reaper.CountTracks(lb.rx) >= size },
          { name = "LB OUT project: 1 track (test tone)", ok = reaper.CountTracks(lb.tx) == 1 },
          { name = "two different test projects", ok = lb.rx ~= lb.tx },
          { name = "tone generator added (" .. TONE_FX .. ")", ok = (lb.fx or -1) >= 0 },
          { name = lb.level and ("tone level %s = %.1f (wanted %d dB)"):format(lb.level.name, lb.level.value, TONE_DB)
              or "tone level parameter found", ok = lb.level ~= nil and math.abs(lb.level.value - TONE_DB) < 1 },
          { name = lb.freq and ("tone frequency %s = %.0f (wanted %d Hz)"):format(lb.freq.name, lb.freq.value, TONE_HZ)
              or "tone frequency parameter found", ok = lb.freq ~= nil and math.abs(lb.freq.value - TONE_HZ) < 1 },
          { name = "ReaSynth on every MIDI receiving track (" .. SYNTH_FX .. ")", ok = synths_ok },
          { name = ("%d hardware sends (one per loopback)"):format(#lb.sends), ok = #lb.sends == size
              and reaper.GetTrackNumSends(lb.sender, 1) == size },
          H.is_playing(lb.rx, "LB IN project", true),
          H.is_playing(lb.tx, "LB OUT project", true),
        }
      end },
  }

  local failed_audio, start_peaks = 0, {}
  local function set_send(n, vol) if lb.sends[n] then reaper.SetTrackSendInfo_Value(lb.sender, 1, lb.sends[n], "D_VOL", vol) end end
  steps[#steps + 1] = { name = "Audio loopbacks", quiet = true,
    run = function() end,
    wait = SETTLE_WAIT,
    check = function()
      local noisy = inputs_with_signal()
      if #noisy == 0 then return { { name = "all loopback inputs silent without the tone", ok = true } } end
      return { { name = "signal without the tone on input(s) " .. table.concat(noisy, ", "), ok = false } }
    end }
  for n = 1, size do
    local note = MELODY[(n - 1) % #MELODY + 1]
    steps[#steps + 1] = { name = "Audio loopback " .. n, quiet = true,
      run = function()
        set_send(n - 1, 0)
        if lb.freq then reaper.TrackFX_SetParam(lb.sender, lb.fx, lb.freq.index, note_hz(note)) end
        for m, tr in ipairs(lb.receivers) do start_peaks[m] = peak(tr) end -- before the note arrives
        set_send(n, 1)
      end,
      wait = AUDIO_WAIT,
      check = function()
        local here, elsewhere = false, {}
        for m, tr in ipairs(lb.receivers) do
          local p = peak(tr)
          if m == n then
            here = p > SIGNAL_MIN
          elseif p > SIGNAL_MIN and p > (start_peaks[m] or 0) * RISE then
            elsewhere[#elsewhere + 1] = m
          end
        end
        local ok = here and #elsewhere == 0
        if not ok then failed_audio = failed_audio + 1 end
        return { { name = ("audio loopback %d: %s"):format(n, ok and "arrives on input " .. n .. " only"
          or ((here and "" or "NOT on input " .. n) .. (#elsewhere > 0 and ((here and "" or ", ") ..
            "also on input(s) " .. table.concat(elsewhere, ", ")) or ""))), ok = ok } }
      end }
  end
  steps[#steps + 1] = { name = "Audio loopbacks",
    run = function() set_send(size, 0) end,
    wait = 0.5, -- a short break between the audio melody and the MIDI scale
    check = function()
      return { { name = ("%d of %d audio loopbacks ok"):format(size - failed_audio, size), ok = failed_audio == 0 } }
    end }

  local failed_midi = 0
  for i, n in ipairs(numbers) do
    local pair, note, before = by_n[n], scale_note(i), 0
    steps[#steps + 1] = { name = "MIDI loopback LB" .. n, quiet = true,
      run = function()
        if not (pair.OUT and pair.IN and pair.OUT.present and pair.IN.present) then return end
        before = (reaper.MIDI_GetRecentInputEvent(0)) -- sequence number of the newest event so far
        reaper.StuffMIDIMessage(16 + pair.OUT.idx, NOTE_ON, note, TEST_VEL)
      end,
      wait = MIDI_WAIT,
      check = function()
        local label = "MIDI loopback LB" .. n
        local problem
        if not pair.OUT then problem = "LB" .. n .. " IN has no LB" .. n .. " OUT"
        elseif not pair.IN then problem = pair.OUT.name .. " has no LB" .. n .. " IN"
        elseif not pair.OUT.present then problem = pair.OUT.name .. " is not enabled"
        elseif not pair.IN.present then problem = pair.IN.name .. " is not enabled" end
        if problem then
          failed_midi = failed_midi + 1
          return { { name = label .. ": " .. problem, ok = false } }
        end
        reaper.StuffMIDIMessage(16 + pair.OUT.idx, NOTE_OFF, note, 0)
        local seen, elsewhere = false, {}
        local i = 0
        while true do -- newest first, back to the events from before the test note
          local seq, buf, _, dev = reaper.MIDI_GetRecentInputEvent(i)
          if seq == 0 or seq <= before then break end
          if #buf >= 2 and (buf:byte(1) & 0xF0) == NOTE_ON and buf:byte(2) == note then
            if dev == pair.IN.idx then seen = true else elsewhere[#elsewhere + 1] = tostring(dev) end
          end
          i = i + 1
        end
        local ok = seen and #elsewhere == 0
        if not ok then failed_midi = failed_midi + 1 end
        return { { name = ("%s: %s -> %s (note %d)%s"):format(label, pair.OUT.name, pair.IN.name, note,
          ok and " ok" or ((seen and "" or ": NOT received") ..
            (#elsewhere > 0 and (" (also on input device(s) " .. table.concat(elsewhere, ", ") .. ")") or ""))),
          ok = ok } }
      end }
  end
  steps[#steps + 1] = { name = "MIDI loopbacks",
    run = function() end,
    check = function()
      return { { name = ("%d of %d MIDI loopbacks ok (found by the names LB<n> OUT / LB<n> IN)"):format(
        #numbers - failed_midi, #numbers), ok = #numbers > 0 and failed_midi == 0 } }
    end }

  steps[#steps + 1] = { name = "Loopback test projects: stop",
    run = function()
      Loopback.stop_projects()
      -- The show workflow test reuses these tabs. If something failed, offer to stop here and inspect them.
      if sel.show and (failed_audio + failed_midi) > 0 and reaper.MB(("The loopback test found %d problem(s).\n\n" ..
          "Stop here to inspect the loopback test projects?\nYes: stop (the show workflow test is skipped)\n" ..
          "No: continue with the show workflow test"):format(failed_audio + failed_midi), H.TITLE, 4) == 6 then
        error("stopped after the loopback test to inspect its projects (they stay open)", 0)
      end
    end,
    check = function() return { { name = "stopped and disarmed", ok = true } } end }
  return steps
end

return Loopback
