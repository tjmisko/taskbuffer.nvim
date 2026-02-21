# taskbuffer.nvim

A neovim plugin for managing tasks defined inline in plain-text markdown notes.

> Tasks are single lines of plain text, stored somewhere convenient for you, centralized later. Formatted your way.

## Features

- Scans markdown files with [ripgrep](https://github.com/BurntSushi/ripgrep) for fast, recursive task discovery
- Displays tasks in a read-only **taskfile** buffer, bucketed by date interval (Overdue, Today, Tomorrow, This Week, etc.)
- Start/stop/complete task timer with `::start`, `::stop`, `::complete` markers written to source files
- Defer, mark irrelevant, mark partial — all operations modify source files directly
- Filter tasks by tag via [Telescope](https://github.com/nvim-telescope/telescope.nvim) picker
- Shift task due dates with `<M-Left>` / `<M-Right>` in both taskfile and markdown buffers
- Jump from taskfile line to source file location with `gf`
- Create new tasks from the CLI with optional header-based insertion
- Fully configurable: sources, keybindings, inbox location, task format

## Requirements

- Neovim 0.9+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) on PATH
- Go 1.21+ (for building the binary)
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (for tag filtering)

## Installation

### lazy.nvim

```lua
{
    "tjmisko/taskbuffer.nvim",
    build = "cd go && go build -o task_bin .",
    config = function()
        require("taskbuffer").setup({
            -- your overrides here
        })
    end,
}
```

### packer.nvim

```lua
use {
    "tjmisko/taskbuffer.nvim",
    run = "cd go && go build -o task_bin .",
    config = function()
        require("taskbuffer").setup()
    end,
}
```

## Configuration

All options with their defaults:

```lua
require("taskbuffer").setup({
    -- Path to the compiled Go binary (auto-detected)
    task_bin = "<plugin_root>/go/task_bin",

    -- State directory for current task tracking
    state_dir = "~/.local/state/task",

    -- Temp directory for taskfile output
    tmpdir = "/tmp",

    -- Task sources: directories (recursive) or glob patterns
    sources = { "~/Documents/Notes" },

    -- Default location for new tasks via `task create`
    inbox = {
        file = "~/Documents/Notes/inbox.md",
        header = nil,  -- e.g. "## Tasks" to insert below a heading
    },

    -- Task syntax formats (passed to Go binary)
    formats = {
        date = "%Y-%m-%d",
        time = "%H:%M",
        duration = "<{n}m>",
        tag_prefix = "#",
        checkbox = { open = "- [ ]", done = "- [x]", irrelevant = "- [-]" },
        date_wrapper = { "(@[[", "]])" },
        marker_prefix = "::",
    },

    -- Keymaps: set any to false to disable
    keymaps = {
        global = {
            complete        = "<leader>tc",
            defer           = "<leader>td",
            check_off       = "<leader>tx",
            irrelevant      = "<leader>ti",
            undo_irrelevant = "<leader>tu",
            quickfix        = "<M-C-q>",
            note            = "<leader>ev",
        },
        taskfile = {
            start_task         = "<leader>tb",
            go_to_file         = "gf",
            partial            = "<leader>tp",
            irrelevant         = "<leader>ti",
            undo_irrelevant    = "<leader>tu",
            filter_tags        = "#",
            reset_filters      = "<leader>tt",
            toggle_markers     = "<leader>tj",
            shift_date_back    = "<M-Left>",
            shift_date_forward = "<M-Right>",
        },
        markdown = {
            shift_date_back    = "<M-Left>",
            shift_date_forward = "<M-Right>",
        },
    },
})
```

To disable a keymap, set it to `false`:

```lua
require("taskbuffer").setup({
    keymaps = {
        global = {
            note = false,  -- don't register the note keymap
        },
    },
})
```

## Task Syntax

Tasks are standard markdown checkboxes with optional metadata:

```
- [ ] Task body <30m> #tag (@[[2026-02-17]] 16:00)
```

| Component | Format | Required |
|-----------|--------|----------|
| Checkbox | `- [ ]`, `- [x]`, `- [-]`, `- [~]` | Yes |
| Body | Free text | Yes |
| Duration | `<Nm>` (e.g. `<30m>`, `<90m>`) | No |
| Tags | `#tag-name` | No |
| Due date | `(@[[YYYY-MM-DD]])` | No |
| Due time | `(@[[YYYY-MM-DD]] HH:MM)` | No |

### Markers

Markers are appended to task lines to track state changes:

| Marker | Meaning |
|--------|---------|
| `::start [[DATE]] TIME` | Task timer started |
| `::stop [[DATE]] TIME` | Task timer stopped |
| `::complete [[DATE]] TIME` | Task completed |
| `::deferral [[DATE]] TIME` | Task deferred |
| `::original [[DATE]]` | Original due date (preserved on first deferral) |
| `::irrelevant [[DATE]] TIME` | Marked irrelevant |
| `::partial [[DATE]] TIME` | Marked partial |

Full example:

```
- [x] Write report <30m> #work (@[[2026-02-17]] 15:00) ::start [[2026-02-17]] 15:17 ::complete [[2026-02-17]] 17:19
```

## Commands

| Command | Description |
|---------|-------------|
| `:Tasks` | Open the taskfile buffer |
| `:TasksClear` | Clear tag filters and refresh |

### CLI Commands

The Go binary can also be used directly:

```bash
task list [--tag TAG] [-markers]   # List tasks (default)
task do                            # Pick and start a task (fzf)
task stop                          # Stop the current task
task complete                      # Complete the current task
task current                       # Print current task name
task tags                          # List all tags
task defer <file> <line>           # Defer a task
task irrelevant <file> <line>      # Mark task irrelevant
task partial <file> <line>         # Mark task partial
task unset <file> <line>           # Undo irrelevant/partial
task check <file> <line>           # Quick check-off
task complete-at <file> <line>     # Complete a specific task
task create [--file F] [--header H] <body>  # Create a new task
```

Global flags (before subcommand):

```bash
task --source ~/Notes --source ~/Work list
task --config '{"state_dir":"/tmp/state"}' current
```

## Keybindings

### Global (all filetypes)

| Action | Default | Description |
|--------|---------|-------------|
| Complete | `<leader>tc` | Mark task on current line as complete |
| Defer | `<leader>td` | Defer task on current line |
| Check off | `<leader>tx` | Quick check-off (no marker) |
| Irrelevant | `<leader>ti` | Mark task irrelevant |
| Undo irrelevant | `<leader>tu` | Undo irrelevant/partial |
| Quickfix | `<M-C-q>` | Send visual selection to quickfix |
| Note | `<leader>ev` | Insert a dated note entry |

### Taskfile buffer

| Action | Default | Description |
|--------|---------|-------------|
| Start task | `<leader>tb` | Start timer for task under cursor |
| Go to file | `gf` | Jump to source file location |
| Partial | `<leader>tp` | Mark task partial |
| Irrelevant | `<leader>ti` | Mark task irrelevant |
| Undo irrelevant | `<leader>tu` | Undo irrelevant/partial |
| Filter tags | `#` | Open Telescope tag picker |
| Reset filters | `<leader>tt` | Clear all filters |
| Toggle markers | `<leader>tj` | Show/hide `::` markers |
| Shift date back | `<M-Left>` | Move due date earlier |
| Shift date forward | `<M-Right>` | Move due date later |

### Markdown files

| Action | Default | Description |
|--------|---------|-------------|
| Shift date back | `<M-Left>` | Move due date earlier |
| Shift date forward | `<M-Right>` | Move due date later |

## Architecture

```
Markdown files ──rg --json──▶ Go binary ──parse──▶ Task structs ──format──▶ .taskfile
                                                                              │
Neovim ◀── buffer.lua reads .taskfile ◀────────────────────────────────────────┘
         keymaps.lua calls Go binary for mutations (defer, irrelevant, etc.)
```

**Go binary** (`go/`): Scanning (`scan.go`), parsing (`parse.go`), formatting (`format.go`), file mutation (`mutate.go`), timer state (`state.go`), frontmatter parsing (`frontmatter.go`).

**Lua plugin** (`lua/taskbuffer/`): Config and setup (`init.lua`), buffer management (`buffer.lua`), keymaps (`keymaps.lua`), Telescope tag picker (`tags.lua`).
