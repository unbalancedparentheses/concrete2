# query: the code units of tests/cases/query.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_query_1() {
query_pass=0
query_fail=0
QUERY_PROG="$TESTDIR/fib.con"

# --- 1. Empty query → explicit error ---
q_empty=$($COMPILER "$QUERY_PROG" --query "" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_empty" -q "error.*empty query"; then
    echo "  ok  query: empty query produces explicit error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: empty query should produce explicit error"
    echo "    output: $(echo "$q_empty" | awk "NR<=2")"
    query_fail=$((query_fail + 1))
fi

# --- 2. Unknown single-word kind → error with known kinds listed ---
q_bogus=$($COMPILER "$QUERY_PROG" --query "bogus_kind" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_bogus" -q "error.*unknown query kind.*bogus_kind"; then
    echo "  ok  query: unknown single-word kind produces error with suggestions"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: unknown single-word kind should produce error"
    echo "    output: $(echo "$q_bogus" | awk "NR<=2")"
    query_fail=$((query_fail + 1))
fi

# --- 3. Unknown two-part kind → error ---
q_bogus2=$($COMPILER "$QUERY_PROG" --query "bogus:myfn" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_bogus2" -q "error.*unknown query kind.*bogus"; then
    echo "  ok  query: unknown two-part kind produces error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: unknown two-part kind should produce error"
    query_fail=$((query_fail + 1))
fi

# --- 4. Empty segment (leading colon) → error ---
q_leading=$($COMPILER "$QUERY_PROG" --query ":fn:cap" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_leading" -q "error.*empty segment"; then
    echo "  ok  query: leading colon produces empty-segment error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: leading colon should produce empty-segment error"
    query_fail=$((query_fail + 1))
fi

# --- 5. Empty segment (trailing colon) → error ---
q_trailing=$($COMPILER "$QUERY_PROG" --query "proof:" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_trailing" -q "error.*empty segment"; then
    echo "  ok  query: trailing colon produces empty-segment error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: trailing colon should produce empty-segment error"
    query_fail=$((query_fail + 1))
fi

# --- 6. Unknown three-part kind → error ---
q_three=$($COMPILER "$QUERY_PROG" --query "bogus:fn:x" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_three" -q "error.*unknown three-part"; then
    echo "  ok  query: unknown three-part kind produces error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: unknown three-part kind should produce error"
    query_fail=$((query_fail + 1))
fi

# --- 7. Too many separators → error ---
q_many=$($COMPILER "$QUERY_PROG" --query "a:b:c:d" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -ne 0 ] && grep <<<"$q_many" -q "error.*too many"; then
    echo "  ok  query: too many separators produces error"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: too many separators should produce error"
    query_fail=$((query_fail + 1))
fi

# --- 8. Valid single-word kind still works ---
q_effects=$($COMPILER "$QUERY_PROG" --query "effects" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -eq 0 ] && grep <<<"$q_effects" -q '"kind".*"effects"'; then
    echo "  ok  query: valid single-word kind (effects) returns facts"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: valid single-word kind should return facts"
    query_fail=$((query_fail + 1))
fi

# --- 9. Valid semantic query still works ---
q_pred=$($COMPILER "$QUERY_PROG" --query "predictable:main.fib" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -eq 0 ] && grep <<<"$q_pred" -q '"query_answer"'; then
    echo "  ok  query: valid semantic query (predictable:fn) returns answer"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: valid semantic query should return answer"
    query_fail=$((query_fail + 1))
fi

# --- 10. Valid kind:function filter still works ---
q_filter=$($COMPILER "$QUERY_PROG" --query "effects:fib" 2>&1) && q_exit=0 || q_exit=$?
if [ "$q_exit" -eq 0 ] && grep <<<"$q_filter" -q '"effects"'; then
    echo "  ok  query: valid kind:function filter returns facts"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: valid kind:function filter should return facts"
    query_fail=$((query_fail + 1))
fi

# --- 11. Error messages list known kinds ---
if grep <<<"$q_bogus" -q "predictable.*proof.*evidence.*audit"; then
    echo "  ok  query: error messages list known semantic query kinds"
    query_pass=$((query_pass + 1))
else
    echo "  FAIL query: error messages should list known query kinds"
    query_fail=$((query_fail + 1))
fi

if [ "$query_fail" -gt 0 ]; then
    echo "  $query_fail invalid-query test failures"
fi
echo "  $query_pass invalid-query tests passed"
PASS=$((PASS + query_pass))
FAIL=$((FAIL + query_fail))
:
}
