import Concrete.Proof.SubjectFacts
import Concrete.Proof.DependencyEdge

/-! # Deterministic dependency roots (R-0004 slice 6)

Freshness computed TRANSITIVELY, so that a deep callee edit stales every claim
that depends on it, while recursion stays finite and nothing about source
location or alpha-renaming becomes semantic.

## The shape chosen, and the one rejected

A Merkle DAG over the SCC condensation is the textbook answer: condense cycles,
then hash each node from its own content plus its children's roots. It shares
structure, so a root can be recomputed incrementally.

This uses a REACHABILITY-CLOSURE digest instead: a node's root is its own subject
digest plus the sorted subject digests of everything reachable from it. The two
agree on the properties that matter here —

* deterministic (the reachable set is sorted by identity, never by insertion
  order or source position);
* finite under recursion (a reachable set cannot grow past the node count, so
  mutual recursion terminates rather than diverging);
* every member of a cycle gets the SAME CLOSURE — they are mutually reachable, so
  the set is entry-point-independent, which is the property SCC condensation
  provides. Their ROOTS still differ, because a root binds the node's own subject
  as well as its closure and two functions in a cycle are two different subjects.
  (An earlier draft of this header claimed cycle members share a root. They do
  not, and should not; the test that asserts closure agreement is the honest form
  of the property.);
* a deep callee edit moves every dependent's root.

— and the closure form is materially easier to check: the root is a function of a
SET, so verifying "this root binds exactly these subjects" needs no reasoning
about traversal order or condensation correctness. What it gives up is incremental
sharing: recomputing one root costs its whole closure. That is the right trade
while the corpus is dozens of functions, and the wrong one if it becomes
thousands — recorded here so the decision is revisited on evidence rather than
rediscovered.

## Never under-approximate

An edge to a callee with no known digest does not silently drop out of the
closure. `unknown:<id>` enters it instead, so a root over an incompletely known
graph cannot equal a root over a fully known one. Dropping the edge would produce
the more confident answer from the less complete information.
-/

namespace Concrete.Proof

/-- One node: an identity, the subject digest of that declaration, and its TYPED
    outgoing edges.

    `digest` is an `Option`, never a string that may be empty. An empty digest is
    indistinguishable from a computed one at the type level, and a root built over
    "" would be a confident value derived from a missing subject.

    Edges carry their kind, so the root can refuse to rest on a `missing` one
    rather than treating every callee as equivalent. -/
structure DepNode where
  id      : String
  digest  : Option String
  edges   : List (DependencyEdge × String)
deriving Repr, Inhabited

/-- Why a root could not be built. Carried rather than collapsed to `none`, so a
    caller can say WHICH fail-closed condition fired instead of reporting a
    generic absence. -/
inductive DepRootError where
  | missingStart (id : String)
  | duplicateId (id : String)
  | incompleteDigest (id : String)
  | unresolvedEdge (from_ to_ : String)
  | missingEdge (from_ to_ : String)
deriving Repr, BEq

def DepRootError.explain : DepRootError → String
  | .missingStart id      => s!"no node for start identity '{id}'"
  | .duplicateId id       => s!"duplicate node identity '{id}'"
  | .incompleteDigest id  => s!"'{id}' has no subject digest"
  | .unresolvedEdge f t   => s!"'{f}' depends on '{t}', which has no node"
  | .missingEdge f t      => s!"'{f}' has a `missing` edge to '{t}'"

/-- Identities reachable from `start` over typed edges.

    Bounded by the node count: each round adds at least one identity or stops, and
    there are finitely many. That bound is what makes recursion terminate rather
    than diverge. -/
def reachableFrom (nodes : List DepNode) (start : String) : List String :=
  let succs := fun (n : String) =>
    match nodes.find? (fun d => d.id == n) with
    | some d => d.edges.map Prod.snd
    | none   => []
  let rec go (fuel : Nat) (frontier acc : List String) : List String :=
    match fuel with
    | 0 => acc
    | Nat.succ f =>
      let next := (frontier.flatMap succs).eraseDups
      let fresh := next.filter (fun n => !acc.contains n)
      if fresh.isEmpty then acc else go f fresh (acc ++ fresh)
  let seed := (succs start).eraseDups
  (go nodes.length seed seed).eraseDups

