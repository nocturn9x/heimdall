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


if __name__ == "__main__":
    unittest.main()
