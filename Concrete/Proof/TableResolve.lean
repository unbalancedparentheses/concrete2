import Concrete.Proof.DependencyEdge
import Concrete.Proof.ClassificationTable

/-!
# Resolving a hand-back table NAME to its entries

The blocker for per-edge correspondence was stated as "the compiler cannot check table membership,
because `FnTable` values exist only Lean-side and the hand-back carries a name and a whole-table
digest". The second half is true. The first half was WRONG, and the mistake was mine: the compiler
IS a Lean program, and these tables are ordinary Lean definitions inside it. Nothing needs to be
evaluated at elaboration time and crossed over as data — the value is already linked in. The only
missing piece was a mapping from the hand-back's NAME to the value.

So this is a dispatch, not a generator change, and it removes the `evalExpr` work that was recorded
as the next blocker.

**Seven of the eight tables named by the checked-in hand-back are in `Concrete/Proof/Proof.lean` and
resolve here. The eighth (`Examples.ProofPatterns.Proofs.combineFns`) lives under `proofs/`, outside
the compiler build, and CANNOT resolve** — it gets a named refusal rather than silence, because a
table the compiler cannot read is a dependency it cannot check, which must refuse rather than pass.
-/

namespace Concrete.Proof

/-- Why a hand-back table name yielded no entries. -/
inductive TableResolveRefusal where
  /-- The name is not one this compiler links. Either the hand-back names a table defined outside
      the compiler build (as `Examples.ProofPatterns.Proofs.combineFns` is), or the dispatch below
      is stale relative to the generator. Both must refuse: an unreadable table is a dependency
      that cannot be checked. -/
  | unknownTable (name : String)
  /-- The table resolved, but its entries are not usable evidence. Carries the underlying reason
      rather than restating it — the entry-level checks already name themselves. -/
  | entriesRefused (name : String) (why : EntryEvidenceRefusal)
  /-- The supplied entries do not hash to the digest recorded beside them. The row is stale, was
      edited, or its digest was copied from another table — all indistinguishable from here, and all
      equally disqualifying. This is the ONLY independent check external material gets. -/
  | tableDigestMismatch (name : String) (recorded : String) (recomputed : String)
deriving Repr, BEq

def TableResolveRefusal.explain : TableResolveRefusal → String
  | .unknownTable n     => s!"'{n}' is not a table this compiler links"
  | .entriesRefused n w => s!"'{n}': {w.explain}"
  | .tableDigestMismatch n rec rc =>
      s!"'{n}' records entry digest {rec} but its entries hash to {rc}"

/-- The hand-back name of every table this compiler links.

    A DISPATCH ON FULLY-QUALIFIED NAMES, matching what the classification generator emits. Kept
    exhaustive-by-listing rather than clever: a wildcard fallback that guessed would resolve a
    misspelled name to the wrong table, and the whole point is that a table's identity is exact. -/
def tableByName : String → Option FnTable
  | "Concrete.Proof.proofFns"          => some proofFns
  | "Concrete.Proof.proofFnsExt"       => some proofFnsExt
  | "Concrete.Proof.cryptoFns"         => some cryptoFns
  | "Concrete.Proof.ctTagFns"          => some ctTagFns
  | "Concrete.Proof.elfFns"            => some elfFns
  | "Concrete.Proof.fixedCapacityFns"  => some fixedCapacityFns
  | "Concrete.Proof.parseValidateFns"  => some parseValidateFns
  -- The EMPTY table is a real table a theorem can name, and omitting it was a hole found by the
  -- dispatch-coverage check rather than by reading: a theorem over `FnTable.empty` would have had
  -- its dependency reported as unresolvable instead of as the (vacuously empty) membership it is.
  | "Concrete.Proof.FnTable.empty"     => some FnTable.empty
  | _                                  => none

/-- How much a table's entry evidence is worth.

    NOT cosmetic. `compilerLinked` means the compiler held the `FnTable` and RECOMPUTED every body
    digest from the actual `PFnDef.body`, refusing on disagreement. `generatorAsserted` means it
    holds digests emitted by the generator and no bodies, so it cannot recompute anything — the
    evidence is trusted rather than checked. Collapsing the two would let a weaker fact be reported
    as the stronger one, which is the failure this codebase keeps finding. -/
inductive TableProvenance where
  | compilerLinked
  | generatorAsserted
deriving Repr, BEq

def TableProvenance.render : TableProvenance → String
  | .compilerLinked    => "compiler-linked"
  | .generatorAsserted => "generator-asserted"

/-- The validated entry evidence for a named table, with its provenance, or a named refusal.

    In-compiler tables are tried FIRST. A name present in both would resolve to the checked value,
    never the asserted one — the stronger evidence wins, rather than whichever is found first. -/
def entryEvidenceWithProvenance (name : String)
    : Except TableResolveRefusal (TableProvenance × List TableEntryEvidence) :=
  match tableByName name with
  | some t => match tableEntryEvidence t with
    | .error w => .error (.entriesRefused name w)
    | .ok rows => .ok (.compilerLinked, rows)
  | none =>
    match externalTableEntries.find? (fun e => e.1 == name) with
    | none => .error (.unknownTable name)
    | some (_, recorded, pairs) =>
      -- Reconstructed from data. The digest is carried as recorded; there is no body to check it
      -- against, which is exactly what `generatorAsserted` says.
      -- Components, not a rendering: `CallableId` has no parser from `render`, and reconstructing
      -- an identity by splitting a display string is exactly the name-as-identity mistake R-0004
      -- exists to remove.
      let rows := pairs.map (fun (m, n, d) =>
        ({ callee := CallableId.ofUser m n, sourceBodyDigestV1 := d } : TableEntryEvidence))
      -- THE ONLY INDEPENDENT CHECK EXTERNAL MATERIAL GETS. There is no body to recompute against,
      -- so the entries are verified against the digest recorded beside them — which catches a stale
      -- row, an edited entry list, and a digest copied from another table (the table's own name is
      -- in the preimage). It does NOT make the evidence checked: agreement says the entries are the
      -- ones recorded, not that a body was ever read. The provenance stays `generatorAsserted`.
      let recomputed := entryTableDigest name rows
      if recorded != recomputed then .error (.tableDigestMismatch name recorded recomputed)
      else .ok (.generatorAsserted, rows)

/-- The validated entry evidence for a named table, or a named refusal. -/
def entryEvidenceForTable (name : String) : Except TableResolveRefusal (List TableEntryEvidence) :=
  (entryEvidenceWithProvenance name).map (·.2)

/-- Does the named table contain this callee, by IDENTITY?

    The question the correspondence join needs and could not previously ask. Returns the refusal
    rather than a Bool when the table cannot be read: "no" and "cannot tell" are different answers,
    and collapsing them would let an unreadable table read as a genuine absence — which is the
    direction that silently narrows a dependency closure. -/
def tableContainsCallee (name : String) (callee : CallableId)
    : Except TableResolveRefusal Bool :=
  (entryEvidenceForTable name).map (fun rows => entryEvidenceContains rows callee)

end Concrete.Proof
