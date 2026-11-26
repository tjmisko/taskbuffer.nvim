# In-memory task index

Status: approved design, implementation plan. Decided 2026-11-26.

## Problem

Pressing `.` (or any task action) rapidly in the task list stalls. Every action
calls `buffer.refresh_and_restore_cursor()`, which forces a full pipeline run:
two `rg` subprocesses over every source, decoding, parsing every task,
frontmatter, formatting, and rewriting the whole buffer. At 10k tasks that is
~190 ms. While it runs, `buffer.validate_source` refuses every action
(`refreshing == true`), so keypresses are dropped with a "loading or stale"
warning. Every write also blocks on a `cp` subprocess (`source.write`).

Measured on this machine (nvim 0.12, warm page cache, 10k notes):

| Operation | Time |
|---|---|
| Lua `fs_scandir` walk of 10k files / 250 dirs | 3.6 ms |
| `rg --files` | 8.4 ms |
| read all 10k files in Lua | 36 ms |
| `fs_stat` every file (version sweep) | 19 ms |
| parse 10k tasks | ~60 ms |
| format 10k tasks | ~50 ms |

File I/O is cheap. The cost is redoing all parse/format work after each edit.

## Goals

- Every current user-visible behavior is kept: editing decentralized notes in
  place from the aggregate list, actions from inside notes, undo/redo, dot
  repeat, visual bulk actions, filters, markers, undated toggle, horizons, tag
  picker, code annotations, frontmatter projects/due/tags/status, the sync
  script APIs (`list.list`, `list.tags`, `buffer.refresh_taskfile`).
- An action from the task list updates the list synchronously, inside the
  keypress handler, so a typed-ahead `.` sees the updated rows. Target: < 5 ms
  per action at 10k tasks, no dropped keypresses.
- Disk writes happen in the background and never block input.
- No subprocesses at all in steady state: no `rg`, no `grep`, no `cp`.

## Non-goals

- OS threads (`vim.uv.new_thread`). Rejected: results cross threads only as
  strings, and decoding 10k tasks costs ~36 ms on the main thread, as much as
  parsing them there.
- File watchers. External changes are picked up by a version sweep.
- A persisted on-disk cache.
- Reflecting unsaved buffer contents in the list.

## Architecture

```
            first :Tasks                           BufEnter(list) / FocusGained
                 |                                          |
   walk.lua  ->  index.build (sliced)              index.sweep (stat all, reparse changed)
                 |                                          |
                 v                                          v
   +----------------------------- index.lua --------------------------------+
   |  files[path] = { version, data, tasks[], project_task, annotations }    |
   +--------------------------------------------------------------------------+
        ^  reparse one file from in-memory content                |
        |                                                          v
   source.lua overlay  <-  mutate / util / undo write via source.write
        |   (pending content + edit records per file)        view (format) -> buffer rows
        v
   writer.lua: per-file queue, async uv fs, rebase-on-conflict, revert on failure
```

### Modules

