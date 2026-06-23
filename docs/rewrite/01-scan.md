# 01 — Scan Layer Blueprint (Go `scan.go` → pure Lua)

> Owner: the **Scan** sub-blueprint. Reads `docs/rewrite/CONTEXT.md` §6.1 (rg
> output parsing) as the assigned hot-spot. Cites Go `file:line` and test names.
> Plan only — signatures + pseudocode, no full implementations.

---

## 1. Scope

Ports everything in `go/scan.go` (250 lines):

- `Scan(ctx, notesPaths...) → []RawMatch` — `scan.go:88-156`. The `rg --json`
  invocation that produces the raw matched task lines.
- `ScanProjects(goDateFmt, fmCfg, dateErrors, notesPaths...) → []Task` —
  `scan.go:158-250`. `rg -l -e "- project" --glob *.md` + per-file frontmatter
  check → synthetic `SortLast` project tasks.
- `expandGlobs(paths) → []string` — `scan.go:69-84`. Glob expansion of source
  args.
- `deduplicatePaths(paths) → []string` — `scan.go:37-67`. Symlink-resolve, sort
  by length, drop nested-prefix paths.
- `RawMatch` struct — `scan.go:16-20`.
- `const defaultScanPattern = `\- \[.\]`` — `scan.go:22`.

Also owns the rg argv contract, the **grep fallback**, the sync/async execution
model, and exit-code handling (`scan.go:141-153`).

**Out of scope** (consumed, not owned):
- Building the config-driven `scanPattern` from checkbox config lives logically
  next to the regex context (`parse.go:107-118`). This blueprint *specifies the
  algorithm* and proposes it live in `scan.build_pattern` (rationale in §5,
  Decision D1) so the rg concern stays local, but the Parse blueprint may call
  it instead. Either way the contract is: `ctx.scan_pattern` is a single rg
  pattern string.
- Frontmatter parsing (`ParseFrontmatter`, `Frontmatter.GetString`,
  `Frontmatter.Tags`) is owned by the Frontmatter blueprint. `scan_projects`
  depends on it; the required interface is defined in §5, Decision D7.
- Strict date validation for the project due date is owned by Parse/Horizon.
  The needed callback interface is defined in §5, Decision D7.

---

## 2. Proposed Lua module

**File:** `lua/taskbuffer/scan.lua` (new).

Slots into the pipeline as the first stage. The Integration blueprint's refresh
path becomes: `scan.scan(ctx, paths)` → `parse.parse_tasks(matches, ctx)` →
frontmatter merge → format. `buffer.lua:build_cmd`/`refresh_taskfile*`
(`buffer.lua:68-137`) stop shelling out to `task_bin list` and call this module
instead.

### 2.1 Data shapes

```lua
---@class RawMatch
---@field path string         absolute file path (rg/grep print abs because we pass abs source paths)
---@field line_number integer 1-based
---@field text string         the matched line, WITHOUT trailing newline

---@class ScanContext            -- subset of the Lua ParseContext (Parse blueprint owns full ctx)
---@field scan_pattern string|nil  rg pattern; nil/"" → defaultScanPattern (`\- \[.\]`)

---@class ProjectScanContext
---@field date_format string       strftime, e.g. "%Y-%m-%d" (for the due-date parse)
---@field frontmatter table        config.values.frontmatter (due_key/status/inherit/etc.)
---@field parse_date fun(s:string):table|nil  strict date parser (Parse blueprint); nil = invalid
---@field date_errors table|nil    collector array; entries pushed for strict mode (mirrors *[]DateError)
```

`Task` is the shared shape owned by the Parse blueprint (`parse.go:11-22`);
`scan_projects` produces a subset of it (see §3.4).

### 2.2 Public functions

```lua
local scan = {}

scan.DEFAULT_PATTERN = [[\- \[.\]]]   -- mirrors scan.go:22

---@param checkbox table<string,string>|nil  status_name → checkbox literal
---@return string  rg alternation pattern (or DEFAULT_PATTERN when checkbox empty)
function scan.build_pattern(checkbox) end

---@param paths string[]
---@return string[]  glob-expanded + symlink-deduped (mirrors expandGlobs→deduplicatePaths)
function scan.expand_globs(paths) end

---@param paths string[]
---@return string[]
function scan.dedup_paths(paths) end

--- Synchronous scan. Mirrors Scan() (scan.go:88-156).
---@param ctx ScanContext|nil
---@param paths string[]
---@return RawMatch[] matches, string|nil err
function scan.scan(ctx, paths) end

--- Async scan. rg/grep runs off-loop; cb is invoked via vim.schedule.
---@param ctx ScanContext|nil
---@param paths string[]
---@param cb fun(matches:RawMatch[], err:string|nil)
function scan.scan_async(ctx, paths, cb) end

--- Mirrors ScanProjects() (scan.go:158-250).
---@param pctx ProjectScanContext
---@param paths string[]
---@return Task[] tasks, string|nil err
function scan.scan_projects(pctx, paths) end
```

