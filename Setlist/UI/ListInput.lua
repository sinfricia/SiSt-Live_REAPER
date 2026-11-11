-- @noindex
--[[
SiSt-Live Setlist: ListInput

What the mouse does in the list: clicking and double-clicking entries, drag and drop, the right-click menus of the entries,
the mouse wheel and the scrollbar. This file only reads the gestures; every change to the list or the tabs is an action
of Actions.lua, every question is asked through UI/Ask.lua.

  handle_click(), handle_drag(), handle_drop(), handle_wheel(), handle_scrollbar()     called once per frame by Frame
]]

local Log = require("SiSt-Live_Log")
local log = Log.get("Setlist")
local Window = require("Gui.Window")
local TextField = require("Gui.TextField")
local Data = require("Setlist.Data")
local State = require("Setlist.State")
local Actions = require("Setlist.Actions")
local ViewState = require("Setlist.UI.ViewState")
local List = require("Setlist.UI.List")
local Ask = require("Setlist.UI.Ask")

local view, drag, input, lay, CFG, MOD = ViewState.view, ViewState.drag, ViewState.input, ViewState.lay, ViewState.CFG, ViewState.MOD
local ENTRY = Data.ENTRY

local ListInput = {}

local PROJECT_FILTER = "Reaper Project File (.rpp)\0*.rpp;*.RPP\0\0"

local function clamp(val, min, max)
   return math.max(min, math.min(max, val))
end

-- True if the given modifier key (MOD.CTRL, MOD.SHIFT, MOD.ALT) is currently held.
local function modifier_down(mask)
   return reaper.JS_Mouse_GetState(mask) & mask ~= 0
end

-- Drag and drop -------------------------------------------------------------------------------------------------

local function end_drag()
   if not State.win.mouse.left then
      drag.active = false
      drag.start_y = nil
      drag.drop_idx = nil
      drag.direction = nil
      drag.drop_dir, drag.drop_link, drag.drop_hover, drag.group, drag.texts_only = nil, nil, nil, nil, nil
      drag.threshold_reached = nil
   end
end

function ListInput.handle_drop()
   if not drag.active or State.win.mouse.left then
      end_drag()
      return
   end

   drag.active = false

   if not drag.drop_idx then end_drag() return end -- (released over nothing, or over the dragged entry itself)

   log:debug("  Dropped [" .. drag.list_idx .. "] at list_idx [" .. drag.drop_idx .. "]")

   -- Perform the swap only if the target index has changed (a linking drop (Shift) counts even when the entry stays where it is)
   if drag.drop_idx == drag.list_idx and not drag.drop_link then end_drag() return end

   -- Ctrl: copy. Shift (drop_link): the text entry is linked to the project at the edge of the entry it is dropped on.
   if drag.group then
      Actions.drop_selection(ListInput.selected_entries(), drag.drop_idx, drag.direction, modifier_down(MOD.CTRL),
         drag.drop_link, drag.drop_hover)
   else
      Actions.drop_entry(drag.list_idx, drag.drop_idx, drag.drop_dir or drag.direction, modifier_down(MOD.CTRL),
         drag.drop_link, drag.drop_hover)
   end

   end_drag()
end

