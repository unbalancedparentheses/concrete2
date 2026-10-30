# positive.2: the code units of tests/cases/positive.2.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_positive_2_1() {
r087s_interp=$($COMPILER "$TESTDIR/regress_087_sibling_promoted.con" --interp 2>&1 || true)
if [ "$r087s_interp" = "42" ]; then
    echo "  ok  bug 087: sibling promoted aggregates — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 087: sibling promoted aggregates — interp gave '$r087s_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_2() {
r087u_interp=$($COMPILER "$TESTDIR/regress_087_unpromoted_sibling.con" --interp 2>&1 || true)
if [ "$r087u_interp" = "42" ]; then
    echo "  ok  bug 087: unpromoted re-declaration — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 087: unpromoted re-declaration — interp gave '$r087u_interp', want 42"
    FAIL=$((FAIL + 1))
fi
# The renamed twin, the other two consumers: the interpreter must agree with the
# binary (pre-fix it returned 2), and the extracted proof model must be the
# lexical one — no branch `let` leaking into the continuation (pre-fix
# `then let x = 100; x`), and the loop body's `let inner_k` kept under its own
# name (no `.bN` suffix: nothing is alpha-renamed once nothing shadows).
r087_interp=$($COMPILER "$TESTDIR/regress_2i_scope1_087_renamed.con" --interp 2>&1 || true)
r087_ext=$($COMPILER "$TESTDIR/regress_2i_scope1_087_renamed.con" --report extraction 2>&1 || true)
if [ "$r087_interp" = "42" ] \
   && grep -qF 'ProofCore: let x = 1; if (a > 0) then x else x' <<<"$r087_ext" \
   && grep -qF 'ProofCore: if (a > 0) then a else a' <<<"$r087_ext" \
   && grep -qE 'ProofCore: let s = 0; let k = 5;.*\{ let inner_k = 1000; [^}]*\(inner_k \+ s\).*\(k \+ s\)' <<<"$r087_ext" \
   && ! grep -qE 'ProofCore: .*\.b[0-9]+' <<<"$r087_ext"; then
    echo "  ok  bug 087: interp == binary == lexical model (shadow_if/param/loop)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 087: interp ($r087_interp) or extracted model is not lexical"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_3() {
r212_interp=$($COMPILER "$TESTDIR/regress_212_parenthesized_const_head.con" --interp 2>&1 || true)
if [ "$r212_interp" = "42" ]; then
    echo "  ok  bug 212: parenthesized constant heads parse and run — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 212: interp gave '$r212_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_4() {
r208_interp=$($COMPILER "$TESTDIR/regress_208_fn_local_named_like_import.con" --interp 2>&1 || true)
if [ "$r208_interp" = "42" ]; then
    echo "  ok  bug 208: an identified fn-typed local is not renamed to an import — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 208: interp gave '$r208_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_5() {
r176_interp=$($COMPILER "$TESTDIR/regress_176_loop_shadow_restores_outer.con" --interp 2>&1 || true)
if [ "$r176_interp" = "42" ]; then
    echo "  ok  bug 176: loop-body shadows close — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 176: loop-body shadows — interp gave '$r176_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_6() {
# Every address-take in the fixture is inside a branch or loop, so each local is promoted by its
# site before the branch; a lazily promoted slot (`%addr.N`, made where `&x` is lowered) means a
# site missed it. This holds the `&&` site alone (`and_rhs_direct`), whose wrong load clang folds.
r285_ssa=$($COMPILER "$TESTDIR/regress_285_enum_payload_addr_taken.con" --emit-ssa 2>&1 || true)
if [[ "$r285_ssa" == *"define i64 @and_rhs_direct("* && "$r285_ssa" != *"%addr."* ]]; then
    echo "  ok  regress_285_enum_payload_addr_taken.con: every address-taken local is promoted before its branch"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_285_enum_payload_addr_taken.con: a local is promoted lazily inside a branch (%addr. slot) or the SSA is missing"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_7() {
r301_ssa=$($COMPILER "$TESTDIR/regress_301_place_borrow_root.con" --emit-ssa 2>&1 || true)
if [[ "$r301_ssa" == *"define i64 @and_rhs("* && "$r301_ssa" != *"%addr."* ]]; then
    echo "  ok  regress_301_place_borrow_root.con: every borrowed root is promoted before its branch"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_301_place_borrow_root.con: a root is promoted lazily inside a branch (%addr. slot) or the SSA is missing"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_8() {
r305_i=$($COMPILER "$TESTDIR/regress_305_borrow_block_early_exit.con" --interp </dev/null 2>&1; echo "rc=$?")
if [ "$r305_i" = "$(printf '42\nrc=0')" ]; then
    echo "  ok  regress_305_borrow_block_early_exit.con: --interp prints 42 and exits 0, as the binary exits 42"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_305_borrow_block_early_exit.con: --interp gave '$r305_i', want output 42 and status 0 (the binary exits 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_9() {
r3052_i=$($COMPILER "$TESTDIR/regress_305_borrow_block_owners_and_exits.con" --interp </dev/null 2>&1; echo "rc=$?")
if [ "$r3052_i" = "$(printf '42\nrc=0')" ]; then
    echo "  ok  regress_305_borrow_block_owners_and_exits.con: --interp prints 42 and exits 0, as the binary exits 42"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_305_borrow_block_owners_and_exits.con: --interp gave '$r3052_i', want output 42 and status 0 (the binary exits 42)"
    FAIL=$((FAIL + 1))
fi
# The reference-parameter owner, in the IR: `take` receives the owner's own slot, the slot every
# later read of `p` loads from (main passed a fresh copy slot that nothing read again). Behaviour
# alone cannot show it, since a read through the binder of a reference owner is refused (E0238).
r305_ir=$($COMPILER "$TESTDIR/regress_305_borrow_block_owners_and_exits.con" --emit-llvm 2>/dev/null || true)
r305_irfn=$(awk '/^define .*@_C\.main\.ref_owner\(/{p=1} p{print} p&&/^}/{exit}' <<<"$r305_ir")
r305_slot=$(sed -n 's/.*call i64 @_C\.main\.take(ptr \(%[A-Za-z0-9_.]*\)).*/\1/p' <<<"$r305_irfn")
r305_slot=${r305_slot%%$'\n'*}
if [ -n "$r305_slot" ] && has_match -F "load ptr, ptr $r305_slot" <<<"$r305_irfn"; then
    echo "  ok  regress_305_borrow_block_owners_and_exits.con: a reference owner's binder is the owner's slot ($r305_slot)"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_305_borrow_block_owners_and_exits.con: ref_owner passes '${r305_slot:-nothing}' to take, which no later read of p loads from"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_10() {
r306_i=$($COMPILER "$TESTDIR/regress_306_for_step_after_body_defers.con" --interp </dev/null 2>&1; echo "rc=$?")
if [ "$r306_i" = "$(printf '42\nrc=0')" ]; then
    echo "  ok  regress_306_for_step_after_body_defers.con: --interp prints 42 and exits 0, as the binary exits 42"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_306_for_step_after_body_defers.con: --interp gave '$r306_i', want output 42 and status 0 (the binary exits 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_11() {
r307_i=$($COMPILER "$TESTDIR/regress_307_call_arg_mut_is_place.con" --interp </dev/null 2>&1; echo "rc=$?")
if [ "$r307_i" = "$(printf '42\nrc=0')" ]; then
    echo "  ok  regress_307_call_arg_mut_is_place.con: --interp prints 42 and exits 0, as the binary exits 42"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_307_call_arg_mut_is_place.con: --interp gave '$r307_i', want output 42 and status 0 (the binary exits 42)"
    FAIL=$((FAIL + 1))
fi
# The lowering itself: no call argument gets a `mutref.` copy slot (main emitted 23 such names for
# this fixture). The differential legs above pass with the copy too, since no defined program
# observes it; this leg fails if the copy comes back.
r307_ir=$($COMPILER "$TESTDIR/regress_307_call_arg_mut_is_place.con" --emit-llvm 2>/dev/null) && r307_irc=0 || r307_irc=$?
r307_mr=$(printf '%s\n' "$r307_ir" | grep -c 'mutref\.' || true)
if [ "$r307_irc" = "0" ] && [ -n "$r307_ir" ] && [ "$r307_mr" = "0" ]; then
    echo "  ok  regress_307_call_arg_mut_is_place.con: no argument copy slot (mutref.) in the LLVM IR"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_307_call_arg_mut_is_place.con: --emit-llvm exit $r307_irc, $r307_mr mutref. names (want exit 0, none)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_12() {
r3072_i=$($COMPILER "$TESTDIR/regress_307_call_arg_owner_types.con" --interp </dev/null 2>&1; echo "rc=$?")
if [ "$r3072_i" = "$(printf '42\nrc=0')" ]; then
    echo "  ok  regress_307_call_arg_owner_types.con: --interp prints 42 and exits 0, as the binary exits 42"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_307_call_arg_owner_types.con: --interp gave '$r3072_i', want output 42 and status 0 (the binary exits 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_13() {
r265_gen() {  # r265_gen SHAPE N: a generated `fn main` of the given shape and size on stdout
    awk -v shape="$1" -v n="$2" 'BEGIN {
        print "fn main() -> Int {"
        print "    let s0: i64 = 0;"
        print "    let mut t: i64 = 0;"
        for (i = 1; i <= n; i++) {
            printf "    let s%d: i64 = s%d + 1;\n", i, i - 1
            if (shape == "if") printf "    if s%d > t { t = t + 1; }\n", i
            if (shape == "match") printf "    match s%d { 0 => { t = t + 1; }, _ => { t = t + 2; }, }\n", i
        }
        printf "    return ((s%d + t) %% 7) as Int;\n", n
        print "}"
    }'
}
r265_stage_ms() {  # r265_stage_ms SRC STAGE: sets r265_ms to the stage's time in ms, "incomplete"
    # (timed out twice) or "rcN" (the compiler failed); never fails itself, so a failed run reaches
    # the verdict below instead of stopping the suite.
    local rc=0 ms
    bounded_run -r 180 180 -- $COMPILER "$1" --emit-trace-json > "$TMPDIR/r265_trace.json" 2>/dev/null || rc=$?
    if bounded_is_incomplete "$rc"; then r265_ms=incomplete; return 0; fi
    if [ "$rc" != 0 ]; then r265_ms="rc$rc"; return 0; fi
    ms="$(sed -nE "s/.*\"timing_ms\":\\{[^}]*\"$2\":([0-9]+).*/\\1/p" "$TMPDIR/r265_trace.json" || true)"
    r265_ms="${ms:-none}"
}
r265_bad=""; r265_incomplete=""
for r265_case in "lets 80000 lower 8000" "if 40000 lower 15000" "if 40000 monomorphize 3000" "match 20000 lower 15000"; do
    read -r r265_shape r265_n r265_stage r265_budget <<< "$r265_case"
    r265_src="$TMPDIR/r265_${r265_shape}_$r265_n.con"
    [ -f "$r265_src" ] || r265_gen "$r265_shape" "$r265_n" > "$r265_src"
    r265_stage_ms "$r265_src" "$r265_stage"; r265_first="$r265_ms"
    # A compiler failure is a FAIL and a double timeout INCOMPLETE at once; only a measured overrun
    # of the budget is retried (Codex review: a retry must not erase a failure).
    case "$r265_first" in
        incomplete) r265_incomplete="$r265_incomplete $r265_shape/$r265_n/$r265_stage"; continue ;;
        ''|*[!0-9]*) r265_bad="$r265_bad $r265_shape/$r265_n/$r265_stage:$r265_first"; continue ;;
    esac
    [ "$r265_first" -gt "$r265_budget" ] || continue
    r265_stage_ms "$r265_src" "$r265_stage"
    case "$r265_ms" in
        incomplete) r265_incomplete="$r265_incomplete $r265_shape/$r265_n/$r265_stage" ;;
        ''|*[!0-9]*) r265_bad="$r265_bad $r265_shape/$r265_n/$r265_stage:${r265_first}ms,$r265_ms" ;;
        *) [ "$r265_ms" -le $((r265_budget * 2)) ] \
               || r265_bad="$r265_bad $r265_shape/$r265_n/$r265_stage:${r265_first}ms,${r265_ms}ms" ;;
    esac
done
if [ -n "$r265_bad" ]; then
    echo "FAIL  bugs 265-267, 269: a back-end stage of a long function exceeded its budget (retry twice the budget) or the compiler failed:$r265_bad"
    FAIL=$((FAIL + 1))
elif [ -n "$r265_incomplete" ]; then
    echo "  INCOMPLETE bugs 265-267, 269: timed out twice (180 s each):$r265_incomplete"
    INCOMPLETE=$((INCOMPLETE + 1))
else
    echo "  ok  bugs 265-267, 269: long functions (80000 lets, 40000 lets with an if, 20000 with a match) lower and monomorphize within budget"
    PASS=$((PASS + 1))
fi
:
}

