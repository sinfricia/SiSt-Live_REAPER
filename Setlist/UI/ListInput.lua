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

local gui, MOD = ViewState.gui, ViewState.MOD
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
   if not gui.leftClick then
      gui.draggingEntry = false
      gui.dragStartY = nil
      gui.dropIdx = nil
      gui.dragDirection = nil
      gui.dropDir, gui.dropLink, gui.dropHover, gui.dragGroup, gui.dragTextsOnly = nil, nil, nil, nil, nil
      gui.dragThreshReached = nil
   end
end

function ListInput.handle_drop()
   if not gui.draggingEntry or gui.leftClick then
      end_drag()
      return
   end

   gui.draggingEntry = false

   if not gui.dropIdx then end_drag() return end -- (released over nothing, or over the dragged entry itself)

   log:debug("  Dropped [" .. gui.dragEntryListIdx .. "] at listIdx [" .. gui.dropIdx .. "]")

   -- Perform the swap only if the target index has changed (a linking drop (Shift) counts even when the entry stays where it is)
   if gui.dropIdx == gui.dragEntryListIdx and not gui.dropLink then end_drag() return end

   -- Ctrl: copy. Shift (dropLink): the text entry is linked to the project at the edge of the entry it is dropped on.
   if gui.dragGroup then
      Actions.drop_selection(ListInput.selected_entries(), gui.dropIdx, gui.dragDirection, modifier_down(MOD.CTRL),
         gui.dropLink, gui.dropHover)
   else
      Actions.drop_entry(gui.dragEntryListIdx, gui.dropIdx, gui.dropDir or gui.dragDirection, modifier_down(MOD.CTRL),
         gui.dropLink, gui.dropHover)
   end

   end_drag()
end

