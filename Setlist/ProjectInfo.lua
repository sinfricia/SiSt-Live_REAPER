-- @noindex
--[[
SiSt-Live Setlist: ProjectInfo

What a song project says about itself in its markers, for the indicators in the list rows:

  loops       the regions named "LOOP" (until stopped) or "LOOP <n>" (n passes) that the Region Looper plays: { from, to, count }
              (count -1 = until stopped)
  end_kind    what happens at the end of the song: "no_stop" (the end action is the Project End Handler - NO STOP),
              "normal" (the Project End Handler: nothing to show), "manual" (no end handler: nothing happens, the user
              switches), or nil (the handlers are unknown, so nothing can be said)

An action marker is a marker named "!<command ID> ...". Markers whose command is not one of the two handlers are other
actions and say nothing about the end of the song.

  read(proj)                        the info of an open project, cached until the project changes
  loop_pass(proj)                   pass, passes, last (loop stopped: last pass) of the loop that the Region Looper plays, or nil
  parse_pass(text)                  the pure part of loop_pass
  parse(markers, handlers, resolve) the pure part: markers = list of { isrgn, pos, rgnend, name }, handlers = { normal,
                                    no_stop } (command IDs, either may be nil), resolve(token) -> command ID or nil

Self test: ProjectInfo.self_test() returns a list of { name, ok }.
]]

local Actions = require("Actions")
local Checks = require("ActionReferenceChecks")

local ProjectInfo = {}

local HANDLER_NAME = "SiSt-Live_Project End Handler"
local NO_STOP_NAME = "SiSt-Live_Project End Handler - NO STOP"

local EMPTY = { loops = {} }

--- The pure part. See the top.
function ProjectInfo.parse(markers, handlers, resolve)
   local info = { loops = {} }
   local found = nil

   for _, m in ipairs(markers) do
      if m.isrgn then
         if (m.name or ""):find("^LOOP") then
            local count = tonumber((m.name or ""):match("^LOOP%s+(%d+)$"))
            if not count or count < 1 then count = -1 end
            info.loops[#info.loops + 1] = { from = m.pos, to = m.rgnend, count = count }
         end
      else
         for _, token in ipairs(Checks.marker_commands(m.name) or {}) do
            local cmd = resolve(token)
            if cmd and cmd ~= 0 then
               if cmd == handlers.no_stop then found = "no_stop"
               elseif cmd == handlers.normal and found ~= "no_stop" then found = "normal" end
            end
         end
      end
   end

   if handlers.normal or handlers.no_stop then
      info.end_kind = found or "manual"
   end
   return info
end

-- Reading a project -------------------------------------------------------------------------------------------

local handlers, handlers_tried = nil, -100

-- The command IDs of the two handlers; looked up again every 10 seconds while one of them is missing
local function find_handlers()
   local now = reaper.time_precise()
   if handlers and (handlers.normal and handlers.no_stop) or now - handlers_tried < 10 then return handlers or {} end
   handlers_tried = now
   handlers = { normal = Actions.find_custom(HANDLER_NAME), no_stop = Actions.find_custom(NO_STOP_NAME) }
   return handlers
end

local function resolve(token)
   if token:match("^%d+$") then return tonumber(token) end
   return reaper.NamedCommandLookup(token)
end

--- "2/3" -> 2, 3, false; "2/-1" -> 2, -1 (until stopped); a trailing "!" (the loop was stopped: last pass) gives true
--- as the third value; anything else -> nil.
function ProjectInfo.parse_pass(text)
   local pass, total, last = (text or ""):match("^(%d+)/(%-?%d+)(!?)$")
   if not pass then return nil end
   return tonumber(pass), tonumber(total), last == "!"
end

--- The loop pass the Region Looper reports for a project (it writes "<pass>/<passes>" into the project's ExtState while
--- it loops, with a "!" once the loop was stopped): pass, passes, last, or nil.
function ProjectInfo.loop_pass(proj)
   if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return nil end
   local found, value = reaper.GetProjExtState(proj, "SiSt-Live", "LoopPass")
   if found == 0 then return nil end
   return ProjectInfo.parse_pass(value)
end

local cache, cache_size = {}, 0 -- project -> { count, total, info }

--- The info of an open project (empty for an invalid pointer). Read once, then again when the project's state change count
--- or its number of markers and regions changes (adding a region does not change the state change count, so the number
--- is watched too; both are cheap to ask).
function ProjectInfo.read(proj)
   if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return EMPTY end
   local count = reaper.GetProjectStateChangeCount(proj)
   local total = reaper.CountProjectMarkers(proj) -- markers and regions together
   local c = cache[proj]
   if c and c.count == count and c.total == total then return c.info end

   local markers = {}
   for i = 0, total - 1 do
      local rv, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers2(proj, i)
      if rv ~= 0 then markers[#markers + 1] = { isrgn = isrgn, pos = pos, rgnend = rgnend, name = name } end
   end
   local info = ProjectInfo.parse(markers, find_handlers(), resolve)

   if not c then
      cache_size = cache_size + 1
      if cache_size > 200 then cache, cache_size = {}, 1 end -- closed projects leave entries behind: start over
   end
   cache[proj] = { count = count, total = total, info = info }
   return info
end

-- Self test ---------------------------------------------------------------------------------------------------

function ProjectInfo.self_test()
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

return ProjectInfo