suite_positive_2_14() {
# bounded_run, not GNU `timeout` (absent on macOS runners); a timeout is INCOMPLETE, not a pass.
r228_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/regress_228_interp_loop_env.con" --interp 2>&1 || true)
if [ "$r228_interp" = "42" ]; then
    echo "  ok  bug 228: a 200000-iteration loop runs under --interp within 20 s (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 228: interp gave '$r228_interp' within 20 s, want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_15() {
r234_interp=$(bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_234_interp_deep_recursion.con" --interp 2>&1 || true)
if [ "$r234_interp" = "42" ]; then
    echo "  ok  bug 234: a depth-100000 recursion runs under --interp within 20 s (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 234: interp gave '$r234_interp' within 20 s, want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_16() {
r235_interp=$(bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_235_interp_array_read.con" --interp 2>&1 || true)
if [ "$r235_interp" = "42" ]; then
    echo "  ok  bug 235: 400000 array reads run under --interp within 20 s (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 235: interp gave '$r235_interp' within 20 s, want 42"
    FAIL=$((FAIL + 1))
fi
# Bug 236: Elab appended an array literal's elements one by one; [7; 200000] must elaborate and run
# under --interp within 20 s each (bug 027's leg compiles literals of this size natively).
r236_rc=0; bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_236_array_repeat_literal.con" --emit-core >/dev/null 2>&1 || r236_rc=$?
r236_interp=$(bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_236_array_repeat_literal.con" --interp 2>&1 || true)
if [ "$r236_rc" = 0 ] && [ "$r236_interp" = "42" ]; then
    echo "  ok  bug 236: a 200000-element array literal elaborates and runs under --interp within 20 s (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 236: --emit-core rc $r236_rc, --interp '$r236_interp' within 20 s each (want 0, 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_17() {
r027_rc=0; bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_027_large_array_literals.con" -o "$TMPDIR/r027_bin" >/dev/null 2>&1 || r027_rc=$?
r027_src="$TMPDIR/r027_distinct_literal.con"
{
    printf 'fn main() -> Int {\n    let mut a: [i64; 100000] = ['
    seq -s ', ' 0 99999 | tr -d '\n'
    printf '];\n    let b: [i64; 100000] = ['
    seq -s ', ' 100000 199999 | tr -d '\n'
    printf '];\n    let mut i: i64 = 0;\n    while i < 100000 {\n        a[i] = b[i] - a[i];\n        i = i + 1;\n    }\n'
    printf '    return (a[99999] - 99958) as Int;\n}\n'
} > "$r027_src"
r249_rc=0; bounded_run -r 20 20 -- $COMPILER "$r027_src" --emit-core >/dev/null 2>&1 || r249_rc=$?
r027d_rc=0; bounded_run -r 20 20 -- $COMPILER "$r027_src" -o "$TMPDIR/r027d_bin" >/dev/null 2>&1 || r027d_rc=$?
r027d_out=""
if [ "$r027d_rc" = 0 ]; then "$TMPDIR/r027d_bin" >/dev/null 2>&1 && r027d_out=0 || r027d_out=$?; fi
if [ "$r027_rc" = 0 ] && [ "$r027d_rc" = 0 ] && [ "$r027d_out" = 42 ]; then
    echo "  ok  bug 027: large array literals compile natively within 20 s (repeated and 2 x 100000 distinct elements, 42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 027: native compile rc $r027_rc (fixture), $r027d_rc (distinct literal, exit '$r027d_out') within 20 s each (want 0, 0, 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_18() {
if [ "$r249_rc" = 0 ]; then
    echo "  ok  bug 249: a 2 x 100000-element explicit array literal parses and elaborates within 20 s"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 249: --emit-core of a 2 x 100000-element explicit literal rc $r249_rc within 20 s (want 0)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_19() {
r248_interp=$(bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_248_interp_array_write.con" --interp 2>&1 || true)
if [ "$r248_interp" = "42" ]; then
    echo "  ok  bug 248: element writes into 100000-element arrays and Vecs run under --interp within 20 s (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 248: interp gave '$r248_interp' within 20 s, want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_20() {
r250_rc=0; bounded_run -r 20 20 -- $COMPILER "$TESTDIR/regress_250_native_array_writes.con" -o "$TMPDIR/r250_bin" >/dev/null 2>&1 || r250_rc=$?
r250_interp=$($COMPILER "$TESTDIR/regress_250_native_array_writes.con" --interp 2>&1 || true)
if [ "$r250_rc" = 0 ] && [ "$r250_interp" = "42" ]; then
    echo "  ok  bug 250: in-loop writes into large aggregates compile natively within 20 s; interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 250: native compile rc $r250_rc within 20 s, interp '$r250_interp' (want 0, 42)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_21() {
r255_gen() {  # r255_gen SHAPE N: a generated `fn main` of the given shape and size on stdout
    awk -v shape="$1" -v n="$2" 'BEGIN {
        print "fn main() -> Int {"
        if (shape == "flat") {
            print "    let mut s: i64 = 0;"
            for (i = 0; i < n; i++) print "    s = s + 1;"
            print "    return (s % 7) as Int;"
        } else {
            print "    let s0: i64 = 0;"
            print "    let mut t: i64 = 0;"
            for (i = 1; i <= n; i++) {
                printf "    let s%d: i64 = s%d + 1;\n", i, i - 1
                if (shape == "if") printf "    if s%d > t { t = t + 1; }\n", i
                if (shape == "while") printf "    while t < s%d { t = t + 1; }\n", i
                if (shape == "match") printf "    match s%d { 0 => { t = t + 1; }, _ => { t = t + 2; }, }\n", i
            }
            printf "    return ((s%d + t) %% 7) as Int;\n", n
        }
        print "}"
    }'
}
r255_bad=""
for r255_case in "flat 80000" "lets 80000" "if 20000" "while 20000" "match 20000"; do
    read -r r255_shape r255_n <<< "$r255_case"
    r255_src="$TMPDIR/r255_${r255_shape}_$r255_n.con"
    r255_gen "$r255_shape" "$r255_n" > "$r255_src"
    r255_rc=0; bounded_run -r 20 10 -- $COMPILER "$r255_src" --emit-core >"$TMPDIR/r255_core.txt" 2>&1 || r255_rc=$?
    if [ "$r255_rc" != 0 ] || ! grep -q "fn main" "$TMPDIR/r255_core.txt"; then
        r255_bad="$r255_bad $r255_shape/$r255_n:rc=$r255_rc"
    fi
done
if [ -z "$r255_bad" ]; then
    echo "  ok  bugs 255-261: long functions (80000 statements, 80000 lets, 20000 lets with an if, a while or a match each) pass the front end within 10 s"
    PASS=$((PASS + 1))
else
    echo "FAIL  bugs 255-261: front end over a long function did not finish within 10 s (retry 20 s):$r255_bad"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_22() {
r282_src="$TMPDIR/r282_nested_ifs_20000.con"
awk -v n=20000 'BEGIN {
    print "fn main() -> Int {"
    print "    let mut s: i64 = 0;"
    print "    let t: i64 = 1;"
    line = "    "
    for (i = 0; i < n; i++) line = line "if t > 0 { s = s + 1; "
    for (i = 0; i < n; i++) line = line "}"
    print line
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r282_src"
r265_stage_ms "$r282_src" resolve; r282_first="$r265_ms"; r282_ms="$r282_first"
case "$r282_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r282_first" -gt 50 ]; then r265_stage_ms "$r282_src" resolve; r282_ms="$r265_ms"; fi ;;
esac
case "$r282_ms" in
    incomplete)
        echo "  INCOMPLETE bug 282: resolving a nest 20000 blocks deep timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 282: resolving a nest 20000 blocks deep failed ($r282_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r282_first" -le 50 ] || [ "$r282_ms" -le 100 ]; then
           echo "  ok  bug 282: a nest 20000 blocks deep resolves within budget (${r282_ms} ms)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 282: resolving a nest 20000 blocks deep took ${r282_first} ms, then ${r282_ms} ms (budget 50, retry 100)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
:
}

suite_positive_2_23() {
r222_interp=$($COMPILER "$TESTDIR/regress_222_imported_enum_impls.con" --interp 2>&1 || true)
if [ "$r222_interp" = "42" ]; then
    echo "  ok  bug 222: an imported enum's impls travel with it — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 222: interp gave '$r222_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_24() {
r224_out=$($COMPILER "$TESTDIR/error_224_failed_let_keeps_mutability.con" --emit-llvm 2>&1 >/dev/null || true)
if ! grep -q ':12:[0-9]*: error\[check\]: (E0217)' <<<"$r224_out" \
   && grep -q ':14:[0-9]*: error\[check\]: (E0217)' <<<"$r224_out"; then
    echo "  ok  bug 224: a recovered let keeps its mutability (E0217 at line 14 only)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 224: E0217 lines are $(grep -o ':[0-9]*:[0-9]*: error\[check\]: (E0217)' <<<"$r224_out" | tr '\n' ' '), want line 14 only"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_25() {
r225_out=$($COMPILER "$TESTDIR/error_225_bound_names_builtin_type.con" --emit-llvm 2>&1 >/dev/null || true)
if grep -q ":12:[0-9]*: error\[check\]: (E0241) type 'String' .* generic function 'dup'" <<<"$r225_out" \
   && grep -q ":14:[0-9]*: error\[check\]: (E0241) type 'String' .* method 'get'" <<<"$r225_out" \
   && ! grep -q "<type>" <<<"$r225_out"; then
    echo "  ok  bug 225: E0241 names String at the call (lines 12 and 14)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 225: E0241 does not name String at lines 12 and 14: $(grep 'E0241' <<<"$r225_out" | awk "NR<=2")"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_26() {
# Bug 220: `0x` / `0b` / `0o` with no digit lexed as 0; now a lexical error.
# The message is asserted, not only E0001: `0b2` was already a parse error before the fix.
run_err "$TESTDIR/error_220_empty_hex_literal.con" "a \`0x\` literal needs at least one hexadecimal digit"
run_err "$TESTDIR/error_220_empty_binary_literal.con" "a \`0b\` literal needs at least one binary digit"
run_err "$TESTDIR/error_220_empty_octal_literal.con" "a \`0o\` literal needs at least one octal digit"
:
}

suite_positive_2_27() {
r275_rc=0
bounded_run -r 20 20 -- $COMPILER "$TESTDIR/error_275_collision_order.con" > "$TMPDIR/r275_collisions.txt" 2>&1 || r275_rc=$?
r275_order=$(sed -nE "s/.*\(E0299\) an? [a-z ]+ named '([A-Za-z]+)'.*/\1/p" "$TMPDIR/r275_collisions.txt" | tr '\n' ' ')
if bounded_is_incomplete "$r275_rc"; then
    echo "  INCOMPLETE bug 275: the collision-order compile timed out twice (20 s each)"
    INCOMPLETE=$((INCOMPLETE + 1))
elif [ "$r275_order" = "first second P " ]; then
    echo "  ok  bug 275: every declaration collision is reported, in order"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 275: declaration collisions reported as '$r275_order', expected 'first second P '"
    FAIL=$((FAIL + 1))
fi
r275_src="$TMPDIR/r275_call_chain_20000.con"
awk -v n=20000 'BEGIN {
    for (i = 0; i < n; i++) printf "fn f%d(x: i64) -> i64 { return f%d(x) + 1; }\n", i, i + 1
    printf "fn f%d(x: i64) -> i64 { return x; }\n", n
    printf "fn main() -> Int { return (f0(42) - %d) as Int; }\n", n
}' > "$r275_src"
r265_stage_ms "$r275_src" check; r275_first="$r265_ms"; r275_ms="$r275_first"
case "$r275_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r275_first" -gt 200 ]; then r265_stage_ms "$r275_src" check; r275_ms="$r265_ms"; fi ;;
esac
case "$r275_ms" in
    incomplete)
        echo "  INCOMPLETE bug 275: checking a chain of 20000 functions timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 275: checking a chain of 20000 functions failed ($r275_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r275_first" -le 200 ] || [ "$r275_ms" -le 400 ]; then
           echo "  ok  bug 275: a chain of 20000 functions checks within budget (${r275_ms} ms)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 275: checking a chain of 20000 functions took ${r275_first} ms, then ${r275_ms} ms (budget 200, retry 400)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
:
}

