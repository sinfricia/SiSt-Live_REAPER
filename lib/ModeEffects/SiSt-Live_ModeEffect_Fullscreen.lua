-- @noindex
-- SiSt-Live mode effect: turns REAPER's fullscreen on or off per mode.
--
-- Uses the native action "Toggle fullscreen" (fixed command ID). Because it toggles, the
-- effect reads REAPER's toggle state first and only runs it when the state differs. If REAPER
-- doesn't report a state, it fails instead of guessing.
--
-- Runs after the screenset effect (see ModeEffects.MODULES), so a window set can't undo it.
--
-- Set in "SiSt-Live: Configure modes": "on" or "off".
-- The command ID is trusted (IDs don't change, names sometimes do). Before running, the effect only checks
-- that the action exists. Fullscreen.check_actions() lists it for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Actions = require("SiSt-Live_Actions")

local Fullscreen = { name = "fullscreen" }

Fullscreen.SECTION    = "SiSt-Live"
Fullscreen.KEY_PREFIX = "fullscreen_" -- + mode. Value: "on", "off", "" = none

Fullscreen.CMD  = 40346
Fullscreen.WHAT = "Toggle fullscreen" -- what the action does (for messages; REAPER's name may differ)

-- Actions ---------------------------------------------------------------
function Fullscreen.check_actions(api)
  return Actions.check_native({ { cmd = Fullscreen.CMD, what = Fullscreen.WHAT } }, api)
end

--- Pure. "on" / "off" (also yes/no, 1/0, true/false) -> true / false; empty -> "none"; else nil + error.
function Fullscreen.parse(input)
  local s = (input or ""):lower():match("^%s*(.-)%s*$")
  if s == "" then return "none" end
  if s == "on" or s == "yes" or s == "1" or s == "true" then return true end
  if s == "off" or s == "no" or s == "0" or s == "false" then return false end
  return nil, ("'%s' is not 'on' or 'off'"):format(input)
end

-- Assignments -----------------------------------------------------------
--- true (on), false (off) or nil (none).
function Fullscreen.get_assignment(mode, api)
  api = api or reaper
  local v = api.GetExtState(Fullscreen.SECTION, Fullscreen.KEY_PREFIX .. mode)
  if v == "on" then return true end
  if v == "off" then return false end
  return nil
end

--- value: true, false, or nil for none.
function Fullscreen.set_assignment(mode, value, api)
  api = api or reaper
  local v = value == true and "on" or (value == false and "off" or "")
  api.SetExtState(Fullscreen.SECTION, Fullscreen.KEY_PREFIX .. mode, v, true) -- persistent
end

-- Effect ----------------------------------------------------------------
function Fullscreen.apply(mode, api)
  local want = Fullscreen.get_assignment(mode, api)
  if want == nil then
    return "skipped", ("no fullscreen setting for %s mode"):format(mode)
  end

  Actions.require_native(Fullscreen.CMD, api, Fullscreen.WHAT)

  local state = api.GetToggleCommandState(Fullscreen.CMD)
  if state ~= 0 and state ~= 1 then
    error("REAPER doesn't report the fullscreen state, not toggling blindly", 0)
  end

  local word = want and "on" or "off"
  if (state == 1) == want then return "skipped", "already " .. word end
  api.Main_OnCommand(Fullscreen.CMD, 0)
  return "ok", "fullscreen " .. word
end

-- Settings --------------------------------------------------------------
-- Field text: "on" or "off", empty = leave alone.
Fullscreen.settings = {
  {
    label  = "fullscreen",
    get    = function(mode, api) return Fullscreen.get_assignment(mode, api) end,
    format = function(v) return v == nil and "" or (v and "on" or "off") end,
    parse  = function(text)
      local v, err = Fullscreen.parse(text)
      if v == nil then return false, "fullscreen: " .. err end
      if v == "none" then return true, nil end
      return true, v
    end,
    set    = function(mode, v, api) Fullscreen.set_assignment(mode, v, api) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Fullscreen.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local v = Fullscreen.get_assignment(mode, api)
    rows[#rows + 1] = { mode .. " fullscreen", v == nil and "(none)" or (v and "on" or "off") }
  end
  local state = api.GetToggleCommandState(Fullscreen.CMD)
  rows[#rows + 1] = { "fullscreen now", state == 1 and "on" or (state == 0 and "off" or "(not reported)") }
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never toggles the real fullscreen.
function Fullscreen.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function fake(opts)
    opts = opts or {}
    local ext, runs, full = {}, {}, { on = false }
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      kbd_getTextFromCmd = function(cmd) return cmd == Fullscreen.CMD and (opts.name or Fullscreen.WHAT) or "" end,
      GetToggleCommandState = function() if opts.no_state then return -1 end return full.on and 1 or 0 end,
      Main_OnCommand = function(cmd) runs[#runs + 1] = cmd; full.on = not full.on end,
    }
    return api, runs
  end

  check("parse: on / off and friends", Fullscreen.parse(" ON ") == true and Fullscreen.parse("no") == false)
  check("parse: empty = none, garbage rejected", Fullscreen.parse("") == "none" and Fullscreen.parse("maybe") == nil)

  local api, runs = fake()
  check("apply: nothing assigned -> skipped", (Fullscreen.apply("show", api)) == "skipped" and #runs == 0)
  Fullscreen.set_assignment("show", true, api)
  Fullscreen.set_assignment("edit", false, api)
  check("apply: edit while not fullscreen -> skipped", (Fullscreen.apply("edit", api)) == "skipped" and #runs == 0)
  check("apply: show turns it on", (Fullscreen.apply("show", api)) == "ok" and #runs == 1)
  check("apply: second run does NOT toggle it off", (Fullscreen.apply("show", api)) == "skipped" and #runs == 1)
  check("apply: edit turns it off", (Fullscreen.apply("edit", api)) == "ok" and #runs == 2)
  Fullscreen.set_assignment("show", nil, api)
  check("assignment can be cleared", Fullscreen.get_assignment("show", api) == nil)

  local blind, blind_runs = fake({ no_state = true })
  Fullscreen.set_assignment("show", true, blind)
  check("apply: unknown state fails, runs nothing", not pcall(Fullscreen.apply, "show", blind) and #blind_runs == 0)
  local renamed, renamed_runs = fake({ name = "View: Toggle fullscreen mode" })
  Fullscreen.set_assignment("show", true, renamed)
  check("apply: a renamed action still runs (the ID is trusted)",
    (Fullscreen.apply("show", renamed)) == "ok" and #renamed_runs == 1)
  local missing, missing_runs = fake({ name = "" })
  Fullscreen.set_assignment("show", true, missing)
  check("apply: missing action fails, runs nothing", not pcall(Fullscreen.apply, "show", missing) and #missing_runs == 0)
  check("live check", Fullscreen.check_actions(fake())[1].ok and Fullscreen.check_actions(renamed)[1].ok
    and not Fullscreen.check_actions(missing)[1].ok)


  local fs = Fullscreen.settings[1]
  check("setting: parse / format", select(2, fs.parse("on")) == true and select(2, fs.parse("off")) == false
    and select(2, fs.parse("")) == nil and not fs.parse("x") and fs.format(true) == "on" and fs.format(nil) == "")

  return results
end

return Fullscreen
