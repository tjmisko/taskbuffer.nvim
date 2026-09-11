# Measuring taskbuffer performance

Measure startup separately from task operations. Loading the plugin registers
commands; `setup()` applies configuration and registers lazy keymaps/autocmds.
Neither loads the scan/list pipeline, reads task files, spawns a process, or
starts a background timer. Keymap actions load when used; opening a normal
markdown file only installs three lazy date shortcuts. Help tags are generated
by plugin managers; run `make helptags` for a development checkout.

## Record a session

```vim
:TasksProfile start
:Tasks
" Switch away and back, toggle filters/markers, and repeat the slow action.
:TasksProfile stop
```

`stop` stops recording and displays the report. Use `:TasksProfile report` to
display it again, or `:messages` to review it. `start` starts a fresh session;
`reset` clears results and preserves whether recording is active. The default
action for `:TasksProfile` is `report`.

To include `setup()` in a recording, put this **before** loading/configuring
taskbuffer, then use `:TasksProfile stop` after reproducing the issue:

```lua
vim.g.taskbuffer_profile = true
```

With lazy.nvim command loading, include `"TasksProfile"` in the plugin's `cmd`
list so recording can start before the first `:Tasks`. The global flag captures
setup when the plugin loads; use `--startuptime` below for module loading costs.

Recording is off by default. Disabled timing hooks do not read the clock or
allocate samples, and the delay probe has no running timer. Enabled recording
keeps at most 256 durations per stage in memory. It stores stage names and
durations, without source paths or task contents, and writes no log files.

To inspect or export a report programmatically:

```lua
local profile = require("taskbuffer.profile")
vim.print(profile.snapshot())
-- Optional: save to a location you choose.
vim.fn.writefile({ vim.json.encode(profile.snapshot()) }, "/tmp/taskbuffer-profile.json")
```

## Interpret the report

All durations are wall-clock milliseconds. Count, total, mean, and max cover the
whole recording; p95 uses the latest 256 samples. With only a few samples, p95
will usually equal max. Timings are inclusive and overlap: **do not sum rows**.

| Stage | What it measures |
| --- | --- |
| `setup`, `setup.*` | Configuration and lazy entry-point registration |
| `tasks.command` | Time until `:Tasks` returns, before scanning and rendering |
| `refresh.async.wall` | Complete refresh through writing and publishing the result |
| `list.async.wall` | Discovery, source processing, and formatting, including yields |
| `scan.paths` | Glob expansion and path deduplication |
| `scan.process.async`, `scan.projects.async` | Concurrent task/project subprocesses |
| `scan.decode` | Converting scan output into Lua matches, including yields |
| `scan.schedule_delay` | Delay from queueing scan processing to running it |
| `sources.check` | Relevant-file metadata collection for snapshot reuse |
| `tasks.build`, `render` | Source processing and display formatting, including yields |
| `parse`, `frontmatter.*`, `format` | Individual processing stages, including yields |
| `async.slice` | Actual uninterrupted CPU work between cooperative yields |
| `taskfile.write`, `taskfile.publish` | Writing output and updating its target buffer |
| `refresh.request`, `tags.async.wall` | Action refresh dispatch and tag queries |
| `event_loop.delay` | Editor-wide scheduling delay above the probe's 20 ms interval |

A long async wall time alone does not mean input was blocked. Processing stages
can now yield, so use **`async.slice` and `event_loop.delay`** to evaluate stalls.
The delay probe includes other plugins, OS scheduling, and pauses while the
editor is suspended; it cannot attribute a stall to taskbuffer. It can also miss
stalls shorter than its polling interval. Reproduce with only taskbuffer enabled
to establish attribution.

As initial investigation targets, aim for a startup delta of a few milliseconds
and main-thread work below roughly 16 ms per turn. Investigate repeated delays
above 16 ms and individual stalls above 50 ms. These are working budgets, not
portable pass/fail thresholds; compare the same machine, workload, and version.

## Compare startup

Neovim's [`--startuptime`](https://neovim.io/doc/user/starting/#--startuptime)
records config, plugin, and first-buffer loading. Run your usual configuration
with taskbuffer enabled and disabled, using a new log filename for each launch
(Neovim appends to existing logs):

```bash
nvim --startuptime /tmp/nvim-with-taskbuffer.log
```

