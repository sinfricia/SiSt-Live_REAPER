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
-- automatically (No in the play round, which first switches to "rec" so No must switch it off; Yes in the rec
-- round). At the end everything is stopped, playback mode play and edit mode are
-- restored, the recordings deleted; the test projects stay open.
-- Files: this main file (menu, test folder, closing projects, unattended mode, the scenario) and its parts in
-- Debug/LiveTest/: Show.lua (show workflow), Looper.lua (Region Looper), Loopback.lua (loopbacks), Helpers.lua.
-- Actions under test are found by file name (scripts) or by name (custom actions), never by a literal ID.
--
-- Temporary home: not part of the package (not in Setup's @provides). Started from the configuration window later.

-- Own folder from this file (not get_action_context: the unattended runner loads this file, that is its path):
-- the package's lib/ and this folder (LiveTest/ parts)
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = here .. "../lib/?.lua;" .. here .. "?.lua;" .. package.path

local SelfTest = require("SelfTest")
local Mode     = require("SiSt-Live_Mode")
local H        = require("LiveTest.Helpers")
local Show     = require("LiveTest.Show")
local Loopback = require("LiveTest.Loopback")

local TITLE = H.TITLE

-- Test folder ------------------------------------------------------------------------------------

local function choose_folder()
  local start = H.test_folder() or reaper.GetResourcePath()
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
  reaper.SetExtState(H.EXT_SECTION, H.KEY_FOLDER, SelfTest.relative_path(H.config_dir(), full) or full, true)
  return true
end

-- Tests and selection ------------------------------------------------------------------------------

-- Run in this order. Loopbacks first: then no routing or song project is open yet that could receive the test
-- signals; the show workflow test then opens its projects into the loopback test's tabs (no save questions).
local TESTS = {
  { id = "loopback", label = "Loopbacks (audio + MIDI)",              steps = Loopback.steps },
  { id = "show",     label = "Show workflow (play/rec, end markers)", steps = Show.steps },
}
local KEY_SELECTION = "tests" -- ExtState: ids of the ticked tests, "loopback,show"

local function selection()
  local stored = reaper.GetExtState(H.EXT_SECTION, KEY_SELECTION)
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
  reaper.SetExtState(H.EXT_SECTION, KEY_SELECTION, #ids > 0 and table.concat(ids, ",") or "none", true)
end

-- Closing projects ---------------------------------------------------------------------------------

--- Closes all projects after asking (question: the dialog text), with REAPER's "File: Close all projects": REAPER
--- then asks whether to save each changed project. Returns false if the user said no. Used at the start and the end.
local function close_all_projects(question)
  if reaper.MB(question, TITLE, 4) ~= 6 then return false end
  local name = reaper.kbd_getTextFromCmd(H.CLOSE_ALL, 0) or ""
  if not name:lower():find("close all projects", 1, true) then -- this one must never be a different action
    error(("action %d is \"%s\", expected \"File: Close all projects\""):format(H.CLOSE_ALL, name), 0)
  end
  reaper.Main_OnCommand(H.CLOSE_ALL, 0)
  return true
end

--- Projects with something in them (a file or tracks). After closing everything REAPER keeps one empty tab.
local function non_empty_projects()
  local list = {}
  for _, p in ipairs(H.projects()) do
    if p.file ~= "" or reaper.CountTracks(p.proj) > 0 then list[#list + 1] = p end
  end
  return list
end

local close_step = { name = "Close open projects",
  required = true,
  run = function()
    local saved = 0
    for _, p in ipairs(H.projects()) do if p.file ~= "" then saved = saved + 1 end end
    if saved == 0 then return end
    if not close_all_projects(("%d project(s) are open. The live test only runs with its own test projects.\n\n" ..
        "Close all projects now? REAPER asks whether to save changes."):format(saved)) then
      error("cancelled: close the open projects first", 0)
    end
  end,
  wait = 0.5, -- REAPER's save questions are modal: the check runs after they are answered
  check = function()
    local left = {}
    for _, p in ipairs(H.projects()) do if p.file ~= "" then left[#left + 1] = H.name_of(p.proj) end end
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

-- The scenario -------------------------------------------------------------------------------------

--- Unattended mode (the argument "unattended", passed by "SiSt-Live_DEBUG Run Live Test unattended.lua"): no menu, no questions, only the show
--- workflow test, other projects are never closed (the run is refused instead), test projects stay open.
local UNATTENDED = (...) == "unattended" -- argument of the unattended runner (loadfile + call), nil when run as an action

--- Names of the non-empty open projects that are not from the test folder.
local function foreign_projects()
  local dir = SelfTest.normalize(H.test_folder() or ""):lower()
  local names = {}
  for _, p in ipairs(non_empty_projects()) do
    local file = SelfTest.normalize(p.file):lower()
    if p.file == "" or file:sub(1, #dir + 1) ~= dir .. "/" then names[#names + 1] = H.name_of(p.proj) end
  end
  return names
end

local function build_scenario(sel)
  local steps = UNATTENDED and {} or { close_step }
  for _, t in ipairs(TESTS) do
    if sel[t.id] then for _, s in ipairs(t.steps(sel)) do steps[#steps + 1] = s end end
  end
  return {
    name = TITLE,

    check_ready = function()
      if sel.show then
        if not H.test_folder() then return false, "no test folder chosen (needed for the show workflow test)" end
        if Show.playback_mode() == "rec" then return false, "playback mode is \"rec\": switch it to play first" end
        if not Mode.is_edit() then return false, "switch to edit mode first" end
        if UNATTENDED then
          local foreign = foreign_projects()
          if #foreign > 0 then
            return false, "other projects are open (unattended mode never closes them): " .. table.concat(foreign, ", ")
          end
        end
      end
      return true
    end,

    steps = steps,

    -- Always: stop, playback mode back to play, edit mode back, recordings deleted. Returns report rows.
    cleanup = function()
      Show.end_setlist_test_mode()
      Loopback.stop_projects()
      H.stop_all()
      if not sel.show then return {} end
      return Show.cleanup()
    end,
  }
end

-- Menu ---------------------------------------------------------------------------------------------
-- The tests are check items: clicking one ticks / unticks it and the menu opens again.

local function run_unattended()
  SelfTest.run_scenario(build_scenario({ show = true }), TITLE, { report_file = "Live test report.txt" })
end

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
    items[#items + 1] = "#Test folder: " .. (H.test_folder() or "(none)")
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
  if sel.show and not H.test_folder() and not choose_folder() then return end
  SelfTest.run_scenario(build_scenario(sel), TITLE,
    { report_file = "Live test report.txt", progress = true, after_report = offer_closing })
end

if UNATTENDED then run_unattended() else menu() end
