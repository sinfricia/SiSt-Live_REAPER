-- @noindex
-- SiSt-Live toolbar source: which native REAPER toolbar the show toolbar copies, and reading it.
--
-- The show toolbar (Show Toolbar/SiSt-Live_Show Toolbar.lua) draws its own big buttons, but WHICH
-- buttons, in which order, comes from a native floating toolbar. You edit that toolbar in REAPER as
-- usual (right-click a toolbar > Customize toolbar...); the show toolbar copies it.
--
-- Settings ("Toolbar settings" dialog: right-click the show toolbar, or its button when no toolbar
-- is set): per mode the number of the floating toolbar (1-32, empty = none). The button size is not a
-- setting: the show toolbar sizes its buttons to fill its window. It shows the toolbar of the current mode.
--
-- Where the buttons come from: REAPER stores customized toolbars in <resource path>/reaper-menu.ini,
-- in a section "[Floating toolbar N]":
--   title=My show buttons
--   item_0=40044 Transport: Play/stop        command ID (number or named "_RS..."/"_SWS...") + text
--   item_1=-1                                separator
-- A toolbar you never customized is not in that file: customize it once (add a button) first.
-- REAPER writes the file when you close the Customize dialog with OK.
--
-- This library only reads (no gfx): the window is in the component.
-- Self test: Toolbar.self_test() returns a list of { name, ok }. Uses a fake REAPER api.

local Toolbar = {}

Toolbar.SECTION    = "SiSt-Live"
Toolbar.KEY_PREFIX = "toolbar_" -- + mode. Value: toolbar number, "" = none
Toolbar.MAX_NUMBER = 32         -- REAPER 7 has floating toolbars 1-32
Toolbar.INI_FILE   = "reaper-menu.ini"
Toolbar.MODES      = { "show", "edit" }


-- Pure functions ------------------------------------------------------------------

function Toolbar.section_name(number)
  return "Floating toolbar " .. number
end

--- Parses the number typed into the settings dialog. Returns the number, false for empty (none),
--- or nil + error message.
function Toolbar.parse_number(input)
  local s = (input or ""):match("^%s*(.-)%s*$")
  if s == "" then return false end
  local n = tonumber(s)
  if not n or n ~= math.floor(n) or n < 1 or n > Toolbar.MAX_NUMBER then
    return nil, ("'%s' is not a floating toolbar number (1-%d)"):format(input, Toolbar.MAX_NUMBER)
  end
  return n
end

