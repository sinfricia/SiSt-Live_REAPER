-- @noindex
-- SiSt-Live mode effect: loads a REAPER screenset (window set) per mode.
--
-- Unlike the other effects this one is NOT idempotent: REAPER can't tell which screenset is
-- loaded, so the assigned one is loaded on every run, also by "Apply current mode". Loading a
-- window set reopens and moves windows and dockers. It runs after the theme and before the layout
-- effect (see ModeEffects.MODULES): if a window set changes layouts, the layout effect corrects them.
--
-- The screenset itself is saved in REAPER as usual (Screensets window, or the
-- "Screenset: Save window set #NN" actions). This effect only stores WHICH slot belongs to a mode:
-- enter the number in "SiSt-Live: Configure modes".
--
-- Native command IDs never change, so they are constants and trusted (names sometimes change). Before
-- running one, the effect only checks that it exists. Screenset.check_actions() lists all of them with
-- their current names for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Actions = require("SiSt-Live_Actions")

local Screenset = { name = "screenset" }

Screenset.SECTION    = "SiSt-Live"
Screenset.KEY_PREFIX = "screenset_" -- + mode, e.g. "screenset_show". Value: slot number, "" = none

-- "Screenset: Load window set #01" ... "#10"
Screenset.FIRST_LOAD_CMD = 40454
Screenset.SLOTS          = 10

-- Actions ---------------------------------------------------------------
--- Command ID of the load action for a slot, or nil if there is no such slot.
function Screenset.command(slot)
  if type(slot) ~= "number" or slot < 1 or slot > Screenset.SLOTS or slot ~= math.floor(slot) then return nil end
  return Screenset.FIRST_LOAD_CMD + slot - 1
end

--- Live check: every command ID with its current name. Fails only for a missing action. Runs nothing.
function Screenset.check_actions(api)
  local list = {}
  for slot = 1, Screenset.SLOTS do
    list[#list + 1] = { cmd = Screenset.command(slot), what = ("load window set #%02d"):format(slot) }
  end
  return Actions.check_native(list, api)
end

--- Pure. Parses the number typed into the settings dialog.
--- Returns slot (number), or false for "none" (empty input), or nil + error message.
function Screenset.parse_slot(input)
  input = (input or ""):match("^%s*(.-)%s*$")
  if input == "" then return false end
  local n = tonumber(input)
  if not n then return nil, ("'%s' is not a number"):format(input) end
  if not Screenset.command(n) then
    return nil, ("there is no screenset #%s (available: 1-%d)"):format(input, Screenset.SLOTS)
  end
  return n
end

-- Assignments -----------------------------------------------------------
--- Assigned slot number, or nil.
function Screenset.get_assignment(mode, api)
  api = api or reaper
  return tonumber(api.GetExtState(Screenset.SECTION, Screenset.KEY_PREFIX .. mode))
end

--- slot: number, or nil/false for none.
function Screenset.set_assignment(mode, slot, api)
  api = api or reaper
  api.SetExtState(Screenset.SECTION, Screenset.KEY_PREFIX .. mode, slot and tostring(slot) or "", true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Screenset.apply(mode, api)
  local slot = Screenset.get_assignment(mode, api)
  if not slot then
    return "skipped", ("no screenset assigned to %s mode"):format(mode)
  end

  local cmd = Screenset.command(slot)
  if not cmd then error(("screenset #%d does not exist"):format(slot), 0) end

  Actions.require_native(cmd, api, ("load window set #%02d"):format(slot))

  api.Main_OnCommand(cmd, 0)
  return "ok", ("loaded screenset #%02d"):format(slot)
end

-- Settings --------------------------------------------------------------
-- Field text: screenset number 1-10, empty = none.
Screenset.settings = {
  {
    label  = "screenset",
    get    = function(mode, api) return Screenset.get_assignment(mode, api) end,
    format = function(slot) return slot and tostring(slot) or "" end,
    parse  = function(text)
      local slot, err = Screenset.parse_slot(text)
      if slot == nil then return false, "screenset: " .. err end
      return true, slot or nil
    end,
    set    = function(mode, slot, api) Screenset.set_assignment(mode, slot, api) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Screenset.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local slot = Screenset.get_assignment(mode, api)
    rows[#rows + 1] = { mode .. " screenset", slot and ("#%02d"):format(slot) or "(none)" }
  end
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never loads a screenset or changes an assignment.
function Screenset.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function fake(first_cmd)
    local ext, runs, names = {}, {}, {}
    for i = 1, 10 do names[first_cmd + i - 1] = ("Screenset: Load window set #%02d"):format(i) end
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
      Main_OnCommand = function(cmd) runs[#runs + 1] = cmd end,
    }
    return api, runs
  end

  check("command ids: #1 and #10", Screenset.command(1) == 40454 and Screenset.command(10) == 40463)
  check("command ids: no slot 0, 11 or 1.5",
    Screenset.command(0) == nil and Screenset.command(11) == nil and Screenset.command(1.5) == nil)

  check("parse: number", Screenset.parse_slot(" 3 ") == 3)
  check("parse: empty = none", Screenset.parse_slot("") == false)
  check("parse: not a number", select(2, Screenset.parse_slot("abc")) ~= nil)
  local _, err = Screenset.parse_slot("11")
  check("parse: slot out of range names the range", err and err:find("1-10", 1, true) ~= nil)

  local api, runs = fake(Screenset.FIRST_LOAD_CMD)
  check("apply: nothing assigned -> skipped", (Screenset.apply("show", api)) == "skipped" and #runs == 0)
  Screenset.set_assignment("show", 2, api)
  local result = Screenset.apply("show", api)
  check("apply: runs the load action of the slot", result == "ok" and runs[1] == 40455)
  Screenset.apply("show", api)
  check("apply: loads again on every run (not idempotent by design)", #runs == 2)
  Screenset.set_assignment("show", false, api)
  check("assignment can be cleared", Screenset.get_assignment("show", api) == nil)

  local missing, missing_runs = fake(50000) -- REAPER has no actions at the expected IDs
  Screenset.set_assignment("show", 2, missing)
  local ok, e = pcall(Screenset.apply, "show", missing)
  check("apply: missing action fails, runs nothing",
    not ok and #missing_runs == 0 and tostring(e):find("40455", 1, true) ~= nil)
  local renamed, renamed_runs = fake(Screenset.FIRST_LOAD_CMD)
  local real_name = renamed.kbd_getTextFromCmd
  renamed.kbd_getTextFromCmd = function(cmd) return real_name(cmd) ~= "" and "Window sets: Restore set (renamed)" or "" end
  Screenset.set_assignment("show", 2, renamed)
  check("apply: a renamed action still runs (the ID is trusted)",
    (Screenset.apply("show", renamed)) == "ok" and renamed_runs[1] == 40455)

  local all_ok = true
  for _, r in ipairs(Screenset.check_actions(fake(Screenset.FIRST_LOAD_CMD))) do all_ok = all_ok and r.ok end
  check("live check passes when every action exists", all_ok)
  check("live check fails for missing actions", not Screenset.check_actions(missing)[1].ok)


  local ss = Screenset.settings[1]
  check("setting: parse / format", select(2, ss.parse("4")) == 4 and ss.format(4) == "4"
    and select(2, ss.parse("")) == nil and ss.format(nil) == "" and not ss.parse("11"))

  return results
end

return Screenset
