import Concrete.Proof.SubjectFacts

/-! # Identity-use serialization — NOT ProofBodyCanonicalV2

RENAMED deliberately. This serializes the flat list of typed identity USES that
elaboration accumulates. It is not a body representation and must not be mistaken for
one: measured on the corpus, `p + 1`, `p * 2` and `p - 9` all serialize identically,
because the vocabulary is four leaf reference kinds and operators, literals, calls and
control flow are absent.

ProofBodyCanonicalV2 will serialize a typed evidence TREE produced by elaboration.
A tree makes malformed nesting UNREPRESENTABLE, which is strictly stronger than the
arity-tagged stream below: an arity stream can be injective, but it lets the producer
emit a malformed stream that the serializer must then reconstruct and validate —
duplicating structure the elaborator already knows. The arity machinery here is
retained as the STACK-VALIDATION layer for that eventual tree's flat encoding, not as
the IR's shape.

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

/-- How many preceding nodes this node consumes as children.

    THE STRUCTURAL CONTRACT, established before any composite node exists. The
    evidence stream is a flat list, which works today only because all four kinds are
    leaf references. The moment operators and calls become nodes, nesting turns
    semantic: `(p + q) * r` and `p + (q * r)` would emit the SAME node sequence, as
    would `f(g(x))` and `g(f(x))`. That collision passes any order-and-multiplicity
    check, because the order genuinely is identical — it is the shadow collision one
    level deeper.

    Rather than convert the IR to a tree, each node declares its arity and the stream
    is read as POSTFIX. Injectivity then becomes checkable (see `streamRoots?`)
    instead of merely structural, and the producer keeps the flat accumulator that
    `restoreScope` semantics already depend on.

    EXHAUSTIVE, no wildcard: a new constructor must state its arity here. Defaulting
    an unknown node to 0 would silently flatten a composite back into a leaf.
    Retrofitting structure onto a published vocabulary is the expensive version of
    this decision, which is why it lands while every arity is still 0. -/
def nodeArity : BodyIdentityUse → Nat
  | .binderRef _ _ => 0
  | .typeRef _     => 0
  | .field _       => 0
  | .variant _     => 0

/-- Postfix well-formedness: the number of roots the stream reduces to, or `none` if
    it is malformed.

    Simulates a stack. Each node pops `nodeArity` children and pushes itself; a node
    demanding more children than are available makes the stream malformed rather than
    silently truncating. A serializer that trusted its input would encode a stream no
    reader could interpret, which is the "looks authoritative" failure again. -/
def streamRootsWith? (arity : BodyIdentityUse → Nat) (uses : List BodyIdentityUse)
    : Option Nat :=
  uses.foldl (init := some 0) fun acc u =>
    match acc with
    | none => none
    | some depth =>
      let need := arity u
      if need > depth then none else some (depth - need + 1)

/-- The arity function is a PARAMETER above so this refusal path is testable now.
    Every current node is a leaf, so no real stream can be malformed yet, and a check
    that cannot be exercised is not a check — it is a claim. A gate supplies a
    composite arity to prove the detection works before the first composite node
    exists, rather than discovering it does not when one arrives. -/
def streamRoots? (uses : List BodyIdentityUse) : Option Nat :=
  streamRootsWith? nodeArity uses

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

/-- PARTIAL canonical bytes for a body's typed evidence, or refusal.

    NOT a complete body representation — see the prefix comment below. This is the
    typed-reference stream, which is a strict subset of the body's meaning.

    ORDER AND MULTIPLICITY ARE SEMANTIC. A body reading a binder twice is not the
    body that reads it once, and a body that reads `x` then `y` is not the one that
    reads `y` then `x`. The node count is emitted first so a truncated stream cannot
    read as a shorter complete one.

    REFUSES an uncovered input. `covered = false` means the producer met a construct
    it could not give a semantic identity; serializing what it DID capture would
    present a partial body as a complete one, which is worse than having no bytes at
    all because it looks authoritative. -/
def serializeIdentityUses (inputs : ProofBodyIdentityInputsV2) : Option String :=
  if !inputs.covered then none
  else if (streamRoots? inputs.uses).isNone then
    -- MALFORMED. A composite node demanding more children than precede it cannot be
    -- read back by anyone, so emitting bytes for it would produce evidence that only
    -- looks authoritative. Refuse, exactly as for an uncovered body.
    none
  else
    let body := String.join (inputs.uses.map serializeNode)
    -- TAGGED PARTIAL, and it must stay that way until the node vocabulary covers the
    -- whole expression language. MEASURED on the corpus: `p + 1`, `p * 2` and
    -- `p - 9` all serialize IDENTICALLY, because the vocabulary has four kinds
    -- (binder, type, field, variant) and operators, literals, calls and control flow
    -- are not among them. `covered = true` therefore means "every reference we
    -- attempted to identify was identifiable", NOT "this body is described".
    --
    -- If freshness consumed these bytes today, editing `p + 1` to `p * 2` would not
    -- invalidate the proof. The prefix makes that impossible to mistake for a
    -- complete body digest, and check_body_canonical_v2 carries a TRIPWIRE that
    -- fails once the vocabulary grows, forcing this decision to be revisited rather
    -- than silently outgrown.
    some ("identityUsesV1:n" ++ toString inputs.uses.length ++ ":" ++ body)

/-- SHADOW digest of a body's typed evidence: the V2 bytes, hashed, or refusal.

    Shadow means OBSERVED, NOT AUTHORITATIVE. This value is reported so the two
    representations can be compared on the real corpus before either is trusted; it
    is deliberately absent from `CheckedDeclFacts.canonical`, so V1 stays byte-frozen
    and no stored proof link can go stale because of it.

    It is a separate function rather than a field on the facts record on purpose: a
    field is one refactor away from being folded into `canonical` by someone
    threading "all the facts" into the digest, whereas a call site has to be written
    deliberately. -/
def shadowIdentityUseDigest (inputs : ProofBodyIdentityInputsV2) (hash : String → String)
    : Option String :=
  (serializeIdentityUses inputs).map hash

end Concrete.Proof

