#!/usr/bin/env python3
"""Launch an isolated, replayable taskbuffer screencast in WezTerm."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify two takes headlessly, at high speed")
    parser.add_argument("--record", action="store_true", help="wait for the companion OBS script before playing")
    parser.add_argument("--deps", type=Path, default=Path.home() / ".local/share/nvim/lazy",
                        help="directory containing telescope.nvim and plenary.nvim (and optionally catppuccin)")
    args = parser.parse_args()
    if args.check and args.record:
        parser.error("--check and --record are mutually exclusive")
    for executable in ("nvim", "rg", "cp") + (() if args.check else ("wezterm",)):
        if not shutil.which(executable):
            parser.error(f"missing executable: {executable}")
    deps = args.deps.expanduser().resolve()
    for name in ("telescope.nvim", "plenary.nvim"):
        if not (deps / name / "lua").is_dir():
            parser.error(f"missing {deps / name}; install it or supply --deps DIR")

    output = repo / ".demo"
    output.mkdir(exist_ok=True)
    # One visible session owns the stable control file; checks use their own file.
    with (output / ("check.lock" if args.check else "runner.lock")).open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("a demo of this kind is already running")
        root = Path(tempfile.mkdtemp(prefix="taskbuffer-demo-"))
        for name in ("vault", "tmp", "state", "config", "data", "cache"):
            (root / name).mkdir()
        control = root / "control.json" if args.check else output / "control.json"
        config = {"repo": str(repo), "root": str(root), "deps": str(deps),
                  "control": str(control), "check": args.check, "record": args.record}
        config_path = root / "demo.json"
        config_path.write_text(json.dumps(config))
        control.write_text(json.dumps({"status": "idle", "record": args.record}))
        env = os.environ.copy()
        env.update({"TASKBUFFER_DEMO_CONFIG": str(config_path),
                    "XDG_CONFIG_HOME": str(root / "config"),
                    "XDG_DATA_HOME": str(root / "data"),
                    "XDG_STATE_HOME": str(root / "state"),
                    "XDG_CACHE_HOME": str(root / "cache"),
                    "NVIM_LOG_FILE": str(root / "nvim.log")})
        # Never inherit an editor server or startup commands from the calling shell.
        for key in ("NVIM", "NVIM_LISTEN_ADDRESS", "VIMINIT", "EXINIT"):
            env.pop(key, None)
        command = ["nvim", "-u", str(repo / "scripts/demo/init.lua"), "-i", "NONE", "--noplugin"]
        if args.check:
            command.insert(1, "--headless")
        else:
            command = ["wezterm", "--config-file", str(repo / "scripts/demo/wezterm.lua"),
                       "start", "--always-new-process", "--no-auto-connect", "--class",
                       "org.taskbuffer.demo", "--cwd", str(root / "vault"), *command]
        print(f"Disposable vault: {root / 'vault'}\nOBS control file: {control}", flush=True)
        try:
            result = subprocess.run(command, env=env, cwd=root / "vault", timeout=90 if args.check else None,
                                    capture_output=args.check, text=True)
        except subprocess.TimeoutExpired:
            parser.exit(1, f"Demo timed out. Inspect {root}\n")
        finally:
            # Also covers terminal launch failures and abrupt editor exits.
            try:
                state = json.loads(control.read_text())
                state["status"] = "closed"
                pending = control.with_suffix(".tmp")
                pending.write_text(json.dumps(state))
                pending.replace(control)
            except (OSError, ValueError):
                pass
        report = root / "result.json"
        if args.check:
            if not report.exists():
                parser.exit(1, f"No completed demo report. Inspect {root}\n")
            data = json.loads(report.read_text())
            if data.get("status") != "complete" or data.get("takes") != 2:
                print(result.stdout or "", result.stderr or "")
                print(json.dumps(data, indent=2))
                parser.exit(1)
            print(f"Passed: {data['takes']} takes, {len(data['checks'])} assertions; report: {report}", flush=True)
            controls = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", str(repo / "scripts/demo/test_controls.lua")],
                env=env, cwd=repo, timeout=30,
            )
            if controls.returncode:
                return controls.returncode
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
