#!/usr/bin/env python3
"""Isolated startup comparisons and task workloads; no user config or task data."""

import argparse
from datetime import date
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def summary(values):
    values = sorted(values)
    return {
        "median_ms": statistics.median(values),
        "p95_ms": values[math.ceil(len(values) * 0.95) - 1],
        "max_ms": max(values),
    }


def run_nvim(argv, env, directory, timeout):
    try:
        subprocess.run(
            argv, env=env, cwd=directory, check=True, capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = error.stderr or ""
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise SystemExit(f"Neovim benchmark failed ({env['TASKBUFFER_BENCH_MODE']}): {error}\n{detail}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", type=positive, default=100)
    parser.add_argument("--tasks-per-file", type=positive, default=20)
    parser.add_argument("--runs", type=positive, default=10)
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--json", type=Path, help="also save the full measurements")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    script = root / "scripts/benchmark.lua"
    results = {"files": args.files, "tasks_per_file": args.tasks_per_file, "runs": args.runs}

    with tempfile.TemporaryDirectory(prefix="taskbuffer-bench-") as temporary:
        directory = Path(temporary)
        for name in ("vault", "output", "state", "config", "data", "cache"):
            (directory / name).mkdir()
        today = date.today().isoformat()
        for index in range(args.files):
            lines = ["---", "tags:", "  - project", "  - benchmark", f"due: {today}", "---", ""]
            lines += [
                f"- [ ] Task {index}/{task} <30m> #bench (@[[{today}]] 12:00)"
                for task in range(args.tasks_per_file)
            ]
            (directory / "vault" / f"note-{index:05}.md").write_text("\n".join(lines) + "\n")

        env = dict(os.environ)
        env.update({
            "XDG_CONFIG_HOME": str(directory / "config"),
            "XDG_DATA_HOME": str(directory / "data"),
            "XDG_STATE_HOME": str(directory / "state"),
            "XDG_CACHE_HOME": str(directory / "cache"),
            "TASKBUFFER_BENCH_ROOT": str(root),
            "TASKBUFFER_BENCH_DIR": temporary,
            "TASKBUFFER_BENCH_RUNS": str(args.runs),
        })
        results["nvim"] = subprocess.check_output([args.nvim, "--version"], text=True).splitlines()[0]
        startup = {mode: [] for mode in ("baseline", "commands", "setup")}
        # Interleave cases to reduce drift; discard one warmup for each case.
        for run in range(args.runs + 1):
            for mode in startup:
                env["TASKBUFFER_BENCH_MODE"] = mode
                log = directory / f"startup-{run}-{mode}.log"
                run_nvim(
                    [args.nvim, "--headless", "-i", "NONE", "-u", str(script), "--startuptime", str(log)],
                    env, directory, 30,
                )
                started = next(line for line in log.read_text().splitlines() if "NVIM STARTED" in line)
                if run:
                    startup[mode].append(float(started.split()[0]))
        results["startup"] = {mode: summary(values) for mode, values in startup.items()}
        env["TASKBUFFER_BENCH_MODE"] = "workload"
        run_nvim(
            [args.nvim, "--headless", "-i", "NONE", "-u", "NONE", "-l", str(script)],
            env, directory, 300,
        )
        results["workload"] = json.loads((directory / "workload.json").read_text())

    print(f"{results['nvim']}; {args.files} files, {args.files * args.tasks_per_file} checkbox tasks, {args.runs} runs")
    print("Startup: milliseconds to NVIM STARTED (fresh processes, warm filesystem cache)")
    print(f"{'case':30} {'median':>10} {'p95':>10} {'max':>10}")
    for mode, row in results["startup"].items():
        print(f"{mode:30} {row['median_ms']:10.3f} {row['p95_ms']:10.3f} {row['max_ms']:10.3f}")
    baseline = results["startup"]["baseline"]["median_ms"]
    for mode in ("commands", "setup"):
        delta = results["startup"][mode]["median_ms"] - baseline
        print(f"{mode} median delta vs baseline: {delta:+.3f} ms")
    for scenario in ("setup", "first_open", "reopen", "bufenter", "source_refresh", "view_changes", "tags"):
        snapshot = results["workload"][scenario]
        print(f"\n{scenario}: inclusive milliseconds; p95 of latest {snapshot['sample_limit']} samples")
        print(f"{'stage':30} {'count':>7} {'mean':>10} {'p95':>10} {'max':>10}")
        for row in snapshot["stages"]:
            print(f"{row['name']:30} {row['count']:7} {row['mean_ms']:10.3f} {row['p95_ms']:10.3f} {row['max_ms']:10.3f}")
    if args.json:
        args.json.write_text(json.dumps(results, indent=2) + "\n")
        print(f"\nSaved {args.json}")


if __name__ == "__main__":
    main()
