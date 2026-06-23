# Blueprint 04 — Horizon + Format subsystem (Go → Lua)

> Sub-blueprint per `docs/rewrite/CONTEXT.md` §7. Cites Go `file:line` and test
> names. This is a **plan**: signatures + pseudocode for the tricky parts only.
> The byte-exact `want` strings in `go/format_test.go` and the cutoff dates in
> `go/horizon_test.go` are the golden spec; everything here defers to them.

## 1. Scope

Owns the Lua port of:

- **`go/horizon.go`** (216 lines): `HorizonSpec`/`ResolvedHorizon`,
  `defaultHorizonSpecs` (`horizon.go:31-42`), `parseDuration` (`:46-65`),
  `resolveCalendarKeyword` (`:69-100`), `parseWeekday` (`:103-122`),
  `parseAfterValue` (`:126-146`), `ResolveHorizons` (`:151-216`).
- **`go/format.go`** (291 lines): `inHorizon` (`:10-16`), `firstMatchHorizon`
  (`:19-34`), `narrowestHorizon` (`:37-73`), `formatTaskLine` (`:86-155`),
  `taskMatchesTags` (`:157-166`), `FormatTaskfile` (`:168-291`).
- The `extractDate` helper (`main.go:123-126`) is absorbed (see §3.1 — it
  disappears by construction).

Does **not** own: `Task` construction / `due_date` field shape (Parse blueprint —
coordination in §3.1 and §5 D1), the strftime→Go-layout converter
(`timeformat.go`, irrelevant after rewrite — we feed strftime straight to
`os.date`), buffer/`:edit` round-trip (Integration blueprint), tag *filter* UI
(`tags.lua`).

## 2. Proposed Lua modules

Two new modules mirroring the Go split, plus one shared date helper.

### 2.1 `lua/taskbuffer/datemath.lua` (new, shared with Parse)

Single source of truth for the canonical comparable date scalar and all
day arithmetic. Keeps the DST/anchor decision in exactly one place.

```lua
local M = {}

--- Canonical comparable: a LOCAL-NOON epoch (see §4 DST mitigation).
---@param y integer @param m integer @param d integer
---@return integer epoch  -- comparable with <, ==, >; os.date-formattable
function M.ymd_to_comparable(y, m, d) end

--- DST-safe day offset via table-field arithmetic (mutate .day, renormalize).
---@param epoch integer @param n integer
---@return integer
function M.add_days(epoch, n) end

--- Start-of-month-after-this-one for the date in `epoch` (day=1, month+1).
---@return integer
function M.start_of_next_month(epoch) end       -- helper for end_of_month

--- Build a comparable directly from broken-down fields (handles month overflow
--- via os.time normalization, e.g. month=13 -> next Jan).
---@param y integer @param m integer @param d integer
---@return integer
function M.ymd_normalize(y, m, d) end           -- = ymd_to_comparable, kept explicit

--- Render a comparable back to text via strftime (default "%Y-%m-%d").
---@param epoch integer @param strftime string|nil
---@return string
function M.format(epoch, strftime) end

--- Broken-down local fields of a comparable (for weekday math, y/m extraction).
---@param epoch integer
---@return table  -- os.date("*t", epoch): .year .month .day .wday (1=Sun..7=Sat)
function M.parts(epoch) end

return M
```

### 2.2 `lua/taskbuffer/horizon.lua` (new)

```lua
---@class ResolvedHorizon
---@field label string
---@field cutoff integer|nil   -- comparable epoch; nil for undated
---@field undated boolean
---@field order integer

local M = {}

function M.default_horizon_specs() end               -- horizon.go:31-42
function M.parse_duration(s) end                      -- -> days:int|nil, err
function M.parse_weekday(s) end                       -- -> 0..6 (Go numbering, Sun=0)
function M.resolve_calendar_keyword(kw, today, week_start) end  -- -> cutoff|nil, err
function M.parse_after_value(val, now, week_start) end          -- -> cutoff|nil, err
---@param specs table[]|nil @param now integer @param week_start integer @param overlap string
---@return ResolvedHorizon[]
function M.resolve_horizons(specs, now, week_start, overlap) end
return M
```

`specs` is `config.values.horizons` directly: a list of
`{ label=string, after=number|string|nil, undated=boolean|nil, order=integer|nil }`.

### 2.3 `lua/taskbuffer/format.lua` (new)

