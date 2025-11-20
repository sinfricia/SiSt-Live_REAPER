function Msg(input)
   local str = tostring(input)
   reaper.ShowConsoleMsg(str .. "\n")
end

local project_list = {}
local proj_count = 0


function SaveSetlistToExtState()
   local section = "ProjectList"                 -- You can choose any section name
   local key_proj_count = "Count"
   local key_project_list = "OpenProjects"       -- Key for the project list
   local key_active_proj_name = "ActiveProj"
   local key_active_proj_index = "ActiveProjIdx" -- Key for the index of the currently open project
   local key_playstates = "Playstates"

   -- Prepare the list of project names to save
   local project_names = {}
   local project_playstates = {}
   for _, project in ipairs(project_list) do
      table.insert(project_names, project.name) -- Only store the project name
      table.insert(project_playstates, project.playstate)
   end

   -- Convert the table to a string (comma-separated)
   local project_list_str = table.concat(project_names, ",")

   -- Save the project names to ext_state
   reaper.SetExtState(section, key_project_list, project_list_str, false)

   -- Save the index of the currently active project
   local active_proj_name = ""
   local active_proj_index = -1

   local active_proj, active_proj_name = reaper.EnumProjects(active_proj_index)

   if not active_proj then return end

   if not active_proj_name or active_proj_name == "" then
      active_proj_name = "Unsaved Project"
   else
      active_proj_name = active_proj_name:match("^.+[\\/](.+)$"):gsub("%.rpp$", ""):gsub("%.RPP$", "") or
          active_proj_name
   end

   for i, project in ipairs(project_list) do
      if project.project == active_proj then
         active_proj_index = i
         break
      end
   end

   reaper.SetExtState(section, key_proj_count, tostring(proj_count), false)
   reaper.SetExtState(section, key_active_proj_name, active_proj_name, false)
   reaper.SetExtState(section, key_active_proj_index, tostring(active_proj_index), false)

   -- PlayStates
   local playstates = table.concat(project_playstates, ",")
   reaper.SetExtState(section, key_playstates, playstates, false)
end

-- Function to retrieve the list of all open project tabs from REAPER
function GetProjTabList()
   local i = 0

   -- Use reaper.EnumProjects to loop through all open projects
   while true do
      local project, project_path = reaper.EnumProjects(i)
      local projName

      if not project then break end -- If no more projects, break the loop

      -- If the project has a path, use it
      if project_path == "" then
         project_path = "Unsaved Project"
      else
         -- Extract the project name from the full path (remove directory path)
         projName = project_path:match("^.+[\\/](.+)$"):gsub("%.rpp$", ""):gsub("%.RPP$", "") or project_path
      end

      local project_playstate = reaper.GetPlayStateEx(project)

      -- Add the project path and its project instance to the list
      table.insert(project_list,
         { projName = projName, path = project_path, project = project, index = i, playstate = project_playstate })
      i = i + 1
   end

   proj_count = i

   SaveSetlistToExtState()
end

GetProjTabList()
