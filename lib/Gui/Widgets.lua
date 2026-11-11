-- @noindex
--[[
SiSt-Live Gui: Widgets

Small drawing helpers that use the Theme. Immediate mode: every frame you call the widget
again, it draws itself and tells you what happened. No widget objects to keep track of.

  Widgets.box(x, y, w, h, "button")                       -- filled rectangle
  Widgets.text("Hello", x, y, w, h, { size = 18, align = "center", color = "muted" })
  if Widgets.button(win, "Retry", x, y, w, h) then ... end
  if Widgets.hold_button(win, "Hold to switch", x, y, w, h) then ... end -- fires after holding 0.5 s
  Widgets.header("REAPER SETLIST", x, y, w, h)            -- window header bar
  Widgets.list_view(win, state, rows, x, y, w, h)         -- scrollable rows { text, style, note, note_style, checked,
                                                          -- bg, header, on_toggle }: state = {} kept by the caller
                                                          -- (state.scroll = first row); a row with `checked` has a
                                                          -- checkbox that a click toggles

  -- Text entry: the text field lives in its own file (lib/Gui/TextField.lua, it keeps state and is
  -- big), but is reachable from here, so a component only needs to load Widgets:
  local name = Widgets.TextField.new{ text = "Intro" }       -- once
  local ev = Widgets.text_field(win, name, x, y, w, h)       -- every frame (= TextField.draw)
  Widgets.TextField.focus(win, name)                         -- the rest of its API, see TextField.lua

Design language (all SiSt-Live windows look alike):
  - Header: Widgets.header. A flat bar in a muted accent color (the accent mixed into the
    background), regular text. Fixed size (HEADER_H): headers don't zoom, only the content does.
    Setlist: teal ("accent"). Status display: its mode (SHOW deep teal "live", EDIT orange; accents it adds
    with Theme.configure). How strong the mix is: the accent's header field, else HEADER_AMOUNT_DEFAULT.
    Header text is white; a header color light enough to need dark text should be avoided.
  - Buttons: Widgets.button. Toggle buttons (opts.toggle = true/false) have an indicator bar at the
    bottom, bright "toggle" color when on, dim when off. That, the hover and the press effect set
    buttons apart from headers.
  - Text: Widgets.text. Font: Theme.FONT_FACE. Colors: Theme roles.

A button click is a press AND a release on the button: pressing, moving off and releasing
does nothing (as in REAPER's own buttons). opts.disabled draws it faded and never clicks.
opts.repeat_every = seconds: the button fires when pressed and then again and again while it is
held (zoom buttons). It doesn't fire on release.
opts.toggle = true / false: a toggle action that is on / off (e.g. Repeat). Draws the indicator bar
at the bottom; on also tints the button. nil: not a toggle.

Self test: Widgets.self_test() returns a list of { name, ok }. Pure functions only.
]]

local Theme = require("Gui.Theme")
local TextField = require("Gui.TextField") -- only needs Theme: no circular require

local Widgets = {}

-- The text field (see the top): the whole module, plus the per-frame call as a widget function
Widgets.TextField = TextField
function Widgets.text_field(win, field, x, y, w, h, opts)
  return TextField.draw(win, field, x, y, w, h, opts)
end

Widgets.TEXT_SIZE = 18
Widgets.DISABLED_ALPHA = 0.35
Widgets.HEADER_H = 44            -- header height in pixels (headers don't zoom)
Widgets.HEADER_TEXT_RATIO = 0.62 -- header font size = height * ratio (27 at 44, as the setlist had)
-- How much of the accent is mixed into the background for a header (the setlist's look: teal at 30 %,
-- the orange edit bar at 60 %)
Widgets.HEADER_AMOUNT_DEFAULT = 0.30

-- Pure functions ----------------------------------------------------------------------

function Widgets.is_inside(px, py, x, y, w, h)
  return px ~= nil and py ~= nil and px >= x and px < x + w and py >= y and py < y + h
end

-- gfx.drawstr flags: 4 = center vertically, plus 1 = center / 2 = right horizontally
local ALIGN_FLAGS = { left = 4, center = 5, right = 6 }
function Widgets.drawstr_flags(align)
  return ALIGN_FLAGS[align or "left"] or ALIGN_FLAGS.left
end

--- What the mouse does to a button this frame: hover, held (pressed on it, still down), clicked.
function Widgets.button_state(mouse, x, y, w, h, disabled)
  local over = Widgets.is_inside(mouse.x, mouse.y, x, y, w, h)
  local pressed_here = Widgets.is_inside(mouse.press_x, mouse.press_y, x, y, w, h)
  if disabled then return false, false, false end
  local held = mouse.left and pressed_here
  local clicked = mouse.left_released and pressed_here and over
  return over, held, clicked
end

--- Hold-to-repeat timing. timers: table kept by the caller (one entry per button key).
--- Fires on the press, then every interval while held. Returns true when it fires.
function Widgets.repeat_fire(timers, key, held, pressed, now, interval)
  if not held then
    timers[key] = nil
    return false
  end
  if pressed or timers[key] == nil or now - timers[key] >= interval then
    timers[key] = now
    return true
  end
  return false
end

--- Pure. One frame of a hold button. st: table kept per button ({} at first). held: the mouse is down on the
--- button (pressed there and still over it). Returns progress 0..1 and fired (true in exactly one frame:
--- when the hold time is reached). Letting go or moving off resets; after firing, nothing happens until
--- the mouse is released.
function Widgets.hold_step(st, held, now, hold_time)
  if not held then
    st.start, st.fired = nil, false
    return 0, false
  end
  st.start = st.start or now
  if st.fired then return 1, false end
  local progress = math.min(1, (now - st.start) / hold_time)
  if progress >= 1 then
    st.fired = true
    return 1, true
  end
  return progress, false
end

--- Pure. Where the toggle indicator bar of a button goes: centered at the bottom.
function Widgets.toggle_bar(x, y, w, h)
  local bh = math.max(3, math.floor(h * 0.08 + 0.5))
  local bw = math.floor(w * 0.5 + 0.5)
  return x + math.floor((w - bw) / 2), y + h - bh - math.max(2, math.floor(h * 0.08)), bw, bh
end

-- Drawing ----------------------------------------------------------------------------

function Widgets.box(x, y, w, h, color, alpha)
  Theme.set(color, alpha)
  gfx.rect(x, y, w, h, true)
end

--- opts: size, color (role, accent or table), alpha, align ("left", "center", "right"), flags (font)
function Widgets.text(str, x, y, w, h, opts)
  opts = opts or {}
  Theme.set_font(opts.size or Widgets.TEXT_SIZE, opts.flags)
  Theme.set(opts.color or "text", opts.alpha)
  gfx.x, gfx.y = x, y
  gfx.drawstr(tostring(str), Widgets.drawstr_flags(opts.align), x + w, y + h)
end

--- Pure. Header box color: the accent mixed into the background (by its header field, else HEADER_AMOUNT_DEFAULT).
function Widgets.header_face(background, accent_color)
  return Theme.mix(background, accent_color, accent_color.header or Widgets.HEADER_AMOUNT_DEFAULT)
end

--- Window header bar with centered text. accent: accent name ("accent", "error", or one a package added), default "accent".
--- Use Widgets.HEADER_H as height. text_w (optional): the text is centered in the first text_w pixels
--- only, e.g. when a button sits at the right end of the header.
function Widgets.header(label, x, y, w, h, accent, text_w)
  accent = accent or "accent"
  local face = Widgets.header_face(Theme.color("background"), Theme.color(accent))
  Widgets.box(x, y, w, h, face)
  local text_color = Theme.luminance(face) > 0.6 and Theme.text_on(face) or "text"
  Widgets.text(label, x, y, text_w or w, h, {
    size = math.floor(h * Widgets.HEADER_TEXT_RATIO + 0.5),
    align = "center",
    color = text_color
  })
end

--- Font size of a header's text.
function Widgets.header_text_size(h)
  return math.floor(h * Widgets.HEADER_TEXT_RATIO + 0.5)
end

--- Where a button that is part of a header goes: the full height of the header, at its right end.
--- The title stays centered over the whole header, so the button is never wider than the space
--- between the centered title and the right edge (label_w: width of the title text). Pure.
Widgets.HEADER_BUTTON_MIN_W = 60
function Widgets.header_button_rect(x, y, w, h, button_w, label_w)
  local room = math.floor((w - (label_w or 0)) / 2) - math.floor(h * 0.25) -- keep a gap to the title
  local bw = math.max(Widgets.HEADER_BUTTON_MIN_W, math.min(button_w, room))
  return x + w - bw, y, bw, h
end

--- Base color of a button that is part of a header: the header color, a bit lighter.
function Widgets.header_button_face(accent)
  accent = accent or "accent"
  local header = Widgets.header_face(Theme.color("background"), Theme.color(accent))
  return Theme.mix(header, Theme.color("text"), 0.14)
end

--- Returns true in the frame the button is clicked. opts: size, disabled, repeat_every, id, toggle,
--- face (base color instead of the "button" role, e.g. Widgets.header_button_face for a header button)
--- (id: only needed for two repeating buttons with the same label)
function Widgets.button(win, label, x, y, w, h, opts)
  opts = opts or {}
  local over, held, clicked = Widgets.button_state(win.mouse, x, y, w, h, opts.disabled)
  if opts.repeat_every and not opts.disabled then
    win.widget_timers = win.widget_timers or {}
    clicked = Widgets.repeat_fire(win.widget_timers, opts.id or label, held, win.mouse.left_pressed,
      reaper.time_precise(), opts.repeat_every)
  end
  local alpha = opts.disabled and Widgets.DISABLED_ALPHA or 1

  local face = Theme.color(opts.face or "button")
  if opts.toggle then face = Theme.mix(face, Theme.color("toggle"), 0.30) end
  if held then
    face = Theme.mix(face, Theme.color("text"), 0.25)
  elseif over then
    face = Theme.mix(face, Theme.color("text"), 0.10)
  end
  Widgets.box(x, y, w, h, face, alpha)
  if opts.toggle ~= nil then
    local bx, by, bw, bh = Widgets.toggle_bar(x, y, w, h)
    Widgets.box(bx, by, bw, bh, opts.toggle and "toggle" or Theme.mix(face, Theme.color("background"), 0.45), alpha)
  end
  Widgets.text(label, x, y, w, h, { size = opts.size, align = "center", alpha = alpha })

  return clicked
end

--- A button that only fires after it was held down for opts.hold seconds (default HOLD_TIME), e.g. a
--- mode switch that must not happen by accident on stage. While held, a bar fills the button from left
--- to right (opts.fill_color, default "toggle"). Returns true in the frame the hold completes.
--- opts: size, disabled, hold, fill_color, face (see Widgets.button), id (only needed for two hold buttons
--- with the same label).
Widgets.HOLD_TIME = 0.5
function Widgets.hold_button(win, label, x, y, w, h, opts)
  opts = opts or {}
  win.widget_holds = win.widget_holds or {}
  local key = opts.id or label
  local st = win.widget_holds[key] or {}
  win.widget_holds[key] = st
  local over, held = Widgets.button_state(win.mouse, x, y, w, h, opts.disabled)
  local progress, fired = Widgets.hold_step(st, held and over, reaper.time_precise(), opts.hold or Widgets.HOLD_TIME)

  local alpha = opts.disabled and Widgets.DISABLED_ALPHA or 1
  local face = Theme.color(opts.face or "button")
  if over then face = Theme.mix(face, Theme.color("text"), 0.10) end
  Widgets.box(x, y, w, h, face, alpha)
  if progress > 0 then Widgets.box(x, y, math.floor(w * progress + 0.5), h, opts.fill_color or "toggle", 0.55) end
  Widgets.text(label, x, y, w, h, { size = opts.size, align = "center", alpha = alpha })
  return fired
end

-- Scrolling list ---------------------------------------------------------------------------

Widgets.ROW_H = 26
Widgets.SCROLLBAR_W = 20 -- as wide as the Setlist's own scrollbar
Widgets.CHECK_SIZE = 18

--- Pure. How many whole rows fit, and the most the list can be scrolled (in rows, 0 = top).
function Widgets.list_limits(n_rows, row_h, view_h)
  local visible = math.max(1, math.floor(view_h / row_h))
  return visible, math.max(0, n_rows - visible)
end

--- Pure. The scroll position (in rows) after a mouse wheel turn: one notch (120) is one row.
function Widgets.wheel_scroll(scroll, wheel, max_scroll)
  if wheel == 0 then return math.min(scroll, max_scroll) end
  local steps = math.max(1, math.floor(math.abs(wheel) / 100 + 0.5))
  local v = scroll + (wheel > 0 and -steps or steps)
  return math.max(0, math.min(max_scroll, v))
end

--- Pure. The scrollbar thumb: y and height, for a track of track_h starting at track_y.
function Widgets.list_thumb(track_y, track_h, n_rows, visible, scroll, max_scroll)
  local thumb_h = math.max(20, math.floor(track_h * visible / math.max(1, n_rows) + 0.5))
  thumb_h = math.min(thumb_h, track_h)
  local t = max_scroll > 0 and scroll / max_scroll or 0
  return track_y + math.floor((track_h - thumb_h) * t + 0.5), thumb_h
end

--- Pure. The scroll position (in rows) when the thumb is dragged so that its middle is at mouse_y.
function Widgets.scroll_from_thumb(mouse_y, track_y, track_h, thumb_h, max_scroll)
  local room = track_h - thumb_h
  if room <= 0 or max_scroll <= 0 then return 0 end
  local t = math.max(0, math.min(1, (mouse_y - track_y - thumb_h / 2) / room))
  return math.floor(t * max_scroll + 0.5)
end

--- A checkbox box at x, y (size Widgets.CHECK_SIZE): checked is true, false or "mixed" (a dash: only some of a group).
--- Clicks are the caller's business (list_view toggles a row when it is clicked).
function Widgets.draw_check(x, y, checked)
  local s = Widgets.CHECK_SIZE
  Widgets.box(x, y, s, s, Theme.mix(Theme.color("background"), Theme.color("text"), 0.45))
  Widgets.box(x + 1, y + 1, s - 2, s - 2, checked and Theme.mix(Theme.color("button"), Theme.color("accent"), 0.5)
    or Theme.color("background"))
  if checked == "mixed" then
    Theme.set("text")
    gfx.rect(x + 4, y + math.floor(s / 2) - 1, s - 8, 3, true)
  elseif checked then
    Theme.set("text")
    gfx.line(x + 4, y + math.floor(s / 2), x + math.floor(s / 2) - 1, y + s - 5)
    gfx.line(x + math.floor(s / 2) - 1, y + s - 5, x + s - 4, y + 4)
    gfx.line(x + 4, y + math.floor(s / 2) + 1, x + math.floor(s / 2) - 1, y + s - 4)
    gfx.line(x + math.floor(s / 2) - 1, y + s - 4, x + s - 4, y + 5)
  end
end

--- A scrollable list of rows with the mouse wheel and a scrollbar (only when the rows don't all fit). state: a table
--- kept by the caller ({} at first; state.scroll is the first visible row). rows: list of
--- { text, style, note, note_style, checked, bg, header, on_toggle } with style / note_style "muted", "accent", "error",
--- "ok" or nil (normal). A row with `checked` (true, false or "mixed") has a checkbox in front; a click anywhere on the row
--- toggles row.checked, or calls row.on_toggle() when it has one (a header row that sets a whole group). Pressing on a
--- checkbox row and dragging over others sets them all to the same state ("swipe select"). bg: a tint behind the row,
--- "ok" (green) or "error" (red). header: a header row (muted, a faint background). indent: a row without a checkbox
--- whose text lines up with the rows that have one. kind: a short word in a column of its own between the text and the
--- note (the column exists when any row has one).
--- opts: row_h, size. Returns state.scroll.
function Widgets.list_view(win, state, rows, x, y, w, h, opts)
  opts = opts or {}
  local row_h = opts.row_h or Widgets.ROW_H
  local visible, max_scroll = Widgets.list_limits(#rows, row_h, h)
  state.scroll = state.scroll or 0
  local m = win.mouse
  local sw = max_scroll > 0 and Widgets.SCROLLBAR_W or 0
  local track_x = x + w - sw

  if Widgets.is_inside(m.x, m.y, x, y, w, h) then
    state.scroll = Widgets.wheel_scroll(state.scroll, m.wheel or 0, max_scroll)
  end
  local thumb_y, thumb_h = Widgets.list_thumb(y, h, #rows, visible, state.scroll, max_scroll)
  if sw > 0 and m.left and Widgets.is_inside(m.press_x, m.press_y, track_x, y, sw, h) then
    state.scroll = Widgets.scroll_from_thumb(m.y, y, h, thumb_h, max_scroll)
    thumb_y, thumb_h = Widgets.list_thumb(y, h, #rows, visible, state.scroll, max_scroll)
  end
  state.scroll = math.max(0, math.min(max_scroll, state.scroll))
  if not m.left then state.paint = nil end

  Widgets.box(x, y, w, h, Theme.mix(Theme.color("background"), Theme.color("text"), 0.04))
  local note_w = math.floor((w - sw) * 0.4)
  local kind_w = 0
  for _, row in ipairs(rows) do
    if row.kind then kind_w = 90 break end
  end
  for i = 1, visible do
    local row = rows[state.scroll + i]
    if not row then break end
    local ry = y + (i - 1) * row_h
    local text_x = x + 8
    if row.bg then Widgets.box(x, ry, w - sw, row_h, row.bg, 0.16) end
    if row.header then Widgets.box(x, ry, w - sw, row_h, "text", 0.07) end
    if row.checked ~= nil then
      local over = Widgets.is_inside(m.x, m.y, x, ry, w - sw, row_h)
      if over then Widgets.box(x, ry, w - sw, row_h, "text", 0.06) end
      if row.on_toggle then
        local _, _, clicked = Widgets.button_state(m, x, ry, w - sw, row_h)
        if clicked then row.on_toggle() end
      else
        -- swipe select: the row that is pressed sets the state, the others the mouse then passes over get the same
        if over and m.left_pressed then state.paint = not row.checked end
        if over and m.left and state.paint ~= nil then row.checked = state.paint end
      end
      Widgets.draw_check(x + 8, ry + math.floor((row_h - Widgets.CHECK_SIZE) / 2), row.checked)
      text_x = x + 8 + Widgets.CHECK_SIZE + 8
    elseif row.indent then
      text_x = x + 8 + Widgets.CHECK_SIZE + 8
    end
    local text_w = (row.note and (w - sw - note_w - 8) or (w - sw - 8)) - (text_x - x - 8) - kind_w
    if row.kind then
      Widgets.text(row.kind, x + w - sw - note_w - 4 - kind_w, ry, kind_w, row_h, { size = 15, color = "muted" })
    end
    local text = row.text
    Widgets.text(text, text_x, ry, text_w, row_h,
      { size = row.header and 15 or opts.size, color = row.style or (row.header and "muted" or "text") })
    if row.note then
      Widgets.text(row.note, x + w - sw - note_w - 4, ry, note_w, row_h,
        { size = 15, align = "right", color = row.note_style or "muted" })
    end
  end
  if sw > 0 then
    Widgets.box(track_x, y, sw, h, "button")
    Widgets.box(track_x + 2, thumb_y, sw - 4, thumb_h, "muted")
  end
  return state.scroll
end

-- Self test ------------------------------------------------------------------------------

function Widgets.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  check("is_inside: corners", Widgets.is_inside(0, 0, 0, 0, 10, 10) and not Widgets.is_inside(10, 10, 0, 0, 10, 10))
  check("is_inside: nil position", not Widgets.is_inside(nil, nil, 0, 0, 10, 10))

  local function mouse(x, y, px, py, left, released)
    return { x = x, y = y, press_x = px, press_y = py, left = left, left_released = released }
  end
  local _, _, c2 = Widgets.button_state(mouse(5, 5, 50, 50, false, true), 0, 0, 10, 10)
  check("button: press started elsewhere doesn't click", not c2)
  local _, _, c3 = Widgets.button_state(mouse(50, 50, 5, 5, false, true), 0, 0, 10, 10)
  check("button: released elsewhere doesn't click", not c3)
  local o5, h5, c5 = Widgets.button_state(mouse(5, 5, 5, 5, false, true), 0, 0, 10, 10, true)
  check("button: disabled never reacts", not o5 and not h5 and not c5)

  local st = {}
  local p0, f0 = Widgets.hold_step(st, true, 10, 1)
  local p1, f1 = Widgets.hold_step(st, true, 10.5, 1)
  local p2, f2 = Widgets.hold_step(st, true, 11, 1)
  local p3, f3 = Widgets.hold_step(st, true, 12, 1)
  check("hold: progress grows while held", p0 == 0 and not f0 and math.abs(p1 - 0.5) < 1e-9 and not f1)
  check("hold: fires once when the time is reached", p2 == 1 and f2 and p3 == 1 and not f3)
  Widgets.hold_step(st, false, 12.1, 1)
  local p4 = Widgets.hold_step(st, true, 13, 1)
  local p5, f5 = Widgets.hold_step(st, true, 13.5, 1)
  check("hold: release resets, a new hold starts from zero", p4 == 0 and math.abs(p5 - 0.5) < 1e-9 and not f5)
  Widgets.hold_step(st, false, 13.6, 1)
  check("hold: letting go early never fires", select(2, Widgets.hold_step(st, true, 20, 1)) == false)

  local hx, _, hw = Widgets.header_button_rect(0, 0, 300, 44, 130, 100)
  check("header_button_rect: narrower so the centered title stays free", hw == 100 - 11 and hx >= 200)
  check("header_button_rect: never narrower than the minimum",
    select(3, Widgets.header_button_rect(0, 0, 100, 44, 130, 90)) == Widgets.HEADER_BUTTON_MIN_W)

  local timers = {}
  Widgets.repeat_fire(timers, "z", true, true, 0, 0.1) -- the press
  check("repeat: not again before the interval", not Widgets.repeat_fire(timers, "z", true, false, 0.05, 0.1))
  check("repeat: again after the interval", Widgets.repeat_fire(timers, "z", true, false, 0.1, 0.1))
  check("repeat: never on release", not Widgets.repeat_fire(timers, "z", false, false, 0.5, 0.1)
    and timers.z == nil)

  local visible, max_scroll = Widgets.list_limits(10, 24, 100)
  check("list_limits: whole rows only", visible == 4 and max_scroll == 6)
  visible, max_scroll = Widgets.list_limits(3, 24, 100)
  check("list_limits: no scrolling when everything fits", visible == 4 and max_scroll == 0)
  check("list_limits: always at least one row", (Widgets.list_limits(5, 24, 10)) == 1)
  check("wheel: one notch down is one row", Widgets.wheel_scroll(0, -120, 6) == 1 and Widgets.wheel_scroll(3, 120, 6) == 2)
  check("wheel: stays inside the limits", Widgets.wheel_scroll(0, 120, 6) == 0 and Widgets.wheel_scroll(6, -120, 6) == 6)
  check("wheel: a smaller list pulls the position back", Widgets.wheel_scroll(5, 0, 2) == 2)
  local ty, th = Widgets.list_thumb(0, 100, 20, 5, 0, 15)
  check("thumb: at the top for scroll 0", ty == 0 and th == 25)
  ty = Widgets.list_thumb(0, 100, 20, 5, 15, 15)
  check("thumb: at the bottom for the last scroll", ty == 75)
  check("thumb: never smaller than 20 px", select(2, Widgets.list_thumb(0, 100, 1000, 5, 0, 995)) == 20)
  check("thumb drag: middle of the track is half way", Widgets.scroll_from_thumb(50, 0, 100, 20, 10) == 5)
  check("thumb drag: top and bottom are the limits",
    Widgets.scroll_from_thumb(-30, 0, 100, 20, 10) == 0 and Widgets.scroll_from_thumb(500, 0, 100, 20, 10) == 10)

  return results
end

return Widgets
