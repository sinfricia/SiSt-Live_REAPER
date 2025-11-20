-- @description Apply actions to all open projects (ImGui Version)
-- @version 1.0.0
-- @author sinfricia
-- @changelog
--   Initial release
-- @about
--   Prompts user to select an action that then gets applied to a selection of open REAPER projects.

local VSDEBUG = dofile("c:/Users/sinas/.vscode/extensions/antoinebalaine.reascript-docs-0.1.15/debugger/LoadDebug.lua")

local r = reaper

local SCRIPT_NAME = "Apply action to all open projects"
-- UTILITY

local DEBUG = false

local function Msg(input)
   if not DEBUG then return end
   r.ShowConsoleMsg(tostring(input) .. "\n")
end

---------------------------------------
-- Dependency check (ReaImGui + SWS)
---------------------------------------

local function CheckDependencies()
   -- ReaImGui
   if not r.ImGui_GetVersion then
      local ret = r.MB(
         "This script requires the ReaImGui extension.\n\nInstall now via ReaPack? (REAPER restart required afterwards)",
         SCRIPT_NAME .. " - Missing dependency",
         1
      )

      if ret == 1 and r.ReaPack_BrowsePackages then
         r.ReaPack_BrowsePackages("ReaImGui API")
      end

      return false
   end

   -- SWS (if you really need it for the action logic later)
   if not r.CF_GetSWSVersion then
      local ret = r.MB(
         "This script requires the SWS extension.\n\nInstall now via ReaPack? (REAPER restart required afterwards)",
         SCRIPT_NAME .. " - Missing dependency",
         1
      )

      if ret == 1 and r.ReaPack_BrowsePackages then
         r.ReaPack_BrowsePackages("SWS Extensions")
      end

      return false
   end

   return true
end

if not CheckDependencies() then
   return
end

---------------------------------------
-- ReaImGui setup
---------------------------------------

-- Keep existing package.path and prepend ImGui builtin path
do
   local imguiPath = r.ImGui_GetBuiltinPath() .. "/?.lua"
   package.path = imguiPath .. ";" .. package.path
end

local ImGui = require("imgui")("0.10")

---------------------------------------
-- Theme (fonts, colors, window profiles)
--  -> This is the place to tweak / extend UI look
---------------------------------------

local Theme = {}

-- Colors grouped in a single palette; easy to swap/extend later
Theme.colors = {
   base = {
      [ImGui.Col_WindowBg]         = 0x2e2e2eFF,
      [ImGui.Col_TitleBg]          = 0x252525FF,
      [ImGui.Col_TitleBgActive]    = 0x252525FF,
      [ImGui.Col_TitleBgCollapsed] = 0x252525FF,

      [ImGui.Col_FrameBg]          = 0x303030FF,
      [ImGui.Col_FrameBgHovered]   = 0x404040FF,
      [ImGui.Col_FrameBgActive]    = 0x505050FF,

      [ImGui.Col_Button]           = 0xf9f9f9FF,
      [ImGui.Col_ButtonHovered]    = 0xe0eef9FF,
      [ImGui.Col_ButtonActive]     = 0x91f8e5FF,

      [ImGui.Col_Header]           = 0x404040FF,
      [ImGui.Col_HeaderHovered]    = 0x505050FF,
      [ImGui.Col_HeaderActive]     = 0x606060FF,

      [ImGui.Col_CheckMark]        = 0xA0A0FFFF,
      [ImGui.Col_Text]             = 0xFFFFFFFF,
   }
}

-- Fonts by semantic *role* instead of family name.
-- Scaling and replacements are now trivial: edit this table only.
Theme.fonts = {
   title = {
      family = "Roboto",
      size   = 16,
      flags  = ImGui.FontFlags_None,
      font   = nil, -- filled at runtime
   },
   body = {
      family = "Roboto",
      size   = 13,
      flags  = ImGui.FontFlags_None,
      font   = nil,
   },
   subtle = {
      family = "Roboto Light",
      size   = 13,
      flags  = ImGui.FontFlags_None,
      font   = nil,
   },
}

-- Window profiles defined by flag names for readability.
local WindowProfiles = {
   Main = { "NoResize", "NoCollapse", "AlwaysAutoResize" },
   Popup = {
      "NoCollapse",
      "NoResize",
      "NoDocking",
      "NoSavedSettings",
      "AlwaysAutoResize",
      "NoScrollbar",
   },
}

local function BuildWindowFlags(list)
   local flags = 0
   for _, name in ipairs(list) do
      local flag = ImGui["WindowFlags_" .. name]
      if flag then
         flags = flags | flag
      end
   end
   return flags
end

-- Precompute numeric flags once (less work per frame)
for key, profile in pairs(WindowProfiles) do
   WindowProfiles[key] = BuildWindowFlags(profile)
end

-- Attach all fonts to a context and cache font objects in Theme.fonts[*].font
function Theme.attachFonts(ctx)
   for role, def in pairs(Theme.fonts) do
      local font = ImGui.CreateFont(def.family, def.flags or ImGui.FontFlags_None)
      ImGui.Attach(ctx, font)
      def.font = font
      Msg(("Attached font '%s' for role '%s'"):format(def.family, role))
   end
