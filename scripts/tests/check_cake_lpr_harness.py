#!/usr/bin/env python3
"""Regression controls for the experimental audit's fail-closed process boundary."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("check_cake_lpr.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BoundaryTests(unittest.TestCase):
    def test_acceptance_requires_successful_exact_verdict(self):
        for rc, stdout, stderr in [(1, "s VERIFIED UNSAT\n", ""),
                                    (0, "", ""), (0, "s NOT VERIFIED UNSAT\n", ""),
                                    (0, "s VERIFIED UNSAT\ns SATISFIABLE\n", ""),
                                    (0, "s VERIFIED UNSAT\n", "error"),
                                    (-9, "s VERIFIED UNSAT\n", "")]:
            with self.subTest(rc=rc, stdout=stdout, stderr=stderr):
                self.assertFalse(audit.accepted(subprocess.CompletedProcess([], rc, stdout, stderr)))
        self.assertTrue(audit.accepted(subprocess.CompletedProcess([], 0, "s VERIFIED UNSAT\n", "")))

    def test_timeout_and_missing_binary_are_not_refutations(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "run.log"
            with self.assertRaises(RuntimeError):
                audit.run([sys.executable, "-c", "import time; time.sleep(5)"], log, 0.05)
            self.assertTrue(log.read_text().startswith("TIMEOUT"))
            with self.assertRaises(FileNotFoundError):
                audit.run([str(Path(d) / "absent")], log, 1)

    def test_trivial_formulas_do_not_count_as_certificate_exercise(self):
        with tempfile.TemporaryDirectory() as d:
            cnf = Path(d) / "input.cnf"
            for text, expected in [("p cnf 1 2\n1 0\n-1 0\n", True),
                                   ("p cnf 2 3\n1 0\n-1 2 0\n-2 0\n", True),
                                   ("p cnf 2 4\n1 2 0\n1 -2 0\n-1 2 0\n-1 -2 0\n", False),
                                   ("p cnf 1 1\n1 0\n", False)]:
                cnf.write_text(text)
                self.assertEqual(audit.unit_conflict(cnf), expected)


if __name__ == "__main__":
    unittest.main()
