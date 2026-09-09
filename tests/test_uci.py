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

"""UCI regressions. Build first with make dev; override the binary with HEIMDALL."""

import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path


ENGINE = Path(os.environ.get("HEIMDALL", "bin/heimdall")).resolve()


class UCIRegressionTests(unittest.TestCase):
    def run_commands(self, commands, cpu=None):
        command = [str(ENGINE)]
        if cpu is not None:
            command = ["taskset", "-c", str(cpu), *command]
        result = subprocess.run(
            command, input=commands + "\nisready\nquit\n", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10,
            env={**os.environ, "NO_COLOR": "1", "NO_LOGO": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("readyok", result.stdout)
        return result.stdout

    def test_missing_arguments_are_rejected_without_crashing(self):
        commands = ["position", "setoption", "setoption name", "setoption name Hash",
                    "setoption name Hash value", "set value 1", "getScale", "getScale 1"]
        commands += ["go " + name for name in
                     ("wtime", "btime", "winc", "binc", "movestogo", "depth",
                      "movetime", "nodes", "mate", "perft")]
        output = self.run_commands("\n".join(commands))
        self.assertEqual(output.count("unknown or invalid command"), len(commands), output)

    def test_bad_depths_and_dfrc_index_are_rejected(self):
        commands = ["go perft -1", "go depth -1", "go depth 0", "position dfrc -1",
                    "getScale abc 1"]
        output = self.run_commands("\n".join(commands))
        self.assertEqual(output.count("unknown or invalid command"), len(commands), output)

    def test_tabs_separate_uci_tokens(self):
        output = self.run_commands("position\tstartpos\ngo\tperft\t1\tbulk")
        self.assertIn("Nodes searched (bulk-counting: on): 20", output)

    def test_button_options_need_no_value(self):
        output = self.run_commands("setoption name TTClear\nsetoption name HClear")
        self.assertNotIn("error", output.lower())

    def test_option_values_preserve_spaces(self):
        output = self.run_commands("debug on\nsetoption name Unknown Option value Some Path With Spaces")
        self.assertIn('name: "Unknown Option", value: "Some Path With Spaces"', output)

    def test_searchmoves_can_precede_limits(self):
        output = self.run_commands("position startpos\ngo searchmoves e2e4 depth 1\nwait")
        self.assertIn("bestmove e2e4", output)

    def test_rejected_searches_do_not_block_stop_or_the_next_search(self):
        for command in ("go wtime 1000 btime 1000", "go movestogo 40 depth 1", "go ponder depth 1"):
            with self.subTest(command=command):
                output = self.run_commands(command + "\nstop\nucinewgame\ngo depth 1\nwait")
                self.assertIn("bestmove 0000", output)
                self.assertEqual(output.count("bestmove "), 2, output)
                self.assertNotIn("cannot start a new game", output)

    def test_time_control_exemptions_still_search(self):
        for commands in (
            "go wtime 1000 btime 1000 winc 10 binc 10 depth 1",
            "go wtime 1000 btime 1000 movetime 100 depth 1",
            "setoption name EnableWeirdTCs value true\ngo wtime 1000 btime 1000 depth 1",
        ):
            with self.subTest(commands=commands):
                output = self.run_commands(commands + "\nwait")
                self.assertIn("bestmove ", output)
                self.assertNotIn("bestmove 0000", output)

    def test_setting_current_hash_size_does_not_resize(self):
        output = self.run_commands("debug on\nsetoption name Hash value 64\n"
                                   "setoption name Hash value 1\nsetoption name Hash value 1")
        self.assertEqual(output.count("resizing TT"), 1, output)
        self.assertIn("resizing TT from 64 MiB To 1 MiB", output)

    def test_depth_limits_complete_all_multipv_lines(self):
        for threads in (1, 4):
            for depth in (1, 2, 3):
                for extra in ("", " nodes 1000000", " movetime 10000",
                              " nodes 1000000 movetime 10000"):
                    with self.subTest(threads=threads, depth=depth, extra=extra):
                        output = self.run_commands(
                            f"uci\nsetoption name Threads value {threads}\n"
                            "setoption name MultiPV value 3\nposition startpos\n"
                            f"go depth {depth}{extra}\nwait"
                        )
                        lines = [(int(d), int(pv)) for d, pv in re.findall(
                            r"^info depth (\d+) .*?\bmultipv (\d+)\b", output, re.MULTILINE
                        )]
                        self.assertEqual({pv for d, pv in lines if d == depth}, {1, 2, 3}, output)
                        # Workers have no local depth limit; existing result
                        # selection may report a deeper worker PV at shutdown.
                        if threads == 1:
                            self.assertEqual(max(d for d, _ in lines), depth, output)
                        self.assertEqual(output.count("bestmove "), 1, output)

    def test_node_limit_can_interrupt_a_multipv_depth_iteration(self):
        for threads in (1, 4):
            with self.subTest(threads=threads):
                output = self.run_commands(
                    f"uci\nsetoption name Threads value {threads}\n"
                    "setoption name MultiPV value 3\nposition startpos\n"
                    "go depth 128 nodes 2000\nwait"
                )
                counts = [int(value) for value in re.findall(r"\bnodes (\d+)\b", output)]
                self.assertTrue(counts, output)
                self.assertGreaterEqual(max(counts), 2000, output)
                self.assertLess(max(counts), 20000, output)
                self.assertEqual(output.count("bestmove "), 1, output)

    def test_node_limits_with_workers(self):
        for threads in (1, 4):
            with self.subTest(threads=threads):
                output = self.run_commands(
                    f"uci\nsetoption name Threads value {threads}\n"
                    "position startpos\ngo nodes 20000\nwait"
                )
                counts = [int(value) for value in re.findall(r"\bnodes (\d+)\b", output)]
                self.assertTrue(counts, output)
                self.assertGreaterEqual(max(counts), 20000, output)
                self.assertLess(max(counts), 100000, output)
                self.assertEqual(output.count("bestmove "), 1, output)

    def test_repeated_short_searches_and_worker_restarts(self):
        commands = ["uci"]
        searches = 0
        for threads in (4, 2, 8, 1):
            commands.append(f"setoption name Threads value {threads}")
            for moves in ("", " moves e2e4 e7e5", " moves d2d4 d7d5"):
                commands.extend([f"position startpos{moves}", "go nodes 1", "wait"])
                searches += 1
        output = self.run_commands("\n".join(commands))
        self.assertEqual(output.count("bestmove "), searches, output)

    @unittest.skipUnless(hasattr(os, "sched_getaffinity") and shutil.which("taskset"),
                         "requires Linux CPU affinity")
    def test_short_node_limits_survive_warm_tt_and_late_workers(self):
        # Sharing one CPU makes workers likely to dequeue Go after the main
        # thread's first limit check. Stale counts used to skip an entire search.
        # Reusing the TT also stresses aspiration retries: reducing the root to
        # quiescence could return an empty PV and stop far below the node budget.
        commands = ["uci", "setoption name Threads value 4"]
        limits = [50000, 1000] * 24
        for limit in limits:
            commands.extend(["position startpos", f"go nodes {limit}", "wait"])
        output = self.run_commands("\n".join(commands), cpu=min(os.sched_getaffinity(0)))
        searches = re.split(r"^bestmove .*$", output, flags=re.MULTILINE)[:-1]
        self.assertEqual(len(searches), len(limits), output)
        for limit, search in zip(limits, searches):
            counts = [int(value) for value in re.findall(r"\bnodes (\d+)\b", search)]
            self.assertTrue(counts, f"Search with {limit}-node limit was skipped:\n{search}")
            self.assertGreaterEqual(max(counts), limit, search)


if __name__ == "__main__":
    unittest.main()
