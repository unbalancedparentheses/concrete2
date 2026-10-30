# collection: the code units of tests/cases/collection.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_collection_1() {

check_collection_tests() {
    local name="$1"
    shift
    local missing=0
    for test_name in "$@"; do
        if ! grep <<<"$stdlib_output" -qF "PASS: $test_name"; then
            echo "FAIL  collection/$name — missing or failing test: $test_name"
            missing=1
        fi
    done
    if [ "$missing" -eq 0 ]; then
        echo "  ok  collection/$name — all $# tests present and passing"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}
:
}
