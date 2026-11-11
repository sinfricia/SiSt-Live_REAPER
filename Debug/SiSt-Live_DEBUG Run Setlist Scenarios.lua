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

  -- 5. linked text entries move with their project ------------------------------------------------------------------
  local function idx_of(name)
    for i, e in ipairs(State.list) do if e.name == name then return i end end
  end
  local ia, ie = idx_of("Alpha"), idx_of("Echo")
  if ia and ie then
    table.insert(State.list, ia + 1, { type = Data.ENTRY.TEXT, name = "Alpha note", path = "Alpha note", link = "above" })
    Actions.commit()
    check("a text entry linked above Alpha: Alpha's block has two entries", select(2, Data.link_block(State.list, ia)) == ia + 1)
    ie = idx_of("Echo")
    Actions.drop_entry(ia, ie, ia < ie and 1 or -1, false)
    refresh()
    local a, n, e = idx_of("Alpha"), idx_of("Alpha note"), idx_of("Echo")
    check("dragging Alpha onto Echo: the note comes along, right after it", a and n == a + 1, names(State.list))
    check("... Alpha is now on the other side of Echo", (ia < ie) == (a > e), names(State.list))
    check("... and the tabs are in the new order", Sync.is_synced(State.list, Sync.project_pointers()))
    local note = State.list[n]
    local target = idx_of("Charlie")
    Actions.drop_entry(n, target, n < target and 1 or -1, false)
    check("dragging the note alone: it moves and loses its link", note.link == nil and idx_of("Alpha note") ~= idx_of("Alpha") + 1,
      names(State.list))
    local ic = idx_of("Charlie")
    Actions.drop_entry(idx_of("Alpha note"), ic, -1, false, true)
    check("dropped with Shift on the top half of Charlie: right above it, linked to it",
      State.list[idx_of("Alpha note")].link == "below" and idx_of("Alpha note") == idx_of("Charlie") - 1, names(State.list))
    -- several selected entries move together; a selected project takes its linked text entry along
    local note_idx = idx_of("Alpha note")
    local group = { State.list[idx_of("Alpha")], State.list[idx_of("Charlie")] }
    local echo_idx = idx_of("Echo")
    local alpha_first = idx_of("Alpha") < idx_of("Charlie")
    Actions.drop_selection(group, echo_idx, 1, false)
    refresh()
    check("two selected projects dropped after Echo: both are behind it, in their old order",
      idx_of("Alpha") > idx_of("Echo") and idx_of("Charlie") > idx_of("Echo")
      and (idx_of("Alpha") < idx_of("Charlie")) == alpha_first, names(State.list))
    check("... Charlie's linked note moved with it", idx_of("Alpha note") == idx_of("Charlie") - 1, names(State.list))
    check("... and the tabs are in the new order", Sync.is_synced(State.list, Sync.project_pointers()))
    local before_names = names(State.list)
    Actions.drop_selection({ State.list[idx_of("Echo")], State.list[idx_of("Alpha")] }, idx_of("Alpha"), 1, false)
    check("dropped on one of the moving entries: nothing happens", names(State.list) == before_names, names(State.list))
    local ib = idx_of("Charlie")
    Actions.drop_entry(ib, ib, 1, false)
    check("dropping an entry on itself changes nothing", idx_of("Charlie") == ib)
  else
    check("(scenario 5 needs Alpha and Echo in the list)", false, names(State.list))
  end

  -- 6. several selected projects, many selections and drop spots, with and without the active project among them,
  -- against a plain model of where they have to end up ----------------------------------------------------------------
  do
    local drop = {}
    for _, e in ipairs(State.list) do
      if e.type ~= Data.ENTRY.PROJECT then drop[#drop + 1] = e end
    end
    Actions.delete_entries(drop)
    State.list = State.read_open_projects()
    Actions.commit()
    refresh()
    local n = #State.list
    local failures, cases, moved_active = {}, 0, 0
    local selections = { { 1 }, { n }, { 1, n }, { 2, 3 }, { 2, 4 }, { 1, 3, 5 }, { n - 1, n }, { 1, 2, 3 } }
    for _, positions in ipairs(selections) do
      for _, active_mode in ipairs({ "selected", "other" }) do
        for ref_pos = 1, n do
          for _, dir in ipairs({ -1, 1 }) do
            local list = State.list
            local sel, selset, ok_sel = {}, {}, true
            for _, p in ipairs(positions) do
              if list[p] and not selset[list[p]] then sel[#sel + 1] = list[p]; selset[list[p]] = true end
            end
            if #sel == 0 or #sel >= n or selset[list[ref_pos]] then ok_sel = false end
            if ok_sel then
              -- the active project: one of the selected ones, or one that is not selected (not the drop target if possible)
              local active
              for _, e in ipairs(list) do
                if (active_mode == "selected") == (selset[e] == true) then active = e break end
              end
              if active then reaper.SelectProjectInstance(active.proj) end
              refresh()

              local rest, moved, at = {}, {}, nil
              for _, e in ipairs(list) do
                if selset[e] then moved[#moved + 1] = e else rest[#rest + 1] = e end
              end
              for i, e in ipairs(rest) do if e == list[ref_pos] then at = i end end
              local pos = dir == 1 and at + 1 or at
              local expected = {}
              for i = 1, pos - 1 do expected[#expected + 1] = rest[i] end
              for _, m in ipairs(moved) do expected[#expected + 1] = m end
              for i = pos, #rest do expected[#expected + 1] = rest[i] end

              local before = {}
              for _, e in ipairs(list) do before[#before + 1] = e.name end
              local active_before = reaper.EnumProjects(-1)
              Actions.drop_selection(sel, ref_pos, dir, false)
              local active_after = reaper.EnumProjects(-1)
              if active_before ~= active_after then moved_active = moved_active + 1 end
              refresh()
              cases = cases + 1
              local same = #State.list == #expected
              for i, e in ipairs(expected) do if State.list[i] ~= e then same = false end end
              local synced = Sync.is_synced(State.list, Sync.project_pointers())
              if not (same and synced) then
                local got = {}
                for _, e in ipairs(State.list) do got[#got + 1] = e.name end
                failures[#failures + 1] = string.format("sel {%s} active=%s drop %s %d: %s | before %s | got %s",
                  table.concat(positions, ","), active_mode, dir == 1 and "after" or "before", ref_pos,
                  same and "tabs differ from list" or "wrong order", table.concat(before, ","), table.concat(got, ","))
              end
            end
          end
        end
      end
    end
    check("group drops: " .. cases .. " cases, all in the expected order and with the tabs in the list's order",
      #failures == 0 and cases > 0, table.concat(failures, "\n      ", 1, math.min(#failures, 4)))
    check("... and the active tab stays the active tab (" .. moved_active .. " of " .. cases .. " cases changed it)",
      moved_active == 0)
  end

  -- 7. the same with text entries linked to the projects: random selections of projects and text entries ----------------
  do
    local ENTRY = Data.ENTRY
    local base = State.read_open_projects()
    local list = {}
    for i, p in ipairs(base) do
      if i % 3 == 0 then list[#list + 1] = { type = ENTRY.TEXT, name = "B" .. i, path = "B" .. i, link = "below" } end
      list[#list + 1] = p
      if i % 2 == 1 then list[#list + 1] = { type = ENTRY.TEXT, name = "A" .. i, path = "A" .. i, link = "above" } end
      if i == 2 then list[#list + 1] = { type = ENTRY.TEXT, name = "F", path = "F" } end
    end
    State.list = list
    Actions.commit()
    refresh()

    local seed = 12345
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end

    local function attachments() -- project entry -> set of the text entries linked to it
      local out = {}
      for i, e in ipairs(State.list) do
        if e.type == ENTRY.PROJECT then
          local set = {}
          local first, last = Data.link_block(State.list, i)
          for k = first, last do if k ~= i then set[State.list[k]] = true end end
          out[e] = set
        end
      end
      return out
    end

    local failures, cases = {}, 0
    for _ = 1, 150 do
      local cur = State.list
      local sel, selset = {}, {}
      for _, e in ipairs(cur) do
        if rnd() < 0.35 then sel[#sel + 1] = e; selset[e] = true end
      end
      local ref_pos = math.floor(rnd() * #cur) + 1
      local dir = rnd() < 0.5 and -1 or 1
      if #sel > 0 and #sel < #cur and not selset[cur[ref_pos]] then
        local before_att = attachments()
        -- what moves: the selected entries and the text entries linked to a selected project
        local moving, expected_att = {}, {}
        for i, e in ipairs(cur) do
          if selset[e] then
            moving[e] = true
            if e.type == ENTRY.PROJECT then
              local first, last = Data.link_block(cur, i)
              for k = first, last do moving[cur[k]] = true end
            end
          end
        end
        for p, set in pairs(before_att) do
          expected_att[p] = {}
          for t in pairs(set) do
            if not (selset[t] and not selset[p]) then expected_att[p][t] = true end -- (a selected text leaves a project that stays)
          end
        end
        local rest_before = {}
        for _, e in ipairs(cur) do if not moving[e] then rest_before[#rest_before + 1] = e end end
        local count_before = #cur

        Actions.drop_selection(sel, ref_pos, dir, false)
        refresh()
        cases = cases + 1

        local problems = {}
        if #State.list ~= count_before then problems[#problems + 1] = "entries lost or added" end
        if not Sync.is_synced(State.list, Sync.project_pointers()) then problems[#problems + 1] = "tabs differ from the list" end
        local rest_after = {}
        for _, e in ipairs(State.list) do if not moving[e] then rest_after[#rest_after + 1] = e end end
        for i, e in ipairs(rest_before) do
          if rest_after[i] ~= e then problems[#problems + 1] = "the entries that stay changed their order" break end
        end
        local after_att = attachments()
        for p, set in pairs(expected_att) do
          for t in pairs(set) do
            if not (after_att[p] and after_att[p][t]) then problems[#problems + 1] = "'" .. t.name .. "' lost its project " .. p.name end
          end
          for t in pairs(after_att[p] or {}) do
            if not set[t] then problems[#problems + 1] = "'" .. t.name .. "' joined " .. p.name .. " without being linked" end
          end
        end
        for i, e in ipairs(State.list) do
          if e.type == ENTRY.TEXT and e.link and not Data.block_of(State.list, i) then
            problems[#problems + 1] = "'" .. e.name .. "' has a link that reaches no project"
          end
        end
        if #problems > 0 then
          local names_sel = {}
          for _, e in ipairs(sel) do names_sel[#names_sel + 1] = e.name end
          failures[#failures + 1] = string.format("select {%s} drop %s '%s': %s", table.concat(names_sel, ","),
            dir == 1 and "after" or "before", cur[ref_pos] and cur[ref_pos].name or "?", table.concat(problems, "; "))
        end
      end
    end
    check("group drops with linked text entries: " .. cases .. " random cases keep every link and the tab order",
      #failures == 0 and cases > 0, table.concat(failures, "\n      ", 1, math.min(#failures, 4)))
  end

  -- 8. text entries only: linked with Shift, joining a block, copied ----------------------------------------------------
  do
    local ENTRY = Data.ENTRY
    State.list = State.read_open_projects()
    local first_proj = State.list[1]
    local x1 = { type = ENTRY.TEXT, name = "X1", path = "X1" }
    local x2 = { type = ENTRY.TEXT, name = "X2", path = "X2" }
    local a1 = { type = ENTRY.TEXT, name = "N1", path = "N1", link = "above" }
    local a2 = { type = ENTRY.TEXT, name = "N2", path = "N2", link = "above" }
    table.insert(State.list, 2, a1)
    table.insert(State.list, 3, a2)
    State.list[#State.list + 1] = x1
    State.list[#State.list + 1] = x2
    Actions.commit()
    local function pos(e) for i, v in ipairs(State.list) do if v == e then return i end end end

    -- Shift: both go right below the project in the last row (the drop is below it), linked to it
    local last_proj_idx
    for i, e in ipairs(State.list) do if e.type == ENTRY.PROJECT then last_proj_idx = i end end
    local last_proj = State.list[last_proj_idx]
    Actions.drop_selection({ x1, x2 }, last_proj_idx, 1, false, true, last_proj_idx)
    check("two text entries dropped with Shift below a project: right below it, both linked to it",
      pos(x1) == pos(last_proj) + 1 and pos(x2) == pos(last_proj) + 2 and x1.link == "above" and x2.link == "above",
      tostring(pos(x1)) .. "," .. tostring(pos(x2)) .. " links " .. tostring(x1.link) .. "," .. tostring(x2.link))

    -- no Shift, dropped between the two entries of the first project's block: they join it
    local y1 = { type = ENTRY.TEXT, name = "Y1", path = "Y1" }
    local y2 = { type = ENTRY.TEXT, name = "Y2", path = "Y2" }
    State.list[#State.list + 1] = y1
    State.list[#State.list + 1] = y2
    Actions.commit()
    Actions.drop_selection({ y1, y2 }, pos(a1), 1, false, false, pos(a1))
    check("two text entries dropped between the entries of a block join it",
      y1.link == "above" and y2.link == "above" and pos(y1) == pos(a1) + 1 and pos(y2) == pos(a1) + 2,
      tostring(y1.link) .. "," .. tostring(y2.link))
    local first_idx = pos(first_proj)
    local f, l = Data.link_block(State.list, first_idx)
    check("... and the block of the project has them", l - f + 1 == 5, "block " .. f .. "-" .. l)

    -- Ctrl+Shift: copies, linked
    local z = { type = ENTRY.TEXT, name = "Z", path = "Z" }
    State.list[#State.list + 1] = z
    Actions.commit()
    local before = #State.list
    local lp = pos(last_proj)
    Actions.drop_selection({ z }, lp, -1, true, true, lp)
    local copy
    for _, e in ipairs(State.list) do if e.name == "Z" and e ~= z then copy = e end end
    check("a copy dropped with Shift above a project: the original stays, the copy is linked to the project",
      #State.list == before + 1 and copy and copy.link == "below" and pos(copy) == pos(last_proj) - 1,
      copy and tostring(copy.link) or "no copy")
  end
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
