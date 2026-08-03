#!/usr/bin/env bash
# Register C gate — the evidence algebra (Concrete/Report/Evidence.lean).
#
# Registers A (obligation sufficiency) and B (transformation soundness) are about
# program semantics and are years of work. Register C is about the evidence DATA
# STRUCTURE, so its rows are dischargeable now — and they are discharged as
# compile-time theorems, not tests. A green build is the proof; this gate exists to
# make deleting or weakening a row LOUD rather than silent, and to lock the
# structural properties a theorem cannot state (one construction site, wired
# consumers, no axiom escape hatches).
#
# Why the rows matter, concretely: H23 shipped a guaranteed out-of-bounds access as
# `proved_by_multi_kernel (3: lean, rocq, isabelle)` because an obligation's status
# was computed without consulting the hypotheses it rested on. C2/C2'/C3 make that
# combination unrepresentable rather than merely wrong.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
EV="Concrete/Report/Evidence.lean"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$EV" ] || { echo "FAIL evidence algebra module missing: $EV"; exit 1; }

echo "=== Register C rows are present and kernel-checked (green build ⇒ proven) ==="
# Each row is a THEOREM in the module. Deleting one is a red gate here; weakening one
# to `sorry` is caught below. The build having succeeded is what makes them proofs.
for t in c1_combine_keeps_left c1_combine_keeps_right \
         c2_combine_proved c2_under_hypotheses_proved \
         c3_caps_to_assumed c3_present_unchanged_when_proved \
         c4_discharge_shrinks c5_self_justifying_free; do
  grep -q "^theorem $t\|^theorem $t " "$EV" \
    && ok "row present: $t" || no "Register C row MISSING: $t"
done

echo "=== no escape hatches in the proofs ==="
# `sorry`/`admit` would make a row vacuous while the gate above still passed.
# `native_decide` would discharge it via compiled code, extending trust to
# Lean.ofReduceBool / Lean.trustCompiler — the very extension docs/AXIOMS.md gates
# elsewhere. Neither belongs in a register that exists to REMOVE trust.
for bad in sorry admit native_decide; do
  grep -qE "\b$bad\b" "$EV" \
    && no "$EV contains '$bad' — a Register C row is not actually proved" \
    || ok "no '$bad' in the evidence algebra"
done

echo "=== behaviour is locked at COMPILE time, not by this gate ==="
# An external review defeated the earlier version of this gate: deleting the validation
# filter from multiKernelVerdict — which lets a kernel whose rendering denotes a DIFFERENT
# proposition attest to this one — left it green at 24/24, because everything here checks
# names, counts and construction sites, never behaviour.
#
# The fix is not more grepping. `example`s in Evidence.lean pin the verdict truth table by
# `rfl`, so such a mutation is a BUILD failure. This gate's job is only to prove the locks
# were not deleted; the build is what proves they hold.
for lock in "unvalidated .closed" "wrongObligation .closed" "wrongKernel .closed" "ok .absent" "ok .refused"; do
  grep -q "$lock" "$EV" && ok "behavioural lock present: $lock" \
                        || no "behavioural lock MISSING: $lock — a truth-table row is unpinned"
