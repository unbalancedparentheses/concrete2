import Concrete.Proof.DependencyEdge

/-!
# Per-edge correspondence — the closed join

`DependencyClosure` (docs/EVIDENCE_ARCHITECTURE.md) requires every compiler edge to have exactly
one validated justification, with missing, surplus, duplicate, ambiguous, unclassified and
mismatched retained as NAMED sets. This module is that join.

**Surplus is scoped to a closed operation, and the scoping is the whole design.** Surplus is
evidence supplied to a PARTICULAR correspondence operation that belongs to no requested edge or
witness slot in that operation. It is emphatically NOT "any table row this proof does not use": a
global classification table may hold entries for other proofs, a function table may hold
implementations this caller never reaches, and whole-table material may be intentionally bound for
dynamic lookup. None of those is surplus merely because one proof does not consume every entry.
The over-broad reading would manufacture refusals nobody can justify, which is why the boundary is
stated here rather than left to the implementation to imply.

**Ordering rule.** Witness identity is validated FIRST, then the exact join is attempted, and only
then is surplus computed. Unknown witnesses are never pre-filtered away — pre-filtering is how
surplus disappears while appearing handled.

**NOT WIRED TO PRODUCTION.** Nothing calls this yet. It cannot be fed from the real corpus until
the classification hand-back carries per-table ENTRY evidence (callee identity + body digest); today
a row names a table and its whole-table digest, so "does table T contain callee C" is unanswerable
compiler-side. The join and every refusal below are exercised by controls; the corpus wiring is
separate and is not claimed here.
-/

namespace Concrete.Proof

/-- One edge the compiler actually has, for which a justification is REQUESTED.

    Carries the callee, not merely a kind. The design sketch listed `requestedEdges : List
    DependencyEdge`, but a bare kind cannot be joined against anything — two edges of the same kind
    to different callees are different requests, and matching on kind alone is the caller-wide
    labelling this work exists to replace. -/
structure RequestedEdge where
  callee : CallableId
  kind   : DependencyEdge
  /-- A dynamically-indexed dependency. Its justification is whole-table material, because a
      dynamic index can reach ANY entry, so the dependency is on all of it. -/
  dynamic : Bool := false
deriving Repr, BEq

/-- What a witness claims to justify. -/
inductive WitnessTarget where
  /-- A specific call edge, by callee identity. -/
  | edgeTo (callee : CallableId)
  /-- Whole-table material for a dynamic edge. ONE justification with the entire table as its
      required material — entries inside are NOT independently expected to match call edges, and
      must not produce per-entry surplus. -/
  | wholeTable (table : String) (digest : String)
deriving Repr, BEq

/-- A justification returned by the theorem side for a particular subject. -/
structure EdgeWitness where
  /-- The subject this witness was returned FOR. Checked before the join: a witness naming another
      subject has failed identity validation and is not merely unused. -/
  subject : CallableId
  target  : WitnessTarget
  kind    : DependencyEdge
  /-- The theorem this witness came from, for diagnosis. Never an identity. -/
  source  : String := ""
deriving Repr, BEq

/-- A witness that cannot enter the join, with the exact field that failed. -/
inductive WitnessRefusal where
  /-- Returned for a different subject than the one being corresponded. -/
  | subjectMismatch (expected : CallableId) (found : CallableId)
  /-- Targets a requested callee, but claims a different edge KIND than the compiler recorded.
      This is the `mismatched` set at the witness level: the edge is real and the claim about it
      is wrong, which is different from having no witness at all. -/
  | kindMismatch (callee : CallableId) (requested : DependencyEdge) (claimed : DependencyEdge)
deriving Repr, BEq

def WitnessRefusal.explain : WitnessRefusal → String
  | .subjectMismatch e f => s!"witness for '{f.render}' offered while corresponding '{e.render}'"
  | .kindMismatch c r cl => s!"'{c.render}' is a {r.canonical} edge but its witness claims {cl.canonical}"

/-- One requested edge with the single valid witness that justifies it. -/
structure EdgeJustification where
  edge    : RequestedEdge
  witness : EdgeWitness
deriving Repr, BEq