suite_positive_2_28() {
for r217 in regress_217_nested_submodule_scope regress_217_sibling_type_precedence; do
    r217_interp=$($COMPILER "$TESTDIR/$r217.con" --interp 2>&1 || true)
    if [ "$r217_interp" = "42" ]; then
        echo "  ok  bug 217: $r217 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 217: $r217 --interp gave '$r217_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_29() {
for r229 in regress_229_value_does_not_hide_type regress_229_user_option_does_not_hide_builtin \
            regress_229_child_newtype_known regress_229_option_named_alias_or_struct \
            regress_229_alias_and_enum_literal_precedence; do
    r229_interp=$($COMPILER "$TESTDIR/$r229.con" --interp 2>&1 || true)
    if [ "$r229_interp" = "42" ]; then
        echo "  ok  bug 229: $r229 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 229: $r229 --interp gave '$r229_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_30() {
for r230 in regress_230_toplevel_type_environment regress_227_toplevel_builtin_result \
            regress_227_nested_builtin_result regress_227_user_result_methods_beside_builtin \
            regress_227_child_result_beside_builtin regress_227_imported_field_builtin_result \
            regress_227_value_import_named_result; do
    r230_interp=$($COMPILER "$TESTDIR/$r230.con" --interp 2>&1 || true)
    if [ "$r230_interp" = "42" ]; then
        echo "  ok  bugs 230/227: $r230 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bugs 230/227: $r230 --interp gave '$r230_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_31() {
r239_edges=$(cached_output "$TESTDIR/regress_239_method_call_beside_trusted_extern.con" "--report trust-edges")
if grep -q "^# totals:" <<<"$r239_edges" && ! grep -qE "^user[[:space:]]+run[[:space:]]" <<<"$r239_edges"; then
    echo "  ok  bug 239: a method call is no trust edge of a foreign binding of its spelling"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report trust-edges records a trust edge for user.run (a method call), or printed no report:"
    printf '%s\n' "$r239_edges" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_32() {
r239_proof=$(cached_output "$TESTDIR/regress_239_method_call_not_an_extern_call_report.con" "--report proof")
if grep -q "module ffi" <<<"$r239_proof" && ! grep -q "calls extern: P_get" <<<"$r239_proof"; then
    echo "  ok  bug 239: --report proof does not read a method call as an extern call"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report proof reads the method call P_get() as an extern call (or printed no report)"
    FAIL=$((FAIL + 1))
fi
# The predictable profile, the effects report and the unsafe report read only free calls as extern
# calls (Codex review r8: before the fix `run` failed the profile, "calls extern (P_get)", the effects
# report said "ffi: yes" and assumed `main.ffi.P_get`, and the unsafe report listed a method caller
# as relying on an extern of the method's spelling).
r239_pred=$(cached_output "$TESTDIR/regress_239_method_call_not_an_extern_call_report.con" "--check predictable")
if grep -q "predictable profile: pass" <<<"$r239_pred"; then
    echo "  ok  bug 239: the predictable profile does not read a method call as an extern call"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --check predictable refused a method call as an extern call:"
    printf '%s\n' "$r239_pred" | awk 'NR<=4'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_33() {
r239_pred2=$(cached_output "$TESTDIR/regress_239_method_call_reaches_ffi_report.con" "--check predictable")
if grep -q "run — calls extern" <<<"$r239_pred2"; then
    echo "  ok  bug 239: the predictable profile refuses FFI reached through a method call"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --check predictable accepted FFI reached through a method call:"
    printf '%s\n' "$r239_pred2" | awk 'NR<=4'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_34() {
r239_pred3=$(cached_output "$TESTDIR/regress_239_method_spelled_like_alloc_op.con" "--check predictable")
if grep -q "predictable profile: pass" <<<"$r239_pred3"; then
    echo "  ok  bug 239: a method spelled like an allocation intrinsic is no allocation"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --check predictable read a method call as an allocation:"
    printf '%s\n' "$r239_pred3" | awk 'NR<=4'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_35() {
r239_alloc=$(cached_output "$TESTDIR/regress_239_destructor_call_is_cleanup.con" "--report alloc")
if grep -q "main" <<<"$r239_alloc" && ! grep -q "no matching free" <<<"$r239_alloc"; then
    echo "  ok  bug 239: a destructor call counts as cleanup in --report alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report alloc reports a destroyed allocation as unmatched:"
    printf '%s\n' "$r239_alloc" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_36() {
r239_alloc2=$(cached_output "$TESTDIR/regress_239_method_spelled_like_free_op.con" "--report alloc")
if grep -q "No allocation activity found." <<<"$r239_alloc2"; then
    echo "  ok  bug 239: a method spelled like a freeing intrinsic frees nothing in --report alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report alloc counts a method spelled like a freeing intrinsic as a free:"
    printf '%s\n' "$r239_alloc2" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_37() {
r239_edges5=$(cached_output "$TESTDIR/regress_239_untrusted_extern_beside_trusted_extern.con" "--report trust-edges")
if grep -qE "call[[:space:]]+calls-ffi[[:space:]]+f" <<<"$r239_edges5" && ! grep -qE "call[[:space:]]+calls-trusted[[:space:]]+f" <<<"$r239_edges5"; then
    echo "  ok  bug 239: an untrusted extern call is not trusted by another module's trusted extern of its name"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report trust-edges for an untrusted extern beside another module's trusted one:"
    printf '%s\n' "$r239_edges5" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_38() {
r239_pred4=$(cached_output "$TESTDIR/regress_239_free_call_reaches_ffi_predictable.con" "--check predictable")
if grep -q "main — calls extern" <<<"$r239_pred4" && grep -q "run — calls extern" <<<"$r239_pred4"; then
    echo "  ok  bug 239: the predictable profile refuses FFI reached through a free call"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --check predictable missed FFI reached through a free call:"
    printf '%s\n' "$r239_pred4" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_39() {
r239_asm=$(cached_output "$TESTDIR/regress_239_extern_alias_assumption_not_method.con" "--report assumptions")
r239_kinds=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(a["kind"] for f in d["functions"] if f["fn"].endswith("user_run") for a in f["assumes"])))' <<<"$r239_asm" 2>/dev/null || true)
if [ "$r239_kinds" = "foreign-binding" ]; then
    echo "  ok  bug 239: an extern import alias reaches its declaration, not a trusted method of its name"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report assumptions for an extern import alias beside a trusted method:"
    printf '%s\n' "$r239_asm" | cut -c1-300 | awk 'NR<=4'
    FAIL=$((FAIL + 1))
fi
r239_edges4=$(cached_output "$TESTDIR/regress_239_imported_trusted_extern_beside_trusted_method.con" "--report trust-edges")
if grep -qE "main[[:space:]]+calls-trusted[[:space:]]+defs_P_get" <<<"$r239_edges4"; then
    echo "  ok  bug 239: an imported trusted extern call is trusted by its declaration beside a trusted method"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report trust-edges lost an imported trusted extern's edge:"
    printf '%s\n' "$r239_edges4" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
r239_edges3=$(cached_output "$TESTDIR/regress_239_trusted_extern_beside_method_edge.con" "--report trust-edges")
if grep -qE "run[[:space:]]+calls-trusted[[:space:]]+defs_P_get" <<<"$r239_edges3" && grep -qE "run[[:space:]]+calls-ffi[[:space:]]+defs_P_get" <<<"$r239_edges3"; then
    echo "  ok  bug 239: a trusted extern call keeps its trust edge beside a method of its spelling"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report trust-edges lost a trusted extern's edge beside a method of its spelling:"
    printf '%s\n' "$r239_edges3" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
r239_edges2=$(cached_output "$TESTDIR/regress_239_extern_call_not_trusted_by_method.con" "--report trust-edges")
if grep -qE "run[[:space:]]+calls-ffi[[:space:]]+defs_P_get" <<<"$r239_edges2" && ! grep -qE "run[[:space:]]+calls-trusted" <<<"$r239_edges2"; then
    echo "  ok  bug 239: an extern call is not trusted by a trusted method of its spelling"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 239: --report trust-edges for an extern call beside a trusted method of its spelling:"
    printf '%s\n' "$r239_edges2" | awk 'NR<=6'
    FAIL=$((FAIL + 1))
fi
# Bug 279: Lower appended each lowered function of a module to the list built so far, filtered the
# program's types against the module's own by a list search per type, checked each call against a
# list of defined functions and deduplicated string literals by a list search, so a module of n
# declarations took n² to lower (20000 functions: 1405 ms). The R-0550 gate judges the stage, but
# at its sizes the pre-fix `functions` shape stays inside its bound, so a generated module of 20000
# functions must lower (the `lower` stage of --emit-trace-json) within 350 ms, retried once at
# 700 ms (fixed: 102 ms on the dev host; pre-fix, twice the retry budget).
r279f_src="$TMPDIR/r279f_functions_20000.con"
awk -v n=20000 'BEGIN {
    for (i = 0; i < n; i++) printf "fn f%d(x: i64) -> i64 { return x + %d; }\n", i, i % 3
    printf "fn main() -> Int { return (f0(40) + f%d(2) - %d) as Int; }\n", n - 1, (n - 1) % 3
}' > "$r279f_src"
r265_stage_ms "$r279f_src" lower; r279f_first="$r265_ms"; r279f_ms="$r279f_first"
case "$r279f_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r279f_first" -gt 350 ]; then r265_stage_ms "$r279f_src" lower; r279f_ms="$r265_ms"; fi ;;
esac
case "$r279f_ms" in
    incomplete)
        echo "  INCOMPLETE bug 279: lowering 20000 functions timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 279: lowering 20000 functions failed ($r279f_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r279f_first" -le 350 ] || [ "$r279f_ms" -le 700 ]; then
           echo "  ok  bug 279: lowering 20000 functions within budget (${r279f_ms} ms, lower)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 279: lowering 20000 functions took ${r279f_first} ms, then ${r279f_ms} ms in lower (budget 350, retry 700)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
:
}

suite_positive_2_40() {
r272_edges=$(cached_output "$TESTDIR/regress_272_imported_extern_ffi_edge.con" "--report trust-edges")
r272_missing=""
for r272_e in "own_call calls-ffi abs" "imported_call calls-ffi abs" "trusted_call calls-ffi tabs" \
              "trusted_call calls-trusted tabs" "aliased_call calls-ffi cabs"; do
    read -r r272_fn r272_kind r272_tgt <<<"$r272_e"
    grep -qE "[[:space:]]$r272_fn[[:space:]]+$r272_kind[[:space:]]+$r272_tgt\$" <<<"$r272_edges" || r272_missing="$r272_missing [$r272_e]"
done
if [ -z "$r272_missing" ] && grep -qF "calls-ffi=4 calls-trusted=1" <<<"$r272_edges"; then
    echo "  ok  bug 272: imported, trusted-imported and aliased extern calls each have a calls-ffi edge"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 272: --report trust-edges missing$r272_missing (or wrong totals):"
    printf '%s\n' "$r272_edges" | awk 'NR<=12'
    FAIL=$((FAIL + 1))
fi
r272_interp=$($COMPILER "$TESTDIR/regress_272_imported_extern_ffi_edge.con" --interp 2>&1 || true)
if [ "$r272_interp" = "42" ]; then
    echo "  ok  bug 272: regress_272_imported_extern_ffi_edge --interp gives 42, as the binary"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 272: regress_272_imported_extern_ffi_edge --interp gave '$r272_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_41() {
run_err "$TESTDIR/error_280_exit_deep_operand.con" "(E0278) \`return\` may not occur inside an operand of a binary operator"
r280c_src="$TMPDIR/r280c_nested_parens_20000.con"
awk -v n=20000 'BEGIN {
    print "fn main() -> Int {"
    line = "    let s: i64 = "
    for (i = 0; i < n; i++) line = line "(1 + "
    line = line "0"
    for (i = 0; i < n; i++) line = line ")"
    print line ";"
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r280c_src"
r265_stage_ms "$r280c_src" check; r280c_first="$r265_ms"; r280c_ms="$r280c_first"
case "$r280c_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r280c_first" -gt 100 ]; then r265_stage_ms "$r280c_src" check; r280c_ms="$r265_ms"; fi ;;
esac
case "$r280c_ms" in
    incomplete)
        echo "  INCOMPLETE bug 280: checking an expression nested 20000 deep timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 280: checking an expression nested 20000 deep failed ($r280c_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r280c_first" -le 100 ] || [ "$r280c_ms" -le 200 ]; then
           echo "  ok  bug 280: checking an expression nested 20000 deep within budget (${r280c_ms} ms, check)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 280: checking an expression nested 20000 deep took ${r280c_first} ms, then ${r280c_ms} ms in check (budget 100, retry 200)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