function ListInput.handle_drag()
   if #State.list < 2 then return end

   if State.win.mouse.left then
      drag.threshold_reached = math.abs(State.win.mouse.y - State.win.mouse.press_y) > CFG.drag_threshold
   end

   if not drag.active and State.win.mouse.left and not drag.scrolling and not input.press_on_indicator
       and drag.threshold_reached then
      local entry_under_mouse, idx_under_mouse = List.entry_at_mouse(true)

      if not entry_under_mouse then return end

      drag.list_idx = idx_under_mouse
      drag.start_y = State.win.mouse.y
      drag.active = true
      local selected = ListInput.selected_entries()
      drag.group = view.selection[entry_under_mouse] and #selected > 1 -- the whole selection moves
      drag.texts_only = true -- (only text entries can be linked by the drag)
      for _, e in ipairs(drag.group and selected or { entry_under_mouse }) do
         if e.type ~= ENTRY.TEXT then drag.texts_only = false end
      end
      log:debug("Dragging started for: %s", State.list[drag.list_idx].name)
   elseif drag.active and drag.threshold_reached then
      drag.direction = 1
      if State.win.mouse.y < drag.start_y then
         drag.direction = -1
      end

      -- Auto-scroll if mouse is near top or bottom
      if State.win.mouse.y < CFG.title_height - CFG.drag_scroll_margin or State.win.mouse.y > lay.list_h + CFG.title_height + CFG.drag_scroll_margin then
         drag.fractional_scroll = drag.fractional_scroll + CFG.drag_scroll_speed

         if math.abs(drag.fractional_scroll) >= 1 then
            view.scroll_offset = List.apply_manual_scroll(view.scroll_offset,
               math.floor(drag.fractional_scroll * drag.direction), lay.max_scroll)
            drag.fractional_scroll = 0

            log:debug("  drag autoscroll: scrollOffset %s", view.scroll_offset)
         end
      else
         drag.fractional_scroll = 0
      end

      local entry_under_mouse, idx_under_mouse = List.entry_at_mouse()

      if not entry_under_mouse then
         -- below the last entry (empty space in the list): the drop goes to the end of the list
         local _, total_rows = List.layout(State.list)
         local end_y = CFG.title_height + (total_rows - view.scroll_offset) * lay.line_height
         if State.win.mouse.y > end_y and State.win.mouse.y < CFG.title_height + lay.list_h and State.win.mouse.x < gfx.w - CFG.scroll_w then
            drag.drop_idx = #State.list
            drag.drop_dir, drag.drop_hover = 1, #State.list
            drag.drop_link = State.win.mouse.shift and drag.texts_only
            ListInput.handle_drop()
            return
         end
      end

      if not entry_under_mouse or idx_under_mouse == drag.list_idx then
         drag.drop_idx = nil
         ListInput.handle_drop() -- (on release this ends the drag: before, the entry stayed in its "dragged" look)
         return
      end

      if math.abs(State.win.mouse.y - drag.start_y) > CFG.drag_threshold then
         -- Calculate drop index based on mouse position
         -- the row under the mouse (leave a dropzone of 1/3 of the line height: dragging feels quite nice), then the entry
         -- the drop is relative to: the one above that row when dragged down, below it when dragged up
         local row = (State.win.mouse.y + (lay.line_height / 3 * drag.direction) - CFG.title_height) / lay.line_height +
             view.scroll_offset
         local _, total_rows = List.layout(State.list)
         -- (above the first entry: 0, below the last one: past the end, so a drop at either end is possible)
         local hovered = row < 0 and 0 or (row >= total_rows and #State.list + 1 or List.entry_at_row(State.list, row))

         drag.drop_idx = clamp(hovered - drag.direction, 1, #State.list)
         drag.drop_dir = drag.direction
         -- With Shift a text entry is linked to the entry the mouse is over; the drop line is where it always is
         drag.drop_hover = idx_under_mouse
         drag.drop_link = State.win.mouse.shift and drag.texts_only
         -- (inside the selection: nothing, except linking to an entry outside of it)
         if drag.group and view.selection[State.list[drag.drop_idx]]
             and not (drag.drop_link and not view.selection[State.list[drag.drop_hover]]) then
            drag.drop_idx = nil
         end
      end

      ListInput.handle_drop()
   end
end

-- Right-click menus ---------------------------------------------------------------------------------------------

-- items: see Window.build_menu. Opens the menu at the mouse and runs the chosen entry's action.
local function show_menu(items)
   gfx.x, gfx.y = State.win.mouse.x, State.win.mouse.y
   local menu_str, actions = Window.build_menu(items)
   local choice = gfx.showmenu(menu_str)
   if choice > 0 and actions[choice] then actions[choice]() end
end

-- Editing a text entry in place ------------------------------------------------------------------------------------

--- The row of the text entry turns into a text field with the text selected. is_new: the entry was just inserted (it goes
--- again when the edit is cancelled or ends empty).
function ListInput.start_edit(entry, is_new)
   ListInput.end_edit()
   -- (Enter keeps the text, Shift+Enter starts another line)
   local field = TextField.new{ text = entry.name or "", select_all = true, max_length = 1000, multiline = true }
   input.edit = { entry = entry, is_new = is_new, field = field }
   TextField.focus(State.win, field)
end

-- Stops editing without a change (the field gives the keyboard back).
function ListInput.end_edit()
   if input.edit then TextField.blur(State.win, input.edit.field) end
   input.edit, input.edit_event = nil, nil
end

-- Selection --------------------------------------------------------------------------------------------------------

--- The selected entries in list order.
function ListInput.selected_entries()
   local out = {}
   for _, e in ipairs(State.list) do
      if view.selection[e] then out[#out + 1] = e end
   end
   return out
end

local function clear_selection(anchor)
   view.selection = {}
   view.sel_anchor = anchor
end

-- Ctrl+click toggles the entry, Shift+click selects the range from the last clicked entry (Ctrl+Shift adds it).
local function modify_selection(entry, idx, ctrl, shift)
   if shift then
      local from = nil
      for i, e in ipairs(State.list) do
         if e == view.sel_anchor then from = i break end
      end
      from = from or idx
      if not ctrl then view.selection = {} end
      for i = math.min(from, idx), math.max(from, idx) do view.selection[State.list[i]] = true end
   else
      view.selection[entry] = not view.selection[entry] or nil
      view.sel_anchor = entry
   end
end

--- Once per frame after the list is drawn: acts on what the field reported. Enter or a click elsewhere keeps the new text
--- (an empty one is not kept), Esc drops it.
function ListInput.handle_edit()
   -- entries that are gone leave the selection
   if next(view.selection) then
      local present = {}
      for _, e in ipairs(State.list) do present[e] = true end
      for e in pairs(view.selection) do
         if not present[e] then view.selection[e] = nil end
      end
   end

   local edit = input.edit
   if not edit then return end

   local idx = nil
   for i, e in ipairs(State.list) do
      if e == edit.entry then idx = i break end
   end
   local ev = input.edit_event or {}
   input.edit_event = nil
   if not idx then ListInput.end_edit() return end -- the entry is gone

   if ev.submitted or ev.blurred or ev.escape then
      local text = edit.field.text:gsub("%s+$", "") -- (no empty lines at the end)
      local keep = not ev.escape and text:match("%S") ~= nil
      ListInput.end_edit()
      if keep then
         if text ~= edit.entry.name then Actions.rename_text(edit.entry, text) end
      elseif edit.is_new then
         Actions.delete_entry(idx)
      end
   end
end

local function delete_text(entry, idx)
   Actions.delete_entry(idx)
end

local function replace_project(entry)
   local path = Ask.open_file("Replace Project Entry", PROJECT_FILTER)
   if path then Actions.replace_project(entry, path) end
end

local function show_text_menu(entry, idx)
   show_menu({
      { label = "-- " .. entry.name, disabled = true },
      { separator = true },
      { label = "Edit Text", action = function() ListInput.start_edit(entry) end },
      { label = "Link to Project Above", disabled = entry.link == "above" or not Data.can_link(State.list, idx, "above"),
         action = function() Actions.link_text(idx, "above") end },
      { label = "Link to Project Below", disabled = entry.link == "below" or not Data.can_link(State.list, idx, "below"),
         action = function() Actions.link_text(idx, "below") end },
      { label = "Unlink", disabled = not entry.link, action = function() Actions.unlink_text(idx) end },
      { separator = true },
      { label = "Color Entry", action = function()
         local r, g, b = Ask.color()
         if r then Actions.color_text(entry, r, g, b) end
      end },
      { label = "Duplicate", action = function() Actions.duplicate_text(idx) end },
      { label = "Delete Text Entry", action = function() delete_text(entry, idx) end },
   })
end

-- The menu for several selected entries: every action applies to the entries it fits, one confirmation for all of them.
local function show_selection_menu()
   local entries = ListInput.selected_entries()
   local texts, projects, linked = {}, {}, 0
   for _, e in ipairs(entries) do
      if e.type == ENTRY.TEXT then
         texts[#texts + 1] = e
         if e.link then linked = linked + 1 end
      elseif e.type == ENTRY.PROJECT then
         projects[#projects + 1] = e
      end
   end

   local items = { { label = #entries .. " Entries Selected", disabled = true }, { separator = true } }
   if #texts > 0 then
      items[#items + 1] = { label = "Color Entries", action = function()
         local r, g, b = Ask.color()
         if r then Actions.color_texts(texts, r, g, b) end
      end }
   end
   if linked > 0 then
      items[#items + 1] = { label = "Unlink", action = function() Actions.unlink_texts(texts) end }
   end
   items[#items + 1] = { separator = true }
   if #projects > 0 then
      items[#items + 1] = { label = "Close Projects", action = function()
         if Ask.confirm("Close the " .. #projects .. " selected projects?", "Close Projects") then
            local pointers = {}
            for _, e in ipairs(projects) do pointers[#pointers + 1] = e.proj end
            local closed = Actions.close_projects(pointers)
            if closed < #projects then
               reaper.MB((#projects - closed) .. " of the projects were not closed: they play, record, or are the last " ..
                  "open project.", "Close Projects", 0)
            end
         end
      end }
   end
   if #texts > 0 then
      items[#items + 1] = { label = "Delete Text Entries", action = function()
         Actions.delete_entries(texts)
      end }
   end
   show_menu(items)
end

local function show_project_menu(entry)
   show_menu({
      { label = tostring(entry.tab_idx or "?") .. ". " .. entry.name, disabled = true },
      { separator = true },
      { label = "Replace Project", action = function() replace_project(entry) end },
      { label = "Close Project", action = function()
         if Ask.confirm("Close the project '" .. entry.name .. "'?", "Close Project") then
            Actions.close_project(entry)
         end
      end },
   })
end

local function show_missing_menu(entry, idx)
   show_menu({
      { label = "Missing", disabled = true },
      { separator = true },
      { label = "Find Project", action = function() replace_project(entry) end },
      { label = "Remove Project", action = function()
         Actions.delete_entry(idx)
      end },
   })
end

-- Clicks, wheel and scrollbar -----------------------------------------------------------------------------------

function ListInput.handle_click()
   -- a click anywhere that is not on an entry (or a Ctrl / Shift click) ends the selection
   local mouse = State.win.mouse
   if mouse.left_pressed and not (mouse.ctrl or mouse.shift) and not List.entry_at_mouse(true) then
      clear_selection(nil)
   end

   -- Ctrl / Shift pressed on a selected entry waited to see whether it is a drag (of the whole selection: a copy with
   -- Ctrl, linked with Shift); a click applies it
   if input.pending_mod and not State.win.mouse.left then
      local pending = input.pending_mod
      input.pending_mod = nil
      if not drag.threshold_reached then
         for i, e in ipairs(State.list) do
            if e == pending.entry then modify_selection(e, i, pending.ctrl, pending.shift) break end
         end
      end
   end

   -- a plain press on one of several selected entries waited to see whether it is a drag; a click ends the selection
   if input.pending_clear and not State.win.mouse.left then
      local entry = input.pending_clear
      input.pending_clear = nil
      if not drag.threshold_reached then -- it was a click, not a drag: it ends the selection, and a project is jumped to
         clear_selection(entry)
         if entry.type == ENTRY.PROJECT and entry.proj and reaper.ValidatePtr(entry.proj, "ReaProject*") then
            if entry.proj ~= State.current_proj then view.list_click_target = entry.proj end
            reaper.SelectProjectInstance(entry.proj)
         end
      end
   end

   if (input.left_click_handled and input.right_click_handled) or drag.active or drag.scrolling then
      return
   end

   local entry, idx = List.entry_at_mouse(true)
   if not entry then
      -- Right-click anywhere outside the entries: the window menu (docking, default position)
      if State.win.mouse.right and not input.right_click_handled then
         input.right_click_handled = true
         State.win:show_context_menu()
      end
      return
   end

   if State.win.mouse.left and not input.left_click_handled then
      local now = reaper.time_precise()
      local is_double = input.last_click_idx == idx and (now - input.last_click_time) <= CFG.double_click_threshold
      input.double_click = is_double
      input.last_click_time = now
      input.last_click_idx = idx

      log:debug("Handling left click on entry at list_idx [" .. idx .. "]" .. (is_double and " (double)" or ""))

      if mouse.ctrl or mouse.shift then
         if view.selection[entry] then
            input.pending_mod = { entry = entry, ctrl = mouse.ctrl, shift = mouse.shift } -- (a drag moves the selection)
         else
            modify_selection(entry, idx, mouse.ctrl, mouse.shift) -- selecting: no jump, no editing
         end
      elseif view.selection[entry] and #ListInput.selected_entries() > 1 then
         input.pending_clear = entry -- (it may be the start of a drag of the whole selection)
      else
         clear_selection(entry)
         if entry.type == ENTRY.TEXT then view.selection[entry] = true end -- a text entry is selected by a plain click
      end

      if mouse.ctrl or mouse.shift then
         -- (nothing else happens)
      elseif input.pending_clear == entry then
         -- (waiting: a drag moves the whole selection and must not switch the active project; a click does, on release)
      elseif entry.type == ENTRY.TEXT then
         if is_double then
            ListInput.start_edit(entry)
         elseif modifier_down(MOD.ALT) then
            delete_text(entry, idx)
         end
      elseif entry.type == ENTRY.PROJECT then
         if entry.proj ~= State.current_proj then
            view.list_click_target = entry.proj -- lets Main tell this switch apart from one made in REAPER
         end
         reaper.SelectProjectInstance(entry.proj)
      end

      input.left_click_handled = true
   end

   if State.win.mouse.right and not input.right_click_handled then
      log:debug("Handling right click on entry " .. entry.name .. " at index " .. idx)

      if view.selection[entry] and #ListInput.selected_entries() > 1 then
         show_selection_menu()
      elseif entry.type == ENTRY.TEXT then
         show_text_menu(entry, idx)
      elseif entry.type == ENTRY.PROJECT then
         show_project_menu(entry)
      elseif entry.type == ENTRY.MISSING then
         show_missing_menu(entry, idx)
      end

      input.right_click_handled = true
   end
end

function ListInput.handle_wheel()
   local wheel = State.win.mouse.wheel -- the Window reads (and resets) gfx.mouse_wheel once per frame
   if wheel ~= 0 and State.win.mouse.ctrl then
      List.apply_zoom(view.zoom_level + (wheel > 0 and 1 or -1))
   elseif wheel ~= 0 then
      -- one notch (120) = one row, the same in both directions
      local steps = math.max(1, math.floor(math.abs(wheel) / 100 + 0.5))
      local delta = wheel > 0 and -steps or steps
      view.scroll_offset = List.apply_manual_scroll(view.scroll_offset, delta, lay.max_scroll)
   end
   -- Hard limit only (e.g. the list got shorter). Rows beyond lay.max_scroll are allowed here on purpose:
   -- they are what the follow-scroll leaves behind.
   view.scroll_offset = clamp(view.scroll_offset, 0, lay.follow_max_scroll)
end

function ListInput.handle_scrollbar()
   local mouse_on_scrollbar = List.mouse_in_rect(gfx.w - CFG.scroll_w, lay.scroll_y, CFG.scroll_w, lay.scroll_h)

   if State.win.mouse.left and mouse_on_scrollbar and not drag.active and not drag.scrolling then
      drag.scrolling = true
      drag.scrollbar_grab_start = State.win.mouse.y
      drag.scrollbar_grab_offset = State.win.mouse.y - lay.scroll_y
   elseif not State.win.mouse.left then
      drag.scrolling = false
      drag.scrollbar_grab_start = 0
      drag.scrollbar_grab_offset = 0
   end

   if drag.scrolling and drag.scrollbar_grab_start ~= State.win.mouse.y then
      local scroll_track_height = lay.list_h + CFG.title_height
      local empty_scroll_h = scroll_track_height - lay.scroll_h
      local new_scroll_y = clamp(State.win.mouse.y - drag.scrollbar_grab_offset, 0, empty_scroll_h)

      view.scroll_offset = math.floor((new_scroll_y / empty_scroll_h) * lay.max_scroll)
      view.scroll_offset = clamp(view.scroll_offset, 0, lay.max_scroll)
      log:debug("Scrolling to scrollOffset: " .. view.scroll_offset)
   end
end

return ListInput
