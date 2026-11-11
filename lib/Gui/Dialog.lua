-- @noindex
--[[
SiSt-Live Gui: Dialog

A question with labeled buttons, drawn as a panel over the content of a window (gfx allows one window per script,
so a dialog cannot be a second window). Immediate mode like the Widgets: call Dialog.draw every frame while the
question is open; it returns the id of the button that was clicked, else nil.

  local spec = {
    title = "Open projects and setlist differ",
    accent = "accent",                       -- header color (optional)
    body = {                                 -- strings or { text = ..., style = "muted" | "heading" }
      "These projects are open, but not in the list:",
      { text = "Intro.rpp", style = "muted" },
    },
    buttons = {                              -- shown top to bottom, long labels are fine
      { id = "tabs", label = "Add them to the list", primary = true },
      { id = "list", label = "Close them" },
    },
  }
  local choice = Dialog.draw(win, spec)      -- nil until a button is clicked
  if choice then ... end

spec.row = true puts the buttons in one row at the bottom right (spec.button_w wide each) instead of stacked
full-width ones.

Custom content (a list, tabs): lay = Dialog.frame(spec, { fill = true, max_w = 760 }) draws the panel and returns where
the content goes (lay.content); draw into it, then choice = Dialog.buttons(win, spec, lay). Dialog.draw is the
same with text lines as the content.

The panel dims everything behind it. It does not block input by itself: while a dialog is open the caller skips its
own mouse handling (the Setlist does not handle clicks on the list then).

Pure functions (tested): Dialog.wrap, Dialog.fit, Dialog.layout.
Self test: Dialog.self_test() returns a list of { name, ok }.
]]

local Theme = require("Gui.Theme")
local Widgets = require("Gui.Widgets")

local Dialog = {}

