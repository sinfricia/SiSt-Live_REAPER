-- @noindex
-- SiSt-Live: DEBUG Screenshot Setlist
-- Saves the open Setlist window as a PNG: <resource path>/Data/SiSt Libraries/Setlist screenshot.png, so Claude can look at
-- drawing changes before handing them over. Needs js_ReaScriptAPI. The result (or the reason it failed) is also written to
-- <resource path>/Data/SiSt Libraries/Setlist screenshot.txt. Claude-only tool, not installed by Setup.
--
-- It copies the window's pixels with GDI (the window has to be visible: not minimised, not behind another window that
-- covers it, and a docked window in a hidden tab has no pixels).

local WINDOW_TITLE = "SiSt-Live Setlist" -- as in Setlist/SiSt-Live_Setlist.lua

local dir = reaper.GetResourcePath() .. "/Data/SiSt Libraries/"
reaper.RecursiveCreateDirectory(dir, 0)
local png_path, report_path = dir .. "Setlist screenshot.png", dir .. "Setlist screenshot.txt"

local function report(text)
   local f = io.open(report_path, "w")
   if f then f:write(text, "\n") f:close() end
end

local function main()
   for _, name in ipairs({ "JS_Window_Find", "JS_Window_GetClientSize", "JS_GDI_GetClientDC", "JS_GDI_ReleaseDC",
      "JS_GDI_Blit", "JS_LICE_CreateBitmap", "JS_LICE_GetDC", "JS_LICE_WritePNG", "JS_LICE_DestroyBitmap" }) do
      if not reaper.APIExists(name) then return false, "js_ReaScriptAPI is missing (" .. name .. ")" end
   end

   local hwnd = reaper.JS_Window_Find(WINDOW_TITLE, false) -- (not exact: the title may carry a "*" or the list name)
   if not hwnd then return false, "no window with '" .. WINDOW_TITLE .. "' in its title is open" end

   local ok, w, h = reaper.JS_Window_GetClientSize(hwnd)
   if not ok or w < 1 or h < 1 then return false, "could not read the window size" end

   local src = reaper.JS_GDI_GetClientDC(hwnd)
   if not src then return false, "could not get the window's drawing surface" end
   local bitmap = reaper.JS_LICE_CreateBitmap(true, w, h)
   local dst = reaper.JS_LICE_GetDC(bitmap)
   reaper.JS_GDI_Blit(dst, 0, 0, src, 0, 0, w, h)
   local written = reaper.JS_LICE_WritePNG(png_path, bitmap, false)
   reaper.JS_GDI_ReleaseDC(hwnd, src)
   reaper.JS_LICE_DestroyBitmap(bitmap)
   if not written then return false, "writing the PNG failed: " .. png_path end
   return true, ("saved %dx%d: %s"):format(w, h, png_path)
end

local ok, result, message = pcall(main)
if not ok then
   report("failed: " .. tostring(result))
else
   report((result and "ok: " or "failed: ") .. tostring(message))
end

reaper.defer(function() end) -- no undo point
