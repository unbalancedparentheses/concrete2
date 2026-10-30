# stackdepth: the code units of tests/cases/stackdepth.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_stackdepth_1() {
sd_pass=0
sd_fail=0

# 1. --report stack-depth produces output on crypto_verify
sd_crypto=$("$COMPILER" examples/crypto_verify/src/main.con --report stack-depth 2>&1)
if grep <<<"$sd_crypto" -q "Stack-Depth Report"; then
    echo "  ok  stackdepth: crypto_verify produces report"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: crypto_verify should produce report"
    sd_fail=$((sd_fail + 1))
fi

# 2. Reports frame bytes for each function
if grep <<<"$sd_crypto" -q "frame:.*bytes"; then
    echo "  ok  stackdepth: reports frame bytes"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: should report frame bytes"
    sd_fail=$((sd_fail + 1))
fi

# 3. Reports call depth
if grep <<<"$sd_crypto" -q "depth:"; then
    echo "  ok  stackdepth: reports call depth"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: should report call depth"
    sd_fail=$((sd_fail + 1))
fi

# 4. Reports stack bound
if grep <<<"$sd_crypto" -q "stack:.*bytes"; then
    echo "  ok  stackdepth: reports stack bound"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: should report stack bound"
    sd_fail=$((sd_fail + 1))
fi

# 5. Leaf functions have depth 0
if grep <<<"$sd_crypto" -A1 "compute_tag" | has_match "depth: 0"; then
    echo "  ok  stackdepth: leaf function has depth 0"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: leaf function should have depth 0"
    sd_fail=$((sd_fail + 1))
fi

# 6. Callers have depth > 0
if grep <<<"$sd_crypto" -A1 "main" | has_match "depth: [1-9]"; then
    echo "  ok  stackdepth: caller has depth > 0"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: caller should have depth > 0"
    sd_fail=$((sd_fail + 1))
fi

# 7. Stack bound >= frame bytes for all functions
sd_valid=true
while IFS= read -r line; do
    frame=$(grep <<<"$line" -o 'frame: [0-9]*' | grep -o '[0-9]*')
    stack=$(grep <<<"$line" -o 'stack: [0-9]*' | grep -o '[0-9]*')
    if [ -n "$frame" ] && [ -n "$stack" ] && [ "$stack" -lt "$frame" ]; then
        sd_valid=false
    fi
done <<< "$(grep <<<"$sd_crypto" "frame:")"
if $sd_valid; then
    echo "  ok  stackdepth: stack bound >= frame bytes for all functions"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: stack bound should be >= frame bytes"
    sd_fail=$((sd_fail + 1))
fi

# 8. Summary shows totals
if grep <<<"$sd_crypto" -q "Totals:.*functions.*bounded"; then
    echo "  ok  stackdepth: summary shows totals"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: summary should show totals"
    sd_fail=$((sd_fail + 1))
fi

# 9. Summary shows max stack bound
if grep <<<"$sd_crypto" -q "Max stack bound:.*bytes"; then
    echo "  ok  stackdepth: summary shows max stack bound"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: summary should show max stack bound"
    sd_fail=$((sd_fail + 1))
fi

# 10. Fixed-capacity all functions bounded (no recursive)
sd_fc=$("$COMPILER" examples/fixed_capacity/src/main.con --report stack-depth 2>&1)
if grep <<<"$sd_fc" -q "0 recursive (unbounded)"; then
    echo "  ok  stackdepth: fixed_capacity has 0 recursive functions"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: fixed_capacity should have 0 recursive functions"
    sd_fail=$((sd_fail + 1))
fi

# 11. Fixed-capacity main has depth > 0 (calls validators)
if grep <<<"$sd_fc" -A1 "  main" | has_match "depth: [1-9]"; then
    echo "  ok  stackdepth: fixed_capacity main has call depth > 0"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: fixed_capacity main should have call depth > 0"
    sd_fail=$((sd_fail + 1))
fi

# 12. Source locations present
if grep <<<"$sd_crypto" -q "@ examples/crypto_verify/src/main.con"; then
    echo "  ok  stackdepth: source locations present"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: should show source locations"
    sd_fail=$((sd_fail + 1))
fi

# --- Adversarial stack-depth tests ---

# 13. Deep chain: main has depth 12 (12-function chain)
sd_deep=$("$COMPILER" tests/programs/adversarial_stackdepth_deep_chain.con --report stack-depth 2>&1)
if grep <<<"$sd_deep" -A1 "  main" | has_match "depth: 12"; then
    echo "  ok  stackdepth: deep chain main has depth 12"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: deep chain main should have depth 12"
    sd_fail=$((sd_fail + 1))
fi

# 14. Deep chain: leaf (step_12) has depth 0
if grep <<<"$sd_deep" -A1 "step_12" | has_match "depth: 0"; then
    echo "  ok  stackdepth: deep chain leaf has depth 0"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: deep chain leaf should have depth 0"
    sd_fail=$((sd_fail + 1))
fi

# 15. Deep chain: 13 bounded, 0 recursive
if grep <<<"$sd_deep" -q "13 bounded, 0 recursive"; then
    echo "  ok  stackdepth: deep chain all 13 bounded, 0 recursive"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: deep chain should show 13 bounded, 0 recursive"
    sd_fail=$((sd_fail + 1))
fi

