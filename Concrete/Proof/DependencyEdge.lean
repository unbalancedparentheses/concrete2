import Concrete.Proof.Proof

/-! # Typed proof-dependency edges (R-0004 step 6)

What a caller RELIES ON when it depends on a callee, and therefore what
invalidates it. Four kinds, and the kind is DERIVED from what the theorem
actually uses — never selected by an author:

| edge | the caller relies on | invalidated by |
| --- | --- | --- |
| `contract` | the callee's proved contract | that contract, or the callee's proof receipt, changing |
| `body` | the exact callee implementation | the callee's body / type / semantic digest changing |
| `trusted` | a declared trust boundary | the boundary changing; and the trust PROPAGATES |
| `missing` | nothing validated | always: the caller is `depsNotCurrent` |

Deriving rather than declaring is the whole point. A mode flag would let an
author assert a relationship the proof does not have — claim `contract` while the
proof unfolds a concrete table, and an implementation change that preserves the
contract would then not stale a caller that actually depends on the body.

## Why the signal is structural, not textual

A `contract` proof quantifies over the table: `∀ (fns : FnTable), …`, so it holds
for ANY table meeting its hypotheses and no callee body can affect it. A `body`
proof names concrete tables, so it is about those exact entries.

Source text cannot tell these apart — `fns` and `combineFns` are both just
identifiers on the page. The distinction exists only after elaboration, in whether
the `FnTable`-typed subterm is a bound variable or a constant.

Measured over the corpus before building this: 271 theorems depend on an
`FnTable`; 113 quantify over it, 158 name constants, and ZERO do both. No
tie-break rule is needed because no theorem needs one.

## `trusted` and `missing` come from elsewhere

Those two are not properties of the theorem's type. A dependency is `trusted`
because the callee declares a trust boundary, and `missing` because nothing
validated it. They are recorded here so consumers handle four cases rather than
two, and so `trusted`'s obligation is stated once: it may count as CURRENT for
traversal, but its trust propagates into the caller's evidence assumptions — a
proof reaching one records `proved_by_lean_modulo_trusted`, never unqualified
`proved_by_lean`.

## Future owner

Per the roadmap this belongs under `Concrete/Proof/Core/DependencyEdge.lean`,
with the classifier in `Concrete/Proof/Extract/DependencyEdges.lean`. That split
depends on R-0114-R-0118 (the import-layer work), so it lands flat here for now
with the intended home recorded rather than forgotten.
-/

namespace Concrete.Proof

/-- What a caller relies on in a dependency. See the module header for the
    invalidation rule attached to each. -/
inductive DependencyEdge where
  /-- The callee's proved contract. Survives an implementation change that
      preserves the contract. -/
  | contract
  /-- The exact callee implementation. Any relevant body change stales the
      caller. -/
  | body
  /-- A declared trust boundary. Counts as current for traversal, but the trust
      PROPAGATES into the caller's evidence assumptions. -/
  | trusted
  /-- Nothing validated. The caller is `depsNotCurrent`. -/
  | missing
  /-- The classification has not been PERFORMED. Distinct from `missing`, and the distinction is
      the same one `needsRecheck` draws against `stale`: `missing` asserts that nothing validates
      this dependency, which is a claim about the dependency; `unclassified` says only that we
      have not asked, which is a claim about our own state.

      The compiler cannot mint `contract` or `body` on its own — that split needs
      `classifyTheorem`, which reads a theorem's elaborated type and lives in `MetaM` on the Lean
      side. Without this constructor the compiler's honest answer would have to be spelled
      `missing`, which asserts something stronger than it knows and would be indistinguishable
      from a genuinely unvalidated dependency once the Lean side DID answer.

      Both fail closed, so nothing is weakened by having two. What differs is the repair: `missing`
      needs a proof, `unclassified` needs the classification hand-back to run. -/
  | unclassified
deriving BEq, Repr, DecidableEq, Inhabited

/-- Canonical tag. Explicit rather than `toString (repr e)`: this appears in
    receipts, and `repr` is derived FORMATTING that can change with a Lean version
    or printer setting. Evidence may not rest on that. -/
def DependencyEdge.canonical : DependencyEdge → String
  | .contract => "contract"
  | .body     => "body"
  | .trusted  => "trusted"
  | .missing  => "missing"
  | .unclassified => "unclassified"

/-- Every constructor, so a consumer that must handle each can be checked against
    the list instead of hand-maintaining a copy of it. -/
def DependencyEdge.all : List DependencyEdge :=
  [.contract, .body, .trusted, .missing, .unclassified]

/-- Every constructor is in `all`. A THEOREM, not a length assertion in a gate.

    `check_dependency_edges.sh` pinned `all.length == 5`, which protects nothing against a sixth
    constructor whose author also updates the 5 to a 6 without adding the entry — the count and
    the list are edited in the same breath, so the test agrees with whatever was written. This
    cannot: adding a constructor leaves an unsolved case unless the constructor is genuinely in
    the list.

    Consumers that must handle every kind should rely on THIS, not on the literal length. -/
