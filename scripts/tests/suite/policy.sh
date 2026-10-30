# policy: the code units of tests/cases/policy.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_policy_1() {
pol_pass=0
pol_fail=0
ROOT_DIR_ABS=$(cd "$(dirname "$0")/../.." && pwd)

# Helper: policy project must fail with expected error
policy_err() {
    local projdir="$1"
    local expected="$2"
    local label="$3"
    local projname
    projname=$(basename "$projdir")
    local output
    output=$( cd "$projdir" && "$ROOT_DIR_ABS/$COMPILER" build 2>&1 ) && build_exit=0 || build_exit=$?
    if [ "$build_exit" -ne 0 ] && grep <<<"$output" -qF -- "$expected"; then
        echo "  ok  policy: $label"
        pol_pass=$((pol_pass + 1))
    else
        echo "  FAIL policy: $label (exit=$build_exit)"
        echo "    expected: $expected"
        echo "    got: $(echo "$output" | awk "NR<=2")"
        pol_fail=$((pol_fail + 1))
    fi
}

# Helper: policy project must compile and run successfully
policy_ok() {
    local projdir="$1"
    local label="$2"
    local projname
    projname=$(basename "$projdir")
    local output
    output=$( cd "$projdir" && "$ROOT_DIR_ABS/$COMPILER" build -o "$TMPDIR/test_pol_""$projname" 2>&1 ) && build_ok=true || build_ok=false
    if $build_ok; then
        local run_result
        run_result=$("$TMPDIR/test_pol_""$projname" 2>&1) && run_exit=0 || run_exit=$?
        rm -f "$TMPDIR/test_pol_""$projname"
        if [ "$run_exit" -eq 0 ]; then
            echo "  ok  policy: $label"
            pol_pass=$((pol_pass + 1))
        else
            echo "  FAIL policy: $label — run exit $run_exit"
            pol_fail=$((pol_fail + 1))
        fi
    else
        echo "  FAIL policy: $label — build failed: $(echo "$output" | awk "NR<=2")"
        pol_fail=$((pol_fail + 1))
    fi
}
:
}

suite_policy_2() {

# --- Positive boundary: legal code under policy must pass ---

# 11. deny = ["Unsafe"] allows safe caps (Console)
policy_ok "$TESTDIR/adversarial_policy_deny_pass" \
    "deny allows safe caps (boundary)"

# 12. predictable = true allows pure bounded code
policy_ok "$TESTDIR/adversarial_policy_predictable_pass" \
    "predictable allows pure code (boundary)"

# 13. Empty [policy] section imposes no restrictions
policy_ok "$TESTDIR/adversarial_policy_empty" \
    "empty policy allows everything (boundary)"

# --- Standalone predictable boundary adversarial tests ---

# 14. Direct recursion fails predictable
pred_direct=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_direct_recursion.con" --check predictable 2>&1) && pred_direct_exit=0 || pred_direct_exit=$?
if [ "$pred_direct_exit" -ne 0 ] && grep <<<"$pred_direct" -q "direct recursion"; then
    echo "  ok  policy: direct recursion fails predictable"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: direct recursion should fail predictable"
    pol_fail=$((pol_fail + 1))
fi

# 15. Mutual recursion fails predictable
pred_mutual=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_mutual_recursion.con" --check predictable 2>&1) && pred_mutual_exit=0 || pred_mutual_exit=$?
if [ "$pred_mutual_exit" -ne 0 ] && grep <<<"$pred_mutual" -q "mutual recursion"; then
    echo "  ok  policy: mutual recursion fails predictable"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: mutual recursion should fail predictable"
    pol_fail=$((pol_fail + 1))
fi

# 16. Hidden allocation (3-level chain) fails predictable
pred_alloc=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_hidden_alloc.con" --check predictable 2>&1) && pred_alloc_exit=0 || pred_alloc_exit=$?
if [ "$pred_alloc_exit" -ne 0 ] && grep <<<"$pred_alloc" -q "Alloc capability"; then
    echo "  ok  policy: hidden alloc chain fails predictable"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: hidden alloc chain should fail predictable"
    pol_fail=$((pol_fail + 1))
fi

# 17. Nested match (pure) passes predictable
pred_match=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_nested_match.con" --check predictable 2>&1) && pred_match_exit=0 || pred_match_exit=$?
if [ "$pred_match_exit" -eq 0 ] && grep <<<"$pred_match" -q "pass"; then
    echo "  ok  policy: deeply nested match passes predictable"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: deeply nested match should pass predictable"
    pol_fail=$((pol_fail + 1))
fi

# 18. Copy enum chain (pure) passes predictable
pred_chain=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_copy_enum_chain.con" --check predictable 2>&1) && pred_chain_exit=0 || pred_chain_exit=$?
if [ "$pred_chain_exit" -eq 0 ] && grep <<<"$pred_chain" -q "pass"; then
    echo "  ok  policy: Copy enum chain passes predictable"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: Copy enum chain should pass predictable"
    pol_fail=$((pol_fail + 1))
fi

# 19. While loop fails predictable (unbounded)
pred_while=$("$COMPILER" "$TESTDIR/adversarial_predict_bound_while_loop.con" --check predictable 2>&1) && pred_while_exit=0 || pred_while_exit=$?
if [ "$pred_while_exit" -ne 0 ] && grep <<<"$pred_while" -q "unbounded loop"; then
    echo "  ok  policy: while loop fails predictable (unbounded)"
    pol_pass=$((pol_pass + 1))
else
    echo "  FAIL policy: while loop should fail predictable"
    pol_fail=$((pol_fail + 1))
fi

echo "  $pol_pass policy gates passed"
PASS=$((PASS + pol_pass))
FAIL=$((FAIL + pol_fail))
:
}