Internal helpers: `scan._argv(pattern, paths)`, `scan._argv_grep(...)`,
`scan._parse_output(stdout) → RawMatch[]`, `scan._classify_exit(code, stderr)`,
`scan._have_rg()` (cached `vim.fn.executable("rg") == 1`).

---

## 3. Algorithm / port notes

### 3.1 `expand_globs` (`scan.go:69-84`)

```
result = {}
for p in paths:
    if p:find("[*?]") then                      -- EXACTLY Go's ContainsAny(p,"*?")
        for m in vim.fn.glob(p, true, true) do  -- nosuf=true, list=true
            result[#result+1] = m
        end                                      -- empty list on no-match (Go: Glob → nil)
    else
        result[#result+1] = p                    -- plain path passes through verbatim
    end
return scan.dedup_paths(result)
```

Parity-critical details:
- **Detect globs by `*`/`?` only** — Go uses `strings.ContainsAny(p,"*?")`
  (`scan.go:74`); it does **not** treat `[` as a glob trigger. A source like
  `~/Notes/[a].md` must pass through literally. Replicate with `p:find("[*?]")`.
- **No-match glob yields nothing** (Go: `filepath.Glob` returns empty slice).
  Pins `TestGlob_NoMatch` (`integration_test.go:508`) and the empty-paths early
  return in §3.3.
- **Nonexistent plain path passes through** so it can reach rg and trigger the
  exit-2 error (`TestPath_NonExistentPath`, `integration_test.go:260`).

### 3.2 `dedup_paths` (`scan.go:37-67`)

```
resolved = {}
for p in paths:
    r = vim.uv.fs_realpath(p) or p     -- EvalSymlinks fail → keep original (scan.go:43-44)
    resolved[#resolved+1] = r
table.sort(resolved, function(a,b) return #a < #b end)   -- length ascending (scan.go:49-51)
kept = {}
for p in resolved:
    nested = false
    for k in kept:
        if p == k or p:sub(1, #k+1) == k.."/" then nested = true; break end  -- scan.go:57
    if not nested then kept[#kept+1] = p
return kept
```

- `vim.uv.fs_realpath` is the analogue of `filepath.EvalSymlinks`: both resolve
  symlinks AND canonicalize (`..`, trailing `/`), and both **fail on
  nonexistent paths** → original kept. Parity holds for `TestPath_NonExistentPath`.
- The `k.."/"` guard is load-bearing: prevents `/a/b` from absorbing `/a/bcd`.
  Replicate the exact `HasPrefix(p, k+"/") || p==k` (`scan.go:57`).
- Sort is by length only; `table.sort` instability vs Go `sort.Slice` is
  harmless (equal-length paths can't be strict prefixes unless equal; exact
  dups dedup via `p==k`).

### 3.3 `scan` (`scan.go:88-156`)

```
paths = scan.expand_globs(paths)
if #paths == 0 then return {}, nil end          -- scan.go:90-92 (no rg invocation)

pattern = (ctx and ctx.scan_pattern ~= "" and ctx.scan_pattern) or scan.DEFAULT_PATTERN
argv = scan._argv(pattern, paths)               -- rg, or grep fallback (§4)
res  = vim.system(argv, { text = true }):wait()
return scan._classify_exit(res.code, res.stderr, res.stdout)
```

`_classify_exit` mirrors `scan.go:141-153` exactly (see §6 exit table):
```
if code == 0 then return scan._parse_output(stdout), nil
if code == 1 then return {}, nil                      -- no matches (scan.go:145-147)
if code == 2 and (stderr == nil or stderr == "") then
    return {}, nil                                    -- no searchable files (scan.go:148-150)
return nil, "rg exited with error: " .. (stderr or "")  -- scan.go:152
```

