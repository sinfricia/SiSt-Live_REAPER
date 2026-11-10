-- @noindex
-- SiSt-Live mode effect: show protection through the mouse modifiers. In show mode the mouse actions that
-- select, move, edit or draw a time selection are switched off, so a stray click on stage can't change anything.
--
-- The "edit" state is simply what REAPER's Preferences > Mouse Modifiers say at the moment of the switch. Nothing
-- else is stored for it:
--   block   (show mode): saves the current assignments of the blocked contexts to ONE small file
--           (Data/SiSt-Live/mouse-edit-state.txt), then sets every key combination of those contexts to "No action".
--   restore (edit mode): puts the saved assignments back and deletes the file.
-- The file means "the mouse modifiers are blocked right now". It is written BEFORE anything is blocked and never
-- overwritten while it exists, so a second switch to show can't save the blocked state as the edit state. If REAPER
-- crashes or is closed in show mode, the next start applies edit mode (Scripts/__startup.lua) and restores from the
-- file. Change mouse modifiers in edit mode only: a change made to a blocked context in show mode is overwritten by
-- the restore.
--
-- What is blocked: Mouse.BLOCK below (all 16 key combinations of each context). The lane contexts, middle-drag
-- scrolling, the ruler / track / cursor-handle CLICKS (edit cursor) and the MIDI editor are left alone. To block
-- more or less, edit that list; a single key combination can be listed as { context, flag }.
--
-- Set in "SiSt-Live: Configure modes": "block" or "restore", empty = leave alone. Set SHOW to block and EDIT to
-- restore.
--
-- See SiSt-Live_ModeEffects.lua for the effect contract.

local Mouse = { name = "mouse" }

Mouse.SECTION    = "SiSt-Live"
Mouse.KEY_PREFIX = "mouse_" -- + mode. Value: "block", "restore", "" = none

Mouse.NO_ACTION = "No action" -- REAPER's unlocalized name; GetMouseModifier then returns "0"
Mouse.BLOCKED   = "0"

-- Contexts to block, in the order they are changed. A string = all 16 key combinations; { context, flag } = one.
Mouse.BLOCK = {
  "MM_CTX_ITEM", "MM_CTX_ITEM_CLK", "MM_CTX_ITEM_DBLCLK",
  "MM_CTX_ITEMEDGE", "MM_CTX_ITEMFADE", "MM_CTX_CROSSFADE",
  "MM_CTX_ITEMLOWER", "MM_CTX_ITEMLOWER_CLK", "MM_CTX_ITEMLOWER_DBLCLK",
  "MM_CTX_ENVLANE", "MM_CTX_ENVLANE_DBLCLK", "MM_CTX_ENVPT", "MM_CTX_ENVSEG", "MM_CTX_ENVSEG_DBLCLK",
  "MM_CTX_RULER",          -- left drag in the ruler: time selection, loop points
  "MM_CTX_TRACK",          -- left drag in empty track space: marquee, time selection
  "MM_CTX_ARRANGE_RMOUSE", -- right drag in the arrange view: marquee select
}

-- State file ------------------------------------------------------------
local state_path_override = nil

--- Where the saved edit state lives. Tests point it somewhere else; nil = the default.
function Mouse.set_state_path(path) state_path_override = path end

function Mouse.state_path()
  if state_path_override then return state_path_override end
  local sep = package.config:sub(1, 1)
  return reaper.GetResourcePath() .. sep .. "Data" .. sep .. "SiSt-Live" .. sep .. "mouse-edit-state.txt"
end

local function ensure_dir()
  if state_path_override then return end
  local sep = package.config:sub(1, 1)
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. sep .. "Data" .. sep .. "SiSt-Live", 0)
end

