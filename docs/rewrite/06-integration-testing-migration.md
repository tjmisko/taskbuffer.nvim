# 06 — Integration, Testing & Migration Blueprint

> Owns the cross-cutting wiring and the rollout, not any single algorithm. Read
> `docs/rewrite/CONTEXT.md` first; this blueprint cites it and the five sibling
> blueprints (01-scan, 02-parse, 03-frontmatter, 04-horizon-format,
> 05-mutate-state-commands) rather than re-deriving their internals.

## 1. Scope

I own:
- The final `lua/taskbuffer/` module tree and the seams between the five
  algorithm blueprints.
- The in-process `list()` orchestrator that replaces `buffer.lua:build_cmd` +
  `vim.system(task_bin ...)`.
- The threading model for parse/format on the UI thread.
- The buffer/output-format decision (text round-trip vs in-memory side-table).
- The full rewiring map of every binary call site → Lua.
- Removal of `go/` and the zero-build distribution story.
- The test framework choice, the golden-file parity harness, and the
  commit-by-commit migration that keeps the plugin working at every step.

I do **not** own: rg invocation/glob/dedup (01), regex/`Task` field parsing
(02), YAML frontmatter parsing (03), horizon resolution + byte-exact formatter
(04), mutation/state/verb primitives (05). I define the *interfaces* those
modules must expose so they compose.

---

## 2. Target module architecture

### 2.1 Final `lua/taskbuffer/` tree

```
lua/taskbuffer/
  init.lua        (kept; setup + public API; aliases dropped — §5)
  config.lua      (kept; drop task_bin/source_args/config_json_arg — §4)
  context.lua     (NEW; build_context(config.values) → ctx — the ParseContext+Config replacement)
  scan.lua        (NEW; 01) scan(ctx) → RawMatch[]; scan_async(ctx, cb); scan_project_paths(ctx) → string[]
  parse.lua       (NEW; 02) parse_tasks(matches, ctx) → Task[]
  frontmatter.lua (NEW; 03) parse_frontmatter(path, ctx) → FM (cached); merge_tags; filter_completed; merge_due; project_task(path, ctx)
  horizon.lua     (NEW; 04) resolve(specs, now, week_start, overlap) → Resolved[]
  format.lua      (NEW; 04) format_taskfile(tasks, now, opts) → string  (byte-exact)
  timefmt.lua     (NEW; 04/02) strftime → {pattern, display, validate}  (port timeformat.go)
  mutate.lua      (NEW; 05) change_checkbox, remove_last_marker, insert_after_header, append_to_file (+ reuse util line IO)
  state.lua       (NEW; 05) read/write/clear current_task; format_marker
  actions.lua     (NEW; 05) verbs: complete_at, defer, check, irrelevant, unset, stop, start, complete, (create/do optional)
  list.lua        (NEW; THIS blueprint) list(opts) / list_async(opts, cb) → taskfile text; tags(ctx) → string[]
  buffer.lua      (kept; rewired to list.lua — §4)
  util.lua        (kept; keeps line IO + date-string ops + qf + parse_taskfile_line; loses run_task_cmd — §4)
  keymaps.lua     (kept; verbs rewired to actions.lua; start_task→state.stop — §4)
  tags.lua        (kept; rewired to list.tags() — §4)
  commands.lua    (unchanged)
  autocmds.lua    (unchanged)
  undo.lua        (unchanged; still consumes util.parse_taskfile_line)
  health.lua      (kept; Go check removed, grep-fallback added — §5)
```

Rationale for module boundaries: one Lua module per Go file keeps the parity
map 1:1 (a reviewer can diff `parse.lua` against `parse.go`), which is the
cheapest way to argue parity to a maintainer. `list.lua` is the *only* new
seam that has no Go counterpart — it is the in-Lua reimplementation of
`main.go:cmdList`/`cmdTags`.

### 2.2 The `ctx` object (replaces `ParseContext` + `Config` + `--config` JSON)

There is no JSON boundary after the rewrite. `context.lua` reads
`config.values` directly and produces one plain Lua table threaded through
every pipeline stage. It is the union of Go's `NewParseContext` output
(`parse.go`) and the `Config` struct (`main.go:103`).

```lua
---@class TaskbufferContext
ctx = {
  sources        = { "/abs/notes", ... },     -- expanded, from config.sources (01 consumes)
  scan_pattern   = [[\- \[.\]]],              -- derived from checkbox (01)
  state_dir      = "/abs/state",

  date           = { strftime="%Y-%m-%d", pattern=<lua pat>, validate=<fn> }, -- (02/04 via timefmt)
  time           = { strftime="%H:%M",   pattern=<lua pat> },
  date_wrapper   = { "(@[[", "]]", ")" },
  tag_prefix     = "#",
  marker_prefix  = "::",
  checkbox       = { open="- [ ]", done="- [x]", irrelevant="- [-]" },

  frontmatter    = { due_key="due", inherit_due=true, require_tags={},
                     status_key="status", done_values={"done","complete"} },

  horizons       = nil | { {label,after,undated,order}, ... },
  horizons_overlap = "sorted",
  week_start     = "monday",

  strict         = false,

  _re   = { status=<engine handle>, date=<engine handle>, marker=<engine handle> }, -- 02 owns
  _fm   = {},   -- frontmatter cache keyed by path (03 owns; see §6.3 latency)
}
```