/-- The closed correspondence request. -/
structure CorrespondenceInput where
  subject            : CallableId
  requestedEdges     : List RequestedEdge
  candidateWitnesses : List EdgeWitness

/-- All four sets retained, plus the witnesses that never entered the join.

    Retained rather than reduced to a Bool: "correspondence failed" does not say whether a proof is
    missing a dependency, claims one the compiler does not have, or was handed conflicting
    evidence — and those have different causes. -/
structure CorrespondenceResult where
  matched   : List EdgeJustification
  missing   : List RequestedEdge
  ambiguous : List (RequestedEdge × List EdgeWitness)
  surplus   : List EdgeWitness
  malformed : List WitnessRefusal

/-- Does this witness target this requested edge? Identity for static edges; whole-table material
    for dynamic ones. A `wholeTable` witness answers a DYNAMIC request and nothing else. -/
def witnessTargets (r : RequestedEdge) (w : EdgeWitness) : Bool :=
  match w.target with
  | .edgeTo c      => !r.dynamic && c == r.callee
  | .wholeTable _ _ => r.dynamic

/-- The closed join. Identity first, then exact matching, then surplus — in that order. -/
def correspond (i : CorrespondenceInput) : CorrespondenceResult :=
  -- STEP 1: identity validation. A witness for another subject never enters the join, and is NOT
  -- counted as surplus — surplus means "belonged to this operation and matched nothing", which is
  -- a different fact from "was never ours".
  let wrongSubject := i.candidateWitnesses.filter (fun w => w.subject != i.subject)
  let ours := i.candidateWitnesses.filter (fun w => w.subject == i.subject)
  let subjectRefusals := wrongSubject.map (fun w => WitnessRefusal.subjectMismatch i.subject w.subject)
  -- STEP 2: exact join, per requested edge.
  let perEdge := i.requestedEdges.map (fun r => (r, ours.filter (witnessTargets r)))
  let kindRefusals := perEdge.flatMap (fun (r, ws) =>
    (ws.filter (fun w => w.kind != r.kind)).map (fun w =>
      WitnessRefusal.kindMismatch r.callee r.kind w.kind))
  -- A witness whose KIND disagrees is not a valid justification, so the edge it targets has none.
  -- It is recorded in `malformed` AND its edge falls to `missing`: the edge genuinely lacks a valid
  -- justification, and saying so is not double-counting — one fact is about the witness, the other
  -- about the edge.
  let validFor := fun (r : RequestedEdge) (ws : List EdgeWitness) => ws.filter (fun w => w.kind == r.kind)
  let matched := perEdge.filterMap (fun (r, ws) =>
    match validFor r ws with
    | [w] => some ({ edge := r, witness := w } : EdgeJustification)
    | _   => none)
  let missing := perEdge.filterMap (fun (r, ws) =>
    if (validFor r ws).isEmpty then some r else none)
  let ambiguous := perEdge.filterMap (fun (r, ws) =>
    match validFor r ws with
    | _ :: _ :: _ => some (r, validFor r ws)
    | _           => none)
  -- STEP 3: surplus, LAST. A witness of ours consumed by no requested edge. Computed by asking each
  -- witness whether any request took it — never by pre-filtering the candidate list, which would
  -- make surplus vanish rather than be reported.
  let surplus := ours.filter (fun w => !(i.requestedEdges.any (fun r => witnessTargets r w)))
  { matched := matched, missing := missing, ambiguous := ambiguous, surplus := surplus
  , malformed := subjectRefusals ++ kindRefusals }

/-- Usable only when every set is empty and the count is exact.

    `matched.length == requestedEdges.length` is asserted in addition to the empty sets, rather than
    inferred from them: a join that silently dropped a request would leave all four sets empty while
    covering less than was asked. The denominator is compared, not assumed — the same discipline the
    manifest accounting needed. -/
def CorrespondenceResult.usable (r : CorrespondenceResult) (requested : Nat) : Bool :=
  r.missing.isEmpty && r.ambiguous.isEmpty && r.surplus.isEmpty && r.malformed.isEmpty
    && r.matched.length == requested

end Concrete.Proof
