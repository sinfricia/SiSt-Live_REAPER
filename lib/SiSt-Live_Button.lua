-- @noindex
-- SiSt-Live toolbar button helper.
-- Lights or unlights the toolbar button of a SiSt-Live toggle action (edit/show mode, debug logging)
-- from ANY script, e.g. when the status display switches the mode.
--
-- The button belongs to the action of a script (e.g. "Modes/SiSt-Live_Toggle Edit-Show Mode.lua"). Its
-- command ID is looked up by the script's file (SiSt-Live_Actions.lua), so it works from the first
-- switch in every REAPER session: no script has to register anything first.
--
-- Uses the global `reaper` lazily (never cached) so tests can swap in a mock.

local Actions = require("SiSt-Live_Actions")

local Button = {}

-- Button names -> script id in Actions.SCRIPTS
Button.SCRIPTS = { mode = "mode", debug = "debug" }

--- Light (true) or unlight (false) the button. Returns false (and the reason) if its action isn't found.
function Button.set_state(id, on, api)
  api = api or reaper
  local cmd, err = Actions.script_command(Button.SCRIPTS[id] or id, api)
  if not cmd then return false, err end
  api.SetToggleCommandState(0, cmd, on and 1 or 0)
  api.RefreshToolbar2(0, cmd)
  return true
end

--- Which action the button belongs to, for diagnostics.
function Button.describe(id, api)
  local cmd, err = Actions.script_command(Button.SCRIPTS[id] or id, api)
  return cmd and ("action %d"):format(cmd) or err
end

--- Built-in self-test. Uses a fake REAPER API: never touches a real toolbar button.
function Button.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end
  local states = {}
  local api = {
    GetResourcePath = function() return "R" end,
    file_exists = function() return false end, -- no script installed
    SetToggleCommandState = function(section, cmd, v) states[#states + 1] = v end,
    RefreshToolbar2 = function() end,
  }
  local ok, why = Button.set_state("debug", true, api)
  check("set_state: script not installed -> false + reason, nothing set",
    not ok and why:find("not installed", 1, true) ~= nil and #states == 0)
  return results
end

return Button
