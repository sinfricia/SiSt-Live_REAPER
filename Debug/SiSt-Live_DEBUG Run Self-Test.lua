-- @noindex
-- Runs the built-in self-tests against the live REAPER API and prints a
-- diagnostics report to the console. Safe to run any time: the mode is
-- restored afterwards, and the mode effects are tested with fakes only
-- (no theme, layout, screenset, keyboard section, fullscreen, locking or window is changed, no assignment is touched).

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local Mode        = require("SiSt-Live_Mode")
local Log         = require("SiSt-Live_Log")
local ModeEffects = require("SiSt-Live_ModeEffects")
local Theme       = require("ModeEffects.SiSt-Live_ModeEffect_Theme")
local Layout      = require("ModeEffects.SiSt-Live_ModeEffect_Layout")
local Screenset   = require("ModeEffects.SiSt-Live_ModeEffect_Screenset")
local KeySection  = require("ModeEffects.SiSt-Live_ModeEffect_KeySection")
local Fullscreen  = require("ModeEffects.SiSt-Live_ModeEffect_Fullscreen")
local Locking     = require("ModeEffects.SiSt-Live_ModeEffect_Locking")
local Windows     = require("ModeEffects.SiSt-Live_ModeEffect_Windows")
local SettingsDialog = require("SiSt-Live_SettingsDialog")
local ToolbarSource = require("SiSt-Live_ToolbarSource")
local Actions     = require("SiSt-Live_Actions")
local Button      = require("SiSt-Live_Button")

-- Add a component here once it offers .self_test(), .diagnostics() and/or .live_check().
-- live_check: checks against the REAL REAPER: every native command ID still exists, listed with its
-- current name (names may change with REAPER updates, the IDs are trusted). Read-only. Run this action
-- after every REAPER update and glance over the names.
local components = {
  { name = "Mode",         self_test = Mode.self_test,        diagnostics = Mode.diagnostics },
  { name = "Log",          self_test = Log.self_test,         diagnostics = Log.diagnostics },
  { name = "ModeEffects",  self_test = ModeEffects.self_test, diagnostics = ModeEffects.diagnostics },
  { name = "SettingsDialog", self_test = SettingsDialog.self_test },
  { name = "ToolbarSource", self_test = ToolbarSource.self_test, diagnostics = function() return ToolbarSource.diagnostics() end },
  { name = "Actions",      self_test = Actions.self_test,     diagnostics = function() return Actions.diagnostics() end },
  { name = "Button",       self_test = Button.self_test },
  { name = "Effect theme", self_test = Theme.self_test,       diagnostics = function() return Theme.diagnostics() end },
  { name = "Effect layout", self_test = Layout.self_test,      diagnostics = function() return Layout.diagnostics() end },
  { name = "Effect screenset", self_test = Screenset.self_test, diagnostics = function() return Screenset.diagnostics() end,
    live_check = function() return Screenset.check_actions() end },
  { name = "Effect keyboard", self_test = KeySection.self_test, diagnostics = function() return KeySection.diagnostics() end,
    live_check = function() return KeySection.check_actions() end },
  { name = "Effect fullscreen", self_test = Fullscreen.self_test, diagnostics = function() return Fullscreen.diagnostics() end,
    live_check = function() return Fullscreen.check_actions() end },
  { name = "Effect locking", self_test = Locking.self_test, diagnostics = function() return Locking.diagnostics() end,
    live_check = function() return Locking.check_actions() end },
  { name = "Effect windows", self_test = Windows.self_test, diagnostics = function() return Windows.diagnostics() end,
    live_check = function() return Windows.check_actions() end },
}

local out = { "=== SiSt-Live self-test & diagnostics ===",
              ("REAPER %s | %s"):format(reaper.GetAppVersion(), _VERSION) }
local passed, failed = 0, 0

for _, c in ipairs(components) do
  out[#out + 1] = ""
  out[#out + 1] = "[" .. c.name .. "]"

  if c.self_test then
    local ok, results = xpcall(c.self_test, debug.traceback)
    if ok then
      for _, r in ipairs(results) do
        out[#out + 1] = ("  %s  %s"):format(r.ok and "PASS" or "FAIL", r.name)
        if r.ok then passed = passed + 1 else failed = failed + 1 end
      end
    else
      failed = failed + 1
      out[#out + 1] = "  FAIL  self_test crashed: " .. tostring(results)
    end
  end

  if c.live_check then
    local ok, results = pcall(c.live_check)
    if ok then
      for _, r in ipairs(results) do
        out[#out + 1] = ("  %s  live: %s"):format(r.ok and "PASS" or "FAIL", r.name)
        if r.ok then passed = passed + 1 else failed = failed + 1 end
      end
    else
      failed = failed + 1
      out[#out + 1] = "  FAIL  live check crashed: " .. tostring(results)
    end
  end

  if c.diagnostics then
    local ok, rows = pcall(c.diagnostics)
    if ok then
      for _, row in ipairs(rows) do
        out[#out + 1] = ("  %-18s %s"):format(row[1], tostring(row[2]))
      end
    else
      out[#out + 1] = "  diagnostics error: " .. tostring(rows)
    end
  end
end

out[#out + 1] = ""
out[#out + 1] = ("Result: %d passed, %d failed"):format(passed, failed)
reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")

reaper.defer(function() end) -- no undo point
