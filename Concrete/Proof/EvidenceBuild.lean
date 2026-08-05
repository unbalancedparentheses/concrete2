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

/-- Array literal in SOURCE order — measured observable: `[f(), g()]` and `[g(), f()]`
    run their elements in the order written. Not sorted, not deduplicated: repetition
    and order are both semantic. -/
def evArrayLit (elemTy : TypeId) (elements : List EvidenceExprV2) : EvidenceExprV2 :=
  .arrayLit elemTy elements

def evIndex (collection index : EvidenceExprV2) : EvidenceExprV2 := .index collection index
def evDeref (inner : EvidenceExprV2) : EvidenceExprV2 := .deref inner
def evBorrow (isMut : Bool) (inner : EvidenceExprV2) : EvidenceExprV2 := .borrow isMut inner
def evCast (target : TypeId) (inner : EvidenceExprV2) : EvidenceExprV2 := .cast target inner

/-- `expr?`. Distinct from its operand: the propagation path is part of the meaning. -/
def evTryProp (operand : EvidenceExprV2) (residualTy : TypeId) : EvidenceExprV2 :=
  .tryProp operand residualTy

/-- Field projection. Owner-relative identity, so `a.x` and `b.x` on different types are
    different evidence even though the spelling matches. -/
def evField (id : FieldId) (object : EvidenceExprV2) : EvidenceExprV2 := .field id object

/-- STRUCT LITERALS ARE DELIBERATELY NOT BUILT YET.

    `FieldId` keys each entry under either outcome, but the ORDER of entries is an open
    language decision: struct-literal initializers currently evaluate in DECLARATION
    order while every other positional construct follows SOURCE order. Building the node
    now would bake whichever order I picked into versioned bytes before anyone decided,
    and a wrong choice there is not a refusal — it is a body that records an evaluation
    order the program does not have. See docs/EVIDENCE_PRODUCER_MATRIX.md.

    Until then a struct literal is a typed gap, so a subject containing one is REFUSED
    rather than described incorrectly. -/
def evStructLitPending : EvidenceExprV2 :=
  .gap { code := .unhandledExpr,
         detail := "struct literal: initializer evaluation order is an open decision" }

/-- A call to a resolved callee. Argument order is the ARGUMENT list's order, which is
    the evaluation order — measured observable for calls.

    An INCOMPLETE identity is refused: a generic callable missing its type arguments
    would otherwise enter evidence looking resolved. -/
def evCall (callee : CallableId) (args : List EvidenceExprV2) : EvidenceExprV2 :=
  if callee.isComplete then .call callee args
  else .gap { code := .unresolvedCallee, detail := "incomplete callee identity" }

/-- A call whose callee could not be resolved to an identity at all. Separate from
    `evCall` so the two refusal REASONS stay distinct in the gap inventory: an
    unresolvable callee is a producer gap, an incomplete one is an identity defect. -/
def evUnresolvedCall : EvidenceExprV2 :=
  .gap { code := .unresolvedCallee, detail := "callee not resolvable to a CallableId" }

/-- Anything the producer has no case for yet. The kind string is DIAGNOSTIC only —
    `CompleteEvidenceBodyV2` cannot carry a gap, so it never reaches bytes. -/
def evUnhandledExpr (kind : String) : EvidenceExprV2 :=
  .gap { code := .unhandledExpr, detail := kind }

def evUnhandledStmt (kind : String) : EvidenceStmtV2 :=
  .gap { code := .unhandledStmt, detail := kind }

/-- Resolve a `break`/`continue` label to a RELATIVE loop target: 0 is the innermost
    enclosing loop, counting outward. Never the label spelling — renaming a label must
    not move a digest.

    `none` when there is no enclosing loop, or when a named label matches none of them.
    Both are refusals rather than a default of 0, which would silently retarget a
    mislabelled break at the innermost loop. -/
def evLoopTarget? (frames : List (Option String)) (label : Option String) : Option Nat :=
  match label with
  | none   => if frames.isEmpty then none else some 0
  | some l => frames.findIdx? fun f => f == some l

/-- Parentheses are TRANSPARENT: they emit no node. `(p)` and `p` are the same program,
    so an extra wrapper would make a purely syntactic edit move the digest. -/
def evParen (inner : EvidenceExprV2) : EvidenceExprV2 := inner

end Concrete.Proof
