-- @noindex
-- Live test: the show workflow with the test projects (description at the top of the main file,
-- Debug/SiSt-Live_DEBUG Run Live Test.lua). Show.steps() for the scenario, Show.cleanup() for its cleanup.

local SelfTest    = require("SelfTest")
local Mode        = require("SiSt-Live_Mode")
local ModeEffects = require("SiSt-Live_ModeEffects")
local Actions     = require("SiSt-Live_Actions")
local ActionReferenceChecks = require("ActionReferenceChecks")
local H           = require("LiveTest.Helpers")
local Looper      = require("LiveTest.Looper")

local Show = {}

-- Actions under test, found by file name / custom action name
local START_SHOW_FILE      = "Transport/SiSt-Live_Start Show.lua" -- run with dofile (see the Start Show step)
local START_SONG_FILE      = "Transport/SiSt-Live_Start Song.lua"
local PLAY_OR_RECORD_FILE  = "Transport/SiSt-Live_Play or record current project (ignore Routing project).lua"
local TOGGLE_PLAYBACK_FILE = "Transport/SiSt-Live_Toggle playback mode (play or recording).lua"
local PEH_NAME          = "SiSt-Live_Project End Handler"
local PEH_NO_STOP_NAME  = "SiSt-Live_Project End Handler - NO STOP"
local PEH_PREVIOUS_NAME = "SiSt-Live_Project End Handler - move to previous project"

local RECORDING_QUESTION = "Recording reminder!" -- title of Start Show's "Do you want to enable recording?"

-- The Setlist's test mode (see Setlist.lua): its autosave is neither read nor written while set (not persisted)
local SETLIST_SECTION, SETLIST_TEST_MODE = "SiSt-Live_Setlist", "TestMode"

local LEAD_IN     = 2    -- s, end-marker tests start playing this far before the marker
local MARKER_WAIT = 4.5  -- s, then wait this long: the marker fires after LEAD_IN, the switch takes a moment

local function playback_mode() return reaper.GetExtState("SiSt-Live", "playback_mode") == "rec" and "rec" or "play" end
Show.playback_mode = playback_mode

local function toggle_playback_mode() H.run(H.script_cmd(TOGGLE_PLAYBACK_FILE)) end

local function window_open(id)
  local cmd = Actions.script_command(id)
  return cmd ~= nil and reaper.GetToggleCommandState(cmd) == 1
end

