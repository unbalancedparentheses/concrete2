# consistency: the code units of tests/cases/consistency.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_consistency_1() {
consistency_pass=0
consistency_fail=0
for prog in "$TESTDIR"/*.con; do
    base=$(basename "$prog" .con)
    result=$($COMPILER "$prog" --report consistency 2>&1) || true
    if grep <<<"$result" -q "All consistency checks passed"; then
        consistency_pass=$((consistency_pass + 1))
    elif grep <<<"$result" -q "consistency violation"; then
        consistency_fail=$((consistency_fail + 1))
        echo "  FAIL: $base"
        grep <<<"$result" -v "^$" | sed 's/^/    /'
    fi
    # programs that fail compilation are silently skipped
done
if [ "$consistency_fail" -gt 0 ]; then
    echo "  $consistency_fail programs have consistency violations"
    FAIL=$((FAIL + consistency_fail))
else
    echo "  All $consistency_pass programs pass self-consistency checks"
fi
PASS=$((PASS + consistency_pass))
:
}
