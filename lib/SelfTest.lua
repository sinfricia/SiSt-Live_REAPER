-- @noindex
--[[
SelfTest: a small, generic self-test library for ReaScripts.

Part of the future shared libraries: it knows no package. Any package can use it.

THE PIECES
  Component   anything that can be tested. A table with:
                name          shown in the report
                file          optional: the file it tests, relative to the package root ("lib/Mode.lua").
                              Used by the coverage check.
                self_test()   optional: tests with fakes, must never change REAPER -> { { name, ok }, ... }
                live_check()  optional: read-only checks against the REAL REAPER -> { { name, ok }, ... }
                diagnostics() optional: information rows -> { { label, value }, ... }
              A result row with warn = true is a warning: shown, but neither passed nor failed.
  Test list   one file per package (not an action) that returns a suite:
                { name = "SiSt-Live", root = <package folder>, components = { ... },
                  coverage = { folder = "lib", exceptions = { ["lib/x.lua"] = "why it has no tests" } } }
              A test list must work from anywhere: it sets up its own module path relative to its own location.
  Runner      SelfTest.run_suites(suites, title): runs every component, catches crashes, counts PASS / FAIL / WARN,
              prints a short report to the console and writes the full one to
              <resource path>/Data/SiSt Libraries/Self-test report.txt.
  Registry    packages register their test list (SelfTest.register, done automatically by the package), so
              SelfTest.run_registered() can test everything that is installed. Stored in ExtState (persistent), one
              entry "name=path|name=path", paths relative to the REAPER resource folder. Self-healing: a test
              list that no longer exists is reported and removed; the package registers itself again on its
              next run.
  Scenarios   SelfTest.run_scenario(scenario): live tests of real workflows (act, wait, check), see below.

WRITING TESTS
  local SelfTest = require("SelfTest")
  function MyModule.self_test()
    local check, results = SelfTest.checker()
    check("adds numbers", MyModule.add(1, 2) == 3)
    return results
  end

COMPONENT SCRIPTS (actions with a window)
  Their tests live inside the script. SelfTest.collect_script(path) runs the script with the test-only switch set
  (global SELFTEST_COLLECT); the script hands over its components instead of opening its window:
    if rawget(_G, "SELFTEST_COLLECT") then
      table.insert(SELFTEST_COLLECT, { name = "My window", self_test = MyWindow.self_test })
      return
    end

Self test: SelfTest.self_test() (pure functions only).
]]

local SelfTest = {}

SelfTest.REGISTRY_SECTION = "SiSt Libraries"
SelfTest.REGISTRY_KEY     = "test_registry"
SelfTest.REPORT_DIR       = "SiSt Libraries"        -- below <resource path>/Data
SelfTest.REPORT_FILE      = "Self-test report.txt"
SelfTest.COLLECT_GLOBAL   = "SELFTEST_COLLECT"

local function sep() return package.config:sub(1, 1) end

-- Writing tests -------------------------------------------------------------------------

--- Returns check(name, condition) and the list it fills. Return the list from self_test().
function SelfTest.checker()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = { name = name, ok = cond and true or false }
  end
  return check, results
end

--- A warning row: shown in the report, counted as a warning (neither passed nor failed).
function SelfTest.warning(name)
  return { name = name, ok = true, warn = true }
end

-- Paths (pure) ---------------------------------------------------------------------------

