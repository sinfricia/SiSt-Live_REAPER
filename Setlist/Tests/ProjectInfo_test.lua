-- @noindex
-- Tests of Setlist/ProjectInfo.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local ProjectInfo = require("Setlist.ProjectInfo")

local Tests = {}

-- Self test ---------------------------------------------------------------------------------------------------

function Tests.self_test()
   local SelfTest = require("SelfTest")
   local check, results = SelfTest.checker()

   local H = { normal = 100, no_stop = 200 }
   local ids = { _RSnormal = 100, _RSnostop = 200, ["40044"] = 40044, _RSother = 300 }
   local function resolve_fake(token) return ids[token] end
   local function marker(name, pos) return { isrgn = false, pos = pos or 0, name = name } end
   local function region(name, from, to) return { isrgn = true, pos = from, rgnend = to, name = name } end

   local info = ProjectInfo.parse({ marker("=START", 1), marker("!_RSnormal", 200) }, H, resolve_fake)
   check("end handler: nothing to show (normal)", info.end_kind == "normal")
   info = ProjectInfo.parse({ marker("=START", 1), marker("!_RSnostop", 200) }, H, resolve_fake)
   check("NO STOP is found", info.end_kind == "no_stop")
   info = ProjectInfo.parse({ marker("=START", 1), marker("End", 200) }, H, resolve_fake)
   check("an end marker without a handler: manual", info.end_kind == "manual")
   info = ProjectInfo.parse({ marker("=START", 1), marker("!_RSother", 150), marker("End", 200) }, H, resolve_fake)
   check("another action marker does not count: still manual", info.end_kind == "manual")
   info = ProjectInfo.parse({ marker("!_RSother", 150), marker("!_RSnostop", 200) }, H, resolve_fake)
   check("a handler next to other action markers is found", info.end_kind == "no_stop")
   info = ProjectInfo.parse({ marker("=START", 1) }, H, resolve_fake)
   check("only a start marker: no end handler, manual", info.end_kind == "manual")
   info = ProjectInfo.parse({}, H, resolve_fake)
   check("no markers at all: manual too (the list leaves out the routing project)", info.end_kind == "manual" and #info.loops == 0)
   info = ProjectInfo.parse({ marker("End", 200) }, {}, resolve_fake)
   check("handlers unknown: no chip rather than a wrong one", info.end_kind == nil)
   info = ProjectInfo.parse({ marker("!40044 _RSnostop", 200) }, H, resolve_fake)
   check("several commands in one action marker", info.end_kind == "no_stop")

   info = ProjectInfo.parse({ region("LOOP", 10, 20), region("LOOP 3", 30, 40), region("LOOP x", 50, 60),
     region("Verse", 70, 80), marker("LOOP", 5) }, H, resolve_fake)
   check("loop regions: LOOP, LOOP <n>, LOOP with junk (= until stopped); other regions and markers are not loops",
     #info.loops == 3 and info.loops[1].count == -1 and info.loops[2].count == 3 and info.loops[2].from == 30
     and info.loops[2].to == 40 and info.loops[3].count == -1)

   local p, n = ProjectInfo.parse_pass("2/3")
   check("loop pass: 2/3", p == 2 and n == 3)
   p, n = ProjectInfo.parse_pass("4/-1")
   check("loop pass: until stopped", p == 4 and n == -1)
   local _, _, last = ProjectInfo.parse_pass("2/3!")
   check("loop pass: stopped (last pass) flag", last == true and select(3, ProjectInfo.parse_pass("2/3")) == false)
   check("loop pass: nothing or junk", ProjectInfo.parse_pass("") == nil and ProjectInfo.parse_pass("x") == nil
     and ProjectInfo.parse_pass(nil) == nil)

   check("an invalid project gives an empty info", #SelfTest.with_reaper({ ValidatePtr = function() return false end },
     function() return ProjectInfo.read({}).loops end) == 0)

   return results
end

return Tests
