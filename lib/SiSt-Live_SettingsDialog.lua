-- @noindex
-- SiSt-Live settings dialog: one dialog for the settings of all mode effects
-- (the "SiSt-Live: Configure modes" action).
--
-- Uses REAPER's native text dialog (GetUserInputs), one field per setting and mode, e.g.
-- "SHOW theme", "EDIT screenset". The fields come from the effects themselves: every effect in
-- ModeEffects.MODULES can list its settings in Effect.settings, so a new effect's settings show up
-- here without changing this file. Setting contract:
--   label                 short name, shown after the mode ("SHOW <label>")
--   get(mode, api)        stored value (nil = none)
--   format(value)         value -> field text ("" = none)
--   parse(text, api)      field text -> true, value[, note]  or  false, error message
--   set(mode, value, api) stores the value (nil = none)
--
-- Flow: fields show the stored values. Only fields whose text changed are parsed. If any is
-- invalid, the errors are shown and the dialog opens again with what was typed. Then one
-- confirmation lists all changes: store and apply the current mode now, store only, or discard.
--
-- This file is only the native text-dialog UI. The settings themselves are defined by the effects,
-- so a future GUI can replace this file and reuse them.
--
-- GetUserInputs shows at most MAX_FIELDS fields. If there are more settings, the dialog is
-- split into one dialog per mode.

local Log         = require("SiSt-Live_Log")
local Mode        = require("SiSt-Live_Mode")
local ModeEffects = require("SiSt-Live_ModeEffects")

local log = Log.get("SettingsDialog")

local SettingsDialog = {}

SettingsDialog.MAX_FIELDS = 16
SettingsDialog.SEP        = "\n" -- field separator: values may contain commas
SettingsDialog.TITLE      = "SiSt-Live mode settings  ('current' = take from REAPER, empty = none)"
SettingsDialog.MODES      = { Mode.SHOW, Mode.EDIT }

-- Pure helpers ----------------------------------------------------------
--- One field per mode and setting, modes first (all SHOW fields, then all EDIT fields).
function SettingsDialog.collect(effects, modes)
  local fields = {}
  for _, mode in ipairs(modes or SettingsDialog.MODES) do
    for _, effect in ipairs(effects) do
      for _, setting in ipairs(effect.settings or {}) do
        fields[#fields + 1] = { mode = mode, effect = effect.name, setting = setting,
          caption = mode:upper() .. " " .. setting.label }
      end
    end
  end
  return fields
end

