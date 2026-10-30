# fixedcap: the code units of tests/cases/fixedcap.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_fixedcap_1() {
fc_pass=0
fc_fail=0

FC_SRC="examples/fixed_capacity/src/main.con"
FC_DIR="$ROOT_DIR/examples/fixed_capacity"

# 1. Fixed-capacity example compiles with predictable policy
fc_build_out=$( cd "$FC_DIR" && "$ROOT_DIR/$COMPILER" build 2>&1 ) && fc_build_ok=true || fc_build_ok=false
if $fc_build_ok; then
    echo "  ok  fixedcap: builds with predictable=true policy"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: should build with predictable=true policy"
    echo "       $fc_build_out"
    fc_fail=$((fc_fail + 1))
fi

# 2. Fixed-capacity example runs and all tests pass (exit 0)
if $fc_build_ok; then
    fc_run_out=$( "$FC_DIR/fixed_capacity" 2>&1 ) && fc_run_exit=0 || fc_run_exit=$?
    if [ "$fc_run_exit" -eq 0 ] && grep <<<"$fc_run_out" -q "All 8 tests passed"; then
        echo "  ok  fixedcap: runs with all 8 tests passing"
        fc_pass=$((fc_pass + 1))
    else
        echo "  FAIL fixedcap: should run with all 8 tests passing (exit=$fc_run_exit)"
        fc_fail=$((fc_fail + 1))
    fi
else
    echo "  SKIP fixedcap: run (build failed)"
    fc_fail=$((fc_fail + 1))
fi

# 3. All functions pass --check predictable
fc_pred=$("$COMPILER" "$FC_SRC" --check predictable 2>&1) && fc_pred_exit=0 || fc_pred_exit=$?
if [ "$fc_pred_exit" -eq 0 ] && grep <<<"$fc_pred" -q "pass"; then
    echo "  ok  fixedcap: all functions pass --check predictable"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: should pass --check predictable"
    fc_fail=$((fc_fail + 1))
fi

# 4. Pure validation functions have evidence=enforced (not trusted)
fc_effects=$("$COMPILER" "$FC_SRC" --report effects 2>&1)
pure_enforced=true
for fn in validate_version validate_msg_type validate_payload_len validate_total_len validate_tag; do
    if ! grep <<<"$fc_effects" -A1 "$fn" | has_match "evidence: enforced"; then
        pure_enforced=false
    fi
done
if $pure_enforced; then
    echo "  ok  fixedcap: pure validators have evidence=enforced"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: pure validators should have evidence=enforced"
    fc_fail=$((fc_fail + 1))
fi

# 5. Pure validation functions are not trusted
pure_not_trusted=true
for fn in validate_version validate_msg_type validate_payload_len validate_total_len validate_tag; do
    if grep <<<"$fc_effects" -A1 "$fn" | has_match "trusted: yes"; then
        pure_not_trusted=false
    fi
done
if $pure_not_trusted; then
    echo "  ok  fixedcap: pure validators are not trusted"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: pure validators should not be trusted"
    fc_fail=$((fc_fail + 1))
fi

# 6. Only test-packet builders are trusted (build_msg, build_bad_version, build_bad_type, build_payload_overflow)
trusted_ok=true
for fn in build_msg build_bad_version build_bad_type build_payload_overflow; do
    if ! grep <<<"$fc_effects" -A1 "$fn" | has_match "trusted: yes"; then
        trusted_ok=false
    fi
done
# Validation core must NOT be trusted
for fn in read_u8 read_u16_be ring_contains ring_push compute_tag validate_message; do
    if grep <<<"$fc_effects" -A1 "$fn" | has_match "trusted: yes"; then
        trusted_ok=false
    fi
done
if $trusted_ok; then
    echo "  ok  fixedcap: only test-packet builders are trusted"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: only test-packet builders should be trusted"
    fc_fail=$((fc_fail + 1))
fi

# 7. Ring buffer loop is bounded
if grep <<<"$fc_effects" -A1 "ring_contains" | has_match "loops: bounded"; then
    echo "  ok  fixedcap: ring buffer scan has bounded loops"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: ring buffer scan should have bounded loops"
    fc_fail=$((fc_fail + 1))
fi

# 8. Zero allocation in all functions
if ! grep <<<"$fc_effects" -v "^$" | grep "alloc:" | grep -v "alloc: none" | has_match .; then
    echo "  ok  fixedcap: zero allocation across all functions"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: should have zero allocation"
    fc_fail=$((fc_fail + 1))
fi

# 9. Extraction report shows pure validators as proof-eligible.
# Since struct-literal + if-without-else extraction landed (e2ab5eef) the
# validators now fully EXTRACT (a strict superset of "eligible") — accept either.
fc_extract=$("$COMPILER" "$FC_SRC" --report extraction 2>&1)
if grep <<<"$fc_extract" -A2 "validate_version" | has_match -E "eligible|extracted"; then
    echo "  ok  fixedcap: pure validators are proof-eligible"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: pure validators should be proof-eligible"
    fc_fail=$((fc_fail + 1))
fi

# 10. Struct literal + if-without-else became proof-EXTRACTABLE (e2ab5eef), so
# the former "known gaps" are closed: the validators that use them now extract
# and the example has zero eligible-but-not-extractable functions.
if grep <<<"$fc_extract" -q "0 eligible but not extractable"; then
    echo "  ok  fixedcap: struct-literal/if-without-else gaps closed (0 not-extractable)"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: extraction should show struct-literal/if-without-else gaps closed"
    fc_fail=$((fc_fail + 1))
fi

# 11. Concrete.toml has predictable policy (whitespace-insensitive: the toml
# aligns values with padding, e.g. `predictable            = true`).
if grep -qE 'predictable[[:space:]]*=[[:space:]]*true' "$FC_DIR/Concrete.toml"; then
    echo "  ok  fixedcap: Concrete.toml declares predictable=true"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: Concrete.toml should declare predictable=true"
    fc_fail=$((fc_fail + 1))
fi

# 12. No capabilities on validation core (pure functions)
pure_caps=true
for fn in validate_version validate_msg_type validate_payload_len validate_total_len validate_tag ok_result err_result; do
    if ! grep <<<"$fc_effects" -A1 "$fn" | has_match "caps: (no external authority)"; then
        pure_caps=false
    fi
done
if $pure_caps; then
    echo "  ok  fixedcap: validation core is capability-free (pure)"
    fc_pass=$((fc_pass + 1))
else
    echo "  FAIL fixedcap: validation core should be capability-free"
    fc_fail=$((fc_fail + 1))
fi

echo "  $fc_pass fixedcap gates passed"
PASS=$((PASS + fc_pass))
FAIL=$((FAIL + fc_fail))
:
}
