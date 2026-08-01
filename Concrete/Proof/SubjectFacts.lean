import Concrete.Frontend.AST
import Concrete.Resolve.CallableId

/-! # Checked declaration facts (R-0004 slice 5, step 1)

The record a proof subject is defined FROM, captured before contracts are erased.

## Why this exists rather than a digest computed in Report

`CFnDef` deliberately does not carry `requires`/`ensures`: contracts are erased at
the AST→Core boundary and no codegen path consumes them, so widening Core with
them for proof bookkeeping would be the wrong trade. But `ProofCore` extraction
runs over Core, which leaves the Report layer as the only place that can currently
see signature and contract facts together — and computing an evidence-bearing
digest there would put the definition of a semantic fact in the layer whose job is
to RENDER semantic facts. That is the same inversion `CallableId` was moved out of
`Concrete/Proof` to avoid: a fact defined by its consumer is that consumer's
opinion.

So the facts are captured once, at the point where they are still all present, and
threaded to the consumers. The digest is then defined ONCE from the facts rather
than reconstructed per consumer.

## Keyed by `CallableId`

Not by qualified name. A name is a representation; two callables can share one and
a rename must not move a subject. The key is the identity the compiler already
mints from resolved facts.

## Coverage is part of the digest, not an assumption about it

`ProofSubjectFactsV1` records WHICH components it covers. A digest that silently
omits a component is worse than one that declares the omission, because a consumer
cannot tell a covered-and-unchanged subject from an uncovered one. `contracts`
carries `covered : Bool` for exactly this reason: contract expressions are encoded
over a deliberate fragment (comparisons, boolean connectives, arithmetic, calls,
literals, identifiers — what real `#[requires]`/`#[ensures]` use), and anything
outside it makes the encoding UNAVAILABLE rather than approximate. An
under-approximated contract digest would report "unchanged" across a contract edit
it could not read, which is precisely the bug-060 failure mode.
-/

namespace Concrete.Proof

open Concrete

/-- Canonical tag per source binary operator.

    Explicit, never `toString (repr op)`. This feeds a digest, and `repr` is
    derived FORMATTING that a Lean version or printer setting can change — the
    same reason `pbinOpCanonical` exists on the Proof side. Enumerated so a new
    operator fails to compile here rather than silently acquiring a tag. -/
def binOpTag : BinOp → String
  | .add => "add" | .sub => "sub" | .mul => "mul" | .div => "div" | .mod => "mod"
  | .eq => "eq"   | .neq => "neq" | .lt => "lt"   | .gt => "gt"
  | .leq => "leq" | .geq => "geq"
  | .and_ => "and" | .or_ => "or"
  | .bitand => "band" | .bitor => "bor" | .bitxor => "bxor"
  | .shl => "shl" | .shr => "shr"
  -- Width/overflow variants are DIFFERENT operations, not spellings of the same
  -- one: wrapping add and saturating add disagree at the boundary. The exhaustive
  -- match is what surfaced these — a wildcard would have given all six one tag.
  | .wrappingAdd => "wadd" | .wrappingSub => "wsub" | .wrappingMul => "wmul"
  | .saturatingAdd => "sadd" | .saturatingSub => "ssub" | .saturatingMul => "smul"

/-- Canonical tag per source unary operator. Same rule as `binOpTag`. -/
def unaryOpTag : UnaryOp → String
  | .neg => "neg" | .not_ => "not" | .bitnot => "bnot"

/-- The stable position of a bound name. Subject bytes use binder positions,
    never source spellings, so capture-avoiding alpha-renaming is invisible. -/
private def binderIndex? (binders : List String) (name : String) : Option Nat :=
  binders.findIdx? fun n => n == name

/-- Canonical type rendering relative to declaration binders.

    `tyCanonical` is the right rendering for a closed `CallableId`; declaration
    facts are different because their signature may still contain bound type and
    capability variables. Those variables are identified by position, not by the
    spelling chosen in source. -/
mutual
def boundTyCanonical (typeBinders capBinders : List String) : Ty → String
  | .int => "Int" | .uint => "Uint"
  | .i8 => "i8" | .i16 => "i16" | .i32 => "i32"
  | .u8 => "u8" | .u16 => "u16" | .u32 => "u32"
  | .bool => "Bool" | .char => "Char" | .unit => "Unit"
  | .float64 => "Float64" | .float32 => "Float32"
  | .string => "String" | .never => "Never" | .placeholder => "?"
  | .named n =>
      match binderIndex? typeBinders n with
      | some i => s!"'t{i}"
      | none => n
  | .typeVar n =>
      match binderIndex? typeBinders n with
      | some i => s!"'t{i}"
      | none => "'free:" ++ n
  | .ref t => "&" ++ boundTyCanonical typeBinders capBinders t
  | .refMut t => "&mut " ++ boundTyCanonical typeBinders capBinders t
  | .ptrMut t => "*mut " ++ boundTyCanonical typeBinders capBinders t
  | .ptrConst t => "*const " ++ boundTyCanonical typeBinders capBinders t
  | .heap t => "Heap<" ++ boundTyCanonical typeBinders capBinders t ++ ">"
  | .heapArray t => "HeapArray<" ++ boundTyCanonical typeBinders capBinders t ++ ">"
  | .array t n => "[" ++ boundTyCanonical typeBinders capBinders t ++ ";" ++ toString n ++ "]"
  | .generic n args => n ++ "<" ++ boundTyListCanonical typeBinders capBinders args ++ ">"
  | .fn_ params caps ret =>
      let (concrete, vars) := caps.normalize
      let cs := String.intercalate "+" concrete
      let vs := vars.map fun v =>
        match binderIndex? capBinders v with
        | some i => s!"c{i}"
        | none => "free:" ++ v
      "fn(" ++ boundTyListCanonical typeBinders capBinders params ++ ")with("
        ++ cs ++ (if vs.isEmpty then "" else "|" ++ String.intercalate "+" vs)
        ++ ")->" ++ boundTyCanonical typeBinders capBinders ret

