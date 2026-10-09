-- @description Project List
-- @version 0.5.1
-- @author sinfricia
-- @changelog
--   - Double click on text entries to edit them
--   - Imporvements to zooming, scrolling and drag & drop behaviors, restoring window state on --     load and click handling
--   - Minor UI changes and fixes
-- @about
--   # REAPER Project List Manager
--   A Tool to manage REAPER project tabs. Designed to be used as a setlist manager in a live environment.

local debug = false

function Msg(input)
   if debug == false then return end
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

function PrintListPaths(list)
   if not debug then return end

   for i, entry in ipairs(list) do
      if not entry.listIdx then
         entry.listIdx = -1
      end
      if not entry.tabIdx then
         entry.tabIdx = -1
      end
      Msg("[" .. entry.listIdx .. "] (tabIdx [" .. entry.tabIdx .. "]): " .. entry.path)
   end
end

function PrintEntry(entry)
   if not debug then return end
   Msg("  Printing Entry:")
   for k, v in pairs(entry) do
      reaper.ShowConsoleMsg(tostring(k) .. ": ")
      Msg(v)
   end
   Msg "------"
end

reaper.ClearConsole()

local scriptName = "Sist-Live_Setlist"

--------------------------
------- VARIABLES --------
--------------------------


local displayTabIdx = true

--- EXT STATE ---
local ExtStateSection = scriptName
local ExtKeyWndState = "WindowState"
local ExtKeySetlist = "Setlist"

--- DATA ---
local setlist = {} -- Table of entries with fields { "name", "path", "proj", "type", "color", "listIdx", "tabIdx",} though not all fields need to be present
local setlistTotalTime = 0

local listIdxToTabIdxLookup = {} --stores for every index in setlist (1-based) the coresponding project tab index (0-based). Corresponding means the next project entry in the list is at this tabIdx.
local tabIdxToListIdxLookup = {}
local openProjCount = 0
local currentProj = reaper.EnumProjects(-1)
local lastProject = currentProj
local projectSwitchHandled = nil
local conflictResolverRunCount = 0




--- GUI ---
local gui = {

   --Window position and size: These value are not updated during script runtime but loaded/saved to ext state
   ww = 400,
   wh = 300,
   wx = 200,
   wy = 200,
   dockState = 0,
   --------------------------

   ctrlPanelSize = 90,
   backgroundColor = 0x2e2e2e,
   font = "Arial",
   titleTextSize = 27,
   entryTextSize = 24,
   buttonFontSize = 18,
   projLenTextSize = 16,
   titleHeight = 56,
   leftBorder = 5,
   lineHeight = 0, -- calculated in InitWnd from entryTextSize and linePadding,
   linePadding = 18,
   minHeight = 0,  --currently unused (but calculated in wndInit)
   minWidth = 0,   --currently unused (but calculated in wndInit)

   activeProjHighlight = { 0.57, 0.97, 0.9, 0.7 },
   nextProjHighlight = { 0.25, 0.67, 0.6, 0.3 },
   dragHighlight = { 1, 0.8, 0.4, 0.7 },
   entryHighlights = {
      missing = { 1, 0, 0, 0.6 },    --red
      text = { 1.0, 0.5, 0.2, 0.2 }, -- light orange
      project = 0
   },
   projectEntryColor = { 1, 1, 1 },
   textEntryColor = { 1, 1, 1, 0.9 },
   entryIndent = 10,
   isNextProj = false,    -- used to draw special highlight for project that comes after current in list
   currProjDrawn = false, --used to handle situations where the same project is open multiple times.

   transportColors = {
      { 0.14, 0.99, 0.22, 1 }, --play
      {},
      {},
      {},
      { 0.89, 0.24, 0.23, 1 } -- record
   },
   playPosColor = { 0.95, 0.82, 0.45, 0.6 },

   dragForbidden = false,
   dragThreshold = 6, -- Small threshold for drag detection,
   dropIndicatorColor = { 1, 1, 1, 0.6 },
   dropIndicatorThickness = 4,
   leftClick = 0,
   rightClick = 0,
   leftClickHandled = false,
   rightClickHandled = false,
   lastClickDownPos = { x = 0, y = 0 },
   lastClickDownPos = { x = 0, y = 0 },

   -- scrolling stuff
   scrollTrackColor = { 0.3, 0.3, 0.3, 1 },
   scrollThumbColor = { 0.6, 0.6, 0.6, 1 },
   numVisibleEntries = 0,
   scrollW = 20,
   scrollH = 0,
   scrollY = 0,
   scrollOffset = 0,
   maxScroll = 0,
   scrollBarGrabStart = 0,
   scrollBarGrabOffset = 0,
   draggingScroll = false,
   dragScrollMargin = 1,       -- Margin in which list scrolls while dragging entry
   dragScrollSpeed = 0.3,
   fractionalScrollOffset = 0, --used for scrolling while dragging an entry to allow fractional scrolling speeds

   -- double-click tracking
   doubleClickThreshold = 0.30, -- seconds between two clicks to qualify
   lastClickTime = 0,           -- timestamp of last click (reaper.time_precise)
   lastClickIdx = nil,          -- list index of last clicked entry
   doubleClick = false,         -- true only on frame where second click detected


   -- dynamic variables for drag & drop functionality
   draggingEntry = false,
   dragEntryListIdx = 0,
   dropIdx = nil,
   dragDirection = 0,
   dragStartY = 0,
   dragThreshReached = nil,

   maxZoomLevel = 16,
   minZoomLevel = -8,
   zoomLevel = 0,
   zoomFactor = 1,
   zoomDelay = 0.10, -- seconds between zoom steps when holding button
   lastZoomTime = 0,

   --buttons
   buttonColor = { 0.5, 0.5, 0.5, 0.6 },
   buttownW = 140,
   buttonH = 30,
   buttonTextSize = 20,

}

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

function CountElementOccurrences(table, element)
   local count = 0
   for _, value in ipairs(table) do
      if value == element then
         count = count + 1
      end
   end
   return count
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
   reaper.SelectProjectInstance(proj)
   reaper.Main_OnCommand(40860, 0) --Close current project tab
   if not proj == proj then
      reaper.SelectProjectInstance(proj)
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
   return path:match("^.+[\\/](.+)$"):gsub("%.rpp$", ""):gsub("%.RPP$", "") or path
end

