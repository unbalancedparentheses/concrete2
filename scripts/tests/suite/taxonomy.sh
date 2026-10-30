# taxonomy: the code units of tests/cases/taxonomy.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_taxonomy_1() {
tx_pass=0
tx_fail=0

# Use proof_pressure which has all 5 diagnostic kinds
PP_FILE="examples/proof_pressure/src/main.con"
tx_text=$($COMPILER "$PP_FILE" --report proof-diagnostics 2>/dev/null)
tx_json=$($COMPILER "$PP_FILE" --report diagnostics-json 2>/dev/null)

# 1. Text output: stale_proof shows failure: stale_proof, repair: theorem_update
if grep <<<"$tx_text" -A3 "compute_checksum" | has_match "failure:.*stale_proof" && \
   grep <<<"$tx_text" -A4 "compute_checksum" | has_match "repair:.*theorem_update"; then
    echo "  ok  taxonomy: stale_proof → failure=stale_proof, repair=theorem_update"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: stale_proof should map to failure=stale_proof, repair=theorem_update"
    tx_fail=$((tx_fail + 1))
fi

# 2. Text output: missing_proof shows failure: missing_proof, repair: add_proof
if grep <<<"$tx_text" -A3 "clamp_value" | has_match "failure:.*missing_proof" && \
   grep <<<"$tx_text" -A4 "clamp_value" | has_match "repair:.*add_proof"; then
    echo "  ok  taxonomy: missing_proof → failure=missing_proof, repair=add_proof"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: missing_proof should map to failure=missing_proof, repair=add_proof"
    tx_fail=$((tx_fail + 1))
fi

# 3. Text output: ineligible with capabilities shows failure: effect_boundary, repair: policy_change
if grep <<<"$tx_text" -A3 "format_result" | has_match "failure:.*effect_boundary" && \
   grep <<<"$tx_text" -A4 "format_result" | has_match "repair:.*policy_change"; then
    echo "  ok  taxonomy: ineligible+caps → failure=effect_boundary, repair=policy_change"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: ineligible+caps should map to failure=effect_boundary, repair=policy_change"
    tx_fail=$((tx_fail + 1))
fi

# 4. Text output: ineligible with entry point shows failure: entry_point, repair: none
if grep <<<"$tx_text" -A3 'main.*cannot be proved' | has_match "failure:.*entry_point" && \
   grep <<<"$tx_text" -A4 'main.*cannot be proved' | has_match "repair:.*none"; then
    echo "  ok  taxonomy: ineligible+entry_point → failure=entry_point, repair=none"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: ineligible+entry_point should map to failure=entry_point, repair=none"
    tx_fail=$((tx_fail + 1))
fi

# 5. Text output: unsupported_construct shows failure: unsupported_construct, repair: code_rewrite
if grep <<<"$tx_text" -A3 "classify_range" | has_match "failure:.*unsupported_construct" && \
   grep <<<"$tx_text" -A4 "classify_range" | has_match "repair:.*code_rewrite"; then
    echo "  ok  taxonomy: unsupported_construct → failure=unsupported_construct, repair=code_rewrite"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: unsupported_construct should map to failure=unsupported_construct, repair=code_rewrite"
    tx_fail=$((tx_fail + 1))
fi

# 6. JSON output: all 5 facts have failure_class and repair_class fields
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
proof_diags = [f for f in d['facts'] if f.get('kind') == 'proof_diagnostic']
assert len(proof_diags) >= 5, f'expected >=5 proof diagnostics, got {len(proof_diags)}'
for f in proof_diags:
    assert 'failure_class' in f, f'missing failure_class in {f[\"function\"]}'
    assert 'repair_class' in f, f'missing repair_class in {f[\"function\"]}'
    assert f['failure_class'] != '', f'empty failure_class in {f[\"function\"]}'
    assert f['repair_class'] != '', f'empty repair_class in {f[\"function\"]}'
" <<< "$tx_json" 2>/dev/null; then
    echo "  ok  taxonomy: JSON — all proof diagnostics have failure_class and repair_class"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: JSON proof diagnostics should have failure_class and repair_class"
    tx_fail=$((tx_fail + 1))
fi

# 7. JSON output: correct failure_class values for each function
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
# Group by (function, diagnostic_kind) to handle multiple diagnostics per function
diags = {(f['function'], f['diagnostic_kind']): f for f in d['facts'] if f.get('kind') == 'proof_diagnostic'}
assert diags[('main.compute_checksum', 'stale_proof')]['failure_class'] == 'stale_proof'
assert diags[('main.clamp_value', 'missing_proof')]['failure_class'] == 'missing_proof'
assert diags[('main.format_result', 'ineligible')]['failure_class'] == 'effect_boundary'
assert diags[('main.main', 'ineligible')]['failure_class'] == 'entry_point'
assert diags[('main.classify_range', 'unsupported_construct')]['failure_class'] == 'unsupported_construct'
" <<< "$tx_json" 2>/dev/null; then
    echo "  ok  taxonomy: JSON — failure_class values are correct per function"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: JSON — failure_class values are wrong"
    tx_fail=$((tx_fail + 1))
fi