def boundTyListCanonical (typeBinders capBinders : List String) : List Ty → String
  | [] => ""
  | [t] => boundTyCanonical typeBinders capBinders t
  | t :: ts => boundTyCanonical typeBinders capBinders t ++ ","
      ++ boundTyListCanonical typeBinders capBinders ts
end

/-- Canonical encoding of a contract relative to its declaration.

    Local variables are de-Bruijn-like parameter positions. A definition call
    must be resolved to a compiler-minted `CallableId`; an unresolved textual
    name makes the contract unavailable rather than entering evidence bytes.
    Generic call arguments are included and must complete the callee identity. -/
partial def contractCanonicalIn
    (termBinders typeBinders capBinders : List String)
    (allowResult : Bool)
    (resolveCall : String → Option CallableId) : Expr → Option String
  | .intLit _ v      => some s!"i:{v}"
  | .boolLit _ b     => some (if b then "b:1" else "b:0")
  | .charLit _ c     => some s!"c:{c.toNat}"
  | .strLit _ s      => some s!"s{s.length}:{s}"
  | .ident _ n       =>
      if allowResult && n == "result" then some "q:result"
      else match binderIndex? termBinders n with
        | some i => some s!"p:{i}"
        | none => some s!"g{n.length}:{n}"
  | .paren _ e       => contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall e
  | .binOp _ op l r  => do
    let a ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall l
    let b ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall r
    some s!"B{binOpTag op}l{a.length}:{a}r{b.length}:{b}"
  | .unaryOp _ op e  => do
    let a ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall e
    some s!"U{unaryOpTag op}o{a.length}:{a}"
  | .call _ f typeArgs args => do
    let base ← resolveCall f
    let canonicalArgs := typeArgs.map fun t => boundTyCanonical typeBinders capBinders t
    -- Render the resolved BASE plus binder-relative arguments. Constructing a
    -- specialized `CallableId` here would render a bound `T` by its source
    -- spelling and reintroduce alpha sensitivity through `CallableId.render`.
    if typeArgs.length != base.typeParams then none else
      let parts ← args.mapM (contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall)
      let joined := String.join (parts.map fun p => s!"a{p.length}:{p}")
      let tys := String.join (canonicalArgs.map fun t => s!"t{t.length}:{t}")
      some s!"C{base.render.length}:{base.render}n{typeArgs.length}{tys}m{args.length}{joined}"
  | .fieldAccess _ o fld => do
    let a ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall o
    some s!"F{fld.length}:{fld}o{a.length}:{a}"
  | .arrayIndex _ a i => do
    let x ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall a
    let y ← contractCanonicalIn termBinders typeBinders capBinders allowResult resolveCall i
    some s!"Xa{x.length}:{x}i{y.length}:{y}"
  | .floatLit _ _ => none
  | .structLit _ _ _ _ _ => none
  | .enumLit _ _ _ _ _ => none
  | .match_ _ _ _ => none
  | .borrow _ _ => none
  | .borrowMut _ _ => none
  | .deref _ _ => none
  | .try_ _ _ => none
  | .arrayLit _ _ => none
  | .cast _ _ _ => none
  | .methodCall _ _ _ _ _ => none
  | .staticMethodCall _ _ _ _ _ => none
  | .fnRef _ _ => none
  | .allocCall _ _ _ => none
  | .ifExpr _ _ _ _ => none

/-- Canonical encoding of a contract expression, or `none` when the expression
    falls outside the encodable fragment.

    `none` is load-bearing: it makes the containing facts record declare its
    contracts UNCOVERED rather than digesting a partial reading. Silently skipping
    an unencodable node would produce a digest that cannot see the very edit it is
    supposed to detect.

    Length-prefixed and tagged, like `pexprCanonical`, so two structurally
    different expressions cannot render alike. -/
partial def contractCanonical : Expr → Option String
  | e => contractCanonicalIn [] [] [] true (fun _ => none) e

