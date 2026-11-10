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
-- Native command IDs never change, so they are constants and trusted (names sometimes change).
-- Screenset.check_actions() checks all of them, in one line, for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Actions = require("Actions")

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

--- Live check: one line for all window set actions. Fails for a missing action. Runs nothing.
function Screenset.check_actions()
  local list = {}
  for slot = 1, Screenset.SLOTS do
    list[#list + 1] = { cmd = Screenset.command(slot), what = ("load window set #%02d"):format(slot) }
  end
  return Actions.check_native("window sets", list)
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
function Screenset.get_assignment(mode)
  return tonumber(reaper.GetExtState(Screenset.SECTION, Screenset.KEY_PREFIX .. mode))
end

--- slot: number, or nil/false for none.
function Screenset.set_assignment(mode, slot)
  reaper.SetExtState(Screenset.SECTION, Screenset.KEY_PREFIX .. mode, slot and tostring(slot) or "", true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Screenset.apply(mode)
  local slot = Screenset.get_assignment(mode)
  if not slot then
    return "skipped", ("no screenset assigned to %s mode"):format(mode)
  end

  local cmd = Screenset.command(slot)
  if not cmd then error(("screenset #%d does not exist"):format(slot), 0) end

  reaper.Main_OnCommand(cmd, 0)
  return "ok", ("loaded screenset #%02d"):format(slot)
end

-- Settings --------------------------------------------------------------
-- Field text: screenset number 1-10, empty = none.
Screenset.settings = {
  {
    label  = "screenset",
    get    = function(mode) return Screenset.get_assignment(mode) end,
    format = function(slot) return slot and tostring(slot) or "" end,
    parse  = function(text)
      local slot, err = Screenset.parse_slot(text)
      if slot == nil then return false, "screenset: " .. err end
      return true, slot or nil
    end,
    set    = function(mode, slot) Screenset.set_assignment(mode, slot) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Screenset.diagnostics()
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local slot = Screenset.get_assignment(mode)
    rows[#rows + 1] = { mode .. " screenset", slot and ("#%02d"):format(slot) or "(none)" }
  end
  return rows
end

--- Built-in self-test. Uses fake REAPER functions: never loads a screenset or changes an assignment.
function Screenset.self_test()
  local with_reaper = require("SelfTest").with_reaper
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function fake(first_cmd)
    local runs, names = {}, {}
    for i = 1, 10 do names[first_cmd + i - 1] = ("Screenset: Load window set #%02d"):format(i) end
    local fakes = {
      kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
      Main_OnCommand = function(cmd) runs[#runs + 1] = cmd end,
    }
    return fakes, runs
  end

  check("command ids: no slot 0, 11 or 1.5",
    Screenset.command(0) == nil and Screenset.command(11) == nil and Screenset.command(1.5) == nil)

  check("parse: not a number", select(2, Screenset.parse_slot("abc")) ~= nil)
  local _, err = Screenset.parse_slot("11")
  check("parse: slot out of range names the range", err and err:find("1-10", 1, true) ~= nil)

  local fakes, runs = fake(Screenset.FIRST_LOAD_CMD)
  check("apply: nothing assigned -> skipped", (with_reaper(fakes, Screenset.apply, "show")) == "skipped" and #runs == 0)
  with_reaper(fakes, Screenset.set_assignment, "show", 2)
  with_reaper(fakes, Screenset.apply, "show")
  with_reaper(fakes, Screenset.apply, "show")
  check("apply: loads again on every run (not idempotent by design)", #runs == 2)

  local missing = fake(50000) -- REAPER has no actions at the expected IDs
  local renamed, renamed_runs = fake(Screenset.FIRST_LOAD_CMD)
  local real_name = renamed.kbd_getTextFromCmd
  renamed.kbd_getTextFromCmd = function(cmd) return real_name(cmd) ~= "" and "Window sets: Restore set (renamed)" or "" end
  with_reaper(renamed, Screenset.set_assignment, "show", 2)
  check("apply: a renamed action still runs (the ID is trusted)",
    (with_reaper(renamed, Screenset.apply, "show")) == "ok" and renamed_runs[1] == 40455)

  local rows = with_reaper(fake(Screenset.FIRST_LOAD_CMD), Screenset.check_actions)
  check("live check: one line for the 10 actions, passes when every action exists",
    #rows == 1 and rows[1].ok and rows[1].name == "window sets: 10 actions exist")
  local bad = with_reaper(missing, Screenset.check_actions)
  check("live check fails for missing actions and counts them", #bad == 1 and not bad[1].ok
    and bad[1].name:find("10 of 10 actions MISSING", 1, true) ~= nil)

  return results
end

return Screenset