# 8. JSON output: correct repair_class values for each function
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
diags = {(f['function'], f['diagnostic_kind']): f for f in d['facts'] if f.get('kind') == 'proof_diagnostic'}
assert diags[('main.compute_checksum', 'stale_proof')]['repair_class'] == 'theorem_update'
assert diags[('main.clamp_value', 'missing_proof')]['repair_class'] == 'add_proof'
assert diags[('main.format_result', 'ineligible')]['repair_class'] == 'policy_change'
assert diags[('main.main', 'ineligible')]['repair_class'] == 'none'
assert diags[('main.classify_range', 'unsupported_construct')]['repair_class'] == 'code_rewrite'
" <<< "$tx_json" 2>/dev/null; then
    echo "  ok  taxonomy: JSON — repair_class values are correct per function"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: JSON — repair_class values are wrong"
    tx_fail=$((tx_fail + 1))
fi

# 9. Schema includes failure_class and repair_class as required fields
schema_out=$($COMPILER "$PP_FILE" --report schema 2>/dev/null)
if grep <<<"$schema_out" -q "failure_class" && grep <<<"$schema_out" -q "repair_class"; then
    echo "  ok  taxonomy: schema includes failure_class and repair_class"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: schema should include failure_class and repair_class"
    tx_fail=$((tx_fail + 1))
fi

# 10. Failure classes are a closed set — no unexpected values
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
valid_failures = {'stale_proof', 'missing_proof', 'unsupported_construct', 'effect_boundary', 'structural_gate', 'entry_point', 'trusted_boundary', 'attachment_integrity', 'theorem_lookup', 'lean_check_failure'}
valid_repairs = {'theorem_update', 'add_proof', 'code_rewrite', 'policy_change', 'registry_update', 'none'}
for f in d['facts']:
    if f.get('kind') == 'proof_diagnostic':
        assert f['failure_class'] in valid_failures, f'unexpected failure_class: {f[\"failure_class\"]}'
        assert f['repair_class'] in valid_repairs, f'unexpected repair_class: {f[\"repair_class\"]}'
" <<< "$tx_json" 2>/dev/null; then
    echo "  ok  taxonomy: all failure/repair classes are from the valid set"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: found unexpected failure or repair class values"
    tx_fail=$((tx_fail + 1))
fi

# 11. Attachment integrity diagnostics appear for stale registry entries
if grep <<<"$tx_text" -q "attachment_integrity"; then
    echo "  ok  taxonomy: attachment_integrity diagnostic appears for stale registry"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: attachment_integrity diagnostic should appear for stale registry"
    tx_fail=$((tx_fail + 1))
fi

# 12. Attachment integrity diagnostic has repair=registry_update
if grep <<<"$tx_text" -A4 "attachment_integrity" | has_match "repair:.*registry_update"; then
    echo "  ok  taxonomy: attachment_integrity → repair=registry_update"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: attachment_integrity should map to repair=registry_update"
    tx_fail=$((tx_fail + 1))
fi

# 13. JSON: attachment_integrity diagnostic present with correct failure/repair class
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ai = [f for f in d['facts'] if f.get('diagnostic_kind') == 'attachment_integrity']
assert len(ai) >= 1, f'expected >=1 attachment_integrity diagnostics, got {len(ai)}'
for f in ai:
    assert f['failure_class'] == 'attachment_integrity', f'wrong failure_class: {f[\"failure_class\"]}'
    assert f['repair_class'] == 'registry_update', f'wrong repair_class: {f[\"repair_class\"]}'
    assert f['code'] == 'E0805', f'wrong code: {f[\"code\"]}'
" <<< "$tx_json" 2>/dev/null; then
    echo "  ok  taxonomy: JSON — attachment_integrity has correct class/code"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: JSON — attachment_integrity should have correct class/code"
    tx_fail=$((tx_fail + 1))
fi

# 14. Error codes E0805-E0807 registered in diagnostic-codes report
dc_out=$($COMPILER "$PP_FILE" --report diagnostic-codes 2>/dev/null)
if python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
codes = {c['code'] for c in d['codes']}
assert 'E0805' in codes, 'E0805 (attachment_integrity) missing'
assert 'E0806' in codes, 'E0806 (theorem_lookup) missing'
assert 'E0807' in codes, 'E0807 (lean_check_failure) missing'
" <<< "$dc_out" 2>/dev/null; then
    echo "  ok  taxonomy: E0805-E0807 registered in diagnostic-codes"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: E0805-E0807 should be registered in diagnostic-codes"
    tx_fail=$((tx_fail + 1))
fi

# 15. Diff handles multiple diagnostics per function without duplicate key error
tx_snap1=$($COMPILER "$PP_FILE" --report diagnostics-json 2>/dev/null)
tx_snap2=$($COMPILER "$PP_FILE" --report diagnostics-json 2>/dev/null)
tx_diff_out=$(echo "$tx_snap1" > "$TMPDIR/tx_snap1.json" && echo "$tx_snap2" > "$TMPDIR/tx_snap2.json" && $COMPILER diff "$TMPDIR/tx_snap1.json" "$TMPDIR/tx_snap2.json" 2>&1) || tx_diff_exit=$?
if ! grep <<<"$tx_diff_out" -q "duplicate keys"; then
    echo "  ok  taxonomy: diff handles multiple diagnostics per function"
    tx_pass=$((tx_pass + 1))
else
    echo "  FAIL taxonomy: diff should handle multiple diagnostics per function"
    tx_fail=$((tx_fail + 1))
fi
rm -f "$TMPDIR/tx_snap1.json" "$TMPDIR/tx_snap2.json"

echo "  $tx_pass taxonomy gates passed"
PASS=$((PASS + tx_pass))
FAIL=$((FAIL + tx_fail))
:
}