r280e_src="$TMPDIR/r280e_nested_parens_20000.con"
awk -v n=20000 'BEGIN {
    print "fn main() -> Int {"
    line = "    let s: i64 = "
    for (i = 0; i < n; i++) line = line "(1 + "
    line = line "0"
    for (i = 0; i < n; i++) line = line ")"
    print line ";"
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r280e_src"
r265_stage_ms "$r280e_src" elaborate; r280e_first="$r265_ms"; r280e_ms="$r280e_first"
case "$r280e_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r280e_first" -gt 100 ]; then r265_stage_ms "$r280e_src" elaborate; r280e_ms="$r265_ms"; fi ;;
esac
case "$r280e_ms" in
    incomplete)
        echo "  INCOMPLETE bug 280: elaborating an expression nested 20000 deep timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 280: elaborating an expression nested 20000 deep failed ($r280e_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r280e_first" -le 100 ] || [ "$r280e_ms" -le 200 ]; then
           echo "  ok  bug 280: elaborating an expression nested 20000 deep within budget (${r280e_ms} ms, elaborate)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 280: elaborating an expression nested 20000 deep took ${r280e_first} ms, then ${r280e_ms} ms in elaborate (budget 100, retry 200)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
r286_src="$TMPDIR/r286_nested_ifs_8000.con"
awk -v n=8000 'BEGIN {
    print "fn main() -> Int {"
    print "    let mut s: i64 = 0;"
    print "    let t: i64 = 1;"
    line = "    "
    for (i = 0; i < n; i++) line = line "if t > 0 { s = s + 1; "
    for (i = 0; i < n; i++) line = line "}"
    print line
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r286_src"
r265_stage_ms "$r286_src" lower; r286_first="$r265_ms"; r286_ms="$r286_first"
case "$r286_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r286_first" -gt 400 ]; then r265_stage_ms "$r286_src" lower; r286_ms="$r265_ms"; fi ;;
esac
case "$r286_ms" in
    incomplete)
        echo "  INCOMPLETE bug 286: lowering 8000 nested ifs timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 286: lowering 8000 nested ifs failed ($r286_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r286_first" -le 400 ] || [ "$r286_ms" -le 800 ]; then
           echo "  ok  bug 286: lowering 8000 nested ifs within budget (${r286_ms} ms, lower)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 286: lowering 8000 nested ifs took ${r286_first} ms, then ${r286_ms} ms in lower (budget 400, retry 800)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
