-- @noindex
-- SiSt-Live Status Display. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   # SiSt-Live Status Display
--   A small window that shows the state of SiSt-Live: the current edit/show mode and any problems.
--
--   Currently shown:
--   - the mode (SHOW / EDIT)
--   - the result of the last mode switch: which mode effects failed and why ("Apply again" retries)
--   - SiSt-Live libraries that could not be loaded
--
--   Mode button (right end of the header): in show mode "Hold for EDIT" must be held down for a second (a
--   bar fills it) so a stray click on stage can't leave show mode. In edit mode "Switch to SHOW" is a normal
--   click. It switches exactly like the toggle action (mode, then the mode effects).
--
--   Right-click menu: window position and docking, "Debug logging" (the same switch as the action
--   "DEBUG Toggle Logging", checked while on), zoom.
--
--   Run the action again (or click its toolbar button) to close the window. The button is lit while
--   the window is open. Right-click for docking and zoom, Ctrl + mouse wheel zooms too.
--
--   Position per mode: screensets don't move script windows, so the window does it itself. Put it where
--   you want it in each mode once: the position is saved when you switch modes and when the window or
--   REAPER closes, and restored when you come back to that mode. Right-click > "Save as default
--   position" stores a position you can always return to ("Return to default position"). A mode that
--   has no saved position yet uses its default.
--
--   Needs REAPER 7. Uses the Mode, ModeEffects and Log libraries of the package: if one is missing,
--   the window opens anyway and shows what is missing.
--
--   Debugging: when SiSt-Live debug logging is on ("DEBUG Toggle Logging") while the window opens,
--   the self tests run and the theme colors are logged (which REAPER theme key each color came from).

local SCRIPT_NAME = "SiSt-Live_Status" -- ExtState section (window position, zoom)
local WINDOW_TITLE = "SiSt-Live Status Display"

local REFRESH_INTERVAL = 0.2 -- seconds between reads of the mode and effect status
local MIN_ZOOM, MAX_ZOOM = -5, 15

-- Base sizes at zoom level 0, in pixels
local SIZE = {
  pad = 8,
  text = 16,
  line_h = 24,
  dot = 4,
  indent = 14,
  button_w = 120,
  button_h = 26,
}

