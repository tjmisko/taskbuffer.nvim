#!/usr/bin/env python3
"""Exercise clean installs with native loading and lazy.nvim; never use user notes."""
import os
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
lazy = Path(os.environ.get("TASKBUFFER_TEST_LAZY", project / ".deps/lazy.nvim")).resolve()
if not (lazy / "lua/lazy/init.lua").is_file():
    raise SystemExit("Clone lazy.nvim into .deps/lazy.nvim or set TASKBUFFER_TEST_LAZY")

with tempfile.TemporaryDirectory(prefix="taskbuffer-install-") as temporary:
    root = Path(temporary)
    for mode in ("native", "lazy", "lazy-command"):
        env = dict(os.environ)
        case = root / mode
        for category in ("CONFIG", "DATA", "STATE", "CACHE"):
            env[f"XDG_{category}_HOME"] = str(case / category.lower())
        env["NVIM_LOG_FILE"] = str(case / "nvim.log")
        env["TASKBUFFER_TEST_ROOT"] = str(case)
        env["TASKBUFFER_TEST_MODE"] = mode
        env["TASKBUFFER_TEST_LAZY"] = str(lazy)
        case.mkdir()
        subprocess.run(
            ["nvim", "--headless", "-i", "NONE", "-u", str(project / "tests/install_init.lua")],
            cwd=project, env=env, check=True, timeout=30,
        )
        print(f"PASS: {mode} installation", flush=True)
