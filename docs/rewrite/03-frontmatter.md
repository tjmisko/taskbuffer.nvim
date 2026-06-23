# 03 — Frontmatter Subsystem (Go → Lua)

Blueprint for porting `go/frontmatter.go` (+ the `ScanProjects` FM
dependency in `go/scan.go:160-249`) to pure Lua. **Plan only** — pseudocode and
signatures, no implementations.

---

## 1. Scope

I own the YAML-frontmatter read path and the three FM pipeline operations.

Go source ported:
- `go/frontmatter.go` in full: `Frontmatter` struct, `GetString`,
  `GetStringSlice`, the `frontmatterCache` + `ParseFrontmatter` /
  `ParseFrontmatterTags` / `ResetFrontmatterCache`, `parseFrontmatterFromFile`,
  `MergeFrontmatterTags`, `MergeFrontmatterDue`, `FilterCompletedFrontmatterTasks`.
- The `*Resolved()` config accessors in `go/main.go:42-77`
  (`DueKeyResolved`, `InheritDueResolved`, `RequireTagsResolved`,
  `StatusKeyResolved`, `DoneValuesResolved`).
- The FM-reading half of `ScanProjects` (`go/scan.go:185-246`): the
  `ParseFrontmatter` call, `fm.Tags` "project" check, `fm.GetString(dueKey)`,
  `fm.GetString(statusKey)` + done-set test. **I provide the read interface;
  Scan blueprint owns rg invocation, glob expansion, body derivation, Task
  construction.**

Out of scope (consumed, not owned): the `Task` table shape (Parse blueprint),
the date-string→date-value parser + strict validation (Parse/Horizon
blueprint), rg invocation and glob/symlink dedup (Scan blueprint).

I must also **reconcile** the existing write-side FM helpers in
`lua/taskbuffer/util.lua` — `find_frontmatter_due_line` (289-319),
`shift_frontmatter_due` (329-369), `set_frontmatter_due_today` (378-405) —
with the new read parser (see §5.D).

---

## 2. Proposed Lua module(s)

### New file: `lua/taskbuffer/frontmatter.lua`

This is the only new module. It owns the cache, the mini-parser, the key
accessors, and the three pipeline ops.

#### Data shapes

```lua
---@class Frontmatter
---@field raw   table<string, string|string[]>  -- top-level keys; scalar→string, list→string[]
---@field tags  string[]                          -- raw["tags"] iff it parsed as a list, else {}
---@field lines table<string, integer>|nil        -- key → 1-based source line (for write-side reuse, §5.D)

---@class FmCfg                 -- resolved view of config.values.frontmatter
---@field due_key string
---@field status_key string
---@field done_values string[]
---@field inherit_due boolean
---@field require_tags string[]

---@class DateError             -- mirrors go/main.go:80-93 (subset I emit)
---@field filepath string
---@field date_str string
---@field context string        -- always "frontmatter due" here (parity w/ frontmatter.go:243)
---@field err string
```

**[DECISION D1] Keep a generic `raw` map (recommended) vs. only `{tags,due,status}`.**
Go stores the whole YAML map (`Frontmatter.Raw`, frontmatter.go:18) and resolves
keys lazily through `GetString`/`GetStringSlice`. I recommend mirroring that with
a `raw` table of *top-level* keys only, because: (a) it makes the cache
key-name-agnostic — `due_key`/`status_key` are configurable
(`TestParseFrontmatter_CustomDueKey`, `TestFMDue_CustomStatusKeyAndDoneValues`),
and a `raw` map lets one cached parse serve any key without baking the config
into the cache key; (b) `get_string`/`get_string_slice` then map 1:1 onto the Go
methods. Cost is negligible — frontmatter blocks are tiny. The parser only needs
to recognize two value *kinds* (scalar string, list), so "generic" here is cheap.

#### Public functions

```lua
-- Cache / lifecycle (parity: frontmatter.go:81-120)
function M.read(path)            -> Frontmatter|nil   -- cached; nil == no/empty/unusable FM
function M.reset()                                    -- clear whole cache (== ResetFrontmatterCache)
function M.invalidate(path)                           -- drop one entry (after a write, §5.D)

-- Key accessors (parity: GetString frontmatter.go:24-49, GetStringSlice :52-72)
function M.get_string(fm, key)        -> string       -- "" when absent / non-scalar
function M.get_string_slice(fm, key)  -> string[]     -- {} when absent / non-list
function M.tags(path)                 -> string[]     -- == ParseFrontmatterTags (frontmatter.go:104)

-- Resolved-config helpers (parity: main.go:42-77; adapts the NESTED Lua shape)
function M.resolve_cfg(raw_fm_cfg)    -> FmCfg

-- Pipeline ops (called in this order — see §4)
function M.merge_frontmatter_tags(tasks)                              -- in place
function M.filter_completed(tasks, fmcfg)            -> Task[]         -- returns new list
function M.merge_frontmatter_due(tasks, fmcfg, dateparse, date_errors)-- in place; may append DateError

-- Sugar for Scan's project pass (§6 interface)
function M.file_fields(path, fmcfg)   -> { tags=string[], due=string, status=string } | nil
```

