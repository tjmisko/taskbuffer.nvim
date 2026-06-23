# Master Blueprint — Removing Go from taskbuffer.nvim (pure-Lua rewrite)

Status: **design complete, ready for maintainer review.** No code written yet.
This is the top-level synthesis. Detail lives in the sibling docs:

| Doc | Scope |
|---|---|
| `CONTEXT.md` | Shared spec: output contract, config schema, call sites, latency hot-spots |
| `01-scan.md` | rg/grep invocation, output parsing, project scan, glob/dedup |
| `02-parse.md` | task-line parser, strftime conversion, strict date validation |
| `03-frontmatter.md` | targeted YAML-subset parser, cache, merge/filter/inherit |
| `04-horizon-format.md` | horizon resolution, bucketing, byte-exact taskfile output |
| `05-mutate-state-commands.md` | file mutations, current_task state, action verbs |
| `06-integration-testing-migration.md` | module wiring, threading, test harness, rollout |

## 1. Verdict

The rewrite is **feasible and worthwhile.** The Go binary is an unconventional
build dependency for a Neovim plugin, and ~40% of its surface (date shifting,
frontmatter-due manipulation, line IO, state writes, the start-marker) is
*already* reimplemented in Lua inside `util.lua`/`keymaps.lua` — so we are
finishing a partial migration, not starting cold.

**Latency conclusion (the central worry):** Lua can hit the target (well under
~50ms for a realistic vault) for everything *except possibly* the first,
cold-cache `:Tasks` of a session, where N frontmatter file reads dominate. rg
stays the heavy lifter for search (unchanged), parse+format is ~12–30ms warm,
and removing the per-action process spawn is a *net latency win* for the verbs.
The single thing that could miss budget is cold frontmatter file I/O — its
mitigations (head-only reads, one open per file, a single per-refresh cache,
and the rg-driven FM-head extraction endgame) are mandatory, not optional. See
§4 and `06` §2.

There is **no free off-main-thread parse**: `vim.system`'s callback runs on the
UI loop, and a `luv` worker thread has no `vim.*` API. So the plan is rg-async +
parse-on-main-thread, with a chunked-coroutine fallback knob if any user reports
hitches. Accept this.

## 2. Final module tree

Keep: `init.lua`, `config.lua`, `buffer.lua`, `util.lua`, `keymaps.lua`,
`tags.lua`, `commands.lua`, `autocmds.lua`, `undo.lua`, `health.lua`.

Add (each ~1:1 with a Go file):
```
lua/taskbuffer/
  context.lua     -- replaces Go ParseContext + Config + the --config JSON boundary
  strftime.lua    -- strftime -> Lua pattern + strict date validate + DateError  (from timeformat.go)
  scan.lua        -- rg/grep invocation + RawMatch + glob/dedup + project paths   (from scan.go)
  parse.lua       -- task-line parser                                              (from parse.go)
  frontmatter.lua -- targeted FM parser + cache + merge/filter/inherit             (from frontmatter.go)
  horizon.lua     -- horizon specs -> resolved cutoffs                             (from horizon.go)
  format.lua      -- bucketing + byte-exact taskfile emit                          (from format.go)
  state.lua       -- current_task read/write/clear + canonical marker formatter    (from state.go)
  mutate.lua      -- file-line primitives                                          (from mutate.go)
  actions.lua     -- verb layer: complete_at/defer/irrelevant/unset/check/stop/start/current/create/do_pick (from main.go cmd*)
  list.lua        -- in-process list()/list_async()/tags(); replaces buffer.build_cmd + vim.system
```

Data flow for `list` (mirrors `main.go:cmdList`, lines 163–230):
```
scan.scan(ctx) -> parse.parse_tasks
  -> frontmatter.merge_tags
  -> frontmatter.filter_completed        (BEFORE inherit — order is load-bearing)
  -> frontmatter.merge_due
  -> scan.scan_projects (++ synthetic SortLast tasks)
  -> keep status=="open"
  -> horizon.resolve -> format.taskfile -> buffer
```

## 3. RESOLVED cross-module conflicts (binding decisions)

The sub-blueprints disagreed on two shared shapes. Resolved here; sub-docs
defer to this section.

### 3.1 `Task.due_date` — CANONICAL: local-noon epoch integer (nil = undated)
- `02-parse` proposed a `{year,month,day}` table; `04-horizon-format` proposed a
  local-**noon** epoch integer; `06` said epoch. **Winner: local-noon epoch
  integer**, because it is simultaneously (a) directly comparable with `<`/`==`
  for the sort and bucketing, (b) DST-safe (noon dodges every midnight
  transition), (c) formattable for display via `os.date(strftime, epoch)`
  honoring the configured output format, and (d) it collapses Go's awkward
  UTC-midnight-date vs local-midnight-cutoff split.
