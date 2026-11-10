-- @noindex
-- SiSt-Live: Apply current mode
-- Brings REAPER into the state of the current mode (theme, ...) without switching the mode.
-- Use it after a REAPER restart, or when something drifted (e.g. a theme was loaded by hand).
--
-- REAPER startup: __startup.lua runs this file with the argument "startup":
--   local apply_mode = loadfile(reaper.GetResourcePath() .. "/Scripts/SiSt-Live/Modes/SiSt-Live_Apply current mode.lua")
--   if apply_mode then apply_mode("startup") end
-- Then it always applies EDIT mode (SiSt-Live always starts in edit mode). That also restores the mouse modifiers if
-- REAPER was closed or crashed in show mode (see the mouse effect).

local startup = (...) == "startup"

-- Own folder from this file (not get_action_context: run from __startup.lua, that is __startup.lua's path)
package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local Mode = require("SiSt-Live_Mode")
local Log  = require("SiSt-Live_Log")
local log  = Log.get("ApplyMode")

local mode = Mode.get()
if startup then
  mode = Mode.EDIT -- Mode.apply sets it, which also lights the mode button correctly
end
local _, failed, err = Mode.apply(mode) -- dialog if effects failed or could not run
log:info("applied %s mode%s, %s", mode, startup and " (REAPER startup)" or "",
  err and ("effects could not run: " .. err) or (failed .. " effect(s) failed"))

reaper.defer(function() end) -- no undo point