`dateparse` (4th arg of `merge_frontmatter_due`) is the
**Parse/Horizon-owned** `string -> date_value|nil, err` function (replaces Go's
`time.Parse(goDateFmt, …)` at frontmatter.go:238). I do not implement date
parsing; I call it and translate failures into `DateError`.

#### Where it slots in

- `buffer.lua` refresh path: after rg→parse produces `tasks`, call the three ops
  (replacing the Go `list` shell-out described in CONTEXT §2). `reset()` is
  called once at the **start** of each refresh (see §3).
- `scan.lua` (Scan blueprint's new module) `scan_projects` calls
  `frontmatter.read` / `file_fields` (shared cache — §3, §6).
- `util.lua` write helpers call `frontmatter.invalidate(path)` after mutating a
  file and reuse the shared scalar-line helper (§5.D).

---

## 3. The cache

Go uses a package global `fmCache` (a `map[string]*Frontmatter` + mutex,
frontmatter.go:74-79). Lua is single-threaded → **plain module-level table, no
lock**:

```lua
local cache = {}   -- path -> Frontmatter (or false to memoize "no FM here")
```

**Why the cache is load-bearing (not just an optimization).** Within one
refresh, the same file is parsed by up to four passes — `MergeFrontmatterTags`
(per task, frontmatter.go:177-178), `FilterCompletedFrontmatterTasks` (per
*unique* file, it has its own `checkedFiles` dedup at :275/286),
`MergeFrontmatterDue` (per task, :207), and `ScanProjects` (:185). Only
`FilterCompleted` dedups locally; the other passes call `ParseFrontmatter`
**once per task** and rely entirely on the global cache. A file with N undated
tasks would otherwise be opened/parsed ~2N+ times. The cache turns that into one
open per unique file.

**[DECISION D2] Cache lifetime = one refresh; clear at refresh start
(recommended).**
Rationale:
- It *exactly* reproduces Go's semantics. The Go binary is a fresh process per
  `list` invocation, so its cache is born and dies inside one refresh. Files
  edited between refreshes are always re-read — which is the correct behavior
  for a long-lived nvim session (user shifts a due date, then `:Tasks`).
- It satisfies the within-invocation-staleness contract
  (`TestParseFrontmatterTags_Cached`, frontmatter_test.go:70-87): the file is
  overwritten *mid-invocation* and the cached (stale) value must still be
  returned. Clear-at-start, never mid-pipeline → identical.
- The `ResetFrontmatterCache()` that every Go test calls maps to `M.reset()`; I
  call it from the refresh entry point in `buffer.lua` and expose it for busted.

Reset hook: `buffer.refresh_taskfile` / `refresh_taskfile_async` call
`frontmatter.reset()` *before* invoking the pipeline. ScanProjects runs in the
same refresh and shares the live cache — do **not** reset between the task pass
and the project pass (Go doesn't; main.go:187-191 share `fmCache`).

Alternative considered — **mtime-keyed invalidation** (`vim.uv.fs_stat().mtime`,
keep entries across refreshes for unchanged files): rejected for v1. It adds a
`stat` syscall per file (partly defeating the savings), diverges from Go's
per-process semantics, and buys nothing — rg already re-scans every file each
refresh, so there is no cross-refresh reuse to capture. Revisit only if profiling
shows FM reads dominate and most files are unchanged.

`invalidate(path)` exists for the write helpers (§5.D) as belt-and-suspenders;
with clear-per-refresh it is technically redundant but cheap and makes the
write→read ordering robust if a future caller refreshes without a full reset.

---

## 4. Pipeline order (must not change)

Per `cmdList` (main.go:186-195) and pinned by
`TestFMDue_FilterBeforeInherit` (fm_due_e2e_test.go:630-660) and the
`fullPipeline` helper (:17-28):

```
tasks = parse(matches)
frontmatter.reset()                                  -- §3
frontmatter.merge_frontmatter_tags(tasks)            -- 1
tasks = frontmatter.filter_completed(tasks, fmcfg)   -- 2  (BEFORE inherit)
frontmatter.merge_frontmatter_due(tasks, fmcfg, …)   -- 3
project_tasks = scan.scan_projects(fmcfg, …)         -- shares cache
all = tasks ++ project_tasks
```

**Why 2 before 3 (critical):** `FilterCompleted` only drops tasks whose
`DueDate == nil` (frontmatter.go:279). If inheritance (3) ran first, every
undated task in a done file would acquire the file's due date and the filter
would keep all of them. `TestFMDue_FilterBeforeInherit` demonstrates exactly
this (runs the wrong order, asserts more tasks survive).

---

## 5. Algorithm / port notes

### A. The mini-parser (`read` / `parseFrontmatterFromFile`)

Go reads line-by-line, requires a leading `---`, collects body lines until the
next `---`, then hands the body to `yaml.Unmarshal` (frontmatter.go:122-172).
We replace `yaml.Unmarshal` with a **targeted top-level line scanner**. We do
**not** add a YAML dep (CONTEXT §6.3).

```
function read(path):
  if cache[path] ~= nil: return cache[path] or nil   -- false memoizes "none"
  fm = parse_head(path)
  cache[path] = fm or false
  return fm

function parse_head(path):                            -- reads ONLY the head
  f = io.open(path, "r"); if not f: return nil        -- (Go returns err; we treat as no-FM)
  first = f:read("*l")
  if trim(first) ~= "---": f:close(); return nil      -- no frontmatter (frontmatter.go:132-134)
  raw, tags, lines = {}, {}, {}
  ln = 1
  pending_list_key = nil
  while true:
    line = f:read("*l"); ln = ln + 1
    if line == nil: break                             -- EOF before closing --- → treat as body collected
    if trim(line) == "---": break                     -- closing delimiter
    -- (a) block-list continuation:  "  - item"
    item = line:match("^%s+%-%s+(.*)$")
    if pending_list_key and item ~= nil:
        push raw[pending_list_key], unquote(item)
        continue
    pending_list_key = nil
    -- (b) "key: value"  (top-level only: zero indentation, key has no leading space)
    key, val = line:match("^(%S[^:]*):%s?(.*)$")
    if key == nil: continue                            -- comment / blank / non-kv → ignore (lenient)
    lines[key] = ln
    val = strip_trailing_comment_if_unquoted(val)      -- see §5.C note on comments
    if val == "" :
        -- could be a block list ("tags:\n  - a") → arm pending list
        raw[key] = {}; pending_list_key = key
    elseif val:match("^%[.*%]$"):
        raw[key] = parse_flow_list(val)                -- inline [a, b, c]
    else:
        raw[key] = unquote(val)                        -- scalar string
  f:close()
  if next(raw) == nil: return nil                      -- empty FM (frontmatter.go:148-150)
  -- tags: ONLY when value is a list (Go: []interface{} only; string tags ignored)
  if type(raw["tags"]) == "table": tags = raw["tags"]
  return { raw = raw, tags = tags, lines = lines }
```

Helpers:
- `unquote(s)`: strip one matching pair of `"…"` or `'…'`; reuse the logic in
  `util.find_frontmatter_due_line` (util.lua:309-313). (Factor into a shared
  helper, §5.D.)
- `parse_flow_list("[a, b, c]")`: strip brackets, split on `,`, trim+unquote
  each. Empty `[]` → `{}` (pins `TestParseFrontmatterTags_EmptyTags`,
  frontmatter_test.go:40-53). If no closing `]` (the broken
  `tags: [valid, yaml` in `frontmatter-edge-vault/malformed.md`), the
  `^%[.*%]$` guard fails → falls through to scalar `unquote` → a *string* value
  → `tags` stays `{}` (no list). Matches Go's "malformed → no tags" outcome
  (`TestFM_MalformedYAML`, integration_test.go:415-427; the broken file yields
  no merged tags and must not crash).

`get_string(fm, key)` (parity GetString, frontmatter.go:24-49):
```
v = fm.raw[key]
return type(v)=="string" and v or ""     -- non-scalar/list/absent → ""
```
Go additionally formats `int`/`float64`/`time.Time`. We never produce those
types (we read raw text) — see §5.B for why that is *output-identical* on the
fixtures and §7/D-list for the residual risk.

`get_string_slice(fm, key)` (parity GetStringSlice, :52-72):
```
v = fm.raw[key]
return type(v)=="table" and v or {}
```

### B. The GetString / YAML-timestamp parity argument (THE central risk)

Go's `GetString` has a `time.Time` branch (frontmatter.go:39-45) because
`yaml.v3` auto-resolves *unquoted* date-like scalars to `time.Time`, then
reformats: `"2006-01-02"` if the time is midnight, else `"2006-01-02 15:04"`.
Our line parser reads the **raw text**, sidestepping this entirely. I verified
text-vs-Go equivalence against every fixture:

| Fixture (key) | On disk | yaml.v3 type → GetString | Lua raw read | Match |
|---|---|---|---|---|
| `bare-date.md` `due` | `2026-04-15` (bare) | time.Time → `2026-04-15` | `2026-04-15` | ✓ |
| `project-sort.md` `due` | `2026-04-15` (bare) | time.Time → `2026-04-15` | `2026-04-15` | ✓ |
| `basic-inherit.md` `due` | `"2026-04-15"` (quoted) | string → `2026-04-15` | `2026-04-15` | ✓ |
| `due-with-time.md` `due` | `"2026-04-15 14:30"` (quoted) | string → `2026-04-15 14:30` | `2026-04-15 14:30` | ✓ |
| `active-status.md` `due` | `"2026-04-10"` | string → as-is | as-is | ✓ |
| all `status`/`state`/`tags` | strings/lists | unchanged | unchanged | ✓ |

Key facts that make this safe **on the fixtures**:
1. Every time-bearing due is **quoted** (`due-with-time.md`,
   `TestMergeFrontmatterDue_WithTime` frontmatter_test.go:233) → yaml.v3 keeps it
   a plain string → no reformat → identical to raw read.
2. Every bare date is a plain `YYYY-MM-DD` at midnight → yaml.v3's reformat is a
   no-op (`Format("2006-01-02")` returns the same digits) → identical.
3. yaml.v3 would only *change* the text for (a) bare datetimes **with seconds**
   (`2026-04-15 14:30:00` parses via `2006-1-2 15:4:5.999…` → reformats to
   `2026-04-15 14:30`, dropping seconds), (b) `T`/`Z` RFC3339 forms, or (c)
   bare non-zero-padded `2026-4-1` (yaml.v3 accepts via `2006-1-2`, reformats to
   `2026-04-01`). **None occur in any fixture.** Bare `2026-04-15 14:30` (no
   seconds) does *not* match any `allowedTimestampFormats` entry → yaml.v3
   leaves it a string → still identical to raw.

→ **The line parser is output-identical to the Go YAML path for 100% of
fixtures.** The residual divergence is confined to the three out-of-fixture
forms above; see §7 risk list for the recommended `normalize_bare_date` guard.

### C. Trailing comments / indentation

- yaml.v3 strips `# comment` after an unquoted scalar; it does **not** strip
  inside quotes. No fixture uses an inline comment after a value, so this is not
  exercised. Recommend a conservative `strip_trailing_comment_if_unquoted`: only
  strip ` #…` when the value is unquoted (mirrors YAML; avoids corrupting a `#`
  inside a quoted string). Mark low-priority (no test pins it).
- Indentation: only top-level (zero-indent) keys matter for `due`/`status`/
  `tags`. Block-list items are indented (`  - foo`) and are matched by the
  `^%s+%-%s+` continuation rule. All fixtures use 2-space block lists
  (`basic-inherit.md`, etc.).

### D. Reconciling with the existing write-side helpers (`util.lua`)

`find_frontmatter_due_line` (util.lua:289-319) already does a head-scan with the
same shape (require `---`, stop at `---`, match `key:%s*(.*)`, strip quotes). To
avoid two parsers drifting:
- **Factor a shared scalar-line helper** `unquote(value) -> value, is_quoted`
  used by both `read` and `find_frontmatter_due_line`.
- The write helpers (`shift_frontmatter_due` :329, `set_frontmatter_due_today`
  :378) keep needing the **line number** and the original quoting to rewrite in
  place; the new parser already records `fm.lines[key]` and could record
  quoting. **[DECISION D3]** Either (i) have the write helpers call
  `frontmatter.read(path)` and use `fm.lines[due_key]` (one parse, reused), or
  (ii) leave `find_frontmatter_due_line` standalone but built on the shared
  unquote helper. Recommend (ii) for v1 (smaller blast radius; write path is not
  latency-critical, runs on a single keypress), with `fm.lines` kept available
  for a later merge.
- After any write, call `frontmatter.invalidate(path)` so a same-refresh re-read
  is fresh (redundant under clear-per-refresh, but correct-by-construction).

### E. `merge_frontmatter_tags` (frontmatter.go:176-193)

```
for task in tasks:
  fm = read(task.filepath); if not fm or #fm.tags==0: continue
  existing = set(task.tags)
  for t in fm.tags: if not existing[t]: append task.tags, t; existing[t]=true
```
Union + dedup, FM tags appended after inline tags, order preserved
(`TestMergeFrontmatterTags_MergesAndDeduplicates` frontmatter_test.go:89-113:
result is `{sspi, inline, project}` — inline first, FM `project` appended, FM
`sspi` deduped).

### F. `filter_completed` (frontmatter.go:258-304)

```
dv = lower-set(fmcfg.done_values)         -- build once; lowercased (frontmatter.go:267-270)
completed, checked = {}, {}
out = {}
for task in tasks:
  if task.due_date ~= nil: push out, task; continue        -- inline-dated always kept (:279)
  if not checked[task.filepath]:
     checked[task.filepath] = true
     fm = read(task.filepath)
     if fm:
        due    = get_string(fm, fmcfg.due_key)
        status = lower(get_string(fm, fmcfg.status_key))
        if due ~= "" and dv[status]: completed[task.filepath] = true   -- BOTH required (:292)
  if completed[task.filepath]: continue                    -- drop undated from done file
  push out, task
return out
```
Pins:
- BOTH due+done required: `TestFMDue_DoneStatusButNoDue` (no due → keep),
  `TestFMDue_FileWithDueButNoDoneStatus` (no status → keep) (e2e:921-948).
- Case-insensitive: `status: DONE` → `lower` → match
  (`TestFMDue_CaseInsensitiveDoneValues` e2e:950-961;
  `TestFMDue_CompleteStatusAlsoFilters` for default `complete`).
- Custom done values lowercased too
  (`TestFilterCompletedFrontmatterTasks_CustomDoneValues` fm_test:307-329).
- The `if #done_values==0 return tasks` guard (frontmatter.go:263) is effectively
  dead because `resolve_cfg` always supplies defaults `{done,complete}`
  (main.go:71-77). Keep the resolved (non-empty) set; mirror the guard for safety.

### G. `merge_frontmatter_due` (frontmatter.go:195-253)

```
if not fmcfg.inherit_due: return                          -- (:198) InheritDueResolved
for task in tasks:
  if task.due_date ~= nil: continue                       -- inline wins (:203)
  fm = read(task.filepath); if not fm: continue
  due = get_string(fm, fmcfg.due_key); if due=="": continue
  if #fmcfg.require_tags > 0:                              -- ALL must be in FM tags (:218-234)
     fmset = set(fm.tags)
     for rt in fmcfg.require_tags: if not fmset[rt]: goto next_task
  date_part, time_part = split_first_space(due)           -- SplitN(due," ",2) (:237)
  val, err = dateparse(date_part)
  if err: collect DateError{filepath, date_part, "frontmatter due", err}; continue   -- (:240-246)
  task.due_date = val
  if time_part: task.due_time = trim(time_part)           -- (:249-251)
```
Pins: inherit (`TestFMDue_BasicInheritance`), inline-wins
(`TestFMDue_InlineAlwaysWins`), `inherit_due=false`
(`TestFMDue_InheritDueDisabled`), custom key
(`TestFMDue_CustomDueKey`/`...DefaultIgnoresStandardDue`), require_tags
all-match (`TestFMDue_RequireTags*`, `...PartialMatchFails`, `EmptyRequireTagsAllowsAll`),
time inheritance (`TestFMDue_InheritsTimeFromFM` → date `2026-04-15`, time
`14:30`). **require_tags reads `fm.tags` (the file's FM tags), not the task's
merged tags** — independent of step 1.

### H. `resolve_cfg` (main.go:42-77) — adapts the **nested** Lua config shape

Go's `FrontmatterConfig` is flat; the live Lua config nests status
(`config.lua:108-117` / `config.lua:264-271`): `{due_key, inherit_due,
require_tags, status={key, done_values}}`. Resolution:
```
due_key     = c.due_key or "due"
status_key  = (c.status and c.status.key) or "status"
done_values = (c.status and c.status.done_values) or {"done","complete"}
inherit_due = (c.inherit_due ~= false)            -- default true; *bool semantics (:51-56)
require_tags= c.require_tags or {}
```
There is no JSON boundary anymore (CONTEXT §4) — read `config.values.frontmatter`
directly; `config_json_arg` / the flat `due_key/status_key/done_values`
marshalling in config.lua:264-271 becomes dead and can be deleted by Integration.

---

## 6. Interface for `ScanProjects` (Scan blueprint depends on this)

Scan's project pass (scan.go:160-249) needs only FM reads. I expose:

```lua
-- Low level (cached, shares §3 cache with the task pipeline):
frontmatter.read(path) -> Frontmatter|nil          -- fm.tags, fm.raw
frontmatter.get_string(fm, key) -> string

-- Or the convenience the project pass will likely use:
frontmatter.file_fields(path, fmcfg)
  -> { tags = string[], due = string, status = string } | nil
```

Scan's `scan_projects` then does (everything below is Scan-owned glue):
```
for path in rg_list("- project", md_glob, sources):     -- scan.go:166-183
  ff = frontmatter.file_fields(path, fmcfg)
  if not ff: continue
  if not contains(ff.tags, "project"): continue          -- scan.go:191-196 (hard-coded "project")
  if ff.due == "": continue                               -- (:202)
  if done_set(fmcfg.done_values)[lower(ff.status)]: continue  -- (:206-216)
  date, err = dateparse(split_first_space(ff.due))        -- (:220-233) context "frontmatter project due"
  ... build SortLast Task, body = basename(path) w/o .md  -- (:235-246), Scan-owned
```
Contract pinned by `TestFMDue_ScanProjectsCustom{DoneValues,DueKey,StatusKey}`
(e2e:809-892) and `TestVault_ProjectScanning` (vault_test:283-304),
`TestFMDue_SortLastFieldSetOnProjectTasks` (e2e:1044-1061). Note the `"project"`
tag literal is **hard-coded** in Go (scan.go:192), independent of `require_tags`.

**Shared cache (yes).** ScanProjects runs in the same refresh after the task
pipeline (main.go:191) and its candidate files frequently overlap task files;
the single module cache means those files are parsed once total. Do not give
Scan its own cache.

---

## 7. Latency analysis

**What's hot:** N file opens on the main UI thread per refresh, one per unique
task-bearing file (∪ project candidate files). For the target vault
(CONTEXT §1: hundreds of files, hundreds–low-thousands of task lines) → ~hundreds
of opens. This is the FM subsystem's entire cost; parsing a ~10–30-line head is
trivial next to the syscalls.

**Quantify:** ~300 unique files × one `open`+head-read. With the cache, the
2N+ re-parse blow-up (§3) collapses to N opens. Head-reading (break at closing
`---`, typically <30 lines) avoids slurping large note bodies. Budget: a few ms
of `open()` on a warm FS; comfortably inside the <50ms refresh target
(CONTEXT §1), and it overlaps nothing else heavy in the FM stage.

**Mitigations (apply all):**
1. **Cache** (§3) — the single biggest win; turns 2N+ parses into N. Mandatory.
2. **Head-only read** — stop at the closing `---`; never read note bodies.
3. **Only touch files with tasks/projects** — the passes iterate `tasks` and the
   rg `-l "- project"` list, so FM-less, task-less files are never opened.
4. **One read, all keys** — a single `read(path)` populates `raw` (tags+due+
   status together); the three passes hit the cache, not the disk.

**[DECISION D4] IO primitive: `io.open` + line read, explicit `close`
(recommended).** Comparison:
- `io.lines(path)` (current util.lua style): pure LuaJIT, but on early `break`
  the handle isn't closed until GC (no handle exposed in 5.1/LuaJIT) → fd churn
  across hundreds of files. Avoid for the head-read.
- **`io.open` + `f:read("*l")` loop + `f:close()`**: pure LuaJIT, no VimL
  boundary, reads only the head, deterministic close. Simplest fast option.
  Recommended.
- `vim.fn.readfile(path, '', N)`: C-fast but (a) crosses the Lua↔VimL boundary
  per call (×hundreds), (b) needs a guessed line cap `N` — pick too small and a
  large frontmatter is truncated; too large and we read body. A 2-stage
  (`readfile(path,'',64)`, fall back on miss) works but is more code for no win
  over `io.open`.
- `vim.uv.fs_open/fs_read/fs_close` (libuv): fastest raw bytes, but we'd hand-
  split newlines and manage partial reads (read a 4KB chunk; re-read if no
  closing `---`). Only worth it if profiling shows `io.open` is the bottleneck.
  Keep as the documented escape hatch.

**Future optimization (flag, don't build):** batch the head-reads through rg in
the Scan pass (rg already runs once) so FM regions arrive with the scan output —
removes the N main-thread opens entirely. Cross-blueprint; owned with Scan.
For v1, per-file `io.open` is sufficient.

---

## 8. Decisions to flag

- **[D1]** Keep a generic `raw` top-level map (vs. only `{tags,due,status}`).
  *Recommend generic* — mirrors Go `Raw`+`GetString`, keeps the cache config-key
  agnostic, costs ~nothing for tiny FM blocks.
- **[D2]** Cache lifetime = **one refresh, cleared at start**. *Recommend* —
  reproduces Go's per-process semantics exactly, satisfies
  `TestParseFrontmatterTags_Cached`, avoids stale reads after edits. Alternative
  (mtime-keyed cross-refresh cache) rejected: adds a `stat`/file, no real reuse
  (rg re-scans anyway).
- **[D3]** Reconcile write helpers: *recommend* keeping
  `find_frontmatter_due_line` standalone but on a **shared `unquote` helper**
  with `read`; expose `fm.lines[key]` for a later merge. Write path isn't
  latency-critical.
- **[D4]** IO primitive: *recommend* `io.open`+head-read+explicit close;
  `vim.uv` as escape hatch.
- **[D5] Bare-date normalization (parity gap).** yaml.v3 reformats bare
  `2026-4-1`→`2026-04-01` and bare `…14:30:00`→`…14:30`; our raw read does not.
  *Recommend* a small `normalize_bare_date` applied only to **unquoted** scalars
  matching `^%d+-%d+-%d+`: zero-pad Y-M-D (and, if a `HH:MM:SS` tail, drop
  seconds) to match Go. No fixture needs it, but it closes the only real
  divergence cheaply. Alternative: document-and-accept (downstream `dateparse`
  would just fail-to-inherit on a non-padded date rather than misbehave).
- **[D6] Lenient line-parse vs. atomic YAML fail.** Go's `yaml.Unmarshal`
  rejects a malformed block **wholesale** (returns nil — frontmatter.go:154-156),
  discarding even valid keys; our key-by-key scanner would still extract a valid
  `due` from a file with one broken line. The only malformed fixture
  (`malformed.md`) has no `due`, so no fixture diverges — but flag that a
  malformed-block-with-valid-due file behaves differently (Lua = more lenient).
  *Recommend* document-and-accept (lenient is arguably better and the case is
  pathological); add a cheap guard only if the maintainer wants strict parity.

---

## 9. Edge cases → pinning tests

| Edge case | Behavior | Pinned by |
|---|---|---|
| No frontmatter | `read`→nil; no tags/due | `TestParseFrontmatterTags_NoFrontmatter` (fm_test:25), `TestFM_NoFrontmatter` (integration:445), `TestFMDue_NoFrontmatterAtAll` (e2e:175) |
| Empty FM (`---`/`---`) | `read`→nil (raw empty) | `TestFM_EmptyFrontmatter` (integration:429) |
| `tags: []` | tags `{}` | `TestParseFrontmatterTags_EmptyTags` (fm_test:40) |
| No `tags:` key | tags `{}` | `TestParseFrontmatterTags_NoTagsField` (fm_test:55) |
| tags as scalar string | tags `{}` (string ignored, not a 1-list) | `TestFM_TagsAsString` (integration:460), `tags-as-string.md` |
| Malformed YAML | no crash, no tags; broken `[a, b` → not a list | `TestFM_MalformedYAML` (integration:415), `malformed.md` |
| Block-list tags | parsed | `TestParseFrontmatterTags_WithTags` (fm_test:10) |
| Inline-flow tags `[a,b]` | parsed (no fixture, but Go via yaml) | (covered by parser; flow path) |
| Within-invocation cache staleness | stale value returned | `TestParseFrontmatterTags_Cached` (fm_test:70) |
| tag union + dedup, order | inline first, FM appended | `TestMergeFrontmatterTags...` (fm_test:89), `TestVault_FrontmatterTagMerge` |
| Custom due_key | reads `deadline`, ignores `due` | `TestParseFrontmatter_CustomDueKey` (fm_test:115), `TestFMDue_CustomDueKey*` |
| Custom status_key/state | `state` resolution | `TestParseFrontmatter_CustomStatusKey` (fm_test:133), `TestFMDue_CustomStatusKey*` |
| Bare YAML date | inherited as `2026-04-15` | `TestFMDue_BareYAMLDate` (e2e:395), `bare-date.md` |
| Quoted date+time | date+`DueTime` | `TestMergeFrontmatterDue_WithTime` (fm_test:229), `TestFMDue_InheritsTimeFromFM` (e2e:364) |
| Inline wins over FM due | inline kept | `TestMergeFrontmatterDue_InlineWins`, `TestFMDue_InlineAlwaysWins` |
| `inherit_due=false` | no inheritance, filter still runs | `TestMergeFrontmatterDue_InheritDueFalse`, `TestFMDue_InheritFalsePlusCompletionFiltering` (e2e:539) |
| require_tags all-match | all required ∈ FM tags | `TestFMDue_RequireTags*` (e2e:298-358) |
| Completion needs due AND done | both required | `TestFMDue_DoneStatusButNoDue` / `...FileWithDueButNoDoneStatus` (e2e:921-948) |
| Case-insensitive done | `DONE`→match | `TestFMDue_CaseInsensitiveDoneValues` (e2e:950) |
| Filter BEFORE inherit | undated-from-done dropped | `TestFMDue_FilterBeforeInherit` (e2e:630) |
| Inline-dated in done file survives | kept | `TestFilterCompleted...KeepsInlineDated`, `TestFMDue_DoneMixedFileSurvivors` |
| Empty vault | 0 tasks | `TestFMDue_EmptyVault` (e2e:898) |
| Project scan (custom cfg) | shared FM read | `TestFMDue_ScanProjects*` (e2e:809), `TestVault_ProjectScanning` |
| Bad FM due date (strict) | DateError, skip | `MergeFrontmatterDue` :240; (strict path via Parse blueprint) |

---

## 10. Test strategy

- **Port the unit tests** in `frontmatter_test.go` to busted/plenary against
  `frontmatter.lua`: write the same temp `.md` files, assert `read`/`tags`/
  `get_string`/`merge_*`/`filter_*` results. Direct 1:1 mappings exist for all
  16 functions there.
- **Port the e2e contract** (`fm_due_e2e_test.go`, the 1096-line main contract)
  by reusing the **existing testdata vaults** (`go/testdata/fm-due-vault`,
  `frontmatter-vault`, `frontmatter-edge-vault`) verbatim — copy/reference them
  from the Lua test tree. Reimplement the `fullPipeline` helper (e2e:17-28) in
  Lua: parse→merge_tags→filter→merge_due, then assert per-task `due_date`/
  `due_time`/survival exactly as the Go tests do. These vaults are the golden
  inputs; keep them as the shared fixture source so Go and Lua are tested against
  identical bytes.
- **Parity harness (recommended):** a small golden test that, for each fixture
  file, asserts `frontmatter.get_string(read(f), key)` equals the value the Go
  `GetString` produced — guards the §5.B timestamp argument and any future
  fixture that adds a bare/quoted/time form. Seed it from the §5.B table.
- **Cache test:** replicate `TestParseFrontmatterTags_Cached` — read, overwrite
  file, read again within one "refresh" (no `reset()`), expect stale; then
  `reset()` and expect fresh.
- **No-crash tests:** `malformed.md`, `empty-frontmatter.md`, missing file →
  `read` returns nil, pipeline ops are no-ops, no error thrown
  (`TestFM_MalformedYAML`/`EmptyFrontmatter`).

---

## 11. Open questions / risks

1. **[D5/D6] residual YAML divergences** — bare non-padded dates, bare
   datetime-with-seconds, `T`/`Z` RFC3339 forms, and malformed-block-with-valid-
   due. Zero fixtures exercise them; recommendation is the cheap
   `normalize_bare_date` guard (D5) + document-and-accept for D6. Needs
   maintainer sign-off on whether strict atomic-fail parity matters.
2. **`dateparse` contract** (Parse/Horizon blueprint) — I depend on a
   `string -> date_value|nil, err` that (a) accepts the configured `date_format`,
   (b) is strict enough to reject `2026-13-45` (CONTEXT §6.6), and (c) returns a
   `date_value` whose representation Format/Horizon agree on. The DueDate type is
   theirs; I only set the field. Confirm the signature.
3. **Inline-comment / multi-doc / anchors** — unsupported by the mini-parser by
   design; no fixture uses them. If real vaults do, revisit (low risk for
   Obsidian-style notes).
4. **Write/read consolidation (D3)** — if a future change wants a single FM
   parser for both read and in-place edit, `fm.lines[key]` is the hook; deferred
   to keep the rewrite blast radius small.
5. **rg-batched FM heads** — the real latency endgame (§7) is cross-blueprint;
   confirm with Scan whether to fold FM-head extraction into the single rg pass.
