-- @noindex
-- SiSt-Live: DEBUG Run Setlist Scenarios
-- Runs the Setlist's real sync and load code against real project tabs (no window needed): projects opened, closed and
-- moved, a duplicate, and loading a setlist file with extras and text entries. Opens a few tiny test projects in a
-- temporary folder and closes them again. The Setlist's saved lists are never touched (test mode).
--
-- Other projects may stay open: they are never changed, only kept in the list, and their tab order is restored at the
-- end. Refuses to run while anything plays. Takes about a second. The report goes to <resource path>/Data/SiSt Libraries/Setlist scenario report.txt and a summary to the
-- REAPER console.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. script_dir .. "../?.lua;" .. package.path

local sep = package.config:sub(1, 1)
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local DuplicateWarning = require("Setlist.UI.DuplicateWarning")

local NEW_TAB = 40859

local rows = {}
local function check(label, cond, detail)
  rows[#rows + 1] = { label = label, ok = cond and true or false, detail = detail }
end
local function report(title)
  local failed, lines = 0, { "=== " .. title .. " ===", os.date("%Y-%m-%d %H:%M:%S"), "" }
  for _, r in ipairs(rows) do
    if not r.ok then failed = failed + 1 end
    lines[#lines + 1] = (r.ok and "  PASS  " or "  FAIL  ") .. r.label .. (r.ok and "" or ("  " .. tostring(r.detail or "")))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("Result: %d passed, %d failed", #rows - failed, failed)
  local text = table.concat(lines, "\n") .. "\n"
  local dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "SiSt Libraries"
  reaper.RecursiveCreateDirectory(dir, 0)
  local f = io.open(dir .. sep .. "Setlist scenario report.txt", "wb")
  if f then f:write(text) f:close() end
  reaper.ShowConsoleMsg(lines[#lines] .. "\n")
  return failed
end

-- Test projects ------------------------------------------------------------------------------------------------

local folder = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "SiSt-Live_setlist_scenarios"
reaper.RecursiveCreateDirectory(folder, 0)
local function project_path(name) return folder .. sep .. name .. ".rpp" end
local created = {}
local function create(name)
  local f = io.open(project_path(name), "wb")
  f:write('<REAPER_PROJECT 0.1 "7.0" 0\n>\n')
  f:close()
  created[#created + 1] = project_path(name)
end

local opened = {} -- project pointers that this script opened
local function open(name)
  reaper.Main_OnCommand(NEW_TAB, 0)
  reaper.Main_openProject("noprompt:" .. project_path(name))
  local proj = reaper.EnumProjects(-1)
  opened[#opened + 1] = proj
  return proj
end

local function is_open(proj)
  return reaper.ValidatePtr(proj, "ReaProject*") and Sync.tab_index(proj) ~= nil
end

local function close(proj)
  if proj and reaper.ValidatePtr(proj, "ReaProject*") then Sync.close_project(proj) end
end

-- The names of the test projects in a list, in list order ("Alpha,Charlie")
local function names(list)
  local out = {}
  for _, e in ipairs(list) do
    if e.type == Data.ENTRY.PROJECT and e.path:find(folder, 1, true) then
      out[#out + 1] = Data.project_name(e.path)
    end
  end
  return table.concat(out, ",")
end

local function has(list, type_, name)
  for _, e in ipairs(list) do
    if e.type == type_ and e.name == name then return true end
  end
  return false
end

local function refresh()
  State.tab_count = Sync.open_count()
  State.current_proj = reaper.EnumProjects(-1)
end

-- Start ------------------------------------------------------------------------------------------------------------

local function guard()
  local idx = 0
  while true do
    local proj, path = reaper.EnumProjects(idx)
    if not proj then break end
    if reaper.GetPlayStateEx(proj) & 5 ~= 0 then return "A project is playing or recording." end
    idx = idx + 1
  end
  return nil
end

local blocked = guard()
if blocked then
  reaper.MB(blocked, "Setlist scenarios", 0)
  return
end

reaper.SetExtState(Data.EXT_SECTION, "TestMode", "1", false) -- the saved lists are neither read nor written

-- What is open now, so that it can be put back the way it was
local original_tabs = Sync.project_pointers()
local original_active = reaper.EnumProjects(-1)

local function scenarios()
  for _, n in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot" }) do create(n) end

  -- 1. the tabs are the truth ------------------------------------------------------------------------------------
  local alpha, bravo, charlie = open("Alpha"), open("Bravo"), open("Charlie")
  refresh()
  State.list = {}
  Actions.follow_tabs()
  check("three projects opened: the list follows (Alpha,Bravo,Charlie)", names(State.list) == "Alpha,Bravo,Charlie", names(State.list))
  check("... and is in sync with the tabs", Sync.is_synced(State.list, Sync.project_pointers()))

  table.insert(State.list, 3, { type = Data.ENTRY.TEXT, name = "Note", path = "Note" }) -- a note between Bravo and Charlie
  Actions.commit()

  local delta = open("Delta")
  refresh()
  check("a project opened: not in sync until the list follows", not Sync.is_synced(State.list, Sync.project_pointers()))
  Actions.follow_tabs()
  check("... it is added at its tab position", names(State.list) == "Alpha,Bravo,Charlie,Delta", names(State.list))
  check("... the note is still in the list", has(State.list, "text", "Note"))

  close(bravo)
  refresh()
  Actions.follow_tabs()
  check("a project closed: its entry is removed (Alpha,Charlie,Delta)", names(State.list) == "Alpha,Charlie,Delta", names(State.list))
  check("... the note is still there", has(State.list, "text", "Note"))

  local first_test_tab = Sync.tab_index(alpha)
  Sync.move_tab(delta, first_test_tab, Sync.open_count())
  refresh()
  Actions.follow_tabs()
  check("a tab moved in REAPER: the list is reordered (Delta,Alpha,Charlie)", names(State.list) == "Delta,Alpha,Charlie", names(State.list))

  -- 2. a project open twice --------------------------------------------------------------------------------------
  local alpha2 = open("Alpha")
  refresh()
  Actions.follow_tabs()
  check("a project opened twice: two entries", names(State.list):find("Alpha,.*Alpha") ~= nil, names(State.list))
  local groups = Sync.duplicates(Sync.open_projects())
  check("... found as a duplicate", #groups == 1 and groups[1].count == 2)
  DuplicateWarning.check()
  check("... the warning is asked", State.dialog ~= nil)
  if State.dialog then State.dialog.on_choice("close") end
  refresh()
  check("... 'close the extra tabs' closes one of them", not is_open(alpha2) and is_open(alpha))
  check("... and the list follows (Delta,Alpha,Charlie)", names(State.list) == "Delta,Alpha,Charlie", names(State.list))

  -- 3. loading a setlist -----------------------------------------------------------------------------------------
  -- the setlist: Charlie (open), a text entry, Echo (exists, not open), Ghost (no file), Foxtrot (saved as missing,
  -- but its file exists)
  local loaded_list = {
    { type = Data.ENTRY.PROJECT, name = "Charlie", path = project_path("Charlie") },
    { type = Data.ENTRY.TEXT, name = "Loaded text", path = "Loaded text" },
    { type = Data.ENTRY.PROJECT, name = "Echo", path = project_path("Echo") },
    { type = Data.ENTRY.PROJECT, name = "Ghost", path = project_path("Ghost") },
    { type = Data.ENTRY.MISSING, name = "Foxtrot", path = project_path("Foxtrot") },
  }
  local setlist_path = folder .. sep .. "scenario.rsl"
  local f = io.open(setlist_path, "wb")
  f:write(Data.list_to_text(loaded_list, "\n"))
  f:close()
  created[#created + 1] = setlist_path

  local loaded, invalid = Actions.read_setlist_file(setlist_path)
  check("the setlist file is read: 5 entries, none invalid", loaded ~= nil and #loaded == 5 and #invalid == 0)
  check("... an entry saved as missing whose file exists is a project again", loaded[5].type == Data.ENTRY.PROJECT)
  check("... Charlie is found at its open tab", loaded[1].proj == charlie)

  reaper.Main_OnCommand(NEW_TAB, 0) -- a blank tab, as REAPER starts with one
  local blank = reaper.EnumProjects(-1)
  opened[#opened + 1] = blank
  refresh()
  Actions.follow_tabs()
  check("a blank tab counts as empty and unsaved", Sync.is_empty_unsaved(blank) and not Sync.is_empty_unsaved(alpha))

  local tabs = Sync.open_projects()
  local extras = Sync.diff(loaded, tabs).tab_only
  local test_extras = 0
  for _, t in ipairs(extras) do
    if t.tab.path:find(folder, 1, true) then test_extras = test_extras + 1 end
  end
  check("the extras include the open test projects that are not in the setlist (Delta, Alpha)", test_extras == 2, test_extras)

  local note
  for _, e in ipairs(State.list) do if e.name == "Note" then note = e end end
  -- remove Delta and the note, keep Alpha
  local remove = { [delta] = true }
  if note then remove[note] = true end
  local function closes(plan, proj)
    for _, tab in ipairs(plan.to_close) do if tab.proj == proj then return true end end
    return false
  end
  local plan = Sync.plan_load(loaded, tabs, State.list, remove, reaper.file_exists, Sync.is_empty_unsaved)
  check("the plan: Echo and Foxtrot are opened, Ghost is missing, Delta is closed",
    #plan.to_open == 2 and plan.to_open[1].name == "Echo" and plan.to_open[2].name == "Foxtrot"
    and #plan.missing == 1 and plan.missing[1].name == "Ghost"
    and closes(plan, delta) and closes(plan, blank))

  Actions.start_load(plan, "Scenario")
  local steps = 0
  while State.job and steps < 20 do
    Actions.step_job()
    steps = steps + 1
  end
  refresh()
  check("the load finishes", State.job == nil)
  check("the list: the kept Alpha first, then the setlist (Alpha,Charlie,Echo,Foxtrot)",
    names(State.list) == "Alpha,Charlie,Echo,Foxtrot", names(State.list))
  check("... the loaded text entry is there, the removed note is not",
    has(State.list, "text", "Loaded text") and not has(State.list, "text", "Note"))
  check("... Ghost is a missing entry", has(State.list, "missing", "Ghost"))
  check("... Delta's tab is closed, Echo is open", not is_open(delta))
  check("... the blank tab was closed without asking", not is_open(blank))
  local echo_open = false
  for _, p in ipairs(Sync.open_projects()) do if p.path == project_path("Echo") then echo_open = true end end
  check("... Echo's tab is open", echo_open)
  check("... the tabs are in the order of the list", Sync.is_synced(State.list, Sync.project_pointers()))
  check("... the title is the setlist's name and not modified", State.name == "Scenario" and State.modified == false)
  Actions.insert_text("After load")
  check("... a change afterwards marks it modified", State.modified == true)

  -- 4. reset ----------------------------------------------------------------------------------------------------
  Actions.reset()
  check("reset: the list is the open projects again", Sync.is_synced(State.list, Sync.project_pointers()) and not has(State.list, "text", "Loaded text"))
  check("... the name is gone", State.name == nil and State.modified == false)
end

local ok, err = pcall(scenarios)
if not ok then check("the scenarios ran without an error", false, tostring(err)) end

-- Clean up: close what this script opened, delete the files, restore the state --------------------------------------
for _, proj in ipairs(opened) do close(proj) end
-- (projects loaded by the Setlist code are not in `opened`)
local idx = 0
while true do
  local proj, path = reaper.EnumProjects(idx)
  if not proj then break end
  if path ~= "" and path:find(folder, 1, true) then
    close(proj)
    idx = 0
  else
    idx = idx + 1
  end
end
for _, path in ipairs(created) do os.remove(path) end
-- the projects that were open before, in the order they had
local target = 0
for _, proj in ipairs(original_tabs) do
  if reaper.ValidatePtr(proj, "ReaProject*") then
    Sync.move_tab(proj, target, Sync.open_count())
    target = target + 1
  end
end
if reaper.ValidatePtr(original_active, "ReaProject*") then reaper.SelectProjectInstance(original_active) end
reaper.SetExtState(Data.EXT_SECTION, "TestMode", "", false)
reaper.DeleteExtState(Data.EXT_SECTION, "TestMode", false)

report("SiSt-Live Setlist scenarios")
reaper.defer(function() end) -- no undo point
