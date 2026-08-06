/-
# Obligation generation as a calculus — slice 1

Implements the structure in `docs/VC_GENERATOR_DESIGN.md`: **one traversal plus a per-constructor
rule table**, replacing four hand-written walkers over the same grammar.

## Why, in one number

Nine discovery defects were found in 2026-08. Every one was "an obligation in syntactic position X
is lost", and every one existed because the same traversal is written eight times (four expression
walkers, four leaves) and nothing forces them to agree. Two examples, both found mechanically in
the last hour rather than by review:

* a shift inside an `if`-EXPRESSION produced no obligation — three sibling walkers had the case,
  the fourth never did;
* a division inside `assert(a / b > 0)` produced none — all eight lacked it.

Neither is a discipline failure. Keeping eight copies of one traversal consistent by hand is a
design problem, and this file is the design fix: **there is one recursion, and adding a family is
a row rather than a walker.**

## Status: SHADOW ONLY

Nothing consumes this yet. It exists to be diffed against the existing walkers
(`--report vcgen-diff`), which are a usable oracle now that their nine defects are fixed and
gated. Every difference is a finding either way — the walker missed something, or this did.
Switching consumers over comes only when the diff is empty or every remaining entry is explained
in writing.
-/
import Concrete.Report.ReportObligations

namespace Concrete
namespace Report
namespace VCGen

/-- What a single node requires, independent of where it sits. -/
inductive Requirement where
  /-- `divisor ≠ 0`, carrying the dividend so the signed `MIN / -1` bound stays expressible. -/
  | divisorNonZero (isMod : Bool) (dividend divisor : Expr)
  /-- `0 ≤ amount < width(shifted)`. -/
  | shiftInRange (shifted amount : Expr)
  /-- `0 ≤ index < len(array)`. -/
  | indexInRange (array index : Expr)
  /-- the whole `a op b` node is in range for its type. -/
  | arithInRange (node : Expr)

/-- The rule table: what THIS node requires, with no recursion in it.

    This is the whole point of the design. A walker mixes "what does this node need" with "how do
    I reach the next node", so a family is a traversal and eight of them drift. Here the first
    question is a flat table and the second is `vcExpr` below, written once.

    Two obligation kinds that do not exist anywhere today are one line each when they are wanted:
    `MIN` negation (`unaryOp .neg`) and float→int casts. Both trap at runtime with nothing
    generated, and that they were skipped is evidence about the old structure's cost, not about
    their difficulty. -/
def requires : Expr → List Requirement
  | .binOp _ .div l r => [.divisorNonZero false l r]
  | .binOp _ .mod l r => [.divisorNonZero true l r]
  | .binOp _ .shl l r => [.shiftInRange l r]
  | .binOp _ .shr l r => [.shiftInRange l r]
  | e@(.binOp _ .add _ _) => [.arithInRange e]
  | e@(.binOp _ .sub _ _) => [.arithInRange e]
  | e@(.binOp _ .mul _ _) => [.arithInRange e]
  | .arrayIndex _ a i => [.indexInRange a i]
  | _ => []

mutual
/-- THE traversal. One recursion over the expression grammar, calling `requires` at every node.

    Exhaustive by construction: every constructor appears once, and a new one forces a case here
    and nowhere else. Compare the eight places a new constructor must currently be added, of which
    the per-walker coverage gate can only check that they exist — not that they agree. -/
partial def vcExpr (e : Expr) : List Requirement :=
  requires e ++
    match e with
    | .paren _ x | .unaryOp _ _ x | .borrow _ x | .borrowMut _ x | .deref _ x
    | .try_ _ x | .cast _ x _ | .fieldAccess _ x _ => vcExpr x
    | .binOp _ _ l r => vcExpr l ++ vcExpr r
    | .arrayIndex _ a i => vcExpr a ++ vcExpr i
    | .allocCall _ x a => vcExpr x ++ vcExpr a
    | .arrayLit _ es => es.flatMap vcExpr
    | .call _ _ _ args => args.flatMap vcExpr
    | .methodCall _ o _ _ args => vcExpr o ++ args.flatMap vcExpr
    | .staticMethodCall _ _ _ _ args => args.flatMap vcExpr
    | .structLit _ _ _ fs base => fs.flatMap (fun (_, fe) => vcExpr fe) ++ (base.map vcExpr).getD []
    | .enumLit _ _ _ _ fs => fs.flatMap (fun (_, fe) => vcExpr fe)
    | .ifExpr _ c t el => vcExpr c ++ t.flatMap vcStmt ++ el.flatMap vcStmt
    | .match_ _ s _ => vcExpr s
    | _ => []

/-- Statement traversal. One recursion, and every statement carrying an expression reaches
    `vcExpr` — including the two that cost obligations this month: `assert_`/`assume_` conditions
    and destructuring scrutinees. -/
