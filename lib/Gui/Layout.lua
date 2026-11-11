-- @noindex
--[[
SiSt-Live Gui: Layout

How a window adapts to its width. Pure functions (no gfx), so every case is tested. The idea in one place: a window part
has a natural size, a compact size and a way to give way, and the window picks the first that fits:

  Layout.pack(sections, avail_w, opts)   the sections of a bar (the command area) in ONE row: natural, then compact, then
                                         the last sections are left out (and the bar says so)
  Layout.pick(variants, max_w, measure)  the first text variant that fits (the status line: long, shorter, shortest)

Usage (see Setlist/UI/CommandArea.lua):
  local plan = Layout.pack({ { w = 380, compact_w = 300 }, { w = 100, compact_w = 80 }, { w = 110, compact_w = 90, align = "right" } },
    gfx.w, { margin = 12, gap = 28, compact_gap = 14, overflow_w = 10 })
  plan.compact    true: use the compact sizes
  plan.items      the sections that are shown: { index = <position in sections>, x = <left edge>, w = <width used> }
  plan.hidden     the positions of the sections that did not fit (the last ones first left out), empty when all fit
  plan.overflow_x where the indicator for the hidden sections goes (the right end of the bar), when there are some

The first section always stays (it is placed even if it is wider than the window: the caller keeps the window from being
smaller than Layout.min_width).

Self test: Layout.self_test() returns a list of { name, ok }.
]]

local Layout = {}

