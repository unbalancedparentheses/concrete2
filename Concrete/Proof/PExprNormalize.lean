import Concrete.Proof.Proof
import Concrete.Proof.Sha256Spec

/-!
# Canonical PExpr normalization and content hashing

These live BELOW `DependencyEdge` in import order, and that placement is the whole point.

`tableEntryEvidence` (in `DependencyEdge`) has to recompute a body digest from the actual
`PFnDef.body` and refuse when it disagrees with the stored provenance — otherwise a body can be
replaced while keeping its callable identity AND its stored digest, and the join still binds,
because every other leg compares metadata against metadata. The producer it needs
(`normalizePExpr` then `shortHash`) used to sit in `ProofCore`, which imports `DependencyRoot`,
which imports `DependencyEdge`. Calling it from the consumer was an import cycle.

Extracted here rather than into `Proof.lean` for a measured reason: `ProofCore` is `namespace
Concrete` and `Proof.lean` is `namespace Concrete.Proof`, so moving these into `Proof.lean` would
rename `Concrete.normalizePExpr` and `Concrete.shortHash` and churn every call site. This module
keeps `namespace Concrete`, so the names do not move — only the file does.

Both blocks were moved verbatim; the four `private` helpers they use
(`pexprFreeIn`, `pexprSortKey`, `isCommutative`, `byteToHex`) had no other users in `ProofCore`,
so they came along and stay private to this module.
-/

namespace Concrete

/-- Bug 045: Elab alpha-renames match binders (`value` → `value.b7`).
    Fingerprints and extracted proof expressions must be INVARIANT under
    that renaming — otherwise editing an unrelated earlier match shifts
    the indices of later binders and falsely staleness-marks every proof
    link and spec downstream. Surface identifiers cannot contain '.', so
    stripping at the first '.' recovers the surface name exactly. -/
def stripAlpha (n : String) : String :=
  match n.splitOn "." with
  | base :: _ => base
  | [] => n

-- ============================================================
-- PExpr normalization
-- ============================================================

/-- Check whether a variable name occurs free in a PExpr. -/
private partial def pexprFreeIn (name : String) : Proof.PExpr → Bool
  | .lit _ => false
  | .var n => n == name
  | .binOp _ l r => pexprFreeIn name l || pexprFreeIn name r
  | .letIn n v b => pexprFreeIn name v || (n != name && pexprFreeIn name b)
  | .ifThenElse c t e => pexprFreeIn name c || pexprFreeIn name t || pexprFreeIn name e
  | .call _ args => args.any (pexprFreeIn name)
  -- The BINDING is itself a free occurrence: `f` in `f(x)` refers to the local
  -- `f`, so a normalizer that thinks `f` is unused could eliminate the very let
  -- that supplies it. `.call`'s name denotes a definition and is not free.
  | .applyVar binding args => binding == name || args.any (pexprFreeIn name)
  | .structLit _ fields => fields.any fun (_, fexpr) => pexprFreeIn name fexpr
  | .enumLit _ _ fields => fields.any fun (_, fexpr) => pexprFreeIn name fexpr
  | .fieldAccess obj _ => pexprFreeIn name obj
  | .arrayIndex arr idx => pexprFreeIn name arr || pexprFreeIn name idx
  | .match_ scrutinee arms =>
    pexprFreeIn name scrutinee ||
    arms.any fun (pat, body) =>
      -- An arm's pattern can shadow `name` via its bindings; if so,
      -- the body doesn't free-occur `name` even if textually present.
      let shadows := match pat with
        | .enumPat _ _ bindings => bindings.contains name
        | .varPat binding => binding == name
        | .litPat _ => false
      !shadows && pexprFreeIn name body
  | .cast inner => pexprFreeIn name inner
  | .arrayLit elems => elems.any (pexprFreeIn name)
  | .arraySet arr idx val =>
    pexprFreeIn name arr || pexprFreeIn name idx || pexprFreeIn name val
  | .while_ cond assigns cont =>
    -- An assign rebinds `name` (it does NOT shadow — the variable
    -- pre-existed). The right-hand expression and the cont can
    -- still free-occur `name`. Walk all three.
    pexprFreeIn name cond ||
    assigns.any (fun (_, e) => pexprFreeIn name e) ||
    pexprFreeIn name cont
  | .while_step cond _ step cont =>
    -- carried list documents rebinds but doesn't shadow (per while_).
    -- Walk cond, step, and cont.
    pexprFreeIn name cond ||
    pexprFreeIn name step ||
    pexprFreeIn name cont

