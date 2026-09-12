# Recording the usage demo

The demo runs in a dedicated WezTerm window with disposable note directories and a Rust project,
a clean Neovim configuration, scene captions, and a display of the keys typed.
It uses this checkout of taskbuffer. Your regular Neovim configuration and notes
are not loaded.

## Launch

Requirements: Python 3, a current stable Neovim, ripgrep, `cp`, and WezTerm. The
tag-filter scene also needs compatible versions of Telescope and Plenary.
These provide the demo's `vim.ui.select` presentation; taskbuffer itself works
with Neovim's built-in menu or any configured `vim.ui.select` provider.
By default the launcher finds these in
`~/.local/share/nvim/lazy`; pass `--deps /path/to/plugins` for another location.
Catppuccin is used when present in that directory; otherwise the demo uses
Neovim's Habamax theme. The launcher does not install plugins.

From the repository, in a terminal on your desktop:

```sh
python3 scripts/demo.py
```

Arrange or maximize the new window before starting a take. Its application ID
is `org.taskbuffer.demo`, and its title is `taskbuffer demo`. The terminal has an
opaque background, large type, and no tabs. Font and window defaults live in
[`scripts/demo/wezterm.lua`](../scripts/demo/wezterm.lua).

| Key | Control |
| --- | --- |
| F5 | Reset the sample notes and play a fresh take |
| F6 | Pause / resume playback |
| F8 | Abort playback |
| `:qa!` | Close the demo |

F5 does nothing during playback; use F8 first to restart. F6 pauses the keys,
while OBS continues recording. Avoid other typing during a take. Between takes,
you can explore the sample vault normally. F5 discards those sample edits.

The sequence targets an overview under 60 seconds, including the three-second
countdown. It gathers work notes, personal notes, and Rust `todo!()` annotations
from three separate source directories. It filters by tag, moves a due date
forward and back, and uses Ctrl-t to set today. It then edits an unsaved Markdown
task, marks it irrelevant, and shows undo/redo and saving.

Ctrl-o and :Tasks return from Markdown sources. The code scene opens a real
`todo!("Sum the cart items #code");`, replaces it with `items.iter().sum()`,
saves, and uses Ctrl-6 to return. Refresh removes the resolved Rust task. The
final action checks off a task in the personal notes directory. Dates are
relative to the day of launch.

The Rust scene uses the opt-in annotation rule documented in
[the README](../README.md#tasks-in-code). All task edits use normal input;
checkbox actions cannot append Markdown markers to the Rust source.

## Record with OBS

Create a scene named **Taskbuffer demo**, add a window capture source, and select
the demo window. On Linux/Wayland use OBS's
[PipeWire window capture](https://obsproject.com/kb/window-capture-sources).
Approve the window selection in the desktop portal when prompted. Frame the
window so the task list, command line, and key display are visible; a 1080p
canvas at 30 fps is a reasonable starting point. Disable audio sources for a
silent README clip.

For a manual take, start recording in OBS, return to Neovim, press F5, and stop
recording after the final caption. The three-second countdown gives you room to
trim the beginning.

For automatic recording:

1. Launch with `python3 scripts/demo.py --record`.
2. In OBS, open **Tools → Scripts**, add
   [`scripts/demo/obs.lua`](../scripts/demo/obs.lua), and choose this repository's
   `.demo/control.json` in the script properties.
3. Set the script's capture scene to **Taskbuffer demo**, with the window capture
   already configured. Check the OBS preview.
4. Return to Neovim and press F5.

The script selects that scene and starts recording. Playback waits for OBS to
confirm recording before the countdown. OBS stops after the last caption, on
F8, on a playback error, or when the demo closes. It only stops recordings it
started, and refuses to take over an existing recording or stream. It does not
change OBS's output settings or choose a capture source for you. A missing OBS
script or scene produces an error in the demo instead of an unrecorded take.

This uses OBS's built-in [Lua scripting](https://docs.obsproject.com/scripting)
and [recording API](https://docs.obsproject.com/reference-frontend-api); no
WebSocket password, global keyboard injector, or elevated permissions are
needed. The scene and script settings persist for the next session.

Record to MKV, then use OBS's **File → Remux Recordings** for MP4. For a smaller,
silent web copy, substitute your recording's path:

```sh
ffmpeg -i take.mkv -an -c:v libx264 -preset slow -crf 20 \
  -pix_fmt yuv420p -movflags +faststart taskbuffer-demo.mp4
```

Keep the master recording separately. Upload the short MP4 to the GitHub README
editor or a release, and link to it from the README; avoid committing large
recordings to Git. A still frame can link to the full video.

## Edit and verify the storyboard

[`scripts/demo/sequence.lua`](../scripts/demo/sequence.lua) contains the sample
notes and the sequence. `p.keys()` feeds Neovim's real input queue through
[`nvim_input()`](https://neovim.io/doc/user/api/#nvim_input()). `p.wait()` yields
to the event loop until the editor reaches the expected state. `p.hold()` adds
reading time. For example:

```lua
p.scene("Mark an unsaved task irrelevant")
p.press("<Space>ti")
p.wait(function()
    return p.line():find("- [-]", 1, true)
        and p.line():find("::irrelevant", 1, true)
end, "irrelevant checkbox and marker")
p.hold(4000)
```

The player drives mappings and normal editing; it does not call task actions
directly. The key display listens to typed input with `vim.on_key`, rather than
printing the planned sequence. Consecutive typed characters are grouped into
words and commands in the display, with chords separated. Text is typed character by character; `p.press()`
delivers a mapping chord together so Neovim cannot block the player while waiting
for the rest of the mapping. Waits yield between inputs so scans, redraws,
Telescope, and editor events can run normally. This exercises Neovim input,
but does not test how a desktop or terminal translates physical keyboard events.

Verify two complete takes, including resetting the vault, without a display:

```sh
python3 scripts/demo.py --check
```

The same storyboard runs at higher speed and checks filtering, date shifts,
setting today, cursor tracking, all three return paths, unsaved edits, checkbox
state, native undo/redo, disk writes, all three source roots, Rust navigation,
and task removal.
It also checks for warning notifications and W10/W13 messages. It does not
validate OBS capture, the desktop portal, or the visual framing; inspect a short
recording on your desktop before making the final take.

A separate editor drives F5/F6/F8 through real input to verify pause, resume,
abort, reset, and controls used from insert or command-line mode.

`make demo-check` additionally tests the OBS script's start/stop handshake and
recording ownership using a mock OBS API. CI runs both checks on Linux with
stable Neovim and a pinned Telescope revision.

Each launch prints its temporary directory. It contains the disposable vault,
isolated editor state, and `result.json` with assertions, observed keys, and elapsed playback seconds
(including the countdown). The accelerated check duration is not the video duration.
These directories are retained for debugging. `.demo/` holds only ignored
coordination files. No demo hooks are loaded by the plugin during normal use.
