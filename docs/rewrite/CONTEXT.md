# Shared Context Brief — Go → Lua Rewrite of taskbuffer.nvim

> Read this in full before writing your blueprint. It is the single source of
> truth for facts shared across all sub-blueprints. Do **not** re-derive these;
> cite them. Your job is to produce a *design blueprint*, not an implementation.

## 1. Goal

`taskbuffer.nvim` currently ships a ~2,500-line Go binary (`go/`) that the Lua
plugin shells out to. We are **removing Go entirely** and reimplementing all of
its behavior in pure Lua inside the Neovim plugin. The only acceptable external
dependency is `rg` (ripgrep) on PATH, with a `grep` fallback (standard nvim
practice). No build step may remain.

Hard requirements:
- **Behavior parity.** The plugin's observable behavior must not regress. The
  Go test suite (~6,500 lines across `go/*_test.go`) encodes the contract;
  treat those tests as the spec.
- **Latency/responsiveness is a first-class concern.** Identify every place
  where Go's parsing/IO speed currently does real work and where Lua might
  struggle. Propose concrete mitigations. The `:Tasks` refresh runs on user
  action and must feel instant (target: well under ~50ms for a realistic vault
  of hundreds–low-thousands of task lines across hundreds of files).
- **No new heavy runtime deps.** Pure Lua + `vim.*` APIs + LuaJIT stdlib +
  `rg`/`grep`. `telescope` stays an *optional* dep (tag picker only).

## 2. Current architecture

### Go binary pipeline (`go/`)
`Scan` (rg --json) → `ParseTask` (regex) → frontmatter merge → horizon resolve →
`FormatTaskfile` → stdout. Plus action subcommands that mutate `.md` files.

Non-test Go files (port targets):
- `scan.go` (250) — rg `--json` invocation; `ScanProjects` (project notes);
  glob expansion + symlink-dedup of source paths.
- `parse.go` (331) — `NewParseContext` builds config-driven regexes;
  `ParseTask` parses one matched line into a `Task`.
- `frontmatter.go` (304) — YAML frontmatter parse (gopkg.in/yaml.v3), per-file
  cache; merge tags, inherit due, filter completed files.
- `horizon.go` (216) — horizon specs → resolved cutoffs; calendar keywords;
  duration strings; week-start.
- `format.go` (291) — bucket dated tasks into horizons; sort; emit byte-exact
  taskfile text; overlap strategies (sorted/first_match/narrowest).
- `timeformat.go` (127) — strftime (`%Y-%m-%d`) → Go layout *and* → regex.
- `mutate.go` (141) — append-to-line, change-checkbox, remove-last-marker,
  insert-after-header, append-to-file.
- `state.go` (101) — `current_task` state file read/write/clear; marker fmt.
- `main.go` (695) — CLI flag parsing + subcommand dispatch + `Config` struct.

### Lua plugin (`lua/taskbuffer/`)
- `init.lua` — setup(), entry points.
- `config.lua` — defaults, deep-merge, path expansion, **builds `--config` JSON
  and `--source` args for the binary** (`config_json_arg`, `source_args`).
- `buffer.lua` — builds the binary `list` command (`build_cmd`), runs it
  sync/async via `vim.system`, writes stdout to `<tmpdir>/<YYYY-MM-DD>.taskfile`,
  `:edit`s it readonly.
- `util.lua` — **already pure-Lua**: taskfile-line parse, read/replace/append
  line in file, `shift_date_in_string`, `set_date_today_in_string`,
  frontmatter-due find/shift/set, visual selection, quickfix, and `run_task_cmd`
  (the generic binary invoker for action verbs).
- `keymaps.lua` — global/taskfile/markdown keymaps. `start_task` already writes
  state + start marker in **pure Lua**; other verbs (complete-at, defer, check,
  irrelevant, unset) route through `util.run_task_cmd` → binary.
- `tags.lua` — telescope tag picker; runs `task_bin ... tags` via `io.popen`.
- `commands.lua` — `:Tasks`, `:TasksClear`, `:TasksUndated`.
- `autocmds.lua`, `undo.lua`, `health.lua`.

### Binary call sites in Lua (everything that must be re-pointed at Lua)
- `buffer.lua:build_cmd` → `list` (sync `refresh_taskfile`, async
  `refresh_taskfile_async`).
- `util.lua:run_task_cmd` → action verbs: `complete-at`, `defer`, `check`,
  `irrelevant`, `unset` (from `keymaps.lua`).
- `tags.lua` → `tags` (via `io.popen`).
- `keymaps.lua:start_task` → `os.execute(task_bin .. " stop")` (the only direct
  shell-out for the verb), then writes state + appends start marker in Lua.
- `config.lua` → `task_bin` default path, `source_args`, `config_json_arg`.
- `health.lua` → checks `task_bin` executable.

## 3. THE OUTPUT CONTRACT (byte-exact — do not change without flagging)

`list` emits one line per task. The Lua side parses it back via
`util.parse_taskfile_line` (filepath = text before 1st `:`; linenumber = between
1st and 2nd `:`) and `taskfile_lines_to_qf` (`^(.-):(.-):(.-):(.*)$`). Header
lines are horizon labels (e.g. `# Today`); a blank line separates buckets.

Per `format.go:formatTaskLine` (verify against `go/format_test.go` `want` strings):
```
{filepath}:{lineno}:1:\t{date-col}{time-col}{dur-col}\t {body} \t{tags}{markers}
```
- Location: `"%s:%d:1:"` then a literal TAB.
- Date col: dated → `[[YYYY-MM-DD]]`; undated → 10 spaces.
- Time col: with time → `" | HH:MM |"`; without → TAB + `" |       |"`
  (note the leading TAB only in the no-time case).
