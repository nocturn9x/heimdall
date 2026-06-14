#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify built binaries match the bench recorded in a commit message"
    )
    parser.add_argument("--commit", default="HEAD", help="commit to read the expected bench from")
    parser.add_argument("--depth", default=13, type=int, help="bench depth to run")
    parser.add_argument("binaries", nargs="+", help="binaries to verify")
    args = parser.parse_args()
    if args.depth < 0:
        parser.error("--depth must be non-negative")
    return args


def expected_bench(commit: str) -> str:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%B", commit],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    message = result.stdout
    match = re.search(r"\(bench\s+([0-9]+)\)", message)
    if match is None:
        match = re.search(r"bench:\s*([0-9]+)", message)
    if match is None:
        raise RuntimeError(f"could not find '(bench N)' or 'bench: N' in commit '{commit}'")
    return match.group(1)


def actual_bench(binary: Path, depth: int) -> tuple[int, str | None, str]:
    result = subprocess.run(
        [str(binary), "bench", str(depth), "-s"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    bench = None
    for line in result.stdout.splitlines():
        match = re.match(r"^([0-9]+) nodes ", line)
        if match is not None:
            bench = match.group(1)
    return result.returncode, bench, result.stdout


def main() -> int:
    args = parse_args()
    try:
        expected = expected_bench(args.commit)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    status = 0
    for binary_name in args.binaries:
        binary = Path(binary_name)
        if not binary.is_file():
            print(f"Error: binary '{binary}' does not exist", file=sys.stderr)
            status = 1
            continue

        print(f"Checking {binary} against bench {expected}")
        try:
            returncode, actual, output = actual_bench(binary, args.depth)
        except OSError as exc:
            print(f"Error: failed to run '{binary}': {exc}", file=sys.stderr)
            status = 1
            continue

        if returncode != 0:
            print(
                f"Error: '{binary} bench {args.depth} -s' failed with exit code {returncode}",
                file=sys.stderr,
            )
            print("\n".join(output.splitlines()[-20:]), file=sys.stderr)
            status = 1
        elif actual is None:
            print(f"Error: failed to extract bench from '{binary}' output", file=sys.stderr)
            print("\n".join(output.splitlines()[-20:]), file=sys.stderr)
            status = 1
        elif actual != expected:
            print(f"Error: '{binary}' bench was {actual}, expected {expected}", file=sys.stderr)
            status = 1
        else:
            print(f"{binary}: bench {actual}")

    return status


if __name__ == "__main__":
    raise SystemExit(main())