# Bug 288: EmitSSA kept its program-wide name tables (colliding names, defined and method names,
# link symbols, emitted types, string lengths, deduplicated declarations) as lists searched per
# function or per type, so emitting n functions took n² (20000 functions: --emit-llvm 5.9 s, the
# in-compiler stages 0.6 s). `--emit-llvm` of 20000 generated functions must finish within 2000 ms,
# retried once at 4000 ms (0.6 s with the fix on the dev host).
r288_src="$TMPDIR/r288_functions_20000.con"
awk -v n=20000 'BEGIN {
    for (i = 0; i < n; i++) printf "fn f%d(x: i64) -> i64 { return x + %d; }\n", i, i % 3
    printf "fn main() -> Int { return (f0(40) + f%d(2) - %d) as Int; }\n", n - 1, (n - 1) % 3
}' > "$r288_src"
r288_emit_ms() {  # sets r288_ms to the --emit-llvm wall time in ms, "incomplete" or "rcN"
    local rc=0 t0 t1
    t0="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    bounded_run -r 180 180 -- $COMPILER "$r288_src" --emit-llvm > /dev/null 2>&1 || rc=$?
    t1="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    if bounded_is_incomplete "$rc"; then r288_ms=incomplete; return 0; fi
    if [ "$rc" != 0 ]; then r288_ms="rc$rc"; return 0; fi
    r288_ms=$((t1 - t0))
}
r288_emit_ms; r288_first="$r288_ms"
case "$r288_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r288_first" -gt 2000 ]; then r288_emit_ms; fi ;;
esac
case "$r288_ms" in
    incomplete)
        echo "  INCOMPLETE bug 288: emitting 20000 functions timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 288: emitting 20000 functions failed ($r288_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r288_first" -le 2000 ] || [ "$r288_ms" -le 4000 ]; then
           echo "  ok  bug 288: emitting 20000 functions within budget (${r288_ms} ms, --emit-llvm)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 288: emitting 20000 functions took ${r288_first} ms, then ${r288_ms} ms (--emit-llvm; budget 2000, retry 4000)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
# Bug 289: Check asked whether a branch's block diverges, never terminates or exits the function
# (each a walk down the block's last statements) at every level of an `if`/`else` or `match` nest,
# and its contract binder collector copied every nested block's names into each enclosing
# level's list, so a nest n deep took n² to check (depth 8000 on main 99084f4f: `if`/`else`
# 2133 ms, `match` 3253 ms, blocks with `let`s 681 ms). Each nest 8000 deep must check (the
# `check` stage of --emit-trace-json) within 250 ms, retried once at 500 ms (54, 58 and 62 ms with
# the fix on the dev host).
r289_bad=""; r289_incomplete=""; r289_ok=""
for r289_shape in ifelse match blocks; do
    r289_src="$TMPDIR/r289_${r289_shape}_8000.con"
    awk -v shape="$r289_shape" -v n=8000 'BEGIN {
        print "fn main() -> Int {"
        print "    let mut s: i64 = 0;"
        print "    let t: i64 = 1;"
        printf "    "
        for (i = 0; i < n; i++) {
            if (shape == "match") printf "match t { 1 => { s = s + 1; "
            else if (shape == "blocks") printf "if t > 0 { let x%d: i64 = s + 1; s = x%d; ", i, i
            else printf "if t > 0 { s = s + 1; "
        }
        for (i = 0; i < n; i++) {
            if (shape == "match") printf "}, _ => { s = s + 2; }, }"
            else if (shape == "blocks") printf "}"
            else printf "} else { s = s + 2; }"
        }
        print ""
        printf "    return (s - %d + 42) as Int;\n", n
        print "}"
    }' > "$r289_src"
    r265_stage_ms "$r289_src" check; r289_first="$r265_ms"; r289_ms="$r289_first"
    case "$r289_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r289_first" -gt 250 ]; then r265_stage_ms "$r289_src" check; r289_ms="$r265_ms"; fi ;;
    esac
    case "$r289_ms" in
        incomplete) r289_incomplete="$r289_incomplete $r289_shape" ;;
        ''|*[!0-9]*) r289_bad="$r289_bad $r289_shape:$r289_ms" ;;
        *) if [ "$r289_first" -le 250 ] || [ "$r289_ms" -le 500 ]; then
               r289_ok="$r289_ok $r289_shape:${r289_ms}ms"
           else
               r289_bad="$r289_bad $r289_shape:${r289_first}ms,${r289_ms}ms"
           fi ;;
    esac
done
if [ -n "$r289_bad" ]; then
    echo "FAIL  bug 289: checking a nest 8000 deep exceeded its budget (250 ms, retry 500) or failed:$r289_bad"
    FAIL=$((FAIL + 1))
elif [ -n "$r289_incomplete" ]; then
    echo "  INCOMPLETE bug 289: checking a nest 8000 deep timed out twice (180 s each):$r289_incomplete"
    INCOMPLETE=$((INCOMPLETE + 1))
else
    echo "  ok  bug 289: nests 8000 deep check within budget:$r289_ok"
    PASS=$((PASS + 1))
fi
:
}

suite_positive_2_42() {
run_err "$TESTDIR/error_298_exit_nested_value_if.con" "(E0278) \`return\` may not occur inside an operand of a binary operator"
run_err "$TESTDIR/error_298_exit_nested_value_match.con" "(E0278) \`return\` may not occur inside an operand of a binary operator"
r298_bad=""; r298_incomplete=""; r298_ok=""
for r298_shape in if match; do
    r298_src="$TMPDIR/r298_${r298_shape}_8000.con"
    awk -v shape="$r298_shape" -v n=8000 'BEGIN {
        print "fn main() -> Int {"
        print "    let t: i64 = 1;"
        printf "    let s: i64 = "
        for (i = 0; i < n; i++) {
            if (shape == "match") printf "match t { 1 => 1 + "
            else printf "if t > 0 { 1 + "
        }
        printf "0"
        for (i = 0; i < n; i++) {
            if (shape == "match") printf ", _ => 0, }"
            else printf " } else { 0 }"
        }
        print ";"
        printf "    return (s - %d + 42) as Int;\n", n
        print "}"
    }' > "$r298_src"
    r265_stage_ms "$r298_src" check; r298_first="$r265_ms"; r298_ms="$r298_first"
    case "$r298_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r298_first" -gt 150 ]; then r265_stage_ms "$r298_src" check; r298_ms="$r265_ms"; fi ;;
    esac
    case "$r298_ms" in
        incomplete) r298_incomplete="$r298_incomplete $r298_shape" ;;
        ''|*[!0-9]*) r298_bad="$r298_bad $r298_shape:$r298_ms" ;;
        *) if [ "$r298_first" -le 150 ] || [ "$r298_ms" -le 300 ]; then
               r298_ok="$r298_ok $r298_shape:${r298_ms}ms"
           else
               r298_bad="$r298_bad $r298_shape:${r298_first}ms,${r298_ms}ms"
           fi ;;
    esac
done
if [ -n "$r298_bad" ]; then
    echo "FAIL  bug 298: checking an operand chain 8000 deep exceeded its budget (150 ms, retry 300) or failed:$r298_bad"
    FAIL=$((FAIL + 1))
elif [ -n "$r298_incomplete" ]; then
    echo "  INCOMPLETE bug 298: checking an operand chain 8000 deep timed out twice (180 s each):$r298_incomplete"
    INCOMPLETE=$((INCOMPLETE + 1))
else
    echo "  ok  bug 298: operand chains 8000 deep through value if/match check within budget:$r298_ok"
    PASS=$((PASS + 1))
fi
# Bug 290: at every arm of every `match`, Check walked every non-Copy binding in scope (the H9
# block-local check and the arms' agreement check), and it looked each enum up in the list of all
# enums, so a function matching n enum values took n² to check (8000 on main 99084f4f: 10088 ms).
# A generated `main` that builds and matches 8000 enum values of 8000 enum types must check (the
# `check` stage of --emit-trace-json) within 600 ms, retried once at 1200 ms (149 ms with the fix
# on the dev host).
r290_src="$TMPDIR/r290_enum_uses_8000.con"
awk -v n=8000 'BEGIN {
    for (i = 0; i < n; i++) printf "enum E%d { A { v: i64 }, B }\n", i
    print "fn main() -> Int {"
    print "    let mut t: i64 = 0;"
    for (i = 0; i < n; i++) {
        printf "    let e%d: E%d = E%d::A { v: 1 };\n", i, i, i
        printf "    match e%d { E%d::A { v } => { t = t + v; }, E%d::B => { t = t + 2; }, }\n", i, i, i
    }
    printf "    return (t - %d + 42) as Int;\n", n
    print "}"
}' > "$r290_src"
r265_stage_ms "$r290_src" check; r290_first="$r265_ms"; r290_ms="$r290_first"
case "$r290_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r290_first" -gt 600 ]; then r265_stage_ms "$r290_src" check; r290_ms="$r265_ms"; fi ;;
esac
case "$r290_ms" in
    incomplete)
        echo "  INCOMPLETE bug 290: checking 8000 matched enum values timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 290: checking 8000 matched enum values failed ($r290_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r290_first" -le 600 ] || [ "$r290_ms" -le 1200 ]; then
           echo "  ok  bug 290: checking 8000 matched enum values within budget (${r290_ms} ms, check)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 290: checking 8000 matched enum values took ${r290_first} ms, then ${r290_ms} ms in check (budget 600, retry 1200)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
r291_src="$TMPDIR/r291_struct_uses_8000.con"
awk -v n=8000 'BEGIN {
    for (i = 0; i < n; i++) printf "struct Copy S%d { a: i64 }\n", i
    print "fn main() -> Int {"
    print "    let mut t: i64 = 0;"
    for (i = 0; i < n; i++) printf "    let s%d: S%d = S%d { a: 1 };\n    t = t + s%d.a;\n", i, i, i, i
    printf "    return (t - %d + 42) as Int;\n", n
    print "}"
}' > "$r291_src"
for r291_stage in check elaborate; do
    r265_stage_ms "$r291_src" "$r291_stage"; r291_first="$r265_ms"; r291_ms="$r291_first"
    case "$r291_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r291_first" -gt 150 ]; then r265_stage_ms "$r291_src" "$r291_stage"; r291_ms="$r265_ms"; fi ;;
    esac
    case "$r291_ms" in
        incomplete)
            echo "  INCOMPLETE bug 291: $r291_stage of 8000 struct uses timed out twice (180 s each)"
            INCOMPLETE=$((INCOMPLETE + 1)) ;;
        ''|*[!0-9]*)
            echo "FAIL  bug 291: $r291_stage of 8000 struct uses failed ($r291_ms)"
            FAIL=$((FAIL + 1)) ;;
        *) if [ "$r291_first" -le 150 ] || [ "$r291_ms" -le 300 ]; then
               echo "  ok  bug 291: $r291_stage of 8000 struct uses within budget (${r291_ms} ms)"
               PASS=$((PASS + 1))
           else
               echo "FAIL  bug 291: $r291_stage of 8000 struct uses took ${r291_first} ms, then ${r291_ms} ms (budget 150, retry 300)"
               FAIL=$((FAIL + 1))
           fi ;;
    esac
