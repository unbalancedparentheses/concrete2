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

end Concrete.Proof
