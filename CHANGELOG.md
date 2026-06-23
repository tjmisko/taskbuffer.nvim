# Changelog

All notable changes to taskbuffer.nvim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Migrated from Go to pure Lua

taskbuffer's task engine was originally a Go binary that the plugin shelled out
to. As of this release the engine is reimplemented entirely in Lua and runs
in-process — there is **no build step and no external binary**. `rg` (ripgrep)
remains the only external dependency, with a `grep` fallback.

The Lua pipeline was verified byte-for-byte against the Go binary (list output
and mutations) before the switch, and is as fast or faster on large vaults
because it no longer spawns a subprocess per refresh.

#### Changed
- Scanning, parsing, formatting, horizon bucketing, frontmatter handling,
  mutation, and timer state now run in Lua (`scan.lua`, `parse.lua`,
  `format.lua`, `horizon.lua`, `strftime.lua`, `frontmatter.lua`, `mutate.lua`,
  `state.lua`, plus `context.lua` / `list.lua` / `actions.lua`).
- Installation no longer needs a `build`/`run` hook — just add the plugin.
- `:checkhealth taskbuffer` reports the in-process Lua pipeline instead of a
  Go binary.

#### Removed
- The Go binary and the entire `go/` directory.
- The `use_lua_pipeline` migration flag and the `task_bin` config option; the
  Lua pipeline is now unconditional.
- The standalone shell CLI (`task list` / `do` / `create` / `stop` / …). It was
  provided by the Go binary and was never ported to Lua. All in-editor features
  (`:Tasks`, keymaps, action verbs, tag picker, timer) are unchanged.

#### Preserved
- The final Go implementation remains buildable from the **`legacy/go`** branch
  and the **`go-final`** tag (commit `68f84e7`):
  `cd go && go build -o task_bin .`.

## [0.2.0] and earlier

The `v0.1.0`, `v0.1.1`, and `v0.2.0` tags mark the Go-era releases. See the git
history for details.
