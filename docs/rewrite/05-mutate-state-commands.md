# 05 — Mutation + State + Command-Dispatch (Go → Lua)

> Sub-blueprint of the Go→Lua rewrite. Read `CONTEXT.md` first. This is a
> **plan**: signatures + pseudocode for tricky parts, not an implementation.

## 1. Scope

This blueprint owns the *action / write* side of the plugin — everything that
mutates `.md` files or the `current_task` state file, and the CLI subcommand
dispatch that drives them.

Go files owned:
- `go/mutate.go` (141) — `AppendToLine`, `CheckOffTask`/`CheckOffTaskWith`,
  `ChangeCheckbox`, `RemoveLastMarker`, `InsertAfterHeader`, `AppendToFile`.
- `go/state.go` (101) — `CurrentTask` read/write/clear, `resolveStateDir`,
  `statePathFor`, `FormatMarker`.
- `go/main.go` (695) command handlers only: `cmdDo` (233), `cmdStopWithConfig`
  (308), `cmdCompleteWithConfig` (338), `cmdCurrent` (371), `cmdDefer` (420),
  `cmdIrrelevant` (464), `cmdUnset` (486), `cmdCheck` (521), `cmdCompleteAt`
  (535), `cmdCreate` (555). (`cmdList`/`cmdTags` are owned by Scan/Format/Tags.)

Explicitly **out of scope but adjacent** (cited where they touch this layer):
the inline-due / marker regexes built in `parse.go:NewParseContext`
(143–154), the strftime→regex helper in `timeformat.go`, `buffer.lua` refresh,
`tags.lua`. I *consume* a strftime→pattern helper from the Parse blueprint
(see §3.4); I do not re-derive it.

Tests that pin this layer (the contract):
- `go/mutate_test.go`: `TestAppendToLine`, `TestAppendToLine_OutOfRange`,
  `TestCheckOffTask`, `TestCheckOffTask_IndentedTask`.
- `go/mutate_new_test.go`: `TestChangeCheckbox`, `TestRemoveLastMarker`,
  `TestRemoveLastMarker_MultipleMarkers`, `TestInsertAfterHeader`,
  `TestInsertAfterHeader_CreatesFile`, `TestAppendToFile`,
  `TestAppendToFile_CreatesFile`, `TestCmdDefer`, `TestCmdDefer_PreservesOriginal`,
  `TestCmdIrrelevant`, `TestCmdUnset_Irrelevant`, `TestCmdCreate_AppendToFile`,
  `TestCmdCreate_InsertAfterHeader`.
- `go/state_test.go`: `TestWriteAndReadCurrentTask`, `TestReadCurrentTask_NoFile`,
  `TestClearCurrentTask`, `TestClearCurrentTask_NoFile`.

---

## 2. Proposed Lua modules

Three new modules + targeted rewires of two existing ones. Layered so the verb
layer (`actions`) never touches disk directly — it composes `mutate` + `state`.

```
lua/taskbuffer/
  mutate.lua    NEW  — file-line primitives (port of mutate.go)
  state.lua     NEW  — current_task + marker formatter (port of state.go)
  actions.lua   NEW  — verb layer (port of main.go cmd* handlers)
  util.lua      EDIT — delegate its file-IO primitives to mutate.lua
  keymaps.lua   EDIT — verbs call actions.* directly; start_task calls actions.start
  commands.lua  EDIT — register :TasksDo/:TasksStop/:TasksComplete/:TasksCurrent/:TasksCreate
  config.lua    EDIT — drop task_bin / source_args / config_json_arg (other blueprints)
  tags.lua, buffer.lua, health.lua — touched by other blueprints; flagged in §8
```

### 2.1 `mutate.lua` — file-line primitives

All functions return `ok:boolean, err:string|nil` (mirrors Go's `error`
return). They do **read-modify-write on disk** via the shared helpers
`read_all_lines`/`write_all_lines` (which preserve trailing-newline state — see
§3.1) unless the buffer-aware path is adopted (§5 [DECISION B]).

