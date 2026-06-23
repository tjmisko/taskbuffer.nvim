# 02 — Parse blueprint (Go `parse.go` + `timeformat.go` → Lua)

> Design blueprint, not implementation. Cites Go `file:line` and Go test names.
> Shared facts come from `docs/rewrite/CONTEXT.md`; not re-derived here.

## 1. Scope

I own the line-level parser and the strftime→pattern/validation layer:

- `go/parse.go` (331 lines): `NewParseContext` (`parse.go:50`), `ParseTask`
  (`parse.go:183`), `ParseTasks` (`parse.go:318`), the `Task`/`Marker` structs
  (`parse.go:11-28`), and the `ParseContext` shape (`parse.go:31-46`).
- `go/timeformat.go` (127 lines): `StrftimeToGo`, `StrftimeToRegex`,
  `convertStrftime`, `ResolveDateTimeFormats`, and the two directive tables
  (`timeformat.go:18-41`).
- The `DateError` contract (`go/main.go:79-100`) and strict-mode collection it
  feeds (`parse.go:209-227`, `parse.go:255-275`).

Out of scope but reconciled: `lua/taskbuffer/util.lua`'s existing
`resolve_date_config` / `parse_date_components` / `shift_date_in_string`
(util.lua:85-238) already do a *partial* strftime→Lua-pattern conversion
(only `%Y %m %d %F`, no validation, DST-fragile day math). These must be
re-pointed at the shared module below so there is exactly one converter.

Not mine: `Scan`/rg (→ Scan blueprint), `frontmatter.go`'s
`MergeFrontmatterDue` and `ScanProjects` date validation (→ Frontmatter
blueprint), `format.go`/`horizon.go` consumption of `due_date` (→ Format /
Horizon). I only define the `due_date` *shape* they must accept and provide the
date helpers (`date_to_iso`, `date_compare`, `validate_date`) they reuse.

## 2. Proposed Lua modules

Two new files, plus a refactor of `util.lua` to drop its duplicate converter.

### `lua/taskbuffer/strftime.lua` (new) — the date-format layer

Replaces `timeformat.go` *and* unifies util.lua's converter. There is **no Go
layout string** in Lua (no `time.Parse`); the Go-layout half of
`timeformat.go` (`strftimeToGoMap`, `StrftimeToGo`) is obsolete — its only job
was feeding `time.Parse`, which we replace with explicit component extraction +
`validate_date`. We keep only the regex/pattern half plus validation.

```lua
local M = {}

-- Compile a strftime format into Lua-pattern material. Pure, cacheable.
---@class StrftimeSpec
---@field run     string   -- non-capturing run for embedding, e.g. "%d%d%d%d%-%d%d%-%d%d"
---@field capture string   -- anchored capture pattern, e.g. "^(%d%d%d%d)%-(%d%d)%-(%d%d)$"
---@field order   string[] -- capture→field map, e.g. {"Y","m","d"}; {} for time-only fmts
---@field has_date boolean -- true if Y/m/d directives present (validatable)
function M.compile(strftime_fmt) end          -- returns StrftimeSpec

-- Extract integer components from a matched date string using a compiled spec.
---@return integer? year, integer? month, integer? day   -- nil,nil,nil on no match
function M.components(date_str, spec) end

-- Strict calendar validator (range + days-in-month + leap year).
---@return boolean ok, string? reason
function M.validate_date(year, month, day) end

-- DateError helpers (mirror go/main.go:79-100).
---@class DateError { file_path, line_number?, date_str, context, err }
function M.new_date_error(file_path, line_number, date_str, context, reason) end
function M.collect_date_error(list, err) end  -- append if list ~= nil (parse.go:96)
function M.format_date_error(err) end         -- "date error: f:l: invalid <ctx> "<d>": <e>"

-- Convenience used by both parse.lua and util.lua's shift/set.
function M.date_to_iso(due_date) end          -- {year,month,day} -> "YYYY-MM-DD"
function M.date_compare(a, b) end             -- calendar compare of two due_date tables
return M
```

### `lua/taskbuffer/parse.lua` (new) — the line parser

