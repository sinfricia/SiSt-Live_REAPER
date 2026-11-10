-- @noindex
--[[
SiSt-Live Gui: Window

The part every SiSt-Live window repeats: open the gfx window where it was last time, run the
frame loop, keep the mouse state per frame, remember where the window is.

Usage:
  local win = Window.new{
    name = "SiSt-Live_Status",               -- ExtState section for everything saved
    title = "SiSt-Live Status",
    defaults = { ww = 320, wh = 160, zoomLevel = 0 },
    extra_keys = { "zoomLevel" },            -- more numbers in win.state that are saved too
  }
  win:set_mode(Mode.get())                   -- optional, see "Placement per mode"
  win:run(function(win)
    -- draw and handle input, once per frame
  end)

Each component keeps its own zoom: put it in win.state and list it in extra_keys.

More options:
  on_open = function(win)     called right after the window opened (gfx is ready: fonts, sizes)
  on_close = function(win)    called first when the window closes (copy values into win.state)
  ignore_saved_state = true   start with the defaults (e.g. a startup modifier for debugging)

Window menu: win:show_context_menu(extra_items) shows Dock window, Save as default position and
Return to default position, followed by the component's own items. The SiSt-Live rule: right-click
on content (e.g. a setlist entry) opens the content's menu, right-click anywhere else this one.
Items: { label = "Zoom in", action = fn, disabled = bool, checked = bool }, { separator = true } or
{ label = "Zoom", submenu = { items } } (see Gui/Zoom.lua for the ready-made zoom submenu).

As a toolbar action: the window is a toggle. Starting the action again closes the window and
the toolbar button is lit while the window is open (needs REAPER 7: set_action_options).

PLACEMENT PER MODE
  Screensets don't move script windows, so the window places itself. A placement is the dock
  state plus the floating position and size. Each mode has its own:
  - Call win:set_mode(mode) whenever the component has read the mode (the status display does
    it 5 times a second). The Window module never reads the mode itself.
  - Same mode as before: the current placement is remembered (in memory only).
  - Mode changed: the remembered placement of the old mode is SAVED. The remembered copy is
    from before the switch, so whatever the screenset did to the dockers is not saved.
    Then the window waits SETTLE_TIME (the screenset may still be rearranging the dockers),
    moves to the new mode's placement and checks a moment later that it really got there.
    If not, it tries again (MAX_ATTEMPTS in total). Nothing is remembered during that time.
  - Closing the window (also when REAPER quits) saves the current mode's placement.
  - Default placement: win:save_default() stores the current placement as the default of the
    current mode. Automatic saving never changes it. win:restore_default() goes back to it.
    A mode without a saved placement uses its default.
  - A mode without saved placement and without default: the window stays where it is.
  Without set_mode the window behaves the same, with a single placement ("any").

  Saved in ExtState (section = name, persistent):
    WindowState               last state: placement + extra keys (zoom). Also the fallback
    Placement_<mode>          automatically saved placement of one mode
    DefaultPlacement_<mode>   default placement of one mode

Keyboard (updated at the start of every frame):
  win.chars                 every key typed since the last frame, in order (gfx.getchar codes).
                            Several keys can arrive in one frame when typing fast: text fields
                            must read all of them, not only the first.
  win.char                  the first of them, 0 if none (kept for simple shortcuts)

Mouse state (win.mouse), updated at the start of every frame:
  x, y                      position
  left, right               button is held
  left_pressed/_released    true only in the frame where it happened (same for right_)
  press_x, press_y          where the last press started (used for clicks and drags)
  wheel                     wheel movement this frame (positive = up)
  ctrl, shift, alt          modifier keys

Debugging: opts.debug = function(text) receives one line per placement event (saved, moved,
checked...), with the docker number or floating position, e.g. "docker 3" / "floating 200,150 320x170".
Docked windows also show their size, e.g. "docker 3 (420x300)". The size of a docker belongs to
REAPER (and to the screenset that is loaded), not to the window: it is logged only, never restored.
Compare the size before the switch ("saved ...") with the one after ("window is at ...") to see
whether the screenset or the move changed it.

Self test: Window.self_test() returns a list of { name, ok }. Uses a fake gfx and ExtState:
it never touches a real window.
]]

local Window = {}
Window.__index = Window