Repeat launches and compare medians. Include opening a markdown file as a separate
case to exercise filetype setup. If taskbuffer is loaded on demand, also measure
the first `:Tasks`; lazy loading moves that work out of startup.

## Reproducible development benchmark

From the repository root, with Python 3, Neovim, and ripgrep installed:

```bash
make bench
make bench BENCH_ARGS='--files 500 --tasks-per-file 20 --runs 20 --json /tmp/taskbuffer-bench.json'
```

The benchmark generates a temporary vault and isolates Neovim's config, data,
cache, state, taskfile output, and inbox. It never uses your configured sources.
Each generated file contains frontmatter with a project tag/due date, plus dated
checkbox tasks. Project tasks are additional to the printed checkbox task count.

It compares baseline Neovim, taskbuffer's command registration, and full setup
in fresh processes with recording disabled. Cases are interleaved and one warmup
per case is discarded. It reports time to `NVIM STARTED`, including Neovim's
builtin plugins. Startup checks also verify that the scan/list modules stay
unloaded. Filesystem caches are warm; this is not a cold-disk benchmark.

Workloads record setup, first open, repeated command opens, buffer re-entry,
forced source refresh, display changes, and cached async tag queries. A forced
source refresh rebuilds the snapshot even when its files have not changed,
measuring the cost incurred after source edits. First open is measured once; repeated
operations use `--runs`. Run several invocations for a first-open distribution.
Headless measurements include buffer updates and filetype hooks, but do not
represent terminal drawing, interactive typing, or the cost of your other
plugins. Active profiling also adds overhead. Confirm findings interactively
with recording disabled before judging perceived performance.

Run the benchmark on the base and changed revisions with the same arguments.
Keep the JSON reports outside the checkout. Use timing trends for regression
review; structural tests cover disabled recording, callback semantics, and
duplicate refresh prevention without machine-dependent timing assertions.

## Find the expensive Lua functions

Once a stage is slow, use the LuaJIT sampling profiler provided by plenary.nvim
(optional, also used by this project's test harness):

```vim
:lua require("plenary.profile").start("/tmp/taskbuffer-lua.profile", { flame = true })
" Repeat the slow action; wait for asynchronous refreshes to finish.
:lua require("plenary.profile").stop()
```

The output contains folded stacks for a flamegraph renderer. Sample a separate
run from stage recording to reduce profiler interference. Neovim's Vimscript
`:profile` is useful for Vimscript hooks; use LuaJIT sampling for Lua internals.

## When work runs

- `:Tasks` opens immediately. Task and project discovery run concurrently via
  `vim.system` callbacks. No interactive path calls the synchronous scan APIs.
- CPU-heavy decoding, parsing, sorting, frontmatter processing, and formatting
  yield between batches, targeting about 4 ms per slice. Timers exist only while
  a requested operation is pending (or opt-in profiling is recording).
- Re-entering taskbuffer scans for added/deleted files and checks relevant files'
  size, inode, mtime, and ctime. Unchanged files reuse the source snapshot; an
  unchanged date/filter/marker view reuses its formatted text as well.
- Tag/marker/undated display changes reuse parsed tasks without a source scan.
  The tag picker also reuses the snapshot. Source mutations force a new snapshot;
  external edits appear on the next entry or `:Tasks` command.
- Identical pending requests coalesce. A newer view/source request supersedes
  obsolete work. Hiding or deleting its task buffer cancels the subprocesses
  and any queued processing slices.
- Results update only the originating buffer. Unchanged output does not rewrite
  the taskfile or replace buffer lines, preserving the cursor and changedtick.
  Refreshes do not reload buffers or replay FileType hooks.

The slice budget is cooperative, not a hard deadline. Individual filesystem
operations (glob expansion, metadata checks, frontmatter reads, output writes)
remain synchronous, as do Neovim's buffer update APIs. A slow filesystem, a huge
single frontmatter block/line, GC, or another plugin can exceed the budget.
Metadata caching also relies on the filesystem reporting file changes. There
are no background file watchers or periodic source scans.

The synchronous `list.list()`, `list.tags()`, and `buffer.refresh_taskfile()`
helpers remain available for scripts. Prefer `list.list_async(opts, callback)`
and `list.tags_async(opts, callback)` in interactive code; each returns a cancel
function. For a source refresh that also updates the visible task buffer, use
`buffer.refresh_and_restore_cursor(callback)`; its callback runs after publication
with an optional error. `buffer.refresh_view()` reuses the current snapshot.