```lua
---@class FormatOpts
---@field show_markers boolean
---@field ignore_undated boolean
---@field tag_filter string[]        -- OR logic; empty/nil = no filter
---@field tag_prefix string|nil      -- default "#"
---@field marker_prefix string|nil   -- default "::"
---@field horizons ResolvedHorizon[]|nil  -- nil -> resolve defaults
---@field overlap string|nil         -- "sorted"|"first_match"|"narrowest"
---@field date_format string|nil     -- strftime; default "%Y-%m-%d"

local M = {}
function M.in_horizon(date, idx, horizons) end          -- format.go:10-16
function M.first_match_horizon(date, horizons) end       -- format.go:19-34
function M.narrowest_horizon(date, horizons) end         -- format.go:37-73
function M.format_task_line(task, opts) end              -- format.go:86-155  BYTE-EXACT
function M.task_matches_tags(task, tags) end             -- format.go:157-166
---@param tasks Task[] @param now integer @param opts FormatOpts
---@return string
function M.format_taskfile(tasks, now, opts) end         -- format.go:168-291
return M
```

**Task table shape consumed** (subset of the Parse blueprint's `Task`):
`{ filepath, line_number, body, due_date (comparable|nil), due_time (""),
duration (""), tags (string[]), markers ({kind,date,time}[]), sort_last (bool) }`.
`status` is irrelevant to format (it is consumed upstream).

**Slot-in / call sites.** `buffer.lua` (currently `build_cmd` → binary `list`)
calls `format.format_taskfile(tasks, now, opts)` where `tasks` come from
Scan→Parse→Frontmatter and `opts` is derived from `config.values`. The on-disk
text round-trip (CONTEXT §3) is preserved by default, so `format_taskfile`'s
return string is written verbatim to `<tmpdir>/<date>.taskfile`.

## 3. Algorithm / port notes

### 3.1 Date representation — the key decision (kills `extractDate`)

Go juggles two `time.Time` flavors: `Task.DueDate` is UTC-midnight (from
`time.Parse` in Parse), while cutoffs are **local**-midnight
(`extractDate(now)` + `AddDate`). `FormatTaskfile` reconciles them by calling
`extractDate(*t.DueDate)` before every bucket test (`format.go:243`). Sorting
(`format.go:210-211`) uses the *raw* `DueDate`, which is safe only because both
flavors are monotonic in calendar day.

In Lua we collapse this to **one canonical scalar**: a comparable integer at
**local noon** for both task dates and cutoffs (anchor rationale in §4). Then:

- **Sort**: compare `due_date` integers directly (`<`).
- **Bucket**: compare `due_date` to `cutoff` integers directly. No
  per-task re-localization — `extractDate` vanishes by construction.
- **Display**: `datemath.format(due_date, opts.date_format)` →
  `os.date("%Y-%m-%d", epoch)` → `"2026-02-17"` (strftime zero-pads `%m`/`%d`,
  matching Go layout `2006-01-02`).

**What I need from the Parse blueprint** (CONTEXT §7 coordination): for a dated
task, `task.due_date` must be the *same* canonical comparable, produced via
`datemath.ymd_to_comparable(y, m, d)`. Undated → `nil`. That is the only
contract: a value that is (a) `<`/`==`-comparable against cutoffs and (b)
`os.date`-formattable. **[DECISION D1]** — recommend Parse store the
`datemath` comparable so format does zero conversion; fallback acceptable shape
is `{year,month,day}` which format would convert at the boundary. Marker
`date`/`time` stay raw **strings** (verbatim passthrough, no math) — no
coordination needed (`format.go:147-150`, want strings in `format_test.go:93`).

### 3.2 `parse_duration` (horizon.go:44-65)

Go regex `^(-?\d+)([dwmy])$`. Lua patterns *do* support `?` (optional) and
anchors, so this ports almost verbatim:

```lua
local n_str, unit = s:match("^(%-?%d+)([dwmy])$")
if not n_str then return nil, ("invalid duration string: %q"):format(s) end
local n = tonumber(n_str)
local mult = ({ d = 1, w = 7, m = 30, y = 365 })[unit]
return n * mult
```

Rejects exactly the `horizon_test.go:TestParseDuration_EdgeCases` set: `"1dd"`,
`"d2"`, `"2x"`, `"2 d"`, `" 1d"`, `"1d "`, `"1D"`, `""` (anchors + single
`[dwmy]` + escaped optional `%-`). Accepts `"0d"→0`, `"-1w"→-7`, `"999y"→364635`.
`TestParseDuration` pins the core cases.

### 3.3 Calendar keywords (horizon.go:69-100) — exact cutoff math

All cutoffs are **start-of-next-period (exclusive upper bound)**, computed by
table-field arithmetic normalized through `os.time` (month overflow handled by
`os.time`, e.g. `month=13` → next Jan). `today` is a comparable; use
`datemath.parts(today)` for `.year`/`.month` and weekday.

| keyword | Go (`horizon.go`) | Lua cutoff | pinned by |
|---|---|---|---|
| `past` | `today.AddDate(-100,0,0)` `:72` | `ymd_normalize(y-100, m, d)` | `TestParseAfterValue_CalendarKeywords` past→`1926-02-17` |
| `yesterday` | `AddDate(0,0,-1)` `:74` | `add_days(today, -1)` | …→`2026-02-16` |
| `end_of_week` | `:76-87` (see below) | weekday formula below | `TestResolveCalendarKeyword_WeekBoundaries` (14 cases) |
| `end_of_month` | `Date(y, m+1, 1)` `:90` | `ymd_normalize(y, m+1, 1)` | `TestResolveCalendarKeyword_MonthBoundaries` (Dec→`2027-01-01`) |
| `end_of_quarter` | `((m-1)/3)*3+4` `:93` | `ymd_normalize(y, math.floor((m-1)/3)*3+4, 1)` | `TestResolveCalendarKeyword_QuarterBoundaries` (Q4→`2027-01-01`) |
| `end_of_year` | `Date(y+1,1,1)` `:96` | `ymd_normalize(y+1, 1, 1)` | …→`2027-01-01` |
| (other) | error `:98` | `return nil, "unknown calendar keyword: "..kw` | `TestParseAfterValue_InvalidInput` |

`end_of_quarter` **must use integer division** (`math.floor`): `m=1,2,3→4`;
`4,5,6→7`; `7,8,9→10`; `10,11,12→13`(→Jan next yr). `m+1`/`qMonth=13` rely on
`os.time` normalizing the overflowed month — verified against the Dec boundary
tests.

**`end_of_week`** (horizon.go:79-87) — depends on `week_start`. Go weekday
numbering is **Sun=0..Sat=6**; Lua `os.date("*t").wday` is **Sun=1..Sat=7**, so
convert `go_wday = parts.wday - 1`. `parse_weekday` returns Go numbering
(0..6, default Monday=1). Port verbatim:

```lua
local week_end = week_start - 1            -- Mon(1) -> Sun(0); Sun(0) -> -1
if week_end < 0 then week_end = 6 end      -- time.Saturday
local today_wday = datemath.parts(today).wday - 1
local days_until_end = (week_end - today_wday + 7) % 7
if days_until_end == 0 then days_until_end = 7 end
return add_days(today, days_until_end + 1)
```

Hand-verified against the golden table: Tue Feb17 / Monday-start → +6 →
`2026-02-23`; Tue Feb17 / Sunday-start → +5 → `2026-02-22`; Sun Feb22 /
Monday-start → +8 → `2026-03-02`; Sat Feb21 / Sunday-start → +8 → `2026-03-01`.

### 3.4 `parse_after_value` (horizon.go:126-146) — simplified, no JSON floats

Config delivers native Lua values (CONTEXT §4: no JSON float ambiguity), so the
`float64` vs `int` split collapses:

```lua
local t = type(val)
if t == "number"  then return add_days(now_today, (math.modf(val))) end  -- trunc toward 0 like Go int()
if t == "string"  then
  local days = parse_duration(val)
  if days then return add_days(now_today, days) end
  return resolve_calendar_keyword(val, now_today, week_start)            -- propagates error for bogus kw
end
if val == nil then return nil, "after value is nil" end
return nil, ("unsupported after type: %s"):format(t)                      -- bool/table
```

`now_today = extractDate(now)` equivalent = the comparable for now's calendar
day (`datemath.parts(now)` → `ymd_to_comparable`). `math.modf` truncates toward
zero to match Go's `int(v)` (only matters for fractional input; config offsets
are integers). Pinned: integer offsets `TestParseAfterValue_IntegerOffset`
(0→today, 1→tomorrow, -7→`2026-02-10`); durations `…_DurationString`;
unsupported `…_UnsupportedTypes` (bool/slice error, `int(5)`→`2026-02-22`); nil
+ bogus `…_InvalidInput`.