function GetProjFromPath(path, duplicateNumber)
   if not duplicateNumber then
      duplicateNumber = 0
   end
   local idx = 0

   Msg("Getting project from path")
   Msg("  Looking for (duplicate) instance " .. duplicateNumber)
   while true do
      local proj, projPath = reaper.EnumProjects(idx)
      if not proj then
         Msg("    Not found. Project not open.")
         return nil
      end
      if path == projPath then
         if duplicateNumber == 0 then
            Msg("    Fount at tab idx [" .. idx .. "]")
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
   local has_sws = 'Missing. Visit https://www.sws-extension.org/ for installtion instructions.'
   local has_js = 'Missing. Click OK to open ReaPack.'

   local has_js_noauto =
   'Get it from ReaPack or visit https://forum.cockos.com/showthread.php?t=212174 \nfor installation instructions.'

   if reaper.APIExists('CF_GetSWSVersion') then has_sws = 'Installed.' end
   if reaper.APIExists('JS_Dialog_BrowseForOpenFiles') then has_js = 'Installed.' end

   if has_sws ~= 'Installed.' or has_js ~= 'Installed.' then
      local error_msg1 = string.format(
         "This script requires SWS Extension and JS ReaScript API to run. \n\nSWS Extension:  %s \nJS API:     %s",
         has_sws, has_js)
      local response = reaper.MB(error_msg1, 'Missing dependencies', 1)

      if response ~= 1 and has_js ~= 'Installed.' then
         local error_msg2 = 'Please install missing dependencies manually.'
         if has_js ~= 'Installed.' then
            error_msg2 = error_msg2 .. '\n\nJS API: \n' .. has_js_noauto
         end
         return reaper.MB(error_msg2, 'Thank you and goodbye', 0)
      elseif response == 1 and has_js == 'Installed.' then
         return
      end

      if has_js ~= 'Installed.' and reaper.APIExists('ReaPack_BrowsePackages') then
         reaper.ReaPack_BrowsePackages('js_ReaScriptAPI: API functions for ReaScripts')
      elseif not reaper.APIExists('ReaPack_BrowsePackages') then
         local error_msg3 =
         "Couldn't find ReaPack. Visit https://reapack.com/ for installation instructions or install missing libraries manually."
         if has_js ~= 'Installed.' then
            error_msg3 = error_msg3 .. '\n\nJS API: \n' .. has_js_noauto
         end
         return reaper.MB(error_msg3, 'Thank you and goodbye', 0)
      end

      return false
   else
      return true
   end
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
      Msg("Found '" .. fileName .. "' in setlist directory.")
      return candidate -- File found in loadPath dir
   else
      return projPath  -- Fall back to original projPath
   end
end

function SerializeTable(tbl)
   if type(tbl) ~= "table" then
      if type(tbl) == "string" then
         return string.format("%q", tbl)
      elseif type(tbl) == "number" or type(tbl) == "boolean" then
         return tostring(tbl)
      elseif tbl == nil then
         return "nil"
      else
         return string.format("%q", tostring(tbl))
      end
   end

   local parts = {}
   local arrayPart = {}
   local hashPart = {}

   -- Detect array portion
   local maxIndex = 0
   for k, _ in pairs(tbl) do
      if type(k) == "number" and k > 0 and k == math.floor(k) then
         maxIndex = math.max(maxIndex, k)
      end
   end

   local isArray = true
   for i = 1, maxIndex do
      if tbl[i] == nil then
         isArray = false
         break
      end
   end

   -- Serialize array elements
   if isArray and maxIndex > 0 then
      for i = 1, maxIndex do
         table.insert(arrayPart, SerializeTable(tbl[i]))
      end
   end

   -- Serialize hash elements
   for k, v in pairs(tbl) do
      local skipKey = false
      if isArray and type(k) == "number" and k >= 1 and k <= maxIndex then
         skipKey = true
      end

      if not skipKey then
         local keyStr
         if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            keyStr = k
         elseif type(k) == "string" then
            keyStr = "[" .. string.format("%q", k) .. "]"
         elseif type(k) == "number" then
            keyStr = "[" .. tostring(k) .. "]"
         else
            keyStr = "[" .. string.format("%q", tostring(k)) .. "]"
         end

         table.insert(hashPart, keyStr .. "=" .. SerializeTable(v))
      end
   end

   -- Combine
   local result = "{"
   for i, v in ipairs(arrayPart) do
      result = result .. v .. ","
   end
   for i, v in ipairs(hashPart) do
      result = result .. v .. ","
   end
   result = result .. "}"

   return result
end

--------------------------
----- DATA FUNCTIONS -----
--------------------------

--- DATA EXPORT/IMPORT ---

function SaveWndStateToExt()
   Msg("Saved WndState to EXT.")
   local persist = true

   local wndState = {}
   wndState.dockState, wndState.wx, wndState.wy, wndState.ww, wndState.wh = gfx.dock(-1, 1, 1, 1, 1)
   wndState.zoomLevel = gui.zoomLevel
   wndState.scrollOffset = gui.scrollOffset

   local wndStateStr = SerializeTable(wndState)

   reaper.SetExtState(ExtStateSection, ExtKeyWndState, wndStateStr, persist)
end

function LoadWndStateFromExt()
   local wndStateStr = reaper.GetExtState(ExtStateSection, ExtKeyWndState)

   if not wndStateStr or wndStateStr == "{" then
      Msg("No WndState in ExtState. Loading defaults.")
      return
   end

   local wndState = load("return " .. wndStateStr)()
   for k, v in pairs(wndState) do
      gui[k] = v or gui[k]
   end

   Msg("Restored WndState from EXT.")
end

function CreateSetlistString(setlist, separator)
   local entryStrings = {}
   Msg("Creating setlist string:")
   for _, entry in ipairs(setlist) do -- Save name for text entries (name = path for those) and full path for projects
      if entry.path ~= "Unsaved Project" then
         local entryStr = ""
         for k, v in pairs(entry) do
            if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
               --as \n is the separator for entries in the list we make sure that values (especially the project path) does not contain that
               entryStr = entryStr .. k .. "=" .. NormalizePath(v) .. "; "
            elseif type(v) == "table" then
               entryStr = entryStr .. k .. "={"
               for i = 1, #v do
                  entryStr = entryStr .. v[i] .. ","
               end
               entryStr = entryStr .. "}; "
            end
         end

         table.insert(entryStrings, entryStr)
         -- Msg("  " .. entryStr)
      end
   end

   local setlistStr = table.concat(entryStrings, separator)

   return setlistStr
end

