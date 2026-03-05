# CLAUDE.md

## Project Overview

`taskbuffer.nvim` is a neovim plugin for managing a personal task/time-tracking system built on Obsidian-style markdown notes. Tasks are defined inline in `.md` files using a specific syntax, scanned with `rg` (ripgrep), parsed in Go, and displayed in a custom "taskfile" buffer format.

## Build & Test

```bash
# Build the Go binary
cd go && go build -o task_bin .

# Run all tests
cd go && go test ./...

# Run a single test
cd go && go test -run TestParseTask_Simple ./...
```

Requires `rg` (ripgrep) on PATH.

## Architecture

### Go binary (`go/`)

**Pipeline**: `Scan` (rg --json) → `ParseTask` (regex parsing) → format/display

- **`scan.go`** — Runs `rg --json` against notes dir, returns `[]RawMatch`
- **`parse.go`** — Parses raw matched lines into `Task` structs
- **`format.go`** — Formats tasks into taskfile display (bucketed by date interval)
- **`horizon.go`** — Horizon specs, resolution, and default horizons
- **`timeformat.go`** — Strftime-to-Go format and regex conversion
- **`mutate.go`** — File mutation (append to line, check off task)
- **`state.go`** — Current task state (start/stop/complete tracking)
- **`frontmatter.go`** — YAML frontmatter parsing for tags/due dates/status
- **`main.go`** — CLI subcommand dispatch (list, do, stop, complete, current, tags)

### Lua plugin (`lua/taskbuffer/`)

- **`init.lua`** — Setup(), public API entry points
- **`config.lua`** — Defaults, validation, path expansion, config JSON serialization
- **`buffer.lua`** — Taskfile buffer management, refresh, state tracking
- **`autocmds.lua`** — BufEnter/BufLeave autocommands for taskfile refresh
- **`keymaps.lua`** — Global, taskfile, and markdown keymaps
- **`commands.lua`** — `:Tasks`, `:TasksClear`, `:TasksUndated` command registration
- **`tags.lua`** — Telescope tag picker
- **`undo.lua`** — Undo/redo stack for date shift operations
- **`util.lua`** — File I/O, date manipulation, taskfile line parsing
- **`health.lua`** — `:checkhealth taskbuffer` diagnostics

### Plugin files

- **`plugin/taskbuffer.lua`** — Lazy-loaded `:Tasks`, `:TasksClear`, and `:TasksUndated` commands
- **`ftdetect/taskfile.vim`** — Filetype detection for `.taskfile`
- **`syntax/taskfile.vim`** — Syntax highlighting

## Task Syntax

```
- [ ] Task body <30m> #tag (@[[2026-02-17]] 16:00) ::start [[2026-02-17]] 15:58 ::complete [[2026-02-17]] 17:19
```

## Key Paths

- Notes: `~/Documents/Notes`
- Task state: `~/.local/state/task/current_task`
