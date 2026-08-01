#!/usr/bin/env bash
# R-0004 slice 5 step 1 — facts captured BEFORE contract erasure.
#
# `CFnDef` drops requires/ensures, type bounds and capability parameters. Those
# are exactly the facts bugs 059 and 060 are filed against, so a subject digest
# must be defined from a record captured while they still exist — not recomputed
# in Report, which would define a semantic fact inside the layer that renders
# semantic facts.
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
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
  # Match a LEAN DIAGNOSTIC, not the bare word: `Except.error` is a legitimate
  # value and matching "error" made every probe of a refusal a false negative —
  # the vacuity guard corrupting the measurement it exists to protect.
  if grep -qE "error:|error\(lean" <<<"$out"; then
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
'#eval
  let e := contractCanonicalIn ["a", "b"] [] [] false (fun _ => none)
  (e (.binOp sp .lt (.ident sp "a") (.ident sp "b")))
    != (e (.binOp sp .lt (.ident sp "b") (.ident sp "a")))'
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
'#eval (ContractFacts.ofResolved ["r"] [] [] (fun _ => none) []
        [.binOp sp .eq (.ident sp "r") (.intLit sp 1)]).covered'
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
echo "=== the digest is defined ONCE, and sees what the legacy hash cannot ==="
# Side by side with the defect. The legacy body fingerprint is blind to both of
# these; that blindness IS bugs 059 and 060.
probe "059: a signature change moves the subject digest with an identical body" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", retTy := "i32" }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", retTy := "u32" }
  proofSubjectDigestV2 a "SAME" != proofSubjectDigestV2 b "SAME"'
probe "060: a TRUE/FALSE ensures flip moves it with an identical body" "true" \
'#eval
  let t : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := ContractFacts.of [] [.binOp sp .eq (.ident sp "result") (.intLit sp 1)] }
  let f : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := ContractFacts.of [] [.binOp sp .eq (.ident sp "result") (.intLit sp 0)] }
  proofSubjectDigestV2 t "SAME" != proofSubjectDigestV2 f "SAME"'
# It must not LOSE what the legacy hash did catch.
probe "a body change is still detected" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" }
  proofSubjectDigestV2 a "ONE" != proofSubjectDigestV2 a "TWO"'
# The schema tag must be in the bytes, so a stored v1 hash is recognisable as a
# DIFFERENT SCHEMA rather than as a mismatch — that is what makes `needs_recheck`
# possible instead of a false `stale`.
probe "the subject digest is not the bare body hash" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" }
  proofSubjectDigestV2 a "B" != shortHash "B"'

echo ""
echo "=== completeness is ENFORCED, not advisory ==="
# isComplete existed and nothing consulted it: an uncovered subject still got an
# ordinary-looking digest. A digest indistinguishable from a complete one IS a
# claim of completeness, whatever a neighbouring flag says.
probe "an uncovered contract yields NO digest" "none" \
'#eval
  let f : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := ContractFacts.of [] [.arrayLit sp [.intLit sp 1]] }
  proofSubjectDigestV2 f "B"'
probe "a complete subject yields a digest" "some" \
'#eval
  let f : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" }
  proofSubjectDigestV2 f "B"'
# an incomplete IDENTITY (type-erased generic) must refuse too
probe "an incomplete identity yields NO digest" "none" \
'#eval
  let f : CheckedDeclFacts := { id := CallableId.ofUser "m" "f" 1 }
  proofSubjectDigestV2 f "B"'
# loop contracts are part of the subject: R-0004 names them, and they are erased
# with requires/ensures
probe "a loop invariant change moves the subject" "true" \
'#eval
  let a : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := { loops := ["inv:A"] } }
  let b : CheckedDeclFacts := { id := CallableId.ofUser "m" "f", contracts := { loops := ["inv:B"] } }
  a.canonical != b.canonical'

echo ""
echo "=== spec fns are resolvable contract targets, in their own namespace ==="
# `spec fn` declarations are bodyless abstractions whose meaning comes from Lean.
# They were in none of the resolution tables, so every contract mentioning one
# resolved to nothing and made the whole subject UNCOVERED — measured on
# hmac_sha256, a flagship, whose `result == ch_spec(x, y, z)` put two entries
# outside the digest entirely.
CC=".lake/build/bin/concrete"
HM="examples/hmac_sha256/src/main.con"
# CAPTURE stderr and CLASSIFY it. The earlier version used 2>/dev/null, so a run
# emitting 11 diagnostics still read as clean. Hiding a channel is not the same as
# knowing what is on it.
HM_OUT="$TMP/hm.out"; HM_ERR="$TMP/hm.err"
"$CC" "$HM" --report subject-facts >"$HM_OUT" 2>"$HM_ERR"
n_entries=$(grep -c '^v1:' "$HM_OUT" || true)
[ "$n_entries" = "23" ] \
  && ok "hmac_sha256 reports exactly 23 subjects" \
  || no "expected exactly 23 hmac_sha256 subjects, got $n_entries"