```lua
local M = {}

---@class Task
---@field file_path   string
---@field line_number integer
---@field body        string
---@field due_date    {year:integer,month:integer,day:integer}|nil  -- nil = undated
---@field due_time    string   -- "" or "HH:MM"/"1:00 PM"
---@field duration    string   -- "" or "30m"
---@field tags        string[] -- prefix-stripped, in source order
---@field status      string   -- "open"|"done"|"irrelevant"|<custom>
---@field markers     {kind:string,date:string,time:string}[]  -- date kept raw (unnormalized)
---@field sort_last   boolean

---@class RawMatch { path:string, line_number:integer, text:string }

---@class ParseContext   -- mirrors parse.go:31-46, but pattern *strings* not *Regexp
-- status_map      : { [checkbox_str] = status_name }   (dup-resolved, alpha-first)
-- checkboxes      : string[] sorted LONGEST-FIRST (ties alpha)  -- literal-prefix list
-- checkbox        : { [status_name] = checkbox_str }   (for mutate, not parse)
-- date_pat_time   : Lua pattern, captures (date,time)  -- inline due, with-time variant
-- date_pat_notime : Lua pattern, captures (date)       -- inline due, no-time variant
-- date_spec       : StrftimeSpec (for component extraction + validation)
-- marker_pat_time / marker_pat_notime : captures (kind,date,time)/(kind,date)
-- marker_start_pat: prefix+kw+"[[" locator (string.find index)
-- marker_prefix   : literal split delimiter
-- tag_pat         : "<pesc(prefix)>([%a_][%w_-]*)"
-- duration_pat    : "<(%d+)m>"   (hardcoded; parse.go:52 ignores configured fmt)
-- strict          : boolean
-- date_errors     : DateError[]|nil   (collector; nil = ignore)

function M.new_parse_context(config) end       -- config = require("taskbuffer.config").values
function M.parse_task(raw_match, ctx) end       -- -> Task|nil, err_string|nil
function M.parse_tasks(raw_matches, ctx) end    -- -> Task[]  (skips unparseable; parse.go:318)
return M
```

`new_parse_context` reads `config.formats.{date,time,tag_prefix,checkbox,
date_wrapper,marker_prefix}` and `config.strict` directly (no JSON boundary,
per CONTEXT §4). **[DECISION-S]** `config.strict` does not yet exist in
`config.lua:87` defaults — it must be added (top-level `strict = false`).

Slot-in: `buffer.lua`'s refresh builds `ctx` once and calls `parse_tasks` on the
rg results (replaces the `list` shell-out). `util.lua` `require`s `strftime` for
its shift/set converters.

## 3. Algorithm / port notes

### 3a. THE central problem — which regex engine

Go uses RE2 with alternation (`a|b|c`), optional non-capturing groups
(`(?:...)?`), and `\d{n}`. Lua patterns have none of these. Evaluated options:

| Option | Captures? | Alternation | Optional groups | Hot-loop cost | Verdict |
|---|---|---|---|---|---|
| (a) Lua `string.find`/`match` + manual tokenizing | yes | decompose | two concrete variants | native LuaJIT C, fastest | **chosen** |
| (b) `vim.regex` compiled once | **no** (whole-match byte offsets only) | yes | yes | C call/line, no submatches → must re-match anyway | rejected |
| (c) hybrid: literal checkbox prefix + Lua patterns for date/marker/tag | yes | n/a | n/a | fastest | **chosen (this is (a) refined)** |

**Recommendation: (c)/(a).** Do *not* use `vim.regex`. Its
`:match_str` returns only the whole-match `[start,end)` byte span with **no
capture groups**, so I could never pull out the date / time / marker-kind
substrings — I'd have to re-tokenize with Lua patterns regardless, paying the
Vim-engine cost for nothing. The Go regexes happen to be *alternation-free once
decomposed*, so native Lua handles them:

