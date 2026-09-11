#!/usr/bin/env python3
"""Run Lua tests in an isolated editor and expose useful failures in CI checks."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="taskbuffer-tests-") as temporary:
    env = dict(os.environ)
    for category in ("CONFIG", "DATA", "STATE", "CACHE"):
        env[f"XDG_{category}_HOME"] = str(Path(temporary) / category.lower())
    env["NVIM_LOG_FILE"] = str(Path(temporary) / "nvim.log")
    result = subprocess.run(
        ["nvim", "--headless", "-i", "NONE", "-u", "tests/minimal_init.lua", "-c", "PlenaryBustedDirectory tests/"],
        cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    print(result.stdout, end="", flush=True)
    if result.returncode and env.get("GITHUB_ACTIONS") == "true":
        lines = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout).splitlines()
        selected = set(range(min(15, len(lines))))
        selected.update(range(max(0, len(lines) - 20), len(lines)))
        for index, line in enumerate(lines):
            if re.search(r"(?:Fail|Error)\s*\|\||E\d{3}:", line):
                selected.update(range(index, min(index + 22, len(lines))))
        message = "\n".join(lines[i] for i in sorted(selected))[:16000]
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::error title=Lua test failures::" + message)
    raise SystemExit(result.returncode)
