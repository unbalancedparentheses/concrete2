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
      equally disqualifying. Detects CORRUPTION of the recorded pair; it is not an independent
      validation of the material, since the same producer computes both sides. -/
  | tableDigestMismatch (name : String) (recorded : String) (recomputed : String)
  /-- Several external rows for one table name. The external material is not the function it claims
      to be, and taking the first match is how a conflicting hand-back resolves confidently. -/
  | externalRowAmbiguous (name : String)
  /-- An external row is structurally invalid: an empty module or declaration identity, a body
      digest that is not canonical 32-hex, or one callable listed twice. Validated BEFORE the digest
      comparison, because a well-formed digest over malformed entries would otherwise verify. -/
  | externalRowMalformed (name : String) (why : String)
deriving Repr, BEq

def TableResolveRefusal.explain : TableResolveRefusal → String
  | .unknownTable n     => s!"'{n}' is not a table this compiler links"
  | .entriesRefused n w => s!"'{n}': {w.explain}"
  | .tableDigestMismatch n rec rc =>
      s!"'{n}' records entry digest {rec} but its entries hash to {rc}"
  | .externalRowAmbiguous n => s!"'{n}' has several external rows — the hand-back is not a function"
  | .externalRowMalformed n w => s!"'{n}' external row is malformed: {w}"

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

/-- What is structurally wrong with an external row's entry list, or `none`.

    SEPARATED FROM LOOKUP so it is testable. A probe that can only reach this through
    `entryEvidenceWithProvenance` can only exercise the checked-in rows, which are well-formed — so
    "malformed external rows are rejected" would be asserted against data containing none. Two
    earlier probes did worse than that: one filtered a local list and the other compared
    `entryTableDigest x` with itself, so both passed without touching this code at all. -/
def externalRowDefect (pairs : List (String × String × String)) : Option String :=
  let isHex := fun (d : String) => d.length == 32 && d.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')
  if pairs.any (fun p => p.1.isEmpty || p.2.1.isEmpty) then some "an empty module or declaration identity"
  else if pairs.any (fun p => !isHex p.2.2) then some "a body digest that is not canonical 32-hex"
  else
    let ids := pairs.map (fun p => p.1 ++ "." ++ p.2.1)
    if ids.eraseDups.length != ids.length then some "one callable listed twice" else none

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
    -- EXACTLY ONE ROW, or refuse. `find?` took the first match, so a duplicate name would bind
    -- silently to whichever row came first — the same defect the classification lookup had, in the
    -- table this one falls back to. Zero and several are equally unusable.
    match externalTableEntries.filter (fun e => e.1 == name) with
    | [] => .error (.unknownTable name)
    | _ :: _ :: _ => .error (.externalRowAmbiguous name)
    | [(_, recorded, pairs)] =>
      -- Reconstructed from data. The digest is carried as recorded; there is no body to check it
      -- against, which is exactly what `generatorAsserted` says.
      -- Components, not a rendering: `CallableId` has no parser from `render`, and reconstructing
      -- an identity by splitting a display string is exactly the name-as-identity mistake R-0004
      -- exists to remove.
      -- STRUCTURAL VALIDATION BEFORE THE DIGEST COMPARISON. A digest recomputed over malformed
      -- entries agrees with itself, so checking the digest first would let an empty identity or a
      -- non-hex body digest through on a self-consistent pair.
      match externalRowDefect pairs with
      | some why => .error (.externalRowMalformed name why)
      | none =>
      let rows := pairs.map (fun (m, n, d) =>
        ({ callee := CallableId.ofUser m n, sourceBodyDigestV1 := d } : TableEntryEvidence))
      -- SINGLE-SOURCE RECOMPUTATION, not an independent check — the wording matters and an earlier
      -- version of this comment got it wrong. Generator and compiler run the SAME `entryTableDigest`,
      -- so agreement establishes canonical-encoding consistency and binding between name, entries
      -- and stored digest. It detects storage corruption, a stale row, and a digest copied from
      -- another table. It does NOT validate the formula, generator correctness, or that these
      -- entries describe the real table bodies — nothing here reads a body. Provenance stays
      -- `generatorAsserted`, and a consistently-altered pair verifies structurally BY DESIGN.
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