end

-- Push a color palette; returns count to pop
function Theme.pushColors(ctx, paletteName)
   local palette = Theme.colors[paletteName or "base"]
   if not palette then return 0 end

   local count = 0
   for col, value in pairs(palette) do
      ImGui.PushStyleColor(ctx, col, value)
      count = count + 1
   end
   return count
end

---------------------------------------
-- UI helpers
---------------------------------------

local function CenterNextWindow(ctx, cond)
   local vp = ImGui.GetMainViewport(ctx)
   local centerX, centerY = ImGui.Viewport_GetWorkCenter(vp)
   ImGui.SetNextWindowPos(ctx, centerX, centerY, cond, 0.5, 0.5)
end

local function EnforceTitleMinSize(ctx, title, useCloseButton, minH)
   local titleW, titleH = ImGui.CalcTextSize(ctx, title)
   local padX, padY     = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)

   -- Extra width for collapse and optional close button (rough but safe)
   local extraW         = padX * (useCloseButton and 16 or 10)
   local minW           = titleW + extraW

   minH                 = minH or (titleH + padY * 4)

   local _, floatMax    = ImGui.NumericLimits_Float()
   ImGui.SetNextWindowSizeConstraints(ctx, minW, minH, floatMax, floatMax)
end

-- Draw a function centered on X/Y within the current content region.
-- center: "x", "y", or "xy"
local function CenterElement(ctx, drawFn, center)
   center = center or "x"

   local curX = ImGui.GetCursorPosX(ctx)
   local curY = ImGui.GetCursorPosY(ctx)

   -- Off-screen draw to measure element
   ImGui.PushID(ctx, "invisible-measure")
   ImGui.SetCursorPos(ctx, -100000, -100000)
   drawFn()
   ImGui.PopID(ctx)

   local minX, minY = ImGui.GetItemRectMin(ctx)
   local maxX, maxY = ImGui.GetItemRectMax(ctx)
   local elemW = maxX - minX
   local elemH = maxY - minY

   ImGui.SetCursorPos(ctx, curX, curY)

   local availW, availH = ImGui.GetContentRegionAvail(ctx)
   local offsetX = 0
   local offsetY = 0

   if center:find("x", 1, true) then
      offsetX = math.max(0, (availW - elemW) * 0.5)
   end
   if center:find("y", 1, true) then
      offsetY = math.max(0, (availH - elemH) * 0.5)
   end

   ImGui.SetCursorPos(ctx, curX + offsetX, curY + offsetY)
   drawFn()
end



---------------------------------------
-- App state
---------------------------------------

local ctx              = nil
local currentWindow    = nil
local isOpen           = true
local sessionMode      = 1
local initId           = 0
local sectionId        = 0
local actionId         = nil
local projectList      = {}
local selectedProjects = {}

-- MAIN LOGIC

local function BuildProjNameList()
   projectList = {}
   local i = 0

   while true do
      local proj = reaper.EnumProjects(i)
      if not proj then break end

      local _, name = reaper.EnumProjects(i)
      if not name or name == "" then
         name = "Unsaved Project"
      end

      -- Remove path & extension
      local shortName = name:match("([^/\\]+)$")
      shortName = shortName:gsub("%.rpp$", "", 1)
      shortName = shortName:gsub("%.RPP$", "", 1)

      table.insert(projectList, {
         proj = proj,
         name = shortName,
         checked = true
      })

      if shortName:find("ROUTING") then
         projectList[#projectList].checked = false
      end

      i = i + 1
   end
end

local function PollAction()
   local actionId = reaper.PromptForAction(0, initId, sectionId)

   if actionId == 0 then
      reaper.defer(PollAction)
   elseif actionId == -1 then
      reaper.ShowMessageBox("Action canceled.", "Info", 0)
   else
      OnActionSelected(actionId)
   end
end

function OnActionSelected(cmd)
   BuildProjNameList()
end

---------------------------------------
-- UI: action prompt
---------------------------------------

local function Window_ActionPrompt()
   if not ctx then return end

   local windowFlags = WindowProfiles.Popup

   local colorStackCount = Theme.pushColors(ctx, "base")

   -- Outer frame styling
   ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 8)
   ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 6)

   CenterNextWindow(ctx, ImGui.Cond_FirstUseEver)
   EnforceTitleMinSize(ctx, SCRIPT_NAME, true)

   -- Title font
   local titleFont = Theme.fonts.title
   if titleFont.font then
      ImGui.PushFont(ctx, titleFont.font, titleFont.size)
   end

   local visible, openFlag = ImGui.Begin(ctx, SCRIPT_NAME, true, windowFlags)

   if titleFont.font then
      ImGui.PopFont(ctx)
   end
   ImGui.PopStyleVar(ctx, 2) -- FramePadding + WindowRounding

   if not visible then
      ImGui.PopStyleColor(ctx, colorStackCount)
      ImGui.End(ctx)
      return openFlag
   end

   -- Body font
   local bodyFont   = Theme.fonts.body
   local subtleFont = Theme.fonts.subtle

   if subtleFont.font then
      ImGui.PushFont(ctx, subtleFont.font, subtleFont.size)
   elseif bodyFont.font then
      ImGui.PushFont(ctx, bodyFont.font, bodyFont.size)
   end

   -- Prompt text (centered horizontally)
   CenterElement(ctx, function()
      ImGui.Text(ctx, "Please select an action...")
   end, "x")

   if subtleFont.font or bodyFont.font then
      ImGui.PopFont(ctx)
   end

   -- Buttons group, centered X+Y
   if bodyFont.font then
      ImGui.PushFont(ctx, bodyFont.font, bodyFont.size)
   end

   CenterElement(ctx, function()
      ImGui.BeginGroup(ctx)

      ImGui.Spacing(ctx)
      ImGui.Spacing(ctx)

      -- Cancel button: black text, rounded corners
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x000000FF) -- black
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 2)

      if ImGui.Button(ctx, "Cancel") then
         ImGui.EndGroup(ctx)
         ImGui.PopStyleColor(ctx, colorStackCount)
         ImGui.End(ctx)
         return false
      end

      ImGui.PopStyleColor(ctx)
      ImGui.PopStyleVar(ctx)

      -- Vertical spacer equal to frame padding Y
      local _, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      ImGui.Dummy(ctx, 1, padY)

      ImGui.EndGroup(ctx)
   end, "xy")

   if bodyFont.font then
      ImGui.PopFont(ctx)
   end

   ImGui.PopStyleColor(ctx, colorStackCount)
   ImGui.End(ctx)

   return openFlag
