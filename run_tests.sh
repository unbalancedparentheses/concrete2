#!/usr/bin/env bash
set -euo pipefail

COMPILER=".lake/build/bin/concrete"
TESTDIR="lean_tests"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TEST_JOBS="${TEST_JOBS:-1}"
JOBDIR="$TMPDIR/jobs"
mkdir -p "$JOBDIR"

PASS=0
FAIL=0
declare -a JOB_PIDS=()
declare -a JOB_FILES=()

path_key() {
    local path="$1"
    path="${path//\//__}"
    path="${path//:/_}"
    path="${path// /_}"
    echo "$path"
}

record_result() {
    local result_file="$1"
    local status message
    status=$(sed -n '1p' "$result_file")
    message=$(sed -n '2,$p' "$result_file")
    echo "$message"
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

flush_one_job() {
    local pid="${JOB_PIDS[0]}"
    local result_file="${JOB_FILES[0]}"
    wait "$pid" || true
    record_result "$result_file"
    JOB_PIDS=("${JOB_PIDS[@]:1}")
    JOB_FILES=("${JOB_FILES[@]:1}")
}

flush_jobs() {
    while [ "${#JOB_PIDS[@]}" -gt 0 ]; do
        flush_one_job
    done
}

throttle_jobs() {
    while [ "${#JOB_PIDS[@]}" -ge "$TEST_JOBS" ]; do
        flush_one_job
    done
}

# Positive tests: should compile and produce expected output
run_ok_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"

    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        {
            echo "FAIL"
            echo "FAIL  $file — compilation failed (expected success)"
        } > "$result_file"
        return
    fi
    local actual
    actual=$("$out" 2>&1) || true
    if [ "$actual" = "$expected" ]; then
        {
            echo "PASS"
            echo "  ok  $file => $expected"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file — expected '$expected', got '$actual'"
        } > "$result_file"
    fi
}