- **status (`parse.go:104` `^\s*(cb1|cb2|cb3)`):** drop regex entirely. After
  left-trimming `" \t"`, do **literal prefix matching**: for each configured
  checkbox string in a list **sorted longest-first** (ties alpha — replicates
  `sortByLengthDesc`, parse.go:101/170), test `stripped:sub(1,#cb) == cb`. This
  is O(Σ|cb|) literal byte compares, no escaping, and *naturally* reproduces
  longest-first / first-match (the alternation-shadow fix,
  `TestAdversarial_AlternationShortPrefixShadowsLong`), empty/whitespace-only
  rejection (filter `vim.trim(cb) == ""` at context-build, parse.go:67-71 →
  `TestAdversarial_EmptyCheckbox`, `TestAdversarial_WhitespaceOnlyCheckbox`),
  and newline-in-checkbox non-match (`TestAdversarial_NewlineInCheckbox`).
- **date / marker:** Lua patterns with the alias/path junk expressed as lazy
  `.-`, and the **optional time handled by trying two concrete patterns**
  (with-time first, no-time fallback) instead of an optional group. `\d{n}` is
  expanded to `%d%d…` runs by `strftime.compile` (§3b). `(?:[^|\]]*\|)?(?:.*/)?`
  → lazy `.-` between the open delimiter and the date.
- **tag (`parse.go:126` `#([A-Za-z_][\w-]*)`):** directly expressible:
  `vim.pesc(tag_prefix) .. "([%a_][%w_-]*)"` (note Lua `%w` excludes `_`, so the
  rest class is `[%w_-]`). `gmatch` to collect, `gsub` to strip from body.

Patterns are built **once** in `new_parse_context` and stored as strings on
`ctx`; the per-line loop only calls `string.find`/`gmatch`. (Lua patterns aren't
compiled objects, but reuse avoids rebuilding the pattern *strings* and the
`vim.pesc`/`strftime.compile` work each line.)

### 3b. strftime → pattern (replaces `timeformat.go`)

`strftime.compile(fmt)` walks the format like `convertStrftime`
(timeformat.go:61) and emits a `StrftimeSpec`. Directive table (covers the
required `%Y %m %d %H %M %I %p %F %R` plus `%%`):

| directive | `run` (embed) | `capture` field | `order` |
|---|---|---|---|
| `%Y` | `%d%d%d%d` | `(%d%d%d%d)` | Y |
| `%m` | `%d%d` | `(%d%d)` | m |
| `%d` | `%d%d` | `(%d%d)` | d |
| `%H` | `%d%d` | `(%d%d)` | — |
| `%M` | `%d%d` | `(%d%d)` | — |
| `%I` | `%d%d?` | `(%d%d?)` | — |
| `%p` | `[AaPp][Mm]` | `[AaPp][Mm]` | — |
| `%F` | `%d%d%d%d%-%d%d%-%d%d` | `(%d%d%d%d)%-(%d%d)%-(%d%d)` | Y,m,d |
| `%R` | `%d%d:%d%d` | `%d%d:%d%d` | — |
| `%%` | `%%` | `%%` | — |
| literal | `vim.pesc(ch)` | `vim.pesc(ch)` | — |

Two parity-critical transforms carried over from `convertStrftime`:
- **`%p` space collapse (timeformat.go:80-87):** if the literal immediately
  before `%p` is a single space, emit `%s*` instead of the escaped space. This
  makes `%I:%M %p` → run `%d%d?:%d%d%s*[AaPp][Mm]`, matching `"1:00 PM"`,
  `"12:30PM"`, `"1:00  AM"` (`TestStrftimeToRegex_12hTimeSpaceHandling`,
  `TestStrftimeToRegex_Matches` 12h row).
- **literal escaping** (`%d.%m.%Y` → dot is literal, not wildcard):
  `TestParseTask_CustomDateFormat_DotSeparatorEscaped`,
  `TestStrftimeToRegex` "European date with dots".

`run` is what gets embedded (captured once as the whole date string) in the
date/marker line patterns. `capture`+`order` are used only to split the matched
date string into Y/m/d for `validate_date`. This **subsumes** util.lua's
`resolve_date_config`/`parse_date_components` (which only knew `%Y %m %d %F`).

The Go `StrftimeToGo`/Go-layout tests (`TestStrftimeToGo`,
`TestResolveDateTimeFormats_*` GoDate/GoTime asserts) do **not** port — there is
no Go layout. The behavioral tests (`TestStrftimeToRegex_Matches`,
`_12hTimeSpaceHandling`) port directly against `compile(fmt).run`
anchored with `^…$`.

### 3c. Building the date matcher (`new_parse_context`)