--- The slots to handle: { { context, flag }, ... }, in order.
function Mouse.slots()
  local slots = {}
  for _, entry in ipairs(Mouse.BLOCK) do
    if type(entry) == "table" then
      slots[#slots + 1] = { entry[1], entry[2] }
    else
      for flag = 0, 15 do slots[#slots + 1] = { entry, flag } end
    end
  end
  return slots
end

--- Pure. Slot values -> file text. Lines "context<TAB>flag<TAB>value".
function Mouse.encode(saved)
  local lines = {}
  for _, s in ipairs(saved) do lines[#lines + 1] = ("%s\t%d\t%s"):format(s.context, s.flag, s.value) end
  return table.concat(lines, "\n") .. "\n"
end

--- Pure. File text -> { { context, flag, value }, ... }, or nil + reason if the text is not a saved state.
function Mouse.decode(text)
  local saved = {}
  for line in (text or ""):gmatch("([^\r\n]+)") do
    local context, flag, value = line:match("^([^\t]+)\t(%d+)\t(.*)$")
    if not context then return nil, "unreadable line: " .. line end
    saved[#saved + 1] = { context = context, flag = tonumber(flag), value = value }
  end
  if #saved == 0 then return nil, "empty file" end
  return saved
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

--- True while the mouse modifiers are blocked (the state file exists).
function Mouse.is_blocked()
  local f = io.open(Mouse.state_path(), "rb")
  if f then f:close() return true end
  return false
end

-- Assignments -----------------------------------------------------------
--- "block", "restore" or nil (none).
function Mouse.get_assignment(mode)
  local v = reaper.GetExtState(Mouse.SECTION, Mouse.KEY_PREFIX .. mode)
  if v == "block" or v == "restore" then return v end
  return nil
end

function Mouse.set_assignment(mode, value)
  reaper.SetExtState(Mouse.SECTION, Mouse.KEY_PREFIX .. mode, value or "", true) -- persistent
end

--- Pure. Field text -> "block" / "restore" / "none", or nil + error.
function Mouse.parse(input)
  local s = (input or ""):lower():match("^%s*(.-)%s*$")
  if s == "" then return "none" end
  if s == "block" or s == "restore" then return s end
  return nil, ("'%s' is not 'block' or 'restore'"):format(input)
end

-- Arrow cursor ------------------------------------------------------------
-- While the mouse modifiers are blocked, the arrange view shows the plain arrow, so it is clear that clicks and
-- drags there do nothing. REAPER sets its own cursor on every mouse move, so setting the arrow alone flickers: the
-- message that makes a window change its cursor (WM_SETCURSOR) is blocked on the arrange view for as long as the
-- arrow script runs, and the arrow is set while the mouse is inside. Needs the js_ReaScriptAPI extension. Written
-- for Windows: the arrow handle is a Windows cursor number, and on macOS / Linux the script ends without doing
-- anything if it can't be loaded.
--
-- The script "SiSt-Live: Lock mouse cursor to arrow in arrange view" (Modes/) runs the loop; the effect starts it
-- after it blocked the mouse modifiers. It ends by itself as soon as the mouse is no longer blocked (the state file
-- is gone) and always gives the arrange view its cursor messages back, also when it ends in any other way.
Mouse.ARROW_SECTION      = "SiSt-Live"
Mouse.ARROW_KEY_BEAT     = "mouse_arrow_beat" -- heartbeat (os.time), not persisted
Mouse.ARROW_BEAT_MAX_AGE = 3                  -- seconds: an older heartbeat means "not running"
Mouse.ARROW_CURSOR       = 32512              -- IDC_ARROW (Windows predefined cursor)
Mouse.ARRANGE_ID         = 1000               -- control ID of the arrange view in REAPER's main window
Mouse.ARROW_MESSAGE      = "WM_SETCURSOR"

--- true if the arrow script is running (its heartbeat is fresh).
function Mouse.arrow_is_running()
  local beat = tonumber(reaper.GetExtState(Mouse.ARROW_SECTION, Mouse.ARROW_KEY_BEAT))
  return beat ~= nil and os.time() - beat < Mouse.ARROW_BEAT_MAX_AGE
end

--- Starts an arrow controller for the script's loop. is_blocked(): true while the mouse modifiers are blocked.
--- Returns the controller (.step(), .release()), or nil + reason if it can't work here.
function Mouse.arrow_create(is_blocked)
  if not reaper.APIExists("JS_WindowMessage_Intercept") then
    return nil, "the js_ReaScriptAPI extension is missing"
  end
  local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), Mouse.ARRANGE_ID)
  if not arrange then return nil, "the arrange view was not found" end
  local arrow = reaper.JS_Mouse_LoadCursor(Mouse.ARROW_CURSOR)
  if not arrow then return nil, "the arrow cursor could not be loaded (Windows cursor number)" end

  local self = { blocking = false, last_beat = 0 }

  --- Gives the arrange view its cursor messages back and removes the heartbeat. Safe to call more than once.
  function self.release()
    if self.blocking then
      reaper.JS_WindowMessage_Release(arrange, Mouse.ARROW_MESSAGE)
      self.blocking = false
    end
    reaper.DeleteExtState(Mouse.ARROW_SECTION, Mouse.ARROW_KEY_BEAT, false)
  end

  --- One cycle. Returns true to go on, or false and a reason when it is finished. Never leaves the block on when
  --- it returns false.
  function self.step()
    if not is_blocked() then
      self.release()
      return false, "the mouse modifiers are no longer blocked"
    end

    local now = os.time()
    if now ~= self.last_beat then
      self.last_beat = now
      reaper.SetExtState(Mouse.ARROW_SECTION, Mouse.ARROW_KEY_BEAT, tostring(now), false)
    end

    if not self.blocking then
      if reaper.JS_WindowMessage_Intercept(arrange, Mouse.ARROW_MESSAGE, false) ~= 1 then -- false = block it
        self.release()
        return false, "the cursor messages of the arrange view could not be blocked (another script has them?)"
      end
      self.blocking = true
    end

    local x, y = reaper.GetMousePosition()
    if reaper.JS_Window_FromPoint(x, y) == arrange then reaper.JS_Mouse_SetCursor(arrow) end
    return true
  end

  return self
end

--- Starts the arrow script unless it already runs. Tests replace this function. Returns nil, or a short note if it
--- could not be started: the mouse modifiers are blocked anyway, only the arrow is missing.
function Mouse.start_arrow_script()
  if Mouse.arrow_is_running() then return nil end
  local cmd, why = require("SiSt-Live_Actions").script_command("arrow")
  if not cmd then return "arrow cursor script not started: " .. tostring(why) end
  reaper.Main_OnCommand(cmd, 0)
  return nil
end

-- Effect ----------------------------------------------------------------
local function block()
  local slots = Mouse.slots()
  local saved_now = false

  if not Mouse.is_blocked() then
    -- Save first. Nothing is blocked unless the saved state is on disk and reads back correctly.
    local saved = {}
    for i, s in ipairs(slots) do
      saved[i] = { context = s[1], flag = s[2], value = reaper.GetMouseModifier(s[1], s[2]) }
    end
    local text = Mouse.encode(saved)
    ensure_dir()
    local f, err = io.open(Mouse.state_path(), "wb")
    if not f then error("can't save the mouse modifiers, nothing blocked: " .. tostring(err), 0) end
    local ok, werr = f:write(text)
    f:close()
    if not ok or read_file(Mouse.state_path()) ~= text then
      os.remove(Mouse.state_path())
      error("can't save the mouse modifiers, nothing blocked: " .. tostring(werr or "file does not read back"), 0)
    end
    saved_now = true
  end

  local changed = 0
  for _, s in ipairs(slots) do
    if reaper.GetMouseModifier(s[1], s[2]) ~= Mouse.BLOCKED then changed = changed + 1 end
    reaper.SetMouseModifier(s[1], s[2], Mouse.NO_ACTION)
  end

  local ok_start, note = pcall(Mouse.start_arrow_script)
  if not ok_start then note = "arrow cursor script not started: " .. tostring(note) end
  note = note and (", " .. note) or ""

  if not saved_now and changed == 0 then return "skipped", "already blocked" .. note end
  return "ok", ("blocked %d mouse modifier slots (edit state saved%s)%s"):format(
    #slots, saved_now and "" or " earlier", note)
end

local function restore()
  local text = read_file(Mouse.state_path())
  if not text then return "skipped", "nothing to restore (not blocked)" end
  local saved, why = Mouse.decode(text)
  if not saved then error("saved mouse modifiers are unreadable, file kept: " .. why, 0) end

  for _, s in ipairs(saved) do
    if s.value == "" then
      reaper.SetMouseModifier(s.context, s.flag, -1) -- was the default
    else
      reaper.SetMouseModifier(s.context, s.flag, s.value)
    end
  end
  os.remove(Mouse.state_path())
  return "ok", ("restored %d mouse modifier slots"):format(#saved)
end

function Mouse.apply(mode)
  local want = Mouse.get_assignment(mode)
  if want == nil then
    return "skipped", ("no mouse setting for %s mode"):format(mode)
  end
  if want == "block" then return block() end
  return restore()
end

-- Settings --------------------------------------------------------------
-- Field text: "block" or "restore", empty = leave alone.
Mouse.settings = {
  {
    label  = "mouse",
    get    = function(mode) return Mouse.get_assignment(mode) end,
    format = function(v) return v or "" end,
    parse  = function(text)
      local v, err = Mouse.parse(text)
      if v == nil then return false, "mouse: " .. err end
      if v == "none" then return true, nil end
      return true, v
    end,
    set    = function(mode, v) Mouse.set_assignment(mode, v) end,
  },
}

-- Diagnostics & self-test -----------------------------------------------
function Mouse.diagnostics()
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    rows[#rows + 1] = { mode .. " mouse", Mouse.get_assignment(mode) or "(none)" }
  end
  rows[#rows + 1] = { "mouse modifiers blocked now", Mouse.is_blocked() and "yes (edit state saved)" or "no" }
  rows[#rows + 1] = { "blocked slots", tostring(#Mouse.slots()) }
  return rows
end

--- Self-test of the arrow cursor. Fake window functions: never touches the real arrange view.
function Mouse.arrow_self_test()
  local with_reaper = require("SelfTest").with_reaper
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local function fake(opts)
    opts = opts or {}
    local log = { intercepts = 0, releases = 0, cursors = 0 }
    local fakes = {
      APIExists = function() return not opts.no_extension end,
      GetMainHwnd = function() return "main" end,
      JS_Window_FindChildByID = function() return (not opts.no_arrange) and "arrange" or nil end,
      JS_Mouse_LoadCursor = function() return (not opts.no_arrow) and "arrow" or nil end,
      JS_WindowMessage_Intercept = function() log.intercepts = log.intercepts + 1; return opts.intercept_result or 1 end,
      JS_WindowMessage_Release = function() log.releases = log.releases + 1 end,
      GetMousePosition = function() return 10, 10 end,
      JS_Window_FromPoint = function() return opts.under_mouse or "arrange" end,
      JS_Mouse_SetCursor = function() log.cursors = log.cursors + 1 end,
    }
    return fakes, log
  end

  local blocked = true
  local function is_blocked() return blocked end

  for _, case in ipairs({
    { "no extension", { no_extension = true } },
    { "no arrange view", { no_arrange = true } },
    { "no arrow cursor", { no_arrow = true } },
  }) do
    local fakes, log = fake(case[2])
    local c, why = with_reaper(fakes, Mouse.arrow_create, is_blocked)
    check("arrow: " .. case[1] .. " -> nothing created, with a reason, nothing blocked",
      c == nil and type(why) == "string" and log.intercepts == 0)
  end

  -- running: the block is set once, the arrow only while the mouse is over the arrange view
  local fakes, log = fake()
  local c = with_reaper(fakes, Mouse.arrow_create, is_blocked)
  with_reaper(fakes, c.step); with_reaper(fakes, c.step); with_reaper(fakes, c.step)
  check("arrow: cursor messages blocked once, arrow set every cycle over the arrange view",
    log.intercepts == 1 and log.cursors == 3 and log.releases == 0)
  check("arrow: heartbeat written, arrow_is_running sees it", with_reaper(fakes, Mouse.arrow_is_running))

  local outside, outside_log = fake({ under_mouse = "tcp" })
  local c2 = with_reaper(outside, Mouse.arrow_create, is_blocked)
  with_reaper(outside, c2.step)
  check("arrow: mouse outside the arrange view -> no arrow set", outside_log.cursors == 0)

  -- the mouse modifiers are restored: finished, block released exactly once, heartbeat gone
  blocked = false
  local more, why = with_reaper(fakes, c.step)
  with_reaper(fakes, c.release) -- the script's exit handler calls release again
  check("arrow: no longer blocked -> finished, cursor messages given back once",
    more == false and why ~= nil and log.releases == 1)
  check("arrow: heartbeat removed when finished", not with_reaper(fakes, Mouse.arrow_is_running))

  -- another script has the cursor messages: finish without leaving anything blocked
  blocked = true
  local taken, taken_log = fake({ intercept_result = 0 })
  local c3 = with_reaper(taken, Mouse.arrow_create, is_blocked)
  local more3 = with_reaper(taken, c3.step)
  check("arrow: block refused -> finished, nothing to release", more3 == false and taken_log.releases == 0)

  -- a stale heartbeat does not count as running
  with_reaper(fake(), function()
    reaper.SetExtState(Mouse.ARROW_SECTION, Mouse.ARROW_KEY_BEAT, tostring(os.time() - 60), false)
    check("arrow: an old heartbeat means not running", not Mouse.arrow_is_running())
  end)

  return results
end

--- Built-in self-test. Fake mouse modifiers and a temporary state file: never touches the real mouse settings.
function Mouse.self_test()
  local with_reaper = require("SelfTest").with_reaper
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local sep = package.config:sub(1, 1)
  local tmp = reaper.GetResourcePath() .. sep .. "SiSt-Live_mousetest_" .. os.time() .. ".txt"
  Mouse.set_state_path(tmp)
  local real_starter, started = Mouse.start_arrow_script, 0
  Mouse.start_arrow_script = function() started = started + 1 end -- the real one would run a REAPER action

  -- A fake REAPER: slot values in a table; "No action" reads back as "0", -1 resets to the default ("")
  local function fake()
    local store, sets = {}, {}
    local fakes = {
      GetMouseModifier = function(c, f) return store[c .. ":" .. f] or "" end,
      SetMouseModifier = function(c, f, v)
        sets[#sets + 1] = c .. ":" .. f
        if v == Mouse.NO_ACTION then v = "0" elseif v == -1 then v = "" end
        store[c .. ":" .. f] = v
      end,
    }
    return fakes, store, sets
  end
  local function snapshot(store)
    local t = {}
    for _, s in ipairs(Mouse.slots()) do t[#t + 1] = s[1] .. ":" .. s[2] .. "=" .. (store[s[1] .. ":" .. s[2]] or "") end
    return table.concat(t, "|")
  end

  local fakes, store, sets = fake()
  -- some edit assignments: custom actions, a mouse modifier, and untouched defaults ("")
  store["MM_CTX_ITEM:0"], store["MM_CTX_ITEM:2"] = "28 m", "1 m"
  store["MM_CTX_ITEM_CLK:4"] = "40290 c"
  store["MM_CTX_ITEM_DBLCLK:10"] = "_XENAKIOS_RESETTAKEVOL"
  store["MM_CTX_RULER:3"] = "4 m"
  local edit_state = snapshot(store)

  check("parse: block / restore / empty / garbage",
    Mouse.parse("Block") == "block" and Mouse.parse(" restore ") == "restore" and Mouse.parse("") == "none"
    and Mouse.parse("maybe") == nil)

  local round = Mouse.decode(Mouse.encode({ { context = "MM_CTX_ITEM", flag = 4, value = "_ext id with spaces" },
    { context = "MM_CTX_RULER", flag = 0, value = "" } }))
  check("state text round trip keeps spaces and empty values",
    round and #round == 2 and round[1].value == "_ext id with spaces" and round[2].value == "" and round[2].flag == 0)
  check("state text: garbage and empty are rejected", Mouse.decode("garbage") == nil and Mouse.decode("") == nil)

  check("apply: nothing assigned -> skipped, nothing touched",
    (with_reaper(fakes, Mouse.apply, "show")) == "skipped" and #sets == 0 and not Mouse.is_blocked())

  with_reaper(fakes, Mouse.set_assignment, "show", "block")
  with_reaper(fakes, Mouse.set_assignment, "edit", "restore")

  local result = with_reaper(fakes, Mouse.apply, "show")
  local all_blocked = true
  for _, s in ipairs(Mouse.slots()) do
    if store[s[1] .. ":" .. s[2]] ~= Mouse.BLOCKED then all_blocked = false end
  end
  check("block: state saved first, then every blocked slot is set to no action",
    result == "ok" and Mouse.is_blocked() and all_blocked)
  check("block: the arrow script is started", started == 1)
  check("block: lanes, scrolling and the MIDI editor are not in the list", (function()
    for _, s in ipairs(Mouse.slots()) do
      if s[1]:find("LINKEDLANE", 1, true) or s[1]:find("FIXEDLANE", 1, true) or s[1]:find("MIDI", 1, true)
          or s[1]:find("MMOUSE", 1, true) then return false end
    end
    return true
  end)())

  local second = with_reaper(fakes, Mouse.apply, "show")
  check("block twice: reported as already blocked, the arrow script is looked after again",
    second == "skipped" and started == 2)
  local restored = with_reaper(fakes, Mouse.apply, "edit")
  check("restore: every slot is exactly as before, even after blocking twice (the saved state was not overwritten)",
    restored == "ok" and snapshot(store) == edit_state)
  check("restore: the state file is gone", not Mouse.is_blocked())
  check("restore again: nothing to do", (with_reaper(fakes, Mouse.apply, "edit")) == "skipped")

  -- a crash in show mode: the state file stays, the next edit-mode run restores it
  with_reaper(fakes, Mouse.apply, "show")
  local next_start_fakes, next_store = fake()
  for k, v in pairs(store) do next_store[k] = v end -- REAPER saved the blocked settings
  with_reaper(next_start_fakes, Mouse.set_assignment, "edit", "restore")
  with_reaper(next_start_fakes, Mouse.apply, "edit")
  check("restore after a restart in show mode: the saved state is put back", snapshot(next_store) == edit_state)

  -- an arrow script that can't be started doesn't fail the block
  local starter_fakes, starter_store = fake()
  with_reaper(starter_fakes, Mouse.set_assignment, "show", "block")
  Mouse.start_arrow_script = function() error("no such script", 0) end
  local starter_result, starter_msg = with_reaper(starter_fakes, Mouse.apply, "show")
  Mouse.start_arrow_script = function() return "arrow cursor script not started: not installed" end
  os.remove(tmp)
  local note_result, note_msg = with_reaper(starter_fakes, Mouse.apply, "show")
  os.remove(tmp)
  check("block: an arrow script that fails to start is only mentioned, the block still works",
    starter_result == "ok" and starter_msg:find("arrow cursor script not started", 1, true) ~= nil
    and note_result == "ok" and note_msg:find("not installed", 1, true) ~= nil
    and starter_store["MM_CTX_ITEM:0"] == Mouse.BLOCKED)

  -- unreadable state file: nothing is changed, the file is kept
  local f = io.open(tmp, "wb"); f:write("garbage\n"); f:close()
  local bad_fakes, _, bad_sets = fake()
  with_reaper(bad_fakes, Mouse.set_assignment, "edit", "restore")
  check("restore: unreadable file fails, changes nothing, file kept",
    not pcall(with_reaper, bad_fakes, Mouse.apply, "edit") and #bad_sets == 0 and Mouse.is_blocked())
  os.remove(tmp)

  -- the file can't be saved: nothing is blocked
  Mouse.set_state_path(sep .. "selftest-no-such-dir" .. sep .. "x.txt")
  local nosave, _, nosave_sets = fake()
  with_reaper(nosave, Mouse.set_assignment, "show", "block")
  check("block: if the state can't be saved, nothing is blocked",
    not pcall(with_reaper, nosave, Mouse.apply, "show") and #nosave_sets == 0)

  Mouse.start_arrow_script = real_starter
  Mouse.set_state_path(nil)
  os.remove(tmp)
  for _, r in ipairs(Mouse.arrow_self_test()) do results[#results + 1] = r end
  return results
end

return Mouse