### 3.5 `resolve_horizons` (horizon.go:151-216)

```
specs = (specs is nil or empty) ? default_horizon_specs() : specs
dated, undated, parse_errors = {}, {}, {}
for i, s in ipairs(specs):            -- Lua i is 1-based; Go i is 0-based
    if s.undated:
        order = s.order or (#specs + (i-1))     -- Go: len(specs)+i
        push undated {label=s.label, undated=true, order=order, cutoff=nil}
    else:
        cutoff, err = parse_after_value(s.after, now, week_start)
        if err: push parse_errors(...); continue        -- SKIP this spec
        order = s.order or (i-1)                          -- Go: i
        push dated {label=s.label, cutoff=cutoff, undated=false, order=order}
if #parse_errors > 0:
    (warn each via vim.notify WARN, replacing Go's os.Stderr  -- behavior, not bytes)
    if #dated == 0: return resolve_horizons(default_horizon_specs(), now, week_start, overlap)  -- full fallback
if overlap == "" or overlap == "sorted":
    table.sort(dated, by cutoff ascending)   -- comparator: a.cutoff < b.cutoff
    for i, h in ipairs(dated): h.order = i-1   -- reassign 0-based
return concat(dated, undated)                  -- dated first, then undated
```

Notes:
- `order` is **metadata only** — `format` never reads it; slice/list *order* is
  what drives display. Kept for parity with `TestResolveHorizons_ExplicitOrder`
  (which uses `overlap="explicit"` so the sort/reassign branch is skipped and
  `s.order` survives).
