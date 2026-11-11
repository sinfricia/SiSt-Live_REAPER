-- @noindex
--[[
SiSt-Live Setlist: Data

The list as data, and the files it lives in. Everything here is about entries, not about the window or the tabs:
no drawing, no clicks, no REAPER project tabs (Sync.lua does that). The Setlist script owns the list itself and passes it
in; nothing in this file keeps state of its own, except the "warn once" flag of the save error.

  Entries      { type = "project" | "text" | "missing", name, path, proj, list_idx, tab_idx, highlight, ... }
  Paths        normalize_path, sanitize_path, project_name, find_next_to_setlist
  Text format  list_to_text, text_to_list (the .rsl format: "key=value; key=value;" per line, values percent-encoded)
  Files        the current list and the autosave in the REAPER Data folder, the atomic write, the startup decision
  List         project_entries, missing_entries, update_indexes, tab_to_list_idx, list_to_tab_idx, describe_list, format_time

Two files in the REAPER resource folder (separate from the user's own setlist files, which only "Save" writes):
  CURRENT LIST  the live state of the Setlist, written after every change, so it survives closing and reopening.
  AUTOSAVE      a list that was replaced (Reset, Restore, Load, or the first start in a new REAPER run), kept so
                "Restore" can bring it back. Written only at those moments.

Tests: Setlist/Tests/Data_test.lua.
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
local TRANSIENT_FIELDS = { proj = true, list_idx = true, tab_idx = true,
   listIdx = true, tabIdx = true } -- (the last two: written by older versions)

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
   local file_name = path:match("([^\\/]+)$")
   if not file_name then return path end -- path ends with a separator
   file_name = file_name:gsub("%.[rR][pP][pP]$", "")
   return file_name
end

function Data.find_next_to_setlist(load_path, proj_path)
   load_path = Data.normalize_path(load_path)
   proj_path = Data.normalize_path(proj_path)

   local load_dir = load_path:match("^(.*)/[^/]*$")
   if not load_dir then return proj_path end

   local proj_dir = proj_path:match("^(.*)/[^/]*$") or ""

   if proj_dir == load_dir then
      return proj_path
   end

   local file_name = proj_path:match("([^/]+)$")
   if not file_name then return proj_path end

   local candidate = load_dir .. "/" .. file_name

   local f = io.open(candidate, "r")
   if f then
      f:close()
      log:debug("Found '" .. file_name .. "' in setlist directory.")
      return candidate -- File found in load_path dir
   else
      return proj_path  -- Fall back to original proj_path
   end
end

-- Text format ----------------------------------------------------------------------------

-- Characters that would break the "key=value; key=value;" format are stored as %XX.
local function encode_value(str)
   return (str:gsub("[%%;={}\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end
Data.encode_value = encode_value -- (used by the tests)

local function decode_value(str)
   return (str:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function Data.serialize_entry(entry)
   local parts = { "enc=1" } -- marker: values below are percent-encoded (older saves have no marker)

   for k, v in pairs(entry) do
      if not TRANSIENT_FIELDS[k] then
         local value_type = type(v)
         if value_type == "string" then
            if k == "path" and entry.type ~= ENTRY.TEXT then
               v = Data.normalize_path(v)
            end
            parts[#parts + 1] = k .. "=" .. encode_value(v)
         elseif value_type == "number" or value_type == "boolean" then
            parts[#parts + 1] = k .. "=" .. encode_value(tostring(v))
         elseif value_type == "table" then -- only flat lists of numbers (e.g. highlight color) are supported
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
   local entry_strings = {}
   log:debug("Creating setlist string:")
   for _, entry in ipairs(list) do
      if entry.path ~= "Unsaved Project" then
         table.insert(entry_strings, Data.serialize_entry(entry))
      end
   end

   return table.concat(entry_strings, separator)
end

-- Parses one serialized entry into a table. Does not validate it.
local function parse_entry(entry_str)
   local entry = {}
   for k, v in entry_str:gmatch("([^; ]+)=([^;]+)") do
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
-- path, so entries of open projects get their `proj` and `tab_idx`. Without it, entries have neither.
function Data.text_to_list(setlist_str, separator, find_proj)
   if setlist_str == "" then
      return {}, {}
   end

   local entry_strings = {}
   for entry_str in string.gmatch(setlist_str, "([^" .. separator .. "]+)") do
      table.insert(entry_strings, entry_str)
   end

   local parsed_setlist = {}
   local duplicate_tracker = {}
   local invalid_entries = {}
   log:debug("   Parsing Setlist string")

   for _, entry_str in ipairs(entry_strings) do
      local new_entry = parse_entry(entry_str)

      if new_entry.type ~= ENTRY.TEXT then
         new_entry.path = Data.sanitize_path(new_entry.path)
      end

      local entry_type = new_entry.type
      local path = new_entry.path

      if not entry_type or not path or entry_type == "" or path == "" then
         table.insert(invalid_entries, entry_str)
         log:warn("invalid setlist entry skipped: %s", entry_str)
      else
         local tracker_key = path
         if entry_type == ENTRY.PROJECT and not path:find("[\\/]") then tracker_key = "" end -- handling unsaved projects

         if duplicate_tracker[tracker_key] then
            duplicate_tracker[tracker_key] = duplicate_tracker[tracker_key] + 1
         else
            duplicate_tracker[tracker_key] = 0
         end

         -- initializing things that are not (or not properly) stored in the setlist string
         new_entry.proj, new_entry.tab_idx = nil, nil
         if entry_type == ENTRY.PROJECT and find_proj then
            new_entry.proj, new_entry.tab_idx = find_proj(path, duplicate_tracker[tracker_key])
         end

         if not new_entry.name then
            new_entry.name = Data.project_name(path)
         end

         if new_entry.type ~= ENTRY.TEXT or (new_entry.link ~= "above" and new_entry.link ~= "below") then
            new_entry.link = nil -- only text entries link, only in these two directions
         end

         new_entry.list_idx = #parsed_setlist + 1

         table.insert(parsed_setlist, new_entry)

         log:debug("     " .. entry_str)
         log:debug("     " .. new_entry.name)
      end
   end

   return parsed_setlist, invalid_entries
end

-- Files ----------------------------------------------------------------------------------

local function data_file_path(file_name)
   local sep = package.config:sub(1, 1)
   return reaper.GetResourcePath() .. sep .. "Data" .. sep .. file_name
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
   local tmp_path, bak_path = path .. ".tmp", path .. ".bak"
   local function is_written() return read_with(fs, path) == content end
   local function cleanup()
      fs.remove(tmp_path)
      fs.remove(bak_path)
   end

   local file, err = fs.open(tmp_path, "wb")
   if not file then return false, "writing " .. tmp_path .. ": " .. tostring(err) end
   local written, write_err = file:write(content)
   file:close()
   if not written then
      fs.remove(tmp_path)
      return false, "writing " .. tmp_path .. ": " .. tostring(write_err)
   end

   -- 1. Straight rename (works everywhere except Windows when the target exists)
   local renamed, rename_err = fs.rename(tmp_path, path)
   if renamed or is_written() then
      cleanup()
      return true
   end

   -- 2. Windows: move the old file aside first, then rename. The old file stays as .bak until the end
   fs.remove(bak_path)
   fs.rename(path, bak_path)
   renamed, rename_err = fs.rename(tmp_path, path)
   if renamed or is_written() then
      cleanup()
      return true
   end

   -- 3. Rename failed: put the old file back (if it was moved), then check again: a rename that reported
   --    a failure may have happened after all
   if read_with(fs, path) == nil and read_with(fs, bak_path) ~= nil then fs.rename(bak_path, path) end
   if is_written() then
      cleanup()
      return true
   end

   -- 4. Last resort: write the content directly into the target (not atomic, but nothing is lost)
   local direct = fs.open(path, "wb")
   if direct then
      local ok = direct:write(content)
      direct:close()
      if ok and is_written() then
         cleanup()
         log:warn("autosave: rename failed (%s), the file was written directly instead", tostring(rename_err))
         return true
      end
   end
   return false, "renaming " .. tmp_path .. " to " .. path .. ": " .. tostring(rename_err)
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

local autosave_present = nil -- read once, then kept up to date where the autosave is written (archive_list)

-- True if there is an autosave with something in it (an empty file does not count). Called every frame (the Restore
-- button): the file is only read the first time.
function Data.has_autosave()
   if autosave_present == nil then
      local str = Data.read_text(Data.autosave_path())
      autosave_present = str ~= nil and str:find("%S") ~= nil
   end
   return autosave_present
end

-- Reads and parses a list file (the current list or the autosave) without touching any projects.
-- Returns parsed_entries, invalid_entry_strings, raw_string, source_description. Nothing there: an empty list.
function Data.read_list_file(path, what, find_proj)
   local setlist_str = Data.read_text(path)
   if not setlist_str then return {}, {}, "", what end
   log:debug("Reading the " .. what)
   local list, invalid_entries = Data.text_to_list(setlist_str, "\n", find_proj)
   log:debug("Read " .. #list .. " entries")
   return list, invalid_entries, setlist_str, what
end

-- Pure function. Whether a list that is about to be replaced is worth keeping as the autosave: not an empty one,
-- and not one without text entries when the existing autosave has some (a plain list of projects is easy to
-- rebuild, the text entries are not).
function Data.worth_archiving(list, existing_autosave_list)
   if #list == 0 then return false end
   local function has_text(l)
      for _, e in ipairs(l) do if e.type == ENTRY.TEXT then return true end end
      return false
   end
   if has_text(existing_autosave_list) and not has_text(list) then return false end
   return true
end

-- Keeps the list that is about to be replaced as the autosave (if it is worth it, see Data.worth_archiving).
-- list_str: Data.list_to_text of that list. Returns true if the autosave now holds it.
function Data.archive_list(list_str)
   if Data.is_test_mode() then return false end
   local list = Data.text_to_list(list_str, "\n")
   local existing = Data.read_list_file(Data.autosave_path(), "autosave")
   if not Data.worth_archiving(list, existing) then
      log:info("the replaced list is not worth keeping: the autosave is left as it is")
      return false
   end
   local path = Data.autosave_path()
   reaper.RecursiveCreateDirectory(path:match("^(.*)[\\/][^\\/]*$") or "", 0)
   local ok, err = Data.write_text_atomic(path, list_str)
   if ok then
      autosave_present = list_str:find("%S") ~= nil
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
function Data.startup_action(has_current_list, first_run_in_session, test_mode)
   if test_mode or not has_current_list or first_run_in_session then return "fresh" end
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

-- How many missing entries the list has, and the list position of the first one (nil if none).
function Data.missing_entries(list)
   local count, first = 0, nil
   for i, entry in ipairs(list) do
      if entry.type == ENTRY.MISSING then
         count = count + 1
         first = first or i
      end
   end
   return count, first
end

function Data.project_entries(list)
   local proj_entries_in_list = {}
   for _, entry in ipairs(list) do
      if entry.type == ENTRY.PROJECT then
         table.insert(proj_entries_in_list, #proj_entries_in_list + 1, entry)
      end
   end

   return proj_entries_in_list
end

-- Sets list_idx (position in the list, 1-based) and tab_idx (position among the project tabs, 0-based) of every entry.
function Data.update_indexes(list)

   local tab_idx = 0
   for i, entry in ipairs(list) do
      entry.list_idx = i

      if entry.type == ENTRY.PROJECT then
         entry.tab_idx = tab_idx
         tab_idx = tab_idx + 1
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

-- Links ----------------------------------------------------------------------------------------------------------
-- A text entry can be linked to the project right above ("above") or right below ("below") it, with only linked text
-- entries in between: the link is the field `link`. The project and its linked text entries are a "block" that moves as one
-- (drag and drop, tab order). A link that does not reach a project (the project was moved away, the entry was dragged
-- somewhere else) is ignored: the entry counts as unlinked.

local function is_linked_text(e, dir)
   return e ~= nil and e.type == ENTRY.TEXT and e.link == dir
end

--- The block of the project entry at position i: first, last list positions (the project and the text entries linked to it).
function Data.link_block(list, i)
   local first, last = i, i
   while first > 1 and is_linked_text(list[first - 1], "below") do first = first - 1 end
   while last < #list and is_linked_text(list[last + 1], "above") do last = last + 1 end
   return first, last
end

--- The block that the entry at position i belongs to (a project entry, or a text entry whose link reaches a project):
--- first, last, position of the project. nil for an entry that is in no block.
function Data.block_of(list, i)
   local e = list[i]
   if not e then return nil end
   if e.type == ENTRY.PROJECT then
      local first, last = Data.link_block(list, i)
      return first, last, i
   end
   if e.type ~= ENTRY.TEXT or not e.link then return nil end
   local step = e.link == "above" and -1 or 1
   local j = i + step
   while is_linked_text(list[j], e.link) do j = j + step end
   if list[j] and list[j].type == ENTRY.PROJECT then
      local first, last = Data.link_block(list, j)
      if i >= first and i <= last then return first, last, j end
   end
   return nil
end

--- The positions that linking the text entry at position i in this direction ("above" / "below") links: the entry and the
--- text entries between it and the project in that direction (they are linked too). nil when no project can be reached
--- through text entries (a missing entry or the end of the list is in the way).
function Data.link_chain(list, i, dir)
   if not list[i] or list[i].type ~= ENTRY.TEXT then return nil end
   local step = dir == "above" and -1 or 1
   local chain, j = { i }, i + step
   while list[j] and list[j].type == ENTRY.TEXT do
      chain[#chain + 1] = j
      j = j + step
   end
   if list[j] and list[j].type == ENTRY.PROJECT then return chain end
   return nil
end

function Data.can_link(list, i, dir)
   return Data.link_chain(list, i, dir) ~= nil
end

--- A text entry that sits between two entries of the same block (a project and its linked text entries) joins that block:
--- it gets the link of the side it is on. Returns true when it did.
function Data.join_block(list, pos)
   local e = list[pos]
   if not e or e.type ~= ENTRY.TEXT then return false end
   for _, dir in ipairs({ "above", "below" }) do
      e.link = dir
      local first, last = Data.block_of(list, pos)
      if first and first < pos and pos < last then return true end -- entries of the block on both sides
   end
   e.link = nil
   return false
end

--- For drawing: a table entry -> { first = bool, last = bool } for every entry in a block of more than one entry.
function Data.linked_rows(list)
   local rows = {}
   for i, e in ipairs(list) do
      if e.type == ENTRY.PROJECT then
         local first, last = Data.link_block(list, i)
         if last > first then
            for k = first, last do rows[list[k]] = { first = k == first, last = k == last } end
         end
      end
   end
   return rows
end

function Data.format_time(seconds)
   local minutes = math.floor(seconds / 60)
   local secs    = math.floor(seconds % 60)
   return string.format("%02d:%02d", minutes, secs)
end

function Data.copy_table(tbl)
   if type(tbl) ~= "table" then return tbl end
   local new_tbl = {}
   for k, v in pairs(tbl) do
      if type(v) == "table" then
         new_tbl[k] = Data.copy_table(v)
      else
         new_tbl[k] = v
      end
   end
   return new_tbl
end

return Data
