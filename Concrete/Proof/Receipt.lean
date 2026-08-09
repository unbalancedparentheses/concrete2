import Concrete.Proof.DependencyEdges
open Concrete in

/-! # The proof-evidence receipt envelope (R-0004 slice 4)

**Declared future owner: `Concrete/Proof/Receipt/`.** Landed flat here because that directory
split depends on R-0114-R-0118 (see the repo-reorganization plan) and is premature; the header
records the intended home so the move is a rename rather than a rediscovery.

## What a receipt is for

A receipt says: *this evidence was established against exactly this subject, under exactly these
dependencies, in exactly this environment.* Its value is entirely in what it BINDS — a receipt
that omits something is not a weaker receipt, it is a receipt that silently claims independence
from whatever it left out.

## The design commitment: unbindable evidence is UNREPRESENTABLE, not rejected

`EdgeEvidence.tablesFullyBound` is a predicate, and a predicate can be forgotten. The type here
is built so it cannot be:

* `tableBindings : List (Name × String)` — a digest per table, **not** `Option String`. There is
  no way to put an unbound table inside a receipt, so no consumer has to remember to check.
* the structure constructor is PRIVATE and `Inhabited` is not derived, so `mint?` really is the
  only way to obtain one. Both were missing in the first version, and the claim below was
  therefore false: a caller could build a receipt with an empty subject and the current schema
  version, and `default` produced one with an empty schema.
* `mint?` returns `Option` and refuses when any named table is unbound, when the digests do not
  correspond to the named tables IDENTITY-wise, when a table is bound twice, when the subject
  digest is absent OR empty, or when an environment identity is empty.

This is the same move Register C made for status composition and `proofSubjectDigestV2` made for
incomplete facts: make the bad state unrepresentable rather than merely discouraged. A guard that
must be remembered is a guard that will eventually be forgotten, and a receipt minted from
partial evidence is indistinguishable from one minted from complete evidence — which is precisely
the failure a receipt exists to prevent.

## What it binds, and why each is separate

Four environment identities rather than one blob, because they fail independently and a consumer
needs to know WHICH moved:

| field | binds | a change means |
|---|---|---|
| `toolchainId` | the Lean/compiler version the proof was checked under | the checker changed; the proof may not replay |
| `workspaceId` | the deterministic workspace root | the proof was established somewhere else |
| `importsId` | the transitive import surface | something the proof could see has changed |
| `schemaVersion` | this envelope's own format | the receipt cannot be compared field-wise |

`schemaVersion` is in the bytes for the reason `v2:` is in the subject digest: a receipt written
under an older envelope must read as a DIFFERENT SCHEMA rather than as a mismatch, so it becomes
`needs_recheck` and not `stale`. Without it, the first envelope change would report every stored
receipt as a failed proof.

## What this does NOT do

It does not replay anything. Minting a receipt records what evidence was established against; it
does not establish it. Slice 7 issues receipts only after a successful kernel replay, and this
type is what that step fills in — a receipt minted without a replay would be a claim about a
proof nobody ran.
-/

namespace Concrete.Proof

open Lean

/-- A proof-evidence receipt. Every field is bound; there is no partial receipt.

    Construct with `mint?` only — the fields are public for reading and pattern-matching, but
    building one directly would let a caller assemble the very state `mint?` refuses. -/
structure ProofEvidenceReceipt where
  /-- PRIVATE constructor. Without it, "mint? is the only constructor" was simply false: any
      caller could assemble a receipt with an empty subject, no bindings and the CURRENT schema
      version — which would then read as comparable. The gate in this repo demonstrated the
      bypass while claiming the invariant held.

      Projections stay public; only construction is closed. -/
  private mk ::
  /-- This envelope's format. Compared BEFORE the contents, so an older receipt is
      `needs_recheck` rather than a failed comparison. -/
  schemaVersion : String
  /-- The v2 subject digest the evidence was established against. -/
  subjectDigest : String
  /-- What the proof relies on, derived from the theorem rather than declared. -/
  edge : DependencyEdge
  /-- One digest per named table, all present by construction. `Option` deliberately absent:
      an unbound table has no representation inside a receipt.

      **Ordering is NORMALIZED, not semantic**, and stating which is the point. The pairs
      arrive in Lean's traversal order, which is deterministic today and is not a promise —
      it is an artifact of how `getUsedConstants` happens to walk an expression. A durable
      receipt cannot rest on that: the same dependency set discovered in a different order
      would serialize differently and compare unequal, reporting drift where there is none.

      So `mint?` sorts by table identity. The consequence to be aware of: order carries no
      information, and two receipts differing only in the ORDER of the same pairs are the
      same receipt. What order cannot hide is a SWAP — exchanging two tables' digests changes
      which name is paired with which value, and that survives sorting. -/
  tableBindings : List (Name × String)
  toolchainId : String
  workspaceId : String
  importsId : String
