# codegen: the code units of tests/cases/codegen.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_codegen_1() {

# --- Category 1: SSA optimization verification ---

# Constant folding: 2 + 3 should be folded to 5
ssa_output=$(cached_emit "$TESTDIR/codegen_constfold.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "ret i64 5"; then
    echo "  ok  codegen_constfold.con --emit-ssa constant folded to ret i64 5"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa missing ret i64 5 (constant folding)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! grep <<<"$ssa_output" -q "add i64"; then
    echo "  ok  codegen_constfold.con --emit-ssa no residual add i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa still contains add i64 (folding missed)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Strength reduction REMOVED for `*` under checked arithmetic (ROADMAP #10):
# `x * 8 → x << 3` is unsound — the checked shift helper validates only the shift
# AMOUNT, not value overflow, so the rewrite would silently drop the overflow
# trap that `*` must raise. So `x * 8` MUST stay a `mul` (it lowers to the checked
# `@__cc_smul_i64` helper). This is a regression guard that the unsound reduction
# stays gone. (Unsigned `div` by a power of two → `shr` is still applied; it is
# sound — the quotient always fits.)
ssa_output=$(cached_emit "$TESTDIR/codegen_strength.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "mul i64"; then
    echo "  ok  codegen_strength.con --emit-ssa keeps mul (checked, no unsound *→shl)"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa lost the mul (unsound *→shl reduction is back?)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! grep <<<"$ssa_output" -q "shl i64 %x"; then
    echo "  ok  codegen_strength.con --emit-ssa did NOT rewrite the mul to a shift"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa rewrote *8 to a shift (drops the overflow trap)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

llvm_output=$(cached_emit "$TESTDIR/codegen_strength.con" "--emit-llvm")
if grep <<<"$llvm_output" -q "@__cc_smul_i64"; then
    echo "  ok  codegen_strength.con --emit-llvm *8 lowers to the checked smul helper"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-llvm missing @__cc_smul_i64 (checked mul lowering)"
    echo "$llvm_output"
    FAIL=$((FAIL + 1))
fi

# --- Category 2: Codegen structure verification ---

# Struct field access: second field at offset 8
ssa_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "gep i8 %p, i64 8"; then
    echo "  ok  struct_basic.con --emit-ssa second field GEP at offset 8"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing gep i8 %p, i64 8"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Enum tag load and comparison
ssa_output=$(cached_emit "$TESTDIR/enum_basic.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "load i32"; then
    echo "  ok  enum_basic.con --emit-ssa tag loaded as i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing load i32 (tag load)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$ssa_output" -q "eq i1"; then
    echo "  ok  enum_basic.con --emit-ssa tag comparison with eq i1"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing eq i1 (tag comparison)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Monomorphization: identity<T> specialized for Int and i32
ssa_output=$(cached_emit "$TESTDIR/report_mono_check.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "define i64 @identity_for_Int"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i64 @identity_for_Int"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$ssa_output" -q "define i32 @identity_for_i32"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i32 @identity_for_i32"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# LLVM struct type definition
llvm_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-llvm")
if grep <<<"$llvm_output" -q "%struct.Point = type { i64, i64 }"; then
    echo "  ok  struct_basic.con --emit-llvm has %struct.Point = type { i64, i64 }"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-llvm missing %struct.Point = type { i64, i64 }"
    echo "$llvm_output" | awk "NR<=40"
    FAIL=$((FAIL + 1))
fi

# Mutable borrow generates store
ssa_output=$(cached_emit "$TESTDIR/borrow_mut.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "store i64"; then
    echo "  ok  borrow_mut.con --emit-ssa mutable borrow generates store i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  borrow_mut.con --emit-ssa missing store i64"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-loop: aggregate promoted to stable alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_loop_field_assign.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "alloca %Point" && ! grep <<<"$ssa_output" -q "phi %Point"; then
    echo "  ok  struct_loop_field_assign.con --emit-ssa aggregate promoted to alloca (no phi %Point)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_loop_field_assign.con --emit-ssa expected alloca %Point but no phi %Point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-if/else: aggregate merge via alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_if_else_merge.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "alloca %Pair" && ! grep <<<"$ssa_output" -q "phi %Pair"; then
    echo "  ok  struct_if_else_merge.con --emit-ssa aggregate if/else merged via alloca (no phi %Pair)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_if_else_merge.con --emit-ssa expected alloca %Pair but no phi %Pair"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-match: aggregate merge via alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_match_merge.con" "--emit-ssa")
if grep <<<"$ssa_output" -q "alloca %Pair" && ! grep <<<"$ssa_output" -q "phi %Pair"; then
    echo "  ok  struct_match_merge.con --emit-ssa aggregate match merged via alloca (no phi %Pair)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_match_merge.con --emit-ssa expected alloca %Pair but no phi %Pair"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Phase 3: ABI interop test (Concrete + C, verifies sizeof/offsetof match)
abi_ll="$TMPDIR/phase3_abi_interop.ll"
abi_bin="$TMPDIR/phase3_abi_interop"
if filter_match "$TESTDIR/phase3_abi_interop.con"; then
    if $COMPILER "$TESTDIR/phase3_abi_interop.con" --emit-llvm > "$abi_ll" 2>/dev/null; then
        if clang "$abi_ll" "$TESTDIR/phase3_abi_interop.c" -o "$abi_bin" -Wno-override-module 2>/dev/null; then
            abi_rc=0; "$abi_bin" >/dev/null 2>&1 || abi_rc=$?
            if [ "$abi_rc" = "42" ]; then
                echo "  ok  phase3_abi_interop.con C interop sizeof/offsetof match (rc 42)"
                PASS=$((PASS + 1))
            else
                echo "FAIL  phase3_abi_interop.con C interop expected rc 42, got $abi_rc"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL  phase3_abi_interop.con C interop clang link failed"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL  phase3_abi_interop.con C interop compilation failed"
        FAIL=$((FAIL + 1))
    fi
fi

# Bug 103 (fixed): an extern whose name ends in `_destroy` stays a declaration and reaches C.
# The C stub counts the destroy calls; exit 42 needs both to arrive (an empty synthesized body,
# the bug, exits 40). The IR leg pins the extern as exactly one `declare` and no `define`.
r103_ll="$TMPDIR/regress_103_extern_destroy.ll"
r103_bin="$TMPDIR/regress_103_extern_destroy"
if filter_match "$TESTDIR/regress_103_extern_destroy.con"; then
    if $COMPILER "$TESTDIR/regress_103_extern_destroy.con" --emit-llvm > "$r103_ll" 2>/dev/null; then
        if [ "$(grep -cE '^declare void @widget_destroy\(' "$r103_ll")" = "1" ] \
           && ! grep -qE '^define [^@]*@widget_destroy\(' "$r103_ll"; then
            echo "  ok  regress_103_extern_destroy.con: widget_destroy stays a declaration"
            PASS=$((PASS + 1))
        else
            echo "FAIL  regress_103_extern_destroy.con: widget_destroy is not exactly one declaration (bug 103)"
            FAIL=$((FAIL + 1))
        fi
        if clang "$r103_ll" "$TESTDIR/regress_103_extern_destroy.c" -o "$r103_bin" -Wno-override-module 2>/dev/null; then
            r103_rc=0; "$r103_bin" >/dev/null 2>&1 || r103_rc=$?
            if [ "$r103_rc" = "42" ]; then
                echo "  ok  regress_103_extern_destroy.con: both destroys reached C (rc 42)"
                PASS=$((PASS + 1))
            else
                echo "FAIL  regress_103_extern_destroy.con: expected rc 42, got $r103_rc (bug 103)"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL  regress_103_extern_destroy.con: clang link with the C stub failed"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL  regress_103_extern_destroy.con: compilation failed"
        FAIL=$((FAIL + 1))
    fi
fi

# Symbol names (FFI.md "Symbol Names"): a user `fn malloc` is `_C.main.malloc`, `alloc` calls
# the C `malloc`, and no Concrete definition takes a C name (bug 129).
r129_ll="$TMPDIR/regress_129_user_fn_named_malloc.ll"
if filter_match "$TESTDIR/regress_129_user_fn_named_malloc.con"; then
    if $COMPILER "$TESTDIR/regress_129_user_fn_named_malloc.con" --emit-llvm > "$r129_ll" 2>/dev/null \
       && grep -qE '^define i64 @_C\.main\.malloc\(' "$r129_ll" \
       && grep -qE '^declare ptr @malloc\(' "$r129_ll" \
       && ! grep -qE '^define [^@]*@malloc\(' "$r129_ll"; then
        echo "  ok  regress_129: the user's malloc is _C.main.malloc; C malloc stays a declaration"
        PASS=$((PASS + 1))
    else
        echo "FAIL  regress_129: a Concrete function took the C symbol malloc (bug 129)"
        FAIL=$((FAIL + 1))
    fi
fi
:
}

suite_codegen_2() {
# #[export_name]: a C caller reaches the Concrete function by its exported name (rc 42).
xp_ll="$TMPDIR/ffi_export_name.ll"
xp_bin="$TMPDIR/ffi_export_name"
if filter_match "$TESTDIR/ffi_export_name.con"; then
    xp_rc=fail
    if $COMPILER "$TESTDIR/ffi_export_name.con" --emit-llvm > "$xp_ll" 2>/dev/null \
       && grep -qE '^define i64 @cc_triple\(' "$xp_ll" \
       && clang "$xp_ll" "$TESTDIR/ffi_export_name.c" -o "$xp_bin" -Wno-override-module 2>/dev/null; then
        xp_rc=0; "$xp_bin" >/dev/null 2>&1 || xp_rc=$?
    fi
    if [ "$xp_rc" = "42" ]; then
        echo "  ok  ffi_export_name.con: C calls the export cc_triple (rc 42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  ffi_export_name.con: expected rc 42 through the export cc_triple, got $xp_rc"
        FAIL=$((FAIL + 1))
    fi
fi
:
}
