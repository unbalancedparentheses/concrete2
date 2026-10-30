# xtarget: the code units of tests/cases/xtarget.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_xtarget_1() {
XTARGET_PASS=0
XTARGET_FAIL=0
run_cross_check() {
    local file="$1"
    local base
    base=$(basename "$file" .con)
    local llpath="$TMPDIR/xtarget_${base}.ll"
    cached_output "$file" "--emit-llvm" > "$llpath" 2>/dev/null
    if [ ! -s "$llpath" ]; then
        return
    fi
    if clang -S --target=x86_64-unknown-linux-gnu -Wno-override-module "$llpath" -o /dev/null 2>/dev/null; then
        XTARGET_PASS=$((XTARGET_PASS + 1))
    else
        echo "FAIL  $base — x86_64 IR compilation failed"
        XTARGET_FAIL=$((XTARGET_FAIL + 1))
        FAIL=$((FAIL + 1))
    fi
}
# Representative subset: integration, stress, phase3, ABI, complex programs
for f in \
    "$TESTDIR/integration_stress_workload.con" \
    "$TESTDIR/integration_compiler_stress.con" \
    "$TESTDIR/integration_generic_pipeline.con" \
    "$TESTDIR/integration_state_machine.con" \
    "$TESTDIR/integration_recursive_structures.con" \
    "$TESTDIR/integration_multi_file_calculator.con" \
    "$TESTDIR/integration_type_registry.con" \
    "$TESTDIR/integration_pipeline_processor.con" \
    "$TESTDIR/phase3_expression_evaluator.con" \
    "$TESTDIR/phase3_task_scheduler.con" \
    "$TESTDIR/phase3_data_pipeline.con" \
    "$TESTDIR/phase3_type_checker.con" \
    "$TESTDIR/phase3_state_machine.con" \
    "$TESTDIR/complex_linked_list.con" \
    "$TESTDIR/complex_struct_methods.con" \
    "$TESTDIR/complex_generic_container.con" \
    "$TESTDIR/complex_state_machine.con" \
    "$TESTDIR/complex_recursive_list.con" \
    "$TESTDIR/complex_recursive_tree.con" \
    "$TESTDIR/repr_c_basic.con" \
    "$TESTDIR/vec_basic.con" \
    "$TESTDIR/vec_stress_realloc.con" \
    "$TESTDIR/trait_basic.con" \
    "$TESTDIR/generic_chain.con" \
    "$TESTDIR/test_recursive_fibonacci.con" \
    ; do
    [ -f "$f" ] && run_cross_check "$f"
done
PASS=$((PASS + XTARGET_PASS))
echo "  $XTARGET_PASS/$((XTARGET_PASS + XTARGET_FAIL)) cross-target checks passed"
:
}
