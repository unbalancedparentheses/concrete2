# bundle: the code units of tests/cases/bundle.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_bundle_1() {
pb_pass=0
pb_fail=0

PP_SRC="examples/proof_pressure/src/main.con"
pb_out=$($COMPILER "$PP_SRC" --report proof-bundle 2>&1 | grep -v '^warning:')

# 1. Bundle has schema_version and schema_kind
if echo "$pb_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['schema_version']==2; assert d['schema_kind']=='proof_bundle'" 2>/dev/null; then
    echo "  ok  bundle: schema_version=2 and schema_kind=proof_bundle"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: should have schema_version=2 and schema_kind=proof_bundle"
    pb_fail=$((pb_fail + 1))
fi

# 2. Bundle has source and compiler identity
if echo "$pb_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'proof_pressure' in d['source']; assert 'concrete' in d['compiler']" 2>/dev/null; then
    echo "  ok  bundle: has source path and compiler identity"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: should have source and compiler fields"
    pb_fail=$((pb_fail + 1))
fi

# 3. Bundle has timestamp
if echo "$pb_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d['timestamp']) > 0" 2>/dev/null; then
    echo "  ok  bundle: has non-empty timestamp"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: should have a timestamp"
    pb_fail=$((pb_fail + 1))
fi

# 4. Summary has correct obligation counts
if echo "$pb_out" | python3 -c "
import sys,json; d=json.load(sys.stdin); s=d['summary']
assert s['proved']==1, f'proved={s[\"proved\"]}'
assert s['stale']==1, f'stale={s[\"stale\"]}'
assert s['missing']==2, f'missing={s[\"missing\"]}'
assert s['blocked']==1, f'blocked={s[\"blocked\"]}'
assert s['ineligible']==2, f'ineligible={s[\"ineligible\"]}'
assert s['total_functions']==7, f'total={s[\"total_functions\"]}'
" 2>/dev/null; then
    echo "  ok  bundle: summary obligation counts correct (1 proved, 1 stale, 2 missing, 1 blocked, 2 ineligible)"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: summary obligation counts incorrect"
    pb_fail=$((pb_fail + 1))
fi

# 5. Summary has extraction counts
if echo "$pb_out" | python3 -c "
import sys,json; s=json.load(sys.stdin)['summary']
assert s['extracted'] >= 3
assert s['excluded'] >= 2
" 2>/dev/null; then
    echo "  ok  bundle: summary has extraction counts"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: summary should have extraction counts"
    pb_fail=$((pb_fail + 1))
fi

# 6. Summary has diagnostic severity counts
if echo "$pb_out" | python3 -c "
import sys,json; s=json.load(sys.stdin)['summary']
assert s['diagnostics_errors'] >= 1
assert s['diagnostics_warnings'] >= 1
" 2>/dev/null; then
    echo "  ok  bundle: summary has diagnostic severity counts"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: summary should have diagnostics_errors and diagnostics_warnings"
    pb_fail=$((pb_fail + 1))
fi

# 7. Assumptions section present with all required fields
if echo "$pb_out" | python3 -c "
import sys,json; a=json.load(sys.stdin)['assumptions']
assert 'proof_model' in a
assert 'compilation_chain' in a
assert 'integer_model' in a
assert 'composition' in a
assert 'checker_soundness' in a
assert 'fingerprint_stability' in a
" 2>/dev/null; then
    echo "  ok  bundle: assumptions section has all 6 required fields"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: assumptions should have proof_model, compilation_chain, integer_model, composition, checker_soundness, fingerprint_stability"
    pb_fail=$((pb_fail + 1))
fi

# 8. Registry entries present
if echo "$pb_out" | python3 -c "
import sys,json; r=json.load(sys.stdin)['registry']
assert len(r) == 3
fns = [e['function'] for e in r]
assert 'main.check_nonce' in fns
assert 'main.compute_checksum' in fns
for e in r:
    assert 'body_fingerprint' in e
    assert 'proof' in e
    assert 'spec' in e
" 2>/dev/null; then
    echo "  ok  bundle: registry has 3 entries with all required fields"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: registry should have 3 entries with function, body_fingerprint, proof, spec"
    pb_fail=$((pb_fail + 1))
fi

