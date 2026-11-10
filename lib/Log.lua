-- @noindex
-- Logging library with ONE debug switch for all packages. General: nothing package-specific in here (a future
-- SiSt Libraries module). A package loads it through its own small wrapper that calls Log.configure once
-- (SiSt-Live: lib/SiSt-Live_Log.lua), so its scripts write to the package's log file.
--
--   local Log = require("SiSt-Live_Log")     -- the package's wrapper (returns this module)
--   local log = Log.get("Setlist")           -- one logger per component
--   log:debug("loaded %d items", n)          -- shown only when debug is ON
--   log:warn("..."), log:error("...")        -- always shown
--
-- Two shared flags in ExtState "SiSt Libraries" (not persisted: REAPER always starts with both OFF):
--   debug          the debug switch of every package (Log.set_debug / Log.toggle_debug).
--   quiet_console  warnings and errors go only to the file, not to the console: printing opens the console window,
--                  which must not pop up on stage. A package sets it (SiSt-Live: on in show mode, set by Mode).
--                  Debug output is the exception: if you turned debug logging on yourself, everything is printed.
-- Every log call reads the flags from ExtState (measured 2026-11-10: 0.13 microseconds per call), so a change
-- made by any script shows at once and there is nothing to cache or refresh.
--
-- Output goes through a replaceable "sink", which is what makes the logger
-- testable. The default sink writes every line to two places:
--   console  the REAPER console (View > ReaScript console output)
--   file     <resource path>/Data/<file_dir>/<file_name> (Log.configure; default Data/SiSt Libraries/SiSt Libraries.log).
--            When it grows past Log.FILE_MAX_BYTES it is renamed to <name>.old.log and a
--            new one is started, so it never grows without limit. If the file can't be
--            written, file logging stops for that script (see Log.diagnostics()).
--
-- Log.configure{ file_dir, file_name, on_debug_change(on), diagnostics() }: all optional. on_debug_change runs
-- after every set_debug (e.g. to light a toolbar button); diagnostics returns extra { label, value } rows.

local Log = {}

Log.SECTION   = "SiSt Libraries"
Log.KEY_DEBUG = "debug"
Log.KEY_QUIET = "quiet_console"
Log.LEVELS    = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

-- Stage guard (pure) -----------------------------------------------------
--- Pure. May a warning/error be printed to the console? Yes, unless the console is quiet and debug logging is off.
function Log.console_allowed(debug_on, quiet)
  return debug_on or not quiet
end

-- Configuration -----------------------------------------------------------
local config = {
  file_dir = "SiSt Libraries",       -- below <resource path>/Data
  file_name = "SiSt Libraries.log",
  on_debug_change = nil,
  diagnostics = nil,
}

-- File (pure apart from io) ------------------------------------------------
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

--- Pure. "SiSt-Live.log" -> "SiSt-Live.old.log".
function Log.old_name(name)
  return (name:gsub("%.log$", "")) .. ".old.log"
end

local function default_file_paths()
  local sep = package.config:sub(1, 1)
  local dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. config.file_dir
  return dir, dir .. sep .. config.file_name, dir .. sep .. Log.old_name(config.file_name)
end

--- Set by the package's wrapper, once per script. Every field is optional; fields left out keep their value.
function Log.configure(opts)
  opts = opts or {}
  if opts.file_dir then config.file_dir = opts.file_dir end
  if opts.file_name then config.file_name = opts.file_name end
  if opts.on_debug_change then config.on_debug_change = opts.on_debug_change end
  if opts.diagnostics then config.diagnostics = opts.diagnostics end
  file.dir_made, file.error = false, nil -- a new place gets its own chance
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
  file.old_path = path and Log.old_name(path) or nil
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
--- May this record be printed to the console right now? (Reads the quiet flag.)
function Log.prints(rec)
  return rec.level < Log.LEVELS.WARN or Log.console_allowed(rec.debug_on, Log.is_quiet())
end

local function console_sink(rec)
  if not Log.prints(rec) then return end
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

-- Debug flag ----------------------------------------------------------
function Log.is_debug() return reaper.GetExtState(Log.SECTION, Log.KEY_DEBUG) == "1" end

--- Minimum level that is emitted right now.
function Log.get_level()
  return Log.is_debug() and Log.LEVELS.DEBUG or Log.LEVELS.WARN
end

--- Only writer of the debug flag; then runs the configured on_debug_change (e.g. a toolbar button).
function Log.set_debug(on)
  on = on and true or false
  local was = Log.is_debug()
  if was and not on then Log.get("Log"):debug("debug logging disabled") end
  reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, on and "1" or "0", false)
  if config.on_debug_change then pcall(config.on_debug_change, on) end
  if on and not was then Log.get("Log"):debug("debug logging enabled") end
