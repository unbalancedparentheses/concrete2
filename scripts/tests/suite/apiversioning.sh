# apiversioning: the code units of tests/cases/apiversioning.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_apiversioning_1() {
api_pass=0
api_fail=0

api_env=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)

# 1. diagnostics-json has schema_version = 2
if grep <<<"$api_env" -q '"schema_version": 2'; then
    echo "  ok  api-versioning: diagnostics-json has schema_version 2"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: diagnostics-json should have schema_version 2"
    api_fail=$((api_fail + 1))
fi

# 2. diagnostics-json has schema_kind = "facts"
if grep <<<"$api_env" -q '"schema_kind": "facts"'; then
    echo "  ok  api-versioning: diagnostics-json has schema_kind facts"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: diagnostics-json should have schema_kind facts"
    api_fail=$((api_fail + 1))
fi

# 3. diagnostics-json has fact_kinds with all 12 kinds
if python3 -c "
import json, sys
env = json.loads(sys.stdin.read())
fk = set(env['fact_kinds'])
expected = {'proof_diagnostic','predictable_violation','proof_status','eligibility','obligation','extraction','traceability','effects','capability','unsafe','alloc','contract'}
assert fk == expected, f'got {fk}'
" <<< "$api_env" 2>/dev/null; then
    echo "  ok  api-versioning: diagnostics-json fact_kinds has all 12 kinds"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: diagnostics-json fact_kinds should have all 12 kinds"
    api_fail=$((api_fail + 1))
fi

# 4. diagnostics-json fact_count matches actual facts length
if python3 -c "
import json, sys
env = json.loads(sys.stdin.read())
assert env['fact_count'] == len(env['facts']), f'{env[\"fact_count\"]} != {len(env[\"facts\"])}'
assert env['fact_count'] > 0
" <<< "$api_env" 2>/dev/null; then
    echo "  ok  api-versioning: diagnostics-json fact_count matches facts length"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: diagnostics-json fact_count should match facts length"
    api_fail=$((api_fail + 1))
fi

# 5. semantic query has schema_version
q_pred=$($COMPILER "$TESTDIR/report_integration.con" --query "predictable:pure_add" 2>/dev/null)
if grep <<<"$q_pred" -q '"schema_version": 2'; then
    echo "  ok  api-versioning: query_answer has schema_version 2"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: query_answer should have schema_version 2"
    api_fail=$((api_fail + 1))
fi

# 6. fact-filter query returns versioned envelope
q_fn=$($COMPILER "$TESTDIR/report_integration.con" --query "fn:pure_add" 2>/dev/null)
if grep <<<"$q_fn" -q '"schema_kind": "facts"' && \
   grep <<<"$q_fn" -q '"schema_version": 2'; then
    echo "  ok  api-versioning: fact-filter query returns versioned envelope"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: fact-filter query should return versioned envelope"
    api_fail=$((api_fail + 1))
fi

# 7. --report schema outputs valid JSON with expected fields
schema_out=$($COMPILER "$TESTDIR/report_integration.con" --report schema 2>/dev/null)
if python3 -c "
import json, sys
s = json.loads(sys.stdin.read())
for k in ['schema_version','fact_kinds','query_kinds','fact_schemas','query_schemas','envelopes','policies','location_encoding']:
    assert k in s, f'missing key: {k}'
assert s['schema_version'] == 2
assert len(s['fact_kinds']) == 12
assert len(s['query_kinds']) == 7
" <<< "$schema_out" 2>/dev/null; then
    echo "  ok  api-versioning: --report schema has all expected fields"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: --report schema should have all expected fields"
    api_fail=$((api_fail + 1))
fi

# 8. kind-filter query returns envelope with fact_count > 0
q_eff=$($COMPILER "$TESTDIR/report_integration.con" --query "effects" 2>/dev/null)
if grep <<<"$q_eff" -q '"schema_version": 2' && \
   grep <<<"$q_eff" -q '"fact_count":' && \
   ! grep <<<"$q_eff" -q '"fact_count": 0'; then
    echo "  ok  api-versioning: kind-filter query returns envelope with facts"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: kind-filter query should return envelope with facts"
    api_fail=$((api_fail + 1))
fi

# 9. empty-result policy: unknown function returns envelope with fact_count 0
q_empty=$($COMPILER "$TESTDIR/report_integration.con" --query "effects:nonexistent_function_xyz" 2>/dev/null)
if grep <<<"$q_empty" -q '"schema_version": 2' && \
   grep <<<"$q_empty" -q '"fact_count": 0'; then
    echo "  ok  api-versioning: empty result returns envelope with fact_count 0"
    api_pass=$((api_pass + 1))
else
    echo "FAIL  api-versioning: empty result should return envelope with fact_count 0"
    api_fail=$((api_fail + 1))
fi

echo "  $api_pass api versioning gates passed"
PASS=$((PASS + api_pass))
FAIL=$((FAIL + api_fail))
:
}
