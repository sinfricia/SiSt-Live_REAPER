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

Not supported (on purpose, for now): undo, multi-line text, input methods for Asian languages.

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

  if key == KEY.ENTER then return "submit", false end
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
    local pasted = (clipboard.get() or ""):gsub("[\r\n\t]+", " ") -- one line only
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

local function sws_clipboard(api)
  if not (api.APIExists and api.APIExists("CF_GetClipboard") and api.APIExists("CF_SetClipboard")) then return nil end
  return { get = function() return api.CF_GetClipboard("") end, set = function(s) api.CF_SetClipboard(s) end }
end

--- Draws the field and handles mouse and keys. Call it every frame.
--- opts: size (font size), disabled. Returns { changed, submitted, escape, blurred, tab, focused }.
function TextField.draw(win, f, x, y, w, h, opts)
  opts = opts or {}
  local ev = {}
  local api = win.api or reaper
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
      local now = api.time_precise()
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
    local clipboard = sws_clipboard(api)
    for _, key in ipairs(win.chars or {}) do
      local event, changed = TextField.apply_key(f, key, mods, clipboard)
      if changed then ev.changed = true; f.blink_start = api.time_precise() end
      if event == "submit" then ev.submitted = true; TextField.blur(win, f); break end
      if event == "escape" then ev.escape = true; break end
      if event == "tab" then ev.tab = true; break end
      if key ~= 0 then f.blink_start = api.time_precise() end
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
  Theme.set(focused and "show" or "line")
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
      Theme.set("show", 0.45)
      gfx.rect(sx, ty, ex - sx, th, true)
    end
  end

  Theme.set("text", opts.disabled and 0.5 or 1)
  gfx.x, gfx.y = x + pad, ty
  gfx.drawstr(join(chars, f.first, last))

  if focused then
    local now = api.time_precise()
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
  check("char_of: ASCII, Latin-1 and unicode codes",
    TextField.char_of(65) == "A" and TextField.char_of(228) == "ä" and TextField.char_of(u(0x20AC)) == "€")
  check("char_of: control and special keys are no characters",
    TextField.char_of(8) == nil and TextField.char_of(K.LEFT) == nil and TextField.char_of(K.DELETE) == nil
    and TextField.char_of(127) == nil and TextField.char_of(u(5)) == nil)

  -- typing
  local f = TextField.new()
  typed(f, { "H", "i", 228, u(0x20AC) })
  check("typing: ASCII, umlaut, euro", f.text == "Hiä€" and f.caret == 4)
  typed(f, { K.LEFT, K.LEFT, "X" })
  check("typing: inserts at the cursor", f.text == "HiXä€" and f.caret == 3)
  typed(f, { K.BACKSPACE, K.DELETE })
  check("backspace and delete remove whole characters", f.text == "Hi€" and f.caret == 2)
  typed(f, { K.HOME, K.BACKSPACE, K.END, K.DELETE })
  check("backspace at the start / delete at the end do nothing", f.text == "Hi€" and f.caret == 3)

  -- selection
  f = TextField.new{ text = "hello world" }
  typed(f, { K.HOME })
  typed(f, { K.RIGHT, K.RIGHT }, { shift = true })
  check("shift+right selects", TextField.selection(f) == 0 and select(2, TextField.selection(f)) == 2)
  typed(f, { "J" })
  check("typing replaces the selection", f.text == "Jllo world" and f.caret == 1)
  typed(f, { K.CTRL_A, K.BACKSPACE })
  check("ctrl+A then backspace clears", f.text == "" and f.caret == 0)
  f = TextField.new{ text = "abc" }
  typed(f, { K.LEFT }, { shift = true })
  typed(f, { K.LEFT })
  check("left with a selection goes to its start", f.caret == 2 and TextField.selection(f) == nil)

  -- words
  f = TextField.new{ text = "Intro für Song 2" }
  typed(f, { K.LEFT }, { ctrl = true })
  check("ctrl+left jumps a word", f.caret == 15)
  typed(f, { K.LEFT, K.LEFT }, { ctrl = true })
  check("ctrl+left over a word with an umlaut", f.caret == 6)
  typed(f, { K.BACKSPACE }, { ctrl = true })
  check("ctrl+backspace deletes the word before", f.text == "für Song 2" and f.caret == 0)
  typed(f, { K.DELETE }, { ctrl = true })
  check("ctrl+delete deletes the word after", f.text == " Song 2")
  check("ctrl+letter is not typed", TextField.apply_key(f, 115, { ctrl = true }) == nil and f.text == " Song 2")

  -- clipboard
  local clip_text = nil
  local clip = { get = function() return "a\r\nb\tc" end, set = function(s) clip_text = s end }
  f = TextField.new{ text = "copy me" }
  typed(f, { K.CTRL_A, K.CTRL_C }, nil, clip)
  check("ctrl+C copies the selection", clip_text == "copy me" and f.text == "copy me")
  typed(f, { K.CTRL_X }, nil, clip)
  check("ctrl+X cuts", f.text == "" and clip_text == "copy me")
  typed(f, { K.CTRL_V }, nil, clip)
  check("ctrl+V pastes one line", f.text == "a b c")
  check("no clipboard: ctrl+V does nothing", select(2, TextField.apply_key(f, K.CTRL_V, {}, nil)) == false)

  -- max length
  f = TextField.new{ text = "abc", max_length = 4 }
  typed(f, { "d", "e" })
  check("max_length: stops typing", f.text == "abcd")
  f.anchor, f.caret = 0, 4
  typed(f, { K.CTRL_V }, nil, { get = function() return "123456" end })
  check("max_length: paste is cut", f.text == "1234")

  -- events
  f = TextField.new{ text = "old" }
  typed(f, { "x" })
  local ev = typed(f, { K.ESC })
  check("esc is only reported, the text stays", ev[1] == "escape" and f.text == "oldx" and f.caret == 4)
  check("enter submits, tab is reported", typed(f, { K.ENTER })[1] == "submit" and typed(f, { K.TAB })[1] == "tab")

  -- layout helpers
  -- a fake font where a string is narrower than its letters added up (like real fonts)
  local function narrow(str) local n = utf8.len(str); return n * 10 - math.max(0, n - 1) end
  local pw = TextField.prefix_widths(TextField.split("abcd"), narrow)
  check("prefix_widths: measured as whole strings", pw[0] == 0 and pw[1] == 10 and pw[4] == 37)
  check("prefix_widths: end of text is where the whole text ends", pw[4] == narrow("abcd"))
  local prefix = { [0] = 0, 10, 20, 30 }
  check("index_at: nearest gap", TextField.index_at(prefix, 3, 4) == 0 and TextField.index_at(prefix, 3, 6) == 1
    and TextField.index_at(prefix, 3, 99) == 3 and TextField.index_at(prefix, 3, -5) == 0)
  local widths = { 10, 10, 10, 10, 10, 10, 10, 10, 10, 10 } -- 10 characters, room for 4
  check("scroll: cursor at the end shows the last characters", TextField.scroll_first(widths, 1, 10, 40) == 7)
  check("scroll: cursor visible: no jump", TextField.scroll_first(widths, 3, 5, 40) == 3)
  check("scroll: cursor left of the view", TextField.scroll_first(widths, 7, 2, 40) == 3)
  check("scroll: back left when there is room", TextField.scroll_first({ 10, 10 }, 2, 2, 40) == 1)

  -- focus
  local win = {}
  local a, b = TextField.new{ text = "aa", select_all = true }, TextField.new{ text = "bb" }
  check("new: select_all selects the whole text", TextField.selection(a) == 0 and select(2, TextField.selection(a)) == 2)
  check("new: without it the cursor is at the end", b.caret == 2 and TextField.selection(b) == nil)
  check("new: select_all on an empty text selects nothing", TextField.selection(TextField.new{ select_all = true }) == nil)
  TextField.focus(win, a)
  check("focus: keeps the selection", TextField.has_focus(win, a) and TextField.selection(a) == 0)
  TextField.focus(win, b)
  check("focus: one field at a time", not TextField.has_focus(win, a) and TextField.has_focus(win, b)
    and b.caret == 2 and TextField.selection(b) == nil)
  TextField.blur(win, b)
  check("blur", not TextField.has_focus(win))

  return results
end

return TextField
