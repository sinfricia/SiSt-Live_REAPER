-- @noindex
-- SiSt-Live logging and debug-flag library.
--
--   local Log = require("SiSt-Live_Log")
--   local log = Log.get("Setlist")           -- one logger per component
--   log:debug("loaded %d items", n)          -- shown only when debug is ON
--   log:warn("..."), log:error("...")        -- always shown
--
-- The debug flag lives in ExtState (not persisted), so every script sees the
-- same switch and REAPER always starts with debug OFF.
-- The flag is cached for Log.CACHE_TTL seconds, so frequent log calls (e.g. in
-- a defer loop) don't hit ExtState every time. Changes made from another
-- script show up within that window; Log.refresh() forces a re-read.
-- Output goes through a replaceable "sink", which is what makes the logger
-- testable. The default sink writes every line to two places:
--   console  the REAPER console (View > ReaScript console output)
--   file     <resource path>/Data/SiSt-Live/SiSt-Live.log, shared by all SiSt-Live scripts.
--            When it grows past Log.FILE_MAX_BYTES it is renamed to SiSt-Live.old.log and a
--            new one is started, so it never grows without limit. If the file can't be
--            written, file logging stops for that script (see Log.diagnostics()).
--
-- Stage guard: printing to the console opens the console window. In show mode that must
-- not happen on stage, so warnings and errors are NOT printed to the console in show mode
-- (they still go to the file). Debug output is the exception: if you turned debug logging
-- on yourself, everything is printed, also in show mode.

local Button = require("SiSt-Live_Button")

local Log = {}

Log.SECTION   = "SiSt-Live"
Log.KEY_DEBUG = "debug"
Log.LEVELS    = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

-- Stage guard (pure) -----------------------------------------------------
-- The mode lives in the Mode library, which itself needs this one, so it is read here
-- directly. Keep these two in step with Mode.SECTION / Mode.KEY_MODE / Mode.SHOW.
Log.MODE_SECTION = "SiSt-Live"
Log.MODE_KEY     = "mode"
Log.MODE_SHOW    = "show"

--- Pure. May this line be printed to the console? Everything that is emitted, except
--- warnings/errors in show mode while debug logging is off (they would open the console).
function Log.console_allowed(debug_on, mode)
  return debug_on or mode ~= Log.MODE_SHOW
end

-- File (pure apart from io) ------------------------------------------------
Log.FILE_DIR       = "SiSt-Live"         -- below <resource path>/Data
Log.FILE_NAME      = "SiSt-Live.log"
Log.FILE_OLD_NAME  = "SiSt-Live.old.log"
Log.FILE_MAX_BYTES = 1024 * 1024

--- Pure. One line of the log file.
function Log.format_file_line(time, rec)
  return ("%s %-5s [%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S", time), rec.level_name, rec.ns, rec.msg)
end

--- Appends one line to path. If the file is already max_bytes or larger, it is first renamed
--- to old_path (replacing an older one). Returns true, or false + error message.
function Log.append_line(path, old_path, line, max_bytes)
  local f, err = io.open(path, "ab")
  if not f then return false, err end
  local size = f:seek("end") or 0
  if size >= max_bytes then
    f:close()
    os.remove(old_path)
    local ok, rename_err = os.rename(path, old_path)
    if not ok then return false, rename_err end
    f, err = io.open(path, "ab")
    if not f then return false, err end
  end
  local ok, write_err = f:write(line)
  f:close()
  if not ok then return false, write_err end
  return true
end

local file = { path = nil, old_path = nil, error = nil, dir_made = false }

local function default_file_paths()
  local sep = package.config:sub(1, 1)
  local dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. Log.FILE_DIR
  return dir, dir .. sep .. Log.FILE_NAME, dir .. sep .. Log.FILE_OLD_NAME
end

--- Full path of the log file.
function Log.file_path()
  if file.path then return file.path end
  local _, path = default_file_paths()
  return path
end

--- Write the log file somewhere else (tests). nil goes back to the default.
function Log.set_file_path(path)
  file.path = path
  file.old_path = path and (path:gsub("%.log$", "") .. ".old.log") or nil
  file.error = nil
