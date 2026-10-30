# stdlib: the code units of tests/cases/stdlib.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_stdlib_1() {
rm -f std/src/lib.con.test.ll std/src/lib.con.test

# Stdlib modules that have #[test] functions
STDLIB_TEST_MODULES="string vec bytes slice text path fmt parse hash map set deque heap ordered_map ordered_set bitset option result fs process net"

if [ -n "$STDLIB_MODULE" ]; then
    # Single module mode: only run the requested module
    echo "  (targeting module: std.$STDLIB_MODULE)"
    mod_output=$($COMPILER std/src/lib.con --test --module "std.$STDLIB_MODULE" 2>&1) && mod_exit=0 || mod_exit=$?
    mod_pass=$(grep <<<"$mod_output" -c "^PASS:" || true)
    mod_fail=$(grep <<<"$mod_output" -c "^FAIL:" || true)
    if [ "$mod_pass" -eq 0 ] && [ "$mod_fail" -eq 0 ]; then
        echo "  warn  std.$STDLIB_MODULE — no tests found (check module name)"
    elif [ "$mod_fail" -gt 0 ]; then
        echo "  FAIL  std.$STDLIB_MODULE — $mod_pass passed, $mod_fail failed"
        grep <<<"$mod_output" "^FAIL:"
    else
        echo "  ok    std.$STDLIB_MODULE — $mod_pass passed"
    fi
    PASS=$((PASS + mod_pass))
    FAIL=$((FAIL + mod_fail))
    # Capture for collection verification section
    stdlib_output="$mod_output"
else
    # Full stdlib run with per-module breakdown
    stdlib_output=$($COMPILER std/src/lib.con --test 2>&1) && stdlib_exit=0 || stdlib_exit=$?
    stdlib_pass=$(grep <<<"$stdlib_output" -c "^PASS:" || true)
    stdlib_fail=$(grep <<<"$stdlib_output" -c "^FAIL:" || true)

    echo "  Stdlib: $stdlib_pass passed, $stdlib_fail failed (exit $stdlib_exit)"
    echo "  (use --stdlib-module <name> to target a single module)"
    if [ "$stdlib_fail" -gt 0 ]; then
        grep <<<"$stdlib_output" "^FAIL:"
    fi
    PASS=$((PASS + stdlib_pass))
    FAIL=$((FAIL + stdlib_fail))
fi
:
}
