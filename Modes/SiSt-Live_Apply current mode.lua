-- @noindex
-- SiSt-Live: Apply current mode
-- Brings REAPER into the state of the current mode (theme, ...) without switching the mode.
-- Use it after a REAPER restart, or when something drifted (e.g. a theme was loaded by hand).
--
-- REAPER startup: __startup.lua runs this file with the argument "startup":
--   local apply_mode = loadfile(reaper.GetResourcePath() .. "/Scripts/SiSt-Live/Modes/SiSt-Live_Apply current mode.lua")
--   if apply_mode then apply_mode("startup") end
-- Then it always applies EDIT mode (SiSt-Live always starts in edit mode) and leaves locking as it is: locking is
-- per project and may have been set on purpose; it only changes on a real mode switch.

local startup = (...) == "startup"

-- Own folder from this file (not get_action_context: run from __startup.lua, that is __startup.lua's path)
local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Mode        = require("SiSt-Live_Mode")
local Log         = require("SiSt-Live_Log")
local ModeEffects = require("SiSt-Live_ModeEffects")
local log         = Log.get("ApplyMode")

local mode, opts = Mode.get(), nil
if startup then
  mode = Mode.EDIT
  Mode.set(mode) -- also lights the mode button correctly
  opts = { except = { locking = true }, except_reason = "left as it is at REAPER startup" }
end
local _, failed = ModeEffects.apply_and_report(mode, opts) -- dialog if an effect failed
log:info("applied %s mode%s, %d effect(s) failed", mode, startup and " (REAPER startup)" or "", failed)

reaper.defer(function() end) -- no undo point
