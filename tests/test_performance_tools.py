"""Regression checks for the UCI performance/PGO workload driver."""
import importlib.util
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "uci_workload", Path(__file__).resolve().parents[1] / "scripts" / "uci_workload.py"
)
workload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workload)


class UCIWorkloadTests(unittest.TestCase):
    def test_selects_disjoint_normalized_positions(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = Path(directory) / "positions.txt"
            corpus.write_text("# comment\na  b\na b\nc d\ne f\ng h\n")
            self.assertEqual(workload.load_positions(corpus, 2, 0, 2), ["a b", "e f"])
            self.assertEqual(workload.load_positions(corpus, 2, 1, 2), ["c d", "g h"])
            with self.assertRaises(ValueError):
                workload.load_positions(corpus, 5)

    def test_rejects_command_injection(self):
        with self.assertRaises(ValueError):
            workload.commands_for(["fen\nquit"], "nodes", 1000, 1)

    def test_command_sequence_waits_and_resets_each_position(self):
        fen = "8/8/8/8/8/8/4k3/6K1 w - - 0 1"
        commands = workload.commands_for([fen, fen], "time", 200, 4)
        self.assertEqual(commands.count("go movetime 200\nwait\n"), 2)
        self.assertEqual(commands.count("ucinewgame\n"), 2)
        self.assertIn("setoption name MoveOverhead value 0", commands)

    def test_uses_last_summary_for_each_search(self):
        output = ("info depth 1 time 10 nodes 100 nps 10000 pv e2e4\n"
                  "info depth 2 time 50 nodes 1000 nps 20000 pv e2e4\n"
                  "bestmove e2e4\n"
                  "info depth 3 time 100 nodes 2000 nps 20000 pv d2d4\n"
                  "bestmove d2d4\n")
        self.assertEqual(workload.parse_output(output, 2),
                         [{"nodes": 1000, "milliseconds": 50, "depth": 2, "bestmove": "e2e4"},
                          {"nodes": 2000, "milliseconds": 100, "depth": 3, "bestmove": "d2d4"}])

    def test_rejects_missing_or_too_short_searches(self):
        for output in ("", "bestmove 0000\n",
                       "info depth 1 time 0 nodes 20 nps 20000 pv e2e4\nbestmove e2e4\n"):
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                workload.parse_output(output, 1)
