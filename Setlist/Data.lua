-- @noindex
--[[
SiSt-Live Setlist: Data

The list as data, and the files it lives in. Everything here is about entries, not about the window or the tabs:
no drawing, no clicks, no REAPER project tabs (Sync.lua does that). The Setlist script owns the list itself and passes it
in; nothing in this file keeps state of its own, except the "warn once" flag of the save error.

  Entries      { type = "project" | "text" | "missing", name, path, proj, listIdx, tabIdx, highlight, ... }
  Paths        normalize_path, sanitize_path, project_name, find_next_to_setlist
  Text format  list_to_text, text_to_list (the .rsl format: "key=value; key=value;" per line, values percent-encoded)
  Files        the current list and the autosave in the REAPER Data folder, the atomic write, the startup decision
  List         project_entries, update_indexes, tab_to_list_idx, list_to_tab_idx, describe_list, format_time

Two files in the REAPER resource folder (separate from the user's own setlist files, which only "Save" writes):
  CURRENT LIST  the live state of the Setlist, written after every change, so it survives closing and reopening.
  AUTOSAVE      a list that was replaced (Reset, Restore, Load, or the first start in a new REAPER run), kept so
                "Restore" can bring it back. Written only at those moments.

Self test: Data.self_test() returns a list of { name, ok }.
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")

local Data = {}

Data.ENTRY = { PROJECT = "project", TEXT = "text", MISSING = "missing" }
local ENTRY = Data.ENTRY

Data.EXT_SECTION = "SiSt-Live_Setlist" -- also the ExtState section of the Window (its "WindowState" key)
local EXT_SECTION = Data.EXT_SECTION
local EXT_SESSION_MARKER = "StartedInThisSession" -- never persisted: empty again after a REAPER restart
local EXT_TEST_MODE = "TestMode"                  -- set by the live test: the saved lists are neither read nor written

local CURRENT_FILENAME = "SiSt-Live_Setlist_current.rsl"
local AUTOSAVE_FILENAME = "SiSt-Live_Setlist_autosave.rsl"
local autosave_error_shown = false

-- Fields that only make sense while the script is running and are rebuilt on load
local TRANSIENT_FIELDS = { proj = true, listIdx = true, tabIdx = true }

-- File functions used by write_text_atomic. Tests pass a fake one.
local REAL_FS = { open = io.open, rename = os.rename, remove = os.remove }

-- Paths -------------------------------------------------------------------------------------------

function Data.normalize_path(path)
   if not path then return "" end

   if type(path) ~= "string" then return path end

   path = path:gsub("\\", "/")

   if #path > 1 then
      path = path:gsub("/+$", "")
   end
   return path
end

function Data.sanitize_path(path)
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

function Data.project_name(path)
   if not path:find("[\\/]") then return path end
   local fileName = path:match("([^\\/]+)$")
   if not fileName then return path end -- path ends with a separator
   fileName = fileName:gsub("%.[rR][pP][pP]$", "")
   return fileName
end

function Data.find_next_to_setlist(loadPath, projPath)
   loadPath = Data.normalize_path(loadPath)
   projPath = Data.normalize_path(projPath)

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

-- Text format ----------------------------------------------------------------------------

-- Characters that would break the "key=value; key=value;" format are stored as %XX.
local function encode_value(str)
   return (str:gsub("[%%;={}\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decode_value(str)
   return (str:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function Data.serialize_entry(entry)
   local parts = { "enc=1" } -- marker: values below are percent-encoded (older saves have no marker)

   for k, v in pairs(entry) do
      if not TRANSIENT_FIELDS[k] then
         local valueType = type(v)
         if valueType == "string" then
            if k == "path" and entry.type ~= ENTRY.TEXT then
               v = Data.normalize_path(v)
            end
            parts[#parts + 1] = k .. "=" .. encode_value(v)
         elseif valueType == "number" or valueType == "boolean" then
            parts[#parts + 1] = k .. "=" .. encode_value(tostring(v))
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

function Data.list_to_text(list, separator)
   local entryStrings = {}
   log:debug("Creating setlist string:")
   for _, entry in ipairs(list) do
      if entry.path ~= "Unsaved Project" then
         table.insert(entryStrings, Data.serialize_entry(entry))
      end
   end

   return table.concat(entryStrings, separator)
end

-- Parses one serialized entry into a table. Does not validate it.
local function parse_entry(entryStr)
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
            entry[k] = decode_value(v)
         end
      end
   end
   entry.enc = nil

   return entry
end

-- Parses setlist text into entries. Returns the entries and the lines that could not be read.
-- find_proj(path, n): optional, returns the project pointer and tab index of the n-th (0-based) open tab with this
-- path, so entries of open projects get their `proj` and `tabIdx`. Without it, entries have neither.
function Data.text_to_list(setlistStr, separator, find_proj)
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
      local newEntry = parse_entry(entryStr)

      if newEntry.type ~= ENTRY.TEXT then
         newEntry.path = Data.sanitize_path(newEntry.path)
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
         newEntry.proj, newEntry.tabIdx = nil, nil
         if entryType == ENTRY.PROJECT and find_proj then
            newEntry.proj, newEntry.tabIdx = find_proj(path, duplicateTracker[trackerKey])
         end

         if not newEntry.name then
            newEntry.name = Data.project_name(path)
         end

         newEntry.listIdx = #parsedSetlist + 1

         table.insert(parsedSetlist, newEntry)

         log:debug("     " .. entryStr)
         log:debug("     " .. newEntry.name)
      end
   end

   return parsedSetlist, invalidEntries
end

-- Files ----------------------------------------------------------------------------------

local function data_file_path(fileName)
   local sep = package.config:sub(1, 1)
   return reaper.GetResourcePath() .. sep .. "Data" .. sep .. fileName
end

function Data.current_list_path()
   return data_file_path(CURRENT_FILENAME)
end

function Data.autosave_path()
   return data_file_path(AUTOSAVE_FILENAME)
end

function Data.read_text(path)
   local file = io.open(path, "rb")
   if not file then return nil end
   local content = file:read("a")
   file:close()
   return content
end

local function read_with(fs, path)
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
function Data.write_text_atomic(path, content, fs)
   fs = fs or REAL_FS
   local tmpPath, bakPath = path .. ".tmp", path .. ".bak"
   local function isWritten() return read_with(fs, path) == content end
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
   if read_with(fs, path) == nil and read_with(fs, bakPath) ~= nil then fs.rename(bakPath, path) end
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

function Data.is_test_mode()
   return reaper.GetExtState(EXT_SECTION, EXT_TEST_MODE) == "1"
end

-- Writes the current list. Called after every change.
function Data.save_current_list(list)
   if Data.is_test_mode() then
      log:debug("test mode: current list not written")
      return
   end
   log:debug("Saving current list")
   local path = Data.current_list_path()
   reaper.RecursiveCreateDirectory(path:match("^(.*)[\\/][^\\/]*$") or "", 0) -- make sure the Data folder exists
   local ok, err = Data.write_text_atomic(path, Data.list_to_text(list, "\n"))
   if not ok then
      log:warn("saving the current list failed: %s", tostring(err))
      if not autosave_error_shown then -- warn once, not on every change
         autosave_error_shown = true
         reaper.MB("Could not write the current list to:\n" .. path .. "\n\n" .. tostring(err),
            "Setlist: saving failed", 0)
      end
   end
end

-- True if there is an autosave with something in it (an empty file does not count).
function Data.has_autosave()
   local str = Data.read_text(Data.autosave_path())
   return str ~= nil and str:find("%S") ~= nil
end

-- Reads and parses a list file (the current list or the autosave) without touching any projects.
-- Returns parsedEntries, invalidEntryStrings, rawString, sourceDescription. Nothing there: an empty list.
function Data.read_list_file(path, what, find_proj)
   local setlistStr = Data.read_text(path)
   if not setlistStr then return {}, {}, "", what end
   log:debug("Reading the " .. what)
   local list, invalidEntries = Data.text_to_list(setlistStr, "\n", find_proj)
   log:debug("Read " .. #list .. " entries")
   return list, invalidEntries, setlistStr, what
end

-- Pure function. Whether a list that is about to be replaced is worth keeping as the autosave: not an empty one,
-- and not one without text entries when the existing autosave has some (a plain list of projects is easy to
-- rebuild, the text entries are not).
function Data.worth_archiving(list, existingAutosaveList)
   if #list == 0 then return false end
   local function hasText(l)
      for _, e in ipairs(l) do if e.type == ENTRY.TEXT then return true end end
      return false
   end
   if hasText(existingAutosaveList) and not hasText(list) then return false end
   return true
end

-- Keeps the list that is about to be replaced as the autosave (if it is worth it, see Data.worth_archiving).
-- listStr: Data.list_to_text of that list. Returns true if the autosave now holds it.
function Data.archive_list(listStr)
   if Data.is_test_mode() then return false end
   local list = Data.text_to_list(listStr, "\n")
   local existing = Data.read_list_file(Data.autosave_path(), "autosave")
   if not Data.worth_archiving(list, existing) then
      log:info("the replaced list is not worth keeping: the autosave is left as it is")
      return false
   end
   local path = Data.autosave_path()
   reaper.RecursiveCreateDirectory(path:match("^(.*)[\\/][^\\/]*$") or "", 0)
   local ok, err = Data.write_text_atomic(path, listStr)
   if ok then
      log:info("the replaced list is kept as the autosave (%d entries)", #list)
   else
      reaper.MB("Could not write the autosave:\n" .. path .. "\n\n" .. tostring(err), "Setlist: autosave failed", 0)
   end
   return ok
end

-- True if this is the first start of the script since REAPER was opened (non-persistent ExtState marker).
function Data.is_first_run()
   return reaper.GetExtState(EXT_SECTION, EXT_SESSION_MARKER) == ""
end

function Data.mark_session_started()
   reaper.SetExtState(EXT_SECTION, EXT_SESSION_MARKER, "1", false)
end

-- Pure function. What the Setlist starts from: "keep" = the current list (the script was restarted in the same REAPER
-- run), "fresh" = the open projects (first start since REAPER was opened, nothing saved, or test mode).
function Data.startup_action(hasCurrentList, firstRunInSession, testMode)
   if testMode or not hasCurrentList or firstRunInSession then return "fresh" end
   return "keep"
end

-- List operations ------------------------------------------------------------------------

-- Pure function. Short summary of a setlist for dialogs, e.g. "47 entries (25 projects, 22 text entries)".
function Data.describe_list(list)
   local counts = { [ENTRY.PROJECT] = 0, [ENTRY.TEXT] = 0, [ENTRY.MISSING] = 0 }
   for _, entry in ipairs(list) do
      if counts[entry.type] then counts[entry.type] = counts[entry.type] + 1 end
   end

   local str = #list .. " entries (" .. counts[ENTRY.PROJECT] .. " projects, " .. counts[ENTRY.TEXT] .. " text entries"
   if counts[ENTRY.MISSING] > 0 then
      str = str .. ", " .. counts[ENTRY.MISSING] .. " missing"
   end
   return str .. ")"
end

function Data.project_entries(list)
   local projEntriesInList = {}
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         table.insert(projEntriesInList, #projEntriesInList + 1, entry)
      end
   end

   return projEntriesInList
end

-- Sets listIdx (position in the list, 1-based) and tabIdx (position among the project tabs, 0-based) of every entry.
function Data.update_indexes(list)

   local tabIdx = 0
   for i, entry in ipairs(list) do
      entry.listIdx = i

      if entry.type == ENTRY.PROJECT then
         entry.tabIdx = tabIdx
         tabIdx = tabIdx + 1
      end
   end
end

-- The list position of the project entry that belongs to project tab tab_idx (0-based). Before the first tab: 0.
-- Past the last tab: one past the end of the list (where a new project goes).
function Data.tab_to_list_idx(list, tab_idx)
   if tab_idx < 0 then return 0 end
   local tab = 0
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         if tab == tab_idx then return i end
         tab = tab + 1
      end
   end
   return #list + 1
end

-- The project tab index (0-based) that a list position corresponds to: the number of project entries before it.
-- Outside the list (and for 0): tab_count, the position after the last tab.
function Data.list_to_tab_idx(list, list_idx, tab_count)
   if list_idx < 0 then return 0 end
   if list_idx < 1 or list_idx > #list then return tab_count end
   local tab = 0
   for i = 1, list_idx - 1 do
      if list[i].type == ENTRY.PROJECT then tab = tab + 1 end
   end
   return tab
end

function Data.format_time(seconds)
   local minutes = math.floor(seconds / 60)
   local secs    = math.floor(seconds % 60)
   return string.format("%02d:%02d", minutes, secs)
end

function Data.copy_table(tbl)
   if type(tbl) ~= "table" then return tbl end
   local newTbl = {}
   for k, v in pairs(tbl) do
      if type(v) == "table" then
         newTbl[k] = Data.copy_table(v)
      else
         newTbl[k] = v
      end
   end
   return newTbl
end

-- Self test ---------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

-- In-memory file system for Data.write_text_atomic. opts.windows: rename onto an existing file fails.
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

define("Data.format_time", function(t)
   t.eq(Data.format_time(59.9), "00:59", "fraction is floored")
   t.eq(Data.format_time(3600), "60:00", "minutes do not wrap into hours")
end)

define("Data.normalize_path", function(t)
   t.eq(Data.normalize_path("/"), "/", "root stays")
end)

define("Data.project_name", function(t)
   t.eq(Data.project_name("C:\\a\\Song.RPP"), "Song", "windows path, upper case extension")
   t.eq(Data.project_name("Song"), "Song", "no separator is returned as is")
   t.eq(Data.project_name("dir/"), "dir/", "trailing separator does not crash")
end)

define("encode_value / decode_value", function(t)
   local nasty = "Intro = 120bpm; {x}, 100%25\r\nline2"
   local encoded = encode_value(nasty)
   t.ok(not encoded:find("[;={}\r\n]"), "no separator characters survive encoding")
end)

define("Setlist string round trip", function(t)
   local original = {
      { type = ENTRY.TEXT,    name = "Intro = 120bpm; {click}", path = "Intro = 120bpm; {click}",         highlight = { 0.5, 0.25, 0.75, 0.4 } },
      { type = ENTRY.PROJECT, name = "Song A",                  path = "/selftest/nonexistent/Song A.rpp" },
      { type = ENTRY.MISSING, name = "Gone",                    path = "/selftest/nonexistent/Gone.rpp" },
      { type = ENTRY.TEXT,    name = "Back\\slash 100%",        path = "Back\\slash 100%" },
      { type = ENTRY.TEXT,    name = "two\nlines",              path = "two\nlines" },
      { type = ENTRY.PROJECT, name = "Unsaved Project",         path = "Unsaved Project" }, -- must be skipped
   }

   local str = Data.list_to_text(original, "\n")
   local parsed, invalid = Data.text_to_list(str, "\n")

   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 5, "unsaved project is not serialized")
   t.eq(parsed[1].name, original[1].name, "label with = ; { } survives")
   t.eq(parsed[1].highlight, { 0.5, 0.25, 0.75, 0.4 }, "highlight list survives as numbers")
   t.eq(parsed[2].type, ENTRY.PROJECT, "project type")
   t.eq(parsed[2].path, Data.sanitize_path("/selftest/nonexistent/Song A.rpp"), "project path")
   t.eq(parsed[3].type, ENTRY.MISSING, "missing type")
   t.eq(parsed[4].name, "Back\\slash 100%", "backslash and percent in label survive")
   t.eq(parsed[5].name, "two\nlines", "newline in label survives")
end)

define("Legacy setlist format still parses", function(t)
   local legacy = "name=Hello; path=Hello; type=text; listIdx=1; \n" ..
       "path=/old/100%41/Song.rpp; type=project; name=Song; listIdx=2; tabIdx=0; "
   local parsed, invalid = Data.text_to_list(legacy, "\n")
   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 2, "two entries")
   t.eq(parsed[1].name, "Hello", "text name")
   t.eq(parsed[2].path, Data.sanitize_path("/old/100%41/Song.rpp"), "no decoding without the enc marker")
end)

define("Invalid entries are reported, not crashed on", function(t)
   local parsed, invalid = Data.text_to_list("name=orphan; \n", "\n")
   t.eq(#parsed, 0, "nothing valid")
   t.eq(#invalid, 1, "one invalid entry")
   local p2, i2 = Data.text_to_list("", "\n")
   t.eq({ #p2, #i2 }, { 0, 0 }, "empty string")
end)

define("List index <-> tab index", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }

   t.eq(Data.list_to_tab_idx(list, 1, 2), 0, "before the first project: tab 0")
   t.eq(Data.list_to_tab_idx(list, 2, 2), 0, "the first project is tab 0")
   t.eq(Data.list_to_tab_idx(list, 3, 2), 1, "a text entry after it: the next tab")
   t.eq(Data.list_to_tab_idx(list, 4, 2), 1, "the second project is tab 1")
   t.eq(Data.list_to_tab_idx(list, 5, 2), 2, "past the end gives the tab count")
   t.eq(Data.list_to_tab_idx(list, -1, 2), 0, "negative gives 0")
   t.eq(Data.list_to_tab_idx(list, 0, 2), 2, "position 0 is outside the list: the tab count")

   t.eq(Data.tab_to_list_idx(list, 0), 2, "tab 0 is list position 2")
   t.eq(Data.tab_to_list_idx(list, 1), 4, "tab 1 is list position 4")
   t.eq(Data.tab_to_list_idx(list, 2), 5, "past the last tab: one past the end of the list")
   t.eq(Data.tab_to_list_idx(list, -1), 0, "before the first tab: 0")
   t.eq(Data.tab_to_list_idx({}, 0), 1, "empty list: position 1")
end)

define("Data.update_indexes / Data.project_entries", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT } }
   Data.update_indexes(list)
   t.eq({ list[1].listIdx, list[2].listIdx, list[3].listIdx, list[4].listIdx }, { 1, 2, 3, 4 }, "listIdx")
   t.eq({ list[2].tabIdx, list[3].tabIdx }, { 0, 1 }, "tabIdx of projects")
   t.eq(list[1].tabIdx, nil, "text entries have no tabIdx")
   t.eq(#Data.project_entries(list), 2, "two project entries")
end)

define("Atomic file write / read", function(t)
   -- Not os.tmpname(): on Windows that points at the drive root, which is usually not writable
   local path = reaper.GetResourcePath() .. package.config:sub(1, 1) .. "SiSt-Live_selftest_" .. os.time() .. ".tmp"
   t.eq(Data.read_text(path .. ".does-not-exist"), nil, "missing file gives nil")

   t.ok(Data.write_text_atomic(path, "first\nversion"), "first write")
   t.ok(Data.write_text_atomic(path, "second"), "overwrite existing file")
   t.eq(Data.read_text(path), "second", "overwritten content")
   t.eq(Data.read_text(path .. ".tmp"), nil, "no .tmp file left behind")

   local ok = Data.write_text_atomic("/selftest/nonexistent-dir/x.rsl", "data")
   t.ok(not ok, "unwritable location reports failure instead of crashing")
   os.remove(path)
end)

define("Atomic write: Windows and sync-client behaviour", function(t)
   local files = { a = "old" }
   t.ok(Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true })), "Windows: target exists")
   t.eq(files.a, "new", "Windows: new content")
   t.eq({ files["a.tmp"], files["a.bak"] }, { nil, nil }, "Windows: no .tmp or .bak left")

   files = { a = "old" }
   t.ok(Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true, liar = true })),
      "rename reports a failure but did move: success")
   t.eq(files.a, "new", "rename that lied: the new content is kept, never deleted")

   files = { a = "old" }
   local ok = Data.write_text_atomic("a", "new", FakeFileSystem(files, { renameFails = true }))
   t.ok(ok, "rename never works: written directly")
   t.eq(files.a, "new", "direct write: new content")

   files = { a = "old" }
   ok = Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true, tmpVanishes = true }))
   t.ok(ok, "the .tmp file vanished: written directly")
   t.eq(files.a, "new", "the .tmp file vanished: new content")

   files = {}
   files = { a = "old" }
   local fs = FakeFileSystem(files, { windows = true, tmpVanishes = true })
   fs.open = (function(open) return function(path, mode)
      if mode == "wb" and path == "a" then return nil, "locked" end -- the direct write is refused too
      return open(path, mode)
   end end)(fs.open)
   t.ok(not Data.write_text_atomic("a", "new", fs), "nothing works: failure is reported")
   t.eq(files.a, "old", "nothing works: the old file is back in place")

   files = {}
   t.ok(Data.write_text_atomic("a", "first", FakeFileSystem(files, { windows = true })), "no old file yet")
   t.eq(files.a, "first", "no old file yet: written")
end)

define("Data.startup_action", function(t)
   t.eq(Data.startup_action(true, true, false), "fresh", "first start after opening REAPER: the open projects")
   t.eq(Data.startup_action(true, false, false), "keep", "restart in the same REAPER run: the list is kept")
   t.eq(Data.startup_action(false, false, false), "fresh", "nothing saved: the open projects")
   t.eq(Data.startup_action(true, false, true), "fresh", "test mode never reads the saved list")
end)

define("Data.worth_archiving", function(t)
   local P = { type = ENTRY.PROJECT, path = "a" }
   local T = { type = ENTRY.TEXT, path = "break" }
   t.ok(not Data.worth_archiving({}, {}), "an empty list is not kept")
   t.ok(Data.worth_archiving({ P }, {}), "a list of projects is kept when there is no autosave")
   t.ok(Data.worth_archiving({ P, T }, { P, T }), "a list with text replaces an autosave with text")
   t.ok(Data.worth_archiving({ P, T }, { P }), "a list with text replaces a plain autosave")
   t.ok(not Data.worth_archiving({ P }, { P, T }), "a plain list never replaces an autosave that has text entries")
end)

define("Data.describe_list", function(t)
   local list = {
      { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
      { type = ENTRY.TEXT },
   }
   list[#list + 1] = { type = ENTRY.MISSING }
   t.eq(Data.describe_list(list), "6 entries (2 projects, 3 text entries, 1 missing)", "missing shown")
end)

function Data.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Data