- **`walk.lua`** (new): pure-Lua discovery. Expands `sources` exactly as today
  (`scan.expand_globs` semantics: dirs recurse, files pass through, `*`/`?`
  globs expand, symlinked sources canonicalized and nested duplicates dropped).
  Recursion with `uv.fs_scandir`:
  - skips every entry whose name starts with `.` (files and dirs);
  - skips directories whose basename is in `config.exclude` (new option,
    default `{ "node_modules", "target", "dist", "build" }`);
  - does NOT honor .gitignore/.ignore (a deliberate change from the rg scan;
    users list ignored directory names in `exclude`);
  - does not follow symlinks found during recursion (rg's default today);
  - keeps files ending in `.md`, plus the extensions of configured
    `annotations` rules. Other extensions are not indexed (today rg reads every
    text file; restricting to `.md` + annotation extensions matches the
    existing grep fallback and is intended);
  - skips files whose first 8 KiB contain a NUL byte (binary).
  Provides a sync `walk(ctx)` and a sliced variant usable inside `async.run`.
- **`index.lua`** (new): the in-memory index.
  - `files[path] = { version, tasks, project_task, annotations, originals }`
    where `version` is the existing `source.version(path)` string.
  - `index.parse_file(path, data, ctx)`: split lines, find candidate lines by
    left-trimmed checkbox prefix (`ctx.checkboxes`) or, for annotation
    extensions, by `rule.pattern` (the `search` regex was an rg prefilter and
    is no longer used; keep accepting it in config). Parse with
    `parse.parse_task`, apply frontmatter from the same `data` (no second
    read; give `frontmatter.lua` a `parse_frontmatter_data(path, data)` entry
    and reuse it for tags/due/status/project), and build the project task if
    the file has a `- project` line. Per-file cost must be O(file size).
  - `index.build(ctx, cb)`: walk + read + parse every file in `async.run`
    slices (keeps the UI responsive), then publish. A sync `build_sync(ctx)`
    serves the script APIs.
  - `index.sweep(cb)`: stat every indexed path plus re-walk for new files;
    reparse only paths whose version changed; drop deleted paths. Runs on
    task-list `BufEnter` and `FocusGained` (only when an index exists).
  - `index.update_file(path, data)`: synchronous single-file reparse from
    in-memory content. Used after every action and on `BufWritePost` for any
    buffer whose path is indexed or lies under a source.
  - `index.tasks()` / `index.tags()` produce what `list.lua` consumes today.
  The index is built lazily on the first `:Tasks`; nothing at startup.
- **`list.lua`**: becomes a thin layer over the index: `view_async` renders from
  the index (building it first if needed); `list`/`tags` sync variants build
  synchronously. `scan.lua`'s rg/grep code is deleted (keep `expand_globs`,
  `deduplicate_paths` by moving them to `walk.lua`).
- **`source.lua` overlay**: in-memory pending contents.
  - Every `source.write(path, data)` outside `source.edit_buffer` no longer
    touches disk synchronously. It stores `overlay[path] = { base = <disk content and
    version when first overlaid>, data = <new content>, edits = <line edit
    records> }`, calls `index.update_file(path, data)`, and enqueues the path
    on the writer. `source.read(path)` returns `overlay[path].data` when
    present.
  - Edit records are derived by a line diff of previous overlay content vs new
    content: for each changed hunk, `{ line, old_lines, new_lines }`.
  - The in-note path (`source.edit_buffer`) is unchanged: it edits the buffer
    directly with native undo and never touches the overlay.
  - `source.check(path)` (dirty buffer refusal) is unchanged and still runs at
    keypress time.
- **`writer.lua`** (new): background persistence.
  - One queue per path, at most one write in flight per path. Edits arriving
    while a write is in flight are coalesced into the next write.
  - Write procedure, using async `uv.fs_*` callbacks only (never a blocking
    call or subprocess):
    1. read current disk content and version;
    2. if disk content equals `overlay.base`, the target is `overlay.data`;
       otherwise rebase each edit record onto the disk content: if the hunk's
       `old_lines` are still at `line`, apply there; else if they occur
       exactly once elsewhere in the file, apply there; else the record
       conflicts;
    3. write the target to a temp file beside the destination (resolve
       symlinks first so the link survives; refuse hard-linked sources as
       today), copy the mode with `uv.fs_fchmod`, copy `user.*` xattrs (see
       below), fsync-free close, `uv.fs_rename` over the destination;
    4. on success: drop the overlay (or keep only edits that arrived during
       the write), set the index entry to the new disk version, reload clean
       loaded buffers for that path (existing `reload`), flash nothing.
  - Conflicting records and failed writes revert: the in-memory change is
    rolled back (`index.update_file` with the rebased or original disk
    content), the matching undo entry is dropped, and one `vim.notify` WARN
    names the file and task text. Other files are unaffected; other records in
    the same batch still apply.
  - `writer.flush_sync()` drains everything synchronously; called from
    `VimLeavePre` so no edit is lost on quit, and available to tests.
