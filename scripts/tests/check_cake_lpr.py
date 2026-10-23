#!/usr/bin/env python3
"""Opt-in SAT audit, not a Concrete proof receipt. Retains exact inputs and logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tomllib

ROOT = Path(__file__).resolve().parents[2]
PIN = "a36874a8b750b43fe4b385b8ddbf5b033e46a3fa"


class Incomplete(RuntimeError):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def accepted(result):
    # An error, timeout, missing verdict or conflicting output is never acceptance.
    return (result.returncode == 0 and result.stdout.strip() == "s VERIFIED UNSAT"
            and not result.stderr.strip())


def refused_empty(result):
    return (result.returncode == 0 and not result.stdout.strip()
            and result.stderr.strip() == "c empty clause not derived at end of proof")


def unit_conflict(path):
    """Diagnostic only: does unit propagation refute the CNF without proof steps?"""
    clauses, clause = [], []
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith(("c", "p")):
            continue
        for token in line.split():
            literal = int(token)
            if literal:
                clause.append(literal)
            else:
                clauses.append(set(clause))
                clause = []
    if clause:
        raise RuntimeError("unterminated DIMACS clause")
    while True:
        if any(not c for c in clauses):
            return True
        units = {next(iter(c)) for c in clauses if len(c) == 1}
        if not units:
            return False
        if any(-u in units for u in units):
            return True
        clauses = [c - {-u for u in units} for c in clauses if not c.intersection(units)]


def run(cmd, log, timeout, env=None):
    start = time.monotonic()
    try:
        r = subprocess.run([str(x) for x in cmd], cwd=ROOT, env=env,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        log.write_text("TIMEOUT\n" + str(e))
        raise Incomplete(f"timeout: {cmd[0]}") from e
    log.write_text(f"exit={r.returncode}\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}")
    return r, time.monotonic() - start


def require(cmd, log, timeout, env=None):
    r, _ = run(cmd, log, timeout, env)
    if r.returncode:
        raise RuntimeError(f"command failed; see {log}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checker-dir", required=True, type=Path,
                    help="output of scripts/tools/build_cake_lpr.sh")
    ap.add_argument("--output", required=True, type=Path, help="new retained artifact directory")
    ap.add_argument("--timeout", type=int, default=120, help="per subprocess, seconds")
    args = ap.parse_args()
    if args.timeout <= 0:
        ap.error("timeout must be positive")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)  # Never reuse a stale successful audit.
    checker = args.checker_dir.resolve() / "cake_lpr"
    report = {"schema": "concrete-cakelpr-experiment-v1", "status": "incomplete",
              "claims": "SAT formulas only; no Lean-to-CNF or native-code correctness claim",
              "formulas": [], "controls": []}
    try:
        for name in ("lake", "lean", "cadical"):
            if not shutil.which(name):
                raise Incomplete(f"required tool missing: {name}; use nix develop")
        build = json.loads((args.checker_dir / "build.json").read_text())
        if build["revision"] != PIN or build["binary_sha256"] != digest(checker):
            raise RuntimeError("checker pin/binary does not match build manifest")
        report["checker_build"] = build
        report["toolchain"] = (ROOT / "lean-toolchain").read_text().strip()
        report["commit"] = require(["git", "rev-parse", "HEAD"], out / "commit.log", args.timeout).strip()
        report["working_tree"] = require(["git", "status", "--porcelain"], out / "tree.log", args.timeout)
        report["shim_sha256"] = digest(ROOT / "scripts/bv_capture_solver.sh")
        sample = out / "Samples.lean"
        sample.write_text("""import Std.Tactic.BVDecide
