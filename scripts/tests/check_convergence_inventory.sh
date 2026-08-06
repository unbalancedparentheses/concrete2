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
# 1. CLOSED. The independent accumulator is deleted; the flat identity-use view is derived
#    from the structural evidence body, so there is one producer.
#
#    Deleting it CHANGED the fact, it did not merely relocate it: containment was proven,
#    not equality, and the derived view turned out to be strictly richer. It records an
#    assignment TARGET as a use of a binder and a match pattern's FIELD identity, neither
#    of which the accumulator ever saw. Two gates that pinned the old, lossy numbers had to
#    be updated to assert the recovered identities (check_type_identity 7 -> 10,
#    check_binder_refs 4 -> 5).
#
#    The entry stays here, inverted: the gap is closed and must STAY closed.
if grep -q "bodyIdentityUses" Concrete/Elab/Elab.lean; then
  no "an identity-use accumulator is back in Elab — the flat view must stay DERIVED from the structural body"
else
  ok "CLOSED: one producer of identity uses; the flat view is derived from the tree"
fi

# 2. CLOSED. Shadow mode reports the structural body too. BOTH lines are printed, and both
#    are meant to stay: they answer different questions. `identityUses` digests the flat
#    list of identity references, where `p + 1`, `p * 2` and `p - 9` collide; `bodyV2`
#    digests the structural body, where they do not. Dropping the flat line would remove
#    the comparison the shadow period exists for.
if grep -q "shadow bodyV2" Concrete/Report/Report.lean; then
  ok "CLOSED: shadow mode reports the structural body digest (gated by check_shadow_body_v2)"
else
  no "the structural shadow line is gone from the report — the comparison it enables is how V2 is observed before it is trusted"
fi
if grep -qE "Proof\.shadowIdentityUseDigest " Concrete/Report/Report.lean; then
  ok "the flat identity-use line is still reported alongside it, so the two can be compared"
else
  no "the flat shadow line was removed — without it there is nothing to compare the structural digest against"
fi

# 3. STILL OPEN, and now the entry that matters most. Structural bytes reach OUTPUT (the
#    shadow report line) but must reach no VERDICT: the authoritative subject digest stays
#    V1-frozen through the shadow period.
#
#    Checked by containment rather than by absence, since absence stopped being true when
#    entry 2 closed. The exact owner set is asserted in check_shadow_body_v2.sh; here we
#    assert only that no STATUS depends on them.
if grep -q "bodyBytesV2" Concrete/Proof/SubjectFacts.lean Concrete/Proof/ProofCore.lean Main.lean 2>/dev/null; then
  no "bodyBytesV2 reached SubjectFacts, ProofCore or Main — a status may now depend on structural bytes while V1 is still the frozen authoritative domain"
else
  ok "GAP OPEN: structural body bytes are reported but no verdict derives from them"
fi

# 4. constRef names a constant without binding its meaning.
if grep -qE "unboundConsts : List ConstId" Concrete/Proof/EvidenceTree.lean; then
  ok "GAP OPEN: constant dependency binding is still an unmet obligation (unboundConsts)"
else
  no "unboundConsts is gone — if ConstId now binds to an initializer digest, record it"
fi

# --- R-0004: open language decision --------------------------------------------------
# 5. Struct-literal initializer evaluation order. STILL UNDECIDED, and the entry now says
#    what is actually true about it.
#
#    The producer was believed to REFUSE struct literals until this was decided —
#    `EvidenceBuild.evStructLitPending` existed and its docstring said so. It was never
#    called. The producer emits a real `structLit` ordered by the DECLARATION list, so the
#    undecided order has been in the shadow bytes the whole time: the outcome the refusal
#    was written to prevent, guarded by a comment instead of by behaviour.
#
#    The bytes are accurate to today's semantics and stay. What must not happen is the
#    order becoming AUTHORITATIVE while undecided, so the close condition is ratification
#    before the fingerprint migration — asserted below rather than trusted to prose.
if grep -q "OPEN LANGUAGE DECISION: struct-literal initializer evaluation order" docs/EVIDENCE_PRODUCER_MATRIX.md; then
  ok "GAP OPEN: struct-literal initializer evaluation order is undecided"
else
  no "the struct-literal ordering decision section is gone — it must be RATIFIED in the language reference, not deleted"
fi

# 5a. The refusal must not be reintroduced as a comment-only guard. Either the producer
#     refuses struct literals in BEHAVIOUR, or it does not claim to.
# Matches a DEFINITION, not any mention: the comment above the removal names the symbol to
# explain why it went, and a bare name match flagged that prose as the thing it forbids.
if grep -qE "^ *def evStructLitPending" Concrete/Proof/EvidenceBuild.lean; then
  no "evStructLitPending is back — if struct literals are refused, the producer must CALL it; a definition nothing calls is a guard that does not guard"
else
  ok "no comment-only struct-literal refusal: the producer's behaviour and its documentation agree"
fi

# 5b. THE CLOSE CONDITION. While V1 is the authoritative domain the order is only in shadow
#     bytes. The moment the migration starts, an unratified evaluation order would become
#     authoritative — so these two facts must not both change without the other.
if grep -q "OPEN LANGUAGE DECISION: struct-literal initializer evaluation order" docs/EVIDENCE_PRODUCER_MATRIX.md \
   && grep -q "bodyBytesV2" Concrete/Proof/SubjectFacts.lean 2>/dev/null; then
  no "structural bytes reached the canonical subject while the struct-literal evaluation order is still UNRATIFIED — decide the order before the migration, not after"
else
  ok "the undecided struct-literal order is confined to shadow bytes"
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