--- Reads one section of reaper-menu.ini. Returns { title, items = { { cmd = "40044", text = "..." }
--- or { separator = true } } } in toolbar order, or nil if the section isn't in the text.
function Toolbar.parse_ini(text, section)
  local result, in_section = nil, false
  local items = {}
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      if in_section then break end
      in_section = header == section
      if in_section then result = { title = nil, items = {} } end
    elseif in_section then
      local key, value = line:match("^%s*([%w_]+)%s*=(.*)$")
      if key == "title" then
        result.title = value
      elseif key then
        local index = tonumber(key:match("^item_(%d+)$"))
        if index then
          local cmd, label = value:match("^%s*(%S+)%s*(.-)%s*$")
          if cmd and tonumber(cmd) and tonumber(cmd) < 0 then
            items[index] = { separator = true }
          elseif cmd then
            items[index] = { cmd = cmd, text = label }
          end
        end
      end
    end
  end
  if not result then return nil end
  -- items in index order (item_0, item_1, ...), gaps skipped
  local indexes = {}
  for i in pairs(items) do indexes[#indexes + 1] = i end
  table.sort(indexes)
  for _, i in ipairs(indexes) do result.items[#result.items + 1] = items[i] end
  return result
end

--- Button text: the toolbar's own text, else the action name without its "Category: " prefix.
--- REAPER stores the action name as the text of buttons you didn't rename: that is shortened too.
function Toolbar.button_label(text, action_name)
  if text and text ~= "" and text ~= action_name then return text end
  if not action_name or action_name == "" then return "?" end
  return (action_name:gsub("^Script:%s*", ""):gsub("^[^:]+:%s+", "", 1))
end

-- Settings --------------------------------------------------------------------------

--- Floating toolbar number of a mode, or nil.
function Toolbar.get_assignment(mode, api)
  api = api or reaper
  return tonumber(api.GetExtState(Toolbar.SECTION, Toolbar.KEY_PREFIX .. mode))
end

function Toolbar.set_assignment(mode, number, api)
  api = api or reaper
  api.SetExtState(Toolbar.SECTION, Toolbar.KEY_PREFIX .. mode, number and tostring(number) or "", true)
end

-- Settings dialog ---------------------------------------------------------------------
-- REAPER's native text dialog for now (a GUI dialog can replace it later: the fields below stay).

Toolbar.DIALOG_TITLE = "SiSt-Live toolbar settings (empty = none)"
Toolbar.DIALOG_CAPTIONS = "SHOW toolbar (1-32),EDIT toolbar (1-32)"

--- The dialog's field texts from the stored settings.
function Toolbar.dialog_texts(api)
  local show, edit = Toolbar.get_assignment("show", api), Toolbar.get_assignment("edit", api)
  return { show and tostring(show) or "", edit and tostring(edit) or "" }
end

--- Checks the typed texts. Returns values ({ show, edit }, false = none) or nil + errors.
function Toolbar.parse_dialog(texts)
  local values, errors = {}, {}
  local function take(i, value, err)
    if value == nil then errors[#errors + 1] = err else values[i] = value end
  end
  for i, mode in ipairs(Toolbar.MODES) do
    local n, err = Toolbar.parse_number(texts[i])
    take(i, n, err and (mode:upper() .. " toolbar: " .. err))
  end
  if #errors > 0 then return nil, errors end
  return values
end

function Toolbar.store_dialog(values, api)
  Toolbar.set_assignment("show", values[1] or nil, api)
  Toolbar.set_assignment("edit", values[2] or nil, api)
end

--- Shows the dialog until the input is valid or cancelled. Returns true if settings were stored.
function Toolbar.configure(api)
  api = api or reaper
  local texts = Toolbar.dialog_texts(api)
  while true do
    local ok, result = api.GetUserInputs(Toolbar.DIALOG_TITLE, 2, Toolbar.DIALOG_CAPTIONS .. ",extrawidth=60",
      table.concat(texts, ","))
    if not ok then return false end
    texts = {}
    for part in (result .. ","):gmatch("(.-),") do texts[#texts + 1] = part end
    local values, errors = Toolbar.parse_dialog(texts)
    if values then
      Toolbar.store_dialog(values, api)
      return true
    end
    api.MB("Please fix:\n\n" .. table.concat(errors, "\n"), "SiSt-Live toolbar settings", 0)
  end
end

-- Loading -----------------------------------------------------------------------------

function Toolbar.ini_path(api)
  return api.GetResourcePath() .. package.config:sub(1, 1) .. Toolbar.INI_FILE
end

--- Reads the toolbar of a mode. Returns a toolbar, or nil + a message to show instead.
--- ini_path: optional, another menu file (tests).
--- toolbar = { number, title, buttons = { { cmd (number), label } or { separator = true }, ... },
---             missing = { "text", ... } (buttons whose action doesn't exist: shown disabled) }
function Toolbar.load(mode, api, ini_path)
  api = api or reaper
  local number = Toolbar.get_assignment(mode, api)
  if not number then
    return nil, ("No toolbar set for %s mode."):format(mode:upper())
  end

  local f = io.open(ini_path or Toolbar.ini_path(api), "rb")
  local text = f and f:read("a")
  if f then f:close() end
  local section = Toolbar.section_name(number)
  local parsed = text and Toolbar.parse_ini(text, section)
  if not parsed then
    return nil, ("%s is not customized yet.\nCustomize it in REAPER (add a button), then Reload."):format(section)
  end

  local toolbar = { number = number, title = parsed.title or section, buttons = {}, missing = {} }
  for _, item in ipairs(parsed.items) do
    if item.separator then
      toolbar.buttons[#toolbar.buttons + 1] = { separator = true }
    else
      local cmd = tonumber(item.cmd) or api.NamedCommandLookup(item.cmd)
      if not cmd or cmd == 0 then
        toolbar.missing[#toolbar.missing + 1] = item.cmd
        toolbar.buttons[#toolbar.buttons + 1] = { cmd = nil, label = Toolbar.button_label(item.text, item.cmd) }
      else
        toolbar.buttons[#toolbar.buttons + 1] = { cmd = cmd,
          label = Toolbar.button_label(item.text, api.kbd_getTextFromCmd(cmd, 0)) }
      end
    end
  end
  return toolbar
end

-- Diagnostics & self test --------------------------------------------------------------

function Toolbar.diagnostics(api)
  api = api or reaper
  local rows = {}
  for _, mode in ipairs({ "show", "edit" }) do
    local n = Toolbar.get_assignment(mode, api)
    local value = n and Toolbar.section_name(n) or "(none)"
    if n then
      local tb, problem = Toolbar.load(mode, api)
      value = value .. (tb and (": %d buttons%s"):format(#tb.buttons,
        #tb.missing > 0 and (", missing actions: " .. table.concat(tb.missing, ", ")) or "")
        or (": " .. problem:gsub("\n", " ")))
    end
    rows[#rows + 1] = { mode .. " toolbar", value }
  end
  rows[#rows + 1] = { "menu file", Toolbar.ini_path(api) }
  return rows
end

function Toolbar.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local ini = table.concat({
    "[Main toolbar]", "item_0=1007 Transport: Play",
    "[Floating toolbar 3]", "title=Show", "item_1=-1", "item_0=40044 Transport: Play/stop",
    "item_2=_RS1234 My script", "icon_0=play.png", "item_10=1016",
    "[Floating toolbar 4]", "item_0=1",
  }, "\r\n")

  local tb = Toolbar.parse_ini(ini, "Floating toolbar 3")
  check("parse: finds the section and title", tb and tb.title == "Show")
  check("parse: items in index order, gaps skipped", tb and #tb.items == 4 and tb.items[1].cmd == "40044"
    and tb.items[2].separator and tb.items[3].cmd == "_RS1234" and tb.items[4].cmd == "1016")
  check("parse: text kept, icons ignored", tb and tb.items[1].text == "Transport: Play/stop"
    and tb.items[3].text == "My script" and tb.items[4].text == "")
  check("parse: stops at the next section", tb and #tb.items == 4)
  check("parse: missing section gives nil", Toolbar.parse_ini(ini, "Floating toolbar 9") == nil
    and Toolbar.parse_ini(nil, "x") == nil)

  check("label: toolbar text first", Toolbar.button_label("Go!", "Transport: Play") == "Go!")
  check("label: text that is the action name is shortened",
    Toolbar.button_label("Transport: Play", "Transport: Play") == "Play")
  check("label: action name without category", Toolbar.button_label("", "Transport: Play/stop") == "Play/stop"
    and Toolbar.button_label(nil, "Script: SiSt-Live_Start Song.lua") == "SiSt-Live_Start Song.lua")
  check("label: unknown", Toolbar.button_label("", "") == "?")

  check("number: valid, empty, invalid", Toolbar.parse_number(" 16 ") == 16 and Toolbar.parse_number("") == false
    and Toolbar.parse_number("33") == nil and Toolbar.parse_number("1.5") == nil and Toolbar.parse_number("x") == nil)

  -- loading with a fake REAPER and a temporary menu file in the resource folder (removed again)
  local sep = package.config:sub(1, 1)
  local tmp = reaper.GetResourcePath() .. sep .. "SiSt-Live_toolbartest_" .. os.time() .. ".ini"
  local ext = {}
  local api = {
    GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
    SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
    GetResourcePath = function() return "unused" end,
    NamedCommandLookup = function(name) return name == "_RS1234" and 55000 or 0 end,
    kbd_getTextFromCmd = function(cmd)
      return ({ [1016] = "Transport: Stop", [40044] = "Transport: Play/stop" })[cmd] or ""
    end,
  }
  local none, msg = Toolbar.load("show", api)
  check("load: no toolbar set gives a message", none == nil and msg:find("No toolbar set", 1, true) ~= nil)

  Toolbar.set_assignment("show", 3, api)
  check("assignment stored", Toolbar.get_assignment("show", api) == 3 and Toolbar.get_assignment("edit", api) == nil)
  local missing_file, msg2 = Toolbar.load("show", api, tmp)
  check("load: no menu file gives a message", missing_file == nil and msg2:find("not customized", 1, true) ~= nil)

  local f = io.open(tmp, "wb")
  if f then
    f:write(ini:gsub("_RS1234 My script", "_RS1234 My script\r\nitem_3=_SWS_GONE Gone"))
    f:close()
    local loaded = Toolbar.load("show", api, tmp)
    check("load: text equal to the action name is shortened", loaded and loaded.buttons[1].label == "Play/stop")
    check("load: buttons resolved", loaded and loaded.buttons[1].cmd == 40044 and loaded.buttons[2].separator
      and loaded.buttons[3].cmd == 55000 and loaded.buttons[3].label == "My script")
    check("load: missing action is listed and has no command", loaded and loaded.missing[1] == "_SWS_GONE"
      and loaded.buttons[4].cmd == nil and loaded.buttons[4].label == "Gone")
    check("load: empty text uses the action name", loaded and loaded.buttons[5].label == "Stop")
    os.remove(tmp)
  else
    check("load: test file could be written", false)
  end

  -- settings dialog (without the dialog itself)
  local values = Toolbar.parse_dialog({ "16", "" })
  check("dialog: valid input", values and values[1] == 16 and values[2] == false)
  local bad, errors = Toolbar.parse_dialog({ "99", "x" })
  check("dialog: every error is reported", bad == nil and #errors == 2)
  Toolbar.store_dialog(values, api)
  check("dialog: stored and read back", Toolbar.get_assignment("show", api) == 16 and Toolbar.get_assignment("edit", api) == nil)
  local texts = Toolbar.dialog_texts(api)
  check("dialog: texts from the stored settings", texts[1] == "16" and texts[2] == "")

  return results
end

return Toolbar
