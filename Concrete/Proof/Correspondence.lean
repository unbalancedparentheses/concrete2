import Concrete.Proof.DependencyEdge
import Concrete.Proof.TableResolve
import Concrete.Proof.DefinitionIdentity

/-!
# Per-edge correspondence — the closed join

`DependencyClosure` (docs/verification/EVIDENCE_ARCHITECTURE.md) requires every compiler edge to have exactly
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

**WIRED TO PRODUCTION AS OF 2026-08-15.** `applyCorrespondenceAuthority` consumes this join: a claim
may be `proved` only if every edge in its closure is justified here. The paragraph that used to sit
in this place said the opposite — "nothing calls this yet", and that the corpus could not feed it
until the hand-back carried per-table entry evidence. Both conditions were met and the note was not
updated, which is exactly the drift the docs-drift gate exists to catch one layer up.

The join is keyed on `DefinitionIdentity`, so "does table T contain callee C" is answered by
`scopedEntryEvidenceForTable` over attested entries — never by a source name.
-/

namespace Concrete.Proof

/-- One edge the compiler actually has, for which a justification is REQUESTED.

    Carries the callee, not merely a kind. The design sketch listed `requestedEdges : List
    DependencyEdge`, but a bare kind cannot be joined against anything — two edges of the same kind
    to different callees are different requests, and matching on kind alone is the caller-wide
    labelling this work exists to replace. -/
structure RequestedEdge where
  /-- WHICH DEFINITION the edge points at, all four identity components. This is the join key, and
      it replaced a `CallableId` — a source NAME, which denotes different functions in different
      programs. `elf_header` and `proof_pressure` both define `main.validate_header` and both render
      `v1:user:main.validate_header`; a shared proof table could justify one program's edge with the
      other program's implementation on name agreement alone. -/
  callee : DefinitionIdentity
  /-- The compiler-local NAME, for diagnosis only. NEVER compared: it exists so a refusal can say
      which edge failed in terms a reader recognises. Comparing it would restore the join this type
      migration removed. -/
  label  : CallableId
  kind   : DependencyEdge
  /-- A dynamically-indexed dependency. Its justification is whole-table material, because a
      dynamic index can reach ANY entry, so the dependency is on all of it. -/
  dynamic : Bool := false
  /-- For a dynamic edge, WHICH table and which entry-derived digest the compiler expects, as
      `(tableName, entryTableDigest)`.

      Without this a dynamic request accepted ANY whole-table witness: the exemption that stops a
      bound table producing per-entry surplus also stopped it being checked at all, so a witness
      naming an unrelated table justified a dynamic edge. The expectation is the table's IDENTITY
      and its digest together — a name alone would match a stale table, a digest alone would match
      a different table with identical membership. -/
  expectedTable : Option (String × String) := none
deriving Repr, BEq

/-- What a witness claims to justify. -/
inductive WitnessTarget where
  /-- A specific call edge, by callee identity. -/
  | edgeTo (callee : DefinitionIdentity)
  /-- Whole-table material for a dynamic edge. ONE justification with the entire table as its
      required material — entries inside are NOT independently expected to match call edges, and
      must not produce per-entry surplus. -/
  | wholeTable (table : String) (digest : String)
deriving Repr, BEq

/-- A justification returned by the theorem side for a particular subject. -/
structure EdgeWitness where
  /-- The subject this witness was returned FOR. Checked before the join: a witness naming another
      subject has failed identity validation and is not merely unused. -/
  subject : DefinitionIdentity
  target  : WitnessTarget
  kind    : DependencyEdge
  /-- The theorem this witness came from, for diagnosis. Never an identity. -/
  source  : String := ""
deriving Repr, BEq

/-- A witness that cannot enter the join, with the exact field that failed. -/
inductive WitnessRefusal where
  /-- Returned for a different subject than the one being corresponded. -/
  | subjectMismatch (expected : DefinitionIdentity) (found : DefinitionIdentity)
  /-- Targets a requested callee, but claims a different edge KIND than the compiler recorded.
      This is the `mismatched` set at the witness level: the edge is real and the claim about it
      is wrong, which is different from having no witness at all. -/
  | kindMismatch (callee : DefinitionIdentity) (requested : DependencyEdge) (claimed : DependencyEdge)
  /-- A requested edge whose callee HAS NO SCOPED IDENTITY, so it cannot be keyed at all.

      Not `missing`. Missing says the compiler asked for a justification and none was offered;
      this says the request could not be formed, because the callee's implementation identity was
      never derivable. Collapsing the two would report an unkeyable edge as an unjustified one and
      send a reader looking for a witness that was never the problem. -/
  | unscopedCallee (callee : CallableId) (kind : DependencyEdge) (why : DefinitionIdentityRefusal)
deriving Repr, BEq

