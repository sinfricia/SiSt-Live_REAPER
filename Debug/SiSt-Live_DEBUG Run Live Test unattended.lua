-- @noindex
-- SiSt-Live: DEBUG Run Live Test unattended
-- For Claude (started with `reaper.exe -nonewinst <this script>`), not for the action list or the package.
-- Runs "SiSt-Live_DEBUG Run Live Test.lua" without menu and questions: show workflow test only (no loopbacks),
-- other projects are never closed (if any are open, the run is refused), the test projects stay open at the end.
-- Result: Data/SiSt Libraries/Live test report.txt (also when the run is refused: "Not started: <reason>").

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""

local live_test, err = loadfile(script_dir .. "SiSt-Live_DEBUG Run Live Test.lua")
local ok = live_test ~= nil
if ok then ok, err = pcall(live_test, "unattended") end
if not ok then reaper.ShowConsoleMsg("Unattended live test failed: " .. tostring(err) .. "\n") end
