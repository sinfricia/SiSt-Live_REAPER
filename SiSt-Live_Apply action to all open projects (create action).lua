function Msg(input)
    local str = tostring(input)
    reaper.ShowConsoleMsg(str .. "\n")
end

-- Variables to manage the action prompt session
local session_mode = 1
local init_id = 0
local section_id = 0
local action_id = nil
local gfx_w, gfx_h = 400, 300
local mouse_handled = false

-- Colors and fonts
local colors = {
    background = { 0.2, 0.2, 0.2 },     -- Dark gray
    text = { 1, 1, 1 },                 -- White
    checkbox = { 0.8, 0.8, 0.8 },       -- Light gray
    checkbox_checked = { 0.3, 0.7, 0.3 }, -- Green
    button = { 0.1, 0.5, 0.9 },         -- Blue
    button_text = { 1, 1, 1 }           -- White
}

local fonts = {
    label = { "Arial", 16 },
    button = { "Arial", 14 }
}

-- Function to handle the selected action
function OnActionSelected(action_id)
    -- Get the action's name
    local action_name = reaper.CF_GetCommandText(section_id, action_id)
    if not action_name then
        reaper.ShowMessageBox("Failed to retrieve action name.", "Error", 0)
        return
    end

    -- Sanitize the action name for the file
    local sanitized_action_name = action_name:gsub('[*\\:<>?/|"%c]+', '-')

    -- Ask if the user wants to add project selection GUI
    local choice = reaper.ShowMessageBox(
        "Would you like the created script to prompt for which projects to apply the action to?",
        "Project Selection",
        4 -- Yes/No dialog
    )

    local create_gui = (choice == 6) -- Yes = 6, No = 7

    -- Get the OS-specific path separator
    local path_separator = package.config:sub(1, 1) -- This returns '\' on Windows and '/' on Unix-based systems

    -- Construct the directory path
    local directory_path = reaper.GetResourcePath() ..
    path_separator .. "Scripts" .. path_separator .. "Apply to all projects (created actions)"

    -- Check if the directory exists, and if not, create it
    reaper.RecursiveCreateDirectory(directory_path, 0)

    -- Define the base script name
    local script_name_base = "SiSt-Live_Apply action to all open_projects_" .. sanitized_action_name

    -- Construct the path to the script (using the correct separator)
    local script_path = directory_path .. path_separator .. script_name_base .. ".lua"

    -- If create_gui is true, use a different script path
    if create_gui then
        script_path = directory_path .. path_separator .. script_name_base .. "_GUI.lua"
    end

    Msg(script_path)

    -- Generate the default script content
    local script_content_all = [[
-- This script applies the action to all open projects
local action_id = ]] .. action_id .. [[

-- Function to apply action to all open projects
local function apply_action_to_all_projects()
    local main_project = reaper.EnumProjects(-1, "")
    local i = 0
    while true do
        local proj = reaper.EnumProjects(i)
        if not proj then break end
        reaper.SelectProjectInstance(proj)
        reaper.Main_OnCommand(action_id, 0)
        i = i + 1
    end
    -- Reselect the main project
    reaper.SelectProjectInstance(main_project)
end

apply_action_to_all_projects()
]]

    -- Generate the GUI version script content
    local script_content_gui = [[
-- Initialize variables
local session_mode = 1
local init_id = 0
local section_id = 0
local action_id = ]] .. action_id .. [[

local project_list = {}
local selected_projects = {}
local gfx_w, gfx_h = 400, 300
local mouse_handled = false
local all_selected = true -- New variable for the toggle button

-- Colors and fonts
local colors = {
    background = {0.2, 0.2, 0.2}, -- Dark gray
    text = {1, 1, 1}, -- White
    checkbox = {0.8, 0.8, 0.8}, -- Light gray
    checkbox_checked = {0.3, 0.7, 0.3}, -- Green
    button = {0.1, 0.5, 0.9}, -- Blue
    button_text = {1, 1, 1} -- White
}

local fonts = {
    label = {"Arial", 16},
    button = {"Arial", 14}
}

-- Function to build a list of open projects
local function get_project_list()
    project_list = {}
    local i = 0
    while true do
        local proj = reaper.EnumProjects(i)
        if not proj then break end
        local _, name = reaper.EnumProjects(i, "")

        if not name or name == "" then
          name = "Unsaved Project"
        end

        -- Remove the path and .RPP extension from the project name
        local short_name = name:match("([^/\\]+)$"):gsub("%.rpp$", "", 1):gsub("%.RPP$", "", 1)
        table.insert(project_list, {proj = proj, name = short_name, checked = true})
        i = i + 1
    end
end

-- Function to execute the action on selected projects
local function apply_action_to_selected_projects(action_id, selected_projects)
    reaper.PreventUIRefresh(-1)
    local main_project = reaper.EnumProjects(-1, "")
    for _, proj in ipairs(selected_projects) do
        --reaper.Undo_BeginBlock2(proj)
        reaper.SelectProjectInstance(proj)
        reaper.Main_OnCommand(action_id, 0)
        --reaper.Undo_EndBlock("", 0)
    end
    reaper.SelectProjectInstance(main_project)
    reaper.PreventUIRefresh(1)
end

-- Function to set up the GUI
local function setup_gui()
    -- Adjust window size based on number of projects
    local num_projects = #project_list
    gfx_w = 400
    gfx_h = 100 + (num_projects * 30) + 70  -- 30px per project, 40px for Apply button and margin

    -- Get the viewport dimensions, which excludes taskbars, etc.
    local left, top, right, bottom = reaper.JS_Window_GetViewportFromRect(0, 0, 1920, 1080, true)

    -- Calculate the screen width and height from the viewport
    local screen_w = right - left
    local screen_h = bottom - top

    -- Position window in the center of the screen
    local x_pos = (screen_w - gfx_w) / 2 + left
    local y_pos = (screen_h - gfx_h) / 2 + top

    gfx.init("Select Projects - Action: " .. reaper.kbd_getTextFromCmd(action_id, section_id), gfx_w, gfx_h, 0, x_pos, y_pos)
    gfx.setfont(1, table.unpack(fonts.label))
end

-- Function to render the GUI
local function render_gui()
    gfx.set(colors.background[1], colors.background[2], colors.background[3])
    gfx.rect(0, 0, gfx_w, gfx_h, true)

    local margin = 10
    local checkbox_size = 20
    local button_width = 120
    local button_height = 30
    local y = margin
    local mouse_x, mouse_y = gfx.mouse_x, gfx.mouse_y
    local mouse_down = gfx.mouse_cap & 1 == 1

    -- Display action text
    gfx.set(colors.text[1], colors.text[2], colors.text[3])
    gfx.x, gfx.y = margin, y
    gfx.drawstr("Select projects to apply the following action to: " .. reaper.kbd_getTextFromCmd(action_id, section_id))

    -- Draw checkboxes for each project
    y = y + 30  -- Starting position for projects
    for i, project in ipairs(project_list) do
        local checkbox_x = margin
        local checkbox_y = y

        -- Draw checkbox
        local color = project.checked and colors.checkbox_checked or colors.checkbox
        gfx.set(color[1], color[2], color[3])
        gfx.rect(checkbox_x, checkbox_y, checkbox_size, checkbox_size, true)

        -- Draw checkbox border
        gfx.set(0, 0, 0)
        gfx.rect(checkbox_x, checkbox_y, checkbox_size, checkbox_size, false)

        -- Draw project name
        gfx.set(colors.text[1], colors.text[2], colors.text[3])
        gfx.x, gfx.y = checkbox_x + checkbox_size + margin, checkbox_y
        gfx.drawstr(project.name)

        -- Check for checkbox interaction
        if mouse_down and not mouse_handled and
           mouse_x > checkbox_x and mouse_x < checkbox_x + checkbox_size and
           mouse_y > checkbox_y and mouse_y < checkbox_y + checkbox_size then
            project.checked = not project.checked
            mouse_handled = true -- Mark the mouse event as handled
        end

        y = y + checkbox_size + margin
    end

    -- Draw "Apply" button (move it higher to reduce the gap)
    local button_x = (gfx_w - button_width) / 2
    local button_y = gfx_h - margin - button_height - 20 -- Move it up 20px
    gfx.set(colors.button[1], colors.button[2], colors.button[3])
    gfx.rect(button_x, button_y, button_width, button_height, true)

    -- Draw button border
    gfx.set(0, 0, 0)
    gfx.rect(button_x, button_y, button_width, button_height, false)

    -- Draw button text
    gfx.set(colors.button_text[1], colors.button_text[2], colors.button_text[3])
    gfx.setfont(1, table.unpack(fonts.button))
    gfx.x, gfx.y = button_x + margin, button_y + (button_height - gfx.texth) / 2
    gfx.drawstr("Apply")

    -- Handle "Apply" button interaction
    if mouse_down and mouse_x > button_x and mouse_x < button_x + button_width
        and mouse_y > button_y and mouse_y < button_y + button_height then
        -- Gather selected projects
        selected_projects = {}
        for _, project in ipairs(project_list) do
            if project.checked then
                table.insert(selected_projects, project.proj)
            end
        end

        gfx.quit()

        -- If no projects selected, show a message
        if #selected_projects == 0 then
            reaper.ShowMessageBox("No projects selected. Action canceled.", "Info", 0)
        else
            apply_action_to_selected_projects(action_id, selected_projects)
        end
    end

    -- Draw "Toggle All" button
    local toggle_button_y = gfx_h - margin - 2 * button_height - 30
    gfx.set(colors.button[1], colors.button[2], colors.button[3])
    gfx.rect(button_x, toggle_button_y, button_width, button_height, true)

    -- Draw button border
    gfx.set(0, 0, 0)
    gfx.rect(button_x, toggle_button_y, button_width, button_height, false)

    -- Draw button text
    gfx.set(colors.button_text[1], colors.button_text[2], colors.button_text[3])
    gfx.setfont(1, table.unpack(fonts.button))
    gfx.x, gfx.y = button_x + margin, toggle_button_y + (button_height - gfx.texth) / 2
    gfx.drawstr(all_selected and "Deselect All" or "Select All")

    -- Handle "Toggle All" button interaction
    if mouse_down and mouse_x > button_x and mouse_x < button_x + button_width
        and mouse_y > toggle_button_y and mouse_y < toggle_button_y + button_height then
        if not mouse_handled then
            all_selected = not all_selected
            for _, project in ipairs(project_list) do
                project.checked = all_selected
            end
            mouse_handled = true -- Mark the mouse event as handled
        end
    end

    gfx.update()

    -- Reset mouse_handled when the mouse button is released
    if not mouse_down then
        mouse_handled = false
    end

    if gfx.getchar() >= 0 then reaper.defer(render_gui) end
end

-- Function to handle the selected action
function on_action_selected(action_id)
    -- Get the list of projects
    get_project_list()

    -- Set up and render the GUI
    setup_gui()
    render_gui()
end

-- Start the action prompt session
-- Function to render the custom action prompt GUI
local function render_action_prompt_gui()
    -- Get the viewport dimensions, which excludes taskbars, etc.
    local left, top, right, bottom = reaper.JS_Window_GetViewportFromRect(0, 0, 1920, 1080, true)

    -- Calculate the screen width and height from the viewport
    local screen_w = right - left
    local screen_h = bottom - top

    -- Define window size
    local gfx_w, gfx_h = 400, 100

    -- Position window in the center of the screen
    local x_pos = (screen_w - gfx_w) / 2 + left
    local y_pos = (screen_h - gfx_h) / 2 + top

    -- Initialize gfx window (borderless)
    gfx.init("Action Selection", gfx_w, gfx_h, 0, x_pos, y_pos)

    -- Colors and fonts for the message
    local colors = {
        background = {0.2, 0.2, 0.2}, -- Dark gray
        text = {1, 1, 1} -- White
    }
    local fonts = {"Arial", 16}

    -- Set background color
    gfx.set(colors.background[1], colors.background[2], colors.background[3])
    gfx.rect(0, 0, gfx_w, gfx_h, true)

    -- Display the message centered
    gfx.set(colors.text[1], colors.text[2], colors.text[3])
    gfx.setfont(1, table.unpack(fonts))
    gfx.x = (gfx_w - gfx.measurestr("Please select an action to apply to the projects.")) / 2
    gfx.y = (gfx_h - gfx.texth) / 2
    gfx.drawstr("Please select an action to apply to the projects.")

    gfx.update()
end

-- Function to handle the action selection
local function poll_action()
    -- Call the action selection prompt
    action_id = reaper.PromptForAction(0, init_id, section_id)

    -- If the user hasn't selected an action yet, keep the GUI open and ask again
    if action_id == 0 then
        reaper.defer(poll_action) -- Keep asking for the action until one is selected
    elseif action_id == -1 then
        -- Handle action cancellation
        reaper.ShowMessageBox("Action canceled.", "Info", 0)
        gfx.quit()  -- Close the GUI after cancellation
    else
        -- Once an action is selected, close the GUI and continue
        gfx.quit()  -- Close the custom GUI
        on_action_selected(action_id)  -- Execute the action with the selected projects
    end
end

on_action_selected(action_id)
]]

    -- Write the  script to a file
    local file = io.open(script_path, "w")
    if not file then
        reaper.ShowMessageBox("Error creating script file.", "Error", 0)
        return
    end

    if create_gui then
        file:write(script_content_gui)
    else
        file:write(script_content_all)
    end

    file:close()

    -- Add both scripts to REAPER's action list
    local success = reaper.AddRemoveReaScript(true, section_id, script_path, true)

    if success then
        reaper.ShowMessageBox("Scripts added successfully.", "Success", 0)
    else
        reaper.ShowMessageBox("Failed to add one or more scripts to REAPER's action list.", "Error", 0)
    end
