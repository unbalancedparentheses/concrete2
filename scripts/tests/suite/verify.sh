# verify: the code units of tests/cases/verify.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_verify_1() {
verify_pass=0
verify_fail=0
for f in "$TESTDIR"/*.con; do
    bn=$(basename "$f")
    case "$bn" in
        error_*|adversarial_*|pressure_err_*|phase3_diag_*|bug_*) continue ;;
    esac
    output=$("$COMPILER" "$f" --report verify 2>&1) || true
    if grep <<<"$output" -q "VERIFIER FAILED"; then
        echo "  FAIL verify: $bn"
        grep <<<"$output" "error:" | awk "NR<=3" | sed 's/^/    /'
        verify_fail=$((verify_fail + 1))
    else
        verify_pass=$((verify_pass + 1))
    fi
done
if [ "$verify_fail" -gt 0 ]; then
    echo "  $verify_fail programs have verifier errors"
    FAIL=$((FAIL + verify_fail))
else
    echo "  All $verify_pass programs pass verifier checks"
fi
PASS=$((PASS + verify_pass))
:
}
