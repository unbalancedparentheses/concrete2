/-
# Obligation DISCOVERY completeness (R-0455, slice 2)

Every soundness argument in this repo so far starts *after* an obligation exists: Register A
asks whether an obligation is sufficient, Register B whether a transformation preserves it,
Register C whether the evidence composes. All three are silent on the prior question —

  **does the compiler generate an obligation at all?**

A missed shift is not a failed proof. It is no proof request, no unproven marker, and a green
report. That is the worst failure mode this pipeline has, because it is invisible by
construction: nothing downstream can notice an obligation that was never created.

## Why this could not be stated before

`collectShiftsE` was a `partial def`. A `partial def` is opaque to the kernel, so *no* theorem
could mention its behaviour — the completeness question was not hard to answer, it was
unaskable. Removing `partial` (the walker recurses under `List.flatMap`, so it needs
`attach` + a `decreasing_by`, not merely the keyword deleted) is what makes the statement
expressible.

Note what that buys and what it does not. Unlike the seven functions that recovered
*structural* recursion, a well-founded definition does **not** reduce by `rfl` — the kernel
will not unfold `WellFounded.fix`. What it gains is equation lemmas and a recursion
principle, i.e. it becomes reasoning-accessible. That is enough for a theorem and not enough
for a `decide`; both facts are load-bearing below.
-/
import Concrete.Report.ReportObligations

namespace Concrete
namespace Report

/-- Syntactic "this expression contains a shift", over the arithmetic fragment.

    Deliberately NOT a mirror of `collectShiftsE`'s traversal — see the boundary examples
    below. It covers binary/unary operators, parens and casts. -/
def hasShift : Expr → Bool
  | .binOp _ .shl _ _ => true
  | .binOp _ .shr _ _ => true
  | .binOp _ _ l r => hasShift l || hasShift r
  | .unaryOp _ _ x | .paren _ x | .cast _ x _ => hasShift x
  | _ => false

/-- **Discovery is complete on the arithmetic fragment**: if a shift is present, the walker
    that feeds shift-amount obligation generation returns a non-empty result.

    Contrapositive — the form that matters: an empty `collectShiftsE` means there was no shift
    to find, not that the walker overlooked one. Shift-amount obligations cannot go missing on
    this fragment. -/
theorem collectShiftsE_complete : ∀ e : Expr, hasShift e = true → collectShiftsE e ≠ []
  | .binOp _ op l r, h => by
      cases op <;>
        first
          | (simp [collectShiftsE]; done)
          | (simp [hasShift] at h
             simp only [collectShiftsE, ne_eq, List.append_eq_nil_iff, not_and]
             intro hl
             rcases h with h' | h'
             · exact absurd hl (collectShiftsE_complete l h')
             · exact collectShiftsE_complete r h')
  | .unaryOp _ _ x, h | .paren _ x, h | .cast _ x _, h => by
      simp only [hasShift] at h; simpa [collectShiftsE] using collectShiftsE_complete x h
  | .ident .., h | .intLit .., h | .boolLit .., h => by simp [hasShift] at h
termination_by e => sizeOf e

/-! ### The boundary, stated rather than left to be discovered

`hasShift` is FALSE for a shift nested inside a call argument, an array index or a struct
literal. `collectShiftsE` does traverse those. So the theorem above is not wrong there — its
hypothesis is simply never met, and it claims nothing.

This is the failure mode of a completeness theorem with a weak antecedent: `∀ e, P e → Q e` is
vacuously strong when `P` is narrow, and reads like global completeness to anyone who checks
the theorem name and not the predicate. Both facts are pinned so the gap is visible in the
build rather than inferred from the definition. -/

private def spD : Span := default

-- A shift inside a call argument: the walker FINDS it...
example : collectShiftsE (.call spD "f" [] [.binOp spD .shl (.ident spD "x") (.intLit spD 3)])
        ≠ [] := by simp [collectShiftsE]
-- ...but `hasShift` does not see it, so the theorem above says nothing about this case.
example : hasShift (.call spD "f" [] [.binOp spD .shl (.ident spD "x") (.intLit spD 3)])
        = false := by simp [hasShift]

-- Non-vacuity: the antecedent IS satisfiable, so the theorem is not empty.
example : hasShift (.binOp spD .add (.ident spD "a")
            (.binOp spD .shl (.ident spD "x") (.intLit spD 3))) = true := by simp [hasShift]

-- And the walker is not trivially non-empty: a shift-free expression yields nothing, so
-- `≠ []` is a real discrimination rather than a property of every input.
example : collectShiftsE (.binOp spD .add (.ident spD "a") (.intLit spD 1)) = [] := by
  simp [collectShiftsE]

end Report
end Concrete
