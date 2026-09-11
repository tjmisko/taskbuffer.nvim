# Release checks

The release audit on 2026-09-11 found correctness issues despite the existing
409-test suite passing. Regression coverage now includes unsaved and hidden source
buffers, stale task locations, fresh timer state, timer completion, headings,
filenames with spaces/colons/Ex separators, CRLF, single-file sources, configuration
isolation, failed source writes, symlinks, and private generated output.

## Required validation before tagging

- Run `make test-lua`, `make lint`, and `make helptags`.
- Clone lazy.nvim into `.deps/lazy.nvim` and run `make test-install`. Alternatively
  set `TASKBUFFER_TEST_LAZY` to an existing checkout. This exercises native
  loading, lazy.nvim setup, and command-triggered loading with temporary sources
  and isolated configuration.
- Require green CI for Neovim 0.10.0 and stable on Linux and macOS, plus lint.
- Run `make bench BENCH_ARGS='--files 500 --tasks-per-file 20 --runs 20 --json /tmp/taskbuffer-release-bench.json'`.
  Inspect editor scheduling delay alongside completion time. Absolute startup
  timings depend heavily on machine load; compare versions in interleaved runs
  when making performance claims.
- Exercise Telescope filtering, source navigation, timer start/completion, date
  edits, undo/redo, and switching buffers during scans in an interactive editor.
- Review the Unreleased changelog and installation instructions, choose the
  release version, and tag only the validated commit.

## Audit evidence

On the local Neovim 0.12.4 installation, 432 tests passed with no failures/errors;
StyLua, Selene, help-tag generation, and all three installation modes passed.
A live Telescope smoke test opened the picker, listed tags, selected a tag, and
refreshed the source taskbuffer successfully. The 10,000-task benchmark measured
full-refresh editor scheduling delay at approximately 6.7 ms p95 (23.3 ms max).
This is a scheduling-delay proxy, not a key-to-screen latency measurement.

The new compatibility matrix must finish successfully on the release commit;
local testing alone does not establish minimum-version or macOS compatibility.
The local attempt to download an older Neovim binary was blocked by the sandbox's
release-asset domain policy. Windows has not been validated.

## Operational limits

Source mutations require saved source buffers and writable source directories.
Writes use a temporary sibling file and rename it into place after writing and
closing successfully. Symlinks are preserved; files with multiple hard links are
refused rather than silently breaking the link relationship. File permission
bits are preserved; extended attributes and custom ACLs are not copied.

Bulk actions and timer transitions can touch several files. They are not
transactions across files, and concurrent external writers are not locked out.
Generated taskfiles are private to a session and cleaned up on normal exit;
an abrupt process termination can leave temporary output behind.

The parser supports taskbuffer's documented task syntax and a limited frontmatter
subset, not all Markdown/YAML constructs. The runtime pipeline is cooperative;
individual filesystem, garbage collection, and Neovim buffer operations can exceed
the target processing slice. Passing tests does not imply zero bugs or hard latency
guarantees.