```lua
---@param path string
---@return string[] lines, boolean had_trailing_nl  -- nil,_ ,err on read failure
function M.read_all_lines(path)

---@param path string
---@param lines string[]
---@param had_trailing_nl boolean
---@return boolean ok, string|nil err
function M.write_all_lines(path, lines, had_trailing_nl)

-- AppendToLine (mutate.go:11). Trims right whitespace of the target line, then
-- appends " " .. text. text is the already-formatted marker (may end in space).
---@param path string, lnum integer, text string -> ok, err
function M.append_to_line(path, lnum, text)

-- ChangeCheckbox (mutate.go:36). First-occurrence plain replace of `from`->`to`.
-- Errors if from=="" or to=="" (mutate.go:37-42).
---@param path string, lnum integer, from string, to string -> ok, err
function M.change_checkbox(path, lnum, from, to)

-- RemoveLastMarker (mutate.go:57). Removes the LAST `::kind [[DATE]] [TIME]`.
-- Uses vim.regex (see §3.4). No-op (ok=true) if no match.
---@param path string, lnum integer, kind string -> ok, err
function M.remove_last_marker(path, lnum, kind)

-- InsertAfterHeader (mutate.go:87). Insert text on the line after a header
-- (TrimSpace equality). Header-not-found -> append "\n"+header+"\n"+text+"\n".
-- File-missing -> create with header+"\n"+text+"\n".
---@param path string, header string, text string -> ok, err
function M.insert_after_header(path, header, text)

-- AppendToFile (mutate.go:126). Append text+"\n"; create file if missing.
---@param path string, text string -> ok, err
function M.append_to_file(path, text)
```

`read_line_from_file`/`replace_line_in_file`/`append_to_line` currently in
`util.lua` (18, 33, 58) become thin wrappers that delegate here, so there is
**one** file-IO implementation (eliminates the trailing-newline divergence in
§3.1 across the codebase). The date-shift code in `keymaps.lua`/`util.lua`
keeps calling `util.replace_line_in_file`, now backed by `mutate`.

### 2.2 `state.lua` — current_task + canonical marker

Port of `state.go`. Config-driven (reads `config.values.state_dir` directly —
no `--config` boundary, per CONTEXT §4).

```lua
---@class CurrentTask
---@field start_time integer  -- unix seconds
---@field name string         -- task body
---@field filepath string
---@field linenumber integer

-- statePathFor (state.go:32). state_dir already ~-expanded by config.apply.
---@return string
function M.state_path()         -- joinpath(config.values.state_dir, "current_task")

-- ReadCurrentTaskFrom (state.go:45). nil,nil when file missing; nil,err when malformed.
---@return CurrentTask|nil, string|nil
function M.read_current()

-- WriteCurrentTaskTo (state.go:78). mkdir -p parent; write "ts\tname\tpath\tlnum\n".
---@param ct CurrentTask -> ok, err
function M.write_current(ct)

-- ClearCurrentTaskFrom (state.go:91). Remove file; missing -> ok (no error).
---@return boolean ok, string|nil err
function M.clear_current()

-- FormatMarker (state.go:99). CANONICAL marker formatter (see §3.3, [DECISION C]).
-- when defaults to os.time().
---@param kind string, when integer|nil -> string  -- "::kind [[DATE]] TIME "
function M.format_marker(kind, when)
```

### 2.3 `actions.lua` — verb layer

One public function per CLI subcommand. Each accepts an optional `when` (unix
seconds) for deterministic tests — mirrors how Go threads `now time.Time`
explicitly into `FormatMarker`/`cmd*`. Each returns `ok:boolean` and notifies on
error; callers decide whether to reload/refresh.

