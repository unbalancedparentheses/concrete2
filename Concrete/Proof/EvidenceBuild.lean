import Concrete.Proof.EvidenceTree
import Concrete.Proof.BodyScope

/-! # Evidence builders

Pure constructors from elaboration inputs to evidence nodes. They exist so the
producer cutover is MECHANICAL rather than semantic: every decision about what a
construct means is made and tested here, while `elabExpr` stays green and unchanged.
When the mutual family is finally renamed, each return site calls a builder that
already has its own gates.

Canonicality decisions live here too, stated once rather than re-derived per call
site. Where a builder cannot produce a faithful node it returns a typed `gap`; it
never guesses, because a guessed node looks resolved and is worse than a refusal.
-/

namespace Concrete.Proof

/-- Integer literal with its semantic width, or a gap when the resolved type is not an
    integer at all. A non-integer here is a caller error; inventing a width would put a
    wrong fact into evidence. -/
def evIntLit (value : Int) (ty : Ty) : EvidenceExprV2 :=
  match evIntTyOf? ty with
  | some w => .intLit value w
  | none   => .gap { code := .unhandledExpr, detail := "int literal with non-integer type" }

/-- Float literal as a BIT PATTERN. `Float.toBits` preserves NaN payloads and signed
    zeros, which a decimal rendering would lose and a canonicalization would merge. -/
def evFloatLit (value : Float) (ty : Ty) : EvidenceExprV2 :=
  match ty with
  | .float64 => .floatLit value.toBits .f64
  | .float32 => .floatLit value.toBits .f32
  | _        => .gap { code := .unhandledExpr, detail := "float literal with non-float type" }

def evBoolLit (b : Bool) : EvidenceExprV2 := .boolLit b
def evStrLit (s : String) : EvidenceExprV2 := .strLit s
def evCharLit (c : Char) : EvidenceExprV2 := .charLit c

/-- A local reference, as a relative lexical position. Unplaceable names become a gap
    rather than position 0, which would silently alias every unresolvable local to the
    innermost binder. -/
def evBinderRef (scope : BodyScope) (name : String) : EvidenceExprV2 :=
  match scope.resolve? name with
  | some (out, idx) => .binderRef out idx
  | none => .gap { code := .unplaceableBinder, detail := "local not in any lexical frame" }

/-- A module constant. The defining module must be known: without it two same-spelled
    constants in different modules would share an identity, so an empty path is a gap
    rather than a `ConstId` with a blank module. -/
def evConstRef (proofPath declName : String) : EvidenceExprV2 :=
  if proofPath.isEmpty then
    .gap { code := .unresolvedConst, detail := "constant with no defining module" }
  else .constRef { defModule := proofPath, declName := declName }

/-- A function used as a value. Incomplete identities are refused: `CallableId.isComplete`
    is false when a generic callable's type arguments are missing, and an incomplete
    identity in evidence is precisely the confidently-wrong-identity failure. -/
def evFnRef (id : CallableId) : EvidenceExprV2 :=
  if id.isComplete then .fnRef id
  else .gap { code := .unresolvedCallee, detail := "incomplete callable identity" }

/-- Unary operator. The tag comes from `unaryOpTag`, the SAME owner the contract
    encoder uses — two tag tables would be two facts that can disagree. -/
def evUnary (op : UnaryOp) (operand : EvidenceExprV2) : EvidenceExprV2 :=
  .unary (unaryOpTag op) operand

/-- Binary operator, tagged by the shared `binOpTag`.

    Operand order is preserved verbatim: `a - b` is not `b - a`, and even for
    commutative operators the EVALUATION order is observable, so normalizing would
    merge programs that differ. -/
def evBinary (op : BinOp) (lhs rhs : EvidenceExprV2) : EvidenceExprV2 :=
  .binary (binOpTag op) lhs rhs

/-- Parentheses are TRANSPARENT: they emit no node. `(p)` and `p` are the same program,
    so an extra wrapper would make a purely syntactic edit move the digest. -/
def evParen (inner : EvidenceExprV2) : EvidenceExprV2 := inner

end Concrete.Proof