def WitnessRefusal.explain : WitnessRefusal → String
  | .subjectMismatch e f =>
      s!"witness for '{f.localName}' offered while corresponding '{e.localName}'"
  | .kindMismatch c r cl =>
      s!"'{c.localName}' is a {r.canonical} edge but its witness claims {cl.canonical}"
  | .unscopedCallee c k w =>
      s!"'{c.render}' ({k.canonical} edge) has no scoped identity: {w.explain} — the request cannot be keyed"

/-- One requested edge with the single valid witness that justifies it. -/
structure EdgeJustification where
  edge    : RequestedEdge
  witness : EdgeWitness
deriving Repr, BEq

/-- The closed correspondence request. -/
structure CorrespondenceInput where
  subject            : DefinitionIdentity
  requestedEdges     : List RequestedEdge
  /-- Edges the compiler HAS whose callee has no scoped identity. They cannot become
      `RequestedEdge`s — that type's key is a `DefinitionIdentity` and there is none — but they must
      not vanish either: an edge dropped before the join is a dependency the closure never examined
      while every set reads empty. They are carried, counted in the denominator, and block
      usability. -/
  unscopedEdges      : List (CallableId × DependencyEdge × DefinitionIdentityRefusal) := []
  candidateWitnesses : List EdgeWitness
  /-- Tables the witness builder NAMED but could not read, as typed refusals.

      Carried into the result rather than reported beside it. An unreadable table is not the absence
      of a dependency — it is a dependency whose material could not be examined — and while the
      builder cannot produce a witness from it either way, dropping the reason meant a consumer of
      `CorrespondenceResult` could not distinguish the two. It was previously appended to a report
      string, which put the fact outside the type that decides usability. -/
  resolverRefusals   : List TableResolveRefusal := []

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
  /-- Tables named by the subject's evidence that could not be read. -/
  resolverRefusals : List TableResolveRefusal

/-- Does this witness target this requested edge? Identity for static edges; whole-table material
    for dynamic ones. A `wholeTable` witness answers a DYNAMIC request and nothing else. -/
def witnessTargets (r : RequestedEdge) (w : EdgeWitness) : Bool :=
  match w.target with
  -- `sameDefinition`, which compares ALL FOUR components. `==` on the structure would be the same
  -- comparison today, and `sameDefinition` is used because it is the operation that MEANS "these
  -- are the same definition" — a future component added to the structure must go through it.
  | .edgeTo c => !r.dynamic && c.sameDefinition r.callee
  | .wholeTable tn td =>
    -- BOTH the table identity and its digest must be the expected ones. A dynamic request with NO
    -- expectation recorded matches nothing: an edge whose required material is unstated cannot be
    -- justified by material that merely claims to be whole-table, and defaulting to "accept" is how
    -- the per-entry-surplus exemption became a hole.
    r.dynamic && (match r.expectedTable with
                  | some (etn, etd) => tn == etn && td == etd
                  | none => false)

/-- The closed join. Identity first, then exact matching, then surplus — in that order. -/
def correspond (i : CorrespondenceInput) : CorrespondenceResult :=
  -- STEP 1: identity validation. A witness for another subject never enters the join, and is NOT
  -- counted as surplus — surplus means "belonged to this operation and matched nothing", which is
  -- a different fact from "was never ours".
  let wrongSubject := i.candidateWitnesses.filter (fun w => !w.subject.sameDefinition i.subject)
  let ours := i.candidateWitnesses.filter (fun w => w.subject.sameDefinition i.subject)
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
  -- UNSCOPED EDGES ARE MALFORMED, NOT MISSING. The distinction is the point: the compiler has the
  -- edge and could not key it, which is a different failure from having a key and no witness.
  let unscopedRefusals := i.unscopedEdges.map (fun (c, k, w) => WitnessRefusal.unscopedCallee c k w)
  { matched := matched, missing := missing, ambiguous := ambiguous, surplus := surplus
  , malformed := subjectRefusals ++ kindRefusals ++ unscopedRefusals
  , resolverRefusals := i.resolverRefusals }

/-- Usable only when every set is empty and the count is exact.

    `matched.length == requestedEdges.length` is asserted in addition to the empty sets, rather than
    inferred from them: a join that silently dropped a request would leave all four sets empty while
    covering less than was asked. The denominator is compared, not assumed — the same discipline the
    manifest accounting needed. -/
def CorrespondenceResult.usable (r : CorrespondenceResult) (requested : Nat) : Bool :=
  r.missing.isEmpty && r.ambiguous.isEmpty && r.surplus.isEmpty && r.malformed.isEmpty
    -- AN UNREADABLE TABLE BLOCKS USABILITY. Today every edge such a table would have justified
    -- falls to `missing` anyway, so this changes no current verdict — but it is not implied by the
    -- other sets: a subject whose theorem names two tables, one unreadable and one covering every
    -- edge, would otherwise be usable while a named dependency was never examined.
    && r.resolverRefusals.isEmpty
    && r.matched.length == requested

end Concrete.Proof
