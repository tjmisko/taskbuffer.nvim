# Testing editor behavior

The September 2026 failures exposed gaps that passing file-level tests did not
cover. An earlier safety test expected shortcuts to refuse unsaved buffers, which
protected disk contents but also encoded the wrong editing behavior. Checking the
resulting file could not detect a stale checkbox decoration. The initial install
smoke test checked that tasks appeared, without asserting that opening was free
of warnings.

## Regression coverage

| User behavior | Automated check | Location |
| --- | --- | --- |
| Open, refresh, and reopen taskbuffer | Real scanner and output writes; check native warnings, error messages, readonly state, and unchanged buffer identity | `tests/interaction_spec.lua` |
| Load through native or lazy.nvim installation | Tasks appear without W10 or other native warnings; generated buffer stays readonly, unmodified, and without swap | `tests/install_init.lua` |
| Mark the current task irrelevant while editing | Type unsaved text, move the task by inserting a heading, press the mapped keys, and check the edited buffer and unchanged disk | `tests/interaction_spec.lua` |
| Undo or unset the task action | One `u` restores the task while keeping earlier typing; `<C-r>` restores the whole action; `<leader>tu` removes the irrelevant status | `tests/interaction_spec.lua` |
| Update the displayed checkbox | Require a real `TextChanged` event with the updated text; with Obsidian, check its actual extmarks before and after the keypress | `tests/interaction_spec.lua` |
| Work before the first save | Exercise both a new filename and an unnamed buffer | `tests/interaction_spec.lua` |
| Use related task and date shortcuts | Drive complete, check-off, defer, inline dates, and frontmatter dates through their key mappings; verify undo and preservation of unsaved text | `tests/interaction_spec.lua` |
| Protect a dirty source while using the aggregate view | Reject the disk-based action, preserve both versions, then navigate to the source and successfully edit it there | `tests/interaction_spec.lua` |
| Cancel, coalesce, or finish an async refresh in another window | Controlled async callbacks verify focus, stale-result rejection, unchanged output, and failure recovery | `tests/buffer_spec.lua` |
| Fail partway through a source operation | Verify staged changes are discarded, buffer routing is reset, and file bytes/metadata remain intact | `tests/unit/source_spec.lua` |

The interaction suite starts a separate Neovim for every case. It sends real
input with `nvim_input`; the controller waits outside that editor so normal
input processing and `TextChanged` events can run. It does not invoke mapping
callbacks or synthesize redraw events. Each case uses temporary sources and
isolated configuration, state, cache, and data directories.

## Running the checks

```sh
make test-lua
python3 scripts/test-lua.py tests/interaction_spec.lua
TASKBUFFER_TEST_LAZY=/path/to/lazy.nvim make test-install
make lint
```

The real-renderer check uses Obsidian's UI module with a temporary workspace;
it does not load a personal Obsidian configuration or scan a notes directory:

```sh
TASKBUFFER_TEST_OBSIDIAN=/path/to/obsidian.nvim \
  python3 scripts/test-lua.py tests/interaction_spec.lua
```

CI runs the interaction suite on Linux and macOS with Neovim 0.10.0 and stable.
Linux/stable additionally tests the real Obsidian renderer at pinned commit
`7a2b7caf41de196de66f27c1969d0d429810621a`. Pinning makes compatibility failures
reproducible; update that pin deliberately and rerun the suite.

## Checking that a regression test is effective

Keep the current tests while running the editor against an older runtime using
`TASKBUFFER_TEST_PROJECT=/path/to/old/taskbuffer.nvim`. Copy only the old runtime
into an isolated directory; do not revert or modify the working checkout.

These historical versions are useful negative controls:

| Runtime | Expected failure |
| --- | --- |
| `0a5e71c` | W10 while publishing the generated buffer |
| `71c773c` | W13 when reopening a generated file |
| `00ac810` | Missing renderer change event and refusal of unsaved source edits |

For future bug fixes, first add a user-level assertion that fails on the faulty
behavior. Test both the requested action and preservation of existing work.
Keep byte-level tests for parsing and file fidelity, and use the interaction
suite for key mappings, undo boundaries, notifications, and event delivery.
