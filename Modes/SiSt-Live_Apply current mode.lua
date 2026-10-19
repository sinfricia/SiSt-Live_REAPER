-- @noindex
-- SiSt-Live: Apply current mode
-- Brings REAPER into the state of the current mode (theme, ...) without switching the mode.
-- Use it after a REAPER restart, or when something drifted (e.g. a theme was loaded by hand).
--
-- To apply it automatically when REAPER starts, add this to <resource path>/Scripts/__startup.lua
-- (look up the command ID in the action list: right click the action > Copy selected action command ID):
--   reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS..."), 0)

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Mode        = require("SiSt-Live_Mode")
local Log         = require("SiSt-Live_Log")
local ModeEffects = require("SiSt-Live_ModeEffects")
local log         = Log.get("ApplyMode")

local mode = Mode.get()
local _, failed = ModeEffects.apply_all(mode)
log:info("applied %s mode, %d effect(s) failed", mode, failed)

reaper.defer(function() end) -- no undo point
