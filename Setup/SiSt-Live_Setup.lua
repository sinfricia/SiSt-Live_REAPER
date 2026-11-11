-- @description SiSt-Live
-- @version 0.1.0
-- @author sinfricia
-- @changelog
--   Pre-release. One package for the whole SiSt-Live show mode suite. It replaces the separate packages
--   "Project List", "SiSt-Live: Toggle Edit/Show mode" and "SiSt-Live: Status Display":
--   uninstall those in ReaPack before installing this one (they install the same files).
--
--   - New: "SiSt-Live: Setup" action. Shows the installed version and checks that every part of the
--     package is in place. Later it will do the first-time setup
--   - New mode effect "windows": switching to show mode opens the setlist and the status display if
--     they are closed. Switching back to edit mode closes only the windows it opened.
--     Set per mode in "Configure modes" ("open", "restore" or empty). Default: show = open, edit = restore
--   - Debug log of window positions: docked windows also show their size, e.g. "docker 3 (420x300)"
--   - Shared logging: all SiSt-Live scripts (now also the setlist) log through one library. Debug lines
--     while "DEBUG Toggle Logging" is on. Everything logged is also written to
--     <resource path>/Data/SiSt-Live/SiSt-Live.log (rotated at 1 MB to SiSt-Live.old.log).
--     In show mode warnings and errors don't open the REAPER console (they still go to the file)
--   - Setlist: Alt-start only runs the self tests now. Its debug output follows "DEBUG Toggle Logging"
--   - New: Toolbar. Big buttons copied from a native floating toolbar. Its own settings dialog
--     (right-click > Toolbar settings): toolbar number per mode. The buttons always fill the window:
--     all of them fit, as big as possible, rows fill the width (no scrolling). Toggle actions have an
--     indicator bar, separators become divider lines. Show mode opens it together with the setlist and
--     the status display
--   - New: "SiSt-Live: Clear time selection and loop points". Replaces the native action 40020 in
--     custom actions (Start Song, Project End Handler): clears both via the API, so show mode locking
--     doesn't ask "Time selection locked. Unlock and remove now?"
--   - Gui: windows receive every key typed in a frame (win.chars), toggle buttons (indicator bar)
--   - Gui: new TextField widget (single-line text entry, UTF-8, selection, clipboard via SWS).
--     Not used by a component yet. Test window: Debug/SiSt-Live_DEBUG Text Field Test.lua (not installed)
--   - Status display: mode button in the header. Show mode: "Hold for EDIT" (hold 0.5 s, no accidental
--     switch on stage). Edit mode: "Switch to SHOW" (click). Show header in a deep teal. Right-click:
--     "Debug logging" on/off
--   - Native REAPER actions are run by their command ID (IDs don't change; names sometimes do). Before
--     running, only "does the action exist" is checked: a renamed action no longer stops an effect.
--     "DEBUG Run Self-Test" lists every ID with its current name
--   - Toolbar buttons of "Toggle Edit/Show mode" and "DEBUG Toggle Logging" are always in sync, also when
--     the status display switches first after REAPER starts (command IDs found by script file,
--     new lib/SiSt-Live_Actions.lua)
--   - Gui: hold button (Widgets.hold_button)
--   - Gui: shared window header (Widgets.header), the setlist's look: muted accent color, regular font,
--     fixed size (headers don't zoom). Setlist teal; status display by mode (teal SHOW / orange EDIT)
--   - Naming: windows are named after what they are, never after a mode: "SiSt-Live Setlist",
--     "SiSt-Live Status Display", "SiSt-Live Toolbar" (folder, file, action and window title match)
--   - Setlist (was Project List 0.5): edit/show mode, theme colors, position per mode, window menu,
--     autosave with a question at the first start, follow-scroll, off-screen arrow, Ctrl + wheel zoom
--   - Status display: shows the mode and failed mode effects, position per mode
--   - Edit/show mode with mode effects: theme, layouts, screenset, fullscreen, keyboard section, mouse modifiers
--   - Debug actions: "DEBUG Toggle Logging" and "DEBUG Run Self-Test"
-- @provides
--   [main] .
--   [main] ../Modes/SiSt-Live_Toggle Edit-Show Mode.lua
--   [main] ../Modes/SiSt-Live_Apply current mode.lua
--   [main] ../Modes/SiSt-Live_Configure modes.lua
--   [main] ../Modes/SiSt-Live_Save current look for current mode.lua
--   [main] ../Modes/SiSt-Live_Lock mouse cursor to arrow in arrange view.lua
--   [main] ../Setlist/SiSt-Live_Setlist.lua
--   [nomain] ../Setlist/Data.lua
--   [nomain] ../Setlist/Sync.lua
--   [nomain] ../Setlist/State.lua
--   [nomain] ../Setlist/ProjectInfo.lua
--   [nomain] ../Setlist/Actions.lua
--   [nomain] ../Setlist/UI/ViewState.lua
--   [nomain] ../Setlist/UI/Ask.lua
--   [nomain] ../Setlist/UI/List.lua
--   [nomain] ../Setlist/UI/ListInput.lua
--   [nomain] ../Setlist/UI/CommandArea.lua
--   [nomain] ../Setlist/UI/LoadDialog.lua
--   [nomain] ../Setlist/UI/DuplicateWarning.lua
--   [main] ../Status Display/SiSt-Live_Status Display.lua
--   [main] ../Toolbar/SiSt-Live_Toolbar.lua
--   [main] ../Transport/SiSt-Live_Clear time selection and loop points.lua
--   [main] ../Debug/SiSt-Live_DEBUG Toggle Logging.lua
--   [main] ../Debug/SiSt-Live_DEBUG Run Self-Test.lua
--   [main] ../Debug/SiSt-Live_DEBUG Run Setlist Scenarios.lua
--   [main] ../Debug/SiSt-Live_DEBUG Looper State.lua
--   [nomain] ../lib/Log.lua
--   [nomain] ../lib/SiSt-Live_Log.lua
--   [nomain] ../lib/SiSt-Live_Button.lua
--   [nomain] ../lib/Actions.lua
--   [nomain] ../lib/SiSt-Live_Actions.lua
--   [nomain] ../lib/SiSt-Live_Mode.lua
--   [nomain] ../lib/SiSt-Live_ModeEffects.lua
--   [nomain] ../lib/SiSt-Live_SettingsDialog.lua
--   [nomain] ../lib/SiSt-Live_ToolbarSource.lua
--   [nomain] ../lib/ActionReferenceChecks.lua
--   [nomain] ../lib/SelfTest.lua
--   [nomain] ../lib/SiSt-Live_Tests.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Theme.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Screenset.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Fullscreen.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Layout.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_KeySection.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Mouse.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Windows.lua
--   [nomain] ../lib/Gui/Theme.lua
--   [nomain] ../lib/Gui/Window.lua
--   [nomain] ../lib/Gui/Widgets.lua
--   [nomain] ../lib/Gui/Dialog.lua
--   [nomain] ../lib/Gui/TextField.lua
--   [nomain] ../lib/Gui/Zoom.lua
-- @about
--   # SiSt-Live
--   REAPER as a playback machine for live shows, with an edit mode for preparing and a show mode
--   that is safe and simple to use on stage.
--
--   Actions installed by this package:
--   - SiSt-Live: Setup: shows the installed version and checks the installation
--   - Toggle Edit/Show mode: switches the mode. Toolbar button lit = show mode
--   - Configure modes: what happens in REAPER when the mode changes (theme, layouts, screenset,
--     fullscreen, keyboard section, mouse modifiers, windows)
--   - Apply current mode: applies the current mode again (e.g. from Scripts/__startup.lua)
--   - Setlist: the setlist (project tabs in show order)
--   - Status Display: the mode and any problems
--   - Toolbar: big buttons for the show, copied from a native floating toolbar
--   - Clear time selection and loop points: for custom actions, works while show mode locks them
--   - DEBUG Toggle Logging / DEBUG Run Self-Test: for troubleshooting. Run the self-test after
--     every REAPER update: it checks the native action IDs the mode effects use
--
--   Needs REAPER 7 and the js_ReaScriptAPI extension (for the setlist).
--
--   Everything installs below Scripts/SiSt-Live. The shared libraries are in Scripts/SiSt-Live/lib.

--[[
SiSt-Live: Setup

The main file of the SiSt-Live ReaPack package. Its header above lists every file of the package
(@provides): add new scripts and libraries there.

What it does for now: checks that every file of the package is installed (list read from the
header above, so it can't get out of step) and shows the result with the package version.
Later this is the place for the first-time setup (key maps, toolbars, screensets, themes).

Self test: Setup.self_test(), run by "DEBUG Run Self-Test" (test-only switch at the end of this file).
]]

local Setup = {}

-- Pure functions --------------------------------------------------------------

--- Reads "@version" and the "@provides" file list from the header text of this file.
--- Returns version (or nil) and a list of { path = "../lib/x.lua", main = true/false }.
--- The "." entry (this file) is skipped.
function Setup.parse_header(text)
  local version = text:match("%-%- @version%s+([^\r\n]+)")
  local files, in_provides = {}, false
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line:match("^%-%- @provides") then
      in_provides = true
    elseif in_provides then
      local opts, path = line:match("^%-%-%s+%[([^%]]*)%]%s+(.-)%s*$")
      if not path then
        path = line:match("^%-%-%s%s+(%S.-)%s*$")
        opts = ""
      end
      if not path or line:match("^%-%- @") then break end
      if path ~= "." then files[#files + 1] = { path = path, main = opts == "main" } end
    end
  end
  return version, files
end

--- "../lib/x.lua" relative to the folder of this script -> full path.
function Setup.resolve(script_dir, rel, sep)
  local parts = {}
  for part in (script_dir .. "/" .. rel):gmatch("[^/\\]+") do
    if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  local prefix = script_dir:match("^[/\\]") and sep or ""
  return prefix .. table.concat(parts, sep)
end

--- The package's [main] scripts as paths relative to the package folder ("Modes/x.lua"), from the parsed header.
function Setup.scripts_to_register(files)
  local scripts = {}
  for _, f in ipairs(files) do
    local rel = f.main and f.path:match("^%.%./(.+)$")
    if rel then scripts[#scripts + 1] = rel end
  end
  return scripts
end

-- Extensions ----------------------------------------------------------------------
-- Required REAPER extensions: one API function each tells whether it is installed.
Setup.EXTENSIONS = {
  { name = "SWS", api = "CF_GetSWSVersion",
    needed_for = "custom and cycle actions, clipboard in text fields" },
  { name = "js_ReaScriptAPI", api = "JS_ReaScriptAPI_Version",
    needed_for = "show mode: blocking the mouse in the arrange view, arrow cursor; Setlist file dialogs" },
  { name = "ReaPack", api = "ReaPack_GetOwner",
    needed_for = "installing and updating SiSt-Live" },
}

--- The required extensions that are not installed (entries of Setup.EXTENSIONS).
function Setup.missing_extensions()
  local missing = {}
  for _, ext in ipairs(Setup.EXTENSIONS) do
    if not reaper.APIExists(ext.api) then missing[#missing + 1] = ext end
  end
  return missing
end

--- Report text. r: version, files, missing (paths), added, failed (action list), extensions (missing ones),
--- tests ({ passed, failed, warnings, report } or nil), tests_skipped (reason, or nil).
function Setup.report(r)
  local version, files, missing, added, failed = r.version, r.files, r.missing, r.added, r.failed
  local lines = { ("SiSt-Live %s"):format(version or "(unknown version)"), "" }
  if #missing == 0 then
    lines[#lines + 1] = ("All %d files of the package are installed."):format(#files)
  else
    lines[#lines + 1] = ("%d of %d files are MISSING:"):format(#missing, #files)
    for _, path in ipairs(missing) do lines[#lines + 1] = "  " .. path end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reinstall the package 'SiSt-Live' in ReaPack (Extensions > ReaPack > Browse packages)."
  end
  if added and #added > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%d script%s added to the action list:"):format(#added, #added == 1 and "" or "s")
    for _, rel in ipairs(added) do lines[#lines + 1] = "  " .. rel end
  end
  if failed and #failed > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "NOT added to the action list:"
    for _, line in ipairs(failed) do lines[#lines + 1] = "  " .. line end
  end
  lines[#lines + 1] = ""
  if not r.extensions or #r.extensions == 0 then
    lines[#lines + 1] = "Required extensions are installed (SWS, js_ReaScriptAPI, ReaPack)."
  else
    lines[#lines + 1] = "MISSING extensions (Extensions > ReaPack > Browse packages):"
    for _, ext in ipairs(r.extensions) do lines[#lines + 1] = ("  %s: needed for %s"):format(ext.name, ext.needed_for) end
  end
  lines[#lines + 1] = ""
  if r.tests then
    local t = r.tests
    lines[#lines + 1] = ("Self-test: %d passed, %d failed%s."):format(t.passed, t.failed,
      t.warnings > 0 and (", %d warning%s"):format(t.warnings, t.warnings == 1 and "" or "s") or "")
    if t.failed > 0 or t.warnings > 0 then lines[#lines + 1] = "  The FAIL / WARN lines are in the full report." end
  else
    lines[#lines + 1] = "Self-test not run: " .. tostring(r.tests_skipped or "unknown reason")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Next step: 'Configure modes' sets what each mode does."
  return table.concat(lines, "\n")
end

-- Self test ---------------------------------------------------------------------

function Setup.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local header = table.concat({
    "-- @description X", "-- @version 1.2.3", "-- @provides", "--   [main] .", "--   [main] ../A/a.lua",
    "--   [nomain] ../lib/b.lua", "--   ../lib/c.lua", "-- @about", "--   [main] ../not/a/file.lua",
  }, "\r\n")
  local _, files = Setup.parse_header(header)
  check("header: files without '.', stops at the next tag", #files == 3 and files[1].path == "../A/a.lua"
    and files[3].path == "../lib/c.lua")
  check("header: main / nomain", files[1].main and not files[2].main and not files[3].main)

  check("resolve: '..' goes one folder up (windows)",
    Setup.resolve("C:\\R\\Scripts\\SiSt-Live\\Setup", "../lib/Gui/Theme.lua", "\\")
    == "C:\\R\\Scripts\\SiSt-Live\\lib\\Gui\\Theme.lua")
  check("resolve: unix absolute path keeps its root",
    Setup.resolve("/r/Scripts/SiSt-Live/Setup/", "../Modes/x.lua", "/") == "/r/Scripts/SiSt-Live/Modes/x.lua")

  local mains = Setup.scripts_to_register({ { path = "../Modes/a.lua", main = true }, { path = "../lib/b.lua", main = false },
    { path = "../Transport/c d.lua", main = true } })
  check("scripts_to_register: only [main] files, relative to the package folder",
    #mains == 2 and mains[1] == "Modes/a.lua" and mains[2] == "Transport/c d.lua")
  local added_report = Setup.report({ version = "1", files = { 1 }, missing = {}, added = { "Modes/a.lua" },
    failed = { "Modes/b.lua: ambiguous" } })
  check("report: added and failed scripts listed", added_report:find("1 script added", 1, true) ~= nil
    and added_report:find("Modes/a.lua", 1, true) ~= nil and added_report:find("NOT added", 1, true) ~= nil
    and added_report:find("ambiguous", 1, true) ~= nil)

  local r = Setup.report({ files = { 1, 2 }, missing = { "lib/x.lua" }, tests_skipped = "playback is running" })
  check("report: missing files listed", r:find("1 of 2 files are MISSING", 1, true) ~= nil
    and r:find("lib/x.lua", 1, true) ~= nil and r:find("unknown version", 1, true) ~= nil)
  check("report: skipped self-test says why", r:find("Self-test not run: playback is running", 1, true) ~= nil)

  -- extensions (fake APIExists): a missing one is named with what needs it
  local present = { CF_GetSWSVersion = true, ReaPack_GetOwner = true }
  local gone = require("SelfTest").with_reaper({ APIExists = function(name) return present[name] == true end },
    Setup.missing_extensions)
  local er = Setup.report({ files = {}, missing = {}, extensions = gone,
    tests = { passed = 3, failed = 1, warnings = 0 } })
  check("extensions: the missing one is reported with what needs it", #gone == 1 and gone[1].name == "js_ReaScriptAPI"
    and er:find("MISSING extensions", 1, true) ~= nil and er:find("js_ReaScriptAPI: needed for show mode", 1, true) ~= nil)
  check("report: self-test result with its failures", er:find("Self-test: 3 passed, 1 failed.", 1, true) ~= nil)

  -- the real header of this file lists the package
  local _, own = Setup.parse_header(Setup.own_header or "")
  check("own header lists the package files", Setup.own_header == nil or #own >= 10)

  return results
end

-- Main ----------------------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function main()
  local _, script_path = reaper.get_action_context()
  local script_dir = script_path:match("^(.*)[/\\]") or ""
  local sep = package.config:sub(1, 1)

  local text = read_file(script_path) or ""
  Setup.own_header = text
  local version, files = Setup.parse_header(text)

  local missing = {}
  for _, f in ipairs(files) do
    local path = Setup.resolve(script_dir, f.path, sep)
    if not reaper.file_exists(path) then missing[#missing + 1] = path end
  end

  -- The package's libraries (optional below: a missing one is already reported by the check above)
  package.path = script_dir .. sep .. ".." .. sep .. "lib" .. sep .. "?.lua;" .. package.path

  -- Add the package's scripts to the action list when they are not in it yet (ReaPack does this on install; a
  -- copied config or a new script needs it). Lookups elsewhere never add anything.
  local added, failed = {}, {}
  local has_actions, Actions = pcall(require, "SiSt-Live_Actions")
  if has_actions then
    for _, rel in ipairs(Setup.scripts_to_register(files)) do
      local cmd, why, kind = Actions.file_command(rel)
      if not cmd and kind == "missing" then
        local new, err = Actions.register(rel)
        if new then added[#added + 1] = rel else failed[#failed + 1] = rel .. ": " .. tostring(err) end
      elseif not cmd then
        failed[#failed + 1] = rel .. ": " .. tostring(why)
      end
    end
  end

  -- Register SiSt-Live's test list for "Run all self-tests" (optional: a missing SelfTest library is reported above)
  local list_path = script_dir .. sep .. ".." .. sep .. "lib" .. sep .. "SiSt-Live_Tests.lua"
  local has_test, SelfTest = pcall(require, "SelfTest")
  if has_test then SelfTest.register("SiSt-Live", list_path) end

  -- The self-test (about a second, only reads; the mode is restored). Never while playing or recording: the
  -- tests switch the mode for a moment, which must not happen during a show.
  local tests, tests_skipped
  if reaper.GetPlayState() & 5 ~= 0 then
    tests_skipped = "playback or recording is running"
  elseif not has_test then
    tests_skipped = "the SelfTest library is missing"
  else
    local suite, err = SelfTest.load_suite(list_path)
    if suite then
      local p, f, w, report = SelfTest.run_suites({ suite }, "SiSt-Live self-test", { console = false })
      tests = { passed = p, failed = f, warnings = w, report = report }
    else
      tests_skipped = "the test list could not be loaded: " .. tostring(err):match("^[^\r\n]*")
    end
  end

  local text = Setup.report({ version = version, files = files, missing = missing, added = added, failed = failed,
    extensions = Setup.missing_extensions(), tests = tests, tests_skipped = tests_skipped })
  local report = tests and tests.report
  if report and reaper.APIExists("CF_ShellExecute") then
    if reaper.MB(text .. "\n\nOpen the full self-test report?", "SiSt-Live Setup", 4) == 6 then
      reaper.CF_ShellExecute(report)
    end
  else
    reaper.MB(text .. (report and ("\n\nFull self-test report:\n" .. report) or ""), "SiSt-Live Setup", 0)
  end
end

-- Test-only switch (see lib/SelfTest.lua): hand over the tests instead of running the setup
if rawget(_G, "SELFTEST_COLLECT") then
  local own_path = debug.getinfo(1, "S").source:match("^@(.*)$")
  Setup.own_header = own_path and read_file(own_path) or nil -- lets the self test check the real header
  table.insert(SELFTEST_COLLECT, { name = "Setup", self_test = Setup.self_test })
else
  main()
  reaper.defer(function() end) -- no undo point
end