- `table.sort` (like Go `sort.Slice`) is **not stable**; duplicate cutoffs
  (`TestResolveHorizons_DuplicateCutoffs`) only need both present, order
  unspecified — fine. Comparator must be strict-weak (`a<b`), never `<=`, to
  avoid Lua's "invalid order function".
- Pinned: `_DefaultsWhenNil`/`_EmptySlice` (8), `_CustomSpecs` (4, order
  preserved), `_SortedOverlap` (reorder Past/Now/Later + ascending cutoffs),
  `_FallbackOnError` (8), `_MixedValidInvalid` (2: skip bad, keep good),
  `_OnlyUndated` (2 undated), `_MultipleUndated` (count==2).

### 3.6 Bucketing strategies (`in_horizon`/`first_match`/`narrowest`)

All take comparable integers; Go's `Equal/After/Before` → `==`/`>`/`<`.

**`in_horizon(date, idx, horizons)`** (format.go:10-16):
```lua
if idx == #horizons then return date >= horizons[idx].cutoff end
return date >= horizons[idx].cutoff and date < horizons[idx+1].cutoff
```
(`idx` is 1-based in Lua; "last" = `#horizons`.) Pinned bit-for-bit by
`TestInHorizon_Boundaries` (day0∈H0 true, day2∈H0 false, day2∈H1 true,
day10∈H2 true — open-ended last; exact-cutoff lands in the *upper* bucket).

**`first_match_horizon`** (format.go:19-34): first listed non-undated horizon
with `date >= cutoff`; else fallback to **last** non-undated index; else 1.
List order matters (not sorted) — `TestFirstMatchHorizon_Basic` uses unsorted
horizons and a future-only fallback returning the last horizon.

**`narrowest_horizon`** (format.go:37-73): tightest containing range.

```lua
local best_idx, best_span = nil, math.huge      -- Go init = MaxInt64
local OPEN = 2^53                                 -- Go open-ended span = 1<<62-1; any value
                                                  -- with: real_span < OPEN < math.huge
for i, h in ipairs(hs) do
  local in_range, span = false, nil
  if i == #hs or hs[i+1].undated then             -- open-ended (last / before-undated)
    if date >= h.cutoff then in_range, span = true, OPEN end
  else
    if date >= h.cutoff and date < hs[i+1].cutoff then
      in_range, span = true, hs[i+1].cutoff - h.cutoff
    end
  end
  if in_range and span < best_span then best_span, best_idx = span, i end  -- STRICT < -> first wins ties
end
if not best_idx then return last-non-undated, else 1 end
return best_idx
```

**Sentinel subtlety (do not collapse to `math.huge`):** Go uses
`bestSpan = 1<<63-1` (init) and open span `1<<62-1` (`format.go:39,50`); since
`1<<62-1 < 1<<63-1`, an open-ended bucket *is* selectable when it is the only
match. If you naively set both to `math.huge`, `OPEN < best_span` is `false`
and open-ended buckets would never be chosen — a real bug. Keep
`init = math.huge` strictly greater than `OPEN`, and `OPEN` strictly greater
than any real span (epoch-second differences are < ~2^35, well under 2^53).
Pinned: `TestNarrowestHorizon_Basic` (day3→Narrow span beats Wide; day6→Far
open-ended), `TestFormatTaskfile_NarrowestOverlap`.

