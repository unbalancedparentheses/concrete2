# serviceerrors: the code units of tests/cases/serviceerrors.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_serviceerrors_1() {
se_pass=0
se_fail=0

SE_SRC="examples/service_errors/src/main.con"
SE_DIR="$ROOT_DIR/examples/service_errors"

# 1. Builds with predictable=true policy
se_build_out=$( cd "$SE_DIR" && "$ROOT_DIR/$COMPILER" build 2>&1 ) && se_build_ok=true || se_build_ok=false
if $se_build_ok; then
    echo "  ok  serviceerrors: builds with predictable=true policy"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: should build with predictable=true policy"
    echo "       $se_build_out"
    se_fail=$((se_fail + 1))
fi

# 2. Runs and all 9 tests pass (exit 0)
if $se_build_ok; then
    se_run_exit=0
    "$SE_DIR/service_errors" 2>&1 || se_run_exit=$?
    if [ "$se_run_exit" -eq 0 ]; then
        echo "  ok  serviceerrors: runs with all 9 tests passing (exit 0)"
        se_pass=$((se_pass + 1))
    else
        echo "  FAIL serviceerrors: should exit 0, got $se_run_exit"
        se_fail=$((se_fail + 1))
    fi
else
    echo "  SKIP serviceerrors: run (build failed)"
    se_fail=$((se_fail + 1))
fi

# 3. All functions pass --check predictable
se_pred=$("$COMPILER" "$SE_SRC" --check predictable 2>&1) && se_pred_exit=0 || se_pred_exit=$?
if [ "$se_pred_exit" -eq 0 ] && grep <<<"$se_pred" -q "pass"; then
    echo "  ok  serviceerrors: all functions pass --check predictable"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: should pass --check predictable"
    se_fail=$((se_fail + 1))
fi

# 4. All 12 functions are pure with evidence=enforced
se_effects=$("$COMPILER" "$SE_SRC" --report effects 2>&1)
if grep <<<"$se_effects" -q "12 with no external authority" && grep <<<"$se_effects" -q "12 enforced"; then
    echo "  ok  serviceerrors: all 12 functions are pure with evidence=enforced"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: all 12 functions should be pure with evidence=enforced"
    se_fail=$((se_fail + 1))
fi

# 5. Zero trusted functions
if grep <<<"$se_effects" -q "0 trusted"; then
    echo "  ok  serviceerrors: zero trusted functions"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: should have zero trusted functions"
    se_fail=$((se_fail + 1))
fi

# 6. Zero allocation across all functions
if ! grep <<<"$se_effects" -v "^$" | grep "alloc:" | grep -v "alloc: none" | has_match .; then
    echo "  ok  serviceerrors: zero allocation across all functions"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: should have zero allocation"
    se_fail=$((se_fail + 1))
fi

# 7. Custom error enums compile and appear in effects
if grep <<<"$se_effects" -q "validate_error_code" && grep <<<"$se_effects" -q "auth_error_code" && grep <<<"$se_effects" -q "rate_error_code"; then
    echo "  ok  serviceerrors: stage-specific error code functions exist"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: stage-specific error code functions should appear in effects"
    se_fail=$((se_fail + 1))
fi

# 8. Pipeline handler functions exist (handle_request, handle_validated, handle_authorized)
if grep <<<"$se_effects" -q "handle_request" && grep <<<"$se_effects" -q "handle_validated" && grep <<<"$se_effects" -q "handle_authorized"; then
    echo "  ok  serviceerrors: 3-stage pipeline handler functions exist"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: pipeline handler functions should appear in effects"
    se_fail=$((se_fail + 1))
fi

# 9. Concrete.toml has predictable policy
if grep -qE 'predictable[[:space:]]*=[[:space:]]*true' "$SE_DIR/Concrete.toml"; then
    echo "  ok  serviceerrors: Concrete.toml declares predictable=true"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: Concrete.toml should declare predictable=true"
    se_fail=$((se_fail + 1))
fi

# 10. All core functions are capability-free (pure)
se_pure_caps=true
for fn in validate authorize check_rate_limit process_action handle_request handle_validated handle_authorized service_error_code; do
    if ! grep <<<"$se_effects" -A1 "$fn" | has_match "caps: (no external authority)"; then
        se_pure_caps=false
    fi
done
if $se_pure_caps; then
    echo "  ok  serviceerrors: all core functions are capability-free (pure)"
    se_pass=$((se_pass + 1))
else
    echo "  FAIL serviceerrors: all core functions should be capability-free"
    se_fail=$((se_fail + 1))
fi

echo "  $se_pass serviceerrors gates passed"
PASS=$((PASS + se_pass))
FAIL=$((FAIL + se_fail))
:
}
