-- @noindex
-- SiSt-Live mode effect: loads the REAPER color theme assigned to the mode.
--
-- Set in "SiSt-Live: Configure modes": load a theme in REAPER the usual way, then type "current"
-- into the theme field of the mode (or type a file name). The file can have any name.
--
-- The assignment is stored in ExtState (persistent, so it travels with a portable install).
-- Themes inside <resource path>/ColorThemes are stored relative to that folder, so the assignment
-- keeps working when the REAPER folder moves. Themes elsewhere are stored with their full path.
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Theme = { name = "theme" }

Theme.SECTION    = "SiSt-Live"
Theme.KEY_PREFIX = "theme_" -- + mode, e.g. "theme_show"
Theme.THEME_DIR  = "ColorThemes"

-- Paths (pure) ----------------------------------------------------------
local function normalize(path)
  return ((path or ""):gsub("\\", "/"))
end

local function file_name(path)
  return normalize(path):match("([^/]+)$") or path
end

--- True if both paths point to the same file. Ignores case and separator style
--- (Windows and default macOS file systems are case-insensitive). Empty paths never match.
function Theme.same_path(a, b)
  if not a or not b or a == "" or b == "" then return false end
  return normalize(a):lower() == normalize(b):lower()
end

function Theme.is_absolute(path)
  local p = normalize(path)
  return p:match("^/") ~= nil or p:match("^%a:/") ~= nil
end

--- <resource path>/ColorThemes, with forward slashes.
function Theme.theme_dir(resource_path)
  return (normalize(resource_path):gsub("/+$", "")) .. "/" .. Theme.THEME_DIR
end

