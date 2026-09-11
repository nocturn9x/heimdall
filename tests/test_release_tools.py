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

"""Check release compatibility decisions for canonical feature-set names."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "check_binary_benches", Path(__file__).resolve().parents[1] / "scripts" / "check_binary_benches.py"
)
benches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benches)

# The v3 baseline, independent of a particular CPU tuning choice.
V3 = {"sse2", "sse3", "ssse3", "sse4_1", "sse4_2", "popcnt", "cx16", "lahf_lm",
      "avx", "avx2", "fma", "f16c", "bmi1", "bmi2", "lzcnt", "movbe"}
V4 = V3 | {"avx512f", "avx512bw", "avx512cd", "avx512dq", "avx512vl"}


class ReleaseCompatibilityTests(unittest.TestCase):
    def test_avx2_bit_alone_does_not_establish_v3_compatibility(self):
        binary = Path("heimdall-1.5.1-linux-amd64-avx2")
        for missing in ["movbe", "f16c", "lahf_lm", "cx16", "bmi2"]:
            with self.subTest(missing=missing):
                self.assertIn(missing, benches.unsupported_reason(binary, V3 - {missing}))
        self.assertIsNone(benches.unsupported_reason(binary, V3))

    def test_vnni_requires_the_complete_v4_baseline_and_vnni(self):
        binary = Path("heimdall-1.5.1-windows-amd64-avx512-vnni.exe")
        self.assertIn("avx512vnni", benches.unsupported_reason(binary, V4))
        self.assertIn("avx512dq", benches.unsupported_reason(binary, V4 - {"avx512dq"} | {"avx512vnni"}))
        self.assertIsNone(benches.unsupported_reason(binary, V4 | {"avx512vnni"}))

    def test_pre_avx_cpus_can_use_their_matching_releases(self):
        sse2 = {"sse2"}
        core2 = sse2 | {"sse3", "ssse3"}
        self.assertIsNone(benches.unsupported_reason(Path("heimdall-1.5.1-linux-amd64-sse2"), sse2))
        self.assertIsNone(benches.unsupported_reason(Path("heimdall-1.5.1-linux-amd64-ssse3"), core2))
        self.assertIn("sse4_1", benches.unsupported_reason(Path("heimdall-1.5.1-linux-amd64-sse41"), core2))

    def test_only_the_final_artifact_suffix_selects_the_feature_set(self):
        binary = Path("Heimdall-dev-avx512-vnni-windows-amd64-SSE2.EXE")
        self.assertIsNone(benches.unsupported_reason(binary, {"sse2"}))

    def test_linux_cpu_feature_aliases_are_normalized(self):
        with patch.object(benches.Path, "is_file", return_value=True), \
             patch.object(benches.Path, "read_text", return_value="flags : pni abm avx2\n"):
            flags = benches.proc_cpuinfo_flags()
        self.assertTrue({"sse3", "lzcnt", "avx2"} <= flags)


if __name__ == "__main__":
    unittest.main()
