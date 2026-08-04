#!/usr/bin/env bash
# R-0004: the typed evidence tree — ProofBodyCanonicalV2's input.
#
# The properties are about REPRESENTABILITY, since nothing consumes the tree yet:
#   - nesting is distinguishable (the reason it is a tree and not a flat stream)
#   - "handled nothing" is unrepresentable: every level has a `gap`
#   - bound names cannot enter the tree, because there is nowhere to put them
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fatal() {
  local rc=$?
  echo "FATAL: check_evidence_tree stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2
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

open Lean in
def ctorsOf (n : Name) : Lean.MetaM (List Name) := do
  match (← getEnv).find? n with
  | some (.inductInfo iv) => pure iv.ctors
  | _ => throwError m!"{n} is not an inductive"

-- An explicit injection into a comparable form. The tree derives NO Repr on purpose:
-- a derived instance across a mutual inductive is exactly where a serializer could
-- quietly acquire a fallback for an unclassified constructor. Writing this by hand in
-- the GATE keeps that pressure on the real serializer rather than relieving it.
partial def shape : EvidenceExprV2 → String
  | .intLit v      => s!"i{v}"
  | .boolLit v     => s!"b{v}"
  | .strLit v      => s!"s{v}"
  | .charLit v     => s!"c{v.toNat}"
  | .binderRef o i => s!"r{o}.{i}"
  | .constRef id   => s!"k{id.render}"
  | .unary op x    => s!"u({op},{shape x})"
  | .binary op l r => s!"n({op},{shape l},{shape r})"
  | .call c args   => s!"C({c.render},[{",".intercalate (args.map shape)}])"
  | .field id o    => s!"f({id.render},{shape o})"
  | .structLit t fs   => s!"S({t.render},[{",".intercalate (fs.map fun fe => shape fe.2)}])"
  | .variantLit id fs => s!"V({id.render},[{",".intercalate (fs.map fun fe => shape fe.2)}])"
  | .deref x       => s!"D({shape x})"
  | .borrow m x    => s!"B({m},{shape x})"
  | .index c i     => s!"X({shape c},{shape i})"
  | .cast t x      => s!"A({t.render},{shape x})"
  | .fnRef id      => s!"F({id.render})"
  | .gap _         => "GAP"

def p : EvidenceExprV2 := .binderRef 0 0
def q : EvidenceExprV2 := .binderRef 0 1
def rr : EvidenceExprV2 := .binderRef 0 2
def fid : CallableId := CallableId.ofUser "m" "f"

#eval show Lean.MetaM Unit from do
  let ex ← ctorsOf ``Concrete.Proof.EvidenceExprV2
  let st ← ctorsOf ``Concrete.Proof.EvidenceStmtV2
  let ar ← ctorsOf ``Concrete.Proof.EvidenceArmV2
  -- FAIL-CLOSED REPRESENTABILITY. Without a `gap` at a level, a producer meeting an
  -- unknown construct there has no honest option and will emit nothing — the silent
  -- under-approximation measured on the flat serializer.
  a s!"EvidenceExprV2 has a gap constructor ({ex.length} ctors)"
    (ex.any fun c => c.toString.endsWith ".gap")
  a s!"EvidenceStmtV2 has a gap constructor ({st.length} ctors)"
    (st.any fun c => c.toString.endsWith ".gap")
  a s!"EvidenceArmV2 has a gap constructor ({ar.length} ctors)"
    (ar.any fun c => c.toString.endsWith ".gap")

#eval do
  -- THE REASON IT IS A TREE. A flat node stream cannot tell these apart.
  a "differently-nested binaries are different values"
    (shape (.binary "add" (.binary "mul" p q) rr)
      != shape (.binary "add" p (.binary "mul" q rr)))
  a "argument ORDER in a call is semantic"
    (shape (.call fid [p, q]) != shape (.call fid [q, p]))
  a "operand order in a binary is semantic"
    (shape (.binary "sub" p q) != shape (.binary "sub" q p))
  a "distinct literals are distinct evidence"
    (shape (.intLit 1) != shape (.intLit 2))
  a "a gap is distinguishable from any real expression"
    (shape (.gap (.unhandledConstruct "x")) != shape p)
  -- Control: the injection is not collapsing everything to one string.
  a "the injection distinguishes structurally different trees"
    ((shape p != shape q) && (shape p != shape (.deref p)))
LEAN

OUT="$TMP_DIR/out.txt"
if ! lake env lean "$TMP_DIR/p.lean" > "$OUT" 2>&1; then
  echo "FATAL: evidence-tree probe did not elaborate" >&2; grep -m3 "error" "$OUT" >&2; exit 1
fi
if grep -qE "error|sorry" "$OUT"; then
  echo "FATAL: probe emitted a diagnostic" >&2; grep -m3 "error" "$OUT" >&2; exit 1
fi
cat "$OUT"
PASS=$(( PASS + $(grep -c '^  ok   ' "$OUT" || true) ))

# Bound NAMES must have nowhere to live. Alpha-invariance by construction beats a
# normalization pass that can be forgotten.
if grep -qE "letBind .*\(name" Concrete/Proof/EvidenceTree.lean; then
  no "letBind carries a source name — alpha-invariance would depend on normalization"
else
  ok "letBind has no name field; a bound name cannot enter the tree"
fi
if grep -q "bindingCount" Concrete/Proof/EvidenceTree.lean; then
  ok "arm patterns record a binding COUNT, not binding names"
else
  no "arm patterns do not use a positional binding count"
fi
# Loop contracts must be part of the body, or an invariant edit is invisible.
if grep -qE "loop .*invariants" Concrete/Proof/EvidenceTree.lean; then
  ok "loops carry their invariants, so an invariant edit changes the body"
else
  no "loops omit invariants — an invariant edit would be invisible to the subject"
fi
# No derived Repr/BEq across the MUTUAL tree. Scoped to the mutual block: EvidenceGap
# is a flat enum outside it and derives BEq/Repr legitimately — a first version of
# this leg flagged that and was wrong, not the code.
mutual_block="$(awk '/^mutual$/,/^end$/' Concrete/Proof/EvidenceTree.lean)"
if printf '%s' "$mutual_block" | grep -qE "^deriving (BEq|Repr)|deriving.*\bRepr\b.*\bBEq\b"; then
  no "the mutual tree derives BEq/Repr — a derived instance can absorb new constructors"
else
  ok "the mutual tree derives no BEq/Repr"
fi

echo "EVIDENCE-TREE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
