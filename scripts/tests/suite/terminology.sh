# terminology: the code units of tests/cases/terminology.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_terminology_1() {
if [ -f "scripts/tests/test_terminology_gate.sh" ]; then
    term_output=$(bash scripts/tests/test_terminology_gate.sh 2>&1) || term_exit=$?
    if [ "${term_exit:-0}" -gt 0 ]; then
        grep <<<"$term_output" "FAIL:" | sed 's/^/  /'
        FAIL=$((FAIL + 1))
    else
        echo "  Terminology gate passed"
        PASS=$((PASS + 1))
    fi
else
    echo "  SKIP: scripts/tests/test_terminology_gate.sh not found"
    SKIP=$((SKIP + 1))
fi
:
}