theorem DependencyEdge.mem_all (e : DependencyEdge) : e ∈ DependencyEdge.all := by
  cases e <;> simp [DependencyEdge.all]

/-- Does this edge let the dependent be considered current?

    `missing` never does. The other three can, but `trusted` does so only with its
    trust carried forward — which is why `propagatesTrust` exists separately
    rather than being folded in here. Answering "is it current?" and "does the
    answer come with an assumption?" in one boolean is how an unqualified
    `proved_by_lean` would be minted over a trust boundary. -/
def DependencyEdge.isCurrentForDependents : DependencyEdge → Bool
  -- EXHAUSTIVE, no catch-all. This was `| .missing => false | _ => true`, and adding
  -- `unclassified` therefore made it CURRENT by default — a dependency nobody has classified
  -- would have let its dependent be considered current, which is fail-open and exactly the
  -- direction that must never be the default.
  --
  -- A wildcard in a function that decides currency means every future edge kind is born
  -- trusted. Listing every constructor makes adding one a compile error, which is the only
  -- reliable prompt to think about it.
  | .contract     => true
  | .body         => true
  | .trusted      => true
  | .missing      => false
  | .unclassified => false

/-- Does relying on this edge oblige the caller to qualify its claim?

    Only `trusted`. A proof reaching a trusted boundary records
    `proved_by_lean_modulo_trusted`; a receipt that carries the edge but drops
    this distinction has laundered the trust. -/
def DependencyEdge.propagatesTrust : DependencyEdge → Bool
  | .trusted => true
  | _        => false

/-- Which subject-level change invalidates a dependent resting on this edge.

    Stated as data rather than prose so a consumer cannot invent its own rule:
    `contract` survives a body change that preserves the contract, `body` does
    not, `trusted` tracks the boundary, `missing` is never current to begin
    with. -/
def DependencyEdge.invalidatedByBodyChange : DependencyEdge → Bool
  | .body    => true
  | .missing => true   -- already not current; a body change cannot improve that
  | _        => false

/-! ## Canonical table-ENTRY evidence (R-0004 slice 6, blocker c prerequisite)

A whole-table digest answers "did this table change". It cannot answer "does this table CONTAIN
that callee", and correspondence needs the second: a `body` edge is justified only when the bound
table holds the exact callee implementation. Digest and membership are different questions, and
one has been standing in for the other.

So entry-level material: per entry, the callable IDENTITY and the subject it was extracted from.
`PFnDef` already carries both — `identity : PFnIdentity` and `sourceBodyDigest` — so this reads
what exists rather than inventing a parallel record.

**Whole-table digests remain necessary**, and this does not replace them. A dynamic index can
reach ANY entry, so a dependency on a dynamically-indexed table is a dependency on all of it;
entry evidence answers membership for the statically-known case and cannot narrow the dynamic
one. Both, for different questions. -/

/-- One entry's correspondence material: which callable, and which subject it came from. -/
structure TableEntryEvidence where
  callee : CallableId
  /-- The V1 SOURCE-BODY digest, and the name says V1 because that is what it holds.
      `PFnDef.sourceBodyDigest` is `sourceBodyDigestV1`: it covers the extracted BODY and binds
      no typed signature, no contracts, no selected specification, no claim scope.
      An earlier version of this field was called `subjectDigest` and documented as "which
      subject it came from" — reinterpreting a V1 body digest as the frozen V2 subject. A
      signature or contract change would leave such evidence looking current, and the eventual
      per-edge join would then be exact over the WRONG subject identity.

      `none` is carried rather than defaulted: an entry whose provenance is unrecorded must not
      compare equal to one whose provenance is recorded and happens to match.

      **The authoritative V2 subject is NOT bound here yet.** Closing that needs either a V2
      subject digest on `PFnDef`, or a join of the callable identity against the authoritative
      subject manifest when correspondence evidence is built. Until then a `body` justification
      cannot claim the exact implementation subject — only that a body matched. -/
  sourceBodyDigestV1 : Option String
deriving Repr, BEq

/-- Entry evidence for a table, or `none` if ANY entry lacks identity.

    All-or-nothing deliberately. A partial membership list answers "is this callee present" with
    "not in the part I could read", which is indistinguishable from "absent" — and absence is
    what justifies refusing an edge. A caller cannot tell those apart from a shortened list, so
    it does not get one. This mirrors `FnTable.allIdentified`: evidence requires identity for the
    WHOLE table, not most of it. -/
def tableEntryEvidence (t : FnTable) : Option (List TableEntryEvidence) :=
  let rows? := t.canonicalEntries.toList.foldl (init := some []) fun acc d =>
    match acc, d.identity.id? with
    | some rows, some cid =>
        some (rows ++ [{ callee := cid, sourceBodyDigestV1 := d.sourceBodyDigest.map (·.value) }])
    | _, _ => none
  -- UNIQUE IDENTITIES, or nothing. A table holding one callable twice cannot say which
  -- implementation a static lookup selects, and `entryEvidenceContains` answering "at least
  -- one" would let a `body` edge be justified by an entry that is not the one dispatch reaches.
  -- `FnTable.hasDuplicateIds` treats a duplicate as an integrity error for the same reason;
  -- membership evidence must not be more permissive than the table it describes.
  match rows? with
  | none => none
  | some rows =>
    if (rows.map (·.callee)).eraseDups.length != rows.length then none else some rows

