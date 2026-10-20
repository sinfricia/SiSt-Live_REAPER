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
--   - Status display: mode button in the header. Show mode: "Hold for EDIT" (hold 1 s, no accidental
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
--   - Edit/show mode with mode effects: theme, layouts, screenset, fullscreen, keyboard section, locking
--   - Debug actions: "DEBUG Toggle Logging" and "DEBUG Run Self-Test"
-- @provides
--   [main] .
--   [main] ../Modes/SiSt-Live_Toggle Edit-Show Mode.lua
--   [main] ../Modes/SiSt-Live_Apply current mode.lua
--   [main] ../Modes/SiSt-Live_Configure modes.lua
--   [main] ../Setlist/SiSt-Live_Setlist.lua
--   [main] ../Status Display/SiSt-Live_Status Display.lua
--   [main] ../Toolbar/SiSt-Live_Toolbar.lua
--   [main] ../Transport/SiSt-Live_Clear time selection and loop points.lua
--   [main] ../Debug/SiSt-Live_DEBUG Toggle Logging.lua
--   [main] ../Debug/SiSt-Live_DEBUG Run Self-Test.lua
--   [nomain] ../lib/SiSt-Live_Log.lua
--   [nomain] ../lib/SiSt-Live_Button.lua
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
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Locking.lua
--   [nomain] ../lib/ModeEffects/SiSt-Live_ModeEffect_Windows.lua
--   [nomain] ../lib/Gui/Theme.lua
--   [nomain] ../lib/Gui/Window.lua
--   [nomain] ../lib/Gui/Widgets.lua
--   [nomain] ../lib/Gui/TextField.lua
-- @about
--   # SiSt-Live
--   REAPER as a playback machine for live shows, with an edit mode for preparing and a show mode
--   that is safe and simple to use on stage.
--
--   Actions installed by this package:
--   - SiSt-Live: Setup: shows the installed version and checks the installation
--   - Toggle Edit/Show mode: switches the mode. Toolbar button lit = show mode
--   - Configure modes: what happens in REAPER when the mode changes (theme, layouts, screenset,
--     fullscreen, keyboard section, locking, windows)
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

Self test: run with SiSt-Live debug logging on ("DEBUG Toggle Logging"): the result of
Setup.self_test() is printed to the console.
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

--- Report text: version, number of files, missing files.
function Setup.report(version, files, missing)
  local lines = { ("SiSt-Live %s"):format(version or "(unknown version)"), "" }
  if #missing == 0 then
    lines[#lines + 1] = ("All %d files of the package are installed."):format(#files)
  else
    lines[#lines + 1] = ("%d of %d files are MISSING:"):format(#missing, #files)
    for _, path in ipairs(missing) do lines[#lines + 1] = "  " .. path end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reinstall the package 'SiSt-Live' in ReaPack (Extensions > ReaPack > Browse packages)."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Next steps: 'Configure modes' sets what each mode does, 'DEBUG Run Self-Test' checks it."
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
  local version, files = Setup.parse_header(header)
  check("header: version", version == "1.2.3")
  check("header: files without '.', stops at the next tag", #files == 3 and files[1].path == "../A/a.lua"
    and files[3].path == "../lib/c.lua")
  check("header: main / nomain", files[1].main and not files[2].main and not files[3].main)

  check("resolve: '..' goes one folder up (windows)",
    Setup.resolve("C:\\R\\Scripts\\SiSt-Live\\Setup", "../lib/Gui/Theme.lua", "\\")
    == "C:\\R\\Scripts\\SiSt-Live\\lib\\Gui\\Theme.lua")
  check("resolve: unix absolute path keeps its root",
    Setup.resolve("/r/Scripts/SiSt-Live/Setup/", "../Modes/x.lua", "/") == "/r/Scripts/SiSt-Live/Modes/x.lua")

  check("report: all installed", Setup.report("1.0", { 1, 2 }, {}):find("All 2 files", 1, true) ~= nil)
  local r = Setup.report(nil, { 1, 2 }, { "lib/x.lua" })
  check("report: missing files listed", r:find("1 of 2 files are MISSING", 1, true) ~= nil
    and r:find("lib/x.lua", 1, true) ~= nil and r:find("unknown version", 1, true) ~= nil)

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

  -- Self test into the console when debug logging is on (the Log library is optional here:
  -- if it is missing, the check above already reports it)
  package.path = script_dir .. sep .. ".." .. sep .. "lib" .. sep .. "?.lua;" .. package.path
  local has_log, Log = pcall(require, "SiSt-Live_Log")
  if has_log and Log.is_debug() then
    local out = { "=== SiSt-Live Setup self test ===" }
    local failed = 0
    for _, r in ipairs(Setup.self_test()) do
      out[#out + 1] = ("  %s  %s"):format(r.ok and "PASS" or "FAIL", r.name)
      if not r.ok then failed = failed + 1 end
    end
    out[#out + 1] = ("%d failed"):format(failed)
    reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  end

  -- Register SiSt-Live's test list for "Run all self-tests" (optional: a missing SelfTest library is reported above)
  local has_test, SelfTest = pcall(require, "SelfTest")
  if has_test then
    SelfTest.register("SiSt-Live", script_dir .. sep .. ".." .. sep .. "lib" .. sep .. "SiSt-Live_Tests.lua")
  end

  reaper.MB(Setup.report(version, files, missing), "SiSt-Live Setup", 0)
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
