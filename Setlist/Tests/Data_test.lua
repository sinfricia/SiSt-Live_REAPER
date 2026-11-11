-- @noindex
-- Tests of Setlist/Data.lua (see lib/SelfTest.lua). Collected by the Setlist script's SELFTEST_COLLECT
-- switch; they run with the self-test.

local Log = require("SiSt-Live_Log")
local Data = require("Setlist.Data")
local ENTRY = Data.ENTRY
local encode_value = Data.encode_value

local Tests = {}

-- Self test ---------------------------------------------------------------------------------------

local SelfTest = require("SelfTest")
local define, run = SelfTest.cases()

-- In-memory file system for Data.write_text_atomic. opts.windows: rename onto an existing file fails.
-- opts.liar: rename does the move but reports a failure (seen with sync clients like kDrive).
-- opts.rename_fails: every rename fails. opts.tmp_vanishes: the .tmp file disappears when written.
local function FakeFileSystem(files, opts)
   opts = opts or {}
   local fs = {}
   function fs.open(path, mode)
      if mode == "rb" then
         if files[path] == nil then return nil, path .. ": No such file or directory" end
         local data = files[path]
         return { read = function() return data end, close = function() end }
      end
      local buf = {}
      return { write = function(_, s) buf[#buf + 1] = s; return true end,
         close = function()
            if not (opts.tmp_vanishes and path:find("%.tmp$")) then files[path] = table.concat(buf) end
         end }
   end
   function fs.rename(from, to)
      if opts.rename_fails then return nil, "Permission denied" end
      if files[from] == nil then return nil, "No such file or directory" end
      if opts.windows and files[to] ~= nil then return nil, "File exists" end
      files[to], files[from] = files[from], nil
      if opts.liar then return nil, "No such file or directory" end
      return true
   end
   function fs.remove(path) files[path] = nil; return true end
   return fs
end

define("Data.format_time", function(t)
   t.eq(Data.format_time(59.9), "00:59", "fraction is floored")
   t.eq(Data.format_time(3600), "60:00", "minutes do not wrap into hours")
end)

define("Data.normalize_path", function(t)
   t.eq(Data.normalize_path("/"), "/", "root stays")
end)

define("Data.project_name", function(t)
   t.eq(Data.project_name("C:\\a\\Song.RPP"), "Song", "windows path, upper case extension")
   t.eq(Data.project_name("Song"), "Song", "no separator is returned as is")
   t.eq(Data.project_name("dir/"), "dir/", "trailing separator does not crash")
end)

define("encode_value / decode_value", function(t)
   local nasty = "Intro = 120bpm; {x}, 100%25\r\nline2"
   local encoded = encode_value(nasty)
   t.ok(not encoded:find("[;={}\r\n]"), "no separator characters survive encoding")
end)

define("Setlist string round trip", function(t)
   local original = {
      { type = ENTRY.TEXT,    name = "Intro = 120bpm; {click}", path = "Intro = 120bpm; {click}",         highlight = { 0.5, 0.25, 0.75, 0.4 } },
      { type = ENTRY.PROJECT, name = "Song A",                  path = "/selftest/nonexistent/Song A.rpp" },
      { type = ENTRY.MISSING, name = "Gone",                    path = "/selftest/nonexistent/Gone.rpp" },
      { type = ENTRY.TEXT,    name = "Back\\slash 100%",        path = "Back\\slash 100%" },
      { type = ENTRY.TEXT,    name = "two\nlines",              path = "two\nlines" },
      { type = ENTRY.PROJECT, name = "Unsaved Project",         path = "Unsaved Project" }, -- must be skipped
   }

   local str = Data.list_to_text(original, "\n")
   local parsed, invalid = Data.text_to_list(str, "\n")

   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 5, "unsaved project is not serialized")
   t.eq(parsed[1].name, original[1].name, "label with = ; { } survives")
   t.eq(parsed[1].highlight, { 0.5, 0.25, 0.75, 0.4 }, "highlight list survives as numbers")
   t.eq(parsed[2].type, ENTRY.PROJECT, "project type")
   t.eq(parsed[2].path, Data.sanitize_path("/selftest/nonexistent/Song A.rpp"), "project path")
   t.eq(parsed[3].type, ENTRY.MISSING, "missing type")
   t.eq(parsed[4].name, "Back\\slash 100%", "backslash and percent in label survive")
   t.eq(parsed[5].name, "two\nlines", "newline in label survives")
end)

