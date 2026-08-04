/-
# Obligation `Expr` → `TermIR.Term` (R-0455, slice 1c)

`TermIR` gave the pipeline a typed IR and a proved transformation. Nothing produced a `Term`
from a real obligation, which made Register B row 1 a true theorem about a transformation the
compiler never ran. This module is the missing producer.

It lives here rather than in `Concrete/Semantics/` because it depends on the surface AST, and
`TermIR` must not: a term language that imports the frontend cannot be the neutral middle of
a pipeline.

## What this measures, immediately

The string lowering (`exprToProver`) DROPS two things, and R-0455 names both:

* `div`/`mod` inside a larger expression — the operator table is infix-only, so a prefix form
  has nowhere to go. The divisor-nonzero *obligation* is unaffected; it is `a / b` appearing
  as a subterm that is lost.
* spec-function calls — there are no uninterpreted symbols to carry them.

`ofExpr` carries both. So the two functions disagree on exactly the obligations the string
layer loses, and `droppedByStringLayer` below turns that into a number rather than a claim in
a roadmap entry.
-/
import Concrete.Semantics.TermIR
import Concrete.Report.ReportObligations

namespace Concrete
namespace Report

open Concrete.TermIR

/-- Map a surface binary operator onto the IR's. `none` for operators outside the fragment,
    which is a REJECTION rather than an approximation — an operator silently mapped to a
    near-neighbour is the failure mode this whole IR exists to remove. -/
def irBinOp : BinOp → Option TermIR.Op
  | .add => some .add | .sub => some .sub | .mul => some .mul
  -- Carried, not dropped. This is the defect: `exprToProver` returns `none` here.
  | .div => some .tdiv | .mod => some .tmod
  | .leq => some .le | .lt => some .lt | .eq => some .eq
  | .and_ => some .and_ | .or_ => some .or_
  -- Deliberately absent, each for a reason rather than an omission:
  --   geq/gt   — representable by swapping operands, and a canonical form with one direction
  --              means a transformation has half as many cases to be sound for;
  --   neq      — `not (eq ..)`, same argument;
  --   bit ops  — the bv sort exists in the IR but no transformation targets it yet, and
  --              admitting terms no pass can handle would make `hasTmod`-style effect locks
  --              unprovable for them.
  | _ => none

mutual
  /-- Translate an obligation expression into the IR. Structural and total: every unhandled
      construct yields `none`, never a guess.

      A `call` becomes an UNINTERPRETED symbol. That is the point — the translation does not
      need to know what a spec function means, and a transformation must be sound for every
      interpretation of it (`TermIR.SymEnv` is quantified over in the row-1 theorems). -/
  def ofExpr : Expr → Option TermIR.Term
    | .intLit _ v => some (.lit v)
    | .boolLit _ b => some (.blit b)
    | .ident _ n => some (.var n)
    | .paren _ e => ofExpr e
    | .unaryOp _ .neg e => (ofExpr e).map (fun t => .bin .sub (.lit 0) t)
    | .unaryOp _ .not_ e => (ofExpr e).map (.un .not_)
    | .binOp _ op l r => do
      let o ← irBinOp op
      let a ← ofExpr l
      let b ← ofExpr r
      some (.bin o a b)
    | .call _ f _ args => (ofExprs args).map (.sym f)
    | _ => none

  def ofExprs : List Expr → Option (List TermIR.Term)
    | [] => some []
    | e :: es => do
      let t ← ofExpr e
      let ts ← ofExprs es
      some (t :: ts)
end

/-- Obligations whose expression the IR can carry but the STRING layer drops — the defect
    R-0455 describes, as a count.

    `exprToProver` returns `none` for a term containing `div`/`mod` or a call; `ofExpr` returns
    `some`. Every key here is an obligation the prover path silently loses today. Reported by
    `--report term-ir` so the number is observable instead of asserted. -/
