import Concrete.Proof.SubjectFacts

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

/-- One node: an identity, the subject digest of that declaration, and the
    identities it calls. -/
structure DepNode where
  id       : String
  digest   : String
  callees  : List String
deriving Repr, BEq, Inhabited

/-- Identities reachable from `start`, excluding itself unless it is genuinely
    reachable from itself (mutual or self recursion), which the caller wants to
    know about rather than have hidden.

    Bounded by the node count: each round either adds an identity or stops, and
    there are finitely many. That bound is what makes recursion terminate. -/
def reachableFrom (nodes : List DepNode) (start : String) : List String :=
  let step := fun (frontier acc : List String) =>
    let next := frontier.flatMap fun n =>
      match nodes.find? (fun d => d.id == n) with
      | some d => d.callees
      | none   => []
    let fresh := next.filter (fun n => !acc.contains n)
    (fresh.eraseDups, acc ++ fresh.eraseDups)
  let rec go (fuel : Nat) (frontier acc : List String) : List String :=
    match fuel with
    | 0 => acc          -- bound reached; acc is already the full closure
    | Nat.succ f =>
      let (fresh, acc') := step frontier acc
      if fresh.isEmpty then acc' else go f fresh acc'
  -- Fuel = node count: a closure cannot contain more identities than exist.
  (go nodes.length (match nodes.find? (fun d => d.id == start) with
                    | some d => d.callees.eraseDups
                    | none   => [])
      (match nodes.find? (fun d => d.id == start) with
       | some d => d.callees.eraseDups
       | none   => [])).eraseDups

/-- The dependency root for one identity.

    Own digest, then the closure's digests SORTED BY IDENTITY — so the root
    depends on which subjects are reachable and what they are, never on traversal
    order or declaration position.

    A reachable identity with no node (an unresolved or external callee) is bound
    as `unknown:<id>` rather than skipped. Skipping it would let an incompletely
    known graph produce the same root as a fully known one, which is the
    under-approximation this must not make. -/
def dependencyRoot (nodes : List DepNode) (id : String) : String :=
  let own := match nodes.find? (fun d => d.id == id) with
    | some d => d.digest
    | none   => "unknown"
  let closure := (reachableFrom nodes id).mergeSort (· ≤ ·)
  let parts := closure.map fun c =>
    match nodes.find? (fun d => d.id == c) with
    | some d => s!"d{c.length}:{c}:{d.digest}"
    | none   => s!"u{c.length}:{c}:unknown"
  "depRootV1:" ++ s!"o{own.length}:{own}" ++ s!"n{closure.length}" ++ String.join parts

/-- Is every identity reachable from `id` backed by a known node?

    Reported separately rather than folded into the root, because "the root over a
    partly unknown graph" and "the root over a known graph" must be
    DISTINGUISHABLE but both must be COMPUTABLE — a consumer needs the root to
    compare and this flag to decide what the comparison is worth. -/
def closureFullyKnown (nodes : List DepNode) (id : String) : Bool :=
  (reachableFrom nodes id).all fun c => (nodes.find? (fun d => d.id == c)).isSome

end Concrete.Proof