inc=$(grep -cE "INCOMPLETE|ABSENT" "$HM_OUT" || true)
[ "$inc" = "0" ] \
  && ok "hmac_sha256 has no incomplete or absent subjects" \
  || no "$inc hmac_sha256 subjects are incomplete/absent — contracts are escaping the digest"
withc=$(grep -c "ens: 1" "$HM_OUT" || true)
[ "$withc" = "2" ] \
  && ok "hmac_sha256 has exactly 2 contract-bearing subjects" \
  || no "expected exactly 2 contract-bearing hmac_sha256 subjects, got $withc"
# Every stderr line must be an EXPECTED kind. The unbound-proof-subject errors are
# bug 058's containment working (a #[proof_by] with no #[proof_fingerprint] is
# unbound, not proved); anything else is unclassified and must fail.
tot_err=$(grep -c "^error:" "$HM_ERR" || true)
unbound=$(grep -c "has no stored proof subject" "$HM_ERR" || true)
if [ "$tot_err" = "$unbound" ]; then
  ok "all $tot_err stderr diagnostics are the expected unbound-proof-subject kind (bug 058 containment)"
else
  no "stderr carries $((tot_err - unbound)) UNCLASSIFIED diagnostic(s) beyond the $unbound expected"
fi

echo ""
echo "=== a name meaning two callables fails closed, with controls ==="
# Ambiguity was implemented but only inspection-verified. This fixture declares
# `dup` as BOTH a spec fn and an ordinary function; a contract naming it cannot
# say which, and resolving by table order would put an abstraction where an
# implementation was meant. The controls are what stop "uncovered" from being an
# artifact of the fixture.
AMB="tests/programs/subject_spec_name_ambiguity.con"
[ -f "$AMB" ] && ok "the ambiguity fixture is committed" || no "ambiguity fixture missing"
AMB_OUT="$TMP/amb.out"
"$CC" "$AMB" --report subject-facts >"$AMB_OUT" 2>/dev/null
amb_cov=$(grep -A7 '^v1:user:amb.uses_ambiguous$' "$AMB_OUT" 2>/dev/null | grep -oE "covered: (true|false)" | head -1 || true)
[ "$amb_cov" = "covered: false" ] \
  && ok "a contract naming an ambiguous callable is UNCOVERED" \
  || no "the ambiguous case is '$amb_cov' — order-dependent resolution is back"
for ctl in uses_spec uses_fn; do
  c=$(grep -A7 "^v1:user:amb.$ctl\$" "$AMB_OUT" | grep -oE "covered: (true|false)" | head -1)
  e=$(grep -A7 "^v1:user:amb.$ctl\$" "$AMB_OUT" | grep -oE "ens: [0-9]+" | head -1)
  if [ "$c" = "covered: true" ] && [ "$e" = "ens: 1" ]; then
    ok "control $ctl resolves unambiguously and stays covered"
  else
    no "control $ctl is '$c'/'$e' — uncovered may be an artifact, not the ambiguity"
  fi
done

probe "a spec fn gets its own namespace" "false" \
'#eval (CallableId.ofSpec "m" "f").render == (CallableId.ofUser "m" "f").render'
probe "the namespace list covers every constructor" "true" \
'#eval CallableNamespace.all.length == 5
  && (CallableNamespace.all.map CallableNamespace.canonical).eraseDups.length == 5'

echo ""
echo "=== a free identifier is not a name in the bytes ==="
# `.ident` used to emit `g<len>:<name>` for anything the declaration did not
# bind — a raw source name straight into evidence, the same defect class as the
# call names `resolveCall` already fixed, one layer down. Two constants sharing a
# spelling would have digested alike.
FID="tests/programs/subject_free_identifier.con"
[ -f "$FID" ] && ok "the free-identifier fixture is committed" || no "free-identifier fixture missing"
fid_cov=$("$CC" "$FID" --report subject-facts 2>/dev/null | grep -A7 "fid.clamp" | grep -oE "covered: (true|false)" | head -1 || true)
[ "$fid_cov" = "covered: false" ] \
  && ok "a contract naming an unresolved constant is UNCOVERED, not textual" \
  || no "a free identifier is '$fid_cov' — a source name may be entering the digest"