end

function Log.toggle_debug()
  local on = not Log.is_debug()
  Log.set_debug(on)
  return on
end

-- Quiet console flag --------------------------------------------------
function Log.is_quiet() return reaper.GetExtState(Log.SECTION, Log.KEY_QUIET) == "1" end

--- Only writer of the quiet flag (SiSt-Live: Mode, on in show mode).
function Log.set_quiet_console(on)
  reaper.SetExtState(Log.SECTION, Log.KEY_QUIET, on and "1" or "0", false)
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
  local rows = {
    { "debug logging", Log.is_debug() and "ON" or "OFF" },
    { "quiet console", Log.is_quiet() and "ON (warnings only in the file)" or "OFF" },
    { "min level",     LEVEL_NAMES[Log.get_level()] },
    { "log file",      Log.file_path() .. (file.error and ("  (NOT WRITTEN: " .. file.error .. ")") or "") },
  }
  if config.diagnostics then
    local ok, extra = pcall(config.diagnostics)
    for _, row in ipairs(ok and extra or { { "package rows", "failed: " .. tostring(extra) } }) do rows[#rows + 1] = row end
  end
  return rows
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
  records = {} -- switching off logs "debug logging disabled" if debug was on: not part of this check
  t:debug("hidden")
  t:warn("shown")
  check("debug off: debug suppressed, warn emitted",
    #records == 1 and records[1].level_name == "WARN")

  Log.set_debug(true)
  check("set_debug(true) visible immediately", Log.is_debug() == true)

  local ok = pcall(t.warn, t, "%d", "not a number")
  check("bad format string does not throw", ok)

  reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, "0", false)
  check("is_debug() sees a change made elsewhere at once", Log.is_debug() == false)

  check("safe_call returns false on error",
    select(1, Log.safe_call(t, "selftest", function() error("boom") end)) == false)

  -- stage guard: the quiet flag (fake ExtState, the real flag is never touched)
  local with_reaper = require("SelfTest").with_reaper
  local warn_rec, debug_warn, info_rec = { level = Log.LEVELS.WARN }, { level = Log.LEVELS.ERROR, debug_on = true },
    { level = Log.LEVELS.INFO, debug_on = true }
  local fakes = {}
  check("stage guard: not quiet (REAPER start) prints warnings", with_reaper(fakes, Log.prints, warn_rec))
  with_reaper(fakes, Log.set_quiet_console, true)
  check("stage guard: quiet console doesn't print warnings", not with_reaper(fakes, Log.prints, warn_rec))
  check("stage guard: debug on prints warnings and info even when quiet",
    with_reaper(fakes, Log.prints, debug_warn) and with_reaper(fakes, Log.prints, info_rec))
  with_reaper(fakes, Log.set_quiet_console, false)
  check("stage guard: quiet off prints again", with_reaper(fakes, Log.prints, warn_rec))

  -- configure: on_debug_change runs after every switch (fake ExtState)
  local seen = {}
  local saved_cb = config.on_debug_change
  config.on_debug_change = function(on) seen[#seen + 1] = on end
  with_reaper(fakes, Log.set_debug, true)
  with_reaper(fakes, Log.set_debug, false)
  config.on_debug_change = saved_cb
  check("configure: on_debug_change gets every switch", #seen == 2 and seen[1] == true and seen[2] == false)
  check("old_name: SiSt-Live.log -> SiSt-Live.old.log", Log.old_name("SiSt-Live.log") == "SiSt-Live.old.log")

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
  check("file: rotated when full", Log.append_line(path, old, "three\n", 5) and read(old) == "one\ntwo\n"
    and read(path) == "three\n")
  Log.append_line(path, old, "four\n", 5)
  check("file: older rotation is replaced", read(old) == "three\n" and read(path) == "four\n")
  check("file: unwritable location reports failure",
    not Log.append_line(sep .. "selftest-no-such-dir" .. sep .. "x.log", sep .. "selftest-no-such-dir" .. sep .. "y.log", "x", 100))
  os.remove(path); os.remove(old)

  -- restore original state
  Log.set_sink(nil)
  if saved == "" then
    reaper.DeleteExtState(Log.SECTION, Log.KEY_DEBUG, false)
  else
    reaper.SetExtState(Log.SECTION, Log.KEY_DEBUG, saved, false)
  end
  if config.on_debug_change then pcall(config.on_debug_change, Log.is_debug()) end

  return results
end

return Log
