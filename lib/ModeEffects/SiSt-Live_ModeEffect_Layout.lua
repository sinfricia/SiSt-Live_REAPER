-- @noindex
-- SiSt-Live mode effect: sets REAPER's global theme layout per section (track panel, transport, mixer).
--
-- Uses the layout override (reaper.ThemeLayout_SetLayout), the same setting as Options > Layouts.
-- It changes how REAPER draws things without touching any project: nothing is saved into the songs,
-- no undo points, and every open project tab follows at once.
--
-- Set in "SiSt-Live: Configure modes": choose the layouts in Options > Layouts, then type "current"
-- into the layouts field of the mode. That stores the current layout of every section in
-- Layout.SECTIONS. The field can also be edited by hand. An empty layout means "theme default".
--
-- Layout names only exist within a theme, so this effect must run after the theme effect. It also
-- runs after the screenset effect, so its layouts win over anything a window set brings along
-- (see the order in ModeEffects.MODULES). A layout the loaded theme doesn't have is reported as a
-- failure; the other sections are still applied.
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Layout = { name = "layout" }

Layout.SECTION    = "SiSt-Live"
Layout.KEY_PREFIX = "layouts_" -- + mode, e.g. "layouts_show"

-- Sections this effect manages, in the order they're applied. Add one line to manage another
-- (names as used by ThemeLayout_GetLayout, e.g. "mcp" for the mixer).
Layout.SECTIONS = {
  { id = "tcp",   label = "Track panel" },
  { id = "trans", label = "Transport" },
  { id = "mcp",   label = "Mixer panel" },
}

local function section_label(id)
  for _, s in ipairs(Layout.SECTIONS) do
    if s.id == id then return s.label end
  end
  return id
end

local function show_layout(name)
  return name == "" and "(theme default)" or name
end

