# testflag: the code units of tests/cases/testflag.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_testflag_1() {
run_test_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"

    local output exit_code
    output=$($COMPILER "$file" --test 2>&1) && exit_code=0 || exit_code=$?
    if [ "$exit_code" = "$expected" ]; then
        {
            echo "PASS"
            echo "  ok  $file --test (exit $expected)"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file --test — expected exit $expected, got $exit_code"
            echo "$output"
        } > "$result_file"
    fi
}

run_test() {
    local file="$1"
    local expected="$2"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_test_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_test_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}
:
}
