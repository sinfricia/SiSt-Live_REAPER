-- @noindex
--[[
SiSt-Live Setlist: Ask

Every question the Setlist asks the user in a dialog, in one place, so that Actions.lua never shows one: Yes / No
questions, text input, the color picker and the file dialogs. Each function returns the answer, or nil when the user
cancelled.

  confirm(text, title)                      true for Yes
  invalid_entries(list, invalid, where)     tells the user which lines of a setlist could not be read
  text(title, label, default)               a non-empty text, or nil
  color()                                   r, g, b as 0..1 floats, or nil
  open_file(title, extensions)              the chosen path, or nil
  save_file(title, default_name)            the chosen path, or nil
  parent_dir()                              the folder above the current project's folder (where the dialogs start)
]]

local Ask = {}

function Ask.confirm(text, title)
   return reaper.MB(text, title, 4) == 6
end

-- list: the entries that were read, invalid: the lines that could not be read, where: "from <file>" for the message.
function Ask.invalid_entries(list, invalid, where)
   if not next(invalid) then return end
   local msg = "Couldn't resolve the following entries while loading " .. where .. ":\n\n"
   local title = "Invalid Entries Found While Parsing"
   if not next(list) then
      msg = "Couldn't resolve ANY of following entries while loading " .. where .. ":\n\n"
      title = "Error Loading from " .. where
   end
   reaper.MB(msg .. table.concat(invalid, "\n") .. "\n", title, 0)
end

function Ask.text(title, label, default)
   local ok, input = reaper.GetUserInputs(title, 1, label, default or "")
   if ok and input ~= "" then return input end
   return nil
end

function Ask.color()
   local picked, color = reaper.GR_SelectColor(reaper.GetMainHwnd())
   if picked == 0 then return nil end -- 0 means the dialog was cancelled
   local r, g, b = reaper.ColorFromNative(color)
   return r / 255, g / 255, b / 255
end

function Ask.parent_dir()
   local project_path = reaper.GetProjectPath()
   if project_path == "" then return "" end
   return project_path:match("^(.*)[\\/].*$") or project_path -- a project at the root of a drive has no parent
end

-- extensions: the dialog's filter, e.g. "Reaper Project File (.rpp)\0*.rpp;*.RPP\0\0"
function Ask.open_file(title, extensions)
   local ok, path = reaper.JS_Dialog_BrowseForOpenFiles(title, Ask.parent_dir(), "", extensions, false)
   if not ok or path == "" then return nil end
   return path
end

function Ask.save_file(title, default_name)
   local ok, path = reaper.JS_Dialog_BrowseForSaveFile(title, Ask.parent_dir(), default_name, "")
   if not ok or path == "" then return nil end
   return path
end

return Ask