-- Encoding (pure) -------------------------------------------------------
-- { tcp = "B150%", trans = "" }  <->  "tcp=B150%25;trans=;"
-- Layout names can contain anything, so % ; = are stored as %XX. Sections are written in
-- Layout.SECTIONS order (stable output), unknown extra keys after them in sorted order.
local function encode_value(s)
  return (s:gsub("[%%;=\r\n]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function decode_value(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function Layout.encode(map)
  local parts, done = {}, {}
  for _, s in ipairs(Layout.SECTIONS) do
    if map[s.id] ~= nil then
      parts[#parts + 1] = s.id .. "=" .. encode_value(map[s.id]) .. ";"
      done[s.id] = true
    end
  end
  local extra = {}
  for id in pairs(map) do if not done[id] then extra[#extra + 1] = id end end
  table.sort(extra)
  for _, id in ipairs(extra) do parts[#parts + 1] = id .. "=" .. encode_value(map[id]) .. ";" end
  return table.concat(parts)
end

--- Returns the map, or nil for an empty string (= nothing assigned).
function Layout.decode(str)
  if not str or str == "" then return nil end
  local map = {}
  for id, value in str:gmatch("([^;=]+)=([^;]*);") do
    map[id] = decode_value(value)
  end
  return next(map) and map or nil
end

-- Theme layouts ---------------------------------------------------------
--- All layout names the loaded theme offers for a section (plus "" = theme default).
function Layout.available(section, api)
  local names = { [""] = true }
  local i = 0
  while true do
    local ok, name = api.ThemeLayout_GetLayout(section, i)
    if not ok then break end
    names[name] = true
    i = i + 1
    if i > 1000 then break end -- safety net against an API that never ends the list
  end
  return names
end

function Layout.current(section, api)
  local _, name = api.ThemeLayout_GetLayout(section, -1)
  return name or ""
end

--- Current layout of every managed section.
function Layout.capture(api)
  local map = {}
  for _, s in ipairs(Layout.SECTIONS) do map[s.id] = Layout.current(s.id, api) end
  return map
end

-- Assignments -----------------------------------------------------------
function Layout.get_assignment(mode, api)
  api = api or reaper
  return Layout.decode(api.GetExtState(Layout.SECTION, Layout.KEY_PREFIX .. mode))
end

function Layout.set_assignment(mode, map, api)
  api = api or reaper
  api.SetExtState(Layout.SECTION, Layout.KEY_PREFIX .. mode, Layout.encode(map), true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Layout.apply(mode, api)
  local target = Layout.get_assignment(mode, api)
  if not target then
    return "skipped", ("no layouts assigned to %s mode"):format(mode)
  end

  local changed, problems = {}, {}
  for _, s in ipairs(Layout.SECTIONS) do
    local want = target[s.id]
    if want ~= nil and Layout.current(s.id, api) ~= want then
      if not Layout.available(s.id, api)[want] then
        problems[#problems + 1] = ("%s layout '%s' not in the loaded theme"):format(s.id, want)
      elseif not api.ThemeLayout_SetLayout(s.id, want) then
        problems[#problems + 1] = ("REAPER refused %s layout '%s'"):format(s.id, want)
      else
        changed[#changed + 1] = ("%s=%s"):format(s.id, show_layout(want))
      end
    end
  end

  if #changed > 0 and api.ThemeLayout_RefreshAll then api.ThemeLayout_RefreshAll() end

  if #problems > 0 then
    local done = #changed > 0 and (" (applied: " .. table.concat(changed, ", ") .. ")") or ""
    error(table.concat(problems, "; ") .. done, 0)
  end
  if #changed == 0 then return "skipped", "already active" end
  return "ok", "set " .. table.concat(changed, ", ")
end

-- Settings --------------------------------------------------------------
-- Field text: "tcp=B150%, trans=150%, mcp=" (empty layout = theme default), "current" = the layouts
-- active in REAPER right now, empty field = none.
function Layout.format_setting(map)
  if not map then return "" end
  local parts = {}
  for _, s in ipairs(Layout.SECTIONS) do
    if map[s.id] ~= nil then parts[#parts + 1] = s.id .. "=" .. map[s.id] end
  end
  return table.concat(parts, ", ")
end

function Layout.parse_setting(text, api)
  local s = (text or ""):match("^%s*(.-)%s*$")
  if s == "" then return true, nil end
  if s:lower() == "current" then return true, Layout.capture(api) end

  local known, ids = {}, {}
  for _, sec in ipairs(Layout.SECTIONS) do known[sec.id] = true; ids[#ids + 1] = sec.id end

  local map = {}
  for part in (s .. ","):gmatch("([^,]*),") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then
      local id, name = part:match("^([%w_]+)%s*=%s*(.-)$")
      if not id or not known[id] then
        return false, ("layouts: '%s' is not section=layout (sections: %s)"):format(part, table.concat(ids, ", "))
      end
      map[id] = name
    end
  end
  if not next(map) then return false, "layouts: nothing to set" end
  return true, map
end

Layout.settings = {
  {
    label  = "layouts",
    get    = function(mode, api) return Layout.get_assignment(mode, api) end,
    format = Layout.format_setting,
    parse  = function(text, api) return Layout.parse_setting(text, api) end,
    set    = function(mode, map, api)
      if map then Layout.set_assignment(mode, map, api)
      else api.SetExtState(Layout.SECTION, Layout.KEY_PREFIX .. mode, "", true) end
    end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Layout.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local map = Layout.get_assignment(mode, api)
    if not map then
      rows[#rows + 1] = { mode .. " layouts", "(none)" }
    else
      local parts = {}
      for _, s in ipairs(Layout.SECTIONS) do
        local want = map[s.id]
        if want ~= nil then
          local ok = Layout.available(s.id, api)[want]
          parts[#parts + 1] = ("%s=%s%s"):format(s.id, show_layout(want), ok and "" or " [NOT IN THEME]")
        end
      end
      rows[#rows + 1] = { mode .. " layouts", table.concat(parts, ", ") }
    end
  end
  local now = {}
  for _, s in ipairs(Layout.SECTIONS) do now[#now + 1] = s.id .. "=" .. show_layout(Layout.current(s.id, api)) end
  rows[#rows + 1] = { "active layouts", table.concat(now, ", ") }
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never changes the real layouts or assignments.
function Layout.self_test()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local function fake(opts)
    local ext, sets, refreshes = {}, {}, { n = 0 }
    local theme = opts.theme or { tcp = { "A", "B", "B150%" }, trans = { "default", "150%" } }
    local current = opts.current or { tcp = "", trans = "" }
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      ThemeLayout_GetLayout = function(section, idx)
        if idx == -1 then return true, current[section] or "" end
        local list = theme[section] or {}
        if idx >= 0 and idx < #list then return true, list[idx + 1] end
        return false, ""
      end,
      ThemeLayout_SetLayout = function(section, name)
        if opts.refuse then return false end
        sets[#sets + 1] = section .. "=" .. name
        current[section] = name
        return true
      end,
      ThemeLayout_RefreshAll = function() refreshes.n = refreshes.n + 1 end,
    }
    return api, sets, refreshes, current
  end

  -- encoding
  local map = { tcp = "B150%", trans = "", mcp = "a;b=c" }
  local enc = Layout.encode(map)
  check("encode: managed sections first, special characters escaped",
    enc == "tcp=B150%25;trans=;mcp=a%3Bb%3Dc;")
  local dec = Layout.decode(enc)
  check("decode: round trip incl. empty layout and special characters",
    dec and dec.tcp == "B150%" and dec.trans == "" and dec.mcp == "a;b=c")
  check("decode: empty / garbage = nothing assigned", Layout.decode("") == nil and Layout.decode("garbage") == nil)

  -- apply
  local api, sets, refreshes = fake({})
  check("apply: nothing assigned -> skipped", (Layout.apply("show", api)) == "skipped" and #sets == 0)

  Layout.set_assignment("show", { tcp = "B150%", trans = "150%" }, api)
  Layout.set_assignment("edit", { tcp = "", trans = "" }, api)
  local result, msg = Layout.apply("show", api)
  check("apply: sets every differing section, in order",
    result == "ok" and table.concat(sets, ",") == "tcp=B150%,trans=150%")
  check("apply: refreshes once after changes", refreshes.n == 1)
  result = Layout.apply("show", api)
  check("apply: second run is skipped (idempotent), no refresh",
    result == "skipped" and #sets == 2 and refreshes.n == 1)
  result = Layout.apply("edit", api)
  check("apply: empty layout restores the theme default", result == "ok" and sets[3] == "tcp=" and sets[4] == "trans=")

  local api2, sets2 = fake({ theme = { tcp = { "A" }, trans = { "150%" } } })
  Layout.set_assignment("show", { tcp = "B150%", trans = "150%" }, api2)
  local ok, err = pcall(Layout.apply, "show", api2)
  check("apply: layout missing in theme fails and names it",
    not ok and tostring(err):find("tcp layout 'B150%' not in the loaded theme", 1, true) ~= nil)
  check("apply: the other sections are still applied", #sets2 == 1 and sets2[1] == "trans=150%"
    and tostring(err):find("applied: trans=150%", 1, true) ~= nil)

  local api3 = fake({ refuse = true })
  Layout.set_assignment("show", { tcp = "B" }, api3)
  check("apply: REAPER refusing a layout fails", not pcall(Layout.apply, "show", api3))

  local api4 = fake({ current = { tcp = "A", trans = "default" } })
  Layout.set_assignment("show", { tcp = "B" }, api4)
  local r4 = Layout.apply("show", api4)
  check("apply: sections missing from the assignment are left alone",
    r4 == "ok" and Layout.current("trans", api4) == "default")

  check("capture: reads every managed section",
    Layout.capture(fake({ current = { tcp = "B", trans = "150%" } })).trans == "150%")


  -- settings field
  local lapi = fake({ current = { tcp = "B", trans = "150%", mcp = "" } })
  local okc, mc = Layout.parse_setting("current", lapi)
  check("setting: 'current' captures every section", okc and mc.tcp == "B" and mc.trans == "150%" and mc.mcp == "")
  check("setting: format", Layout.format_setting(mc) == "tcp=B, trans=150%, mcp=")
  check("setting: format -> parse round trip", (Layout.parse_setting(Layout.format_setting(mc), lapi)))
  local okp, mp = Layout.parse_setting("tcp = B150% , trans=150%", lapi)
  check("setting: typed text parsed, sections left out stay unmanaged",
    okp and mp.tcp == "B150%" and mp.trans == "150%" and mp.mcp == nil)
  check("setting: unknown section / missing '=' rejected",
    not Layout.parse_setting("foo=1", lapi) and not Layout.parse_setting("tcp", lapi))
  local ls = Layout.settings[1]
  ls.set("show", mp, lapi)
  check("setting: set / get", ls.get("show", lapi).tcp == "B150%")
  ls.set("show", nil, lapi)
  check("setting: cleared", ls.get("show", lapi) == nil)

  return results
end

return Layout
