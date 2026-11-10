-- @noindex
-- SiSt-Live mode effect: loads the REAPER color theme assigned to the mode.
--
-- Set in "SiSt-Live: Configure modes": load a theme in REAPER the usual way, then type "current"
-- into the theme field of the mode (or type a file name), or run "SiSt-Live: Save current look for
-- current mode" (Theme.take_current). The file can have any name.
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
function Theme.get_assignment(mode)
  return reaper.GetExtState(Theme.SECTION, Theme.KEY_PREFIX .. mode)
end

function Theme.set_assignment(mode, ref)
  reaper.SetExtState(Theme.SECTION, Theme.KEY_PREFIX .. mode, ref, true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Theme.apply(mode)
  local ref = Theme.get_assignment(mode)
  if ref == "" then
    return "skipped", ("no theme assigned to %s mode"):format(mode)
  end

  local full = Theme.resolve(ref, reaper.GetResourcePath())
  -- The file first: REAPER keeps reporting the last loaded theme even after its file was renamed or deleted,
  -- so "already active" alone would hide a missing file until the next start.
  if not reaper.file_exists(full) then
    error(("theme for %s mode not found: %s"):format(mode, full), 0)
  end
  if Theme.same_path(reaper.GetLastColorThemeFile(), full) then
    return "skipped", "already active: " .. file_name(ref)
  end
  if not reaper.OpenColorThemeFile(full) then
    error("REAPER could not load the theme: " .. full, 0)
  end
  return "ok", "loaded " .. file_name(ref)
end

-- Take current ----------------------------------------------------------
--- The theme loaded in REAPER right now, as it would be stored.
--- Returns ref, note (only for a theme outside ColorThemes), or nil, error message.
function Theme.current_ref()
  local current = reaper.GetLastColorThemeFile()
  if current == "" or not reaper.file_exists(current) then
    return nil, "REAPER has no theme file loaded right now"
  end
  local ref, portable = Theme.make_ref(current, reaper.GetResourcePath())
  return ref, (not portable) and ("theme %s is outside ColorThemes: full path stored, it won't move with the REAPER folder"):format(ref) or nil
end

--- "Save current look" (contract in SiSt-Live_ModeEffects.lua): the loaded theme becomes the mode's theme.
function Theme.take_current(mode)
  local ref, note = Theme.current_ref()
  if not ref then error(note, 0) end
  local old = Theme.get_assignment(mode)
  if Theme.same_path(old, ref) then return nil, "unchanged: " .. file_name(ref) end
  return {
    text = ("theme: %s -> %s"):format(old ~= "" and old or "(none)", ref),
    note = note,
    save = function() Theme.set_assignment(mode, ref) end,
  }
end

-- Settings --------------------------------------------------------------
-- Field text: theme file (relative to ColorThemes, or a full path), "current" = the theme loaded in
-- REAPER right now, empty = none.
function Theme.parse_setting(text)
  local s = (text or ""):match("^%s*(.-)%s*$")
  if s == "" then return true, nil end
  local resource = reaper.GetResourcePath()

  if s:lower() == "current" then
    local ref, note = Theme.current_ref()
    if not ref then return false, "theme: " .. note end
    return true, ref, note
  end

  local ref = Theme.make_ref(s, resource) -- a full path inside ColorThemes becomes relative
  if not reaper.file_exists(Theme.resolve(ref, resource)) then
    return false, ("theme file not found: %s"):format(s)
  end
  local note = Theme.is_absolute(ref) and ("theme %s is outside ColorThemes: it won't move with the REAPER folder"):format(ref) or nil
  return true, ref, note
end

Theme.settings = {
  {
    label  = "theme",
    get    = function(mode) local ref = Theme.get_assignment(mode) return ref ~= "" and ref or nil end,
    format = function(ref) return ref or "" end,
    parse  = function(text) return Theme.parse_setting(text) end,
    set    = function(mode, ref) Theme.set_assignment(mode, ref or "") end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Theme.diagnostics()
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local ref = Theme.get_assignment(mode)
    local value = "(none)"
    if ref ~= "" then
      local exists = reaper.file_exists(Theme.resolve(ref, reaper.GetResourcePath()))
      value = ref .. (exists and "" or "  [FILE MISSING]")
    end
    rows[#rows + 1] = { mode .. " theme", value }
  end
  local current = reaper.GetLastColorThemeFile()
  rows[#rows + 1] = { "loaded theme", current ~= "" and file_name(current) or "(none)" }
  return rows
end

--- Built-in self-test. Uses fake REAPER functions: never touches the real theme or assignments.
function Theme.self_test()
  local with_reaper = require("SelfTest").with_reaper
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end

  local R = "C:\\REAPER"
  local function fake(opts)
    local loads = {}
    local files = {}
    for _, f in ipairs(opts.files or {}) do files[normalize(f):lower()] = true end
    local fakes = {
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
    return fakes, loads
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
  local fakes, loads = fake({ files = { show_full, edit_full }, current = edit_full })
  local result, msg = with_reaper(fakes, Theme.apply, "show")
  check("apply: nothing assigned -> skipped, nothing loaded", result == "skipped" and #loads == 0)

  with_reaper(fakes, Theme.set_assignment, "show", "Show.ReaperTheme")
  with_reaper(fakes, Theme.set_assignment, "edit", "Edit.ReaperTheme")
  result, msg = with_reaper(fakes, Theme.apply, "edit")
  check("apply: theme already active -> skipped", result == "skipped" and #loads == 0)

  result, msg = with_reaper(fakes, Theme.apply, "show")
  result = with_reaper(fakes, Theme.apply, "show")
  check("apply: second run is skipped (idempotent)", result == "skipped" and #loads == 1)

  local fakes2, loads2 = fake({ files = {}, current = edit_full })
  with_reaper(fakes2, Theme.set_assignment, "show", "Gone.ReaperTheme")
  local ok, err = pcall(with_reaper, fakes2, Theme.apply, "show")
  check("apply: missing file fails with a clear message",
    not ok and tostring(err):find("not found", 1, true) and #loads2 == 0)

  local fakes4, loads4 = fake({ files = {}, current = show_full }) -- loaded in REAPER, but the file is gone
  with_reaper(fakes4, Theme.set_assignment, "show", "Show.ReaperTheme")
  local ok4, err4 = pcall(with_reaper, fakes4, Theme.apply, "show")
  check("apply: missing file fails even while REAPER still has it loaded",
    not ok4 and tostring(err4):find("not found", 1, true) and #loads4 == 0)

  local fakes3 = fake({ files = { show_full }, current = edit_full, load_fails = true })
  with_reaper(fakes3, Theme.set_assignment, "show", "Show.ReaperTheme")
  check("apply: REAPER refusing the file fails", not pcall(with_reaper, fakes3, Theme.apply, "show"))

  -- settings field
  local sfakes = fake({ files = { show_full }, current = show_full })
  check("setting: missing file rejected", not with_reaper(sfakes, Theme.parse_setting, "Nope.ReaperTheme"))
  check("setting: 'current' without a loaded theme rejected", not with_reaper(fake({ current = "" }), Theme.parse_setting, "current"))

  -- take current
  local tfakes = fake({ files = { show_full }, current = show_full })
  local item = with_reaper(tfakes, Theme.take_current, "show")
  local before = with_reaper(tfakes, Theme.get_assignment, "show")
  if item then with_reaper(tfakes, item.save) end
  check("take current: nothing stored before saving, then the loaded theme is stored relative",
    item ~= nil and item.text == "theme: (none) -> Show.ReaperTheme" and before == ""
    and with_reaper(tfakes, Theme.get_assignment, "show") == "Show.ReaperTheme")
  local none, why = with_reaper(tfakes, Theme.take_current, "show")
  check("take current: same theme already stored -> nothing to save",
    none == nil and tostring(why):find("unchanged", 1, true) ~= nil)
  local outside_file = "D:\\Themes\\X.ReaperTheme"
  local item2 = with_reaper(fake({ files = { outside_file }, current = outside_file }), Theme.take_current, "edit")
  check("take current: theme outside ColorThemes comes with a note", item2 ~= nil and item2.note ~= nil)
  check("take current: no theme loaded fails", not pcall(with_reaper, fake({ current = "" }), Theme.take_current, "show"))

  return results
end

return Theme
