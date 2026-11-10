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
-- enter the number in "SiSt-Live: Configure modes". "SiSt-Live: Save current look for current mode"
-- saves the current windows into the mode's slot (Screenset.take_current); it needs a slot set first.
--
-- Native command IDs never change, so they are constants and trusted (names sometimes change).
-- Screenset.check_actions() checks all of them, in one line, for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Actions = require("Actions")

local Screenset = { name = "screenset" }

Screenset.SECTION    = "SiSt-Live"
Screenset.KEY_PREFIX = "screenset_" -- + mode, e.g. "screenset_show". Value: slot number, "" = none

-- "Screenset: Load window set #01" ... "#10", "Screenset: Save window set #01" ... "#10"
Screenset.FIRST_LOAD_CMD = 40454
Screenset.FIRST_SAVE_CMD = 40474
Screenset.SLOTS          = 10

-- Actions ---------------------------------------------------------------
--- Command ID of the load action for a slot, or nil if there is no such slot.
function Screenset.command(slot)
  if type(slot) ~= "number" or slot < 1 or slot > Screenset.SLOTS or slot ~= math.floor(slot) then return nil end
  return Screenset.FIRST_LOAD_CMD + slot - 1
end

--- Command ID of the save action for a slot, or nil if there is no such slot.
function Screenset.save_command(slot)
  local load = Screenset.command(slot)
  return load and (Screenset.FIRST_SAVE_CMD + slot - 1) or nil
end

--- Live check: one line for the load actions, one for the save actions. Fails for a missing action. Runs nothing.
function Screenset.check_actions()
  local load, save = {}, {}
  for slot = 1, Screenset.SLOTS do
    load[#load + 1] = { cmd = Screenset.command(slot), what = ("load window set #%02d"):format(slot) }
    save[#save + 1] = { cmd = Screenset.save_command(slot), what = ("save window set #%02d"):format(slot) }
  end
  local rows = Actions.check_native("window sets (load)", load)
  for _, row in ipairs(Actions.check_native("window sets (save)", save)) do rows[#rows + 1] = row end
  return rows
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

-- Take current ----------------------------------------------------------
--- "Save current look" (contract in SiSt-Live_ModeEffects.lua): saves the current windows and dockers into the
--- mode's slot. Without a slot nothing is saved: picking one here could overwrite a window set used elsewhere.
function Screenset.take_current(mode)
  local slot = Screenset.get_assignment(mode)
  if not slot then
    return nil, ("no slot set for %s mode: set one in Configure modes first"):format(mode:upper())
  end
  local cmd = Screenset.save_command(slot)
  if not cmd then error(("screenset #%d does not exist"):format(slot), 0) end
  return {
    text = ("screenset #%02d: overwritten with the current windows and dockers"):format(slot),
    save = function() reaper.Main_OnCommand(cmd, 0) end,
  }
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
    for i = 1, 10 do
      names[first_cmd + i - 1] = ("Screenset: Load window set #%02d"):format(i)
      names[first_cmd + 20 + i - 1] = ("Screenset: Save window set #%02d"):format(i)
    end
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
  check("live check: one line each for the 10 load and 10 save actions, passes when every action exists",
    #rows == 2 and rows[1].ok and rows[2].ok and rows[1].name == "window sets (load): 10 actions exist"
    and rows[2].name == "window sets (save): 10 actions exist")
  local bad = with_reaper(missing, Screenset.check_actions)
  check("live check fails for missing actions and counts them", #bad == 2 and not bad[1].ok
    and bad[1].name:find("10 of 10 actions MISSING", 1, true) ~= nil)

  -- take current
  check("save command ids: 40474 for #01, none for slot 11",
    Screenset.save_command(1) == 40474 and Screenset.save_command(10) == 40483 and Screenset.save_command(11) == nil)
  local tfakes, truns = fake(Screenset.FIRST_LOAD_CMD)
  local none, why = with_reaper(tfakes, Screenset.take_current, "show")
  check("take current: no slot set -> nothing to save, says where to set one",
    none == nil and tostring(why):find("Configure modes", 1, true) ~= nil and #truns == 0)
  with_reaper(tfakes, Screenset.set_assignment, "show", 3)
  local item = with_reaper(tfakes, Screenset.take_current, "show")
  local ran_before = #truns
  if item then with_reaper(tfakes, item.save) end
  check("take current: saves into the mode's slot only after confirming",
    item ~= nil and ran_before == 0 and #truns == 1 and truns[1] == 40476)

  return results
end

return Screenset