# 16. Wide fan: main has depth 1 (not 8 — max not sum)
sd_wide=$("$COMPILER" tests/programs/adversarial_stackdepth_wide_fan.con --report stack-depth 2>&1)
if grep <<<"$sd_wide" -A1 "  main" | has_match "depth: 1"; then
    echo "  ok  stackdepth: wide fan main has depth 1 (max not sum)"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: wide fan main should have depth 1"
    sd_fail=$((sd_fail + 1))
fi

# 17. Wide fan: all 8 leaves have depth 0
sd_wide_leaves=$(grep <<<"$sd_wide" "depth: 0" | wc -l | tr -d ' ')
if [ "$sd_wide_leaves" -eq 8 ]; then
    echo "  ok  stackdepth: wide fan has 8 leaves with depth 0"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: wide fan should have 8 leaves with depth 0 (got $sd_wide_leaves)"
    sd_fail=$((sd_fail + 1))
fi

# 18. Mixed recursion: 2 bounded, 4 recursive (unbounded).
#
# UPDATED with the transitive recursion-admission fix (spike/multi-prover-evidence). This
# expected 3 bounded / 3 recursive, which encoded a FAIL-OPEN: the fixture's `main` calls
# recurse(5) and mutual_a(3), so its stack usage IS unbounded, yet it was counted bounded
# because only DIRECT recursion was admitted. Transitive admission classifies it correctly,
# so the count moved 3/3 -> 2/4 and the old expectation was asserting the defect.
#
# pure_leaf and pure_caller remain the only genuinely bounded functions.
sd_mixed=$("$COMPILER" tests/programs/adversarial_stackdepth_mixed_recursion.con --report stack-depth 2>&1)
if grep <<<"$sd_mixed" -q "2 bounded, 4 recursive (unbounded)"; then
    echo "  ok  stackdepth: mixed has 2 bounded, 4 recursive (main is transitively unbounded)"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: mixed should have 2 bounded, 4 recursive (main calls recurse/mutual_a)"
    sd_fail=$((sd_fail + 1))
fi

# 19. Mixed recursion: recurse shows unbounded
if grep <<<"$sd_mixed" -A1 "  recurse" | has_match "unbounded"; then
    echo "  ok  stackdepth: direct recursion shows unbounded"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: direct recursion should show unbounded"
    sd_fail=$((sd_fail + 1))
fi

# 20. Mixed recursion: mutual_a shows unbounded
if grep <<<"$sd_mixed" -A1 "mutual_a" | has_match "unbounded"; then
    echo "  ok  stackdepth: mutual recursion shows unbounded"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: mutual recursion should show unbounded"
    sd_fail=$((sd_fail + 1))
fi

# 21. Mixed recursion: pure_caller has real depth (bounded)
if grep <<<"$sd_mixed" -A1 "pure_caller" | has_match "depth: 1"; then
    echo "  ok  stackdepth: non-recursive in mixed file has real depth"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: non-recursive in mixed file should have real depth"
    sd_fail=$((sd_fail + 1))
fi

# 22. Large frame: big_frame has frame > 100 bytes
sd_large=$("$COMPILER" tests/programs/adversarial_stackdepth_large_frame.con --report stack-depth 2>&1)
sd_big_frame=$(grep <<<"$sd_large" -A1 "big_frame" | grep -o 'frame: [0-9]*' | grep -o '[0-9]*')
if [ -n "$sd_big_frame" ] && [ "$sd_big_frame" -gt 100 ]; then
    echo "  ok  stackdepth: large frame function has frame > 100 bytes ($sd_big_frame)"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: large frame function should have frame > 100 bytes (got $sd_big_frame)"
    sd_fail=$((sd_fail + 1))
fi

# 23. Diamond: node_a has depth 2 (A->B->D or A->C->D)
sd_diamond=$("$COMPILER" tests/programs/adversarial_stackdepth_diamond.con --report stack-depth 2>&1)
if grep <<<"$sd_diamond" -A1 "node_a" | has_match "depth: 2"; then
    echo "  ok  stackdepth: diamond node_a has depth 2"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: diamond node_a should have depth 2"
    sd_fail=$((sd_fail + 1))
fi

# 24. Diamond: B and C both have depth 1
sd_b_depth=$(grep <<<"$sd_diamond" -A1 "node_b" | grep -o 'depth: [0-9]*' | grep -o '[0-9]*')
sd_c_depth=$(grep <<<"$sd_diamond" -A1 "node_c" | grep -o 'depth: [0-9]*' | grep -o '[0-9]*')
if [ "$sd_b_depth" = "1" ] && [ "$sd_c_depth" = "1" ]; then
    echo "  ok  stackdepth: diamond B and C both have depth 1"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: diamond B=$sd_b_depth and C=$sd_c_depth should both be depth 1"
    sd_fail=$((sd_fail + 1))
fi

# 25. Zero params: bare_leaf has minimum frame (8 bytes)
sd_zero=$("$COMPILER" tests/programs/adversarial_stackdepth_zero_params.con --report stack-depth 2>&1)
if grep <<<"$sd_zero" -A1 "bare_leaf" | has_match "frame: 8 bytes"; then
    echo "  ok  stackdepth: zero-param leaf has minimum frame (8 bytes)"
    sd_pass=$((sd_pass + 1))
else
    echo "  FAIL stackdepth: zero-param leaf should have minimum frame (8 bytes)"
    sd_fail=$((sd_fail + 1))
fi

echo "  $sd_pass stackdepth gates passed"
PASS=$((PASS + sd_pass))
FAIL=$((FAIL + sd_fail))
:
}
