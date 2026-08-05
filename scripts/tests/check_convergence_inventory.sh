#!/usr/bin/env bash
# CONVERGENCE INVENTORY — every known gap, machine-checked.
#
# The roadmap records the remaining R-0004 and multi-prover gaps in prose. Prose cannot
# fail, so a gap that is silently dropped, or silently CLOSED without the inventory being
# updated, leaves no trace. This gate makes each one executable.
#
# Every entry asserts the gap's CURRENT state. A gap that closes FAILS this gate — that is
# the point: closing one must be a deliberate act that updates the inventory, not a side
# effect nobody notices. The failure message says what to do.
#
# This is the same discipline as the quadratic-append ratchet and the struct-literal
# tripwire, applied to the gap list itself.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
fatal() { local rc=$?; echo "FATAL: check_convergence_inventory stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2; exit "$rc"; }
trap fatal ERR
PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# --- R-0004: evidence producer -------------------------------------------------------
# 1. Two producers of identity uses still exist. The tree is proven to lose nothing
#    (check_identity_use_bytes), so deletion is UNBLOCKED but not done.
if grep -qE "recordBodyIdentityUse \(" Concrete/Elab/Elab.lean; then
  ok "GAP OPEN: the independent bodyIdentityUses accumulator still exists"
else
  no "the accumulator is GONE — good, but update this inventory and confirm the derived flat view replaced every consumer"
fi

# 2. Shadow mode still reports the FLAT identity-use bytes, not the structural body.
if grep -qE "Proof\.shadowIdentityUseDigest " Concrete/Report/Report.lean; then
  ok "GAP OPEN: shadow mode still reports flat identity-use bytes, not bodyBytesV2"
else
  no "shadow mode no longer uses the flat digest — if it now serializes the structural body, record that and re-point this entry"
fi

# 3. Nothing consumes the structural body for a VERDICT yet.
if grep -q "bodyBytesV2" Concrete/Report/Report.lean 2>/dev/null; then
  no "Report now references bodyBytesV2 — structural bytes are reaching output; update the inventory and check whether any STATUS depends on them"
else
  ok "GAP OPEN: no consumer derives a verdict from the structural body bytes"
fi

# 4. constRef names a constant without binding its meaning.
if grep -qE "unboundConsts : List ConstId" Concrete/Proof/EvidenceTree.lean; then
  ok "GAP OPEN: constant dependency binding is still an unmet obligation (unboundConsts)"
else
  no "unboundConsts is gone — if ConstId now binds to an initializer digest, record it"
fi

# --- R-0004: open language decision --------------------------------------------------
# 5. Struct-literal initializer evaluation order.
if grep -q "OPEN LANGUAGE DECISION: struct-literal initializer evaluation order" docs/EVIDENCE_PRODUCER_MATRIX.md; then
  ok "GAP OPEN: struct-literal initializer evaluation order is undecided"
else
  no "the struct-literal ordering decision section is gone — it must be RATIFIED in the language reference, not deleted"
fi

# --- R-0004: freshness, migration, receipts ------------------------------------------
# 6. Bugs 059/060 remain open: freshness does not consume V2.
for b in 059 060; do
  if grep -qE "^\s*\[$b\]=.*OPEN" scripts/tests/audit_bug_corpus.sh; then
    ok "GAP OPEN: bug $b (freshness does not consume the V2 subject) is still recorded OPEN"
  else
    no "bug $b is no longer OPEN in the corpus — if V2 freshness landed, convert its tripwire and update this inventory"
  fi
done

# 7. V1 remains the authoritative fingerprint domain.
v1="$(bash scripts/tests/check_v1_fingerprint_golden.sh 2>/dev/null | tail -1 || true)"
case "$v1" in
  *"77 extracted"*) ok "GAP OPEN: V1 is still the frozen authoritative domain (77 extracted)" ;;
  "") no "the V1 golden did not report — inconclusive, not progress" ;;
  *) no "the V1 golden count MOVED ($v1). Either the corpus changed or the migration began; both require an inventory update" ;;
esac

# --- multi-prover: post-R-0004 --------------------------------------------------------
# 8. The kernel statuses must stay non-authoritative until the subject-digest cross-check
#    exists. The spike's own comment records the gap; assert it is still stated.
# Matched on a fragment that does not span the line break: the full phrase
# "there is no subject-digest cross-check" wraps in the source, and my first pattern
# failed on that rather than on a missing caveat.
if grep -q "there is no subject-digest" Concrete/Proof/ObligationCore.lean; then
  ok "GAP OPEN: multi-kernel statuses attest checker diversity, not proposition agreement"
else
  no "the subject-digest cross-check caveat is gone from ObligationCore — if the cross-check now EXISTS, say so; if the comment was merely deleted, restore it"
fi

# 9. The roadmap must carry the post-R-0004 multi-prover list.
if grep -q "Multi-prover work that remains AFTER R-0004" ROADMAP.md; then
  ok "GAP OPEN: the post-R-0004 multi-prover work is recorded in the roadmap"
else
  no "the post-R-0004 multi-prover section is missing from ROADMAP.md"
fi

# 10. The spike pin must be a fixed SHA, never a branch name.
if grep -qE "spike/multi-prover-evidence @ 80be5368|pin \`?80be5368" ROADMAP.md; then
  ok "the spike is pinned to an immutable SHA, not a moving head"
else
  no "the pinned spike SHA is absent from ROADMAP.md — later deltas must integrate as new PINNED epochs"
fi

# 11. `solver_error` is never produced. Three independent sites expected it — absent
#     solver, garbage solver, and the negatives gate — and all three get `unproven`. Every
#     case is FAIL-CLOSED (no false proof, asserted hard at each site), but a consumer
#     cannot distinguish "the solver misbehaved or was missing" from "not proved", which
#     are different facts: one is an environment defect, the other a proof-difficulty
#     statement.
if grep -q "TRACKED: absent solver reports" scripts/tests/check_smt_path.sh; then
  ok "GAP OPEN: solver_error is never produced; absent/garbage solver reports unproven"
else
  no "the solver_error tracking leg is gone — if the diagnostic landed, restore the strict assertions at all three sites"
fi

echo "CONVERGENCE-INVENTORY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
