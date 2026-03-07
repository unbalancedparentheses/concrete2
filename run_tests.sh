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
    actual=$("$out" 2>&1) || true
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
run_ok "$TESTDIR/enum_basic.con"        2
run_ok "$TESTDIR/enum_fields.con"       12
run_ok "$TESTDIR/enum_linear.con"       42
run_ok "$TESTDIR/borrow_read.con"      10
run_ok "$TESTDIR/borrow_mut.con"       42
run_ok "$TESTDIR/borrow_no_consume.con" 42
run_ok "$TESTDIR/generic_fn.con"       42
run_ok "$TESTDIR/generic_struct.con"   30
run_ok "$TESTDIR/string_basic.con"    5
run_ok "$TESTDIR/string_borrow.con"   10
run_ok "$TESTDIR/result_ok.con"      42
run_ok "$TESTDIR/result_err.con"     99
run_ok "$TESTDIR/module_basic.con"   42
run_ok "$TESTDIR/module_struct.con"  30
run_ok "$TESTDIR/array_basic.con"   20
run_ok "$TESTDIR/array_assign.con"  5
run_ok "$TESTDIR/cast_basic.con"    42
run_ok "$TESTDIR/cast_float.con"    7
run_ok "$TESTDIR/impl_method.con"   30
run_ok "$TESTDIR/impl_mut_method.con" 42
run_ok "$TESTDIR/impl_static.con"   7
run_ok "$TESTDIR/trait_basic.con"   30
run_ok "$TESTDIR/trait_multiple.con" 50
run_ok "$TESTDIR/cap_basic.con"    0
run_ok "$TESTDIR/cap_bang.con"     30
run_ok "$TESTDIR/cap_method.con"   0
run_ok "$TESTDIR/break_basic.con"  5
run_ok "$TESTDIR/continue_basic.con" 25
run_ok "$TESTDIR/break_for.con"    10
run_ok "$TESTDIR/continue_for.con" 27

echo ""
echo "=== Negative tests (expected errors) ==="
run_err "$TESTDIR/error_unconsumed.con"        "was never consumed"
run_err "$TESTDIR/error_use_after_move.con"    "used after move"
run_err "$TESTDIR/error_branch_disagree.con"   "consumed in one branch"
run_err "$TESTDIR/error_loop_consume.con"      "inside a loop"
run_err "$TESTDIR/error_type_mismatch.con"     "type mismatch"
run_err "$TESTDIR/error_no_else_consume.con"   "no else branch"
run_err "$TESTDIR/error_enum_nonexhaustive.con"   "non-exhaustive match"
run_err "$TESTDIR/error_enum_match_disagree.con"   "match arms disagree"
run_err "$TESTDIR/error_enum_unknown_variant.con"  "unknown variant"
run_err "$TESTDIR/error_borrow_after_move.con"    "used after move"
run_err "$TESTDIR/error_double_mut_borrow.con"    "already mutably borrowed"
run_err "$TESTDIR/error_deref_non_ref.con"        "cannot dereference"
run_err "$TESTDIR/error_generic_count.con"       "expects 2 arguments"
run_err "$TESTDIR/error_generic_type.con"        "type mismatch"
run_err "$TESTDIR/error_string_unconsumed.con"   "was never consumed"
run_err "$TESTDIR/error_try_non_result.con"      "requires a Result enum"
run_err "$TESTDIR/error_try_wrong_return.con"    "function must return same Result type"
run_err "$TESTDIR/error_import_private.con"      "is not public"
run_err "$TESTDIR/error_private_field.con"       "unknown module"
run_err "$TESTDIR/error_array_type.con"          "type mismatch"
run_err "$TESTDIR/error_array_index.con"         "type mismatch"
run_err "$TESTDIR/error_cast_invalid.con"        "cannot cast"
run_err "$TESTDIR/error_unknown_method.con"      "no method"
run_err "$TESTDIR/error_trait_missing_method.con" "missing method"
run_err "$TESTDIR/error_trait_wrong_sig.con"     "signature does not match"
run_err "$TESTDIR/error_cap_pure.con"            "requires capability"
run_err "$TESTDIR/error_cap_propagation.con"     "requires capability"
run_err "$TESTDIR/error_cap_method.con"          "requires capability"
run_err "$TESTDIR/error_break_outside.con"       "break outside of loop"
run_err "$TESTDIR/error_continue_outside.con"    "continue outside of loop"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
