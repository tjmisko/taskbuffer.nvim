# Environment & harness notes (discovered during implementation)

These are facts about *running the tests in this worktree* that the blueprint
did not anticipate. They affect the scan module and the parity harness, not the
shipped plugin.

## 1. `.worktrees/` is gitignored → `rg` ignores absolute in-tree paths

This worktree lives at `.worktrees/refactor/lua-rewrite`, and the **parent
repo's** `.gitignore` contains `.worktrees/`. `rg` respects VCS ignore rules, so
when given an **absolute path under this worktree** it discovers the parent
ignore and matches **nothing**:

```
git -C ~/Projects/taskbuffer.nvim check-ignore <worktree>/go/testdata/basic-vault
  -> reported ignored
rg --json -e '...' <ABS path under worktree>   -> 0 matches (exit 1)
rg --json -e '...' testdata/basic-vault         -> matches (relative, cwd inside tree)
rg --no-ignore ... <ABS>                         -> matches
```

Consequence: **39 of the Go tests fail in this worktree** — exactly the
`rg`-backed ones (`TestEdge_*`, `TestPath_*`, `TestTag_*`, `TestGlob_*`,
`TestVault_*`, `TestFMDue_*`). The pure-logic unit tests
(`parse_test`, `format_test`, `horizon_test`, `timeformat_test`, `mutate_test`,
`state_test`, `frontmatter_test`) **pass**, because `scan_test.go` builds vaults
under `t.TempDir()` (an OS tempdir, outside the ignored tree). This is a
test-environment artifact, **not a code bug** — it cannot affect real users
(`~/Notes` isn't gitignored) or CI (normal checkout, not under `.worktrees/`).

### Mitigations (mandatory for any test that scans)
- Specs that scan must create their fixture vault under `vim.fn.tempname()`
  (OS tempdir), write `.md` files there, and scan that — never an in-worktree
  absolute path. `tests/fixtures/vaults/` is committed for the *parity* harness,
  which copies a vault to a tempdir at test time (see `tests/helpers`).
- The plugin's `scan.lua` itself does **not** need `--no-ignore`; shipping
  behavior is to respect ignores (matches Go). Adding `--no-ignore` would change
  scan semantics and is out of scope.

## 2. Golden / parity output must use vault-relative paths

The taskfile output embeds `"<filepath>:<lineno>:1:..."`. The absolute vault
path differs between the capture machine, CI, and a tempdir copy, so golden
files **cannot** store absolute paths and be compared byte-for-byte across
environments. The parity harness must relativize the file path to the vault root
(or substitute a `{VAULT}` placeholder) on both capture and assert sides before
diffing. This was implicit in blueprint 06 §7.2 ("assert byte-for-byte") but only
works once paths are made portable.

## 3. Test fixtures

`go/testdata/` was **copied** (not moved) to `tests/fixtures/vaults/` so the Go
suite keeps working during the strangler migration (it is deleted with `go/` in
Phase 6). The `path-edge-vault/linked -> symlink-target` symlink and the
`empty-dir/.gitkeep` are preserved.

## 4. Test harness commands

- nvim 0.11.5, plenary present at `~/.local/share/nvim/lazy/plenary.nvim`.
- Whole suite: `make test-lua` (`PlenaryBustedDirectory tests/`).
- Single file (use this while modules are landing in parallel):
  `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/unit/<mod>_spec.lua"`.
- Harness noise: a `telescope`/`after/plugin` require error may print from the
  user's nvim config bleeding in; it does not fail specs — ignore it.
