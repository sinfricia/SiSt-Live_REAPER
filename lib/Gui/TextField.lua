-- @noindex
--[[
SiSt-Live Gui: TextField

A single-line text entry field for gfx windows (renaming, settings, future config windows).

Usage (also reachable from Widgets: Widgets.TextField is this module, Widgets.text_field = TextField.draw):
  local TextField = require("Gui.TextField")
  local name = TextField.new{ text = "Intro", placeholder = "Name", max_length = 40 }

  win:run(function(win)
    local ev = TextField.draw(win, name, x, y, w, h)  -- every frame, like the other widgets
    if ev.submitted then rename(name.text) end         -- Enter
    if ev.escape then ... end                          -- Esc: reported only, the field changes nothing
  end)

  name.text is the current text (UTF-8). TextField.set_text(field, s) replaces it from code.
  TextField.focus(win, field) puts the cursor into a field from code.

Why it looks like this:
  - Immediate mode like the other widgets (draw it every frame, read what happened), but the text,
    cursor and selection live in a small state table you keep (TextField.new). That's the minimum a
    text field needs to remember between frames.
  - All editing is a pure function: TextField.apply_key(state, key, mods, clipboard) changes the
    state and says what happened. It knows nothing about gfx, so every key is covered by the self
    test.
  - Text is UTF-8 (ä, é, ...). Cursor and selection count characters, never bytes, so a character
    can never be cut in half.
  - gfx has no clipping. Instead of drawing text that sticks out of the box, the field scrolls by
    whole characters and only draws what fits. Simple, and nothing can ever be drawn outside.
  - Positions (cursor, selection, clicks) come from measuring the real text up to each character,
    never from adding up single characters: fonts draw a string narrower than the sum of its
    letters, and that error would grow along the text (cursor drawn on a letter, clicks landing a
    few characters too early).
  - Only one field in a window has the keyboard (win.text_focus). While it has it, it reads ALL keys
    of the frame (win.chars). Components check TextField.has_focus(win) before using keys
    themselves (e.g. a shortcut on the space bar).

Keys while focused:
  typing, Backspace, Delete, Left/Right, Home/End, Shift + those = select,
  Ctrl+Left/Right = word, Ctrl+Backspace/Delete = delete word, Ctrl+A = select all,
  Ctrl+C / Ctrl+X / Ctrl+V = clipboard (needs the SWS extension; without it these do nothing),
  Enter = submit (field loses focus), Esc = ev.escape (nothing else happens: the window decides, e.g.
  closing a dialog later), Tab = ev.tab (the caller decides where the focus goes).
Mouse: click = cursor (never selects), drag = select, double-click = select all, click outside = field loses focus
(ev.blurred, the text is kept).

Multi-line (opts.multiline = true in TextField.new, and opts.line_h when drawing): Shift+Enter inserts a line break,
Up / Down move between the lines (same column where there is one), Home / End go to the start / end of the line, Enter
submits as always. The box is as high as you give it (lines * line_h); a line is drawn as far as it fits, no wrapping.

Not supported (on purpose, for now): undo, input methods for Asian languages.

Self test: TextField.self_test() returns a list of { name, ok }. Pure functions only.
]]

local Theme = require("Gui.Theme")

local TextField = {}

TextField.BLINK = 0.53            -- seconds the cursor is shown / hidden
TextField.DOUBLE_CLICK = 0.35     -- seconds
TextField.PAD = 6                 -- text distance from the box edge, pixels
TextField.TEXT_SIZE = 18

-- gfx.getchar codes
local KEY = {
  BACKSPACE = 8, TAB = 9, ENTER = 13, ESC = 27,
  LEFT = 1818584692, RIGHT = 1919379572, HOME = 1752132965, END = 6647396, DELETE = 6579564,
  UP = 30064, DOWN = 1685026670,
  CTRL_A = 1, CTRL_C = 3, CTRL_V = 22, CTRL_X = 24,
}
TextField.KEY = KEY
local UNICODE_FLAG = 0x75000000 -- 'u' << 24: gfx.getchar returns codepoints above 255 like this