Note: in production all three receive `dated_horizons` (undated already
removed in `format_taskfile`), so the `undated` guards are dead but harmless —
keep them for unit-test parity (the unit tests pass undated-free lists too).

### 3.7 `format_task_line` — BYTE-EXACT column spec (format.go:86-155)

Emit segments into a per-line `parts` table; `table.concat(parts)`. No `..` in
loops. Each row below is the exact byte sequence; `\t` = literal tab,
`·` marks a literal space for clarity (do **not** emit `·`).

| # | Segment | Condition | Exact bytes | Go ref |
|---|---|---|---|---|
| 1 | Location | always | `{filepath}:{lineno}:1:` via `string.format("%s:%d:1:", …)` | `:90` |
| 2 | Date (dated) | `due_date` set | `\t[[` + `os.date(fmt,due_date)` + `]]` | `:97-98` |
| 2 | Date (undated) | `due_date` nil | `\t··········` (TAB + **10 spaces**) | `:100` |
| 3 | Time (timed) | `due_time ~= ""` | `·|·` + `due_time` + `·|` (leading SPACE, **no tab**) | `:104-105` |
| 3 | Time (untimed) | `due_time == ""` | `\t·|·······|` (leading **TAB** + 7 spaces between pipes) | `:107` |
| 4 | Duration (set) | `duration ~= ""` | left-pad `duration` to width 4 + `·|` | `:111-116` |
| 4 | Duration (unset) | `duration == ""` | `·····|` (**5 spaces** + pipe) | `:118` |
| 5 | Body | always | `\t·` + `body` + `·\t` | `:122` |
| 6 | Tags | `#tags>0` | `·` then `prefix..tag`, space-separated | `:125-138` |
| 7 | Markers | `show_markers && #markers>0` | per marker: `·` + `prefix..kind` + `·[[` + `date` + `]]` + (`time~=""` ? `·`+`time`) | `:141-151` |

**The two quirks to not miss:**

1. **Leading-tab only when no time** (segment 3). With a time, the time column
   starts with a *space* and relies on the date column's `]]` immediately
   before (`\t[[2026-02-17]] | 16:00 |`). Without a time, the column instead
   *prepends a TAB* (`\t[[2026-02-17]]\t |       |`), so dated-untimed lines
   carry **two** tabs in the date+time region and undated lines do too
   (`\t          \t |       |`). This is the single trickiest byte in the whole
   format. Pinned by `TestFormatTaskLine_WithTime` vs `_WithDuration` vs
   `_Undated` (`format_test.go:42,58,162`).

2. **Duration is RIGHT-justified to width 4** (pad on the *left*), not left.
   `"5m"→"··5m·|"`, `"30m"/"90m"→"·30m·|"/"·90m·|"`, `"120m"→"120m·|"` (no pad),
   `"1440m"→"1440m·|"` (overflow, pad clamped to 0). Pinned by
   `TestFormatTaskLine_ShortDuration` (`··5m·|`) and `_WithDuration` (`·90m·|`).

**Padding helpers (Go `strings.Repeat`/`%-Ns` analogue).** Lua `string.format`
*does* delegate width specs to C `printf`, so `string.format("%4s |", dur)`
right-justifies exactly like Go's left-pad — and `%4s` does not truncate longer
strings (matches Go clamping pad to 0). I still recommend an explicit helper to
keep intent obvious and avoid any reliance on C-printf width behavior:

```lua
local function lpad(s, w) return string.rep(" ", math.max(0, w - #s)) .. s end
-- duration column:  lpad(duration, 4) .. " |"        (== string.format("%4s |", duration))
```

The date/time/empty-duration columns are **fixed literals** (10 spaces, 7
spaces, 5 spaces) — hard-code them, do not compute. `string.format("%d", …)`
for the line number requires an integer (ensure Parse yields integer
`line_number`; LuaJIT is lenient but 5.3+ errors on fractional).

### 3.8 `format_taskfile` (format.go:168-291) — orchestration

1. **Tag filter** (`:170-178`): if `#opts.tag_filter>0`, keep tasks where
   `task_matches_tags` (OR over filter ∩ task tags). `task_matches_tags`:
   nested loop / set membership; any match → true (`format.go:157-166`).