-- The mode button in the header. Fixed size like the header (headers don't zoom)
local MODE_BUTTON = {
  w = 140,
  text = 15,
}

-- Libraries, loaded in main(). Gui is required, the others are optional.
local Theme, Window, Widgets
local Log, Mode, ModeEffects
local log = nil
local lib_problems = {}

local function first_line(v)
  return (tostring(v):match("^[^\r\n]*"))
end

local function debug_log(fmt, ...)
  if log then log:debug(fmt, ...) end
end

--------------------------------------------------------------------------------
-- Pure functions (no REAPER, no gfx). Tested in Status.self_test()
--------------------------------------------------------------------------------

local Status = {}

function Status.clamp_zoom(level)
  return math.max(MIN_ZOOM, math.min(MAX_ZOOM, math.floor(level or 0)))
end

function Status.zoom_scale(level)
  return 1 + Status.clamp_zoom(level) * 0.1
end

--- Base size scaled by the zoom level, rounded to whole pixels
function Status.scaled(base, level)
  return math.floor(base * Status.zoom_scale(level) + 0.5)
end

--- Turns the raw state into what the window shows.
--- input fields (all optional):
---   mode, mode_values = { show = ..., edit = ... }   from the Mode library
---   effects = { { name, status }, ... }, last_run, failed_value   from ModeEffects (nil: not loaded)
---   lib_problems = { "text", ... }, retry_problem = "text"
---   format_time = function(unix_time) -> string (default: HH:MM)
--- Returns { mode_label, mode_accent, lines = { { kind, text } }, has_errors, can_retry }
--- Line kinds: "error", "detail" (belongs to the error above), "ok", "info".
function Status.build_model(input)
  local format_time = input.format_time or function(t) return os.date("%H:%M", t) end
  local model = { lines = {}, has_errors = false, can_retry = false }
  local function add(kind, text)
    model.lines[#model.lines + 1] = { kind = kind, text = text }
    if kind == "error" then model.has_errors = true end
  end

  local mv = input.mode_values
  if mv and input.mode ~= nil and input.mode == mv.show then
    model.mode_label, model.mode_accent = "SHOW", "show"
  elseif mv and input.mode ~= nil and input.mode == mv.edit then
    model.mode_label, model.mode_accent = "EDIT", "edit"
  else
    model.mode_label, model.mode_accent = "MODE UNKNOWN", "error"
  end

  for _, problem in ipairs(input.lib_problems or {}) do add("error", problem) end
  if input.retry_problem then add("error", input.retry_problem) end

  if input.effects then
    local last = input.last_run
    if not last then
      add("info", "No mode switch in this REAPER session yet")
    elseif (last.failed_count or 0) == 0 then
      add("ok", ("Mode effects applied (%s mode, %s)"):format(last.mode, format_time(last.time)))
    else
      add("error", ("%d mode effect%s failed (%s mode, %s)"):format(last.failed_count,
        last.failed_count == 1 and "" or "s", last.mode, format_time(last.time)))
      for _, effect in ipairs(input.effects) do
        local s = effect.status
        if s and s.result == input.failed_value then
          add("detail", effect.name .. ": " .. (s.message ~= "" and s.message or "no message"))
        end
      end
      model.can_retry = true
    end
  end

  return model
end

function Status.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local mv = { show = "show", edit = "edit" }
  local function t(time) return "T" .. time end

  local m = Status.build_model({ mode = "show", mode_values = mv })
  check("mode: show", m.mode_label == "SHOW" and m.mode_accent == "show")
  m = Status.build_model({ mode = "edit", mode_values = mv })
  check("mode: edit", m.mode_label == "EDIT" and m.mode_accent == "edit")
  m = Status.build_model({ mode = "garbage", mode_values = mv })
  check("mode: unknown value", m.mode_label == "MODE UNKNOWN" and m.mode_accent == "error")
  m = Status.build_model({})
  check("mode: Mode library missing", m.mode_label == "MODE UNKNOWN" and #m.lines == 0 and not m.has_errors)
  m = Status.build_model({ mode = nil, mode_values = { show = nil, edit = "edit" } })
  check("mode: nil never matches a missing constant", m.mode_label == "MODE UNKNOWN")

  m = Status.build_model({ lib_problems = { "A missing", "B missing" } })
  check("library problems are errors", #m.lines == 2 and m.lines[1].kind == "error" and m.has_errors)
  m = Status.build_model({ retry_problem = "boom" })
  check("retry problem is shown", m.lines[1].text == "boom" and m.has_errors)

  m = Status.build_model({ effects = {}, failed_value = "failed" })
  check("no mode switch yet", m.lines[1].kind == "info" and not m.can_retry and not m.has_errors)

  m = Status.build_model({ effects = {}, failed_value = "failed", format_time = t,
    last_run = { mode = "show", time = 5, ok_count = 3, failed_count = 0 } })
  check("all effects ok", m.lines[1].kind == "ok" and m.lines[1].text:find("show mode, T5", 1, true)
    and not m.can_retry and not m.has_errors)

  local effects = {
    { name = "theme",  status = { result = "failed", message = "file not found" } },
    { name = "layout", status = { result = "ok", message = "" } },
    { name = "keys",   status = { result = "failed", message = "" } },
    { name = "never",  status = nil },
  }
  m = Status.build_model({ effects = effects, failed_value = "failed", format_time = t,
    last_run = { mode = "edit", time = 7, ok_count = 1, failed_count = 2 } })
  check("failures: header with count", m.lines[1].kind == "error" and m.lines[1].text:find("^2 mode effects failed"))
  check("failures: one detail line per failed effect", #m.lines == 3 and m.lines[2].text == "theme: file not found"
    and m.lines[3].text == "keys: no message")
  check("failures: retry offered", m.can_retry and m.has_errors)
  m = Status.build_model({ effects = effects, failed_value = "failed", format_time = t,
    last_run = { mode = "edit", time = 7, ok_count = 3, failed_count = 1 } })
  check("failures: singular", m.lines[1].text:find("^1 mode effect failed") ~= nil)

  check("zoom: clamped", Status.clamp_zoom(100) == MAX_ZOOM and Status.clamp_zoom(-100) == MIN_ZOOM)
  check("zoom: nil is level 0", Status.clamp_zoom(nil) == 0 and Status.zoom_scale(nil) == 1)
  check("zoom: sizes scale and round", Status.scaled(10, 5) == 15 and Status.scaled(16, 0) == 16)

  return results
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function add_lib_path()
  local _, script_path = reaper.get_action_context()
  local dir = (script_path or ""):match("^(.*[/\\])") or ""
  package.path = dir .. "../lib/?.lua;" .. package.path
end

-- The Gui library is part of the SiSt-Live package: without it nothing can be drawn.
local function load_gui()
  local ok, err = pcall(function()
    Theme = require("Gui.Theme")
    Window = require("Gui.Window")
    Widgets = require("Gui.Widgets")
  end)
  if not ok then
    reaper.MB("The Gui library (lib/Gui) could not be loaded:\n\n" .. tostring(err) ..
      "\n\nReinstall the package 'SiSt-Live' in ReaPack.", "SiSt-Live Status Display", 0)
  end
  return ok
end

-- The other libraries are optional: a missing one is shown in the window instead.
local function load_optional(module)
  local ok, result = pcall(require, module)
  if ok then return result end
  lib_problems[#lib_problems + 1] = module .. " not loaded: " .. first_line(result)
  return nil
end

local function load_optional_libs()
  Log = load_optional("SiSt-Live_Log")
  Mode = load_optional("SiSt-Live_Mode")
  ModeEffects = load_optional("SiSt-Live_ModeEffects")
  if Log then log = Log.get("StatusDisplay") end
  if not (Mode and ModeEffects) then
    lib_problems[#lib_problems + 1] = "Reinstall the package 'SiSt-Live' in ReaPack"
  end
end

--------------------------------------------------------------------------------
-- Self tests
--------------------------------------------------------------------------------

--- Runs the self tests of this script and of the Gui library. out(text) prints one line.
--- Returns the number of failures.
local function run_self_tests(out)
  local suites = {
    { "Gui.Theme", Theme.self_test },
    { "Gui.Window", Window.self_test },
    { "Gui.Widgets", Widgets.self_test },
    { "Status Display", Status.self_test },
  }
  local passed, failed = 0, 0
  for _, suite in ipairs(suites) do
    local ok, results = pcall(suite[2])
    if not ok then
      failed = failed + 1
      out(("ERROR [%s] %s"):format(suite[1], tostring(results)))
    else
      for _, r in ipairs(results) do
        if r.ok then
          passed = passed + 1
        else
          failed = failed + 1
          out(("FAIL [%s] %s"):format(suite[1], r.name))
        end
      end
    end
  end
  out(("Status Display self tests: %d passed, %d failed"):format(passed, failed))
  return failed
end

--------------------------------------------------------------------------------
-- Reading the state and drawing
--------------------------------------------------------------------------------

local effect_names = {}  -- names of the mode effects, read once at startup
local retry_problem = nil

local function read_input()
  local input = { lib_problems = lib_problems, retry_problem = retry_problem }
  if Mode then
    input.mode = Mode.get()
    input.mode_values = { show = Mode.SHOW, edit = Mode.EDIT }
  end
  if ModeEffects then
    input.last_run = ModeEffects.get_last_run()
    input.failed_value = ModeEffects.FAILED
    input.effects = {}
    for _, name in ipairs(effect_names) do
      input.effects[#input.effects + 1] = { name = name, status = ModeEffects.get_status(name) }
    end
  end
  return input
end

local function apply_effects_again()
  retry_problem = nil
  local ok, err = pcall(ModeEffects.apply_all, Mode.get())
  if not ok then retry_problem = "Applying the mode effects failed: " .. first_line(err) end
  debug_log("apply again: %s", ok and "done" or tostring(err))
end

local LINE_STYLE = {
  error  = { dot = "error", color = "text" },
  ok     = { dot = "ok", color = "text" },
  info   = { color = "muted" },
  detail = { color = "muted", indent = true },
}

-- Switches the mode like the toggle action does: set the mode, then run the mode effects (a failing
-- effect never undoes the switch). Used by the mode button.
local function switch_mode(target)
  retry_problem = nil
  Mode.set(target)
  if log then log:info("mode switched to %s from the status display", target) end
  local ok, err = pcall(ModeEffects.apply_all, target)
  if not ok then retry_problem = "Applying the mode effects failed: " .. first_line(err) end
end

--- Draws the model. Returns the action that was clicked: "retry", "show", "edit" or nil.
local function draw(win, model)
  local zoom = win.state.zoomLevel
  local function px(base) return Status.scaled(base, zoom) end
  local pad, text_size, line_h = px(SIZE.pad), px(SIZE.text), px(SIZE.line_h)
  local w = gfx.w - 2 * pad

  gfx.clear = Theme.clear_color()

  -- Mode banner: the shared header in the mode's color. Fixed size: headers don't zoom.
  -- SHOW uses the deep teal "live" (white text stays readable on it)
  local banner_h = Widgets.HEADER_H
  local header_accent = ({ show = "live" })[model.mode_accent] or model.mode_accent
  local has_mode_button = Mode and ModeEffects and (model.mode_accent == "show" or model.mode_accent == "edit")
  Widgets.header(model.mode_label, pad, pad, w, banner_h, header_accent) -- title centered over the whole header
  Theme.set_font(Widgets.header_text_size(banner_h))
  local label_w = gfx.measurestr(model.mode_label)
  local mbx, mby, mbw, mbh = Widgets.header_button_rect(pad, pad, w, banner_h, MODE_BUTTON.w, label_w)
  local face = Widgets.header_button_face(header_accent)

  -- Mode button: part of the header (full height, right end, a lighter shade of the header color).
  -- To EDIT the button must be HELD (a bar fills it): a stray click during the show does nothing.
  -- To SHOW a click is enough: that's the safe direction.
  local action = nil
  if has_mode_button and model.mode_accent == "show" then
    if Widgets.hold_button(win, "Hold for EDIT", mbx, mby, mbw, mbh,
        { size = MODE_BUTTON.text, fill_color = "edit", face = face }) then
      action = "edit"
    end
  elseif has_mode_button then
    if Widgets.button(win, "Switch to SHOW", mbx, mby, mbw, mbh, { size = MODE_BUTTON.text, face = face }) then
      action = "show"
    end
  end

  -- Status lines
  local y = pad + banner_h + pad
  local dot_w = px(SIZE.dot) * 2 + pad
  for _, line in ipairs(model.lines) do
    local style = LINE_STYLE[line.kind] or LINE_STYLE.info
    local x = pad + (style.indent and px(SIZE.indent) or 0)
    if style.dot then
      Theme.set(style.dot)
      gfx.circle(x + px(SIZE.dot), y + line_h / 2, px(SIZE.dot), true, true)
    end
    Widgets.text(line.text, x + dot_w, y, gfx.w - x - dot_w - pad, line_h, { size = text_size, color = style.color })
    y = y + line_h
  end

  -- "Apply again" only after failures
  if model.can_retry then
    if Widgets.button(win, "Apply again", pad, y + pad / 2, px(SIZE.button_w), px(SIZE.button_h), { size = text_size }) then
      action = "retry"
    end
  end
  return action
end

-- Right-click anywhere: the shared window menu, the debug switch and zoom (no content menus here)
local function show_context_menu(win)
  local function zoom_to(level) win.state.zoomLevel = Status.clamp_zoom(level) end
  local debug_on = Log and Log.refresh()
  win:show_context_menu({
    { label = "Debug logging", checked = debug_on, disabled = Log == nil,
      action = function()
        local on = Log.toggle_debug() -- keeps the "DEBUG Toggle Logging" toolbar button in sync
        reaper.ShowConsoleMsg("SiSt-Live debug logging: " .. (on and "ON" or "OFF") .. "\n")
      end },
    { separator = true },
    { label = "Zoom in", action = function() zoom_to(win.state.zoomLevel + 1) end },
    { label = "Zoom out", action = function() zoom_to(win.state.zoomLevel - 1) end },
    { label = "Reset zoom", action = function() zoom_to(0) end },
  })
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function main()
  add_lib_path()
  if not load_gui() then return end
  load_optional_libs()

  -- Test-only switch (see lib/SelfTest.lua): hand over the tests instead of opening the window
  if rawget(_G, "SELFTEST_COLLECT") then
    table.insert(SELFTEST_COLLECT, { name = "Status Display", self_test = Status.self_test })
    return
  end

  if Log and Log.is_debug() then
    run_self_tests(function(s) debug_log("%s", s) end)
    for _, row in ipairs(Theme.diagnostics()) do debug_log("%s: %s", row[1], row[2]) end
    for _, problem in ipairs(lib_problems) do debug_log("library problem: %s", problem) end
  end

  if ModeEffects then
    local ok, names = pcall(ModeEffects.names)
    if ok then
      effect_names = names
    else
      lib_problems[#lib_problems + 1] = "Mode effects could not be listed: " .. first_line(names)
    end
  end

  local win = Window.new{
    name = SCRIPT_NAME,
    title = WINDOW_TITLE,
    defaults = { ww = 320, wh = 170, zoomLevel = 0 },
    extra_keys = { "zoomLevel" },
    debug = function(text) debug_log("window: %s", text) end,
  }
  if Mode then win:set_mode(Mode.get()) end -- open where the window was in this mode

  local model, last_refresh = nil, -math.huge
  local function refresh_model()
    local input = read_input()
    win:set_mode(input.mode) -- saves / restores the window position per mode (nil: nothing happens)
    model = Status.build_model(input)
    last_refresh = reaper.time_precise()
  end

  win:run(function()
    if reaper.time_precise() - last_refresh >= REFRESH_INTERVAL then refresh_model() end

    local m = win.mouse
    if m.wheel ~= 0 and m.ctrl then
      win.state.zoomLevel = Status.clamp_zoom(win.state.zoomLevel + (m.wheel > 0 and 1 or -1))
    end
    if m.right_released then show_context_menu(win) end

    local action = draw(win, model)
    if action == "retry" then
      apply_effects_again()
      refresh_model()
    elseif action == "show" or action == "edit" then
      switch_mode(action == "show" and Mode.SHOW or Mode.EDIT)
      refresh_model()
    end
  end)
end

main()
