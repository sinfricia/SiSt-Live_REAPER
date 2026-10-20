-- @noindex
-- ActionReferenceChecks: finds places that call an action that no longer exists.
--
-- Part of the future shared libraries (no SiSt-Live specifics in here): it only reads REAPER's own files
-- and the open projects, and never changes anything.
--
-- Custom actions, toolbar buttons, shortcuts, mouse modifiers, cycle actions and action markers store the
-- command ID of the action they run. Named IDs of scripts ("_RS...") come from the script's path: when a
-- script is moved, renamed or deleted, every place that uses it silently does nothing (a custom action
-- just skips that step). These checks list those places BEFORE they fail during a show.
--
-- 1. Config check, ActionReferenceChecks.check_config() -> report
--    reaper-kb.ini       SCR   registered scripts (ID + file path)
--                        ACT   custom actions: every step
--                        KEY   key and MIDI shortcuts
--    reaper-menu.ini     item_N=      toolbar buttons and menu entries
--    reaper-mouse.ini    mm_N=        mouse modifiers that run an action
--    S&M_Cyclactions.ini ActionN=     SWS cycle actions: every step
--    S&M.ini             key=_...     SWS settings that store an action (e.g. a startup action)
--    For every NAMED command ID ("_RS...", "_SWS...", "_<custom action>"):
--      a) REAPER knows the ID (NamedCommandLookup ~= 0)
--      b) for scripts: the script file still exists (REAPER keeps action list entries of deleted files)
--    Native numeric IDs are not checked here: they don't change when files move, and other sections (MIDI
--    editor, mouse contexts) use other number ranges, which would give false alarms.
--
-- 2. Action marker check, ActionReferenceChecks.check_markers() -> report
--    Markers whose name starts with "!" run actions while playing ("!1016 _RS..."). They live inside the
--    projects, so the config check can't see them: this check reads the markers of all OPEN projects.
--    Here native IDs are checked too: action markers always use the main section.
--
-- REAPER writes reaper-kb.ini / reaper-menu.ini when actions or toolbars change, so the files normally
-- match what REAPER has loaded.
--
-- A report is { problems = { { where, id, problem } }, unused_missing = { { id, path } }, checked = n,
--               unreadable = { file names } }.
-- results(report, title) turns a report into { name, ok } rows for a self-test runner.
-- Self test: ActionReferenceChecks.self_test() uses sample texts and a fake marker list only.

local Checks = {}

Checks.FILES = {
  kb     = "reaper-kb.ini",
  menu   = "reaper-menu.ini",
  mouse  = "reaper-mouse.ini",
  cycle  = "S&M_Cyclactions.ini",
  sws    = "S&M.ini",
}

-- Pure functions: reading the files' text ----------------------------------------------------

local function lines(text)
  return ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n")
end

local function unquote(s)
  return (s:match('^"(.*)"$') or s)
end

local function is_named(token)
  return token:sub(1, 1) == "_" and #token > 1
end

