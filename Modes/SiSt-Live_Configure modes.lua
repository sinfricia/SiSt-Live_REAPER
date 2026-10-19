-- @noindex
-- SiSt-Live: Configure modes
-- One dialog for all mode effect settings (theme, layouts, screenset, fullscreen, keyboard section,
-- locking, windows),
-- for both modes. Type "current" into the theme or layouts field to take what REAPER uses right
-- now; empty = none. All changes are confirmed before anything is stored.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local SettingsDialog = require("SiSt-Live_SettingsDialog")

SettingsDialog.run()

reaper.defer(function() end) -- no undo point
