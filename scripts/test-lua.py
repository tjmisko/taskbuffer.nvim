#!/usr/bin/env python3
"""Run Lua tests in an isolated editor and expose useful failures in CI checks."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("spec", nargs="?", help="Run one test file instead of the full suite")
args = parser.parse_args()
command = "PlenaryBustedDirectory tests/"
if args.spec:
    spec = Path(args.spec).resolve()
    if not spec.is_relative_to(project / "tests") or not spec.name.endswith("_spec.lua") or not spec.is_file():
        parser.error("spec must be an existing tests/*_spec.lua file")
    command = "lua require('plenary.test_harness').test_file(vim.env.TASKBUFFER_TEST_SPEC)"
with tempfile.TemporaryDirectory(prefix="taskbuffer-tests-") as temporary:
    env = dict(os.environ)
    for category in ("CONFIG", "DATA", "STATE", "CACHE"):
        env[f"XDG_{category}_HOME"] = str(Path(temporary) / category.lower())
    env["NVIM_LOG_FILE"] = str(Path(temporary) / "nvim.log")
    if args.spec:
        env["TASKBUFFER_TEST_SPEC"] = str(spec)
    result = subprocess.run(
        ["nvim", "--headless", "-i", "NONE", "-u", "tests/minimal_init.lua", "-c", command],
        cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        timeout=120,
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