Mirrors parse.go:131-143. `o,c2,c3 = wrapper[1],wrapper[2],wrapper[3]`. Two
layouts (parse.go:134 vs 137):

- **3-element / default** `(@[[ , ]] , )` — time sits *after* `]]`, before `)`:
  ```
  date_pat_time   = pesc(o) .. ".-(" .. D .. ")" .. pesc(c2) .. "%s*(" .. T .. ")" .. pesc(c3)
  date_pat_notime = pesc(o) .. ".-(" .. D .. ")" .. pesc(c2) .. "%s*"          .. pesc(c3)
  ```
- **2-element** `{a,b}` — Go inserts `\s*(TIME)?` *before* `b` (parse.go:141):
  ```
  date_pat_time   = pesc(o) .. ".-(" .. D .. ")%s*(" .. T .. ")" .. pesc(c2)
  date_pat_notime = pesc(o) .. ".-(" .. D .. ")%s*"             .. pesc(c2)
  ```
  Config fallback to default when wrapper has <2 non-empty elements
  (parse.go:134/137 guards → `TestAdversarial_ConfigFallbacks`).

`D = date_spec.run`, `T = time_spec.run`. The lazy `.-` reproduces the
alias/path strip `(?:[^|\]]*\|)?(?:.*/)?`: it expands minimally until `D` then
the closer matches (`TestParseTask_AliasDate`, `_PathPrefixDate`,
`_CustomDateFormat_WikilinkAlias`). Try `date_pat_time` first; on timed input
`date_pat_notime` *can't* match (the `)`/`c2` won't sit right after `]]`), so
order is safe but time-first is clearest.

Markers always use literal `[[ ]]` regardless of wrapper (parse.go:151 is
hardcoded — `TestAdversarial_MarkerDateIgnoresCustomWrapper`):
```
marker_pat_time   = "([%w_]+)%s+%[%[.-(" .. D .. ")%]%]%s*(" .. T .. ")"
marker_pat_notime = "([%w_]+)%s+%[%[.-(" .. D .. ")%]%]"
marker_start_pat  = pesc(marker_prefix) .. "%s*[%w_]+%s+%[%["
```
(`\w` → `[%w_]` since Lua `%w` omits underscore.)

### 3d. `parse_task` — the six steps (parse.go:183-316)

Pre: `line = trim_left(text, " \t")` then strip trailing `\r\n` (parse.go:184).

1. **Status** — loop `ctx.checkboxes` longest-first; first `line:sub(1,#cb)==cb`
   gives `checkbox_str`, `status = status_map[checkbox_str]`. No match →
   `return nil, "no checkbox found"`. `checkbox_end = #checkbox_str` (1-based
   body start = `checkbox_end+1`). (parse.go:187-196, 285.)

2. **Date group + index** — `s,e,date_str,time_str = line:find(date_pat_time)`;
   if nil retry `date_pat_notime` (then `time_str=""`). If found:
   - `date_group_start = s`, `date_group_end = e`,
     `after_date = line:sub(e+1)`, `body_end = s` (exclusive).
   - `y,m,d = strftime.components(date_str, date_spec)`; `ok = validate_date(...)`.
   - **valid** → `due_date = {year=y,month=m,day=d}`, `due_time = time_str or ""`.
   - **invalid + strict** → `collect_date_error(ctx.date_errors, …context="inline
     due date")`, leave `due_date=nil`, **continue** parsing body/tags/markers
     (parse.go:211-219; `TestDateValidation_InlineDates_Strict`,
     `_StrictPreservesBody`).
   - **invalid + non-strict** → `return nil, 'unparseable date "<d>"'`
     (parse.go:220-222; `TestDateValidation_InlineDates_NonStrict`,
     `TestAdversarial_InvalidDateValues`).
   - No regex match at all → undated, **no error** (distinct from invalid):
     `(@[[]])` → `date_pat_*` don't match → `TestParseTask_EmptyDate`. First of
     multiple groups wins because `string.find` is leftmost
     (`TestAdversarial_MultipleDateGroups`).

3. **Duration** — `dur = line:match(duration_pat)`; if set `duration = dur.."m"`
   (parse.go:230-235). Hardcoded `<(%d+)m>` for parity
   (`TestParseTask_WithDuration`, `_UndatedWithDuration`).

