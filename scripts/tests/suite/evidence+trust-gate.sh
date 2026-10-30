# evidence+trust-gate: the code units of tests/cases/evidence+trust-gate.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_evidence_trust_gate_1() {
wf_pass=0
wf_fail=0

# proof_pressure is our test project with a known proof mix
PP_DIR="examples/proof_pressure"

# 1. Build shows proof summary line
wf_build=$(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_wf_pp" 2>&1)
if grep <<<"$wf_build" -q "^Proofs:"; then
    echo "  ok  workflow: build shows proof summary line"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: build should show proof summary line"
    echo "    out: $(echo "$wf_build" | tail -3)"
    wf_fail=$((wf_fail + 1))
fi
rm -f "$TMPDIR/test_wf_pp"

# 2. Build summary mentions proved count
if grep <<<"$wf_build" "^Proofs:" | has_match "proved"; then
    echo "  ok  workflow: build summary mentions proved count"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: build summary should mention proved"
    wf_fail=$((wf_fail + 1))
fi

# 3. Build summary mentions stale count
if grep <<<"$wf_build" "^Proofs:" | has_match "stale"; then
    echo "  ok  workflow: build summary mentions stale count"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: build summary should mention stale"
    wf_fail=$((wf_fail + 1))
fi

# 4. Build exit code is 0 (build succeeds despite stale proofs)
wf_build_rc=0
(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_wf_pp2" >/dev/null 2>&1) || wf_build_rc=$?
if [ "$wf_build_rc" -eq 0 ]; then
    echo "  ok  workflow: build succeeds despite stale proofs (exit 0)"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: build should succeed despite stale proofs (got exit $wf_build_rc)"
    wf_fail=$((wf_fail + 1))
fi
rm -f "$TMPDIR/test_wf_pp2"

# 5. Check command produces proof status report
wf_check=$(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" check 2>&1) || true
if grep <<<"$wf_check" -q "=== Proof Status Report ==="; then
    echo "  ok  workflow: check shows proof status report"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check should show proof status report"
    wf_fail=$((wf_fail + 1))
fi

# 6. Check command shows next steps
if grep <<<"$wf_check" -q "^Next steps:"; then
    echo "  ok  workflow: check shows next steps"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check should show next steps"
    wf_fail=$((wf_fail + 1))
fi

# 7. Check exit code is 1 (has stale/missing/blocked obligations)
wf_check_rc=0
(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" check >/dev/null 2>&1) || wf_check_rc=$?
if [ "$wf_check_rc" -eq 1 ]; then
    echo "  ok  workflow: check exits 1 when obligations unresolved"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check should exit 1 with unresolved obligations (got $wf_check_rc)"
    wf_fail=$((wf_fail + 1))
fi

# 8. Check next-steps prioritizes stale before missing
first_step=$(grep <<<"$wf_check" -A1 "^Next steps:" | tail -1)
if grep <<<"$first_step" -q "stale"; then
    echo "  ok  workflow: check next-steps prioritizes stale"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check next-steps should prioritize stale"
    echo "    first step: $first_step"
    wf_fail=$((wf_fail + 1))
fi

# 9. Check totals line present
if grep <<<"$wf_check" -q "^Totals:"; then
    echo "  ok  workflow: check shows totals line"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check should show totals line"
    wf_fail=$((wf_fail + 1))
fi

# 10. Check without project dir gives helpful error
wf_noproject=$(cd /tmp && "$ROOT_DIR/$COMPILER" check 2>&1) || true
if grep <<<"$wf_noproject" -q "no Concrete.toml found"; then
    echo "  ok  workflow: check without project gives helpful error"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: check without project should give helpful error"
    wf_fail=$((wf_fail + 1))
fi

if [ "$wf_fail" -gt 0 ]; then
    echo "  $wf_fail workflow test failures"
fi
echo "  $wf_pass workflow tests passed"
PASS=$((PASS + wf_pass))
FAIL=$((FAIL + wf_fail))
:
}
