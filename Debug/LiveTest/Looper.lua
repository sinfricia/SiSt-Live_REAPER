-- @noindex
-- Live test: Region Looper (part of the show workflow test, play mode only).
-- The deferred Region Looper loops regions named "LOOP <n>" n times, "LOOP" until "Stop loop", which then allows
-- one final pass. While looping: repeat on, time selection = region, the "cue" and "timecode" tracks muted; when
-- the loop ends everything is restored. The test takes the first LOOP region in the test songs, whatever kind.
-- To keep it short, it jumps to shortly before the region end for every pass (the looper only counts the jump
-- back to the region start).

local SelfTest = require("SelfTest")
local H        = require("LiveTest.Helpers")

local Looper = {}

local LOOPER_FILE     = "Region Looper/SiSt-Live_Region Looping (defered).lua"
local STOP_LOOP_FILE  = "Region Looper/SiSt-Live_Region Looping_Stop loop.lua"
local LOOP_LEAD_IN    = 1      -- s, start playing this far before the region
local LOOP_BEFORE_END = 0.8    -- s, jump to this far before the region end for the next pass
local LOOP_PASS_WAIT  = 1.5    -- s, then wait: the jump back to the start (or past the end) has happened
local LOOPER_TRACKS   = { "cue", "timecode" } -- muted by the looper while looping

local loop = {} -- the region under test: { proj, start, stop, count (-1 = until Stop loop), name, mutes = {} }

local function find_loop_region()
  for _, proj in ipairs(H.songs) do
    local i = 0
    while true do
      local rv, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers2(proj, i)
      if rv == 0 then break end
      if isrgn and name:find("^LOOP") then
        local count = tonumber(name:match("^LOOP%s+(%d+)$"))
        return { proj = proj, start = pos, stop = rgnend, name = name, count = (count and count >= 1) and count or -1 }
      end
      i = i + 1
    end
  end
end

local function looper_tracks(proj)
  local list = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    for _, wanted in ipairs(LOOPER_TRACKS) do
      if name:lower() == wanted then list[#list + 1] = { tr = tr, name = name } end
    end
  end
  return list
end

local function looping_state()
  local proj = loop.proj
  local _, ext = reaper.GetProjExtState(proj, "SiSt-Live", "RegionLooping")
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  return {
    pos = reaper.GetPlayPositionEx(proj),
    rep = reaper.GetSetRepeatEx(proj, -1) == 1,
    ext = ext,
    selection = math.abs(sel_start - loop.start) < H.TOLERANCE and math.abs(sel_end - loop.stop) < H.TOLERANCE,
  }
end

local function jump_before_end()
  reaper.SelectProjectInstance(loop.proj)
  reaper.SetEditCurPos2(loop.proj, loop.stop - LOOP_BEFORE_END, false, true) -- seek the running playback
end

local function mute_rows(want_muted)
  local rows = {}
  for _, t in ipairs(loop.mutes or {}) do
    local muted = reaper.GetMediaTrackInfo_Value(t.tr, "B_MUTE") == 1
    local expected = want_muted or t.before
    rows[#rows + 1] = { name = ("track %s %s"):format(t.name, want_muted and "muted while looping"
      or ("back to " .. (t.before and "muted" or "unmuted"))), ok = muted == expected }
  end
  if #rows == 0 then rows[1] = SelfTest.warning("no cue / timecode track in " .. H.name_of(loop.proj) .. ": muting not tested") end
  return rows
end

