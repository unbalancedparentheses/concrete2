# proofgate: the code units of tests/cases/proofgate.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_proofgate_1() {
pg_pass=0
pg_fail=0

GATE_SCRIPT="$ROOT_DIR/scripts/ci/proof_gate.sh"

# 1. Proof gate script exists and is executable
if [ -x "$GATE_SCRIPT" ]; then
    echo "  ok  proofgate: script exists and is executable"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: script should exist and be executable"
    pg_fail=$((pg_fail + 1))
fi

# 2. Proof gate passes on the pressure set
pg_out=$(bash "$GATE_SCRIPT" 2>&1) || true
pg_exit=$?
if [ "$pg_exit" -eq 0 ]; then
    echo "  ok  proofgate: passes on proof pressure set (exit 0)"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: should pass on proof pressure set"
    pg_fail=$((pg_fail + 1))
fi

# 3. Proof gate reports all 20 checks
if grep <<<"$pg_out" -q "passed: 20 / 20"; then
    echo "  ok  proofgate: runs all 20 checks"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: should run all 20 checks"
    pg_fail=$((pg_fail + 1))
fi

# 4. Proof gate covers all 8 sections
if grep <<<"$pg_out" -q "Extraction" && \
   grep <<<"$pg_out" -q "Registry" && \
   grep <<<"$pg_out" -q "Proof-status" && \
   grep <<<"$pg_out" -q "Proof diagnostics" && \
   grep <<<"$pg_out" -q "Proof dependencies" && \
   grep <<<"$pg_out" -q "Evidence bundle" && \
   grep <<<"$pg_out" -q "Determinism" && \
   grep <<<"$pg_out" -q "Lean theorem"; then
    echo "  ok  proofgate: covers all 8 check sections"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: should cover all 8 sections"
    pg_fail=$((pg_fail + 1))
fi

# 5. Proof gate shows compiler identity
if grep <<<"$pg_out" -q "compiler:.*concrete"; then
    echo "  ok  proofgate: shows compiler identity"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: should show compiler identity"
    pg_fail=$((pg_fail + 1))
fi

# 6. CI workflow includes proof-gate job
if grep -q "proof-gate" "$ROOT_DIR/.github/workflows/lean_action_ci.yml"; then
    echo "  ok  proofgate: CI workflow includes proof-gate job"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: CI workflow should include proof-gate job"
    pg_fail=$((pg_fail + 1))
fi

# 7. Makefile includes test-proof-gate target
if grep -q "test-proof-gate" "$ROOT_DIR/Makefile"; then
    echo "  ok  proofgate: Makefile includes test-proof-gate target"
    pg_pass=$((pg_pass + 1))
else
    echo "  FAIL proofgate: Makefile should include test-proof-gate target"
    pg_fail=$((pg_fail + 1))
fi

echo "  $pg_pass proofgate gates passed"
PASS=$((PASS + pg_pass))
FAIL=$((FAIL + pg_fail))
:
}