function ListInput.handle_drag()
   if #State.list < 2 then return end

   if gui.leftClick then
      gui.dragThreshReached = math.abs(State.win.mouse.y - gui.lastClickDownPos.y) > gui.dragThreshold
   end

   if not gui.draggingEntry and gui.leftClick and not gui.draggingScroll and not gui.pressOnIndicator
       and gui.dragThreshReached then
      local entryUnderMouse, idxUnderMouse = List.entry_at_mouse(true)

      if not entryUnderMouse then return end

      gui.dragEntryListIdx = idxUnderMouse
      gui.dragStartY = State.win.mouse.y
      gui.draggingEntry = true
      local selected = ListInput.selected_entries()
      gui.dragGroup = gui.selection[entryUnderMouse] and #selected > 1 -- the whole selection moves
      gui.dragTextsOnly = true -- (only text entries can be linked by the drag)
      for _, e in ipairs(gui.dragGroup and selected or { entryUnderMouse }) do
         if e.type ~= ENTRY.TEXT then gui.dragTextsOnly = false end
      end
      log:debug("Dragging started for: %s", State.list[gui.dragEntryListIdx].name)
   elseif gui.draggingEntry and gui.dragThreshReached then
      gui.dragDirection = 1
      if State.win.mouse.y < gui.dragStartY then
         gui.dragDirection = -1
      end

      -- Auto-scroll if mouse is near top or bottom
      if State.win.mouse.y < gui.titleHeight - gui.dragScrollMargin or State.win.mouse.y > gui.listH + gui.titleHeight + gui.dragScrollMargin then
         gui.fractionalScrollOffset = gui.fractionalScrollOffset + gui.dragScrollSpeed

         if math.abs(gui.fractionalScrollOffset) >= 1 then
            gui.scrollOffset = List.apply_manual_scroll(gui.scrollOffset,
               math.floor(gui.fractionalScrollOffset * gui.dragDirection), gui.maxScroll)
            gui.fractionalScrollOffset = 0

            log:debug("  drag autoscroll: scrollOffset %s", gui.scrollOffset)
         end
      else
         gui.fractionalScrollOffset = 0
      end

      local entryUnderMouse, idxUnderMouse = List.entry_at_mouse()

      if not entryUnderMouse then
         -- below the last entry (empty space in the list): the drop goes to the end of the list
         local _, totalRows = List.layout(State.list)
         local endY = gui.titleHeight + (totalRows - gui.scrollOffset) * gui.lineHeight
         if State.win.mouse.y > endY and State.win.mouse.y < gui.titleHeight + gui.listH and State.win.mouse.x < gfx.w - gui.scrollW then
            gui.dropIdx = #State.list
            gui.dropDir, gui.dropHover = 1, #State.list
            gui.dropLink = State.win.mouse.shift and gui.dragTextsOnly
            ListInput.handle_drop()
            return
         end
      end

      if not entryUnderMouse or idxUnderMouse == gui.dragEntryListIdx then
         gui.dropIdx = nil
         ListInput.handle_drop() -- (on release this ends the drag: before, the entry stayed in its "dragged" look)
         return
      end

      if math.abs(State.win.mouse.y - gui.dragStartY) > gui.dragThreshold then
         -- Calculate drop index based on mouse position
         -- the row under the mouse (leave a dropzone of 1/3 of the line height: dragging feels quite nice), then the entry
         -- the drop is relative to: the one above that row when dragged down, below it when dragged up
         local row = (State.win.mouse.y + (gui.lineHeight / 3 * gui.dragDirection) - gui.titleHeight) / gui.lineHeight +
             gui.scrollOffset
         local _, totalRows = List.layout(State.list)
         -- (above the first entry: 0, below the last one: past the end, so a drop at either end is possible)
         local hovered = row < 0 and 0 or (row >= totalRows and #State.list + 1 or List.entry_at_row(State.list, row))

         gui.dropIdx = clamp(hovered - gui.dragDirection, 1, #State.list)
         gui.dropDir = gui.dragDirection
         -- With Shift a text entry is linked to the entry the mouse is over; the drop line is where it always is
         gui.dropHover = idxUnderMouse
         gui.dropLink = State.win.mouse.shift and gui.dragTextsOnly
         -- (inside the selection: nothing, except linking to an entry outside of it)
         if gui.dragGroup and gui.selection[State.list[gui.dropIdx]]
             and not (gui.dropLink and not gui.selection[State.list[gui.dropHover]]) then
            gui.dropIdx = nil
         end
      end

      ListInput.handle_drop()
   end
end

-- Right-click menus ---------------------------------------------------------------------------------------------

-- items: see Window.build_menu. Opens the menu at the mouse and runs the chosen entry's action.
local function show_menu(items)
   gfx.x, gfx.y = State.win.mouse.x, State.win.mouse.y
   local menuStr, actions = Window.build_menu(items)
   local choice = gfx.showmenu(menuStr)
   if choice > 0 and actions[choice] then actions[choice]() end
end

-- Editing a text entry in place ------------------------------------------------------------------------------------

--- The row of the text entry turns into a text field with the text selected. is_new: the entry was just inserted (it goes
--- again when the edit is cancelled or ends empty).
function ListInput.start_edit(entry, is_new)
   ListInput.end_edit()
   -- (Enter keeps the text, Shift+Enter starts another line)
   local field = TextField.new{ text = entry.name or "", select_all = true, max_length = 1000, multiline = true }
   gui.edit = { entry = entry, is_new = is_new, field = field }
   TextField.focus(State.win, field)
end

-- Stops editing without a change (the field gives the keyboard back).
function ListInput.end_edit()
   if gui.edit then TextField.blur(State.win, gui.edit.field) end
   gui.edit, gui.editEvent = nil, nil
end

-- Selection --------------------------------------------------------------------------------------------------------

--- The selected entries in list order.
function ListInput.selected_entries()
   local out = {}
   for _, e in ipairs(State.list) do
      if gui.selection[e] then out[#out + 1] = e end
   end
   return out
end

local function clear_selection(anchor)
   gui.selection = {}
   gui.selAnchor = anchor
end

-- Ctrl+click toggles the entry, Shift+click selects the range from the last clicked entry (Ctrl+Shift adds it).
local function modify_selection(entry, idx, ctrl, shift)
   if shift then
      local from = nil
      for i, e in ipairs(State.list) do
         if e == gui.selAnchor then from = i break end
      end
      from = from or idx
      if not ctrl then gui.selection = {} end
      for i = math.min(from, idx), math.max(from, idx) do gui.selection[State.list[i]] = true end
   else
      gui.selection[entry] = not gui.selection[entry] or nil
      gui.selAnchor = entry
   end
end

--- Once per frame after the list is drawn: acts on what the field reported. Enter or a click elsewhere keeps the new text
--- (an empty one is not kept), Esc drops it.
function ListInput.handle_edit()
   -- entries that are gone leave the selection
   if next(gui.selection) then
      local present = {}
      for _, e in ipairs(State.list) do present[e] = true end
      for e in pairs(gui.selection) do
         if not present[e] then gui.selection[e] = nil end
      end
   end

   local edit = gui.edit
   if not edit then return end

   local idx = nil
   for i, e in ipairs(State.list) do
      if e == edit.entry then idx = i break end
   end
   local ev = gui.editEvent or {}
   gui.editEvent = nil
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
      { label = tostring(entry.tabIdx or "?") .. ". " .. entry.name, disabled = true },
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
   if gui.pendingMod and not gui.leftClick then
      local pending = gui.pendingMod
      gui.pendingMod = nil
      if not gui.dragThreshReached then
         for i, e in ipairs(State.list) do
            if e == pending.entry then modify_selection(e, i, pending.ctrl, pending.shift) break end
         end
      end
   end

   -- a plain press on one of several selected entries waited to see whether it is a drag; a click ends the selection
   if gui.pendingClear and not gui.leftClick then
      local entry = gui.pendingClear
      gui.pendingClear = nil
      if not gui.dragThreshReached then -- it was a click, not a drag: it ends the selection, and a project is jumped to
         clear_selection(entry)
         if entry.type == ENTRY.PROJECT and entry.proj and reaper.ValidatePtr(entry.proj, "ReaProject*") then
            if entry.proj ~= State.current_proj then gui.listClickTarget = entry.proj end
            reaper.SelectProjectInstance(entry.proj)
         end
      end
   end

   if (gui.leftClickHandled and gui.rightClickHandled) or gui.draggingEntry or gui.draggingScroll then
      return
   end

   local entry, idx = List.entry_at_mouse(true)
   if not entry then
      -- Right-click anywhere outside the entries: the window menu (docking, default position)
      if gui.rightClick and not gui.rightClickHandled then
         gui.rightClickHandled = true
         State.win:show_context_menu()
      end
      return
   end

   if gui.leftClick and not gui.leftClickHandled then
      local now = reaper.time_precise()
      local isDouble = gui.lastClickIdx == idx and (now - gui.lastClickTime) <= gui.doubleClickThreshold
      gui.doubleClick = isDouble
      gui.lastClickTime = now
      gui.lastClickIdx = idx

      log:debug("Handling left click on entry at listIdx [" .. idx .. "]" .. (isDouble and " (double)" or ""))

      if mouse.ctrl or mouse.shift then
         if gui.selection[entry] then
            gui.pendingMod = { entry = entry, ctrl = mouse.ctrl, shift = mouse.shift } -- (a drag moves the selection)
         else
            modify_selection(entry, idx, mouse.ctrl, mouse.shift) -- selecting: no jump, no editing
         end
      elseif gui.selection[entry] and #ListInput.selected_entries() > 1 then
         gui.pendingClear = entry -- (it may be the start of a drag of the whole selection)
      else
         clear_selection(entry)
         if entry.type == ENTRY.TEXT then gui.selection[entry] = true end -- a text entry is selected by a plain click
      end

      if mouse.ctrl or mouse.shift then
         -- (nothing else happens)
      elseif gui.pendingClear == entry then
         -- (waiting: a drag moves the whole selection and must not switch the active project; a click does, on release)
      elseif entry.type == ENTRY.TEXT then
         if isDouble then
            ListInput.start_edit(entry)
         elseif modifier_down(MOD.ALT) then
            delete_text(entry, idx)
         end
      elseif entry.type == ENTRY.PROJECT then
         if entry.proj ~= State.current_proj then
            gui.listClickTarget = entry.proj -- lets Main tell this switch apart from one made in REAPER
         end
         reaper.SelectProjectInstance(entry.proj)
      end

      gui.leftClickHandled = true
   end

   if gui.rightClick and not gui.rightClickHandled then
      log:debug("Handling right click on entry " .. entry.name .. " at index " .. idx)

      if gui.selection[entry] and #ListInput.selected_entries() > 1 then
         show_selection_menu()
      elseif entry.type == ENTRY.TEXT then
         show_text_menu(entry, idx)
      elseif entry.type == ENTRY.PROJECT then
         show_project_menu(entry)
      elseif entry.type == ENTRY.MISSING then
         show_missing_menu(entry, idx)
      end

      gui.rightClickHandled = true
   end
end

function ListInput.handle_wheel()
   local wheel = State.win.mouse.wheel -- the Window reads (and resets) gfx.mouse_wheel once per frame
   if wheel ~= 0 and State.win.mouse.ctrl then
      List.apply_zoom(gui.zoomLevel + (wheel > 0 and 1 or -1))
   elseif wheel ~= 0 then
      -- one notch (120) = one row, the same in both directions
      local steps = math.max(1, math.floor(math.abs(wheel) / 100 + 0.5))
      local delta = wheel > 0 and -steps or steps
      gui.scrollOffset = List.apply_manual_scroll(gui.scrollOffset, delta, gui.maxScroll)
   end
   -- Hard limit only (e.g. the list got shorter). Rows beyond gui.maxScroll are allowed here on purpose:
   -- they are what the follow-scroll leaves behind.
   gui.scrollOffset = clamp(gui.scrollOffset, 0, gui.followMaxScroll)
end

function ListInput.handle_scrollbar()
   local mouseOnScrollbar = List.mouse_in_rect(gfx.w - gui.scrollW, gui.scrollY, gui.scrollW, gui.scrollH)

   if gui.leftClick and mouseOnScrollbar and not gui.draggingEntry and not gui.draggingScroll then
      gui.draggingScroll = true
      gui.scrollBarGrabStart = State.win.mouse.y
      gui.scrollBarGrabOffset = State.win.mouse.y - gui.scrollY
   elseif not gui.leftClick then
      gui.draggingScroll = false
      gui.scrollBarGrabStart = 0
      gui.scrollBarGrabOffset = 0
   end

   if gui.draggingScroll and gui.scrollBarGrabStart ~= State.win.mouse.y then
      local scrollTrackHeight = gui.listH + gui.titleHeight
      local emptyScrollH = scrollTrackHeight - gui.scrollH
      local newScrollY = clamp(State.win.mouse.y - gui.scrollBarGrabOffset, 0, emptyScrollH)

      gui.scrollOffset = math.floor((newScrollY / emptyScrollH) * gui.maxScroll)
      gui.scrollOffset = clamp(gui.scrollOffset, 0, gui.maxScroll)
      log:debug("Scrolling to scrollOffset: " .. gui.scrollOffset)
   end
end

return ListInput
