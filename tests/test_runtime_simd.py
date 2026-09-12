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

"""Exercise startup dispatch and identical search trees in a universal engine."""
import os
from pathlib import Path
import re
import subprocess
import unittest


ENGINE = Path(os.environ.get("HEIMDALL", "bin/heimdall")).resolve()


class RuntimeSimdTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = {**os.environ, "NO_COLOR": "1", "NO_LOGO": "1"}
        cls.environment.pop("HEIMDALL_SIMD", None)
        detected = subprocess.run([str(ENGINE), "simd"], env=cls.environment,
                                  capture_output=True, text=True, timeout=15, check=True)
        cls.backends = next(line.partition(": ")[2].split() for line in detected.stdout.splitlines()
                            if line.startswith("Supported SIMD backends: "))
        if len(cls.backends) == 1:
            raise unittest.SkipTest("requires a SIMD=universal build")

    def test_forced_backends_and_auto_selection(self):
        for backend in [*self.backends, "auto"]:
            with self.subTest(backend=backend):
                result = subprocess.run([str(ENGINE), "simd"], capture_output=True, text=True, timeout=15,
                                        env={**self.environment, "HEIMDALL_SIMD": backend})
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = self.backends[-1] if backend == "auto" else backend
                self.assertIn("SIMD backend: " + expected + "\n", result.stdout)

    def test_unknown_and_unsupported_backends_fail_before_execution(self):
        all_backends = {"scalar", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "neon"}
        for backend in {"invalid"} | (all_backends - set(self.backends)):
            with self.subTest(backend=backend):
                result = subprocess.run([str(ENGINE), "simd"], capture_output=True, text=True, timeout=15,
                                        env={**self.environment, "HEIMDALL_SIMD": backend})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(backend, result.stderr)
                self.assertIn("heimdall:", result.stderr)

    def test_fixed_depth_search_matches_across_backends(self):
        for position in ["startpos", "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"]:
            expected = None
            for backend in self.backends:
                with self.subTest(position=position, backend=backend):
                    commands = ("uci\nsetoption name Threads value 1\nposition " + position +
                                "\ngo depth 4\nwait\nquit\n")
                    result = subprocess.run([str(ENGINE)], input=commands, capture_output=True, text=True, timeout=30,
                                            env={**self.environment, "HEIMDALL_SIMD": backend})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    lines = result.stdout.splitlines()
                    final = next(line for line in reversed(lines) if line.startswith("info depth 4 "))
                    tree = (re.search(r"\bscore (cp|mate) (-?\d+)", final).groups(),
                            re.search(r"\bnodes (\d+)", final).group(1),
                            next(line for line in lines if line.startswith("bestmove ")))
                    if expected is None:
                        expected = tree
                    self.assertEqual(tree, expected)


if __name__ == "__main__":
    unittest.main()