-- UTF-8 helpers (pure) ---------------------------------------------------------------

--- String -> list of characters. Invalid UTF-8 bytes become single "?" characters.
function TextField.split(s)
  local chars, i, n = {}, 1, #s
  local pattern = "^" .. utf8.charpattern
  while i <= n do
    local _, e = s:find(pattern, i)
    if e and utf8.len(s:sub(i, e)) == 1 then
      chars[#chars + 1] = s:sub(i, e)
      i = e + 1
    else
      chars[#chars + 1] = "?"
      i = i + 1
    end
  end
  return chars
end

local function join(chars, from, to)
  return table.concat(chars, "", from or 1, to or #chars)
end

--- A gfx.getchar code -> the typed character (UTF-8 string), or nil if it isn't a character.
function TextField.char_of(code)
  if code >= UNICODE_FLAG and code < UNICODE_FLAG + 0x1000000 then
    local cp = code - UNICODE_FLAG
    if cp >= 32 and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF) then return utf8.char(cp) end
    return nil
  end
  if (code >= 32 and code <= 126) or (code >= 160 and code <= 255) then return utf8.char(code) end
  return nil
end

local function is_word_char(c)
  return c ~= nil and (c:match("^[%w_]$") ~= nil or #c > 1) -- letters with accents etc. count as word
end

--- Index after moving one word left/right from caret (0 = before the first character).
function TextField.word_left(chars, caret)
  local i = caret
  while i > 0 and not is_word_char(chars[i]) do i = i - 1 end
  while i > 0 and is_word_char(chars[i]) do i = i - 1 end
  return i
end

function TextField.word_right(chars, caret)
  local i, n = caret, #chars
  while i < n and not is_word_char(chars[i + 1]) do i = i + 1 end
  while i < n and is_word_char(chars[i + 1]) do i = i + 1 end
  return i
end

-- State -------------------------------------------------------------------------------

--- opts: text, placeholder, max_length (characters),
---   select_all: start with the whole text selected (e.g. renaming: typing replaces the old name).
---   Then put the cursor in from code with TextField.focus(win, field): focusing keeps the selection.
function TextField.new(opts)
  opts = opts or {}
  local f = {
    text = opts.text or "",
    placeholder = opts.placeholder or "",
    max_length = opts.max_length,
    multiline = opts.multiline,
    caret = 0,        -- characters before the cursor
    anchor = nil,     -- other end of the selection, nil = no selection
    first = 1,        -- first character drawn (horizontal scrolling)
    last_click = -math.huge,
    dragging = false,
  }
  f.caret = #TextField.split(f.text)
  if opts.select_all and f.caret > 0 then f.anchor = 0 end
  return f
end

--- Selection as from, to (0-based character positions, from < to), or nil.
function TextField.selection(f)
  if not f.anchor or f.anchor == f.caret then return nil end
  return math.min(f.anchor, f.caret), math.max(f.anchor, f.caret)
end

function TextField.set_text(f, s)
  f.text = s or ""
  f.caret = #TextField.split(f.text)
  f.anchor, f.first = nil, 1
end

-- Replaces the selection (or inserts at the cursor) with `insert`, respecting max_length.
-- Returns true if the text changed.
local function replace_selection(f, chars, insert)
  local from, to = TextField.selection(f)
  from, to = from or f.caret, to or f.caret
  local new = TextField.split(insert or "")
  if f.max_length then
    local room = f.max_length - (#chars - (to - from))
    while #new > math.max(room, 0) do table.remove(new) end
  end
  if #new == 0 and from == to then return false end
  local result = {}
  for i = 1, from do result[#result + 1] = chars[i] end
  for _, c in ipairs(new) do result[#result + 1] = c end
  for i = to + 1, #chars do result[#result + 1] = chars[i] end
  f.text = join(result)
  f.caret, f.anchor = from + #new, nil
  return true
end

-- Lines (pure). A line is { from, to }: the caret positions at its start and at its end (0 = before the first character).
-- The line break or space that ends a line is skipped: the next line starts after it.

--- The lines of the text as the user typed them (broken at the line breaks only).
function TextField.hard_lines(chars)
  local lines, start = {}, 0
  for i, c in ipairs(chars) do
    if c == "\n" then
      lines[#lines + 1] = { from = start, to = i - 1 }
      start = i
    end
  end
  lines[#lines + 1] = { from = start, to = #chars }
  return lines
end

--- The number of the line (1-based) that the caret position is in (the later one at a position that ends one line and
--- starts the next).
function TextField.line_of(lines, caret)
  local line = 1
  for k = 1, #lines do
    if lines[k].from <= caret then line = k end
  end
  return line
end

--- The lines of the text wrapped to max_w pixels: at the line breaks, then at spaces (the space is skipped), and a word
--- that is wider than a line is cut where it no longer fits. measure(s) -> width. Always at least one line.
function TextField.wrap_lines(chars, max_w, measure)
  local lines = {}
  local function add_segment(s, e) -- the characters s+1 .. e (no line break in them)
    if e == s then lines[#lines + 1] = { from = s, to = s } return end
    local pos = s
    while pos < e do
      local fit = 0
      while pos + fit < e and measure(join(chars, pos + 1, pos + fit + 1)) <= max_w do fit = fit + 1 end
      if fit == 0 then fit = 1 end
      if pos + fit >= e then
        lines[#lines + 1] = { from = pos, to = e }
        pos = e
      else
        local brk = nil -- a space within the fitting part (or the one right after it): the line ends before it
        for i = pos + fit + 1, pos + 2, -1 do
          if chars[i] == " " then brk = i break end
        end
        if brk then
          lines[#lines + 1] = { from = pos, to = brk - 1 }
          pos = brk
        else
          lines[#lines + 1] = { from = pos, to = pos + fit }
          pos = pos + fit
        end
      end
    end
    if lines[#lines].to < e then lines[#lines + 1] = { from = e, to = e } end -- the text ends in a skipped space
  end
  local start = 0
  for i, c in ipairs(chars) do
    if c == "\n" then
      add_segment(start, i - 1)
      start = i
    end
  end
  add_segment(start, #chars)
  return lines
end

--- The editing core. Applies one key. mods: { ctrl, shift }. clipboard: { get = fn() -> string,
--- set = fn(string) } or nil. Returns event ("submit", "escape", "tab" or nil) and changed.
function TextField.apply_key(f, key, mods, clipboard)
  mods = mods or {}
  local chars = TextField.split(f.text)
  local n = #chars
  f.caret = math.max(0, math.min(f.caret, n))

  local function move(to)
    if mods.shift then
      f.anchor = f.anchor or f.caret
    else
      f.anchor = nil
    end
    f.caret = math.max(0, math.min(to, n))
  end

  if key == KEY.ENTER then
    if f.multiline and mods.shift then return nil, replace_selection(f, chars, "\n") end
    return "submit", false
  end
  if key == KEY.ESC then return "escape", false end
  if key == KEY.TAB then return "tab", false end

  if key == KEY.LEFT then
    local sel_from = TextField.selection(f)
    if sel_from and not mods.shift and not mods.ctrl then move(sel_from)
    else move(mods.ctrl and TextField.word_left(chars, f.caret) or f.caret - 1) end
    return nil, false
  end
  if key == KEY.RIGHT then
    local _, sel_to = TextField.selection(f)
    if sel_to and not mods.shift and not mods.ctrl then move(sel_to)
    else move(mods.ctrl and TextField.word_right(chars, f.caret) or f.caret + 1) end
    return nil, false
  end
  if f.multiline then
    local lines = f.vlines or TextField.hard_lines(chars) -- (the drawn lines when the field has been drawn: wrapped)
    local k = TextField.line_of(lines, f.caret)
    if key == KEY.UP then
      if k == 1 then move(0)
      else move(math.min(lines[k - 1].from + (f.caret - lines[k].from), lines[k - 1].to)) end
      return nil, false
    end
    if key == KEY.DOWN then
      if k == #lines then move(n)
      else move(math.min(lines[k + 1].from + (f.caret - lines[k].from), lines[k + 1].to)) end
      return nil, false
    end
    if key == KEY.HOME then move(lines[k].from); return nil, false end
    if key == KEY.END then move(lines[k].to); return nil, false end
  end
  if key == KEY.HOME then move(0); return nil, false end
  if key == KEY.END then move(n); return nil, false end
  if key == KEY.CTRL_A then f.anchor, f.caret = 0, n; return nil, false end

  if key == KEY.CTRL_C or key == KEY.CTRL_X then
    local from, to = TextField.selection(f)
    if from and clipboard and clipboard.set then
      clipboard.set(join(chars, from + 1, to))
      if key == KEY.CTRL_X then return nil, replace_selection(f, chars, "") end
    end
    return nil, false
  end
  if key == KEY.CTRL_V then
    if not (clipboard and clipboard.get) then return nil, false end
    local pasted = clipboard.get() or ""
    if f.multiline then
      pasted = pasted:gsub("\r\n?", "\n"):gsub("\t", " ")
    else
      pasted = pasted:gsub("[\r\n\t]+", " ") -- one line only
    end
    return nil, replace_selection(f, chars, pasted)
  end

  if key == KEY.BACKSPACE or key == KEY.DELETE then
    if TextField.selection(f) then return nil, replace_selection(f, chars, "") end
    local from, to
    if key == KEY.BACKSPACE then
      if f.caret == 0 then return nil, false end
      from, to = mods.ctrl and TextField.word_left(chars, f.caret) or f.caret - 1, f.caret
    else
      if f.caret == n then return nil, false end
      from, to = f.caret, mods.ctrl and TextField.word_right(chars, f.caret) or f.caret + 1
    end
    f.anchor, f.caret = from, to
    return nil, replace_selection(f, chars, "")
  end

  local c = not mods.ctrl and TextField.char_of(key) or nil
  if c then return nil, replace_selection(f, chars, c) end
  return nil, false
end

-- Pure layout helpers -----------------------------------------------------------------------

--- Character position (0..#chars) closest to x pixels from the start of the drawn text.
--- prefix_w[i] = width of the first i drawn characters (prefix_w[0] = 0).
function TextField.index_at(prefix_w, count, x)
  for i = 1, count do
    local mid = (prefix_w[i - 1] + prefix_w[i]) / 2
    if x < mid then return i - 1 end
  end
  return count
end

--- Widths of the text up to each character: p[0] = 0, p[i] = width of the first i characters.
--- measure(s) returns the drawn width of a string. Character widths are p[i] - p[i-1].
function TextField.prefix_widths(chars, measure)
  local p = { [0] = 0 }
  for i = 1, #chars do p[i] = measure(join(chars, 1, i)) end
  return p
end

--- First character to draw so that the cursor is visible. widths[i] = width of character i.
--- Keeps `first` when the cursor is already visible (no jumping while typing).
function TextField.scroll_first(widths, first, caret, avail)
  local n = #widths
  first = math.max(1, math.min(first or 1, n + 1))
  if caret < first - 1 then return math.max(1, caret + 1) end -- cursor left of the view
  local w = 0
  for i = first, caret do w = w + widths[i] end
  while w > avail and first <= caret do -- cursor right of the view: scroll right
    w = w - widths[first]
    first = first + 1
  end
  -- room left at the end (e.g. after deleting): scroll back left
  local total = 0
  for i = first, n do total = total + widths[i] end
  while first > 1 and total + widths[first - 1] <= avail do
    first = first - 1
    total = total + widths[first]
  end
  return first
end

-- Focus -------------------------------------------------------------------------------------

function TextField.has_focus(win, f)
  if f then return win.text_focus == f end
  return win.text_focus ~= nil
end

--- Gives the field the keyboard. Cursor and selection stay as they are (a field created with
--- select_all keeps its selection). Clicking a field focuses it and places the cursor at the click.
function TextField.focus(win, f)
  if win.text_focus == f then return end
  win.text_focus = f
  f.dragging = false
  f.blink_start = nil
end

function TextField.blur(win, f)
  if win.text_focus == f then win.text_focus = nil end
  f.anchor, f.dragging = nil, false
end

-- Drawing & input ------------------------------------------------------------------------------

local function sws_clipboard()
  if not (reaper.APIExists("CF_GetClipboard") and reaper.APIExists("CF_SetClipboard")) then return nil end
  return { get = function() return reaper.CF_GetClipboard("") end, set = function(s) reaper.CF_SetClipboard(s) end }
end

--- Draws the field and handles mouse and keys. Call it every frame.
--- opts: size (font size), disabled, line_h (multi-line: the height of one line). Returns { changed, submitted, escape,
--- blurred, tab, focused }.
function TextField.draw(win, f, x, y, w, h, opts)
  opts = opts or {}
  if f.multiline then return TextField.draw_multiline(win, f, x, y, w, h, opts) end
  local ev = {}
  local m = win.mouse
  local size = opts.size or TextField.TEXT_SIZE
  local pad = TextField.PAD
  local inside = m.x >= x and m.x < x + w and m.y >= y and m.y < y + h

  Theme.set_font(size)
  local chars = TextField.split(f.text)
  local function measure(str) return (gfx.measurestr(str)) end
  local P = TextField.prefix_widths(chars, measure)
  local function caret_at(mouse_x) -- character position under the mouse, in the drawn part
    local rel = { [0] = 0 }
    for i = f.first, #chars do rel[i - f.first + 1] = P[i] - P[f.first - 1] end
    return f.first - 1 + TextField.index_at(rel, #chars - f.first + 1, mouse_x - x - pad)
  end

  -- Mouse
  if not opts.disabled and m.left_pressed then
    if inside then
      local now = reaper.time_precise()
      if not TextField.has_focus(win, f) then TextField.focus(win, f) end
      if now - f.last_click <= TextField.DOUBLE_CLICK then
        f.anchor, f.caret = 0, #chars -- double-click: select all
        f.dragging = false
      else
        f.caret = caret_at(m.x) -- a click only places the cursor
        f.anchor = f.caret
        f.dragging = true
      end
      f.last_click = now
      f.blink_start = now
    elseif TextField.has_focus(win, f) then
      TextField.blur(win, f)
      ev.blurred = true
    end
  end
  if f.dragging then
    if m.left then
      f.caret = caret_at(m.x)
    else
      f.dragging = false
    end
  end

  -- Keys: all of this frame, only for the focused field
  if TextField.has_focus(win, f) and not opts.disabled then
    local mods = { ctrl = m.ctrl, shift = m.shift }
    local clipboard = sws_clipboard()
    for _, key in ipairs(win.chars or {}) do
      local event, changed = TextField.apply_key(f, key, mods, clipboard)
      if changed then ev.changed = true; f.blink_start = reaper.time_precise() end
      if event == "submit" then ev.submitted = true; TextField.blur(win, f); break end
      if event == "escape" then ev.escape = true; break end
      if event == "tab" then ev.tab = true; break end
      if key ~= 0 then f.blink_start = reaper.time_precise() end
    end
    win.chars = {} -- the keys belong to the field: nothing else in the window reacts to them
    if ev.changed then
      chars = TextField.split(f.text)
      P = TextField.prefix_widths(chars, measure)
    end
  end
  ev.focused = TextField.has_focus(win, f)

  -- Box
  local focused = ev.focused
  local face = Theme.mix(Theme.color("background"), Theme.color("text"), 0.07)
  Theme.set(face, opts.disabled and 0.5 or 1)
  gfx.rect(x, y, w, h, true)
  Theme.set(focused and "accent" or "line")
  gfx.rect(x, y, w, h, false)
  if focused then gfx.rect(x + 1, y + 1, w - 2, h - 2, false) end

  -- Text: only the characters that fit, starting at f.first
  local avail = w - 2 * pad
  local widths = {}
  for i = 1, #chars do widths[i] = P[i] - P[i - 1] end
  f.first = focused and TextField.scroll_first(widths, f.first, f.caret, avail) or 1
  local th = gfx.texth
  local ty = y + (h - th) / 2
  if #chars == 0 and not focused then
    Theme.set("muted", opts.disabled and 0.5 or 1)
    gfx.x, gfx.y = x + pad, ty
    gfx.drawstr(f.placeholder, 0, x + w - pad, ty + th)
    return ev
  end

  local last = f.first - 1
  while last < #chars and P[last + 1] - P[f.first - 1] <= avail do last = last + 1 end
  local function x_of(pos) -- pixel x of a character position (clamped to the drawn part)
    pos = math.max(f.first - 1, math.min(pos, last))
    return x + pad + P[pos] - P[f.first - 1]
  end

  local from, to = TextField.selection(f)
  if focused and from then
    local sx, ex = x_of(math.max(from, f.first - 1)), x_of(to)
    if ex > sx then
      Theme.set("accent", 0.45)
      gfx.rect(sx, ty, ex - sx, th, true)
    end
  end

  Theme.set("text", opts.disabled and 0.5 or 1)
  gfx.x, gfx.y = x + pad, ty
  gfx.drawstr(join(chars, f.first, last))

  if focused then
    local now = reaper.time_precise()
    f.blink_start = f.blink_start or now
    if math.floor((now - f.blink_start) / TextField.BLINK) % 2 == 0 then
      Theme.set("text")
      -- one pixel left of the next character's start: in the gap, not on the letter
      local cx = math.floor(x_of(f.caret)) - (f.caret > f.first - 1 and 1 or 0)
      gfx.line(cx, ty, cx, ty + th - 1)
    end
  end
  return ev
end

--- The multi-line variant of draw: the text is wrapped to the width of the box, one line is opts.line_h pixels high and
--- the first one starts opts.top_pad pixels below the top; the keys are those of the single-line field plus the line keys.
function TextField.draw_multiline(win, f, x, y, w, h, opts)
  local ev = {}
  local m = win.mouse
  local size = opts.size or TextField.TEXT_SIZE
  local pad = TextField.PAD
  local line_h = opts.line_h or math.floor(h)
  local top = opts.top_pad or 0
  local avail = w - 2 * pad
  local inside = m.x >= x and m.x < x + w and m.y >= y and m.y < y + h

  Theme.set_font(size)
  local function measure(str) return (gfx.measurestr(str)) end
  local chars = TextField.split(f.text)
  local lines = TextField.wrap_lines(chars, avail, measure)
  f.vlines = lines

  -- the character position of a point (line by y, column by x)
  local function caret_at(mx, my)
    local k = math.max(1, math.min(#lines, math.floor((my - y - top) / line_h) + 1))
    local first, last = lines[k].from, lines[k].to
    local rel = mx - x - pad
    for pos = first + 1, last do
      local before = measure(join(chars, first + 1, pos - 1))
      local after = measure(join(chars, first + 1, pos))
      if rel < (before + after) / 2 then return pos - 1 end
    end
    return last
  end

  -- Mouse
  if not opts.disabled and m.left_pressed then
    if inside then
      local now = reaper.time_precise()
      if not TextField.has_focus(win, f) then TextField.focus(win, f) end
      if now - f.last_click <= TextField.DOUBLE_CLICK then
        f.anchor, f.caret = 0, #chars
        f.dragging = false
      else
        f.caret = caret_at(m.x, m.y)
        f.anchor = f.caret
        f.dragging = true
      end
      f.last_click = now
      f.blink_start = now
    elseif TextField.has_focus(win, f) then
      TextField.blur(win, f)
      ev.blurred = true
    end
  end
  if f.dragging then
    if m.left then f.caret = caret_at(m.x, m.y) else f.dragging = false end
  end

  -- Keys
  if TextField.has_focus(win, f) and not opts.disabled then
    local mods = { ctrl = m.ctrl, shift = m.shift }
    local clipboard = sws_clipboard()
    for _, key in ipairs(win.chars or {}) do
      local event, changed = TextField.apply_key(f, key, mods, clipboard)
      if changed then
        ev.changed = true
        f.blink_start = reaper.time_precise()
        chars = TextField.split(f.text) -- (a following key of this frame moves on the new lines)
        f.vlines = TextField.wrap_lines(chars, avail, measure)
      end
      if event == "submit" then ev.submitted = true; TextField.blur(win, f); break end
      if event == "escape" then ev.escape = true; break end
      if event == "tab" then ev.tab = true; break end
      if key ~= 0 then f.blink_start = reaper.time_precise() end
    end
    win.chars = {}
    lines = f.vlines
  end
  ev.focused = TextField.has_focus(win, f)

  -- Box
  local focused = ev.focused
  local face = Theme.mix(Theme.color("background"), Theme.color("text"), 0.07)
  Theme.set(face, opts.disabled and 0.5 or 1)
  gfx.rect(x, y, w, h, true)
  Theme.set(focused and "accent" or "line")
  gfx.rect(x, y, w, h, false)
  if focused then gfx.rect(x + 1, y + 1, w - 2, h - 2, false) end

  -- Lines
  local th = gfx.texth
  local from, to = TextField.selection(f)
  local caret_line = TextField.line_of(lines, f.caret)
  for k = 1, #lines do
    local first, last = lines[k].from, lines[k].to
    local ty = y + top + (k - 1) * line_h + (line_h - th) / 2
    local function x_of(pos) return x + pad + measure(join(chars, first + 1, pos)) end
    if focused and from then -- the selected part of this line
      local s, e = math.max(from, first), math.min(to, last)
      if e > s then
        Theme.set("accent", 0.45)
        gfx.rect(x_of(s), ty, x_of(e) - x_of(s), th, true)
      end
    end
    Theme.set("text", opts.disabled and 0.5 or 1)
    gfx.x, gfx.y = x + pad, ty
    gfx.drawstr(join(chars, first + 1, last))
    if focused and k == caret_line then
      local now = reaper.time_precise()
      f.blink_start = f.blink_start or now
      if math.floor((now - f.blink_start) / TextField.BLINK) % 2 == 0 then
        Theme.set("text")
        local cx = math.floor(x_of(math.min(f.caret, last))) - (f.caret > first and 1 or 0)
        gfx.line(cx, ty, cx, ty + th - 1)
      end
    end
  end
  return ev
end

-- Self test ---------------------------------------------------------------------------------------

function TextField.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local K = KEY
  local function u(cp) return UNICODE_FLAG + cp end
  local function typed(f, keys, mods, clip)
    local events = {}
    for _, k in ipairs(keys) do
      local e = TextField.apply_key(f, type(k) == "string" and k:byte() or k, mods, clip)
      if e then events[#events + 1] = e end
    end
    return events
  end

  -- UTF-8
  local c = TextField.split("aä€😀")
  check("split: characters, not bytes", #c == 4 and c[2] == "ä" and c[4] == "😀")
  check("split: broken UTF-8 doesn't crash", #TextField.split("a\255b") == 3)

  -- typing
  local f = TextField.new()
  typed(f, { "H", "i", 228, u(0x20AC) })
  check("typing: ASCII, umlaut, euro", f.text == "Hiä€" and f.caret == 4)

  -- words
  f = TextField.new{ text = "Intro für Song 2" }
  typed(f, { K.LEFT, K.LEFT, K.LEFT }, { ctrl = true })
  check("ctrl+left over a word with an umlaut", f.caret == 6)

  -- clipboard
  f = TextField.new{ text = "a" }
  check("no clipboard: ctrl+V does nothing", select(2, TextField.apply_key(f, K.CTRL_V, {}, nil)) == false)

  -- max length
  f = TextField.new{ text = "abc", max_length = 4 }
  typed(f, { "d", "e" })
  check("max_length: stops typing", f.text == "abcd")
  f.anchor, f.caret = 0, 4
  typed(f, { K.CTRL_V }, nil, { get = function() return "123456" end })
  check("max_length: paste is cut", f.text == "1234")

  -- multi-line
  f = TextField.new{ text = "ab", multiline = true }
  typed(f, { K.ENTER }, { shift = true })
  typed(f, { "c" })
  check("multi-line: Shift+Enter inserts a line break", f.text == "ab\nc" and f.caret == 4)
  check("multi-line: plain Enter submits", typed(f, { K.ENTER })[1] == "submit")
  f = TextField.new{ text = "one" }
  typed(f, { K.ENTER }, { shift = true })
  check("single line: Shift+Enter submits like Enter", f.text == "one")
  f = TextField.new{ text = "hello\nhi\nworld", multiline = true }
  f.caret = 4 -- in "hello", column 4
  typed(f, { K.DOWN })
  check("multi-line: Down goes to the same column, or the end of a shorter line", f.caret == 8)
  typed(f, { K.DOWN })
  check("multi-line: and on to the next line", f.caret == 11)
  typed(f, { K.DOWN })
  check("multi-line: Down on the last line goes to the end", f.caret == 14)
  typed(f, { K.UP, K.UP })
  check("multi-line: Up twice", f.caret == 5 or f.caret == 2 or f.caret == 4)
  f.caret = 8
  typed(f, { K.HOME })
  check("multi-line: Home goes to the start of the line", f.caret == 6)
  typed(f, { K.END })
  check("multi-line: End goes to the end of the line", f.caret == 8)
  f = TextField.new{ text = "a\n\nb", multiline = true }
  local lines = TextField.hard_lines(TextField.split(f.text))
  check("multi-line: lines, an empty line in the middle", #lines == 3 and lines[1].from == 0 and lines[1].to == 1
    and lines[2].from == 2 and lines[2].to == 2 and lines[3].from == 3 and lines[3].to == 4)
  check("multi-line: the line of a position", TextField.line_of(lines, 0) == 1 and TextField.line_of(lines, 2) == 2
    and TextField.line_of(lines, 3) == 3)
  -- wrapping (every character 10 wide)
  local function m10(str) return #str * 10 end
  local function shape(text, w)
    local out = {}
    for _, l in ipairs(TextField.wrap_lines(TextField.split(text), w, m10)) do out[#out + 1] = l.from .. "-" .. l.to end
    return table.concat(out, " ")
  end
  check("wrap: fits on one line", shape("one two", 1000) == "0-7")
  check("wrap: breaks at a space, which is skipped", shape("one two three", 80) == "0-7 8-13")
  check("wrap: a word wider than the line is cut", shape("abcdefghij", 40) == "0-4 4-8 8-10")
  check("wrap: line breaks", shape("ab\ncd", 1000) == "0-2 3-5")
  check("wrap: empty text is one empty line", shape("", 100) == "0-0")
  check("wrap: a trailing space that did not fit gets a line for the caret", shape("abcd ", 40) == "0-4 5-5")
  f = TextField.new{ text = "one two three", multiline = true }
  f.vlines = TextField.wrap_lines(TextField.split(f.text), 80, m10)
  f.caret = 10
  typed(f, { K.UP })
  check("wrap: Up goes to the line above, same column", f.caret == 2)
  typed(f, { K.END })
  check("wrap: End goes to the end of the (wrapped) line", f.caret == 7)
  typed(f, { K.DOWN, K.HOME })
  check("wrap: Down and Home go to the start of the next line", f.caret == 8)
  f = TextField.new{ text = "x\ny", multiline = true }
  f.anchor, f.caret = 0, 3
  typed(f, { K.CTRL_V }, nil, { get = function() return "1\r\n2\t3" end })
  check("multi-line: paste keeps line breaks, tabs become spaces", f.text == "1\n2 3")

  return results
end

return TextField