--- Fields in dialog-sized groups: all in one if they fit, else one group per mode.
function SettingsDialog.groups(fields)
  if #fields <= SettingsDialog.MAX_FIELDS then return { fields } end
  local by_mode, order = {}, {}
  for _, f in ipairs(fields) do
    if not by_mode[f.mode] then by_mode[f.mode] = {}; order[#order + 1] = f.mode end
    table.insert(by_mode[f.mode], f)
  end
  local groups = {}
  for _, mode in ipairs(order) do groups[#groups + 1] = by_mode[mode] end
  return groups
end

--- Splits the dialog result into exactly n texts (empty fields stay empty).
function SettingsDialog.split(str, n)
  local texts = {}
  for part in ((str or "") .. SettingsDialog.SEP):gmatch("(.-)" .. SettingsDialog.SEP) do
    texts[#texts + 1] = part
  end
  for i = #texts + 1, n do texts[i] = "" end
  while #texts > n do table.remove(texts) end
  return texts
end

--- Current field texts.
function SettingsDialog.read(fields, api)
  local texts = {}
  for i, f in ipairs(fields) do
    texts[i] = f.setting.format(f.setting.get(f.mode, api))
  end
  return texts
end

--- Compares typed texts with the stored ones. Returns changes and errors.
--- change: { field, value, old (text), new (text), note }
function SettingsDialog.evaluate(fields, old_texts, new_texts, api)
  local changes, errors = {}, {}
  for i, f in ipairs(fields) do
    local typed = (new_texts[i] or ""):match("^%s*(.-)%s*$")
    if typed ~= old_texts[i] then
      local ok, value, note = f.setting.parse(typed, api)
      if not ok then
        errors[#errors + 1] = f.mode:upper() .. " " .. tostring(value)
      else
        local new = f.setting.format(value)
        if new ~= old_texts[i] then -- e.g. "current" that equals what is stored is no change
          changes[#changes + 1] = { field = f, value = value, old = old_texts[i], new = new,
            note = note and (f.mode:upper() .. " " .. note) or nil }
        end
      end
    end
  end
  return changes, errors
end

function SettingsDialog.store(changes, api)
  for _, c in ipairs(changes) do
    c.field.setting.set(c.field.mode, c.value, api)
    log:info("%s: '%s' -> '%s'", c.field.caption, c.old, c.new)
  end
end

local function show(text) return text == "" and "(none)" or text end

function SettingsDialog.describe(changes)
  local lines = {}
  for _, c in ipairs(changes) do
    lines[#lines + 1] = ("%s:  %s  ->  %s"):format(c.field.caption, show(c.old), show(c.new))
  end
  for _, c in ipairs(changes) do
    if c.note then lines[#lines + 1] = "\nNote: " .. c.note end
  end
  return table.concat(lines, "\n")
end

-- Dialog ----------------------------------------------------------------
-- Runs the dialog for one group until it's valid or cancelled. Returns changes, or nil if cancelled.
local function run_group(fields, api)
  local old = SettingsDialog.read(fields, api)
  local texts = old
  local captions = {}
  for i, f in ipairs(fields) do captions[i] = f.caption end
  local captions_csv = table.concat(captions, ",") .. ",separator=" .. SettingsDialog.SEP .. ",extrawidth=220"

  while true do
    local ok, result = api.GetUserInputs(SettingsDialog.TITLE, #fields, captions_csv,
      table.concat(texts, SettingsDialog.SEP))
    if not ok then return nil end
    texts = SettingsDialog.split(result, #fields)

    local changes, errors = SettingsDialog.evaluate(fields, old, texts, api)
    if #errors == 0 then return changes end
    api.MB("Please fix:\n\n" .. table.concat(errors, "\n"), "SiSt-Live mode settings", 0)
  end
end

--- The "SiSt-Live: Configure modes" action. Returns the number of stored changes.
function SettingsDialog.run(api)
  api = api or reaper
  local effects = {}
  for _, e in ipairs(ModeEffects.load()) do
    if not e.load_error then effects[#effects + 1] = e end
  end

  local all = {}
  for _, group in ipairs(SettingsDialog.groups(SettingsDialog.collect(effects))) do
    local changes = run_group(group, api)
    if not changes then return 0 end -- cancelled: nothing is stored
    for _, c in ipairs(changes) do all[#all + 1] = c end
  end

  if #all == 0 then return 0 end

  local current = Mode.get()
  local ret = api.MB(SettingsDialog.describe(all) ..
    ("\n\nYes: store and apply %s mode (current) now\nNo: store only (applied at the next switch)\nCancel: discard"):format(current:upper()),
    "SiSt-Live mode settings: store changes?", 3)
  if ret == 2 then return 0 end -- cancel

  SettingsDialog.store(all, api)
  if ret == 6 then ModeEffects.apply_all(current) end
  return #all
end

-- Self-test -------------------------------------------------------------
function SettingsDialog.self_test()
  local results = {}
  local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

  local store = {}
  local api = {}
  local function setting(label)
    return {
      label  = label,
      get    = function(mode) return store[mode .. label] end,
      format = function(v) return v and tostring(v) or "" end,
      parse  = function(text)
        if text == "" then return true, nil end
        local n = tonumber(text)
        if not n then return false, label .. ": not a number" end
        return true, n, n > 5 and (label .. " is big") or nil
      end,
      set    = function(mode, v) store[mode .. label] = v end,
    }
  end
  local effects = { { name = "a", settings = { setting("one"), setting("two") } },
                    { name = "b" },
                    { name = "c", settings = { setting("three") } } }

  local fields = SettingsDialog.collect(effects, { "show", "edit" })
  check("collect: one field per setting and mode, modes first",
    #fields == 6 and fields[1].caption == "SHOW one" and fields[3].caption == "SHOW three"
    and fields[4].caption == "EDIT one")
  check("groups: everything in one dialog when it fits", #SettingsDialog.groups(fields) == 1)

  local many = {}
  for i = 1, 9 do many[i] = setting("s" .. i) end
  local big = SettingsDialog.groups(SettingsDialog.collect({ { name = "x", settings = many } }, { "show", "edit" }))
  check("groups: split per mode above the field limit", #big == 2 and #big[1] == 9 and big[2][1].mode == "edit")

  check("split: empty fields are kept", table.concat(SettingsDialog.split("a\n\nc\n", 4), "|") == "a||c|")
  check("split: always n texts", #SettingsDialog.split("", 3) == 3 and #SettingsDialog.split("a\nb\nc\nd", 2) == 2)

  store = { showone = 1 }
  local old = SettingsDialog.read(fields, api)
  check("read: stored values as text, none as empty", old[1] == "1" and old[2] == "")

  local new = { "1", " 3 ", "", "", "x", "7" }
  local changes, errors = SettingsDialog.evaluate(fields, old, new, api)
  check("evaluate: unchanged fields are ignored, changes trimmed",
    #changes == 2 and changes[1].field.caption == "SHOW two" and changes[1].new == "3")
  check("evaluate: invalid field reported with its mode", #errors == 1 and errors[1] == "EDIT two: not a number")
  check("evaluate: notes are passed on", changes[2].note == "EDIT three is big")

  SettingsDialog.store(changes, api)
  check("store: values written", store.showtwo == 3 and store.editthree == 7)

  local cleared = SettingsDialog.evaluate(fields, SettingsDialog.read(fields, api), { "", "3", "", "", "", "7" }, api)
  SettingsDialog.store(cleared, api)
  check("empty field clears the setting", #cleared == 1 and store.showone == nil)

  check("describe lists old -> new", SettingsDialog.describe(changes):find("SHOW two:  (none)  ->  3", 1, true) ~= nil)

  check("every registered effect setting follows the contract", (function()
    for _, e in ipairs(ModeEffects.load()) do
      for _, s in ipairs(e.settings or {}) do
        if type(s.label) ~= "string" or type(s.get) ~= "function" or type(s.format) ~= "function"
            or type(s.parse) ~= "function" or type(s.set) ~= "function" then return false end
      end
    end
    return true
  end)())

  return results
end

return SettingsDialog