- **Parse still validates components first.** `parse` strictly validates `y/m/d`
  (range, days-in-month, leap) *before* converting, then emits
  `os.time{year=y,month=m,day=d,hour=12,min=0,sec=0}`. The `{y,m,d}` table is a
  transient inside `strftime.validate_date`, never the Task field.
- Horizon cutoffs use the **same** local-noon epoch representation and the same
  table-field arithmetic (`os.date("*t")` → mutate `.day` → `os.time`). No
  `+days*86400` anywhere (kills the existing DST bug in `util.lua:214/349`).
- **Markers keep verbatim date/time strings** (format-preserving), never epochs.
  `due_time` and `duration` stay `""`-default strings. Both Parse and Horizon
  already agree here.

### 3.2 Regex strategy — pure-Lua for parse; `vim.regex` allowed only in `remove_last_marker`
- `02-parse` chose a pure-Lua hybrid (literal checkbox prefixes longest-first;
  `string.find`/`gmatch` with decomposed sub-patterns; optional-time handled by
  trying a with-time then no-time pattern). This is the project-wide default and
  the right call (vim.regex gives only whole-match byte offsets — no captures).
- `05-mutate` wants `vim.regex` for "remove the **last** `::kind` marker". That
  is a find-offsets-of-last-match problem where vim.regex is acceptable, but to
  avoid shipping two regex philosophies, **prefer** the pure-Lua approach:
  iterate `string.find` from offset 1 collecting match spans, delete the last.
  vim.regex is the sanctioned fallback if the pure-Lua span-tracking proves
  fiddly with optional time. Either way, the date/time pattern fragments come
  from the single `strftime.lua` source — no second copy.

### 3.3 The strftime converter is singular
`strftime.lua` is the one place that turns `%Y-%m-%d`/`%H:%M` into Lua patterns
and validates. It **subsumes and deletes** `util.lua`'s weaker inline converter
(`resolve_date_config`/`parse_date_components`, which only knew `%Y/%m/%d/%F`).
All of: parser date/time extraction, `shift_date_in_string`,
`set_date_today_in_string`, frontmatter-due shifting, and `remove_last_marker`
consume it.

### 3.4 Frontmatter cache is shared and per-refresh
One module-level table keyed by path, populated once per file, **cleared at the
start of every refresh** (`list.lua` calls `frontmatter.reset()`). Shared
between the task-FM merge passes and the `scan_projects` pass. This is the single
biggest latency lever — it collapses the Go code's 2N+ re-parses
(`MergeFrontmatterTags`, `FilterCompletedFrontmatterTasks`, `MergeFrontmatterDue`,
project scan each re-read the same files) into one open per unique file.

## 4. Latency budget (consolidated)

| Stage | Cost (realistic vault) | Notes / mitigation |
|---|---|---|
| rg search | unchanged, async | `vim.system` async; NUL-delimited plain output (not `--json`) — ~10× cheaper to parse than `vim.json.decode` per line |
| parse (per line) | ~12–30ms warm, main thread | patterns compiled once per refresh; pure-Lua `string.find` is C-fast |
| frontmatter (cold) | **20–120ms, main thread** ← the risk | head-only reads, one open/file, per-refresh cache; endgame: have rg also emit FM heads to avoid N opens |
| horizon+format | <5ms | O(n log n) sort + `table.concat` (never `..` in a loop) |
| action verbs | **faster than today** | removes a process spawn (~3–15ms) + `/bin/sh` + (for `do`) a second fzf spawn |

If cold frontmatter ever misses budget, the fallback ladder is: (1) read FM
heads in the same rg pass; (2) chunk parsing across `vim.schedule` ticks; (3)
mtime-keyed cross-refresh cache. Do not add a luv worker (no `vim.*`).

## 5. Decision register — needs maintainer sign-off

