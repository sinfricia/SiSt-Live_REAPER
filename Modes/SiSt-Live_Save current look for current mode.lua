-- @noindex
-- SiSt-Live: Save current look for current mode. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   Set REAPER up the way the current mode should look (theme, layouts in Options > Layouts, windows and
--   dockers), then run this. One confirmation lists what will be stored for the current mode:
--   - theme: the theme file loaded right now
--   - layouts: the active track panel, transport and mixer layouts
--   - screenset: the current windows and dockers are saved into the mode's window set slot (only if a slot is
--     set in "SiSt-Live: Configure modes"; otherwise the screenset is left alone)
--   Yes stores everything, No changes nothing. Nothing is re-applied: REAPER already looks like that.
--   The other mode settings (fullscreen, keyboard, mouse, windows) are not touched.
--   There is deliberately no autosave of the look: a window closed by accident on stage would become the show look.

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local Mode        = require("SiSt-Live_Mode")
local ModeEffects = require("SiSt-Live_ModeEffects")

local TITLE = "SiSt-Live: save current look"

local mode = Mode.get()
local items, skipped, problems = ModeEffects.take_current(mode)
local text = ModeEffects.describe_take(mode, items, skipped, problems)

if #items == 0 then
  reaper.MB(text, TITLE, 0)
elseif reaper.MB(text, TITLE, 4) == 6 then -- Yes
  local failures = ModeEffects.save_taken(items)
  if #failures > 0 then
    local lines = {}
    for _, f in ipairs(failures) do lines[#lines + 1] = ("%s: %s"):format(f.name, f.message) end
    reaper.MB("Not saved:\n\n" .. table.concat(lines, "\n"), TITLE, 0)
  end
end

reaper.defer(function() end) -- no undo point