Window.EXT_KEY = "WindowState" -- same key as the Setlist, so it can move to this module
Window.PLACEMENT_KEYS = { "dockState", "wx", "wy", "ww", "wh" }
Window.BASE_DEFAULTS = { dockState = 0, wx = 200, wy = 200, ww = 400, wh = 300 }
Window.ANY_MODE = "any" -- slot used when the component never calls set_mode
Window.SETTLE_TIME = 0.5 -- seconds to wait after a mode change before moving, and before checking
Window.MAX_ATTEMPTS = 3  -- moves per mode change before giving up (logged)

local SAVED = "Placement_"
local DEFAULT = "DefaultPlacement_"

-- Pure functions --------------------------------------------------------------

local function is_finite_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Stored string "{name=number,name=number,...}" -> table with only the whitelisted number keys. nil for empty
--- input or text that is not wrapped in braces. Entries that are not name=number (a string, a call, ...) are
--- ignored. Nothing is ever run as code.
function Window.parse_state(str, keys)
  if not str then return nil end
  local body = str:match("^%s*{(.*)}%s*$")
  if not body then return nil end

  local wanted = {}
  for _, key in ipairs(keys) do wanted[key] = true end

  local result = {}
  for name, value in body:gmatch("([%a_][%w_]*)%s*=%s*([^,%s]+)") do
    local number = tonumber(value)
    if wanted[name] and is_finite_number(number) then result[name] = number end
  end
  return result
end