define("Legacy setlist format still parses", function(t)
   local legacy = "name=Hello; path=Hello; type=text; listIdx=1; \n" ..
       "path=/old/100%41/Song.rpp; type=project; name=Song; listIdx=2; tabIdx=0; "
   local parsed, invalid = Data.text_to_list(legacy, "\n")
   t.eq(#invalid, 0, "no invalid entries")
   t.eq(#parsed, 2, "two entries")
   t.eq(parsed[1].name, "Hello", "text name")
   t.eq(parsed[2].path, Data.sanitize_path("/old/100%41/Song.rpp"), "no decoding without the enc marker")
end)

define("Invalid entries are reported, not crashed on", function(t)
   local parsed, invalid = Data.text_to_list("name=orphan; \n", "\n")
   t.eq(#parsed, 0, "nothing valid")
   t.eq(#invalid, 1, "one invalid entry")
   local p2, i2 = Data.text_to_list("", "\n")
   t.eq({ #p2, #i2 }, { 0, 0 }, "empty string")
end)

define("List index <-> tab index", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT } }

   t.eq(Data.list_to_tab_idx(list, 1, 2), 0, "before the first project: tab 0")
   t.eq(Data.list_to_tab_idx(list, 2, 2), 0, "the first project is tab 0")
   t.eq(Data.list_to_tab_idx(list, 3, 2), 1, "a text entry after it: the next tab")
   t.eq(Data.list_to_tab_idx(list, 4, 2), 1, "the second project is tab 1")
   t.eq(Data.list_to_tab_idx(list, 5, 2), 2, "past the end gives the tab count")
   t.eq(Data.list_to_tab_idx(list, -1, 2), 0, "negative gives 0")
   t.eq(Data.list_to_tab_idx(list, 0, 2), 2, "position 0 is outside the list: the tab count")

   t.eq(Data.tab_to_list_idx(list, 0), 2, "tab 0 is list position 2")
   t.eq(Data.tab_to_list_idx(list, 1), 4, "tab 1 is list position 4")
   t.eq(Data.tab_to_list_idx(list, 2), 5, "past the last tab: one past the end of the list")
   t.eq(Data.tab_to_list_idx(list, -1), 0, "before the first tab: 0")
   t.eq(Data.tab_to_list_idx({}, 0), 1, "empty list: position 1")
end)

define("Links: blocks", function(t)
   local function P(n) return { type = ENTRY.PROJECT, name = n } end
   local function T(n, link) return { type = ENTRY.TEXT, name = n, link = link } end
   -- A, [t1 above A], [t2 below B], B, [t3 above B], free, C
   local list = { P("A"), T("t1", "above"), T("t2", "below"), P("B"), T("t3", "above"), T("free"), P("C") }
   t.eq({ Data.link_block(list, 1) }, { 1, 2 }, "A and the text linked above it")
   t.eq({ Data.link_block(list, 4) }, { 3, 5 }, "B with its text above and below")
   t.eq({ Data.link_block(list, 7) }, { 7, 7 }, "C has none")
   t.eq({ Data.block_of(list, 2) }, { 1, 2, 1 }, "a text finds its block and project")
   t.eq({ Data.block_of(list, 3) }, { 3, 5, 4 }, "also when linked below")
   t.eq(Data.block_of(list, 6), nil, "an unlinked text is in no block")
   list[6].link = "below" -- links to C: right there, so it counts
   t.eq({ Data.block_of(list, 6) }, { 6, 7, 7 }, "linked below to C")
   list[6].link = "above" -- text 5 is linked above, so it could reach B... but 5 is "above" B: continuous run
   t.eq({ Data.block_of(list, 6) }, { 3, 6, 4 }, "a run of linked texts reaches the project")
   list[6].link = nil
   list[2].link = "below" -- A, t1 (below), t2 (below), B: t1 and t2 are both B's
   t.eq({ Data.link_block(list, 4) }, { 2, 5 }, "both texts above B")
   t.eq({ Data.link_block(list, 1) }, { 1, 1 }, "A lost its text")
   list[2].link = "above"
   -- can_link
   local l2 = { P("A"), T("x"), T("y"), P("B") }
   t.eq(Data.link_chain(l2, 2, "above"), { 2 }, "directly below a project")
   t.eq(Data.link_chain(l2, 3, "above"), { 3, 2 }, "another text entry in between: linked too")
   t.eq(Data.link_chain(l2, 2, "below"), { 2, 3 }, "the same downwards")
   t.eq(Data.link_chain(l2, 3, "below"), { 3 }, "directly above a project")
   t.eq(Data.link_chain({ P("A"), { type = ENTRY.MISSING }, T("x") }, 3, "above"), nil, "a missing entry is in the way")
   t.eq(Data.link_chain({ T("only") }, 1, "above"), nil, "no project at all")
   t.eq(Data.can_link(l2, 3, "above"), true, "can_link")
   t.eq(l2[2].link, nil, "nothing is changed by asking")
   -- join_block: dropped between two entries of a block
   local l4 = { P("A"), T("n1", "above"), T("n2", "above"), P("B") }
   local drop = T("drop")
   table.insert(l4, 3, drop)
   t.eq({ Data.join_block(l4, 3), drop.link }, { true, "above" }, "between two entries of A's block: linked above")
   local l5 = { P("A"), T("b1", "below"), T("b2", "below"), P("B") }
   drop = T("drop")
   table.insert(l5, 3, drop)
   t.eq({ Data.join_block(l5, 3), drop.link }, { true, "below" }, "between two entries linked below: linked below")
   local l6 = { P("A"), T("n1", "above") }
   drop = T("drop")
   table.insert(l6, 2, drop)
   t.eq({ Data.join_block(l6, 2), drop.link }, { true, "above" }, "between a project and its first linked entry: linked above")
   local l7 = { P("A"), T("n1", "above") }
   drop = T("drop", "above")
   table.insert(l7, drop)
   t.eq({ Data.join_block(l7, 3), drop.link }, { false, nil }, "after the last entry of a block: outside, no link")
   -- linked_rows
   local l3 = { P("A"), T("t", "above"), T("free"), P("B") }
   local rows = Data.linked_rows(l3)
   t.eq(rows[l3[1]], { first = true, last = false }, "the project starts the line")
   t.eq(rows[l3[2]], { first = false, last = true }, "the linked text ends it")
   t.eq({ rows[l3[3]], rows[l3[4]] }, {}, "the others have no line")
end)

define("Links survive saving", function(t)
   local list = { { type = ENTRY.PROJECT, name = "A", path = "/selftest/nonexistent/A.rpp" },
      { type = ENTRY.TEXT, name = "note", path = "note", link = "above" },
      { type = ENTRY.TEXT, name = "odd", path = "odd", link = "sideways" } }
   local parsed = Data.text_to_list(Data.list_to_text(list, "\n"), "\n")
   t.eq(parsed[2].link, "above", "the link is stored")
   t.eq(parsed[3].link, nil, "an unknown direction is ignored")
   t.eq(parsed[1].link, nil, "a project has no link")
end)

define("missing_entries", function(t)
   local list = { { type = ENTRY.PROJECT }, { type = ENTRY.MISSING }, { type = ENTRY.TEXT }, { type = ENTRY.MISSING } }
   local count, first = Data.missing_entries(list)
   t.eq({ count, first }, { 2, 2 }, "two missing entries, the first at position 2")
   local none, nothing = Data.missing_entries({ { type = ENTRY.PROJECT } })
   t.eq({ none, nothing }, { 0, nil }, "none")
end)

define("Data.update_indexes / Data.project_entries", function(t)
   local list = { { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT } }
   Data.update_indexes(list)
   t.eq({ list[1].list_idx, list[2].list_idx, list[3].list_idx, list[4].list_idx }, { 1, 2, 3, 4 }, "list_idx")
   t.eq({ list[2].tab_idx, list[3].tab_idx }, { 0, 1 }, "tab_idx of projects")
   t.eq(list[1].tab_idx, nil, "text entries have no tab_idx")
   t.eq(#Data.project_entries(list), 2, "two project entries")
end)

define("Atomic file write / read", function(t)
   -- Not os.tmpname(): on Windows that points at the drive root, which is usually not writable
   local path = reaper.GetResourcePath() .. package.config:sub(1, 1) .. "SiSt-Live_selftest_" .. os.time() .. ".tmp"
   t.eq(Data.read_text(path .. ".does-not-exist"), nil, "missing file gives nil")

   t.ok(Data.write_text_atomic(path, "first\nversion"), "first write")
   t.ok(Data.write_text_atomic(path, "second"), "overwrite existing file")
   t.eq(Data.read_text(path), "second", "overwritten content")
   t.eq(Data.read_text(path .. ".tmp"), nil, "no .tmp file left behind")

   local ok = Data.write_text_atomic("/selftest/nonexistent-dir/x.rsl", "data")
   t.ok(not ok, "unwritable location reports failure instead of crashing")
   os.remove(path)
end)

define("Atomic write: Windows and sync-client behaviour", function(t)
   local files = { a = "old" }
   t.ok(Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true })), "Windows: target exists")
   t.eq(files.a, "new", "Windows: new content")
   t.eq({ files["a.tmp"], files["a.bak"] }, { nil, nil }, "Windows: no .tmp or .bak left")

   files = { a = "old" }
   t.ok(Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true, liar = true })),
      "rename reports a failure but did move: success")
   t.eq(files.a, "new", "rename that lied: the new content is kept, never deleted")

   files = { a = "old" }
   local ok = Data.write_text_atomic("a", "new", FakeFileSystem(files, { rename_fails = true }))
   t.ok(ok, "rename never works: written directly")
   t.eq(files.a, "new", "direct write: new content")

   files = { a = "old" }
   ok = Data.write_text_atomic("a", "new", FakeFileSystem(files, { windows = true, tmp_vanishes = true }))
   t.ok(ok, "the .tmp file vanished: written directly")
   t.eq(files.a, "new", "the .tmp file vanished: new content")

   files = {}
   files = { a = "old" }
   local fs = FakeFileSystem(files, { windows = true, tmp_vanishes = true })
   fs.open = (function(open) return function(path, mode)
      if mode == "wb" and path == "a" then return nil, "locked" end -- the direct write is refused too
      return open(path, mode)
   end end)(fs.open)
   t.ok(not Data.write_text_atomic("a", "new", fs), "nothing works: failure is reported")
   t.eq(files.a, "old", "nothing works: the old file is back in place")

   files = {}
   t.ok(Data.write_text_atomic("a", "first", FakeFileSystem(files, { windows = true })), "no old file yet")
   t.eq(files.a, "first", "no old file yet: written")
