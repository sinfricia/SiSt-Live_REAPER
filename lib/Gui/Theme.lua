-- @noindex
--[[
SiSt-Live Gui: Theme

Colors and fonts shared by all SiSt-Live windows.

Components ask for ROLES, never for REAPER theme keys:
  Theme.set("text")             -- gfx.set to the text color of the current REAPER theme
  Theme.set("accent", 0.5)      -- accent colors work the same way, with an optional alpha
  Theme.set({ 1, 0, 0 })        -- a color table is accepted too
  Theme.set_font(18)            -- the shared font face at size 18
  gfx.clear = Theme.clear_color()

The colors are read from the REAPER theme once, on first use (or by calling Theme.load()).
A theme change while a window is open is not picked up: reopen the window to get the new colors.

Where the colors come from:
  ROLES    read from the REAPER theme. Each role lists theme keys to try in order. The first one
           the theme defines wins. If none is defined, the fallback color is used.
  DERIVED  mixed from two roles, so they follow the theme without needing extra theme keys.
  ACCENTS  fixed colors with a meaning that must not change with the theme (accent, toggle, ok, error).
           An accent may carry header = <0..1>: how strongly a Widgets header mixes it into the background.
           A package adds its own accents once per script, e.g. SiSt-Live's Status Display:
             Theme.configure({ accents = { edit = { 1.00, 0.50, 0.20, header = 0.60 } } })

Adding a role: add one line to ROLES or DERIVED. Check the result with Theme.diagnostics()
(the status display logs it at startup when SiSt-Live debug logging is on).

Fonts: the shared face is set here, in one place (Theme.FONT_FACE, Arial). REAPER has no API for the theme's fonts, but it
keeps them in reaper.ini as LOGFONT structures in hex (lb_font = the list box font, user_font1 ... ): a window that wants
the font of the REAPER theme calls Theme.use_reaper_font() once at its start.

Self test: Theme.self_test() returns a list of { name, ok }. Uses fake REAPER functions (SelfTest.with_reaper).
]]

local Theme = {}

Theme.FONT_FACE = "Arial"
Theme.FONT_SLOT = 1

-- Shown for a role that doesn't exist, so a typo is visible on screen instead of failing silently
Theme.MISSING_COLOR = { 1, 0, 1 }

-- If text and background are closer than this in brightness (0..1), the text color is replaced
-- by black or white. Protects against themes where the keys used here don't fit together.
Theme.MIN_CONTRAST = 0.3

Theme.ROLES = {
  background = { keys = { "col_main_bg2", "col_main_bg" }, fallback = { 0.18, 0.18, 0.18 } },
  text       = { keys = { "col_main_text2", "col_main_text" }, fallback = { 0.90, 0.90, 0.90 } },
}

-- name = { from role, to role, amount 0..1 }
Theme.DERIVED = {
  button = { "background", "text", 0.18 }, -- button face
  muted  = { "background", "text", 0.60 }, -- secondary text
  line   = { "background", "text", 0.25 }, -- dividers
}

