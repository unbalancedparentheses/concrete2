# passlevel: the code units of tests/cases/passlevel.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_passlevel_1() {
PIPELINE_TEST=".lake/build/bin/pipeline-test"
if [ -x "$PIPELINE_TEST" ]; then
    output=$("$PIPELINE_TEST" 2>&1) || true
    # Parse the summary line: "=== N/M passed, F failed ==="
    summary_line=$(grep <<<"$output" -E '^=== [0-9]+/[0-9]+ passed')
    if [ -n "$summary_line" ]; then
        pl_passed=$(echo "$summary_line" | sed 's/=== \([0-9]*\)\/.*/\1/')
        pl_total=$(echo "$summary_line" | sed 's/.*\/\([0-9]*\) passed.*/\1/')
        pl_failed=$(echo "$summary_line" | sed 's/.*, \([0-9]*\) failed.*/\1/')
        PASS=$((PASS + pl_passed))
        FAIL=$((FAIL + pl_failed))
        echo "  $pl_passed/$pl_total pass-level tests passed"
        if [ "$pl_failed" -gt 0 ]; then
            grep <<<"$output" "^FAIL:" >&2
        fi
    else
        # FAIL-CLOSED (audit 2026-07-16): the binary ran but its summary
        # line did not parse — the output contract broke, so the pass-level
        # results are unknown. Unknown is a failure, not a warning.
        echo "  FAIL: could not parse pipeline-test summary ('=== N/M passed, F failed ===')"
        echo "$output"
        FAIL=$((FAIL + 1))
    fi
else
    # FAIL-CLOSED (audit 2026-07-16): a missing binary silently skipped all
    # pass-level Lean tests in CI for months. pipeline-test is now in
    # lakefile defaultTargets; absence is a broken build, not a skip.
    echo "  FAIL: $PIPELINE_TEST not built (it is a defaultTarget — run 'lake build')"
    FAIL=$((FAIL + 1))
fi
:
}