`context.build_context(cfg, runtime)` is called once per refresh. `runtime`
carries the per-invocation flags that today are CLI args:
`{ markers=bool, ignore_undated=bool, tags={...} }` (today: `-markers`,
`--ignore-undated`, repeated `--tag`).

### 2.3 The canonical `Task` shape (shared across 02/03/04/05)

Pinned here because four blueprints read/write it. Mirrors Go's `Task` struct.

```lua
---@class Task
{ filepath   = "/abs/file.md",
  linenumber = 11,
  body       = "Buy groceries",
  due_date   = <epoch-at-local-midnight> | nil,  -- see note
  due_time   = "16:00",        -- already display-formatted string (Go stores verbatim)
  duration   = "30m",          -- raw, e.g. "30m"/"5m"/"90m"
  tags       = { "exercise", "target" },
  status     = "open"|"done"|"irrelevant",
  markers    = { { kind="start", date="2026-02-17", time="15:58" }, ... },
  sort_last  = false }          -- true for synthetic project tasks
```

`due_date` representation is a **02/04 seam decision** but must satisfy two
consumers: (a) equality + ordering for horizon bucketing and sort, (b)
re-display via the configured strftime in `format.lua`
(`format.go:98 DueDate.Format(dateFmt)`). Recommendation: store an
**epoch-at-local-midnight integer** (`os.time{year=y,month=m,day=d}`), so
ordering is integer compare and display is `os.date(ctx.date.strftime, epoch)`.
This also fixes CONTEXT §6.5 (DST) since midnight epochs are normalized by
`os.time`. Flag to 02/04: do **not** store raw matched date strings as the
source of truth — Go round-trips through `time.Time`, so the displayed date is
canonicalized, not echoed.

### 2.4 Data flow for `list` (the in-process pipeline)

Mirrors `main.go:cmdList` (`go/main.go:163-231`) exactly, step for step:

```
list(opts):
  ctx       = context.build_context(config.values, opts)
  matches   = scan.scan(ctx)                                   -- 01  (rg --json)
  tasks     = parse.parse_tasks(matches, ctx)                  -- 02
  frontmatter.merge_tags(tasks, ctx)                           -- 03  (MergeFrontmatterTags)
  tasks     = frontmatter.filter_completed(tasks, ctx)         -- 03  (FilterCompletedFrontmatterTasks)
  frontmatter.merge_due(tasks, ctx)                            -- 03  (MergeFrontmatterDue)
  for p in scan.scan_project_paths(ctx):                       -- 01  (rg -l "- project")
      t = frontmatter.project_task(p, ctx)                     -- 03  (builds SortLast Task)
      if t then tasks[#tasks+1] = t
  open      = filter(tasks, status=="open")                    -- main.go:198
  if ctx.strict and #date_errors>0: return nil, errmsg         -- main.go:204 (abort, no write)
  horizons  = horizon.resolve(ctx.horizons, now, ctx.week_start, ctx.horizons_overlap) -- 04
  text      = format.format_taskfile(open, now, {              -- 04  (byte-exact)
                markers=opts.markers, ignore_undated=opts.ignore_undated,
                tag_filter=opts.tags, tag_prefix=ctx.tag_prefix,
                marker_prefix=ctx.marker_prefix, horizons=horizons,
                overlap=ctx.horizons_overlap, date_strftime=ctx.date.strftime })
  return text
```

`tags(ctx)` mirrors `main.go:cmdTags` (`go/main.go:383-418`): scan → parse →
merge_tags → project paths → collect open tasks' tags → unique + sorted.

**Ownership seam — project tasks:** Go's `ScanProjects` (`scan.go:158`) *both*
finds project candidate files (rg) *and* parses their frontmatter into Tasks.
We split that: **01** owns only the rg `-l "- project"` candidate-path scan
(`scan.scan_project_paths`); **03** owns turning a path into a `Task`
(`frontmatter.project_task`, including the `done_values` skip, the `due`
split-on-space, the `filepath.Base` body, `SortLast=true`). `list.lua`
assembles. This keeps all YAML knowledge in 03.

---

## 3. [DECISION] Pipeline threading

### 3.1 The honest constraint

CONTEXT §6.4 frames this as "rg async, parse/format on the main thread." The
subtle, load-bearing fact: **`vim.system`'s `on_exit` callback runs on
Neovim's main loop in a *fast-event* context.** It is single-threaded with the
UI. Doing parse/format there still consumes UI-thread time — there is no free
lunch from "parse in the callback." Worse, in a fast-event context most
`vim.*` is forbidden, and **`vim.regex():match_str()` is not guaranteed
callable** there (02 must pick its engine knowing this). So the realistic
options collapse to:

- **(a)** rg async (`vim.system` rg) → in `on_exit`, `vim.schedule(...)` →
  parse + format **synchronously** on the main thread → write buffer.
