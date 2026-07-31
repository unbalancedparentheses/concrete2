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

/-- Canonical encoding of a contract expression, or `none` when the expression
    falls outside the encodable fragment.

    `none` is load-bearing: it makes the containing facts record declare its
    contracts UNCOVERED rather than digesting a partial reading. Silently skipping
    an unencodable node would produce a digest that cannot see the very edit it is
    supposed to detect.

    Length-prefixed and tagged, like `pexprCanonical`, so two structurally
    different expressions cannot render alike. -/
partial def contractCanonical : Expr → Option String
  | .intLit _ v      => some s!"i:{v}"
  | .boolLit _ b     => some (if b then "b:1" else "b:0")
  | .charLit _ c     => some s!"c:{c.toNat}"
  | .strLit _ s      => some s!"s{s.length}:{s}"
  | .ident _ n       => some s!"v{n.length}:{n}"
  | .paren _ e       => contractCanonical e   -- grouping is syntax, not semantics
  | .binOp _ op l r  => do
    let a ← contractCanonical l
    let b ← contractCanonical r
    -- Explicit operator tag, never `repr`: this feeds a digest, and `repr` is
    -- derived formatting that a Lean or printer change can move.
    some s!"B{binOpTag op}l{a.length}:{a}r{b.length}:{b}"
  | .unaryOp _ op e  => do
    let a ← contractCanonical e
    some s!"U{unaryOpTag op}o{a.length}:{a}"
  | .call _ f _ args => do
    let parts ← args.mapM contractCanonical
    let joined := String.join (parts.map fun p => s!"a{p.length}:{p}")
    some s!"C{f.length}:{f}n{args.length}{joined}"
  | .fieldAccess _ o fld => do
    let a ← contractCanonical o
    some s!"F{fld.length}:{fld}o{a.length}:{a}"
  | .arrayIndex _ a i => do
    let x ← contractCanonical a
    let y ← contractCanonical i
    some s!"Xa{x.length}:{x}i{y.length}:{y}"
  -- Everything else is OUTSIDE the fragment. Enumerated rather than caught by a
  -- wildcard so a NEW Expr constructor fails to compile here and has to be
  -- classified deliberately — a wildcard would silently place it out of scope.
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
  -- `mk`/`litArm`/`varArm`/`rangeArm` are MatchArm constructors, not Expr ones;
  -- they sit in the same mutual block and are easy to mistake for Expr cases.

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

/-- Everything a proof subject is defined from, for ONE declaration, captured
    before contract erasure.

    The body is deliberately absent: it is already covered by extraction and
    `sourceBodyDigestV1`, and duplicating it here would state one fact in two
    places. These are the facts Core drops. -/
structure CheckedDeclFacts where
  /-- The compiler-minted identity. The KEY, not the name. -/
  id          : CallableId
  /-- Parameter names paired with canonical types. Names are included because a
      contract mentions them, so a rename changes what the contracts denote. -/
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
  let ps := String.join (f.params.map fun (n, t) => lp "n" n ++ lp "t" t)
  let tb := String.join (f.typeBounds.map fun (n, bs) =>
              lp "g" n ++ lp "B" (String.intercalate "," bs))
  let cs := String.join (f.contracts.requires.map (lp "R"))
          ++ String.join (f.contracts.ensures.map (lp "E"))
  String.join
    [ "subjectFactsV1:"
    , lp "I" f.id.render
    , lp "P" ps
    , lp "r" f.retTy
    , lp "T" (String.intercalate "," f.typeParams)
    , lp "G" tb
    , lp "c" (String.intercalate "," f.capParams)
    , lp "C" (String.intercalate "," f.capSet)
    , lp "K" cs
    , "cov:" ++ (if f.contracts.covered then "1" else "0")
    , "tr:" ++ (if f.isTrusted then "1" else "0")
    , "ov:" ++ (if f.overflowChecked then "1" else "0")
    ]

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
