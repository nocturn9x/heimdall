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

"""Run the same vec*, inference, and state checks for any Makefile backend."""

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=("universal", "scalar", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "neon"))
    parser.add_argument("--runner", default="", help="Optional execution prefix, e.g. qemu-aarch64 -L /path/to/sysroot")
    parser.add_argument("--directory", type=Path, help="Separate artifacts for cross builds")
    parser.add_argument("--exe-extension", default=".exe" if sys.platform == "win32" else "")
    args = parser.parse_args()
    directory = args.directory or Path("build/simd") / args.backend
    directory.mkdir(parents=True, exist_ok=True)
    runner = shlex.split(args.runner)
    extension = args.exe_extension
    environment = dict(os.environ)
    environment.pop("HEIMDALL_SIMD", None)
    runtime_backends = None

    def run(command, **kwargs):
        print(shlex.join(map(str, command)), flush=True)
        return subprocess.run(list(map(str, command)), check=True, **kwargs)

    def check(name, fixture, *flags):
        nonlocal runtime_backends
        binary = directory / name
        run(["make", "dev", f"SIMD={args.backend}", "PGO=0", "SINGLE_LAYER=0", "IS_TEST=1", "IS_DEBUG=0",
             f"MAIN=tests/{name.split('-')[0]}.nim", f"EXE_BASE={binary}",
             f"EVALFILE={fixture.resolve()}", "EVAL_SCALE=400", "L1_SIZE=512", "L2_SIZE=16", "L3_SIZE=32",
             "INPUT_BUCKETS=16", "OUTPUT_BUCKETS=8", "DUAL_ACTIVATION=1", *flags])
        command = [*runner, str(binary) + extension]
        if args.backend != "universal":
            run(command)
            return
        if runtime_backends is None:
            detected = run(command, env=environment, capture_output=True, text=True)
            print(detected.stdout, end="", flush=True)
            line = next(line for line in detected.stdout.splitlines() if line.startswith("Supported SIMD backends: "))
            runtime_backends = line.partition(": ")[2].split()
            assert "scalar" in runtime_backends
            for rejected in {"invalid", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "neon"} - set(runtime_backends):
                result = subprocess.run(command, env={**environment, "HEIMDALL_SIMD": rejected}, capture_output=True, text=True)
                assert result.returncode == 1, (rejected, result.returncode, result.stderr)
                assert "heimdall:" in result.stderr and rejected in result.stderr, result.stderr
        for backend in runtime_backends:
            print(f"Forcing {backend}", flush=True)
            run(command, env={**environment, "HEIMDALL_SIMD": backend})

    fixture = directory / "multilayer-ti.bin"
    run([sys.executable, "tests/make_multilayer_fixture.py", fixture])
    if args.backend != "scalar":
        check("test_simd", fixture)
    check("test_multilayer", fixture)
    check("test_nnue", fixture)
    check("test_threat_diff", fixture, "L1_SIZE=768")
    check("test_threat_updates", fixture)
    single_activation = directory / "single-activation-ti.bin"
    run([sys.executable, "tests/make_multilayer_fixture.py", single_activation, "--dual", "0"])
    check("test_multilayer-single-activation", single_activation, "DUAL_ACTIVATION=0")


if __name__ == "__main__":
    main()