/-- Contracts attached to a declaration, with an explicit coverage flag.

    `covered = false` means at least one contract fell outside the encodable
    fragment, so `canonical` describes only part of the contract set and must not
    be treated as identifying it. -/
structure ContractFacts where
  requires  : List String := []
  ensures   : List String := []
  /-- False when any contract was unencodable. See the module header. -/
  covered   : Bool := true
deriving Repr, BEq, Inhabited

/-- Build contract facts, collapsing to `covered := false` if anything in the set
    is unencodable. Deliberately all-or-nothing per declaration: a half-read
    contract set is not a smaller true statement, it is a false one. -/
def ContractFacts.of (reqs ens : List Expr) : ContractFacts :=
  let enc := fun (es : List Expr) => es.map contractCanonical
  let rs := enc reqs
  let es := enc ens
  if rs.any (·.isNone) || es.any (·.isNone) then
    { requires := [], ensures := [], covered := false }
  else
    { requires := rs.filterMap id, ensures := es.filterMap id, covered := true }

/-- Build contract facts in their declaration environment. This is the producer
    used by Elab; the binder-free `of` above remains useful for closed probes. -/
def ContractFacts.ofResolved
    (params typeParams capParams : List String)
    (resolveCall : String → Option CallableId)
    (reqs ens : List Expr) : ContractFacts :=
  let rs := reqs.map (contractCanonicalIn params typeParams capParams false resolveCall)
  let es := ens.map (contractCanonicalIn params typeParams capParams true resolveCall)
  if rs.any (·.isNone) || es.any (·.isNone) then
    { requires := [], ensures := [], covered := false }
  else
    { requires := rs.filterMap id, ensures := es.filterMap id, covered := true }

/-- Everything a proof subject is defined from, for ONE declaration, captured
    before contract erasure.

    The body is deliberately absent: it is already covered by extraction and
    `sourceBodyDigestV1`, and duplicating it here would state one fact in two
    places. These are the facts Core drops. -/
structure CheckedDeclFacts where
  /-- The compiler-minted identity. The KEY, not the name. -/
  id          : CallableId
  /-- Source parameter names paired with binder-relative canonical types.
      Names are diagnostic only; `canonical` uses position and type. -/
  params      : List (String × String) := []
  retTy       : String := ""
  /-- Type parameters and their bounds, canonically ordered by the parameter's
      declared position (which is semantic — `<T, U>` is not `<U, T>`). -/
  typeParams  : List String := []
  typeBounds  : List (String × List String) := []
  /-- Capability variables and the concrete capability set, both normalized so
      union order cannot produce two facts for one declaration. -/
  capParams   : List String := []
  capSet      : List String := []
  contracts   : ContractFacts := {}
  /-- Declaration-level flags that change what a proof may assume. `isTrusted` in
      particular is a trust boundary and must not be invisible to a subject. -/
  isTrusted   : Bool := false
  overflowChecked : Bool := false
deriving Repr, BEq, Inhabited

/-- Canonical, length-prefixed rendering. Feeds the subject digest.

    The COVERAGE FLAG is inside the rendering, so a facts record whose contracts
    could not be read cannot collide with one whose contracts are genuinely
    absent. Those are different states and a digest must not merge them. -/
def CheckedDeclFacts.canonical (f : CheckedDeclFacts) : String :=
  let lp := fun (tag s : String) => s!"{tag}{s.length}:{s}"
  let ps := String.join (f.params.map fun (_, t) => lp "t" t)
  let tb := String.join (f.typeBounds.map fun (_, bs) =>
              lp "B" (String.intercalate "," bs))
  let cs := String.join (f.contracts.requires.map (lp "R"))
          ++ String.join (f.contracts.ensures.map (lp "E"))
  String.join
    [ "subjectFactsV1:"
    , lp "I" f.id.render
    , lp "P" ps
    , lp "r" f.retTy
    , lp "T" (toString f.typeParams.length)
    , lp "G" tb
    , lp "c" (toString f.capParams.length)
    , lp "C" (String.intercalate "," f.capSet)
    , lp "K" cs
    , "cov:" ++ (if f.contracts.covered then "1" else "0")
    , "tr:" ++ (if f.isTrusted then "1" else "0")
    , "ov:" ++ (if f.overflowChecked then "1" else "0")
    ]

/-- A declaration is eligible to mint a complete subject only when every
    required component was captured and its callable identity is complete. -/
def CheckedDeclFacts.isComplete (f : CheckedDeclFacts) : Bool :=
  f.id.isComplete && f.contracts.covered

/-- All declarations' facts for one program, keyed by identity.

    A list rather than a map so it can be ordered canonically and digested; lookup
    goes through `find?` on the rendered identity, never on a name. -/
structure ProgramFacts where
  schemaVersion : Nat := 1
  decls : List CheckedDeclFacts := []
deriving Repr, Inhabited

/-- Facts for one identity, resolved by IDENTITY rather than by name. -/
def ProgramFacts.find? (p : ProgramFacts) (id : CallableId) : Option CheckedDeclFacts :=
  p.decls.find? fun d => d.id.render == id.render

end Concrete.Proof
