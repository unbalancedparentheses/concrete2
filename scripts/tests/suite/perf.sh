# perf: the code units of tests/cases/perf.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_perf_1() {
if [ -f "scripts/tests/test_perf.sh" ] && [ -f ".perf-baseline" ]; then
    perf_output=$(bash scripts/tests/test_perf.sh --compare 2>&1) || true
    perf_warns=$(grep <<<"$perf_output" -c "WARNING" || true)
    if [ "$perf_warns" -gt 0 ]; then
        echo "  $perf_warns performance regression warning(s):"
        grep <<<"$perf_output" "WARNING" | sed 's/^/    /'
    else
        echo "  No performance regressions detected"
    fi
    PASS=$((PASS + 1))
elif [ -f "scripts/tests/test_perf.sh" ] && [ ! -f ".perf-baseline" ]; then
    echo "  SKIP: no .perf-baseline file (run 'bash scripts/tests/test_perf.sh --save' to create)"
    SKIP=$((SKIP + 1))
else
    echo "  SKIP: scripts/tests/test_perf.sh not found"
    SKIP=$((SKIP + 1))
fi
:
}
