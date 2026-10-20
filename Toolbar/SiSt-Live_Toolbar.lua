-- @noindex
-- SiSt-Live Toolbar. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   # SiSt-Live Toolbar
--   Big, readable buttons for the show, in the colors of the REAPER theme.
--
--   The buttons and their order come from a native REAPER floating toolbar: edit that toolbar in REAPER
--   as usual (right-click a toolbar > Customize toolbar...) and set its number per mode in the toolbar
--   settings (right-click the toolbar > Toolbar settings...).
--   The SiSt-Live Toolbar shows the toolbar of the current mode and switches with the mode. A toolbar must
--   have been customized once to be found.
--
--   - Button text: the native button's text, else the action name (without "Category: ")
--   - Toggle actions (e.g. Repeat) have an indicator bar at the bottom: bright while on, dim while off
--   - Size: the buttons always fit the window. The number of columns is chosen so that ALL buttons fit,
--     as big as possible, and every row fills the window width. More buttons or a smaller window give
--     smaller buttons, never scrolling (nothing to scroll during a show). Buttons are always at least
--     1.5 times wider than high; space left below stays empty. Zoom (Ctrl + wheel) only changes the text size
--   - Separators become a thin divider line with extra space: a vertical line between two buttons of a
--     row, a horizontal line between two rows when the separator falls on a row break
--   - A button whose action doesn't exist (e.g. a script that was removed) is drawn greyed out
--
--   The toolbar is read when the window opens and when the mode changes, never in the background.
--   After changing the native toolbar: right-click > Reload toolbar.
--
--   Right-click: window menu (dock, default position per mode), Toolbar settings, Reload toolbar, zoom.
--   Ctrl + mouse wheel zooms. The window remembers its position per mode, like the other windows.
--   Run the action again (or click its toolbar button) to close the window.
--
--   Debugging: with SiSt-Live debug logging on ("DEBUG Toggle Logging") while the window opens, the
--   self tests run, and every reload and button click is logged ([Toolbar]).

local SCRIPT_NAME = "SiSt-Live_Toolbar" -- ExtState section (window position, zoom)
local WINDOW_TITLE = "SiSt-Live Toolbar"

local REFRESH_INTERVAL = 0.1 -- seconds between reads of the mode and the toggle states
local MIN_ZOOM, MAX_ZOOM = -5, 15
local MIN_TEXT_SCALE = 0.6   -- labels shrink down to this before they are cut off

-- Sizes in pixels. The buttons size themselves to the window (see ToolbarWindow.fit_layout).
local SIZE = {
  pad = 10,
  gap = 10,
  separator = 26, -- extra space for a separator (the divider line is drawn in the middle)
  min_ratio = 1.5, -- buttons are at least this many times wider than high (never square)
  max_ratio = 4,  -- buttons at most this many times wider than high (when choosing the columns)
  text_ratio = 0.36, -- button text size = button height * ratio (times the zoom)
  min_text = 9,
  message = 15,   -- text when there is no toolbar
  settings_w = 150,
  settings_h = 28,
}

-- Libraries, loaded in main(). Gui and ToolbarSource are required, the others optional.
local Theme, Window, Widgets, ToolbarSource
local Log, Mode
local log = nil
local lib_problems = {}

local function first_line(v)
  return (tostring(v):match("^[^\r\n]*"))
end

local function debug_log(fmt, ...)
  if log then log:debug(fmt, ...) end
end

--------------------------------------------------------------------------------
-- Pure functions (no REAPER, no gfx). Tested in ToolbarWindow.self_test()
--------------------------------------------------------------------------------

local ToolbarWindow = {}

function ToolbarWindow.clamp_zoom(level)
  return math.max(MIN_ZOOM, math.min(MAX_ZOOM, math.floor(level or 0)))
end

--- Base size scaled by the zoom level (10% per step), rounded to whole pixels
function ToolbarWindow.scaled(base, level)
  return math.floor(base * (1 + ToolbarWindow.clamp_zoom(level) * 0.1) + 0.5)
