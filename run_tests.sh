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
run_ok "$TESTDIR/closure_basic.con" 42
run_ok "$TESTDIR/closure_capture_copy.con" 52
run_ok "$TESTDIR/closure_capture_move.con" 30
run_ok "$TESTDIR/closure_multiple_captures.con" 60
run_ok "$TESTDIR/closure_nested.con" 15
run_ok "$TESTDIR/closure_no_capture.con" 100
# Phase 3: defer/destroy/Copy
run_ok "$TESTDIR/defer_basic.con" 10
run_ok "$TESTDIR/defer_lifo.con" 42
run_ok "$TESTDIR/defer_early_return.con" 10
run_ok "$TESTDIR/defer_loop.con" 42
run_ok "$TESTDIR/destroy_trait.con" 42
run_ok "$TESTDIR/copy_struct.con" 42
run_ok "$TESTDIR/copy_enum.con" 42

# abort test: compiles but exits with nonzero (signal)
run_abort() {
    local file="$1"
    local name
    name=$(basename "$file" .con)
    local out="$TMPDIR/$name"
    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        echo "FAIL  $file — compilation failed"
        FAIL=$((FAIL + 1))
        return
    fi
    if "$out" > /dev/null 2>&1; then
        echo "FAIL  $file — expected nonzero exit"
        FAIL=$((FAIL + 1))
    else
        echo "  ok  $file => nonzero exit"
        PASS=$((PASS + 1))
    fi
}
run_abort "$TESTDIR/abort_basic.con"

# Phase 5: Allocator system
run_ok "$TESTDIR/alloc_basic.con" 30
run_ok "$TESTDIR/alloc_propagate.con" 30
run_ok "$TESTDIR/heap_arrow.con" 20
run_ok "$TESTDIR/heap_arrow_mut.con" 42

# Phase 6: Borrow regions
run_ok "$TESTDIR/borrow_named.con" 30
run_ok "$TESTDIR/borrow_mut_named.con" 42
run_ok "$TESTDIR/borrow_multi.con" 35

# Capability polymorphism
run_ok "$TESTDIR/cap_poly.con" 42
run_ok "$TESTDIR/cap_poly_chain.con" 42

# Borrow escape (positive — deref value is OK)
run_ok "$TESTDIR/escape_return.con" 10

# Complex multi-feature programs
run_ok "$TESTDIR/complex_linked_list.con" 42
run_ok "$TESTDIR/complex_closure_pipeline.con" 27
run_ok "$TESTDIR/complex_struct_methods.con" 42
run_ok "$TESTDIR/complex_defer_destroy.con" 42
run_ok "$TESTDIR/complex_enum_result.con" 25
run_ok "$TESTDIR/complex_borrow_compute.con" 170
run_ok "$TESTDIR/complex_generic_container.con" 42
run_ok "$TESTDIR/complex_loop_accumulate.con" 50

# Phase 4: while-as-expression
run_ok "$TESTDIR/while_expr_basic.con" 5
run_ok "$TESTDIR/while_expr_no_break.con" 99
run_ok "$TESTDIR/while_expr_nested.con" 6
run_ok "$TESTDIR/break_accumulate.con" 10
run_ok "$TESTDIR/while_nested_break.con" 6

# Additional capability tests
run_ok "$TESTDIR/cap_std_expand.con" 0
run_ok "$TESTDIR/cap_nested_call.con" 42

# Additional closure tests
run_ok "$TESTDIR/closure_higher_order.con" 15
run_ok "$TESTDIR/closure_identity.con" 42

# Additional defer/Copy tests
run_ok "$TESTDIR/defer_nested_scope.con" 42
run_ok "$TESTDIR/defer_try.con" 42
run_ok "$TESTDIR/copy_multiple_use.con" 50

# Additional allocator tests
run_ok "$TESTDIR/heap_struct_method.con" 30
run_ok "$TESTDIR/alloc_free_loop.con" 45

# Additional borrow region tests
run_ok "$TESTDIR/borrow_sequential.con" 30
run_ok "$TESTDIR/borrow_copy_in_block.con" 42

# Phase 7: Bitwise operators + hex/bin/oct literals
run_ok "$TESTDIR/bitwise_and.con" 15
run_ok "$TESTDIR/bitwise_or.con" 255
run_ok "$TESTDIR/bitwise_xor.con" 240
run_ok "$TESTDIR/bitwise_shift.con" 1056
run_ok "$TESTDIR/bitwise_not.con" -1
run_ok "$TESTDIR/hex_literal.con" 255
run_ok "$TESTDIR/bin_oct_literal.con" 73

# Phase 7b: Print / basic I/O
run_ok "$TESTDIR/print_int_basic.con" "42
0"
run_ok "$TESTDIR/print_bool_basic.con" "true
0"
run_ok "$TESTDIR/print_in_loop.con" "0
1
2
0"