- **(b)** Same, but parse in **chunks** driven by a coroutine resumed across
  `vim.schedule`/`vim.defer_fn` ticks, so no single tick exceeds one frame.
- **(c)** A `vim.uv.new_work()` / `new_thread()` luv worker that does pure
  string crunching (parse/format) off-thread. **No `vim.*` API there** — only
  LuaJIT + string libs. `ctx` and rg output must cross as serialized
  strings/plain tables; `vim.regex`/`vim.json` unavailable on the worker.

### 3.2 Worst-case main-thread cost (quantified)

Realistic vault per CONTEXT: hundreds of files, low-thousands of task lines.
Take a deliberately pessimistic 2,000 task lines across 600 `.md` files.

| Stage | Work | Estimated main-thread cost |
|-------|------|----------------------------|
| rg `--json` scan | spawned process, async | ~0ms (off-thread; wall-clock 5-30ms) |
| JSON decode of rg stream | 2,000 `vim.json.decode` (or plain-split per 01) | 3-10ms |
| `parse_tasks` | 2,000 lines × ~4-6 pattern ops | 4-12ms (LuaJIT) |
| `merge_tags` / `filter` / `merge_due` | table walks over 2,000 tasks | 1-3ms |
| **frontmatter head-reads (COLD)** | open + read head of up to 600 files | **20-120ms** ← dominant |
| frontmatter (WARM, mtime cache) | cache hits | 1-3ms |
| project scan (rg `-l`) | async | ~0ms |
| `resolve` + `format_taskfile` + sort | sort 2,000 + string build | 2-6ms |
| **Total, warm cache** | | **~12-30ms** (within 50ms budget) |
| **Total, cold cache** | | **~35-150ms** (can exceed budget) |

Conclusion: **parse + format are not the bottleneck** (~12-30ms, fine). The
variable that can blow the 50ms target is **frontmatter file-head I/O on a cold
cache** (CONTEXT §6.3). That cost is owned by 03 (head-only reads + mtime
cache) and ideally moved off-thread by gathering frontmatter blocks through the
**same async rg pass** rather than per-file `io.open` on the main thread.

### 3.3 Recommendation

**Adopt (a) — rg async + synchronous parse/format in a `vim.schedule`d
callback — as the default**, because the on-thread parse/format budget
(~12-30ms warm) sits comfortably under 50ms and below typical perceptual
thresholds. Keep the existing sync path (`refresh_taskfile` via
`scan.scan(ctx)` `:wait()`) for code paths that already block by design
(`refresh_and_restore_cursor`, tag-picker apply).

**Fallback (b)** — gate behind a config knob `parse_strategy = "sync" |
"chunked"` (default `"sync"`). If a user reports frame hitches on a pathological
vault, `"chunked"` resumes a parse coroutine across `vim.schedule` ticks in
batches of ~500 lines so no tick exceeds ~8ms. Cheap to add later; do **not**
build it pre-emptively.

**Reject (c) as the default.** A luv worker buys little (15ms is already
fine), and its costs are real: `ctx` must be reduced to a plain serializable
table (no compiled `vim.regex` handles, forcing 02 to a pure-Lua-pattern
engine), rg output and `Task[]` must cross the thread boundary as
strings/`vim.mpack`, and `vim.json` is unavailable on the worker. Document it
as the escape hatch for users with truly enormous vaults, not the shipped
default.

**Cross-seam directive to 02:** because parse runs after `vim.schedule` (main
thread, not fast-event), `vim.regex` *is* usable — but if 02 wants the option
to later move to a luv worker, prefer pure Lua `string.match`/hand-rolled
tokenizing. Integration's default does not require the worker, so 02 may use
`vim.regex` freely; just document the worker trade-off.

---

## 4. [DECISION] Buffer / output format

### 4.1 Options

- **A — Keep the on-disk `<tmpdir>/<date>.taskfile` text round-trip.** `list()`
  returns the same byte-exact text; `buffer.lua` writes it and `:edit`s it
  readonly, exactly as today. Every downstream consumer re-parses that text.
- **B — Build the buffer directly from in-memory `Task` objects** via
  `nvim_buf_set_lines`, with a `line → {filepath, linenumber, task}` side table
  (a Lua array or extmarks) so keymaps look up the source by line index instead
  of slicing strings.

### 4.2 Consumers that depend on the text contract (CONTEXT §3)

Every one of these works **unchanged** under Option A:
- `util.parse_taskfile_line` (`util.lua:7`) — filepath before 1st `:`, lineno
  between 1st/2nd `:`.
- `util.taskfile_lines_to_qf` (`util.lua:410`) — `^(.-):(.-):(.-):(.*)$`.
- `keymaps.lua:start_task` body extraction (`keymaps.lua:400`) —
  `^.-|.-|.-|(.*)$` slicing on the pipe columns, then `:match("^(.-)%s*::")`.
- `keymaps.lua:go_to_file` / `start_task` location slicing
  (`keymaps.lua:393,420`) — first/second `:` substring.
- `undo.lua:flash_edits` (`undo.lua:46`) — calls `parse_taskfile_line`.
- `syntax/taskfile.vim` + `ftdetect/taskfile.vim` — pattern-match the rendered
  text and the `.taskfile` extension; concealment depends on the exact
  TAB/`[[ ]]` layout.