`_parse_output` (the hot loop — see §6.1 for format choice):
```
matches = {}
for record in stdout:gmatch("[^\n]+") do            -- split on \n; records are \0-delimited internally
    local nul = record:find("\0", 1, true)
    if nul then
        local path = record:sub(1, nul - 1)
        local rest = record:sub(nul + 1)
        local lineno, text = rest:match("^(%d+):(.*)$")
        if lineno then
            matches[#matches+1] = { path = path, line_number = tonumber(lineno), text = text }
        end
    end
return matches
```

### 3.4 `scan_projects` (`scan.go:158-250`)

```
paths = scan.expand_globs(paths)
if #paths == 0 then return {}, nil end                 -- scan.go:162-164

argv = have_rg
       and { "rg", "-l", "-e", "- project", "--glob", "*.md", unpack(paths) }   -- scan.go:166
       or  { "grep", "-rlEI", "--include=*.md", "-e", "- project", unpack(paths) }
res = vim.system(argv, { text = true }):wait()
if res.code == 1 then return {}, nil end               -- no matches (scan.go:172-174)
if res.code ~= 0 then return nil, "rg project scan: "..(res.stderr or "") end  -- scan.go:175

tasks = {}
for file in res.stdout:gmatch("[^\n]+") do
    file = trim(file); if file == "" then goto continue end   -- scan.go:180-183
    fm = pctx.frontmatter_mod.parse(file)                     -- Frontmatter dep (D7)
    if not fm then goto continue end                          -- scan.go:185-187

    if not list_contains(fm.tags, "project") then goto continue end   -- scan.go:190-196
    due_key, status_key, done_vals = resolve(pctx.frontmatter)        -- scan.go:197-199
    fm_due = fm:get_string(due_key)
    if fm_due == "" then goto continue end                           -- scan.go:201-203

    fm_status = fm:get_string(status_key):lower()
    if set_contains(lower_each(done_vals), fm_status) then goto continue end  -- scan.go:206-216

    date_part, time_part = split_first_space(fm_due)                 -- SplitN(fmDue," ",2) scan.go:220
    dt = pctx.parse_date(date_part)                                  -- strict parse (scan.go:221)
    if not dt then
        push_date_error(pctx.date_errors, {file=file, date=date_part,
                        context="frontmatter project due"})          -- scan.go:222-230
        goto continue
    end
    tasks[#tasks+1] = {
        file_path = file, line_number = 1,
        body = basename_no_md(file),                                -- TrimSuffix(Base(file),".md") scan.go:235
        due_date = dt, due_time = trim(time_part or ""),
        tags = fm.tags, status = "open", sort_last = true,          -- scan.go:237-246
    }
    ::continue::
return tasks, nil
```

Note: `ScanProjects` does **not** special-case exit code 2 (unlike `Scan`);
only code 1 → empty, everything else non-zero → error (`scan.go:170-176`).
Replicate that asymmetry.

### 3.5 `build_pattern` (mirrors `parse.go:107-118`)

```
function scan.build_pattern(checkbox)
    if not checkbox or next(checkbox) == nil then return scan.DEFAULT_PATTERN end
    local seen, parts = {}, {}
    for _, cb in pairs(checkbox) do
        cb = vim.trim(cb)
        if cb ~= "" then                                  -- skip empty/whitespace (parse.go:67-71)
            local esc = rg_quote_meta(cb)
            if not seen[esc] then seen[esc] = true; parts[#parts+1] = esc end
        end
    end
    if #parts == 0 then return scan.DEFAULT_PATTERN end
    sort_by_length_desc(parts)                            -- longest first (parse.go:117 / parse.go:170)
    return table.concat(parts, "|")
end
```

`rg_quote_meta` must escape **exactly Go's `regexp.QuoteMeta` set**:
``\.+*?()|[]{}^$`` plus backslash. So `"- [ ]"` → `- \[ \]` (space and `-` are
**not** escaped — verified: Go escapes none of space/`-`). Defaults thus build
`- \[ \]|- \[-\]|- \[x\]` (sorted: space < `-` < `x`), matching only the three
configured checkboxes — narrower than `defaultScanPattern`'s `\- \[.\]`, which
is why `Scan(nil, …)` (tests in `scan_test.go`) and `DefaultParseContext()`
(`vault_test.go`) can diverge for stray checkboxes like `- [w]`. `sort_by_length_desc`
ties break alphabetically ascending (`parse.go:170-176`) to keep longer literals
ahead of shorter prefixes in the alternation.