```lua
-- cmdCompleteAt (main.go:535): append ::complete marker, then open->done checkbox.
function M.complete_at(filepath, linenumber, when)         -- ok

-- cmdDefer (main.go:420): copy inline due as ::original if absent, append ::deferral.
function M.defer(filepath, linenumber, when)               -- ok

-- cmdIrrelevant (main.go:464): open->irrelevant checkbox + ::irrelevant marker.
function M.irrelevant(filepath, linenumber, when)          -- ok

-- cmdUnset (main.go:486): if ::irrelevant present, remove last marker + irrelevant->open.
function M.unset(filepath, linenumber)                     -- ok

-- cmdCheck (main.go:521): open->done checkbox only, no marker.
function M.check(filepath, linenumber)                     -- ok

-- cmdCompleteWithConfig (main.go:338): read current_task, append ::complete,
-- open->done, clear state. No-op + notify if nothing running.
function M.complete_current(when)                          -- ok

-- cmdStopWithConfig (main.go:308): read current_task, append ::stop, clear state.
function M.stop(when)                                      -- ok

-- start: combines keymaps.lua start_task + cmdDo's start half. If a task is
-- running, stop() it first (replaces os.execute(task_bin.." stop")). Append
-- ::start marker, write state. `body` is the task name for state (see §3.6).
function M.start(filepath, linenumber, body, when)         -- ok

-- cmdDo (main.go:233): TODAY's open tasks -> native picker -> start (ASYNC; see [DECISION A]).
function M.do_pick()                                       -- (async, callback-driven)

-- cmdCurrent (main.go:371): return current task name or nil. Caller prints/echoes.
function M.current()                                       -- string|nil

-- cmdCreate (main.go:555): resolve target file + header from opts/inbox config,
-- mkdir parent, insert_after_header or append_to_file.
---@param opts { body:string, file?:string, header?:string } -> ok
function M.create(opts)                                    -- ok
```

---

## 3. Algorithm / port notes

### 3.1 File IO + trailing-newline / CRLF parity (the subtle part)

Go's read-modify-write idiom across `mutate.go`/`main.go:cmdDefer`:
`lines = strings.Split(data, "\n")` … `os.WriteFile(Join(lines, "\n"), 0644)`.
Because `Split` on a file ending in `\n` yields a trailing empty element, and
`Join` restores it, **Go preserves the original trailing-newline state exactly**
(file with no final `\n` stays without one — see `TestAppendToFile`
`mutate_new_test.go:114` which asserts via `TrimRight`).

The current Lua (`util.lua:44-51`, `:68-75`) reads with `io.lines` (which never
yields the trailing empty element) and then writes
`table.concat(lines,"\n") .. "\n"` — i.e. it **always force-appends `\n`**. For
a file *without* a final newline this *adds* one. Divergence from Go.

Port rule for `mutate.read_all_lines` / `write_all_lines`:
```
data = read whole file
had_trailing_nl = data:sub(-1) == "\n"
lines = vim.split(data, "\n", { plain = true })   -- matches strings.Split
if had_trailing_nl then lines[#lines]=="" ; drop it for editing, re-add on write
write: table.concat(lines, "\n") .. (had_trailing_nl and "\n" or "")
```
This reproduces Go's split/join byte-for-byte. **CRLF:** Go's `Split("\n")`
leaves a trailing `\r` on each line and `TrimRight(line, " \t")` does *not*
strip `\r`, so on a CRLF file Go appends markers *after* the `\r`
(`"text\r ::marker"`). `vim.split` behaves identically. To match Go exactly,
keep `\r`. (See §5 [DECISION D] for an optional correctness improvement.)
No Go test exercises CRLF; notes are LF in practice.

Writing uses `vim.fn.writefile`/`io.open(...,"w")`; permission `0644` is the
default for `io.open` on Linux, matching Go's `os.WriteFile(...,0644)`.

### 3.2 `append_to_line`, `change_checkbox` (plain, not pattern)

- `append_to_line`: `line = line:gsub("[ \t]+$","")` then `line = line.." "..text`.
  `text` is the pre-formatted marker, which **already ends in a trailing space**
  (§3.3). Do not strip it — `TestAppendToLine` (`mutate_test.go:9`) asserts the
  result keeps the trailing space:
  `"line two ::start [[2026-02-17]] 15:00 "`.
- `change_checkbox`: must replace the **first** occurrence only and treat
  `from`/`to` as **literals** (they contain `[` `]`). Use plain find+splice, not
  `gsub` (Lua patterns + `%`-escaping in replacement are a trap here):
  ```
  local s, e = line:find(from, 1, true)   -- plain
  if not s then return ok end             -- Go's Replace(...,1) is a no-op if absent
  line = line:sub(1, s-1) .. to .. line:sub(e+1)
  ```
  Indentation is preserved because the replace is positional, not anchored —
  `TestCheckOffTask_IndentedTask` (`mutate_test.go:65`). Empty `from`/`to` →
  error (`mutate.go:37-42`).

### 3.3 Canonical marker — exact spacing

