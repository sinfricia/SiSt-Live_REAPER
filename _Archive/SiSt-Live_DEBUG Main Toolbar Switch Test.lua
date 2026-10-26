-- @noindex
-- SiSt-Live DEBUG: Main Toolbar Switch Test
-- An experiment, not part of the package. Question: can a script make REAPER's main toolbar the
-- "focused" toolbar without clicking a button, so that "Toolbars: Switch to toolbar N" changes the MAIN
-- toolbar? (Those actions act on the toolbar that was clicked last.) If yes, a mode effect can switch the
-- main toolbar per mode.
--
-- What it does:
--   1. Lists the windows inside REAPER's main window that look like toolbars or dockers (class and title
--      contain "toolbar" or "dock"), with position and size. Read only.
--   2. You pick one (the main toolbar above the track list), a focus method and a toolbar number.
--   3. It focuses that window with the chosen method and runs "Toolbars: Switch to toolbar N".
--   4. It asks you whether the MAIN toolbar switched and writes the answer to the report file.
--   5. It offers to switch the main toolbar back the same way ("Toolbars: Switch to main toolbar").
--
-- Focus methods (none of them clicks a button, except 4 which asks first):
--   1  JS_Window_SetFocus (keyboard focus)
--   2  WM_SETFOCUS message
--   3  WM_MOUSEACTIVATE message (what Windows sends before a click, without the click)
--   4  a real left click at the bottom-right corner pixel of the toolbar. Only if 1-3 don't work: if a
--      button reaches that corner, it would be triggered. Asks before clicking.
--
-- Before running: click some OTHER toolbar (e.g. a docked floating toolbar), so the main toolbar is
-- definitely not the last clicked one.
--
-- Report: <resource path>/Data/SiSt-Live/main_toolbar_test.txt (everything is also in the console).
-- Needs the js_ReaScriptAPI extension.

local TITLE = "SiSt-Live: main toolbar switch test"

local SWITCH = { -- "Toolbars: Switch to toolbar N" (IDs from the action list, checked by name below)
  [1] = 41105, [2] = 41106, [3] = 41107, [4] = 41108, [5] = 41647, [6] = 41648, [7] = 41649, [8] = 41650,
  [9] = 41948, [10] = 41949, [11] = 41950, [12] = 41951, [13] = 41952, [14] = 41953, [15] = 41954, [16] = 41955,
  [17] = 42729,
}
local SWITCH_MAIN = 41646 -- "Toolbars: Switch to main toolbar"