/-- Does this table contain the callee, by IDENTITY?

    Identity, never name: two callables can share a display name, and `PFnDef.displayName` is
    explicitly not identity. Membership decided on a rendering would be the defect R-0004 exists
    to close, appearing in the check meant to close it. -/
def entryEvidenceContains (rows : List TableEntryEvidence) (callee : CallableId) : Bool :=
  rows.any fun r => r.callee == callee

/-! ## Implementation identity and table-entry binding (R-0004 slice 6)

Lives HERE rather than in `DependencyEdges` because `ProofCore` must produce the manifest and
`DependencyEdges` imports `ProofCore` — putting it there made the producer a cycle. The types are
pure data over `CallableId`, so this is their natural home anyway.
-/

/-- A closed, validated map from callable identity to IMPLEMENTATION digest.

    **Why implementation and not proof subject.** The frozen V2 subject includes the selected
    specification and claim scope, which describe what a particular proof LINK claims. One
    callable can carry several proof links, so `CallableId -> ProofSubjectDigestV2` is not a
    function and a join on it is ill-defined. The IMPLEMENTATION digest excludes spec and scope,
    so it is one per callable — which is what a table entry needs, since an entry describes an
    implementation and does not change when a different specification is pointed at it.

    **Why a closed type and not a callback.** The previous version took
    `CallableId -> Option String`, so any caller could mint a "bound" entry from any non-empty
    string — the private constructor required only non-emptiness, not provenance. The tests
    passed `"v2:abc"` and proved exactly that. A private constructor guarding a value the caller
    supplies is not a guard.

    Constructor is private; `ofRows` is the only way in, and it validates. -/
structure ImplementationManifest where
  private mk ::
  private rows : List (CallableId × String)
deriving Repr

/-- Build a manifest from rows, validating FORMAT only — or refuse.

    **This validates syntax, not provenance.** A caller cannot pass `"v2:abc"`, but can pass
    thirty-two zeros. The authoritative producer is `implementationManifestOf` in `ProofCore`,
    which computes each digest from complete canonical facts; this function cannot tell a computed
    digest from a well-formed invented one, and does not claim to. Call the result a validated
    manifest ENVELOPE unless it came from that producer.

    Refuses on a duplicate callable — the manifest claims to be a FUNCTION, and two rows for one
    callable means it is not — and on a digest that is not canonical 32-hex. Both refuse the
    whole manifest rather than the offending row: a manifest missing entries answers "no
    implementation for this callable" indistinguishably from a callable that genuinely has none. -/
def ImplementationManifest.ofRows (rows : List (CallableId × String))
    : Option ImplementationManifest :=
  let isHex := fun (d : String) => d.length == 32 && d.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')
  if (rows.map (·.1)).eraseDups.length != rows.length then none
  else if !(rows.all fun r => isHex r.2) then none
  else some (ImplementationManifest.mk rows)

def ImplementationManifest.find? (m : ImplementationManifest) (c : CallableId) : Option String :=
  (m.rows.find? fun r => r.1 == c).map (·.2)

/-- A table entry bound to its authoritative IMPLEMENTATION digest.

    `implDigest` is a plain `String` with a private constructor, so an entry without an
    authoritative implementation has no representation — and the value can only have come from a
    validated manifest, not from a caller-supplied callback. -/
structure BoundTableEntry where
  private mk ::
  callee     : CallableId
  implDigest : String
deriving Repr, BEq

/-- Join entry evidence against a CLOSED manifest, or refuse.

    Refuses the whole list when any entry has no manifest row. Dropping unbindable entries would
    shrink the membership set, and a shrunken set answers "is this callee present" with "not
    among the ones I could bind" — indistinguishable from "absent", which is what justifies
    refusing an edge. A membership list must never be able to under-report. -/
def bindEntryImplementations (rows : List TableEntryEvidence) (manifest : ImplementationManifest)
    : Option (List BoundTableEntry) :=
  rows.foldl (init := some []) fun acc r =>
    match acc, manifest.find? r.callee with
    | some out, some d => some (out ++ [BoundTableEntry.mk r.callee d])
    | _, _ => none

/-- The bound implementation digest for a callee, if it is a member.

    Returns the DIGEST rather than a Bool: a `body` justification must record which
    implementation justified it, or a later check cannot tell whether the entry it matched is the
    one still there. -/
def boundEntryImplementationOf (rows : List BoundTableEntry) (callee : CallableId) : Option String :=
  (rows.find? fun r => r.callee == callee).map (·.implDigest)


end Concrete.Proof