/-- Ordering key for commutative canonicalization.
    vars sort before lits; among vars, alphabetical; among lits, by value. -/
private def pexprSortKey : Proof.PExpr → (Nat × String)
  | .var n => (0, n)
  | .lit (.int n) => (1, toString n)
  | .lit (.bool b) => (1, toString b)
  | _ => (2, "")  -- compound exprs stay in place

private def isCommutative : Proof.PBinOp → Bool
  | .add | .mul | .eq | .ne => true
  | _ => false

/-- Normalize a PExpr to canonical form for stable proof attachment.
    Applied once after Core→PExpr extraction, before storage.

    Rewrites (applied bottom-up):
    1. Dead let elimination:  let x = v; body  →  body  (when x ∉ FV(body))
    2. Algebraic identities:  x+0→x, 0+x→x, x*1→x, 1*x→x, x*0→0, 0*x→0, x-0→x
    3. Boolean short-circuit: if true then a else b → a, if false … → b
    4. Let flattening:        let x = (let y=v; e); body → let y=v; let x=e; body
    5. Commutative ordering:  add/mul/eq/ne operands sorted by (kind, name/value) -/
partial def normalizePExpr : Proof.PExpr → Proof.PExpr
  | .lit v => .lit v
  -- Bug 045: comparison is ALPHA-INVARIANT — Elab renames match binders
  -- (`value` → `value.b7`); committed specs/theorems use surface names.
  -- The kernel-facing extraction stays verbatim (R-03 pins it); only this
  -- normalizer, which both sides of the drift comparison run through,
  -- strips the suffix. Surface names cannot contain '.'.
  | .var n => .var (stripAlpha n)
  | .binOp op lhs rhs =>
    let l := normalizePExpr lhs
    let r := normalizePExpr rhs
    -- Algebraic identities
    match op, l, r with
    | .add, .lit (.int 0), x | .add, x, .lit (.int 0) => x
    | .sub, x, .lit (.int 0) => x
    | .mul, .lit (.int 1), x | .mul, x, .lit (.int 1) => x
    | .mul, .lit (.int 0), _ | .mul, _, .lit (.int 0) => .lit (.int 0)
    | _, _, _ =>
      -- Commutative canonicalization: sort operands
      if isCommutative op then
        let (ln, ls) := pexprSortKey l
        let (rn, rs) := pexprSortKey r
        let swap := ln > rn || (ln == rn && ls > rs)
        if swap then .binOp op r l
        else .binOp op l r
      else .binOp op l r
  | .letIn name val body =>
    let v := normalizePExpr val
    let b := normalizePExpr body
    -- Dead let elimination
    if !pexprFreeIn name b then b
    -- Let flattening: let x = (let y = v'; e); body → let y = v'; let x = e; body
    else match v with
    | .letIn innerName innerVal innerBody =>
      normalizePExpr (.letIn innerName innerVal (.letIn name innerBody b))
    | _ => .letIn name v b
  | .ifThenElse cond thenBr elseBr =>
    let c := normalizePExpr cond
    let t := normalizePExpr thenBr
    let e := normalizePExpr elseBr
    -- Boolean short-circuit
    match c with
    | .lit (.bool true) => t
    | .lit (.bool false) => e
    | _ => .ifThenElse c t e
  | .call fn args =>
    .call fn (args.map normalizePExpr)
  -- Alpha-stripped like `.var`: the binding is a LOCAL name, so Elab's
  -- `f` → `f.bN` renaming reaches it exactly as it reaches a variable
  -- occurrence. A `.call` name is a definition and must stay verbatim.
  | .applyVar binding args =>
    .applyVar (stripAlpha binding) (args.map normalizePExpr)
  | .structLit name fields =>
    .structLit name (fields.map fun (fname, fexpr) => (fname, normalizePExpr fexpr))
  | .enumLit enumName variant fields =>
    .enumLit enumName variant (fields.map fun (fname, fexpr) => (fname, normalizePExpr fexpr))
  | .fieldAccess obj field =>
    .fieldAccess (normalizePExpr obj) field
  | .arrayIndex arr idx =>
    .arrayIndex (normalizePExpr arr) (normalizePExpr idx)
  | .match_ scrutinee arms =>
    .match_ (normalizePExpr scrutinee)
      (arms.map fun (pat, body) =>
        let pat' := match pat with
          | .enumPat en v binds => .enumPat en v (binds.map stripAlpha)
          | .varPat b => .varPat (stripAlpha b)
          | other => other
        (pat', normalizePExpr body))
  | .cast inner => .cast (normalizePExpr inner)
  | .arrayLit elems => .arrayLit (elems.map normalizePExpr)
  | .arraySet arr idx val =>
    .arraySet (normalizePExpr arr) (normalizePExpr idx) (normalizePExpr val)
  | .while_ cond assigns cont =>
    .while_ (normalizePExpr cond)
      (assigns.map fun (n, e) => (n, normalizePExpr e))
      (normalizePExpr cont)
  | .while_step cond carried step cont =>
    .while_step (normalizePExpr cond) carried
      (normalizePExpr step)
      (normalizePExpr cont)

/-- Two-digit lowercase hex of a byte. -/
private def byteToHex (b : Sha256Spec.Byte) : String :=
  let digits := "0123456789abcdef".toList
  let n := b.toNat
  String.ofList [digits.getD (n / 16) '0', digits.getD (n % 16) '0']

/-- Compact, stable hex hash of a body fingerprint, for the in-source
    `#[proof_fingerprint("…")]` attribute. The full PExpr string is grotesque in
    source, so we store a digest. SHA-256 truncated to 128 bits: the previous
    64-bit non-cryptographic `String.hash` defended against accidental drift but
    not against a crafted body that collides with the recorded fingerprint —
    a silent stale→proved upgrade. Reuses the in-repo FIPS 180-4 spec
    (`Concrete.Sha256Spec`), so the digest needs no new trusted code. -/
def shortHash (fingerprint : String) : String :=
  let bytes : List Sha256Spec.Byte :=
    fingerprint.toUTF8.toList.map fun b => BitVec.ofNat 8 b.toNat
  let digest := (Sha256Spec.hash bytes).take 16
  String.join (digest.map byteToHex)

/-- THE canonical V1 source-body digest. One producer, and that is the point.

    This formula existed twice — `Report.renderSourceBodyDigest` and inline in
    `implementationManifestOf`. Two copies of a digest are worse than two copies of ordinary
    logic: the whole value of comparing an entry's stored digest against the manifest's is that
    both sides mean the same thing, and a drifted copy makes every comparison quietly answer a
    different question.

    NORMALIZE FIRST, so the digest is invariant under commutative reordering: two bodies differing
    only in the order of `+`'s operands denote the same body, and separating them would report
    drift where there is none.

    LIMIT: this establishes ARTIFACT binding and freshness. It does NOT establish semantic
    equivalence between a source body and a `PFnDef` — that is the source-to-proof-model
    faithfulness question, and matching digests are not an answer to it.

    **Now used by `tableEntryEvidence`**, which is the check that matters most. It used to read
    `PFnDef.sourceBodyDigest` and TRUST it rather than recomputing from `PFnDef.body`, so a
    substituted body retaining old metadata still bound. That needed this producer BELOW
    `DependencyEdge` in the import order, which is why it lives in `PExprNormalize` next to the
    `normalizePExpr` and `shortHash` it is built from, rather than in `ProofCore`. -/
def sourceBodyDigestV1Of (pe : Proof.PExpr) : String :=
  shortHash (Proof.pexprCanonical (normalizePExpr pe))

end Concrete