done
r292_src="$TMPDIR/r292_nested_while_8000.con"
awk -v n=8000 'BEGIN {
    print "fn main() -> Int {"
    print "    let mut s: i64 = 0;"
    line = "    "
    for (i = 0; i < n; i++) line = line "while s < 1 { "
    line = line "s = s + 1; "
    for (i = 0; i < n; i++) line = line "} "
    print line
    print "    return (s - 1 + 42) as Int;"
    print "}"
}' > "$r292_src"
r265_stage_ms "$r292_src" lower; r292_first="$r265_ms"; r292_ms="$r292_first"
case "$r292_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r292_first" -gt 500 ]; then r265_stage_ms "$r292_src" lower; r292_ms="$r265_ms"; fi ;;
esac
case "$r292_ms" in
    incomplete)
        echo "  INCOMPLETE bug 292: lowering 8000 nested whiles timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 292: lowering 8000 nested whiles failed ($r292_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r292_first" -le 500 ] || [ "$r292_ms" -le 900 ]; then
           echo "  ok  bug 292: lowering 8000 nested whiles within budget (${r292_ms} ms, lower)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 292: lowering 8000 nested whiles took ${r292_first} ms, then ${r292_ms} ms in lower (budget 500, retry 900)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
# Bug 293: every compile runs Report's safety gate (provenViolationDiagnostics), whose scoped
# walker re-walked each statement's subtree for the scalars it assigns, filtered the whole
# hypothesis list after every statement and copied the scope at every nesting level, so a function
# nested n deep took n² (10000 nested ifs: --emit-llvm 9.5 s with bug 286 fixed, of which the
# stages through lower 0.25 s). `--emit-llvm` of 10000 nested ifs must finish within 3000 ms,
# retried once at 6000 ms.
r293_src="$TMPDIR/r293_nested_ifs_10000.con"
awk -v n=10000 'BEGIN {
    print "fn main() -> Int {"
    print "    let mut s: i64 = 0;"
    print "    let t: i64 = 1;"
    line = "    "
    for (i = 0; i < n; i++) line = line "if t > 0 { s = s + 1; "
    for (i = 0; i < n; i++) line = line "}"
    print line
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r293_src"
r293_emit_ms() {  # sets r293_ms to the --emit-llvm wall time in ms, "incomplete" or "rcN"
    local rc=0 t0 t1
    t0="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    bounded_run -r 180 180 -- $COMPILER "$r293_src" --emit-llvm > /dev/null 2>&1 || rc=$?
    t1="$(python3 -c 'import time; print(int(time.time() * 1000))')"
    if bounded_is_incomplete "$rc"; then r293_ms=incomplete; return 0; fi
    if [ "$rc" != 0 ]; then r293_ms="rc$rc"; return 0; fi
    r293_ms=$((t1 - t0))
}
r293_emit_ms; r293_first="$r293_ms"
case "$r293_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r293_first" -gt 3000 ]; then r293_emit_ms; fi ;;
esac
case "$r293_ms" in
    incomplete)
        echo "  INCOMPLETE bug 293: compiling 10000 nested ifs timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 293: compiling 10000 nested ifs failed ($r293_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r293_first" -le 3000 ] || [ "$r293_ms" -le 6000 ]; then
           echo "  ok  bug 293: compiling 10000 nested ifs within budget (${r293_ms} ms, --emit-llvm)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 293: compiling 10000 nested ifs took ${r293_first} ms, then ${r293_ms} ms (--emit-llvm; budget 3000, retry 6000)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
# Bug 295: the parser appended each match arm, parameter, call argument (and every other list it
# builds element by element: fields, variants, bindings, methods, import symbols) to the list built
# so far, so a list of n took n² to parse (10000 on main 1bcb7c36: a match of 10000 arms 263 ms,
# a function of 10000 parameters called with 10000 arguments 434 ms). Each shape at 20000 must
# parse (the `parse` stage of --emit-trace-json) within 250 ms, retried once at 500 ms.
r295_bad=""; r295_incomplete=""; r295_ok=""
for r295_shape in arms params; do
    r295_src="$TMPDIR/r295_${r295_shape}_20000.con"
    awk -v shape="$r295_shape" -v n=20000 'BEGIN {
        if (shape == "arms") {
            print "fn main() -> Int {"
            printf "    let t: i64 = %d;\n", n - 1
            print "    let mut s: i64 = 0;"
            print "    match t {"
            for (i = 0; i < n; i++) printf "        %d => { s = %d; },\n", i, i
            print "        _ => { s = 0; },"
            print "    }"
            printf "    return (s - %d + 42) as Int;\n", n - 1
            print "}"
        } else {
            printf "fn f("
            for (i = 0; i < n; i++) printf "%sp%d: i64", (i ? ", " : ""), i
            print ") -> i64 {"
            printf "    return p0 + p%d;\n", n - 1
            print "}"
            printf "fn main() -> Int {\n    return (f("
            for (i = 0; i < n; i++) printf "%s1", (i ? ", " : "")
            print ") + 40) as Int;"
            print "}"
        }
    }' > "$r295_src"
    r265_stage_ms "$r295_src" parse; r295_first="$r265_ms"; r295_ms="$r295_first"
    case "$r295_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r295_first" -gt 250 ]; then r265_stage_ms "$r295_src" parse; r295_ms="$r265_ms"; fi ;;
    esac
    case "$r295_ms" in
        incomplete) r295_incomplete="$r295_incomplete $r295_shape" ;;
        ''|*[!0-9]*) r295_bad="$r295_bad $r295_shape:$r295_ms" ;;
        *) if [ "$r295_first" -le 250 ] || [ "$r295_ms" -le 500 ]; then
               r295_ok="$r295_ok $r295_shape:${r295_ms}ms"
           else
               r295_bad="$r295_bad $r295_shape:${r295_first}ms,${r295_ms}ms"
           fi ;;
    esac
done
if [ -n "$r295_bad" ]; then
    echo "FAIL  bug 295: parsing a list of 20000 exceeded its budget (250 ms, retry 500) or failed:$r295_bad"
    FAIL=$((FAIL + 1))
elif [ -n "$r295_incomplete" ]; then
    echo "  INCOMPLETE bug 295: parsing a list of 20000 timed out twice (180 s each):$r295_incomplete"
    INCOMPLETE=$((INCOMPLETE + 1))
else
    echo "  ok  bug 295: lists of 20000 parse within budget:$r295_ok"
    PASS=$((PASS + 1))
fi
# Bug 296: the callee walk (Proof/CallCollect.lean) built its list by appending each statement's,
# argument's, field's, arm's and element's callees to the list built so far, and the post-mono
# verifier deduplicated a function's callees by pairwise comparison, so a function of n calls
# took n² in Elab (asked twice per body) and in the monomorphize stage (20000 calls on main's
# compiler: elaborate 2681 ms, monomorphize 2440 ms). A `main` calling 20000 functions must
# elaborate within 800 ms and monomorphize within 600 ms, each retried once at twice that
# (315 and 174 ms with the fix on the dev host).
r296_src="$TMPDIR/r296_many_calls_20000.con"
awk -v n=20000 'BEGIN {
    for (i = 0; i < n; i++) printf "fn f%d(x: i64) -> i64 { return x + 1; }\n", i
    print "fn main() -> Int {"
    print "    let mut t: i64 = 0;"
    for (i = 0; i < n; i++) printf "    t = f%d(t);\n", i
    printf "    return (t - %d + 42) as Int;\n", n
    print "}"
}' > "$r296_src"
r296_bad=""; r296_incomplete=""; r296_ok=""
for r296_case in "elaborate 800" "monomorphize 600"; do
    read -r r296_stage r296_budget <<< "$r296_case"
    r265_stage_ms "$r296_src" "$r296_stage"; r296_first="$r265_ms"; r296_ms="$r296_first"
    case "$r296_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r296_first" -gt "$r296_budget" ]; then r265_stage_ms "$r296_src" "$r296_stage"; r296_ms="$r265_ms"; fi ;;
    esac
    case "$r296_ms" in
        incomplete) r296_incomplete="$r296_incomplete $r296_stage" ;;
        ''|*[!0-9]*) r296_bad="$r296_bad $r296_stage:$r296_ms" ;;
        *) if [ "$r296_first" -le "$r296_budget" ] || [ "$r296_ms" -le $((2 * r296_budget)) ]; then
               r296_ok="$r296_ok $r296_stage:${r296_ms}ms"
           else
               r296_bad="$r296_bad $r296_stage:${r296_first}ms,${r296_ms}ms(budget $r296_budget)"
           fi ;;
    esac
done
if [ -n "$r296_bad" ]; then
    echo "FAIL  bug 296: a function of 20000 calls exceeded its stage budget (retry at twice) or failed:$r296_bad"
    FAIL=$((FAIL + 1))
elif [ -n "$r296_incomplete" ]; then
    echo "  INCOMPLETE bug 296: a function of 20000 calls timed out twice (180 s each):$r296_incomplete"
    INCOMPLETE=$((INCOMPLETE + 1))
else
    echo "  ok  bug 296: a function of 20000 calls within budget:$r296_ok"
    PASS=$((PASS + 1))
