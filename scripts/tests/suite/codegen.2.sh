# codegen.2: the code units of tests/cases/codegen.2.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_codegen_2_1() {

# LLVM packed struct matches report layout
llvm_output=$(cached_emit "$TESTDIR/report_layout_check.con" "--emit-llvm")
if grep <<<"$llvm_output" -q "%struct.Packed = type <{"; then
    echo "  ok  report_layout_check.con --emit-llvm packed struct uses <{ syntax"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm missing packed struct <{ syntax"
    echo "$llvm_output" | awk "NR<=40"
    FAIL=$((FAIL + 1))
fi

# LLVM enum payload size matches report layout max_payload
report_output=$(cached_output "$TESTDIR/report_layout_check.con" "--report layout")
layout_max_payload=$(grep <<<"$report_output" -o "max_payload: [0-9]*" | grep -o "[0-9]*")
if grep <<<"$llvm_output" -qE "%enum\.Shape = type \{ (\[0 x i64\], )?i32, \[$layout_max_payload x i8\] \}"; then
    echo "  ok  report_layout_check.con --emit-llvm enum payload size matches --report layout max_payload ($layout_max_payload)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm enum payload size does not match --report layout max_payload ($layout_max_payload)"
    echo "  LLVM: $(grep <<<"$llvm_output" '%enum.Shape')"
    echo "  Report: $(grep <<<"$report_output" 'max_payload')"
    FAIL=$((FAIL + 1))
fi

# Core-SSA consistency: function signature preserved across representations
core_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-core")
ssa_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-ssa")
if grep <<<"$core_output" -q "fn sum_point(p: Point) -> Int"; then
    echo "  ok  struct_basic.con --emit-core preserves fn sum_point(p: Point) -> Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-core missing fn sum_point(p: Point) -> Int"
    echo "$core_output"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$ssa_output" -q "define i64 @sum_point"; then
    echo "  ok  struct_basic.con --emit-ssa maps sum_point to define i64 @sum_point"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing define i64 @sum_point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi
:
}
