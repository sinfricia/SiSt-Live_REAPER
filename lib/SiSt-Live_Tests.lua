-- @noindex
-- SiSt-Live's test list (see lib/SelfTest.lua). Not an action: run it with "SiSt-Live: DEBUG Run Self-Test" or with
-- "Run all self-tests" (every registered package).
--
-- Works from anywhere: it adds its own folder to the module path, so any runner can load it.
--
-- Adding a module: one entry below, with the file it tests. A lib file without an entry shows up as a warning
-- ("not on the test list") unless it is listed under coverage.exceptions with a reason.
-- self_test: tests with fakes, never changes REAPER. live_check: read-only checks against the real REAPER
-- (e.g. every native command ID still exists; run after REAPER updates). diagnostics: information rows.

local sep = package.config:sub(1, 1)
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
if not package.path:find(here, 1, true) then package.path = here .. "?.lua;" .. package.path end
local root = here .. ".." .. sep -- the package folder (Scripts/SiSt-Live)

local SelfTest       = require("SelfTest")
local Mode           = require("SiSt-Live_Mode")
local Log            = require("SiSt-Live_Log")
local ModeEffects    = require("SiSt-Live_ModeEffects")
local SettingsDialog = require("SiSt-Live_SettingsDialog")
local ToolbarSource  = require("SiSt-Live_ToolbarSource")
local Actions        = require("SiSt-Live_Actions")
local Button         = require("SiSt-Live_Button")
local ActionReferenceChecks = require("ActionReferenceChecks")
local EffectTheme    = require("ModeEffects.SiSt-Live_ModeEffect_Theme")
local Layout         = require("ModeEffects.SiSt-Live_ModeEffect_Layout")
local Screenset      = require("ModeEffects.SiSt-Live_ModeEffect_Screenset")
local KeySection     = require("ModeEffects.SiSt-Live_ModeEffect_KeySection")
local Fullscreen     = require("ModeEffects.SiSt-Live_ModeEffect_Fullscreen")
local Locking        = require("ModeEffects.SiSt-Live_ModeEffect_Locking")
local Windows        = require("ModeEffects.SiSt-Live_ModeEffect_Windows")
local GuiTheme       = require("Gui.Theme")
local Window         = require("Gui.Window")
local Widgets        = require("Gui.Widgets")
local TextField      = require("Gui.TextField")

-- The config reference check reads several files: run it once, use the report twice (live check + diagnostics)
local config_report = nil
local function config_references()
  config_report = config_report or ActionReferenceChecks.check_config()
  return config_report
end

local components = {
  { name = "Mode", file = "lib/SiSt-Live_Mode.lua", self_test = Mode.self_test, diagnostics = Mode.diagnostics },
  { name = "Log", file = "lib/SiSt-Live_Log.lua", self_test = Log.self_test, diagnostics = Log.diagnostics },
  { name = "ModeEffects", file = "lib/SiSt-Live_ModeEffects.lua", self_test = ModeEffects.self_test,
    diagnostics = ModeEffects.diagnostics },
  { name = "SettingsDialog", file = "lib/SiSt-Live_SettingsDialog.lua", self_test = SettingsDialog.self_test },
  { name = "ToolbarSource", file = "lib/SiSt-Live_ToolbarSource.lua", self_test = ToolbarSource.self_test,
    diagnostics = function() return ToolbarSource.diagnostics() end },
  { name = "Actions", file = "lib/SiSt-Live_Actions.lua", self_test = Actions.self_test,
    diagnostics = function() return Actions.diagnostics() end },
  { name = "Button", file = "lib/SiSt-Live_Button.lua", self_test = Button.self_test },
  { name = "Effect theme", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Theme.lua", self_test = EffectTheme.self_test,
    diagnostics = function() return EffectTheme.diagnostics() end },
  { name = "Effect layout", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Layout.lua", self_test = Layout.self_test,
    diagnostics = function() return Layout.diagnostics() end },
  { name = "Effect screenset", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Screenset.lua",
    self_test = Screenset.self_test, diagnostics = function() return Screenset.diagnostics() end,
    live_check = function() return Screenset.check_actions() end },
  { name = "Effect keyboard", file = "lib/ModeEffects/SiSt-Live_ModeEffect_KeySection.lua",
    self_test = KeySection.self_test, diagnostics = function() return KeySection.diagnostics() end,
    live_check = function() return KeySection.check_actions() end },
  { name = "Effect fullscreen", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Fullscreen.lua",
    self_test = Fullscreen.self_test, diagnostics = function() return Fullscreen.diagnostics() end,
    live_check = function() return Fullscreen.check_actions() end },
  { name = "Effect locking", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Locking.lua",
    self_test = Locking.self_test, diagnostics = function() return Locking.diagnostics() end,
    live_check = function() return Locking.check_actions() end },
  { name = "Effect windows", file = "lib/ModeEffects/SiSt-Live_ModeEffect_Windows.lua",
    self_test = Windows.self_test, diagnostics = function() return Windows.diagnostics() end,
    live_check = function() return Windows.check_actions() end },
  { name = "Gui Theme", file = "lib/Gui/Theme.lua", self_test = GuiTheme.self_test },
  { name = "Gui Window", file = "lib/Gui/Window.lua", self_test = Window.self_test },
  { name = "Gui Widgets", file = "lib/Gui/Widgets.lua", self_test = Widgets.self_test },
  { name = "Gui TextField", file = "lib/Gui/TextField.lua", self_test = TextField.self_test },
  { name = "SelfTest", file = "lib/SelfTest.lua", self_test = SelfTest.self_test },
  -- Every named action ID used by custom actions, shortcuts, toolbars/menus, mouse modifiers and SWS cycle/startup
  -- actions must exist. Diagnostics: scripts in the action list whose file is missing but that nothing uses.
  { name = "Action references (config)", file = "lib/ActionReferenceChecks.lua",
    self_test = ActionReferenceChecks.self_test,
    live_check = function() return ActionReferenceChecks.results(config_references(), "Config") end,
    diagnostics = function()
      local rows = { { "references checked", config_references().checked } }
      for _, s in ipairs(config_references().unused_missing) do rows[#rows + 1] = { "unused, file missing", s.path } end
      if #rows == 1 then rows[2] = { "unused, file missing", "(none)" } end
      return rows
    end },
}

-- Component scripts: their tests live inside the script (test-only switch, see lib/SelfTest.lua)
for _, script in ipairs({
  "Setlist/SiSt-Live_Setlist.lua",
  "Status Display/SiSt-Live_Status Display.lua",
  "Toolbar/SiSt-Live_Toolbar.lua",
  "Setup/SiSt-Live_Setup.lua",
}) do
  for _, c in ipairs(SelfTest.collect_script(root .. (script:gsub("/", sep)))) do
    c.file = script
    components[#components + 1] = c
  end
end

return {
  name = "SiSt-Live",
  root = root,
  components = components,
  coverage = {
    folder = "lib",
    exceptions = {
      ["lib/SiSt-Live_Tests.lua"] = "this test list",
      ["lib/SiSt-Live_Toolbar.lua"] = "unused old copy of ToolbarSource, deleted in step 2",
    },
  },
}
