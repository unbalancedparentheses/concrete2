# errorcodes: the code units of tests/cases/errorcodes.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_errorcodes_1() {
ec_pass=0
ec_fail=0

# 1. --report diagnostic-codes outputs valid JSON with all expected fields
dc_out=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostic-codes 2>/dev/null)
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['schema_version'] == 2
assert d['code_count'] >= 170
assert d['code_count'] == len(d['codes'])
assert 'severity_meanings' in d
assert 'compatibility' in d
" <<< "$dc_out" 2>/dev/null; then
    echo "  ok  error-codes: --report diagnostic-codes has expected structure"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: --report diagnostic-codes should have expected structure"
    ec_fail=$((ec_fail + 1))
fi

# 2. All codes have required fields
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for c in d['codes']:
    assert 'code' in c and 'pass' in c and 'severity' in c and 'description' in c, f'missing field in {c}'
    assert c['code'].startswith('E'), f'code should start with E: {c[\"code\"]}'
    assert c['severity'] in ('error', 'warning', 'info', 'note'), f'bad severity: {c[\"severity\"]}'
" <<< "$dc_out" 2>/dev/null; then
    echo "  ok  error-codes: all codes have required fields and valid values"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: codes should have code, pass, severity, description"
    ec_fail=$((ec_fail + 1))
fi

# 3. No duplicate codes
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
codes = [c['code'] for c in d['codes']]
assert len(codes) == len(set(codes)), f'duplicate codes: {[c for c in codes if codes.count(c) > 1]}'
" <<< "$dc_out" 2>/dev/null; then
    echo "  ok  error-codes: no duplicate error codes"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: should have no duplicate codes"
    ec_fail=$((ec_fail + 1))
fi

# 4. Codes cover all passes
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
passes = set(c['pass'] for c in d['codes'])
expected = {'parse', 'resolve', 'check', 'elab', 'core-check', 'verify', 'lower', 'policy', 'ssa-verify', 'proof'}
assert expected.issubset(passes), f'missing passes: {expected - passes}'
" <<< "$dc_out" 2>/dev/null; then
    echo "  ok  error-codes: codes cover all compiler passes"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: codes should cover all passes"
    ec_fail=$((ec_fail + 1))
fi

# 5. Rendered diagnostic includes error code
err_out=$($COMPILER "$TESTDIR/error_resolve_undeclared_span.con" 2>&1) || true
if grep <<<"$err_out" -q '(E0100)'; then
    echo "  ok  error-codes: rendered diagnostic includes error code"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: rendered diagnostic should include error code"
    echo "$err_out" | awk "NR==1"
    ec_fail=$((ec_fail + 1))
fi

# 6. Proof diagnostic JSON fact includes code field
pd_out=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)
if grep <<<"$pd_out" -q '"code": "E080'; then
    echo "  ok  error-codes: proof_diagnostic fact includes code field"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: proof_diagnostic fact should include code field"
    ec_fail=$((ec_fail + 1))
fi

# 7. Codes are deterministic across runs
dc_out2=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostic-codes 2>/dev/null)
if [ "$dc_out" = "$dc_out2" ]; then
    echo "  ok  error-codes: diagnostic-codes output is deterministic"
    ec_pass=$((ec_pass + 1))
else
    echo "FAIL  error-codes: diagnostic-codes should be deterministic across runs"
    ec_fail=$((ec_fail + 1))
fi

echo "  $ec_pass error code gates passed"
PASS=$((PASS + ec_pass))
FAIL=$((FAIL + ec_fail))
:
}