2. **Resolve horizons** (`:181-184`): `opts.horizons` or
   `resolve_horizons(nil, now, parse_weekday("monday")=1, "sorted")`.
   (Note Go hardcodes `time.Monday` here; in the real plugin pass
   `config.week_start`.)
3. **Split horizons** (`:187-196`): `dated_horizons` = non-undated in list
   order; `undated_horizon` = the **last** undated in the list (Go reassigns on
   each hit → last wins; multiple undated all funnel into this one label).
4. **Split tasks** (`:199-206`): `due_date` set → dated, else undated.
5. **Sort** (see §3.9).
6. **Emit dated** (`:242-270`) with the stateful header machine:
   ```
   interval, last_interval = 1, nil    -- Lua 1-based; Go interval=0,last=-1
   out = {}
   for _, t in ipairs(dated):
     date = t.due_date
     if overlap == "first_match": interval = first_match_horizon(date, dated_horizons)
     elseif overlap == "narrowest": interval = narrowest_horizon(date, dated_horizons)
     else: -- "sorted": monotonic forward scan from current interval
       for i = interval, #dated_horizons do
         if in_horizon(date, i, dated_horizons) then interval = i; break end
       end
     if interval ~= last_interval:
       if last_interval ~= nil then out[#out+1] = "\n" end   -- blank line BETWEEN buckets
       out[#out+1] = dated_horizons[interval].label
       out[#out+1] = "\n"
       last_interval = interval
     out[#out+1] = format_task_line(t, opts)
     out[#out+1] = "\n"
   ```
   - **Sorted is stateful & monotonic**: `interval` persists and only advances
     (relies on ascending date sort). If nothing matches from `interval`
     onward, `interval` keeps its prior value (Go semantics — e.g. a date before
     the earliest cutoff lumps into the current/first bucket). Reproduce
     verbatim; do **not** reset to 1 per task.
   - **first_match/narrowest are stateless** per task; `interval` can decrease,
     so a non-consecutive repeat of a bucket re-emits its header (Go only
     suppresses *consecutive* duplicates via `last_interval`). Reproduce — do
     not "dedupe".
7. **Emit undated** (`:272-288`): `label = undated_horizon.label or "# Someday"`.
   If `#undated>0 and not opts.ignore_undated`: if `#out>0` push `"\n"` (blank
   separator only when prior content exists), push `label`, `"\n"`, then each
   line + `"\n"`.
8. `return table.concat(out, "")` (empty input → `out` empty → `""`).

**Blank-line model:** a blank line is a bare `"\n"` pushed *before* a header,
which combines with the preceding line's trailing `"\n"` to render one empty
line. Never before the first header. Verified against the multi-bucket layout
implied by `TestFormatTaskfile_BucketsAndHeaders` and `_SomedayBucket`.

### 3.9 Sorting (format.go:209-231) — total cascading comparators

Lua `table.sort` needs a strict-weak `less(a,b)`; build it to bottom out at
`line_number` (total) so it never errors.

- **dated** (`:209-220`): `due_date` < ; then `filepath` < ; then `sort_last`
  (non-`sort_last` first: `if a.sort_last ~= b.sort_last then return not a.sort_last`);
  then `line_number` <.
- **undated** (`:223-231`): `filepath` < ; then `sort_last`; then `line_number` <.

`sort_last` = synthetic project tasks (`scan.go:245`) sorting *after* real
tasks at the same key. Pinned by `TestFMDue_SortLastComparatorUnit`
(`fm_due_e2e_test.go:1063`). `table.sort`/`sort.Slice` both unstable, but the
comparators are total so any residual tie is a true duplicate (order moot).
General sort pinned by `TestFormatTaskfile_SortsByDate`,
`_AllTasksSameDate` (filepath a<b<c).

## 4. Latency analysis

Format is **not** a hot path: `O(n log n)` sort + `O(n)` emit for `n` =
hundreds–low-thousands of tasks. Two `table.sort` calls and one linear pass:
expected **well under 1 ms**, dwarfed by Scan/Parse. Concerns are constant
factors, not complexity:

- **No `..` accumulation in loops.** Building the file via `result = result ..
  line` is `O(n²)` garbage. Use a single `out = {}` buffer, `out[#out+1] = …`,
  one terminal `table.concat(out, "")`. Same inside `format_task_line` (a small
  `parts` table per line). This is the one real Lua pitfall here.
