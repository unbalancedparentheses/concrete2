#!/usr/bin/env python3
"""Regression controls for the experimental audit's fail-closed process boundary."""
import importlib.util
import os
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

    def test_empty_refusal_requires_unambiguous_normal_completion(self):
        diagnostic = "c empty clause not derived at end of proof\n"
        for rc, out, err in [(1, "", diagnostic), (-9, "", diagnostic),
                             (0, "s VERIFIED UNSAT", diagnostic),
                             (0, "", diagnostic + "other error")]:
            self.assertFalse(audit.refused_empty(subprocess.CompletedProcess([], rc, out, err)))
        self.assertTrue(audit.refused_empty(subprocess.CompletedProcess([], 0, "", diagnostic)))

    def test_trivial_formulas_do_not_count_as_certificate_exercise(self):
        with tempfile.TemporaryDirectory() as d:
            cnf = Path(d) / "input.cnf"
            for text, expected in [("p cnf 1 2\n1 0\n-1 0\n", True),
                                   ("p cnf 2 3\n1 0\n-1 2 0\n-2 0\n", True),
                                   ("p cnf 2 4\n1 2 0\n1 -2 0\n-1 2 0\n-1 -2 0\n", False),
                                   ("p cnf 1 1\n1 0\n", False)]:
                cnf.write_text(text)
                self.assertEqual(audit.unit_conflict(cnf), expected)

    def test_capture_records_selected_solver_and_preserves_pair(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "bin").mkdir()
            solver = root / "bin/cadical"
            solver.write_text('#!/bin/sh\nprintf "original-proof" > "$2"\nexit 20\n')
            solver.chmod(0o755)
            cnf, proof, capture = root / "input.cnf", root / "output.lrat", root / "capture"
            cnf.write_text("p cnf 1 2\n1 0\n-1 0\n")
            capture.mkdir()
            env = dict(os.environ, LEAN_SYSROOT=str(root), CNF_CAPTURE_DIR=str(capture),
                       BV_CAPTURE_CERTIFICATES="1")
            shim = Path(__file__).resolve().parents[1] / "bv_capture_solver.sh"
            r = subprocess.run(["bash", str(shim), str(cnf), str(proof), "--lrat"], env=env)
            self.assertEqual(r.returncode, 20)
            copied = list(capture.glob("*.dimacs"))
            self.assertEqual(len(copied), 1)
            self.assertEqual(copied[0].read_bytes(), cnf.read_bytes())
            self.assertEqual(copied[0].with_suffix(".lrat").read_bytes(), proof.read_bytes())
            self.assertEqual(copied[0].with_suffix(".solver").read_text().strip(), str(solver))
            env["CNF_CAPTURE_DIR"] = str(root / "missing")
            r = subprocess.run(["bash", str(shim), str(cnf), str(proof)], env=env, capture_output=True)
            self.assertEqual(r.returncode, 125)


if __name__ == "__main__":
    unittest.main()
