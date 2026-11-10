-- @noindex
-- SiSt-Live's logging: the general Log library (lib/Log.lua), set up for SiSt-Live. Every SiSt-Live script loads
-- this file, not Log directly, so its lines go to SiSt-Live's log file:
--   <resource path>/Data/SiSt-Live/SiSt-Live.log (rotated at 1 MB to SiSt-Live.old.log)
-- and switching debug logging lights the "DEBUG Toggle Logging" toolbar button.
-- The quiet console flag (no console window on stage) is set by the Mode library: on in show mode.
--
--   local Log = require("SiSt-Live_Log")   -- returns the Log module itself
--   local log = Log.get("Setlist")

local Log    = require("Log")
local Button = require("SiSt-Live_Button")

Log.configure({
  file_dir = "SiSt-Live",
  file_name = "SiSt-Live.log",
  on_debug_change = function(on) Button.set_state("debug", on) end,
  diagnostics = function() return { { "debug button", Button.describe("debug") } } end,
})

return Log
