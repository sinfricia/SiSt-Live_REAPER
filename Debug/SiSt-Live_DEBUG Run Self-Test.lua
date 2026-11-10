-- @noindex
-- SiSt-Live: DEBUG Run Self-Test
-- Runs SiSt-Live's test list (lib/SiSt-Live_Tests.lua) and prints a short report to the REAPER console; the full
-- report (every PASS line) goes to <resource path>/Data/SiSt Libraries/Self-test report.txt.
--
-- Safe to run any time: the tests use fakes and never change REAPER (the mode is restored afterwards). The live
-- checks only read the real REAPER, e.g. that every native command ID the mode effects use still exists: run this
-- after every REAPER update. Also registers SiSt-Live's test list for "Run all self-tests".

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "") .. "../lib/?.lua;" .. package.path
local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""

local SelfTest = require("SelfTest")

local list_path = script_dir .. ".." .. package.config:sub(1, 1) .. "lib" .. package.config:sub(1, 1) .. "SiSt-Live_Tests.lua"
SelfTest.register("SiSt-Live", list_path)

local suite, err = SelfTest.load_suite(list_path)
if suite then
  SelfTest.run_suites({ suite }, "SiSt-Live self-test")
else
  reaper.ShowConsoleMsg("SiSt-Live self-test: the test list could not be loaded:\n" .. tostring(err) .. "\n")
end

reaper.defer(function() end) -- no undo point
