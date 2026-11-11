-- @noindex
-- Tests of Setlist/Sync.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local Log = require("SiSt-Live_Log")
local Data = require("Setlist.Data")
local Sync = require("Setlist.Sync")

local Tests = {}

-- Self test ---------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

define("is_synced / diff / follow_tabs / duplicates", function(t)
   local ENTRY = Data.ENTRY
   local function proj(path, p) return { type = ENTRY.PROJECT, path = path, proj = p } end
   local function tab(path, p) return { type = ENTRY.PROJECT, path = path, proj = p, name = path } end
   local function text(s) return { type = ENTRY.TEXT, path = s } end
   local function paths(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = e.path end
      return table.concat(out, ",")
   end
   local A, B, C = {}, {}, {}

   -- is_synced
   t.ok(Sync.is_synced({ proj("a", A), text("t"), proj("b", B) }, { A, B }), "is_synced: same pointers, same order, text in between")
   t.ok(not Sync.is_synced({ proj("b", B), proj("a", A) }, { A, B }), "is_synced: different order")
   t.ok(not Sync.is_synced({ proj("a", A) }, { A, B }), "is_synced: tab without entry")
   t.ok(not Sync.is_synced({ proj("a", A), proj("b", B) }, { A }), "is_synced: entry without tab")
   t.ok(not Sync.is_synced({ proj("a", nil) }, { A }), "is_synced: entry without pointer")
   t.ok(Sync.is_synced({ text("t") }, {}), "is_synced: no projects at all")
   t.ok(Sync.is_synced({ proj("a", A) }, { A }, { "a" }) and not Sync.is_synced({ proj("a", A) }, { A }, { "other" }),
      "is_synced: the same pointer with another file (File > Open into the tab) is not in sync")
   t.ok(Sync.is_synced({ { type = ENTRY.MISSING, path = "x" }, proj("a", A) }, { A }), "is_synced: missing entries are not projects")

   -- diff
   local d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("b", B) })
   t.ok(d.in_sync and #d.matched == 2, "diff: equal is in sync")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("b", B), tab("a", A) })
   t.ok(d.order_changed and not d.in_sync and #d.list_only == 0 and #d.tab_only == 0, "diff: only the order differs")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A) })
   t.ok(#d.list_only == 1 and d.list_only[1].path == "b" and #d.tab_only == 0, "diff: tab closed: the entry has no tab")
   d = Sync.diff({ proj("a", A) }, { tab("a", A), tab("c", C) })
   t.ok(#d.tab_only == 1 and d.tab_only[1].tab.path == "c" and d.tab_only[1].tab_idx == 1 and #d.list_only == 0,
      "diff: tab opened: the tab has no entry")
   d = Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("b", {}) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0 and #d.matched == 2, "diff: same file, new pointer (closed and opened again) is the same entry")
   d = Sync.diff({ proj("C:\\x\\a.rpp", nil) }, { tab("C:/x/a.rpp", A) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0, "diff: paths match whatever the slashes")
   d = Sync.diff({ proj("a", A), proj("a", nil) }, { tab("a", A), tab("a", B) })
   t.ok(#d.list_only == 0 and #d.tab_only == 0 and d.matched[2].tab_idx == 1, "diff: the same file twice is two entries for two tabs")
   d = Sync.diff({ proj("a", A), proj("a", nil) }, { tab("a", A) })
   t.ok(#d.list_only == 1 and #d.tab_only == 0, "diff: the same file twice in the list, once open: one entry has no tab")
   d = Sync.diff({ text("t"), { type = ENTRY.MISSING, path = "gone" } }, { tab("a", A) })
   t.ok(#d.list_only == 0 and #d.tab_only == 1, "diff: text and missing entries are never compared")
   t.ok(Sync.diff({}, {}).in_sync, "diff: nothing and nothing is in sync")

   -- follow_tabs
   local list = { proj("a", A), text("break"), proj("b", B), proj("c", C) }
   local r = Sync.follow_tabs(list, { tab("c", C), tab("a", A), tab("b", B) })
   t.eq(paths(r), "c,break,a,b", "follow_tabs: reorder keeps text in place")
   t.eq(paths(list), "a,break,b,c", "follow_tabs: the input list is not changed")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("a", A) })
   t.eq(paths(r), "a,break", "follow_tabs: entry of a closed tab is removed, text stays")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("a", A), tab("n", C), tab("b", B) })
   t.eq(paths(r), "a,n,break,b", "follow_tabs: a new tab goes after the entry of the tab before it")
   r = Sync.follow_tabs({ proj("a", A), text("break"), proj("b", B) }, { tab("n", C), tab("a", A), tab("b", B) })
   t.eq(paths(r), "n,a,break,b", "follow_tabs: a new first tab goes before the first project")
   r = Sync.follow_tabs({ proj("a", A) }, { tab("a", A), tab("n", B), tab("m", C) })
   t.eq(paths(r), "a,n,m", "follow_tabs: several new tabs keep their tab order")
   r = Sync.follow_tabs({ text("t") }, { tab("n", A) })
   t.eq(paths(r), "t,n", "follow_tabs: a list of only text gets the project after it")
   r = Sync.follow_tabs({}, { tab("a", A), tab("b", B) })
   t.eq(paths(r), "a,b", "follow_tabs: an empty list becomes the tabs")
   local reopened, new_ptr = proj("a", {}), {}
   r = Sync.follow_tabs({ reopened }, { tab("a", new_ptr) })
   t.ok(r[1] == reopened and reopened.proj == new_ptr, "follow_tabs: a reopened project keeps its entry and gets the new pointer")
   r = Sync.follow_tabs({ proj("a", A), proj("b", B) }, { tab("b", B), tab("x", C), tab("a", A) })
   t.eq(paths(r), "b,x,a", "follow_tabs: reorder and new tab together")
   local tabs2 = { tab("b", B), tab("x", C), tab("a", A) }
   r = Sync.follow_tabs({ proj("a", A), text("t"), proj("b", B) }, tabs2)
   t.ok(Sync.is_synced(r, { B, C, A }) and Sync.diff(r, tabs2).in_sync, "follow_tabs: the result is in sync")

   -- follow_tabs with linked text entries: a project moves with them
   local function linked(s, dir) return { type = ENTRY.TEXT, path = s, link = dir } end
   r = Sync.follow_tabs({ proj("a", A), linked("a-note", "above"), linked("b-note", "below"), proj("b", B), text("free") },
      { tab("b", B), tab("a", A) })
   t.eq(paths(r), "b-note,b,a,a-note,free", "follow_tabs: linked text entries move with their project, free ones stay")
   r = Sync.follow_tabs({ proj("a", A), linked("a-note", "above"), proj("b", B) }, { tab("a", A), tab("n", C), tab("b", B) })
   t.eq(paths(r), "a,a-note,n,b", "follow_tabs: a new tab goes after the block of the tab before it")
   local gone_note, other_note = linked("gone-note", "below"), linked("a-note", "above")
   r = Sync.follow_tabs({ gone_note, proj("g", C), other_note, proj("a", A), proj("b", B) }, { tab("a", A), tab("b", B) })
   t.eq(paths(r), "gone-note,a-note,a,b", "follow_tabs: the texts of a closed project stay, without their link")
   t.ok(gone_note.link == nil and other_note.link == nil, "follow_tabs: and the link is cleared, so they do not join the next project")

   -- duplicates
   local dups = Sync.duplicates({ tab("a", A), tab("b", B), tab("A", C), tab("a", {}) })
   t.ok(#dups == 1 and dups[1].count == 2 and dups[1].tabs[1] == 0 and dups[1].tabs[2] == 3, "duplicates: found by path")
   t.ok(#Sync.duplicates({ tab("C:\\x\\a.rpp", A), tab("C:/x/a.rpp", B) }) == 1, "duplicates: slashes do not matter")
   t.ok(#Sync.duplicates({ tab("Unsaved Project", A), tab("Unsaved Project", B) }) == 0, "duplicates: unsaved projects may be open many times")
   t.ok(#Sync.duplicates({ tab("a", A), tab("b", B) }) == 0, "duplicates: none")

   -- change_summary
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A) }, { tab("a", A) })), nil, "change_summary: nothing changed")
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A), proj("b", B) }, { tab("a", A), tab("c", C) })), "1 new, 1 gone", "change_summary: new and gone")
   t.eq(Sync.change_summary(Sync.diff({ proj("a", A), proj("b", B) }, { tab("b", B), tab("a", A) })), "reordered", "change_summary: reordered")