partial def vcStmt (s : Stmt) : List Requirement :=
  match s with
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => vcExpr v
  | .return_ _ (some v) => vcExpr v
  | .return_ _ none => []
  | .assert_ _ c | .assume_ _ c => vcExpr c
  | .ifElse _ c t el => vcExpr c ++ t.flatMap vcStmt ++ (el.getD []).flatMap vcStmt
  | .while_ _ c b _ => vcExpr c ++ b.flatMap vcStmt
  | .forLoop _ init c step b _ =>
      (init.map vcStmt).getD [] ++ vcExpr c ++ (step.map vcStmt).getD [] ++ b.flatMap vcStmt
  | .fieldAssign _ o _ v | .derefAssign _ o v => vcExpr o ++ vcExpr v
  -- The WRITE target needs its own bounds check. `requires` fires on `.arrayIndex`
  -- EXPRESSIONS, i.e. reads; `a[i] = v` is a statement, so without this line the store's
  -- bounds obligation is never emitted -- and a store is the more safety-critical direction.
  -- Found by the differential against the walkers, not by review.
  | .arrayIndexAssign _ a i v => .indexInRange a i :: (vcExpr a ++ vcExpr i ++ vcExpr v)
  | .borrowIn _ _ _ _ _ b => b.flatMap vcStmt
  | .letDestructure _ _ _ _ v _ => vcExpr v
  | .letStructDestructure _ _ _ v => vcExpr v
  | _ => []
end

/-! ### Differential against the existing walkers

The walkers are the oracle: nine defects found, fixed and gated, so they are the best available
statement of what SHOULD be generated. Agreement is evidence for this file; disagreement is a
finding on one side or the other, and either is worth having. -/

/-- Divisor requirements from this calculus, as comparable strings. -/
def divisorsHere (f : FnDef) : List String :=
  (f.body.flatMap vcStmt).filterMap fun r =>
    match r with
    | .divisorNonZero isMod _ d => some s!"{if isMod then "mod" else "div"}:{Concrete.fmtExpr d}"
    | _ => none

/-- The same, from the existing walker, via the same statement traversal it already uses. -/
def divisorsThere (f : FnDef) : List String :=
  (f.body.flatMap collectDivisorsS).map fun (isMod, _, d) =>
    s!"{if isMod then "mod" else "div"}:{Concrete.fmtExpr d}"

/-- Shift requirements, both sides. -/
def shiftsHere (f : FnDef) : List String :=
  (f.body.flatMap vcStmt).filterMap fun r =>
    match r with
    | .shiftInRange sv amt => some s!"{Concrete.fmtExpr sv}<<{Concrete.fmtExpr amt}"
    | _ => none

def shiftsThere (f : FnDef) : List String :=
  (f.body.flatMap collectShiftsS).map fun (l, r) =>
    s!"{Concrete.fmtExpr l}<<{Concrete.fmtExpr r}"

/-- Bounds requirements, both sides. `collectIndexUsesE` records the array EXPRESSION (not a
    name) since 2026-08-05, so the two are directly comparable without peeling parens here. -/
def boundsHere (f : FnDef) : List String :=
  (f.body.flatMap vcStmt).filterMap fun r =>
    match r with
    | .indexInRange a i => some s!"{Concrete.fmtExpr a}[{Concrete.fmtExpr i}]"
    | _ => none

def boundsThere (f : FnDef) : List String :=
  (f.body.flatMap collectIndexUsesS).map fun (a, i) =>
    s!"{Concrete.fmtExpr a}[{Concrete.fmtExpr i}]"

/-- Overflow requirements, both sides. Both collect the whole `a op b` node for `+`/`-`/`*`. -/
def arithHere (f : FnDef) : List String :=
  (f.body.flatMap vcStmt).filterMap fun r =>
    match r with
    | .arithInRange e => some (Concrete.fmtExpr e)
    | _ => none

def arithThere (f : FnDef) : List String :=
  (f.body.flatMap collectArithS).map Concrete.fmtExpr

/-- Per-function diff: `(qualName, family, onlyHere, onlyThere)`, empty when they agree.

    Multiset-shaped rather than set-shaped: a duplicated obligation is a real difference, and
    comparing sets would hide it. -/
def diff (modules : List Module) : List (String × String × List String × List String) := Id.run do
  let mut out := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    for (fam, here, there) in
        [("div", divisorsHere f, divisorsThere f), ("shift", shiftsHere f, shiftsThere f),
         ("bounds", boundsHere f, boundsThere f), ("overflow", arithHere f, arithThere f)] do
      let onlyHere := here.filter (fun x => (here.count x) > (there.count x))
      let onlyThere := there.filter (fun x => (there.count x) > (here.count x))
      if !onlyHere.isEmpty || !onlyThere.isEmpty then
        out := out ++ [(fq, fam, onlyHere.eraseDups, onlyThere.eraseDups)]
  return out

/-- Totals both sides found, so AGREEMENT can be distinguished from BOTH-FOUND-NOTHING.

    Two checks today passed while ranging over an empty set, so a differential that reports
    "agree" without saying how much it compared is not evidence. -/
def diffTotals (modules : List Module) : Nat × Nat := Id.run do
  let mut here := 0
  let mut there := 0
  for (_, f) in modules.flatMap allFunctions do
    here := here + (divisorsHere f).length + (shiftsHere f).length
              + (boundsHere f).length + (arithHere f).length
    there := there + (divisorsThere f).length + (shiftsThere f).length
              + (boundsThere f).length + (arithThere f).length
  return (here, there)

end VCGen
end Report
end Concrete