---

## 4. ripgrep argv + grep fallback

### 4.1 rg argv (recommended plain `--null` format — see §6.1)

```
{ "rg", "--no-config", "--color=never", "--no-heading", "-n", "--null",
  "-e", pattern, <path1>, <path2>, ... }
```

- `--null` (`-0`): terminates each printed path with a NUL. Output record =
  `<path>\0<lineno>:<text>` (empirically verified, ripgrep 14.1.1). NUL delimits
  the path, so arbitrary `:`/unicode in `text` and even `:` in `path` parse
  unambiguously.
- `-n`/`--no-heading`/`--color=never`: pin a deterministic, machine-parseable
  layout regardless of TTY detection.
- `--no-config`: **deliberate, safe divergence** from Go (which used neither
  `--json`-fixed output nor this flag). Because we now depend on a *plain*
  layout, a user's `RIPGREP_CONFIG_PATH` injecting `--heading`/`--color` would
  corrupt parsing. With `--json` the Go binary was naturally immune; `--no-config`
  restores that immunity for the plain format. (See Decision D2.)
- Source paths are passed as separate argv elements (no shell) — spaces / `(` /
  unicode in paths need no quoting. Pins `TestPath_SpacesInPath`
  (`integration_test.go:198`).
- Default-rg semantics preserved (NOT overridden, for parity with the Go call
  `scan.go:99-101`): respects `.gitignore`, skips hidden files, skips binary,
  does **not** follow symlinks. The symlink-skip is why `TestPath_ParentScansAll`
  (`integration_test.go:293`) asserts `>= 5` (the `linked` symlink dir is not
  traversed) and why dedup, not rg, handles `TestPath_SymlinkDedup`.

### 4.2 grep fallback (`rg` absent)

`scan._have_rg()` = cached `vim.fn.executable("rg") == 1`. When false, build:

```
{ "grep", "-rnEIZ", "--include=*.md", "-e", pattern, <path1>, ... }
```

Empirically verified (`grep -rnZ`) the output is **byte-identical in shape** to
rg's: `<path>\0<lineno>:<text>\n` — so `scan._parse_output` is shared verbatim.

Flag mapping:
- `-Z`/`--null` → same NUL-after-path as rg `--null`.
- `-n` → line numbers (the `lineno:` field).
- `-r` (lowercase) → recursive **without** following symlinks (matches rg default;
  `-R` would follow — do not use).
- `-E` → ERE, required because the multi-checkbox pattern uses `|` alternation.
  The escaped literals (`\[`, `\]`, `\(`, …) and the default `\- \[.\]` are valid
  ERE. `rg_quote_meta`'s escape set is ERE-compatible for every char it escapes.
- `-I` → skip binary files (rg does this by default).
- `--include=*.md` → restrict to markdown.

Exit codes are identical to rg (0/1/2, verified), so `_classify_exit` is shared.

**rg-only features lost under grep (degradations to document):**
1. **No `.gitignore` awareness** — grep searches files rg would ignore. Partially
   mitigated by `--include=*.md`, but rg also scans `.markdown`/`.txt`/etc. while
   grep is now md-only. Net: slightly different file set.
2. **No hidden-file skip** — `grep -r` descends `.obsidian/` etc.; rg skips them.
3. **No smart unicode/encoding handling** — grep is bytes-oriented; non-UTF-8
   files may behave differently (acceptable for a fallback).
4. **Slower** on large vaults (no parallel walk, no gitignore pruning).
5. `scan_projects` fallback uses `grep -rlEI --include=*.md` for the `-l` form.

The fallback is best-effort parity; the Go test suite assumes `rg`, so grep
parity is validated only by the unit tests we add (§7), not the ported vault
tests.

### 4.3 Async vs sync execution

Mirror the existing two-mode shape in `buffer.lua` (`refresh_taskfile` sync at
`:112`, `refresh_taskfile_async` at `:122-137`).

- **`scan.scan` (sync):** `vim.system(argv,{text=true}):wait()`. Used by the
  blocking refresh path and by all ported tests (deterministic).
- **`scan.scan_async`:** `vim.system(argv,{text=true}, function(res) … end)` —
  rg runs off the UI loop; in the callback re-enter the loop via `vim.schedule`
  and hand `_parse_output(res.stdout)` to `cb`. This keeps the *I/O* (the rg
  process) async exactly as today.

