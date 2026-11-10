-- @noindex
-- Live test: helpers shared by the main file (Debug/SiSt-Live_DEBUG Run Live Test.lua) and its parts
-- (LiveTest/Show.lua, Looper.lua, Loopback.lua). Also the state the show workflow and the looper share: the routing
-- project and the songs of the test folder (set by Show).

local SelfTest = require("SelfTest")
local General  = require("Actions")
local Actions  = require("SiSt-Live_Actions")

local H = {}

H.TITLE = "SiSt-Live live test"
H.sep   = package.config:sub(1, 1)

-- Native actions (IDs are trusted, see lib/Actions.lua)
H.STOP      = 1016  -- Transport: Stop
H.PLAY      = 1007  -- Transport: Play
H.NEW_TAB   = 40859 -- File: New project tab
H.CLOSE_TAB = 40860 -- File: Close current project tab
H.CLOSE_ALL = 40886 -- File: Close all projects

H.TOLERANCE   = 0.05 -- s, edit cursor position
H.PLAY_WINDOW = 3    -- s, "plays from X": play position at most this far after X

H.EXT_SECTION = "SiSt-Live_LiveTest"
H.KEY_FOLDER  = "folder"

-- Shared state of the show workflow and the looper: set after opening the test projects, again after Start Show
-- (it moves the routing project to the first tab)
H.routing, H.songs = nil, {}

-- Test folder ---------------------------------------------------------------------------------------

function H.config_dir() return SelfTest.normalize(reaper.GetResourcePath()) end

--- Full path of the test folder (with the system separator), or nil if none is chosen yet. Stored relative to the
--- REAPER config when possible, so it works with different kDrive drive letters.
function H.test_folder()
  local stored = reaper.GetExtState(H.EXT_SECTION, H.KEY_FOLDER)
  if stored == "" then return nil end
  local absolute = stored:match("^%a:") or stored:match("^/")
  local full = absolute and stored or (H.config_dir() .. "/" .. stored)
  return (SelfTest.normalize(full):gsub("/", H.sep))
end

--- All files below dir (recursive, fresh listing), full paths with the system separator.
function H.all_files(dir)
  local out = {}
  for _, rel in ipairs(SelfTest.list_files(dir)) do out[#out + 1] = dir .. H.sep .. rel:gsub("/", H.sep) end
  return out
end

--- The .rpp files directly in dir (not in subfolders), sorted by name (case ignored): the setlist order.
function H.rpp_files(dir)
  local files = {}
  for _, rel in ipairs(SelfTest.list_files(dir, ".rpp")) do
    if not rel:find("/", 1, true) then files[#files + 1] = rel end
  end
  table.sort(files, function(x, y) return x:lower() < y:lower() end)
  return files
end

-- Actions ------------------------------------------------------------------------------------------

function H.run(cmd) reaper.Main_OnCommand(cmd, 0) end

--- Command ID of a package script by its file ("Transport/x.lua"). Fails with the reason.
function H.script_cmd(file)
  local cmd, err = Actions.file_command(file)
  if not cmd then error("script not found: " .. file .. " (" .. tostring(err) .. ")", 0) end
  return cmd
end

--- Runs a script of Actions.SCRIPTS ("mode", ...).
function H.run_script(id)
  local cmd, err = Actions.script_command(id)
  if not cmd then error(err, 0) end
  reaper.Main_OnCommand(cmd, 0)
end

--- A custom action by its name: command ID and named ID ("_ee13..."; what action markers contain). Fails with the
--- reason.
function H.custom(name)
  local cmd, err = General.find_custom(name)
  if not cmd then error(err, 0) end
  return cmd, "_" .. reaper.ReverseNamedCommandLookup(cmd)
end

-- Projects ------------------------------------------------------------------------------------------

--- Open projects: { { proj, file } } in tab order (file is "" for an unsaved project).
function H.projects()
  local list, i = {}, 0
  while true do
    local proj, file = reaper.EnumProjects(i)
    if not proj then return list end
    list[#list + 1] = { proj = proj, file = file or "" }
    i = i + 1
  end
end

function H.name_of(proj) return proj and reaper.GetProjectName(proj) or "(none)" end
function H.active() return (reaper.EnumProjects(-1)) end
function H.playing(proj) return reaper.GetPlayStateEx(proj) & 1 == 1 end
function H.near(a, b) return math.abs(a - b) <= H.TOLERANCE end
function H.valid(proj) return proj and reaper.ValidatePtr(proj, "ReaProject*") end

function H.find_projects()
  H.routing, H.songs = nil, {}
  for _, p in ipairs(H.projects()) do
    if H.name_of(p.proj):find("ROUTING", 1, true) then H.routing = p.proj else H.songs[#H.songs + 1] = p.proj end
  end
end

--- Stops every project except the routing project and the active song: only what the next step needs plays,
--- so the transport shows at a glance whether the test runs correctly.
function H.keep_only_needed_playing()
  local keep = H.active()
  for _, p in ipairs(H.projects()) do
    if p.proj ~= H.routing and p.proj ~= keep then reaper.Main_OnCommandEx(H.STOP, 0, p.proj) end
  end
end

function H.stop_all()
  for _, p in ipairs(H.projects()) do reaper.Main_OnCommandEx(H.STOP, 0, p.proj) end
end

--- Where a song starts: the "=START" marker, otherwise the project start (as "Move edit cursor to project start
--- respecting time 0 and start marker" does).
function H.song_start(proj)
  local start = reaper.GetProjectTimeOffset(proj, false)
  local i = 0
  while true do
    local rv, isrgn, pos, _, name = reaper.EnumProjectMarkers2(proj, i)
    if rv == 0 then return start end
    if not isrgn and name == "=START" then return pos end
    i = i + 1
  end
end

-- Check rows shared by several steps ----------------------------------------------------------------

function H.is_active(proj, label)
  return { name = ("active project is %s (is: %s)"):format(label, H.name_of(H.active())), ok = H.active() == proj }
end

function H.is_recording(proj, label, expected)
  return { name = ("%s %s"):format(label, expected and "is recording" or "is not recording"),
    ok = (reaper.GetPlayStateEx(proj) & 4 == 4) == expected }
end

function H.is_playing(proj, label, expected)
  return { name = ("%s %s"):format(label, expected and "is playing" or "is stopped"), ok = H.playing(proj) == expected }
end

--- from_marker: plays from =START; otherwise from the very beginning (0).
function H.plays_from(proj, label, from_marker)
  local from = from_marker and H.song_start(proj) or 0
  local pos = reaper.GetPlayPositionEx(proj)
  return { name = ("%s plays from %s (%.2f s, play position %.2f s, play state %d)"):format(label,
      from_marker and "=START" or "the very beginning", from, pos, reaper.GetPlayStateEx(proj)),
    ok = H.playing(proj) and pos >= from - H.TOLERANCE and pos <= from + H.PLAY_WINDOW }
end

return H
