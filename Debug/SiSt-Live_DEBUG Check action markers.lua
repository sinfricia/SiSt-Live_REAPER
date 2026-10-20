-- @noindex
-- SiSt-Live DEBUG: Check action markers
-- Checks the action markers ("!1016 _RS...") of all OPEN projects: every action they run must exist.
-- Read only. Result: summary in a message box, details in the console.
--
-- Temporary home: not part of the package (not in Setup's @provides). Moves to Batch Project Tools later.

local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ""
package.path = script_dir .. "../lib/?.lua;" .. package.path

local ActionReferenceChecks = require("ActionReferenceChecks")

local report = ActionReferenceChecks.check_markers()

local out = { "=== Action markers in open projects ===" }
for _, p in ipairs(report.problems) do
  out[#out + 1] = ("  FAIL  %s: %s %s"):format(p.where, p.id, p.problem)
end
out[#out + 1] = ("%d actions in markers checked, %d broken"):format(report.checked, #report.problems)
reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")

local summary = #report.problems == 0
    and ("All %d actions in action markers exist."):format(report.checked)
    or ("%d of %d actions in action markers are missing.\nDetails in the console."):format(#report.problems, report.checked)
reaper.MB(summary, "Check action markers", 0)

reaper.defer(function() end) -- no undo point