**Buffered, not streaming (recommended — Decision D3):** pass a completion
callback and consume the whole `res.stdout` at once. Rationale: the parse is
~sub-millisecond per thousand records (§6.1), so streaming's only benefit
(overlapping parse with rg I/O) is negligible and it introduces NUL/record
reassembly across chunk boundaries (`vim.system`'s `stdout` chunk handler can
split mid-record). Streaming is noted as an optional future optimization if
parse ever moves on-loop and dominates (it won't here — the on-loop cost is
Parse/Format, owned by Integration).

**Important latency caveat for Integration:** rg async only hides the *rg* time.
`_parse_output` + downstream `parse.parse_tasks` + format all run on the UI loop
inside the callback. Scan's own contribution to that is the cheap `_parse_output`;
the dominant on-loop cost is Parse (CONTEXT §6.2/§6.4), not Scan.

---

## 5. Decisions to flag

**[DECISION D1] Where `build_pattern` lives.** *Recommend:* put it in
`scan.lua` (`scan.build_pattern`) and have the Parse module/`config` call it to
populate `ctx.scan_pattern`. *Rationale:* the pattern is an rg-output concern
(escaping must match what rg/grep accept). *Alternative:* fold it into
`parse.lua`'s context builder next to `statusRe` (mirrors `parse.go:107-118`
locality). Low stakes — pick one and keep `ctx.scan_pattern` as the interface.

**[DECISION D2] rg output format: plain `--null` vs `--json`.** *Recommend
plain `--null -n --no-heading --color=never --no-config`.* *Rationale:* (a)
~10× cheaper to parse in Lua (no per-line `vim.json.decode`, no nested-table
allocation, no `submatches` array, no per-file `begin`/`end` messages to skip);
(b) NUL-delimited path makes `:`/unicode in content irrelevant — verified
robust. *Cost:* output layout is now sensitive to injected rg flags → mitigated
by `--no-config`. *Alternative (`--json` + `vim.json.decode`):* maximally
robust against any rg config and self-describing, but allocation-heavy and the
hot path we're told to optimize (CONTEXT §6.1). Keep `--json` documented as a
debug/diagnostic path only.

**[DECISION D3] Buffered vs streaming collection.** *Recommend buffered* (whole
`res.stdout` in the completion callback). Rationale in §4.3. *Alternative:*
`vim.system` per-chunk `stdout` handler with a carry buffer for partial records
— more code, no measurable win at our scale.

**[DECISION D4] `--no-config` divergence from Go.** Adding `--no-config` is a
behavior change vs the current Go binary. *Recommend keeping it* for the plain
format's parse stability; the only behavior it changes is ignoring a user's
`RIPGREP_CONFIG_PATH`, which we *want* ignored. Flagging because it's a
conscious break from strict byte-parity with the Go invocation.

**[DECISION D5] Partial-failure handling (exit 2 with non-empty stderr while
matches exist).** Go discards *all* matches and returns an error if rg exits 2
with any stderr (`scan.go:148-152`), even on a single permission-denied file.
*Recommend replicating Go exactly* for parity (a single unreadable file aborts
the scan). *Alternative:* add `--no-messages` so per-file errors don't flip the
exit code / populate stderr, making scans resilient — but that diverges from Go
and could mask real problems. Leave as maintainer's call.

**[DECISION D6] `vim.fn.glob` vs `filepath.Glob` divergences.** Two known
mismatches, both low-risk for real source configs: (a) Go `*` matches dotfiles
at the globbed component; `vim.fn.glob('*')` does **not** return dotfiles by
default. (b) Go `filepath.Glob` has no `**`; `vim.fn.glob` treats `**` as
recursive descent. *Recommend* using `vim.fn.glob(p, true, true)` and
documenting these; none of the glob-vault fixtures
(`glob-vault/notes-*`, `notes-?`, `*`) use dotfiles or `**`, so
`TestGlob_StarWildcard`/`QuestionMark`/`MatchAll` (`integration_test.go:478-506`)
still pass. Revisit only if a user reports a dotfile/`**` source.

