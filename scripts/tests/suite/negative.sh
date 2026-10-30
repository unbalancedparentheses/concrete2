# negative: the code units of tests/cases/negative.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_negative_1() {
run_err "$TESTDIR/error_postfix_question.con"    'postfix `?` was removed'
:
}

suite_negative_2() {
for r186 in regress_186_coherent_impls regress_186_coherent_impls_reversed regress_186_primitive_impl_spellings regress_186_visible_targets; do
    r186_i=$($COMPILER "$TESTDIR/$r186.con" --interp </dev/null 2>&1 | awk 'END{print}' || true)
    if [ "$r186_i" = "42" ]; then
        echo "  ok  bug 186: $r186 --interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 186: $r186 --interp gave '$r186_i', want 42 (the binary's exit)"
        FAIL=$((FAIL + 1))
    fi
done
# The interpreter refuses each error fixture with the same first code as the native compile.
for r186e in duplicate_impl:E0590 overlap_generic_impl:E0591 orphan_impl:E0592 specialized_impl:E0593 method_clash:E0594 ambiguous_bound_method:E0595; do
    r186e_f="$TESTDIR/error_186_${r186e%%:*}.con"; r186e_c="${r186e#*:}"
    r186e_i=$($COMPILER "$r186e_f" --interp </dev/null 2>&1 | grep -oE '\(E[0-9]{4}\)' | awk 'NR==1' || true)
    if [ "$r186e_i" = "($r186e_c)" ]; then
        echo "  ok  bug 186: error_186_${r186e%%:*} --interp refuses with $r186e_c"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 186: error_186_${r186e%%:*} --interp gave '$r186e_i', want ($r186e_c)"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_3() {
# Round 3 (Codex): an implicit receiver borrow obeys the explicit borrow's rules. `&mut self`
# through a shared reference (the receiver, `self` in a `&self` method, or the binding a
# projection is rooted at) is E0237 — for `x: &T` Elab built a `&mut &T` and the callee wrote
# out of bounds; on an immutable binding E0233; while the binding is borrowed E0232. Every
# legal `&mut self` receiver form still runs (8), and --interp agrees (it failed on `T$bump`
# and on a projection through `&mut W`).
# Bug 052 round 3 (Codex): same-named types in two modules — generic dispatch chose the
# top-level impl for the nested type (101 / 100), then was refused (E0814 / E0815). Bug 096:
# Core spells each type by its defining module, so each dispatch reaches its own impl,
# natively and under --interp.
for r052c in "collision_destroy:2" "collision_trait:1 100"; do
    r052c_f="${r052c%%:*}"; r052c_want="${r052c#*:}"
    r052c_src="tests/regressions/bug052_vec_array_destroy/$r052c_f.con"
    # The whole output and the exit status of both: the binary prints the lines and exits 0;
    # --interp prints the lines, then main's result (0), and exits 0.
    r052c_n="(no binary)"
    if $COMPILER "$r052c_src" -o "$TESTDIR/.r052c_bin" >/dev/null 2>&1; then
        r052c_n=$("$TESTDIR/.r052c_bin" 2>&1; echo "rc=$?")
        r052c_n=$(printf '%s' "$r052c_n" | tr '\n' ' ')
    fi
    rm -f "$TESTDIR/.r052c_bin"
    r052c_i=$($COMPILER "$r052c_src" --interp 2>&1; echo "rc=$?")
    r052c_i=$(printf '%s' "$r052c_i" | tr '\n' ' ')
    if [ "$r052c_n" = "$r052c_want rc=0" ] && [ "$r052c_i" = "$r052c_want 0 rc=0" ]; then
        echo "  ok  bug 052/096: $r052c_f — binary and --interp print $r052c_want"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 052/096: $r052c_f — binary '$r052c_n', --interp '$r052c_i', want '$r052c_want'"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_4() {
r102_z=$($COMPILER "$TESTDIR/regress_102_zero_sized_ptr_eq.con" --interp 2>&1 || true)
if [ "$r102_z" = "1" ]; then
    echo "  ok  regress_102_zero_sized_ptr_eq: --interp == binary (1)"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_102_zero_sized_ptr_eq: --interp gave '$r102_z', binary exits 1"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_5() {
# Bugs 102 and 105: the interpreter agrees with the binary (102 needed pointer equality on
# reference paths in the interpreter; 105's reproducer runs in both).
# Bug 175: a match whose arms all diverge (break/continue/return) left its merge open (E0708
# inside a loop, E0703 under an if); five shapes, binary exit 42.
# Bug 188: legitimate capability polymorphism (positive control), binary exit 42.
for r102 in regress_102_pointer_local_address regress_102_ptr_eq_through_raw_base regress_105_ref_valued_branch_generic regress_175_match_arms_all_diverge regress_183_deref_assign_rhs_first regress_136_137_literal_eval_order regress_190_array_value_copy regress_181_borrowed_binders regress_d2_roots_and_projections regress_d1_mut_ref_reborrow regress_198_read_owned regress_199_cast_to_alias regress_d6_copy_generics regress_188_capvar_polymorphism; do
    r102_src="$TESTDIR/$r102.con"
    r102_i=$($COMPILER "$r102_src" --interp 2>&1 | awk "NR<=1" || true)
    r102_n=""
    if $COMPILER "$r102_src" -o "$TESTDIR/.r102_bin" >/dev/null 2>&1; then
        "$TESTDIR/.r102_bin" >/dev/null 2>&1 && r102_n=0 || r102_n=$?
    fi
    rm -f "$TESTDIR/.r102_bin"
    if [ -n "$r102_n" ] && [ "$r102_i" = "$r102_n" ]; then
        echo "  ok  $r102: --interp == binary ($r102_n)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r102: --interp gave '$r102_i', binary exit '$r102_n'"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_6() {
r179_dir="$TMPDIR/r179"
mkdir -p "$r179_dir"
r179_leg() {  # <label> <rounds> <width> <expected rc> <compile command prefix...>; output path appended
    local label="$1" rounds="$2" width="$3" want="$4"; shift 4
    local bad="" round i rc pids
    for round in $(seq 1 "$rounds"); do
        pids=()
        for i in $(seq 1 "$width"); do
            ( "$@" "$r179_dir/bin_$i" > "$r179_dir/log_$i" 2>&1 ) &
            pids+=("$!")
        done
        for i in $(seq 1 "$width"); do
            if ! wait "${pids[$((i - 1))]}"; then
                bad="$bad round $round compile $i failed: $(awk 'NR<=2' "$r179_dir/log_$i" | tr '\n' ' ');"
                continue
            fi
            rc=0
            "$r179_dir/bin_$i" >/dev/null 2>&1 || rc=$?
            [ "$rc" = "$want" ] || bad="$bad round $round binary $i exited $rc;"
        done
        rm -f "$r179_dir"/bin_* "$r179_dir"/log_*
    done
    if [ -z "$bad" ]; then
        echo "  ok  $label: $((rounds * width)) concurrent compiles ($width x $rounds), every binary exits $want"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $label:$bad"
        FAIL=$((FAIL + 1))
    fi
}
r179_leg regress_179_concurrent_compile 5 8 42 \
    "$ROOT_DIR/$COMPILER" "$ROOT_DIR/$TESTDIR/regress_179_concurrent_compile.con" -o
r179_build() { cd "$ROOT_DIR/$TESTDIR/regress_179_concurrent_build" && "$ROOT_DIR/$COMPILER" build -o "$1"; }
r179_leg regress_179_concurrent_build 3 4 0 r179_build
# Bug 165: println/print/append desugared into helper calls that bound by spelling, so a
# module's own `fn print_int` was called by `println`. The interpreter prints the program's
# stdout then its result; the binary must print the same stdout and exit with that result.
r165_src="$TESTDIR/regress_165_generated_helper_call.con"
r165_i=$($COMPILER "$r165_src" --interp 2>&1 || true)
r165_n=""; r165_o=""
if $COMPILER "$r165_src" -o "$TESTDIR/.r165_bin" >/dev/null 2>&1; then
    r165_o=$("$TESTDIR/.r165_bin" 2>&1) && r165_n=0 || r165_n=$?
fi
rm -f "$TESTDIR/.r165_bin"
if [ "$r165_n" = "42" ] && [ "$r165_i" = "$(printf '%s\n42' "$r165_o")" ]; then
    echo "  ok  regress_165_generated_helper_call: --interp == binary (stdout and 42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_165_generated_helper_call: --interp gave '$r165_i', binary '$r165_o' exit '$r165_n'"
    FAIL=$((FAIL + 1))
fi
# Bug 184 (FIXED): `--interp` read ALL of standard input before `main` ran, so a program that
# never reads stdin, fed by a pipe that stays open, waited for the writer to close it (the binary
# returns at once). Standard input is now pulled when the program reads it. Each run's stdin is a
# fifo whose writer prints the feed and then holds it open for 30 s, under a 10 s bound: a run
# that waits for end of input times out (124) and fails. The writer is killed and reaped after
# every run. regress_184_interp_stdin_unread never reads stdin (21); regress_184_interp_stdin_read
# is the control that does: one read(0, buf, 2) of "AB" returns both bytes at once (131).
r184_run() {  # <feed> <command...>: run the command with stdin held open after <feed>
    local feed="$1" fifo="$TMPDIR/r184_fifo_$$_$RANDOM" w rc=0
    shift
    mkfifo "$fifo"
    { printf '%s' "$feed"; exec sleep 30; } > "$fifo" 2>/dev/null &
    w=$!
    # bounded_run, not GNU `timeout` (absent on macOS runners). The retry budget is pinned to 10 s so
    # first try + retry (20 s) ends before the writer releases the pipe (30 s): a run that waits for
    # end of input still times out (124) instead of being rescued by a longer retry.
    bounded_run -i "$fifo" -r 10 10 -- "$@" || rc=$?
    kill "$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    rm -f "$fifo"
    return "$rc"
}
r184_leg() {  # <fixture> <bytes the open pipe carries first> <expected value>
    local src="$TESTDIR/$1.con" feed="$2" want="$3" bin="$TMPDIR/r184_$1" i_out i_rc n_rc
    i_rc=0
    i_out=$(r184_run "$feed" "$COMPILER" "$src" --interp 2>&1) || i_rc=$?
    n_rc=""
    if "$COMPILER" "$src" -o "$bin" >/dev/null 2>&1; then
        n_rc=0
        r184_run "$feed" "$bin" >/dev/null 2>&1 || n_rc=$?
    fi
    rm -f "$bin"
    if [ "$i_rc" = 0 ] && [ "$i_out" = "$want" ] && [ "$n_rc" = "$want" ]; then
        echo "  ok  bug 184: $1 with stdin held open: --interp == binary ($want), neither waits for end of input"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 184: $1 with stdin held open: --interp rc $i_rc output '$i_out', binary exit '$n_rc' (124 = timed out), want $want"
        FAIL=$((FAIL + 1))
    fi
}
r184_leg regress_184_interp_stdin_unread "" 21
r184_leg regress_184_interp_stdin_read AB 131
# Bug 104 (fixed by the normalized place rule): a reference re-pointed by assignment at
# block-local storage is refused (E0238). Bug 107 (fixed): shadowing a binding a live
# reference borrows is refused (E0238); the binary read the shadowing binding's slot.
# Bugs 119 and 120 (fixed by batch 2's interpreter changes) and 117, 118, 128 and 139 (the
# interpreter-coverage pass, with 144): the interpreter agrees with the binary on each reproducer.
for r119 in bug119_interp_generic_trait_method bug120_interp_field_borrow_through_ref \
            bug117_interp_module_const bug118_interp_nested_module_import \
            bug128_interp_int_to_float_identity bug150_float_self_compare_fold \
            bug152_string_trim_empty; do
    r119_src="tests/regressions/$r119/repro.con"
    r119_i=$($COMPILER "$r119_src" --interp 2>&1 | awk "NR<=1" || true)
    r119_n=""
    if $COMPILER "$r119_src" -o "$TESTDIR/.r119_bin" >/dev/null 2>&1; then
        "$TESTDIR/.r119_bin" >/dev/null 2>&1 && r119_n=0 || r119_n=$?
    fi
    rm -f "$TESTDIR/.r119_bin"
    if [ -n "$r119_n" ] && [ "$r119_i" = "$r119_n" ]; then
        echo "  ok  $r119: --interp == binary ($r119_n)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r119: --interp gave '$r119_i', binary exit '$r119_n'"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_7() {
for r096 in "regress_096_type_identity_same_named:1234567" "regress_096_imported_type_layout:7" \
            "regress_096_local_and_imported_same_name:7" "regress_096_same_named_destroy:102" \
            "regress_096_imported_struct_field_binding:73" "regress_097_param_named_like_colliding_fn:1211099" \
            "regress_097_free_fn_named_like_method:51001" "regress_096_method_value_same_named:1017" \
            "regress_097_let_shadows_colliding_fn:1112" "regress_096_private_method_not_transported:71" \
            "regress_096_sibling_types_unused:1" "regress_096_method_owner_same_module:101007" \
            "regress_096_transitive_signature_binding:93" "regress_096_sibling_injected_binding:7" \
            "regress_096_alias_copy_unused:4" "regress_096_import_closure_copy:4" \
            "regress_096_generic_method_param_named_like_type:3" "regress_096_newtype_field_nominal:7" \
            "regress_096_diverging_initializer:5" \
            "regress_097_098_same_named_private_fns:112124" "regress_096_nested_same_named_methods:751300:native"; do
    r096_f="${r096%%:*}"; r096_rest="${r096#*:}"; r096_want="${r096_rest%%:*}"
    case "$r096_rest" in *:native) continue ;; esac
    # the whole --interp output (the value, then main's result 0) and its exit status
    r096_got=$($COMPILER "$TESTDIR/$r096_f.con" --interp 2>&1; echo "rc=$?")
    r096_got=$(printf '%s' "$r096_got" | tr '\n' ' ')
    if [ "$r096_got" = "$r096_want 0 rc=0" ]; then
        echo "  ok  $r096_f: --interp prints $r096_want"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r096_f: --interp gave '$r096_got', want $r096_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_8() {
# Bug 127: struct-literal initializers run in source order and land at their declared offsets,
# natively and under --interp (the binary used to run them in declaration order). One synchronous
# loop compiles each source once (a parallel run_ok on the same file would race on its .ll), and
# both consumers must give the expected value, not merely agree.
for r127_case in "$TESTDIR/regress_127_struct_literal_source_order.con:42" \
                 "tests/regressions/bug127_struct_literal_field_order/repro.con:56"; do
    r127_src="${r127_case%:*}"; r127_want="${r127_case##*:}"
    if ! filter_match "$r127_src"; then SKIP=$((SKIP + 1)); continue; fi
    r127_i=$($COMPILER "$r127_src" --interp 2>&1 | awk "NR<=1" || true)
    r127_n=""
    if $COMPILER "$r127_src" -o "$TESTDIR/.r127_bin" >/dev/null 2>&1; then
        "$TESTDIR/.r127_bin" >/dev/null 2>&1 && r127_n=0 || r127_n=$?
    fi
    rm -f "$TESTDIR/.r127_bin"
    if [ "$r127_n" = "$r127_want" ] && [ "$r127_i" = "$r127_want" ]; then
        echo "  ok  bug127 $r127_src: --interp and binary both give $r127_want"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug127 $r127_src: expected $r127_want; --interp gave '$r127_i', binary exit '$r127_n'"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_9() {
r146_ssa=$($COMPILER tests/regressions/bug146_heap_deref_does_not_free/repro.con --emit-ssa 2>&1 || true)
if [[ "$r146_ssa" == *"call void @free("* ]]; then
    echo "  ok  bug146 repro: *h emits the free of the cell"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug146 repro: *h emits no free (the cell leaks)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_10() {
r142_i=$($COMPILER "$TESTDIR/regress_142_exits_allowed.con" --interp 2>&1 | awk "NR<=1" || true)
if [ "$r142_i" = "1 4 5 2 00" ]; then
    echo "  ok  regress_142_exits_allowed.con: --interp prints what the binary prints"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_142_exits_allowed.con: --interp printed '$r142_i'"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_11() {
r143s_i=$($COMPILER "$TESTDIR/regress_143_defer_sibling_scopes.con" --interp 2>&1 | awk "NR<=1" || true)
if [ "$r143s_i" = "1 7 70 0" ]; then
    echo "  ok  regress_143_defer_sibling_scopes.con: --interp prints what the binary prints"; PASS=$((PASS+1))
else
    echo "FAIL  regress_143_defer_sibling_scopes.con: --interp printed '$r143s_i'"; FAIL=$((FAIL+1))
fi
r143_i=$($COMPILER "$TESTDIR/regress_143_defer_reserve_by_place.con" --interp 2>&1 | awk "NR<=1" || true)
if [ "$r143_i" = "7 1 4 2 2 5 5 5 0" ]; then
    echo "  ok  regress_143_defer_reserve_by_place.con: --interp prints what the binary prints"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_143_defer_reserve_by_place.con: --interp printed '$r143_i'"
    FAIL=$((FAIL + 1))
fi
for r143 in tests/regressions/bug143_defer_borrow_unpinned/repro.con tests/regressions/bug143_defer_borrow_unpinned/repro_order.con; do
    r143_i=$($COMPILER "$r143" --interp 2>&1 || true)
    r143_n=$($COMPILER "$r143" -o "$TESTDIR/.r143_bin" 2>&1 || true)
    if [[ "$r143_i" == *"(E0206)"* && "$r143_n" == *"(E0206)"* ]]; then
        echo "  ok  $r143: refused with E0206 natively and under --interp"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r143: not refused with E0206 by both engines"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TESTDIR/.r143_bin"
done
:
}

suite_negative_12() {
r149_ssa=$($COMPILER "$TESTDIR/regress_149_break_value_statement_loop.con" --emit-ssa 2>&1 || true)
if [[ "$r149_ssa" == *"call void @free("* ]]; then
    echo "  ok  regress_149_break_value_statement_loop.con: the break operand runs (emits @free)"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_149_break_value_statement_loop.con: the break operand was not lowered"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_13() {
for r144 in tests/regressions/bug144_heap_interior_untracked/repro.con tests/regressions/bug144_heap_interior_untracked/repro_free.con; do
    r144_i=$($COMPILER "$r144" --interp 2>&1 || true)
    r144_n=$($COMPILER "$r144" -o "$TESTDIR/.r144_bin" 2>&1 || true)
    if [[ "$r144_i" == *"error[check]"* && "$r144_n" == *"error[check]"* && ( "$r144_n" == *"(E0290)"* || "$r144_n" == *"(E0287)"* ) ]]; then
        echo "  ok  $r144: refused at the checker natively and under --interp"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r144: not refused at the checker by both engines"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TESTDIR/.r144_bin"
done
for r142 in tests/regressions/bug142_exit_in_operand/repro.con tests/regressions/bug142_exit_in_operand/repro_arg.con; do
    r142_i=$($COMPILER "$r142" --interp 2>&1 || true)
    r142_n=$($COMPILER "$r142" -o "$TESTDIR/.r142_bin" 2>&1 || true)
    if [[ "$r142_i" == *"(E0278)"* && "$r142_n" == *"(E0278)"* ]]; then
        echo "  ok  $r142: refused with E0278 natively and under --interp"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r142: not refused with E0278 by both engines"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TESTDIR/.r142_bin"
done
# Both engines refuse the bug 140 reproducers at the checker (the interpreter used to fail at
# run time on references, and the binary compared addresses).
for r140 in tests/regressions/bug140_comparison_consumes_linear/repro.con tests/regressions/bug140_comparison_consumes_linear/repro_ref.con; do
    r140_i=$($COMPILER "$r140" --interp 2>&1 || true)
    r140_n=$($COMPILER "$r140" -o "$TESTDIR/.r140_bin" 2>&1 || true)
    if [[ "$r140_i" == *"(E0229)"* && "$r140_n" == *"(E0229)"* ]]; then
        echo "  ok  $r140: refused with E0229 natively and under --interp"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r140: not refused with E0229 by both engines"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TESTDIR/.r140_bin"
done
:
}

suite_negative_14() {
r091_table="
error_091_destroy_through_ref:E0290
error_091_destroy_concrete_through_ref:E0290
error_091_destroy_method_then_destroy:E0205
error_091_destroy_paren_then_destroy:E0205
error_091_destroy_static_borrowed:E0290
error_091_destroy_deref_ref:E0290
error_091_destroy_defname_borrowed:E0290
error_091_destroy_deref_if_ref:E0238
error_091_destroy_newtype_through_ref:E0290
error_091_destroy_defname_deref_arg:E0290
error_091_destroy_defname_paren_arg:E0205
error_091_destroy_deref_borrow_mut:E0290
error_091_receiver_deref_moved:E0290
error_091_receiver_deref_borrow_moved:E0290
error_091_mut_receiver_through_ref:E0237
error_091_mut_receiver_through_ref_concrete:E0237
error_091_mut_receiver_through_ref_projection:E0237
error_091_mut_receiver_in_ref_self:E0237
error_091_mut_receiver_immutable:E0233
error_091_mut_receiver_immutable_concrete:E0233
error_091_mut_receiver_borrowed:E0302
error_091_mut_receiver_paren_deref:E0237
error_091_mut_receiver_deref_borrow:E0237
error_091_mut_receiver_deref_if_ref:E0238
error_091_mut_receiver_reborrow_shared:E0237
error_091_mut_receiver_paren_borrow_live:E0302
error_091_mut_borrow_explicit_through_ref:E0237
error_091_mut_borrow_explicit_paren_immutable:E0233
error_091_mut_borrow_explicit_projection_through_ref:E0237
error_091_mut_receiver_paren_borrow_outer:E0302
error_091_mut_receiver_projection_borrow_live:E0302
error_091_deref_ref_by_value:E0290
error_091_paren_call_arg_not_consumed:E0205
error_091_match_deref_ref_payload:E0290
error_091_mut_receiver_deref_borrow_provenance:E0302
error_091_borrow_provenance_unknown:E0302
error_091_mut_receiver_ref_to_mut_ref:E0302
error_091_mut_receiver_reborrowed_mut_ref:E0302
error_091_mut_receiver_reassigned_ref:E0302
error_091_ref_repointed_in_branch:E0302
error_091_mut_receiver_paren_borrow_arg:E0293
error_091_mut_receiver_deref_reborrow_arg:E0293
error_091_newtype_payload_through_ref:E0290
error_091_mut_receiver_deref_field_arg:E0293
error_091_mut_receiver_nested_reborrow_arg:E0293
error_091_mut_receiver_if_reborrow_arg:E0238
error_091_heap_field_through_ref:E0290
error_091_mut_receiver_if_local_reborrow_arg:E0302
error_091_ref_receiver_under_mut_reborrow:E0302
error_091_norm_heap_deref_payload:E0290
error_091_norm_conditional_receiver:E0238
error_091_norm_deref_read_under_reborrow:E0302
error_091_norm_temporaries:E0238
error_091_norm_if_projection:E0238
error_091_norm_if_local_binding:E0238
error_091_norm_if_local_chain:E0238
error_091_norm_match_owned_binder:E0238
error_091_norm_cast_arg_overlap:E0293
error_091_norm_parent_arg_under_reborrow:E0302
error_091_norm_copied_mut_ref:E0302
error_091_norm_double_deref_heap:E0302
error_091_norm_field_write_under_reborrow:E0302
error_091_norm_borrow_block_under_live_ref:E0302
error_091_norm_paren_heap_load:E0290
error_091_norm_assign_under_shared_ref:E0302
error_091_norm_heap_field_load:E0290
error_091_norm_paren_array_write:E0217
error_091_norm_double_deref_read:E0238
error_091_norm_intrinsic_arg_under_reborrow:E0302
error_091_norm_ref_array_overwrite:E0291
error_091_norm_generic_ref_array_overwrite:E0291
error_091_norm_catchall_binder_through_ref:E0302
error_091_norm_enum_payload_ref:E0239
error_091_norm_generic_field_ref_write:E0239
error_091_norm_heap_ref_field_write:E0239
error_091_norm_match_untraced_ref:E0239
error_091_norm_alias_ref_field:E0239
error_091_norm_nested_ref_binder:E0238
error_091_norm_alias_cast_overlap:E0293
error_091_norm_alias_cast_let:E0239
error_091_norm_intrinsic_ref_result:E0239
error_091_norm_temp_projection_ref:E0239
error_091_norm_generic_nested_ref:E0239
error_091_norm_generic_nested_alias_ref:E0239
error_091_norm_ref_write_through_ref:E0238
error_091_norm_generic_fn_mut_param:E0238
error_091_norm_generic_transitive_ref:E0238
error_091_norm_free_under_projected_borrow:E0302
error_091_norm_field_write_under_projected_borrow:E0302
trait_generic_fn_value_param:ok
trait_destroy_owned_receiver:ok
trait_mut_receiver_forms:ok
trait_generic_receiver_forms:ok
trait_mut_receiver_nested_reborrow:ok
trait_destroy_newtype_payload:ok
trait_destroy_newtype_payload_paren:ok
"
r091_bad=""
for row in $r091_table; do
    f="${row%%:*}"; want="${row#*:}"
    out=$($COMPILER "$TESTDIR/$f.con" -o "$TMPDIR/r091_table_bin" 2>&1) && rc=0 || rc=$?
    if [ "$want" = "ok" ]; then
        [ "$rc" -eq 0 ] || r091_bad="$r091_bad $f(want ok)"
    else
        grep -qF "($want)" <<<"$out" || r091_bad="$r091_bad $f(want $want)"
    fi
done
rm -f "$TMPDIR/r091_table_bin"
if [ -z "$r091_bad" ]; then
    echo "  ok  bug 091: normalized-place table — every recorded spelling behaves as recorded"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 091: normalized-place table rows changed:$r091_bad"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_15() {
for r091m in "trait_mut_receiver_forms:8" "trait_generic_receiver_forms:4030412"; do
    r091m_f="${r091m%%:*}"; r091m_want="${r091m#*:}"
    r091m_got=$($COMPILER "$TESTDIR/$r091m_f.con" --interp 2>&1 | awk "NR<=1" || true)
    if [ "$r091m_got" = "$r091m_want" ]; then
        echo "  ok  bug 091: $r091m_f — interp == binary ($r091m_want)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 091: $r091m_f — interp gave '$r091m_got', want $r091m_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_16() {
r091d_interp=$($COMPILER "$TESTDIR/trait_destroy_owned_receiver.con" --interp 2>&1 | awk "NR<=1" || true)
if [ "$r091d_interp" = "11111" ]; then
    echo "  ok  bug 091: Destroy consumes its receiver — interp == binary (11111)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 091: Destroy consumes its receiver — interp gave '$r091d_interp', want 11111"
    FAIL=$((FAIL + 1))
fi
:
}

suite_negative_17() {
for r099 in "regress_099_generic_infer_field_index:43043" "regress_099_generic_infer_call_results:4" \
            "regress_100_generic_ref_destroy:2" "regress_099_generic_infer_cap_method:14"; do
    r099_f="${r099%%:*}"; r099_want="${r099#*:}"
    # the whole --interp output (the value, then main's result 0) and its exit status
    r099_got=$($COMPILER "$TESTDIR/$r099_f.con" --interp 2>&1; echo "rc=$?")
    r099_got=$(printf '%s' "$r099_got" | tr '\n' ' ')
    if [ "$r099_got" = "$r099_want 0 rc=0" ]; then
        echo "  ok  $r099_f: --interp prints $r099_want"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $r099_f: --interp gave '$r099_got', want $r099_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_negative_18() {
run_err "$TESTDIR/error_arrow_not_heap.con" "postfix \`->\` was removed"
:
}
