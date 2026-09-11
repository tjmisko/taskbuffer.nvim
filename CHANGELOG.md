# Changelog

All notable changes to taskbuffer.nvim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Performance and release hardening

- Keep setup limited to configuration and lazy entry points; expand source globs
  only when discovering tasks. Run concurrent scans and process large results in
  cancellable slices, reusing unchanged source snapshots and formatted views.
- Add opt-in `:TasksProfile` instrumentation and an isolated benchmark harness.
- Edit the current source buffer directly for task and date shortcuts, including
  unsaved tasks. Apply checkbox and marker changes in one native undo step,
  preserve unrelated edits, and let Markdown renderers see normal change events.
- Protect unsaved source buffers from disk mutations; refresh clean loaded
  buffers after successful edits. Stage source writes before replacement so
  failed writes do not truncate the original; preserve permissions, extended
  attributes, ACLs, and symlinks using the platform copy utility.
- Route global actions in taskbuffer to the source task, reject stale task
  locations, and ignore headings. Escape source filenames when navigating.
- Start timers through the action API, creating state directories on demand.
  Refuse to stop a different task after a stored task location becomes stale.
- Preserve CRLF and missing final newlines in date edits and undo/redo.
- Use private session directories for generated taskfiles to avoid collisions
  between Neovim instances; remove generated output on normal exit.
- Fix macOS grep fallback flags and canonicalize generated taskfile paths.
- Correct empty/list configuration overrides, avoid mutating caller options,
  and keep filename prefixes when scanning a single file.
- Add action safety and installation regressions, isolate the test runner from
  personal configuration, and cover Neovim 0.10.0/stable on Linux and macOS in CI.
- Exercise actual keypresses, native undo, source editing, and warning-free
  taskfile refreshes in separate editors. Check change-event delivery and run a
  pinned Obsidian renderer integration in CI to detect stale checkbox displays.


### Migrated from Go to pure Lua

taskbuffer's task engine was originally a Go binary that the plugin shelled out
to. As of this release the engine is reimplemented entirely in Lua and runs
in-process — there is **no build step and no external binary**. `rg` (ripgrep)
provides discovery, with a `grep` fallback. Source edits use the standard system
`cp` utility to preserve file metadata.

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