local sep = package.config:sub(1, 1)
local report_dir = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "SiSt-Live"
local report_path = report_dir .. sep .. "main_toolbar_test.txt"
local lines = {}
local function out(fmt, ...)
  local line = select("#", ...) > 0 and fmt:format(...) or fmt
  lines[#lines + 1] = line
  reaper.ShowConsoleMsg(line .. "\n")
end
local function save_report()
  reaper.RecursiveCreateDirectory(report_dir, 0)
  local f = io.open(report_path, "ab")
  if f then
    f:write(table.concat(lines, "\n") .. "\n\n")
    f:close()
  end
  lines = {}
end

local function check_name(cmd, expected)
  local name = reaper.kbd_getTextFromCmd(cmd, 0)
  return name == expected, name
end

-- 0. Requirements --------------------------------------------------------------------------------
if not reaper.APIExists("JS_Window_ArrayAllChild") then
  reaper.MB("This test needs the js_ReaScriptAPI extension (install it with ReaPack).", TITLE, 0)
  return
end

out("=== %s, %s, REAPER %s ===", TITLE, os.date("%Y-%m-%d %H:%M:%S"), reaper.GetAppVersion())

-- 1. Find toolbar-like windows (read only) -----------------------------------------------------------
local main = reaper.GetMainHwnd()
local arr = reaper.new_array({}, 4096)
local count = reaper.JS_Window_ArrayAllChild(main, arr)
out("child windows of the main window: %s", tostring(count))

local candidates = {}
for _, address in ipairs(arr.table()) do
  local hwnd = reaper.JS_Window_HandleFromAddress(address)
  if hwnd then
    local class = reaper.JS_Window_GetClassName(hwnd) or ""
    local title = reaper.JS_Window_GetTitle(hwnd) or ""
    local text = (class .. " " .. title):lower()
    if text:find("toolbar", 1, true) or text:find("dock", 1, true) then
      local _, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
      candidates[#candidates + 1] = { hwnd = hwnd, class = class, title = title, l = l, t = t, r = r, b = b,
        visible = reaper.JS_Window_IsVisible(hwnd) }
    end
  end
end

if #candidates == 0 then
  out("No window with 'toolbar' or 'dock' in its class or title found.")
  out("All child classes (first 200):")
  local n = 0
  for _, address in ipairs(arr.table()) do
    local hwnd = reaper.JS_Window_HandleFromAddress(address)
    if hwnd and n < 200 then
      n = n + 1
      out("  %s | %s", reaper.JS_Window_GetClassName(hwnd) or "?", reaper.JS_Window_GetTitle(hwnd) or "")
    end
  end
  save_report()
  reaper.MB("No toolbar windows found. The list of all windows is in the console and the report file:\n" ..
    report_path, TITLE, 0)
  return
end

out("Candidates:")
for i, c in ipairs(candidates) do
  out("  %d: class '%s', title '%s', %s, at %d,%d size %dx%d", i, c.class, c.title,
    c.visible and "visible" or "hidden", c.l or -1, c.t or -1, (c.r or 0) - (c.l or 0), (c.b or 0) - (c.t or 0))
end
save_report()

-- 2. Choose -------------------------------------------------------------------------------------------
local guess = 1
for i, c in ipairs(candidates) do
  if c.visible and (c.title:lower():find("main", 1, true)) then guess = i; break end
end

local ok, answer = reaper.GetUserInputs(TITLE .. " (see console for the window list)", 3,
  "Window no. (main toolbar),Focus method (1-4),Switch to toolbar (1-17),extrawidth=80",
  ("%d,1,5"):format(guess))
if not ok then return end
local win_no, method, tb = answer:match("^%s*(%d+)%s*,%s*(%d)%s*,%s*(%d+)%s*$")
win_no, method, tb = tonumber(win_no), tonumber(method), tonumber(tb)
local target = win_no and candidates[win_no]
if not (target and method and method >= 1 and method <= 4 and tb and SWITCH[tb]) then
  reaper.MB("Please enter a window number from the list, a method 1-4 and a toolbar 1-17.", TITLE, 0)
  return
end

local expected = "Toolbars: Switch to toolbar " .. tb
local name_ok, name = check_name(SWITCH[tb], expected)
if not name_ok then
  out("Command %d is '%s', not '%s': stopped.", SWITCH[tb], name, expected)
  save_report()
  reaper.MB(("Command %d is '%s', not '%s'.\nStopped (nothing was run)."):format(SWITCH[tb], name, expected), TITLE, 0)
  return
end

-- 3. Focus + switch --------------------------------------------------------------------------------------
local function focus(hwnd, how)
  if how == 1 then
    reaper.JS_Window_SetFocus(hwnd)
  elseif how == 2 then
    reaper.JS_WindowMessage_Send(hwnd, "WM_SETFOCUS", 0, 0, 0, 0)
  elseif how == 3 then
    -- lParam: low word HTCLIENT (1), high word the mouse message (WM_LBUTTONDOWN = 0x201)
    reaper.JS_WindowMessage_Send(hwnd, "WM_MOUSEACTIVATE", 0, 0, 1, 0x201)
  elseif how == 4 then
    local _, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
    local cx, cy = (r - l) - 2, (b - t) - 2 -- client coordinates of the bottom-right corner
    reaper.JS_WindowMessage_Send(hwnd, "WM_LBUTTONDOWN", 1, 0, cx, cy)
    reaper.JS_WindowMessage_Send(hwnd, "WM_LBUTTONUP", 0, 0, cx, cy)
  end
end

if method == 4 and reaper.MB("Method 4 sends a real left click to the bottom-right corner of window " .. win_no ..
    ".\nIf a toolbar button reaches that corner, it is triggered.\n\nContinue?", TITLE, 4) ~= 6 then
  return
end

out("Test: window %d (class '%s', title '%s'), method %d, then '%s' (%d)", win_no, target.class, target.title,
  method, expected, SWITCH[tb])
focus(target.hwnd, method)
reaper.Main_OnCommand(SWITCH[tb], 0)

-- 4. Result --------------------------------------------------------------------------------------------
local result = reaper.MB(("Did the MAIN toolbar (above the track list) switch to toolbar %d?\n\n" ..
  "Yes = the main toolbar switched\nNo = nothing / another toolbar switched"):format(tb), TITLE, 4)
out("Result: %s", result == 6 and "MAIN TOOLBAR SWITCHED" or "main toolbar did NOT switch")
save_report()

-- 5. Switch back ------------------------------------------------------------------------------------------
if result == 6 and reaper.MB("Switch the main toolbar back now (same method, 'Switch to main toolbar')?", TITLE, 4) == 6 then
  local back_ok = check_name(SWITCH_MAIN, "Toolbars: Switch to main toolbar")
  if back_ok then
    focus(target.hwnd, method)
    reaper.Main_OnCommand(SWITCH_MAIN, 0)
    local back = reaper.MB("Is the main toolbar back?", TITLE, 4)
    out("Switch back: %s", back == 6 and "worked" or "did NOT work")
  else
    out("Switch back: command %d has another name, not run", SWITCH_MAIN)
  end
  save_report()
end

reaper.MB("Done. The results are in the console and in\n" .. report_path, TITLE, 0)