| # | Decision | Recommendation | Where |
|---|---|---|---|
| D1 | Pipeline threading | rg async → parse/format **synchronously on main thread** in the callback; chunked-coroutine knob as fallback | 06 §2 |
| D2 | Output/buffer model | **Keep** the on-disk `<tmpdir>/<date>.taskfile` text round-trip (byte-exact). Defer in-memory side-table to a later PR | 06 §3, CONTEXT §3 |
| D3 | Test harness | **plenary `:PlenaryBustedDirectory`** + golden-file parity captured from the still-present Go binary over `go/testdata/` | 06 §6 |
| D4 | rg output format | plain **`rg --null -n --no-heading --color=never -e PAT paths`**; same parser for grep fallback | 01 |
| D5 | `--no-config` on rg | pass it (ignore user `RIPGREP_CONFIG_PATH` that could break parsing) — **behavior break, confirm** | 01 D4 |
| D6 | rg partial-failure | abort-on-error vs best-effort when one source path fails — **confirm** | 01 D5 |
| D7 | `cmdDo` picker | replace **fzf** shell-out with **`vim.ui.select`** (sheds the fzf dep; auto-uses telescope/fzf-lua if present) | 05 A |
| D8 | Canonical marker | one `state.format_marker` using the **configured** `marker_prefix` (Go hardcoded `::`); byte-identical for defaults, fixes Go's custom-prefix inconsistency | 05 C |
| D9 | File-write safety | make `mutate` **buffer-aware** (`nvim_buf_set_lines`+`:update` when file is loaded, else disk RMW) instead of blind disk-write + `:edit!` which discards unsaved edits | 05 B (**top risk**) |
| D10 | Trailing newline / CRLF | mirror Go's split/join newline preservation instead of `util.lua`'s force-append `\n`; keep `\r` for CRLF parity | 05 |
| D11 | Malformed-YAML leniency | line-parser is more lenient than yaml.v3's atomic-fail; no fixture diverges, but **confirm** the looser behavior is acceptable | 03 D6 |
| D12 | `create`/`do` exposure | currently `create` is unmapped and `do` only via state file; expose `:TasksCreate`/`:TasksDo` etc. — **confirm desired surface** | 05 |

## 6. Rewiring map (every binary call site → Lua)

| Today | Replacement |
|---|---|
| `buffer.build_cmd` + `vim.system(... list)` sync/async | `list.list()` / `list.list_async(cb)` (in-process pipeline) |
| `util.run_task_cmd({verb,file,line})` | direct `actions.<verb>(file, line)` |
| `tags.lua` `io.popen(task_bin ... tags)` | `list.tags()` (in-process; same dedup/sort) |
| `keymaps.start_task` `os.execute(task_bin.." stop")` | `state.stop()` / `actions.stop()` |
| `config.source_args` / `config.config_json_arg` | deleted; modules read `config.values` + `context.lua` |
| `config.task_bin` default + `expand` | deleted |
| `health.lua` Go-binary check | replaced by rg-present / grep-fallback check |
| `init.lua` `M.source_args`/`M.config_json_arg` aliases | deleted |

## 7. Removals / distribution

Delete `go/` entirely (source, `go.mod`, `go.sum`, `task_bin`, testdata moves to
`tests/fixtures/`), drop the go entry from `.gitignore`, and strip
`cd go && go build` from `README.md`, `CLAUDE.md`, and `doc/` help. Result:
**zero-build, clone-and-go pure-Lua plugin.** Neovim floor stays **≥ 0.10**
(`vim.system`, `vim.uv`). `telescope` stays optional (tag picker only); `fzf`
dependency is removed (D7).

## 8. Migration order (strangler — plugin works at every commit)

Per `06` §5. Gate `go/` deletion on byte-exact parity.

- **P0** Golden capture: run the existing Go binary over `go/testdata/` vaults;
  freeze `list`/`tags`/post-mutation outputs into `tests/fixtures/golden/`
  (inject a fixed `now`).
- **P1** Pure-logic modules + unit specs: `strftime`, `horizon`, `format`,
  `parse`, `frontmatter`, `mutate`, `state` (no wiring yet).
- **P2** Read path: `scan` + `list.list`, behind a `use_lua_pipeline` flag; diff
  against the binary until byte-identical, then make it default.
- **P3** Write path: `actions.*`; re-point `keymaps`/`util`; parity on mutations.
- **P4** Flip default; remove the flag.
- **P5** **Parity gate** — full golden suite green on CI.
- **P6** Delete `go/`, de-Go health/README/CLAUDE/doc; confirm zero-build.

## 9. Top risks

1. **Cold frontmatter file I/O** is the only thing likely to miss the latency
   target on the first `:Tasks` per session, and there is no `vim.*`-capable
   off-thread escape — so the head-only-read + per-refresh-cache (and ideally
   rg-driven FM-head) mitigations must land. (06 §8, 03 §latency)
2. **File-write safety (D9):** today's disk-write + `:edit!` can silently discard
   a user's unsaved edits to a source note. The buffer-aware mutate is a
   correctness fix, not just polish.
3. **Byte-exact format parity:** the time-column's leading-tab-only-when-no-time
   quirk and the duration right-pad-to-4 are easy to get subtly wrong; the
   golden-file gate is what catches it. (04 column-spec table)
4. **Parser fidelity on adversarial lines:** wikilink aliases, paths in links,
   `::`/prefix appearing in body text, indented/codeblock lines — all pinned by
   `parse_adversarial_test.go`; port those tests early. (02)