--- Pure. Puts the sections in a row.
---   sections: list of { w, compact_w (default w), align = "left" (default) | "right" } in order of importance; a
---             right-aligned section sits at the right end of the row.
---   opts:     margin (left and right of the bar), gap (between sections), compact_gap (the gap when compact),
---             overflow_w (room for the indicator when sections are left out)
--- Tries all sections with the natural sizes, then compact; then without the last one, and so on, down to the first one.
function Layout.pack(sections, avail_w, opts)
   opts = opts or {}
   local margin = opts.margin or 12
   local gap = opts.gap or 28
   local compact_gap = opts.compact_gap or gap
   local overflow_w = opts.overflow_w or 0

   local function width_of(s, compact) return compact and (s.compact_w or s.w) or s.w end

   -- the first n sections in one row, or nil when they do not fit
   local function try(n, compact)
      local g = compact and compact_gap or gap
      local limit = avail_w - (n < #sections and overflow_w or 0)
      local total = 2 * margin
      for i = 1, n do total = total + width_of(sections[i], compact) + (i > 1 and g or 0) end
      if total > limit then return nil end
      local items, x, rights = {}, margin, {}
      for i = 1, n do
         local s = sections[i]
         local w = width_of(s, compact)
         if s.align == "right" then
            rights[#rights + 1] = { index = i, w = w }
         else
            items[#items + 1] = { index = i, x = x, w = w }
            x = x + w + g
         end
      end
      local right_edge = limit - margin
      for k = #rights, 1, -1 do
         right_edge = right_edge - rights[k].w
         items[#items + 1] = { index = rights[k].index, x = right_edge, w = rights[k].w }
         right_edge = right_edge - g
      end
      return { compact = compact, items = items }
   end

   local function finish(plan, n)
      plan.hidden = {}
      for i = n + 1, #sections do plan.hidden[#plan.hidden + 1] = i end
      if #plan.hidden > 0 then plan.overflow_x = avail_w - overflow_w end
      return plan
   end

   for n = #sections, 1, -1 do
      local plan = try(n, false) or try(n, true)
      if plan then return finish(plan, n) end
   end

   -- not even the first one fits: it is placed anyway
   local first = sections[1]
   local plan = { compact = true, items = {} }
   if first then plan.items[1] = { index = 1, x = margin, w = width_of(first, true) } end
   return finish(plan, first and 1 or 0)
end

--- Pure. The narrowest window the first (most important) section can be shown in: it compact, the margins and, when
--- there are more sections, room for the indicator.
function Layout.min_width(sections, margin, overflow_w)
   local first = sections[1]
   if not first then return 2 * (margin or 12) end
   return (first.compact_w or first.w) + 2 * (margin or 12) + (#sections > 1 and (overflow_w or 0) or 0)
end

--- Pure. The first of the variants (strings, longest first) that is at most max_w wide; the last one when none is.
--- measure(s) -> width.
function Layout.pick(variants, max_w, measure)
   for _, v in ipairs(variants) do
      if measure(v) <= max_w then return v end
   end
   return variants[#variants]
end

function Layout.self_test()
   local results = {}
   local function check(name, cond) results[#results + 1] = { name = name, ok = cond and true or false } end

   local S = {
      { w = 380, compact_w = 300 },                 -- List
      { w = 100, compact_w = 80 },                  -- Insert
      { w = 110, compact_w = 90, align = "right" }, -- Zoom
   }
   local O = { margin = 12, gap = 28, compact_gap = 14, overflow_w = 10 }

   local plan = Layout.pack(S, 800, O)
   check("pack: wide window: natural sizes, everything shown", not plan.compact and #plan.items == 3 and #plan.hidden == 0)
   check("pack: natural positions: after each other, the right-aligned one at the right edge",
      plan.items[1].x == 12 and plan.items[2].x == 12 + 380 + 28 and plan.items[3].x == 800 - 12 - 110)

   plan = Layout.pack(S, 560, O) -- natural needs 12+380+28+100+28+110+12 = 670, compact 12+300+14+80+14+90+12 = 522
   check("pack: narrower: compact sizes, everything shown", plan.compact and #plan.items == 3 and #plan.hidden == 0
      and plan.items[1].w == 300)
   check("pack: compact positions", plan.items[2].x == 12 + 300 + 14 and plan.items[3].x == 560 - 12 - 90)

   plan = Layout.pack(S, 450, O) -- all three compact need 522; List + Insert compact: 12+300+14+80+12 = 418, +10 = 428
   check("pack: narrow: the last section is left out, the bar says so",
      plan.compact and #plan.items == 2 and plan.hidden[1] == 3 and #plan.hidden == 1 and plan.overflow_x == 440)
   check("pack: what stays keeps its order from the left", plan.items[1].index == 1 and plan.items[2].index == 2)

   plan = Layout.pack(S, 340, O) -- List alone compact: 12+300+12 = 324, +10 = 334
   check("pack: narrower still: only the first section", #plan.items == 1 and plan.items[1].index == 1
      and #plan.hidden == 2 and plan.hidden[1] == 2 and plan.hidden[2] == 3)

   plan = Layout.pack(S, 200, O)
   check("pack: the first section is placed even when it does not fit", #plan.items == 1 and plan.items[1].x == 12
      and #plan.hidden == 2)

   plan = Layout.pack({ { w = 50 } }, 100, O)
   check("pack: one section that fits: nothing hidden, no indicator", #plan.hidden == 0 and plan.overflow_x == nil)
   plan = Layout.pack({}, 100, O)
   check("pack: no sections", #plan.items == 0 and #plan.hidden == 0)

   check("min_width: the first section compact, the margins and the indicator", Layout.min_width(S, 12, 10) == 334)
   check("min_width: a single section needs no indicator", Layout.min_width({ { w = 50 } }, 12, 10) == 74)
   check("min_width: nothing", Layout.min_width({}, 12) == 24)

   local function m(s) return #s * 10 end
   check("pick: the first that fits", Layout.pick({ "long text", "short", "s" }, 60, m) == "short")
   check("pick: none fits: the last", Layout.pick({ "long text", "short", "s" }, 5, m) == "s")
   check("pick: all fit: the first", Layout.pick({ "ab", "a" }, 100, m) == "ab")

   return results
end

return Layout