Theme.ACCENTS = {
  accent = { 0.25, 0.67, 0.60 }, -- teal: focus, default header (same teal as the Setlist's show highlight)
  toggle = { 0.30, 0.90, 0.80 }, -- toggle buttons that are on (brighter and more cyan than "accent")
  ok    = { 0.30, 0.78, 0.40 },
  error = { 0.92, 0.26, 0.24, header = 0.60 },
}

--- Adds (or replaces) accents: opts.accents = { name = { r, g, b[, a], header = amount } }.
function Theme.configure(opts)
  for name, color in pairs((opts or {}).accents or {}) do Theme.ACCENTS[name] = color end
end

-- Pure helpers ------------------------------------------------------------

function Theme.mix(a, b, amount)
  return {
    a[1] + (b[1] - a[1]) * amount,
    a[2] + (b[2] - a[2]) * amount,
    a[3] + (b[3] - a[3]) * amount,
  }
end

-- Perceived brightness 0..1 (Rec. 601 weights)
function Theme.luminance(c)
  return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

-- Black or white, whichever is readable on the given color
function Theme.text_on(c)
  if Theme.luminance(c) > 0.55 then return { 0, 0, 0 } end
  return { 1, 1, 1 }
end

-- Color table -> value for gfx.clear (r + g*256 + b*65536)
function Theme.to_clear_color(c)
  local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return byte(c[1]) + byte(c[2]) * 256 + byte(c[3]) * 65536
end

function Theme.to_hex(c)
  local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return ("#%02X%02X%02X"):format(byte(c[1]), byte(c[2]), byte(c[3]))
end

--- Reads all roles from the theme. Pure apart from the reaper calls (tests swap in fakes).
--- Returns colors (name -> {r,g,b}) and sources (name -> theme key, "fallback", "derived" ...).
function Theme.resolve(roles, derived)
  roles = roles or Theme.ROLES
  derived = derived or Theme.DERIVED
  local colors, sources = {}, {}

  for name, def in pairs(roles) do
    colors[name], sources[name] = def.fallback, "fallback"
    for _, key in ipairs(def.keys) do
      local native = reaper.GetThemeColor(key, 0)
      if type(native) == "number" and native >= 0 then
        local r, g, b = reaper.ColorFromNative(native)
        colors[name], sources[name] = { r / 255, g / 255, b / 255 }, key
        break
      end
    end
  end

  if colors.text and colors.background
      and math.abs(Theme.luminance(colors.text) - Theme.luminance(colors.background)) < Theme.MIN_CONTRAST then
    colors.text = Theme.text_on(colors.background)
    sources.text = sources.text .. " (replaced: too little contrast)"
  end

  for name, def in pairs(derived) do
    local from, to = colors[def[1]], colors[def[2]]
    if from and to then
      colors[name], sources[name] = Theme.mix(from, to, def[3]), "derived"
    end
  end

  return colors, sources
end

-- Current state -------------------------------------------------------------

local current = nil -- { colors, sources, file }

--- Reads the colors from the current REAPER theme. Called by the first color lookup, so a
--- window normally never calls it itself. Call it again to pick up a changed theme.
function Theme.load()
  local colors, sources = Theme.resolve()
  current = { colors = colors, sources = sources, file = reaper.GetLastColorThemeFile() or "" }
end

--- A role or accent name, or a color table (returned as it is).
function Theme.color(c)
  if type(c) == "table" then return c end
  if not current then Theme.load() end
  return current.colors[c] or Theme.ACCENTS[c] or Theme.MISSING_COLOR
end

--- gfx.set to a role, accent or color table. alpha defaults to the color's own alpha, else 1.
function Theme.set(c, alpha)
  local col = Theme.color(c)
  gfx.set(col[1], col[2], col[3], alpha or col[4] or 1)
end

--- face (optional): another face than the shared one, e.g. Theme.TITLE_FACE for a title.
function Theme.set_font(size, flags, face)
  gfx.setfont(Theme.FONT_SLOT, face or Theme.FONT_FACE, size, flags)
end

--- Pure. The face name inside a LOGFONT structure written as hex (as reaper.ini stores the theme's fonts): 28 bytes of
--- sizes and flags, then the zero-terminated name. nil when there is none.
function Theme.face_from_logfont(hex)
  if type(hex) ~= "string" or #hex < 58 then return nil end
  local face = {}
  for i = 57, #hex - 1, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    if not byte or byte == 0 then break end
    face[#face + 1] = string.char(byte)
  end
  local name = table.concat(face)
  return name ~= "" and name or nil
end

--- The face the REAPER theme uses for key (a reaper.ini entry, "lb_font" = the list box font by default), or nil.
function Theme.reaper_font_face(key)
  key = key or "lb_font"
  local file = io.open(reaper.get_ini_file(), "rb")
  if not file then return nil end
  local face = nil
  for line in file:lines() do
    local hex = line:match("^" .. key .. "=(%x+)")
    if hex then
      face = Theme.face_from_logfont(hex)
      break
    end
  end
  file:close()
  return face
end

--- Makes the shared font the one the REAPER theme uses for key. Returns the face, or nil when it is not found (the face
--- stays as it was).
function Theme.use_reaper_font(key)
  local face = Theme.reaper_font_face(key)
  if face then Theme.FONT_FACE = face end
  return face
end

Theme.TITLE_FACE = nil -- a face for headers (Widgets.header), nil = the shared one

function Theme.clear_color()
  return Theme.to_clear_color(Theme.color("background"))
end

-- Diagnostics & self test ---------------------------------------------------

--- { label, value } rows: theme file and where each color came from.
function Theme.diagnostics()
  if not current then Theme.load() end
  local rows = { { "theme file", current.file ~= "" and current.file or "(unknown)" } }
  local names = {}
  for name in pairs(current.colors) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    rows[#rows + 1] = { "color " .. name, Theme.to_hex(current.colors[name]) .. " from " .. current.sources[name] }
  end
  return rows
end

function Theme.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local function near(a, b) return math.abs(a - b) < 1e-9 end
  local function same(a, b) return near(a[1], b[1]) and near(a[2], b[2]) and near(a[3], b[3]) end

  -- Fake REAPER: theme colors are stored as "native" r + g*256 + b*65536 (Windows layout)
  local theme = {}
  local with_reaper = require("SelfTest").with_reaper
  local fakes = {
    GetThemeColor = function(key) return theme[key] or -1 end,
    ColorFromNative = function(n) return n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF end,
  }
  local roles = {
    background = { keys = { "bg_a", "bg_b" }, fallback = { 0.1, 0.1, 0.1 } },
    text = { keys = { "fg" }, fallback = { 0.9, 0.9, 0.9 } },
  }
  local derived = { button = { "background", "text", 0.5 } }

  -- resolving
  theme = { bg_b = 0x000033, fg = 0xFFFFFF } -- bg_a missing: second key used
  local c, s = with_reaper(fakes, Theme.resolve, roles, derived)
  check("resolve: falls through to the second key", s.background == "bg_b" and same(c.background, { 0x33 / 255, 0, 0 }))
  check("resolve: derived color is mixed from the roles", same(c.button, Theme.mix(c.background, c.text, 0.5))
    and s.button == "derived")

  theme = {}
  c, s = with_reaper(fakes, Theme.resolve, roles, derived)
  check("resolve: fallback when the theme defines no key", s.background == "fallback" and same(c.text, { 0.9, 0.9, 0.9 }))

  theme = { bg_a = 0x808080, fg = 0x828282 } -- grey text on grey background
  c, s = with_reaper(fakes, Theme.resolve, roles, derived)
  check("resolve: unreadable text is replaced", same(c.text, { 0, 0, 0 }) or same(c.text, { 1, 1, 1 }))
  check("resolve: replacement is noted in the source", s.text:find("replaced") ~= nil)

  -- helpers
  check("to_clear_color: red is the low byte, blue the high byte",
    Theme.to_clear_color({ 1, 0, 0 }) == 0xFF and Theme.to_clear_color({ 0, 0, 1 }) == 0xFF0000)
  check("to_clear_color: values outside 0..1 are clamped", Theme.to_clear_color({ 2, -1, 0 }) == 0xFF)

  check("face_from_logfont: the name inside reaper.ini's hex font entry",
    Theme.face_from_logfont("F7FFFFFF000000000000000000000000F40100000000000003020102526F626F746F204D656469756D00656400726966000000000000000000000000F1") == "Roboto Medium")
  check("face_from_logfont: nothing or junk", Theme.face_from_logfont(nil) == nil and Theme.face_from_logfont("") == nil
    and Theme.face_from_logfont("F7FFFFFF") == nil)

  return results
end

return Theme
