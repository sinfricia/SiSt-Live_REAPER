-- @noindex
-- SiSt-Live Setlist. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   # SiSt-Live Setlist
--   A Tool to manage REAPER project tabs. Designed to be used as a setlist manager in a live environment.
--
--   Startup modifiers: hold Ctrl to ignore the saved window state, Shift to ignore the autosave,
--   Alt to run the built-in self tests (results in the REAPER console).
--
--   Logging: the shared SiSt-Live log (lib/SiSt-Live_Log.lua), component "Setlist". Debug lines appear
--   while "DEBUG Toggle Logging" is on. Warnings always go to <resource path>/Data/SiSt-Live/SiSt-Live.log,
--   and to the console too, except in show mode.
--
--   Autosave: the setlist is saved to <resource path>/Data/SiSt-Live_Setlist_autosave.rsl after every change.
--   On the first start after REAPER was opened you are asked whether to load it. If you start with a clean
--   slate instead, the old autosave is kept as SiSt-Live_Setlist_autosave_backup.rsl (open it with Load Setlist).
--
--   Window: right-click on an entry for the entry's menu, anywhere else for the window menu (docking and the
--   default position). The window remembers its position per edit/show mode: put it where you want it in
--   each mode once. "Save as default position" stores a position you can always go back to.
--
--   Libraries (lib folder, looked up next to this script, one folder up (Scripts/SiSt-Live/lib) and in
--   <resource path>/Scripts/SiSt-Live/lib):
--   - lib/Gui (required): window, theme colors, buttons.
--   - lib/SiSt-Live_Mode.lua (optional): the edit/show mode. Without it the script runs in show mode.
--   Both are installed with the package "SiSt-Live".
--
--   Edit/show mode: the list follows the current project in both modes, except when you click a project in the
--   list in edit mode. Switching to show mode also jumps to it. Show mode locks all editing of the setlist
--   (Queue Project still works). An arrow at the list edge points to the current project when it is out of view.

-- Shared SiSt-Live libraries, loaded in LoadSharedLibs().
-- Gui (required): without it the script doesn't start.
local Theme, Window, Widgets = nil, nil, nil -- lib/Gui/Theme.lua, Window.lua, Widgets.lua
local win = nil                              -- the Window object (created in Init)
-- Mode (optional): nil if it could not be loaded. The script then runs without the mode switch (show mode).
local Mode = nil     -- lib/SiSt-Live_Mode.lua
local pollMode = nil -- returned by Mode.watch(); call once per frame to pick up mode changes
-- Log (shared logging): loaded first in LoadSharedLibs(). Until then, or if it can't be loaded, `log` is a
-- stand-in that drops debug/info lines and prints warnings and errors to the console.
local Log = nil -- lib/SiSt-Live_Log.lua

local function FallbackLine(level)
   return function(_, fmt, ...)
      local ok, msg = pcall(string.format, tostring(fmt), ...)
      reaper.ShowConsoleMsg("[Setlist] " .. level .. " " .. (ok and msg or tostring(fmt)) .. "\n")
   end
end
local log = {
   debug = function() end,
   info = function() end,
   warn = FallbackLine("WARN"),
   error = FallbackLine("ERROR"),
}

-- True while SiSt-Live debug logging is on ("DEBUG Toggle Logging"). Use it to skip expensive debug output.
function IsDebug()
   return Log ~= nil and Log.is_debug()
end

function PrintListPaths(list)
   if not IsDebug() then return end

   for _, entry in ipairs(list) do
      log:debug("  [%s] (tabIdx [%s]): %s", entry.listIdx or -1, entry.tabIdx or -1, tostring(entry.path))
   end
end

function PrintEntry(entry)
   if not IsDebug() then return end
   log:debug("  Printing Entry:")
   for k, v in pairs(entry) do
      log:debug("    %s: %s", tostring(k), tostring(v))
   end
end

local scriptName = "Sist-Live_Setlist" -- ExtState section (kept from earlier versions: saved state stays)
local WINDOW_TITLE = "SiSt-Live Setlist"

--------------------------
------- CONSTANTS --------
--------------------------

-- Possible values of entry.type
local ENTRY = { PROJECT = "project", TEXT = "text", MISSING = "missing" }

-- Operating modes, set from the shared SiSt-Live Mode library. Switching to SHOW jumps to the current project.
-- Following the current project on project changes happens in both modes.
local MODE = { SHOW = "show", EDIT = "edit" }

-- Shared SiSt-Live libraries (owned by other packages, not by this script)
local SHARED_LIB_PROBE = "Gui/Theme.lua" -- a folder containing this file is taken as the lib folder

local TITLE_TEXT = "REAPER SETLIST"

-- REAPER action command IDs used by the script
local CMD = {
   NEW_PROJ_TAB = 40859,   -- File: New project tab
   CLOSE_PROJ_TAB = 40860, -- File: Close current project tab
   TAB_MOVE_LEFT = 3242,   -- Project tabs: Move project tab left by one
   TAB_MOVE_RIGHT = 3243,  -- Project tabs: Move project tab right by one
}

-- Keyboard modifier bit masks (same layout for gfx.mouse_cap and JS_Mouse_GetState)
local MOD = { CTRL = 4, SHIFT = 8, ALT = 16 }

-- How many times ResolveConflictsWithOpenProj may run by itself before it shows the error dialog
local MAX_RESOLVE_ATTEMPTS = 3

--------------------------
------- VARIABLES --------
--------------------------

local displayTabIdx = true

--- EXT STATE ---
local ExtStateSection = scriptName -- also the Window's section: its "WindowState" key is the same as before
local ExtKeySetlist = "Setlist"
local ExtKeySessionMarker = "StartedInThisSession" -- never persisted: empty again after a REAPER restart

--- DATA ---
local setlist = {} -- Table of entries with fields { "name", "path", "proj", "type", "color", "listIdx", "tabIdx",} though not all fields need to be present
local setlistTotalTime = 0

local listIdxToTabIdxLookup = {} --stores for every index in setlist (1-based) the coresponding project tab index (0-based). Corresponding means the next project entry in the list is at this tabIdx.
local tabIdxToListIdxLookup = {}
local openProjCount = 0
local currentProj = reaper.EnumProjects(-1)
local lastProject = currentProj

--- GUI CONFIG ---
-- Constants only. Never written to at runtime. Reads of gui.<key> fall through to this table.
local CFG = {
   ctrlPanelSize = 90,
   buttonFontSize = 18,
   titleHeight = 56,
   leftBorder = 5,
   entryIndent = 10,

   -- Base sizes at zoom level 0. The zoomed values live in gui (see ApplyZoom).
   entryTextSize = 24,
   projLenTextSize = 16,
   linePadding = 18,

   minZoomLevel = -8,
   maxZoomLevel = 16,
   zoomDelay = 0.10, -- seconds between zoom steps while a zoom button is held

   activeProjHighlight = { 0.57, 0.97, 0.9, 0.7 },
   nextProjHighlight = { 0.25, 0.67, 0.6, 0.3 },
   dragHighlight = { 1, 0.8, 0.4, 0.7 },
   entryHighlights = {
      [ENTRY.MISSING] = { 1, 0, 0, 0.6 },    --red
      [ENTRY.TEXT] = { 1.0, 0.5, 0.2, 0.2 }, -- light orange
      -- projects have no default highlight
   },
   textEntryAlpha = 0.9,                      -- text notes: theme text color, slightly faded

   transportColors = {
      { 0.14, 0.99, 0.22, 1 }, --play
      {},
      {},
      {},
      { 0.89, 0.24, 0.23, 1 } -- record
   },
   playPosColor = { 0.95, 0.82, 0.45, 0.6 },

   dragThreshold = 6, -- pixels the mouse must move before a drag starts
   dropIndicatorThickness = 4,
   dragScrollMargin = 1, -- Margin in which list scrolls while dragging entry
   dragScrollSpeed = 0.3,

   scrollW = 20,

   doubleClickThreshold = 0.30,                 -- seconds between two clicks to qualify as double click


   smoothScrollTime = 0.08,                     -- time constant (seconds) of the animated follow-scroll. 0 = jump instantly

   offscreenIndicatorW = 44,                    -- arrow shown at the list edge when the current project is out of view
   offscreenIndicatorH = 18,
   offscreenIndicatorColor = { 0.57, 0.97, 0.9, 0.9 },

   buttonW = 140,
   buttonH = 30,
}

--- GUI STATE ---
-- Everything that changes at runtime. Missing keys are looked up in CFG.
local gui = setmetatable({
   -- Saved with the window (Window extra_keys, copied in OnWindowOpen / OnWindowClose)
   zoomLevel = 0,
   scrollOffset = 0,

   -- Derived layout values (calculated in ApplyZoom, OnWindowOpen and Frame)
   lineHeight = 0,
   minHeight = 0, --currently unused
   minWidth = 0,  --currently unused
   listH = 0,
   entryTextSize = CFG.entryTextSize,
   projLenTextSize = CFG.projLenTextSize,
   linePadding = CFG.linePadding,

   -- Mouse state
   leftClick = false,
   rightClick = false,
   prevLeftClick = false,
   prevRightClick = false,
   leftClickHandled = false,
   rightClickHandled = false,
   lastClickDownPos = { x = 0, y = 0 },

   -- Double-click tracking
   lastClickTime = 0,   -- timestamp of last click (reaper.time_precise)
   lastClickIdx = nil,  -- list index of last clicked entry
   doubleClick = false, -- true only on frame where second click detected

   -- Scrolling
   numVisibleEntries = 0,
   scrollH = 0,
   scrollY = 0,
   maxScroll = 0,       -- MANUAL range (wheel, scrollbar, drag): last entry at the bottom of the window
   followMaxScroll = 0, -- FOLLOW range (autoscroll): may leave empty rows at the end of the list
   scrollBarGrabStart = 0,
   scrollBarGrabOffset = 0,
   draggingScroll = false,
   fractionalScrollOffset = 0, --used for scrolling while dragging an entry to allow fractional scrolling speeds

   -- Drag & drop
   draggingEntry = false,
   dragEntryListIdx = 0,
   dropIdx = nil,
   dragDirection = 0,
   dragStartY = 0,
   dragThreshReached = nil,

   -- Follow-scroll (keeps the current project near the top of the list)
   mode = MODE.SHOW,         -- set from the shared Mode library (see OnSharedModeChanged). Stays SHOW without it.
   followPending = true,     -- true = scroll to the current project as soon as possible (also on startup)
   listClickTarget = nil,    -- project just selected by clicking it in the list (no follow in edit mode)
   displayOffset = nil,      -- drawn scroll position (may be fractional while animating). nil = not started yet
   lastAnimTime = nil,
   pressOnIndicator = false, -- the current mouse press started on the off-screen arrow (no drag from it)

   -- Drawing helpers
   isNextProj = false,    -- used to draw special highlight for project that comes after current in list
   currProjDrawn = false, --used to handle situations where the same project is open multiple times.
}, { __index = CFG })

local terminate = false

--------------------------
--- UTILITY FUNCTIONS ----
--------------------------

function GetProjectLengthFromMarker(proj) -- used because reaper.GetProjectLength was unreliable...
   local markerCount = reaper.CountProjectMarkers(proj)

   for i = markerCount - 1, 0, -1 do
      local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers2(proj, i)
      if retval and not isrgn then
         return pos
      end
   end

   return 0
end

function FormatTimeMMSS(seconds)
   local minutes = math.floor(seconds / 60)
   local secs    = math.floor(seconds % 60)
   return string.format("%02d:%02d", minutes, secs)
end

function RgbaIntToFloat(r, g, b, a)
   if not r or not g or not b then return end
   if not a then a = 255 end

   local rFloat = r / 255
   local gFloat = g / 255
   local bFloat = b / 255
   local aFloat = a / 255

   return rFloat, gFloat, bFloat, aFloat
end

function CopyTable(tbl)
   if type(tbl) ~= "table" then return tbl end
   local newTbl = {}
   for k, v in pairs(tbl) do
      if type(v) == "table" then
         newTbl[k] = CopyTable(v)
      else
         newTbl[k] = v
      end
   end
   return newTbl
end

function Clamp(val, min, max)
   return math.max(min, math.min(max, val))
end

function FileExists(path)
   local file = io.open(path, "r")
   if file then
      file:close()
      return true
   else
      return false
   end
end

function CountOpenProjects()
   openProjCount = 0
   while true do
      local proj = reaper.EnumProjects(openProjCount)
      if not proj then return end
      openProjCount = openProjCount + 1
   end
end

function CloseProject(proj)
   local prevProj = reaper.EnumProjects(-1) -- remember which tab was active
   reaper.SelectProjectInstance(proj)
   reaper.Main_OnCommand(CMD.CLOSE_PROJ_TAB, 0)
   if prevProj ~= proj and reaper.ValidatePtr(prevProj, "ReaProject*") then
      reaper.SelectProjectInstance(prevProj) -- go back to the tab the user was on
   end
end

function GetCurrProjParentDir()
   local currProjPath = reaper.GetProjectPath()

   if currProjPath == "" then
      return ""
   end

   local parentDir = currProjPath:match("^(.*)[\\/].*$")

   -- Check if proj is at root of drive
   if not parentDir then
      parentDir = currProjPath
   end

   return parentDir
end

function ExtractProjNameFromPath(path)
   if not path:find("[\\/]") then return path end
   local fileName = path:match("([^\\/]+)$")
   if not fileName then return path end -- path ends with a separator
   fileName = fileName:gsub("%.[rR][pP][pP]$", "")
   return fileName
end

function GetProjFromPath(path, duplicateNumber)
   if not duplicateNumber then
      duplicateNumber = 0
   end
   local idx = 0

   log:debug("Getting project from path")
   log:debug("  Looking for (duplicate) instance " .. duplicateNumber)
   while true do
      local proj, projPath = reaper.EnumProjects(idx)
      if not proj then
         log:debug("    Not found. Project not open.")
         return nil
      end
      if path == projPath then
         if duplicateNumber == 0 then
            log:debug("    Found at tab idx [%d]", idx)
            return proj
         else
            duplicateNumber = duplicateNumber - 1
         end
      end
      idx = idx + 1
   end
end

function GetProjTabIdx(targetProj)
   local idx = 0
   while true do
      local proj = reaper.EnumProjects(idx)
      if not proj then return end
      if proj == targetProj then
         return idx
      end
      idx = idx + 1
   end
end

function PadNumberStringWithZeroes(numberStr, numDigits)
   local paddingLength = numDigits - #numberStr

   if paddingLength > 0 then
      numberStr = string.rep("0", paddingLength) .. numberStr
   end

   return numberStr
end

function IsMouseInRect(x, y, w, h)
   return gfx.mouse_x >= x and gfx.mouse_x <= x + w and gfx.mouse_y >= y and gfx.mouse_y <= y + h
end

function IsPointInRect(x, y, w, h, px, py)
   return px >= x and px <= x + w and py >= y and py <= y + h
end

function CheckDependencies()
   if reaper.APIExists('JS_Dialog_BrowseForOpenFiles') then return true end

   local ret = reaper.MB(
      "This script requires the JS_ReaScriptAPI extension.\n\nClick OK to open ReaPack and install it, then restart the script.",
      "Missing dependency", 1)

   if ret == 1 then
      if reaper.APIExists('ReaPack_BrowsePackages') then
         reaper.ReaPack_BrowsePackages('js_ReaScriptAPI: API functions for ReaScripts')
      else
         reaper.MB(
            "Couldn't find ReaPack. Visit https://reapack.com/ for installation instructions, or get JS_ReaScriptAPI from https://forum.cockos.com/showthread.php?t=212174",
            "ReaPack missing", 0)
      end
   end

   return false
end