Dialog.MAX_W = 560     -- widest panel
Dialog.PAD = 12        -- space inside the panel and around it (the command area's margin)
Dialog.LINE_H = 24
Dialog.BUTTON_H = 40
Dialog.GAP = 8         -- between buttons
Dialog.BUTTON_W = 160  -- width of a button in a row of buttons
Dialog.BUTTON_TEXT = 17 -- text size of the buttons (the command area's)

--- Splits text into lines no wider than max_w. measure(str) returns the width of a string. Words are kept whole;
--- a word wider than the line gets a line of its own (it is cut off by the drawing).
function Dialog.wrap(text, max_w, measure)
  local lines = {}
  for paragraph in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if line ~= "" and measure(try) > max_w then
        lines[#lines + 1] = line
        line = word
      else
        line = try
      end
    end
    lines[#lines + 1] = line -- an empty paragraph is an empty line
  end
  return lines
end

--- Keeps at most max_lines lines; if lines are cut, the last kept line says how many were left out.
function Dialog.fit(lines, max_lines)
  max_lines = math.max(1, max_lines)
  if #lines <= max_lines then return lines end
  local out = {}
  for i = 1, max_lines - 1 do out[i] = lines[i] end
  out[max_lines] = { text = string.format("... and %d more", #lines - max_lines + 1), style = "muted" }
  return out
end

--- Where everything goes. Returns { x, y, w, h (panel), header_h, body_y, buttons = { {x, y, w, h}, ... },
--- max_lines (how many body lines fit), content = { x, y, w, h } (the area between header and buttons) }.
--- opts: max_w (widest panel, default MAX_W), body_h (a fixed content height instead of n_lines lines),
--- fill (the content takes all the room that is left: for custom content like a list).
function Dialog.layout(win_w, win_h, n_lines, n_buttons, opts)
  opts = opts or {}
  local pad = Dialog.PAD
  local header_h = Widgets.HEADER_H
  local w = math.max(1, math.min(win_w - 2 * pad, opts.max_w or Dialog.MAX_W))
  local buttons_h = opts.row and Dialog.BUTTON_H or (n_buttons * Dialog.BUTTON_H + math.max(0, n_buttons - 1) * Dialog.GAP)
  local room = win_h - 2 * pad - header_h - buttons_h - 3 * pad
  local max_lines = math.max(1, math.floor(room / Dialog.LINE_H))
  local body_h
  if opts.fill then
    body_h = math.max(Dialog.LINE_H, room)
  elseif opts.body_h then
    body_h = math.min(opts.body_h, math.max(Dialog.LINE_H, room))
  else
    body_h = math.min(n_lines, max_lines) * Dialog.LINE_H
  end
  local h = header_h + pad + body_h + pad + buttons_h + pad
  local x = math.floor((win_w - w) / 2)
  local y = math.max(pad, math.floor((win_h - h) / 2))
  local out = { x = x, y = y, w = w, h = h, header_h = header_h, body_y = y + header_h + pad, max_lines = max_lines,
    buttons = {}, content = { x = x + pad, y = y + header_h + pad, w = w - 2 * pad, h = body_h } }
  local by = y + header_h + pad + body_h + pad
  if opts.row then
    -- one row, right-aligned, buttons of equal width (narrower when the panel is)
    local bw = math.min(opts.button_w or Dialog.BUTTON_W, math.floor((w - 2 * pad - (n_buttons - 1) * Dialog.GAP) / math.max(1, n_buttons)))
    local total = n_buttons * bw + (n_buttons - 1) * Dialog.GAP
    for i = 1, n_buttons do
      out.buttons[i] = { x = x + w - pad - total + (i - 1) * (bw + Dialog.GAP), y = by, w = bw, h = Dialog.BUTTON_H }
    end
  else
    for i = 1, n_buttons do
      out.buttons[i] = { x = x + pad, y = by, w = w - 2 * pad, h = Dialog.BUTTON_H }
      by = by + Dialog.BUTTON_H + Dialog.GAP
    end
  end
  return out
end

-- Drawing ----------------------------------------------------------------------------

--- Draws the dim background, the panel and its header, and returns the layout (see Dialog.layout). For dialogs with
--- custom content: draw into lay.content yourself, then call Dialog.buttons. opts: see Dialog.layout (n_lines is 0).
function Dialog.frame(spec, opts)
  opts = opts or {}
  opts.row = opts.row or spec.row
  opts.button_w = opts.button_w or spec.button_w
  local lay = Dialog.layout(gfx.w, gfx.h, 0, #spec.buttons, opts)
  Widgets.box(0, 0, gfx.w, gfx.h, "background", 0.85) -- dim what is behind
  Widgets.box(lay.x, lay.y, lay.w, lay.h, Theme.mix(Theme.color("background"), Theme.color("text"), 0.08))
  Widgets.header(spec.title or "", lay.x, lay.y, lay.w, lay.header_h, spec.accent)
  return lay
end

--- Draws the buttons of spec (see the top) into lay.buttons. Returns the id of the clicked one, else nil.
--- A button may have disabled = true.
function Dialog.buttons(win, spec, lay)
  local clicked = nil
  for i, b in ipairs(spec.buttons) do
    local r = lay.buttons[i]
    local face = nil
    if b.primary then face = Theme.mix(Theme.color("button"), Theme.color("accent"), 0.35) end
    if Widgets.button(win, b.label, r.x, r.y, r.w, r.h,
      { face = face, disabled = b.disabled, size = Dialog.BUTTON_TEXT, id = "dialog:" .. tostring(b.id) }) then
      clicked = clicked or b.id
    end
  end
  return clicked
end

local function body_lines(spec, max_w)
  local measure = function(s) return (gfx.measurestr(s)) end
  Theme.set_font(Widgets.TEXT_SIZE)
  local lines = {}
  for _, item in ipairs(spec.body or {}) do
    local text, style = item, nil
    if type(item) == "table" then text, style = item.text, item.style end
    for _, l in ipairs(Dialog.wrap(text, max_w, measure)) do lines[#lines + 1] = { text = l, style = style } end
  end
  return lines
end

--- Draws a dialog with text and buttons over the whole window and returns the id of the clicked button (nil
--- otherwise). The simple case; for custom content use Dialog.frame and Dialog.buttons.
function Dialog.draw(win, spec)
  local pad = Dialog.PAD
  local lines = body_lines(spec, math.min(gfx.w - 2 * pad, Dialog.MAX_W) - 2 * pad)
  local lay = Dialog.layout(gfx.w, gfx.h, #lines, #spec.buttons, { row = spec.row, button_w = spec.button_w })
  lines = Dialog.fit(lines, lay.max_lines)

  lay = Dialog.frame(spec, { body_h = #lines * Dialog.LINE_H })
  for i, l in ipairs(lines) do
    local color = "text"
    if l.style == "muted" then color = "muted" elseif l.style == "heading" then color = "accent" end
    Widgets.text(l.text, lay.content.x, lay.content.y + (i - 1) * Dialog.LINE_H, lay.content.w, Dialog.LINE_H,
      { color = color })
  end
  return Dialog.buttons(win, spec, lay)
end

-- Self test ------------------------------------------------------------------------------

function Dialog.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function measure(s) return #s end -- one unit per character

  local lines = Dialog.wrap("aaa bbb ccc", 7, measure)
  check("wrap: breaks between words", #lines == 2 and lines[1] == "aaa bbb" and lines[2] == "ccc")
  lines = Dialog.wrap("short", 50, measure)
  check("wrap: short text stays one line", #lines == 1 and lines[1] == "short")
  lines = Dialog.wrap("a\n\nb", 50, measure)
  check("wrap: paragraphs and empty lines are kept", #lines == 3 and lines[2] == "")
  lines = Dialog.wrap("abcdefghijkl mn", 5, measure)
  check("wrap: a long word gets its own line", #lines == 2 and lines[1] == "abcdefghijkl" and lines[2] == "mn")
  check("wrap: empty text is one empty line", #Dialog.wrap("", 10, measure) == 1)

  local many = {}
  for i = 1, 10 do many[i] = { text = "l" .. i } end
  check("fit: enough room keeps everything", #Dialog.fit(many, 10) == 10)
  local cut = Dialog.fit(many, 4)
  check("fit: cut lines are counted in the last line", #cut == 4 and cut[4].text == "... and 7 more" and cut[3].text == "l3")
  check("fit: always at least one line", #Dialog.fit(many, 0) == 1)

  local lay = Dialog.layout(800, 600, 3, 2)
  check("layout: panel is centered and not wider than MAX_W", lay.w == Dialog.MAX_W and lay.x == (800 - lay.w) // 2)
  check("layout: two buttons below the body, in order",
    lay.buttons[1].y >= lay.body_y + 3 * Dialog.LINE_H and lay.buttons[2].y > lay.buttons[1].y)
  check("layout: buttons fit inside the panel",
    lay.buttons[2].y + lay.buttons[2].h <= lay.y + lay.h and lay.buttons[1].x > lay.x)
  lay = Dialog.layout(300, 600, 1, 1)
  check("layout: narrow window shrinks the panel", lay.w == 300 - 2 * Dialog.PAD)
  lay = Dialog.layout(400, 250, 40, 3)
  check("layout: small window limits the body lines", lay.max_lines >= 1 and lay.max_lines < 40)
  lay = Dialog.layout(800, 600, 0, 2, { fill = true, max_w = 760 })
  check("layout: fill uses the room that is left, up to max_w",
    lay.w == 760 and lay.content.h > 300 and lay.buttons[2].y + lay.buttons[2].h <= lay.y + lay.h
    and lay.y + lay.h <= 600)
  lay = Dialog.layout(800, 600, 0, 1, { body_h = 100 })
  check("layout: fixed content height", lay.content.h == 100 and lay.content.y == lay.body_y)
  lay = Dialog.layout(800, 600, 3, 2, { row = true })
  check("layout row: all buttons on one line, right-aligned, equal width",
    lay.buttons[1].y == lay.buttons[2].y and lay.buttons[1].w == lay.buttons[2].w
    and lay.buttons[2].x + lay.buttons[2].w == lay.x + lay.w - Dialog.PAD and lay.buttons[1].x < lay.buttons[2].x)
  lay = Dialog.layout(300, 600, 3, 2, { row = true, button_w = 400 })
  check("layout row: buttons get narrower when the panel is narrow",
    lay.buttons[1].w < 400 and lay.buttons[2].x + lay.buttons[2].w <= lay.x + lay.w - Dialog.PAD)
  lay = Dialog.layout(400, 100, 5, 2)
  check("layout: tiny window still gives one line and a valid top", lay.max_lines == 1 and lay.y >= Dialog.PAD)

  return results
end

return Dialog