- **xattr copy** (`xattr.lua`, new): LuaJIT FFI bindings for
  `listxattr`/`getxattr`/`setxattr` on Linux and their macOS signatures
  (extra `position`/`options` args). Copy only names starting with `user.`.
  Skip entirely when `listxattr` returns 0. If FFI or the call is unavailable,
  continue without xattrs (never fail the write for this). Runs inside the
  writer; it may be synchronous since it is a handful of syscalls only when
  attributes exist.
- **`buffer.lua`**: view publishing from the index.
  - After an action, `buffer.apply_local_change()` re-renders synchronously
    from the index and publishes in the same call stack. Cursor stays on the
    same row number (so `.` lands on the next task), clamped to the last line.
  - `validate_source` drops the `refreshing` gate. It checks: the row maps to a
    task in the current snapshot, no dirty buffer, the line in
    `source.read(path)` (overlay-aware) equals the row's original text.
  - Background re-renders (sweep found changes) keep the cursor on the same
    task by identity, as `publish` already does.
- **`undo.lua`**: unchanged entry shape (`{ filepath, linenumber, old_line,
  new_line }`). Undo/redo read and write through `source` (overlay-aware), so
  they are instant and go through the writer's conflict rules. Validation reads
  via `source.read`, not raw disk. The writer drops an undo entry whose edit
  was reverted.
- **Day rollover**: a timer fires at the next local midnight while a task list
  exists and re-renders (re-bucketing Today/Overdue) without touching disk.

### Task identity

A task is `(path, line_number)` plus its exact original line text. When a file
is reparsed, rows are re-associated by exact text, nearest line first.
Duplicates resolve to the nearest line.

### Incremental rendering

`format.format_view` is ~50 ms at 10k tasks, mostly per-task string building
and `vim.fn.strdisplaywidth` calls. Cache each task's rendered row text on the
parsed task object, keyed by the display options that affect it (markers, date
format). Only reparsed files produce new task objects, so an action re-renders
one task. Bucketing/sorting over cached rows must stay well under 5 ms at 10k
tasks; publish replaces only the changed line range with
`nvim_buf_set_lines` when the change is a removal/insert/replace of a few rows.

## Conflict rules (settled)

| # | Situation | Rule |
|---|---|---|
| R1 | Keypress | Sync gate: annotation rows and dirty source buffers are refused as today. A refused action never touches the view. |
| R2 | Gate passes | Index, row, and undo stack update immediately. Cursor stays on the same row number. |
| R3 | Write time | Disk unchanged since base: write. Changed: rebase each hunk; same line, else unique elsewhere, else conflict. |
| R4 | Conflict or write failure | Revert that change in memory, drop its undo entry, notify once. Other files unaffected. |
| R5 | Several edits, one file | Each hunk rebased independently; one conflict does not block the rest. |
| R6 | External change | Sweep on list enter / FocusGained reparses changed files; pending overlay edits still go through R3. |
| R7 | Clean source buffer open | Reload it after the write (existing behavior). |
| R8 | Undo/redo from the list | Same overlay + writer path; conflicts follow R3/R4. |
| R9 | Actions inside a note | Unchanged: direct buffer edit, native undo. |
| R10 | Write mechanics | Temp file + atomic rename, mode via `fs_fchmod`, `user.*` xattrs via FFI, symlink targets preserved, hard links refused. No subprocess. |

Dirty source buffers keep being refused. The index reflects disk plus our own
overlay, never unsaved buffers.

## Implementation steps

Each step lands as one or more atomic conventional commits on
`feat/in-memory-index`, with `make test` and `make lint` green.

### Step 1: replace the `cp` subprocess in `source.write`