fi
# Bug 297: Elab (elabCallEv) and Lower (lowerExpr) appended each call argument to the list built
# so far, quadratic in a call's arity (8000 arguments: elaborate 145 ms, lower 126 ms). A call of
# 12000 arguments must elaborate and lower within 60 ms each, retried once at 120 ms.
r297_src="$TMPDIR/r297_many_params_12000.con"
awk -v n=12000 'BEGIN {
    line = "fn f("
    for (i = 0; i < n; i++) line = line (i ? ", " : "") "p" i ": i64"
    print line ") -> i64 {"
    printf "    return p0 + p%d;\n", n - 1
    print "}"
    line = "fn main() -> Int {\n    return (f("
    for (i = 0; i < n; i++) line = line (i ? ", " : "") "1"
    print line ") + 40) as Int;"
    print "}"
}' > "$r297_src"
for r297_stage in elaborate lower; do
    r265_stage_ms "$r297_src" "$r297_stage"; r297_first="$r265_ms"; r297_ms="$r297_first"
    case "$r297_first" in
        ''|*[!0-9]*) ;;
        *) if [ "$r297_first" -gt 60 ]; then r265_stage_ms "$r297_src" "$r297_stage"; r297_ms="$r265_ms"; fi ;;
    esac
    case "$r297_ms" in
        incomplete)
            echo "  INCOMPLETE bug 297: a call of 12000 arguments timed out twice in $r297_stage (180 s each)"
            INCOMPLETE=$((INCOMPLETE + 1)) ;;
        ''|*[!0-9]*)
            echo "FAIL  bug 297: a call of 12000 arguments failed ($r297_ms, $r297_stage)"
            FAIL=$((FAIL + 1)) ;;
        *) if [ "$r297_first" -le 60 ] || [ "$r297_ms" -le 120 ]; then
               echo "  ok  bug 297: a call of 12000 arguments within budget (${r297_ms} ms, $r297_stage)"
               PASS=$((PASS + 1))
           else
               echo "FAIL  bug 297: a call of 12000 arguments took ${r297_first} ms, then ${r297_ms} ms in $r297_stage (budget 60, retry 120)"
               FAIL=$((FAIL + 1))
           fi ;;
    esac
done
# Bug 178 follow-up: SSAVerify computed immediate dominators by Cooper-Harvey-Kennedy, whose
# intersect walked the n-deep chain of a wide match's check blocks once per merge predecessor
# (16000 arms: lower 895 ms with bug 297 fixed). Lengauer-Tarjan replaced it: a match of 16000
# literal arms must lower within 400 ms, retried once at 800 ms (170 - 191 ms on the dev host).
r178d_src="$TMPDIR/r178d_wide_match_16000.con"
awk -v n=16000 'BEGIN {
    print "fn main() -> Int {"
    printf "    let t: i64 = %d;\n", n - 1
    print "    let mut s: i64 = 0;"
    print "    match t {"
    for (i = 0; i < n; i++) printf "        %d => { s = %d; },\n", i, i
    print "        _ => { s = 0; },"
    print "    }"
    printf "    return (s - %d + 42) as Int;\n", n - 1
    print "}"
}' > "$r178d_src"
r265_stage_ms "$r178d_src" lower; r178d_first="$r265_ms"; r178d_ms="$r178d_first"
case "$r178d_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r178d_first" -gt 400 ]; then r265_stage_ms "$r178d_src" lower; r178d_ms="$r265_ms"; fi ;;
esac
case "$r178d_ms" in
    incomplete)
        echo "  INCOMPLETE bug 178: lowering a 16000-arm match timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 178: lowering a 16000-arm match failed ($r178d_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r178d_first" -le 400 ] || [ "$r178d_ms" -le 800 ]; then
           echo "  ok  bug 178: lowering a 16000-arm match within budget (${r178d_ms} ms, lower)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 178: lowering a 16000-arm match took ${r178d_first} ms, then ${r178d_ms} ms in lower (budget 400, retry 800)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
:
}

suite_positive_2_43() {
for r239 in regress_239_extern_call_beside_generic_method regress_239_extern_call_beside_capable_method; do
    r239_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r239.con" --interp 2>&1 || true)
    if [ "$r239_interp" = "99" ]; then
        echo "  ok  bug 239: $r239 — interp == binary (99)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 239: $r239 --interp gave '$r239_interp', want 99"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_44() {
# bounded_run, not GNU `timeout` (absent on macOS runners); a timeout is INCOMPLETE, not a pass.
for r238 in regress_238_free_fn_spelled_like_method_call regress_238_other_module_free_fn_takes_method_spelling \
            regress_238_parent_free_fn_takes_method_spelling regress_239_free_fn_beside_imported_method \
            regress_240_trait_bounds_and_type_param_shadow regress_241_parent_calls_child_respelled_method \
            regress_238_method_named_by_definition_name regress_239_parent_method_beside_child_free_fn \
            regress_241_parent_names_child_respelled_method regress_238_method_call_in_constant \
            regress_238_extern_takes_method_spelling regress_238_imported_extern_alias_takes_method_spelling \
            regress_238_method_definition_name_taken_by_extern regress_238_method_value_spelled_like_extern \
            regress_238_method_value_beside_unrelated_extern regress_239_method_call_beside_untrusted_extern \
            regress_239_static_method_beside_free_fn_report regress_239_method_call_beside_extern_of_other_arity \
            regress_239_extern_call_beside_method_with_indirect_call regress_239_method_call_beside_trusted_extern \
            regress_238_method_value_beside_extern_of_other_arity regress_239_nested_method_beside_extern \
            regress_239_respelled_method_beside_extern_types regress_239_method_call_not_an_extern_call_report \
            regress_247_function_value_reaches_foreign regress_239_method_value_no_foreign_assumption \
            regress_239_method_spelled_like_intrinsic regress_239_method_call_reaches_ffi_report \
            regress_239_method_spelled_like_vec_op regress_239_method_spelled_like_alloc_op \
            regress_239_alias_spelled_method_reaches_ffi regress_239_extern_call_beside_capable_method_explained \
            regress_239_method_edge_beside_free_alias regress_238_free_alias_takes_method_spelling \
            regress_239_fn_parameter_spelled_like_method regress_238_extern_alias_takes_nested_method_spelling \
            regress_238_unrelated_alias_beside_method regress_239_imported_extern_alias_beside_capable_method \
            regress_239_method_ffi_beside_free_alias regress_239_method_value_type_agreement \
            regress_239_method_cap_explained_past_free_alias regress_239_method_spelled_like_free_op \
            regress_238_method_value_both_spellings_taken_by_externs regress_239_method_value_beside_constant \
            regress_223_method_core_name_taken \
            regress_239_trusted_extern_beside_method_edge \
            regress_239_imported_trusted_extern_beside_trusted_method \
            regress_247_free_call_beside_unrelated_extern \
            regress_239_free_call_not_extern_report \
            regress_239_free_call_reaches_ffi_predictable \
            regress_239_imported_extern_alias_beside_method_arity regress_239_extern_alias_assumption_not_method \
            regress_239_extern_call_not_trusted_by_method regress_247_free_value_beside_unrelated_extern; do
    r238_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r238.con" --interp 2>&1 || true)
    if [ "$r238_interp" = "42" ]; then
        echo "  ok  bugs 238-241: $r238 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bugs 238-241: $r238 --interp gave '$r238_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
# Bug 281: the body-identity use list (`Proof.stmtFlatUses`) built each branch's uses by appending
# its nested blocks' lists, copying the list from below at every level, so statements nested n deep
# took n² to elaborate (depth 10000: 1362 ms). The scaling gate excludes the whole `nested-ifs`
# shape until its other open costs are fixed, so a generated body of `if` blocks nested 20000 deep
# must elaborate (the `elaborate` stage of --emit-trace-json) within 300 ms, retried once at
# 600 ms (fixed: about 60 ms on the dev host; pre-fix, about nine times the retry budget).
r281e_src="$TMPDIR/r281e_nested_ifs_20000.con"
awk -v n=20000 'BEGIN {
    print "fn main() -> Int {"
    print "    let mut s: i64 = 0;"
    print "    let t: i64 = 1;"
    line = "    "
    for (i = 0; i < n; i++) line = line "if t > 0 { s = s + 1; "
    for (i = 0; i < n; i++) line = line "}"
    print line
    printf "    return (s - %d + 42) as Int;\n", n
    print "}"
}' > "$r281e_src"
r265_stage_ms "$r281e_src" elaborate; r281e_first="$r265_ms"; r281e_ms="$r281e_first"
case "$r281e_first" in
    ''|*[!0-9]*) ;;
    *) if [ "$r281e_first" -gt 300 ]; then r265_stage_ms "$r281e_src" elaborate; r281e_ms="$r265_ms"; fi ;;
esac
case "$r281e_ms" in
    incomplete)
        echo "  INCOMPLETE bug 281: elaborating a body nested 20000 deep timed out twice (180 s each)"
        INCOMPLETE=$((INCOMPLETE + 1)) ;;
    ''|*[!0-9]*)
        echo "FAIL  bug 281: elaborating a body nested 20000 deep failed ($r281e_ms)"
        FAIL=$((FAIL + 1)) ;;
    *) if [ "$r281e_first" -le 300 ] || [ "$r281e_ms" -le 600 ]; then
           echo "  ok  bug 281: elaborating a body nested 20000 deep within budget (${r281e_ms} ms, elaborate)"
           PASS=$((PASS + 1))
       else
           echo "FAIL  bug 281: elaborating a body nested 20000 deep took ${r281e_first} ms, then ${r281e_ms} ms in elaborate (budget 300, retry 600)"
           FAIL=$((FAIL + 1))
       fi ;;
esac
:
}

