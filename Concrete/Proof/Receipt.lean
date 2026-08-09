import Concrete.Proof.DependencyEdges

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
* `mint?` is the only constructor, and it returns `Option`. It refuses when any named table is
  unbound, when the subject digest is absent, or when an environment identity is empty.

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
deriving Repr, Inhabited

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
  if !ev.tablesFullyBound then none
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
    (r : ProofEvidenceReceipt) (subjectDigest : String)
    (tableBindings : List (Name × String))
    (toolchainId workspaceId importsId : String) : Bool :=
  let normalized := tableBindings.mergeSort (fun a b => toString a.1 ≤ toString b.1)
  r.subjectDigest == subjectDigest
    && r.tableBindings == normalized
    && r.toolchainId == toolchainId
    && r.workspaceId == workspaceId
    && r.importsId == importsId

/-- A stored receipt is comparable only when it was written under this envelope version.
    Distinct from "the contents differ" for the same reason `needsRecheck` is distinct from
    `stale`: the format changed, and the program may not have. -/
def ProofEvidenceReceipt.comparable (r : ProofEvidenceReceipt) : Bool :=
  r.schemaVersion == receiptSchemaVersion

end Concrete.Proof
