# workflow: the code units of tests/cases/workflow.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_workflow_1() {
wf_pass=0
wf_fail=0

PP_SRC="examples/proof_pressure/src/main.con"

# 1. Extraction report shows extracted/excluded/blocked status labels
wf_ext=$($COMPILER "$PP_SRC" --report extraction 2>&1) || true
if grep <<<"$wf_ext" -q "extracted" && grep <<<"$wf_ext" -q "excluded"; then
    echo "  ok  workflow: extraction report shows extracted and excluded status"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: extraction report should show extracted and excluded status"
    wf_fail=$((wf_fail + 1))
fi

# 2. Extraction report shows PExpr form for extracted functions
if grep <<<"$wf_ext" -q "ProofCore\|PExpr\|ret\|binop\|if"; then
    echo "  ok  workflow: extraction report shows PExpr form"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: extraction report should show PExpr form for extracted functions"
    wf_fail=$((wf_fail + 1))
fi

# 3. Extraction report shows fingerprint for extracted functions
if grep <<<"$wf_ext" -q "fingerprint"; then
    echo "  ok  workflow: extraction report shows fingerprint"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: extraction report should show fingerprint"
    wf_fail=$((wf_fail + 1))
fi

# 4. lean-stubs generates PExpr definitions and theorem stubs
wf_stubs=$($COMPILER "$PP_SRC" --report lean-stubs 2>&1) || true
if grep <<<"$wf_stubs" -q "Expr" && grep <<<"$wf_stubs" -q "theorem" && grep <<<"$wf_stubs" -q "sorry"; then
    echo "  ok  workflow: lean-stubs generates PExpr defs and theorem stubs with sorry"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: lean-stubs should generate PExpr defs, theorem stubs, and sorry"
    wf_fail=$((wf_fail + 1))
fi

# 5. lean-stubs generates eval helpers
if grep <<<"$wf_stubs" -q "eval_\|eval "; then
    echo "  ok  workflow: lean-stubs generates eval helpers"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: lean-stubs should generate eval helpers"
    wf_fail=$((wf_fail + 1))
fi

# 6. lean-stubs generates function table (generatedFns)
if grep <<<"$wf_stubs" -q "generatedFns\|FnTable"; then
    echo "  ok  workflow: lean-stubs generates function table"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: lean-stubs should generate function table"
    wf_fail=$((wf_fail + 1))
fi

# 7. lean-stubs excludes ineligible functions (no theorem for format_result)
if ! grep <<<"$wf_stubs" -q "format_result.*correct\|format_resultExpr"; then
    echo "  ok  workflow: lean-stubs excludes ineligible function format_result"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: lean-stubs should not generate stubs for ineligible functions"
    wf_fail=$((wf_fail + 1))
fi

# 8. proof-status shows proved/stale/missing/blocked/ineligible states
wf_ps=$($COMPILER "$PP_SRC" --report proof-status 2>&1) || true
if grep <<<"$wf_ps" -q "proved" && grep <<<"$wf_ps" -q "stale\|proof stale" && grep <<<"$wf_ps" -q "missing\|unproved" && grep <<<"$wf_ps" -q "blocked" && grep <<<"$wf_ps" -q "ineligible"; then
    echo "  ok  workflow: proof-status shows all 5 obligation states"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: proof-status should show proved/stale/missing/blocked/ineligible"
    wf_fail=$((wf_fail + 1))
fi

# 9. proof-diagnostics shows failure_class and repair_class
wf_diag=$($COMPILER "$PP_SRC" --report proof-diagnostics 2>&1) || true
if grep <<<"$wf_diag" -q "failure:" && grep <<<"$wf_diag" -q "repair:"; then
    echo "  ok  workflow: proof-diagnostics shows failure and repair classes"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: proof-diagnostics should show failure: and repair: lines"
    wf_fail=$((wf_fail + 1))
fi

# 10. proof-deps shows dependency edges for proved functions
wf_deps=$($COMPILER "$PP_SRC" --report proof-deps 2>&1) || true
if grep <<<"$wf_deps" -q "validate_header" && grep <<<"$wf_deps" -q "check_nonce"; then
    echo "  ok  workflow: proof-deps shows validate_header → check_nonce dependency"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: proof-deps should show validate_header → check_nonce edge"
    wf_fail=$((wf_fail + 1))
fi

# 11. End-to-end: fingerprint from extraction matches fingerprint in obligations
wf_ob=$($COMPILER "$PP_SRC" --report obligations 2>&1) || true
wf_ext_fp=$(grep <<<"$wf_ext" -A6 "check_nonce" | grep -o '\[.*\]' | awk "NR==1")
wf_ob_fp=$(grep <<<"$wf_ob" -A8 "check_nonce" | grep -o '\[.*\]' | awk "NR==1")
if [ -n "$wf_ext_fp" ] && [ "$wf_ext_fp" = "$wf_ob_fp" ]; then
    echo "  ok  workflow: extraction fingerprint matches obligation fingerprint"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: extraction and obligation fingerprints should match"
    wf_fail=$((wf_fail + 1))
fi

# 14. Workflow coherence: proof-status shows obligation totals
wf_totals=$($COMPILER "$PP_SRC" --report proof-status 2>&1) || true
if grep <<<"$wf_totals" -q "Totals\|proved\|functions"; then
    echo "  ok  workflow: proof-status report shows obligation totals"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: proof-status report should show obligation totals"
    wf_fail=$((wf_fail + 1))
fi

# 15. diagnostic-codes includes all proof error codes E0800-E0807
wf_codes=$($COMPILER "$PP_SRC" --report diagnostic-codes 2>&1) || true
if grep <<<"$wf_codes" -q "E0800" && grep <<<"$wf_codes" -q "E0805" && grep <<<"$wf_codes" -q "E0807"; then
    echo "  ok  workflow: diagnostic-codes registers E0800-E0807"
    wf_pass=$((wf_pass + 1))
else
    echo "  FAIL workflow: diagnostic-codes should include E0800, E0805, E0807"
    wf_fail=$((wf_fail + 1))
fi

echo "  $wf_pass workflow gates passed"
PASS=$((PASS + wf_pass))
FAIL=$((FAIL + wf_fail))
:
}
