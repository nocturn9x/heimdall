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
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=("scalar", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "neon"))
    parser.add_argument("--runner", default="", help="Optional execution prefix, e.g. qemu-aarch64 -L /path/to/sysroot")
    args = parser.parse_args()
    directory = Path("build/simd") / args.backend
    directory.mkdir(parents=True, exist_ok=True)
    runner = shlex.split(args.runner)
    extension = ".exe" if sys.platform == "win32" else ""

    def run(command):
        print(shlex.join(map(str, command)), flush=True)
        subprocess.run(list(map(str, command)), check=True)

    def check(name, fixture, *flags):
        binary = directory / name
        run(["make", "dev", f"SIMD={args.backend}", "PGO=0", "SINGLE_LAYER=0", "IS_TEST=1", "IS_DEBUG=0",
             f"MAIN=tests/{name.split('-')[0]}.nim", f"EXE_BASE={binary}",
             f"EVALFILE={fixture.resolve()}", "EVAL_SCALE=400", "L1_SIZE=512", "L2_SIZE=16", "L3_SIZE=32",
             "INPUT_BUCKETS=16", "OUTPUT_BUCKETS=8", "DUAL_ACTIVATION=1", *flags])
        run([*runner, str(binary) + extension])

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
