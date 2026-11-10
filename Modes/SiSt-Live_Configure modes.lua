-- @noindex
-- SiSt-Live: Configure modes
-- One dialog for all mode effect settings (theme, layouts, screenset, fullscreen, keyboard section,
-- mouse modifiers, windows),
-- for both modes. Type "current" into the theme or layouts field to take what REAPER uses right
-- now; empty = none. All changes are confirmed before anything is stored.

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local SettingsDialog = require("SiSt-Live_SettingsDialog")

SettingsDialog.run()

reaper.defer(function() end) -- no undo point
