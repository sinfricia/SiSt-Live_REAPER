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

   -- Perform the swap only if the target index has changed
   if gui.dropIdx == gui.dragEntryListIdx then end_drag() return end

   Actions.drop_entry(gui.dragEntryListIdx, gui.dropIdx, gui.dragDirection, modifier_down(MOD.CTRL)) -- Ctrl: copy

   end_drag()
end

function ListInput.handle_drag()
   if #State.list < 2 then return end

   if gui.leftClick then
      gui.dragThreshReached = math.abs(gfx.mouse_y - gui.lastClickDownPos.y) > gui.dragThreshold
   end

   if not gui.draggingEntry and gui.leftClick and not gui.draggingScroll and not gui.pressOnIndicator
       and gui.dragThreshReached then
      local entryUnderMouse, idxUnderMouse = List.entry_at_mouse(true)

      if not entryUnderMouse then return end

      gui.dragEntryListIdx = idxUnderMouse
      gui.dragStartY = gfx.mouse_y
      gui.draggingEntry = true
      log:debug("Dragging started for: %s", State.list[gui.dragEntryListIdx].name)
   elseif gui.draggingEntry and gui.dragThreshReached then
      gui.dragDirection = 1
      if gfx.mouse_y < gui.dragStartY then
         gui.dragDirection = -1
      end

      -- Auto-scroll if mouse is near top or bottom
      if gfx.mouse_y < gui.titleHeight - gui.dragScrollMargin or gfx.mouse_y > gui.listH + gui.titleHeight + gui.dragScrollMargin then
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

      if not entryUnderMouse or idxUnderMouse == gui.dragEntryListIdx then
         gui.dropIdx = nil
         ListInput.handle_drop() -- (on release this ends the drag: before, the entry stayed in its "dragged" look)
         return
      end

      if math.abs(gfx.mouse_y - gui.dragStartY) > gui.dragThreshold then
         -- Calculate drop index based on mouse position
         -- the row under the mouse (leave a dropzone of 1/3 of the line height: dragging feels quite nice), then the entry
         -- the drop is relative to: the one above that row when dragged down, below it when dragged up
         local row = (gfx.mouse_y + (gui.lineHeight / 3 * gui.dragDirection) - gui.titleHeight) / gui.lineHeight +
             gui.scrollOffset
         local _, totalRows = List.layout(State.list)
         local hovered = List.entry_at_row(State.list, clamp(row, 0, totalRows - 0.001))

         gui.dropIdx = clamp(hovered - gui.dragDirection, 1, #State.list)
      end

      ListInput.handle_drop()
   end
end

-- Right-click menus ---------------------------------------------------------------------------------------------

-- items: see Window.build_menu. Opens the menu at the mouse and runs the chosen entry's action.
local function show_menu(items)
   gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
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

--- Once per frame after the list is drawn: acts on what the field reported. Enter or a click elsewhere keeps the new text
--- (an empty one is not kept), Esc drops it.
function ListInput.handle_edit()
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
   if Ask.confirm("Delete the text entry '" .. entry.name .. "'?", "Delete Text Entry") then
      Actions.delete_entry(idx)
   end
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
         if Ask.confirm("Remove '" .. entry.name .. "' from the setlist?", "Remove Entry") then
            Actions.delete_entry(idx)
         end
      end },
   })
end

-- Clicks, wheel and scrollbar -----------------------------------------------------------------------------------

function ListInput.handle_click()
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

      if entry.type == ENTRY.TEXT then
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

      if entry.type == ENTRY.TEXT then
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
      gui.scrollBarGrabStart = gfx.mouse_y
      gui.scrollBarGrabOffset = gfx.mouse_y - gui.scrollY
   elseif not gui.leftClick then
      gui.draggingScroll = false
      gui.scrollBarGrabStart = 0
      gui.scrollBarGrabOffset = 0
   end

   if gui.draggingScroll and gui.scrollBarGrabStart ~= gfx.mouse_y then
      local scrollTrackHeight = gui.listH + gui.titleHeight
      local emptyScrollH = scrollTrackHeight - gui.scrollH
      local newScrollY = clamp(gfx.mouse_y - gui.scrollBarGrabOffset, 0, emptyScrollH)

      gui.scrollOffset = math.floor((newScrollY / emptyScrollH) * gui.maxScroll)
      gui.scrollOffset = clamp(gui.scrollOffset, 0, gui.maxScroll)
      log:debug("Scrolling to scrollOffset: " .. gui.scrollOffset)
   end
end

return ListInput