--- Turns a full theme path into what gets stored. Returns ref, portable:
--- inside ColorThemes -> path relative to it, true. Elsewhere -> full path, false.
function Theme.make_ref(path, resource_path)
  local dir = Theme.theme_dir(resource_path) .. "/"
  local p = normalize(path)
  if #p > #dir and p:sub(1, #dir):lower() == dir:lower() then
    return p:sub(#dir + 1), true
  end
  return p, false
end

--- Turns a stored ref back into a full path with the given separator (default: this OS).
function Theme.resolve(ref, resource_path, sep)
  sep = sep or package.config:sub(1, 1)
  local full = Theme.is_absolute(ref) and normalize(ref) or (Theme.theme_dir(resource_path) .. "/" .. normalize(ref))
  return (full:gsub("/", sep))
end

-- Assignments -----------------------------------------------------------
--- Stored ref for the mode, "" if none.
function Theme.get_assignment(mode, api)
  api = api or reaper
  return api.GetExtState(Theme.SECTION, Theme.KEY_PREFIX .. mode)
end

function Theme.set_assignment(mode, ref, api)
  api = api or reaper
  api.SetExtState(Theme.SECTION, Theme.KEY_PREFIX .. mode, ref, true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Theme.apply(mode, api)
  local ref = Theme.get_assignment(mode, api)
  if ref == "" then
    return "skipped", ("no theme assigned to %s mode"):format(mode)
  end

  local full = Theme.resolve(ref, api.GetResourcePath())
  if Theme.same_path(api.GetLastColorThemeFile(), full) then
    return "skipped", "already active: " .. file_name(ref)
  end

  if not api.file_exists(full) then
    error(("theme for %s mode not found: %s"):format(mode, full), 0)
  end
  if not api.OpenColorThemeFile(full) then
    error("REAPER could not load the theme: " .. full, 0)
  end
  return "ok", "loaded " .. file_name(ref)
end

-- Settings --------------------------------------------------------------
-- Field text: theme file (relative to ColorThemes, or a full path), "current" = the theme loaded in
-- REAPER right now, empty = none.
function Theme.parse_setting(text, api)
  local s = (text or ""):match("^%s*(.-)%s*$")
  if s == "" then return true, nil end
  local resource = api.GetResourcePath()

  if s:lower() == "current" then
    local current = api.GetLastColorThemeFile()
    if current == "" or not api.file_exists(current) then
      return false, "theme: REAPER has no theme file loaded right now"
    end
    local ref, portable = Theme.make_ref(current, resource)
    return true, ref, (not portable) and ("theme %s is outside ColorThemes: full path stored, it won't move with the REAPER folder"):format(ref) or nil
  end

  local ref = Theme.make_ref(s, resource) -- a full path inside ColorThemes becomes relative
  if not api.file_exists(Theme.resolve(ref, resource)) then
    return false, ("theme file not found: %s"):format(s)
  end
  local note = Theme.is_absolute(ref) and ("theme %s is outside ColorThemes: it won't move with the REAPER folder"):format(ref) or nil
  return true, ref, note
end

Theme.settings = {
  {
    label  = "theme",
    get    = function(mode, api) local ref = Theme.get_assignment(mode, api) return ref ~= "" and ref or nil end,
    format = function(ref) return ref or "" end,
    parse  = function(text, api) return Theme.parse_setting(text, api) end,
    set    = function(mode, ref, api) Theme.set_assignment(mode, ref or "", api) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Theme.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local ref = Theme.get_assignment(mode, api)
    local value = "(none)"
    if ref ~= "" then
      local exists = api.file_exists(Theme.resolve(ref, api.GetResourcePath()))
      value = ref .. (exists and "" or "  [FILE MISSING]")
    end
    rows[#rows + 1] = { mode .. " theme", value }
  end
  local current = api.GetLastColorThemeFile()
  rows[#rows + 1] = { "loaded theme", current ~= "" and file_name(current) or "(none)" }
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never touches the real theme or assignments.
function Theme.self_test()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local R = "C:\\REAPER"
  local function fake(opts)
    local ext, loads = {}, {}
    local files = {}
    for _, f in ipairs(opts.files or {}) do files[normalize(f):lower()] = true end
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      GetResourcePath = function() return R end,
      GetLastColorThemeFile = function() return opts.current or "" end,
      file_exists = function(p) return files[normalize(p):lower()] == true end,
      OpenColorThemeFile = function(p)
        loads[#loads + 1] = p
        if opts.load_fails then return false end
        opts.current = p
        return true
      end,
    }
    return api, loads
  end

  -- paths
  check("ref: theme in ColorThemes is stored relative",
    select(1, Theme.make_ref("c:/reaper/colorthemes/My Show.ReaperTheme", R)) == "My Show.ReaperTheme"
    and select(2, Theme.make_ref("c:/reaper/colorthemes/My Show.ReaperTheme", R)) == true)
  check("ref: subfolder of ColorThemes stays relative",
    Theme.make_ref(R .. "\\ColorThemes\\Old\\A.ReaperThemeZip", R) == "Old/A.ReaperThemeZip")
  local ref_out, portable_out = Theme.make_ref("D:\\Themes\\X.ReaperTheme", R)
  check("ref: theme elsewhere keeps full path, not portable",
    ref_out == "D:/Themes/X.ReaperTheme" and portable_out == false)
  check("ref: folder name prefix is not mistaken for ColorThemes",
    select(2, Theme.make_ref(R .. "\\ColorThemesOld\\X.ReaperTheme", R)) == false)
  check("resolve: relative ref with Windows separator",
    Theme.resolve("Old/A.ReaperTheme", R, "\\") == "C:\\REAPER\\ColorThemes\\Old\\A.ReaperTheme")
  check("resolve: absolute ref unchanged", Theme.resolve("/Users/x/T.ReaperTheme", "/R", "/") == "/Users/x/T.ReaperTheme")
  check("same_path ignores case and separators", Theme.same_path("C:\\A\\b.ReaperTheme", "c:/a/B.reapertheme"))
  check("same_path: empty never matches", not Theme.same_path("", ""))

  local show_full = "C:\\REAPER\\ColorThemes\\Show.ReaperTheme"
  local edit_full = "C:\\REAPER\\ColorThemes\\Edit.ReaperTheme"

  -- apply
  local api, loads = fake({ files = { show_full, edit_full }, current = edit_full })
  local result, msg = Theme.apply("show", api)
  check("apply: nothing assigned -> skipped, nothing loaded", result == "skipped" and #loads == 0)

  Theme.set_assignment("show", "Show.ReaperTheme", api)
  Theme.set_assignment("edit", "Edit.ReaperTheme", api)
  result, msg = Theme.apply("edit", api)
  check("apply: theme already active -> skipped", result == "skipped" and #loads == 0)

  result, msg = Theme.apply("show", api)
  check("apply: loads the show theme", result == "ok" and #loads == 1 and Theme.same_path(loads[1], show_full))
  result = Theme.apply("show", api)
  check("apply: second run is skipped (idempotent)", result == "skipped" and #loads == 1)
  result = Theme.apply("edit", api)
  check("apply: each mode uses its own theme", result == "ok" and Theme.same_path(loads[2], edit_full))

  local api2, loads2 = fake({ files = {}, current = edit_full })
  Theme.set_assignment("show", "Gone.ReaperTheme", api2)
  local ok, err = pcall(Theme.apply, "show", api2)
  check("apply: missing file fails with a clear message",
    not ok and tostring(err):find("not found", 1, true) and #loads2 == 0)

  local api3 = fake({ files = { show_full }, current = edit_full, load_fails = true })
  Theme.set_assignment("show", "Show.ReaperTheme", api3)
  check("apply: REAPER refusing the file fails", not pcall(Theme.apply, "show", api3))


  -- settings field
  local sapi = fake({ files = { show_full }, current = show_full })
  local ok1, ref1 = Theme.parse_setting("current", sapi)
  check("setting: 'current' takes the loaded theme", ok1 and ref1 == "Show.ReaperTheme")
  local ok2, ref2 = Theme.parse_setting(" Show.ReaperTheme ", sapi)
  check("setting: typed file name accepted", ok2 and ref2 == "Show.ReaperTheme")
  check("setting: missing file rejected", not Theme.parse_setting("Nope.ReaperTheme", sapi))
  local ok3, ref3 = Theme.parse_setting("", sapi)
  check("setting: empty = none", ok3 and ref3 == nil)
  check("setting: 'current' without a loaded theme rejected", not Theme.parse_setting("current", fake({ current = "" })))
  local ts = Theme.settings[1]
  ts.set("show", "X.ReaperTheme", sapi)
  check("setting: set / get / format", ts.format(ts.get("show", sapi)) == "X.ReaperTheme")
  ts.set("show", nil, sapi)
  check("setting: cleared", ts.get("show", sapi) == nil)

  return results
end

return Theme