-- Pure function. Folders that may contain the shared SiSt-Live libraries, most likely first.
-- scriptPath: full path of this script (nil if unknown). resourcePath: REAPER resource folder. sep: path separator.
function GetSharedLibSearchDirs(scriptPath, resourcePath, sep)
   sep = sep or "/"
   local dirs = {}

   local scriptDir = scriptPath and scriptPath:match("^(.*[\\/])")
   if scriptDir then
      dirs[#dirs + 1] = scriptDir .. "lib" .. sep                -- lib next to this script
      dirs[#dirs + 1] = scriptDir .. ".." .. sep .. "lib" .. sep -- Scripts/SiSt-Live/<folder>/ -> Scripts/SiSt-Live/lib
   end

   if resourcePath and resourcePath ~= "" then
      dirs[#dirs + 1] = resourcePath .. sep .. "Scripts" .. sep .. "SiSt-Live" .. sep .. "lib" .. sep
   end

   return dirs
end

-- Returns the first search folder that contains the shared libraries, plus the list of folders searched.
function FindSharedLibDir()
   local _, scriptPath = reaper.get_action_context()
   local dirs = GetSharedLibSearchDirs(scriptPath, reaper.GetResourcePath(), package.config:sub(1, 1))
   for _, dir in ipairs(dirs) do
      if reaper.file_exists(dir .. SHARED_LIB_PROBE) then return dir, dirs end
   end
   return nil, dirs
end

function WarnSharedLibsUnavailable(details)
   reaper.MB(details .. "\n\nThe setlist keeps working, but without the edit/show mode switch (always show mode).\n" ..
      "Reinstall the package 'SiSt-Live' in ReaPack to get the Mode library.",
      "SiSt-Live: Mode library not available", 0)
end

function ShowGuiLibMissing(details)
   reaper.MB(details .. "\n\nThe setlist can't start without lib/Gui.\n" ..
      "Reinstall the package 'SiSt-Live' in ReaPack to get it.",
      "SiSt-Live: Gui library not available", 0)
end

-- Loads the shared libraries.
-- Gui (required): on failure an error is shown and false is returned: the script must not start.
-- Mode (optional, loads its own Log and Button helpers): on failure one warning, the list stays in show mode.
-- Must be called during the first run of the script (not from a deferred function): get_action_context.
-- Returns true if the script can run.
function LoadSharedLibs()
   local dir, searched = FindSharedLibDir()
   if not dir then
      ShowGuiLibMissing("Couldn't find " .. SHARED_LIB_PROBE .. " in:\n\n" .. table.concat(searched, "\n"))
      return false
   end

   if not package.path:find(dir, 1, true) then
      package.path = dir .. "?.lua;" .. package.path
   end

   -- Log first, so everything after it is logged. Optional: without it the stand-in logger stays.
   local logOk, logLib = pcall(require, "SiSt-Live_Log")
   if logOk then
      Log = logLib
      log = Log.get("Setlist")
   else
      log:warn("Log library could not be loaded, debug logging is off: %s", tostring(logLib))
   end

   local guiOk, guiErr = pcall(function()
      Theme = require("Gui.Theme")
      Window = require("Gui.Window")
      Widgets = require("Gui.Widgets")
   end)
   if not guiOk then
      ShowGuiLibMissing("Loading lib/Gui from\n" .. dir .. "\nfailed:\n\n" .. tostring(guiErr))
      return false
   end

   local ok, err = pcall(function()
      Mode = require("SiSt-Live_Mode")
      pollMode = Mode.watch(OnSharedModeChanged) -- calls OnSharedModeChanged once right away
   end)

   if not ok then
      Mode, pollMode = nil, nil
      SetListMode(MODE.SHOW)
      WarnSharedLibsUnavailable("Loading the Mode library from\n" .. dir .. "\nfailed:\n\n" .. tostring(err))
      return true -- the Gui library is there: the script runs without the mode switch
   end

   log:info("shared libraries loaded from %s - list mode: %s", dir, gui.mode)
   return true
end

-- One line for the self test report.
function DescribeSharedLibState()
   local guiState = (Log and "Log library: loaded. " or "Log library: NOT loaded. ") ..
       (Window and "Gui library: loaded. " or "Gui library: NOT loaded. ")
   if not Mode then return guiState .. "Mode library: NOT loaded (mode switch inactive, always show mode)" end
   return guiState .. "Mode library: loaded. Shared mode: " .. tostring(Mode.get()) .. ", list mode: " .. tostring(gui.mode)
end

-- True if the given modifier key (MOD.CTRL, MOD.SHIFT, MOD.ALT) is currently held.
-- Works before gfx.init, which gfx.mouse_cap does not.
function IsModifierDown(mask)
   return reaper.JS_Mouse_GetState(mask) & mask ~= 0
end

function NormalizePath(path)
   if not path then return "" end

   if type(path) ~= "string" then return path end

   path = path:gsub("\\", "/")

   if #path > 1 then
      path = path:gsub("/+$", "")
   end
   return path
end

function SanitizePath(path)
   if not path then return "" end

   if type(path) ~= "string" then return path end

   local sep = package.config:sub(1, 1) -- "\" on Windows, "/" on Unix

   if sep == "\\" then
      -- On Windows
      path = path:gsub("/", "\\")
   else
      -- On Unix
      path = path:gsub("\\", "/")
   end

   return path
end

function CheckIfFileInRelativeDir(loadPath, projPath)
   loadPath = NormalizePath(loadPath)
   projPath = NormalizePath(projPath)

   local loadDir = loadPath:match("^(.*)/[^/]*$")
   if not loadDir then return projPath end

   local projDir = projPath:match("^(.*)/[^/]*$") or ""

   if projDir == loadDir then
      return projPath
   end

   local fileName = projPath:match("([^/]+)$")
   if not fileName then return projPath end

   local candidate = loadDir .. "/" .. fileName

   local f = io.open(candidate, "r")
   if f then
      f:close()
      log:debug("Found '" .. fileName .. "' in setlist directory.")
      return candidate -- File found in loadPath dir
   else
      return projPath  -- Fall back to original projPath
   end
end

--------------------------
----- DATA FUNCTIONS -----
--------------------------

--- DATA EXPORT/IMPORT ---

-- Characters that would break the "key=value; key=value;" format are stored as %XX.
function EncodeValue(str)
   return (str:gsub("[%%;={}\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end

function DecodeValue(str)
   return (str:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Fields that only make sense while the script is running and are rebuilt on load
local TRANSIENT_FIELDS = { proj = true, listIdx = true, tabIdx = true }

function SerializeEntry(entry)
   local parts = { "enc=1" } -- marker: values below are percent-encoded (older saves have no marker)

   for k, v in pairs(entry) do
      if not TRANSIENT_FIELDS[k] then
         local valueType = type(v)
         if valueType == "string" then
            if k == "path" and entry.type ~= ENTRY.TEXT then
               v = NormalizePath(v)
            end
            parts[#parts + 1] = k .. "=" .. EncodeValue(v)
         elseif valueType == "number" or valueType == "boolean" then
            parts[#parts + 1] = k .. "=" .. EncodeValue(tostring(v))
         elseif valueType == "table" then -- only flat lists of numbers (e.g. highlight color) are supported
            local items = {}
            for i = 1, #v do
               items[i] = tostring(v[i])
            end
            parts[#parts + 1] = k .. "={" .. table.concat(items, ",") .. "}"
         end
      end
   end

   return table.concat(parts, "; ") .. "; "
end

function CreateSetlistString(list, separator)
   local entryStrings = {}
   log:debug("Creating setlist string:")
   for _, entry in ipairs(list) do
      if entry.path ~= "Unsaved Project" then
         table.insert(entryStrings, SerializeEntry(entry))
      end
   end

   return table.concat(entryStrings, separator)
end

-- Parses one serialized entry into a table. Does not validate it.
function ParseEntryString(entryStr)
   local entry = {}
   for k, v in entryStr:gmatch("([^; ]+)=([^;]+)") do
      if v:find("^{.*}$") then -- value is a list
         local tbl = {}
         for s in v:gmatch("([^{},]+)") do
            tbl[#tbl + 1] = tonumber(s) or s
         end
         entry[k] = tbl
      else
         entry[k] = (v:gsub("^%s*(.-)%s*$", "%1")) -- trim spaces
      end
   end

   if entry.enc == "1" then
      for k, v in pairs(entry) do
         if type(v) == "string" and k ~= "enc" then
            entry[k] = DecodeValue(v)
         end
      end
   end
   entry.enc = nil

   return entry
end

function ParseSetlistString(setlistStr, separator)
   if setlistStr == "" then
      return {}, {}
   end

   local entryStrings = {}
   for entryStr in string.gmatch(setlistStr, "([^" .. separator .. "]+)") do
      table.insert(entryStrings, entryStr)
   end

   local parsedSetlist = {}
   local duplicateTracker = {}
   local invalidEntries = {}
   log:debug("   Parsing Setlist string")

   for _, entryStr in ipairs(entryStrings) do
      local newEntry = ParseEntryString(entryStr)

      if newEntry.type ~= ENTRY.TEXT then
         newEntry.path = SanitizePath(newEntry.path)
      end

      local entryType = newEntry.type
      local path = newEntry.path

      if not entryType or not path or entryType == "" or path == "" then
         table.insert(invalidEntries, entryStr)
         log:warn("invalid setlist entry skipped: %s", entryStr)
      else
         local trackerKey = path
         if entryType == ENTRY.PROJECT and not path:find("[\\/]") then trackerKey = "" end -- handling unsaved projects

         if duplicateTracker[trackerKey] then
            duplicateTracker[trackerKey] = duplicateTracker[trackerKey] + 1
         else
            duplicateTracker[trackerKey] = 0
         end

         -- initializing things that are not (or not properly) stored in the setlist string
         newEntry.proj = nil
         if entryType == ENTRY.PROJECT then
            newEntry.proj = GetProjFromPath(path, duplicateTracker[trackerKey])
         end

         if not newEntry.name then
            newEntry.name = ExtractProjNameFromPath(path)
         end

         newEntry.listIdx = #parsedSetlist + 1
         newEntry.tabIdx = newEntry.proj and GetProjTabIdx(newEntry.proj) or nil

         table.insert(parsedSetlist, newEntry)

         log:debug("     " .. entryStr)
         log:debug("     " .. newEntry.name)
      end
   end

   return parsedSetlist, invalidEntries
end

-- AUTOSAVE: the working state is written to a file in the REAPER resource folder after every change.
-- This is separate from the user's own setlist files (.rsl), which are only written by "Save Setlist".
local AUTOSAVE_FILENAME = "SiSt-Live_Setlist_autosave.rsl"
local AUTOSAVE_BACKUP_FILENAME = "SiSt-Live_Setlist_autosave_backup.rsl" -- old autosave after a clean start
local autosaveErrorShown = false

function GetDataFilePath(fileName)
   local sep = package.config:sub(1, 1)
   return reaper.GetResourcePath() .. sep .. "Data" .. sep .. fileName
end

function GetAutosavePath()
   return GetDataFilePath(AUTOSAVE_FILENAME)
end

function GetAutosaveBackupPath()
   return GetDataFilePath(AUTOSAVE_BACKUP_FILENAME)
end

function ReadTextFile(path)
   local file = io.open(path, "rb")
   if not file then return nil end
   local content = file:read("a")
   file:close()
   return content
end

-- File functions used by WriteTextFileAtomic. Tests pass a fake one (FakeFileSystem in the self tests).
local REAL_FS = { open = io.open, rename = os.rename, remove = os.remove }

local function ReadWith(fs, path)
   local f = fs.open(path, "rb")
   if not f then return nil end
   local content = f:read("a")
   f:close()
   return content
end

-- Writes to "<path>.tmp" first and then moves it over the target, so a crash while writing can never
-- leave a half-written autosave behind. Returns true, or false + error message (which step failed).
--
-- Robust against folders that a sync client watches (kDrive, Dropbox, OneDrive): there a rename can
-- report a failure although it happened, or a file can be locked for a moment. So:
--   - the old file is never deleted before the new one is in place: it is moved to "<path>.bak" and
--     only removed at the end (or moved back if the new one couldn't be put in place)
--   - success is decided by reading the file back, not by the return value of rename
--   - last resort: the content (still in memory) is written directly into the target
-- fs: optional file functions { open, rename, remove } (tests).
function WriteTextFileAtomic(path, content, fs)
   fs = fs or REAL_FS
   local tmpPath, bakPath = path .. ".tmp", path .. ".bak"
   local function isWritten() return ReadWith(fs, path) == content end
   local function cleanup()
      fs.remove(tmpPath)
      fs.remove(bakPath)
   end

   local file, err = fs.open(tmpPath, "wb")
   if not file then return false, "writing " .. tmpPath .. ": " .. tostring(err) end
   local written, writeErr = file:write(content)
   file:close()
   if not written then
      fs.remove(tmpPath)
      return false, "writing " .. tmpPath .. ": " .. tostring(writeErr)
   end

   -- 1. Straight rename (works everywhere except Windows when the target exists)
   local renamed, renameErr = fs.rename(tmpPath, path)
   if renamed or isWritten() then
      cleanup()
      return true
   end

   -- 2. Windows: move the old file aside first, then rename. The old file stays as .bak until the end
   fs.remove(bakPath)
   fs.rename(path, bakPath)
   renamed, renameErr = fs.rename(tmpPath, path)
   if renamed or isWritten() then
      cleanup()
      return true
   end

   -- 3. Rename failed: put the old file back (if it was moved), then check again: a rename that reported
   --    a failure may have happened after all
   if ReadWith(fs, path) == nil and ReadWith(fs, bakPath) ~= nil then fs.rename(bakPath, path) end
   if isWritten() then
      cleanup()
      return true
   end

   -- 4. Last resort: write the content directly into the target (not atomic, but nothing is lost)
   local direct = fs.open(path, "wb")
   if direct then
      local ok = direct:write(content)
      direct:close()
      if ok and isWritten() then
         cleanup()
         log:warn("autosave: rename failed (%s), the file was written directly instead", tostring(renameErr))
         return true
      end
   end
   return false, "renaming " .. tmpPath .. " to " .. path .. ": " .. tostring(renameErr)
end

function SaveAutosave()
   log:debug("Saving autosave")
   local path = GetAutosavePath()
   reaper.RecursiveCreateDirectory(path:match("^(.*)[\\/][^\\/]*$") or "", 0) -- make sure the Data folder exists
   local ok, err = WriteTextFileAtomic(path, CreateSetlistString(setlist, "\n"))
   if not ok then
      log:warn("autosave failed: %s", tostring(err))
      if not autosaveErrorShown then -- warn once, not on every change
         autosaveErrorShown = true
         reaper.MB("Could not write the autosave file:\n" .. GetAutosavePath() .. "\n\n" .. tostring(err),
            "Setlist autosave failed", 0)
      end
   end
end

-- Reads and parses the autosave without touching any projects.
-- Returns parsedEntries, invalidEntryStrings, rawString, sourceDescription.
function ReadAutosave()
   local setlistStr = ReadTextFile(GetAutosavePath())
   local source = "autosave file"

   if not setlistStr then -- no file yet: fall back to the old in-session ExtState (previous script versions)
      setlistStr = reaper.GetExtState(ExtStateSection, ExtKeySetlist)
      source = "EXT_STATE"
   end

   log:debug("Retrieving from " .. source .. ": ")
   local list, invalidEntries = ParseSetlistString(setlistStr, "\n")
   log:debug("Retrieved " .. #list .. " entries")
   return list, invalidEntries, setlistStr, source
end

-- Uses a parsed autosave: reports invalid entries, then checks it against the open projects
-- (opens missing projects, asks about conflicts). Returns the resulting setlist.
function ApplyAutosave(list, invalidEntries, source)
   if next(invalidEntries) then
      HandleIInvalidSetlistStringEntries(list, invalidEntries, "from " .. source)
   end

   if next(list) then
      return ResolveConflictsWithOpenProj(list, false)
   end
   return {}
end

-- Keeps a copy of the autosave before a clean start overwrites it. Returns true on success.
function BackupAutosave(setlistStr)
   local ok, err = WriteTextFileAtomic(GetAutosaveBackupPath(), setlistStr or "")
   if ok then
      log:info("old autosave backed up to %s", GetAutosaveBackupPath())
   else
      reaper.MB("Could not back up the old autosave to:\n" .. GetAutosaveBackupPath() .. "\n\n" .. tostring(err),
         "Setlist autosave backup failed", 0)
   end
   return ok
end

-- True if this is the first start of the script since REAPER was opened (non-persistent ExtState marker).
function IsFirstRunInSession()
   return reaper.GetExtState(ExtStateSection, ExtKeySessionMarker) == ""
end

function MarkSessionStarted()
   reaper.SetExtState(ExtStateSection, ExtKeySessionMarker, "1", false)
end

-- Pure function. What to do with the autosave at startup:
-- "ignore" = start from the open projects, "ask" = first start since REAPER was opened,
-- "load" = script restarted in the same REAPER session.
function GetStartupAutosaveAction(hasAutosave, firstRunInSession, ignoreRequested)
   if ignoreRequested or not hasAutosave then return "ignore" end
   if firstRunInSession then return "ask" end
   return "load"
end

-- Pure function. Short summary of a setlist for dialogs, e.g. "47 entries (25 projects, 22 text notes)".
function DescribeSetlistContents(list)
   local counts = { [ENTRY.PROJECT] = 0, [ENTRY.TEXT] = 0, [ENTRY.MISSING] = 0 }
   for _, entry in ipairs(list) do
      if counts[entry.type] then counts[entry.type] = counts[entry.type] + 1 end
   end

   local str = #list .. " entries (" .. counts[ENTRY.PROJECT] .. " projects, " .. counts[ENTRY.TEXT] .. " text notes"
   if counts[ENTRY.MISSING] > 0 then
      str = str .. ", " .. counts[ENTRY.MISSING] .. " missing"
   end
   return str .. ")"
end

-- Asks whether to load the autosave. Returns "load", "clean" or "cancel".
function AskLoadAutosave(list)
   local ret = reaper.MB("Found the autosaved setlist from your last session:\n" ..
      DescribeSetlistContents(list) .. "\n\n" ..
      "Yes: load it and check which projects need to be opened.\n" ..
      "No: start with a clean slate (only the currently open projects).\n" ..
      "      The old autosave is kept as a backup.\n" ..
      "Cancel: don't start the setlist.",
      "Setlist: load autosave?", 3)

   if ret == 6 then return "load" end
   if ret == 7 then return "clean" end
   return "cancel"
end

function SaveSetlistToFile()
   local parentDir = GetCurrProjParentDir()

   -- Show a save dialog to let user choose save location
   local extensionList = ""
   local retval, savePath = reaper.JS_Dialog_BrowseForSaveFile("Save Setlist", parentDir, "setlist.rsl",
      extensionList)

   if not retval or savePath == "" then return end

   local file = io.open(savePath, "w")
   if not file then
      reaper.MB("Failed to open file for writing:\n" .. savePath, "Save setlist to file", 0)
      return
   end

   local setlistStr = CreateSetlistString(setlist, "\n")

   file:write(setlistStr)

   file:close()
   reaper.MB("Setlist saved to\n" .. savePath, "Save setlist to file", 0)
end

function LoadSetlistFromFile()
   local parentDir = GetCurrProjParentDir()

   local extensionList = "ReaSetlist (.rsl)\0*.rsl;*.RSL\0Reaper Project List (.rpl)\0*.rpl;*.RPL\0\0"
   local retval, loadPath = reaper.JS_Dialog_BrowseForOpenFiles("Open Setlist", parentDir, "", extensionList, false)
   if not retval or loadPath == "" then return setlist end

   local file = io.open(loadPath, "r")
   if not file then
      reaper.MB("Failed to open file:\n" .. loadPath, "Load setlist from file", 0)
      return
   end

   local setlistStr = ""
   for line in file:lines() do
      line = line:match("^%s*(.-)%s*$") -- trim whitespace
      if line ~= "" then
         setlistStr = setlistStr .. line .. "\n"
      end
   end

   file:close()

   local fileList, invalidEntries = ParseSetlistString(setlistStr, "\n")

   log:debug("Checking if files exists in setlist directory")
   for i = 1, #fileList do
      if fileList[i].type ~= ENTRY.TEXT then -- text entries have no file behind them
         local path = CheckIfFileInRelativeDir(loadPath, fileList[i].path)
         fileList[i].path = SanitizePath(path)
         fileList[i].proj = GetProjFromPath(fileList[i].path)
      end
   end

   local list = ResolveConflictsWithOpenProj(fileList, false, true)

   if not next(invalidEntries) then
      reaper.MB("Loaded setlist from\n" .. loadPath, "Load setlist from file", 0)
   else
      HandleIInvalidSetlistStringEntries(fileList, invalidEntries, "from " .. loadPath)
   end
   return list
end

function HandleIInvalidSetlistStringEntries(validEntries, invalidEntries, context)
   if not context then context = "" end
   local msg = "Couldn't resolve the following entries while loading " .. context .. ":\n\n"
   local title = "Invalid entries found while parsing"
   if validEntries then
      if not next(validEntries) then
         msg = "Couldn't resolve ANY of following entries while loading " .. context .. ":\n\n"
         title = "Error loading from " .. context
      end
   end

   for _, v in ipairs(invalidEntries) do
      msg = msg .. v .. "\n"
   end

   reaper.MB(msg, title, 0)
end

----------------------------
--- DATA MANIPULATION
----------------------------

function CountEntryOccurrences(table, entry)
   local count = 0
   for _, occurence in ipairs(table) do
      if NormalizePath(occurence.path) == NormalizePath(entry.path) then
         count = count + 1
      end
   end
   return count
end

function BuildTabIdxToListIdxLookup(list)
   if not list then list = setlist end

   log:debug("Building Tab Index to List Index Lookup...")
   local tabIdx = 0
   tabIdxToListIdxLookup = {}

   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         --log:debug("  -Tab idx [" .. tabIdx .. "] corresponds to list idx [" .. i .. "]")

         tabIdxToListIdxLookup[tabIdx] = i
         tabIdx = tabIdx + 1
      end
   end
end

function BuildListIdxToTabIdxLookup(list)
   --log:debug("Building List Index to Tab Index Lookup...")

   if not list then list = setlist end

   local tabIdxCounter = 0
   listIdxToTabIdxLookup = {}

   for i, entry in ipairs(list) do
      --log:debug("  -List idx [" .. i .. "] corresponds to tab idx [" .. tabIdxCounter .. "]")
      listIdxToTabIdxLookup[i] = tabIdxCounter

      if entry.type == ENTRY.PROJECT then
         tabIdxCounter = tabIdxCounter + 1
      end
   end
end

function TabIdxToListIdx(tabIdx, list)
   log:debug("Getting List Index for Tab Index [" .. tabIdx .. "]")

   if not list then list = setlist end

   BuildTabIdxToListIdxLookup(list)

   if tabIdx < 0 then
      log:debug("  opt1 = 0")
      return 0
   elseif not tabIdxToListIdxLookup[tabIdx] then
      log:debug("  opt2 = " .. #list + 1)

      return #list + 1
   else
      log:debug("  opt3 = " .. tabIdxToListIdxLookup[tabIdx])
      return tabIdxToListIdxLookup[tabIdx]
   end
end

function ListIdxToTabIdx(listIdx, list)
   BuildListIdxToTabIdxLookup(list)

   if not list then list = setlist end
   --log:debug("Getting Tab Index for List Index [" .. listIdx .. "]")
   if listIdx < 0 then
      --log:debug("  opt1 = 0")
      return 0
   elseif listIdx > #list or not listIdxToTabIdxLookup[listIdx] then
      --log:debug("  opt2 = " .. openProjCount)
      return openProjCount
   else
      --log:debug("  opt3 = " .. listIdxToTabIdxLookup[listIdx])

      return listIdxToTabIdxLookup[listIdx]
   end
end

function GetProjEntriesInList(list)
   local projEntriesInList = {}
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         table.insert(projEntriesInList, #projEntriesInList + 1, entry)
      end
   end

   return projEntriesInList
end

function GetOpenProjectList()
   local i = 1

   local openProjList = {}

   while true do
      local proj, projPath = reaper.EnumProjects(i - 1)
      if not proj then break end

      local projName = "unknown"

      if projPath == "" then
         projName = "Unsaved Project"
         projPath = projName
      else -- extract project name from full path
         projName = ExtractProjNameFromPath(projPath)
      end

      table.insert(openProjList, {
         name = projName,
         path = projPath,
         proj = proj,
         listIdx = i,                  -- position in setlist, 1 based
         tabIdx = GetProjTabIdx(proj), -- project tab position if type is project
         type = ENTRY.PROJECT
      })
      i = i + 1
   end


   CalculateSetlistTime(openProjList)

   return openProjList, i
end

function CalculateSetlistTime(openProjectList)
   setlistTotalTime = 0
   for _, entry in ipairs(openProjectList) do
      setlistTotalTime = setlistTotalTime + GetProjectLengthFromMarker(entry.proj)
   end
end

function ReplaceProjEntry(list, entry)
   if entry.type == ENTRY.TEXT then return end

   local parentDir = GetCurrProjParentDir()

   local extensionList = "Reaper Project File (.rpp)\0*.rpp;*.RPP\0\0"
   local retval, loadPath = reaper.JS_Dialog_BrowseForOpenFiles("Replace Project Entry", parentDir, "",
      extensionList,
      false)
   if not retval or loadPath == "" then return end

   reaper.Main_OnCommand(CMD.NEW_PROJ_TAB, 0) --New project tab
   if FileExists(loadPath) then
      reaper.Main_openProject(loadPath)
   else
      reaper.MB("Selected file couldn't be loaded", "Error", 0)
   end

   local tabIdx = entry.tabIdx
   if not tabIdx then
      tabIdx = ListIdxToTabIdx(entry.listIdx)
   end

   MoveProjTabToIdx(reaper.EnumProjects(-1), tabIdx)

   if entry.proj then
      CloseProject(entry.proj)
   end

   PrintEntry(entry)

   list[entry.listIdx].type = ENTRY.PROJECT
   list[entry.listIdx].proj = reaper.EnumProjects(-1)
   list[entry.listIdx].path = loadPath
   list[entry.listIdx].name = ExtractProjNameFromPath(loadPath)
   list[entry.listIdx].tabIdx = ListIdxToTabIdx(entry.listIdx)

   PrintEntry(list[entry.listIdx])
end

-- Checks a setlist against currently open projects and resolves conflicts.
-- attempt (internal): which pass this is. If a pass ends with the list and the open tabs still disagreeing in
-- length, up to MAX_RESOLVE_ATTEMPTS passes are made automatically before the user is bothered.
function ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt)
   attempt = attempt or 1
   log:debug("Conflict resolver: searching for conflicts between list and open projects (pass %d)", attempt)

   if not next(list) then
      log:debug("  Setlist empty, building from open projects")
      return GetOpenProjectList()
   end

   local openProjList = GetOpenProjectList()

   -- check if any open projects are not in list or vice versa
   local missingInList = {}
   local missingInOpenProjects = {}
   local missingInListStr, missingInOpenProjStr, duplicateProjStr = "\n\n", "\n\n", "\n\n" --only used for message box


   -- build lookup table for projects in list
   local listPaths = {}
   local listDuplicateTracker = {}
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         if not listDuplicateTracker[entry.path] then
            listDuplicateTracker[entry.path] = 0
         else
            listDuplicateTracker[entry.path] = listDuplicateTracker[entry.path] + 1
         end

         listPaths[entry.path] = entry
      end
   end

   -- build lookup table for openProjects and check for projects not in list
   local openPaths = {}
   local duplicateProjects = {}
   local openDuplicateTracker = {}
   for _, entry in ipairs(openProjList) do
      if openPaths[entry.path] and listPaths[entry.path] then
         table.insert(duplicateProjects, entry)
         duplicateProjStr = duplicateProjStr .. entry.path .. " - (duplicate " .. #duplicateProjects .. ")\n"

         if not openDuplicateTracker[entry.path] then
            openDuplicateTracker[entry.path] = 1
         else
            openDuplicateTracker[entry.path] = openDuplicateTracker[entry.path] + 1
         end

         log:debug("Found duplicate no. %d for path %s", openDuplicateTracker[entry.path], entry.path)
      end

      openPaths[entry.path] = entry

      if entry.type == ENTRY.PROJECT and (not listPaths[entry.path]) then
         table.insert(missingInList, entry)
         missingInListStr = missingInListStr .. entry.path .. "\n"
      end
   end

   -- check for entries not in openProjects
   local nextIsDuplicate = {}
   for _, entry in ipairs(list) do
      if not openPaths[entry.path] and entry.type == ENTRY.PROJECT and not nextIsDuplicate[entry.path] then
         table.insert(missingInOpenProjects, entry)
         missingInOpenProjStr = missingInOpenProjStr .. entry.path .. "\n"
         nextIsDuplicate[entry.path] = true
      end
   end

   if IsDebug() then
      log:debug("  Open projects: ")
      for _, entry in ipairs(openProjList) do
         log:debug("    " .. entry.path)
      end

      log:debug("  Entries in list: ")
      for _, entry in ipairs(list) do
         log:debug("    " .. entry.path)
      end

      if next(missingInList) then
         log:debug("  Missing in list: ")
         for _, entry in ipairs(missingInList) do
            log:debug("    " .. entry.path)
         end
      end

      if next(missingInOpenProjects) then
         log:debug("  Missing in open projects: ")
         for _, entry in ipairs(missingInOpenProjects) do
            log:debug("    [" .. entry.listIdx .. "]: " .. entry.path)
         end
      end
   end


   -- handle projects that are open in multiple tabs
   if next(duplicateProjects) then
      local msg = "WARNING! The following projects are opened multiple times:" ..
          duplicateProjStr ..
          "\nAre you sure you want that? Clicking 'No' will close all duplicates."

      -- On a retry pass the user has already answered this: duplicates that are still open mean "keep them"
      local ret = attempt > 1 and 6 or reaper.MB(msg, "SETLIST - DUPLICATE PROJECTS FOUND", 3)

      log:debug("Processing duplicate open projects... ")


      if ret == 6 then
         for _, entry in ipairs(duplicateProjects) do
            local duplicateCount = CountEntryOccurrences(duplicateProjects, entry)
            local duplicatesInList = CountEntryOccurrences(list, entry) - 1

            if duplicatesInList == -1 then
               duplicatesInList = 0
            end

            log:debug("Inserting " ..
               duplicateCount - duplicatesInList ..
               " duplicates of " .. entry.name .. " into list. (If 0 that means all duplicates are already in list.)")

            for i = 1, duplicateCount - duplicatesInList do
               local newEntryIdx = TabIdxToListIdx(entry.tabIdx, list)
               log:debug("  Duplicate " .. i .. " (tabIdx [" .. entry.tabIdx .. "]) = at listIdx [" .. newEntryIdx .. "]")
               entry.listIdx = newEntryIdx
               table.insert(list, newEntryIdx, entry)
               list[newEntryIdx].tabIdx = ListIdxToTabIdx(newEntryIdx, list)
            end
         end
      elseif ret == 7 then
         for _, entry in ipairs(duplicateProjects) do
            reaper.SelectProjectInstance(entry.proj)
            reaper.Main_OnCommand(CMD.CLOSE_PROJ_TAB, 0) --Close current project tab
         end
      else
         terminate = true
         return list
      end

      -- remove unprocessed duplicate entries in list
      for _, entry in ipairs(duplicateProjects) do
         local duplicateCount = CountEntryOccurrences(duplicateProjects, entry)
         local duplicatesInList = CountEntryOccurrences(list, entry) - 1

         if entry.path == "Unsaved Project" then
            log:debug("DuplicateCount: " .. duplicateCount)
            log:debug("DuplicatesInList: " .. duplicatesInList)
         end
         if duplicatesInList > duplicateCount then
            for i = #list, 1, -1 do
               if list[i].path == entry.path and list[i].proj == nil then
                  table.remove(list, i)
                  listDuplicateTracker[entry.path] = listDuplicateTracker[entry.path] - 1
               end
            end
         end
      end

      UpdateTabAndListIdx()
   end

   -- find additional duplicate entries in list that are not opened and add them to table for next check
   log:debug("Processing duplicates in list that don't correspond to open projects")
   for path, duplicateNumber in pairs(listDuplicateTracker) do
      if duplicateNumber > 0 then
         if openDuplicateTracker[path] then
            duplicateNumber = duplicateNumber - openDuplicateTracker[path]
         end
         log:debug("  " .. path .. " has " .. duplicateNumber .. " unprocessed duplicates in list.")
      end
      local numFoundDuplicate = 0
      for j = #list, 1, -1 do
         if numFoundDuplicate >= duplicateNumber then break end

         local entry = list[j]
         if entry.path == path then
            table.insert(missingInOpenProjects, #missingInOpenProjects + 1, entry)
            numFoundDuplicate = numFoundDuplicate + 1

            missingInOpenProjStr = missingInOpenProjStr .. entry.path .. " - (duplicate #" .. numFoundDuplicate .. ")\n"
            log:debug("  Added to missing in open projects: ")
            log:debug("    [" .. entry.listIdx .. "]: " .. entry.path)
         end
      end
   end

   local openedFileCount = 0
   -- handle projects not open but in list
   if next(missingInOpenProjects) then
      local msg = "The following projects are in the loaded setlist but are not currently open:" ..
          missingInOpenProjStr ..
          "\nDo you want to open these projects? Clicking 'No' will remove them from the list."

      local ret
      if silent then
         ret = 7
      elseif isLoadFile or attempt > 1 then -- on a retry pass the user has already answered: don't ask again
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      log:debug("Processing projects in list but not open... ")
      if ret == 6 then
         -- Open projects on list
         for _, entry in ipairs(missingInOpenProjects) do
            if reaper.file_exists(entry.path) then
               reaper.Main_OnCommand(CMD.NEW_PROJ_TAB, 0) --New project tab
               reaper.Main_openProject(entry.path)
               openProjCount = openProjCount + 1

               entry.tabIdx = ListIdxToTabIdx(entry.listIdx, list)
               currentProj = reaper.EnumProjects(-1)

               list[entry.listIdx].proj = currentProj
               list[entry.listIdx].tabIdx = entry.tabIdx

               MoveProjTabToIdx(currentProj, entry.tabIdx)
               table.insert(openProjList, #openProjList + 1, entry)
            else
               local msg = "The following file was not found. Entry will be added but action needs to be taken:\n\n" ..
                   entry.path
               reaper.MB(msg, "File no found", 0)

               list[entry.listIdx].type = ENTRY.MISSING
            end
         end
         openedFileCount = #missingInOpenProjects
      elseif ret == 7 then
         local numRemoved = 0
         for _, entry in ipairs(missingInOpenProjects) do
            log:debug("  removing [" .. entry.listIdx .. "]: " .. entry.path)

            table.remove(list, entry.listIdx - numRemoved)
            numRemoved = numRemoved + 1
         end
      else
         terminate = true
         return list
      end
   end

   -- handle projects not in list but open
   if next(missingInList) then
      local msg = "The following projects are currently open but not in the loaded setlist:" ..
          missingInListStr ..
          "\nDo you want to add the projects to the setlist? Clicking 'No' will close them."

      local ret
      if silent or attempt > 1 then
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      log:debug("Processing open projects not in list...")
      PrintListPaths(list)


      if ret == 6 then -- Clicked Yes
         -- Add new projects to the list

         for _, entry in ipairs(missingInList) do
            entry.tabIdx = entry.tabIdx + openedFileCount
            local newEntryIdx = TabIdxToListIdx(entry.tabIdx, list)
            log:debug("  adding to list: [" .. newEntryIdx .. "] (tabIdx = " .. entry.tabIdx .. ") " .. entry.path)
            table.insert(list, newEntryIdx, entry)
         end
      elseif ret == 7 then -- Clicked No
         for _, entry in ipairs(missingInList) do
            if openProjCount == 1 then
               reaper.MB("Can't close last open project. Adding it to list.", "Warning", 0)
               table.insert(list, entry)
               break
            end


            reaper.SelectProjectInstance(entry.proj)
            local playState = reaper.GetPlayState()
            log:debug("  play state of the project to close: %d", playState)
            if playState & 4 == 4 then
               reaper.MB("Can't close project while it is recording. Adding it to list.", "Warning", 0)
               table.insert(list, entry)
               goto continue_close_loop
            elseif playState > 0 then
               ret = reaper.MB(
                  "Are you sure you want to close this project while it's playing?\n\nPressing 'No' will add it to the list",
                  "Warning", 4)
               if ret == 7 then
                  table.insert(list, entry)
                  goto continue_close_loop
               end
            end
            reaper.Main_OnCommand(CMD.CLOSE_PROJ_TAB, 0) --Close current project tab
            openProjCount = openProjCount - 1
         end
         ::continue_close_loop::
      else
         terminate = true
         return list
      end

      PrintListPaths(list)
   end


   local projEntriesInList = GetProjEntriesInList(list)
   openProjList = GetOpenProjectList()


   --Check for order mismatch
   log:debug("Checking for order mismatch between open projects and list...")
   log:debug("OpenProjList:")
   PrintListPaths(openProjList)
   log:debug("projEntriesInList:")
   PrintListPaths(projEntriesInList)

   local orderConflict = false
   if #openProjList ~= #projEntriesInList then
      if attempt < MAX_RESOLVE_ATTEMPTS then
         -- Earlier phases (opening/closing tabs, removing duplicates) can leave the counts out of step for one
         -- pass. The list is already partly fixed, so another pass normally finishes the job without any dialog.
         log:info("Length mismatch after pass " .. attempt .. " (" .. #openProjList .. " tabs vs " ..
            #projEntriesInList .. " entries). Running resolver again.")
         return ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt + 1)
      end

      local str = #openProjList > #projEntriesInList and "openProj > list" or "openProj < projEntriesInList"
      local ret = reaper.MB(
         "Something went wrong with conflict resolutions. Unequal lengths of openProjList and projEntriesInList: " ..
         str .. ": " .. #openProjList .. " vs " .. #projEntriesInList .. "\nDo you want to run ConclictResolver again?",
         "Error in conlict resolution", 2)

      if ret == 3 then
         terminate = true
         return {}
      elseif ret == 4 then
         return ResolveConflictsWithOpenProj(list, silent, isLoadFile, attempt + 1)
      else
         return {}
      end
   end

   for i = 1, #openProjList do
      if not openProjList[i] or not projEntriesInList[i] then
         reaper.MB("Error with resolving conflicts! Aborting", "Error", 0)
         setlist = GetOpenProjectList()
         return
      end
      local proj1 = openProjList[i].proj
      local proj2 = projEntriesInList[i].proj

      if proj1 ~= proj2 and openProjList[i].path ~= projEntriesInList[i].path then
         log:debug("  Mismatch at tab index " .. i - 1)
         orderConflict = true
         break
      end
   end

   if orderConflict then
      local msg =
      "Order mismach detected between setlist and open projects!\n\nSync setlist -> project tabs?\nClicking 'No' will sync project tabs -> setlist."

      local ret
      if silent or isLoadFile then
         ret = 6
      else
         ret = reaper.MB(msg, "Desync detected", 3)
      end

      if ret == 6 then
         ListOrderToProjTabs(list)
      elseif ret == 7 then
         list = UpdateListOrderFromOpenProjects(list)
      else
         terminate = true
         return list
      end
   end

   UpdateTabAndListIdx(list)

   return list
end

function MoveProjTabToIdx(targetProj, targetIdx, startIdx)
   if not targetProj then return end

   if not startIdx then
      startIdx = GetProjTabIdx(targetProj)
   end

   if not targetIdx or not startIdx then return end


   targetIdx = Clamp(targetIdx, 0, openProjCount)

   log:debug("Starting move for '" ..
      reaper.GetProjectName(targetProj) .. "' from tabIdx [" .. startIdx .. "] to [" .. targetIdx .. "]")

   local moveDirection = 0

   if targetIdx > startIdx then
      moveDirection = 1  -- Move right (down with drag&drop)
   elseif targetIdx < startIdx then
      moveDirection = -1 -- Move left (down with drag&drop)
   else
      log:debug("Aborted move: targetIdx == startIdx")
      return -- No movement
   end

   log:debug("  moveDirection: " .. moveDirection)

   local tabMoveCmdID = { [-1] = CMD.TAB_MOVE_LEFT, [1] = CMD.TAB_MOVE_RIGHT }

   log:debug("  Number of move commands: " .. (targetIdx - startIdx) * moveDirection)
   for i = 1, (targetIdx - startIdx) * moveDirection do
      log:debug("    Move " .. i)

      reaper.Main_OnCommandEx(tabMoveCmdID[moveDirection], 0, targetProj) --Project tabs: Move project tab left/right by one
   end
end

function ListOrderToProjTabs(list)
   log:debug("Starting project tab sort...")

   local projEntriesInSetlist = GetProjEntriesInList(list)

   for i, entry in ipairs(projEntriesInSetlist) do
      MoveProjTabToIdx(entry.proj, i - 1)
      entry.tabIdx = i - 1
   end
end

function UpdateTabAndListIdx(list)
   log:debug("Updating tab and list index fields from respective orders")
   if not list then list = setlist end

   local tabIdx = 0
   for i, entry in ipairs(list) do
      entry.listIdx = i

      if entry.type == ENTRY.PROJECT then
         entry.tabIdx = tabIdx
         tabIdx = tabIdx + 1
      end
   end
end

-- Call this after EVERY change to the setlist (insert, delete, rename, move...).
-- It refreshes the index fields and saves, so a crash never loses edits.
function CommitSetlist()
   UpdateTabAndListIdx()
   SaveAutosave()
end

-- All open project tabs, in tab order.
function GetOpenProjectPtrs()
   local ptrs = {}
   while true do
      local proj = reaper.EnumProjects(#ptrs)
      if not proj then break end
      ptrs[#ptrs + 1] = proj
   end
   return ptrs
end

-- True if the project entries of the list are in the same order as the given tabs.
function IsListOrderInSync(list, tabProjs)
   local n = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         if entry.proj ~= tabProjs[n] then return false end
      end
   end
   return true
end

-- Pure function: returns a NEW list where text/missing entries keep their positions and the
-- project entries are re-ordered to match tabProjs (tab order). Does not modify the input.
-- Returns (list, true) on success, or (originalList, false) if the entries can't be matched
-- unambiguously (count mismatch, entry without proj, same project twice).
function ReorderProjectsByTabOrder(list, tabProjs)
   local entryByProj = {}
   local projEntryCount = 0
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         if not entry.proj or entryByProj[entry.proj] then return list, false end
         entryByProj[entry.proj] = entry
         projEntryCount = projEntryCount + 1
      end
   end

   if projEntryCount ~= #tabProjs then return list, false end

   local orderedEntries = {}
   for i, proj in ipairs(tabProjs) do
      if not entryByProj[proj] then return list, false end
      orderedEntries[i] = entryByProj[proj]
   end

   local result = {}
   local n = 0
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         n = n + 1
         result[i] = orderedEntries[n]
      else
         result[i] = entry
      end
   end

   return result, true
end

-- Returns the list re-ordered to match the current tab order. Assign the result: list = Update...(list)
function UpdateListOrderFromOpenProjects(list, tabProjs)
   log:debug("Updating setlist from open projects...")
   local result, ok = ReorderProjectsByTabOrder(list, tabProjs or GetOpenProjectPtrs())
   if not ok then log:warn("could not match list entries to open tabs unambiguously, list left unchanged") end
   return result
end

--------------------------
----- GUI FUNCTIONS ------
--------------------------

-- Pure calculation: sizes for a zoom level, always derived from the base sizes in CFG.
-- Returns clampedLevel, entryTextSize, projLenTextSize, linePadding
function ComputeZoom(level)
   level = Clamp(level, CFG.minZoomLevel, CFG.maxZoomLevel)
   return level,
       CFG.entryTextSize + level,
       CFG.projLenTextSize + level / 2,
       CFG.linePadding + level * 2
end

function ApplyZoom(level)
   gui.zoomLevel, gui.entryTextSize, gui.projLenTextSize, gui.linePadding = ComputeZoom(level)

   Theme.set_font(gui.entryTextSize)
   gui.lineHeight = gfx.texth + gui.linePadding
   log:debug("Zoom level is now " .. gui.zoomLevel)
end

-- Zoom one step in (+1) or out (-1). Alt resets the zoom.
-- Holding a zoom button repeats this (Widgets.button repeat_every), so there is no throttling here.
function ZoomStep(step)
   if win.mouse.alt then ApplyZoom(0) else ApplyZoom(gui.zoomLevel + step) end
end

function FindEntryUnderMouseCursor(findAtLastClickPos)
   if not findAtLastClickPos then
      findAtLastClickPos = false
   end

   local mouseIsOverList = gfx.mouse_y < gui.listH + gui.titleHeight - gui.dragThreshold and
       gfx.mouse_y > gui.titleHeight and gfx.mouse_x < gfx.w - gui.scrollW and gfx.mouse_x > gui.leftBorder

   if not mouseIsOverList then
      return nil, nil
   end

   local entryUnderMouse = nil
   local idxUnderMouse = nil
   for i, _ in ipairs(setlist) do
      local yStart = gui.titleHeight + (i - 1) * gui.lineHeight
      local yEnd = yStart + gui.lineHeight

      if yEnd > gui.listH + gui.titleHeight then return nil, nil end -- only return entry if fully visible.

      local mouseIsOverEntry

      if findAtLastClickPos then
         mouseIsOverEntry = IsPointInRect(0, yStart, gfx.w - gui.scrollW, gui.lineHeight,
            gui.lastClickDownPos.x, gui.lastClickDownPos.y)
      else
         mouseIsOverEntry = IsMouseInRect(0, yStart, gfx.w - gui.scrollW, gui.lineHeight)
      end

      if mouseIsOverEntry then
         idxUnderMouse = i + gui.scrollOffset
         entryUnderMouse = setlist[idxUnderMouse]
         break
      end
   end

   if not entryUnderMouse or idxUnderMouse > #setlist then
      return nil, nil
   end

   return entryUnderMouse, idxUnderMouse
end

-- Pure function. Returns the scroll offset (0-based, number of entries scrolled out at the top) that puts the
-- previous PROJECT entry in the top row, so the current project and every text entry between the two stay visible.
-- If there is no previous project the list starts at the top. Returns nil if currentListIdx isn't in the list.
function GetFollowScrollOffset(list, currentListIdx, maxScroll)
   if not currentListIdx or currentListIdx < 1 or currentListIdx > #list then return nil end

   local offset = 0
   for i = currentListIdx - 1, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         offset = i - 1
         break
      end
   end

   return Clamp(offset, 0, maxScroll or offset)
end

-- Pure function. How far the list may scroll. Normally that's "last entry at the bottom", but to let the
-- previous project of the LAST project reach the top row the range is extended (the rows below stay empty).
-- A list that fits completely never scrolls.
function GetMaxScroll(list, numVisibleEntries)
   local naturalMax = math.max(0, #list - numVisibleEntries)
   if naturalMax == 0 then return 0 end

   for i = #list, 1, -1 do
      if list[i].type == ENTRY.PROJECT then
         return math.max(naturalMax, GetFollowScrollOffset(list, i) or 0) -- no maxScroll given: unclamped
      end
   end
   return naturalMax
end

-- Pure function. The range for manual scrolling (wheel, scrollbar, dragging): the last entry may reach the
-- bottom of the window, but there is never an empty row below it.
function GetManualMaxScroll(list, numVisibleEntries)
   return math.max(0, #list - numVisibleEntries)
end

-- Pure function. Scrolls by delta rows (positive = down) in the manual range.
-- Smooth after a follow-scroll: if the view currently shows empty rows beyond the manual range, scrolling up
-- moves it from where it is (it does not snap back first), and scrolling down simply stays where it is.
function ApplyManualScroll(offset, delta, manualMax)
   local upperLimit = math.max(manualMax, offset)
   return Clamp(offset + delta, 0, upperLimit)
end

-- Pure function. Should a change of the current project scroll the list? Always, except when the project was
-- selected by clicking it in the list while in edit mode: the list must not move away from where you work.
function ShouldFollowProjectChange(mode, changedFromList)
   return not (mode == MODE.EDIT and changedFromList)
end

-- Pure function. Editing is locked in show mode, but only if the mode switch exists (otherwise the setlist
-- could never be edited).
function IsEditLocked(mode, modeSwitchActive)
   return modeSwitchActive == true and mode == MODE.SHOW
end

function IsEditingLocked()
   return IsEditLocked(gui.mode, Mode ~= nil)
end

-- Pure function. List index of the first project entry for proj, or nil.
function FindProjListIdx(list, proj)
   if not proj then return nil end
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT and entry.proj == proj then return i end
   end
   return nil
end

-- Pure function. Where the entry at listIdx is relative to the visible rows:
-- -1 = scrolled out at the top, 1 = below the visible rows, 0 = visible (or listIdx unknown).
function GetOffscreenDirection(listIdx, scrollOffset, numVisible)
   if not listIdx then return 0 end
   if listIdx <= scrollOffset then return -1 end
   if listIdx > scrollOffset + numVisible then return 1 end
   return 0
end

-- Pure function. One animation step of the drawn scroll position towards the target (exponential ease-out).
-- No current value or timeConstant <= 0 jumps straight to the target. Snaps once closer than 0.01 rows.
function StepSmoothScroll(current, target, dt, timeConstant)
   if current == nil or not timeConstant or timeConstant <= 0 then return target end
   if dt <= 0 then return current end

   local new = current + (target - current) * (1 - math.exp(-dt / timeConstant))
   if math.abs(target - new) < 0.01 then return target end
   return new
end

-- Pure function. A gfx.showmenu item, greyed out (not selectable) when disabled.
function MenuItem(label, enabled)
   return (enabled and "" or "#") .. label
end

-- Pure function. The (greyed) header line of a context menu, with a note while editing is locked.
function MenuTitle(text, locked)
   return "#" .. text .. (locked and "  (locked in show mode)" or "")
end

-- Pure function. Maps a value of the shared Mode library to MODE. Anything unknown gives nil.
-- lib: the library's constants ({ SHOW = ..., EDIT = ... }). Defaults to "show" / "edit".
function ToListMode(libMode, lib)
   lib = lib or { SHOW = "show", EDIT = "edit" }
   if libMode ~= nil and libMode == lib.SHOW then return MODE.SHOW end
   if libMode ~= nil and libMode == lib.EDIT then return MODE.EDIT end
   return nil
end

-- Applies a list mode. Switching to show mode jumps to the current project right away.
-- Returns true if the mode changed.
function SetListMode(newMode)
   if not newMode or newMode == gui.mode then return false end

   local oldMode = gui.mode
   gui.mode = newMode
   if newMode == MODE.SHOW then
      gui.followPending = true
   end
   log:info("list mode: %s -> %s", tostring(oldMode), newMode)
   return true
end

-- Callback for Mode.watch(): runs once at startup, then on every change of the shared mode.
function OnSharedModeChanged(newLibMode, oldLibMode)
   local listMode = ToListMode(newLibMode, Mode)
   if not listMode then
      log:warn("unknown shared mode '%s', keeping %s", tostring(newLibMode), tostring(gui.mode))
      return
   end
   SetListMode(listMode)
end

function InsertTextEntry()
   local ret, input = reaper.GetUserInputs("Insert Text Note", 1, "Enter label:", "")
   if ret and input ~= "" then
      table.insert(setlist, { name = input, path = input, type = ENTRY.TEXT })
      CommitSetlist()
   end
end

function LoadSetlistButtonAction()
   setlist = LoadSetlistFromFile() or setlist
   if not terminate then CommitSetlist() end
   gui.followPending = true
end

function HandleControlPanel()
   local pad = gui.entryIndent
   local bW, bH = gui.buttonW, gui.buttonH
   local y = gfx.h - bH - gui.titleHeight / 2
   local normal = { size = gui.buttonFontSize }
   local locked = { size = gui.buttonFontSize, disabled = IsEditingLocked() } -- show mode

   if Widgets.button(win, "Save Setlist", pad, y, bW, bH, normal) then SaveSetlistToFile() end
   if Widgets.button(win, "Load Setlist", pad * 2 + bW, y, bW, bH, locked) then LoadSetlistButtonAction() end
   if Widgets.button(win, "Insert Text", pad * 3 + bW * 2, y, bW, bH, locked) then InsertTextEntry() end

   -- Zoom buttons (right aligned). They repeat while held, Alt+click resets the zoom.
   local zW, zH = bW / 5, bH * 0.8
   local zY = gfx.h - zH - gui.titleHeight / 2
   local zoom = { size = gui.buttonFontSize * 1.2, repeat_every = gui.zoomDelay }

   if Widgets.button(win, "-", gfx.w - pad - zW, zY, zW, zH, zoom) then ZoomStep(-1) end
   if Widgets.button(win, "+", gfx.w - pad - pad / 2 - zW * 2, zY, zW, zH, zoom) then ZoomStep(1) end
end

function HandleDraggingEntry()
   if #setlist < 2 then return end

   if IsEditingLocked() then
      if gui.draggingEntry then -- the mode switched to show in the middle of a drag: cancel it
         gui.draggingEntry = false
         gui.dropIdx = nil
         log:debug("Drag cancelled: editing is locked in show mode")
      end
      return
   end

   if gui.leftClick then
      gui.dragThreshReached = math.abs(gfx.mouse_y - gui.lastClickDownPos.y) > gui.dragThreshold
   end

   if not gui.draggingEntry and gui.leftClick and not gui.draggingScroll and not gui.pressOnIndicator
       and gui.dragThreshReached then
      local entryUnderMouse, idxUnderMouse = FindEntryUnderMouseCursor(true)

      if not entryUnderMouse then return end

      gui.dragEntryListIdx = idxUnderMouse
      gui.dragStartY = gfx.mouse_y
      gui.draggingEntry = true
      log:debug("Dragging started for: %s", setlist[gui.dragEntryListIdx].name)
   elseif gui.draggingEntry and gui.dragThreshReached then
      gui.dragDirection = 1
      if gfx.mouse_y < gui.dragStartY then
         gui.dragDirection = -1
      end

      -- Auto-scroll if mouse is near top or bottom
      if gfx.mouse_y < gui.titleHeight - gui.dragScrollMargin or gfx.mouse_y > gui.listH + gui.titleHeight + gui.dragScrollMargin then
         gui.autoscrolling = true
         gui.fractionalScrollOffset = gui.fractionalScrollOffset + gui.dragScrollSpeed

         if math.abs(gui.fractionalScrollOffset) >= 1 then
            gui.scrollOffset = ApplyManualScroll(gui.scrollOffset,
               math.floor(gui.fractionalScrollOffset * gui.dragDirection), gui.maxScroll)
            gui.fractionalScrollOffset = 0

            log:debug("  drag autoscroll: scrollOffset %s", gui.scrollOffset)
         end
      else
         gui.autoscrolling = false
         gui.fractionalScrollOffset = 0
      end

      local entryUnderMouse, idxUnderMouse = FindEntryUnderMouseCursor()

      if not entryUnderMouse or idxUnderMouse == gui.dragEntryListIdx then
         gui.dropIdx = nil
         return
      end

      if math.abs(gfx.mouse_y - gui.dragStartY) > gui.dragThreshold then
         -- Calculate drop index based on mouse position
         local newDropIdx = math.floor((gfx.mouse_y + (gui.lineHeight / 3 * gui.dragDirection) - gui.titleHeight) /
                gui.lineHeight) +
             1 -- leave dropzone of 1/3 of the line height. It's not working perfectly but dragging feels quite nice :)

         newDropIdx = Clamp(newDropIdx + gui.scrollOffset - gui.dragDirection, 1, #setlist)

         gui.dropIdx = newDropIdx
      end

      HandleDroppingEntry()
   end
end

function HandleDroppingEntry()
   if not gui.draggingEntry or gui.leftClick then
      PostDragCleanup()
      return
   end

   gui.draggingEntry = false

   if not gui.dropIdx then return end

   log:debug("  Dropped [" .. gui.dragEntryListIdx .. "] at listIdx [" .. gui.dropIdx .. "]")

   -- Perform the swap only if the target index has changed
   if gui.dropIdx == gui.dragEntryListIdx then return end

   local dragEntry = setlist[gui.dragEntryListIdx]

   if gui.dragDirection == 1 then
      gui.dropIdx = gui.dropIdx + 1
   end

   if dragEntry.type == ENTRY.TEXT and IsModifierDown(MOD.CTRL) then --ctrl is held
      log:debug("Duplicating Text Item: " .. dragEntry.name)
      local duplicateText = CopyTable(dragEntry)
      duplicateText.listIdx = gui.dropIdx
      table.insert(setlist, gui.dropIdx, duplicateText)
      log:debug("Inserted duplicate at idx " .. duplicateText.listIdx)
      goto finalizeDrop
   elseif dragEntry.type == ENTRY.PROJECT then
      local newTabIdx = ListIdxToTabIdx(gui.dropIdx)
      MoveProjTabToIdx(dragEntry.proj, newTabIdx)
   end

   if gui.dragDirection == 1 then
      table.insert(setlist, gui.dropIdx, dragEntry)
      table.remove(setlist, gui.dragEntryListIdx)
   else
      table.remove(setlist, gui.dragEntryListIdx)
      table.insert(setlist, gui.dropIdx, dragEntry)
   end

   ::finalizeDrop::
   CommitSetlist()

   PostDragCleanup()
end

function PostDragCleanup()
   if not gui.leftClick then
      gui.draggingEntry = false
      gui.dragStartY = nil
      gui.dropIdx = nil
      gui.dragDirection = nil
      gui.dragThreshReached = nil
   end
end

function RenameTextEntry(entry)
   local ret, newName = reaper.GetUserInputs("Rename Text Note", 1, "Enter new label:", entry.name or "")
   if ret and newName ~= "" then
      entry.name = newName
      CommitSetlist()
   end
end

function ColorTextEntry(entry)
   local retval, color = reaper.GR_SelectColor(reaper.GetMainHwnd())
   if retval ~= 0 then -- 0 means the dialog was cancelled
      local r, g, b = reaper.ColorFromNative(color)
      r, g, b = RgbaIntToFloat(r, g, b)
      log:debug("Text Highlight set to color: " .. r .. "," .. g .. "," .. b)
      entry.highlight = { r, g, b, 0.4 }
      CommitSetlist()
   end
end

function QueueProject(entry)
   local nextProjTabIdx = GetProjTabIdx(currentProj) + 1 -- the tab that is going to play next
   MoveProjTabToIdx(entry.proj, nextProjTabIdx)
   setlist = UpdateListOrderFromOpenProjects(setlist)
   CommitSetlist()
end

function ShowTextEntryMenu(entry, idx)
   local locked = IsEditingLocked()
   gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
   local choice = gfx.showmenu(MenuTitle("-- " .. entry.name, locked) .. "||" ..
      MenuItem("Rename", not locked) .. "|" .. MenuItem("Color Entry", not locked) .. "|" ..
      MenuItem("Duplicate", not locked) .. "|" .. MenuItem("Delete Text Entry", not locked))
   if locked then return end -- every item is greyed out anyway

   if choice == 2 then
      RenameTextEntry(entry)
   elseif choice == 3 then
      ColorTextEntry(entry)
   elseif choice == 4 then
      log:debug("Duplicating Text Item: " .. entry.name)
      table.insert(setlist, idx + 1, CopyTable(entry))
      CommitSetlist()
   elseif choice == 5 then
      table.remove(setlist, idx)
      CommitSetlist()
   end
end

function ShowProjectEntryMenu(entry)
   local locked = IsEditingLocked()
   gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
   local choice = gfx.showmenu(MenuTitle(tostring(entry.tabIdx or "?") .. ". " .. entry.name, locked) ..
      "||Queue Project||" .. MenuItem("Replace Project", not locked) .. "|" .. MenuItem("Close Project", not locked))
   if locked and choice ~= 2 then return end -- Queue Project stays available during the show

   if choice == 2 then
      QueueProject(entry)
   elseif choice == 3 then
      ReplaceProjEntry(setlist, entry)
      CommitSetlist()
   elseif choice == 4 then
      CloseProject(entry.proj)
   end
end

function ShowMissingEntryMenu(entry, idx)
   local locked = IsEditingLocked()
   gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
   local choice = gfx.showmenu(MenuTitle("MISSING", locked) .. "||" ..
      MenuItem("Find Project", not locked) .. "|" .. MenuItem("Remove Project", not locked))
   if locked then return end

   if choice == 2 then
      ReplaceProjEntry(setlist, entry)
      CommitSetlist()
   elseif choice == 3 then
      log:debug("Removing [" .. idx .. "]: " .. entry.path)
      table.remove(setlist, idx)
      CommitSetlist()
   end
end

function HandleEntryClick()
   if (gui.leftClickHandled and gui.rightClickHandled) or gui.draggingEntry or gui.draggingScroll then
      return
   end

   local entry, idx = FindEntryUnderMouseCursor(true)
   if not entry then
      -- Right-click anywhere outside the entries: the window menu (docking, default position)
      if gui.rightClick and not gui.rightClickHandled then
         gui.rightClickHandled = true
         win:show_context_menu()
      end
      return
   end

   if gui.leftClick and not gui.leftClickHandled then
      local now = reaper.time_precise()
      local isDouble = gui.lastClickIdx == idx and (now - gui.lastClickTime) <= gui.doubleClickThreshold
      gui.doubleClick = isDouble
      gui.lastClickTime = now
      gui.lastClickIdx = idx

      log:debug("Handling left click on entry at listIdx [" .. idx .. "]" .. (isDouble and " (double)" or ""))

      if entry.type == ENTRY.TEXT then
         if IsEditingLocked() then
            -- show mode: no renaming or deleting
         elseif isDouble then
            RenameTextEntry(entry)
         elseif IsModifierDown(MOD.ALT) then
            log:debug("Deleting Text Entry: " .. entry.name)
            table.remove(setlist, idx)
            CommitSetlist()
         end
      elseif entry.type == ENTRY.PROJECT then
         if entry.proj ~= currentProj then
            gui.listClickTarget = entry.proj -- lets Main tell this switch apart from one made in REAPER
         end
         reaper.SelectProjectInstance(entry.proj)
      end

      gui.leftClickHandled = true
   end

   if gui.rightClick and not gui.rightClickHandled then
      log:debug("Handling right click on entry " .. entry.name .. " at index " .. idx)

      if entry.type == ENTRY.TEXT then
         ShowTextEntryMenu(entry, idx)
      elseif entry.type == ENTRY.PROJECT then
         ShowProjectEntryMenu(entry)
      elseif entry.type == ENTRY.MISSING then
         ShowMissingEntryMenu(entry, idx)
      end

      gui.rightClickHandled = true
   end
end

function HandleMouseScroll()
   local wheel = win.mouse.wheel -- the Window reads (and resets) gfx.mouse_wheel once per frame
   if wheel ~= 0 and win.mouse.ctrl then
      ApplyZoom(gui.zoomLevel + (wheel > 0 and 1 or -1))
   elseif wheel ~= 0 then
      -- one notch (120) = one row, the same in both directions
      local steps = math.max(1, math.floor(math.abs(wheel) / 100 + 0.5))
      local delta = wheel > 0 and -steps or steps
      gui.scrollOffset = ApplyManualScroll(gui.scrollOffset, delta, gui.maxScroll)
   end
   -- Hard limit only (e.g. the list got shorter). Rows beyond gui.maxScroll are allowed here on purpose:
   -- they are what the follow-scroll leaves behind.
   gui.scrollOffset = Clamp(gui.scrollOffset, 0, gui.followMaxScroll)
end

function HandleScrollbarClick()
   local mouseOnScrollbar = IsMouseInRect(gfx.w - gui.scrollW, gui.scrollY, gui.scrollW, gui.scrollH)

   if gui.leftClick and mouseOnScrollbar and not gui.draggingEntry and not gui.draggingScroll then
      gui.draggingScroll = true
      gui.scrollBarGrabStart = gfx.mouse_y
      gui.scrollBarGrabOffset = gfx.mouse_y - gui.scrollY
   elseif not gui.leftClick then
      gui.draggingScroll = false
      gui.scrollBarGrabStart = 0
      gui.scrollBarGrabOffset = 0
   end

   if gui.draggingScroll and gui.scrollBarGrabStart ~= gfx.mouse_y then
      local scrollTrackHeight = gui.listH + gui.titleHeight
      local emptyScrollH = scrollTrackHeight - gui.scrollH
      local newScrollY = Clamp(gfx.mouse_y - gui.scrollBarGrabOffset, 0, emptyScrollH)

      gui.scrollOffset = math.floor((newScrollY / emptyScrollH) * gui.maxScroll)
      gui.scrollOffset = Clamp(gui.scrollOffset, 0, gui.maxScroll)
      log:debug("Scrolling to scrollOffset: " .. gui.scrollOffset)
   end
end

-- Moves the drawn scroll position towards gui.scrollOffset. snap = true ends any animation at once
-- (used whenever the user scrolls, clicks or drags, so what is drawn is always what the mouse hits).
function UpdateDisplayOffset(snap)
   local now = reaper.time_precise()
   local dt = math.min(now - (gui.lastAnimTime or now), 0.1) -- a stalled frame doesn't skip the animation
   gui.lastAnimTime = now

   if snap then
      gui.displayOffset = gui.scrollOffset
   else
      gui.displayOffset = StepSmoothScroll(gui.displayOffset, gui.scrollOffset, dt, gui.smoothScrollTime)
   end
end

-- Draws an arrow at the top or bottom edge of the list when the current project is out of view.
-- Clicking it jumps back to the current project (in both modes).
function HandleOffscreenIndicator()
   if gui.draggingEntry then return end

   local dir = GetOffscreenDirection(FindProjListIdx(setlist, currentProj), gui.scrollOffset, gui.numVisibleEntries)
   if dir == 0 then return end

   local w, h = gui.offscreenIndicatorW, gui.offscreenIndicatorH
   local x = math.floor((gfx.w - gui.scrollW - w) / 2)
   local listBottom = gui.titleHeight + gui.numVisibleEntries * gui.lineHeight
   local y = dir < 0 and gui.titleHeight + 2 or listBottom - h - 2

   gfx.set(table.unpack(gui.offscreenIndicatorColor))
   gfx.rect(x, y, w, h, true)

   local cx, triW, triH = x + w / 2, h * 0.9, h * 0.5
   local top = y + (h - triH) / 2
   gfx.set(0, 0, 0, 0.8)
   if dir < 0 then
      gfx.triangle(cx - triW / 2, top + triH, cx + triW / 2, top + triH, cx, top)
   else
      gfx.triangle(cx - triW / 2, top, cx + triW / 2, top, cx, top + triH)
   end

   local pressedNow = gui.leftClick and not gui.prevLeftClick
   if pressedNow and not gui.leftClickHandled
       and IsPointInRect(x, y, w, h, gui.lastClickDownPos.x, gui.lastClickDownPos.y) then
      gui.leftClickHandled = true -- the entry under the arrow is not selected
      gui.pressOnIndicator = true -- and not dragged
      gui.followPending = true    -- the jump happens when the mouse is released
      log:debug("Off-screen arrow clicked: jumping to the current project")
   end
end

function DrawScrollbar()
   local setlistLenght = #setlist
   if setlistLenght <= gui.numVisibleEntries then return end

   local scrollTrackHeight = gui.listH + gui.titleHeight
   gui.scrollH = scrollTrackHeight * (gui.numVisibleEntries / setlistLenght)
   local offset = gui.displayOffset or gui.scrollOffset
   gui.scrollY = Clamp(offset / math.max(gui.maxScroll, 1), 0, 1) * (scrollTrackHeight - gui.scrollH)

   -- Scroll Track
   Theme.set("button")
   gfx.rect(gfx.w - gui.scrollW, 0, gui.scrollW, scrollTrackHeight)

   -- Scroll Thumb
   Theme.set("muted")
   gfx.rect(gfx.w - gui.scrollW + 2, gui.scrollY, gui.scrollW - 4, gui.scrollH)

   return gui.scrollY, gui.scrollH
end

function DrawListEntry(y, entry)
   if not entry or not y then return end
   local highlight = entry.highlight

   if gui.draggingEntry and entry.listIdx == gui.dragEntryListIdx and gui.dragThreshReached then
      highlight = gui.dragHighlight
   elseif entry.proj == currentProj and not gui.currProjDrawn then
      highlight = gui.activeProjHighlight
      gui.currProjDrawn = true
      gui.isNextProj = true
   elseif gui.isNextProj and entry.type == ENTRY.PROJECT then
      highlight = gui.nextProjHighlight
      gui.isNextProj = false
   end

   highlight = highlight or gui.entryHighlights[entry.type]

   if highlight then
      gfx.set(table.unpack(highlight))
      gfx.rect(gui.leftBorder, y + 2, gfx.w - gui.scrollW, gui.lineHeight - 4)
   end

   Theme.set("line")
   gfx.line(gui.leftBorder, y + gui.lineHeight, gfx.w - gui.scrollW, y + gui.lineHeight - 1)

   -------------------
   -- draw entry text
   local textAlpha -- text uses the theme's text color, nil = not drawn
   local entryStr
   gfx.x = gui.leftBorder + gui.entryIndent
   Theme.set_font(gui.entryTextSize)
   if entry.type == ENTRY.PROJECT then
      textAlpha = 1
      local displayIdx = tostring(displayTabIdx and entry.tabIdx or entry.listIdx)
      displayIdx = PadNumberStringWithZeroes(displayIdx, math.floor(math.log(openProjCount, 10) + 1)) .. ". "

      --draw selected project indicator
      if entry.proj == currentProj then
         Theme.set("text")
         local radius = gui.leftBorder / 2
         gfx.circle(gui.leftBorder, y + (gui.lineHeight - radius * 2) / 2 + 1, radius, true, true)
      end


      local playState = reaper.GetPlayStateEx(entry.proj)
      if playState > 0 then
         -- draw pos indicator
         local projLen = GetProjectLengthFromMarker(entry.proj)

         local playPos = reaper.GetPlayPositionEx(entry.proj)
         local r, g, b, a = table.unpack(gui.playPosColor)
         gfx.set(r, g, b, a)

         local x = (gfx.w - gui.scrollW - gui.entryIndent) * playPos / projLen + 5
         gfx.rect(x, y, gui.leftBorder, gui.lineHeight)

         a = 0.2
         gfx.set(r, g, b, a)

         gfx.rect(gui.leftBorder, y, x, gui.lineHeight)


         -- draw project playstate indicator
         local displayIdxWidth = gfx.measurestr(displayIdx)

         if playState == 1 then
            gfx.x = gfx.x + displayIdxWidth
            displayIdx = ""
            gfx.set(table.unpack(gui.transportColors[playState]))

            local triangleH = gui.lineHeight * 0.5
            local triangleW = Clamp(triangleH * 0.8, 0, displayIdxWidth * 0.8)

            local iconLRPadding = (displayIdxWidth - triangleW) / 2 - 5
            local iconTopPadding = (gui.lineHeight - triangleH) / 2
            gfx.triangle(
               gui.leftBorder + gui.entryIndent + triangleW, y + gui.lineHeight / 2,
               gui.leftBorder + gui.entryIndent + iconLRPadding, y + iconTopPadding,
               gui.leftBorder + gui.entryIndent + iconLRPadding, y + iconTopPadding + triangleH)
         elseif playState == 5 then
            gfx.x = gfx.x + displayIdxWidth
            displayIdx = ""

            local iconRadius = Clamp(gui.lineHeight * 0.5 / 2 - 2, 0, displayIdxWidth / 2 * 0.8)

            gfx.set(table.unpack(gui.transportColors[playState]))
            gfx.circle(gui.leftBorder + gui.entryIndent + iconRadius, y + gui.lineHeight / 2, iconRadius, true,
               true)
         end
      end
      entryStr = displayIdx .. (entry.name or "")
   elseif entry.type == ENTRY.TEXT then
      textAlpha = gui.textEntryAlpha
      entryStr = "--  " .. (entry.name or "")
   elseif entry.type == ENTRY.MISSING then
      textAlpha = gui.textEntryAlpha
      entryStr = "?  " .. (entry.name or "")
   end


   local _, strH = gfx.measurestr(entryStr)
   gfx.y = y + (gui.lineHeight - strH) / 2

   if textAlpha and entryStr then
      Theme.set("text", textAlpha)
      gfx.drawstr(entryStr)
   end

   ----------------------
   --Project Length Stuff
   if entry.type == ENTRY.PROJECT then
      if entry.name:find("_.*ROUTING") then return end

      -- proj length
      local projLen = GetProjectLengthFromMarker(entry.proj)

      local projLenStr = FormatTimeMMSS(projLen)

      Theme.set_font(gui.projLenTextSize)
      local strW, strH = gfx.measurestr(projLenStr)
      gfx.x = gfx.w - gui.scrollW - strW - gui.entryIndent
      gfx.y = y + (gui.lineHeight - strH) / 2

      gfx.drawstr(projLenStr)
   end
end

function DisplaySetlist()
   gfx.clear = Theme.clear_color()

   -- Draw Entries. While a follow-scroll animates, gui.displayOffset is fractional: the rows are drawn shifted
   -- by the fraction and one extra row is drawn. The backgrounds painted below hide what sticks out.
   local offset = gui.displayOffset or gui.scrollOffset
   local firstIdx = math.floor(offset)
   local frac = offset - firstIdx
   local rows = gui.numVisibleEntries + (frac > 0 and 1 or 0)

   for i = 1, rows do
      local idx = i + firstIdx
      if idx > #setlist then break end
      if idx >= 1 then
         DrawListEntry(gui.titleHeight + (i - 1 - frac) * gui.lineHeight, setlist[idx])
      end
   end

   gui.isNextProj = false
   gui.currProjDrawn = false

   Theme.set("background")
   gfx.rect(0, 0, gfx.w, gui.titleHeight)
   gfx.rect(0, gfx.h - gui.ctrlPanelSize, gfx.w, gui.ctrlPanelSize)

   -- Draw Title: the shared SiSt-Live header (teal, fixed size: gui.titleHeight - 12 = Widgets.HEADER_H)
   Widgets.header(TITLE_TEXT, 3, 3, gfx.w - 6, gui.titleHeight - 12, "show")

   -- Draw Total Setlist Time

   local time = FormatTimeMMSS(setlistTotalTime)
   local str = "Total Setlist Time: " .. time

   Theme.set_font(gui.projLenTextSize - gui.zoomLevel / 2)

   local strW, strH = gfx.measurestr(str)

   gfx.x = gfx.w - gui.entryIndent - strW
   gfx.y = gfx.h - gui.ctrlPanelSize + gui.entryIndent * 0.7
   gfx.drawstr(str)

   -- draw ctrlPanel divider
   Theme.set("text", 0.6)
   gfx.rect(0, gfx.h - gui.ctrlPanelSize, gfx.w, gui.dropIndicatorThickness - 2)

   -- Draw a line indicating where the project would be dropped if dragging

   if gui.draggingEntry and gui.dropIdx and gui.dragDirection then
      local isDragFarEnough = gui.dropIdx ~= gui.dragEntryListIdx and
          (gui.dropIdx > gui.dragEntryListIdx or gui.dropIdx < gui.dragEntryListIdx)

      if isDragFarEnough then
         local dropYstart

         if gui.dropIdx == 1 then
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset - 1) * gui.lineHeight
         elseif gui.dragDirection == 1 then
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset) * gui.lineHeight
         else
            dropYstart = gui.titleHeight + (gui.dropIdx - gui.scrollOffset - 1) * gui.lineHeight
         end

         -- Draw drop indicator line as a rectangle
         Theme.set("text", 0.6)
         gfx.rect(5, dropYstart - 2, gfx.w - 10, gui.dropIndicatorThickness)
      end
   end
end

-- Window callbacks (see lib/Gui/Window.lua). Zoom and scroll position are saved with the window.
function OnWindowOpen(w)
   gui.zoomLevel = w.state.zoomLevel or 0
   gui.scrollOffset = w.state.scrollOffset or 0
   ApplyZoom(gui.zoomLevel) -- needs the open window (font metrics)
   gui.minHeight = gui.ctrlPanelSize + gui.titleHeight + gui.lineHeight * 3
   gui.minWidth = gui.buttonW * 3 + gui.entryIndent + 5
end

function OnWindowClose(w)
   w.state.zoomLevel = gui.zoomLevel
   w.state.scrollOffset = gui.scrollOffset
   if not terminate then SaveAutosave() end
end

--------------------------
------- SELF TESTS -------
--------------------------
-- Hold Alt while starting the script to run these. Results are printed to the REAPER console.
-- Rule: tests must never write ExtState or touch project tabs, because they run in the user's live session.

local selfTests = {}

local function DefineTest(name, fn)
   selfTests[#selfTests + 1] = { name = name, fn = fn }
end

local function DeepEqual(a, b)
   if type(a) ~= type(b) then return false end
   if type(a) ~= "table" then return a == b end
   for k, v in pairs(a) do
      if not DeepEqual(v, b[k]) then return false end
   end
   for k in pairs(b) do
      if a[k] == nil then return false end
   end
   return true
end

local function Describe(v)
   if type(v) ~= "table" then return tostring(v) end
   local parts = {}
   for k, x in pairs(v) do
      parts[#parts + 1] = tostring(k) .. "=" .. Describe(x)
   end
   table.sort(parts)
   return "{" .. table.concat(parts, ", ") .. "}"
end

-- Runs all tests, prints a report to the console and returns the number of failures.
function RunSelfTests()
   local passed, failed = 0, 0
   -- keep the console readable: only test results are printed (the tests call functions that log)
   if Log then Log.set_sink(function() end) end

   local function out(s) reaper.ShowConsoleMsg(s .. "\n") end
   out("=== " .. WINDOW_TITLE .. " self tests ===")

   for _, test in ipairs(selfTests) do
      local t = {}
      function t.eq(actual, expected, label)
         if DeepEqual(actual, expected) then
            passed = passed + 1
         else
            failed = failed + 1
            out(string.format("  FAIL [%s] %s\n      expected: %s\n      actual:   %s",
               test.name, label or "", Describe(expected), Describe(actual)))
         end
      end

      function t.ok(cond, label) t.eq(cond and true or false, true, label) end

      local ok, err = pcall(test.fn, t)
      if not ok then
         failed = failed + 1
         out("  ERROR [" .. test.name .. "] " .. tostring(err))
      end
   end

   out(string.format("=== %d passed, %d failed ===", passed, failed))
   if Log then Log.set_sink(nil) end
   return failed
end

DefineTest("FormatTimeMMSS", function(t)
   t.eq(FormatTimeMMSS(0), "00:00", "zero")
   t.eq(FormatTimeMMSS(59.9), "00:59", "fraction is floored")
   t.eq(FormatTimeMMSS(61), "01:01", "one minute one second")
   t.eq(FormatTimeMMSS(3600), "60:00", "minutes do not wrap into hours")
end)

DefineTest("Clamp / PadNumberStringWithZeroes", function(t)
   t.eq(Clamp(5, 0, 3), 3, "above max")
   t.eq(Clamp(-5, 0, 3), 0, "below min")
   t.eq(Clamp(2, 0, 3), 2, "inside range")
   t.eq(PadNumberStringWithZeroes("7", 3), "007", "padded")
   t.eq(PadNumberStringWithZeroes("123", 2), "123", "never truncated")
end)

DefineTest("NormalizePath", function(t)
   t.eq(NormalizePath("C:\\a\\b\\"), "C:/a/b", "backslashes and trailing separator")
   t.eq(NormalizePath("/"), "/", "root stays")
   t.eq(NormalizePath(nil), "", "nil gives empty string")
end)

DefineTest("ExtractProjNameFromPath", function(t)
   t.eq(ExtractProjNameFromPath("/a/b/Song.rpp"), "Song", "unix path")
   t.eq(ExtractProjNameFromPath("C:\\a\\Song.RPP"), "Song", "windows path, upper case extension")
   t.eq(ExtractProjNameFromPath("Song"), "Song", "no separator is returned as is")
   t.eq(ExtractProjNameFromPath("dir/"), "dir/", "trailing separator does not crash")
end)

DefineTest("EncodeValue / DecodeValue", function(t)
   local nasty = "Intro = 120bpm; {x}, 100%25\r\nline2"
   local encoded = EncodeValue(nasty)
   t.ok(not encoded:find("[;={}\r\n]"), "no separator characters survive encoding")
   t.eq(DecodeValue(encoded), nasty, "round trip")
   t.eq(EncodeValue("plain text"), "plain text", "plain text is untouched")
end)

DefineTest("Setlist string round trip", function(t)
   local original = {
      { type = ENTRY.TEXT,    name = "Intro = 120bpm; {click}", path = "Intro = 120bpm; {click}",         highlight = { 0.5, 0.25, 0.75, 0.4 } },
      { type = ENTRY.PROJECT, name = "Song A",                  path = "/selftest/nonexistent/Song A.rpp" },
      { type = ENTRY.MISSING, name = "Gone",                    path = "/selftest/nonexistent/Gone.rpp" },
      { type = ENTRY.TEXT,    name = "Back\\slash 100%",        path = "Back\\slash 100%" },
      { type = ENTRY.TEXT,    name = "two\nlines",              path = "two\nlines" },
      { type = ENTRY.PROJECT, name = "Unsaved Project",         path = "Unsaved Project" }, -- must be skipped
   }

   local str = CreateSetlistString(original, "\n")
   local parsed, invalid = ParseSetlistString(str, "\n")

   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 5, "unsaved project is not serialized")
   t.eq(parsed[1].name, original[1].name, "label with = ; { } survives")
   t.eq(parsed[1].highlight, { 0.5, 0.25, 0.75, 0.4 }, "highlight list survives as numbers")
   t.eq(parsed[2].type, ENTRY.PROJECT, "project type")
   t.eq(parsed[2].path, SanitizePath("/selftest/nonexistent/Song A.rpp"), "project path")
   t.eq(parsed[3].type, ENTRY.MISSING, "missing type")
   t.eq(parsed[4].name, "Back\\slash 100%", "backslash and percent in label survive")
   t.eq(parsed[5].name, "two\nlines", "newline in label survives")
   for i, entry in ipairs(parsed) do
      t.eq(entry.listIdx, i, "listIdx " .. i)
   end
end)

DefineTest("Legacy setlist format still parses", function(t)
   local legacy = "name=Hello; path=Hello; type=text; listIdx=1; \n" ..
       "path=/old/100%41/Song.rpp; type=project; name=Song; listIdx=2; tabIdx=0; "
   local parsed, invalid = ParseSetlistString(legacy, "\n")
   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 2, "two entries")
   t.eq(parsed[1].name, "Hello", "text name")
   t.eq(parsed[2].path, SanitizePath("/old/100%41/Song.rpp"), "no decoding without the enc marker")
end)

DefineTest("Invalid entries are reported, not crashed on", function(t)
   local parsed, invalid = ParseSetlistString("name=orphan; \n", "\n")
   t.eq(#parsed, 0, "nothing valid")
   t.eq(#invalid, 1, "one invalid entry")
   local p2, i2 = ParseSetlistString("", "\n")
   t.eq({ #p2, #i2 }, { 0, 0 }, "empty string")
end)

DefineTest("List index <-> tab index lookups", function(t)
   local savedCount = openProjCount
   openProjCount = 2
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }

   t.eq({ ListIdxToTabIdx(1, list), ListIdxToTabIdx(2, list), ListIdxToTabIdx(3, list), ListIdxToTabIdx(4, list) },
      { 0, 0, 1, 1 }, "list -> tab")
   t.eq(ListIdxToTabIdx(5, list), 2, "past the end gives openProjCount")
   t.eq({ TabIdxToListIdx(-1, list), TabIdxToListIdx(0, list), TabIdxToListIdx(1, list), TabIdxToListIdx(2, list) },
      { 0, 2, 4, 5 }, "tab -> list")

   openProjCount = savedCount
end)

DefineTest("UpdateTabAndListIdx / GetProjEntriesInList", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT } }
   UpdateTabAndListIdx(list)
   t.eq({ list[1].listIdx, list[2].listIdx, list[3].listIdx, list[4].listIdx }, { 1, 2, 3, 4 }, "listIdx")
   t.eq({ list[2].tabIdx, list[3].tabIdx }, { 0, 1 }, "tabIdx of projects")
   t.eq(list[1].tabIdx, nil, "text entries have no tabIdx")
   t.eq(#GetProjEntriesInList(list), 2, "two project entries")
end)

DefineTest("ReorderProjectsByTabOrder", function(t)
   local T1, T2 = { type = ENTRY.TEXT, name = "T1" }, { type = ENTRY.TEXT, name = "T2" }
   local A = { type = ENTRY.PROJECT, proj = "a", name = "A" }
   local B = { type = ENTRY.PROJECT, proj = "b", name = "B" }
   local C = { type = ENTRY.PROJECT, proj = "c", name = "C" }
   local list = { T1, A, T2, B, C }

   local result, ok = ReorderProjectsByTabOrder(list, { "c", "a", "b" })
   t.ok(ok, "success flag")
   t.eq({ result[1].name, result[2].name, result[3].name, result[4].name, result[5].name },
      { "T1", "C", "T2", "A", "B" }, "text entries stay, projects follow tab order")
   t.eq({ list[2].name, list[4].name, list[5].name }, { "A", "B", "C" }, "input list is not modified")

   local same, okSame = ReorderProjectsByTabOrder(list, { "a", "b", "c" })
   t.ok(okSame, "already ordered")
   t.eq(same[2].name, "A", "order unchanged")

   local r1, ok1 = ReorderProjectsByTabOrder(list, { "a", "b" })
   t.ok(not ok1 and r1 == list, "count mismatch leaves list untouched")
   local r2, ok2 = ReorderProjectsByTabOrder(list, { "a", "b", "zzz" })
   t.ok(not ok2 and r2 == list, "unknown tab leaves list untouched")
   local r3, ok3 = ReorderProjectsByTabOrder({ { type = ENTRY.PROJECT, name = "no proj" } }, { "a" })
   t.ok(not ok3, "entry without proj is refused")
   local dup = { A, { type = ENTRY.PROJECT, proj = "a", name = "A2" } }
   local _, ok4 = ReorderProjectsByTabOrder(dup, { "a", "a" })
   t.ok(not ok4, "same proj twice is refused")
end)

DefineTest("IsListOrderInSync", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT, proj = "a" }, { type = ENTRY.PROJECT, proj = "b" } }
   t.ok(IsListOrderInSync(list, { "a", "b" }), "in sync")
   t.ok(not IsListOrderInSync(list, { "b", "a" }), "swapped")
end)

DefineTest("Zoom calculation", function(t)
   t.eq({ ComputeZoom(0) }, { 0, CFG.entryTextSize, CFG.projLenTextSize, CFG.linePadding }, "level 0 gives base sizes")
   t.eq({ ComputeZoom(2) }, { 2, CFG.entryTextSize + 2, CFG.projLenTextSize + 1, CFG.linePadding + 4 }, "level 2")
   t.eq((ComputeZoom(1000)), CFG.maxZoomLevel, "clamped to max")
   t.eq((ComputeZoom(-1000)), CFG.minZoomLevel, "clamped to min")
end)

DefineTest("Atomic file write / read", function(t)
   -- Not os.tmpname(): on Windows that points at the drive root, which is usually not writable
   local path = reaper.GetResourcePath() .. package.config:sub(1, 1) .. "SiSt-Live_selftest_" .. os.time() .. ".tmp"
   t.eq(ReadTextFile(path .. ".does-not-exist"), nil, "missing file gives nil")

   t.ok(WriteTextFileAtomic(path, "first\nversion"), "first write")
   t.eq(ReadTextFile(path), "first\nversion", "content read back")
   t.ok(WriteTextFileAtomic(path, "second"), "overwrite existing file")
   t.eq(ReadTextFile(path), "second", "overwritten content")
   t.eq(ReadTextFile(path .. ".tmp"), nil, "no .tmp file left behind")

   local ok = WriteTextFileAtomic("/selftest/nonexistent-dir/x.rsl", "data")
   t.ok(not ok, "unwritable location reports failure instead of crashing")
   os.remove(path)
end)

-- In-memory file system for WriteTextFileAtomic. opts.windows: rename onto an existing file fails.
-- opts.liar: rename does the move but reports a failure (seen with sync clients like kDrive).
-- opts.renameFails: every rename fails. opts.tmpVanishes: the .tmp file disappears when written.
local function FakeFileSystem(files, opts)
   opts = opts or {}
   local fs = {}
   function fs.open(path, mode)
      if mode == "rb" then
         if files[path] == nil then return nil, path .. ": No such file or directory" end
         local data = files[path]
         return { read = function() return data end, close = function() end }
      end
      local buf = {}
      return { write = function(_, s) buf[#buf + 1] = s; return true end,
         close = function()
            if not (opts.tmpVanishes and path:find("%.tmp$")) then files[path] = table.concat(buf) end
         end }
   end
   function fs.rename(from, to)
      if opts.renameFails then return nil, "Permission denied" end
      if files[from] == nil then return nil, "No such file or directory" end
      if opts.windows and files[to] ~= nil then return nil, "File exists" end
      files[to], files[from] = files[from], nil
      if opts.liar then return nil, "No such file or directory" end
      return true
   end
   function fs.remove(path) files[path] = nil; return true end
   return fs
end

DefineTest("Atomic write: Windows and sync-client behaviour", function(t)
   local files = { a = "old" }
   t.ok(WriteTextFileAtomic("a", "new", FakeFileSystem(files, { windows = true })), "Windows: target exists")
   t.eq(files.a, "new", "Windows: new content")
   t.eq({ files["a.tmp"], files["a.bak"] }, { nil, nil }, "Windows: no .tmp or .bak left")

   files = { a = "old" }
   t.ok(WriteTextFileAtomic("a", "new", FakeFileSystem(files, { windows = true, liar = true })),
      "rename reports a failure but did move: success")
   t.eq(files.a, "new", "rename that lied: the new content is kept, never deleted")

   files = { a = "old" }
   local ok = WriteTextFileAtomic("a", "new", FakeFileSystem(files, { renameFails = true }))
   t.ok(ok, "rename never works: written directly")
   t.eq(files.a, "new", "direct write: new content")

   files = { a = "old" }
   ok = WriteTextFileAtomic("a", "new", FakeFileSystem(files, { windows = true, tmpVanishes = true }))
   t.ok(ok, "the .tmp file vanished: written directly")
   t.eq(files.a, "new", "the .tmp file vanished: new content")

   files = {}
   files = { a = "old" }
   local fs = FakeFileSystem(files, { windows = true, tmpVanishes = true })
   fs.open = (function(open) return function(path, mode)
      if mode == "wb" and path == "a" then return nil, "locked" end -- the direct write is refused too
      return open(path, mode)
   end end)(fs.open)
   t.ok(not WriteTextFileAtomic("a", "new", fs), "nothing works: failure is reported")
   t.eq(files.a, "old", "nothing works: the old file is back in place")

   files = {}
   t.ok(WriteTextFileAtomic("a", "first", FakeFileSystem(files, { windows = true })), "no old file yet")
   t.eq(files.a, "first", "no old file yet: written")
end)

DefineTest("GetFollowScrollOffset", function(t)
   -- 1:T0 2:P1 3:T1 4:T2 5:P2 6:P3 7:T3
   local list = {
      { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.TEXT },
      { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
   }
   t.eq(GetFollowScrollOffset(list, 2, 10), 0, "first project: nothing above it, start at the top")
   t.eq(GetFollowScrollOffset(list, 5, 10), 1,
      "previous project (idx 2) goes to the top row, texts below it stay visible")
   t.eq(GetFollowScrollOffset(list, 6, 10), 4, "directly following project: previous project in top row")
   t.eq(GetFollowScrollOffset(list, 6, 3), 3, "clamped to maxScroll near the end of the list")
   t.eq(GetFollowScrollOffset(list, 0, 10), nil, "idx 0 (tab not in list)")
   t.eq(GetFollowScrollOffset(list, 8, 10), nil, "idx past the end")
   t.eq(GetFollowScrollOffset({ { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }, 2, 0), 0, "short list: maxScroll 0")
end)

DefineTest("GetMaxScroll", function(t)
   local function projects(n)
      local l = {}
      for i = 1, n do l[i] = { type = ENTRY.PROJECT } end
      return l
   end
   t.eq(GetMaxScroll(projects(5), 10), 0, "list that fits never scrolls")
   t.eq(GetMaxScroll(projects(20), 9), 18, "20 projects: last project's predecessor (idx 19) can reach the top row")
   t.eq(GetMaxScroll(projects(12), 10), 10, "list only 2 longer than the window still scrolls far enough")
   local withTexts = projects(3)
   for i = 4, 9 do withTexts[i] = { type = ENTRY.TEXT } end
   t.eq(GetMaxScroll(withTexts, 4), 5, "trailing text entries: normal range is enough")
   t.eq(GetMaxScroll({}, 5), 0, "empty list")
end)

DefineTest("Manual scrolling range", function(t)
   t.eq(GetManualMaxScroll({ 1, 2, 3, 4, 5 }, 3), 2, "last entry at the bottom")
   t.eq(GetManualMaxScroll({ 1, 2 }, 5), 0, "fits: no scrolling")

   t.eq(ApplyManualScroll(3, 1, 8), 4, "normal scroll down")
   t.eq(ApplyManualScroll(3, -5, 8), 0, "clamped at the top")
   t.eq(ApplyManualScroll(7, 4, 8), 8, "clamped at the manual maximum")
   -- view was left beyond the manual range by the follow-scroll (empty rows showing)
   t.eq(ApplyManualScroll(18, -1, 11), 17, "scrolling up starts from where the view is: smooth, no snap")
   t.eq(ApplyManualScroll(18, 1, 11), 18, "scrolling down does not go further")
   t.eq(ApplyManualScroll(13, -2, 11), 11, "comes back into the manual range step by step")
   t.eq(ApplyManualScroll(11, 1, 11), 11, "manual maximum is a hard stop once reached")
end)

DefineTest("GetStartupAutosaveAction", function(t)
   t.eq(GetStartupAutosaveAction(true, true, false), "ask", "first start after opening REAPER")
   t.eq(GetStartupAutosaveAction(true, false, false), "load", "restart in the same session: no question")
   t.eq(GetStartupAutosaveAction(false, true, false), "ignore", "no autosave: nothing to ask")
   t.eq(GetStartupAutosaveAction(true, true, true), "ignore", "shift held: autosave ignored, no question")
   t.eq(GetStartupAutosaveAction(true, false, true), "ignore", "shift held in the same session")
end)

DefineTest("DescribeSetlistContents", function(t)
   local list = {
      { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
      { type = ENTRY.TEXT },
   }
   t.eq(DescribeSetlistContents(list), "5 entries (2 projects, 3 text notes)", "projects and texts")
   list[#list + 1] = { type = ENTRY.MISSING }
   t.eq(DescribeSetlistContents(list), "6 entries (2 projects, 3 text notes, 1 missing)", "missing shown")
   t.eq(DescribeSetlistContents({}), "0 entries (0 projects, 0 text notes)", "empty")
end)

DefineTest("ShouldFollowProjectChange", function(t)
   t.ok(ShouldFollowProjectChange(MODE.SHOW, false), "show mode, tab changed in REAPER")
   t.ok(ShouldFollowProjectChange(MODE.SHOW, true), "show mode, clicked in the list")
   t.ok(ShouldFollowProjectChange(MODE.EDIT, false), "edit mode, tab changed in REAPER")
   t.ok(not ShouldFollowProjectChange(MODE.EDIT, true), "edit mode, clicked in the list: list stays")
end)

DefineTest("IsEditLocked", function(t)
   t.ok(IsEditLocked(MODE.SHOW, true), "show mode locks")
   t.ok(not IsEditLocked(MODE.EDIT, true), "edit mode doesn't")
   t.ok(not IsEditLocked(MODE.SHOW, false), "no mode library: never locked")
   t.ok(not IsEditLocked(MODE.SHOW, nil), "nil counts as no mode library")
end)

DefineTest("FindProjListIdx / GetOffscreenDirection", function(t)
   local list = {
      { type = ENTRY.TEXT,    proj = "a" }, { type = ENTRY.PROJECT, proj = "a" }, { type = ENTRY.TEXT },
      { type = ENTRY.PROJECT, proj = "b" }, { type = ENTRY.PROJECT, proj = "a" },
   }
   t.eq(FindProjListIdx(list, "a"), 2, "first project entry, text entries ignored")
   t.eq(FindProjListIdx(list, "b"), 4, "b")
   t.eq(FindProjListIdx(list, "zzz"), nil, "not in list")
   t.eq(FindProjListIdx(list, nil), nil, "nil project")

   -- rows 6..10 visible (scrollOffset 5, 5 rows)
   t.eq(GetOffscreenDirection(5, 5, 5), -1, "just above")
   t.eq(GetOffscreenDirection(6, 5, 5), 0, "first visible row")
   t.eq(GetOffscreenDirection(10, 5, 5), 0, "last visible row")
   t.eq(GetOffscreenDirection(11, 5, 5), 1, "just below")
   t.eq(GetOffscreenDirection(nil, 5, 5), 0, "unknown project: no arrow")
end)

DefineTest("StepSmoothScroll", function(t)
   t.eq(StepSmoothScroll(nil, 7, 0.016, 0.08), 7, "first frame jumps")
   t.eq(StepSmoothScroll(0, 7, 0.016, 0), 7, "time constant 0 disables the animation")
   t.eq(StepSmoothScroll(3, 7, 0, 0.08), 3, "no time passed: no movement")
   local v = StepSmoothScroll(0, 10, 0.016, 0.08)
   t.ok(v > 0 and v < 10, "moves towards the target without reaching it in one frame")
   local down = StepSmoothScroll(10, 0, 0.016, 0.08)
   t.ok(down < 10 and down > 0, "works downwards too")
   local x = 0
   for _ = 1, 120 do x = StepSmoothScroll(x, 10, 1 / 60, 0.08) end
   t.eq(x, 10, "settles exactly on the target within two seconds")
   t.eq(StepSmoothScroll(9.995, 10, 0.016, 0.08), 10, "snaps when closer than 0.01 rows")
end)

DefineTest("MenuItem / MenuTitle", function(t)
   t.eq(MenuItem("Rename", true), "Rename", "enabled")
   t.eq(MenuItem("Rename", false), "#Rename", "disabled is greyed")
   t.eq(MenuTitle("Song", false), "#Song", "title")
   t.eq(MenuTitle("Song", true), "#Song  (locked in show mode)", "title while locked")
end)

DefineTest("GetSharedLibSearchDirs", function(t)
   t.eq(GetSharedLibSearchDirs("C:\\R\\Scripts\\SiSt-Live\\Setlist\\SiSt-Live_Setlist.lua", "C:\\R", "\\"), {
      "C:\\R\\Scripts\\SiSt-Live\\Setlist\\lib\\",
      "C:\\R\\Scripts\\SiSt-Live\\Setlist\\..\\lib\\",
      "C:\\R\\Scripts\\SiSt-Live\\lib\\",
   }, "windows layout")
   t.eq(GetSharedLibSearchDirs("/r/Scripts/x/a.lua", "", "/"), { "/r/Scripts/x/lib/", "/r/Scripts/x/../lib/" },
      "no resource path")
   t.eq(GetSharedLibSearchDirs(nil, "/r", "/"), { "/r/Scripts/SiSt-Live/lib/" }, "script path unknown")
   t.eq(GetSharedLibSearchDirs("noSeparator.lua", nil, "/"), {}, "nothing usable")
end)

DefineTest("ToListMode", function(t)
   t.eq(ToListMode("show"), MODE.SHOW, "show")
   t.eq(ToListMode("edit"), MODE.EDIT, "edit")
   t.eq(ToListMode(""), nil, "empty")
   t.eq(ToListMode("garbage"), nil, "garbage")
   t.eq(ToListMode(nil), nil, "nil")
   local lib = { SHOW = "live", EDIT = "prep" }
   t.eq(ToListMode("live", lib), MODE.SHOW, "uses the library's own values")
   t.eq(ToListMode("prep", lib), MODE.EDIT, "uses the library's own values (edit)")
   t.eq(ToListMode("show", lib), nil, "does not assume the default strings")
   t.eq(ToListMode(nil, {}), nil, "nil never matches a missing constant")
end)

DefineTest("SetListMode / OnSharedModeChanged", function(t)
   local savedMode, savedPending = gui.mode, gui.followPending

   gui.mode, gui.followPending = MODE.SHOW, false
   t.ok(SetListMode(MODE.EDIT), "show -> edit reports a change")
   t.eq(gui.mode, MODE.EDIT, "now in edit mode")
   t.eq(gui.followPending, false, "entering edit mode does not request a scroll")
   t.ok(not SetListMode(MODE.EDIT), "same mode again: no change")
   t.ok(not SetListMode(nil), "nil is ignored")
   t.eq(gui.mode, MODE.EDIT, "nil leaves the mode alone")
   t.ok(SetListMode(MODE.SHOW), "edit -> show reports a change")
   t.eq(gui.followPending, true, "back in show mode: jump to the current project")

   local lib = Mode or { SHOW = "show", EDIT = "edit" }
   OnSharedModeChanged(lib.EDIT, nil)
   t.eq(gui.mode, MODE.EDIT, "callback: shared edit -> list edit")
   OnSharedModeChanged("garbage", lib.EDIT)
   t.eq(gui.mode, MODE.EDIT, "callback: unknown value keeps the current mode")
   OnSharedModeChanged(lib.SHOW, lib.EDIT)
   t.eq(gui.mode, MODE.SHOW, "callback: shared show -> list show")

   gui.mode, gui.followPending = savedMode, savedPending
end)

-- The Gui library tests itself (lib/Gui). Each module's self_test returns a list of { name, ok }.
DefineTest("Gui library (lib/Gui)", function(t)
   t.ok(Theme and Window and Widgets, "Gui library loaded")
   for _, lib in ipairs({ { "Theme", Theme }, { "Window", Window }, { "Widgets", Widgets } }) do
      if lib[2] then
         for _, r in ipairs(lib[2].self_test()) do t.ok(r.ok, lib[1] .. ": " .. r.name) end
      end
   end
end)

--------------------------
------- MAIN FLOW --------
--------------------------

-- Called by the Window once per frame. The Window runs the loop, handles closing and saves its state.
function Frame(w)
   if terminate then
      log:info("closing %s", WINDOW_TITLE)
      w:request_close()
   else
      lastProject = currentProj
      currentProj = reaper.EnumProjects(-1)

      CountOpenProjects()
      if pollMode then pollMode() end -- picks up edit/show changes (callback errors are logged, not thrown)
      if Mode then w:set_mode(gui.mode) end -- the window saves / restores its position per mode

      local numProjInList = #GetProjEntriesInList(setlist)
      local tabProjs = GetOpenProjectPtrs()
      if openProjCount ~= numProjInList then
         setlist = ResolveConflictsWithOpenProj(setlist, true) or GetOpenProjectList()
         if not terminate then SaveAutosave() end
      elseif not IsListOrderInSync(setlist, tabProjs) then
         -- The user rearranged the project tabs in REAPER: make the list follow
         local reordered, ok = ReorderProjectsByTabOrder(setlist, tabProjs)
         if ok then
            setlist = reordered
            CommitSetlist()
         end
      end

      -- Mouse state: read once per frame by the Window (w.mouse), copied into the names used below
      local m = w.mouse
      gui.prevRightClick, gui.rightClick = gui.rightClick, m.right
      gui.prevLeftClick, gui.leftClick = gui.leftClick, m.left
      if m.left_pressed or m.right_pressed then
         gui.lastClickDownPos = { x = m.press_x, y = m.press_y }
         if m.left_pressed then log:debug("Left click detected at position: " .. m.press_x .. "," .. m.press_y) end
      end

      if not gui.leftClick then
         gui.leftClickHandled = false
         gui.pressOnIndicator = false
      end
      if not gui.rightClick then gui.rightClickHandled = false end
      if not m.left and not m.right then gui.draggingScroll = false end


      gui.listH = gfx.h - gui.ctrlPanelSize - gui.titleHeight
      gui.numVisibleEntries = math.floor(gui.listH / gui.lineHeight)
      gui.maxScroll = GetManualMaxScroll(setlist, gui.numVisibleEntries)
      gui.followMaxScroll = GetMaxScroll(setlist, gui.numVisibleEntries)

      -- Follow-scroll: whenever the active project changes (tab click in REAPER or click in the list),
      -- bring the previous project to the top row. Not when a project was clicked in the list in edit mode.
      if lastProject ~= currentProj then
         local fromList = currentProj ~= nil and currentProj == gui.listClickTarget
         if ShouldFollowProjectChange(gui.mode, fromList) then
            gui.followPending = true
         else
            log:debug("Project selected in the list in edit mode: not scrolling")
         end
      end
      gui.listClickTarget = nil -- set by HandleEntryClick at the end of a frame, used once in the next one

      if #setlist <= gui.numVisibleEntries and gui.scrollOffset ~= 0 then
         gui.scrollOffset = 0
         log:debug("Scroll set to 0 because all entries are visible.")
      elseif gui.followPending and not (gui.leftClick or gui.draggingEntry or gui.draggingScroll) then
         local listIdx = TabIdxToListIdx(GetProjTabIdx(currentProj) or -1)
         local offset = GetFollowScrollOffset(setlist, listIdx, gui.followMaxScroll)
         if offset then
            gui.scrollOffset = offset
            log:debug("Following current project (" .. gui.mode .. " mode): listIdx " .. listIdx .. ", scrollOffset = " ..
               offset .. " (follow range " .. gui.followMaxScroll .. ", manual range " .. gui.maxScroll .. ", " ..
               gui.numVisibleEntries .. " rows visible, zoom " .. gui.zoomLevel .. ")")
         end
         gui.followPending = false
      end

      -- Any user scrolling, click or drag ends a running scroll animation right away
      local userInput = m.wheel ~= 0 or gui.leftClick or gui.rightClick or gui.draggingEntry or
          gui.draggingScroll

      HandleScrollbarClick()
      HandleMouseScroll()
      UpdateDisplayOffset(userInput)
      DisplaySetlist()
      DrawScrollbar()
      HandleOffscreenIndicator()

      HandleControlPanel()
      Theme.set_font(gui.entryTextSize)

      HandleEntryClick()
      HandleDraggingEntry()
   end
end

function Init()
   if not CheckDependencies() then return false end

   -- Hold Alt while launching to run the self tests (debug output: "DEBUG Toggle Logging")
   local runTests = IsModifierDown(MOD.ALT)
   if runTests then
      reaper.ClearConsole()
   end

   -- Loads lib/Gui (required) and the Mode library (optional, sets the list mode before the first frame)
   if not LoadSharedLibs() then return false end

   CountOpenProjects()

   local ignoreAutosave = IsModifierDown(MOD.SHIFT)
   local firstRun = IsFirstRunInSession()
   local saved, invalid, savedStr, source = {}, {}, "", ""

   if ignoreAutosave then
      log:info("started with Shift held: ignoring the autosave")
   else
      saved, invalid, savedStr, source = ReadAutosave()
   end

   local action = GetStartupAutosaveAction(next(saved) ~= nil, firstRun, ignoreAutosave)
   log:info("autosave at startup: " .. action .. (firstRun and " (first start since REAPER was opened)" or ""))

   local cleanStart = false
   if action == "ask" then
      local answer = AskLoadAutosave(saved)
      if answer == "cancel" then
         log:info("start cancelled by the user")
         return false -- not marked as started: the next start asks again
      end
      cleanStart = answer == "clean"
      action = cleanStart and "ignore" or "load"
   end

   MarkSessionStarted()

   if action == "load" then
      setlist = ApplyAutosave(saved, invalid, source) or {}
   end

   if not next(setlist) then
      log:info("building the list from the open projects")
      setlist = GetOpenProjectList()
   end

   if cleanStart then
      BackupAutosave(savedStr)
      UpdateTabAndListIdx()
      SaveAutosave() -- the clean list replaces the old autosave right away
   end

   if IsDebug() then
      log:debug("Setlist after Init:")
      PrintListPaths(setlist)
   end

   local ignoreWindowState = IsModifierDown(MOD.CTRL)
   if ignoreWindowState then log:info("started with Ctrl held: ignoring the saved window state") end

   win = Window.new{
      name = ExtStateSection, -- same section and "WindowState" key as before: the saved state is kept
      title = WINDOW_TITLE,
      defaults = { ww = 400, wh = 300, wx = 200, wy = 200, dockState = 0, zoomLevel = 0, scrollOffset = 0 },
      extra_keys = { "zoomLevel", "scrollOffset" },
      ignore_saved_state = ignoreWindowState,
      on_open = OnWindowOpen,
      on_close = OnWindowClose, -- also writes the autosave
      debug = function(text) log:debug("window: %s", text) end,
   }
   if Mode then win:set_mode(gui.mode) end -- open at this mode's position

   -- Run the self tests last, so the report is at the end of the console and isn't pushed out of
   -- REAPER's limited console buffer by the long startup log above it.
   if runTests then
      RunSelfTests()
      reaper.ShowConsoleMsg(DescribeSharedLibState() .. "\n")
   end

   if terminate then return false end -- a startup dialog was cancelled: don't open the window

   win:run(Frame) -- opens the window. Closing (also REAPER quitting) saves its state and the autosave
   return true
end

-- Headless test runners set SISTLIST_SELFTEST_ONLY to run the tests without opening a window
if rawget(_G, "SISTLIST_SELFTEST_ONLY") then
   LoadSharedLibs() -- so the Gui library's own self tests run too
   SISTLIST_SELFTEST_FAILED = RunSelfTests()
else
   Init()
end
