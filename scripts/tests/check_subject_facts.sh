#!/usr/bin/env bash
# R-0004 slice 5 step 1 — facts captured BEFORE contract erasure.
#
# `CFnDef` drops requires/ensures, type bounds and capability parameters. Those
# are exactly the facts bugs 059 and 060 are filed against, so a subject digest
# must be defined from a record captured while they still exist — not recomputed
# in Report, which would define a semantic fact inside the layer that renders
# semantic facts.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
probe() {
  local label="$1" want="$2" body="$3"
  cat > "$TMP/p.lean" <<LEAN
import Concrete
open Concrete Concrete.Proof
def sp : Span := default
$body
LEAN
  local out; out="$(lake env lean "$TMP/p.lean" 2>&1 || true)"
  if grep -qE "error" <<<"$out"; then
    no "$label — probe did not elaborate: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  elif grep -qF -- "$want" <<<"$out"; then ok "$label"
  else no "$label — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fi
}

echo "=== contracts are encoded, and bug 060's shape is distinguishable ==="
# A TRUE and a FALSE #[ensures] currently digest ALIKE — that is bug 060. The
# encoder must tell them apart, or nothing built on it can.
probe "a TRUE and a FALSE ensures encode differently" "true" \
'#eval (contractCanonical (.binOp sp .eq (.ident sp "result") (.intLit sp 1)))
    != (contractCanonical (.binOp sp .eq (.ident sp "result") (.intLit sp 0)))'
# Operand order is semantic for comparisons — a < b is not b < a.
probe "operand order is preserved for a non-commutative comparison" "true" \
'#eval (contractCanonical (.binOp sp .lt (.ident sp "a") (.ident sp "b")))
    != (contractCanonical (.binOp sp .lt (.ident sp "b") (.ident sp "a")))'
# Width variants are different OPERATIONS, not spellings.
probe "wrapping and saturating add are different operations" "true" \
'#eval binOpTag BinOp.wrappingAdd != binOpTag BinOp.saturatingAdd'

echo ""
echo "=== outside the fragment, the encoding is UNAVAILABLE, not approximate ==="
# Silently skipping an unreadable node yields a digest blind to the edit it must
# detect. `none` forces the containing record to declare itself uncovered.
probe "an out-of-fragment expression does not encode" "none" \
'#eval contractCanonical (.arrayLit sp [.intLit sp 1])'
probe "one unencodable contract makes the whole set uncovered" "false" \
'#eval (ContractFacts.of [] [.arrayLit sp [.intLit sp 1]]).covered'
probe "an encodable set stays covered" "true" \
'#eval (ContractFacts.of [] [.binOp sp .eq (.ident sp "r") (.intLit sp 1)]).covered'
# "could not read the contracts" and "there are no contracts" are DIFFERENT
# states; a digest that merges them lets an unreadable contract pass as absent.
probe "uncovered and genuinely-absent contracts do not digest alike" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := ContractFacts.of [] [.arrayLit sp [.intLit sp 1]] }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" }
  a.canonical != b.canonical'

echo ""
echo "=== the facts cover what bug 059 says the body hash omits ==="
# 059: the fingerprint omits parameters, return type, generics/bounds and
# capabilities. Each must move the canonical form.
probe "a return-type change moves the facts" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", retTy := "i32" }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", retTy := "u32" }
  a.canonical != b.canonical'
probe "a parameter type change moves the facts" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", params := [("x", "i32")] }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", params := [("x", "u32")] }
  a.canonical != b.canonical'
probe "a capability change moves the facts" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", capSet := ["File"] }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", capSet := ["File", "Net"] }
  a.canonical != b.canonical'
probe "a generic bound change moves the facts" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" 1, typeBounds := [("T", ["Copy"])] }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" 1, typeBounds := [("T", ["Destroy"])] }
  a.canonical != b.canonical'
probe "losing a trust boundary moves the facts" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", isTrusted := true }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", isTrusted := false }
  a.canonical != b.canonical'

echo ""
echo "=== keyed by identity, not by name ==="
probe "lookup resolves by CallableId" "true" \
'#eval
  let d : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" }
  let p : ProgramFacts := { decls := [d] }
  (p.find? (CallableId.ofUser "m" "f")).isSome && (p.find? (CallableId.ofUser "other" "f")).isNone'

echo ""
echo "=== the producer runs at the erasure point, not downstream ==="
# The facts must be built where requires/ensures still exist. If this moves into
# Report, the definition of a semantic fact has moved into the rendering layer.
if grep -q "declFacts" "$ROOT_DIR/Concrete/Elab/Elab.lean"; then
  ok "Elab (pre-erasure) populates declFacts"
else
  no "declFacts is not populated in Elab — the facts would have to be rebuilt downstream"
fi
if grep -q "declFacts" "$ROOT_DIR/Concrete/Elab/Core.lean"; then
  ok "CModule carries declFacts as a parallel record"
else
  no "CModule does not carry declFacts"
fi
# And they must NOT have been bolted onto CFnDef: Core excludes contracts on
# purpose and no codegen path consumes them.
if grep -A26 "^structure CFnDef" "$ROOT_DIR/Concrete/Elab/Core.lean" | grep -qE "requires|ensures"; then
  no "CFnDef gained contracts — Core excludes them deliberately; keep facts parallel"
else
  ok "CFnDef did NOT gain contracts; the facts stay a parallel record"
fi

echo ""
echo "SUBJECT-FACTS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
