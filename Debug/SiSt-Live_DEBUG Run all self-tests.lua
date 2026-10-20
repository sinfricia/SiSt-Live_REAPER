-- @noindex
-- Run all self-tests: runs the test lists of every registered package (see lib/SelfTest.lua) in one report.
-- Packages register themselves automatically when their scripts run. Test lists that no longer exist are
-- reported and removed from the registry.
--
-- Temporary home: not part of the package (not in Setup's @provides). Moves to SiSt Libraries later.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

require("SelfTest").run_registered()

reaper.defer(function() end) -- no undo point