function Looper.steps()
  return {
    { name = "Region Looper running",
      run = function()
        local cmd = H.script_cmd(LOOPER_FILE)
        loop.started_by_test = reaper.GetToggleCommandState(cmd) ~= 1
        if loop.started_by_test then reaper.Main_OnCommand(cmd, 0) end -- normally started by __startup.lua
      end,
      wait = 0.5,
      check = function()
        local running = reaper.GetToggleCommandState(H.script_cmd(LOOPER_FILE)) == 1
        return { { name = running and ("Region Looper running" .. (loop.started_by_test and " (started by the test)" or ""))
          or "Region Looper could not be started", ok = running } }
      end },

    { name = "Loop: start",
      required = true, -- the next loop steps build on it
      run = function()
        local found = find_loop_region()
        for k in pairs(loop) do loop[k] = nil end
        if not found then return end
        for k, v in pairs(found) do loop[k] = v end
        loop.mutes = looper_tracks(loop.proj)
        for _, t in ipairs(loop.mutes) do t.before = reaper.GetMediaTrackInfo_Value(t.tr, "B_MUTE") == 1 end
        reaper.SelectProjectInstance(loop.proj)
        H.keep_only_needed_playing()
        reaper.Main_OnCommandEx(H.STOP, 0, loop.proj)
        reaper.SetEditCurPos2(loop.proj, math.max(0, loop.start - LOOP_LEAD_IN), false, false)
        reaper.Main_OnCommandEx(H.PLAY, 0, loop.proj) -- play mode
        -- Not tested (2026-10-25, Sina: maybe later): REC take switching - in play mode the looper switches the
        -- REC folder items starting at the loop start to their next take on every pass.
      end,
      wait = LOOP_LEAD_IN + 1,
      check = function()
        if not loop.proj then
          return { { name = "no region named LOOP... in the test songs", ok = false } }
        end
        local s = looping_state()
        local rows = {
          { name = ("loop region \"%s\" in %s (%.1f - %.1f s, %s)"):format(loop.name, H.name_of(loop.proj), loop.start,
            loop.stop, loop.count > 0 and (loop.count .. " passes") or "until Stop loop"), ok = true },
          { name = "playing inside the loop region", ok = s.pos >= loop.start and s.pos < loop.stop },
          { name = "repeat on", ok = s.rep },
          { name = "time selection = loop region", ok = s.selection },
          { name = "looping flag (project ExtState RegionLooping) on", ok = s.ext == "true" },
        }
        for _, r in ipairs(mute_rows(true)) do rows[#rows + 1] = r end
        return rows
      end },

    { name = "Loop: next pass",
      run = jump_before_end,
      wait = LOOP_PASS_WAIT,
      check = function()
        local s = looping_state()
        return { { name = ("jumped back to the loop start (position %.2f s)"):format(s.pos),
          ok = s.pos >= loop.start and s.pos < loop.stop - LOOP_BEFORE_END } }
      end },

    { name = "Loop: Stop loop",
      run = function()
        if loop.count == 2 then return end -- already in its last pass: nothing left to stop
        reaper.SelectProjectInstance(loop.proj) -- Stop loop acts on the active project
        reaper.Main_OnCommand(H.script_cmd(STOP_LOOP_FILE), 0)
        jump_before_end()
      end,
      wait = LOOP_PASS_WAIT,
      check = function()
        if loop.count == 2 then
          return { SelfTest.warning("\"" .. loop.name .. "\" is already in its last pass: Stop loop not tested") }
        end
        local s = looping_state()
        return {
          { name = ("one final pass after Stop loop (position %.2f s)"):format(s.pos),
            ok = s.pos >= loop.start and s.pos < loop.stop - LOOP_BEFORE_END },
          { name = "repeat off during the final pass", ok = not s.rep },
        }
      end },

    { name = "Loop: end",
      run = jump_before_end,
      wait = LOOP_PASS_WAIT,
      check = function()
        local s = looping_state()
        local rows = {
          { name = ("plays on past the loop region (position %.2f s, region end %.2f s)"):format(s.pos, loop.stop),
            ok = s.pos >= loop.stop },
          { name = "repeat off", ok = not s.rep },
          { name = "looping flag off", ok = s.ext ~= "true" },
        }
        for _, r in ipairs(mute_rows(false)) do rows[#rows + 1] = r end
        reaper.Main_OnCommandEx(H.STOP, 0, loop.proj)
        return rows
      end },
  }
end

return Looper
