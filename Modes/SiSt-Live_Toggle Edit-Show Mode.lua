-- @noindex
-- SiSt-Live: Toggle Edit/Show mode. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   Toggles SiSt-Live between Edit and Show mode.
--   Toolbar button: lit = Show mode, unlit = Edit mode (default on every start).
--
--   Mode effects: after switching, REAPER is brought into the state of the new mode.
--   All of them are set in "SiSt-Live: Configure modes", one field per mode and effect:
--   - theme: file name, or "current" for the theme loaded in REAPER right now
--   - layouts: "current" for the layouts chosen in Options > Layouts, or e.g. "tcp=B150%, trans=150%"
--   - screenset: number of a window set saved in REAPER's Screensets window (loaded on every switch)
--   - fullscreen: on / off
--   - keyboard: main, or the alt section number (1 = Main alt-1)
--   - mouse: block (show mode: switches item, envelope and time selection mouse actions off) / restore
--   - windows: open (show mode: opens the setlist, status display and toolbar) / restore (closes
--     the ones that show mode opened). Never configured: show = open, edit = restore
--   An empty field leaves that part of REAPER alone. Set both modes, otherwise switching back
--   doesn't restore anything.
--   "SiSt-Live: Save current look for current mode" takes theme, layouts and screenset from REAPER in one go.
--   "SiSt-Live: Apply current mode" re-applies everything without switching. To start REAPER with
--   the right theme, call it from Scripts/__startup.lua.

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local Mode = require("SiSt-Live_Mode")
local Log  = require("SiSt-Live_Log")
local log  = Log.get("ToggleMode")

Log.safe_call(log, "toggle", Mode.toggle)
local mode = Mode.get()
log:info("mode is now %s", mode)

-- Effects run after the mode is set: the mode is the source of truth and a failing effect never undoes it.
-- Mode.apply shows the dialog if effects failed or could not run at all.
Mode.apply(mode)

reaper.defer(function() end) -- prevents REAPER from creating an undo point