- **`os.date`/`os.time` per task.** One `os.date(fmt, due_date)` per dated line
  for display, plus a handful in horizon resolution (≤ #horizons, once per
  refresh). At low-thousands of lines this is microseconds-scale; if ever hot,
  cache `os.date` results by `due_date` (dates repeat heavily across tasks) —
  but **not needed** at target scale.
- **Comparator overhead.** Cascading field comparisons are cheap; avoid
  building sort keys with string concat. Comparing integer `due_date` directly
  (not re-deriving from y/m/d) keeps it tight — another reason for the
  comparable-scalar shape (§3.1).
- Runs on the UI thread after Scan (rg can be async). Format's contribution to
  the ~50 ms budget is negligible; the budget is spent in Scan/Parse
  (Integration blueprint).

## 5. Decisions to flag

- **[D1] `Task.due_date` shape (coordinate w/ Parse).** *Recommend:* Parse
  stores the `datemath.ymd_to_comparable` scalar (local-noon epoch). Rationale:
  zero per-task conversion in format/sort; one anchor decision; integer
  comparisons. *Alt:* Parse stores `{year,month,day}`; format converts at the
  boundary (costs one `os.time`/task, and re-introduces an anchoring touch-point
  in two modules). Either is correct; the scalar is faster and centralizes DST.
- **[D2] Date anchor = local noon, not midnight.** *Recommend* noon (see §4
  below). *Alt:* midnight (matches Go literally) — works for ordering/equality
  but is fragile in the handful of zones with a midnight DST transition. Noon
  changes **no** observable bytes (display day is identical) and removes the
  fragility entirely. Flagged because it deviates from Go's literal
  `extractDate` midnight.
- **[D3] Parse-error reporting channel.** Go writes warnings to `os.Stderr`
  (`horizon.go:195`). *Recommend* `vim.notify(msg, WARN)`. Not byte-observable;
  no test asserts the text — only the *fallback behavior* is pinned
  (`_FallbackOnError`, `_MixedValidInvalid`).
- **[D4] `%4s` vs explicit `lpad`.** *Recommend* explicit `lpad` helper for
  legibility; `string.format("%4s |", dur)` is an equivalent shortcut (Lua
  delegates width to C printf). Flagged only because CONTEXT §"Lua string.format
  lacks Go's %-Ns" implies it cannot — it can; the real reason to prefer `lpad`
  is intent-clarity, not capability.
- **[D5] `week_start` source in `format_taskfile`'s default path.** Go hardcodes
  `time.Monday` at `format.go:183`. *Recommend* the plugin always pass resolved
  `opts.horizons` (built from `config.week_start`) so this default branch is
  never hit; keep the Monday hardcode only as the literal fallback for parity.

## 6. Edge cases → tests

- **nil / empty tasks** → `""`. `TestFormatTaskfile_EmptyInput`. Guard
  `tasks = tasks or {}`.
- **Only undated** → `# Someday` only, no dated headers.
  `TestFormatTaskfile_OnlyUndated`; no leading blank since `#out==0`.
- **Undated present + dated present** → undated section after a blank.
  `_SomedayBucket`.
- **Undated hidden** (`ignore_undated`) → drop section + tasks, keep dated.
  `_IgnoreUndated`, `_IgnoreUndatedKeepsDated`.
- **Empty buckets skipped** → only headers with ≥1 task appear.
  `_SkipsEmptyBuckets`, `_ExactBoundaryDate` (`# Past` absent),
  `_AllTasksSameDate` (`# Future` absent).
- **Tag filter OR** → union of matching tags; non-matching dropped.
  `_TagFilter`, `_TagFilterOR`.
- **Custom horizons + custom undated label** → use provided list, not defaults.
  `_CustomHorizons` (`# Backlog` not `# Someday`), `_CustomUndatedLabel`
  (`# Inbox`).
- **Overlap strategies** → `_FirstMatchOverlap` (unsorted list order;
  General-before-Priority by date sort), `_NarrowestOverlap` (Wide/Narrow/Far),
  default sorted `_BucketsAndHeaders`.
- **Single open-ended horizon** → everything in one bucket. `_SingleHorizon`.
- **Exact cutoff lands in upper bucket** → `date == cutoff` ∈ that horizon,
  not the prior. `_ExactBoundaryDate`, `TestInHorizon_Boundaries`.
- **Far-off / overdue** default buckets → `_BucketsAndHeaders` (Overdue,
  Far Off positions).
