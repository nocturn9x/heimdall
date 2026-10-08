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

"""Android build checks; device tests opt in with HEIMDALL_ANDROID (remote path)."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANDROID_ENGINE = os.environ.get("HEIMDALL_ANDROID")
REFERENCE = os.environ.get("HEIMDALL_ANDROID_REFERENCE")


@unittest.skipUnless(shutil.which("make") and os.name == "posix", "requires POSIX make")
class AndroidBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.ndk = Path(self.temporary.name)
        for host in ("linux-x86_64", "darwin-x86_64", "windows-x86_64"):
            compiler = self.ndk / "toolchains/llvm/prebuilt" / host / "bin"
            compiler.mkdir(parents=True)
            for name in ("clang", "clang.exe"):
                (compiler / name).touch()

    def build(self, *flags, target="dev", success=True):
        result = subprocess.run(
            ["make", "--no-print-directory", "-n", target, "TARGET=android",
             f"ANDROID_NDK_HOME={self.ndk}", "ANDROID_HOST_TAG=linux-x86_64",
             "ANDROID_ABI=arm64-v8a", "ANDROID_API=21", "SIMD=auto", "PGO=0",
             "OS=", "UNAME_S=Linux", "EXTRA_NFLAGS=", *flags],
            cwd=ROOT, text=True, capture_output=True,
            env={k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS")},
        )
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("nimble install", output)
            self.assertNotIn("git submodule", output)
            self.assertNotIn("git lfs", output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def test_arm64_baseline_and_android_linker(self):
        output = self.build()
        for flag in ("--cpu:arm64", "--os:android", "--target=aarch64-linux-android21",
                     "-march=armv8-a", "-d:neon", "-fPIE", "-pie", "-d:noTHP",
                     "-z,max-page-size=16384", "-z,common-page-size=16384",
                     "bin/heimdall-android-arm64-v8a"):
            self.assertIn(flag, output)
        for flag in ("-static", "-march=native", "-mcpu=native", "-d:avx2"):
            self.assertNotIn(flag, output)
        self.assertIn(f'--clang.exe:"{self.ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"', output)

    def test_x86_64_uses_target_baseline(self):
        output = self.build("ANDROID_ABI=x86_64")
        for flag in ("--cpu:amd64", "--target=x86_64-linux-android21",
                     "-march=x86-64", "-d:sse2", "bin/heimdall-android-x86_64"):
            self.assertIn(flag, output)
        self.assertNotIn("-d:avx2", output)
        self.assertNotIn("-march=native", output)

    def test_scalar_and_universal_for_both_abis(self):
        for abi in ("arm64-v8a", "x86_64"):
            with self.subTest(abi=abi):
                scalar = self.build(f"ANDROID_ABI={abi}", "SIMD=scalar")
                self.assertNotIn(" -d:simd", scalar)
                self.assertNotIn("-march=native", scalar)
                universal = self.build(f"ANDROID_ABI={abi}", "SIMD=universal")
                self.assertIn("-d:runtimeSimd", universal)

    def test_host_platform_flags_do_not_leak(self):
        for flags in (("UNAME_S=Darwin", "ANDROID_HOST_TAG=darwin-x86_64"),
                      ("OS=Windows_NT", "ANDROID_HOST_TAG=windows-x86_64")):
            with self.subTest(flags=flags):
                output = self.build(*flags)
                self.assertNotIn("-mmacosx", output)
                self.assertNotIn("/stack:", output)
                self.assertNotIn("heimdall-android-arm64-v8a.exe", output)
                self.assertIn("--target=aarch64-linux-android21", output)

    def test_output_and_api_overrides(self):
        output = self.build("ANDROID_API=28", "EXE_BASE=bin/android-custom",
                            "MAIN=tests/test_alloc.nim", "IS_TEST=1")
        self.assertIn("--target=aarch64-linux-android28", output)
        self.assertIn("-o:bin/android-custom", output)
        self.assertIn("tests/test_alloc.nim", output)
        self.assertIn("api-28/auto", output)

    def test_convenience_target_skips_dependency_fetching(self):
        self.assertIn("TARGET=android", self.build(target="android"))

    def test_invalid_configuration_is_rejected(self):
        for flags, message in (
            (("ANDROID_ABI=armeabi-v7a",), "Unsupported ANDROID_ABI"),
            (("ANDROID_API=19",), "ANDROID_API must be an integer >= 21"),
            (("ANDROID_API=invalid",), "ANDROID_API must be an integer >= 21"),
            (("ANDROID_NDK_HOME=",), "Set ANDROID_NDK_HOME"),
            (("ANDROID_NDK_HOME=/missing-heimdall-ndk",), "Android NDK Clang not found"),
            (("SIMD=avx2",), "incompatible with ANDROID_ABI"),
            (("ANDROID_ABI=x86_64", "SIMD=neon"), "incompatible with ANDROID_ABI"),
            (("PGO=1",), "cannot run host PGO training"),
        ):
            with self.subTest(flags=flags):
                self.assertIn(message, self.build(*flags, success=False))


@unittest.skipUnless(ANDROID_ENGINE and shutil.which("adb"), "set HEIMDALL_ANDROID and connect adb")
class AndroidRuntimeTests(unittest.TestCase):
    def run_commands(self, commands):
        # adb honours ANDROID_SERIAL when more than one device is connected.
        result = subprocess.run(
            ["adb", "shell", "-T", "exec " + shlex.quote(ANDROID_ENGINE)],
            input=commands + "\nisready\nquit\n", text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("readyok", result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("cmd>", result.stdout)
        return result.stdout

    def test_plain_uci_handshake(self):
        output = self.run_commands("uci")
        self.assertRegex(output, r"(?m)^id name Heimdall ")
        self.assertIn("uciok", output)

    def test_perft_and_special_moves(self):
        for position, depth, nodes in (
            ("startpos", 4, 197281),
            ("fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3, 97862),
        ):
            with self.subTest(position=position):
                output = self.run_commands(f"uci\nposition {position}\ngo perft {depth} bulk")
                self.assertIn(f"Nodes searched (bulk-counting: on): {nodes}", output)

    def test_search_worker_lifecycle(self):
        output = self.run_commands(
            "uci\nsetoption name Hash value 8\nsetoption name Threads value 4\n"
            "position startpos\ngo depth 4\nwait\ngo infinite\nstop\n"
            "setoption name Threads value 2\nucinewgame\nposition startpos\ngo depth 3\nwait"
        )
        self.assertEqual(output.count("bestmove "), 3, output)
        self.assertIn("info depth 4 ", output)
        self.assertIn("info depth 3 ", output)

    @unittest.skipUnless(REFERENCE, "set HEIMDALL_ANDROID_REFERENCE to a matching native build")
    def test_deterministic_search_matches_native(self):
        commands = (
            "uci\nsetoption name Hash value 8\nposition startpos\ngo depth 4\nwait\n"
            "ucinewgame\nposition startpos moves e2e4 e7e5 g1f3 b8c6\ngo depth 4\nwait\n"
            "ucinewgame\nposition fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1\n"
            "go depth 4\nwait"
        )
        android = self.run_commands(commands)
        native = subprocess.run(
            [REFERENCE], input=commands + "\nisready\nquit\n", text=True,
            capture_output=True, timeout=60, env={**os.environ, "NO_COLOR": "1", "NO_LOGO": "1"},
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)

        def results(output):
            scores = re.findall(r"^info depth 4 .*? score (cp|mate) (-?\d+).*? nodes (\d+).*? pv (.*)$",
                                output, re.MULTILINE)
            moves = re.findall(r"^bestmove (.*)$", output, re.MULTILINE)
            return scores, moves

        self.assertEqual(len(results(android)[0]), 3, android)
        self.assertEqual(results(android), results(native.stdout))


if __name__ == "__main__":
    unittest.main()