run_ok() {
    local file="$1"
    local expected="$2"
    if [ "$TEST_JOBS" -le 1 ]; then
        local result_file="$JOBDIR/$$.$RANDOM.result"
        run_ok_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    local result_file="$JOBDIR/$$.$RANDOM.result"
    throttle_jobs
    (run_ok_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

# Negative tests: should fail to compile with a specific error substring
run_err_worker() {
    local file="$1"
    local expected_err="$2"
    local result_file="$3"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"

    local stderr
    if stderr=$($COMPILER "$file" -o "$out" 2>&1); then
        {
            echo "FAIL"
            echo "FAIL  $file — compiled successfully (expected error)"
        } > "$result_file"
        return
    fi
    if grep -Fq -- "$expected_err" <<<"$stderr"; then
        {
            echo "PASS"
            echo "  ok  $file => error: $expected_err"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file — expected error '$expected_err', got: $stderr"
        } > "$result_file"
    fi
}

run_err() {
    local file="$1"
    local expected_err="$2"
    if [ "$TEST_JOBS" -le 1 ]; then
        local result_file="$JOBDIR/$$.$RANDOM.result"
        run_err_worker "$file" "$expected_err" "$result_file"
        record_result "$result_file"
        return
    fi
    local result_file="$JOBDIR/$$.$RANDOM.result"
    throttle_jobs
    (run_err_worker "$file" "$expected_err" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
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
run_ok "$TESTDIR/struct_loop_field_assign.con" 42
run_ok "$TESTDIR/struct_loop_break.con"  42
run_ok "$TESTDIR/struct_nested_loop.con" 42
run_ok "$TESTDIR/linear_consume.con"     42
run_ok "$TESTDIR/linear_branch_agree.con" 42
run_ok "$TESTDIR/linear_loop_inner.con"  3
run_ok "$TESTDIR/enum_basic.con"        2
run_ok "$TESTDIR/enum_fields.con"       12
run_ok "$TESTDIR/enum_linear.con"       42
run_ok "$TESTDIR/borrow_read.con"      10
run_ok "$TESTDIR/borrow_mut.con"       42
run_ok "$TESTDIR/borrow_no_consume.con" 42
run_ok "$TESTDIR/sequential_mut_borrow.con" 43
run_ok "$TESTDIR/generic_fn.con"       42
run_ok "$TESTDIR/generic_struct.con"   30
run_ok "$TESTDIR/string_basic.con"    5
run_ok "$TESTDIR/string_borrow.con"   10
run_ok "$TESTDIR/result_ok.con"      42
run_ok "$TESTDIR/result_err.con"     99
run_ok "$TESTDIR/result_generic_try.con" 42
run_ok "$TESTDIR/net_tcp_roundtrip.con" 42
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
# Phase 3: defer/destroy/Copy
run_ok "$TESTDIR/defer_basic.con" 10
run_ok "$TESTDIR/defer_lifo.con" 42
run_ok "$TESTDIR/defer_early_return.con" 10
run_ok "$TESTDIR/defer_loop.con" 42
run_ok "$TESTDIR/destroy_trait.con" 42
run_ok "$TESTDIR/copy_struct.con" 42
run_ok "$TESTDIR/copy_enum.con" 42

# abort test: compiles but exits with nonzero (signal)
run_abort_worker() {
    local file="$1"
    local result_file="$2"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"
    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        {
            echo "FAIL"
            echo "FAIL  $file — compilation failed"
        } > "$result_file"
        return
    fi
    if "$out" > /dev/null 2>&1; then
        {
            echo "FAIL"
            echo "FAIL  $file — expected nonzero exit"
        } > "$result_file"
    else
        {
            echo "PASS"
            echo "  ok  $file => nonzero exit"
        } > "$result_file"
    fi
}
run_abort() {
    local file="$1"
    if [ "$TEST_JOBS" -le 1 ]; then
        local result_file="$JOBDIR/$$.$RANDOM.result"
        run_abort_worker "$file" "$result_file"
        record_result "$result_file"
        return
    fi
    local result_file="$JOBDIR/$$.$RANDOM.result"
    throttle_jobs
    (run_abort_worker "$file" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
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
run_ok "$TESTDIR/result_string.con" 5
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
run_ok "$TESTDIR/print_int_basic.con" "42"
run_ok "$TESTDIR/print_bool_basic.con" "true"
run_ok "$TESTDIR/print_in_loop.con" "0
1
2"

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
run_ok "$TESTDIR/option_string.con" 2
run_ok "$TESTDIR/option_mixed_payloads.con" 44

# Phase 11: File I/O builtins
run_ok "$TESTDIR/file_write_read.con" 5
run_ok "$TESTDIR/file_read_basic.con" 12

# Phase 10: Monomorphized trait dispatch
run_ok "$TESTDIR/trait_dispatch_basic.con" 30
run_ok "$TESTDIR/trait_dispatch_multi.con" 47
run_ok "$TESTDIR/trait_dispatch_chain.con" 42

# Phase 12: New stdlib builtins
run_ok "$TESTDIR/string_slice_basic.con" 5
run_ok "$TESTDIR/string_char_at_basic.con" 65
run_ok "$TESTDIR/string_contains_basic.con" 1
run_ok "$TESTDIR/string_eq_basic.con" 1
run_ok "$TESTDIR/int_to_string_basic.con" 2
run_ok "$TESTDIR/string_to_int_basic.con" 123
run_ok "$TESTDIR/string_trim_basic.con" 5
run_ok "$TESTDIR/print_char_basic.con" "A0"

# Vec<T> tests
run_ok "$TESTDIR/vec_basic.con" 23
run_ok "$TESTDIR/vec_push_get.con" 500
run_ok "$TESTDIR/vec_pop.con" 42
run_ok "$TESTDIR/vec_set_basic.con" 99
run_ok "$TESTDIR/vec_len_after_ops.con" 32
run_ok "$TESTDIR/vec_stress_realloc.con" 249
run_ok "$TESTDIR/vec_set_all.con" 60
run_ok "$TESTDIR/vec_pop_until_empty.con" 29

# Networking tests
if [ "${SKIP_FLAKY_TCP_TEST:-0}" = "1" ]; then
    echo "skip lean_tests/tcp_basic.con (SKIP_FLAKY_TCP_TEST=1)"
else
    run_ok "$TESTDIR/tcp_basic.con" 1
fi
run_ok "$TESTDIR/socket_listen_close.con" 0

# HashMap tests
run_ok "$TESTDIR/hashmap_int_int.con" 102
run_ok "$TESTDIR/hashmap_string_int.con" 42
run_ok "$TESTDIR/hashmap_remove.con" 0
run_ok "$TESTDIR/hashmap_contains.con" 10
run_ok "$TESTDIR/hashmap_overwrite.con" 201
run_ok "$TESTDIR/hashmap_remove_check.con" 201
run_ok "$TESTDIR/hashmap_stress.con" 790
run_ok "$TESTDIR/hashmap_get_missing.con" 0

# Phase 7: FFI / Unsafe
run_ok "$TESTDIR/ffi_basic.con" 42
run_ok "$TESTDIR/trusted_extern_basic.con" 42

# Phase 8: Additional coverage
run_ok "$TESTDIR/nested_match_enum.con" 60
run_ok "$TESTDIR/generic_pair.con" 42
run_ok "$TESTDIR/enum_multi_variant.con" 8
run_ok "$TESTDIR/trait_multi_bound.con" 42
run_ok "$TESTDIR/while_nested_labeled.con" 25
run_ok "$TESTDIR/if_else_while.con" 3
run_ok "$TESTDIR/while_seq_scoping.con" 400
run_ok "$TESTDIR/fmt_parse_roundtrip.con" 0
run_ok "$TESTDIR/vec_trace.con" 0
run_ok "$TESTDIR/hashmap_trace.con" 0
run_ok "$TESTDIR/struct_nested.con" 42
run_ok "$TESTDIR/complex_multi_feature.con" 40
run_ok "$TESTDIR/complex_heap_borrow.con" 42
run_ok "$TESTDIR/complex_enum_nested.con" 87
run_ok "$TESTDIR/defer_multiple.con" 30
run_ok "$TESTDIR/borrow_in_method.con" 67
run_ok "$TESTDIR/generic_multi_bound_dispatch.con" 49
run_ok "$TESTDIR/complex_recursive_enum.con" 19
run_ok "$TESTDIR/struct_method_chain.con" 39
run_ok "$TESTDIR/complex_option_chain.con" 26
run_ok "$TESTDIR/complex_trait_hierarchy.con" 45
run_ok "$TESTDIR/cap_propagation_deep.con" "1
42"

# Unsafe boundary: ref-to-ptr is safe (no Unsafe needed)
run_ok "$TESTDIR/ref_to_ptr_safe.con" 0

# repr(C) / FFI safety
run_ok "$TESTDIR/repr_c_basic.con" 42
run_ok "$TESTDIR/repr_c_nested.con" 42
run_ok "$TESTDIR/repr_c_cross_module.con" 30

# Function pointer from struct field (indirect call fix)
run_ok "$TESTDIR/fn_ptr_struct_field.con" 42
run_ok "$TESTDIR/fn_ptr_method_call.con" 42
run_ok "$TESTDIR/stdlib_hashmap.con" 0

echo ""
flush_jobs
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
run_err "$TESTDIR/error_linear_used_not_consumed.con" "was never consumed"
run_err "$TESTDIR/error_deref_non_ref.con"        "cannot dereference"
run_err "$TESTDIR/error_generic_count.con"       "expects 2 arguments"
run_err "$TESTDIR/error_generic_type.con"        "type mismatch"
run_err "$TESTDIR/error_generic_unused_linear.con" "was never consumed"
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
run_err "$TESTDIR/error_cap_pure.con"            "but caller has"
run_err "$TESTDIR/error_cap_propagation.con"     "but caller has"
run_err "$TESTDIR/error_cap_method.con"          "but caller has"
run_err "$TESTDIR/error_cap_poly_inline.con"     "requires capability"
run_err "$TESTDIR/error_break_outside.con"       "break outside of loop"
run_err "$TESTDIR/error_continue_outside.con"    "continue outside of loop"
# Phase 3: defer/destroy/Copy errors
run_err "$TESTDIR/error_defer_move.con"          "reserved by defer"
run_err "$TESTDIR/error_copy_destroy.con"        "implements Destroy and cannot be Copy"
run_err "$TESTDIR/error_copy_linear_field.con"   "contains non-copy field"
run_err "$TESTDIR/error_destroy_no_impl.con"     "does not implement Destroy"
run_err "$TESTDIR/error_destroy_reserved.con"    "is a reserved identifier"
# Phase 5: Allocator errors
run_err "$TESTDIR/error_alloc_no_cap.con"       "but caller has"
run_err "$TESTDIR/error_heap_direct_access.con"  "use '->' for heap access"
run_err "$TESTDIR/error_heap_leak.con"           "was never consumed"
run_err "$TESTDIR/error_alloc_reserved.con"      "is a reserved identifier"
# Phase 6: Borrow region errors
run_err "$TESTDIR/error_borrow_escape.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_borrow_frozen.con"     "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_shadow.con"     "shadows existing name"
run_err "$TESTDIR/error_borrow_mut_conflict.con" "is frozen by borrow block"
run_err "$TESTDIR/error_named_ref_mut_conflict.con" "already borrowed"
# Additional escape analysis errors
run_err "$TESTDIR/error_escape_return.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_escape_field.con"      "cannot escape its borrow block"
# While-as-expression errors
run_err "$TESTDIR/error_while_expr_type.con"   "does not match else type"
# Additional break/continue errors
run_err "$TESTDIR/error_break_linear_skip.con" "break would skip unconsumed linear variable"
# Additional borrow errors
run_err "$TESTDIR/error_borrow_double_mut.con"   "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_assign_frozen.con" "frozen by borrow block"
# Bitwise errors
run_err "$TESTDIR/error_bitwise_float.con" "type mismatch"
# Print errors
run_err "$TESTDIR/error_print_no_cap.con" "but caller has"
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
# File I/O errors
run_err "$TESTDIR/error_file_no_cap.con" "but caller has"
# FFI errors
run_err "$TESTDIR/error_ffi_no_unsafe.con" "but caller has"
# Vec errors
run_err "$TESTDIR/error_vec_no_alloc.con" "but caller has"
# Network errors
run_err "$TESTDIR/error_network_no_cap.con" "but caller has"
# HashMap errors
run_err "$TESTDIR/error_hashmap_no_alloc.con" "but caller has"
# Match exhaustiveness
run_err "$TESTDIR/error_match_missing_variant.con" "missing variant"
# Return type mismatch
run_err "$TESTDIR/error_return_type_mismatch.con" "type mismatch"
# Capability propagation errors
run_err "$TESTDIR/error_cap_deep_missing.con" "but caller has"
# Borrow conflict errors
run_err "$TESTDIR/error_borrow_double_mut.con" "frozen by borrow"

# Span-bearing diagnostics (Resolve errors include line:col prefix)
run_err "$TESTDIR/error_resolve_undeclared_span.con" "4:12: error[resolve]: undeclared variable"
run_err "$TESTDIR/error_resolve_unknown_func_span.con" "3:18: error[resolve]: unknown function"
run_err "$TESTDIR/error_resolve_unknown_type.con" "error[resolve]: unknown type 'Foo'"
run_err "$TESTDIR/error_resolve_not_enum.con" "is not an enum"
run_err "$TESTDIR/error_resolve_multi_errors.con" "unknown function 'unknown2'"
run_err "$TESTDIR/error_resolve_unknown_enum.con" "unknown enum 'Phantom'"
# Check error variants
run_err "$TESTDIR/error_assign_immutable.con" "cannot assign to immutable"
run_err "$TESTDIR/error_arrow_not_heap.con" "arrow access"
# repr(C) / FFI safety errors
run_err "$TESTDIR/error_repr_c_generic.con" "cannot have type parameters"
run_err "$TESTDIR/error_repr_c_string_field.con" "non-FFI-safe field"
run_err "$TESTDIR/error_extern_string_param.con" "non-FFI-safe parameter"
run_err "$TESTDIR/error_extern_non_repr_struct.con" "non-FFI-safe parameter"
run_err "$TESTDIR/error_repr_c_on_enum.con" "can only be applied to struct"
# Unsafe boundary errors
run_err "$TESTDIR/error_ptr_deref_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_ptr_assign_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_ptr_cast_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_int_to_ptr_no_unsafe.con" "requires capability"
# Trusted boundary tests
run_ok "$TESTDIR/trusted_fn_ptr_deref.con" 0
run_ok "$TESTDIR/trusted_impl_basic.con" 0
run_ok "$TESTDIR/trusted_ptr_assign.con" 0
run_ok "$TESTDIR/trusted_ptr_cast.con" 0
run_err "$TESTDIR/error_trusted_extern_needs_unsafe.con" "but caller has"
run_err "$TESTDIR/error_trusted_on_struct.con" "trusted"
run_ok "$TESTDIR/trusted_trait_impl.con" 0
run_ok "$TESTDIR/trusted_ptr_arith.con" 0
run_err "$TESTDIR/error_ptr_arith_no_unsafe.con" "requires capability"
# Trusted runtime tests
run_ok "$TESTDIR/trusted_deref_runtime.con" 42
run_ok "$TESTDIR/trusted_assign_runtime.con" 77
run_ok "$TESTDIR/trusted_cast_runtime.con" 0
run_ok "$TESTDIR/trusted_arith_runtime.con" 32
run_ok "$TESTDIR/trusted_with_alloc.con" 10
run_ok "$TESTDIR/trusted_report_check.con" 0
# Capability propagation errors
run_err "$TESTDIR/error_cap_alloc_missing.con" "but caller has"
run_err "$TESTDIR/error_cap_console_missing.con" "but caller has"
run_err "$TESTDIR/error_cap_multi_missing.con" "but caller has"
# Trusted + capabilities interaction errors
run_err "$TESTDIR/error_trusted_no_alloc.con" "but caller has"
# Trusted boundary negative tests
run_err "$TESTDIR/error_untrusted_calls_trusted_ptr.con" "requires capability"
run_err "$TESTDIR/error_untrusted_ptr_assign.con" "requires capability"
# Builtin capability enforcement
run_err "$TESTDIR/error_abort_no_process.con" "but caller has"

# === String edge case tests ===
run_ok "$TESTDIR/string_empty.con" 0
run_ok "$TESTDIR/string_concat_empty.con" 5
run_ok "$TESTDIR/string_eq_same.con" 1
run_ok "$TESTDIR/string_eq_different.con" 0
run_ok "$TESTDIR/string_slice_full.con" 5
run_ok "$TESTDIR/string_multi_fn.con" 8
run_ok "$TESTDIR/string_contains_empty.con" 1
run_ok "$TESTDIR/string_char_at_first_last.con" 196
run_ok "$TESTDIR/string_trim_spaces.con" 2
run_ok "$TESTDIR/string_to_int_roundtrip.con" 42

# === Math function tests ===
run_ok "$TESTDIR/math_sqrt.con" 5
run_ok "$TESTDIR/math_pow.con" 81
run_ok "$TESTDIR/math_abs.con" 52
run_ok "$TESTDIR/trait_numeric_abs.con" 57
run_ok "$TESTDIR/math_floor_ceil.con" 34
run_ok "$TESTDIR/math_sin_cos.con" 10
run_ok "$TESTDIR/math_exp_log.con" 10

# === Integer edge case tests ===
run_ok "$TESTDIR/int_arithmetic_negative.con" 50
run_ok "$TESTDIR/int_division.con" 31
run_ok "$TESTDIR/int_bitwise_combined.con" 15
run_ok "$TESTDIR/int_shift_basic.con" 4
run_ok "$TESTDIR/int_cast_i32.con" 42
run_ok "$TESTDIR/int_large_multiply.con" 56088

# === Newtype tests ===
run_ok "$TESTDIR/newtype_basic.con" 42
run_ok "$TESTDIR/newtype_copy.con" 20
run_ok "$TESTDIR/newtype_linear.con" 7
run_ok "$TESTDIR/newtype_generic.con" 100
run_err "$TESTDIR/error_newtype_no_implicit.con" "type mismatch"
run_err "$TESTDIR/error_newtype_wrong_inner.con" "type mismatch"

# === ABI / Layout tests ===
run_ok "$TESTDIR/sizeof_basic.con" 12
run_ok "$TESTDIR/alignof_basic.con" 12
run_ok "$TESTDIR/repr_packed.con" 7
run_ok "$TESTDIR/repr_align.con" 16
run_err "$TESTDIR/error_repr_packed_align.con" "cannot have both"
run_err "$TESTDIR/error_repr_align_not_pow2.con" "must be a power of two"

# === Summary-path tests ===
run_ok "$TESTDIR/summary_import_pub_fn.con" 42
run_ok "$TESTDIR/summary_import_pub_constant.con" 42
run_ok "$TESTDIR/summary_import_pub_extern.con" 42
run_ok "$TESTDIR/summary_import_pub_newtype.con" 42
run_ok "$TESTDIR/summary_import_type_alias.con" 42
run_ok "$TESTDIR/summary_submodule.con" 42
run_ok "$TESTDIR/summary_trait_impl_cross_module.con" 42
run_err "$TESTDIR/error_summary_trait_missing_cross.con" "missing method"

# === --test flag tests ===
echo ""
flush_jobs
echo "=== --test flag tests ==="
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
    if [ "$TEST_JOBS" -le 1 ]; then
        local result_file="$JOBDIR/$$.$RANDOM.result"
        run_test_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    local result_file="$JOBDIR/$$.$RANDOM.result"
    throttle_jobs
    (run_test_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

run_test "$TESTDIR/test_flag_pass.con" 0
run_test "$TESTDIR/test_flag_mixed.con" 1
run_test "$TESTDIR/test_flag_submodule.con" 0

# #[test] validation errors
run_err "$TESTDIR/error_test_with_params.con" "must have no parameters"
run_err "$TESTDIR/error_test_generic.con" "must not be generic"
run_err "$TESTDIR/error_test_wrong_return.con" "must return i32"
run_err "$TESTDIR/error_test_on_struct.con" "can only be applied to function"

# === Report output tests ===
echo ""
flush_jobs
echo "=== Report output tests ==="

# --report unsafe should show trusted boundaries
report_output=$($COMPILER "$TESTDIR/trusted_report_check.con" --report unsafe 2>&1)
if echo "$report_output" | grep -q "trusted impl Buffer" && echo "$report_output" | grep -q "trusted fn raw_read"; then
    echo "  ok  trusted_report_check.con --report unsafe shows trusted boundaries"
    PASS=$((PASS + 1))
else
    echo "FAIL  trusted_report_check.con --report unsafe missing trusted boundaries"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --report unsafe should show trusted extern fn declarations separately from regular extern fn
report_output=$($COMPILER "$TESTDIR/trusted_extern_basic.con" --report unsafe 2>&1)
if echo "$report_output" | grep -q "Trusted extern functions" && echo "$report_output" | grep -q "trusted extern fn abs"; then
    echo "  ok  trusted_extern_basic.con --report unsafe shows trusted extern functions"
    PASS=$((PASS + 1))
else
    echo "FAIL  trusted_extern_basic.con --report unsafe missing trusted extern functions"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --report caps should show trusted extern with (none) capability
report_output=$($COMPILER "$TESTDIR/trusted_extern_basic.con" --report caps 2>&1)
if echo "$report_output" | grep -q "trusted extern:" && echo "$report_output" | grep -q "abs : (none)"; then
    echo "  ok  trusted_extern_basic.con --report caps shows trusted extern with no capability"
    PASS=$((PASS + 1))
else
    echo "FAIL  trusted_extern_basic.con --report caps missing trusted extern info"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --report unsafe should show regular extern under "Extern functions" (not "Trusted")
report_output=$($COMPILER "$TESTDIR/ffi_basic.con" --report unsafe 2>&1)
if echo "$report_output" | grep -q "Extern functions:" && echo "$report_output" | grep -q "extern fn abs" && ! echo "$report_output" | grep -q "Trusted extern"; then
    echo "  ok  ffi_basic.con --report unsafe shows regular extern (not trusted)"
    PASS=$((PASS + 1))
else
    echo "FAIL  ffi_basic.con --report unsafe should show regular extern, not trusted"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report caps: pure, single cap, multi cap ---
report_output=$($COMPILER "$TESTDIR/report_caps_check.con" --report caps 2>&1)
if echo "$report_output" | grep -q "pure_fn : (pure)"; then
    echo "  ok  report_caps_check.con --report caps shows pure_fn : (pure)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_caps_check.con --report caps missing pure_fn : (pure)"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "alloc_fn : Alloc"; then
    echo "  ok  report_caps_check.con --report caps shows alloc_fn : Alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_caps_check.con --report caps missing alloc_fn : Alloc"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "multi_fn : File, Network"; then
    echo "  ok  report_caps_check.con --report caps shows multi_fn : File, Network"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_caps_check.con --report caps missing multi_fn : File, Network"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report unsafe: Unsafe capability + raw pointer signatures ---
report_output=$($COMPILER "$TESTDIR/report_unsafe_rawptr.con" --report unsafe 2>&1)
if echo "$report_output" | grep -q "Functions with Unsafe capability" && echo "$report_output" | grep -q "ptr_swap"; then
    echo "  ok  report_unsafe_rawptr.con --report unsafe shows Unsafe capability for ptr_swap"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_unsafe_rawptr.con --report unsafe missing Unsafe capability for ptr_swap"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "Functions with raw pointer signatures" && echo "$report_output" | grep -q "ptr_swap"; then
    echo "  ok  report_unsafe_rawptr.con --report unsafe shows raw pointer signatures for ptr_swap"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_unsafe_rawptr.con --report unsafe missing raw pointer signatures for ptr_swap"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report layout: struct sizes, packed, enum tags ---
report_output=$($COMPILER "$TESTDIR/report_layout_check.con" --report layout 2>&1)
if echo "$report_output" | grep -q "struct Padded" && echo "$report_output" | grep -q "size:" && echo "$report_output" | grep -q "align:"; then
    echo "  ok  report_layout_check.con --report layout shows struct Padded with size and align"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --report layout missing struct Padded with size/align"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "struct Packed" && echo "$report_output" | grep -q "#\[packed\]"; then
    echo "  ok  report_layout_check.con --report layout shows struct Packed with #[packed]"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --report layout missing struct Packed with #[packed]"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "enum Shape" && echo "$report_output" | grep -q "tag:" && echo "$report_output" | grep -q "payload_offset:"; then
    echo "  ok  report_layout_check.con --report layout shows enum Shape with tag and payload_offset"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --report layout missing enum Shape with tag/payload_offset"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report layout: cross-validate sizes against runtime sizeof ---
padded_size=$(echo "$report_output" | grep "struct Padded" -A1 | grep -o "size: [0-9]*" | head -1 | grep -o "[0-9]*")
packed_size=$(echo "$report_output" | grep "struct Packed" -A1 | grep -o "size: [0-9]*" | head -1 | grep -o "[0-9]*")
expected_sum=$((padded_size + packed_size))
$COMPILER "$TESTDIR/report_layout_check.con" -o "$TMPDIR/report_layout_check" > /dev/null 2>&1
runtime_sum=$("$TMPDIR/report_layout_check" 2>&1) || true
if [ "$expected_sum" = "$runtime_sum" ]; then
    echo "  ok  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) match runtime sizeof ($runtime_sum)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) != runtime sizeof ($runtime_sum)"
    FAIL=$((FAIL + 1))
fi

# --- report interface: public API, struct fields, private exclusion ---
report_output=$($COMPILER "$TESTDIR/report_interface_check.con" --report interface 2>&1)
if echo "$report_output" | grep -q "fn add_points" && echo "$report_output" | grep -q "\[Alloc\]"; then
    echo "  ok  report_interface_check.con --report interface shows fn add_points with [Alloc]"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_interface_check.con --report interface missing fn add_points with [Alloc]"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "struct Point" && echo "$report_output" | grep -q "x: i32"; then
    echo "  ok  report_interface_check.con --report interface shows struct Point with x: i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_interface_check.con --report interface missing struct Point with x: i32"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if ! echo "$report_output" | grep -q "private_helper"; then
    echo "  ok  report_interface_check.con --report interface excludes private_helper"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_interface_check.con --report interface should not show private_helper"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report mono: generic count and specializations ---
report_output=$($COMPILER "$TESTDIR/report_mono_check.con" --report mono 2>&1)
if echo "$report_output" | grep -q "Generic functions: 1"; then
    echo "  ok  report_mono_check.con --report mono shows Generic functions: 1"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --report mono missing Generic functions: 1"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

if echo "$report_output" | grep -q "Specializations generated: 2"; then
    echo "  ok  report_mono_check.con --report mono shows Specializations generated: 2"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --report mono missing Specializations generated: 2"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# === Codegen differential tests ===
echo ""
echo "=== Codegen differential tests ==="

# --- Category 1: SSA optimization verification ---

# Constant folding: 2 + 3 should be folded to 5
ssa_output=$($COMPILER "$TESTDIR/codegen_constfold.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "ret i64 5"; then
    echo "  ok  codegen_constfold.con --emit-ssa constant folded to ret i64 5"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa missing ret i64 5 (constant folding)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! echo "$ssa_output" | grep -q "add i64"; then
    echo "  ok  codegen_constfold.con --emit-ssa no residual add i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa still contains add i64 (folding missed)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Strength reduction: x * 8 should become shl x, 3
ssa_output=$($COMPILER "$TESTDIR/codegen_strength.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "shl i64 %x, 3"; then
    echo "  ok  codegen_strength.con --emit-ssa strength-reduced *8 to shl 3"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa missing shl i64 %x, 3 (strength reduction)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! echo "$ssa_output" | grep -q "mul i64"; then
    echo "  ok  codegen_strength.con --emit-ssa no residual mul i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa still contains mul i64 (reduction missed)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# --- Category 2: Codegen structure verification ---

# Struct field access: second field at offset 8
ssa_output=$($COMPILER "$TESTDIR/struct_basic.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "gep i8 %p, i64 8"; then
    echo "  ok  struct_basic.con --emit-ssa second field GEP at offset 8"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing gep i8 %p, i64 8"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Enum tag load and comparison
ssa_output=$($COMPILER "$TESTDIR/enum_basic.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "load i32"; then
    echo "  ok  enum_basic.con --emit-ssa tag loaded as i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing load i32 (tag load)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "eq i1"; then
    echo "  ok  enum_basic.con --emit-ssa tag comparison with eq i1"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing eq i1 (tag comparison)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Monomorphization: identity<T> specialized for Int and i32
ssa_output=$($COMPILER "$TESTDIR/report_mono_check.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "define i64 @identity_for_Int"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i64 @identity_for_Int"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "define i32 @identity_for_i32"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i32 @identity_for_i32"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# LLVM struct type definition
llvm_output=$($COMPILER "$TESTDIR/struct_basic.con" --emit-llvm 2>&1)
if echo "$llvm_output" | grep -q "%struct.Point = type { i64, i64 }"; then
    echo "  ok  struct_basic.con --emit-llvm has %struct.Point = type { i64, i64 }"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-llvm missing %struct.Point = type { i64, i64 }"
    echo "$llvm_output" | head -40
    FAIL=$((FAIL + 1))
fi

# Mutable borrow generates store
ssa_output=$($COMPILER "$TESTDIR/borrow_mut.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "store i64"; then
    echo "  ok  borrow_mut.con --emit-ssa mutable borrow generates store i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  borrow_mut.con --emit-ssa missing store i64"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-loop: aggregate promoted to stable alloca (no aggregate phi)
ssa_output=$($COMPILER "$TESTDIR/struct_loop_field_assign.con" --emit-ssa 2>&1)
if echo "$ssa_output" | grep -q "alloca %Point" && ! echo "$ssa_output" | grep -q "phi %Point"; then
    echo "  ok  struct_loop_field_assign.con --emit-ssa aggregate promoted to alloca (no phi %Point)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_loop_field_assign.con --emit-ssa expected alloca %Point but no phi %Point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# --- Category 3: Cross-representation consistency ---

# LLVM packed struct matches report layout
llvm_output=$($COMPILER "$TESTDIR/report_layout_check.con" --emit-llvm 2>&1)
if echo "$llvm_output" | grep -q "%struct.Packed = type <{"; then
    echo "  ok  report_layout_check.con --emit-llvm packed struct uses <{ syntax"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm missing packed struct <{ syntax"
    echo "$llvm_output" | head -40
    FAIL=$((FAIL + 1))
fi

# LLVM enum payload size matches report layout max_payload
report_output=$($COMPILER "$TESTDIR/report_layout_check.con" --report layout 2>&1)
layout_max_payload=$(echo "$report_output" | grep -o "max_payload: [0-9]*" | grep -o "[0-9]*")
if echo "$llvm_output" | grep -q "%enum.Shape = type { i32, \[$layout_max_payload x i8\] }"; then
    echo "  ok  report_layout_check.con --emit-llvm enum payload size matches --report layout max_payload ($layout_max_payload)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm enum payload size does not match --report layout max_payload ($layout_max_payload)"
    echo "  LLVM: $(echo "$llvm_output" | grep '%enum.Shape')"
    echo "  Report: $(echo "$report_output" | grep 'max_payload')"
    FAIL=$((FAIL + 1))
fi

# Core-SSA consistency: function signature preserved across representations
core_output=$($COMPILER "$TESTDIR/struct_basic.con" --emit-core 2>&1)
ssa_output=$($COMPILER "$TESTDIR/struct_basic.con" --emit-ssa 2>&1)
if echo "$core_output" | grep -q "fn sum_point(p: Point) -> Int"; then
    echo "  ok  struct_basic.con --emit-core preserves fn sum_point(p: Point) -> Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-core missing fn sum_point(p: Point) -> Int"
    echo "$core_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "define i64 @sum_point"; then
    echo "  ok  struct_basic.con --emit-ssa maps sum_point to define i64 @sum_point"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing define i64 @sum_point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# === Compiler bug regression tests ===
run_ok "$TESTDIR/regress_deref_field_precedence.con"  42
run_ok "$TESTDIR/regress_mut_field_writeback.con"     42
run_ok "$TESTDIR/regress_char_bool_cast.con"          42
run_ok "$TESTDIR/regress_ref_no_spill.con"            42
run_ok "$TESTDIR/regress_string_field_access.con"     42

# === Stdlib module tests ===
echo ""
echo "=== Stdlib module tests ==="
flush_jobs
rm -f std/src/lib.con.test.ll std/src/lib.con.test
stdlib_output=$($COMPILER std/src/lib.con --test 2>&1) && stdlib_exit=0 || stdlib_exit=$?
stdlib_pass=$(echo "$stdlib_output" | grep -c "^PASS:" || true)
stdlib_fail=$(echo "$stdlib_output" | grep -c "^FAIL:" || true)
echo "  Stdlib: $stdlib_pass passed, $stdlib_fail failed (exit $stdlib_exit)"
if [ "$stdlib_fail" -gt 0 ]; then
    echo "$stdlib_output" | grep "^FAIL:"
fi
PASS=$((PASS + stdlib_pass))
FAIL=$((FAIL + stdlib_fail))

# === Per-collection test verification ===
# Verify each new collection's tests are present and passing in the stdlib run.
# This catches silent regressions where a collection's tests vanish or break.
echo ""
echo "=== Collection test verification ==="

check_collection_tests() {
    local name="$1"
    shift
    local missing=0
    for test_name in "$@"; do
        if ! echo "$stdlib_output" | grep -qF "PASS: $test_name"; then
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

check_collection_tests "Deque" \
    test_push_back_pop_front test_push_front_pop_back test_deque_pop_empty \
    test_get test_growth_wrapping test_mixed_push_pop \
    test_deque_wrap_stress test_deque_clear_reuse

check_collection_tests "BinaryHeap" \
    test_max_heap_basic test_min_heap_basic test_heap_pop_empty test_heap_stress \
    test_heap_sorted_output test_heap_push_pop_interleaved

check_collection_tests "OrderedMap" \
    test_insert_and_get test_sorted_order test_overwrite test_omap_remove test_get_missing \
    test_omap_insert_remove_stress

check_collection_tests "OrderedSet" \
    test_insert_contains test_oset_remove test_min_max test_duplicate_insert \
    test_oset_insert_remove_stress test_oset_clear_reuse

check_collection_tests "BitSet" \
    test_set_and_test test_unset test_count test_union test_intersect test_with_capacity \
    test_loop_set_small test_bitset_word_boundaries test_bitset_large_stress \
    test_len_is_logical_size test_beyond_logical_size test_unset_beyond_logical_size \
    test_non_monotonic_sets test_unset_preserves_len test_intersect_preserves_len \
    test_bitset_clear_reuse

echo ""
flush_jobs
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
