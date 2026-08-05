#!/usr/bin/env bash
# R-0004: binder references emitted during elaboration, as RELATIVE lexical
# positions.
#
# Three forcing properties, because each is satisfiable by a broken producer that
# passes the other two:
#   1. A scope that binds NOTHING must not shift framesOut.
#   2. Binding TIMING is construct-specific — lets, loop variables and arm patterns
#      are not interchangeable, and testing only lets proves nothing about arms.
#   3. A construct that cannot be given a semantic identity must mark the subject
#      UNCOVERED, never silently emit nothing.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fatal() {
  local rc=$?
  echo "FATAL: check_binder_refs stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2
  exit "$rc"
}
trap fatal ERR

PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/p.lean" <<'LEAN'
import Concrete
open Concrete Concrete.Proof

def a (label : String) (c : Bool) : IO Unit :=
  if c then IO.println ("  ok   " ++ label)
  else throw (IO.userError ("FAILED: " ++ label))

def facts (s : String) : Option ProofBodyIdentityInputsV2 :=
  match (do
    let parsed ← Pipeline.parse s
    let summary := Pipeline.buildSummary parsed
    let resolved ← Pipeline.resolve parsed summary
    Pipeline.check resolved summary
    let el ← Pipeline.elaborate resolved summary
    pure el.coreModules : Except Diagnostics (List CModule)) with
  | .error _ => none
  | .ok ms => (ms.head?.bind (·.declFacts.head?)).map (·.bodyIdentityInputs)

def binders (s : String) : List BodyIdentityUse :=
  (((facts s).map ProofBodyIdentityInputsV2.uses).getD []).filter fun u =>
    match u with | .binderRef _ _ => true | _ => false

def noBind : String :=
  "mod m { pub fn f(p: Int) -> Int { if p > 0 { return p; } return p; } }"
def withLet : String :=
  "mod m { pub fn f(p: Int) -> Int { let q: Int = p; return q; } }"
def renamed : String :=
  "mod m { pub fn f(p: Int) -> Int { let zzz: Int = p; return zzz; } }"
def loopVar : String :=
  "mod m { pub fn f(p: Int) -> Int { let mut i: Int = 0; while i < p { i = i + 1; } return i; } }"
-- The DISCRIMINATOR for arm frames: from inside an arm, reach the outer parameter.
-- Without this, an arm binding at (0,0) is indistinguishable from a binding that
-- landed in the enclosing frame — the ambiguity that hid the missing push at first.
def outerFromArm : String :=
  "mod m {
     enum Copy E { A { v: Int }, B { v: Int } }
     pub fn f(e: E, p: Int) -> Int { match e { E::A { v } => { return p; }, E::B { v } => { return v; } } }
   }"

#eval do
  -- Sanity FIRST: an empty binder list would make every leg below vacuous.
  a "the producer emits binder references at all"
    ((binders withLet).length > 0)

  -- CHECK 1. Every reference stays at framesOut 0: the `if` binds nothing, so it
  -- materializes no frame. An eager push-per-block would report 1 here and move
  -- digests for a semantically irrelevant edit.
  a "a scope that binds nothing does not shift framesOut"
    ((binders noBind).all fun u => match u with
      | .binderRef out _ => out == 0
      | _ => true)

  -- CHECK 2a. Progressive indexing: the let is a LATER binder than the parameter.
  a "a let binds after the parameters, in source order"
    (binders withLet == [BodyIdentityUse.binderRef 0 0, BodyIdentityUse.binderRef 0 1])
  a "renaming the local leaves the positions identical"
    (binders withLet == binders renamed)
  a "the rename probe genuinely changed the program"
    (withLet != renamed)

  -- CHECK 2b. A loop variable is an ordinary binder of its enclosing block, and is
  -- in scope in the loop CONDITION — a different timing answer than a let's own
  -- initializer, which is why lets alone prove nothing here.
  a "a loop variable is in scope in the condition and the body"
    ((binders loopVar).length == 4
      && (binders loopVar).all fun u => match u with
           | .binderRef out i => out == 0 && (i == 0 || i == 1)
           | _ => true)

  -- CHECK 2c. Arm patterns open their OWN frame, proved by crossing outward.
  a "an arm pattern opens a frame — an outer binder is one frame out"
    (binders outerFromArm == [BodyIdentityUse.binderRef 0 0,
      BodyIdentityUse.binderRef 1 1, BodyIdentityUse.binderRef 0 0])
  a "arm bodies stay covered"
    (((facts outerFromArm).map ProofBodyIdentityInputsV2.covered) == some true)