--- Forward slashes, "." and ".." resolved. Keeps a leading "C:/", "//" or "/".
function SelfTest.normalize(path)
  path = (path or ""):gsub("\\", "/")
  local prefix = path:match("^%a:/") or path:match("^//") or path:match("^/") or ""
  local parts = {}
  for part in path:sub(#prefix + 1):gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil else parts[#parts + 1] = ".." end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return prefix .. table.concat(parts, "/")
end

--- path relative to base (both normalized, case ignored), or nil if path is not inside base.
function SelfTest.relative_to(path, base)
  local p, b = SelfTest.normalize(path), SelfTest.normalize(base)
  if b:sub(-1) ~= "/" then b = b .. "/" end
  if #p > #b and p:sub(1, #b):lower() == b:lower() then return p:sub(#b + 1) end
  return nil
end

local function is_absolute(path)
  return path:match("^%a:/") ~= nil or path:sub(1, 1) == "/"
end

-- Registry -----------------------------------------------------------------------------------

--- Pure. { { name, path } } <-> "name=path|name=path"
function SelfTest.encode_registry(entries)
  local parts = {}
  for _, e in ipairs(entries) do parts[#parts + 1] = e.name .. "=" .. e.path end
  return table.concat(parts, "|")
end

function SelfTest.decode_registry(str)
  local entries = {}
  for part in (str or ""):gmatch("[^|]+") do
    local name, path = part:match("^([^=]+)=(.+)$")
    if name then entries[#entries + 1] = { name = name, path = path } end
  end
  return entries
end

local function read_registry()
  return SelfTest.decode_registry(reaper.GetExtState(SelfTest.REGISTRY_SECTION, SelfTest.REGISTRY_KEY))
end

local function write_registry(entries)
  table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
  reaper.SetExtState(SelfTest.REGISTRY_SECTION, SelfTest.REGISTRY_KEY, SelfTest.encode_registry(entries), true)
end

--- Registers a package's test list (full path). Writes only if it is new or the path changed.
--- Returns true, or false + reason.
function SelfTest.register(name, list_path)
  if type(name) ~= "string" or name == "" or name:find("[|=]") then return false, "invalid package name" end
  local stored = SelfTest.relative_to(list_path, reaper.GetResourcePath()) or SelfTest.normalize(list_path)
  if stored:find("|", 1, true) then return false, "path contains '|'" end
  local entries = read_registry()
  for _, e in ipairs(entries) do
    if e.name == name then
      if e.path == stored then return true end
      e.path = stored
      write_registry(entries)
      return true
    end
  end
  entries[#entries + 1] = { name = name, path = stored }
  write_registry(entries)
  return true
end

function SelfTest.unregister(name)
  local entries, kept = read_registry(), {}
  for _, e in ipairs(entries) do if e.name ~= name then kept[#kept + 1] = e end end
  if #kept ~= #entries then write_registry(kept) end
end

--- Registry entries with their full paths: { { name, path (as stored), full } }
function SelfTest.registered()
  local resource = SelfTest.normalize(reaper.GetResourcePath())
  local list = {}
  for _, e in ipairs(read_registry()) do
    local full = is_absolute(e.path) and e.path or (resource .. "/" .. e.path)
    list[#list + 1] = { name = e.name, path = e.path, full = (full:gsub("/", sep())) }
  end
  return list
end

-- Loading tests ------------------------------------------------------------------------------

--- Loads a test list file. Returns the suite, or nil + reason.
function SelfTest.load_suite(path)
  local ok, suite = pcall(dofile, path)
  if not ok then return nil, tostring(suite) end
  if type(suite) ~= "table" or type(suite.name) ~= "string" or type(suite.components) ~= "table" then
    return nil, "not a test list (it must return a table with name and components)"
  end
  return suite
end

--- Runs a component script with the test-only switch set and returns the components it hands over.
--- A script that fails or hands over nothing is returned as a component with an error.
function SelfTest.collect_script(path)
  local label = path:match("[^/\\]+$") or path
  local collected = {}
  _G[SelfTest.COLLECT_GLOBAL] = collected
  local ok, err = pcall(dofile, path)
  _G[SelfTest.COLLECT_GLOBAL] = nil
  if not ok then return { { name = label, error = tostring(err) } } end
  if #collected == 0 then
    return { { name = label, error = "handed over no tests (does it support the test-only switch?)" } }
  end
  return collected
end

-- Running ------------------------------------------------------------------------------------

--- Runs one component. Returns rows: { kind = "test" | "live" | "error" | "info", name, ok, warn, value }.
function SelfTest.run_component(c)
  local rows = {}
  local function add(row) rows[#rows + 1] = row end
  if c.error then
    add({ kind = "error", name = "could not load: " .. c.error, ok = false })
    return rows
  end
  for _, part in ipairs({ { "self_test", "test" }, { "live_check", "live" } }) do
    local fn = c[part[1]]
    if fn then
      local ok, res = xpcall(fn, debug.traceback)
      if not ok then
        add({ kind = "error", name = part[1] .. " crashed: " .. tostring(res), ok = false })
      elseif type(res) ~= "table" then
        add({ kind = "error", name = part[1] .. " returned no result list", ok = false })
      else
        for _, r in ipairs(res) do
          add({ kind = part[2], name = tostring(r.name), ok = r.ok and true or false, warn = r.warn and true or nil })
        end
      end
    end
  end
  if c.diagnostics then
    local ok, res = xpcall(c.diagnostics, debug.traceback)
    if not ok then
      add({ kind = "info", name = "diagnostics error", value = tostring(res) })
    elseif type(res) == "table" then
      for _, r in ipairs(res) do add({ kind = "info", name = tostring(r[1]), value = tostring(r[2]) }) end
    end
  end
  return rows
end

--- Pure. Counts rows: passed, failed, warnings (info rows don't count).
function SelfTest.count(rows)
  local passed, failed, warnings = 0, 0, 0
  for _, r in ipairs(rows) do
    if r.kind ~= "info" then
      if r.warn then warnings = warnings + 1
      elseif r.ok then passed = passed + 1
      else failed = failed + 1 end
    end
  end
  return passed, failed, warnings
end

-- Coverage ------------------------------------------------------------------------------------

--- All files below dir (recursive) with the given extension, as relative paths with "/". Sorted.
function SelfTest.list_files(dir, ext)
  local out = {}
  local function walk(abs, rel)
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(abs, i)
      if not f then break end
      if not ext or f:sub(-#ext):lower() == ext:lower() then out[#out + 1] = rel .. f end
      i = i + 1
    end
    i = 0
    while true do
      local d = reaper.EnumerateSubdirectories(abs, i)
      if not d then break end
      walk(abs .. sep() .. d, rel .. d .. "/")
      i = i + 1
    end
  end
  walk(dir, "")
  table.sort(out)
  return out
end

--- Pure. Warning rows for every file that no component names (case ignored) and that has no exception.
function SelfTest.uncovered(files, components, exceptions)
  local covered, excused = {}, {}
  for _, c in ipairs(components) do if c.file then covered[SelfTest.normalize(c.file):lower()] = true end end
  for path in pairs(exceptions or {}) do excused[SelfTest.normalize(path):lower()] = true end
  local rows = {}
  for _, f in ipairs(files) do
    local key = SelfTest.normalize(f):lower()
    if not covered[key] and not excused[key] then
      rows[#rows + 1] = SelfTest.warning(f .. ": not on the test list")
    end
  end
  return rows
end

-- The coverage check of a suite, as one more component.
local function coverage_component(suite)
  local cov = suite.coverage
  if not (cov and cov.folder and suite.root) then return nil end
  return {
    name = "Test coverage (" .. cov.folder .. "/)",
    live_check = function()
      local dir = SelfTest.normalize(suite.root .. "/" .. cov.folder)
      local files = {}
      for _, f in ipairs(SelfTest.list_files((dir:gsub("/", sep())), ".lua")) do files[#files + 1] = cov.folder .. "/" .. f end
      local rows = SelfTest.uncovered(files, suite.components, cov.exceptions)
      table.insert(rows, 1, { name = ("%d files checked"):format(#files), ok = true })
      return rows
    end,
    diagnostics = function()
      local rows = {}
      for path, why in pairs(cov.exceptions or {}) do rows[#rows + 1] = { "no tests: " .. path, why } end
      table.sort(rows, function(a, b) return a[1] < b[1] end)
      return rows
    end,
  }
end

-- Report ----------------------------------------------------------------------------------------

local function row_line(r)
  if r.kind == "info" then return ("  %-24s %s"):format(r.name, r.value) end
  local tag = r.warn and "WARN" or (r.ok and "PASS" or "FAIL")
  return ("  %s  %s%s"):format(tag, r.kind == "live" and "live: " or "", r.name)
end

local function write_report(lines, file_name)
  local dir = reaper.GetResourcePath() .. sep() .. "Data" .. sep() .. SelfTest.REPORT_DIR
  reaper.RecursiveCreateDirectory(dir, 0)
  local path = dir .. sep() .. (file_name or SelfTest.REPORT_FILE)
  local f = io.open(path, "wb")
  if not f then return nil end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  return path
end

--- Runs suites. Console: one line per component, every FAIL / WARN line and the diagnostics. Report file:
--- everything, incl. every PASS line. opts.report_file: other report file name (same folder).
--- Returns passed, failed, warnings.
function SelfTest.run_suites(suites, title, opts)
  local console, full = {}, {}
  local function both(line) console[#console + 1] = line; full[#full + 1] = line end
  both(("=== %s ==="):format(title or "Self-test"))
  both(("%s | REAPER %s | %s"):format(os.date("%Y-%m-%d %H:%M:%S"), reaper.GetAppVersion(), _VERSION))

  local total_p, total_f, total_w = 0, 0, 0
  for _, suite in ipairs(suites) do
    both("")
    both("##### " .. suite.name)
    local components = {}
    for _, c in ipairs(suite.components) do components[#components + 1] = c end
    components[#components + 1] = coverage_component(suite)

    for _, c in ipairs(components) do
      local rows = SelfTest.run_component(c)
      local p, f, w = SelfTest.count(rows)
      total_p, total_f, total_w = total_p + p, total_f + f, total_w + w

      local summary = ("[%s] %d passed"):format(c.name, p)
      if f > 0 then summary = summary .. (", %d FAILED"):format(f) end
      if w > 0 then summary = summary .. (", %d warning%s"):format(w, w == 1 and "" or "s") end
      console[#console + 1] = summary
      full[#full + 1] = ""
      full[#full + 1] = summary
      for _, r in ipairs(rows) do
        local line = row_line(r)
        full[#full + 1] = line
        if r.kind == "info" or r.warn or not r.ok then console[#console + 1] = line end
      end
    end
  end

  both("")
  both(("Result: %d passed, %d failed, %d warning%s"):format(total_p, total_f, total_w, total_w == 1 and "" or "s"))
  local path = write_report(full, opts and opts.report_file)
  console[#console + 1] = path and ("Full report: " .. path) or "Full report could not be written."
  reaper.ShowConsoleMsg(table.concat(console, "\n") .. "\n")
  return total_p, total_f, total_w
end

--- Runs every registered test list. Lists that no longer exist are reported and removed from the registry.
function SelfTest.run_registered()
  local suites, notes, overview = {}, {}, {}
  for _, e in ipairs(SelfTest.registered()) do
    overview[#overview + 1] = { e.name, e.path }
    if not reaper.file_exists(e.full) then
      notes[#notes + 1] = SelfTest.warning(("%s: test list not found (%s), removed from the registry"):format(e.name, e.path))
      SelfTest.unregister(e.name)
    else
      local suite, err = SelfTest.load_suite(e.full)
      suites[#suites + 1] = suite or { name = e.name, components = { { name = "test list", error = err } } }
    end
  end
  if #overview == 0 then notes[#notes + 1] = SelfTest.warning("no test lists registered yet") end

  table.insert(suites, 1, { name = "Registry", components = { {
    name = "Registered test lists",
    live_check = function()
      local rows = { { name = ("%d registered"):format(#overview), ok = true } }
      for _, n in ipairs(notes) do rows[#rows + 1] = n end
      return rows
    end,
    diagnostics = function() return overview end,
  } } })
  return SelfTest.run_suites(suites, "All registered self-tests")
end

-- Scenarios (live tests) ---------------------------------------------------------------------

--[[
A scenario tests a real workflow in the running REAPER: each step DOES something (runs an action), waits until
REAPER has reacted (playback, project switches take a moment) and then checks the result. Waiting is deferred, so
REAPER keeps running. Scenarios change REAPER's state: only run them on test projects, never in a show.

  scenario = {
    name        = "SiSt-Live live test",
    check_ready = function() return ok, reason end,      -- optional: refuse to start (reason goes to the console)
    steps = {
      { name = "Switch to show mode",
        run   = function() ... end,                         -- acts; an error here stops the scenario
        wait  = 2,                                          -- seconds before check
        check = function() return { { name, ok }, ... } end,
        required = true,                                    -- optional: a failed check stops the scenario
        quiet = true },                                     -- optional: no own report section; its rows go to
                                                            -- the next step that isn't quiet (many small steps)
      ...
    },
    cleanup     = function() ... end,                       -- optional: always runs at the end; may return
                                                            -- { { name, ok } } rows for the report
  }

A step whose run fails stops the scenario (later steps build on it); the remaining steps are reported as
skipped. A failed check only stops it if the step is `required` (e.g. preparing the test projects). The result is a normal report (one component per step).
]]

--- Runs a scenario (see above). opts: passed on to run_suites (e.g. report_file); opts.progress = true opens a
--- small window that shows the running step; closing it stops the scenario (cleanup still runs);
--- opts.after_report(passed, failed, warnings) runs after the report is in the console.
--- Returns false if check_ready refused, true once started (the report comes when the last step is done).
function SelfTest.run_scenario(scenario, title, opts)
  title = title or scenario.name
  if scenario.check_ready then
    local ok, ready, reason = xpcall(scenario.check_ready, debug.traceback)
    if not ok or not ready then
      reaper.ShowConsoleMsg(("=== %s ===\nNot started: %s\n"):format(title, tostring(ok and reason or ready)))
      return false
    end
  end

  local results, index, current, wake = {}, 0, nil, 0
  local progress, stopped, started = opts and opts.progress, false, reaper.time_precise()
  if progress then -- top center of the screen (the middle is often covered by REAPER windows)
    local W, H, MARGIN = 520, 110, 60
    local l, top, r = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    gfx.init(title, W, H, 0, math.floor(l + (r - l - W) / 2), top + MARGIN)
  end
  local function show_progress()
    if not progress then return end
    if gfx.getchar() < 0 then stopped = true; return end -- the window was closed
    -- "Debug" look: dark amber with an amber bar at the top, so the test window stands out from REAPER's windows.
    -- The whole background is painted every time, so no old text stays visible.
    gfx.set(0.28, 0.21, 0.07)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    gfx.set(1.0, 0.74, 0.22)
    gfx.rect(0, 0, gfx.w, 4, 1)
    gfx.setfont(1, "Arial", 16)
    gfx.set(1.0, 0.90, 0.70)
    gfx.x, gfx.y = 12, 10
    gfx.drawstr(("Step %d of %d  (%d s)"):format(index, #scenario.steps, math.floor(reaper.time_precise() - started)))
    gfx.setfont(1, "Arial", 20, string.byte("b"))
    gfx.x, gfx.y = 12, 36
    gfx.drawstr(current and current.name or "")
    gfx.setfont(1, "Arial", 14)
    gfx.set(0.88, 0.76, 0.52)
    gfx.x, gfx.y = 12, 78
    gfx.drawstr("Close this window to stop the test.")
    gfx.update()
  end
  local pending = {} -- rows of quiet steps, waiting for the next step that isn't quiet
  local function add(name, rows)
    if #pending > 0 then
      local all = pending
      for _, r in ipairs(rows) do all[#all + 1] = r end
      rows, pending = all, {}
    end
    results[#results + 1] = { name = name, rows = rows }
  end

  local function finish()
    if progress then gfx.quit() end
    if #pending > 0 then add("(more results)", {}) end
    if scenario.cleanup then
      local ok, rows = xpcall(scenario.cleanup, debug.traceback)
      if not ok then
        add("Cleanup", { { name = "cleanup crashed: " .. tostring(rows), ok = false } })
      elseif type(rows) == "table" and #rows > 0 then
        add("Cleanup", rows)
      end
    end
    local components = {}
    for _, r in ipairs(results) do
      local rows = r.rows
      components[#components + 1] = { name = r.name, live_check = function() return rows end }
    end
    local passed, failed, warnings = SelfTest.run_suites({ { name = scenario.name, components = components } }, title, opts)
    if opts and opts.after_report then -- e.g. a question that depends on the results, asked with the report in view
      local ok, err = xpcall(opts.after_report, debug.traceback, passed, failed, warnings)
      if not ok then reaper.ShowConsoleMsg("after_report failed: " .. tostring(err) .. "\n") end
    end
  end

  -- Reports the steps after `last` as skipped and finishes.
  local function stop_after(last)
    for j = last + 1, #scenario.steps do
      add(scenario.steps[j].name, { SelfTest.warning("skipped: an earlier step failed") })
    end
    finish()
  end

  local next_step
  local function wait_and_check()
    show_progress()
    if stopped then
      add(current.name, { SelfTest.warning("stopped: the progress window was closed") })
      return stop_after(index)
    end
    if reaper.time_precise() < wake then return reaper.defer(wait_and_check) end
    local ok, rows = xpcall(current.check or function() return {} end, debug.traceback)
    if not ok or type(rows) ~= "table" then rows = { { name = "check crashed: " .. tostring(rows), ok = false } } end
    if current.quiet then
      for _, r in ipairs(rows) do pending[#pending + 1] = r end
    else
      add(current.name, rows)
    end
    if current.required then
      for _, r in ipairs(rows) do
        if not r.ok and not r.warn then return stop_after(index) end
      end
    end
    next_step()
  end

  local function run_current()
    if stopped then
      add(current.name, { SelfTest.warning("stopped: the progress window was closed") })
      return stop_after(index)
    end
    local ok, err = xpcall(current.run, debug.traceback)
    if not ok then
      add(current.name, { { name = "could not run: " .. tostring(err), ok = false } })
      return stop_after(index)
    end
    wake = reaper.time_precise() + (current.wait or 0)
    reaper.defer(wait_and_check)
  end

  next_step = function()
    index = index + 1
    current = scenario.steps[index]
    if not current then return finish() end
    -- Show the step first and run it in the next cycle: the window only repaints when the script yields, so the
    -- name would otherwise appear only after the step's action (late, e.g. while a dialog is open).
    show_progress()
    reaper.defer(run_current)
  end

  next_step()
  return true
end

-- Self test ---------------------------------------------------------------------------------------

function SelfTest.self_test()
  local check, results = SelfTest.checker()

  local c2, r2 = SelfTest.checker()
  c2("a", true); c2("b", nil)
  check("checker: rows with name and ok", #r2 == 2 and r2[1].ok == true and r2[2].ok == false and r2[2].name == "b")

  check("normalize: separators and ..", SelfTest.normalize("C:\\R\\Scripts\\x\\..\\lib\\a.lua") == "C:/R/Scripts/lib/a.lua")
  check("normalize: unix root and .", SelfTest.normalize("/r/./x//y") == "/r/x/y")
  check("normalize: .. beyond the start is kept", SelfTest.normalize("a/../../b") == "../b")
  check("relative_to: inside, case ignored", SelfTest.relative_to("C:/R/Scripts/x.lua", "c:\\r") == "Scripts/x.lua")
  check("relative_to: outside, or only a name prefix", SelfTest.relative_to("D:/x.lua", "C:/R") == nil
    and SelfTest.relative_to("C:/Rx/a.lua", "C:/R") == nil)

  local reg = { { name = "B", path = "Scripts/b.lua" }, { name = "A", path = "C:/x/a.lua" } }
  local back = SelfTest.decode_registry(SelfTest.encode_registry(reg))
  check("registry: round trip", #back == 2 and back[1].name == "B" and back[2].path == "C:/x/a.lua")
  check("registry: empty and garbage", #SelfTest.decode_registry("") == 0 and #SelfTest.decode_registry("nonsense|x=y") == 1)

  local rows = SelfTest.run_component({ name = "x",
    self_test = function() return { { name = "ok", ok = true }, { name = "bad", ok = false }, SelfTest.warning("hm") } end,
    live_check = function() error("boom") end,
    diagnostics = function() return { { "label", 5 } } end })
  local p, f, w = SelfTest.count(rows)
  check("run_component: results, crash caught, diagnostics", p == 1 and f == 2 and w == 1
    and rows[#rows].kind == "info" and rows[#rows].value == "5")
  check("run_component: a component that failed to load is one failure",
    select(2, SelfTest.count(SelfTest.run_component({ name = "y", error = "missing" }))) == 1)
  check("run_component: a self_test without a result list fails",
    select(2, SelfTest.count(SelfTest.run_component({ name = "z", self_test = function() end }))) == 1)

  local unc = SelfTest.uncovered({ "lib/A.lua", "lib/b.lua", "lib/c.lua" },
    { { name = "a", file = "lib/a.lua" } }, { ["lib/c.lua"] = "why" })
  check("uncovered: only files neither listed nor excused, case ignored", #unc == 1 and unc[1].warn
    and unc[1].name:find("lib/b.lua", 1, true) == 1)
  return results
end

return SelfTest
