-- @noindex
-- Tests of Setlist/UI/ViewState.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local Log = require("SiSt-Live_Log")
local Mode = require("SiSt-Live_Mode")
local ViewState = require("Setlist.UI.ViewState")
local view, MODE = ViewState.view, ViewState.MODE

local Tests = {}

-- Self test ---------------------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("ToListMode", function(t)
   t.eq(ViewState.to_list_mode(""), nil, "empty")
   t.eq(ViewState.to_list_mode("garbage"), nil, "garbage")
   t.eq(ViewState.to_list_mode(nil), nil, "nil")
   local lib = { SHOW = "live", EDIT = "prep" }
   t.eq(ViewState.to_list_mode("live", lib), MODE.SHOW, "uses the library's own values")
   t.eq(ViewState.to_list_mode("prep", lib), MODE.EDIT, "uses the library's own values (edit)")
   t.eq(ViewState.to_list_mode("show", lib), nil, "does not assume the default strings")
   t.eq(ViewState.to_list_mode(nil, {}), nil, "nil never matches a missing constant")
end)

define("SetListMode / OnSharedModeChanged", function(t)
   local saved_mode, saved_pending = view.mode, view.follow_pending

   view.mode, view.follow_pending = MODE.SHOW, false
   t.ok(ViewState.set_mode(MODE.EDIT), "show -> edit reports a change")
   t.eq(view.follow_pending, false, "entering edit mode does not request a scroll")
   t.ok(not ViewState.set_mode(MODE.EDIT), "same mode again: no change")
   t.ok(not ViewState.set_mode(nil), "nil is ignored")
   t.eq(view.mode, MODE.EDIT, "nil leaves the mode alone")
   t.ok(ViewState.set_mode(MODE.SHOW), "edit -> show reports a change")
   t.eq(view.follow_pending, true, "back in show mode: jump to the current project")

   ViewState.on_shared_mode_changed(Mode.EDIT, nil)
   t.eq(view.mode, MODE.EDIT, "callback: shared edit -> list edit")
   ViewState.on_shared_mode_changed("garbage", Mode.EDIT)
   t.eq(view.mode, MODE.EDIT, "callback: unknown value keeps the current mode")
   ViewState.on_shared_mode_changed(Mode.SHOW, Mode.EDIT)
   t.eq(view.mode, MODE.SHOW, "callback: shared show -> list show")

   view.mode, view.follow_pending = saved_mode, saved_pending
end)

function Tests.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Tests