--- Table -> "{key=value,...}" with the whitelisted number keys in the given order.
function Window.serialize_state(state, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    if is_finite_number(state[key]) then parts[#parts + 1] = key .. "=" .. tostring(state[key]) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- True if a dock state means "docked" (bit 0). Robust against floats and nil.
function Window.is_docked_state(dock)
  return is_finite_number(dock) and math.floor(dock) & 1 == 1
end

--- Mode value -> name usable in an ExtState key. nil gives ANY_MODE.
function Window.slot_name(mode)
  if mode == nil then return Window.ANY_MODE end
  return (tostring(mode):gsub("[^%w_]", "_"))
end

--- A placement copied out of any table (only the placement keys). nil if incomplete.
function Window.copy_placement(src)
  if not src then return nil end
  local p = {}
  for _, k in ipairs(Window.PLACEMENT_KEYS) do
    if not is_finite_number(src[k]) then return nil end
    p[k] = src[k]
  end
  return p
end

--- Same placement? Positions within half a pixel count as equal.
function Window.same_placement(a, b)
  if not a or not b then return false end
  for _, k in ipairs(Window.PLACEMENT_KEYS) do
    if not (is_finite_number(a[k]) and is_finite_number(b[k])) or math.abs(a[k] - b[k]) >= 0.5 then
      return false
    end
  end
  return true
end

--- Docker index from a dock state (bits 8-15). Also set while floating: the last docker used.
function Window.docker_index(dock)
  if not is_finite_number(dock) then return nil end
  return (math.floor(dock) >> 8) & 0xFF
end

--- Short description for the log: "docker 3" or "floating 200,150 320x170".
function Window.describe(p)
  if not p then return "(none)" end
  if Window.is_docked_state(p.dockState) then return "docker " .. Window.docker_index(p.dockState) end
  return ("floating %d,%d %dx%d"):format(math.floor(p.wx + 0.5), math.floor(p.wy + 0.5),
    math.floor(p.ww + 0.5), math.floor(p.wh + 0.5))
end

--- Is the window (actual) where it should be (target)? Docked: same dock state, the floating
--- values don't matter. Floating: same position and size.
function Window.placement_matches(target, actual)
  if not target or not actual then return false end
  local docked = Window.is_docked_state(target.dockState)
  if docked ~= Window.is_docked_state(actual.dockState) then return false end
  if docked then return math.floor(target.dockState) == math.floor(actual.dockState) end
  return Window.same_placement(target, actual)
end

--- Menu items -> gfx.showmenu string and the actions in menu order (separators and submenu headings don't
--- count, greyed out items do, as gfx.showmenu numbers them). A submenu item is { label = "Zoom", submenu = { items } }:
--- its last entry must be a normal item (gfx.showmenu closes the submenu there). Submenus inside submenus are not
--- supported.
function Window.build_menu(items)
  local parts, actions = {}, {}
  local function add(list, closing)
    for i, item in ipairs(list) do
      if item.separator then
        parts[#parts + 1] = ""
      elseif item.submenu then
        parts[#parts + 1] = ">" .. item.label
        add(item.submenu, "<")
      else
        local last = (i == #list) and closing or ""
        parts[#parts + 1] = last .. (item.disabled and "#" or "") .. (item.checked and "!" or "") .. item.label
        actions[#actions + 1] = (not item.disabled) and item.action or false
      end
    end
  end
  add(items, "")
  return table.concat(parts, "|"), actions
end

--- " (SHOW mode)" for menu labels, "" when the window doesn't know the mode
function Window.mode_suffix(slot)
  if not slot or slot == Window.ANY_MODE then return "" end
  return " (" .. slot:upper() .. " mode)"
end

--- Which placement a mode gets: remembered in this session, else saved, else default.
--- Returns the placement and where it came from, or nil.
function Window.choose_placement(remembered, saved, default)
  if remembered then return remembered, "remembered" end
  if saved then return saved, "saved" end
  if default then return default, "default" end
  return nil
end

--- Mouse state of this frame from the previous one and the raw gfx values.
function Window.next_mouse(prev, cap, x, y, wheel)
  local left, right = cap & 1 ~= 0, cap & 2 ~= 0
  local m = {
    x = x, y = y, wheel = wheel or 0,
    left = left, right = right,
    left_pressed = left and not prev.left, left_released = prev.left and not left,
    right_pressed = right and not prev.right, right_released = prev.right and not right,
    ctrl = cap & 4 ~= 0, shift = cap & 8 ~= 0, alt = cap & 16 ~= 0,
    press_x = prev.press_x, press_y = prev.press_y,
  }
  if m.left_pressed or m.right_pressed then m.press_x, m.press_y = x, y end
  return m
end

--- Reads the keyboard queue: every key of this frame. getchar: gfx.getchar. Returns closed (true if
--- the window was closed) and the list of keys. max: safety limit per frame.
function Window.read_chars(getchar, max)
  local chars = {}
  local c = getchar()
  if c < 0 then return true, chars end
  while c > 0 and #chars < (max or 64) do
    chars[#chars + 1] = c
    c = getchar()
  end
  return false, chars
end

local function empty_mouse()
  return Window.next_mouse({}, 0, 0, 0, 0)
end

-- Window object ------------------------------------------------------------------

function Window.new(opts)
  assert(type(opts) == "table" and type(opts.name) == "string", "Window.new: opts.name is required")
  local self = setmetatable({}, Window)
  self.name = opts.name
  self.title = opts.title or opts.name
  self.toggle_action = opts.toggle_action ~= false
  self.debug = opts.debug or function() end
  self.on_open = opts.on_open
  self.on_close = opts.on_close
  self.ignore_saved_state = opts.ignore_saved_state == true

  self.keys = {}
  for _, k in ipairs(Window.PLACEMENT_KEYS) do self.keys[#self.keys + 1] = k end
  for _, k in ipairs(opts.extra_keys or {}) do self.keys[#self.keys + 1] = k end

  self.state = {}
  for k, v in pairs(Window.BASE_DEFAULTS) do self.state[k] = v end
  for k, v in pairs(opts.defaults or {}) do self.state[k] = v end

  self.slot = nil       -- current mode as key name (nil until set_mode)
  self.remembered = {}  -- slot -> placement remembered in this session (memory only)
  self.pending = nil    -- after a mode change: { target, source, since, attempts } until settled
  self.settle_time = opts.settle_time or Window.SETTLE_TIME

  self.mouse = empty_mouse()
  self.char = 0
  self.chars = {}
  self.is_open = false
  self.quit_requested = false
  return self
end

-- Saved state ----------------------------------------------------------------------

function Window:load_state()
  local saved = Window.parse_state(reaper.GetExtState(self.name, Window.EXT_KEY), self.keys)
  for k, v in pairs(saved or {}) do self.state[k] = v end
  return saved ~= nil
end

function Window:save_state()
  reaper.SetExtState(self.name, Window.EXT_KEY, Window.serialize_state(self.state, self.keys), true)
end

function Window:read_placement(prefix, slot)
  return Window.copy_placement(Window.parse_state(reaper.GetExtState(self.name, prefix .. slot),
    Window.PLACEMENT_KEYS))
end

function Window:write_placement(prefix, slot, p)
  reaper.SetExtState(self.name, prefix .. slot, Window.serialize_state(p, Window.PLACEMENT_KEYS), true)
end

-- Placement --------------------------------------------------------------------------

function Window:current_slot()
  return self.slot or Window.ANY_MODE
end

function Window:current_placement()
  return Window.copy_placement(self.state)
end

--- The current placement for the log: "docker 3" or "floating 200,150 320x170".
function Window:describe_now()
  return Window.describe(self:current_placement())
end

function Window:placement_for(slot)
  return Window.choose_placement(self.remembered[slot], self:read_placement(SAVED, slot),
    self:read_placement(DEFAULT, slot))
end

--- Moves the open window to a placement. Returns true if anything changed.
function Window:apply_placement(p)
  gfx.dock(p.dockState)
  if not Window.is_docked_state(p.dockState) then
    gfx.init("", p.ww, p.wh, p.dockState, p.wx, p.wy) -- empty title: move/resize the open window
  end
  for _, k in ipairs(Window.PLACEMENT_KEYS) do self.state[k] = p[k] end
end

function Window:now()
  return reaper.time_precise()
end

--- Tell the window the current mode. See PLACEMENT PER MODE at the top.
function Window:set_mode(mode)
  if mode == nil then return end
  local slot = Window.slot_name(mode)

  if not self.is_open or self.slot == nil then
    self.slot = slot -- before opening: open() uses this mode's placement
    if self.is_open then self.remembered[slot] = self:current_placement() end
    return
  end

  if slot ~= self.slot then
    self:begin_mode_change(slot)
  elseif self.pending then
    self:continue_mode_change()
  else
    self.remembered[slot] = self:current_placement()
  end
end

function Window:begin_mode_change(slot)
  local old = self.slot
  if self.remembered[old] and not self.pending then
    self:write_placement(SAVED, old, self.remembered[old])
    self.debug(("mode %s -> %s: saved %s for %s"):format(old, slot, Window.describe(self.remembered[old]), old))
  else
    self.debug(("mode %s -> %s: %s not saved (it had not settled yet)"):format(old, slot, old))
  end
  self.slot = slot

  local target, source = self:placement_for(slot)
  self.pending = { target = target, source = source, since = self:now(), attempts = 0 }
  self.debug(("waiting %.1fs, then moving to %s placement of %s: %s (now: %s)"):format(self.settle_time,
    source or "no", slot, Window.describe(target), self:describe_now()))
end

function Window:continue_mode_change()
  local p = self.pending
  if self:now() - p.since < self.settle_time then return end -- still settling

  local actual = self:current_placement()
  if not p.target then
    self.debug(("no placement for %s yet: window stays at %s"):format(self.slot, self:describe_now()))
    return self:end_mode_change(actual)
  end

  if Window.placement_matches(p.target, actual) then
    self.debug(("%s: window is at %s%s"):format(self.slot, self:describe_now(),
      p.attempts == 0 and " (no move needed)" or (" after %d move(s)"):format(p.attempts)))
    return self:end_mode_change(actual)
  end

  if p.attempts >= Window.MAX_ATTEMPTS then
    self.debug(("%s: gave up after %d moves: wanted %s, window is at %s"):format(self.slot, p.attempts,
      Window.describe(p.target), self:describe_now()))
    return self:end_mode_change(p.target) -- remember what was wanted, not the wrong result
  end

  p.attempts = p.attempts + 1
  p.since = self:now()
  self:apply_placement(p.target)
  self.debug(("%s: move %d to %s (was at %s)"):format(self.slot, p.attempts, Window.describe(p.target),
    Window.describe(actual)))
end

function Window:end_mode_change(placement)
  self.remembered[self.slot] = placement
  self.pending = nil
end

--- Saves the current placement as the default of the current mode. Returns the slot name.
function Window:save_default()
  local slot = self:current_slot()
  local p = self:current_placement()
  self:write_placement(DEFAULT, slot, p)
  self.debug(("saved default for %s: %s"):format(slot, Window.describe(p)))
  return slot
end

function Window:has_default()
  return self:read_placement(DEFAULT, self:current_slot()) ~= nil
end

--- Moves the window to the default of the current mode. Returns false if there is none.
function Window:restore_default()
  local slot = self:current_slot()
  local p = self:read_placement(DEFAULT, slot)
  if not p then return false end
  self:apply_placement(p)
  self.remembered[slot] = p
  self.pending = nil
  self.debug(("moved to the default of %s: %s"):format(slot, Window.describe(p)))
  return true
end

--- Shows the window menu at the mouse. extra_items are added after a separator (see the top).
--- Returns the chosen item's label, or nil.
function Window:show_context_menu(extra_items)
  local suffix = Window.mode_suffix(self.slot)
  local items = {
    { label = "Dock window", checked = self:is_docked(), action = function() self:toggle_dock() end },
    { separator = true },
    { label = "Save as default position" .. suffix, action = function() self:save_default() end },
    { label = "Return to default position" .. suffix, disabled = not self:has_default(),
      action = function() self:restore_default() end },
  }
  if extra_items and #extra_items > 0 then
    items[#items + 1] = { separator = true }
    for _, item in ipairs(extra_items) do items[#items + 1] = item end
  end

  local menu, actions = Window.build_menu(items)
  gfx.x, gfx.y = self.mouse.x, self.mouse.y
  local choice = gfx.showmenu(menu)
  local action = actions[choice]
  if action then action() end
  return action and choice or nil
end

-- Geometry & lifecycle ----------------------------------------------------------------

-- Reads position, size and dock state from the open window. Done every frame, because after the
-- user closed the window these values can no longer be read.
function Window:capture_geometry()
  local dock, wx, wy, ww, wh = gfx.dock(-1, 1, 1, 1, 1)
  if is_finite_number(dock) then self.state.dockState = dock end
  if is_finite_number(ww) and ww > 0 and is_finite_number(wh) and wh > 0 then
    self.state.wx, self.state.wy, self.state.ww, self.state.wh = wx, wy, ww, wh
  end
end

function Window:open()
  local slot = self:current_slot()
  local p, source
  if self.ignore_saved_state then
    source = "default (saved state ignored)"
  else
    self:load_state()
    p, source = self:placement_for(slot)
  end
  if p then
    for _, k in ipairs(Window.PLACEMENT_KEYS) do self.state[k] = p[k] end
  end
  self.debug(("opening with %s placement of %s: %s"):format(source or "last", slot,
    Window.describe(self:current_placement())))

  local s = self.state
  gfx.init(self.title, s.ww, s.wh, s.dockState, s.wx, s.wy)
  self.is_open = true
  self.remembered[slot] = self:current_placement()
  if self.slot then
    -- REAPER may still be docking the window: check it like after a mode change (init was move 1)
    self.pending = { target = self:current_placement(), source = "opening", since = self:now(), attempts = 1 }
  end
  if self.toggle_action and reaper.set_action_options then
    reaper.set_action_options(1 | 4) -- 1: starting the action again closes the window, 4: toggle on
  end
  if self.on_open then self.on_open(self) end
end

function Window:close()
  if not self.is_open then return end
  self.is_open = false
  if self.on_close then self.on_close(self) end
  -- Closed in the middle of a mode change: save where the window should be, not where it is
  local p = self.pending and self.pending.target or self:current_placement()
  if p then
    self:write_placement(SAVED, self:current_slot(), p)
    self.debug(("closing: saved %s for %s"):format(Window.describe(p), self:current_slot()))
  end
  self:save_state()
  gfx.quit()
  if self.toggle_action and reaper.set_action_options then
    reaper.set_action_options(8) -- toggle off
  end
end

function Window:request_close()
  self.quit_requested = true
end

function Window:is_docked()
  return Window.is_docked_state(self.state.dockState)
end

function Window:toggle_dock()
  local dock = math.floor(gfx.dock(-1))
  if dock & 1 == 1 then gfx.dock(dock & ~1) else gfx.dock(dock | 1) end
end

function Window:update_input()
  self.mouse = Window.next_mouse(self.mouse, gfx.mouse_cap, gfx.mouse_x, gfx.mouse_y, gfx.mouse_wheel)
  gfx.mouse_wheel = 0
end

--- Opens the window and calls frame(win) once per frame until the window is closed.
function Window:run(frame)
  self:open()
  reaper.atexit(function() self:close() end) -- also when the script is stopped or REAPER quits

  local function loop()
    local closed, chars = Window.read_chars(gfx.getchar)
    if closed or self.quit_requested then
      self:close()
      return
    end
    self.chars = chars
    self.char = chars[1] or 0
    self:capture_geometry()
    self:update_input()
    frame(self)
    gfx.update()
    reaper.defer(loop)
  end
  loop()
end

-- Self test ----------------------------------------------------------------------

function Window.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local keys = { "wx", "zoomLevel" }

  -- parsing
  check("parse: empty string (first start) gives nil", Window.parse_state("", keys) == nil)
  check("parse: syntax error gives nil", Window.parse_state("{{{ broken", keys) == nil)
  check("parse: code is never run, such a value is ignored", (Window.parse_state("{wx=os.exit()}", keys) or {}).wx == nil)
  check("parse: text without braces gives nil", Window.parse_state("wx=5", keys) == nil
    and Window.parse_state("{wx=5", keys) == nil)
  local p = Window.parse_state("{wx=10,zoomLevel=\"bad\",foo=1}", keys)
  check("parse: only whitelisted numbers are kept", p and p.wx == 10 and p.zoomLevel == nil and p.foo == nil)
  check("parse: Setlist format is read", (Window.parse_state("{dockState=0,wx=5,}", { "wx" }) or {}).wx == 5)

  -- real stored values (reaper-extstate.ini, 2026-11-10) and odd numbers
  local real = Window.parse_state("{dockState=769.0,wx=1063.0,wy=240.0,ww=637.0,wh=520.0,zoomLevel=0,scrollOffset=0}",
    { "dockState", "wx", "wy", "ww", "wh", "zoomLevel", "scrollOffset" })
  check("parse: a real Setlist value is read completely", real and real.dockState == 769 and real.wx == 1063
    and real.wy == 240 and real.ww == 637 and real.wh == 520 and real.zoomLevel == 0 and real.scrollOffset == 0)
  local odd = Window.parse_state("{wx=-1920.5,wy=1e+3,ww=0x10,zoomLevel=inf, foo = 7 , bar=\"x,y\"}",
    { "wx", "wy", "ww", "zoomLevel", "foo" })
  check("parse: negative, exponent, spaces; inf is dropped", odd and odd.wx == -1920.5 and odd.wy == 1000
    and odd.ww == 16 and odd.zoomLevel == nil and odd.foo == 7)
  check("parse: empty braces give an empty table", next(Window.parse_state("{}", keys)) == nil)

  -- serializing
  local s = Window.serialize_state({ wx = -5, zoomLevel = 2, other = 9 }, keys)
  check("serialize: whitelisted keys in order", s == "{wx=-5,zoomLevel=2}")
  check("serialize: infinite / NaN values are left out",
    Window.serialize_state({ wx = math.huge, zoomLevel = 0 / 0 }, keys) == "{}")
  local round = Window.parse_state(Window.serialize_state({ wx = -5.25, zoomLevel = 2 }, keys), keys)
  check("serialize then parse gives the same values", round and round.wx == -5.25 and round.zoomLevel == 2)

  -- placement helpers
  check("is_docked_state", Window.is_docked_state(1) and Window.is_docked_state(257.0)
    and not Window.is_docked_state(256) and not Window.is_docked_state(nil))
  local full = { dockState = 0, wx = 1, wy = 2, ww = 3, wh = 4, zoomLevel = 9 }
  local copy = Window.copy_placement(full)
  check("copy_placement: incomplete gives nil", Window.copy_placement({ wx = 1 }) == nil)
  check("same_placement", Window.same_placement(copy, { dockState = 0, wx = 1.2, wy = 2, ww = 3, wh = 4 })
    and not Window.same_placement(copy, { dockState = 1, wx = 1, wy = 2, ww = 3, wh = 4 }))
  local a, b, c = { 1 }, { 2 }, { 3 }
  check("choose_placement: order remembered > saved > default",
    select(2, Window.choose_placement(a, b, c)) == "remembered" and select(2, Window.choose_placement(nil, b, c)) == "saved"
    and select(2, Window.choose_placement(nil, nil, c)) == "default" and Window.choose_placement(nil, nil, nil) == nil)

  -- placement per mode, with a fake window (gfx), fake ExtState and a fake clock
  local SelfTest = require("SelfTest")
  local ext, clock = {}, 0 -- the test reads the saved placements in ext directly
  local fakes = {
    GetExtState = function(sec, k) return ext[sec .. "/" .. k] or "" end,
    SetExtState = function(sec, k, v) ext[sec .. "/" .. k] = v end,
    time_precise = function() return clock end,
  }
  -- fake.redirect[a] = b: REAPER puts the window in b when asked for a (dockers still rearranging)
  local fake = { dock_state = 0, x = 10, y = 20, w = 300, h = 100, redirect = {}, redirect_once = true }
  local g = {
    w = 300, h = 100, -- the docker or window size, read every frame (log only)
    init = function(title, w, h, d, x, y)
      fake.w, fake.h, fake.dock_state, fake.x, fake.y = w, h, d, x, y
    end,
    dock = function(v, ...)
      if v == -1 and select("#", ...) > 0 then return fake.dock_state, fake.x, fake.y, fake.w, fake.h end
      if v == -1 then return fake.dock_state end
      local to = fake.redirect[v]
      if to and fake.redirect_once then fake.redirect[v] = nil end
      fake.dock_state = to or v
    end,
    quit = function() end,
  }
  local log = {}
  local function new_win()
    return Window.new{ name = "T", toggle_action = false,
      debug = function(line) log[#log + 1] = line end }
  end
  local function move(d, x) fake.dock_state, fake.x = d, x end -- the user (or REAPER) moves the window
  local function frame(win, mode, seconds)                    -- one mode check of the component
    clock = clock + (seconds or 0)
    win:capture_geometry()
    win:set_mode(mode)
  end
  local function saved(slot, key)
    return (Window.parse_state(ext["T/Placement_" .. slot], { key }) or {})[key]
  end

  SelfTest.with_reaper(fakes, SelfTest.with_gfx, g, function()
    local win = new_win()
    win:set_mode("edit")
    win:open()
    check("open: first time uses the last state", fake.x == Window.BASE_DEFAULTS.wx and win.slot == "edit")
    check("open: checked like a mode change", win.pending ~= nil)
    frame(win, "edit", 0.6)
    check("open: settled after the check", win.pending == nil)

    move(0, 111); frame(win, "edit", 0.2)
    check("same mode: remembered, not written to disk", ext["T/Placement_edit"] == nil and win.remembered.edit.wx == 111)

    move(0, 999)          -- the screenset moves things right before the switch is noticed
    frame(win, "show")
    check("switch: saves the old mode's placement from BEFORE the switch", saved("edit", "wx") == 111)
    check("switch: nothing moves before the settle time", fake.x == 999)
    frame(win, "show", 0.6)
    check("switch: mode without placement stays where it is", fake.x == 999 and win.pending == nil)

    move(257, 999); frame(win, "show", 0.2) -- the user docks it in show mode
    frame(win, "edit")
    check("switch back: waits first", fake.dock_state == 257)
    frame(win, "edit", 0.3)
    check("switch back: still waiting before the settle time", fake.dock_state == 257)
    frame(win, "edit", 0.3)
    check("switch back: moved to the edit placement", fake.dock_state == 0 and fake.x == 111)
    frame(win, "edit", 0.6)
    check("switch back: checked and settled", win.pending == nil)

    fake.redirect[257] = 513 -- REAPER puts it in the wrong docker once
    frame(win, "show"); frame(win, "show", 0.6)
    check("wrong docker: first move went wrong", fake.dock_state == 513 and win.pending ~= nil)
    frame(win, "show", 0.6)
    check("wrong docker: moved again", fake.dock_state == 257)
    frame(win, "show", 0.6)
    check("wrong docker: settled at the right placement", win.pending == nil and win.remembered.show.dockState == 257)

    frame(win, "edit"); for _ = 1, 3 do frame(win, "edit", 0.6) end
    fake.redirect, fake.redirect_once = { [257] = 513 }, false -- REAPER always puts it in the wrong docker
    frame(win, "show"); for _ = 1, Window.MAX_ATTEMPTS + 1 do frame(win, "show", 0.6) end
    check("gives up after MAX_ATTEMPTS moves", win.pending == nil and fake.dock_state == 513)
    check("gives up: remembers the wanted placement, not the wrong one", win.remembered.show.dockState == 257)
    fake.redirect = {}
    frame(win, "show", 0.2)
    check("after giving up: normal remembering again", win.remembered.show.dockState == 513)
    move(257, 999); frame(win, "show", 0.2)

    win:save_default()
    check("default: saved for the current mode", ext["T/DefaultPlacement_show"] ~= nil and win:has_default())
    move(0, 5); frame(win, "show", 0.2)
    check("default: restore moves back at once", win:restore_default() and fake.dock_state == 257)
    win.slot = "edit"
    check("default: edit has none", not win:has_default() and not win:restore_default())
    win.slot = "show"

    frame(win, "edit") -- closed during a mode change
    win:close()
    check("close during a mode change: saves where the window should be", saved("edit", "wx") == 111)

    ext["T/Placement_edit"] = nil -- no saved placement for edit: the default is used on open
    ext["T/DefaultPlacement_edit"] = "{dockState=0,wx=42,wy=1,ww=200,wh=90}"
    local win2 = new_win()
    win2:set_mode("edit")
    win2:open()
    check("open: mode without saved placement opens at its default", fake.x == 42 and fake.w == 200)

    local win3 = new_win()
    win3:open()
    check("no set_mode: works with the 'any' slot, no checking", win3:current_slot() == "any" and win3.pending == nil)
    win3:close()
    check("no set_mode: placement saved under 'any'", ext["T/Placement_any"] ~= nil)

    -- menu
    local _, actions = Window.build_menu({
      { label = "A", action = "a" }, { separator = true }, { label = "B", checked = true, action = "b" },
      { label = "C", disabled = true, action = "c" },
    })
    check("build_menu: actions numbered like gfx.showmenu, disabled has none",
      actions[1] == "a" and actions[2] == "b" and actions[3] == false and #actions == 3)
    local sub_menu, sub_actions = Window.build_menu({
      { label = "A", action = "a" },
      { label = "Zoom", submenu = { { label = "In", action = "in" }, { label = "Out", action = "out" } } },
      { separator = true },
      { label = "B", action = "b" },
    })
    check("build_menu: a submenu is opened with > and closed on its last entry with <",
      sub_menu == "A|>Zoom|In|<Out||B")
    check("build_menu: submenu entries are numbered in menu order, the heading does not count",
      #sub_actions == 4 and sub_actions[2] == "in" and sub_actions[3] == "out" and sub_actions[4] == "b")

    local events = {}
    ext["H/WindowState"] = "{dockState=0,wx=5,wy=5,ww=500,wh=400}"
    local hw = Window.new{ name = "H", toggle_action = false, ignore_saved_state = true,
      on_open = function() events[#events + 1] = "open" end,
      on_close = function(w) events[#events + 1] = "close"; w.state.zoomLevel = 7 end,
      extra_keys = { "zoomLevel" } }
    hw:open()
    check("ignore_saved_state: opens with the defaults", fake.w == Window.BASE_DEFAULTS.ww)
    hw:close()
    check("on_close: called before saving, so its values are saved",
      events[2] == "close" and (ext["H/WindowState"] or ""):find("zoomLevel=7", 1, true) ~= nil)
  end)

  local function queue(list) local i = 0; return function() i = i + 1; return list[i] or 0 end end
  local closed, keys = Window.read_chars(queue({ 97, 98, 99 }))
  check("read_chars: all keys of the frame, in order", not closed and #keys == 3 and keys[1] == 97 and keys[3] == 99)
  closed, keys = Window.read_chars(queue({}))
  check("read_chars: no key", not closed and #keys == 0)
  closed = Window.read_chars(queue({ -1 }))
  check("read_chars: window closed", closed)
  closed, keys = Window.read_chars(function() return 120 end, 5)
  check("read_chars: limited per frame", not closed and #keys == 5)

  check("placement_matches: docked compares the docker only",
    Window.placement_matches({ dockState = 257 }, { dockState = 257, wx = 5, wy = 5, ww = 5, wh = 5 })
    and not Window.placement_matches({ dockState = 257 }, { dockState = 513 })
    and not Window.placement_matches({ dockState = 257 }, { dockState = 256, wx = 0, wy = 0, ww = 1, wh = 1 }))

  return results
end

return Window
