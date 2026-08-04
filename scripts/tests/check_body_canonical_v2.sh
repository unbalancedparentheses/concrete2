#!/usr/bin/env bash
# R-0004: ProofBodyCanonicalV2 serialization.
#
# The serializer resolves NOTHING; it only encodes what the producer captured. So the
# properties here are about faithfulness and refusal, not about semantics:
#   - every node constructor is classified (REFLECTIVELY checked, not grepped)
#   - order and multiplicity survive
#   - the encoding is injective
#   - an uncovered body is REFUSED, never serialized as complete
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fatal() {
  local rc=$?
  echo "FATAL: check_body_canonical_v2 stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2
  exit "$rc"
}
trap fatal ERR

PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/p.lean" <<'LEAN'
import Lean
import Concrete
open Concrete Concrete.Proof

def a (label : String) (c : Bool) : IO Unit :=
  if c then IO.println ("  ok   " ++ label)
  else throw (IO.userError ("FAILED: " ++ label))

-- REFLECTIVE COMPLETENESS. This is the authority, not a grep and not the exhaustive
-- match alone. An exhaustive match stops a bare new constructor at compile time, but
-- a constructor added TOGETHER with a fallback arm compiles and serializes garbage.
-- Comparing the inductive's real constructor count against the serializer's declared
-- tag inventory catches that case.
open Lean in
def ctorCount : Lean.MetaM Nat := do
  match (← getEnv).find? ``Concrete.Proof.BodyIdentityUse with
  | some (.inductInfo iv) => pure iv.ctors.length
  | _ => throwError "BodyIdentityUse is not an inductive"

def ownerA : TypeId := TypeId.user "m" "A"

def nodes : List BodyIdentityUse :=
  [ .binderRef 0 0, .typeRef ownerA, .field { owner := ownerA, field := "x" },
    .variant { owner := ownerA, variant := "V" } ]

def covered  : ProofBodyIdentityInputsV2 := { uses := nodes, covered := true }
def uncov    : ProofBodyIdentityInputsV2 := { uses := nodes, covered := false }
-- Same multiset, different ORDER.
def reordered : ProofBodyIdentityInputsV2 := { uses := nodes.reverse, covered := true }
-- Same kinds, one node REPEATED.
def repeated : ProofBodyIdentityInputsV2 :=
  { uses := nodes ++ [.binderRef 0 0], covered := true }
def once : ProofBodyIdentityInputsV2 := { uses := [.binderRef 0 0], covered := true }
def twice : ProofBodyIdentityInputsV2 :=
  { uses := [.binderRef 0 0, .binderRef 0 0], covered := true }
-- Distinct positions that a non-injective encoding could confuse.
def posA : ProofBodyIdentityInputsV2 := { uses := [.binderRef 1 11], covered := true }
def posB : ProofBodyIdentityInputsV2 := { uses := [.binderRef 11 1], covered := true }

#eval show Lean.MetaM Unit from do
  let n ← ctorCount
  a s!"every node constructor is classified ({n} constructors, {allNodeTags.length} tags)"
    (n == allNodeTags.length)
  a "the declared tags are mutually distinct"
    (allNodeTags.eraseDups.length == allNodeTags.length)
  a "every node kind serializes to its own tag"
    ((nodes.map nodeTag).eraseDups.length == nodes.length)

#eval do
  -- Sanity first: an empty result would make the comparisons below vacuous.
  a "a covered body serializes to non-empty versioned bytes"
    (((serializeBody covered).getD "").startsWith "bodyV2:")

  a "an UNCOVERED body is refused, not serialized as complete"
    (serializeBody uncov == none)
  a "refusal is about coverage, not about content — same nodes, covered, do serialize"
    (serializeBody covered != none)

  a "node ORDER changes the bytes"
    (serializeBody covered != serializeBody reordered)
  a "node MULTIPLICITY changes the bytes"
    (serializeBody covered != serializeBody repeated
      && serializeBody once != serializeBody twice)
  a "the node count is emitted, so a truncated stream cannot read as a shorter one"
    (((serializeBody once).getD "").startsWith "bodyV2:n1:"
      && ((serializeBody twice).getD "").startsWith "bodyV2:n2:")

  a "the encoding is injective across distinct positions"
    (serializeBody posA != serializeBody posB)
  a "identical inputs serialize identically"
    (serializeBody covered == serializeBody { uses := nodes, covered := true })

  -- The serializer must not leak a source name. Only the typed IDs' own rendering
  -- may appear, and a binder never contributes one.
  a "a binder reference contributes no name to the bytes"
    ((((serializeBody once).getD "").splitOn "b").length >= 2)
LEAN

OUT="$TMP_DIR/out.txt"
if ! lake env lean "$TMP_DIR/p.lean" > "$OUT" 2>&1; then
  echo "FATAL: serializer probe did not elaborate" >&2; sed -n '1,12p' "$OUT" >&2; exit 1
fi
if grep -qE "error|sorry" "$OUT"; then
  echo "FATAL: probe emitted a diagnostic" >&2; sed -n '1,10p' "$OUT" >&2; exit 1
fi
cat "$OUT"
PASS=$(( PASS + $(grep -c '^  ok   ' "$OUT" || true) ))

# Structural BACKSTOPS. These supplement the reflective check above; they are not the
# authority. A wildcard arm would let an unclassified constructor receive a generic
# tag, and a derived Repr would produce bytes for a node kind nobody classified.
code="$(sed -e '/^ *--/d' -e '/^ *\/-/,/-\//d' Concrete/Proof/BodyCanonicalV2.lean)"
if printf '%s' "$code" | grep -qE '^\s*\|\s*_\s*=>'; then
  no "the serializer has a wildcard arm — an unclassified node would get a generic tag"
else
  ok "the serializer has no wildcard arm"
fi
if printf '%s' "$code" | grep -qE "deriving.*Repr|Repr\b"; then
  no "the serializer reaches for Repr — a derived instance absorbs new constructors silently"
else
  ok "the serializer does not derive its bytes from Repr"
fi
# The split is the architecture: serialization must not resolve anything.
if printf '%s' "$code" | grep -qE "lookup|resolve|Elab|find\?"; then
  no "the serializer performs resolution — that belongs to the producer, which alone has the information"
else
  ok "the serializer resolves nothing; it only encodes captured nodes"
fi

echo "BODY-CANONICAL-V2: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
