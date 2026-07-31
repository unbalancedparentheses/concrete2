import Lean
import Concrete.Proof.DependencyEdge

/-! # Deriving a dependency edge from a theorem (R-0004 step 6)

The classifier. It reads the ELABORATED TYPE of a theorem and answers what that
theorem relies on, so the edge is derived from the proof rather than declared by
its author.

## The discriminator

* every `FnTable`-typed subterm is a BOUND VARIABLE → `contract`. The theorem
  holds for any table meeting its hypotheses, so no callee body can affect it.
* the type names concrete table CONSTANTS → `body`. The theorem is about those
  exact entries, and any relevant body change stales it.

Source text cannot answer this. `fns` and `combineFns` are both identifiers on the
page; the difference appears only after elaboration.

## Table-valued expressions, and why a naive test fails OPEN

A first version tested "is this a constant whose TYPE is `FnTable`". That misses a
table built inline — `eval (FnTable.ofGlobals g) …` mentions `FnTable.ofGlobals`,
a constant of FUNCTION type, so the test finds no table constant and answers
`contract` for a theorem that depends on concrete entries. Failing toward
`contract` is the unsafe direction: it says "an implementation change cannot
affect this" about a proof that an implementation change breaks.

So a constant counts as table-valued when its type RETURNS `FnTable` after any
number of arguments, not only when it IS `FnTable`. Measured when this was
written: 11 plain table definitions and 4 table-valued combinators
(`FnTable.mk`, `.ofGlobals`, `.withCallables`, and the flat constructor), and 8
theorems that mention a combinator without naming a table — all of them
metatheory about `FnTable` itself rather than claims about a program. The gap was
latent, not live, and it is closed here before it becomes live.

## What this does NOT decide

`trusted` and `missing` are not properties of the theorem's type: a dependency is
trusted because the callee declares a boundary, and missing because nothing
validated it. Those come from the callee's status, and this classifier
deliberately does not guess them — it reports what the theorem uses, and returns
`none` when the theorem depends on no table at all.
-/

namespace Concrete.Proof

open Lean Meta

/-- Is this constant table-VALUED — either an `FnTable` or a function returning
    one? The second case is what a naive "type is FnTable" test misses. -/
def isTableValued (ci : ConstantInfo) : MetaM Bool := do
  let tableTy : Lean.Expr := mkConst ``Concrete.Proof.FnTable
  if (← isDefEq ci.type tableTy) then return true
  forallTelescope ci.type fun _ b => isDefEq b tableTy

/-- Names of table-valued constants appearing in `e`. -/
def tableConstsIn (e : Lean.Expr) : MetaM (List Name) := do
  let mut out : List Name := []
  for c in e.getUsedConstants do
    match (← try pure (some (← getConstInfo c)) catch _ => pure none) with
    | some ci => if (← isTableValued ci) then out := c :: out
    | none    => pure ()
  return out.eraseDups

/-- The result of reading a theorem's type: which edge it implies, and the
    concrete tables it names (empty for a `contract` edge).

    The tables are carried, not just the verdict, because a `body` edge has to say
    WHICH entries it binds — a receipt recording only "body" would not let a
    consumer decide whether a given change stales it. -/
structure EdgeEvidence where
  edge   : DependencyEdge
  tables : List Name
  /-- True when the type quantifies over some `FnTable`. Kept alongside `edge` so
      a caller can see the two facts that produced the verdict rather than having
      to trust it. -/
  quantifiesOverTable : Bool
deriving Repr, Inhabited

/-- Derive the edge a theorem implies, or `none` if it depends on no table.

    `none` is deliberately distinct from `missing`: a theorem that never mentions
    a table has no table dependency to classify, whereas `missing` means there IS
    a dependency and nothing validated it. Collapsing them would let "irrelevant"
    read as "unvalidated" and contain claims that are fine. -/
def classifyTheorem (n : Name) : MetaM (Option EdgeEvidence) := do
  let info ← getConstInfo n
  let tableTy : Lean.Expr := mkConst ``Concrete.Proof.FnTable
  forallTelescope info.type fun xs body => do
    let mut bound := false
    for x in xs do
      if (← isDefEq (← inferType x) tableTy) then bound := true
    let mut exprs := [body]
    for x in xs do exprs := (← inferType x) :: exprs
    let mut consts : List Name := []
    for e in exprs do consts := consts ++ (← tableConstsIn e)
    let named := consts.eraseDups
    if named.isEmpty && !bound then return none
    -- Naming a concrete table wins: such a theorem depends on those entries even
    -- if it ALSO quantifies over some other table. Answering `contract` there
    -- would be the fail-open direction.
    if !named.isEmpty then
      return some { edge := .body, tables := named, quantifiesOverTable := bound }
    return some { edge := .contract, tables := [], quantifiesOverTable := true }

end Concrete.Proof
