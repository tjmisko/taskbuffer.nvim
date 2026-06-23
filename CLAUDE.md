# CLAUDE.md

## Project Overview

`taskbuffer.nvim` is a neovim plugin for managing a personal task/time-tracking system built on Obsidian-style markdown notes. Tasks are defined inline in `.md` files using a specific syntax, scanned with `rg` (ripgrep), parsed and formatted entirely in Lua, and displayed in a custom "taskfile" buffer format. There is no build step and no external binary.

## Build & Test

```bash
# Run all tests (requires plenary.nvim; CI clones it to .deps/)
make test          # alias for test-lua
make test-lua      # nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

# End-to-end Docker tests (plugin loading under lazy.nvim, vim-plug, custom configs)
make test-e2e-all

# Lint
make lint          # stylua --check + selene
```

Requires `rg` (ripgrep) on PATH (falls back to `grep` if absent).

## Architecture

The plugin is pure Lua. The pipeline runs in-process — no Go binary, no subprocess except `rg` for scanning.

**Pipeline**: `scan` (rg --json) → `parse` (regex parsing) → `format` (bucket by horizon) → taskfile buffer

### Lua pipeline (`lua/taskbuffer/`)

- **`scan.lua`** — Runs `rg --json` against sources (sync + async), returns raw matches
- **`parse.lua`** — Parses raw matched lines into task tables
- **`format.lua`** — Formats tasks into taskfile display (bucketed by date interval)
- **`horizon.lua`** — Horizon specs, resolution, and default horizons
- **`strftime.lua`** — Strftime-to-Lua-pattern format and regex conversion
- **`frontmatter.lua`** — YAML frontmatter parsing for tags/due dates/status
- **`mutate.lua`** — File mutation (append to line, check off task)
- **`state.lua`** — Current task state (start/stop/complete tracking)
- **`context.lua`** — Builds the shared context (config + runtime) for the pipeline
- **`list.lua`** — In-process list/tags pipeline (orchestrates scan → parse → format)
- **`actions.lua`** — Mutating verbs (complete, defer, check, irrelevant, unset, stop)

### Lua plugin / UI (`lua/taskbuffer/`)

- **`init.lua`** — Setup(), public API entry points
- **`config.lua`** — Defaults, validation, path expansion
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

## Legacy Go implementation

The original engine was a Go binary (`go/`). It has been fully superseded by the
Lua pipeline and removed from `main`. It remains available on the `legacy/go`
branch and the `go-final` tag for reference.

## Task Syntax

```
- [ ] Task body <30m> #tag (@[[2026-02-17]] 16:00) ::start [[2026-02-17]] 15:58 ::complete [[2026-02-17]] 17:19
```

## Key Paths

- Notes: `~/Notes`
- Task state: `~/.local/state/task/current_task`
