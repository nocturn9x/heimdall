#!/usr/bin/env python3
"""Run a selected FEN corpus with real UCI node or time limits (also PGO training)."""

import argparse
import os
import re
import signal
import subprocess
import time
from pathlib import Path


def load_positions(path, count=24, offset=0, stride=1):
    if count < 1 or offset < 0 or stride < 1:
        raise ValueError("count/stride must be positive and offset nonnegative")
    positions = list(dict.fromkeys(
        " ".join(line.split()) for line in path.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ))
    selected = positions[offset::stride][:count]
    if len(selected) != count:
        raise ValueError(f"requested {count} positions, found only {len(selected)}")
    return selected


def commands_for(positions, limit_kind, limit, threads):
    if limit_kind not in ("nodes", "time") or limit < 1 or threads < 1:
        raise ValueError("invalid workload limit or thread count")
    commands = ["uci", "setoption name Hash value 64",
                f"setoption name Threads value {threads}",
                "setoption name UCI_Chess960 value true",
                "setoption name MoveOverhead value 0"]
    go = "nodes" if limit_kind == "nodes" else "movetime"
    for fen in positions:
        if "\n" in fen or "\r" in fen or len(fen.split()) != 6:
            raise ValueError("expected one six-field FEN per position")
        commands += ["ucinewgame", f"position fen {fen}", f"go {go} {limit}", "wait"]
    return "\n".join([*commands, "quit", ""])


def parse_output(output, count):
    games = re.split(r"^bestmove .*$", output, flags=re.MULTILINE)
    bestmoves = re.findall(r"^bestmove (.*)$", output, re.MULTILINE)
    if len(games) != count + 1:
        raise RuntimeError(f"expected {count} completed searches, got {len(games) - 1}")
    result = []
    for game, bestmove in zip(games[:-1], bestmoves):
        lines = re.findall(r"^info depth (\d+) .*\btime (\d+) nodes (\d+)\b.*$", game, re.MULTILINE)
        if not lines:
            raise RuntimeError("search has no completed info summary")
        depth, milliseconds, nodes = map(int, lines[-1])
        if not nodes or not milliseconds:
            raise RuntimeError("workload search is too short or terminal; use another corpus/budget")
        result.append({"nodes": nodes, "milliseconds": milliseconds,
                       "depth": depth, "bestmove": bestmove})
    return result


def run_workload(binary, positions, limit_kind="nodes", limit=200000, threads=1,
                 cpu=None, timeout=300, counters=False):
    commands = commands_for(positions, limit_kind, limit, threads)
    command = [str(binary)]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]
    if counters:
        command = ["perf", "stat", "-x", "\t", "--no-big-num", "-e",
                   "instructions:u,cycles:u,branches:u,branch-misses:u", "--", *command]
    started = time.perf_counter()
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=os.name == "posix",
        env={**os.environ, "NO_COLOR": "1", "NO_LOGO": "1"},
    )
    try:
        stdout, stderr = process.communicate(commands, timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    if process.returncode:
        raise RuntimeError(f"workload exited {process.returncode}:\n{stdout}\n{stderr}")
    searches = parse_output(stdout, len(positions))
    nodes = sum(search["nodes"] for search in searches)
    seconds = sum(search["milliseconds"] for search in searches) / 1000
    sample = {"nodes": nodes, "nps": nodes / seconds, "search_seconds": seconds,
              "wall_seconds": time.perf_counter() - started, "time": time.time(),
              "searches": searches}
    if counters:
        sample["counters"] = {}
        for line in stderr.splitlines():
            fields = line.split("\t")
            if len(fields) > 2 and fields[2] in ("instructions:u", "cycles:u", "branches:u", "branch-misses:u"):
                sample["counters"][fields[2]] = float(fields[0])
        if len(sample["counters"]) != 4:
            raise RuntimeError(f"missing perf counters:\n{stderr}")
    return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--positions", type=Path, required=True)
    parser.add_argument("--count", type=int, default=24)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--stride", type=int, default=1)
    parser.add_argument("--limit-kind", choices=("nodes", "time"), default="nodes")
    parser.add_argument("--limit", type=int, default=200000)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--cpu", type=int)
    args = parser.parse_args()
    positions = load_positions(args.positions, args.count, args.offset, args.stride)
    sample = run_workload(args.binary.resolve(strict=True), positions, args.limit_kind,
                          args.limit, args.threads, args.cpu)
    print(f"{sample['nodes']} nodes {round(sample['nps'])} nps")


if __name__ == "__main__":
    main()