end

local function file_sink(rec)
  if file.error then return end -- failed once: don't try on every line
  local path, old_path = file.path, file.old_path
  if not path then
    local dir
    dir, path, old_path = default_file_paths()
    if not file.dir_made then
      reaper.RecursiveCreateDirectory(dir, 0)
      file.dir_made = true
    end
  end
  local ok, err = Log.append_line(path, old_path, Log.format_file_line(os.time(), rec), Log.FILE_MAX_BYTES)
  if not ok then file.error = tostring(err) end
end

-- Sink ------------------------------------------------------------------
local function console_sink(rec)
  if rec.level >= Log.LEVELS.WARN
      and not Log.console_allowed(rec.debug_on, reaper.GetExtState(Log.MODE_SECTION, Log.MODE_KEY)) then
    return
  end
  reaper.ShowConsoleMsg(("[%s] %-5s [%s] %s\n"):format(
    os.date("%H:%M:%S"), rec.level_name, rec.ns, rec.msg))
end

local function default_sink(rec)
  pcall(file_sink, rec) -- a broken file must never stop the console line
  console_sink(rec)
end

local sink = default_sink

--- Replace the output target. fn(record) with record = {level, level_name, ns, msg, debug_on}.
--- Replaces console AND file (tests use it to capture or silence everything).
--- Call with nil to restore the default (console + file).
function Log.set_sink(fn) sink = fn or default_sink end

-- Debug flag (cached) ---------------------------------------------------
Log.CACHE_TTL = 0.25 -- seconds

local cache = { value = false, stamp = nil }

local function read_debug(force)
  local now = reaper.time_precise()
  if force or not cache.stamp or now < cache.stamp or now - cache.stamp >= Log.CACHE_TTL then
    cache.value = reaper.GetExtState(Log.SECTION, Log.KEY_DEBUG) == "1"
    cache.stamp = now
  end
  return cache.value
end

function Log.is_debug() return read_debug(false) end

--- Bypass the cache and re-read the flag from ExtState.
function Log.refresh() return read_debug(true) end

--- Minimum level that is emitted right now.
function Log.get_level()
  return Log.is_debug() and Log.LEVELS.DEBUG or Log.LEVELS.WARN
end

--- Only writer of the debug flag; keeps cache and toolbar button in sync.
function Log.set_debug(on)
  on = on and true or false
  local was = read_debug(true)
  if was and not on then Log.get("Log"):debug("debug logging disabled") end
  reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, on and "1" or "0", false)
  cache.value, cache.stamp = on, reaper.time_precise()
  Button.set_state("debug", on)
  if on and not was then Log.get("Log"):debug("debug logging enabled") end
end

function Log.toggle_debug()
  Log.set_debug(not read_debug(true))
  return cache.value
end

-- Formatting ------------------------------------------------------------
-- Never lets a bad format string or odd argument crash the caller.
local function format_message(fmt, ...)
  local n = select("#", ...)
  if n == 0 then return tostring(fmt) end
  local args = { ... }
  for i = 1, n do
    local t = type(args[i])
    if t ~= "number" and t ~= "string" then args[i] = tostring(args[i]) end
  end
  local ok, res = pcall(string.format, tostring(fmt), table.unpack(args, 1, n))
  if ok then return res end
  return tostring(fmt) .. " [format error: " .. tostring(res) .. "]"
end

local function emit(level, ns, ...)
  local debug_on = Log.is_debug()
  if level < (debug_on and Log.LEVELS.DEBUG or Log.LEVELS.WARN) then return end
  pcall(sink, {
    level = level,
    level_name = LEVEL_NAMES[level],
    ns = ns,
    msg = format_message(...),
    debug_on = debug_on,
  })
end

-- Loggers ---------------------------------------------------------------
local Logger = {}
Logger.__index = Logger
for name, level in pairs(Log.LEVELS) do
  Logger[name:lower()] = function(self, ...) emit(level, self.ns, ...) end
end

local loggers = {}

--- Get (or create) the logger for a component name.
function Log.get(ns)
  if not loggers[ns] then loggers[ns] = setmetatable({ ns = ns }, Logger) end
  return loggers[ns]