deriving Repr

-- NO `Inhabited`. `deriving Inhabited` manufactures a default receipt — empty schema, empty
-- subject, no bindings — which is another route to an invalid value and defeats the private
-- constructor entirely. A type whose invalid state is one `default` away is not closed.

/-! ## The three environment identities

The receipt REFUSES an empty identity, so until something produces these no receipt can mint —
fail-closed, and loud. These are those producers.

Each is a digest over versioned canonical bytes rather than a display string, and each is
deliberately independent of the machine it ran on, because clean-machine reproducibility is a
completion requirement: an identity containing an absolute path would make every receipt
un-replayable anywhere else, which is the opposite of what binding the environment is for. -/

/-- The toolchain the proof was checked under: compiler version AND Lean toolchain.

    Both, not either. The compiler decides what the subject IS; Lean decides what a proof of it
    MEANS. A receipt that pinned only one would survive a change to the other, and
    `tableValueDigest`'s structural rendering is explicitly toolchain-relative — that limit is
    only acceptable because this exists. -/
def toolchainIdOf (compilerVersion leanToolchain : String) : String :=
  shortHash ("toolchainV1:" ++ toString compilerVersion.length ++ ":" ++ compilerVersion
             ++ "|lean:" ++ toString leanToolchain.length ++ ":" ++ leanToolchain)

/-- The workspace, identified by its PACKAGE identity rather than its path.

    A filesystem path is not a workspace identity: it differs between two checkouts of the same
    commit, so receipts would disagree across machines while describing identical evidence, and
    an identical path on a different machine would wrongly agree. Package name plus the module
    set is reproducible from the source alone.

    Modules are SORTED, so discovery order cannot enter the identity. -/
def workspaceIdOf (packageName : String) (moduleNames : List String) : String :=
  let mods := (moduleNames.mergeSort (· ≤ ·)).map (fun m => "m" ++ toString m.length ++ ":" ++ m)
  shortHash ("workspaceV1:" ++ toString packageName.length ++ ":" ++ packageName
             ++ "|n" ++ toString moduleNames.length ++ ":" ++ String.join mods)

/-- The import closure a proof could see, as (module, digest) pairs.

    Names alone would not move when an imported module's CONTENT changes, which is the same
    defect `tableValueDigest` exists to prevent one level down. Sorted by module name for the
    reason the workspace's module list is: import order is not part of what a proof depends on,
    but import CONTENT is. -/
def importsIdOf (imports : List (String × String)) : String :=
  let ps := (imports.mergeSort (fun a b => a.1 ≤ b.1)).map fun (m, d) =>
    "i" ++ toString m.length ++ ":" ++ m ++ "=" ++ toString d.length ++ ":" ++ d
  shortHash ("importsV1:n" ++ toString imports.length ++ ":" ++ String.join ps)

/-- The current envelope format. Bumping this makes every stored receipt `needs_recheck`,
    which is the intended behaviour and the reason the field exists. -/
def receiptSchemaVersion : String := "receiptV1"

/-- Mint a receipt, or refuse.

    Refuses — returning `none` rather than a degraded receipt — when:

    * any named table is unbound (`tablesFullyBound` false), because a `body` edge that cannot
      detect a change in a table it names reads exactly like a dependency that never changes;
    * the subject digest is absent, which `proofSubjectDigestV2` already signals for incomplete
      or missing facts;
    * any environment identity is empty. An empty string is not "unknown", it is a value that
      compares equal to another empty string — so two proofs established under different
      toolchains would agree. Refusing is the only reading that does not invent agreement. -/