--- reaper-kb.ini. Returns scripts ({ ["_RS..."] = "path as stored" }) and refs ({ { id, where } }).
function Checks.parse_kb(text)
  local scripts, refs = {}, {}
  for line in lines(text) do
    local kind = line:match("^(%u%u%u)%s")
    if kind == "SCR" then
      local id, path = line:match('^SCR%s+%S+%s+%S+%s+(%S+)%s+"[^"]*"%s+(.-)%s*$')
      if id and path and path ~= "" then scripts["_" .. id] = unquote(path) end
    elseif kind == "ACT" then
      local name, steps = line:match('^ACT%s+%S+%s+%S+%s+"[^"]*"%s+"([^"]*)"%s*(.*)$')
      if name then
        local n = 0
        for cmd in steps:gmatch("%S+") do
          n = n + 1
          if is_named(cmd) then
            refs[#refs + 1] = { id = cmd, where = ('Custom action "%s", step %d'):format(name, n) }
          end
        end
      end
    elseif kind == "KEY" then
      local cmd, comment = line:match("^KEY%s+%S+%s+%S+%s+(%S+)%s+%S+%s*#?%s*(.*)$")
      if cmd and is_named(cmd) then
        -- REAPER's comment looks like "Main : Ctrl+Shift+S : Script: ..." -> keep section and key
        local section, key = comment:match("^%s*(.-)%s+:%s+(.-)%s+:")
        refs[#refs + 1] = { id = cmd, where = "Shortcut " .. (section and (section .. " : " .. key) or "?") }
      end
    end
  end
  return scripts, refs
end

--- reaper-menu.ini: toolbar buttons and menu entries.
function Checks.parse_menu(text)
  local refs, section = {}, "?"
  for line in lines(text) do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      section = header
    else
      local index, cmd, label = line:match("^item_(%d+)=(%S+)%s*(.-)%s*$")
      if cmd and is_named(cmd) then
        refs[#refs + 1] = { id = cmd, where = ('%s, item %d "%s"'):format(section, tonumber(index) + 1, label) }
      end
    end
  end
  return refs
end

--- reaper-mouse.ini: "mm_N=<value>". Values are "<n> m" (built-in behaviour), "<cmd> c" (native action) or a
--- named ID ("_SWS...", "_<custom action>").
function Checks.parse_mouse(text)
  local refs, section = {}, "?"
  for line in lines(text) do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      section = header
    else
      local slot, value = line:match("^mm_(%d+)=(%S+)")
      if value and is_named(value) then
        refs[#refs + 1] = { id = value, where = ("Mouse modifier %s, slot %s"):format(section, slot) }
      end
    end
  end
  return refs
end

--- S&M_Cyclactions.ini: "ActionN=<name>|<step>|<step>|...". Steps also contain cycle commands ("!", "IF",
--- "ENDIF", numbers): only named IDs are checked.
function Checks.parse_cycle(text)
  local refs, section = {}, "?"
  for line in lines(text) do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      section = header
    else
      local def = line:match("^Action%d+=(.*)$")
      if def then
        local name, n = nil, 0
        for part in (def .. "|"):gmatch("([^|]*)|") do
          if not name then
            name = part
          else
            n = n + 1
            if is_named(part) then
              refs[#refs + 1] = { id = part, where = ('Cycle action "%s" (%s), step %d'):format(name, section, n) }
            end
          end
        end
      end
    end
  end
  return refs
end

--- S&M.ini: any setting whose value is a named action ID (e.g. SWS startup actions).
function Checks.parse_sws(text)
  local refs, section = {}, "?"
  for line in lines(text) do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      section = header
    else
      local key, value = line:match("^([^=;]+)=%s*(%S+)%s*$")
      if value and is_named(value) then
        refs[#refs + 1] = { id = value, where = ("SWS setting [%s] %s"):format(section, key) }
      end
    end
  end
  return refs
end

--- An action marker's name -> list of command tokens, or nil if it is no action marker ("!1016 _RS...").
function Checks.marker_commands(name)
  local body = (name or ""):match("^!%s*(.-)%s*$")
  if not body or body == "" then return nil end
  local cmds = {}
  for token in body:gmatch("%S+") do cmds[#cmds + 1] = token end
  return cmds
end

--- True for "C:\...", "C:/...", "/..." and "\\server\...".
function Checks.is_absolute(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\]") ~= nil
end

--- Checks references. Pure: the questions to REAPER and the file system are passed in.
---   known(id)          does REAPER know this command ID?
---   file_exists(path)  does this script file exist? (path as stored in reaper-kb.ini)
--- Returns problems ({ where, id, problem }) and unused_missing (registered scripts whose file is missing
--- and that nothing refers to), both sorted.
function Checks.check(scripts, refs, known, file_exists)
  local problems, used, file_ok = {}, {}, {}
  local function script_file_ok(id)
    local path = scripts[id]
    if not path then return true end -- not a registered script (extension, custom action)
    if file_ok[path] == nil then file_ok[path] = file_exists(path) and true or false end
    return file_ok[path], path
  end

  for _, r in ipairs(refs) do
    used[r.id] = true
    if not known(r.id) then
      problems[#problems + 1] = { where = r.where, id = r.id, problem = "no such action" }
    else
      local ok, path = script_file_ok(r.id)
      if not ok then
        problems[#problems + 1] = { where = r.where, id = r.id, problem = "script file missing: " .. path }
      end
    end
  end

  local unused_missing = {}
  for id, path in pairs(scripts) do
    if not used[id] and not script_file_ok(id) then
      unused_missing[#unused_missing + 1] = { id = id, path = path }
    end
  end

  table.sort(problems, function(a, b) return a.where < b.where end)
  table.sort(unused_missing, function(a, b) return a.path < b.path end)
  return problems, unused_missing
end

--- Turns a report into { name, ok } rows: one failed row per problem, then one summary row.
function Checks.results(report, title)
  local rows = {}
  for _, f in ipairs(report.unreadable or {}) do rows[#rows + 1] = { name = "could not read " .. f, ok = false } end
  for _, p in ipairs(report.problems) do
    rows[#rows + 1] = { name = ("%s: %s %s"):format(p.where, p.id, p.problem), ok = false }
  end
  rows[#rows + 1] = { name = ("%s: %d references checked, %d broken"):format(title, report.checked, #report.problems),
    ok = #report.problems == 0 and #(report.unreadable or {}) == 0 }
  return rows
end

-- Live checks (real files, real REAPER) --------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function known(id)
  return reaper.NamedCommandLookup(id) ~= 0
end

--- Reads the config files and checks every named reference. A missing optional file (mouse modifiers,
--- SWS files) is not a problem: it simply has nothing to check. A missing reaper-kb.ini is.
function Checks.check_config()
  local sep = package.config:sub(1, 1)
  local resource = reaper.GetResourcePath()
  local texts, unreadable = {}, {}
  for key, name in pairs(Checks.FILES) do texts[key] = read_file(resource .. sep .. name) end
  if not texts.kb then unreadable[#unreadable + 1] = Checks.FILES.kb end

  local scripts, refs = Checks.parse_kb(texts.kb)
  for _, more in ipairs({ Checks.parse_menu(texts.menu), Checks.parse_mouse(texts.mouse),
      Checks.parse_cycle(texts.cycle), Checks.parse_sws(texts.sws) }) do
    for _, r in ipairs(more) do refs[#refs + 1] = r end
  end

  local function file_exists(path)
    local full = Checks.is_absolute(path) and path or (resource .. sep .. "Scripts" .. sep .. path)
    return reaper.file_exists((full:gsub("[/\\]", sep)))
  end
  local problems, unused_missing = Checks.check(scripts, refs, known, file_exists)
  return { problems = problems, unused_missing = unused_missing, checked = #refs, unreadable = unreadable }
end

--- Checks the action markers of all open projects. Named IDs: REAPER must know them. Native IDs: must exist
--- in the main section.
function Checks.check_markers()
  local problems, checked = {}, 0
  local p = 0
  while true do
    local proj = reaper.EnumProjects(p)
    if not proj then break end
    local proj_name = reaper.GetProjectName(proj)
    if proj_name == "" then proj_name = "(unsaved project)" end
    local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
    for i = 0, num_markers + num_regions - 1 do
      local _, is_region, pos, _, name, number = reaper.EnumProjectMarkers3(proj, i)
      local cmds = not is_region and Checks.marker_commands(name)
      if cmds then
        for _, token in ipairs(cmds) do
          checked = checked + 1
          local ok
          if is_named(token) then
            ok = known(token)
          else
            local n = tonumber(token)
            ok = n ~= nil and (reaper.kbd_getTextFromCmd(n, 0) or "") ~= ""
          end
          if not ok then
            problems[#problems + 1] = { where = ('%s, marker %d "%s" at %s'):format(proj_name, number, name,
              reaper.format_timestr_pos(pos, "", -1)), id = token, problem = "no such action" }
          end
        end
      end
    end
    p = p + 1
  end
  return { problems = problems, unused_missing = {}, checked = checked, unreadable = {} }
end

-- Self test ------------------------------------------------------------------------------------

function Checks.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local kb = table.concat({
    'SCR 4 0 RSaaa "Custom: Play.lua" SiSt-Live/Transport/Play.lua',
    'SCR 4 0 RSbbb "Custom: Gone.lua" "SiSt-Live/Old Folder/Gone.lua"',
    'SCR 4 0 RSccc "Custom: Unused gone.lua" SiSt-Live/Unused.lua',
    'ACT 1 0 "abc123" "SiSt-Live_Project End Handler" 1016 _RSaaa 40861 _RSbbb _SWS_GONE _abc999',
    'KEY 159 16256 _RSaaa 0\t\t # Main : MIDI Chan 16 Note 0 : Script: Play.lua',
    'KEY 9 65 40044 0\t\t # Main : Ctrl+A : Transport: Play/stop',
  }, "\r\n")
  local scripts, refs = Checks.parse_kb(kb)
  check("kb: registered scripts with plain and quoted paths",
    scripts._RSaaa == "SiSt-Live/Transport/Play.lua" and scripts._RSbbb == "SiSt-Live/Old Folder/Gone.lua")
  check("kb: named custom action steps only, with step number", #refs == 5 and refs[1].id == "_RSaaa"
    and refs[1].where == 'Custom action "SiSt-Live_Project End Handler", step 2' and refs[4].id == "_abc999")
  check("kb: named shortcut with section and key, numeric shortcut ignored",
    refs[5].where == "Shortcut Main : MIDI Chan 16 Note 0")

  local menu = Checks.parse_menu(table.concat({
    "[Floating toolbar 32]", "item_0=_RSddd Project List", "item_1=-1", "item_2=40044 Play",
  }, "\n"))
  check("menu: named buttons only", #menu == 1 and menu[1].where == 'Floating toolbar 32, item 1 "Project List"')

  local mouse = Checks.parse_mouse(table.concat({
    "[hasimported]", "MM_CTX_ITEM=1", "[MM_CTX_ITEM_DBLCLK]", "mm_1=0 m", "mm_10=_XENAKIOS_RESETTAKEVOL",
    "mm_12=40653 c", "[MM_CTX_TRACK_CLK]", "mm_6=_e65a75cf",
  }, "\n"))
  check("mouse: named actions only, behaviours and native actions ignored", #mouse == 2
    and mouse[1].id == "_XENAKIOS_RESETTAKEVOL" and mouse[2].where == "Mouse modifier MM_CTX_TRACK_CLK, slot 6")

  local cycle = Checks.parse_cycle(table.concat({
    "[Main_Cyclactions]", "Action1=Cycle: Loop 4x|IF NOT|1068|_c72d|ENDIF|!|65535|!|ENDLOOP|_984d|", "Nb_Actions=1",
  }, "\n"))
  check("cycle: named steps with step number, cycle commands ignored", #cycle == 2 and cycle[1].id == "_c72d"
    and cycle[1].where == 'Cycle action "Cycle: Loop 4x" (Main_Cyclactions), step 3')

  local sws = Checks.parse_sws("[Misc]\nRemoveAllEnvsSelTracksPrompt=1\nGlobalStartupAction=_RSaaa\n[Notes]\nBigFontName=Arial\n")
  check("sws: settings that store a named action", #sws == 1 and sws[1].where == "SWS setting [Misc] GlobalStartupAction")

  check("marker: action marker commands", table.concat(Checks.marker_commands("!1016 _RSaaa") or {}, ",") == "1016,_RSaaa"
    and Checks.marker_commands("Verse") == nil and Checks.marker_commands("!") == nil)

  for _, more in ipairs({ menu, mouse, cycle, sws }) do for _, r in ipairs(more) do refs[#refs + 1] = r end end
  local known_ids = { _RSaaa = true, _RSbbb = true, _RSccc = true, _abc999 = true, _XENAKIOS_RESETTAKEVOL = true,
    _e65a75cf = true, _c72d = true }
  local files = { ["SiSt-Live/Transport/Play.lua"] = true }
  local problems, unused = Checks.check(scripts, refs, function(id) return known_ids[id] end,
    function(path) return files[path] end)
  local by_id = {}
  for _, p in ipairs(problems) do by_id[p.id] = p.problem end
  check("check: unknown extension action", by_id._SWS_GONE == "no such action")
  check("check: deleted script that REAPER still lists", by_id._RSbbb == "script file missing: SiSt-Live/Old Folder/Gone.lua")
  check("check: script that was never registered", by_id._RSddd == "no such action")
  check("check: unknown cycle action step", by_id._984d == "no such action")
  check("check: working references are fine", by_id._RSaaa == nil and by_id._abc999 == nil and by_id._e65a75cf == nil)
  check("check: unused script with missing file listed separately", #unused == 1 and unused[1].path == "SiSt-Live/Unused.lua")

  local rows = Checks.results({ problems = problems, checked = #refs, unreadable = {} }, "Config")
  check("results: one row per problem plus a failed summary", #rows == #problems + 1 and not rows[#rows].ok)
  check("is_absolute", Checks.is_absolute("C:\\x.lua") and Checks.is_absolute("/x.lua") and not Checks.is_absolute("a/x.lua"))
  check("empty files give nothing", #select(2, Checks.parse_kb(nil)) == 0 and #Checks.parse_menu(nil) == 0)
  return results
end

return Checks