end)

define("Data.startup_action", function(t)
   t.eq(Data.startup_action(true, true, false), "fresh", "first start after opening REAPER: the open projects")
   t.eq(Data.startup_action(true, false, false), "keep", "restart in the same REAPER run: the list is kept")
   t.eq(Data.startup_action(false, false, false), "fresh", "nothing saved: the open projects")
   t.eq(Data.startup_action(true, false, true), "fresh", "test mode never reads the saved list")
end)

define("Data.worth_archiving", function(t)
   local P = { type = ENTRY.PROJECT, path = "a" }
   local T = { type = ENTRY.TEXT, path = "break" }
   t.ok(not Data.worth_archiving({}, {}), "an empty list is not kept")
   t.ok(Data.worth_archiving({ P }, {}), "a list of projects is kept when there is no autosave")
   t.ok(Data.worth_archiving({ P, T }, { P, T }), "a list with text replaces an autosave with text")
   t.ok(Data.worth_archiving({ P, T }, { P }), "a list with text replaces a plain autosave")
   t.ok(not Data.worth_archiving({ P }, { P, T }), "a plain list never replaces an autosave that has text entries")
end)

define("Data.describe_list", function(t)
   local list = {
      { type = ENTRY.PROJECT }, { type = ENTRY.TEXT }, { type = ENTRY.PROJECT }, { type = ENTRY.TEXT },
      { type = ENTRY.TEXT },
   }
   list[#list + 1] = { type = ENTRY.MISSING }
   t.eq(Data.describe_list(list), "6 entries (2 projects, 3 text entries, 1 missing)", "missing shown")
end)

function Tests.self_test()
   return run(function(go)
      Log.set_sink(function() end) -- the code under test logs: keep the console quiet
      go()
      Log.set_sink(nil)
   end)
end

return Tests
