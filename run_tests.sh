#!/usr/bin/env bash
set -euo pipefail

COMPILER=".lake/build/bin/concrete"
TESTDIR="lean_tests"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# Positive tests: should compile and produce expected output
run_ok() {
    local file="$1"
    local expected="$2"
    local name
    name=$(basename "$file" .con)
    local out="$TMPDIR/$name"

    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        echo "FAIL  $file — compilation failed (expected success)"
        FAIL=$((FAIL + 1))
        return
    fi
    local actual
    actual=$("$out" 2>&1)
    if [ "$actual" = "$expected" ]; then
        echo "  ok  $file => $expected"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $file — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# Negative tests: should fail to compile with a specific error substring
run_err() {
    local file="$1"
    local expected_err="$2"
    local name
    name=$(basename "$file" .con)
    local out="$TMPDIR/$name"

    local stderr
    if stderr=$($COMPILER "$file" -o "$out" 2>&1); then
        echo "FAIL  $file — compiled successfully (expected error)"
        FAIL=$((FAIL + 1))
        return
    fi
    if echo "$stderr" | grep -q "$expected_err"; then
        echo "  ok  $file => error: $expected_err"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $file — expected error '$expected_err', got: $stderr"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Positive tests ==="
run_ok "$TESTDIR/fib.con"                55
run_ok "$TESTDIR/arithmetic.con"         65
run_ok "$TESTDIR/if_else.con"            1
run_ok "$TESTDIR/while_loop.con"         5050
run_ok "$TESTDIR/recursion.con"          479001600
run_ok "$TESTDIR/nested_calls.con"       42
run_ok "$TESTDIR/struct_basic.con"       7
run_ok "$TESTDIR/struct_field_assign.con" 33
run_ok "$TESTDIR/linear_consume.con"     42
run_ok "$TESTDIR/linear_branch_agree.con" 42
run_ok "$TESTDIR/linear_loop_inner.con"  3

echo ""
echo "=== Negative tests (expected errors) ==="
run_err "$TESTDIR/error_unconsumed.con"        "was never consumed"
run_err "$TESTDIR/error_use_after_move.con"    "used after move"
run_err "$TESTDIR/error_branch_disagree.con"   "consumed in one branch"
run_err "$TESTDIR/error_loop_consume.con"      "inside a loop"
run_err "$TESTDIR/error_type_mismatch.con"     "type mismatch"
run_err "$TESTDIR/error_no_else_consume.con"   "no else branch"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
