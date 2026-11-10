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

  if not saved_now and changed == 0 then return "skipped", "already blocked" end
  return "ok", ("blocked %d mouse modifier slots (edit state saved%s)"):format(
    #slots, saved_now and "" or " earlier")
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

--- Built-in self-test. Fake mouse modifiers and a temporary state file: never touches the real mouse settings.
function Mouse.self_test()
  local with_reaper = require("SelfTest").with_reaper
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local sep = package.config:sub(1, 1)
  local tmp = reaper.GetResourcePath() .. sep .. "SiSt-Live_mousetest_" .. os.time() .. ".txt"
  Mouse.set_state_path(tmp)

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
  check("block: lanes, scrolling and the MIDI editor are not in the list", (function()
    for _, s in ipairs(Mouse.slots()) do
      if s[1]:find("LINKEDLANE", 1, true) or s[1]:find("FIXEDLANE", 1, true) or s[1]:find("MIDI", 1, true)
          or s[1]:find("MMOUSE", 1, true) then return false end
    end
    return true
  end)())

  local second = with_reaper(fakes, Mouse.apply, "show")
  check("block twice: reported as already blocked", second == "skipped")
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

  Mouse.set_state_path(nil)
  os.remove(tmp)
  return results
end

return Mouse