4. **Markers** — compute `after_date` slice (parse.go:237-248):
   - dated: `line:sub(date_group_end+1)`.
   - undated: `i = line:find(marker_start_pat)`; `after = i and line:sub(i) or ""`.
   Then `split_plain(after, marker_prefix)` (parse.go:249), `vim.trim` each
   segment, skip empties; for each try `marker_pat_time` then `marker_pat_notime`
   → `{kind,date,time or ""}`. In **strict** mode validate `date` via
   `components`+`validate_date`, collecting `context = "marker ("..kind..")"`
   (parse.go:257-268; `TestDateValidation_MarkerDates_Strict`,
   `_MultipleMarkers`). Non-strict stores raw, **no** validation
   (`TestDateValidation_MarkerDates_NonStrict` keeps `"2026-13-45"`). Marker
   `date` is kept **as matched** (alias/path stripped, format-preserved):
   `TestParseTask_MarkerWithPathPrefixDate` → `"2025-06-13"`;
   `_CustomDateFormat_MarkersWithCustomFormat` → `"03/04/2026"`.

5. **Tags** — `for t in line:gmatch(tag_pat) do tags[#tags+1]=t end` over the
   **whole line** (parse.go:278; `TestParseTask_WithTags`,
   `_UndatedWithTags`, `_NoSpaceMarkers` → `"fish-tank"`).

6. **Body** — (parse.go:284-303):
   - dated: `body = line:sub(checkbox_end+1, date_group_start-1)`.
   - undated: `body_end = line:find(marker_start_pat) or (#line+1)`;
     `body = line:sub(checkbox_end+1, body_end-1)`.
   - strip duration: `gsub(body, pesc("<"..dur.."m>"), "", 1)`.
   - strip tags: `gsub(body, tag_pat, "")`.
   - `body = vim.trim(body)`.
   The marker-start (prefix+kw+`[[`) boundary—not a bare prefix—keeps `::` in
   body text from truncating (`TestAdversarial_MarkerPrefixInBodyText`
   `std::vector`; `TestAdversarial_MarkerPrefixSingleColon`). Dated bodies use
   `date_group_start`, never the prefix, so `Note: fix bug (@[[…]])` survives.

`parse_tasks` maps `parse_task` over matches, dropping `nil` results (warn under
a `Verbose`-equivalent), exactly like parse.go:318-331
(`TestParseTasks_SkipsUnparseable`).

### 3e. `validate_date` (replaces `time.Parse` strictness)

```
ok = month in 1..12  and  day in 1..days_in_month(year,month)
days_in_month = {31, feb, 31,30,31,30,31,31,30,31,30,31}
feb = (leap(year) and 29) or 28
leap(y) = (y%4==0 and y%100~=0) or y%400==0
```
Covers every `invalidDateCases`/`validDateCases` row in
`date_validation_test.go:12-51` (month 00/13/99, day 00/32/99, 30-day-month 31,
Feb 30/31, Feb 29 non-leap 2025, century non-leap 2100; valid Feb 29 leap 2024
and century-leap 2000). This is the only correctness-critical replacement of Go
semantics, since `os.time`/`os.date` silently normalize `2026-13-45`
(CONTEXT §6.6).

## 4. due_date representation — **[DECISION-D]**

Go: `DueDate *time.Time`, nil = undated (parse.go:16). Downstream needs:
(i) calendar compare for horizon bucketing/sort (format.go), (ii) format to the
**always-ISO** `[[YYYY-MM-DD]]` display column (CONTEXT §3 `want` strings show
ISO regardless of input `date_format`), (iii) day arithmetic for horizons.

| candidate | compare | display ISO | day math | DST risk |
|---|---|---|---|---|
| `{year,month,day}` table | trivial field compare | `date_to_iso` | `os.time{y,m,d}` normalize (DST-safe, CONTEXT §6.5) | none |
| `"YYYY-MM-DD"` string | lexicographic ok | identity | must re-parse to fields | none |
| epoch (`os.time`) | numeric | needs `os.date` (TZ-dependent) | `+86400` is DST-fragile | **bad** |