# Phase 7c: Module file resolution
run_ok "$TESTDIR/module_file/main.con" 42

# Additional complex tests
run_ok "$TESTDIR/complex_fibonacci_closure.con" 55
run_ok "$TESTDIR/complex_state_machine.con" 42
run_ok "$TESTDIR/complex_builder_pattern.con" 60
run_ok "$TESTDIR/complex_error_chain.con" 40
run_ok "$TESTDIR/complex_defer_cleanup.con" 30

# Phase C: Self keyword
run_ok "$TESTDIR/self_type_basic.con" 42
run_ok "$TESTDIR/self_type_method.con" 42

# Phase D: Labeled loops
run_ok "$TESTDIR/labeled_break.con" 42
run_ok "$TESTDIR/labeled_continue.con" 0

# Phase E: Trait bounds
run_ok "$TESTDIR/trait_bound_basic.con" 30
run_ok "$TESTDIR/trait_bound_multiple.con" 50

# Phase G: Recursive data structure tests
run_ok "$TESTDIR/complex_recursive_list.con" 42
run_ok "$TESTDIR/complex_recursive_tree.con" 42
run_ok "$TESTDIR/complex_recursive_mutual.con" 42

# Phase 7c: Heap dereference
run_ok "$TESTDIR/heap_deref_basic.con" 30
run_ok "$TESTDIR/heap_deref_int.con" 42
run_ok "$TESTDIR/heap_deref_enum.con" 42
run_ok "$TESTDIR/heap_deref_recursive.con" 42

# Phase 9a: Option<T>
run_ok "$TESTDIR/option_basic.con" 52
run_ok "$TESTDIR/option_heap.con" 42

# Phase 10: Monomorphized trait dispatch
run_ok "$TESTDIR/trait_dispatch_basic.con" 30
run_ok "$TESTDIR/trait_dispatch_multi.con" 47
run_ok "$TESTDIR/trait_dispatch_chain.con" 42

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
run_err "$TESTDIR/error_closure_uncalled.con"    "was never consumed"
run_err "$TESTDIR/error_closure_use_after_move.con" "used after move"
# Phase 3: defer/destroy/Copy errors
run_err "$TESTDIR/error_defer_move.con"          "reserved by defer"
run_err "$TESTDIR/error_copy_destroy.con"        "implements Destroy and cannot be Copy"
run_err "$TESTDIR/error_copy_linear_field.con"   "contains non-copy field"
run_err "$TESTDIR/error_destroy_no_impl.con"     "does not implement Destroy"
run_err "$TESTDIR/error_destroy_reserved.con"    "is a reserved identifier"
# Phase 5: Allocator errors
run_err "$TESTDIR/error_alloc_no_cap.con"       "requires capability"
run_err "$TESTDIR/error_heap_direct_access.con"  "use '->' for heap access"
run_err "$TESTDIR/error_heap_leak.con"           "was never consumed"
run_err "$TESTDIR/error_alloc_reserved.con"      "is a reserved identifier"
# Phase 6: Borrow region errors
run_err "$TESTDIR/error_borrow_escape.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_borrow_frozen.con"     "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_shadow.con"     "shadows existing name"
run_err "$TESTDIR/error_borrow_mut_conflict.con" "is frozen by borrow block"
# Additional escape analysis errors
run_err "$TESTDIR/error_escape_return.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_escape_field.con"      "cannot escape its borrow block"
# While-as-expression errors
run_err "$TESTDIR/error_while_expr_type.con"   "does not match else type"
# Additional break/continue errors
run_err "$TESTDIR/error_break_linear_skip.con" "break would skip unconsumed linear variable"
# Additional closure errors
run_err "$TESTDIR/error_closure_double_call.con" "used after move"
# Additional capability errors
run_err "$TESTDIR/error_cap_closure_context.con" "requires capability"
# Additional borrow errors
run_err "$TESTDIR/error_borrow_double_mut.con"   "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_assign_frozen.con" "frozen by borrow block"
# Bitwise errors
run_err "$TESTDIR/error_bitwise_float.con" "type mismatch"
# Print errors
run_err "$TESTDIR/error_print_no_cap.con" "requires capability"
# Module errors
run_err "$TESTDIR/error_module_not_found.con" "module file not found"
run_err "$TESTDIR/module_circular/main.con" "circular module import"
# Self keyword errors
run_err "$TESTDIR/error_self_outside_impl.con" "Self can only be used inside impl blocks"
# Labeled loop errors
run_err "$TESTDIR/error_unknown_label.con" "unknown loop label"
run_err "$TESTDIR/error_label_not_loop.con" "label can only precede while or for"
# Trait bound errors
run_err "$TESTDIR/error_trait_bound_missing.con" "does not implement trait"
# Trait dispatch errors
run_err "$TESTDIR/error_trait_dispatch_missing.con" "no method"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