`FormatMarker` (`state.go:99-101`):
`fmt.Sprintf("::%-s [[%s]] %s ", kind, date, time)`. `%-s` == `%s` (no width),
so the literal shape is:
```
"::" .. kind .. " [[" .. date .. "]] " .. time .. " "        -- note TRAILING space
```
`state.format_marker(kind, when)` reproduces this, with one deliberate change
(see §5 [DECISION C]): it uses `config.values.formats.marker_prefix` (default
`"::"`) instead of Go's hardcoded `"::"`. For default config the bytes are
identical. The `::start` suffix that `keymaps.lua:413-414` builds by hand
(`" " .. marker_prefix .. "start [[" .. date .. "]] " .. time`, *no* trailing
space) is **deleted** — `actions.start` routes through
`mutate.append_to_line(file, line, state.format_marker("start", when))`, giving
the same result as Go's `cmdDo` (`main.go:289-291`). One canonical formatter, one
append path.

`cmdDefer`'s `::original` marker is *not* `FormatMarker` — it is
`fmt.Sprintf(" ::original [[%s]]", date)` (`main.go:451`): leading space, the
**date only**, no time, **no** trailing space. Keep that as a separate inline
string in `actions.defer` (prefix-aware: `" "..marker_prefix.."original [["..date.."]]"`).

### 3.4 `remove_last_marker` — vim.regex, last match (the only hard port)

Go (`mutate.go:69`):
`pattern = \s*::<kind>\s+\[\[<DateRe>\]\]\s*(<TimeRe>)?`, find **all** matches,
remove the **last**. Two things defeat Lua patterns: the optional time group
`(...)?` and config-driven `{4}`/`{2}` quantifiers. **Use `vim.regex`** (Vim
engine: supports `\?`, `\{4}`, `\(...\)`, `\s\+`).