Under Option B, **all six** plus the syntax/ftdetect flow must be re-touched
(filetype set manually, readonly via `modifiable=false`, side-table lookups
swapped in for string slicing in keymaps/undo/quickfix).

### 4.3 Recommendation

**Adopt Option A (keep the text round-trip) for the rewrite.** Rationale:

1. **Smallest blast radius during the riskiest change.** The Go→Lua port is
   already large; coupling it to a buffer-rendering refactor multiplies the
   surface where parity can silently break. Under A, `format.lua` reproducing
   the bytes means `buffer.lua`, `keymaps.lua`, `tags.lua`, `undo.lua`,
   `syntax/`, `ftdetect/` need **zero** changes beyond repointing the data
   source.
2. **The parity gate becomes a pure string compare.** Golden = Go stdout; Lua
   `list()` returns a string; `assert.are.equal(golden, got)`. Option B has no
   such clean oracle.
3. The text contract is already pinned by `format_test.go` `want` strings
   (CONTEXT §3), so we get a free, exhaustive spec for `format.lua`.

**Optimization to keep, not block on:** under A we may still skip the disk by
writing the identical text straight into the buffer with
`nvim_buf_set_lines` + `bo.modifiable=false`, *if* we also set
`vim.bo.filetype = "taskfile"` to preserve syntax. That removes the temp-file
write and the `:edit` reload while keeping byte-identical content and all
consumers. Treat this as a small, optional follow-up *inside* Phase 4, gated so
it does not affect parity (the bytes are unchanged). **Defer Option B (the
side-table) to a separate post-Go PR** — it is a robustness optimization
(killing fragile string re-parsing), not part of achieving parity, and should
not ride the migration.

---

## 5. Rewiring map

Every binary call site (CONTEXT §2) → its Lua replacement.

| # | Call site (file:fn) | Today | Lua replacement |
|---|---------------------|-------|-----------------|
| 1 | `buffer.lua:build_cmd` + `refresh_taskfile` (sync) | spawn `task_bin … list`, write stdout to `<tmpdir>/<date>.taskfile` | `local text = require("taskbuffer.list").list(opts); write_taskfile(text)`. `build_cmd` deleted; `opts` = `{markers=show_markers, ignore_undated=not show_undated, tags=active_tag_filter}` |
| 2 | `buffer.lua:refresh_taskfile_async` | `vim.system(task_bin … list, on_exit)` | `require("taskbuffer.list").list_async(opts, function(text) write_taskfile(text); callback() end)`. `list_async` runs `scan.scan_async` (rg via `vim.system`) then `vim.schedule(parse→format)` (§3) |
| 3 | `util.lua:run_task_cmd` → `complete-at` | `vim.system(task_bin complete-at f n)` | `require("taskbuffer.actions").complete_at(f, n, ctx)` |
| 4 | `util.lua:run_task_cmd` → `defer` | `task_bin defer f n` | `actions.defer(f, n, ctx)` |
| 5 | `util.lua:run_task_cmd` → `check` | `task_bin check f n` | `actions.check(f, n, ctx)` |
| 6 | `util.lua:run_task_cmd` → `irrelevant` | `task_bin irrelevant f n` | `actions.irrelevant(f, n, ctx)` |
| 7 | `util.lua:run_task_cmd` → `unset` | `task_bin unset f n` | `actions.unset(f, n, ctx)` |
| 8 | `util.lua:run_task_cmd` (the wrapper) | generic invoker + optional `refresh_and_restore_cursor` | delete `run_task_cmd`; `keymaps.lua` calls `actions.<verb>` then `buffer.refresh_and_restore_cursor()` directly. (Keymap callbacks in `keymaps.lua:348-376,431-439` updated.) |
| 9 | `keymaps.lua:start_task` → `os.execute(task_bin .. " stop")` (`keymaps.lua:391`) | shell out to stop running task | `require("taskbuffer.state").stop(ctx)` (writes stop marker + clears state, in Lua). The rest of `start_task` (state write + `append_to_line` start marker) is already pure Lua and stays, ideally relocated into `actions.start`/`state.start` for testability |
| 10 | `tags.lua` `io.popen(task_bin … tags)` (`tags.lua:24`) | shell, read stdout lines | `local tags = require("taskbuffer.list").tags(ctx)`; drop `io.popen`, `vim.fn.shellescape`, `2>/dev/null` |
| 11 | `config.lua:source_args` (`config.lua:234`) | builds `--source` CLI args | **internalize**: `ctx.sources` (expanded list). Public `source_args` deleted (or kept as deprecated stub returning `{}` for one release — see §8 test impact) |
| 12 | `config.lua:config_json_arg` (`config.lua:245`) | builds `--config` JSON | **delete**; replaced by `context.build_context(config.values)` |
| 13 | `config.lua:defaults.task_bin` (`config.lua:88`) + `expand_config_paths` line (`config.lua:201`) | binary path default + expansion | **delete** the field and its expansion |
| 14 | `init.lua` `M.source_args` / `M.config_json_arg` aliases (`init.lua:14-15`) | re-export config fns | **delete** (or deprecated stubs); update `doc/taskbuffer.txt` API section (`taskbuffer.txt:386-392`) |
| 15 | `health.lua` Go-binary executable check (`health.lua:16-22`) | `vim.fn.executable(task_bin)` | **drop**. Add: rg present → ok; rg absent but grep present → warn ("grep fallback active, slower / `--json` parity caveats"); neither → error |
| 16 | `buffer.lua` / `tags.lua` writers | write `<tmpdir>/<date>.taskfile` then `:edit` | unchanged under Option A (§4) |