def droppedByStringLayer (modules : List Module) : List (String × String) :=
  (multiKernelObligations modules (requireLeanGoal := false)).filterMap fun o =>
    match exprToProver rocqBinOp o.mainExpr, ofExpr o.mainExpr with
    | none, some _ => some (o.key, Concrete.fmtExpr o.mainExpr)
    | _, _ => none

/-- Obligations both layers carry. -/
def carriedByBoth (modules : List Module) : List String :=
  (multiKernelObligations modules (requireLeanGoal := false)).filterMap fun o =>
    match exprToProver rocqBinOp o.mainExpr, ofExpr o.mainExpr with
    | some _, some _ => some o.key
    | _, _ => none

/-- Obligations NEITHER layer carries — and the reason this is reported rather than left
    implicit.

    A `0 dropped` result is easy to read as "the string layer loses nothing". Measured on the
    corpus it means something narrower: the obligations that DO contain a division subterm
    (e.g. `arr[(a / b) as Int]`) also contain a `cast`, which neither layer models, so they are
    dropped by both and never counted as an IR win.

    `ofExpr` rejects casts deliberately. A cast changes value semantics — truncation — so
    carrying it as if transparent would be a silent misinterpretation, which is the failure
    this IR exists to remove. Modelling casts is future work; pretending they are identity
    would be worse than dropping them.

    So the IR's advantage on div/mod is **latent on this corpus, not live**. Reporting all
    three buckets is what makes that visible instead of hidden behind a zero. -/
def droppedByBoth (modules : List Module) : List String :=
  (multiKernelObligations modules (requireLeanGoal := false)).filterMap fun o =>
    match exprToProver rocqBinOp o.mainExpr, ofExpr o.mainExpr with
    | none, none => some o.key
    | _, _ => none

/-! ### Behavioural locks

`ofExpr` handles what the string layer drops. Pinned by `rfl` rather than asserted in a gate,
so weakening the translation is a build failure. -/

private def sp : Span := default

-- `a / b` as a SUBTERM: dropped by the string layer, carried here. The obligation this
-- appears in is exactly the case R-0455 names.
example : ofExpr (.binOp sp .lt (.binOp sp .div (.ident sp "a") (.ident sp "b")) (.intLit sp 10))
        = some (.bin .lt (.bin .tdiv (.var "a") (.var "b")) (.lit 10)) := rfl
-- The counterpart — that `exprToProver` returns `none` here — CANNOT be an `rfl` example:
-- `exprToProver` is a `partial def`, so the kernel cannot reduce it. That is the same
-- limitation that makes `evalIntEnv` unprovable and is a large part of R-0455's motivation,
-- encountered here while trying to write the lock for it. The drop is therefore measured at
-- runtime by `droppedByStringLayer` and asserted by `check_transform_register.sh` as a COUNT,
-- which is a stronger claim than a hand-written example anyway.

-- A spec-function call becomes an uninterpreted symbol rather than being dropped.
example : ofExpr (.call sp "f" [] [.ident sp "x"]) = some (.sym "f" [.var "x"]) := rfl

-- Unary negation is normalised to `0 - x`, so the IR needs no unary-minus operator and every
-- transformation has one fewer case to be sound for.
example : ofExpr (.unaryOp sp .neg (.ident sp "x")) = some (.bin .sub (.lit 0) (.var "x")) := rfl

-- Out-of-fragment operators are REJECTED, not approximated. `geq` is representable by
-- swapping operands; admitting it as `le` with the arguments in the wrong order is the
-- silent-misinterpretation failure the IR exists to prevent.
example : irBinOp .geq = none := rfl
example : irBinOp .bitand = none := rfl

-- And the translation composes with row 1: a carried `mod` subterm is then eliminated.
example : (ofExpr (.binOp sp .lt (.binOp sp .mod (.ident sp "a") (.ident sp "b"))
              (.intLit sp 10))).map TermIR.hasTmod = some true := rfl
example : (ofExpr (.binOp sp .lt (.binOp sp .mod (.ident sp "a") (.ident sp "b"))
              (.intLit sp 10))).map (TermIR.hasTmod ∘ TermIR.elimTmod) = some false := rfl

end Report
end Concrete