function ParseSetlistString(setlistStr, separator)
   if setlistStr == "" then
      return {}, {}
   end

   local entryStrings = {}
   local pattern = "([^" .. separator .. "]+)"
   for entryStr in string.gmatch(setlistStr, pattern) do
      table.insert(entryStrings, entryStr)
   end

   local parsedSetlist = {}
   local duplicateTracker = {}
   local invalidEntries = {}
   Msg("   Parsing Setlist string")
   for i = 1, #entryStrings do
      local entryStr = entryStrings[i] --entryStrings have the type prefixed!


      local newEntry = {}
      for k, v in entryStr:gmatch("([^; ]+)=([^;]+)") do
         if v:find("^{.*}$") then -- value is table
            local tbl = {}

            for s, _ in v:gmatch("([^{},]+)") do
               Msg("Found value: " .. s)
               table.insert(tbl, s)
            end
            newEntry[k] = tbl
         else
            newEntry[k] = v:gsub("^%s*(.-)%s*$", "%1") -- trim spaces
         end
      end

      Msg("")
      Msg("")
      newEntry.path = SanitizePath(newEntry.path)
      local type = newEntry.type
      local path = newEntry.path

      if not type or not path or type == "" or path == "" then
         table.insert(invalidEntries, entryStr)
         Msg("    Invalid entrystring")
         goto skip
      end

      if type == "project" and not path:find("[\\/]") then path = "" end -- handling unsaved projects

      if duplicateTracker[path] then
         duplicateTracker[path] = duplicateTracker[path] + 1
      else
         duplicateTracker[path] = 0
      end

      -- initializing things that are not or may not be properly stored in Setlist String
      newEntry.proj = nil
      if type == "project" then
         newEntry.proj = GetProjFromPath(newEntry.path, duplicateTracker[path])
      end

      if not newEntry.name then
         newEntry.name = ExtractProjNameFromPath(path)
      end


      newEntry["listIdx"] = #parsedSetlist + 1
      newEntry["tabIdx"] = GetProjTabIdx(newEntry.proj)


      table.insert(parsedSetlist, newEntry)

      Msg("     " .. entryStr)
      Msg("     " .. newEntry.name)

      ::skip::
   end

   return parsedSetlist, invalidEntries
end

function SaveSetlistToExtState()
   Msg("Saving to EXT_STATE")
   local setlistStr = CreateSetlistString(setlist, "\n")
   reaper.SetExtState(ExtStateSection, ExtKeySetlist, setlistStr, false)
end

