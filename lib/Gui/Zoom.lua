-- @noindex
-- Gui zoom: the zoom level of a window (win.state.zoomLevel, saved with the window, see Window.lua) and what
-- goes with it. A level is a whole number; every step changes sizes by 10 percent.
--
--   local Zoom = require("Gui.Zoom")
--   local function px(base) return Zoom.scaled(base, win.state.zoomLevel) end   -- a size at the current zoom
--   Zoom.wheel(win)                                  -- Ctrl + mouse wheel zooms (call once per frame)
--   win:show_context_menu({ Zoom.menu_item(win) })   -- "Zoom" submenu: Zoom in, Zoom out, Reset zoom
--
-- Range: Zoom.MIN to Zoom.MAX unless a function is given its own min and max.
-- The component must list "zoomLevel" in the Window's extra_keys to have it saved.

local Zoom = {}

Zoom.MIN  = -5
Zoom.MAX  = 15
Zoom.STEP = 0.1 -- size change per level

--- Whole number inside the range. nil gives 0.
function Zoom.clamp(level, min, max)
  return math.max(min or Zoom.MIN, math.min(max or Zoom.MAX, math.floor(level or 0)))
end

--- Factor for a level: 1 at level 0.
function Zoom.scale(level, min, max)
  return 1 + Zoom.clamp(level, min, max) * Zoom.STEP
end

--- Base size scaled by the level, rounded to whole pixels.
function Zoom.scaled(base, level, min, max)
  return math.floor(base * Zoom.scale(level, min, max) + 0.5)
end

--- Sets the window's zoom level (clamped).
function Zoom.set(win, level, min, max)
  win.state.zoomLevel = Zoom.clamp(level, min, max)
end

--- Ctrl + mouse wheel changes the zoom by one level per wheel notch. Call once per frame.
function Zoom.wheel(win, min, max)
  local m = win.mouse
  if m.wheel ~= 0 and m.ctrl then
    Zoom.set(win, (win.state.zoomLevel or 0) + (m.wheel > 0 and 1 or -1), min, max)
  end
end

--- A menu item for Window:show_context_menu / Window.build_menu: the "Zoom" submenu.
function Zoom.menu_item(win, min, max)
  local function level() return win.state.zoomLevel or 0 end
  return { label = "Zoom", submenu = {
    { label = "Zoom in",    action = function() Zoom.set(win, level() + 1, min, max) end },
    { label = "Zoom out",   action = function() Zoom.set(win, level() - 1, min, max) end },
    { label = "Reset zoom", action = function() Zoom.set(win, 0, min, max) end },
  } }
end

--- Built-in self-test (pure; a fake window).
function Zoom.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  check("clamp: range, whole numbers, nil is 0",
    Zoom.clamp(100) == Zoom.MAX and Zoom.clamp(-100) == Zoom.MIN and Zoom.clamp(2.7) == 2 and Zoom.clamp(nil) == 0)
  check("clamp: own range", Zoom.clamp(20, -8, 16) == 16 and Zoom.clamp(-20, -8, 16) == -8)
  check("scale: 10 percent per level, clamped", Zoom.scale(0) == 1 and math.abs(Zoom.scale(5) - 1.5) < 1e-9
    and math.abs(Zoom.scale(99) - (1 + Zoom.MAX * Zoom.STEP)) < 1e-9)
  check("scaled: rounded to whole pixels", Zoom.scaled(20, 0) == 20 and Zoom.scaled(20, 5) == 30
    and Zoom.scaled(15, 1) == 17)

  local win = { state = { zoomLevel = 0 }, mouse = { wheel = 0, ctrl = false } }
  win.mouse.wheel = 1
  Zoom.wheel(win)
  check("wheel without Ctrl does nothing", win.state.zoomLevel == 0)
  win.mouse.ctrl = true
  Zoom.wheel(win)
  Zoom.wheel(win)
  check("Ctrl + wheel up zooms in one level per notch", win.state.zoomLevel == 2)
  win.mouse.wheel = -3
  Zoom.wheel(win)
  check("a wheel notch is one level, however fast it spins", win.state.zoomLevel == 1)
  win.state.zoomLevel = Zoom.MAX
  win.mouse.wheel = 1
  Zoom.wheel(win)
  check("wheel stops at the end of the range", win.state.zoomLevel == Zoom.MAX)

  local item = Zoom.menu_item(win)
  win.state.zoomLevel = 3
  item.submenu[1].action()
  local after_in = win.state.zoomLevel
  item.submenu[2].action(); item.submenu[2].action()
  local after_out = win.state.zoomLevel
  item.submenu[3].action()
  check("menu: a submenu 'Zoom' with in, out and reset",
    item.label == "Zoom" and #item.submenu == 3 and after_in == 4 and after_out == 2 and win.state.zoomLevel == 0)
  local own = Zoom.menu_item(win, -8, 16)
  win.state.zoomLevel = 16
  own.submenu[1].action()
  check("menu: own range", win.state.zoomLevel == 16)

  return results
end

return Zoom