**Recommend the normalized table `{year,month,day}` (nil = undated).** It is
DST-safe, directly comparable, formats to the required ISO column via
`date_to_iso`, and is the form Horizon's day math wants
(`os.time({year=y,month=m,day=d})` then field-add — *not* `+days*86400`, which
util.lua:214 currently does and is fragile). Alternative (ISO string) is
attractive (it *is* the display form) but forces re-parsing for any arithmetic;
I'd accept it only if Horizon/Format owners prefer strings. Flag to coordinate
with those owners. `due_time`/`duration` stay `""`-default strings; `markers`
keep **raw** date strings (unnormalized, format-preserved per §3d.4).

## 5. Decisions to flag

- **[DECISION-D]** `due_date` = `{year,month,day}` table (above). Needs
  Horizon/Format sign-off.
- **[DECISION-S]** Add `strict` (default `false`) to `config.lua` defaults; wire
  `ctx.date_errors` collector + a surfacing path (notify? `:checkhealth`?) for
  collected `DateError`s. Go surfaces them via `cmdList` (main.go:176-179);
  pick a Lua sink — **recommend** `vim.notify(WARN)` once per refresh.
- **[DECISION-E1]** alias/path junk as lazy `.-` vs faithful
  `[^|%]]-` + path. `.-` passes all pinned tests; the bounded class is closer to
  Go but adds two more optional segments. **Recommend `.-`**, note the
  divergence risk (pathological multi-`]]` lines) as low.
- **[DECISION-E2]** optional time via two concrete patterns vs one decomposed
  "match core then probe trailing `^%s*(TIME)`". **Recommend two patterns**
  (simpler, fewer position-capture games); decomposition is the fallback if a
  wrapper layout resists.
- **[DECISION-U]** Delete util.lua's `resolve_date_config`/
  `parse_date_components` and re-point `shift_date_in_string`/
  `set_date_today_in_string` at `strftime.lua`. Also fix their DST-fragile
  `t + days*86400` (util.lua:214) to field arithmetic. **Recommend yes**
  (removes the second, weaker converter).
- Duration format stays hardcoded `<(%d+)m>` (Go ignores configured
  `formats.duration`, parse.go:52). Flag only if configurability is wanted.

## 6. Edge cases → pinning tests

| # | case | Go test | Lua handling |
|---|---|---|---|
| 1 | wikilink alias `[[id\|DATE]]` | `TestParseTask_AliasDate`, `_CustomDateFormat_WikilinkAlias` | lazy `.-` strips alias |
| 2 | path prefix `[[daily/DATE]]` | `TestParseTask_PathPrefixDate`, `_MarkerWithPathPrefixDate` | lazy `.-` strips path |
| 3 | prefix `::` in body | `TestAdversarial_MarkerPrefixInBodyText`, `_MarkerPrefixSingleColon` | body boundary = `marker_start_pat` (prefix+kw+`[[`), not bare prefix |
| 4 | indented / tab-led line | `TestParseTask_Indented` | left-trim `" \t"` |
| 5 | unknown / no checkbox | `TestParseTasks_SkipsUnparseable`, `TestDateValidation_StrictDoesNotSuppressCheckboxErrors` | no literal-prefix match → error (even in strict; no DateError) |
| 6 | empty date `(@[[]])` | `TestParseTask_EmptyDate` | `date_pat_*` don't match → undated, no error, body keeps `(@[[]])` |
| 7 | invalid date values | `TestAdversarial_InvalidDateValues`, `TestDateValidation_InlineDates_*` | `validate_date`; strict→collect, non-strict→error |
| 8 | dup checkbox names | `TestAdversarial_DuplicateCheckboxDeterministic` | `status_map` alpha-first (parse.go:79-87) |
| 9 | alternation shadow `- ` vs `- [ ]` | `TestAdversarial_AlternationShortPrefixShadowsLong` | longest-first literal list |
| 10 | empty / whitespace / newline checkbox | `TestAdversarial_EmptyCheckbox`, `_WhitespaceOnlyCheckbox`, `_NewlineInCheckbox` | filter `vim.trim(cb)==""` at build; literal compare never matches `\n` on one line |
| 11 | multiple tags, hyphen, no-space marker | `TestParseTask_WithTags`, `_NoSpaceMarkers`, `_UndatedWithTags` | `gmatch` whole line, `[%a_][%w_-]*` |
| 12 | markers with/without time, no-space `::` | `TestParseTask_WithMarkers`, `_StartStop`, `_FullComplex` | two marker patterns; split on prefix |
| 13 | multiple date groups | `TestAdversarial_MultipleDateGroups` | leftmost `string.find` |
| 14 | custom formats US/dot/compact/12h | `TestParseTask_CustomDateFormat_*` | `strftime.compile` runs |
| 15 | config fallbacks (`#`/`::`, partial wrapper) | `TestAdversarial_ConfigFallbacks` | default guards in `new_parse_context` |
| 16 | prefix collisions (`::`==tag, `[`==tag) | `TestAdversarial_TagPrefix*` | Lua patterns reproduce the documented leak |
| 17 | marker custom-wrapper ignored | `TestAdversarial_MarkerDateIgnoresCustomWrapper` | marker patterns hardcode `[[ ]]` |
| 18 | strict multi-surface error count | `TestDateValidation_MultipleErrorsCollected` | shared `date_errors` list; inline+marker here, frontmatter via Frontmatter owner |
| 19 | DateError formatting (no `:0:`) | `TestDateValidation_ErrorMessages` | `format_date_error` omits line when nil |
| 20 | nil collector safe | `TestDateValidation_NilCollectorSafe` | `collect_date_error` no-ops on nil |