done
LOCKS="$(grep -c "^example : (multiKernelVerdict" "$EV")"
[ "$LOCKS" -ge 8 ] && ok "verdict truth table pinned by $LOCKS compile-time examples" \
                   || no "only $LOCKS verdict examples (expected >=8) — rows were removed"

echo "=== validation is a WITNESS, not a boolean claim ==="
# The deepest fix from that review. `loweringAgreed : Bool` was a claim ABOUT a check
# rather than a product OF one: any caller could write `true`, and two of the three
# consumers did exactly that, relying on an upstream filter. The third derived it from a
# set that failed open. Both were possible only because the type let a caller assert the
# check instead of performing it.
#
# `LoweringValidated` has a private constructor and is minted only from the set of
# obligations whose agreement lemma CLOSED, and it is bound to the kernel and obligation it
# validates so it cannot be reused across either.
grep -q "structure LoweringValidated where" "$EV" \
  && ok "LoweringValidated exists" || no "LoweringValidated missing — validation is a bare Bool again"
awk '/structure LoweringValidated where/,/deriving/' "$EV" | grep -q "private mk ::" \
  && ok "LoweringValidated constructor is private (cannot be fabricated)" \
  || no "LoweringValidated constructor is PUBLIC — a caller can fabricate a witness"
grep -q "def LoweringValidated.mint" "$EV" \
  && ok "the only route to a witness is mint (requires the agreement-closed set)" \
  || no "no mint function — how is a witness obtained?"
grep -q "validated : Option LoweringValidated" "$EV" \
  && ok "KernelInput carries a witness, not a Bool" \
  || no "KernelInput does not carry Option LoweringValidated"
grep -qE "w.kernel == k.name && w.obligation == ob" "$EV" \
  && ok "the witness is checked against THIS kernel and THIS obligation (no reuse)" \
  || no "witness binding not checked — a witness could be reused across kernels/obligations"
# And no consumer may assert validation as a literal, which is what this replaced.
#
# Match CODE, not prose: require `kernel :=` on the same line so a receipt literal is
# matched and the comments explaining this history are not. The first version of this
# check flagged its own explanatory comments — a gate whose failure mode is describing
# the defect it guards against is noise, and noise is how gates get ignored.
#
# `lean` is the one permitted literal and the reason is in Report.lean: Lean's rendering
# IS the reference the others are validated against, so nothing exists to validate it
# with. That asymmetry is a real gap, filed under R-0450.
if grep -rn "loweringAgreed := true" Main.lean Concrete/Report/Report.lean 2>/dev/null \
     | grep "kernel :=" | grep -v 'kernel := "lean"' | grep -q .; then
  no "a consumer still writes 'loweringAgreed := true' for an EXTERNAL kernel"
else
  ok "external validation is never asserted as a literal (lean excepted, see R-0450)"
fi
grep -q "loweringAgreed := rocqW.isSome" Concrete/Report/Report.lean \
  && ok "receipts DERIVE loweringAgreed from the minted witness" \
  || no "receipts no longer derive loweringAgreed from a witness"

echo "=== C4 is enforced by the TYPE, not only by the theorem ==="
# C4 says discharge is the only operation that shrinks an assumption set. That constrains
# the function; the private constructor is what constrains the type. Without it,
# `{ e with assumes := [] }` forges a discharge and the claim presents as proved — the
# review demonstrated exactly that. Both halves are asserted because deleting either
# reopens the hole.
grep -q "private mk ::" "$EV" \
  && ok "Evidence has a private constructor (record-update forgery is a compile error)" \
  || no "Evidence constructor is PUBLIC — '{ e with assumes := [] }' forges a discharge"

echo "=== C3's companion: the capped status is not a proof class ==="
# C3 proves a claim with outstanding assumptions presents as exactly "assumed".
# This proves "assumed" is outside proofClasses. Together they close the H23 CLASS —
# a capped claim can never read as proved. They do NOT close H23 itself: nothing
# populates `assumes` until R-0461, so the H23 fixture still reports proved, which
# check_known_wrong_corpus.sh asserts. Do not read this gate as evidence the hole is shut.
grep -q 'example : (!proofClasses.contains "assumed") = true := rfl' Concrete/Report/Report.lean \
  && ok "compile-time proof that the capped status is not a proof class" \
  || no "missing companion example tying C3 to proofClasses"

echo "=== ONE derivation: badge strings are constructed in exactly one module ==="
# The structural property no theorem can state, and the one whose absence produced
# the report/artifact divergence: if two surfaces can each assemble a badge, they can
# disagree, and one of them can learn about a class the other never hears about.
# `kernel_disagreement` existed in the report and not in the stored artifact for
# exactly this reason. Vocabulary LISTS are not construction, so they are excluded.
for cls in proved_by_two_kernels proved_by_multi_kernel kernel_disagreement; do
  SITES="$(grep -rln "s!\"$cls\|(\"$cls\"," Concrete/ Main.lean 2>/dev/null | sort -u)"
  N="$(printf '%s' "$SITES" | grep -c . || true)"
  if [ "$N" = "1" ] && printf '%s' "$SITES" | grep -q "Evidence.lean"; then
    ok "$cls is constructed only in Evidence.lean"
  else
    no "$cls constructed in $N site(s): $(printf '%s' "$SITES" | tr '\n' ' ')"
  fi
done

echo "=== every consumer goes through the shared derivation ==="
# Report, ledger fold and release policy must all call multiKernelVerdict. A surface
# that computes its own class is a surface that can know something the others do not.
CONSUMERS="$(grep -rc "multiKernelVerdict" Main.lean Concrete/Report/Report.lean 2>/dev/null | tr '\n' ' ')"
[ "$(grep -c "multiKernelVerdict" Main.lean)" -ge 2 ] \
  && ok "Main.lean routes report AND policy through multiKernelVerdict" \
  || no "a Main.lean surface still computes its own multi-kernel class ($CONSUMERS)"
grep -q "multiKernelVerdict" Concrete/Report/Report.lean \
  && ok "the ledger fold routes through multiKernelVerdict" \
  || no "foldMultiKernelResults does not use the shared derivation"

echo "=== the ledger stores a CANONICAL class, never a composite string ==="
# R-0440: a friendly composite label may not erase the underlying dimensions. The
# display form (`proved_by_two_kernels (lean, rocq)`) is for humans; the stored status
# must be a bare vocabulary word so it stays checkable against statusVocabulary.
grep -q '"kernel_disagreement"' Concrete/Proof/ObligationCore.lean \
  && ok "kernel_disagreement is in statusVocabulary" \
  || no "kernel_disagreement missing from statusVocabulary (ledger can emit it)"
grep -q "def MultiKernelVerdict.displayStatus" "$EV" \
  && ok "display form is separated from the canonical class" \
  || no "no displayStatus — the composite string risks being stored as a status"

echo "=== hypothesis provenance is total: every origin decides its own debt ==="
# The four origins have genuinely different justification status, and erasing that is
# what made H23 possible. `debt` must handle each explicitly — a catch-all would
# silently give a new origin zero debt, which is the fail-OPEN default this codebase
# keeps finding.
for o in guard statement invariant assumed; do
  grep -q "| \.$o" "$EV" && ok "HypOrigin.debt handles .$o explicitly" \
                         || no "HypOrigin.debt missing case: .$o"
done
grep -qE "^\s*\|\s*_\s*=>" "$EV" \
  && no "evidence algebra contains a catch-all pattern (fail-open default)" \
  || ok "no catch-all pattern — a new origin is a missing-case ERROR, not silent"

echo ""
echo "EVIDENCE-ALGEBRA: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
