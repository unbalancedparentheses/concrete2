/-
# Non-arithmetic multi-kernel evidence: boolean postconditions

Every kernel-agreement demo before this one is **linear integer arithmetic** — `omega`, `lia`,
`presburger`. Three kernels agreeing on arithmetic is a real result, but it exercises one theory,
and each prover's decision procedure for it is mature and well-trodden.

This module carries the first NON-arithmetic obligation to all three kernels: a boolean
postcondition, discharged by case analysis rather than by an arithmetic decision procedure.

## Why booleans first, and not merely because they are easy

The multi-kernel claim does not rest on "three provers said yes". It rests on: each kernel closed
a lowering **whose truth table matches the reference evaluator**, which is what prevents a kernel
from proving a *different* proposition and having that counted. For a boolean goal over `n`
variables that check is **exhaustive** — all `2^n` assignments, no sampling. Arithmetic
obligations can only be checked on chosen instances, and an inductive property over unbounded
inputs could not be checked at all.

So booleans are the one rung of the ladder where faithfulness is *complete* rather than sampled.
That is a stronger agreement argument than the arithmetic tier has, on a weaker theory.

## Why Concrete `bool` maps to Rocq `bool`, not `Prop`

`Prop` would be unfaithful and would drag in axioms. Concrete's `bool` is two-valued and
decidable; Rocq's `Prop` is intuitionistic, so De Morgan's `~(a /\ b) -> ~a \/ ~b` is **not
provable** there without classical logic. Lowering to `Prop` would therefore either fail or
require `Classical`, which `Print Assumptions` would then report — turning an axiom-free
attestation into an axiom-bearing one for no reason. Over `bool` the same fact is
`destruct a, b; reflexivity`: constructive, and verified axiom-free
("Closed under the global context") against real `coqc`.

Isabelle/HOL is classical, so `by simp` closes it either way; Lean's `decide` needs the
decidable `Bool` for the same reason Rocq does. The three lowerings therefore agree on `bool`
and would NOT agree on `Prop` — which is itself a finding about cross-logic portability that
only a non-arithmetic obligation could surface.
-/
import Concrete.Report.ReportObligations

namespace Concrete
namespace Report

open Concrete.TermIR

/-- One boolean postcondition obligation: `bodyExpr = postExpr`, over boolean variables.

    Restricted to a function whose body is a single `return <expr>`, because substituting the
    body into the postcondition is only sound when there is nothing else to execute — no
    assignment, no branch, no call with an effect. A wider body needs the operational step that
    the `refinement` profile names and this does not attempt. -/
structure BoolObl where
  fnQual   : String
  key      : String
  /-- Boolean parameter names, in declaration order. -/
  vars     : List String
  /-- The returned expression — the left side of the equivalence. -/
  bodyExpr : Expr
  /-- The postcondition's right side, from `#[ensures(result == …)]`. -/
  postExpr : Expr

/-- Is every parameter boolean, and is the return type boolean? -/
private def allBoolParams (f : FnDef) : Bool :=
  f.retTy == .bool && !f.params.isEmpty && f.params.all (fun p => p.ty == .bool)

/-- `#[ensures(result == <expr>)]` → `<expr>`. Only this exact shape; anything else is left
    alone rather than guessed at. -/
private def resultEquivOf : Expr → Option Expr
  | .binOp _ .eq (.ident _ "result") rhs => some rhs
  | .binOp _ .eq lhs (.ident _ "result") => some lhs
  | .paren _ e => resultEquivOf e
  | _ => none

/-- The single returned expression of a one-statement body. -/
private def soleReturnOf : List Stmt → Option Expr
  | [.return_ _ (some e)] => some e
  | _ => none

/-- Collect boolean postcondition obligations.

    Deliberately narrow: all-boolean signature, a single `return`, and an `#[ensures]` of the
    form `result == <expr>`. Everything outside that shape is skipped, and `boolKernelSkipped`
    reports the count so "0 obligations" cannot be read as "nothing to prove here". -/
def boolPostObligations (modules : List Module) : List BoolObl := Id.run do
  let mut out : List BoolObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    if allBoolParams f then
      match soleReturnOf f.body with
      | none => pure ()
      | some body =>
        let mut i := 0
        for ens in f.ensures do
          match resultEquivOf ens with
          | none => pure ()
          | some post =>
            out := out ++ [{ fnQual := pfx ++ f.name, key := s!"{pfx}{f.name}#boolpost{i}"
                           , vars := f.params.map (·.name), bodyExpr := body, postExpr := post }]
            i := i + 1
  return out

/-- Functions with an all-boolean signature that were SKIPPED, and why — so coverage is stated
    rather than implied. -/