local start_mode = Mode.get()
local status_was_open = window_open("status")
local files_before = nil -- files in the test folder before the test: everything new is a recording

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
  local songs = H.songs
  for i = 1, #songs - 1 do
    local pos = end_marker(songs[i], id)
    if pos then
      state.from, state.pos = i, pos
      reaper.SelectProjectInstance(songs[i])
      reaper.Main_OnCommandEx(H.STOP, 0, songs[i])
      reaper.SetEditCurPos2(songs[i], pos - LEAD_IN, false, false)
      H.run(H.script_cmd(PLAY_OR_RECORD_FILE)) -- as Start Song does, but from the cursor (recording can't seek)
      return
    end
  end
end

local function marker_found(state)
  return { name = ("end marker found in %s at %.2f s"):format(H.name_of(H.songs[state.from]), state.pos), ok = true }
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

--- The show workflow in one playback mode. rec: playback mode "rec", switched on by answering Yes in Start Show.
local function show_round(rec)
  local suffix = rec and " (rec)" or ""
  local peh, no_stop = {}, {}
  local unexpected = {} -- message boxes Start Show showed other than the recording question
  return {
    { name = "Start Show" .. suffix,
      run = function()
        H.stop_all()
        -- Play round: start from "rec", so answering No has to switch recording off (it once stayed on)
        if not rec and playback_mode() == "play" then toggle_playback_mode() end
        -- Start Show runs here (dofile) instead of as an action, so its recording question can be answered
        -- automatically: No in the play round, Yes in the rec round. Any other message box is recorded.
        local original = reaper.ShowMessageBox
        reaper.ShowMessageBox = function(msg, title)
          if title == RECORDING_QUESTION then return rec and 6 or 7 end -- 6 = Yes, 7 = No
          unexpected[#unexpected + 1] = ("%s: %s"):format(tostring(title), tostring(msg))
          return 1
        end
        local ok, err = pcall(dofile, Actions.join_path(reaper.GetResourcePath(), START_SHOW_FILE, H.sep))
        reaper.ShowMessageBox = original
        if not ok then error(err, 0) end
      end,
      wait = 2,
      check = function()
        H.find_projects()
        local song1 = H.songs[1]
        return {
          { name = #unexpected == 0 and "no other message boxes"
              or ("unexpected message boxes: " .. table.concat(unexpected, " / ")), ok = #unexpected == 0 },
          { name = ("playback mode is %s (recording question answered %s)"):format(rec and "rec" or "play",
              rec and "Yes" or "No"), ok = playback_mode() == (rec and "rec" or "play") },
          { name = "routing project moved to the first tab", ok = reaper.EnumProjects(0) == H.routing },
          H.is_playing(H.routing, "routing project", true),
          H.is_recording(H.routing, "routing project", rec),
          H.is_active(song1, "the first song (" .. H.name_of(song1) .. ")"),
          { name = ("first song: edit cursor at =START (%.2f s, is %.2f s)"):format(H.song_start(song1),
              reaper.GetCursorPositionEx(song1)), ok = H.near(reaper.GetCursorPositionEx(song1), H.song_start(song1)) },
        }
      end },

    { name = "Start Song" .. suffix,
      run = function()
        local song1 = H.songs[1]
        H.keep_only_needed_playing()
        reaper.Main_OnCommandEx(H.STOP, 0, song1)
        reaper.SetEditCurPos2(song1, H.song_start(song1) + 10, false, false) -- somewhere in the song
        H.run(H.script_cmd(START_SONG_FILE))
      end,
      wait = 1.5,
      check = function()
        return {
          H.is_active(H.songs[1], "the first song"),
          H.plays_from(H.songs[1], "first song", true),
          H.is_recording(H.songs[1], "first song", rec),
        }
      end },

    { name = "End marker: Project End Handler" .. suffix,
      required = true, -- the next steps build on this switch
      run = function()
        H.keep_only_needed_playing()
        local _, id = H.custom(PEH_NAME)
        play_into_end_marker(peh, id)
      end,
      wait = MARKER_WAIT,
      check = function()
        if not peh.from then return { marker_missing("the Project End Handler") } end
        local from, to = H.songs[peh.from], H.songs[peh.from + 1]
        return {
          marker_found(peh),
          H.is_active(to, "the next song (" .. H.name_of(to) .. ")"),
          H.is_playing(from, "previous song", false),
          { name = "previous song: edit cursor back at =START", ok = H.near(reaper.GetCursorPositionEx(from), H.song_start(from)) },
          H.plays_from(to, "next song", false),
          H.is_recording(to, "next song", false), -- this end handler only plays, also in rec mode
          H.is_recording(H.routing, "routing project", rec),
        }
      end },

    { name = "Project End Handler - move to previous project" .. suffix,
      run = function()
        H.keep_only_needed_playing()
        H.run((H.custom(PEH_PREVIOUS_NAME)))
      end,
      wait = 2,
      check = function()
        local back, left = H.songs[peh.from], H.songs[peh.from + 1]
        return {
          H.is_active(back, "the previous song (" .. H.name_of(back) .. ")"),
          H.is_playing(left, "the song it came from", false),
          H.plays_from(back, "previous song", false),
          H.is_recording(back, "previous song", false),
        }
      end },

    { name = "End marker: Project End Handler - NO STOP" .. suffix,
      run = function()
        H.keep_only_needed_playing()
        local _, id = H.custom(PEH_NO_STOP_NAME)
        play_into_end_marker(no_stop, id)
      end,
      wait = MARKER_WAIT,
      check = function()
        if not no_stop.from then return { marker_missing("the Project End Handler - NO STOP") } end
        local to = H.songs[no_stop.from + 1]
        return {
          marker_found(no_stop),
          H.is_active(to, "the next song (" .. H.name_of(to) .. ")"),
          H.plays_from(to, "next song", true),
          H.is_recording(to, "next song", rec),
          H.is_playing(H.routing, "routing project", true),
          H.is_recording(H.routing, "routing project", rec),
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
  for _, f in ipairs(H.all_files(H.test_folder())) do
    local ext = f:match("%.([^.\\/]+)$")
    if not files_before[f:lower()] and ext and MEDIA[ext:lower()] then new[#new + 1] = f end
  end
  local rows = {}
  if #new == 0 then rows[1] = { name = "no recordings to delete", ok = true } end
  local is_new = {}
  for _, f in ipairs(new) do is_new[SelfTest.normalize(f):lower()] = true end

  local items_removed = 0
  for _, p in ipairs(H.projects()) do
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

function Show.steps()
  local steps = {
    { name = "Open test projects",
      required = true,
      run = function()
        local dir = H.test_folder()
        local files = H.rpp_files(dir)
        if #files == 0 then error("no .rpp files in " .. dir, 0) end
        files_before = {}
        for _, f in ipairs(H.all_files(dir)) do files_before[f:lower()] = true end
        -- Into the open tabs first ("noprompt:" replaces whatever is there without asking, e.g. the loopback
        -- test's unsaved projects), new tabs for the rest; tabs left over are closed.
        local tabs = H.projects()
        for i, f in ipairs(files) do
          if tabs[i] then reaper.SelectProjectInstance(tabs[i].proj) else reaper.Main_OnCommand(H.NEW_TAB, 0) end
          reaper.Main_openProject("noprompt:" .. dir .. H.sep .. f)
        end
        for i = #tabs, #files + 1, -1 do
          reaper.SelectProjectInstance(tabs[i].proj)
          reaper.Main_OnCommand(H.CLOSE_TAB, 0)
        end
      end,
      wait = 2,
      check = function()
        local dir = SelfTest.normalize(H.test_folder()):lower()
        local function inside(path)
          local p = SelfTest.normalize(path):lower()
          return p == dir or p:sub(1, #dir + 1) == dir .. "/"
        end
        local outside, rec_outside = {}, {}
        for _, p in ipairs(H.projects()) do
          if not inside(p.file) then outside[#outside + 1] = H.name_of(p.proj) end
          if not inside(reaper.GetProjectPathEx(p.proj)) then rec_outside[#rec_outside + 1] = H.name_of(p.proj) end
        end
        H.find_projects()
        return {
          { name = #outside == 0 and "only test projects open" or ("not from the test folder: " .. table.concat(outside, ", ")),
            ok = #outside == 0 },
          { name = #rec_outside == 0 and "all test projects record into the test folder"
            or ("records outside the test folder (recordings couldn't be deleted safely): " .. table.concat(rec_outside, ", ")),
            ok = #rec_outside == 0 },
          { name = "routing project (\"ROUTING\" in the name) open", ok = H.routing ~= nil },
          { name = ("at least three songs open (%d)"):format(#H.songs), ok = #H.songs >= 3 },
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
        H.run_script("mode")
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
  for _, s in ipairs(Looper.steps()) do steps[#steps + 1] = s end -- Region Looper: play mode only
  for _, s in ipairs(show_round(true)) do steps[#steps + 1] = s end
  steps[#steps + 1] = { name = "Show -> Edit mode",
    run = function()
      H.stop_all()
      H.run_script("mode")
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

--- Always at the end of a run with the show workflow: playback mode back to play, mode back, recordings deleted.
--- Returns report rows.
function Show.cleanup()
  if playback_mode() == "rec" then toggle_playback_mode() end
  if Mode.get() ~= start_mode then H.run_script("mode") end
  local rows = { { name = "playback mode back to play", ok = playback_mode() == "play" } }
  for _, r in ipairs(delete_recordings()) do rows[#rows + 1] = r end
  return rows
end

--- Ends the Setlist's test mode (also when the show workflow did not run).
function Show.end_setlist_test_mode()
  reaper.DeleteExtState(SETLIST_SECTION, SETLIST_TEST_MODE, false)
end

return Show
