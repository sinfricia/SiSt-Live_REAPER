-- @noindex
-- Toggles SiSt-Live debug logging. Toolbar button: lit = debug ON.
-- Output appears in the REAPER console (View > ReaScript console output).

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Log = require("SiSt-Live_Log")

local on = Log.toggle_debug()
reaper.ShowConsoleMsg("SiSt-Live debug logging: " .. (on and "ON" or "OFF") .. "\n")

reaper.defer(function() end) -- no undo point