Note on `actions`/`ctx` plumbing: keymap callbacks should build `ctx` once via
`context.build_context(config.values)` (cheap) or cache it; the verbs only need
`ctx.checkbox`, `ctx.marker_prefix`, `ctx.date`/`ctx.time`, `ctx.state_dir`
(05's surface).

---

## 6. Removals & distribution

### 6.1 Delete (Phase 6, after the parity gate)

- `go/` entire directory — all `*.go`, `*_test.go`, `go.mod`, `go.sum`,
  `go/.gitignore`, the built `task_bin`. **Move `go/testdata/` → `tests/fixtures/vaults/` first** (§7) so parity tests keep their inputs.
- `.gitignore` lines `go/task_bin` and `go/taskbuffer` (root `.gitignore:1-2`).
- `Dockerfile` builder stage (Stage 1 + the `COPY --from=builder` line) — keep
  only the Neovim+rg runtime; copy plugin Lua, no binary.
- `Makefile`: drop `build:` and the Go `test:` target; keep `test-lua`,
  `test-e2e*`, `lint`, drop `clean:`'s `rm go/task_bin`.
- `.github/workflows/ci.yml`: delete the `go-test` job (`ci.yml:10-21`); keep
  `lua-test` + `lua-check`. Add a `parity` job (§7) that runs the Lua golden
  tests (no Go).
- `scripts/test.sh` — rewrite or delete (it builds + runs Go tests).
- `repro.lua` — drop the `build = "cd go && go build -o task_bin ."` line
  (`repro.lua:11`).

### 6.2 Edit (docs / config — drop all build references)

- `config.lua` — remove `task_bin` (§5 #13). `formats` comments
  "passed to Go binary" → "task syntax".
- `README.md` — Requirements: drop "Go >= 1.21"; Installation: drop
  `build =`/`run =` hooks (`README.md:30,50`); drop the "build manually"
  block; "Health Check" list drop Go binary; "Architecture" diagram + prose
  (`README.md:324-335`) rewritten to "Markdown → rg → Lua parse → taskfile";
  "CLI Commands" section — the `task` binary no longer exists, so either delete
  §"CLI Commands" or note the verbs are now Neovim-internal (see §8).
- `doc/taskbuffer.txt` — Requirements (`:33`) drop Go; Installation
  (`:40-61`) drop build hooks; Health check (`:274-279`) drop Go binary, add
  grep fallback; Public API (`:386-392`) drop `source_args`/`config_json_arg`.
- `CLAUDE.md` (both the project one and worktree copy) — "Build & Test" section
  loses `cd go && go build`; Architecture "parsed in Go" → "parsed in Lua";
  the Go-binary bullet list replaced by the Lua module list.
- `PROJECT.md` — "flag in go script" task note is historical; leave or update.

### 6.3 Zero-build confirmation & version floor

After 6.1/6.2 the plugin is **pure Lua + `rg`** with an optional `grep`
fallback (01) and optional `telescope` (tag picker). Clone-and-go: no compile
step, no `build`/`run` hook. Runtime floor stays **Neovim ≥ 0.10**, already
gated in `init.lua:1` and `health.lua:7`, justified by:
- `vim.system` (0.10) — async rg in `buffer.lua`/`list_async`.
- `vim.uv` (0.10 alias of `vim.loop`) — `fs_stat` in `buffer.lua:148`,
  `fs_realpath` for symlink dedup (01).
- `vim.json` (present 0.9+, safe at 0.10) — rg `--json` decode (01) / nothing
  if 01 chooses plain output.
No new heavy runtime deps (CONTEXT §1).

---

## 7. [DECISION] Test strategy & parity harness

### 7.1 Test framework

**Recommendation: stay on plenary `:PlenaryBustedDirectory`.** The repo already
runs it (`Makefile:test-lua`, `tests/minimal_init.lua`, `tests/*_spec.lua`,
CI `lua-test` job at `ci.yml:23-35`). It embeds an Neovim runtime, so specs can
freely call `vim.*` (which parse/format/frontmatter will, via
`vim.json`/`vim.regex`/`vim.fn`). Zero new dependency.

Alternatives considered:
- **busted (standalone)** — faster, nicer assertions, but our modules call
  `vim.*` everywhere; running them needs an Neovim host anyway, which is exactly
  what plenary provides. Not worth a second toolchain.
- **mini.test** — excellent child-process isolation and screenshot assertions;
  ideal for the *buffer/keymap UI* layer. Adds a dep + a second idiom. Defer as
  an optional later addition for buffer-level e2e; not for the port.

Structure:
```
tests/
  unit/         (plenary; one spec per Lua module, ported from the matching *_test.go)
  parity/       (plenary; golden-file byte diffs over fixtures/vaults)
  fixtures/
    vaults/     (moved from go/testdata/)
    golden/     (captured Go stdout + post-mutation file bytes)
  e2e/          (existing Docker smoke tests; Dockerfile de-Go'd)
  minimal_init.lua, *_spec.lua (existing, migrated under unit/)
```

### 7.2 Golden-file parity harness

The Go suite (6,562 test lines across `go/*_test.go`) is the spec. Use it
**twice**: port the unit assertions, and capture end-to-end golden outputs.

**Capture (one-time, while Go still builds on `main`/Phase 0):**
`scripts/capture-golden.sh`:
1. `cd go && go build -o task_bin .`
2. For each `tests/fixtures/vaults/<vault>` and each flag variant, run
   `task_bin --source <vault> --config <json> list [variant flags]` and write
   stdout to `tests/fixtures/golden/<vault>__<variant>.taskfile`.
   Variant matrix (covers `vault_test.go` + `integration_test.go`): default;
   `--markers`; `--ignore-undated`; `--tag <t>` (single + multiple);
   custom `--config` for `custom-format-vault` (date wrapper / checkbox / tag /
   marker prefix), `horizons-vault` (custom horizons, overlap=first_match,
   week_start=sunday), `fm-due-vault` (inherit_due, require_tags, custom keys).
3. Capture `tags` stdout per vault → `golden/<vault>__tags.txt`.
4. For mutations: copy a vault to a temp dir, run each verb
   (`defer`/`irrelevant`/`unset`/`check`/`complete-at` on a known
   `file:line`), and snapshot the resulting **file bytes** →
   `golden/mutate/<vault>__<verb>__<file>.md`. Pin `now`/timezone so markers are
   deterministic (set `TZ` and, if needed, a frozen-clock build tag — note Go
   uses `time.Now()`; for capture, either accept a fixed `TZ` and post-filter
   the time field, or add a `--now` test hook).

**Assert (Lua, runs with Go absent):**
`tests/parity/list_spec.lua` etc. read `fixtures/vaults` + `fixtures/golden`,
build the matching `ctx`, run `list.list`/`list.tags`/`actions.<verb>` over a
fresh copy, and `assert.are.equal(golden, got)` byte-for-byte. Because Option A
(§4) keeps the bytes identical, this is a literal string compare. Commit the
fixtures + golden so CI needs no Go.

**Determinism caveat (flag to maintainer):** markers and "Today" bucketing
depend on the current date. Either (a) inject a `now`/clock into `ctx` (add an
optional `ctx.now` consumed by 04/05, defaulting to `os.time()`), which also
makes horizon tests deterministic, or (b) normalize the volatile `HH:MM`/date
columns out before diffing. **Recommend (a)** — a `now` injection point is the
single cheapest enabler of deterministic parity for both horizons and markers,
and it costs 04/05 almost nothing. This is the one new seam the parity harness
asks of the algorithm blueprints.

### 7.3 Go test → Lua module test map

| Go test file (funcs) | Lua spec | Module under test |
|----------------------|----------|-------------------|
| `scan_test.go`, `scan_multi_test.go` (`TestScan_*`, `TestDeduplicatePaths_*`, `TestScan_GlobExpansion`) | `tests/unit/scan_spec.lua` | `scan.lua` |
| `parse_test.go`, `parse_adversarial_test.go` (`TestParseTask_*`) | `tests/unit/parse_spec.lua` | `parse.lua` |
| `date_validation_test.go` (strict reject 2026-13-45) | `tests/unit/parse_spec.lua` (+ `strict`) | `parse.lua`/`timefmt.lua` |
| `timeformat_test.go` | `tests/unit/timefmt_spec.lua` | `timefmt.lua` |
| `frontmatter_test.go`, `fm_due_e2e_test.go` (`TestFM_*`, inherit/project/status) | `tests/unit/frontmatter_spec.lua` + `tests/parity` (`fm-due-vault`) | `frontmatter.lua` |
| `horizon_test.go` (keywords/durations/week-start/overlap) | `tests/unit/horizon_spec.lua` | `horizon.lua` |
| `format_test.go` (`want` strings, bucketing, sort, SortLast) | `tests/unit/format_spec.lua` | `format.lua` |
| `mutate_test.go`, `mutate_new_test.go` | `tests/unit/mutate_spec.lua` | `mutate.lua` |
| `state_test.go` | `tests/unit/state_spec.lua` | `state.lua` |
| `config_test.go` | `tests/unit/context_spec.lua` (ctx shape, not JSON) | `context.lua` |
| `integration_test.go` (`TestEdge_*`, `TestPath_*`, `TestTag_*`, `TestGlob_*`, `TestCustom_*`, `TestCombo_*`) | `tests/parity/list_spec.lua` | end-to-end `list.lua` |
| `vault_test.go` (`TestVault_CmdListEndToEnd`, `TestVault_TagFilter*`, `TestVault_ProjectScanning`, `TestVault_CustomHorizons`, `TestVault_HorizonsOverlapFirstMatch`, `TestVault_WeekStartSunday`, `TestVault_CmdListIgnoreUndated`) | `tests/parity/list_spec.lua` (variant matrix) | end-to-end `list.lua`/`tags` |

Existing Lua specs to migrate/rewrite: `config_spec.lua` (drop
`config_json_arg`/`source_args` blocks → assert `ctx` fields instead),
`buffer_spec.lua` (no longer "requires the Go binary"; test against fixtures),
`keymaps_spec.lua` (unchanged — keymap registration is binary-agnostic),
`undo_spec.lua` (unchanged).

---

## 8. Sequenced implementation plan (strangler pattern)

Single feature flag `config.values.use_lua_pipeline` (default `false` until
Phase 4) lets every commit ship a working plugin: `false` → existing binary
path, `true` → Lua path. The flag and the binary path are deleted in Phase 6.

**Phase 0 — Harness & golden capture (Go untouched)**
- `chore: move go/testdata to tests/fixtures/vaults`
- `test: add scripts/capture-golden.sh and commit golden fixtures`
- `feat: add use_lua_pipeline flag (default false) and context.build_context skeleton`
- DoD: golden files committed; `make test-lua` + `make test` (Go) both green;
  plugin behavior unchanged (flag off).

**Phase 1 — Pure-logic modules + unit specs (flag still off)**
Land each module with its ported spec, no wiring yet. Suggested atomic commits
(dependency order): `timefmt` → `horizon` → `format` → `parse` → `frontmatter`
→ `scan` → `state` → `mutate`.
- `feat(lua): port timeformat.go to timefmt.lua` (+ `test: timefmt_spec`)
- `feat(lua): port horizon.go to horizon.lua` (+ spec)
- `feat(lua): port format.go to format.lua` (+ spec using format_test want strings)
- `feat(lua): port parse.go to parse.lua` (+ spec incl. strict date validation)
- `feat(lua): port frontmatter.go to frontmatter.lua` (+ spec)
- `feat(lua): port scan.go to scan.lua (rg --json + grep fallback)` (+ spec)
- `feat(lua): port state.go to state.lua` (+ spec)
- `feat(lua): port mutate.go to mutate.lua` (+ spec)
- DoD per commit: its ported unit spec green; plugin still uses binary.

**Phase 2 — `list` orchestrator + parity (flag-gated read path)**
- `feat(lua): add list.lua (list/list_async/tags) wiring the pipeline`
- `test: parity specs diffing list/tags vs golden over all vaults`
- `feat: route buffer.refresh_* and tags.lua through list.lua when use_lua_pipeline`
- DoD: `tests/parity` green for every vault/variant; with flag on, `:Tasks`
  byte-matches binary output; flag off path untouched.

**Phase 3 — Verbs + state (flag-gated write path)**
- `feat(lua): add actions.lua verbs (defer/irrelevant/unset/check/complete-at)`
- `feat: route util.run_task_cmd callers and start_task stop through actions/state when flagged`
- `test: parity specs on post-mutation file bytes`
- DoD: mutation parity green; flag off path untouched.

**Phase 4 — Flip default**
- `feat: enable use_lua_pipeline by default`
- (optional) `perf: write taskfile straight to buffer via nvim_buf_set_lines (bytes unchanged)`
- DoD: full `make test-lua` + parity green with flag on by default; e2e smoke
  (Docker, **Go binary still present**) green; soak.

**Phase 5 — PARITY GATE (no code, a checklist before deletion)**
- All `tests/unit` specs green (every ported Go test).
- All `tests/parity` byte-diffs green across all vaults × variants × mutations.
- e2e smoke green in a **Go-free** image (rebuild Dockerfile without builder
  stage as a dry run).
- Manual: `:checkhealth taskbuffer`, `:Tasks`, tag picker, date-shift, undo,
  start/stop, on a real vault.
- DoD: gate signed off → proceed to Phase 6. **Do not delete `go/` before this.**

**Phase 6 — Remove Go + zero-build**
- `refactor: delete binary code paths and use_lua_pipeline flag`
- `chore: remove go/ directory, go.mod/go.sum, task_bin`
- `chore: de-Go Dockerfile, Makefile, CI (drop go-test, add parity job)`
- `docs: drop build steps from README, doc/taskbuffer.txt, CLAUDE.md, repro.lua`
- `feat(health): drop Go check, add rg + grep-fallback check`
- `refactor(config): remove task_bin; remove source_args/config_json_arg (+ specs)`
- DoD: `rg -n "task_bin|go build|cd go|config_json_arg" -- . ':!docs/rewrite'`
  returns nothing; clone-and-go works on a fresh checkout with only `rg`
  installed; CI green with no Go job.

---

## 9. Edge cases (mapped to Go tests)

- **Empty / non-existent / no-task sources** → `scan` returns empty, `list`
  returns `""` (today `write_taskfile("")` yields an empty buffer; preserve).
  `TestScan_EmptyDir`, `TestScan_NoMatchesInFile`, `TestPath_EmptyDirectory`,
  `TestPath_NonExistentPath`, `TestPath_NoTasksInMarkdown`,
  `TestTag_NoMatchEmptyOutput`, `TestCombo_AllFiltersNoResults`.
- **Symlink/nested/duplicate dedup** must replicate
  `scan.go:deduplicatePaths` (realpath via `vim.uv.fs_realpath`, sort by length,
  prefix-drop). `TestPath_SymlinkDedup`, `TestPath_OverlappingNested`,
  `TestPath_ExactDuplicates`, `TestPath_ParentScansAll`,
  `TestDeduplicatePaths_*`. (01 owns; Integration's parity vaults pin it.)
- **Spaces in paths** — the taskfile location is `filepath:line:1:`; a path with
  a space still parses because `parse_taskfile_line` splits on `:` not space.
  `TestPath_SpacesInPath`.
- **Project (SortLast) tasks** sort *after* same-date regular tasks
  (`format.go:216`). `TestVault_ProjectScanning`, `fm-due-vault/project-sort.md`.
- **Completed-status files excluded**, **due inheritance**, **require_tags**,
  **custom due/status keys**, **bare vs quoted vs with-time dates** — all in
  `fm_due_e2e_test.go` + `frontmatter_test.go`; pinned by `fm-due-vault` golden.
- **Custom format round-trip** (date wrapper, checkbox, tag/marker prefix, EU/US
  dates, 12h time) — `TestCustom_*` + `custom-format-vault` golden + the e2e
  Docker variants (`Dockerfile.us-dates`, `.eu-dates`, `.custom-checkbox`,
  `.12h-time`, `.minimal-wrapper`). These exercise `ctx` plumbing end-to-end.
- **Strict date rejection** (`2026-13-45`) — `date_validation_test.go`. In strict
  mode `list` returns an error string and writes **no** taskfile (matches
  `main.go:204` abort). See §10 on whether strict is even reachable.

---

## 10. Risks & open questions

**Top risk — frontmatter/scan cold-cache I/O latency (§3.2).** Parse/format are
cheap; the 50ms budget is threatened only by per-file frontmatter head-reads on
a cold cache (20-120ms on a 600-file vault). The only true off-thread option
(luv worker) cannot use `vim.*`. Mitigation must land in 03/01: head-only
reads, mtime-keyed cache, and ideally gathering frontmatter via the async rg
pass instead of main-thread `io.open`. If that does not materialize, the first
`:Tasks` of a session will feel laggy. **This is the single thing most likely to
miss the latency target.**

**Open questions / maintainer decisions:**
1. **[DECISION] Performance regression budget.** Confirm targets: warm refresh
   < ~15ms, cold < 50ms, hard ceiling (e.g. ≤ 2× Go cold time) before
   auto-enabling `parse_strategy="chunked"`. Need a cap to gate Phase 4.
2. **[DECISION] `strict` mode reachability.** `config.config_json_arg`
   (`config.lua:245`) never sends `strict`, so in-plugin behavior is effectively
   `strict=false` today (CLI-only feature). Keep it false-by-default for parity
   and optionally expose `config.strict`? Or drop in-plugin strict entirely?
3. **[DECISION] CLI-only subcommands.** `do` (fzf picker), `create`, `current`
   are never called from Lua keymaps — only `list`, `tags`, `stop`,
   `complete-at`, `defer`, `check`, `irrelevant`, `unset`, and the inline
   `start_task`. MVP parity needs only the latter set. Port `state`/`current`
   for completeness; `do` needs fzf (replace with telescope or drop); `create`
   is easy to keep. Decide scope — recommend porting `current`/`create`,
   dropping the fzf `do` (or reimplementing on telescope later).
4. **grep fallback fidelity (01).** `rg --json` has no grep analog; grep mode
   needs a plain-output path and may diverge on binary/encoding edge cases. The
   health check should *warn* when only grep is present. Acceptable diff or
   blocker? (Recommend: acceptable, warn loudly.)
5. **Golden determinism (§7.2).** Approve adding an optional `ctx.now` injection
   (consumed by 04/05) so horizon bucketing and markers are deterministic in
   parity tests. Cheap, high-leverage; needs 04/05 buy-in.

**Acceptable behavioral diffs:** error-message wording and stderr formatting
(today surfaced via `vim.notify`); the exact text of failure notifications.
**Not acceptable:** any change to the taskfile bytes (§3 contract), task
ordering/tie-breaks (`format.go:209-231` — total order, so safe to reproduce),
which files are included/excluded, marker text written to source files, or the
`current_task` state-file format (`state.go`, consumed by `start_task`).

**Sort stability:** Go `sort.Slice` is not stable, but `format.go`'s comparators
are total (date, path, SortLast, line), so `table.sort` reproduces it
deterministically — no stability gap. Verify the same total-order comparators in
`format.lua`.

**DST (CONTEXT §6.5):** `util.lua` currently shifts dates with
`t + days*86400` (`util.lua:214,349`) — DST-fragile. The port should move
date math to `os.time{year,month,day}` table normalization (§2.3), and the
parity tests should include a DST-boundary date to pin it.