LEAN

OUT="$TMP_DIR/out.txt"
if ! lake env lean "$TMP_DIR/p.lean" > "$OUT" 2>&1; then
  echo "FATAL: binder-ref probe did not elaborate" >&2; sed -n '1,12p' "$OUT" >&2; exit 1
fi
if grep -qE "error|sorry" "$OUT"; then
  echo "FATAL: probe emitted a diagnostic" >&2; sed -n '1,10p' "$OUT" >&2; exit 1
fi
cat "$OUT"
PASS=$(( PASS + $(grep -c '^  ok   ' "$OUT" || true) ))

# CHECK 3, structurally: the local-reference path must not be able to emit nothing.
# Every scope-resolution failure has to reach markBodyIdentityUncovered, or a binder
# the frame stack cannot place would silently vanish from the body — an
# under-approximated subject, which is worse than an uncovered one because it looks
# complete.
ident_arm="$(awk '/A local reference is a BINDER reference/,/return \.ident/' Concrete/Elab/Elab.lean)"
if printf '%s' "$ident_arm" | grep -q "markBodyIdentityUncovered"; then
  ok "an unplaceable local marks the subject uncovered rather than emitting nothing"
else
  no "the local-reference path has no uncovered branch — a missing binder would vanish silently"
fi
if printf '%s' "$ident_arm" | grep -q "recordBodyIdentityUse (.binderRef"; then
  ok "a placeable local emits a typed binderRef node"
else
  no "the local-reference path does not emit a binderRef"
fi

# Frames must open lazily. An eager push would satisfy every positional leg above
# while breaking CHECK 1, so assert the mechanism, not only its outputs.
if grep -q "pendingFrame" Concrete/Elab/Elab.lean; then
  ok "frames open lazily via pendingFrame, so empty scopes cost nothing"
else
  no "no lazy-frame mechanism — a non-binding scope would shift framesOut"
fi

# ONE PRODUCER. Every semantic child edge inside the evidence-producing mutual block
# must call elabExprEv; a Core-only projection there would silently discard the child's
# evidence and still compile, so the count is asserted rather than trusted.
blk="$(python3 - <<'PYEOF'
lines=open('Concrete/Elab/Elab.lean').read().split('\n')
s=e=None
for i,l in enumerate(lines):
    if l=='mutual' and s is None: s=i
    elif l=='end' and s is not None: e=i; break
print('\n'.join(lines[s:e]))
PYEOF
)"
stale=$(printf '%s' "$blk" | grep -cE '\belabExpr[^E]' || true)
if [ "$stale" -eq 0 ]; then
  ok "no Core-only elabExpr projection inside the producing block"
else
  no "$stale Core-only elabExpr call(s) inside the producing block — child evidence would be discarded"
fi

# The pairing types must live where CExpr is genuinely in scope. Declaring them in the
# Proof layer made Lean AUTO-BIND CExpr as an implicit type variable, so the structure
# was polymorphic over a made-up type and its core field landed in Prop — invisible
# until something constructed it.
if grep -q "ElaboratedExprV2" Concrete/Proof/EvidenceTree.lean; then
  no "the Proof layer declares ElaboratedExprV2; CExpr is not in scope there and gets auto-bound"
else
  ok "the pairing types live on the Elab side, where CExpr is in scope"
fi

echo "BINDER-REFS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