end

local function Window_ProjectList()
   if not ctx then return end

   local windowFlags = WindowProfiles.Main
   local colorStackCount = Theme.pushColors(ctx, "base")

   -- Outer frame styling
   ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 8)
   ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 6)

   CenterNextWindow(ctx, ImGui.Cond_FirstUseEver)
   EnforceTitleMinSize(ctx, SCRIPT_NAME, true)

   -- Title font
   local titleFont = Theme.fonts.title
   if titleFont.font then
      ImGui.PushFont(ctx, titleFont.font, titleFont.size)
   end

   local visible, openFlag = ImGui.Begin(ctx, "Select Project", true, windowFlags)

   if titleFont.font then
      ImGui.PopFont(ctx)
   end
   ImGui.PopStyleVar(ctx, 2) -- FramePadding + WindowRounding

   if not visible then
      ImGui.PopStyleColor(ctx, colorStackCount)
      ImGui.End(ctx)
      return openFlag
   end

   -- Body font
   local bodyFont   = Theme.fonts.body
   local subtleFont = Theme.fonts.subtle

   if subtleFont.font then
      ImGui.PushFont(ctx, subtleFont.font, subtleFont.size)
   elseif bodyFont.font then
      ImGui.PushFont(ctx, bodyFont.font, bodyFont.size)
   end

   -- Prompt text (centered horizontally)
   CenterElement(ctx, function()
      ImGui.Text(ctx, "Please select projects...")
   end, "x")

   if subtleFont.font or bodyFont.font then
      ImGui.PopFont(ctx)
   end

   -- Buttons group, centered X+Y
   if bodyFont.font then
      ImGui.PushFont(ctx, bodyFont.font, bodyFont.size)
   end

   CenterElement(ctx, function()
      ImGui.BeginGroup(ctx)

      ImGui.Spacing(ctx)
      ImGui.Spacing(ctx)

      -- Cancel button: black text, rounded corners
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x000000FF) -- black
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 2)

      if ImGui.Button(ctx, "Cancel") then
         return false
      end

      ImGui.PopStyleColor(ctx)
      ImGui.PopStyleVar(ctx)

      -- Vertical spacer equal to frame padding Y
      local _, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      ImGui.Dummy(ctx, 1, padY)

      ImGui.EndGroup(ctx)
   end, "xy")

   if bodyFont.font then
      ImGui.PopFont(ctx)
   end

   ImGui.PopStyleColor(ctx, colorStackCount)
   ImGui.End(ctx)

   return openFlag
end

---------------------------------------
-- Main loop
---------------------------------------

local WindowHandlers = {
   ActionPrompt = Window_ActionPrompt,
   ProjectList  = Window_ProjectList,
}

local function MainLoop()
   local handler = WindowHandlers[currentWindow]
   if not handler then return end

   local result = handler()

   if result == true then
      r.defer(MainLoop)
   elseif type(result) == "string" then
      currentWindow = result
      r.defer(MainLoop)
   elseif result == false then
      return -- EXIT SCRIPT
   end
end

---------------------------------------
-- Init
---------------------------------------

local function Init()
   ctx = ImGui.CreateContext(SCRIPT_NAME)
   Theme.attachFonts(ctx)
   currentWindow = "ActionPrompt"
   MainLoop()
end

Init()
