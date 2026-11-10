-- @noindex
-- SiSt-Live toolbar button helper.
-- Lights or unlights the toolbar button of a SiSt-Live toggle action (edit/show mode, debug logging)
-- from ANY script, e.g. when the status display switches the mode.
--
-- The button belongs to the action of a script (e.g. "Modes/SiSt-Live_Toggle Edit-Show Mode.lua"). Its
-- command ID is looked up by the script's file (SiSt-Live_Actions.lua), so it works from the first
-- switch in every REAPER session: no script has to register anything first.
--
-- Calls the global `reaper` directly (never cached), so tests can swap in fakes.

local Actions = require("SiSt-Live_Actions")

local Button = {}

-- Button names -> script id in Actions.SCRIPTS
Button.SCRIPTS = { mode = "mode", debug = "debug" }

--- Light (true) or unlight (false) the button. Returns false (and the reason) if its action isn't found.
function Button.set_state(id, on)
  local cmd, err = Actions.script_command(Button.SCRIPTS[id] or id)
  if not cmd then return false, err end
  reaper.SetToggleCommandState(0, cmd, on and 1 or 0)
  reaper.RefreshToolbar2(0, cmd)
  return true
end

--- Which action the button belongs to, for diagnostics.
function Button.describe(id)
  local cmd, err = Actions.script_command(Button.SCRIPTS[id] or id)
  return cmd and ("action %d"):format(cmd) or err
end

--- Built-in self-test. Uses fake REAPER functions (SelfTest.with_reaper): never touches a real toolbar button.
function Button.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local states = {}
  local fakes = {
    GetResourcePath = function() return "R" end,
    file_exists = function() return false end, -- no script installed
    SetToggleCommandState = function(section, cmd, v) states[#states + 1] = v end,
    RefreshToolbar2 = function() end,
  }
  local ok, why = require("SelfTest").with_reaper(fakes, function() return Button.set_state("debug", true) end)
  check("set_state: script not installed -> false + reason, nothing set",
    not ok and why:find("not installed", 1, true) ~= nil and #states == 0)
  return results
end

return Button