- Duration col: with dur → right-pad dur to width 4 then `" |"` (e.g. `" 30m |"`,
  `"  5m |"`, `" 90m |"`); without → `"     |"` (5 spaces + pipe).
- Body: `"\t %s \t"`.
- Tags: leading space then `#tag` space-separated (prefix configurable).
- Markers (only when `--markers`): ` ::kind [[date]]` + optional ` HH:MM`.

Representative `want` strings from `format_test.go`:
```
/notes/project.md:11:1:\t[[2026-02-17]]\t |       |     |\t Buy groceries \t
/notes/test.md:5:1:\t[[2026-02-17]] | 16:00 |     |\t Team meeting \t
/notes/test.md:1:1:\t[[2026-02-17]]\t |       | 90m |\t Deep work \t
/notes/test.md:1:1:\t[[2026-02-17]]\t |       |     |\t Run 5k \t #exercise #target
/notes/someday.md:3:1:\t          \t |       |     |\t Investigate OOM Kill \t
```

> A live architectural question to evaluate (the Integration blueprint owns the
> recommendation): keep this on-disk text round-trip (lowest risk; preserves
> ftdetect/syntax/`:edit` flow), OR build the buffer directly from in-memory
> Task objects with a line→{filepath,line} side table (removes fragile string
> re-parsing). Whichever is chosen, the contract above is the fallback default.

## 4. Config schema (what `config_json_arg` sends today)

```
state_dir, date_format ("%Y-%m-%d"), time_format ("%H:%M"),
date_wrapper (["(@[[","]]",")"]), marker_prefix ("::"), tag_prefix ("#"),
checkbox ({open="- [ ]",done="- [x]",irrelevant="- [-]"}),
horizons (nil|[{label,after,undated,order}]), horizons_overlap
("sorted"|"first_match"|"narrowest"), week_start ("monday"),
frontmatter ({due_key="due", inherit_due=true, require_tags=[],
status_key="status", done_values=["done","complete"]}),
strict (bool).
```
After the rewrite there is no JSON boundary — Lua modules read `config.values`
directly. `source_args`/`config_json_arg` become internal or are deleted.

## 5. Task syntax (the thing being parsed)
```
- [ ] Body <30m> #tag (@[[2026-02-17]] 16:00) ::start [[2026-02-17]] 15:58 ::complete [[2026-02-17]] 17:19
```
- Checkbox at line start (after optional indent): `- [ ]` / `- [x]` / `- [-]`
  (configurable; statuses open/done/irrelevant).
- Duration `<Nm>`. Tags `#tag`. Inline due `(@[[DATE]] [TIME])` — date may be a
  wikilink with alias `[[path/to|DATE]]` (regex strips `(?:[^|\]]*\|)?(?:.*/)?`).
- Markers `::kind [[DATE]] [TIME]` (kinds: start, stop, complete, deferral,
  original, irrelevant).
- Frontmatter can supply `due`/`status`/`tags`; "project" notes (frontmatter
  tag `project` + `due`) become synthetic `SortLast` tasks (body = filename).

## 6. Known latency hot-spots to address (call these out explicitly)
1. **rg output parsing.** Go streams `rg --json`. In Lua decide: `--json` +
   `vim.json.decode` per line vs a plain format (`--no-heading -n` / `--vimgrep`
   / `-0`). Plain is faster but task content contains `:`; pick a separator that
   survives arbitrary content. Owner: Scan blueprint.
2. **Line parsing.** Go uses RE2. Lua patterns lack alternation / optional
   non-capturing groups / `\|`. The status, date (with wikilink alias), and
   marker regexes need a strategy: Lua `string.match` vs `vim.regex` (Vim engine,
   supports `\%(...\)`, `\?`, `\|`) vs hand-rolled tokenizing. Owner: Parse.
3. **Frontmatter.** Go parses YAML per file (cached). Lua has no YAML; a targeted
   line-parser for the needed keys (tags/due/status) avoids a full parser but
   must handle: block lists, inline `[a, b]`, tags-as-string, quoted values,
   YAML-timestamp dates. Reading only the head of each file + caching is key.
   Owner: Frontmatter.
4. **Main-thread blocking.** Moving parse/format into Lua runs it on the UI loop
   (rg can still be async). Quantify and, if needed, chunk. Owner: Integration.
5. **Date math across DST.** `os.time + days*86400` (current Lua) is DST-fragile;
   prefer table-field arithmetic normalized by `os.time`. Owner: Horizon/Parse.
6. **Strict date validation.** Go `time.Parse` rejects 2026-13-45; Lua `os.time`
   silently normalizes. Strict mode needs explicit validation. Owner: Parse.

## 7. Deliverable format (every sub-blueprint)
Write to your assigned `docs/rewrite/NN-*.md`. Include:
1. **Scope** — which Go file(s)/behavior you own.
2. **Proposed Lua module(s)** — file path(s), public functions w/ signatures,
   data shapes (the Lua `Task` table shape), where they slot into the existing
   `lua/taskbuffer/` tree.
3. **Algorithm/port notes** — how each Go function maps to Lua; pseudocode for
   the tricky parts only.
4. **Latency analysis** — concrete: what's hot, expected cost, mitigation.
5. **Decisions to flag** — enumerated, each with a recommendation + rationale +
   alternatives. Mark anything needing the maintainer's call as **[DECISION]**.
6. **Edge cases** — enumerated, mapped to the Go test(s) that pin them.
7. **Test strategy** — how to verify parity (which Go tests port to busted/
   plenary; any golden-file approach).
8. **Open questions / risks.**

Keep it a *plan*. Pseudocode and signatures yes; full implementations no.
Be concrete and skeptical about latency. Cite Go file:line and test names.
