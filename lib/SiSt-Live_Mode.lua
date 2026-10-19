-- @noindex
-- SiSt-Live Mode library: owns the edit/show mode state.
-- Never read or write the mode ExtState directly; always go through this module.

local Button = require("SiSt-Live_Button")
local Log    = require("SiSt-Live_Log")

local log = Log.get("Mode")

local Mode = {}

-- Storage ---------------------------------------------------------------
Mode.SECTION  = "SiSt-Live"
Mode.KEY_MODE = "mode"

-- Modes -----------------------------------------------------------------
Mode.SHOW    = "show"
Mode.EDIT    = "edit"
Mode.DEFAULT = Mode.EDIT   -- applied on every REAPER start (nothing is persisted)

local VALID = { [Mode.SHOW] = true, [Mode.EDIT] = true }

-- Toolbar button: lit = SHOW mode (so the unlit startup state matches DEFAULT = EDIT)
local function sync_button()
  Button.set_state("mode", Mode.get() == Mode.SHOW)
end

-- Public API ------------------------------------------------------------
--- Raw stored string ("" when unset). Mainly for diagnostics and tests.
function Mode.get_raw()
  return reaper.GetExtState(Mode.SECTION, Mode.KEY_MODE)
end

function Mode.get()
  local v = Mode.get_raw()
  return VALID[v] and v or Mode.DEFAULT -- empty or invalid falls back to default
end

function Mode.is_edit() return Mode.get() == Mode.EDIT end
function Mode.is_show() return Mode.get() == Mode.SHOW end

--- The only writer. Returns false (and warns) if the mode is invalid.
function Mode.set(mode)
  if not VALID[mode] then
    log:warn("set: invalid mode %s ignored", tostring(mode))
    return false
  end
  local previous = Mode.get()
  reaper.SetExtState(Mode.SECTION, Mode.KEY_MODE, mode, false) -- persist = false
  log:debug("set: %s -> %s", previous, mode)
  sync_button()
  return true
end

function Mode.toggle()
  return Mode.set(Mode.is_edit() and Mode.SHOW or Mode.EDIT)
end

--- Transition detection for defer loops.
--- on_change(new_mode, old_mode) fires once immediately (old_mode == nil)
--- so consumers can initialise, then only when the mode actually changes.
--- Callback errors are logged, never thrown, so a faulty consumer cannot
--- kill its own defer loop. Returns a poll function; call it once per cycle.
function Mode.watch(on_change)
  assert(type(on_change) == "function", "Mode.watch: on_change must be a function")
  local last = Mode.get()
  log:debug("watch started, initial mode = %s", last)
  Log.safe_call(log, "on_change(init)", on_change, last, nil)
  return function()
    local current = Mode.get()
    if current ~= last then
      local old = last
      last = current
      log:debug("transition detected: %s -> %s", old, current)
      Log.safe_call(log, "on_change", on_change, current, old)
    end
  end
end

--- Built-in self-test, run against the real REAPER API.
--- Saves and restores the current mode. Returns a list of { name, ok }.
function Mode.self_test()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local saved = Mode.get_raw()
  Log.set_sink(function() end) -- silence expected warnings while testing

  reaper.SetExtState(Mode.SECTION, Mode.KEY_MODE, "garbage", false)
  check("invalid stored value falls back to default", Mode.get() == Mode.DEFAULT)

  check("set(show) accepted", Mode.set(Mode.SHOW) == true)
  check("get() returns show after set", Mode.get() == Mode.SHOW)
  check("set(invalid) rejected", Mode.set("nope") == false)
  check("rejected set leaves mode unchanged", Mode.get() == Mode.SHOW)
  Mode.toggle()
  check("toggle show -> edit", Mode.is_edit())
  Mode.toggle()
  check("toggle edit -> show", Mode.is_show())

  local calls = {}
  local poll = Mode.watch(function(new, old) calls[#calls + 1] = { new, old } end)
  check("watch fires on init with old == nil", #calls == 1 and calls[1][2] == nil)
  poll()
  check("watch silent while unchanged", #calls == 1)
  Mode.set(Mode.EDIT)
  poll()
  check("watch fires on change (show -> edit)",
    #calls == 2 and calls[2][1] == Mode.EDIT and calls[2][2] == Mode.SHOW)

  -- restore original state
  if saved == "" then
    reaper.DeleteExtState(Mode.SECTION, Mode.KEY_MODE, false)
  else
    reaper.SetExtState(Mode.SECTION, Mode.KEY_MODE, saved, false)
  end
  sync_button()
  Log.set_sink(nil)

  return results
end

--- Ordered { label, value } rows for the diagnostics action.
function Mode.diagnostics()
  local raw = Mode.get_raw()
  return {
    { "effective mode",   Mode.get() },
    { "raw ExtState",     raw == "" and "(empty)" or raw },
    { "raw value valid",  tostring(VALID[raw] == true) },
    { "default mode",     Mode.DEFAULT },
    { "mode button",      Button.describe("mode") },
  }
end

return Mode