Coordination with Parse blueprint: I consume two helpers that emit **Vim-regex**
fragments for the configured date/time formats — call them
`timefmt.date_vim_re()` and `timefmt.time_vim_re()` (the Vim-syntax analogue of
Go's `StrftimeToRegex`, `timeformat.go:52`). Defaults: `\d\d\d\d-\d\d-\d\d` and
`\d\d:\d\d`. If the Parse blueprint only exposes Lua-pattern or RE2-style
fragments, I add a tiny local adapter (`\d{4}` → `\d\d\d\d`); flagged in §8.

Pattern (very-nomagic-ish, built with the configured `marker_prefix`):
```
local re = vim.regex(
  [[\s*]] .. vim.fn.escape(marker_prefix, [[\]]) .. vim.pesc_vim(kind)
       .. [[\s\+\[\[]] .. date_vim_re .. [[\]\]\s*\%(]] .. time_vim_re .. [[\)\?]])
```
Finding the **last** match (vim.regex only reports the first via `match_str`):
```
local last_s, last_e
local base = 0
while true do
  local s, e = re:match_str(line:sub(base + 1))   -- byte offsets, 0-indexed, in the slice
  if not s then break end
  last_s, last_e = base + s, base + e
  base = base + e                                  -- advance past this match
  if e == s then base = base + 1 end               -- guard zero-width
end
if not last_s then return true end                 -- no marker -> no-op (mutate.go:74)
line = line:sub(1, last_s) .. line:sub(last_e + 1)
line = line:gsub("[ \t]+$", "")                    -- mutate.go:80 TrimRight
```
Crucially the pattern requires `marker_prefix .. kind`, so the inline due
`(@[[...]])` is never eaten — `TestRemoveLastMarker` (`mutate_new_test.go:30`)
asserts `(@[[2026-02-17]])` survives. `TestRemoveLastMarker_MultipleMarkers`
(`:50`) asserts the first `::irrelevant` stays and only the last is removed.

### 3.5 Verb composition (main.go handlers → actions)

- `complete_at` (`main.go:535`): `append_to_line(complete marker)` →
  `change_checkbox(open→done)`. `TestCmdCreate`... actually pinned indirectly;
  matches `cmdCompleteAt`.
- `defer` (`main.go:420`): read line; if `not line:find(marker_prefix.."original",1,true)`
  then extract inline due date (consume Parse's inline-due matcher,
  `parse.inline_due(line) -> date_str|nil`, equivalent to `ctx.dateRe`
  submatch[1] incl. wikilink-alias stripping `parse.go:143`) and append
  `" "..prefix.."original [["..date.."]]"`; then append
  `" "..format_marker("deferral", when)`. Single read-modify-write of the line.
  `TestCmdDefer` (`mutate_new_test.go:145`), `TestCmdDefer_PreservesOriginal`
  (`:165`).
- `irrelevant` (`main.go:464`): `change_checkbox(open→irrelevant)` →
  `append_to_line(::irrelevant marker)`. `TestCmdIrrelevant` (`:187`).
- `unset` (`main.go:486`): read line; if `line:find(prefix.."irrelevant",1,true)`
  then `remove_last_marker("irrelevant")` → `change_checkbox(irrelevant→open)`;
  else no-op. `TestCmdUnset_Irrelevant` (`:207`).
- `check` (`main.go:521`): `change_checkbox(open→done)`.
- `complete_current`/`stop` (`main.go:338`/`308`): `read_current()`; if nil →
  notify "No task running" + ok; else append marker (`complete`/`stop`),
  (complete only) `change_checkbox(open→done)`, `clear_current()`, notify.
- `current` (`main.go:371`): `read_current()` → `ct and ct.name or nil`.

> Optimization note: Go does each checkbox-change and marker-append as a
> *separate* full file read-write (e.g. `cmdIrrelevant` writes twice). Lua can
> do **one** read-modify-write touching both the checkbox and the line tail —
> the result is byte-identical because the two edits are disjoint regions. I
> recommend the single-pass form in `actions` (call a `mutate.edit_line(path,
> lnum, fn)` that applies an in-memory transform). Keep the granular
> `mutate.change_checkbox`/`append_to_line` for the direct unit tests.

### 3.6 `start` body / `do_pick`

`cmdDo` (`main.go:233-306`): stop any running task, scan today's open tasks,
fzf-pick, append `::start`, write state with `name = task.Body` (the *parsed*
body). The existing `keymaps.lua` `start_task` instead scrapes the body out of
the **taskfile display line** (`keymaps.lua:400-404`) because it had no parsed
Task. With the Lua rewrite the picker (`do_pick`) has real `Task` objects so it
writes the true body. For the taskfile keymap path, `actions.start(file, line,
body)` takes `body` from the Integration blueprint's line→Task side table when
available; if absent it falls back to the display-scrape. `name` only affects
`current`'s printout and the state file's display column — it never drives the
marker writes (those use filepath+linenumber), so a slightly different body is
cosmetic, not a correctness regression.

`do_pick` flow (async, see [DECISION A]):
```
if read_current() then stop() end
tasks = <scan+parse today's open tasks>     -- owned by Scan/Parse; today == os.date(date_fmt)
if #tasks == 0 then notify "No tasks due today" return end
vim.ui.select(tasks, { format_item = function(t) return t.body end }, function(choice)
  if not choice then return end             -- cancel == Go's "No task selected"
  M.start(choice.filepath, choice.linenumber, choice.body)
end)
```

### 3.7 `create` (main.go:555)

```
body  = opts.body                              -- error if empty (main.go:567)
file  = opts.file  or config.values.inbox.file -- error if both empty (main.go:578)
file  = expand(file)                           -- ~ already expanded by config for inbox
mkdir parent of file (vim.fn.mkdir(dir,"p"))   -- main.go:584-587
header = opts.header or config.values.inbox.header
line   = config.values.formats.checkbox.open .. " " .. body
if header and header ~= "" then mutate.insert_after_header(file, header, line)
else mutate.append_to_file(file, line) end
```
`TestCmdCreate_AppendToFile` (`mutate_new_test.go:227`),
`TestCmdCreate_InsertAfterHeader` (`:244`). Note config exposes
`inbox = { file, header }` (`config.lua:103`), matching the
`--inbox-file`/`--inbox-header` flags Go received.

### 3.8 State file format / path (state.go)

`write_current`: `mkdir -p dirname(state_path())`; write
`("%d\t%s\t%s\t%d\n"):format(start_time, name, filepath, linenumber)` — **with
trailing newline** (`state.go:83`). The current `keymaps.lua:410` writes the
4-field TSV **without** the trailing `\n`; `read_current` (like Go,
`state.go:53`) trims `\n\r` so both parse, but `write_current` should emit the
`\n` for byte-parity with `TestWriteAndReadCurrentTask` (`state_test.go:9`).
`read_current`: open file → missing (`vim.uv.fs_stat` nil / open fails with
ENOENT) → `nil, nil`; else `vim.split(trimmed, "\t")` with the **4th field
greedy** (Go uses `SplitN(line,"\t",4)` so a name containing a tab is impossible
but a *path* could in theory contain tabs — keep 4-field semantics: first three
splits, rest is linenumber). Validate `#parts == 4`, `tonumber(parts[1])`,
`tonumber(parts[4])`; else `nil, "malformed current_task"`.

---

## 4. Latency analysis

Mutations here are **single-file, single-line, no scan** — `cmdDefer`,
`cmdIrrelevant`, `cmdUnset`, `cmdCheck`, `cmdCompleteAt`, `cmdStop`,
`cmdComplete`, `cmdCurrent` never invoke `rg`; they read/write one small `.md`.
The actual work (read a few KB, splice one line, write) is **sub-millisecond** in
both Go and Lua.

What we shed is **process-spawn latency**, which today dominates each verb:
- Every verb currently goes through `util.run_task_cmd` →
  `vim.system({task_bin, ...}):wait()` (a synchronous fork/exec), or
  `os.execute(task_bin.." stop")` for start's implicit stop
  (`keymaps.lua:390`). Fork/exec + dynamic-linker + Go runtime bootstrap is
  typically **~3–15 ms** per call (more on a cold page cache / slow disk; the
  Go binary is statically-ish but still pays runtime init). `os.execute` adds a
  `/bin/sh -c` layer on top.
- In-Lua, the verb is a function call doing one `read`/`write` syscall pair:
  realistically **< 0.5 ms**, with **zero** process spawn.

So each verb gets ~**3–15 ms faster** and, more importantly, becomes *synchronous
and jank-free* on the UI thread (no `:wait()` stalling redraw). `do_pick` sheds
**two** spawns (the `task do` process *and* `fzf`); the remaining cost there is
the scan, owned by the Scan/Parse blueprints. The build step (`go build`)
disappears entirely. Net: pure latency win, no latency risk introduced by this
layer (the only new cost is `vim.regex` compilation in `remove_last_marker`,
which is µs-scale and only on `unset`).

---

## 5. Decisions to flag

**[DECISION A] fzf picker → `vim.ui.select` (drop the fzf dependency).**
`cmdDo` (`main.go:271`) shells out to `fzf` — the *only* place fzf is used, so
it is a hard external dep that exists solely for `do`. Recommend replacing it
with `vim.ui.select`, which is built-in, requires no dependency, and
automatically uses whatever picker UI the user has installed (telescope,
dressing.nvim, fzf-lua, snacks) or the plain numbered prompt otherwise.
Telescope is already an *optional* dep (tag picker); routing `do` through
telescope directly would make it a second optional path — `vim.ui.select` is
strictly simpler and dependency-free. Consequence: `do_pick` becomes
**async/callback-driven** (the start action runs in the select callback), which
is fine since `do` is interactive. *Alternative:* keep fzf via `vim.system` for
users who prefer it — rejected (re-introduces the dep we are trying to shed).

**[DECISION B] File-write safety: buffer-aware mutation vs disk + `:edit!`.**
Today every verb writes the file on disk and then the caller does `vim.cmd("edit!")`
(`keymaps.lua:352` etc.) or `buffer.refresh_and_restore_cursor()` →
`vim.cmd("edit!")` (`buffer.lua:62`). Two hazards:
  1. **Global verbs operate on the current buffer** (a markdown file the user is
     editing). Writing disk then `:edit!` **silently discards unsaved buffer
     edits**.
  2. **Taskfile verbs operate on a *source* `.md` that may be open in another
     window/buffer.** Disk write makes that buffer stale; a later `:w` there
     clobbers the marker.
Recommendation: give `mutate` a **buffer-aware** path. Before disk
read-modify-write, `bufnr = vim.fn.bufnr(vim.uv.fs_realpath(path) or path)`; if
the file is loaded *and* modifiable, mutate via `nvim_buf_set_lines` +
`vim.api.nvim_buf_call(bufnr, function() vim.cmd("update") end)` (preserves undo
history, no silent discard); otherwise do the disk path. This is the single
consistent approach for both call sites. *Minimum viable alternative* if the
buffer-API path is deferred: before `:edit!`, check `vim.bo.modified` and
**warn/abort** instead of silently reloading. **This is the top risk in §8.**

**[DECISION C] One canonical marker formatter, using the configured prefix.**
Go's `FormatMarker` hardcodes `"::"` (`state.go:100`) and `cmdDefer` hardcodes
`"::original"`/`"::original"` checks (`main.go:447,451`), while *parsing* respects
the configurable `marker_prefix` (`parse.go:146-154`). That is an internal Go
inconsistency that only bites when `marker_prefix` is customized. Recommend the
canonical `state.format_marker` (and defer's `::original`, and unset's
`Contains` check) all use `config.values.formats.marker_prefix`. For the default
`"::"` the output is byte-identical to Go (all the `Test*` golden strings hold);
for a custom prefix the Lua behavior is the *correct* one (formatter agrees with
parser). Flag for maintainer sign-off since it is a deliberate
behavior-improvement over Go.

**[DECISION D] CRLF handling.** Match Go exactly (keep `\r`, marker lands after
it) for strict parity, OR strip a trailing `\r` in the `append_to_line`
right-trim for correctness on the rare CRLF note. Recommend **match Go** now
(no CRLF test exists; lowest risk), and leave a TODO for the `\r`-stripping
improvement. Flag.

**[DECISION E] Expose the verbs as `:` commands (and `create`).** The Go binary
double-served as (a) the plugin backend and (b) a standalone shell CLI
(`task do`, `task stop`, `task current` — e.g. from a statusline). Removing it
deletes the shell entry points. Within nvim, recommend registering
`:TasksDo` → `actions.do_pick`, `:TasksStop` → `actions.stop`,
`:TasksComplete` → `actions.complete_current`, `:TasksCurrent` →
`actions.current` (echo), and a **new** `:TasksCreate {body}` →
`actions.create{ body = <args> }` (wires up the existing-but-unused `inbox`
config + `cmdCreate`). The lost *shell* CLI is a maintainer call — see §8.

---

## 6. Edge cases → tests

| Edge case | Behavior (Go ref) | Pinning test |
|---|---|---|
| Line number out of range | error, no write | `TestAppendToLine_OutOfRange` (mutate_test.go:33) — also assert change_checkbox/remove_last_marker guard `idx` (mutate.go:18,49,64) |
| Append keeps marker's trailing space | `"…15:00 "` | `TestAppendToLine` (mutate_test.go:9) |
| Indented checkbox change | indentation preserved, positional replace | `TestCheckOffTask_IndentedTask` (mutate_test.go:65) |
| First-occurrence checkbox replace only | line 2 untouched | `TestChangeCheckbox` (mutate_new_test.go:10), `TestCheckOffTask` (mutate_test.go:44) |
| Empty checkbox `from`/`to` | error | `mutate.go:37-42` (no direct test; add Lua unit test) |
| Marker removal when absent | no-op, ok | `mutate.go:74`; covered via `cmdUnset` no-marker branch (main.go:518) |
| Remove LAST of multiple markers | first stays, last gone | `TestRemoveLastMarker_MultipleMarkers` (mutate_new_test.go:50) |
| Remove marker doesn't eat inline due `(@[[…]])` | preserved | `TestRemoveLastMarker` (mutate_new_test.go:30) |
| Header found → insert after | new task on header+1 | `TestInsertAfterHeader` (mutate_new_test.go:72), `TestCmdCreate_InsertAfterHeader` (:244) |
| Header not found → append header+text | appended block | `mutate.go:105-113` (assert via Lua unit test) |
| File missing → InsertAfterHeader/AppendToFile create it | created | `TestInsertAfterHeader_CreatesFile` (:95), `TestAppendToFile_CreatesFile` (:130) |
| Missing trailing newline preserved | no spurious `\n` | `TestAppendToFile` (mutate_new_test.go:114) — and §3.1 (current util.lua regresses this) |
| CRLF | marker after `\r` (Go parity) | none (see [DECISION D]) |
| Defer with no existing `::original` | copies inline due as `::original`, adds `::deferral` | `TestCmdDefer` (mutate_new_test.go:145) |
| Defer preserves existing `::original` | exactly one `::original`, original date kept | `TestCmdDefer_PreservesOriginal` (:165) |
| Defer with no inline date | skip `::original`, still add `::deferral` | `main.go:447-454` (add Lua unit test) |
| Irrelevant: `[ ]`→`[-]` + marker | both applied | `TestCmdIrrelevant` (mutate_new_test.go:187) |
| Unset: remove marker + `[-]`→`[ ]`; no-op if no marker | restored | `TestCmdUnset_Irrelevant` (:207); no-op branch `main.go:518` |
| State write/read round-trip (TSV, 4 fields) | exact | `TestWriteAndReadCurrentTask` (state_test.go:9) |
| State file missing | read → nil,nil | `TestReadCurrentTask_NoFile` (state_test.go:46) |
| State malformed (<4 fields / bad ts / bad lnum) | error | `state.go:55-65` (add Lua unit test) |
| Clear when missing | ok, no error | `TestClearCurrentTask_NoFile` (state_test.go:79) |
| Clear existing | file gone | `TestClearCurrentTask` (state_test.go:59) |
| stop/complete/current with nothing running | "No task running" / nil, ok | `main.go:316,346,376` |

---

## 7. Test strategy

- **Port the Go tests 1:1 to busted/plenary** against `mutate.lua`/`state.lua`/
  `actions.lua`. Each uses a temp dir + a stubbed `config.values` (override
  `formats.checkbox`, `formats.marker_prefix`, `state_dir`). Tests write fixture
  files with `vim.fn.writefile`, run the function, read back, assert
  **byte-exact** lines — the Go `want` strings transfer verbatim (e.g.
  `"line two ::start [[2026-02-17]] 15:00 "`).
- **Determinism:** thread `when` (unix seconds) into every marker-producing
  action (mirrors Go passing `now time.Time`), so golden assertions don't depend
  on wall-clock. State tests set `config.values.state_dir` to a temp dir instead
  of Go's `t.Setenv("HOME", …)`.
- **Picker:** make `do_pick`'s selector injectable (`M._select = vim.ui.select`)
  so a test can stub the choice and assert the resulting `::start` + state write,
  decoupled from UI.
- **`vim.regex`** needs a real nvim runtime, so the `remove_last_marker`/marker
  suites run under `nvim --headless` + plenary (busted-in-nvim), not bare
  busted. Flag in §8.
- **Golden round-trip:** reuse the Go test fixtures as on-disk goldens; a small
  harness can diff Lua output against the committed Go `want` strings to catch
  drift during the port.

---

## 8. Open questions / risks

1. **[TOP RISK] Open-buffer / unsaved-changes corruption** (see [DECISION B]).
   The current disk-write + `:edit!` flow silently discards unsaved edits in the
   current buffer and staleness-races other windows holding the same source file.
   The buffer-aware mutate path fixes it but adds the most implementation
   surface in this layer. Needs maintainer agreement on the approach before
   coding.
2. **Lost shell CLI** (see [DECISION E]). If the user invokes `task current` /
   `task do` from a shell, tmux, or statusline, those vanish with the binary.
   Mitigation options: accept nvim-only; or ship a tiny `nvim --headless -c
   'lua require("taskbuffer.actions").current()'` shim. Maintainer call.
3. **Parse-blueprint coupling.** `remove_last_marker` needs Vim-regex date/time
   fragments and `defer` needs the inline-due matcher (`parse.go:143` incl.
   wikilink-alias stripping). If Parse exposes only Lua-pattern/RE2 fragments I
   add a thin adapter. Confirm the exact helper names/shapes with the Parse
   blueprint (proposed: `timefmt.date_vim_re()`, `timefmt.time_vim_re()`,
   `parse.inline_due(line)`).
4. **`vim.regex` in CI.** Marker-removal tests require an nvim runtime; CI must
   run busted-under-nvim/plenary, not plain LuaJIT busted.
5. **`start` body source.** Depends on the Integration blueprint's line→Task side
   table; until that exists, `actions.start` falls back to the fragile
   display-line scrape (`keymaps.lua:400-404`). Cosmetic only (affects `current`
   display + state name column), but worth confirming.
6. **`marker_prefix` divergence from Go** (see [DECISION C]) — needs sign-off
   since it intentionally differs from Go for non-default prefixes.
