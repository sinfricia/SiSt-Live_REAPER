-- @noindex
--[[
SiSt-Live Gui: Theme

Colors and fonts shared by all SiSt-Live windows.

Components ask for ROLES, never for REAPER theme keys:
  Theme.set("text")             -- gfx.set to the text color of the current REAPER theme
  Theme.set("show", 0.5)        -- accent colors work the same way, with an optional alpha
  Theme.set({ 1, 0, 0 })        -- a color table is accepted too
  Theme.set_font(18)            -- the shared font face at size 18
  gfx.clear = Theme.clear_color()

The colors are read from the REAPER theme once, on first use (or by calling Theme.load()).
A theme change while a window is open is not picked up: reopen the window to get the new colors.

Where the colors come from:
  ROLES    read from the REAPER theme. Each role lists theme keys to try in order. The first one
           the theme defines wins. If none is defined, the fallback color is used.
  DERIVED  mixed from two roles, so they follow the theme without needing extra theme keys.
  ACCENTS  fixed colors with a meaning that must not change with the theme (show/edit, ok/error).

Adding a role: add one line to ROLES or DERIVED. Check the result with Theme.diagnostics()
(the status display logs it at startup when SiSt-Live debug logging is on).

Fonts: REAPER has no API to read the theme's fonts, so the face is set here, in one place.

Self test: Theme.self_test() returns a list of { name, ok }. Uses a fake REAPER api.
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
  show  = { 0.25, 0.67, 0.60 }, -- same teal as the Setlist's show highlight
  edit  = { 1.00, 0.50, 0.20 }, -- same orange as the Setlist's edit title bar
  toggle = { 0.30, 0.90, 0.80 }, -- toggle buttons that are on (brighter and more cyan than "show")
  live   = { 0x1F / 255, 0x7F / 255, 0x70 / 255 }, -- status header in show mode: deep teal, white text readable
  ok    = { 0.30, 0.78, 0.40 },
  error = { 0.92, 0.26, 0.24 },
}

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

--- Reads all roles from the theme. Pure apart from the api calls, so tests can pass a fake api.
--- Returns colors (name -> {r,g,b}) and sources (name -> theme key, "fallback", "derived" ...).
function Theme.resolve(api, roles, derived)
  roles = roles or Theme.ROLES
  derived = derived or Theme.DERIVED
  local colors, sources = {}, {}

  for name, def in pairs(roles) do
    colors[name], sources[name] = def.fallback, "fallback"
    for _, key in ipairs(def.keys) do
      local native = api.GetThemeColor(key, 0)
      if type(native) == "number" and native >= 0 then
        local r, g, b = api.ColorFromNative(native)
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
function Theme.load(api)
  api = api or reaper
  local colors, sources = Theme.resolve(api)
  current = { colors = colors, sources = sources, file = api.GetLastColorThemeFile() or "" }
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

function Theme.set_font(size, flags)
  gfx.setfont(Theme.FONT_SLOT, Theme.FONT_FACE, size, flags)
end

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

  -- Fake api: theme colors are stored as "native" r + g*256 + b*65536 (Windows layout)
  local theme = {}
  local file = "A.ReaperTheme"
  local api = {
    GetThemeColor = function(key) return theme[key] or -1 end,
    ColorFromNative = function(n) return n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF end,
    GetLastColorThemeFile = function() return file end,
  }
  local roles = {
    background = { keys = { "bg_a", "bg_b" }, fallback = { 0.1, 0.1, 0.1 } },
    text = { keys = { "fg" }, fallback = { 0.9, 0.9, 0.9 } },
  }
  local derived = { button = { "background", "text", 0.5 } }

  -- resolving
  theme = { bg_b = 0x000033, fg = 0xFFFFFF } -- bg_a missing: second key used
  local c, s = Theme.resolve(api, roles, derived)
  check("resolve: falls through to the second key", s.background == "bg_b" and same(c.background, { 0x33 / 255, 0, 0 }))
  check("resolve: native color converted to 0..1", same(c.text, { 1, 1, 1 }))
  check("resolve: derived color is mixed from the roles", same(c.button, Theme.mix(c.background, c.text, 0.5))
    and s.button == "derived")

  theme = {}
  c, s = Theme.resolve(api, roles, derived)
  check("resolve: fallback when the theme defines no key", s.background == "fallback" and same(c.text, { 0.9, 0.9, 0.9 }))

  theme = { bg_a = 0x808080, fg = 0x828282 } -- grey text on grey background
  c, s = Theme.resolve(api, roles, derived)
  check("resolve: unreadable text is replaced", same(c.text, { 0, 0, 0 }) or same(c.text, { 1, 1, 1 }))
  check("resolve: replacement is noted in the source", s.text:find("replaced") ~= nil)

  -- helpers
  check("mix: halfway", same(Theme.mix({ 0, 0, 0 }, { 1, 1, 1 }, 0.5), { 0.5, 0.5, 0.5 }))
  check("text_on: white on dark, black on light",
    same(Theme.text_on({ 0.1, 0.1, 0.1 }), { 1, 1, 1 }) and same(Theme.text_on({ 0.9, 0.9, 0.9 }), { 0, 0, 0 }))
  check("to_clear_color: red is the low byte, blue the high byte",
    Theme.to_clear_color({ 1, 0, 0 }) == 0xFF and Theme.to_clear_color({ 0, 0, 1 }) == 0xFF0000)
  check("to_clear_color: values outside 0..1 are clamped", Theme.to_clear_color({ 2, -1, 0 }) == 0xFF)
  check("to_hex", Theme.to_hex({ 1, 0.5, 0 }) == "#FF8000")

  -- loading / lookups (module state is saved and restored, the real theme is never touched)
  local saved = current
  current = nil
  theme = { col_main_bg2 = 0x202020, col_main_text2 = 0xE0E0E0 }
  file = "B.ReaperTheme"
  Theme.load(api)
  check("color: role from the theme", same(Theme.color("background"), { 0x20 / 255, 0x20 / 255, 0x20 / 255 }))
  check("color: accent", Theme.color("show") == Theme.ACCENTS.show)
  check("color: table is passed through", Theme.color(Theme.ACCENTS.ok) == Theme.ACCENTS.ok)
  check("color: unknown name is magenta", Theme.color("no_such_role") == Theme.MISSING_COLOR)
  check("diagnostics: lists the theme file first", Theme.diagnostics()[1][2] == "B.ReaperTheme")
  current = saved

  return results
end

return Theme
