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
--   - locking: on (all lock modes except full item, every open project) / off
--   - windows: open (show mode: opens the setlist, status display and toolbar) / restore (closes
--     the ones that show mode opened). Never configured: show = open, edit = restore
--   An empty field leaves that part of REAPER alone. Set both modes, otherwise switching back
--   doesn't restore anything.
--   "SiSt-Live: Apply current mode" re-applies everything without switching. To start REAPER with
--   the right theme, call it from Scripts/__startup.lua.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Mode = require("SiSt-Live_Mode")
local Log  = require("SiSt-Live_Log")
local log  = Log.get("ToggleMode")

Log.safe_call(log, "toggle", Mode.toggle)
local mode = Mode.get()
log:info("mode is now %s", mode)

-- Effects run after the mode is set: the mode is the source of truth and a failing effect never
-- undoes it. The effects library is loaded here, not at the top, so that even a missing or broken
-- effects file can't stop the toggle itself.
local ok, err = pcall(function()
  require("SiSt-Live_ModeEffects").apply_and_report(mode) -- dialog if an effect failed
end)
if not ok then
  log:error("mode effects could not run: %s", tostring(err)) -- Log keeps the console closed on stage
  if mode == Mode.SHOW then
    -- Nothing was switched (no locking, keyboard, windows...) and no effect status was stored, so the Status
    -- Display can't show it: this needs immediate attention.
    reaper.MB("Show mode: the mode effects could not run.\n\nDetails in the log:\n" .. Log.file_path(),
      "SiSt-Live: mode effects", 0)
  end
end

reaper.defer(function() end) -- prevents REAPER from creating an undo point