**[DECISION D7] Cross-module interface required from Frontmatter + Parse.**
`scan.scan_projects` needs:
```lua
-- from the Frontmatter blueprint:
frontmatter.parse(path) -> fm | nil
--   fm.tags : string[]                         (from the `tags:` YAML key; [] if none)
--   fm:get_string(key) -> string               ("" if absent; YAML dates normalized
--                                                to "YYYY-MM-DD" or "YYYY-MM-DD HH:MM",
--                                                mirroring Frontmatter.GetString, frontmatter.go:24-49)
--   returns nil for: no frontmatter, malformed YAML (silently skipped)

-- from the Parse/Horizon blueprint (strict date validation, CONTEXT §6.6):
pctx.parse_date(date_str) -> table | nil        -- nil ⇒ invalid (rejects 2026-13-45)

-- config (read directly from config.values.frontmatter, no JSON boundary):
--   due_key (default "due"), status.key (default "status"),
--   status.done_values (default {"done","complete"})  — resolution mirrors
--   FrontmatterConfig.*Resolved() (main.go:42-77)
```
`date_errors` is a plain Lua array used as the `*[]DateError` collector; push
`{file_path=…, date_str=…, context="frontmatter project due", line_number=0}`.

---

## 6. Edge cases → Go tests

### 6.1 Exit-code matrix (verified empirically, ripgrep 14.1.1) — `scan.go:141-153`

| Situation | code | stderr | Scan result | Pinned by |
|---|---|---|---|---|
| matches found | 0 | "" | parsed `RawMatch[]` | `TestScan_FindsTasksInTempDir` (`scan_test.go:9`) |
| empty directory | 1 | "" | `{}` (no error) | `TestScan_EmptyDir` (`scan_test.go:69`), `TestPath_EmptyDirectory` (`integration_test.go:227`) |
| md file, no task lines | 1 | "" | `{}` (no error) | `TestScan_NoMatchesInFile` (`scan_test.go:80`), `TestPath_NoTasksInMarkdown` (`integration_test.go:237`) |
| glob matched no files → empty paths | (no rg run) | — | `{}` | `TestGlob_NoMatch` (`integration_test.go:508`) |
| no searchable files / exit-2-empty-stderr | 2 | "" | `{}` (no error) | defensive, `scan.go:148-150` |
| nonexistent path | 2 | non-empty | **error** | `TestPath_NonExistentPath` (`integration_test.go:260`) |

### 6.2 Multi-source / paths

- Two dirs → union of matches: `TestScan_MultipleDirs` (`scan_multi_test.go:9`),
  `TestVault_MultiSource` (`vault_test.go:187`).
- Single source isolation: `TestVault_SingleSourceOnly` (`vault_test.go:217`).
- Spaces in path: `TestPath_SpacesInPath` (`integration_test.go:198`) — argv
  array, no quoting.
- Deeply nested found via recursive walk: `TestPath_DeeplyNested`
  (`integration_test.go:211`), `TestVault_BasicScanAndParse` (`vault_test.go:67`).
- Absolute, ≥1 line numbers, non-empty text invariants:
  `TestScan_FindsTasksInTempDir` loop (`scan_test.go:56-66`). (Paths are absolute
  because we pass absolute, glob-expanded, realpath-resolved source paths.)

### 6.3 Dedup / symlinks (`scan.go:37-67`)

- Nested → parent only: `TestDeduplicatePaths_Nested` (`scan_multi_test.go:54`),
  `TestPath_OverlappingNested` (`integration_test.go:269`).
- Disjoint preserved: `TestDeduplicatePaths_Disjoint` (`scan_multi_test.go:68`),
  `TestPath_ParentScansAll` (`integration_test.go:293`, `>= 5`).
- Symlink resolves to same real path → 1: `TestPath_SymlinkDedup`
  (`integration_test.go:247`).
- Exact duplicate path → deduped to one source, still 2 tasks:
  `TestPath_ExactDuplicates` (`integration_test.go:282`).

### 6.4 Globs (`scan.go:69-84`)

- `*` / `?` / `*` (match-all): `TestScan_GlobExpansion` (`scan_multi_test.go:78`),
  `TestGlob_StarWildcard`/`QuestionMark`/`MatchAll` (`integration_test.go:478-506`).
- No-match glob → `{}`: `TestGlob_NoMatch` (`integration_test.go:508`).

### 6.5 Content robustness (the parser must survive these)

- Indented tasks (leading `\t`/spaces) still matched: `TestEdge_IndentedTasks`
  (`integration_test.go:120`), `daily.md` line in `scan_test.go:30-31`.