function LoadSetlistFromExtState()
   local setlistStr = reaper.GetExtState(ExtStateSection, ExtKeySetlist)

   Msg("Retrieving from EXT_STATE: ")
   local extSetlist, invalidEntries = ParseSetlistString(setlistStr, "\n")
   Msg("Retrieved " .. #extSetlist .. " entries")

   if next(invalidEntries) then
      HandleIInvalidSetlistStringEntries(extSetlist, invalidEntries, "from EXT_STATE")
   end

   if next(extSetlist) then
      return ResolveConflictsWithOpenProj(extSetlist, false)
   else
      return {}
   end
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

   Msg("Checking if files exists in setlist directory")
   for i = 1, #fileList do
      local path = CheckIfFileInRelativeDir(loadPath, fileList[i].path)
      fileList[i].path = SanitizePath(path)
      fileList[i].proj = GetProjFromPath(fileList[i].path)
   end

   SaveSetlistToExtState()
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

   Msg("Building Tab Index to List Index Lookup...")
   local tabIdx = 0
   tabIdxToListIdxLookup = {}

   for i, entry in ipairs(list) do
      if entry.type == "project" then
         --Msg("  -Tab idx [" .. tabIdx .. "] corresponds to list idx [" .. i .. "]")

         tabIdxToListIdxLookup[tabIdx] = i
         tabIdx = tabIdx + 1
      end
   end
end

function BuildListIdxToTabIdxLookup(list)
   --Msg("Building List Index to Tab Index Lookup...")

   if not list then list = setlist end

   local tabIdxCounter = 0
   listIdxToTabIdxLookup = {}

   for i, entry in ipairs(list) do
      --Msg("  -List idx [" .. i .. "] corresponds to tab idx [" .. tabIdxCounter .. "]")
      listIdxToTabIdxLookup[i] = tabIdxCounter

      if entry.type == "project" then
         tabIdxCounter = tabIdxCounter + 1
      end
   end
end

function TabIdxToListIdx(tabIdx, list)
   Msg("Getting List Index for Tab Index [" .. tabIdx .. "]")

   if not list then list = setlist end

   BuildTabIdxToListIdxLookup(list)

   if tabIdx < 0 then
      Msg("  opt1 = 0")
      return 0
   elseif not tabIdxToListIdxLookup[tabIdx] then
      Msg("  opt2 = " .. #list + 1)

      return #list + 1
   else
      Msg("  opt3 = " .. tabIdxToListIdxLookup[tabIdx])
      return tabIdxToListIdxLookup[tabIdx]
   end
end

function ListIdxToTabIdx(listIdx, list)
   BuildListIdxToTabIdxLookup(list)

   if not list then list = setlist end
   --Msg("Getting Tab Index for List Index [" .. listIdx .. "]")
   if listIdx < 0 then
      --Msg("  opt1 = 0")
      return 0
   elseif listIdx > #list or not listIdxToTabIdxLookup[listIdx] then
      --Msg("  opt2 = " .. openProjCount)
      return openProjCount
   else
      --Msg("  opt3 = " .. listIdxToTabIdxLookup[listIdx])

      return listIdxToTabIdxLookup[listIdx]
   end
end

function GetProjEntriesInList(list)
   local projEntriesInList = {}
   for _, entry in ipairs(list) do
      if entry.type == "project" then
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
         type = "project"
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
   if entry.type == "text" then return end

   local parentDir = GetCurrProjParentDir()

   local extensionList = "Reaper Project File (.rpp)\0*.rpp;*.RPP\0\0"
   local retval, loadPath = reaper.JS_Dialog_BrowseForOpenFiles("Replace Project Entry", parentDir, "",
      extensionList,
      false)
   if not retval or loadPath == "" then return end

   reaper.Main_OnCommand(40859, 0) --New project tab
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

   list[entry.listIdx].type = "project"
   list[entry.listIdx].proj = reaper.EnumProjects(-1)
   list[entry.listIdx].path = loadPath
   list[entry.listIdx].name = ExtractProjNameFromPath(loadPath)
   list[entry.listIdx].tabIdx = ListIdxToTabIdx(entry.listIdx)

   PrintEntry(list[entry.listIdx])
end

function ResolveConflictsWithOpenProj(list, silent, isLoadFile) -- checks a setlist against currently open projects and resolves conflicts
   Msg("\nSTARTING CONFLICT RESOLVER: Searching for conflicts between list and open projects...")

   if not next(list) then
      Msg("  Setlist empty, building from open projects")
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
      if entry.type == "project" then
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

         Msg("Found dupe nreaper. " .. openDuplicateTracker[entry.path] .. " for path " .. entry.path)
      end

      openPaths[entry.path] = entry

      if entry.type == "project" and (not listPaths[entry.path]) then
         table.insert(missingInList, entry)
         missingInListStr = missingInListStr .. entry.path .. "\n"
      end
   end

   -- check for entries not in openProjects
   local nextIsDuplicate = {}
   for _, entry in ipairs(list) do
      if not openPaths[entry.path] and entry.type == "project" and not nextIsDuplicate[entry.path] then
         table.insert(missingInOpenProjects, entry)
         missingInOpenProjStr = missingInOpenProjStr .. entry.path .. "\n"
         nextIsDuplicate[entry.path] = true
      end
   end

   if debug then
      Msg("  Open projects: ")
      for _, entry in ipairs(openProjList) do
         Msg("    " .. entry.path)
      end

      Msg("  Entries in list: ")
      for _, entry in ipairs(list) do
         Msg("    " .. entry.path)
      end

      if next(missingInList) then
         Msg("  Missing in list: ")
         for _, entry in ipairs(missingInList) do
            Msg("    " .. entry.path)
         end
      end

      if next(missingInOpenProjects) then
         Msg("  Missing in open projects: ")
         for _, entry in ipairs(missingInOpenProjects) do
            Msg("    [" .. entry.listIdx .. "]: " .. entry.path)
         end
      end
   end


   -- handle projects that are open in multiple tabs
   if next(duplicateProjects) then
      local msg = "WARNING! The following projects are opened multiple times:" ..
          duplicateProjStr ..
          "\nAre you sure you want that? Clicking 'No' will close all duplicates."

      local ret = reaper.MB(msg, "SETLIST - DUPLICATE PROJECTS FOUND", 3)

      Msg("Processing duplicate open projects... ")


      if ret == 6 then
         for _, entry in ipairs(duplicateProjects) do
            local duplicateCount = CountEntryOccurrences(duplicateProjects, entry)
            local duplicatesInList = CountEntryOccurrences(list, entry) - 1

            if duplicatesInList == -1 then
               duplicatesInList = 0
            end

            Msg("Inserting " ..
               duplicateCount - duplicatesInList ..
               " duplicates of " .. entry.name .. " into list. (If 0 that means all duplicates are already in list.)")

            for i = 1, duplicateCount - duplicatesInList do
               local newEntryIdx = TabIdxToListIdx(entry.tabIdx, list)
               Msg("  Duplicate " .. i .. " (tabIdx [" .. entry.tabIdx .. "]) = at listIdx [" .. newEntryIdx .. "]")
               entry.listIdx = newEntryIdx
               table.insert(list, newEntryIdx, entry)
               list[newEntryIdx].tabIdx = ListIdxToTabIdx(newEntryIdx, list)
            end
         end
      elseif ret == 7 then
         for _, entry in ipairs(duplicateProjects) do
            reaper.SelectProjectInstance(entry.proj)
            reaper.Main_OnCommand(40860, 0) --Close current project tab
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
            Msg("DuplicateCount: " .. duplicateCount)
            Msg("DuplicatesInList: " .. duplicatesInList)
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
   Msg("Processing duplicates in list that don't correspond to open projects")
   for path, duplicateNumber in pairs(listDuplicateTracker) do
      if duplicateNumber > 0 then
         if openDuplicateTracker[path] then
            duplicateNumber = duplicateNumber - openDuplicateTracker[path]
         end
         Msg("  " .. path .. " has " .. duplicateNumber .. " unprocessed duplicates in list.")
      end
      local numFoundDuplicate = 0
      for j = #list, 1, -1 do
         if numFoundDuplicate >= duplicateNumber then break end

         local entry = list[j]
         if entry.path == path then
            table.insert(missingInOpenProjects, #missingInOpenProjects + 1, entry)
            numFoundDuplicate = numFoundDuplicate + 1

            missingInOpenProjStr = missingInOpenProjStr .. entry.path .. " - (duplicate #" .. numFoundDuplicate .. ")\n"
            Msg("  Added to missing in open projects: ")
            Msg("    [" .. entry.listIdx .. "]: " .. entry.path)
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
      elseif isLoadFile then
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      Msg("Processing projects in list but not open... ")
      if ret == 6 then
         -- Open projects on list
         for _, entry in ipairs(missingInOpenProjects) do
            if reaper.file_exists(entry.path) then
               reaper.Main_OnCommand(40859, 0) --New project tab
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

               list[entry.listIdx].type = "missing"
            end
         end
         openedFileCount = #missingInOpenProjects
      elseif ret == 7 then
         local numRemoved = 0
         for _, entry in ipairs(missingInOpenProjects) do
            Msg("  removing [" .. entry.listIdx .. "]: " .. entry.path)

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
      if silent then
         ret = 6
      else
         ret = reaper.MB(msg, "Conflict while loading setlist", 3)
      end
      Msg("\nProcessing open projects not in list... ")
      PrintListPaths(list)
      Msg("")


      if ret == 6 then -- Clicked Yes
         -- Add new projects to the list

         for _, entry in ipairs(missingInList) do
            entry.tabIdx = entry.tabIdx + openedFileCount
            local newEntryIdx = TabIdxToListIdx(entry.tabIdx, list)
            Msg("  adding to list: [" .. newEntryIdx .. "] (tabIdx = " .. entry.tabIdx .. ") " .. entry.path)
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
            Msg(playState & 4)
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
            reaper.Main_OnCommand(40860, 0) --Close current project tab
            openProjCount = openProjCount - 1
         end
         ::continue_close_loop::
      else
         terminate = true
         return list
      end

      PrintListPaths(list)
      Msg("")
   end


   local projEntriesInList = GetProjEntriesInList(list)
   openProjList = GetOpenProjectList()


   --Check for order mismatch
   Msg("Checking for order mismatch between open projects and list...")
   Msg("OpenProjList:")
   PrintListPaths(openProjList)
   Msg("projEntriesInList:")
   PrintListPaths(projEntriesInList)

   local orderConflict = false
   if #openProjList ~= #projEntriesInList then
      conflictResolverRunCount = conflictResolverRunCount + 1

      if conflictResolverRunCount < 0 then
         ResolveConflictsWithOpenProj(list, silent)
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
         ResolveConflictsWithOpenProj(list, silent)
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
         Msg("  Mismatch at tab index " .. i - 1)
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

   Msg("Starting move for '" ..
      reaper.GetProjectName(targetProj) .. "' from tabIdx [" .. startIdx .. "] to [" .. targetIdx .. "]")

   local moveDirection = 0

   if targetIdx > startIdx then
      moveDirection = 1  -- Move right (down with drag&drop)
   elseif targetIdx < startIdx then
      moveDirection = -1 -- Move left (down with drag&drop)
   else
      Msg("Aborted move: targetIdx == startIdx")
      return -- No movement
   end

   Msg("  moveDirection: " .. moveDirection)

   local tabMoveCmdID = { [-1] = 3242, [1] = 3243 }

   Msg("  Number of move commands: " .. (targetIdx - startIdx) * moveDirection)
   for i = 1, (targetIdx - startIdx) * moveDirection do
      Msg("    Move " .. i)

      reaper.Main_OnCommandEx(tabMoveCmdID[moveDirection], 0, targetProj) --Project tabs: Move project tab left/right by one
   end
end

function ListOrderToProjTabs(list)
   Msg("Starting project tab sort...")

   local projEntriesInSetlist = GetProjEntriesInList(list)

   for i, entry in ipairs(projEntriesInSetlist) do
      MoveProjTabToIdx(entry.proj, i - 1)
      entry.tabIdx = i - 1
   end
end

function UpdateTabAndListIdx(list)
   Msg("Updating tab and list index fields from respective orders")
   if not list then list = setlist end

   for i, _ in ipairs(list) do
      list[i].listIdx = i

      if list[i].type == "project" then
         list[i].tabIdx = ListIdxToTabIdx(i, list)
      end
   end
end

function SortListByListIdx(list)
   table.sort(list, function(x, y)
      return x.listIdx < y.listIdx
   end)
end

function UpdateListOrderFromOpenProjects(list, openProjectList)
   Msg("Updating setlist from open projects...")

   if not openProjectList then
      openProjectList = GetOpenProjectList()
   end

   for i, openProjEntry in ipairs(openProjectList) do
      for j, listEntry in ipairs(list) do
         if listEntry.proj == openProjEntry.proj then
            Msg("  Found open project '" .. openProjEntry.name .. "' (tabIdx [" .. i - 1 .. "]) at listIdx [" .. j .. "]")
            local newListIdx = TabIdxToListIdx(i - 1, list)

            if newListIdx > j then
               table.insert(list, newListIdx, listEntry)
               table.remove(list, j)
            elseif newListIdx < j then
               table.remove(list, j)
               table.insert(list, newListIdx, listEntry)
            end
         end
      end
   end


   return list
end

--------------------------
----- GUI FUNCTIONS ------
--------------------------

function UpdateZoom(direction, newZoomLevel) -- direction: 1 = zoom in, -1 = zoom out, anything else = auto calculate based on newZoomLevel
   if gui.leftClick and reaper.time_precise() - gui.lastZoomTime < gui.zoomDelay or not direction then
      return
   end

   if (direction == 1 and gui.zoomLevel == gui.maxZoomLevel) or (direction == -1 and gui.zoomLevel == gui.minZoomLevel) then
      return
   end

   local zoomStep = 0
   if (direction ~= -1 or direction ~= 1) and newZoomLevel then
      direction = newZoomLevel - gui.zoomLevel
      if direction > 0 then
         direction = 1
      elseif direction < 0 then
         direction = -1
      else
         return
      end
      zoomStep = newZoomLevel - gui.zoomLevel
   else
      newZoomLevel = 1
      zoomStep = direction * gui.zoomFactor
   end

   gui.lastZoomTime = reaper.time_precise()

   gui.entryTextSize = gui.entryTextSize + zoomStep
   gui.projLenTextSize = gui.projLenTextSize + zoomStep / 2
   gui.linePadding = gui.linePadding + zoomStep * 2

   gfx.setfont(1, gui.font, gui.entryTextSize) -- Set the font for the list (index 1, size 16)
   gui.lineHeight = gfx.texth + gui.linePadding

   gui.zoomLevel = gui.zoomLevel + zoomStep
   Msg("Zoom level changed to " .. gui.zoomLevel)
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

function IsProjVisibleInList(proj) --proj can be either a ReaProject* or a number representing the project tab index
   local tabIdx = 0
   if type(proj) == "number" and proj > 0 then
      if proj > openProjCount - 1 then
         proj = openProjCount - 1
      end
      tabIdx = proj
   elseif reaper.ValidatePtr(proj, "ReaProject*") then
      tabIdx = GetProjTabIdx(proj)
   else
      return false
   end

   --Msg("Checking visibility for project tabIdx [" .. tostring(proj) .. "]")


   local listIdx = TabIdxToListIdx(tabIdx)

   local visibleStartIdx = gui.scrollOffset + 1
   local visibleEndIdx = gui.scrollOffset + math.floor(gui.listH / gui.lineHeight)

   if listIdx >= visibleStartIdx and listIdx <= visibleEndIdx then
      return true
   else
      return false
   end
end

function IsActiveProjAtTopOfList()

end

function HandleSaveListButton()
   local bX = gui.entryIndent
   local bH = gui.buttonH
   local bY = gfx.h - bH - gui.titleHeight / 2 -- Position the save button
   local bW = gui.buttownW

   gfx.set(table.unpack(gui.buttonColor)) -- Save button color
   gfx.setfont(1, gui.font, gui.buttonFontSize)

   gfx.rect(bX, bY, bW, bH, true) -- Draw filled rectangle for save button
   gfx.set(1, 1, 1)               -- White text
   gfx.x = bX
   gfx.y = bY
   gfx.drawstr("Save Setlist", 5, bX + bW, bY + bH)


   if gui.leftClick and IsPointInRect(bX, bY, bW, bH, gui.lastClickDownPos.x, gui.lastClickDownPos.y) and not gui.leftClickHandled then
      SaveSetlistToFile()
      gui.leftClickHandled = true
   end
end

function HandleLoadListButton()
   local bX = gui.entryIndent * 2 + gui.buttownW
   local bH = gui.buttonH
   local bY = gfx.h - bH - gui.titleHeight / 2
   local bW = gui.buttownW

   gfx.set(table.unpack(gui.buttonColor))
   gfx.setfont(1, gui.font, gui.buttonFontSize)

   gfx.rect(bX, bY, bW, bH, true)
   gfx.set(1, 1, 1)
   gfx.x = bX
   gfx.y = bY
   gfx.drawstr("Load Setlist", 5, bX + bW, bY + bH)


   if gui.leftClick and IsPointInRect(bX, bY, bW, bH, gui.lastClickDownPos.x, gui.lastClickDownPos.y) and not gui.leftClickHandled then
      setlist = LoadSetlistFromFile()
      gui.leftClickHandled = true
   end
end

function HandleInsertTextButton()
   local bX = gui.entryIndent * 3 + gui.buttownW * 2
   local bH = gui.buttonH
   local bY = gfx.h - bH - gui.titleHeight / 2
   local bW = gui.buttownW

   gfx.set(table.unpack(gui.buttonColor))
   gfx.setfont(1, gui.font, gui.buttonFontSize)

   gfx.rect(bX, bY, bW, bH, true)
   gfx.set(1, 1, 1)
   gfx.x = bX
   gfx.y = bY
   gfx.drawstr("Insert Text", 5, bX + bW, bY + bH)

   if gui.leftClick and IsPointInRect(bX, bY, bW, bH, gui.lastClickDownPos.x, gui.lastClickDownPos.y) and not gui.leftClickHandled then
      local ret, input = reaper.GetUserInputs("Insert Text Note", 1, "Enter label:", "")
      if ret and input ~= "" then
         table.insert(setlist,
            { name = input, path = input, type = "text", listIdx = #setlist + 1 })
      end
      gui.leftClickHandled = true
   end
end

function HandleZoomButtons()
   gfx.setfont(1, gui.font, gui.buttonFontSize * 1.2)


   -- Zoom Out
   local bW = gui.buttownW / 5
   local bX = gfx.w - gui.entryIndent - bW
   local bH = gui.buttonH * 0.8
   local bY = gfx.h - bH - gui.titleHeight / 2

   gfx.set(table.unpack(gui.buttonColor))
   gfx.rect(bX, bY, bW, bH, true)
   gfx.set(1, 1, 1)
   local strW, strH = gfx.measurestr("-")
   gfx.x = bX + (bW - strW) / 2
   gfx.y = bY + (bH - strH) / 2 - 1
   gfx.drawstr("-")


   if gui.leftClick and IsPointInRect(bX, bY, bW, bH, gui.lastClickDownPos.x, gui.lastClickDownPos.y) and not gui.leftClickHandled then
      if reaper.JS_Mouse_GetState(16) == 16 then --alt is held
         UpdateZoom(0, 0)
      else
         UpdateZoom(-1)
      end
   end

   -- Zoom In
   local bX = gfx.w - gui.entryIndent - (gui.entryIndent / 2) - bW * 2

   gfx.set(table.unpack(gui.buttonColor))
   gfx.rect(bX, bY, bW, bH, true)
   gfx.set(1, 1, 1)
   local strW, strH = gfx.measurestr("+")
   gfx.x = bX + (bW - strW) / 2
   gfx.y = bY + (bH - strH) / 2
   gfx.drawstr("+")


   if gui.leftClick and IsPointInRect(bX, bY, bW, bH, gui.lastClickDownPos.x, gui.lastClickDownPos.y) and not gui.leftClickHandled then
      if reaper.JS_Mouse_GetState(16) == 16 then --alt is held
         UpdateZoom(0, 0)
      else
         UpdateZoom(1)
      end
   end

   if not gui.leftClick then
      gui.leftClickHandled = false
      gui.lastZoomTime = 0
   end
end

function HandleDraggingEntry()
   if #setlist < 2 then return end

   if gui.leftClick then
      gui.dragThreshReached = math.abs(gfx.mouse_y - gui.lastClickDownPos.y) > gui.dragThreshold
   end

   if not gui.draggingEntry and gui.leftClick and not gui.draggingScroll and gui.dragThreshReached then
      local entryUnderMouse, idxUnderMouse = FindEntryUnderMouseCursor(true)

      if not entryUnderMouse then return end

      gui.dragEntryListIdx = idxUnderMouse
      gui.dragStartY = gfx.mouse_y
      gui.draggingEntry = true
      Msg("Draging initialized for project: " .. setlist[gui.dragEntryListIdx].name)
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
            gui.scrollOffset = math.floor(gui.scrollOffset + gui.fractionalScrollOffset * gui.dragDirection)
            gui.scrollOffset = Clamp(gui.scrollOffset, 0, gui.maxScroll)
            gui.fractionalScrollOffset = 0

            Msg(gui.scrollOffset)
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

   Msg("  Dropped [" .. gui.dragEntryListIdx .. "] at listIdx [" .. gui.dropIdx .. "]")

   -- Perform the swap only if the target index has changed
   if gui.dropIdx == gui.dragEntryListIdx then return end

   local dragEntry = setlist[gui.dragEntryListIdx]

   if gui.dragDirection == 1 then
      gui.dropIdx = gui.dropIdx + 1
   end

   if dragEntry.type == "text" and reaper.JS_Mouse_GetState(4) == 4 then --ctrl is held
      Msg("Duplicating Text Item: " .. dragEntry.name)
      local duplicateText = CopyTable(dragEntry)
      duplicateText.listIdx = gui.dropIdx
      table.insert(setlist, gui.dropIdx, duplicateText)
      Msg("Inserted duplicate at idx " .. duplicateText.listIdx)
      goto finalizeDrop
   elseif dragEntry.type == "project" then
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
   UpdateTabAndListIdx()
   SaveSetlistToExtState()

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

function HandleEntryClick()
   if (gui.leftClickHandled and gui.rightClickHandled) or gui.draggingEntry or gui.draggingScroll then
      return
   end

   local entryUnderMouse, idxUnderMouse = FindEntryUnderMouseCursor(true)

   if not entryUnderMouse then return end

   if gui.leftClick and not gui.leftClickHandled then -- Left-click
      local now = reaper.time_precise()
      local isDouble = gui.lastClickIdx == idxUnderMouse and (now - gui.lastClickTime) <= gui.doubleClickThreshold
      gui.doubleClick = isDouble
      gui.lastClickTime = now
      gui.lastClickIdx = idxUnderMouse


      Msg("Handling single left click on entry at listIdx [" .. idxUnderMouse .. "]")

      if entryUnderMouse.type == "text" then
         if isDouble then
            Msg("Handling double left click on entry at listIdx [" .. idxUnderMouse .. "]")

            local ret, newName = reaper.GetUserInputs("Rename Text Note", 1, "Enter new label:",
               entryUnderMouse.name or "")

            if ret and newName and newName ~= "" then
               entryUnderMouse.name = newName
               gui.dragForbidden = false
            end
         elseif reaper.JS_Mouse_GetState(16) == 16 then --alt is held
            Msg("Deleting Text Entry: " .. entryUnderMouse.name)
            table.remove(setlist, idxUnderMouse)
            UpdateTabAndListIdx()
         end
      elseif entryUnderMouse.type == "project" then
         reaper.SelectProjectInstance(entryUnderMouse.proj)
      end

      --[[
      local modifierPressed = reaper.JS_Mouse_GetState(4) == 4 or reaper.JS_Mouse_GetState(8) == 8 or
          reaper.JS_Mouse_GetState(16) == 16 --ctrl, alt or shift is held ]]

      gui.leftClickHandled = true
   end


   if gui.rightClick and not gui.rightClickHandled then -- Right-click
      Msg("Handling right click on entry " .. entryUnderMouse.name .. " at index " .. idxUnderMouse)
      if entryUnderMouse.type == "text" then
         -- Show right-click menu
         gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
         local choice = gfx.showmenu("#-- " .. entryUnderMouse.name .. "||Rename|Color Entry|Duplicate|Delete Text Entry")
         if choice == 2 then
            local ret, newName = reaper.GetUserInputs("Rename Text Note", 1, "Enter new label:",
               entryUnderMouse.name or "")
            if ret and newName and newName ~= "" then
               entryUnderMouse.name = newName
            end
         elseif choice == 3 then
            local retval, color = reaper.GR_SelectColor(reaper.GetMainHwnd())
            if retval then
               local r, g, b = reaper.ColorFromNative(color)
               r, g, b = RgbaIntToFloat(r, g, b)
               Msg("Text Highlight set to color: " .. r .. "," .. g .. "," .. b)
               entryUnderMouse.highlight = { r, g, b, 0.4 }
            end
         elseif choice == 4 then
            Msg("Duplicating Text Item: " .. entryUnderMouse.name)
            local duplicateText = CopyTable(entryUnderMouse)
            duplicateText.listIdx = entryUnderMouse.listIdx + 1
            table.insert(setlist, entryUnderMouse.listIdx + 1, duplicateText)
         elseif choice == 5 then
            table.remove(setlist, idxUnderMouse)
            UpdateTabAndListIdx()
         end
         gui.rightClickHandled = true
      elseif entryUnderMouse.type == "project" then
         -- Show right-click menu
         gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
         local choice = gfx.showmenu("#" ..
            entryUnderMouse.tabIdx .. ". " .. entryUnderMouse.name .. "||Queue Project||Replace Project|Close Project")

         if choice == 2 then -- move project to the tab that is gonna play next
            local nextProjTabIdx = GetProjTabIdx(currentProj) + 1
            MoveProjTabToIdx(entryUnderMouse.proj, nextProjTabIdx)
            UpdateListOrderFromOpenProjects(setlist)
         elseif choice == 3 then
            ReplaceProjEntry(setlist, entryUnderMouse)
         elseif choice == 4 then
            CloseProject(entryUnderMouse.proj)
         end
         gui.rightClickHandled = true
      elseif entryUnderMouse.type == "missing" then
         -- Show right-click menu
         gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
         local choice = gfx.showmenu("#MISSING||Find Project|Remove Project")

         if choice == 2 then -- move project to the tab that is gonna play next
            ReplaceProjEntry(setlist, entryUnderMouse)
         elseif choice == 3 then
            Msg("Removing [" .. entryUnderMouse.listIdx .. "]: " .. entryUnderMouse.path)

            table.remove(setlist, entryUnderMouse.listIdx)
            UpdateTabAndListIdx(setlist)
         end
         gui.rightClickHandled = true
      end
   end
end

function HandleMouseScroll()
   if gfx.mouse_wheel ~= 0 then
      gui.scrollOffset = math.floor(gui.scrollOffset - gfx.mouse_wheel / 100)
      gfx.mouse_wheel = 0
   end
   gui.scrollOffset = Clamp(gui.scrollOffset, 0, gui.maxScroll)
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
      Msg("Scrolling to scrollOffset: " .. gui.scrollOffset)
   end
end

function DrawScrollbar()
   local setlistLenght = #setlist
   if setlistLenght <= gui.numVisibleEntries then return end

   local scrollTrackHeight = gui.listH + gui.titleHeight
   gui.scrollH = scrollTrackHeight * (gui.numVisibleEntries / setlistLenght)
   gui.scrollY = (gui.scrollOffset / gui.maxScroll) * (scrollTrackHeight - gui.scrollH)

   -- Scroll Track
   gfx.set(table.unpack(gui.scrollTrackColor))
   gfx.rect(gfx.w - gui.scrollW, 0, gui.scrollW, scrollTrackHeight)

   -- Scroll Thumb
   gfx.set(table.unpack(gui.scrollThumbColor))
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
   elseif gui.isNextProj and entry.type == "project" then
      highlight = gui.nextProjHighlight
      gui.isNextProj = false
   end

   if not highlight then
      highlight = gui.entryHighlights[entry.type]
   end

   if highlight ~= 0 then
      gfx.set(table.unpack(highlight))
      gfx.rect(gui.leftBorder, y + 2, gfx.w - gui.scrollW, gui.lineHeight - 4)
   end

   gfx.set(1, 1, 1, 0.3)
   gfx.line(gui.leftBorder, y + gui.lineHeight, gfx.w - gui.scrollW, y + gui.lineHeight - 1)

   -------------------
   -- draw entry text
   local textColor
   local entryStr
   gfx.x = gui.leftBorder + gui.entryIndent
   gfx.setfont(1, gui.font, gui.entryTextSize)
   if entry.type == "project" then
      textColor = gui.projectEntryColor
      local displayIdx = tostring(displayTabIdx and entry.tabIdx or entry.listIdx)
      displayIdx = PadNumberStringWithZeroes(displayIdx, math.floor(math.log(openProjCount, 10) + 1)) .. ". "

      --draw selected project indicator
      if entry.proj == currentProj then
         gfx.set(1, 1, 1, 1)
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
   elseif entry.type == "text" then
      textColor = gui.textEntryColor
      entryStr = "--  " .. (entry.name or "")
   elseif entry.type == "missing" then
      textColor = gui.textEntryColor
      entryStr = "?  " .. (entry.name or "")
   end


   local _, strH = gfx.measurestr(entryStr)
   gfx.y = y + (gui.lineHeight - strH) / 2

   if textColor and entryStr then
      gfx.set(table.unpack(textColor))
      gfx.drawstr(entryStr)
   end

   ----------------------
   --Project Length Stuff
   if entry.type == "project" then
      if entry.name:find("_.*ROUTING") then return end

      -- proj length
      local projLen = GetProjectLengthFromMarker(entry.proj)

      local projLenStr = FormatTimeMMSS(projLen)

      gfx.setfont(1, gui.font, gui.projLenTextSize)
      local strW, strH = gfx.measurestr(projLenStr)
      gfx.x = gfx.w - gui.scrollW - strW - gui.entryIndent
      gfx.y = y + (gui.lineHeight - strH) / 2

      gfx.drawstr(projLenStr)
   end
end

function DisplaySetlist()
   gfx.clear = gui.backgroundColor

   -- Draw Title
   gfx.x = 0
   gfx.y = 0
   gfx.setfont(1, gui.font, gui.titleTextSize)
   gfx.set(table.unpack(gui.nextProjHighlight))
   gfx.rect(3, 3, gfx.w - 6, gui.titleHeight - 12)
   gfx.set(table.unpack(gui.projectEntryColor))
   gfx.drawstr("REAPER SETLIST", 5, gfx.w, gui.titleHeight - 6)

   -- Draw Entries

   for i = 1, gui.numVisibleEntries do
      local idx = i + gui.scrollOffset

      if idx > #setlist then break end

      local y = gui.titleHeight + (i - 1) * gui.lineHeight

      DrawListEntry(y, setlist[idx])
   end

   gui.isNextProj = false
   gui.currProjDrawn = false

   -- Draw Total Setlist Time

   local time = FormatTimeMMSS(setlistTotalTime)
   local str = "Total Setlist Time: " .. time

   gfx.setfont(1, gui.font, gui.projLenTextSize - gui.zoomLevel / 2)

   local strW, strH = gfx.measurestr(str)

   gfx.x = gfx.w - gui.entryIndent - strW
   gfx.y = gfx.h - gui.ctrlPanelSize + gui.entryIndent * 0.7
   gfx.drawstr(str)

   -- draw ctrlPanel divider
   gfx.set(1, 1, 1, 0.6)
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
         gfx.set(table.unpack(gui.dropIndicatorColor))
         gfx.rect(5, dropYstart - 2, gfx.w - 10, gui.dropIndicatorThickness)
      end
   end
end

function InitWnd()
   local state = reaper.JS_Mouse_GetState(4) -- check if ctrl key is pressed
   if state == 4 then
      Msg("Script started with ctrl pressed")
   end


   if state ~= 4 then
      LoadWndStateFromExt()
   end

   gfx.init(scriptName, gui.ww, gui.wh, gui.dockState, gui.wx, gui.wy) -- title, width, height, dockstate, x, y
   UpdateZoom(0, gui.zoomLevel)
   gfx.setfont(1, gui.font, gui.entryTextSize)                         -- Set the font for the list (index 1, size 16)
   gui.lineHeight = gfx.texth + gui.linePadding
   gui.minHeight = gui.ctrlPanelSize + gui.titleHeight + gui.lineHeight * 3
   gui.minWidth = gui.buttownW * 3 + gui.entryIndent + 5
end

--------------------------
------- MAIN FLOW --------
--------------------------

function Main()
   if gfx.getchar() < 0 or terminate then
      gfx.quit()
      Msg("Terminating " .. scriptName)
   else
      lastProject = currentProj
      currentProj = reaper.EnumProjects(-1)

      CountOpenProjects()

      local numProjInList = #GetProjEntriesInList(setlist)
      if openProjCount ~= numProjInList then
         setlist = ResolveConflictsWithOpenProj(setlist, true)
      elseif setlist[0] then
         local i = 0
         while true do
            local proj = reaper.EnumProjects(i)
            if setlist[i].proj ~= proj then --only update setlist order if openProj and Setlist are different
               UpdateListOrderFromOpenProjects(setlist)
            end
            i = i + 1
            if not proj then break end
         end
      end

      gui.prevRightClick = gui.rightClick
      gui.rightClick = gfx.mouse_cap & 2 > 0 or false
      if gui.rightClick and not gui.prevRightClick then
         gui.lastClickDownPos = { ["x"] = gfx.mouse_x, ["y"] = gfx.mouse_y }
      end

      gui.prevLeftClick = gui.leftClick
      gui.leftClick = gfx.mouse_cap & 1 > 0 or false
      if gui.leftClick and not gui.prevLeftClick then
         Msg("Left click detected at position: " .. gfx.mouse_x .. "," .. gfx.mouse_y)
         gui.lastClickDownPos = { ["x"] = gfx.mouse_x, ["y"] = gfx.mouse_y }
      end



      if gfx.mouse_cap == 0 then
         gui.draggingScroll = false
         gui.leftClickHandled = false
         gui.rightClickHandled = false
      end


      gui.listH = gfx.h - gui.ctrlPanelSize - gui.titleHeight
      gui.numVisibleEntries = math.floor(gui.listH / gui.lineHeight)
      gui.maxScroll = math.max(0, #setlist - gui.numVisibleEntries)

      if #setlist <= gui.numVisibleEntries and gui.scrollOffset ~= 0 then
         gui.scrollOffset = 0
         Msg("Scroll set to 0 because all entries are visible.")
      elseif lastProject ~= currentProj or not projectSwitchHandled then
         Msg("Project switch detected.")
         projectSwitchHandled = false
         if gui.leftClick or gui.draggingEntry then goto delayProjSwitchHandling end

         if (not IsProjVisibleInList(currentProj) or not IsProjVisibleInList(GetProjTabIdx(currentProj) + 1)) and not projectSwitchHandled then
            gui.scrollOffset = TabIdxToListIdx(GetProjTabIdx(currentProj) + 1) - math.floor(gui.numVisibleEntries)

            -- Make sure we prioritize showing the current project if both current and next are not visible
            local currProjListIdx = TabIdxToListIdx(GetProjTabIdx(currentProj))
            if currProjListIdx < gui.scrollOffset + 1 then
               gui.scrollOffset = currProjListIdx - 1
            end

            gui.scrollOffset = Clamp(gui.scrollOffset, 0, gui.maxScroll)

            Msg("Scrolling to make active entry visible at scrollOffset: " .. gui.scrollOffset)
         end
         projectSwitchHandled = true
      end
      ::delayProjSwitchHandling::

      HandleScrollbarClick()
      HandleMouseScroll()
      DisplaySetlist()
      DrawScrollbar()

      gfx.setfont(1, gui.font, gui.buttonTextSize) -- Set the font for the buttons
      HandleSaveListButton()
      HandleLoadListButton()
      HandleInsertTextButton()
      gfx.setfont(1, gui.font, gui.entryTextSize) -- Set the font for the list (index 1, size 16)


      HandleEntryClick()
      HandleDraggingEntry()

      HandleZoomButtons()

      gfx.update()
      reaper.defer(Main)
   end
end

function Init()
   if not CheckDependencies() then return end

   reaper.set_action_options(1)

   CountOpenProjects()

   local state = reaper.JS_Mouse_GetState(8) -- check if shift key is pressed
   if state == 8 then
      Msg("Script started with shift pressed")
   end

   if state ~= 8 then
      setlist = LoadSetlistFromExtState()
   end

   if not next(setlist) then
      Msg("EXT_STATE setlist empty, building from scratch.")
      setlist = GetOpenProjectList()
   end

   --table.insert(setlist, {
   --   name = "this is da text",
   --   path = "this is da text",
   --   proj = nil,
   --   listIdx = #setlist + 1, -- position in setlist, 1 based
   --   idx = nil,              -- project tab position if type is project
   --   type = "text"
   --})



   if debug then
      Msg("Setlist after Init: ")
      PrintListPaths(setlist)
   end

   InitWnd()

   Main()
end

Init()

reaper.atexit(
   function()
      if not terminate then
         SaveWndStateToExt()
         SaveSetlistToExtState()
      end
   end
)