end

--- Places ALL buttons in the window (w x h), as big as possible. items: toolbar buttons ({ separator =
--- true } or a button). s: { pad, gap, separator, min_ratio, max_ratio }.
--- How: every possible number of columns is tried. For each, the rows fill the width, the button height is
--- what the window height allows, but at most width / min_ratio (buttons are always wider than high). The columns that give the biggest buttons win
--- (a button wider than max_ratio x its height only counts as max_ratio x wide: no long flat strips).
--- Separators: inside a row extra space with a vertical divider; on a row break extra space between the
--- rows with a horizontal divider. Leading, trailing and repeated separators count once or not at all.
--- Returns rects = { { item, x, y, w, h }, ... }, dividers = { { x1, y1, x2, y2 }, ... }, columns.
function ToolbarWindow.fit_layout(items, w, h, s)
  local buttons, sep_before, pending = {}, {}, false
  for _, item in ipairs(items) do
    if item.separator then
      if #buttons > 0 then pending = true end
    else
      buttons[#buttons + 1] = item
      sep_before[#buttons] = pending
      pending = false
    end
  end
  local n = #buttons
  if n == 0 then return {}, {}, 0 end
  local avail_w, avail_h = w - 2 * s.pad, h - 2 * s.pad

  -- sizes for a number of columns: button width per row, button height, score
  local function plan(cols)
    local rows = math.ceil(n / cols)
    local row_w, min_w, breaks = {}, math.huge, 0
    for r = 1, rows do
      local first, last = (r - 1) * cols + 1, math.min(r * cols, n)
      local seps = 0
      for i = first + 1, last do if sep_before[i] then seps = seps + 1 end end
      if r > 1 and sep_before[first] then breaks = breaks + 1 end
      row_w[r] = (avail_w - (cols - 1) * s.gap - seps * s.separator) / cols
      min_w = math.min(min_w, row_w[r])
    end
    local bh = math.min((avail_h - (rows - 1) * s.gap - breaks * s.separator) / rows, min_w / (s.min_ratio or 1))
    local score = (bh > 0 and min_w > 0) and math.min(min_w, s.max_ratio * bh) * bh or -1
    return { cols = cols, rows = rows, row_w = row_w, bh = math.max(bh, 1), score = score }
  end

  local best = nil
  for cols = n, 1, -1 do -- equal scores: fewer rows wins
    local p = plan(cols)
    if not best or p.score > best.score then best = p end
  end

  local rects, dividers = {}, {}
  local y = s.pad
  for r = 1, best.rows do
    local first, last = (r - 1) * best.cols + 1, math.min(r * best.cols, n)
    if r > 1 then
      local bottom = y + best.bh
      local space = s.gap + (sep_before[first] and s.separator or 0)
      if sep_before[first] then
        local ly = bottom + math.floor(space / 2)
        dividers[#dividers + 1] = { x1 = s.pad, y1 = ly, x2 = w - s.pad, y2 = ly }
      end
      y = bottom + space
    end
    local x = s.pad
    for i = first, last do
      if i > first then
        local right = x
        local space = s.gap + (sep_before[i] and s.separator or 0)
        if sep_before[i] then
          local lx = right + math.floor(space / 2)
          local inset = math.floor(best.bh * 0.15)
          dividers[#dividers + 1] = { x1 = lx, y1 = y + inset, x2 = lx, y2 = y + best.bh - inset }
        end
        x = right + space
      end
      rects[#rects + 1] = { item = buttons[i], x = x, y = y, w = best.row_w[r], h = best.bh }
      x = x + best.row_w[r]
    end
  end
  return rects, dividers, best.cols
end

--- Font size that fits a label into max_w, and the label (cut off with "..." if even the smallest
--- size is too wide). measure(text, size) returns the width.
function ToolbarWindow.fit_label(label, max_w, size, measure)
  local min_size = math.max(1, math.floor(size * MIN_TEXT_SCALE))
  for s = size, min_size, -1 do
    if measure(label, s) <= max_w then return label, s end
  end
  -- cut off by whole UTF-8 characters
  local chars = {}
  for _, c in utf8.codes(label) do chars[#chars + 1] = utf8.char(c) end
  for n = #chars - 1, 1, -1 do
    local cut = table.concat(chars, "", 1, n) .. "..."
    if measure(cut, min_size) <= max_w then return cut, min_size end
  end
  return "...", min_size
end

function ToolbarWindow.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local s = { pad = 5, gap = 5, separator = 20, max_ratio = 4 }
  local B, S = { label = "b" }, { separator = true }
  local function near(a, b) return math.abs(a - b) < 1e-6 end

  local rects, dividers, cols = ToolbarWindow.fit_layout({ B, B, B }, 320, 60, s)
  check("fit: wide window gives one row", cols == 3 and #rects == 3 and rects[3].y == 5 and #dividers == 0)
  check("fit: the row fills the width", near(rects[1].w, 100) and near(rects[3].x + rects[3].w, 315)
    and near(rects[1].h, 50))

  rects, dividers = ToolbarWindow.fit_layout({ B, S, B }, 330, 60, s)
  check("fit: separator in a row: extra space, row still fills the width",
    near(rects[2].x, 5 + 147.5 + 25) and near(rects[2].x + rects[2].w, 325))
  check("fit: separator in a row is a vertical line in the space",
    #dividers == 1 and dividers[1].x1 == dividers[1].x2 and dividers[1].x1 > 152 and dividers[1].x1 < rects[2].x)

  rects, dividers, cols = ToolbarWindow.fit_layout({ B, S, B }, 110, 300, s)
  check("fit: narrow window gives a column", cols == 1 and rects[2].x == 5 and near(rects[2].y, 5 + 100 + 25))
  check("fit: without min_ratio buttons can be square", near(rects[1].h, 100) and near(rects[1].w, 100))
  check("fit: separator on a row break is a horizontal line between the rows",
    #dividers == 1 and dividers[1].y1 == dividers[1].y2 and dividers[1].y1 > 105 and dividers[1].y1 < rects[2].y
    and dividers[1].x1 == 5 and dividers[1].x2 == 105)

  local wide = { pad = 5, gap = 5, separator = 20, min_ratio = 1.5, max_ratio = 4 }
  rects = ToolbarWindow.fit_layout({ B, B }, 110, 300, wide)
  check("fit: min_ratio keeps buttons wider than high", near(rects[1].w / rects[1].h, 1.5))
  rects = ToolbarWindow.fit_layout({ B, B, B }, 320, 200, wide)
  check("fit: min_ratio in a wide window too", rects[1].w / rects[1].h >= 1.5 - 1e-9)

  local many = {}
  for i = 1, 20 do many[i] = B end
  rects = ToolbarWindow.fit_layout(many, 400, 100, s)
  local inside = #rects == 20
  for _, r in ipairs(rects) do
    inside = inside and r.x >= 5 - 1e-6 and r.x + r.w <= 395 + 1e-6 and r.y >= 5 - 1e-6 and r.y + r.h <= 95 + 1e-6
  end
  check("fit: too many buttons get smaller, all stay inside the window", inside)

  rects, dividers = ToolbarWindow.fit_layout({ S, B, S, S, B, S }, 400, 60, s)
  check("fit: leading, repeated and trailing separators count once or not at all", #rects == 2 and #dividers == 1)
  rects = ToolbarWindow.fit_layout({ B }, 100, 500, s)
  check("fit: a single button in a tall window stays square", near(rects[1].h, 90))
  rects, dividers, cols = ToolbarWindow.fit_layout({ S }, 400, 60, s)
  check("fit: no buttons", #rects == 0 and #dividers == 0 and cols == 0)

  local function measure(text, size) return utf8.len(text) * size / 2 end -- fake font
  local l, sz = ToolbarWindow.fit_label("Play", 100, 20, measure)
  check("fit: short label keeps its size", l == "Play" and sz == 20)
  l, sz = ToolbarWindow.fit_label("abcdefghijk", 80, 20, measure) -- 11 chars: fits at 14
  check("fit: long label gets smaller", l == "abcdefghijk" and sz == 14)
  l, sz = ToolbarWindow.fit_label("Ääääääääääääääääääääää", 60, 20, measure)
  check("fit: too long is cut off by whole characters", l:sub(-3) == "..." and utf8.len(l) ~= nil and sz == 12)

  check("zoom", ToolbarWindow.scaled(100, 0) == 100 and ToolbarWindow.scaled(100, 5) == 150
    and ToolbarWindow.clamp_zoom(99) == MAX_ZOOM)
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

-- Gui and ToolbarSource are part of the SiSt-Live package: without them there is nothing to show.
local function load_required()
  local ok, err = pcall(function()
    Theme = require("Gui.Theme")
    Window = require("Gui.Window")
    Widgets = require("Gui.Widgets")
    ToolbarSource = require("SiSt-Live_ToolbarSource")
  end)
  if not ok then
    reaper.MB("A SiSt-Live library could not be loaded:\n\n" .. tostring(err) ..
      "\n\nReinstall the package 'SiSt-Live' in ReaPack.", WINDOW_TITLE, 0)
  end
  return ok
end

local function load_optional()
  local ok_log, l = pcall(require, "SiSt-Live_Log")
  if ok_log then Log = l; log = Log.get("Toolbar") end
  local ok_mode, m = pcall(require, "SiSt-Live_Mode")
  if ok_mode then Mode = m else lib_problems[#lib_problems + 1] = "Mode library not loaded: " .. first_line(m) end
end

local function run_self_tests(out)
  local passed, failed = 0, 0
  local suites = { { "Toolbar window", ToolbarWindow.self_test }, { "ToolbarSource", ToolbarSource.self_test },
    { "Gui Widgets", Widgets.self_test } }
  for _, suite in ipairs(suites) do
    local ok, res = pcall(suite[2])
    if not ok then
      failed = failed + 1
      out(("FAIL %s self test crashed: %s"):format(suite[1], tostring(res)))
    else
      for _, r in ipairs(res) do
        if r.ok then passed = passed + 1 else failed = failed + 1; out(("FAIL %s: %s"):format(suite[1], r.name)) end
      end
    end
  end
  out(("Toolbar self tests: %d passed, %d failed"):format(passed, failed))
  return failed
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function current_mode()
  return Mode and Mode.get() or "show"
end

local function main()
  add_lib_path()
  if not load_required() then return end
  load_optional()

  -- Test-only switch (see lib/SelfTest.lua): hand over the tests instead of opening the window
  if rawget(_G, "SELFTEST_COLLECT") then
    table.insert(SELFTEST_COLLECT, { name = "Toolbar window", self_test = ToolbarWindow.self_test })
    return
  end

  if Log and Log.is_debug() then run_self_tests(function(s) debug_log("%s", s) end) end

  local toolbar, message = nil, nil -- the loaded toolbar, or a message instead
  local loaded_mode = nil
  local toggles = {}                -- cmd -> true (on) / false (off); not a toggle action: nil
  local last_refresh = -math.huge

  local function reload(mode)
    loaded_mode = mode
    toolbar, message = ToolbarSource.load(mode)
    toggles = {}
    last_refresh = -math.huge -- read the toggle states right away
    if toolbar then
      debug_log("loaded %s for %s mode: %d buttons", ToolbarSource.section_name(toolbar.number), mode, #toolbar.buttons)
      if #toolbar.missing > 0 and log then
        log:warn("toolbar %d: actions not found: %s", toolbar.number, table.concat(toolbar.missing, ", "))
      end
    else
      debug_log("no toolbar for %s mode: %s", mode, first_line(message))
    end
  end

  local win = Window.new{
    name = SCRIPT_NAME,
    title = WINDOW_TITLE,
    defaults = { ww = 700, wh = 70, zoomLevel = 0 },
    extra_keys = { "zoomLevel" },
    debug = function(text) debug_log("window: %s", text) end,
  }
  win:set_mode(current_mode()) -- open where the window was in this mode
  reload(current_mode())

  local function zoom_to(level) win.state.zoomLevel = ToolbarWindow.clamp_zoom(level) end
  local function open_settings()
    if ToolbarSource.configure() then
      debug_log("toolbar settings stored")
      reload(current_mode())
    end
  end

  win:run(function()
    local now = reaper.time_precise()
    if now - last_refresh >= REFRESH_INTERVAL then
      last_refresh = now
      local mode = current_mode()
      win:set_mode(mode) -- position per mode
      if mode ~= loaded_mode then reload(mode) end
      if toolbar then
        for _, b in ipairs(toolbar.buttons) do
          if b.cmd then
            local state = reaper.GetToggleCommandStateEx(0, b.cmd)
            if state == 1 then toggles[b.cmd] = true elseif state == 0 then toggles[b.cmd] = false else toggles[b.cmd] = nil end
          end
        end
      end
    end

    local m = win.mouse
    if m.wheel ~= 0 and m.ctrl then zoom_to(win.state.zoomLevel + (m.wheel > 0 and 1 or -1)) end
    if m.right_released then
      win:show_context_menu({
        { label = "Toolbar settings...", action = open_settings },
        { label = "Reload toolbar", action = function() reload(current_mode()) end },
        { separator = true },
        { label = "Zoom in", action = function() zoom_to(win.state.zoomLevel + 1) end },
        { label = "Zoom out", action = function() zoom_to(win.state.zoomLevel - 1) end },
        { label = "Reset zoom", action = function() zoom_to(0) end },
      })
    end

    gfx.clear = Theme.clear_color()
    local zoom = win.state.zoomLevel
    local function px(base) return ToolbarWindow.scaled(base, zoom) end

    if not toolbar then
      -- One line per row (gfx.drawstr can't wrap), then a button to the settings
      local lines = {}
      for line in (message .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
      for _, problem in ipairs(lib_problems) do lines[#lines + 1] = problem end
      local pad, line_h = px(SIZE.pad), math.floor(px(SIZE.message) * 1.4)
      local y = pad
      for _, line in ipairs(lines) do
        Widgets.text(line, pad, y, gfx.w - 2 * pad, line_h, { size = px(SIZE.message), color = "muted" })
        y = y + line_h
      end
      if Widgets.button(win, "Toolbar settings...", pad, y + pad, px(SIZE.settings_w), px(SIZE.settings_h),
          { size = px(SIZE.message) }) then
        open_settings()
      end
      return
    end

    local s = { pad = SIZE.pad, gap = SIZE.gap, separator = SIZE.separator, min_ratio = SIZE.min_ratio,
      max_ratio = SIZE.max_ratio }
    local rects, dividers = ToolbarWindow.fit_layout(toolbar.buttons, gfx.w, gfx.h, s)
    local function measure(text, size)
      Theme.set_font(size)
      return (gfx.measurestr(text))
    end

    Theme.set("line")
    for _, d in ipairs(dividers) do gfx.line(d.x1, d.y1, d.x2, d.y2) end

    for _, r in ipairs(rects) do
      local b = r.item
      local text_size = math.max(SIZE.min_text, math.floor(r.h * SIZE.text_ratio * (1 + zoom * 0.1)))
      local label, size = ToolbarWindow.fit_label(b.label, r.w - 2 * s.pad, text_size, measure)
      local clicked = Widgets.button(win, label, r.x, r.y, r.w, r.h,
        { size = size, disabled = b.cmd == nil, toggle = b.cmd and toggles[b.cmd] or nil })
      if clicked and b.cmd then
        debug_log("run %d (%s)", b.cmd, b.label)
        reaper.Main_OnCommand(b.cmd, 0)
        last_refresh = -math.huge -- show the new toggle state right away
      end
    end
  end)
end

main()