Scope: `lua/taskbuffer/source.lua`, new `lua/taskbuffer/xattr.lua`, tests.
Still synchronous in this step (the writer arrives in step 3); only the `cp`
call is replaced by `uv.fs_fchmod` (mode from the original's stat) and the FFI
xattr copy. Timestamps are not preserved (the write resets mtime anyway);
ownership is left to the OS (no-op for files the user owns).

Tests (`tests/unit/source_spec.lua`):
- should keep mode bits when rewriting a 0600 note
- should keep `user.*` xattrs when the note has them (skip with a pending
  message when the filesystem rejects `setxattr`, e.g. tmpfs without
  `user_xattr`)
- should rewrite the symlink target and leave the link in place
- should not spawn any process during a write (wrap `vim.system`,
  `vim.fn.system`, `vim.fn.jobstart`, `uv.spawn` and assert zero calls)
- existing hard-link refusal and unwritable-file tests keep passing

### Step 2: in-memory index, Lua walk and reader

Scope: new `walk.lua`, `index.lua`; rewrite `list.lua` over the index; remove
rg/grep code from `scan.lua` (or delete the module and move path helpers to
`walk.lua`); `frontmatter.lua` gains data-based parsing; `config.lua` gains
`exclude`; `health.lua` stops requiring rg; README/doc/CLAUDE.md updated
(rg no longer required; `annotations.search` no longer used; `exclude`).
Behavior after this step: the list still refreshes fully after an action, but
from the index (reparse only changed files via version check) instead of a
rescan. Sweep on list `BufEnter` and `FocusGained`; `BufWritePost` reparses
one file.

Tests:
- unit `walk_spec`: hidden files/dirs skipped, `exclude` dirs skipped, symlinks
  inside sources not followed, globs and single-file sources, nested-source
  dedup, `.md` + annotation extensions only, binary files skipped
- unit `index_spec`: build parity with the old pipeline on every fixture vault
  under `tests/fixtures/vaults` (same rendered view text); `update_file`
  reparses only that file; sweep picks up modified, new, and deleted files;
  frontmatter tags/due/status/project from in-memory data
- replace `scan_spec` rg/grep argv tests with the walk tests; keep or port the
  pattern tests that still apply
- existing `list_spec`, `view_spec`, `annotations_spec`, `interaction_spec`
  keep passing

### Step 3: optimistic actions and background writer

Scope: `source.lua` overlay, new `writer.lua`, `buffer.lua` (sync local
publish, `validate_source` without `refreshing` gate), `util.run_task_cmd`,
`keymaps.lua` date shifts and bulk actions, `undo.lua`, `autocmds.lua`
(`VimLeavePre` flush). All list-originated mutations (complete, check, defer,
irrelevant, unset, start/stop markers, date shift, set today, bulk visual
variants, frontmatter due edits, undo, redo) go through the overlay and
publish synchronously.

Tests:
- E2E (real keypresses via `tests/helpers/editor.lua`, real files): should mark
  every task irrelevant when `.` is pressed 10+ times in one `nvim_input` call;
  no warnings; every source line correct after `writer` drains; cursor walked
  down the list
- E2E: should revert the row, drop the undo entry, and warn once when the
  write fails (read-only source directory or hard-linked source); other files
  in the same burst are written
- unit `writer_spec`: unchanged disk writes target; shifted lines rebase to the
  unique match; ambiguous or missing text conflicts and reverts; coalescing of
  edits during an in-flight write; `flush_sync` drains; multiple files in
  parallel
- unit: undo before the write lands leaves the original file content
- existing `undo_spec`, `dotrepeat_spec`, `interaction_spec`, `keymaps_spec`,
  `release_spec` keep passing (adapt waits: tests that read files must call
  `writer.flush_sync()` or wait for the writer)

### Step 4: incremental rendering and day rollover

Scope: `format.lua` (per-task row cache), `buffer.lua` (range publish),
midnight timer.

Tests:
- unit: rendered text identical to the full render for add/remove/change of
  one task across horizons, filters, markers, undated toggle
- unit: per-action local publish at 10k synthetic tasks under 5 ms (measure
  with `profile`; generous CI margin, e.g. assert < 20 ms)
- unit: midnight rollover moves a Today task to Overdue without disk reads
- update `scripts/benchmark.lua` with an action-latency scenario

## Rollout

Merge `feat/in-memory-index` into `main` after all four steps pass, push, and
update the lazy.nvim install.
