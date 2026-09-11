# taskbuffer.nvim

[![CI](https://github.com/tjmisko/taskbuffer.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/tjmisko/taskbuffer.nvim/actions/workflows/ci.yml)

Keep tasks in your Markdown files. Use Neovim to see and manage them together.

```markdown
- [ ] Review the API proposal #work (@[[2026-09-14]])
- [ ] Replace the bike chain <30m> #home
```

`:Tasks` gathers tasks into a readonly buffer, grouped by due date. Jump to the
original note, complete a task, change its due date, or filter the list by tag.
Taskbuffer also reads tags and due dates from YAML frontmatter.

[Installation](#installation) · [Usage](#usage) · [Configuration](#configuration) · [Help](#help-and-contributing)

## Requirements

- Neovim **0.10 or newer**.
- Linux or macOS, with the standard `cp` utility. Windows is not tested.
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for task discovery.
- Optional: [Telescope](https://github.com/nvim-telescope/telescope.nvim#installation)
  for the tag picker.

Taskbuffer is written in Lua and requires no build step. It works with Markdown
files independently of Obsidian.

## Installation

With [lazy.nvim](https://lazy.folke.io/spec), add this plugin spec:

```lua
{
    "tjmisko/taskbuffer.nvim",
    lazy = false,
    opts = {
        sources = { "~/notes" }, -- Change this to your notes directory.
    },
}
```

`lazy = false` makes commands and source-editing shortcuts available immediately.
Setup registers entry points; it does not scan your files. Scanning starts when
you open taskbuffer. Define `vim.g.mapleader` before configuring the plugin.

With another plugin manager, install `tjmisko/taskbuffer.nvim` and call:

```lua
require("taskbuffer").setup({ sources = { "~/notes" } })
```

Run `:checkhealth taskbuffer` to check your installation and source paths.

## Usage

1. Add a task such as `- [ ] Try taskbuffer #work` to a Markdown file under one
   of your configured sources, then save it.
2. Run `:Tasks`. Undated tasks appear under **Someday** by default.
3. Move to a task and press `<Enter>` or `gf` to open its source. Press
   `<leader>tx` to check it off, or `#` in taskbuffer to filter by tag.

The default due-date syntax is `(@[[YYYY-MM-DD]])`, with an optional time:

```markdown
- [ ] Send the draft <45m> #work (@[[2026-09-14]] 16:00)
```

Here `<45m>` is an estimated duration. Dates, durations, and tags are optional.
Checkboxes represent open (`- [ ]`), complete (`- [x]`), or irrelevant (`- [-]`)
tasks. Completion, deferral, and timer actions add timestamped `::` markers to
the task line. See `:help taskbuffer-syntax` for the full format.

### Editing and saving

**In a Markdown buffer**, shortcuts edit the current buffer, including unsaved
text. Each task action is one normal undo step. Use `u` / `<C-r>` to undo or redo,
and `:write` to save.

**In taskbuffer**, actions update the source file on disk. Save any unsaved
changes to that source before acting from the task list. Run `:Tasks` to pick up
saved or external changes; taskbuffer rejects stale source locations.

### Keybindings

On a task in a Markdown file or in taskbuffer:

| Key | Action |
| --- | --- |
| `<leader>tx` | Check off without adding a timestamp |
| `<leader>tc` | Complete and add a timestamp |
| `<leader>td` | Record a deferral |
| `<leader>ti` | Mark irrelevant and add a timestamp |
| `<leader>tu` | Remove the irrelevant marking |
| `<M-Left>` / `<M-Right>` | Move the due date earlier / later; accepts a count |
| `<C-T>` | Set the due date to today |

In taskbuffer:

| Key | Action |
| --- | --- |
| `<Enter>` / `gf` | Open the task's source |
| `#` | Filter by tag with Telescope |
| `<leader>tt` | Reset filters |
| `<leader>ts` | Toggle undated tasks |
| `<leader>tj` | Toggle timestamp markers |
| `<leader>tb` | Start timing the selected task |
| `u` / `<C-r>` | Undo / redo a date change |

Date changes also work on a visual selection in taskbuffer. The global
`<leader>ev` mapping inserts a dated note entry. All mappings can be changed or
disabled; see `:help taskbuffer-keybindings` for the complete list.

### Commands

| Command | Action |
| --- | --- |
| `:Tasks` | Open or refresh the task list and clear tag filters |
| `:TasksClear` | Clear the tag filter on the current list |
| `:TasksUndated` | Open the list with undated tasks visible |
| `:TasksProfile [start\|stop\|reset\|report]` | Record or inspect performance timings |

## Configuration

Pass only the options you want to change in `opts` or `setup()`. Sources can be
directories, individual files, or glob patterns. For example:

```lua
opts = {
    sources = { "~/notes", "~/projects/**/tasks.md" },
    show_undated = true,
    keymaps = {
        global = {
            complete = "<leader>tC",
            note = false, -- Disable the dated-note shortcut.
        },
    },
}
```

The [full reference](doc/taskbuffer.txt) is also available inside Neovim:

| Topic | Help |
| --- | --- |
| All options and defaults | `:help taskbuffer-configuration` |
| Due-date groups | `:help taskbuffer-horizons` |
| Frontmatter tags, dates, and status | `:help taskbuffer-frontmatter` |
| Date, time, and checkbox formats | `:help taskbuffer-formats` |

## Performance

Task scans run asynchronously. Taskbuffer reuses cached results for filtering
and cancels pending work when its buffer is hidden. Profiling is off by default.

To investigate a slowdown, run `:TasksProfile start`, reproduce it, then run
`:TasksProfile stop`. See the [performance guide](docs/performance.md) for startup
measurements, benchmarks, and interpreting the report.

## Help and contributing

To record a usage video with scripted input and an on-screen key display, see
the [demo recording guide](docs/demo.md).

Start with `:help taskbuffer` and `:checkhealth taskbuffer`. If a task is missing,
check that its file is saved under a configured source and that filters are
cleared with `:Tasks`.

[Report a bug](https://github.com/tjmisko/taskbuffer.nvim/issues) with your Neovim
version, plugin commit, relevant configuration, and a small example that
reproduces the problem. Use sample tasks you can share publicly.

For development checks and regression coverage, see the
[testing guide](docs/testing.md). Changes are recorded in the
[changelog](CHANGELOG.md).

## Project history

I originally wrote taskbuffer in Bash, then as a Go binary with a Neovim plugin.
The Go implementation remains in the Git history. The current Lua rewrite and
the [Obsidian port](https://github.com/tjmisko/obsidian-taskbuffer) were built by
AI coding agents under my direction.

## License

[MIT](LICENSE) — Tyler Misko.