- Tasks inside code blocks / blockquotes are matched by rg (filtering is Parse's
  job, not Scan's): `TestEdge_CodeBlockTasksMatched` (`integration_test.go:177`),
  `TestEdge_BlockquoteNotMatched` (`integration_test.go:136`).
- Arbitrary `:` and unicode in the line (the NUL-format motivation): covered by
  fixtures bodies and asserted indirectly via `m.Text` substring checks in
  `TestScan_MultipleDirs` (`scan_multi_test.go:24-38`). Add a direct scan unit
  test (§7) for `body: with: colons café 12:30`.

### 6.6 Project scan (`scan.go:158-250`)

- Finds a `tags:[project]` + `due:` file → 1 synthetic task, body = filename,
  due parsed, `SortLast`: `TestVault_ProjectScanning` (`vault_test.go:283`),
  `fm_due_e2e_test.go:806-1051`.
- Invalid project due, strict → 0 tasks + 1 DateError ctx "frontmatter project
  due": `TestDateValidation_ScanProjects_Strict` (`date_validation_test.go:345`).
- Invalid project due, non-strict → silently 0 tasks:
  `TestDateValidation_ScanProjects_NonStrict` (`date_validation_test.go:371`).
- `done`-status / custom `DoneValues` / `DueKey` / `StatusKey` filtering:
  `fm_due_e2e_test.go:818-899`.

---

## 7. Test strategy (parity)

- **Port the Go scan/dedup/glob unit tests to busted/plenary** against real temp
  dirs (these are pure rg behavior, fast, deterministic):
  `scan_test.go` (3), `scan_multi_test.go` (4), and the path/glob subset of
  `integration_test.go` (`TestPath_*`, `TestGlob_*`). Assert on `RawMatch[]`
  length + fields, and on `dedup_paths`/`expand_globs` outputs directly.
- **Golden round-trip:** because Scan feeds Parse→Format and CONTEXT §3 fixes a
  byte-exact taskfile, keep a golden-file check at the *pipeline* level (owned by
  Integration) over the `testdata/*-vault` fixtures; Scan parity is implied when
  the golden matches. Scan-only tests guard the RawMatch contract.
- **rg vs grep equivalence test:** run `scan.scan` once forcing rg and once
  forcing the grep path (`scan._have_rg` stubbed false) over the same fixture and
  assert identical `RawMatch[]` (modulo the documented gitignore/hidden
  divergences — use a fixture without ignored/hidden files). This is the only
  coverage for the fallback (Go suite never exercises grep).
- **Exit-code unit tests:** empty dir, no-match file, nonexistent path — assert
  the §6.1 matrix (`{}` vs error). Reuse `TestScan_EmptyDir`/`NoMatchesInFile`/
  `TestPath_NonExistentPath` as the spec.
- **Unicode/`:` direct test:** new test with a body containing `: café 12:30`
  to lock the NUL-split parser (no Go analogue; protects D2).
- Reuse `vault_test.go`'s `scanAndParse` helper shape as the Lua pipeline harness
  so ported tests read 1:1.

---

## 8. Open questions / risks

1. **`vim.uv.fs_realpath` on broken symlinks / permission errors.** Returns nil →
   we keep the original (matches Go EvalSymlinks-error path). But if a symlink
   resolves on Go but not under libuv (or vice-versa) on some platform, dedup
   could differ. Low risk on Linux; verify on the dev box.
2. **`--no-config` (D4) is a real behavior break.** If any downstream relies on a
   user's RIPGREP_CONFIG_PATH, this silently changes results. Needs maintainer
   sign-off.
3. **Partial-failure abort (D5).** Replicating Go means one unreadable file kills
   the whole `:Tasks` refresh. On large real vaults with the occasional
   permission-denied, this could be surprising; `--no-messages` would fix it but
   diverges.
4. **grep fallback fidelity.** gitignore/hidden-file divergences mean a vault
   that depends on rg's `.gitignore` pruning (e.g. a `node_modules` of stray
   `.md`) will over-match under grep. Documented, not fixed.
5. **`vim.system` availability.** Requires Neovim ≥ 0.10. If older versions must
   be supported, fall back to `vim.fn.jobstart`/`io.popen` (io.popen loses async
   + exit-code fidelity). Confirm minimum Neovim version with Integration.
6. **NUL handling in `:wait()` text mode.** `vim.system(..., {text=true})`
   returns stdout as a Lua string that *contains* embedded `\0` bytes (Lua
   strings are 8-bit clean) — verified the `record:find("\0")` approach works;
   just don't pass through any API that treats strings as C-NUL-terminated.
