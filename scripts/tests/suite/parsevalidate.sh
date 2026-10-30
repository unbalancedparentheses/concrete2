# parsevalidate: the code units of tests/cases/parsevalidate.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_parsevalidate_1() {
pv_pass=0
pv_fail=0

PV_SRC="examples/parse_validate/src/main.con"
PV_DIR="$ROOT_DIR/examples/parse_validate"

# 1. Builds with predictable=true policy
pv_build_out=$( cd "$PV_DIR" && "$ROOT_DIR/$COMPILER" build 2>&1 ) && pv_build_ok=true || pv_build_ok=false
if $pv_build_ok; then
    echo "  ok  parsevalidate: builds with predictable=true policy"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: should build with predictable=true policy"
    echo "       $pv_build_out"
    pv_fail=$((pv_fail + 1))
fi

# 2. Runs and all 8 tests pass (exit 0)
if $pv_build_ok; then
    pv_run_exit=0
    "$PV_DIR/parse_validate" 2>&1 || pv_run_exit=$?
    if [ "$pv_run_exit" -eq 0 ]; then
        echo "  ok  parsevalidate: runs with all 8 tests passing (exit 0)"
        pv_pass=$((pv_pass + 1))
    else
        echo "  FAIL parsevalidate: should exit 0, got $pv_run_exit"
        pv_fail=$((pv_fail + 1))
    fi
else
    echo "  SKIP parsevalidate: run (build failed)"
    pv_fail=$((pv_fail + 1))
fi

# 3. All functions pass --check predictable
pv_pred=$("$COMPILER" "$PV_SRC" --check predictable 2>&1) && pv_pred_exit=0 || pv_pred_exit=$?
if [ "$pv_pred_exit" -eq 0 ] && grep <<<"$pv_pred" -q "pass"; then
    echo "  ok  parsevalidate: all functions pass --check predictable"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: should pass --check predictable"
    pv_fail=$((pv_fail + 1))
fi

# 4. All 10 functions are pure with real evidence (proved or enforced, none merely
# reported). Three validators became `proved` once struct-literal/if-without-else
# extraction landed (e2ab5eef); the remainder stay `enforced`. The "0 reported"
# check is the invariant: every pure function carries enforced-or-stronger evidence.
pv_effects=$("$COMPILER" "$PV_SRC" --report effects 2>&1)
if grep <<<"$pv_effects" -q "10 with no external authority" && grep <<<"$pv_effects" -q "0 reported"; then
    echo "  ok  parsevalidate: all 10 functions are pure with evidence (proved/enforced)"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: all 10 functions should be pure with evidence (proved/enforced)"
    pv_fail=$((pv_fail + 1))
fi

# 5. Zero trusted functions
if grep <<<"$pv_effects" -q "0 trusted"; then
    echo "  ok  parsevalidate: zero trusted functions"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: should have zero trusted functions"
    pv_fail=$((pv_fail + 1))
fi

# 6. Zero allocation across all functions
if ! grep <<<"$pv_effects" -v "^$" | grep "alloc:" | grep -v "alloc: none" | has_match .; then
    echo "  ok  parsevalidate: zero allocation across all functions"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: should have zero allocation"
    pv_fail=$((pv_fail + 1))
fi

# 7. ParseError enum and Result<Header, ParseError> compile
if grep <<<"$pv_effects" -q "parse_header" && grep <<<"$pv_effects" -q "error_code"; then
    echo "  ok  parsevalidate: ParseError enum and stdlib Result work"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: ParseError and Result should compile and appear in effects"
    pv_fail=$((pv_fail + 1))
fi

# 8. compute_checksum has bounded loop (the only loop in the example)
if grep <<<"$pv_effects" -A1 "compute_checksum" | has_match "loops: bounded"; then
    echo "  ok  parsevalidate: compute_checksum has bounded loop"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: compute_checksum should have bounded loop"
    pv_fail=$((pv_fail + 1))
fi

# 9. Concrete.toml has predictable policy
if grep -qE 'predictable[[:space:]]*=[[:space:]]*true' "$PV_DIR/Concrete.toml"; then
    echo "  ok  parsevalidate: Concrete.toml declares predictable=true"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: Concrete.toml should declare predictable=true"
    pv_fail=$((pv_fail + 1))
fi

# 10. All core validators are capability-free (pure)
pv_pure_caps=true
for fn in validate_version validate_msg_type validate_payload_len validate_total_len validate_checksum compute_checksum parse_header error_code; do
    if ! grep <<<"$pv_effects" -A1 "$fn" | has_match "caps: (no external authority)"; then
        pv_pure_caps=false
    fi
done
if $pv_pure_caps; then
    echo "  ok  parsevalidate: all core functions are capability-free (pure)"
    pv_pass=$((pv_pass + 1))
else
    echo "  FAIL parsevalidate: all core functions should be capability-free"
    pv_fail=$((pv_fail + 1))
fi

echo "  $pv_pass parsevalidate gates passed"
PASS=$((PASS + pv_pass))
FAIL=$((FAIL + pv_fail))
:
}
