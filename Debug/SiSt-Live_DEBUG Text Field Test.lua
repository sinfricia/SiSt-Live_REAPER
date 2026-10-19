-- @noindex
-- SiSt-Live DEBUG: Text Field Test
-- A test window for the TextField widget (lib/Gui/TextField.lua). Not used by any component yet.
--
-- What to try:
--   - click a field, type (also ä, é, €), Backspace / Delete, arrows, Home / End
--   - Shift + arrows to select, Ctrl + arrows to jump words, Ctrl+Backspace to delete a word
--   - Ctrl+A, Ctrl+C / Ctrl+X / Ctrl+V (needs the SWS extension)
--   - Enter (submit), Esc (only reported, nothing changes), Tab (next field)
--   - double-click (select all), drag to select, click outside (the field loses focus)
--   - type more than fits: the text scrolls, nothing is drawn outside the box
--   - the first field opens focused with its text selected (select_all, like renaming an entry):
--     typing replaces it. A click only places the cursor. The second field takes at most 10 characters
-- Every event is listed in the window and logged ([TextFieldTest], with "DEBUG Toggle Logging" on).
-- Every key the window receives is logged too, with its raw gfx.getchar code: if something odd is
-- typed (e.g. a space you didn't type), the log shows which key produced it.
-- The self test result of the widget is shown at the top.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Theme = require("Gui.Theme")
local Window = require("Gui.Window")
local Widgets = require("Gui.Widgets")
local TextField = require("Gui.TextField")
local ok_log, Log = pcall(require, "SiSt-Live_Log")
local log = ok_log and Log.get("TextFieldTest") or nil

-- Self test of the widget
local passed, failed_names = 0, {}
for _, r in ipairs(TextField.self_test()) do
  if r.ok then passed = passed + 1 else failed_names[#failed_names + 1] = r.name end
end
local self_test_line = #failed_names == 0 and ("TextField self test: all %d passed"):format(passed)
    or ("TextField self test: %d FAILED: %s"):format(#failed_names, table.concat(failed_names, "; "))
if log then log:info("%s", self_test_line) end

local has_clipboard = reaper.APIExists("CF_GetClipboard")

local fields = {
  { label = "Name", field = TextField.new{ text = "Intro", placeholder = "Type a name", select_all = true } },
  { label = "Max 10", field = TextField.new{ placeholder = "At most 10 characters", max_length = 10,
    } },
}

local events = {}
local function add_event(text)
  table.insert(events, 1, os.date("%H:%M:%S ") .. text)
  if #events > 8 then table.remove(events) end
  if log then log:debug("%s", text) end
end

-- Raw key -> readable name for the log
local KEY_NAMES = {}
for name, code in pairs(TextField.KEY) do KEY_NAMES[code] = name end
local function describe_key(code)
  local c = TextField.char_of(code)
  return ("%d (%s)"):format(code, KEY_NAMES[code] or (c and ("'" .. c .. "'")) or "not a character")
end

local win = Window.new{
  name = "SiSt-Live_TextFieldTest",
  title = "SiSt-Live Text Field Test",
  defaults = { ww = 520, wh = 360 },
}
TextField.focus(win, fields[1].field) -- like renaming: the field opens with the cursor in it

win:run(function()
  for _, key in ipairs(win.chars) do
    if log then log:debug("key %s, ctrl %s, shift %s", describe_key(key), tostring(win.mouse.ctrl), tostring(win.mouse.shift)) end
  end
  gfx.clear = Theme.clear_color()
  local pad, row_h, label_w = 12, 32, 80
  local y = pad

  Widgets.text(self_test_line, pad, y, gfx.w - 2 * pad, 22,
    { size = 15, color = #failed_names == 0 and "ok" or "error" })
  y = y + 22
  Widgets.text("Clipboard (SWS): " .. (has_clipboard and "available" or "NOT available, Ctrl+C/X/V do nothing"),
    pad, y, gfx.w - 2 * pad, 20, { size = 14, color = "muted" })
  y = y + 28

  for i, entry in ipairs(fields) do
    Widgets.text(entry.label, pad, y, label_w, row_h, { size = 16 })
    local ev = TextField.draw(win, entry.field, pad + label_w, y, gfx.w - 2 * pad - label_w, row_h)
    local name = entry.label
    if ev.changed then add_event(name .. ": changed to '" .. entry.field.text .. "'") end
    if ev.submitted then add_event(name .. ": SUBMITTED '" .. entry.field.text .. "'") end
    if ev.escape then add_event(name .. ": Esc (text kept: '" .. entry.field.text .. "')") end
    if ev.blurred then add_event(name .. ": lost focus") end
    if ev.tab then
      local next_entry = fields[i % #fields + 1]
      TextField.focus(win, next_entry.field)
      add_event(name .. ": Tab -> " .. next_entry.label)
    end
    y = y + row_h + 10
  end

  -- keys that reach the window are NOT typed into a field (should only happen without focus)
  for _, key in ipairs(win.chars) do add_event("key " .. describe_key(key) .. " reached the window (no field focused)") end

  y = y + 6
  Widgets.text("Events (newest first):", pad, y, gfx.w - 2 * pad, 20, { size = 14, color = "muted" })
  y = y + 22
  for _, line in ipairs(events) do
    Widgets.text(line, pad, y, gfx.w - 2 * pad, 18, { size = 14 })
    y = y + 18
  end
end)