/-- One validated result: the preimage and the trust qualification together.

    Returned as a STRUCTURE rather than a preimage plus a separate boolean,
    because a flag beside a value is an invitation to compare the value and
    ignore the flag — which is precisely how an unqualified `proved_by_lean`
    would get minted over a trust boundary. -/
structure DependencyRootMaterial where
  preimage     : String
  carriesTrust : Bool
deriving Repr, BEq, Inhabited

/-- The canonical PREIMAGE of a dependency root, plus its trust qualification.

    A serialization, NOT a compact hash and NOT a Merkle root — it shares no
    structure and does not shrink. A consumer wanting a fixed-width value hashes
    it; calling it a root oversold what it is.

    THE EDGES ARE IN THE BYTES. An earlier version serialized only reachable
    identities and their digests, so changing an edge from `contract` to `body`
    produced the SAME preimage — the typed edges were traversed and then thrown
    away, which defeats the point of typing them. Each edge now contributes its
    canonical kind, its target identity and that target's length-prefixed digest.

    FAIL CLOSED, reason carried. Every one of these would otherwise yield a
    confident value from incomplete information: a missing start; a duplicate
    identity (first-match lookup would hide the conflict); an absent OR EMPTY
    subject digest; an edge to an identity with no node; an edge typed
    `missing`. -/
def dependencyRootMaterial (nodes : List DepNode) (id : String)
    : Except DepRootError DependencyRootMaterial := do
  let ids := nodes.map (·.id)
  match ids.find? (fun n => (ids.filter (· == n)).length > 1) with
  | some dup => throw (.duplicateId dup)
  | none => pure ()
  let start ← match nodes.find? (fun d => d.id == id) with
    | some d => pure d
    | none   => throw (.missingStart id)
  -- `some ""` is as incomplete as `none`: an empty digest is a computed-looking
  -- value derived from nothing.
  let digestOf := fun (n : String) => do
    match nodes.find? (fun d => d.id == n) with
    | none   => throw (.unresolvedEdge id n)
    | some d => match d.digest with
      | some v => if v.isEmpty then throw (.incompleteDigest n) else pure v
      | none   => throw (.incompleteDigest n)
  let ownDigest ← digestOf start.id
  let closure := (reachableFrom nodes id).mergeSort (· ≤ ·)
  let mut parts : List String := []
  let mut trust := false
  for n in (id :: closure) do
    let node ← match nodes.find? (fun d => d.id == n) with
      | some d => pure d
      | none   => throw (.unresolvedEdge id n)
    let nDigest ← digestOf n
    parts := parts ++ [s!"N{n.length}:{n}:{nDigest.length}:{nDigest}"]
    -- edges sorted by (kind, target) so the preimage cannot depend on the order
    -- they were discovered in
    let sorted := node.edges.mergeSort fun a b =>
      (a.1.canonical ++ a.2) ≤ (b.1.canonical ++ b.2)
    for (k, tgt) in sorted do
      if k == DependencyEdge.missing then throw (.missingEdge n tgt)
      let tgtDigest ← digestOf tgt
      if k == DependencyEdge.trusted then trust := true
      parts := parts ++
        [s!"E{k.canonical.length}:{k.canonical}:{tgt.length}:{tgt}:{tgtDigest.length}:{tgtDigest}"]
  return { preimage := "depRootPreimageV2:" ++ s!"o{ownDigest.length}:{ownDigest}"
                        ++ s!"n{closure.length}" ++ String.join parts
         , carriesTrust := trust }

/-- Does any edge in the closure carry trust, so a claim resting on this root must
    say `proved_by_lean_modulo_trusted` rather than `proved_by_lean`?

    Separate from the root because it is a different question: the root says WHAT
    the claim rests on, this says what QUALIFICATION the claim must carry. -/
def closureCarriesTrust (nodes : List DepNode) (id : String) : Bool :=
  (id :: reachableFrom nodes id).any fun n =>
    match nodes.find? (fun d => d.id == n) with
    | some d => d.edges.any fun (k, _) => k == DependencyEdge.trusted
    | none   => false

end Concrete.Proof
