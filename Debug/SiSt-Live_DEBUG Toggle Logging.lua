-- @noindex
-- Toggles SiSt-Live debug logging. Toolbar button: lit = debug ON.
-- Output appears in the REAPER console (View > ReaScript console output).

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local Log = require("SiSt-Live_Log")

local on = Log.toggle_debug()
reaper.ShowConsoleMsg("SiSt-Live debug logging: " .. (on and "ON" or "OFF") .. "\n")

reaper.defer(function() end) -- no undo point
