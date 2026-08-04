import Concrete.Proof.SubjectFacts

/-! # Typed evidence tree (ProofBodyCanonicalV2's input)

The semantic body of a declaration, as elaboration resolved it. A TREE, not a flat
stream: nesting is semantic — `(p + q) * r` and `p + (q * r)` are different bodies,
as are `f(g(x))` and `g(f(x))` — and a tree makes malformed nesting UNREPRESENTABLE
rather than merely detectable. The alternative, an arity-tagged flat stream, is
injective but lets the producer emit a malformed stream the serializer must
reconstruct and validate, duplicating structure the elaborator already knows and
adding a second correctness problem where there was one.

Every reference here is a compiler-minted identity, never a source spelling:
`CallableId`, `TypeId`, `FieldId`, `VariantId`, `ConstId`, and binders as relative
lexical positions. Literal VALUES are ordinary program data and are carried as such.

`gap` is the fail-closed constructor and the reason this can be exhaustive from the
start. A producer meeting a construct it cannot yet describe must emit `gap` with a
reason; it may not emit nothing. "Handled nothing" is unrepresentable, so an
unfinished vocabulary shows up as a refusal rather than as a body that silently
under-approximates — the failure mode measured on the flat serializer, where
`p + 1`, `p * 2` and `p - 9` were byte-identical.
-/

namespace Concrete.Proof

/-- Why a construct could not be described. Carried so a refusal is diagnosable
    rather than anonymous; the reason is NOT a source name. -/
inductive EvidenceGap where
  /-- The producer has no case for this construct yet. -/
  | unhandledConstruct (kind : String)
  /-- The construct resolved, but no semantic identity was available for it. -/
  | unresolvedIdentity (kind : String)
deriving BEq, Repr, Inhabited

mutual

/-- An expression, as resolved evidence. -/
inductive EvidenceExprV2 where
  /-- Literal program data. Values, not identities: a literal is not an entity. -/
  | intLit   (value : Int)
  | boolLit  (value : Bool)
  | strLit   (value : String)
  | charLit  (value : Char)
  /-- A local, by RELATIVE lexical position: frames crossed outward, then index. -/
  | binderRef (framesOut idx : Nat)
  /-- A module constant, by identity. Its VALUE is bound at the declaration, so a
      reference need only name it. -/
  | constRef (id : ConstId)
  | unary  (op : String) (operand : EvidenceExprV2)
  | binary (op : String) (lhs rhs : EvidenceExprV2)
  /-- A call to a resolved callee. Argument ORDER is semantic. -/
  | call (callee : CallableId) (args : List EvidenceExprV2)
  /-- Field projection: the owner-relative field identity plus the object. -/
  | field (id : FieldId) (object : EvidenceExprV2)
  /-- Construction of a struct. Field order is normalized by the producer so two
      spellings of one value cannot differ here. -/
  | structLit (ty : TypeId) (fields : List (FieldId × EvidenceExprV2))
  /-- Construction of an enum variant. -/
  | variantLit (id : VariantId) (fields : List (FieldId × EvidenceExprV2))
  | deref     (inner : EvidenceExprV2)
  | borrow    (isMut : Bool) (inner : EvidenceExprV2)
  | index     (collection index : EvidenceExprV2)
  | cast      (target : TypeId) (inner : EvidenceExprV2)
  /-- A function used as a value. -/
  | fnRef (id : CallableId)
  /-- FAIL CLOSED. Not an expression the producer understood. -/
  | gap (reason : EvidenceGap)
deriving Inhabited

/-- A statement, as resolved evidence. -/
inductive EvidenceStmtV2 where
  /-- A binding. The bound NAME is absent: it is referred to by position. -/
  | letBind (ty : Option TypeId) (initializer : EvidenceExprV2)
  | assign  (place value : EvidenceExprV2)
  | ret     (value : Option EvidenceExprV2)
  | branch  (condition : EvidenceExprV2) (thenBody elseBody : List EvidenceStmtV2)
  | match_  (scrutinee : EvidenceExprV2) (arms : List EvidenceArmV2)
  /-- A loop, carrying its CONTRACTS: an invariant edit changes the obligation, so
      omitting them would make an invariant change invisible to the subject. -/
  | loop    (condition : EvidenceExprV2) (invariants : List EvidenceExprV2)
            (variant : Option EvidenceExprV2) (body : List EvidenceStmtV2)
  | block   (statements : List EvidenceStmtV2)
  | exprStmt (value : EvidenceExprV2) (isValue : Bool)
  | breakStmt (value : Option EvidenceExprV2)
  | continueStmt
  /-- FAIL CLOSED. -/
  | gap (reason : EvidenceGap)
deriving Inhabited

/-- A match arm. Pattern bindings are positional, so only their COUNT is recorded —
    the names are never part of the evidence. -/
inductive EvidenceArmV2 where
  | variantArm (id : VariantId) (bindingCount : Nat)
               (guard : Option EvidenceExprV2) (body : List EvidenceStmtV2)
  | litArm (value : EvidenceExprV2) (guard : Option EvidenceExprV2)
           (body : List EvidenceStmtV2)
  | bindArm (guard : Option EvidenceExprV2) (body : List EvidenceStmtV2)
  | rangeArm (lo hi : EvidenceExprV2) (inclusive : Bool)
             (guard : Option EvidenceExprV2) (body : List EvidenceStmtV2)
  | gap (reason : EvidenceGap)
deriving Inhabited

end

/-- A declaration's evidence body. -/
structure EvidenceBodyV2 where
  statements : List EvidenceStmtV2 := []
deriving Inhabited

end Concrete.Proof
