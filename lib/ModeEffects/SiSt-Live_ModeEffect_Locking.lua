-- @noindex
-- SiSt-Live mode effect: turns REAPER's locking on (with every lock mode except full item locking)
-- or off per mode.
--
-- Locking is a PROJECT setting, so the effect applies it to every open project tab, not just the
-- active one. It uses REAPER's own non-toggle actions, which can safely run again:
--   on:  "Locking: Set ... locking mode" for every lock mode in Locking.ON_STEPS, "Locking: Clear full
--        item locking mode" (its visual effect isn't wanted, the other modes cover it), then
--        "Locking: Enable locking"
--   off: "Locking: Disable locking". The lock modes stay set; they only matter while locking is on.
-- To lock more or less, edit Locking.ON_STEPS.
-- The actions are run per project with Main_OnCommandEx, without switching tabs (switching could
-- disturb a playing project).
--
-- Because nothing toggles, there is no state to check: every run sets the state again. Projects
-- opened later are not touched until the next switch or "Apply current mode".
--
-- Set in "SiSt-Live: Configure modes": "on" or "off".
-- The command IDs are trusted (IDs don't change, names sometimes do): before running, the effect only
-- checks that every action exists. Locking.check_actions() lists them for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.

local Actions = require("SiSt-Live_Actions")

local Locking = { name = "locking" }

Locking.SECTION    = "SiSt-Live"
Locking.KEY_PREFIX = "locking_" -- + mode. Value: "on", "off", "" = none

-- Native actions (fixed IDs; "what" is what they do, REAPER's names may differ), in the order they run.
Locking.ON_STEPS = {
  { cmd = 40595, what = "Locking: Set item edges locking mode" },
  { cmd = 40598, what = "Locking: Set item fade/volume handles locking mode" },
  { cmd = 41852, what = "Locking: Set item stretch marker locking mode" },
  { cmd = 40577, what = "Locking: Set left/right item locking mode" },
  { cmd = 40580, what = "Locking: Set up/down item locking mode" },
  { cmd = 41849, what = "Locking: Set take envelope locking mode" },
  { cmd = 40583, what = "Locking: Set track envelope locking mode" },
  { cmd = 40589, what = "Locking: Set marker locking mode" },
  { cmd = 40586, what = "Locking: Set region locking mode" },
  { cmd = 40592, what = "Locking: Set time signature marker locking mode" },
  { cmd = 40571, what = "Locking: Set time selection locking mode" },
  { cmd = 40627, what = "Locking: Set loop points locking mode" },
  { cmd = 40575, what = "Locking: Clear full item locking mode" }, -- no full item locking in show mode
  { cmd = 40569, what = "Locking: Enable locking" },
}
Locking.OFF_STEPS = {
  { cmd = 40570, what = "Locking: Disable locking" },
}
Locking.CMD_TOGGLE = 1135 -- "Options: Toggle locking", only read for diagnostics (active project)

-- Actions ---------------------------------------------------------------
--- The actions a state needs, in the order they run.
function Locking.steps(on)
  return on and Locking.ON_STEPS or Locking.OFF_STEPS
end

function Locking.check_actions(api)
  local list = {}
  for _, steps in ipairs({ Locking.ON_STEPS, Locking.OFF_STEPS }) do
    for _, a in ipairs(steps) do list[#list + 1] = a end
  end
  return Actions.check_native(list, api)
end

local function open_projects(api)
  local projects = {}
  while true do
    local proj = api.EnumProjects(#projects)
    if not proj then break end
    projects[#projects + 1] = proj
  end
  return projects
end

-- Assignments -----------------------------------------------------------
--- true (on), false (off) or nil (none).
function Locking.get_assignment(mode, api)
  api = api or reaper
  local v = api.GetExtState(Locking.SECTION, Locking.KEY_PREFIX .. mode)
  if v == "on" then return true end
  if v == "off" then return false end
  return nil
end

function Locking.set_assignment(mode, value, api)
  api = api or reaper
  local v = value == true and "on" or (value == false and "off" or "")
  api.SetExtState(Locking.SECTION, Locking.KEY_PREFIX .. mode, v, true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Locking.apply(mode, api)
  local want = Locking.get_assignment(mode, api)
  if want == nil then
    return "skipped", ("no locking setting for %s mode"):format(mode)
  end

  local steps = Locking.steps(want)
  for _, a in ipairs(steps) do -- check that every action exists before running any
    Actions.require_native(a.cmd, api, a.what)
  end

  local projects = open_projects(api)
  for _, proj in ipairs(projects) do
    for _, a in ipairs(steps) do
      api.Main_OnCommandEx(a.cmd, 0, proj)
    end
  end

  return "ok", ("locking %s in %d project%s"):format(want and "on (all lock modes but full item)" or "off",
    #projects, #projects == 1 and "" or "s")
end

-- Settings --------------------------------------------------------------
-- Field text: "on" or "off", empty = leave alone.
function Locking.parse(input)
  local s = (input or ""):lower():match("^%s*(.-)%s*$")
  if s == "" then return "none" end
  if s == "on" or s == "yes" or s == "1" or s == "true" then return true end
  if s == "off" or s == "no" or s == "0" or s == "false" then return false end
  return nil, ("'%s' is not 'on' or 'off'"):format(input)
end

Locking.settings = {
  {
    label  = "locking",
    get    = function(mode, api) return Locking.get_assignment(mode, api) end,
    format = function(v) return v == nil and "" or (v and "on" or "off") end,
    parse  = function(text)
      local v, err = Locking.parse(text)
      if v == nil then return false, "locking: " .. err end
      if v == "none" then return true, nil end
      return true, v
    end,
    set    = function(mode, v, api) Locking.set_assignment(mode, v, api) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Locking.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local v = Locking.get_assignment(mode, api)
    rows[#rows + 1] = { mode .. " locking", v == nil and "(none)" or (v and "on" or "off") }
  end
  local state = api.GetToggleCommandState(Locking.CMD_TOGGLE)
  rows[#rows + 1] = { "locking (active tab)", state == 1 and "on" or (state == 0 and "off" or "(not reported)") }
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never changes the real locking.
function Locking.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function fake(opts)
    opts = opts or {}
    local ext, runs, names = {}, {}, {}
    for _, list in ipairs({ Locking.ON_STEPS, Locking.OFF_STEPS }) do
      for _, a in ipairs(list) do names[a.cmd] = a.what end
    end
    if opts.names then for k, v in pairs(opts.names) do names[k] = v end end
    local projects = opts.projects or { "p1", "p2", "p3" }
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
      EnumProjects = function(i) return projects[i + 1] end,
      Main_OnCommandEx = function(cmd, _, proj) runs[#runs + 1] = proj .. ":" .. cmd end,
    }
    return api, runs
  end

  local api, runs = fake()
  check("apply: nothing assigned -> skipped", (Locking.apply("show", api)) == "skipped" and #runs == 0)

  Locking.set_assignment("show", true, api)
  Locking.set_assignment("edit", false, api)
  local result, msg = Locking.apply("show", api)
  local per_project = #Locking.ON_STEPS
  check("apply on: every step in every project", result == "ok" and #runs == 3 * per_project
    and runs[1] == "p1:40595" and runs[per_project + 1] == "p2:40595")
  check("apply on: full item locking cleared, then locking enabled last",
    runs[per_project - 1] == "p1:40575" and runs[per_project] == "p1:40569")
  check("apply on: full item locking is never set", (function()
    for _, r in ipairs(runs) do if r:find(":40574", 1, true) or r:find(":40568", 1, true) then return false end end
    return true
  end)())
  check("apply on: message counts the projects", msg == "locking on (all lock modes but full item) in 3 projects")

  local api2, runs2 = fake()
  Locking.set_assignment("edit", false, api2)
  Locking.apply("edit", api2)
  check("apply off: only disable, in every project", table.concat(runs2, ",") == "p1:40570,p2:40570,p3:40570")

  local renamed, renamed_runs = fake({ names = { [40575] = "Locking: Clear full item lock mode (renamed)" } })
  Locking.set_assignment("show", true, renamed)
  check("apply: a renamed action still runs (the IDs are trusted)",
    (Locking.apply("show", renamed)) == "ok" and #renamed_runs == 3 * per_project)
  local missing, missing_runs = fake({ names = { [40575] = "" } })
  Locking.set_assignment("show", true, missing)
  check("apply: a missing action fails before anything runs",
    not pcall(Locking.apply, "show", missing) and #missing_runs == 0)

  local all_ok = true
  for _, r in ipairs(Locking.check_actions(fake())) do all_ok = all_ok and r.ok end
  check("live check passes when every action exists", all_ok)
  local missing_found = false
  for _, r in ipairs(Locking.check_actions(missing)) do if not r.ok then missing_found = true end end
  check("live check fails for a missing action", missing_found)

  local ls = Locking.settings[1]
  check("setting: parse / format", select(2, ls.parse("on")) == true and select(2, ls.parse("off")) == false
    and select(2, ls.parse("")) == nil and not ls.parse("x") and ls.format(true) == "on" and ls.format(nil) == "")

  return results
end

return Locking
