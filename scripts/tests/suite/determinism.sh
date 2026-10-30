# determinism: the code units of tests/cases/determinism.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_determinism_1() {
if [ -f "scripts/tests/test_determinism.sh" ]; then
    det_output=$(bash scripts/tests/test_determinism.sh --quick 2>&1) || det_exit=$?
    det_pass=$(grep <<<"$det_output" "passed:" | awk '{print $2}')
    det_fail=$(grep <<<"$det_output" "failed:" | awk '{print $2}')
    if [ "${det_fail:-0}" -gt 0 ]; then
        echo "  FAIL: $det_fail determinism regressions detected"
        grep <<<"$det_output" "FAIL:" | sed 's/^/    /'
        FAIL=$((FAIL + det_fail))
    else
        echo "  All ${det_pass:-0} determinism checks passed"
    fi
    PASS=$((PASS + ${det_pass:-0}))
else
    echo "  SKIP: scripts/tests/test_determinism.sh not found"
    SKIP=$((SKIP + 1))
fi
:
}
