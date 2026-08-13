#!/usr/bin/env bash
# ONE PRODUCER PER FACT — generalized from the obligation-record guard to a registry.
#
# WHY THIS EXISTS, concretely. "Two producers of one fact" is named as a defect class 14 times
# across this codebase and ROADMAP.md. It is enforced for exactly one fact
# (check_obligation_single_truth_source.sh, the obligation record). Everywhere else it lives in
# prose — and prose is not a gate.
#
# The cost of that was measured on 2026-08-13. `Report.lean:1763` states the rule for `depRoot`
# ("Both consumers read `ProofCore.dependencyNodesOf`, so there is one set of nodes rather than a
# Report-local rebuild — two builders is how a second, weaker answer appears"). Three lines away,
# `shadowEdgeKinds` violated it: it derived edge kinds as `if isTrusted then "trusted" else
# "unclassified"`, consulting no classification table, so it reported `unclassified` for edges the
# hand-back had classified `body`. Nothing checked. The stale line then caused a WRONG DIAGNOSIS —
# a coverage fail-open was reported, and root coverage was predicted to fall from 62/64 to ~53/64,
# when in fact the roots were correct and the report was lying. Two producers did not just risk
# divergence; they produced a false finding that was committed and had to be retracted.
#
# TWO ENTRY KINDS, because the class has two shapes:
#
#   FORMULA  a digest/preimage expression that must exist in exactly ONE file. A second copy is a
#            second answer to "did this change", and the copies drift silently because both are
#            plausible.
#   OWNERS   a derived fact (a kind, a currency decision, a node set) whose definition and
#            permitted consumers are named. A new consumer is not automatically wrong, but it must
#            be looked at — the failure names the file so the question is forced.
#
# CODE REFERENCES ONLY, via lib/code_refs.sh. A first version of a sibling guard grepped raw text
# and fired on a doc comment; and while writing THIS gate, a comment in `Report.lean` explaining
# the fix above made `classifiedEdgeOf` look like it had a consumer there. Documenting a boundary is
# not crossing it. The stripper is self-tested below before any verdict uses it, because narrowing
# what a guard reads is only safe if it still fires.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/code_refs.sh"

PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- the stripper must be trustworthy before it decides anything --------------------------------
if code_refs_selftest "$TMP/st" bodyBytesV2; then
  ok "code_refs ignores comment-only mentions and still catches real code references"
else
  no "code_refs self-test FAILED — every verdict below would be unreliable"
  echo "ONE-PRODUCER: PASS=$PASS FAIL=$FAIL"; exit 1
fi

SCOPE=(Concrete/ Main.lean)

# ================================================================================================
# FORMULA REGISTRY — each must live in exactly one file.
# ================================================================================================
echo "=== formulas have exactly one producer ==="

formula() {  # label | fragment | expected sole owner
  local label="$1" frag="$2" want="$3"
  local got; got="$(code_refs "$frag" "${SCOPE[@]}")"
  if [ -z "$got" ]; then
    no "$label: fragment '$frag' matches NO file — the registry entry is stale, so it was checking nothing"
  elif [ "$got" = "$want " ]; then
    ok "$label: one producer ($want)"
  else
    no "$label: expected sole producer '$want', found: $got — a second copy of a formula is a second answer"
  fi
}

formula "V1 source-body digest"  'shortHash (Proof.pexprCanonical' 'Concrete/Proof/BodyIdentity.lean'
formula "implementation digest"  'shortHash ("implementationV1:'   'Concrete/Proof/ImplementationIdentity.lean'

# ================================================================================================
# OWNER REGISTRY — definition plus permitted consumers, asserted as an exact set.
# ================================================================================================
echo "=== derived facts have one definition and named consumers ==="

owners() {  # label | fragment | expected set (space separated, in code_refs order)
  local label="$1" frag="$2" want="$3"
  local got; got="$(code_refs "$frag" "${SCOPE[@]}")"
  if [ -z "$got" ]; then
    no "$label: fragment '$frag' matches NO file — stale registry entry, checking nothing"
  elif [ "$got" = "$want " ]; then
    ok "$label: owners are exactly as registered"
  else
    no "$label: owner set changed. expected '$want' got '$got' — if a new consumer is legitimate, add it HERE and say why; if it RECOMPUTES the fact, it is the defect this gate exists to catch"
  fi
}

# The canonical body-digest producer. Report and DependencyEdge must READ it, never re-derive it —
# Report held a second copy of this formula until 2d351a2d.
owners "sourceBodyDigestV1Of" 'sourceBodyDigestV1Of' \
  'Concrete/Proof/BodyIdentity.lean Concrete/Proof/DependencyEdge.lean Concrete/Proof/ImplementationIdentity.lean Concrete/Report/Report.lean'

# Edge KIND classification. This is the fact `shadowEdgeKinds` had a second, weaker producer for.
owners "classifiedEdgeOf" 'classifiedEdgeOf' \
  'Concrete/Proof/ClassificationTable.lean Concrete/Proof/ProofCore.lean'

# The node/edge set. Both the root builder and the report must read ONE set of nodes.
owners "dependencyNodesOf" 'dependencyNodesOf' \
  'Concrete/Proof/ProofCore.lean Concrete/Report/Report.lean'

# The currency decision. A second opinion on "is this edge current" is a fail-open waiting to
# happen — this predicate was `| _ => true` once, which made `unclassified` current by default.
owners "isCurrentForDependents" 'isCurrentForDependents' \
  'Concrete/Proof/DependencyEdge.lean Concrete/Proof/DependencyRoot.lean Concrete/Proof/ProofCore.lean Concrete/Report/Report.lean'

# ================================================================================================
# The registry must not be empty of teeth: prove an added second producer would FAIL.
# ================================================================================================
echo "=== the registry would catch a second producer ==="
mkdir -p "$TMP/neg/Concrete"
printf 'def sneaky : String := shortHash (Proof.pexprCanonical (normalizePExpr pe))\n' \
  > "$TMP/neg/Concrete/Sneaky.lean"
neg="$(code_refs 'shortHash (Proof.pexprCanonical' "$TMP/neg")"
if [ "$neg" = "$TMP/neg/Concrete/Sneaky.lean " ]; then
  ok "a duplicated formula in a new file IS detected (the check has teeth)"
else
  no "a duplicated formula was NOT detected (got '$neg') — this gate cannot catch what it exists for"
fi

echo "ONE-PRODUCER: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
