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

"""OpenBench genfens regressions. Build first with make dev."""

import os
import subprocess
import unittest
from collections import Counter
from pathlib import Path


ENGINE = Path(os.environ.get("HEIMDALL", "bin/heimdall")).resolve()


class GenfensRegressionTests(unittest.TestCase):
    def generate(self, count, extra="", seed=123):
        result = subprocess.run(
            [str(ENGINE), f"genfens {count} seed {seed} book None {extra}", "quit"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        prefix = "info string genfens "
        fens = [line[len(prefix):] for line in result.stdout.splitlines()
                if line.startswith(prefix)]
        self.assertEqual(len(fens), count)
        for fen in fens:
            self.assertEqual(len(fen.split()), 6)
        return fens

    def test_dfrc_starts_and_seed_reproducibility(self):
        fens = self.generate(32, "dfrc true plies 0")
        self.assertEqual(fens, self.generate(32, "dfrc true plies 0"))
        self.assertNotEqual(fens, self.generate(32, "dfrc true plies 0", seed=124))
        self.assertGreater(len(set(fens)), 1)
        asymmetric = False
        for fen in fens:
            placement, turn, rights, ep, halfmove, fullmove = fen.split()
            ranks = placement.split("/")
            self.assertEqual(ranks[1:7], ["pppppppp", "8", "8", "8", "8", "PPPPPPPP"])
            self.assertEqual((turn, ep, halfmove, fullmove), ("w", "-", "0", "1"))
            asymmetric |= ranks[0].upper() != ranks[7]
            expected_rights = ""
            for rank, first_file in ((ranks[7], "A"), (ranks[0].upper(), "a")):
                self.assertEqual(Counter(rank), Counter("RNBQKBNR"))
                bishops = [i for i, piece in enumerate(rank) if piece == "B"]
                rooks = [i for i, piece in enumerate(rank) if piece == "R"]
                self.assertNotEqual(bishops[0] % 2, bishops[1] % 2)
                self.assertLess(rooks[0], rank.index("K"))
                self.assertLess(rank.index("K"), rooks[1])
                expected_rights += "".join(chr(ord(first_file) + i) for i in reversed(rooks))
            self.assertEqual(rights, expected_rights)
        self.assertTrue(asymmetric)

    def test_default_lengths_and_reproducibility(self):
        for extra in ("", "dfrc true"):
            with self.subTest(extra=extra):
                fens = self.generate(256, extra)
                self.assertEqual(fens, self.generate(256, extra))
                turns = Counter()
                for fen in fens:
                    fields = fen.split()
                    self.assertEqual(fields[5], "5")
                    turns[fields[1]] += 1
                # A fixed seed makes this repeatable; a broad interval catches
                # fixed lengths or severe bias without requiring exact RNG output.
                self.assertTrue(80 < turns["w"] < 176, turns)
                self.assertTrue(80 < turns["b"] < 176, turns)

    def test_explicit_lengths_and_disabled_dfrc(self):
        for option in ("plies", "moves", "depth"):
            with self.subTest(option=option):
                self.assertEqual(self.generate(1, f"dfrc false {option} 0"), [
                    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
                ])
                for fen in self.generate(8, f"dfrc true {option} 2"):
                    self.assertEqual((fen.split()[1], fen.split()[5]), ("w", "2"))

    def test_invalid_dfrc_values(self):
        for extra in ("dfrc", "dfrc maybe"):
            with self.subTest(extra=extra):
                result = subprocess.run(
                    [str(ENGINE), f"genfens 1 seed 123 book None {extra}", "quit"],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dfrc requires true or false", result.stderr)


if __name__ == "__main__":
    unittest.main()