example (x y : BitVec 16) : (x ^^^ y) ^^^ y = x := by bv_decide
example (x y : BitVec 8) : x + y = y + x := by bv_decide
example (y : BitVec 32) : y &&& 255#32 = (BitVec.setWidth 8 y).setWidth 32 := by bv_decide
""")
        owners = [x.strip() for x in (ROOT / "scripts/tests/axiom_native_owners.txt").read_text().splitlines()
                  if x.strip() and not x.startswith("#")]
        # Resolve owner modules by elaborated theorem names, not by grepping short names.
        population = require(["lake", "env", "lean", "scripts/tools/proof_layer_theorems.lean"],
                             out / "population.log", args.timeout)
        axioms = {a for line in population.splitlines() if "\t" in line
                  for a in line.split("\t")[1].split() if "._native.bv_decide.ax_" in a}
        if not axioms:
            raise RuntimeError("no native bitvector axioms found; population is vacuous")
        locations = require(["lake", "env", "lean", "scripts/tools/proof_layer_theorems.lean"],
                            out / "locations.log", args.timeout,
                            dict(os.environ, PROOF_LAYER_MODE="locations"))
        module_map = dict(line.split("\t") for line in locations.splitlines() if "\t" in line)
        modules = {}
        libraries = tomllib.loads((ROOT / "lakefile.toml").read_text())["lean_lib"]
        for owner in owners:
            parts = module_map[owner].split(".")
            roots = [ROOT / lib.get("srcDir", ".") for lib in libraries if lib["name"] == parts[0]]
            candidates = [root / ("/".join(parts) + ".lean") for root in roots]
            existing = [p for p in candidates if p.is_file()]
            if not existing:
                raise RuntimeError(f"cannot resolve module for {owner}")
            modules[str(existing[-1])] = existing[-1]
        jobs = [("sample", sample)] + [(f"project-{i}", p) for i, p in enumerate(modules.values())]
        project_count = 0
        for tag, source in jobs:
            capture = out / tag
            capture.mkdir()
            env = dict(os.environ, CNF_CAPTURE_DIR=str(capture), BV_CAPTURE_CERTIFICATES="1")
            report.setdefault("sources", []).append({"path": str(source), "sha256": digest(source)})
            require(["lake", "env", "lean", f"-Dsat.solver={ROOT / 'scripts/bv_capture_solver.sh'}", source],
                    out / f"{tag}.log", args.timeout, env)
            formulas = sorted(capture.glob("*.dimacs"))
            if not formulas:
                raise RuntimeError(f"no captured formulas for {tag}")
            if tag.startswith("project"):
                project_count += len(formulas)
            for i, cnf in enumerate(formulas):
                cert = cnf.with_suffix(".lrat")
                solver = Path(cnf.with_suffix(".solver").read_text().strip()).resolve(strict=True)
                before = digest(cnf)
                if not cert.is_file():
                    raise RuntimeError(f"missing original LRAT certificate: {cnf}")
                cert_sha = digest(cert)
                result, check_time = run([checker, cnf, cert], capture / f"{i}.checker.log", args.timeout)
                if not accepted(result) or digest(cnf) != before or digest(cert) != cert_sha:
                    raise RuntimeError(f"checker rejected or inputs changed: {cnf}")
                empty = capture / "empty.lrat"
                empty.write_text("")
                result, _ = run([checker, cnf, empty], capture / f"{i}.empty.log", args.timeout)
                # Empty proof acceptance means the formula alone suffices; never count it as
                # exercising a proof. Operational failures are not evidence of rejection.
                trivial = accepted(result)
                if not trivial and not refused_empty(result):
                    raise RuntimeError(f"unexpected empty-proof outcome: {cnf}")
                report["formulas"].append({"group": tag, "cnf": str(cnf.relative_to(out)),
                    "cnf_sha256": before, "lrat": str(cert.relative_to(out)), "lrat_sha256": cert_sha,
                    "empty_proof_accepted": trivial, "unit_propagation_conflict": unit_conflict(cnf),
                    "solver": str(solver), "solver_sha256": digest(solver),
                    "original_solver_certificate": True, "check_seconds": check_time})
        report["native_axioms"] = sorted(axioms)
        if project_count != len(axioms):
            raise RuntimeError(f"captured {project_count} project formulas for {len(axioms)} native axioms")
        nontrivial = [f for f in report["formulas"]
                      if not f["empty_proof_accepted"] and not f["unit_propagation_conflict"]]
        if not any(f["group"] == "sample" for f in nontrivial):
            raise RuntimeError("no nontrivial sample certificate exercised")
        # Reuse an actual nontrivial proof against a SAT formula: formula swaps must fail.
        chosen = nontrivial[0]
        sat = out / "wrong-formula.cnf"
        sat.write_text("p cnf 2 1\n1 2 0\n")
        bad = out / "corrupt.lrat"
        bad.write_text("not an LRAT certificate\n")
        for name, cnf, cert in [("mismatched-formula", sat, out / chosen["lrat"]),
                                ("corrupt-proof", out / chosen["cnf"], bad)]:
            result, _ = run([checker, cnf, cert], out / f"{name}.log", args.timeout)
            # Require a checker diagnostic, not just a crash, missing executable or timeout.
            if (result.returncode != 0 or result.stdout.strip()
                    or not result.stderr.startswith("c Checking failed at line:")):
                raise RuntimeError(f"negative control did not produce a checker refusal: {name}")
            report["controls"].append(name)
        if digest(checker) != build["binary_sha256"]:
            raise RuntimeError("checker changed during audit")
        report["status"] = "passed"
    except Incomplete as e:
        report["status"] = "incomplete"
        report["error"] = str(e)
    except (OSError, ValueError, KeyError, RuntimeError) as e:
        report["status"] = "failed"
        report["error"] = str(e)
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"CAKE-LPR-EXPERIMENT: {report['status']} ({out / 'report.json'})")
    if "error" in report:
        print(report["error"], file=sys.stderr)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