- **SortLast ordering** → synthetic project task after real task at same key.
  `TestFMDue_SortLastComparatorUnit`.
- **Custom date format in output** → `os.date(opts.date_format, …)`; default
  `%Y-%m-%d`. (Display path; the `mustDatePtr` fixtures all use `%Y-%m-%d`.)
- **Byte-exact line forms** → `_Simple`, `_WithTime`, `_WithDuration`,
  `_ShortDuration`, `_WithTags`, `_WithMarkers`, `_MarkersHiddenByDefault`,
  `_Full`, `_Undated` (the canonical column-quirk fixtures).
- **Horizon resolution** → all of §3.5's pinned tests (defaults/empty,
  custom, sorted reorder, fallback, mixed valid/invalid, only-undated,
  duplicate cutoffs, explicit order, multiple undated).
- **Calendar/duration math** → §3.2/§3.3 pinned tables (week boundaries ×14,
  month, quarter, year; duration edge cases ×10; after-value types).

## 7. Test strategy

- **Golden parity, line-for-line.** Port `format_test.go`'s `formatTaskLine`
  fixtures to busted/plenary as exact-string assertions (these are the
  byte-contract). Keep the literal `want` strings verbatim — they encode the
  tab/space layout that humans cannot eyeball.
- **Fixed `now`.** Inject `now = datemath.ymd_to_comparable(2026, 2, 17)` (the
  Go `testNow`/`testToday`, a Tuesday) so cutoffs are deterministic regardless
  of the runner's clock. All horizon math tests pass `now`/`today` explicitly.
- **Order-via-`string.find`.** Port the `strings.Index` ordering assertions
  (`_BucketsAndHeaders`, overlap tests) using `string.find` offsets — they
  assert relative section/task positions, not bytes.
- **Calendar tables.** Port the parameterized `TestResolveCalendarKeyword_*`
  and `TestParseAfterValue_*` tables directly; compare
  `datemath.format(cutoff, "%Y-%m-%d")` to the Go `want`.
- **DST cross-check (non-golden).** Add a Lua-only test that runs the week/day
  offset math under a spring-forward TZ (`TZ=America/Santiago` historically had
  midnight transitions) asserting `add_days` never drifts a calendar day — this
  is the regression guard the Go suite cannot express.
- **Bucketing units.** Port `TestInHorizon_Boundaries`,
  `TestFirstMatchHorizon_Basic`, `TestNarrowestHorizon_Basic` against hand-built
  `ResolvedHorizon` lists with integer cutoffs (`now + k days`).
- **Optional end-to-end golden file.** Once Scan/Parse land, capture the Go
  binary's `list` stdout for a fixture vault and diff the Lua output
  byte-for-byte (`assert.equals`) — the strongest parity check.

## 8. Open questions / risks

- **R1 (anchor coordination).** [D1]/[D2] must be agreed with Parse *before*
  either codes the date field, or task dates and cutoffs land on different
  anchors and bucketing silently misfiles boundary dates. Single shared
  `datemath` module removes the risk; confirm Parse imports it.
- **R2 (`os.time` table-arithmetic correctness).** The whole port leans on
  `os.time` normalizing overflowed fields (`month=13`, `day=0`, negative day).
  This is C `mktime` behavior — reliable on Linux/macOS LuaJIT, but worth a
  dedicated unit test (month rollover, year rollover, leap day 2028-02-29) since
  it underpins every keyword cutoff.
- **R3 (display vs parse format coupling).** Output dates are rendered with
  `config.formats.date` strftime and must round-trip through
  `util.parse_taskfile_line` / the Parse regex. If a user sets an exotic
  `date_format`, the time column's fixed 7-space width can misalign visually
  (Go has the identical limitation — `due_time` is never padded, see
  `parse_test.go:514` `"1:00 PM"`); bytes still match, only cosmetics differ.
- **R4 (`narrowest` sentinel in doubles).** Confirm the chosen `OPEN` constant
  (`2^53`) stays strictly between max real span and `math.huge` on the target
  LuaJIT build; if LuaJIT 64-bit ints are used for cutoffs, real spans are
  exact and the inequality still holds — but verify, since collapsing the
  sentinel to `math.huge` is a silent correctness bug (§3.6).
- **R5 (multiple-undated label).** Go funnels *all* undated tasks under the
  *last* undated horizon's label and silently drops earlier undated labels in
  the format stage (resolution keeps them, format ignores all but the last).
  No format test pins multi-undated display; confirm this is intended before
  relying on it.