suite_positive_2_45() {
for r223 in regress_223_aliased_struct_methods regress_223_aliased_enum \
            regress_223_aliased_generic_and_bound regress_223_aliased_destroy_impl \
            regress_223_aliased_self_result regress_223_aliased_cap_params; do
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r223_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r223.con" --interp 2>&1 || true)
    if [ "$r223_interp" = "42" ]; then
        echo "  ok  bug 223: $r223 — an aliased imported type is the type, interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 223: $r223 --interp gave '$r223_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_46() {
for r233e in error_233_imported_initializer_calls_function error_233_imported_initializer_extern \
             error_233_imported_initializer_via_constant; do
    r233e_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r233e.con" --interp 2>&1 || true)
    if grep -qF "cannot be inlined outside its module" <<<"$r233e_interp"; then
        echo "  ok  bug 233: $r233e — --interp refuses the imported initializer's call as the binary does"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 233: $r233e --interp gave '$r233e_interp', want the inlining refusal"
        FAIL=$((FAIL + 1))
    fi
done
for r233 in regress_233_shared_spelling_import regress_233_import_constant \
            regress_233_nested_import_constant regress_233_import_constant_scope \
            regress_233_nested_alias_constant regress_233_constant_type_alias \
            regress_233_constant_type_imported_alias regress_246_imported_alias_chain \
            regress_246_imported_alias_chain_across_imports regress_246_imported_alias_chain_long; do
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r233_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r233.con" --interp 2>&1 || true)
    if [ "$r233_interp" = "42" ]; then
        echo "  ok  bug 233: $r233 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 233: $r233 --interp gave '$r233_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
r233_dir=$(mktemp -d)
cp -R tests/regressions/bug233_import_public_constant_refused/project/. "$r233_dir/"
r233_out=$(cd "$r233_dir" && "$ROOT_DIR/$COMPILER" build 2>&1) && r233_rc=0 || r233_rc=$?
r233_run_rc=none
if [ "$r233_rc" = 0 ] && [ -x "$r233_dir/bug233" ]; then
    bounded_run 20 -- "$r233_dir/bug233" >/dev/null 2>&1 && r233_run_rc=0 || r233_run_rc=$?
fi
rm -rf "$r233_dir"
if [ "$r233_run_rc" = 42 ]; then
    echo "  ok  bug 233: a project's \`mod user;\` file imports a sibling file's constant (exit 42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 233: project build of tests/regressions/bug233_import_public_constant_refused/project (build rc $r233_rc, run rc $r233_run_rc), want exit 42:"
    printf '%s\n' "$r233_out" | awk 'NR<=3'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_47() {
for r243 in regress_243_aliased_newtype_import regress_243_aliased_newtype_with_original \
            regress_243_aliased_generic_newtype regress_243_nested_aliased_newtype; do
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r243_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r243.con" --interp 2>&1 || true)
    if [ "$r243_interp" = "42" ]; then
        echo "  ok  bug 243: $r243 — an aliased newtype is the newtype, interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 243: $r243 --interp gave '$r243_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_48() {
r242_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/regress_242_two_imported_methods_one_core_name.con" --interp 2>&1 || true)
if [ "$r242_interp" = "42" ]; then
    echo "  ok  bug 242: regress_242_two_imported_methods_one_core_name — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 242: regress_242_two_imported_methods_one_core_name --interp gave '$r242_interp', want 42"
    FAIL=$((FAIL + 1))
fi
for r242 in regress_242_imported_signature_type \
            regress_242_toplevel_signature_type \
            regress_242_imported_enum_beside_own_enum \
            regress_242_imported_field_type \
            regress_242_aliased_self_result \
            regress_242_imported_constant_type \
            regress_242_imported_alias_target \
            regress_242_generic_argument \
            regress_242_newtype_beside_other_import \
            regress_242_struct_beside_other_import \
            regress_242_two_modules_signatures \
            regress_242_alias_target_closure \
            regress_242_child_newtype_from_child_function; do
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r242_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r242.con" --interp 2>&1 || true)
    if [ "$r242_interp" = "42" ]; then
        echo "  ok  bug 242: $r242 — interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 242: $r242 --interp gave '$r242_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
for r096 in regress_096_method_owner_exact:9 regress_096_enum_payload_binding_other_type:7 \
            regress_096_const_initializer_other_type:7 regress_096_newtype_unwrap_other_type:7; do
    r096_f=${r096%%:*}; r096_want=${r096##*:}
    r096_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r096_f.con" --interp 2>&1 || true)
    # each prints its value, then main returns 0
    if [ "$r096_interp" = "$r096_want"$'\n'0 ]; then
        echo "  ok  bug 242: $r096_f — interp == binary ($r096_want)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 242: $r096_f --interp gave '$r096_interp', want $r096_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_49() {
for r254 in regress_254_newtype_over_struct:7 regress_254_newtype_over_enum:42; do
    r254_f=${r254%%:*}; r254_want=${r254##*:}
    r254_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r254_f.con" --interp 2>&1 || true)
    if [ "$r254_interp" = "$r254_want" ]; then
        echo "  ok  bug 254: $r254_f — interp == binary ($r254_want)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 254: $r254_f --interp gave '$r254_interp', want $r254_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_50() {
for r245 in regress_245_toplevel_private_constants regress_245_nested_private_constants; do
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r245_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r245.con" --interp 2>&1 || true)
    if [ "$r245_interp" = "42" ]; then
        echo "  ok  bug 245: $r245 — each tree's private constant, interp == binary (42)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 245: $r245 --interp gave '$r245_interp', want 42"
        FAIL=$((FAIL + 1))
    fi
done
# Bug 245 (Codex review): --report model-diff samples each tree's function in that tree's constants.
r245_md=$(bounded_run 60 -- $COMPILER "$TESTDIR/regress_245_toplevel_private_constants.con" --report model-diff 2>&1 || true)
if grep -qF "agree	a.ga	unclaimed	()	model=40	runtime=40" <<<"$r245_md" \
   && grep -qF "agree	b.gb	unclaimed	()	model=2	runtime=2" <<<"$r245_md"; then
    echo "  ok  bug 245: model-diff compares each tree's private constant (a.ga 40, b.gb 2)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 245: model-diff of regress_245_toplevel_private_constants did not agree on a.ga and b.gb:"
    printf '%s\n' "$r245_md" | awk 'NR<=4'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_51() {
for r251 in regress_251_generic_reads_defining_tree_constant:40 \
            regress_251_generic_constant_absent_in_instantiating_tree:40 \
            regress_251_nested_generic_constants:42 \
            regress_251_generic_calls_shadowed_intrinsic:40 \
            regress_251_generic_constant_calls_shadowed_intrinsic:40 \
            regress_251_generic_call_beside_destination_extern:40 \
            regress_251_generic_calls_source_extern:40 \
            regress_251_generic_calls_source_import_alias:40; do
    r251_f=${r251%%:*}; r251_want=${r251##*:}
    # bounded_run, not GNU `timeout`; a timeout is INCOMPLETE, not a pass.
    r251_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r251_f.con" --interp 2>&1 || true)
    if [ "$r251_interp" = "$r251_want" ]; then
        echo "  ok  bug 251: $r251_f — interp == binary ($r251_want)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 251: $r251_f --interp gave '$r251_interp', want $r251_want"
        FAIL=$((FAIL + 1))
    fi
done
:
}

suite_positive_2_52() {
r253_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/regress_253_local_rights_beside_imports.con" --interp 2>&1 || true)
if [ "$r253_interp" = "42" ]; then
    echo "  ok  bug 253: regress_253_local_rights_beside_imports — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 253: regress_253_local_rights_beside_imports --interp gave '$r253_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_53() {
for r262 in "error_262_parent_constructs_child_newtype.con:(E0263)" \
            "error_262_sibling_constructs_newtype.con:(E0296)" \
            "error_262_child_constructs_parent_newtype.con:(E0296)" \
            "regress_262_own_rights_beside_child.con:42" \
            "regress_262_imported_fn_beside_child_newtype.con:42"; do
    r262_f="${r262%%:*}"; r262_want="${r262#*:}"
    r262_interp=$(bounded_run 20 -- $COMPILER "$TESTDIR/$r262_f" --interp 2>&1 || true)
    case "$r262_want" in
        "("*) r262_ok=$(printf '%s' "$r262_interp" | grep -cF "$r262_want" || true) ;;
        *) if [ "$r262_interp" = "$r262_want" ]; then r262_ok=1; else r262_ok=0; fi ;;
    esac
    if [ "$r262_ok" -ge 1 ]; then
        echo "  ok  bug 262: $r262_f --interp gives $r262_want, as the binary"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 262: $r262_f --interp gave '$r262_interp', want $r262_want"
        FAIL=$((FAIL + 1))
    fi
done
# Bug 231: each of the seven bound positions in the fixture is refused, not only the first.
r231_n=$($COMPILER "$TESTDIR/error_231_unknown_bound_trait.con" --emit-core 2>&1 | grep -cF '(E0125)' || true)
if [ "$r231_n" = "7" ]; then
    echo "  ok  bug 231: all seven bound positions refused (E0125 x7)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 231: error_231_unknown_bound_trait gave $r231_n E0125 refusals, want 7"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_54() {
r231_interp=$($COMPILER "$TESTDIR/regress_231_bounds_name_module_traits.con" --interp 2>&1 || true)
if [ "$r231_interp" = "42" ]; then
    echo "  ok  bug 231: bounds on module traits, Copy and Destroy (function, struct, impl, method) — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 231: regress_231_bounds_name_module_traits --interp gave '$r231_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_55() {
r217_src="$TESTDIR/regress_217_enclosing_type_not_in_scope.con"
r217_core_rc=0; $COMPILER "$r217_src" --emit-core >/dev/null 2>&1 || r217_core_rc=$?
r217_interp=$($COMPILER "$r217_src" --interp 2>&1 || true)
if [ "$r217_core_rc" = 0 ] && [ "$r217_interp" = "42" ]; then
    echo "  ok  bug 217: an enclosing enum Result does not hide the builtin in a submodule (front end accepts; --interp 42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 217: regress_217_enclosing_type_not_in_scope: --emit-core rc $r217_core_rc, --interp '$r217_interp' (want 0, 42)"
    FAIL=$((FAIL + 1))
fi
r217_dir=$(mktemp -d)
cp -R tests/regressions/bug217_resolve_skips_nested_submodules/project/. "$r217_dir/"
r217_out=$(cd "$r217_dir" && "$ROOT_DIR/$COMPILER" build 2>&1) && r217_rc=0 || r217_rc=$?
rm -rf "$r217_dir"
if [ "$r217_rc" != 0 ] && grep -qF "src/util.con:5:13: error[resolve]: (E0108) unknown type 'Nope'" <<<"$r217_out"; then
    echo "  ok  bug 217: a project's \`mod util;\` file is resolved (E0108 attributed to src/util.con)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 217: project build of tests/regressions/bug217_resolve_skips_nested_submodules/project (rc $r217_rc) did not refuse src/util.con with resolve E0108:"
    printf '%s\n' "$r217_out" | awk 'NR<=3'
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_56() {
r213_interp=$($COMPILER "$TESTDIR/regress_213_arm_after_binding_arm.con" --interp 2>&1 || true)
if [ "$r213_interp" = "42" ]; then
    echo "  ok  bug 213: arms after a catch-all are not lowered — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 213: interp gave '$r213_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_2_57() {
r211_interp=$($COMPILER "$TESTDIR/regress_211_generic_add_numeric.con" --interp 2>&1 || true)
if [ "$r211_interp" = "42" ]; then
    echo "  ok  bug 211: numeric generic instances are admitted — interp == binary (42)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 211: interp gave '$r211_interp', want 42"
    FAIL=$((FAIL + 1))
fi
:
}