end)

define("plan_load", function(t)
   local ENTRY = Data.ENTRY
   local function proj(path, p) return { type = ENTRY.PROJECT, path = path, proj = p, name = path } end
   local function text(s) return { type = ENTRY.TEXT, path = s, name = s } end
   local function paths(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = e.path end
      return table.concat(out, ",")
   end
   local A, B, C, D = {}, {}, {}, {}
   local exists = function(path) return path ~= "gone" end

   local loaded = { proj("a", nil), text("L1"), proj("b", nil), proj("gone", nil) }
   local x_entry, y_entry = proj("x", C), proj("y", D)
   local b_entry = proj("b", B)
   local tabs = { b_entry, x_entry, y_entry }
   local note, break_note = text("note"), text("break")
   local current = { x_entry, note, b_entry, break_note, y_entry }

   local plan = Sync.plan_load(loaded, tabs, current, {}, exists)
   t.eq(paths(plan.list), "x,note,break,y,a,L1,b,gone", "everything kept: the kept entries in the order of the current list, then the loaded ones")
   t.eq(paths(plan.to_open), "a", "to_open: the loaded project with no tab and an existing file")
   t.eq(paths(plan.missing), "gone", "missing: no tab and no file")
   t.eq(#plan.to_close, 0, "nothing marked: nothing is closed")

   plan = Sync.plan_load(loaded, tabs, current, { [C] = true, [D] = true, [note] = true, [break_note] = true }, exists)
   t.eq(paths(plan.list), "a,L1,b,gone", "everything marked: only the loaded setlist remains")
   t.eq(paths(plan.to_close), "x,y", "the marked extras are closed, in tab order")

   plan = Sync.plan_load(loaded, tabs, current, { [C] = true, [break_note] = true }, exists)
   t.eq(paths(plan.list), "note,y,a,L1,b,gone", "a mix: x and the break removed, the note and y kept")
   t.eq(paths(plan.to_close), "x", "only x is closed")

   -- a kept text entry keeps its link only while its project is kept
   local lx = { type = ENTRY.TEXT, path = "lx", name = "lx", link = "above" }
   local current2 = { x_entry, lx, b_entry, y_entry }
   plan = Sync.plan_load(loaded, tabs, current2, {}, exists)
   t.eq(plan.list[2].link, "above", "plan_load: the project stays, so the link stays")
   plan = Sync.plan_load(loaded, tabs, current2, { [C] = true }, exists)
   t.eq({ plan.list[1].path, plan.list[1].link }, { "lx", nil }, "plan_load: the project is removed: the text entry loses its link")
   t.eq(lx.link, "above", "plan_load: the current list itself is not changed")

   -- identical text entries are replaced by the loaded ones, not kept next to them
   local loaded_with_note = { proj("a", nil), text("note"), proj("b", nil) }
   plan = Sync.plan_load(loaded_with_note, tabs, current, {}, exists)
   t.eq(paths(plan.list), "x,break,y,a,note,b", "an identical text entry is replaced by the loaded one (only one 'note' remains)")
   local ident = Sync.identical_texts(current, loaded_with_note)
   t.ok(ident[note] and not ident[break_note], "identical_texts: found by text")
   local colored = text("note"); colored.highlight = { 1, 0, 0, 0.4 }
   t.ok(not Sync.identical_texts({ colored }, loaded_with_note)[colored], "identical_texts: a different color is not identical")
   local twice = Sync.identical_texts({ text("note"), text("note") }, loaded_with_note)
   local count = 0
   for _ in pairs(twice) do count = count + 1 end
   t.eq(count, 1, "identical_texts: two in the current list, one in the loaded: only one matches")

   -- an empty unsaved tab is closed without being asked about
   local blank = proj("Unsaved Project", {})
   plan = Sync.plan_load(loaded_with_note, { b_entry, blank }, { b_entry, blank }, {}, exists, function(p) return p == blank.proj end)
   t.eq(#plan.to_close, 1, "an empty unsaved tab is closed")
   t.eq(paths(plan.list), "a,note,b", "... and does not stay in the list")

   plan = Sync.plan_load({ proj("b", nil) }, tabs, { b_entry }, {}, exists)
   t.eq(paths(plan.list), "x,y,b", "an extra the current list does not know is added after the kept entries")

   plan = Sync.plan_load({ proj("a", nil) }, {}, {}, {}, exists)
   t.eq(paths(plan.to_open), "a", "nothing open: everything of the setlist is opened")
   plan = Sync.plan_load({}, {}, {}, {}, exists)
   t.eq(#plan.list, 0, "nothing at all: an empty list")
end)

function Tests.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Tests
