"""Regression tests for the perft comparison tools; no engines required."""

import contextlib
import io
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import MagicMock, patch

import compare_positions
import suite


class SuiteTests(unittest.TestCase):
    def run_suite(self, results, parallel=False, positions="first\nsecond\n"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "positions.txt"
            path.write_text(positions)
            args = Namespace(positions_file=path, parallel=parallel, workers=1,
                             no_silent=False, show_failures=True, ply=1)
            output = io.StringIO()
            with patch.object(suite, "test", side_effect=results), contextlib.redirect_stdout(output):
                status = suite.main(args)
            return status, output.getvalue()

    def test_failure_reaches_exit_status_and_summary_in_both_modes(self):
        for parallel in (False, True):
            with self.subTest(parallel=parallel):
                status, output = self.run_suite([0, 1], parallel)
                self.assertEqual(status, 1)
                self.assertIn("1 successful, 1 failed", output)
                self.assertIn("\n\tsecond", output)

    def test_success_in_both_modes(self):
        for parallel in (False, True):
            with self.subTest(parallel=parallel):
                status, output = self.run_suite([0, 0], parallel)
                self.assertEqual(status, 0)
                self.assertIn("2 successful, 0 failed", output)

    def test_blank_file_is_not_success(self):
        self.assertEqual(self.run_suite([], positions=" \n\t\n")[0], 2)

    def test_blank_lines_are_skipped(self):
        status, output = self.run_suite([0, 0], positions="\nfirst\n\nsecond\n")
        self.assertEqual(status, 0)
        self.assertIn("Ran 2 tests", output)

    def test_parallel_interruption_is_not_success(self):
        self.assertEqual(self.run_suite(KeyboardInterrupt(), parallel=True)[0], 255)


class ComparatorTests(unittest.TestCase):
    def compare(self, stockfish_output, heimdall_output, returncode=0):
        stockfish = MagicMock(returncode=0)
        stockfish.communicate.return_value = (stockfish_output, None)
        heimdall = MagicMock(returncode=returncode)
        heimdall.communicate.return_value = (heimdall_output, None)
        args = Namespace(silent=False, stockfish=Path(__file__), heimdall=Path(__file__),
                         ply=1, bulk=True, fen="")
        output = io.StringIO()
        with patch.object(compare_positions.subprocess, "Popen", side_effect=[stockfish, heimdall]), contextlib.redirect_stdout(output):
            status = compare_positions.main(args)
        return status, output.getvalue()

    def test_verbose_import_and_matching_perft(self):
        status, output = self.compare("e2e4: 1\nNodes searched: 1\n",
                                      "e2e4: 1\nNodes searched (bulk-counting: on): 1\n")
        self.assertEqual(status, 0)
        self.assertIn("No discrepancies detected", output)

    def test_empty_output_is_not_success(self):
        self.assertEqual(self.compare("", "")[0], 2)

    def test_incomplete_divide_is_not_success(self):
        self.assertEqual(self.compare("Nodes searched: 20\n",
                                      "Nodes searched (bulk-counting: on): 20\n")[0], 2)

    def test_terminal_position_with_zero_nodes_is_valid(self):
        self.assertEqual(self.compare("Nodes searched: 0\n",
                                      "Nodes searched (bulk-counting: on): 0\n")[0], 0)

    def test_colored_summary_is_valid(self):
        self.assertEqual(self.compare("e2e4: 1\nNodes searched: 1\n",
                                      "e2e4: 1\n\x1b[32mNodes searched (bulk-counting: on): \x1b[97m1\x1b[0m\n")[0], 0)

    def test_mismatch_is_failure(self):
        self.assertEqual(self.compare("e2e4: 1\nNodes searched: 1\n",
                                      "d2d4: 1\nNodes searched (bulk-counting: on): 1\n")[0], 1)

    def test_crash_diagnostic_contains_merged_output(self):
        status, output = self.compare("", "engine failure details", returncode=1)
        self.assertEqual(status, 3)
        self.assertIn("engine failure details", output)


if __name__ == "__main__":
    unittest.main()