def boolKernelSkipped (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for (pfx, f) in modules.flatMap allFunctions do
    if allBoolParams f then
      if (soleReturnOf f.body).isNone then
        out := out ++ [(pfx ++ f.name, "body is not a single `return` (needs the operational step)")]
      else if f.ensures.all (fun e => (resultEquivOf e).isNone) then
        out := out ++ [(pfx ++ f.name, "no `#[ensures(result == …)]` postcondition")]
  return out

/-! ## Exhaustive agreement with the reference evaluator

The arithmetic tier checks its lowerings on chosen instances. Over booleans every assignment can
be enumerated, so agreement is **decided**, not sampled. -/

/-- All `2^n` boolean assignments to `vars`. -/
def allAssignments : List String → List BoolEnv
  | [] => [[]]
  | v :: rest => (allAssignments rest).flatMap (fun a => [(v, true) :: a, (v, false) :: a])

/-- The obligation's truth value under one assignment: does the body agree with the
    postcondition? `none` if either side is not evaluable, which must NOT be read as `true`. -/
def BoolObl.evalUnder (o : BoolObl) (benv : BoolEnv) : Option Bool := do
  let l ← evalBoolEnv [] o.bodyExpr benv
  let r ← evalBoolEnv [] o.postExpr benv
  some (l == r)

/-- Is the obligation TRUE on every assignment? `none` if any assignment fails to evaluate —
    an unevaluable row makes the answer unknown rather than false. -/
def BoolObl.holdsEverywhere (o : BoolObl) : Option Bool := Id.run do
  let mut sawUnknown := false
  let mut allTrue := true
  for benv in allAssignments o.vars do
    match o.evalUnder benv with
    | none => sawUnknown := true
    | some b => if !b then allTrue := false
  return if sawUnknown then none else some allTrue

/-! ## The three lowerings

Each kernel gets a boolean rendering with its OWN decision procedure — not one shared arithmetic
tactic. That is the point of a non-arithmetic tier: `lia`/`presburger`/`omega` are useless here,
so agreement between the kernels is not three invocations of the same idea.

| kernel | sort | tactic | refusal marker (already known to the classifier) |
|--------|------|--------|--------------------------------------------------|
| Rocq | `bool` | `destruct …; reflexivity` | `Unable to unify` |
| Isabelle/HOL | `bool` | `auto` (classical; `simp` is too weak — see below) | `Failed to finish proof` |
| Lean | `Bool` | `decide` | `decide` reports the proposition FALSE |

All three were validated against the real tools before any of this was wired up, including the
negative controls: a false boolean claim is REFUSED by each, with the marker above. -/

/-- Boolean operator spelling per kernel: `(and, or, not, eq)`. Rocq and Lean use the decidable
    `bool`/`Bool` operators; Isabelle's inner syntax is classical HOL but agrees on `bool`. -/
private structure BoolOps where
  and_ : String
  or_  : String
  not_ : String
  /-- TOP-LEVEL equivalence: the lemma's own `=`, at proposition level. -/
  eqv  : String
  /-- NESTED boolean equality, which is NOT the same thing. In Rocq `a = b` on `bool` is a
      `Prop`, so `negb (a = b)` is a type error — the emitted `xor` script failed exactly that
      way, while the `rfl` locks passed. Isabelle's HOL `=` on `bool` is already boolean, and
      Lean needs `==` because `=` yields a `Prop` there too. Three kernels, three answers to one
      question the renderer had been treating as uniform. -/
  eqNested : String → String → String

private def rocqBoolOps : BoolOps :=
  { and_ := "&&", or_ := "||", not_ := "negb", eqv := "="
  , eqNested := fun a b => s!"(eqb {a} {b})" }
private def isaBoolOps : BoolOps :=
  { and_ := "&", or_ := "|", not_ := "~", eqv := "="
  , eqNested := fun a b => s!"({a} = {b})" }
private def leanBoolOps : BoolOps :=
  { and_ := "&&", or_ := "||", not_ := "!", eqv := "="
  , eqNested := fun a b => s!"({a} == {b})" }

/-- Render a boolean expression with one kernel's spellings. `none` outside the fragment —
    an integer literal or a call has no boolean meaning here and must not be invented. -/
private def renderBool (ops : BoolOps) : Expr → Option String
  | .ident _ n => some n
  | .boolLit _ b => some (if b then "true" else "false")
  | .paren _ e => renderBool ops e
  | .unaryOp _ .not_ e => do let x ← renderBool ops e; some s!"({ops.not_} {x})"
  | .binOp _ .and_ l r => do
      let a ← renderBool ops l; let b ← renderBool ops r; some s!"({a} {ops.and_} {b})"
  | .binOp _ .or_ l r => do
      let a ← renderBool ops l; let b ← renderBool ops r; some s!"({a} {ops.or_} {b})"
  | .binOp _ .eq l r => do
      let a ← renderBool ops l; let b ← renderBool ops r; some (ops.eqNested a b)
  | .binOp _ .neq l r => do
      let a ← renderBool ops l; let b ← renderBool ops r
      some s!"({ops.not_} {ops.eqNested a b})"
  | _ => none

/-- The obligation as one kernel's proposition: `body = post`. -/
def BoolObl.prop (o : BoolObl) (ops : BoolOps) : Option String := do
  let l ← renderBool ops o.bodyExpr
  let r ← renderBool ops o.postExpr
  some s!"{l} {ops.eqv} {r}"

/-- Rocq script. `destruct` on every boolean variable then `reflexivity` — constructive, so
    `Print Assumptions` reports "Closed under the global context" rather than a classical axiom. -/
def BoolObl.rocqScript (o : BoolObl) : Option String := do
  let p ← o.prop rocqBoolOps
  let binder := if o.vars.isEmpty then "" else s!"forall ({" ".intercalate o.vars} : bool), "
  let dest := if o.vars.isEmpty then "" else s!"destruct {", ".intercalate o.vars}; "
  some <| "\n".intercalate
    [ "(* non-arithmetic multi-kernel: a BOOLEAN postcondition, closed by case analysis. *)"
    -- REQUIRED. `&&` and `||` live in `bool_scope`; without this the script fails with
    -- `Unknown interpretation for notation "_ || _"`. The `rfl` locks below pinned the
    -- rendering and passed while the emitted script did not compile at all -- caught only by
    -- running `coqc` on the generated output, which is why the gate does that rather than
    -- trusting the locks.
    -- `eqb` (boolean equality) comes from `Bool`; `&&`/`||` from `bool_scope`.
    , "From Stdlib Require Import Bool."
    , "Open Scope bool_scope."
    , s!"Lemma boolpost : {binder}{p}."
    , s!"Proof. {dest}reflexivity. Qed."
    , "Print Assumptions boolpost." ]

/-- Isabelle/HOL theory. HOL is classical, but the goal is over `bool` either way, so `simp`
    closes it without the lowering depending on classicality. -/
def BoolObl.isabelleTheory (o : BoolObl) (thyName : String) : Option String := do
  let p ← o.prop isaBoolOps
  let binder := if o.vars.isEmpty then "" else s!"ALL {" ".intercalate o.vars}::bool. "
  some <| "\n".intercalate
    [ s!"theory {thyName}", "imports Main", "begin"
    , s!"lemma boolpost: \"{binder}{p}\""
    -- `auto`, not `simp`. `simp` is pure rewriting and could not finish `xor`: it reduced the
    -- goal to a TRUE residual (`(a | b) & (a --> ~b)) = (a = ~b)`) and stopped. Propositional
    -- tautologies need classical reasoning, which is Isabelle's own answer to what Rocq does
    -- with `destruct` -- so each kernel still uses its native procedure, none of them
    -- arithmetic. Found by running the generated theory, not by reading it.
    , "  by auto", "end" ]

/-- Lean goal, closed by `decide` — which is exactly why the sort must be the decidable `Bool`. -/
def BoolObl.leanGoal (o : BoolObl) : Option String := do
  let p ← o.prop leanBoolOps
  let binder := if o.vars.isEmpty then "" else s!"∀ {" ".intercalate o.vars} : Bool, "
  some s!"{binder}{p}"

/-! ### Locks

The renderings are pinned here rather than only exercised end-to-end, so changing a spelling is a
build failure and not a silently different proposition sent to a kernel. -/

private def spB : Span := default
private def nandBody : Expr :=
  .binOp spB .or_ (.unaryOp spB .not_ (.ident spB "a")) (.unaryOp spB .not_ (.ident spB "b"))
private def nandPost : Expr :=
  .unaryOp spB .not_ (.binOp spB .and_ (.ident spB "a") (.ident spB "b"))
private def nandObl : BoolObl :=
  { fnQual := "d.nand", key := "d.nand#boolpost0", vars := ["a", "b"]
  , bodyExpr := nandBody, postExpr := nandPost }

-- De Morgan, in each kernel's spelling. These exact strings were run through `coqc`,
-- `isabelle build` and `lean` before being written down.
example : nandObl.prop rocqBoolOps = some "((negb a) || (negb b)) = (negb (a && b))" := rfl
example : nandObl.prop isaBoolOps  = some "((~ a) | (~ b)) = (~ (a & b))" := rfl
example : nandObl.leanGoal = some "∀ a b : Bool, ((! a) || (! b)) = (! (a && b))" := rfl

-- Rocq's proof is `destruct a, b; reflexivity` — constructive on `bool`. Over `Prop` this
-- direction of De Morgan needs classical logic, which is why the sort choice is not cosmetic.
-- Only renderability is pinned here: whether the SCRIPT is correct is settled by `coqc`
-- accepting it in the gate, not by a substring check that would pass on a malformed proof.
example : nandObl.rocqScript.isSome = true := rfl
example : (nandObl.isabelleTheory "BoolPost").isSome = true := rfl

-- EXHAUSTIVE agreement: De Morgan holds on all four assignments, decided rather than sampled.
example : nandObl.holdsEverywhere = some true := rfl
example : (allAssignments ["a", "b"]).length = 4 := rfl

-- And the check discriminates: `a || b` is NOT `!(a && b)`, so a wrong postcondition is caught
-- by the reference evaluator before any kernel is invoked.
private def badObl : BoolObl :=
  { nandObl with bodyExpr := .binOp spB .or_ (.ident spB "a") (.ident spB "b") }
example : badObl.holdsEverywhere = some false := rfl

-- Outside the fragment renders as `none` rather than being guessed at.
example : renderBool rocqBoolOps (.intLit spB 3) = none := rfl

end Report
end Concrete