end

-- Error guard -----------------------------------------------------------
--- Run fn(...) and log failures (with stack trace) instead of crashing.
--- Success: returns true, <fn results...>.  Failure: returns false, message.
function Log.safe_call(logger, label, fn, ...)
  local r = table.pack(xpcall(fn, function(err)
    return debug.traceback(tostring(err), 2)
  end, ...))
  if r[1] then return table.unpack(r, 1, r.n) end
  logger:error("%s failed: %s", label, r[2])
  return false, r[2]
end

-- Diagnostics & self-test -------------------------------------------------
--- Ordered { label, value } rows for the diagnostics action.
function Log.diagnostics()
  return {
    { "debug logging", Log.refresh() and "ON" or "OFF" },
    { "min level",     LEVEL_NAMES[Log.get_level()] },
    { "cache TTL",     Log.CACHE_TTL .. " s" },
    { "debug button",  Button.describe("debug") },
    { "log file",      Log.file_path() .. (file.error and ("  (NOT WRITTEN: " .. file.error .. ")") or "") },
  }
end

--- Built-in self-test against the real REAPER API. Saves and restores the
--- debug flag. Returns a list of { name, ok }.
function Log.self_test()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local saved = reaper.GetExtState(Log.SECTION, Log.KEY_DEBUG)
  local records = {}
  Log.set_sink(function(rec) records[#records + 1] = rec end)
  local t = Log.get("SelfTest")

  Log.set_debug(false)
  t:debug("hidden")
  t:warn("shown")
  check("debug off: debug suppressed, warn emitted",
    #records == 1 and records[1].level_name == "WARN")

  Log.set_debug(true)
  check("set_debug(true) visible immediately (cache updated)", Log.is_debug() == true)
  records = {}
  t:debug("x=%d", 5)
  check("debug on: debug emitted and formatted", #records == 1 and records[1].msg == "x=5")

  local ok = pcall(t.warn, t, "%d", "not a number")
  check("bad format string does not throw", ok)

  reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, "0", false)
  check("refresh() picks up external change", Log.refresh() == false)

  check("safe_call returns false on error",
    select(1, Log.safe_call(t, "selftest", function() error("boom") end)) == false)

  -- stage guard
  check("stage guard: edit mode prints", Log.console_allowed(false, "edit") and Log.console_allowed(false, ""))
  check("stage guard: show mode doesn't print warnings", not Log.console_allowed(false, "show"))
  check("stage guard: debug on prints in show mode", Log.console_allowed(true, "show"))

  -- file: a test file in the resource folder, never the real log
  local sep = package.config:sub(1, 1)
  local path = reaper.GetResourcePath() .. sep .. "SiSt-Live_logtest_" .. os.time() .. ".log"
  local old = path:gsub("%.log$", "") .. ".old.log"
  local function read(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local text = f:read("a"); f:close(); return text
  end
  check("file: first line creates the file", Log.append_line(path, old, "one\n", 100) and read(path) == "one\n")
  Log.append_line(path, old, "two\n", 100)
  check("file: lines are appended", read(path) == "one\ntwo\n")
  check("file: rotated when full", Log.append_line(path, old, "three\n", 5) and read(old) == "one\ntwo\n"
    and read(path) == "three\n")
  Log.append_line(path, old, "four\n", 5)
  check("file: older rotation is replaced", read(old) == "three\n" and read(path) == "four\n")
  check("file: unwritable location reports failure",
    not Log.append_line(sep .. "selftest-no-such-dir" .. sep .. "x.log", sep .. "selftest-no-such-dir" .. sep .. "y.log", "x", 100))
  os.remove(path); os.remove(old)
  local line = Log.format_file_line(0, { level_name = "WARN", ns = "T", msg = "m" })
  check("file: line has date, level, component", line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d WARN  %[T%] m\n$") ~= nil)

  -- restore original state
  Log.set_sink(nil)
  if saved == "" then
    reaper.DeleteExtState(Log.SECTION, Log.KEY_DEBUG, false)
  else
    reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, saved, false)
  end
  Button.set_state("debug", Log.refresh())

  return results
end

return Log