def ProofEvidenceReceipt.mint?
    (subjectDigest? : Option String) (ev : EdgeEvidence)
    (toolchainId workspaceId importsId : String) : Option ProofEvidenceReceipt := do
  let subj ← subjectDigest?
  -- An EMPTY subject is not a subject. `none` was refused and `some ""` was not, which is the
  -- same hole as an empty environment identity: "" is a value that compares equal to another
  -- "", so two proofs over different subjects would agree.
  if subj.isEmpty then none
  else if !ev.tablesFullyBound then none
  -- IDENTITY CORRESPONDENCE, not just arity. `tablesFullyBound` checks that the lists are the
  -- same LENGTH and every digest is present — which admits `tables := [X]` with
  -- `tableDigests := [(Y, …)]`, minting a receipt that claims Y while the theorem depended on
  -- X. Equal counts of unrelated things is not correspondence.
  else if (ev.tables.map toString).mergeSort (· ≤ ·)
          != (ev.tableDigests.map (toString ·.1)).mergeSort (· ≤ ·) then none
  -- A duplicate binding for one table means the evidence disagrees with itself about that
  -- table's digest, and picking one would make the receipt depend on list order.
  else if (ev.tableDigests.map (toString ·.1)).eraseDups.length != ev.tableDigests.length then none
  else if toolchainId.isEmpty || workspaceId.isEmpty || importsId.isEmpty then none
  else
    -- Safe by the guard above: `tablesFullyBound` establishes every digest is `some`, so this
    -- filterMap drops nothing. Written as filterMap rather than `!` so the total function stays
    -- total if the guard is ever moved.
    -- SORTED BY TABLE IDENTITY. See the field's note: traversal order is deterministic but
    -- not meaningful, and a receipt that compares unequal because a walker visited two
    -- constants in a different order would report drift that did not happen.
    let bindings := (ev.tableDigests.filterMap fun (n, d?) => d?.map fun d => (n, d))
                    |>.mergeSort (fun a b => toString a.1 ≤ toString b.1)
    some { schemaVersion := receiptSchemaVersion
         , subjectDigest := subj
         , edge := ev.edge
         , tableBindings := bindings
         , toolchainId, workspaceId, importsId }

/-- Is a stored receipt still current against freshly computed material?

    Schema is checked FIRST and separately: an older envelope is not comparable at all, and
    answering `false` there would mean "the proof went stale", which is a claim about the
    program rather than about the format. Callers must branch on `comparable` before reading
    this — the two questions have different repairs, which is the same distinction
    `needsRecheck` draws against `stale`.

    Everything the receipt binds participates. A change to a table's body moves its digest; a
    different toolchain, workspace or import closure moves those identities; a swapped pair of
    table digests changes which name carries which value and survives the sort. Any of them
    means the recorded evidence was established against something other than what is here now. -/
def ProofEvidenceReceipt.isCurrentAgainst
    (r : ProofEvidenceReceipt) (subjectDigest : String) (edge : DependencyEdge)
    (tableBindings : List (Name × String))
    (toolchainId workspaceId importsId : String) : Bool :=
  let normalized := tableBindings.mergeSort (fun a b => toString a.1 ≤ toString b.1)
  r.subjectDigest == subjectDigest
    -- The EDGE participates, and its omission was a real hole: a receipt recorded for a
    -- `contract` edge would have read current against `body` material, which is the direction
    -- that matters — a claim that survives an implementation change it actually depends on.
    && r.edge == edge
    && r.tableBindings == normalized
    && r.toolchainId == toolchainId
    && r.workspaceId == workspaceId
    && r.importsId == importsId

/-- A stored receipt is comparable only when it was written under this envelope version.
    Distinct from "the contents differ" for the same reason `needsRecheck` is distinct from
    `stale`: the format changed, and the program may not have. -/
def ProofEvidenceReceipt.comparable (r : ProofEvidenceReceipt) : Bool :=
  r.schemaVersion == receiptSchemaVersion

/-- What a stored receipt is worth against current material. ONE value, not two booleans.

    `comparable` and `isCurrentAgainst` are each correct and had to be called in the right
    order: schema first, then contents. That is a predicate a consumer must remember, and this
    file already contains one lesson about predicates that must be remembered — the receipt's
    own invariant was documentation until the constructor was closed. A consumer that reads
    them out of order reports "the proof went stale" when the ENVELOPE changed, which is a
    claim about the program rather than about the format.

    So the sequencing lives here, once:

      `needsRecheck`  written under a different envelope — not comparable, and NOT a statement
                      about the program. Repair: re-verify and re-record.
      `notCurrent`    same envelope, and something it binds has moved. Repair: fix or re-prove.
      `current`       same envelope, everything it binds matches. -/
inductive ReceiptDisposition where
  | current
  | notCurrent
  | needsRecheck
deriving Repr, DecidableEq, Inhabited

/-- The single entry point a consumer should use. Checks schema BEFORE contents, so the
    "different format" and "different program" answers can never be swapped. -/
def ProofEvidenceReceipt.disposition
    (r : ProofEvidenceReceipt) (subjectDigest : String) (edge : DependencyEdge)
    (tableBindings : List (Name × String))
    (toolchainId workspaceId importsId : String) : ReceiptDisposition :=
  if !r.comparable then .needsRecheck
  else if r.isCurrentAgainst subjectDigest edge tableBindings toolchainId workspaceId importsId
    then .current else .notCurrent


end Concrete.Proof