# 9. Dependency graph present with edges
if echo "$pb_out" | python3 -c "
import sys,json; g=json.load(sys.stdin)['dependency_graph']
assert len(g) >= 1
vh = [e for e in g if e['function']=='main.validate_header']
assert len(vh) == 1
assert 'main.check_nonce' in vh[0]['proved_deps']
" 2>/dev/null; then
    echo "  ok  bundle: dependency graph has validate_header → check_nonce edge"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: dependency graph should have validate_header → check_nonce"
    pb_fail=$((pb_fail + 1))
fi

# 10. Dependency graph shows stale deps
if echo "$pb_out" | python3 -c "
import sys,json; g=json.load(sys.stdin)['dependency_graph']
main = [e for e in g if e['function']=='main.main']
assert len(main) == 1
assert 'main.compute_checksum' in main[0]['stale_deps']
" 2>/dev/null; then
    echo "  ok  bundle: dependency graph shows stale dep (main → compute_checksum)"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: dependency graph should show main's stale dep on compute_checksum"
    pb_fail=$((pb_fail + 1))
fi

# 11. Facts include all 5 proof-related kinds
if echo "$pb_out" | python3 -c "
import sys,json; facts=json.load(sys.stdin)['facts']
kinds = set(f['kind'] for f in facts)
assert 'proof_status' in kinds
assert 'obligation' in kinds
assert 'extraction' in kinds
assert 'proof_diagnostic' in kinds
assert 'eligibility' in kinds
" 2>/dev/null; then
    echo "  ok  bundle: facts include all 5 proof-related kinds"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: facts should include proof_status, obligation, extraction, proof_diagnostic, eligibility"
    pb_fail=$((pb_fail + 1))
fi

# 12. fact_count matches actual facts length
if echo "$pb_out" | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert d['fact_count'] == len(d['facts']), f'{d[\"fact_count\"]} != {len(d[\"facts\"])}'
" 2>/dev/null; then
    echo "  ok  bundle: fact_count matches actual facts length"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: fact_count should equal len(facts)"
    pb_fail=$((pb_fail + 1))
fi

# 13. Bundle for a clean file (no registry) has zero proved/stale
PB_DIR=$(mktemp -d)
cat > "$PB_DIR/clean.con" <<'CONEOF'
fn add(a: Int, b: Int) -> Int { return a + b; }
fn main() -> i32 { return 0; }
CONEOF
pb_clean=$($COMPILER "$PB_DIR/clean.con" --report proof-bundle 2>&1 | grep -v '^warning:')
if echo "$pb_clean" | python3 -c "
import sys,json; s=json.load(sys.stdin)['summary']
assert s['proved']==0
assert s['stale']==0
assert s['registry'] if False else True
" 2>/dev/null && echo "$pb_clean" | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert len(d['registry'])==0
" 2>/dev/null; then
    echo "  ok  bundle: clean file has zero proved/stale and empty registry"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: clean file should have zero proved/stale and empty registry"
    pb_fail=$((pb_fail + 1))
fi
rm -rf "$PB_DIR"

# 14. Bundle exit code 0 when registry has only warnings (stale fingerprint is a warning)
pb_exit=0
$COMPILER "$PP_SRC" --report proof-bundle >/dev/null 2>&1 || pb_exit=$?
if [ "$pb_exit" -eq 0 ]; then
    echo "  ok  bundle: exit code 0 when registry has only warnings"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: should exit 0 when registry has only warnings"
    pb_fail=$((pb_fail + 1))
fi

# 15. Bundle does not include non-proof facts (no capability, unsafe, alloc, effects)
if echo "$pb_out" | python3 -c "
import sys,json; facts=json.load(sys.stdin)['facts']
kinds = set(f['kind'] for f in facts)
assert 'capability' not in kinds
assert 'unsafe' not in kinds
assert 'alloc' not in kinds
assert 'effects' not in kinds
" 2>/dev/null; then
    echo "  ok  bundle: excludes non-proof facts (capability, unsafe, alloc, effects)"
    pb_pass=$((pb_pass + 1))
else
    echo "  FAIL bundle: should not include capability, unsafe, alloc, or effects facts"
    pb_fail=$((pb_fail + 1))
fi

echo "  $pb_pass bundle gates passed"
PASS=$((PASS + pb_pass))
FAIL=$((FAIL + pb_fail))
:
}
