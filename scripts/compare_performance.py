#!/usr/bin/env python3
# Copyright 2026 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Authored with assistance from AI agents.

"""Alternate paired engine workloads on one CPU and save raw samples."""

import argparse
import hashlib
import json
import math
import os
import platform
import random
import re
import signal
import statistics
import subprocess
import time
from pathlib import Path

if __package__:
    from .uci_workload import load_positions, run_workload
else:
    from uci_workload import load_positions, run_workload


def run(binary, depth, cpu, timeout, counters=False, mode="search"):
    command = [str(binary)]
    commands = None
    if mode == "search":
        command += ["bench", str(depth), "--silent"]
    else:
        commands = f"position startpos\ngo perft {depth} bulk nosplit\nquit\n"
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]
    if counters:
        command = ["perf", "stat", "-x", "\t", "--no-big-num", "-e",
                   "instructions:u,cycles:u,branches:u,branch-misses:u", "--", *command]
    start = time.perf_counter()
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=os.name == "posix",
        env={**os.environ, "NO_COLOR": "1", "NO_LOGO": "1"},
    )
    try:
        stdout, stderr = process.communicate(commands, timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        # perf/taskset may be the direct child. Stop the engine beneath them too.
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    elapsed = time.perf_counter() - start
    if process.returncode:
        raise RuntimeError(f"{command} exited {process.returncode}:\n{stdout}\n{stderr}")
    if mode == "search":
        matches = re.findall(r"^(\d+) nodes (\d+) nps$", stdout, re.MULTILINE)
    else:
        counts = re.findall(r"^Nodes searched \(bulk-counting: on\): (\d+)$", stdout, re.MULTILINE)
        speeds = re.findall(r"^Nodes per second: (\d+)$", stdout, re.MULTILINE)
        matches = list(zip(counts, speeds)) if len(counts) == len(speeds) else []
    if len(matches) != 1:
        raise RuntimeError(f"Missing benchmark summary from {binary}:\n{stdout}")
    nodes, nps = map(int, matches[0])
    if not nodes or not nps:
        raise RuntimeError("Benchmark must report positive nodes and throughput")
    sample = {"nodes": nodes, "nps": nps, "cpu_seconds": nodes / nps,
              "wall_seconds": elapsed, "time": time.time()}
    if counters:
        sample["counters"] = {}
        for line in stderr.splitlines():
            fields = line.split("\t")
            if len(fields) > 2 and fields[2] in ("instructions:u", "cycles:u", "branches:u", "branch-misses:u"):
                sample["counters"][fields[2]] = float(fields[0])
        if len(sample["counters"]) != 4:
            raise RuntimeError(f"Missing perf counters:\n{stderr}")
    return sample


def summarize(samples):
    # Log ratios treat equivalent speedups and slowdowns symmetrically.
    ratios = [math.log(pair["candidate"]["nps"] / pair["baseline"]["nps"]) for pair in samples]
    rng = random.Random(0)
    boot = sorted(statistics.mean(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    percent = lambda value: 100 * math.expm1(value)
    summary = {
        "pairs": len(samples),
        "geomean_speedup_percent": percent(statistics.mean(ratios)),
        "median_speedup_percent": percent(statistics.median(ratios)),
        "bootstrap_95_percent": [percent(boot[250]), percent(boot[9749])],
        "baseline_median_nps": statistics.median(pair["baseline"]["nps"] for pair in samples),
        "candidate_median_nps": statistics.median(pair["candidate"]["nps"] for pair in samples),
    }
    if all("counters" in pair[name] for pair in samples for name in ("baseline", "candidate")):
        summary["counter_change_percent"] = {
            event: percent(statistics.mean(
                math.log(pair["candidate"]["counters"][event] / pair["baseline"]["counters"][event])
                for pair in samples
            ))
            for event in samples[0]["baseline"]["counters"]
            if all(pair[name]["counters"][event] > 0 for pair in samples for name in ("baseline", "candidate"))
        }
    return summary


def binary_info(path):
    with path.open("rb") as binary:
        digest = hashlib.file_digest(binary, "sha256").hexdigest()
    return {"path": str(path), "sha256": digest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--mode", choices=("search", "perft", "uci"), default="search")
    parser.add_argument("--depth", type=int)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--perf", action="store_true", help="Record four user-space hardware counters")
    parser.add_argument("--positions", type=Path, help="FEN corpus for --mode uci")
    parser.add_argument("--count", type=int, default=24)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--stride", type=int, default=1)
    parser.add_argument("--limit-kind", choices=("nodes", "time"), default="nodes")
    parser.add_argument("--limit", type=int, default=200000, help="Nodes or milliseconds per UCI position")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.depth is None:
        args.depth = 14 if args.mode == "search" else 6
    if args.pairs < 2 or args.warmups < 0 or args.depth < 1:
        parser.error("need at least two pairs, nonnegative warmups and a positive depth")
    binaries = {"baseline": args.baseline.resolve(strict=True), "candidate": args.candidate.resolve(strict=True)}
    report = {"host": platform.platform(), "mode": args.mode,
              "depth": args.depth if args.mode != "uci" else None, "cpu": args.cpu,
              "binaries": {name: binary_info(path) for name, path in binaries.items()}, "samples": []}
    if args.mode == "uci":
        if args.positions is None or args.limit < 1 or args.threads < 1:
            parser.error("UCI mode needs --positions and positive limit/threads")
        try:
            positions = load_positions(args.positions, args.count, args.offset, args.stride)
        except ValueError as error:
            parser.error(str(error))
        report["workload"] = {"positions": positions, "limit_kind": args.limit_kind,
                              "limit": args.limit, "threads": args.threads}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    expected_nodes = None
    expected_searches = None

    def sample(name):
        nonlocal expected_nodes, expected_searches
        if args.mode == "uci":
            value = run_workload(binaries[name], positions, args.limit_kind, args.limit,
                                 args.threads, args.cpu, args.timeout, args.perf)
        else:
            value = run(binaries[name], args.depth, args.cpu, args.timeout, args.perf, args.mode)
        if expected_nodes is None:
            expected_nodes = value["nodes"]
        deterministic = args.mode != "uci" or (args.limit_kind == "nodes" and args.threads == 1)
        if deterministic and value["nodes"] != expected_nodes:
            raise RuntimeError(f"Node count changed: {name} reports {value['nodes']}, expected {expected_nodes}")
        if deterministic and args.mode == "uci":
            signatures = [(search["nodes"], search["depth"], search["bestmove"])
                          for search in value["searches"]]
            if expected_searches is None:
                expected_searches = signatures
            if signatures != expected_searches:
                raise RuntimeError(f"Fixed-node search results changed for {name}")
        return value

    for _ in range(args.warmups):
        for name in binaries:
            sample(name)
    for index in range(args.pairs):
        order = ["baseline", "candidate"] if index % 2 == 0 else ["candidate", "baseline"]
        pair = {"order": order}
        for name in order:
            pair[name] = sample(name)
        report["samples"].append(pair)
        report["summary"] = summarize(report["samples"])
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Pair {index + 1}/{args.pairs}: baseline {pair['baseline']['nps']:,.0f} nps; "
              f"candidate {pair['candidate']['nps']:,.0f} nps", flush=True)
    print(json.dumps(report["summary"], indent=2), flush=True)


if __name__ == "__main__":
    main()
