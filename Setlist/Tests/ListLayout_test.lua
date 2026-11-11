-- @noindex
-- Tests of Setlist/UI/ListLayout.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local ListLayout = require("Setlist.UI.ListLayout")
local ViewState = require("Setlist.UI.ViewState")
local CFG = ViewState.CFG

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

local Tests = {}

define("ListLayout.compute", function(t)
   local big = ListLayout.compute(800, 600, 400, 300, 40)
   t.eq(big.small, false, "a big window has the command bar")
   t.eq(big.panel_h, CFG.ctrl_panel_size, "panel height")
   t.eq(big.list_h, 600 - CFG.ctrl_panel_size - CFG.title_height, "the list gets what the header and the panel leave")
   t.eq(big.visible_rows, math.floor(big.list_h / 40), "whole rows only")

   local narrow = ListLayout.compute(300, 600, 400, 300, 40)
   t.eq(narrow.small, true, "too narrow for the command bar")
   t.eq(narrow.panel_h, 0, "no panel when small")
   t.eq(narrow.list_h, 600 - CFG.title_height, "the list takes the room of the panel")

   t.eq(ListLayout.compute(800, 250, 400, 300, 40).small, true, "too low for the command bar")
   t.eq(ListLayout.compute(400, 300, 400, 300, 40).small, false, "exactly the minimum is not small")
   t.eq(ListLayout.compute(800, 40, 400, 300, 40).visible_rows, 1, "at least one row, also in a tiny window")
end)

function Tests.self_test()
   return run(function(go) go() end)
end

return Tests
