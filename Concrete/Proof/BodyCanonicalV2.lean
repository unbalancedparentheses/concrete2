import Concrete.Proof.SubjectFacts

/-! # ProofBodyCanonicalV2 — serialization only

This module SERIALIZES the typed evidence nodes elaboration produced. It resolves
nothing: no name lookup, no scope reconstruction, no type inference. Those belong to
the producer, which is the only place the information exists — `obj.field` has no
owner type at the AST, which is why the producer runs during elaboration.

Keeping the split strict means the serializer has no judgement to get wrong. Every
question it could answer incorrectly has already been answered upstream, and the one
thing it must not do — invent a value for a node it does not understand — is
prevented by matching exhaustively with no fallback.

`Repr` is deliberately NOT used to derive any of this. A derived instance absorbs new
constructors silently, producing bytes for a node kind nobody classified. The whole
point of the exhaustive match is that adding a constructor must stop the build.
-/

namespace Concrete.Proof

/-- Versioned domain tags, one per node kind.

    EXHAUSTIVE, no wildcard: a new `BodyIdentityUse` constructor must fail to
    compile here rather than receive a generic tag. Tags are single characters and
    mutually distinct so the concatenated stream cannot be ambiguous. -/
def nodeTag : BodyIdentityUse → String
  | .binderRef _ _ => "b"
  | .typeRef _     => "t"
  | .field _       => "f"
  | .variant _     => "v"

/-- Every tag the serializer knows how to emit.

    Kept beside `nodeTag` so a reflective check can compare this against the
    inductive's real constructor count. That comparison is what catches the case a
    plain exhaustive match cannot: a constructor added TOGETHER with a fallback arm,
    which compiles happily and serializes garbage. -/
def allNodeTags : List String := ["b", "t", "f", "v"]

/-- Length-prefixed encoding of one node.

    Length prefixes make the stream injective: without them `t` + `"ab"` and `t` +
    `"a"` followed by `b`-something could not be told apart. The same reasoning that
    fixed `TypeId.render`, where `("a.b","c")` and `("a","b.c")` collided. -/
def serializeNode : BodyIdentityUse → String
  | .binderRef out idx =>
      let p := s!"{out}:{idx}"
      "b" ++ toString p.length ++ ":" ++ p
  | .typeRef id =>
      let p := id.render
      "t" ++ toString p.length ++ ":" ++ p
  | .field id =>
      let p := id.render
      "f" ++ toString p.length ++ ":" ++ p
  | .variant id =>
      let p := id.render
      "v" ++ toString p.length ++ ":" ++ p

/-- Canonical bytes for a body's typed evidence, or refusal.

    ORDER AND MULTIPLICITY ARE SEMANTIC. A body reading a binder twice is not the
    body that reads it once, and a body that reads `x` then `y` is not the one that
    reads `y` then `x`. The node count is emitted first so a truncated stream cannot
    read as a shorter complete one.

    REFUSES an uncovered input. `covered = false` means the producer met a construct
    it could not give a semantic identity; serializing what it DID capture would
    present a partial body as a complete one, which is worse than having no bytes at
    all because it looks authoritative. -/
def serializeBody (inputs : ProofBodyIdentityInputsV2) : Option String :=
  if !inputs.covered then none
  else
    let body := String.join (inputs.uses.map serializeNode)
    some ("bodyV2:n" ++ toString inputs.uses.length ++ ":" ++ body)

end Concrete.Proof
