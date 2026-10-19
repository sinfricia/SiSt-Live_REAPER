-- @noindex
-- SiSt-Live mode effect: switches the keyboard shortcut section of the main window
-- (plain "Main", or one of the alternate sections alt-1 ... alt-16).
--
-- REAPER actions used (native command IDs never change, so they are constants):
--   Main:      "Main action section: Clear any override"      (24800)
--   alt-N:     "Main action section: Toggle override to <name>" (24802 + N, alt-1 = 24803)
-- The command IDs are trusted (IDs don't change, names sometimes do; the alt actions even carry the
-- section's name, which you can rename). Before running, the effect only checks that the action exists.
--
-- The alt actions TOGGLE: running one while it's active would switch the override off again. So the
-- effect reads REAPER's toggle state first and only runs the action when it is off. If REAPER doesn't
-- report a state, it fails instead of guessing.
--
-- Set in "SiSt-Live: Configure modes": "main" or the alt number, e.g. 1 for alt-1.
--
-- KeySection.check_actions() lists all IDs with their current names for "DEBUG Run Self-Test".
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.



local Actions = require("SiSt-Live_Actions")

local KeySection = { name = "keyboard" }

KeySection.SECTION    = "SiSt-Live"
KeySection.KEY_PREFIX = "keysection_" -- + mode. Value: 0 = Main, 1..16 = alt-N, "" = none

KeySection.MAIN          = 0
KeySection.ALT_COUNT     = 16
KeySection.CMD_MAIN      = 24800 -- Main action section: Clear any override
KeySection.CMD_ALT_BASE  = 24802 -- + N: Main action section: Toggle override to alt-N (24802 itself = recording)

-- Actions ---------------------------------------------------------------
--- Command ID for a section number (0 = Main), or nil.
function KeySection.command(n)
  if n == KeySection.MAIN then return KeySection.CMD_MAIN end
  if type(n) ~= "number" or n < 1 or n > KeySection.ALT_COUNT or n ~= math.floor(n) then return nil end
  return KeySection.CMD_ALT_BASE + n
end

function KeySection.label(n)
  if n == KeySection.MAIN then return "Main" end
  return ("alt-%d"):format(n)
end

--- Live check: every command ID with its current name. Fails only for a missing action. Runs nothing.
function KeySection.check_actions(api)
  local list = {}
  for n = 0, KeySection.ALT_COUNT do
    list[#list + 1] = { cmd = KeySection.command(n), what = "keyboard " .. KeySection.label(n) }
  end
  return Actions.check_native(list, api)
end

--- Pure. Parses the text typed into the settings dialog: "main" / "default" / "0" -> 0,
--- "1" / "alt1" / "alt-1" -> 1. Returns the number, false for empty (= none), or nil + error.
function KeySection.parse(input)
  local s = (input or ""):lower():match("^%s*(.-)%s*$")
  if s == "" then return false end
  local n
  if s == "main" or s == "default" then
    n = KeySection.MAIN
  else
    n = tonumber(s:match("^alt%s*%-?%s*(%d+)$") or s:match("^(%d+)$"))
  end
  if not n or not KeySection.command(n) then
    return nil, ("'%s' is not 'main' or an alt number 1-%d"):format(input, KeySection.ALT_COUNT)
  end
  return n
end

-- Assignments -----------------------------------------------------------
function KeySection.get_assignment(mode, api)
  api = api or reaper
  return tonumber(api.GetExtState(KeySection.SECTION, KeySection.KEY_PREFIX .. mode))
end

function KeySection.set_assignment(mode, n, api)
  api = api or reaper
  api.SetExtState(KeySection.SECTION, KeySection.KEY_PREFIX .. mode, n and tostring(n) or "", true) -- persistent
end

--- The active section according to REAPER's toggle states, or nil.
function KeySection.active(api)
  for n = 0, KeySection.ALT_COUNT do
    if api.GetToggleCommandState(KeySection.command(n)) == 1 then return n end
  end
  return nil
end

-- Effect ----------------------------------------------------------------
function KeySection.apply(mode, api)
  local n = KeySection.get_assignment(mode, api)
  if not n then
    return "skipped", ("no keyboard section assigned to %s mode"):format(mode)
  end

  local cmd = KeySection.command(n)
  if not cmd then error(("keyboard section %s does not exist"):format(tostring(n)), 0) end

  local name = Actions.require_native(cmd, api, "keyboard " .. KeySection.label(n))

  local state = api.GetToggleCommandState(cmd)
  if state == 1 then return "skipped", "already active: " .. KeySection.label(n) end
  if state ~= 0 then
    -- the alt actions toggle: without a known state, running one might switch the section off
    error(("REAPER doesn't report the state of '%s', not switching blindly"):format(name), 0)
  end

  api.Main_OnCommand(cmd, 0)
  return "ok", "switched to " .. KeySection.label(n)
end

-- Settings --------------------------------------------------------------
-- Field text: "main" or an alt number (1 = alt-1), empty = leave alone.
KeySection.settings = {
  {
    label  = "keyboard",
    get    = function(mode, api) return KeySection.get_assignment(mode, api) end,
    format = function(n) return n == nil and "" or (n == KeySection.MAIN and "main" or tostring(n)) end,
    parse  = function(text)
      local n, err = KeySection.parse(text)
      if n == nil then return false, "keyboard: " .. err end
      return true, n or nil
    end,
    set    = function(mode, n, api) KeySection.set_assignment(mode, n, api) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function KeySection.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local n = KeySection.get_assignment(mode, api)
    rows[#rows + 1] = { mode .. " keyboard", n and KeySection.label(n) or "(none)" }
  end
  local active = KeySection.active(api)
  rows[#rows + 1] = { "active section", active and KeySection.label(active) or "(not reported by REAPER)" }
  return rows
end

--- Built-in self-test. Uses a fake REAPER API: never switches the real keyboard section.
function KeySection.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  -- fake with the real IDs; alt-1 renamed "SHOW" like in a real setup
  local function fake(opts)
    opts = opts or {}
    local names, ext, runs = {}, {}, {}
    local override = nil -- nil = Main
    names[24800] = "Main action section: Clear any override"
    names[24802] = "Main action section: Toggle override to recording"
    names[24803] = "Main action section: Toggle override to SHOW"
    for i = 2, 16 do names[24802 + i] = ("Main action section: Toggle override to alt-%d"):format(i) end
    if opts.names then for k, v in pairs(opts.names) do names[k] = v end end
    local api = {
      GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
      SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
      kbd_getTextFromCmd = function(cmd) return names[cmd] or "" end,
      GetToggleCommandState = function(cmd)
        if opts.no_state then return -1 end
        if cmd == 24800 then return override == nil and 1 or 0 end
        return cmd == override and 1 or 0
      end,
      Main_OnCommand = function(cmd)
        runs[#runs + 1] = cmd
        if cmd == 24800 then override = nil
        elseif cmd == override then override = nil -- toggles off
        else override = cmd end
      end,
    }
    return api, runs
  end

  check("command ids: Main, alt-1, alt-16",
    KeySection.command(0) == 24800 and KeySection.command(1) == 24803 and KeySection.command(16) == 24818)
  check("command ids: no alt-0 / alt-17", KeySection.command(17) == nil and KeySection.command(-1) == nil)

  check("parse: main / default", KeySection.parse("Main") == 0 and KeySection.parse(" default ") == 0)
  check("parse: 1 / alt1 / alt-1",
    KeySection.parse("1") == 1 and KeySection.parse("alt1") == 1 and KeySection.parse("ALT-1") == 1)
  check("parse: empty = none", KeySection.parse("") == false)
  check("parse: garbage and out of range rejected", KeySection.parse("foo") == nil and KeySection.parse("17") == nil)

  local api, runs = fake()
  check("apply: nothing assigned -> skipped", (KeySection.apply("show", api)) == "skipped" and #runs == 0)
  KeySection.set_assignment("show", 1, api)
  KeySection.set_assignment("edit", 0, api)
  check("apply: edit while Main is active -> skipped", (KeySection.apply("edit", api)) == "skipped" and #runs == 0)
  check("apply: switches to alt-1", (KeySection.apply("show", api)) == "ok" and runs[1] == 24803)
  check("apply: second run does NOT toggle it off again", (KeySection.apply("show", api)) == "skipped" and #runs == 1)
  check("apply: back to Main", (KeySection.apply("edit", api)) == "ok" and runs[2] == 24800)

  local blind, blind_runs = fake({ no_state = true })
  KeySection.set_assignment("show", 1, blind)
  check("apply: unknown toggle state fails, runs nothing", not pcall(KeySection.apply, "show", blind) and #blind_runs == 0)

  local renamed, renamed_runs = fake({ names = { [24803] = "Main action section: Toggle override to STAGE" } })
  KeySection.set_assignment("show", 1, renamed)
  check("apply: a renamed action still runs (the ID is trusted)",
    (KeySection.apply("show", renamed)) == "ok" and renamed_runs[1] == 24803)
  local missing, missing_runs = fake({ names = { [24803] = "" } })
  KeySection.set_assignment("show", 1, missing)
  check("apply: missing action fails, runs nothing", not pcall(KeySection.apply, "show", missing) and #missing_runs == 0)

  local all_ok = true
  for _, r in ipairs(KeySection.check_actions(fake())) do all_ok = all_ok and r.ok end
  check("live check passes when every action exists", all_ok and #KeySection.check_actions(fake()) == 17)
  check("live check fails for a missing action", not KeySection.check_actions(missing)[2].ok)


  local ks = KeySection.settings[1]
  check("setting: parse / format", select(2, ks.parse("main")) == 0 and select(2, ks.parse("1")) == 1
    and select(2, ks.parse("")) == nil and ks.format(0) == "main" and ks.format(1) == "1" and not ks.parse("17"))

  return results
end

return KeySection
