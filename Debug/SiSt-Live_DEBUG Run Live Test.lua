-- @noindex
-- SiSt-Live: DEBUG Run Live Test
-- Plays through the core show workflow in the running REAPER with the TEST projects and checks every result:
--   open the test projects, edit -> show mode, then twice (playback mode play, then rec): Start Show, Start Song,
--   the end markers (Project End Handler, NO STOP), Project End Handler - move to previous project; show -> edit
--   mode. In rec mode it checks what records: Start Show (routing), Start Song and NO STOP record, the other end
--   handlers only play. Recordings are removed from the projects and deleted at the end.
-- Result: summary in the console, full report in <resource path>/Data/SiSt Libraries/Live test report.txt.
-- What it can't see (looks, pop-ups, a real MIDI message from the WING, REAPER restart) stays on the manual
-- show checklist.
--
-- Menu: "Run live test" / "Choose test folder...". The first run asks for the test folder. It is stored relative
-- to the REAPER config when possible, so it works on machines with different kDrive drive letters.
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
      run = function() play_into_end_marker(peh, PEH) end,
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
      run = function() run(PEH_PREVIOUS) end,
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
      run = function() play_into_end_marker(no_stop, PEH_NO_STOP) end,
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

local steps = {
  { name = "Close open projects",
    required = true,
    run = function()
      local saved = 0
      for _, p in ipairs(projects()) do if p.file ~= "" then saved = saved + 1 end end
      if saved == 0 then return end
      if reaper.MB(("%d project(s) are open. The live test only runs with its own test projects.\n\n" ..
          "Close all projects now? REAPER asks whether to save changes."):format(saved), TITLE, 4) ~= 6 then
        error("cancelled: close the open projects first", 0)
      end
      local name = reaper.kbd_getTextFromCmd(CLOSE_ALL, 0) or ""
      if not name:lower():find("close all projects", 1, true) then -- this one must never be a different action
        error(("action %d is \"%s\", expected \"File: Close all projects\""):format(CLOSE_ALL, name), 0)
      end
      reaper.Main_OnCommand(CLOSE_ALL, 0)
    end,
    wait = 0.5, -- REAPER's save questions are modal: the check runs after they are answered
    check = function()
      local left = {}
      for _, p in ipairs(projects()) do if p.file ~= "" then left[#left + 1] = name_of(p.proj) end end
      return { { name = #left == 0 and "no other project open"
        or ("still open (closing cancelled?): " .. table.concat(left, ", ")), ok = #left == 0 } }
    end },

  { name = "Open test projects",
    required = true,
    run = function()
      local dir = test_folder()
      local files = rpp_files(dir)
      if #files == 0 then error("no .rpp files in " .. dir, 0) end
      files_before = {}
      for _, f in ipairs(all_files(dir)) do files_before[f:lower()] = true end
      for i, f in ipairs(files) do
        if i > 1 then reaper.Main_OnCommand(NEW_TAB, 0) end
        reaper.Main_openProject("noprompt:" .. dir .. sep .. f)
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
    run = function() run_script("mode") end,
    wait = 2,
    check = function()
      local rows = mode_checks(Mode.SHOW)
      rows[#rows + 1] = { name = "Setlist is open", ok = window_open("setlist") }
      rows[#rows + 1] = { name = "Status Display is open", ok = window_open("status") }
      return rows
    end },
}
for _, s in ipairs(show_round(false)) do steps[#steps + 1] = s end
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

local scenario = {
  name = TITLE,

  check_ready = function()
    if not test_folder() then return false, "no test folder chosen" end
    if playback_mode() == "rec" then return false, "playback mode is \"rec\": switch it to play first" end
    if not Mode.is_edit() then return false, "switch to edit mode first" end
    return true
  end,

  steps = steps,

  -- Always: stop, playback mode back to play, edit mode back, recordings deleted. Returns report rows.
  cleanup = function()
    stop_all()
    if playback_mode() == "rec" then run(TOGGLE_PLAYBACK_MODE) end
    if Mode.get() ~= start_mode then run_script("mode") end
    local rows = { { name = "playback mode back to play", ok = playback_mode() == "play" } }
    for _, r in ipairs(delete_recordings()) do rows[#rows + 1] = r end
    return rows
  end,
}

-- Menu ---------------------------------------------------------------------------------------------

local function menu()
  local folder = test_folder()
  local items = { "Run live test", "Choose test folder...", "", "#Test folder: " .. (folder or "(none)") }
  local x, y = reaper.GetMousePosition()
  gfx.init("", 0, 0, 0, x, y)
  gfx.x, gfx.y = gfx.screentoclient(x, y)
  local choice = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  if choice == 1 then
    SelfTest.run_scenario(scenario, TITLE, { report_file = "Live test report.txt" })
  elseif choice == 2 then
    choose_folder()
  end
end

if not test_folder() and not choose_folder() then return end -- first run: ask for the test folder
menu()