## 7. Test strategy (busted/plenary parity)

- Port `parse_test.go`, `parse_adversarial_test.go`, `date_validation_test.go`
  (inline + marker sections) and the *behavioral* `timeformat_test.go` rows
  (`_Matches`, `_12hTimeSpaceHandling`) 1:1 as plenary specs asserting on the
  `Task` table fields. Frontmatter/ScanProjects date rows port under the
  Frontmatter owner reusing `strftime.validate_date`.
- `strftime.compile(fmt).run` anchored `^…$` reused for the regex-match rows;
  drop the Go-layout (`StrftimeToGo`) assertions.
- **Golden harness:** keep the Go binary buildable during transition; run both
  on a fixture corpus and diff the `Task` projections (a small Lua script that
  prints `file:line:body|due|time|dur|tags|status|markers` and a Go `-dump`
  mode), gating parity before deleting `go/`.

## 8. Latency

Per line: 1 left-trim, ≤N literal prefix compares (N = #checkbox, ~3), 1-2
`string.find` (date), 1 `string.find` (duration), 1 `string.find`
(marker-start) + a split + per-segment match, 1 `gmatch` pass (tags), 2 `gsub`
(body). All native LuaJIT C string ops over short lines. Estimate **<2 ms for
~2 000 task lines**, dwarfed by rg + file IO + frontmatter (CONTEXT §6.1/§6.3);
parse is *not* the bottleneck. Mitigations: (1) build all patterns + the sorted
checkbox list + `strftime.compile` results **once** per refresh in
`new_parse_context`, never per line; (2) avoid per-line table churn — reuse the
`ctx`, only allocate the `Task`/`tags`/`markers` tables actually returned;
(3) reject `vim.regex` (per-line C boundary + no captures → re-tokenize).
Chunking onto `vim.schedule` is unnecessary at these sizes and is the
Integration owner's call for pathological 10k+ vaults; the parser stays
synchronous.

## 9. Open questions / risks

- **Lazy `.-` vs Go's bounded alias/path** ([DECISION-E1]): a single line with
  multiple `]]` and a malformed first date could diverge from RE2 backtracking.
  Low risk; covered by adding adversarial fixtures, not yet pinned by a Go test.
- **`strict` surfacing**: Go prints `DateError`s through `cmdList`; the Lua sink
  (notify vs healthcheck vs quickfix) is unspecified upstream — needs a call.
- **`config.strict` plumbing**: depends on config schema add (DECISION-S) and
  whether `buffer.lua` passes a per-refresh `date_errors` collector.
- **util.lua unification timing**: re-pointing shift/set at `strftime.lua`
  (DECISION-U) touches existing keymap behavior; sequence after parse.lua lands
  and its tests are green to avoid regressing date-shift.
