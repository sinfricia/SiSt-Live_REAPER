-- @noindex
-- SiSt-Live: Lock mouse cursor to arrow in arrange view. Part of the SiSt-Live package (see Setup/SiSt-Live_Setup.lua).
--
--   Shows the plain arrow cursor in the arrange view while the mouse modifiers are blocked in show mode (mode
--   effect "mouse"), so it is clear that clicks and drags there do nothing. Started by that effect; ends by itself
--   when the mouse modifiers are restored. Running it by hand does nothing while they aren't blocked.
--   Windows only for now (see the arrow cursor part of lib/ModeEffects/SiSt-Live_ModeEffect_Mouse.lua).

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path

local Mouse = require("ModeEffects.SiSt-Live_ModeEffect_Mouse")
local Log   = require("SiSt-Live_Log")
local log   = Log.get("ArrowCursor")

-- Started again while it runs (by hand, or by a second switch to show mode): REAPER ends the old run, which gives the
-- arrange view its cursor messages back (atexit), and starts this one. So there is never more than one.
reaper.set_action_options(1 | 2)

if not Mouse.is_blocked() then return end -- nothing to show

local arrow, why = Mouse.arrow_create(Mouse.is_blocked)
if not arrow then
  log:debug("not started: %s", why)
  return
end

reaper.atexit(arrow.release) -- the cursor messages always go back to the arrange view

local function loop()
  local ok, more, reason = xpcall(arrow.step, debug.traceback)
  if not ok then
    log:error("arrow cursor stopped: %s", tostring(more))
    arrow.release()
    return
  end
  if not more then
    log:debug("arrow cursor ended: %s", tostring(reason))
    return
  end
  reaper.defer(loop)
end

loop()