end

-- Start the action prompt session
-- Function to render the custom action prompt GUI
local function render_action_prompt_gui()
    -- Get the viewport dimensions, which excludes taskbars, etc.
    local left, top, right, bottom = reaper.JS_Window_GetViewportFromRect(0, 0, 1920, 1080, true)

    -- Calculate the screen width and height from the viewport
    local screen_w = right - left
    local screen_h = bottom - top

    -- Define window size
    local gfx_w, gfx_h = 500, 100

    -- Position window in the center of the screen
    local x_pos = (screen_w - gfx_w) / 2 + left
    local y_pos = (screen_h - gfx_h) / 2 + top

    -- Initialize gfx window (borderless)
    gfx.init("Action Selection", gfx_w, gfx_h, 0, x_pos, y_pos)

    -- Colors and fonts for the message
    local colors = {
        background = { 0.2, 0.2, 0.2 }, -- Dark gray
        text = { 1, 1, 1 }            -- White
    }
    local fonts = { "Arial", 16 }

    -- Set background color
    gfx.set(colors.background[1], colors.background[2], colors.background[3])
    gfx.rect(0, 0, gfx_w, gfx_h, true)

    -- Display the message centered
    gfx.set(colors.text[1], colors.text[2], colors.text[3])
    gfx.setfont(1, table.unpack(fonts))
    gfx.x = (gfx_w - gfx.measurestr("Please select an action that you want to create an 'Apply to all projects' version of.")) /
    2
    gfx.y = (gfx_h - gfx.texth) / 2
    gfx.drawstr("Please select an action that you want to create an 'Apply to all projects' version of.")

    gfx.update()
end

-- Function to handle the action selection
local function poll_action()
    -- Call the action selection prompt
    action_id = reaper.PromptForAction(0, init_id, section_id)

    -- If the user hasn't selected an action yet, keep the GUI open and ask again
    if gfx.getchar() == -1 then
        reaper.PromptForAction(-1, 0, 0)
    elseif action_id == 0 then
        reaper.defer(poll_action) -- Keep asking for the action until one is selected
    elseif action_id == -1 then
        -- Handle action cancellation
        reaper.ShowMessageBox("Action canceled.", "Info", 0)
        reaper.PromptForAction(-1, 0, 0)
        gfx.quit() -- Close the GUI after cancellation
    else
        -- Once an action is selected, close the GUI and continue
        gfx.quit()                  -- Close the custom GUI
        reaper.PromptForAction(-1, 0, 0)
        OnActionSelected(action_id) -- Execute the action with the selected projects
    end
end

reaper.PromptForAction(session_mode, init_id, section_id)
render_action_prompt_gui()
poll_action()
