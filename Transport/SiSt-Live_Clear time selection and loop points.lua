-- @noindex
--
-- SiSt-Live: Clear time selection and loop points (active project)
--
-- Replacement for the native action 40020 "Time selection: Remove (unselect) time selection and
-- loop points" in custom actions (Start Song, Project End Handler).
--
-- Why: in show mode REAPER's locking locks the time selection and loop points. Action 40020 then
-- stops and asks "Time selection locked. Unlock and remove now?". This script clears both directly
-- through the API, which doesn't go through the action system, so no prompt appears and the lock
-- itself stays on.
--
-- Works on the ACTIVE project tab, like 40020 does. In a custom action it therefore acts on whatever
-- tab is active at that step (e.g. after "Switch to next project tab": the new song).

-- Started again while the previous run still waits for its defer (e.g. Start Show runs it once per
-- project in a loop): end the old instance and start the new one, without REAPER's task control prompt.
-- The clearing itself is already done by then: ending the old instance only cancels its empty defer.
reaper.set_action_options(1 | 2)

local PROJ = 0 -- 0 = active project

reaper.GetSet_LoopTimeRange2(PROJ, true, false, 0, 0, false) -- time selection
reaper.GetSet_LoopTimeRange2(PROJ, true, true, 0, 0, false)  -- loop points

reaper.defer(function() end) -- no undo point for this script
