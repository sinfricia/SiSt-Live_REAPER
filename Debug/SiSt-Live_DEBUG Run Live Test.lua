-- @noindex
-- SiSt-Live: DEBUG Run Live Test
-- Live tests in the running REAPER. The menu lists them as check items (click to tick / untick, remembered);
-- "Run selected tests" runs the ticked ones in one report:
--
-- SHOW WORKFLOW: plays through the core show workflow with the TEST projects and checks every result
--   (after the play round also the Region Looper on the first "LOOP..." region of the test songs, incl. Stop loop):
--   open the test projects, edit -> show mode, then twice (playback mode play, then rec): Start Show, Start Song,
--   the end markers (Project End Handler, NO STOP), Project End Handler - move to previous project; show -> edit
--   mode. In rec mode it checks what records: Start Show (routing), Start Song and NO STOP record, the other end
--   handlers only play. Recordings are removed from the projects and deleted at the end.
-- Result: summary in the console, full report in <resource path>/Data/SiSt Libraries/Live test report.txt.
-- What it can't see (looks, pop-ups, a real MIDI message from the WING, REAPER restart) stays on the manual
-- show checklist.
--
-- LOOPBACKS: REAPER's internal audio loopbacks (one channel at a time: a quiet test tone goes out on loopback N,
--   only input N may receive it) and MIDI loopbacks (a note on "LB<n> OUT ..." must arrive on "LB<n> IN ..." only;
--   each loopback plays the next note of a scale through ReaSynth). Builds two unsaved projects, "LB OUT" (tone
--   generator) and "LB IN" (receiving tracks, heard on the main outs); both play. Needs no test projects.
-- A small window shows which step is running; closing it stops the test (cleanup still runs).
--
-- Before every run, other projects are closed (after asking), so nothing reaches the WING through the routing
-- session. "Choose test folder..." sets the folder of the show workflow test projects (asked when needed). It is
-- stored relative to the REAPER config when possible, so it works on machines with different kDrive drive letters.
--
-- The test folder holds the test projects (*.rpp). They are opened in alphabetical order, so the file names set
-- the setlist order (e.g. "1 ROUTING.rpp", "2 Song A.rpp", "3 Song B.rpp"):
--   - one routing project with "ROUTING" in its name (Start Show looks for "ROUTING"), built like the real one
--     (REC folder, SamplePlayer track), without media and without inputs that make sound
--   - at least three songs, each with a "=START" marker (not at 0) and an end-of-project action marker like the
--     real songs, at least 60 s after =START (so it doesn't fire on its own during the test). At least one song
--     that is not the last must end with the Project End Handler marker, and one with the NO STOP marker: the
--     test plays into these markers (from 2 s before) and checks the switch to the next song.
-- Other open projects: the test asks to close them (REAPER asks about saving). It never runs on other projects.
-- The test projects must record into the test folder (only new files there are deleted afterwards).
-- Playback mode must be "play", REAPER in edit mode. Start Show's "Do you want to enable recording?" is answered
-- automatically (No in the play round, Yes in the rec round). At the end everything is stopped, playback mode play and edit mode are
-- restored, the recordings deleted; the test projects stay open.
--
-- Temporary home: not part of the package (not in Setup's @provides). Moves with the other checks in step 3.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local SelfTest    = require("SelfTest")
local Mode        = require("SiSt-Live_Mode")
local ModeEffects = require("SiSt-Live_ModeEffects")
local Actions     = require("SiSt-Live_Actions")
local ActionReferenceChecks = require("ActionReferenceChecks")

local sep = package.config:sub(1, 1)

-- Actions under test. Scripts outside Actions.SCRIPTS and custom actions by their IDs for now
-- (replaced by the lookup by file name in step 3 / 6).
local START_SHOW_FILE = "Transport/SiSt-Live_Start Show.lua"                -- run with dofile (see Start Show step)
local RECORDING_QUESTION = "Recording reminder!" -- title of Start Show's "Do you want to enable recording?"
local START_SONG   = "_RSf6595f5391afe59936df5608aa263fde4281db94" -- Script: SiSt-Live_Start Song.lua (MIDI ch 16 note 0)
local PEH          = "_ee138e4d8dfe664db1ef75556f3562a7" -- Custom: SiSt-Live_Project End Handler
local PEH_NO_STOP  = "_4dcc2040d7152045aaecf3d227e0cff3" -- Custom: SiSt-Live_Project End Handler - NO STOP
local PEH_PREVIOUS = "_4b83cb3542875a4585d6476d092248fa" -- Custom: SiSt-Live_Project End Handler - move to previous project
local PLAY_OR_RECORD = "_RSd0a27f3833c9358457f90dde0a72fe9942b9e481" -- Script: SiSt-Live_Play or record current project (ignore Routing project).lua
local TOGGLE_PLAYBACK_MODE = "_RSa9686300d4ed1b32912b2918386a4fe072559b3a" -- Script: SiSt-Live_Toggle playback mode (play or recording).lua
local STOP         = 1016  -- Transport: Stop
local NEW_TAB      = 40859 -- File: New project tab
local CLOSE_ALL    = 40886 -- File: Close all projects

-- The Setlist's test mode (see Setlist.lua): its autosave is neither read nor written while set (not persisted)
local SETLIST_SECTION, SETLIST_TEST_MODE = "Sist-Live_Setlist", "TestMode"

local TOLERANCE   = 0.05 -- s, edit cursor position
local PLAY_WINDOW = 3    -- s, "plays from X": play position at most this far after X
local LEAD_IN     = 2    -- s, end-marker tests start playing this far before the marker
local MARKER_WAIT = 4.5  -- s, then wait this long: the marker fires after LEAD_IN, the switch takes a moment

local EXT_SECTION, EXT_KEY = "SiSt-Live_LiveTest", "folder"
local TITLE = "SiSt-Live live test"

-- Test folder ------------------------------------------------------------------------------------

local function config_dir() return SelfTest.normalize(reaper.GetResourcePath()) end

--- Path of `to` relative to `from` (both normalized, "/"), or nil if they are on different drives.
local function relative_path(from, to)
  local a, b = {}, {}
  for part in from:gmatch("[^/]+") do a[#a + 1] = part end
  for part in to:gmatch("[^/]+") do b[#b + 1] = part end
  if not a[1] or not b[1] or a[1]:lower() ~= b[1]:lower() then return nil end
  local same = 0
  while a[same + 1] and b[same + 1] and a[same + 1]:lower() == b[same + 1]:lower() do same = same + 1 end
  local parts = {}
  for _ = same + 1, #a do parts[#parts + 1] = ".." end
  for i = same + 1, #b do parts[#parts + 1] = b[i] end
  return #parts == 0 and "." or table.concat(parts, "/")
end

local function stored_folder() return reaper.GetExtState(EXT_SECTION, EXT_KEY) end

--- Full path of the test folder (with the system separator), or nil if none is chosen yet.
local function test_folder()
  local stored = stored_folder()
  if stored == "" then return nil end
  local absolute = stored:match("^%a:") or stored:match("^/")
  local full = absolute and stored or (config_dir() .. "/" .. stored)
  return (SelfTest.normalize(full):gsub("/", sep))
end

local function choose_folder()
  local start = test_folder() or reaper.GetResourcePath()
  local path
  if reaper.JS_Dialog_BrowseForFolder then
    local rv, p = reaper.JS_Dialog_BrowseForFolder("Folder with the SiSt-Live test projects", start)
    path = rv == 1 and p ~= "" and p or nil
  else
    local ok, p = reaper.GetUserInputs("SiSt-Live live test", 1, "Test project folder:,extrawidth=300", start)
    path = ok and p ~= "" and p or nil
  end
  if not path then return false end
  local full = SelfTest.normalize(path)
  reaper.SetExtState(EXT_SECTION, EXT_KEY, relative_path(config_dir(), full) or full, true)
  return true
end

--- All files below dir (recursive, fresh listing), full paths.
local function all_files(dir)
  local out = {}
  local function walk(d)
    reaper.EnumerateFiles(d, -1)
    reaper.EnumerateSubdirectories(d, -1)
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(d, i)
      if not f then break end
      out[#out + 1] = d .. sep .. f
      i = i + 1
    end
    i = 0
    while true do
      local sub = reaper.EnumerateSubdirectories(d, i)
      if not sub then break end
      walk(d .. sep .. sub)
      i = i + 1
    end
  end
  walk(dir)
  return out
end

local function rpp_files(dir)
  local files, i = {}, 0
  reaper.EnumerateFiles(dir, -1) -- fresh listing
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():match("%.rpp$") then files[#files + 1] = f end
    i = i + 1
  end
  table.sort(files, function(x, y) return x:lower() < y:lower() end)
  return files
end

-- Helpers ------------------------------------------------------------------------------------------

local function run(id)
  local cmd = type(id) == "number" and id or reaper.NamedCommandLookup(id)
  if not cmd or cmd == 0 then error("action not found: " .. tostring(id), 0) end
  reaper.Main_OnCommand(cmd, 0)
end

local function run_script(id)
  local cmd, err = Actions.script_command(id)
  if not cmd then error(err, 0) end
  reaper.Main_OnCommand(cmd, 0)
end

--- Open projects: { { proj, file } } in tab order (file is "" for an unsaved project).
local function projects()
  local list, i = {}, 0
  while true do
    local proj, file = reaper.EnumProjects(i)
    if not proj then return list end
    list[#list + 1] = { proj = proj, file = file or "" }
    i = i + 1
  end
end

local function name_of(proj) return proj and reaper.GetProjectName(proj) or "(none)" end
local function active() return (reaper.EnumProjects(-1)) end
local function playing(proj) return reaper.GetPlayStateEx(proj) & 1 == 1 end
local function near(a, b) return math.abs(a - b) <= TOLERANCE end

--- Where a song starts: the "=START" marker, otherwise the project start (as "Move edit cursor to project start
--- respecting time 0 and start marker" does).
local function song_start(proj)
  local start = reaper.GetProjectTimeOffset(proj, false)
  local i = 0
  while true do
    local rv, isrgn, pos, _, name = reaper.EnumProjectMarkers2(proj, i)
    if rv == 0 then return start end
    if not isrgn and name == "=START" then return pos end
    i = i + 1
  end
end

-- Check rows shared by several steps
local function is_active(proj, label)
  return { name = ("active project is %s (is: %s)"):format(label, name_of(active())), ok = active() == proj }
end
local function is_recording(proj, label, expected)
  return { name = ("%s %s"):format(label, expected and "is recording" or "is not recording"),
    ok = (reaper.GetPlayStateEx(proj) & 4 == 4) == expected }
end
local function is_playing(proj, label, expected)
  return { name = ("%s %s"):format(label, expected and "is playing" or "is stopped"), ok = playing(proj) == expected }
end
--- from_marker: plays from =START; otherwise from the very beginning (0).
local function plays_from(proj, label, from_marker)
  local from = from_marker and song_start(proj) or 0
  local pos = reaper.GetPlayPositionEx(proj)
  return { name = ("%s plays from %s (%.2f s, play position %.2f s, play state %d)"):format(label,
      from_marker and "=START" or "the very beginning", from, pos, reaper.GetPlayStateEx(proj)),
    ok = playing(proj) and pos >= from - TOLERANCE and pos <= from + PLAY_WINDOW }
end

local routing, songs = nil, {} -- set after opening, again after Start Show (it moves routing to the first tab)

--- Position of the end action marker in proj that runs `id` (a marker named "!... id ..."), or nil.
local function end_marker(proj, id)
  local found, i = nil, 0
  while true do
    local rv, isrgn, pos, _, name = reaper.EnumProjectMarkers2(proj, i)
    if rv == 0 then return found end
    for _, token in ipairs(not isrgn and ActionReferenceChecks.marker_commands(name) or {}) do
      if token == id then found = pos end
    end
    i = i + 1
  end
end

--- Finds the first song (not the last one: there must be a next song) with an end marker for `id` and plays (or
--- records, in rec mode) it from shortly before the marker. Fills state: from (song index), pos (marker
--- position). No such song: state stays empty, the check reports it.
local function play_into_end_marker(state, id)
  for i = 1, #songs - 1 do
    local pos = end_marker(songs[i], id)
    if pos then
      state.from, state.pos = i, pos
      reaper.SelectProjectInstance(songs[i])
      reaper.Main_OnCommandEx(STOP, 0, songs[i])
      reaper.SetEditCurPos2(songs[i], pos - LEAD_IN, false, false)
      run(PLAY_OR_RECORD) -- as Start Song does, but from the cursor (recording can't seek)
      return
    end
  end
end

local function marker_found(state)
  return { name = ("end marker found in %s at %.2f s"):format(name_of(songs[state.from]), state.pos), ok = true }
end
local function marker_missing(what)
  return { name = "no test song (except the last) has an end marker that runs " .. what ..
    " (markers with unknown actions are listed under \"Action markers\")", ok = false }
end

local function mode_checks(mode)
  local rows = { { name = "mode is " .. mode .. " (is: " .. Mode.get() .. ")", ok = Mode.get() == mode } }
  local last = ModeEffects.get_last_run()
  rows[#rows + 1] = { name = "mode effects ran for " .. mode .. " without failures",
    ok = last ~= nil and last.mode == mode and last.failed_count == 0 }
  for _, effect in ipairs(ModeEffects.names()) do
    local s = ModeEffects.get_status(effect)
    rows[#rows + 1] = { name = ("effect %s: %s"):format(effect, s and (s.result .. " " .. (s.message or "")) or "no status"),
      ok = s ~= nil and s.mode == mode and s.result ~= ModeEffects.FAILED }
  end
  return rows
end

local function window_open(id)
  local cmd = Actions.script_command(id)
  return cmd ~= nil and reaper.GetToggleCommandState(cmd) == 1
end

-- The scenario -------------------------------------------------------------------------------------

local start_mode = Mode.get()
local status_was_open = window_open("status")
local files_before = nil -- files in the test folder before the test: everything new is a recording

local function find_projects()
  routing, songs = nil, {}
  for _, p in ipairs(projects()) do
    if name_of(p.proj):find("ROUTING", 1, true) then routing = p.proj else songs[#songs + 1] = p.proj end
  end
end

local function playback_mode() return reaper.GetExtState("SiSt-Live", "playback_mode") == "rec" and "rec" or "play" end

--- Stops every project except the routing project and the active song: only what the next step needs plays,
--- so the transport shows at a glance whether the test runs correctly.
local function keep_only_needed_playing()
  local keep = active()
  for _, p in ipairs(projects()) do
    if p.proj ~= routing and p.proj ~= keep then reaper.Main_OnCommandEx(STOP, 0, p.proj) end
  end
end

local function stop_all()
  for _, p in ipairs(projects()) do reaper.Main_OnCommandEx(STOP, 0, p.proj) end
end

--- The show workflow in one playback mode. rec: playback mode "rec", switched on by answering Yes in Start Show.
local function show_round(rec)
  local suffix = rec and " (rec)" or ""
  local peh, no_stop = {}, {}
  local unexpected = {} -- message boxes Start Show showed other than the recording question
  return {
    { name = "Start Show" .. suffix,
      run = function()
        stop_all()
        -- Start Show runs here (dofile) instead of as an action, so its recording question can be answered
        -- automatically: No in the play round, Yes in the rec round. Any other message box is recorded.
        local original = reaper.ShowMessageBox
        reaper.ShowMessageBox = function(msg, title)
          if title == RECORDING_QUESTION then return rec and 6 or 7 end -- 6 = Yes, 7 = No
          unexpected[#unexpected + 1] = ("%s: %s"):format(tostring(title), tostring(msg))
          return 1
        end
        local ok, err = pcall(dofile, Actions.join_path(reaper.GetResourcePath(), START_SHOW_FILE, sep))
        reaper.ShowMessageBox = original
        if not ok then error(err, 0) end
      end,
      wait = 2,
      check = function()
        find_projects()
        local song1 = songs[1]
        return {
          { name = #unexpected == 0 and "no other message boxes"
              or ("unexpected message boxes: " .. table.concat(unexpected, " / ")), ok = #unexpected == 0 },
          { name = ("playback mode is %s (recording question answered %s)"):format(rec and "rec" or "play",
              rec and "Yes" or "No"), ok = playback_mode() == (rec and "rec" or "play") },
          { name = "routing project moved to the first tab", ok = reaper.EnumProjects(0) == routing },
          is_playing(routing, "routing project", true),
          is_recording(routing, "routing project", rec),
          is_active(song1, "the first song (" .. name_of(song1) .. ")"),
          { name = ("first song: edit cursor at =START (%.2f s, is %.2f s)"):format(song_start(song1),
              reaper.GetCursorPositionEx(song1)), ok = near(reaper.GetCursorPositionEx(song1), song_start(song1)) },
        }
      end },

    { name = "Start Song" .. suffix,
      run = function()
        local song1 = songs[1]
        keep_only_needed_playing()
        reaper.Main_OnCommandEx(STOP, 0, song1)
        reaper.SetEditCurPos2(song1, song_start(song1) + 10, false, false) -- somewhere in the song
        run(START_SONG)
      end,
      wait = 1.5,
      check = function()
        return {
          is_active(songs[1], "the first song"),
          plays_from(songs[1], "first song", true),
          is_recording(songs[1], "first song", rec),
        }
      end },

    { name = "End marker: Project End Handler" .. suffix,
      required = true, -- the next steps build on this switch
      run = function() keep_only_needed_playing(); play_into_end_marker(peh, PEH) end,
      wait = MARKER_WAIT,
      check = function()
        if not peh.from then return { marker_missing("the Project End Handler") } end
        local from, to = songs[peh.from], songs[peh.from + 1]
        return {
          marker_found(peh),
          is_active(to, "the next song (" .. name_of(to) .. ")"),
          is_playing(from, "previous song", false),
          { name = "previous song: edit cursor back at =START", ok = near(reaper.GetCursorPositionEx(from), song_start(from)) },
          plays_from(to, "next song", false),
          is_recording(to, "next song", false), -- this end handler only plays, also in rec mode
          is_recording(routing, "routing project", rec),
        }
      end },

    { name = "Project End Handler - move to previous project" .. suffix,
      run = function() keep_only_needed_playing(); run(PEH_PREVIOUS) end,
      wait = 2,
      check = function()
        local back, left = songs[peh.from], songs[peh.from + 1]
        return {
          is_active(back, "the previous song (" .. name_of(back) .. ")"),
          is_playing(left, "the song it came from", false),
          plays_from(back, "previous song", false),
          is_recording(back, "previous song", false),
        }
      end },

    { name = "End marker: Project End Handler - NO STOP" .. suffix,
      run = function() keep_only_needed_playing(); play_into_end_marker(no_stop, PEH_NO_STOP) end,
      wait = MARKER_WAIT,
      check = function()
        if not no_stop.from then return { marker_missing("the Project End Handler - NO STOP") } end
        local to = songs[no_stop.from + 1]
        return {
          marker_found(no_stop),
          is_active(to, "the next song (" .. name_of(to) .. ")"),
          plays_from(to, "next song", true),
          is_recording(to, "next song", rec),
          is_playing(routing, "routing project", true),
          is_recording(routing, "routing project", rec),
        }
      end },
  }
end

--- Removes the recordings: items whose source file is new in the test folder are deleted from the open projects,
--- then the new media/peak files are deleted from disk. Folders REAPER created for the recordings stay (Windows
--- doesn't let Lua delete folders). Returns report rows.
local MEDIA = { wav = true, flac = true, mp3 = true, ogg = true, wv = true, aif = true, aiff = true, caf = true,
  w64 = true, rf64 = true, reapeaks = true }
local function delete_recordings()
  if not files_before then return {} end
  local new = {}
  for _, f in ipairs(all_files(test_folder())) do
    local ext = f:match("%.([^.\\/]+)$")
    if not files_before[f:lower()] and ext and MEDIA[ext:lower()] then new[#new + 1] = f end
  end
  local rows = {}
  if #new == 0 then rows[1] = { name = "no recordings to delete", ok = true } end
  local is_new = {}
  for _, f in ipairs(new) do is_new[SelfTest.normalize(f):lower()] = true end

  local items_removed = 0
  for _, p in ipairs(projects()) do
    for i = reaper.CountMediaItems(p.proj) - 1, 0, -1 do
      local item = reaper.GetMediaItem(p.proj, i)
      local take = reaper.GetActiveTake(item)
      local src = take and reaper.GetMediaItemTake_Source(take)
      local file = src and reaper.GetMediaSourceFileName(src) or ""
      if is_new[SelfTest.normalize(file):lower()] then
        reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(item), item)
        items_removed = items_removed + 1
      end
    end
  end
  reaper.UpdateArrange()

  local kept = {}
  for _, f in ipairs(new) do
    if not os.remove(f) then kept[#kept + 1] = f end
  end
  if #new > 0 then
    rows[#rows + 1] = { name = ("recordings deleted: %d items removed, %d of %d files deleted"):format(items_removed,
      #new - #kept, #new), ok = true }
  end
  for _, f in ipairs(kept) do rows[#rows + 1] = SelfTest.warning("could not delete (still in use?): " .. f) end

  return rows
end

-- Loopback test -------------------------------------------------------------------------------------
-- REAPER's internal loopbacks (not ReaRoute). Audio: track inputs and hardware outputs from 768 on are the loopback
-- channels (as in the routing and song projects: REC 768 = loopback 1), 1:1, count = reaper.ini loopback_size.
-- MIDI: loopback devices look like normal MIDI devices; found by Sina's naming scheme "LB<n> OUT ..." /
-- "LB<n> IN ..." (same n = one pair). A track's MIDI input = 4096 + device * 32 (+ channel, 0 = all).
-- Two projects, like the show: "LB OUT" sends (tone generator), "LB IN" receives and plays what arrives on the
-- main outs. Both must play (stopped background projects don't run in this config).

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
local TONE_FX  = { "JS: Tone Generator", "Tone Generator", "JS: synthesis/tonegenerator" }
local SYNTH_FX = { "ReaSynth (Cockos)", "VSTi: ReaSynth (Cockos)", "ReaSynth" }
local PLAY = 1007 -- Transport: Play

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

local function valid(proj) return proj and reaper.ValidatePtr(proj, "ReaProject*") end

local function stop_loopback_projects()
  for _, proj in ipairs({ lb.tx, lb.rx }) do
    if valid(proj) then
      reaper.Main_OnCommandEx(STOP, 0, proj)
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

local function add_fx(tr, names)
  for _, fx_name in ipairs(names) do
    local fx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
    if fx >= 0 then
      reaper.TrackFX_Show(tr, fx, 2) -- no floating FX window during the test
      reaper.TrackFX_Show(tr, fx, 0) -- and no FX chain window
      return fx
    end
  end
  return -1
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
  reaper.Main_OnCommand(NEW_TAB, 0)
  local proj = reaper.EnumProjects(-1)
  if proj == current then error("could not open a new project tab for the test", 0) end
  return proj
end

local function loopback_steps(sel)
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
        reaper.Main_OnCommandEx(PLAY, 0, lb.rx)
        reaper.Main_OnCommandEx(PLAY, 0, lb.tx)
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
          { name = "tone generator added", ok = (lb.fx or -1) >= 0 },
          { name = lb.level and ("tone level %s = %.1f (wanted %d dB)"):format(lb.level.name, lb.level.value, TONE_DB)
              or "tone level parameter found", ok = lb.level ~= nil and math.abs(lb.level.value - TONE_DB) < 1 },
          { name = lb.freq and ("tone frequency %s = %.0f (wanted %d Hz)"):format(lb.freq.name, lb.freq.value, TONE_HZ)
              or "tone frequency parameter found", ok = lb.freq ~= nil and math.abs(lb.freq.value - TONE_HZ) < 1 },
          { name = "ReaSynth on every MIDI receiving track", ok = synths_ok },
          { name = ("%d hardware sends (one per loopback)"):format(#lb.sends), ok = #lb.sends == size
              and reaper.GetTrackNumSends(lb.sender, 1) == size },
          is_playing(lb.rx, "LB IN project", true),
          is_playing(lb.tx, "LB OUT project", true),
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
      stop_loopback_projects()
      -- The show workflow test reuses these tabs. If something failed, offer to stop here and inspect them.
      if sel.show and (failed_audio + failed_midi) > 0 and reaper.MB(("The loopback test found %d problem(s).\n\n" ..
          "Stop here to inspect the loopback test projects?\nYes: stop (the show workflow test is skipped)\n" ..
          "No: continue with the show workflow test"):format(failed_audio + failed_midi), TITLE, 4) == 6 then
        error("stopped after the loopback test to inspect its projects (they stay open)", 0)
      end
    end,
    check = function() return { { name = "stopped and disarmed", ok = true } } end }
  return steps
end

-- Region Looper (part of the show workflow test, play mode only) -------------------------------------
-- The deferred Region Looper loops regions named "LOOP <n>" n times, "LOOP" until "Stop loop", which then allows
-- one final pass. While looping: repeat on, time selection = region, the "cue" and "timecode" tracks muted; when
-- the loop ends everything is restored. The test takes the first LOOP region in the test songs, whatever kind.
-- To keep it short, it jumps to shortly before the region end for every pass (the looper only counts the jump
-- back to the region start).

local LOOPER_FILE    = "Region Looper/SiSt-Live_Region Looping (defered).lua"
local STOP_LOOP_FILE = "Region Looper/SiSt-Live_Region Looping_Stop loop.lua"
local LOOP_LEAD_IN   = 1      -- s, start playing this far before the region
local LOOP_BEFORE_END = 0.8   -- s, jump to this far before the region end for the next pass
local LOOP_PASS_WAIT = 1.5    -- s, then wait: the jump back to the start (or past the end) has happened
local LOOPER_TRACKS  = { "cue", "timecode" } -- muted by the looper while looping

local loop = {} -- the region under test: { proj, start, stop, count (-1 = until Stop loop), name, mutes = {} }

local function script_cmd(file)
  local cmd = reaper.AddRemoveReaScript(true, 0, Actions.join_path(reaper.GetResourcePath(), file, sep), true)
  if not cmd or cmd <= 0 then error("script not found: " .. file, 0) end
  return cmd
end

local function find_loop_region()
  for _, proj in ipairs(songs) do
    local i = 0
    while true do
      local rv, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers2(proj, i)
      if rv == 0 then break end
      if isrgn and name:find("^LOOP") then
        local count = tonumber(name:match("^LOOP%s+(%d+)$"))
        return { proj = proj, start = pos, stop = rgnend, name = name, count = (count and count >= 1) and count or -1 }
      end
      i = i + 1
    end
  end
end

local function looper_tracks(proj)
  local list = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    for _, wanted in ipairs(LOOPER_TRACKS) do
      if name:lower() == wanted then list[#list + 1] = { tr = tr, name = name } end
    end
  end
  return list
end

local function looping_state()
  local proj = loop.proj
  local _, ext = reaper.GetProjExtState(proj, "SiSt-Live", "RegionLooping")
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  return {
    pos = reaper.GetPlayPositionEx(proj),
    rep = reaper.GetSetRepeatEx(proj, -1) == 1,
    ext = ext,
    selection = math.abs(sel_start - loop.start) < TOLERANCE and math.abs(sel_end - loop.stop) < TOLERANCE,
  }
end

local function jump_before_end()
  reaper.SelectProjectInstance(loop.proj)
  reaper.SetEditCurPos2(loop.proj, loop.stop - LOOP_BEFORE_END, false, true) -- seek the running playback
end

local function mute_rows(want_muted)
  local rows = {}
  for _, t in ipairs(loop.mutes or {}) do
    local muted = reaper.GetMediaTrackInfo_Value(t.tr, "B_MUTE") == 1
    local expected = want_muted or t.before
    rows[#rows + 1] = { name = ("track %s %s"):format(t.name, want_muted and "muted while looping"
      or ("back to " .. (t.before and "muted" or "unmuted"))), ok = muted == expected }
  end
  if #rows == 0 then rows[1] = SelfTest.warning("no cue / timecode track in " .. name_of(loop.proj) .. ": muting not tested") end
  return rows
end

local function loop_steps()
  return {
    { name = "Region Looper running",
      run = function()
        local cmd = script_cmd(LOOPER_FILE)
        loop.started_by_test = reaper.GetToggleCommandState(cmd) ~= 1
        if loop.started_by_test then reaper.Main_OnCommand(cmd, 0) end -- normally started by __startup.lua
      end,
      wait = 0.5,
      check = function()
        local running = reaper.GetToggleCommandState(script_cmd(LOOPER_FILE)) == 1
        return { { name = running and ("Region Looper running" .. (loop.started_by_test and " (started by the test)" or ""))
          or "Region Looper could not be started", ok = running } }
      end },

    { name = "Loop: start",
      required = true, -- the next loop steps build on it
      run = function()
        local found = find_loop_region()
        for k in pairs(loop) do loop[k] = nil end
        if not found then return end
        for k, v in pairs(found) do loop[k] = v end
        loop.mutes = looper_tracks(loop.proj)
        for _, t in ipairs(loop.mutes) do t.before = reaper.GetMediaTrackInfo_Value(t.tr, "B_MUTE") == 1 end
        reaper.SelectProjectInstance(loop.proj)
        keep_only_needed_playing()
        reaper.Main_OnCommandEx(STOP, 0, loop.proj)
        reaper.SetEditCurPos2(loop.proj, math.max(0, loop.start - LOOP_LEAD_IN), false, false)
        reaper.Main_OnCommandEx(1007, 0, loop.proj) -- Transport: Play (play mode)
        -- Not tested (2026-10-25, Sina: maybe later): REC take switching - in play mode the looper switches the
        -- REC folder items starting at the loop start to their next take on every pass.
      end,
      wait = LOOP_LEAD_IN + 1,
      check = function()
        if not loop.proj then
          return { { name = "no region named LOOP... in the test songs", ok = false } }
        end
        local s = looping_state()
        local rows = {
          { name = ("loop region \"%s\" in %s (%.1f - %.1f s, %s)"):format(loop.name, name_of(loop.proj), loop.start,
            loop.stop, loop.count > 0 and (loop.count .. " passes") or "until Stop loop"), ok = true },
          { name = "playing inside the loop region", ok = s.pos >= loop.start and s.pos < loop.stop },
          { name = "repeat on", ok = s.rep },
          { name = "time selection = loop region", ok = s.selection },
          { name = "looping flag (project ExtState RegionLooping) on", ok = s.ext == "true" },
        }
        for _, r in ipairs(mute_rows(true)) do rows[#rows + 1] = r end
        return rows
      end },

    { name = "Loop: next pass",
      run = jump_before_end,
      wait = LOOP_PASS_WAIT,
      check = function()
        local s = looping_state()
        return { { name = ("jumped back to the loop start (position %.2f s)"):format(s.pos),
          ok = s.pos >= loop.start and s.pos < loop.stop - LOOP_BEFORE_END } }
      end },

    { name = "Loop: Stop loop",
      run = function()
        if loop.count == 2 then return end -- already in its last pass: nothing left to stop
        reaper.SelectProjectInstance(loop.proj) -- Stop loop acts on the active project
        reaper.Main_OnCommand(script_cmd(STOP_LOOP_FILE), 0)
        jump_before_end()
      end,
      wait = LOOP_PASS_WAIT,
      check = function()
        if loop.count == 2 then
          return { SelfTest.warning("\"" .. loop.name .. "\" is already in its last pass: Stop loop not tested") }
        end
        local s = looping_state()
        return {
          { name = ("one final pass after Stop loop (position %.2f s)"):format(s.pos),
            ok = s.pos >= loop.start and s.pos < loop.stop - LOOP_BEFORE_END },
          { name = "repeat off during the final pass", ok = not s.rep },
        }
      end },

    { name = "Loop: end",
      run = jump_before_end,
      wait = LOOP_PASS_WAIT,
      check = function()
        local s = looping_state()
        local rows = {
          { name = ("plays on past the loop region (position %.2f s, region end %.2f s)"):format(s.pos, loop.stop),
            ok = s.pos >= loop.stop },
          { name = "repeat off", ok = not s.rep },
          { name = "looping flag off", ok = s.ext ~= "true" },
        }
        for _, r in ipairs(mute_rows(false)) do rows[#rows + 1] = r end
        reaper.Main_OnCommandEx(STOP, 0, loop.proj)
        return rows
      end },
  }
end

-- Show workflow test --------------------------------------------------------------------------------

local function show_steps()
  local steps = {
    { name = "Open test projects",
      required = true,
      run = function()
        local dir = test_folder()
        local files = rpp_files(dir)
        if #files == 0 then error("no .rpp files in " .. dir, 0) end
        files_before = {}
        for _, f in ipairs(all_files(dir)) do files_before[f:lower()] = true end
        -- Into the open tabs first ("noprompt:" replaces whatever is there without asking, e.g. the loopback
        -- test's unsaved projects), new tabs for the rest; tabs left over are closed.
        local tabs = projects()
        for i, f in ipairs(files) do
          if tabs[i] then reaper.SelectProjectInstance(tabs[i].proj) else reaper.Main_OnCommand(NEW_TAB, 0) end
          reaper.Main_openProject("noprompt:" .. dir .. sep .. f)
        end
        for i = #tabs, #files + 1, -1 do
          reaper.SelectProjectInstance(tabs[i].proj)
          reaper.Main_OnCommand(40860, 0) -- File: Close current project tab
        end
      end,
      wait = 2,
      check = function()
        local dir = SelfTest.normalize(test_folder()):lower()
        local function inside(path)
          local p = SelfTest.normalize(path):lower()
          return p == dir or p:sub(1, #dir + 1) == dir .. "/"
        end
        local outside, rec_outside = {}, {}
        for _, p in ipairs(projects()) do
          if not inside(p.file) then outside[#outside + 1] = name_of(p.proj) end
          if not inside(reaper.GetProjectPathEx(p.proj)) then rec_outside[#rec_outside + 1] = name_of(p.proj) end
        end
        find_projects()
        return {
          { name = #outside == 0 and "only test projects open" or ("not from the test folder: " .. table.concat(outside, ", ")),
            ok = #outside == 0 },
          { name = #rec_outside == 0 and "all test projects record into the test folder"
            or ("records outside the test folder (recordings couldn't be deleted safely): " .. table.concat(rec_outside, ", ")),
            ok = #rec_outside == 0 },
          { name = "routing project (\"ROUTING\" in the name) open", ok = routing ~= nil },
          { name = ("at least three songs open (%d)"):format(#songs), ok = #songs >= 3 },
        }
      end },

    { name = "Action markers",
      run = function() end,
      check = function()
        -- every action marker of the open (= test) projects must run existing actions
        return ActionReferenceChecks.results(ActionReferenceChecks.check_markers(), "Action markers")
      end },

    { name = "Edit -> Show mode",
      run = function()
        reaper.SetExtState(SETLIST_SECTION, SETLIST_TEST_MODE, "1", false) -- show mode opens the Setlist
        run_script("mode")
      end,
      wait = 2,
      check = function()
        local rows = mode_checks(Mode.SHOW)
        rows[#rows + 1] = { name = "Setlist is open", ok = window_open("setlist") }
        rows[#rows + 1] = { name = "Status Display is open", ok = window_open("status") }
        return rows
      end },
  }
  for _, s in ipairs(show_round(false)) do steps[#steps + 1] = s end
  for _, s in ipairs(loop_steps()) do steps[#steps + 1] = s end -- Region Looper: play mode only
  for _, s in ipairs(show_round(true)) do steps[#steps + 1] = s end
  steps[#steps + 1] = { name = "Show -> Edit mode",
    run = function()
      stop_all()
      run_script("mode")
    end,
    wait = 2,
    check = function()
      local rows = mode_checks(Mode.EDIT)
      rows[#rows + 1] = { name = "Status Display back as before (" .. (status_was_open and "open" or "closed") .. ")",
        ok = window_open("status") == status_was_open }
      return rows
    end }
  return steps
end

-- Tests and selection ------------------------------------------------------------------------------

-- Run in this order. Loopbacks first: then no routing or song project is open yet that could receive the test
-- signals; the show workflow test then opens its projects into the loopback test's tabs (no save questions).
local TESTS = {
  { id = "loopback", label = "Loopbacks (audio + MIDI)",              steps = loopback_steps },
  { id = "show",     label = "Show workflow (play/rec, end markers)", steps = show_steps },
}
local KEY_SELECTION = "tests" -- ExtState: ids of the ticked tests, "loopback,show"

local function selection()
  local stored = reaper.GetExtState(EXT_SECTION, KEY_SELECTION)
  local sel = {}
  if stored == "" then
    for _, t in ipairs(TESTS) do sel[t.id] = true end -- default: all
  else
    for id in stored:gmatch("[^,]+") do sel[id] = true end
  end
  return sel
end

local function save_selection(sel)
  local ids = {}
  for _, t in ipairs(TESTS) do if sel[t.id] then ids[#ids + 1] = t.id end end
  reaper.SetExtState(EXT_SECTION, KEY_SELECTION, #ids > 0 and table.concat(ids, ",") or "none", true)
end

--- Closes all projects after asking (question: the dialog text), with REAPER's "File: Close all projects": REAPER
--- then asks whether to save each changed project. Returns false if the user said no. Used at the start and the end.
local function close_all_projects(question)
  if reaper.MB(question, TITLE, 4) ~= 6 then return false end
  local name = reaper.kbd_getTextFromCmd(CLOSE_ALL, 0) or ""
  if not name:lower():find("close all projects", 1, true) then -- this one must never be a different action
    error(("action %d is \"%s\", expected \"File: Close all projects\""):format(CLOSE_ALL, name), 0)
  end
  reaper.Main_OnCommand(CLOSE_ALL, 0)
  return true
end

--- Projects with something in them (a file or tracks). After closing everything REAPER keeps one empty tab.
local function non_empty_projects()
  local list = {}
  for _, p in ipairs(projects()) do
    if p.file ~= "" or reaper.CountTracks(p.proj) > 0 then list[#list + 1] = p end
  end
  return list
end

local close_step = { name = "Close open projects",
  required = true,
  run = function()
    local saved = 0
    for _, p in ipairs(projects()) do if p.file ~= "" then saved = saved + 1 end end
    if saved == 0 then return end
    if not close_all_projects(("%d project(s) are open. The live test only runs with its own test projects.\n\n" ..
        "Close all projects now? REAPER asks whether to save changes."):format(saved)) then
      error("cancelled: close the open projects first", 0)
    end
  end,
  wait = 0.5, -- REAPER's save questions are modal: the check runs after they are answered
  check = function()
    local left = {}
    for _, p in ipairs(projects()) do if p.file ~= "" then left[#left + 1] = name_of(p.proj) end end
    return { { name = #left == 0 and "no other project open"
      or ("still open (closing cancelled?): " .. table.concat(left, ", ")), ok = #left == 0 } }
  end }

-- After the report (so the results can be read first): offer to close the test projects, as at the start
local function offer_closing(passed, failed)
  local open = #non_empty_projects()
  if open == 0 then return end
  local closed = close_all_projects(("Live test done: %d passed, %d failed (report in the console).\n\n" ..
    "Close the %d test project(s) now? REAPER asks whether to save changes: answer No."):format(passed, failed, open))
  reaper.ShowConsoleMsg(closed and "Test projects closed.\n" or "Test projects left open.\n")
end

local function build_scenario(sel)
  local steps = { close_step }
  for _, t in ipairs(TESTS) do
    if sel[t.id] then for _, s in ipairs(t.steps(sel)) do steps[#steps + 1] = s end end
  end
  return {
    name = TITLE,

    check_ready = function()
      if sel.show then
        if not test_folder() then return false, "no test folder chosen (needed for the show workflow test)" end
        if playback_mode() == "rec" then return false, "playback mode is \"rec\": switch it to play first" end
        if not Mode.is_edit() then return false, "switch to edit mode first" end
      end
      return true
    end,

    steps = steps,

    -- Always: stop, playback mode back to play, edit mode back, recordings deleted. Returns report rows.
    cleanup = function()
      reaper.DeleteExtState(SETLIST_SECTION, SETLIST_TEST_MODE, false)
      stop_loopback_projects()
      stop_all()
      if not sel.show then return {} end
      if playback_mode() == "rec" then run(TOGGLE_PLAYBACK_MODE) end
      if Mode.get() ~= start_mode then run_script("mode") end
      local rows = { { name = "playback mode back to play", ok = playback_mode() == "play" } }
      for _, r in ipairs(delete_recordings()) do rows[#rows + 1] = r end
      return rows
    end,
  }
end

-- Menu ---------------------------------------------------------------------------------------------
-- The tests are check items: clicking one ticks / unticks it and the menu opens again.

local function menu()
  local x, y = reaper.GetMousePosition()
  gfx.init("", 0, 0, 0, x, y)
  local run_now = false
  while true do
    local sel = selection()
    local items, any = {}, false
    for _, t in ipairs(TESTS) do
      items[#items + 1] = (sel[t.id] and "!" or "") .. t.label
      any = any or sel[t.id] == true
    end
    local RUN, CHOOSE = #TESTS + 1, #TESTS + 2
    items[#items + 1] = ""
    items[#items + 1] = (any and "" or "#") .. "Run selected tests"
    items[#items + 1] = "Choose test folder..."
    items[#items + 1] = ""
    items[#items + 1] = "#Test folder: " .. (test_folder() or "(none)")
    gfx.x, gfx.y = gfx.screentoclient(x, y)
    local choice = gfx.showmenu(table.concat(items, "|"))
    if choice >= 1 and choice <= #TESTS then
      local id = TESTS[choice].id
      sel[id] = not sel[id]
      save_selection(sel)
    elseif choice == CHOOSE then
      choose_folder()
    else
      run_now = choice == RUN
      break
    end
  end
  gfx.quit()
  if not run_now then return end

  local sel = selection()
  if sel.show and not test_folder() and not choose_folder() then return end
  SelfTest.run_scenario(build_scenario(sel), TITLE,
    { report_file = "Live test report.txt", progress = true, after_report = offer_closing })
end

menu()