# LOOP BINDERS ARE BINDERS. Encoding a loop's clauses with only the function's
# parameters in scope made `#[invariant(0 <= i && i <= 16)]` an unresolved free
# identifier and took the whole subject out — measured on constant_time_tag.
for ex in constant_time_tag hmac_sha256 crypto_verify elf_header parse_validate fixed_capacity; do
  n=$("$CC" "examples/$ex/src/main.con" --report subject-facts 2>/dev/null | grep -cE "INCOMPLETE" || true)
  [ "$n" = "0" ] || no "$ex has $n incomplete subjects"
done
allz=$(for ex in constant_time_tag hmac_sha256 crypto_verify elf_header parse_validate fixed_capacity; do
  "$CC" "examples/$ex/src/main.con" --report subject-facts 2>/dev/null | grep -cE "INCOMPLETE" || true; done | paste -sd+ - | bc)
[ "$allz" = "0" ] \
  && ok "no flagship example has an incomplete subject (loop binders in scope)" \
  || no "$allz incomplete subjects across the flagships"

echo ""
echo "=== loop contracts reach the subject FROM SOURCE ==="
# The field existed and nothing read `f.loopContracts`, so the earlier check only
# proved the field affects canonicalization — not that a source invariant reaches
# it. This drives a real program and edits a real invariant.
CC=".lake/build/bin/concrete"
CT="examples/constant_time_tag/src/main.con"
nloops=$("$CC" "$CT" --report subject-facts 2>/dev/null | grep -oE "loopClauses: [0-9]+" | head -1 | grep -oE "[0-9]+")
# EXACT structure, not "> 0". constant_time_tag's ct_compare has ONE loop with
# ONE invariant and ONE variant, so the encoded clause count is 2 — "loops: 2" is
# a count of CLAUSES, not of loops, and reading it as two loops was my
# mislabelling. A `> 0` assertion would pass on any miscount.
[ "${nloops:-0}" = "2" ] \
  && ok "ct_compare contributes exactly 2 loop clauses (1 invariant + 1 variant)" \
  || no "expected 2 loop clauses for ct_compare, got ${nloops:-0}"
WORK="$TMP/ctedit"; mkdir -p "$WORK"; cp -r examples/constant_time_tag "$WORK/ct"
D1=$("$CC" "$WORK/ct/src/main.con" --report subject-facts 2>/dev/null | grep "subject digest" | head -1)
python3 - "$WORK/ct/src/main.con" <<'PYEOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'(#\[invariant\([^)]*?)0 <= i', r'\g<1>1 <= i', s, count=1)
open(p,'w').write(s2)
PYEOF
D2=$("$CC" "$WORK/ct/src/main.con" --report subject-facts 2>/dev/null | grep "subject digest" | head -1)
[ -n "$D1" ] && [ "$D1" != "$D2" ] \
  && ok "editing a source invariant moves the subject digest" \
  || no "a source invariant edit did NOT move the digest ($D1 vs $D2)"

echo ""
echo "=== threaded, not recomputed ==="
if grep -q "declFacts.find?" "$ROOT_DIR/Concrete/Proof/ProofCore.lean"; then
  ok "ProofCore reads the facts off the module by IDENTITY"
else
  no "ProofCore does not read threaded facts — they would have to be rebuilt"
fi
if grep -q "subjectDigest" "$ROOT_DIR/Concrete/Proof/ProofCore.lean"; then
  ok "entries carry the subject digest"
else
  no "entries do not carry a subject digest"
fi
# STILL OPEN, asserted as a tripwire so "the digest exists" cannot read as "the
# bugs are closed". The freshness decision still compares the BODY fingerprint.
if grep -q "if shortHash currentFp != h then" "$ROOT_DIR/Concrete/Proof/ProofCore.lean"; then
  ok "TRIPWIRE: freshness still compares the body fingerprint — 059/060 remain OPEN"
else
  no "the freshness comparison changed: v1 stored hashes must become needs_recheck, never stale, and backfill only from kernel replay"
fi

GATE_DONE=1
echo ""
echo "SUBJECT-FACTS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
