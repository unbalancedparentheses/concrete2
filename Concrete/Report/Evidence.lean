namespace Concrete
namespace Report

/-! # The evidence algebra — Register C

Every claim this compiler makes is *conditional on something*: the facts assumed at a
program point, the rules that produced the obligation, the boundaries declared trusted.
Before this module those conditions lived nowhere. `status` was a `String` assembled
independently at each surface, so a status could be — and was — stronger than the things
it rested on.

That is not hypothetical. **H23**: an array-bounds obligation assumed a loop invariant
whose preservation VC read `unproven` in the same report, and reported
`proved_by_multi_kernel (3: lean, rocq, isabelle)`. The compiled binary aborted on the
access. Three kernels across two logics agreed, because all three were handed the same
unestablished hypothesis. See `examples/unsound_hypothesis/`.

## Why a representation rather than a check

A check for "did we remember to consult the hypotheses?" is another surface that can be
weaker than the property it guards — the failure this codebase keeps finding. So the fix
is representational: an `Evidence` value carries its assumption set, and the only
combining operation takes the UNION. Losing an assumption then requires *removing* an
element, which is a visible act; H23 was an *omission*, and this shape has no omission
that loses information.

This is the de Bruijn discipline the project already applies to other people's proofs and
not to its own: the emitted Rocq scripts run `Print Assumptions`, `docs/AXIOMS.md` tracks
and gates Lean's axiom set. A theorem carries its axioms and "proved" means the axiom set
is empty. `Evidence` applies exactly that to Concrete's own claims.

## Register C

Registers A (obligation sufficiency) and B (transformation soundness) are about program
semantics and are years of work. Register C is about *this data structure*, so its rows
are dischargeable now — and they are, below, as compile-time theorems rather than tests.
A green build is the proof.

  C1  combining evidence unions the assumption sets — nothing is dropped
  C2  a combination is proved IFF every part is proved
  C3  a claim with a non-empty assumption set NEVER presents as a proof class
  C4  discharge is the only operation that shrinks an assumption set

C3 is H23 stated as a theorem.

## What this does NOT do

It does not decide whether an obligation is *sufficient* (Register A) or whether a
transformation is *sound* (Register B). It guarantees only that evidence is never
reported as stronger than its inputs. That is a smaller claim than it sounds and the
only one reachable cheaply — but H23 was a violation of exactly it. -/

/-- A reference to the obligation that would discharge an assumption: a VC id such as
    `lam.bad@6#O2`. Kept as a plain id so the assumption set is comparable and
    serializable; the referenced VC's own status is looked up when rendering. -/
abbrev ObligationRef := String

/-- Where a hypothesis came from. The four sources have genuinely different
    justification status, and erasing that distinction is what made H23 possible.

    `guard` and `statement` are *self-justifying* and carry no assumption:

    * `guard` — a control-flow condition. Sound by construction: the branch was taken.
    * `statement` — a `#[requires]`. This is NOT debt. It belongs to what the claim
      SAYS ("for all inputs satisfying P, …"), and every call site carries its own
      separate obligation to establish P. Treating it as debt would make every function
      conditional on all its callers, transitively, and destroy modular verification.

    The other two are debt and MUST carry a `justifiedBy` reference:

    * `invariant` — a loop `#[invariant]`. Internal to the function, so nothing external
      discharges it; it owes its own O1 (init) and O2 (preservation).
    * `assumed` — an explicit `#[assume]`. Owes nothing and can never be discharged, so
      it permanently caps the claim. -/
inductive HypOrigin where
  | guard
  | statement
  | invariant (justifiedBy : ObligationRef)
  | assumed   (name : String)
  deriving Repr, DecidableEq, Inhabited

/-- The assumption a hypothesis contributes, if any. Self-justifying origins contribute
    nothing; debt origins contribute the reference that would retire them.

    This function is the whole hypothesis policy in one place. Adding an origin without
    deciding its debt is a missing-case error, not a silent `none`. -/
def HypOrigin.debt : HypOrigin → Option ObligationRef
  | .guard         => none
  | .statement     => none
  | .invariant ref => some ref
  | .assumed name  => some s!"assume:{name}"

/-- A hypothesis with its provenance. The bare `Expr` this replaces could not be asked
    what justified it, which is why nothing composed. -/
structure Hypothesis where
  prop   : String
  origin : HypOrigin
  deriving Repr, Inhabited

/-- Evidence for one claim: what established it, what it rests on, and who attested.

    `assumes` is the load-bearing field. `cls` is a label, not an ordering — per R-0440
    evidence is multidimensional and this module deliberately does NOT impose a ladder on
    classes. The only ordering asserted anywhere here is on assumption sets, by inclusion. -/
structure Evidence where
  /-- The evidence class as recorded (`proved_by_lean`, `solver_checked`, …). A label
      over the other fields; never the source of truth for whether something is proved. -/
  cls          : String
  /-- Obligation references this claim rests on. EMPTY is the definition of proved. -/
  assumes      : List ObligationRef := []
  /-- Per-kernel receipts. Orthogonal to `assumes`: a claim can be attested by three
      kernels and still rest on an unestablished invariant. That is precisely H23. -/
  attestations : List String := []
  deriving Repr, Inhabited

namespace Evidence

/-- Proved means the assumption set is empty. This is a definition, not a check. -/
def isProved (e : Evidence) : Bool := e.assumes.isEmpty

/-- Evidence resting on nothing. -/
def proved (cls : String) (attestations : List String := []) : Evidence :=
  { cls, assumes := [], attestations }

/-- Attach an assumption. The only way to introduce debt. -/
def assuming (e : Evidence) (ref : ObligationRef) : Evidence :=
  { e with assumes := e.assumes ++ [ref] }

/-- Combine two pieces of evidence: the assumption sets UNION.

    Union rather than intersection or replacement is the entire point. There is no
    argument order and no branch in which an assumption is dropped, so the C1/C2
    theorems below are immediate — which is the design working, not the proofs being
    weak. -/
def combine (a b : Evidence) : Evidence :=
  { cls          := a.cls
  , assumes      := a.assumes ++ b.assumes
  , attestations := a.attestations ++ b.attestations }

/-- Fold a claim together with every hypothesis it was discharged under. This is the
    operation whose absence was H23. -/
def underHypotheses (e : Evidence) (hyps : List Hypothesis) : Evidence :=
  { e with assumes := e.assumes ++ hyps.filterMap (·.origin.debt) }

/-- Retire assumptions whose discharging obligations are now proved. The ONLY operation
    that removes an element from an assumption set. -/
def discharge (e : Evidence) (dischargedRefs : List ObligationRef) : Evidence :=
  { e with assumes := e.assumes.filter (fun r => !dischargedRefs.contains r) }

/-- The status string every surface must render from — report, ledger, JSON artifact and
    policy gate alike, so none of them can know something another does not.

    A claim with outstanding assumptions presents as `assumed`, never as a `proved_*`
    class. `assumed` is deliberate reuse rather than a new conditional badge: it is
    already in the status vocabulary, already what `#[assume]` produces, and already
    gate-forbiddable through `ProjectPolicy.forbidAssume` — so capping here makes H23
    catchable by enforcement that already exists. A conditional badge still containing
    the substring `proved` would reproduce H23 for every consumer that pattern-matches
    the status, which is exactly how H23 passed the policy gate. -/
def present (e : Evidence) : String :=
  if e.assumes.isEmpty then e.cls else "assumed"

/-- The outstanding conditions, for the structured `conditions` field. Rendering surfaces
    show these next to `assumed` so the reader learns WHICH obligation is missing —
    "proved except for invariant@6" is real evidence, and collapsing it to `unproven`
    would throw away the fact that exactly one VC remains. -/
def conditions (e : Evidence) : List ObligationRef := e.assumes.eraseDups

/-! ## Register C — discharged rows

Compile-time theorems, placed here rather than in a test because a green build must be
the proof. `scripts/tests/check_evidence_algebra.sh` asserts they are still present, so
deleting one is a red gate rather than a silent loss of the guarantee. -/

/-- **C1 — combining never drops an assumption.** The safety direction of the union. -/
theorem c1_combine_keeps_left (a b : Evidence) :
    ∀ r ∈ a.assumes, r ∈ (a.combine b).assumes := by
  intro r hr; simp [combine, List.mem_append]; exact Or.inl hr

theorem c1_combine_keeps_right (a b : Evidence) :
    ∀ r ∈ b.assumes, r ∈ (a.combine b).assumes := by
  intro r hr; simp [combine, List.mem_append]; exact Or.inr hr

/-- **C2 — a combination is proved IFF every part is proved.**

    This is the H23 invariant in its positive form: you cannot assemble a proved claim
    out of parts that are not all proved. -/
theorem c2_combine_proved (a b : Evidence) :
    (a.combine b).isProved = (a.isProved && b.isProved) := by
  cases ha : a.assumes <;> simp [combine, isProved, ha]

/-- **C2' — the same for a claim folded together with its hypotheses.** An obligation
    discharged under an unjustified hypothesis is not proved, whatever its own proof did.
    This is the exact statement H23 violated. -/
theorem c2_under_hypotheses_proved (e : Evidence) (hyps : List Hypothesis) :
    (e.underHypotheses hyps).isProved
      = (e.isProved && (hyps.filterMap (·.origin.debt)).isEmpty) := by
  cases he : e.assumes <;> simp [underHypotheses, isProved, he]

/-- **C3 — a claim with outstanding assumptions presents as exactly `assumed`.**

    H23 as a theorem. It cannot present as any `proved_*` class because it presents as a
    single fixed literal — and that literal is proved to be outside `proofClasses` by a
    companion `example` next to the discharge-adapter firewall in `Report.lean`, which is
    where that list lives. The two together are the full statement: capped claims land on
    a status the evidence-class firewall already forbids untrusted backends from
    emitting. -/
theorem c3_caps_to_assumed (e : Evidence) (h : e.assumes ≠ []) :
    e.present = "assumed" := by
  cases he : e.assumes with
  | nil => exact absurd he h
  | cons _ _ => simp [present, he]

/-- **C3' — the converse, so C3 is not vacuous.** With nothing outstanding the class is
    reported unchanged; the cap costs nothing when there is no debt. -/
theorem c3_present_unchanged_when_proved (e : Evidence) (h : e.assumes = []) :
    e.present = e.cls := by
  simp [present, h]

/-- **C4 — discharge only ever shrinks an assumption set.** No path adds debt while
    claiming to remove it. -/
theorem c4_discharge_shrinks (e : Evidence) (refs : List ObligationRef) :
    ∀ r ∈ (e.discharge refs).assumes, r ∈ e.assumes := by
  intro r hr; simp [discharge, List.mem_filter] at hr; exact hr.1

/-- Self-justifying hypotheses contribute no debt at all. Proved member-wise: `filterMap`
    yields `[]` exactly when every element maps to `none`, and both self-justifying
    origins do by definition of `debt`. -/
theorem selfJustifying_no_debt (hs : List Hypothesis)
    (h : ∀ hy ∈ hs, hy.origin = .guard ∨ hy.origin = .statement) :
    hs.filterMap (·.origin.debt) = [] := by
  simp only [List.filterMap_eq_nil_iff]
  intro a ha
  cases h a ha with
  | inl hg  => simp [hg, HypOrigin.debt]
  | inr hst => simp [hst, HypOrigin.debt]

/-- **C5 — guards and `#[requires]` never cap a claim.** This is the modularity
    guarantee, and it is as load-bearing as C3 in the other direction: if a `#[requires]`
    counted as debt, every function would become conditional on all of its callers,
    transitively, and modular verification would collapse. A precondition belongs to what
    the claim SAYS, not to what it owes. -/
theorem c5_self_justifying_free (e : Evidence) (hyps : List Hypothesis)
    (h : ∀ hy ∈ hyps, hy.origin = .guard ∨ hy.origin = .statement) :
    (e.underHypotheses hyps).assumes = e.assumes := by
  simp [underHypotheses, selfJustifying_no_debt hyps h]

end Evidence

/-! ## Shared derivation for multi-kernel evidence

ONE function, so the multi-kernel report and the ledger fold cannot disagree about the
same obligation. They previously computed the class independently, which is how
`kernel_disagreement` came to exist in the report and not in the stored artifact. -/

/-- A kernel's verdict on one obligation, as the report's three-valued cell already
    distinguishes them. `refused` is the kernel saying no; the absences are not verdicts
    and must never be read as dissent. -/
inductive KernelCell where
  | closed
  | refused
  | absent   -- off / unavailable / not-asked / error: no verdict was given
  deriving Repr, DecidableEq, Inhabited

/-- One kernel's contribution to an obligation.

    `name` is the identity recorded in the badge (`rocq`); `label` is the display form
    used in diagnostics (`rocq:lia`). Both are needed: the badge string is consumed by
    gates and must stay stable, while a disagreement message should name the tactic. -/
structure KernelInput where
  name           : String
  label          : String
  cell           : KernelCell
  loweringAgreed : Bool
  deriving Repr, Inhabited

/-- Everything both the report and the ledger fold need about one obligation, derived
    ONCE. They previously computed this independently, which is exactly how
    `kernel_disagreement` came to exist in the report and not in the stored artifact. -/
structure MultiKernelVerdict where
  /-- `evidence.cls` is the CANONICAL class — a bare vocabulary word, no parenthetical.
      This is what the ledger stores, so it stays checkable against
      `ObligationCore.statusVocabulary`. -/
  evidence : Evidence
  /-- The human form, e.g. `proved_by_two_kernels (lean, rocq)`. Display only, per
      R-0440: a friendly composite label may not erase the underlying dimensions, so the
      dimensions live in `attest`/`dissent`/receipts and this string is never stored as
      the status. -/
  display  : String
  /-- Kernels that dissent from Lean on the same proposition, as display strings. -/
  dissent  : List String
  /-- Kernels whose closure counts toward the badge, `lean` included. -/
  attest   : List String
  deriving Repr, Inhabited

/-- The status a human-facing surface should print: the rich display form, unless
    outstanding assumptions cap it — in which case C3 applies and it is `assumed`. -/
def MultiKernelVerdict.displayStatus (v : MultiKernelVerdict) : String :=
  if v.evidence.assumes.isEmpty then v.display else v.evidence.present

/-- Derive the multi-kernel verdict for one obligation.

    `loweringAgreed = false` excludes a kernel entirely: it closed or refused a DIFFERENT
    proposition, so its verdict is not evidence about this one.

    A verdict disagreement — kernels rendering the same proposition returning opposite
    verdicts — is neither a badge nor `unproven`. Every kernel here is complete for
    linear integer arithmetic, so a disagreement is a defect report, most likely about
    our own driver for the dissenting kernel.

    Note `assumes := []` throughout: this layer knows nothing about the hypotheses the
    obligation was discharged under. R-0461 supplies them via `underHypotheses`, and by
    C2′ the resulting claim is proved only if those are discharged too. Kernel count
    never overrides that — which is the H23 lesson expressed in the type. -/
def multiKernelVerdict (leanClosed : Bool) (externals : List KernelInput)
    : MultiKernelVerdict :=
  let usable := externals.filter (·.loweringAgreed)
  let dissent := usable.filterMap (fun k =>
    if k.cell == .closed && !leanClosed then some s!"{k.label} closed while lean refused"
    else if k.cell == .refused && leanClosed then some s!"{k.label} refused while lean closed"
    else none)
  let attest := (if leanClosed then ["lean"] else [])
    ++ usable.filterMap (fun k => if k.cell == .closed then some k.name else none)
  -- Canonical class for the record, and the display form for humans, derived together
  -- so they cannot drift. Only the canonical one is ever stored as a status.
  let (cls, display) :=
    if !dissent.isEmpty then
      ("kernel_disagreement", s!"kernel_disagreement ({"; ".intercalate dissent})")
    else if attest.length ≥ 3 then
      ("proved_by_multi_kernel", s!"proved_by_multi_kernel ({attest.length}: {", ".intercalate attest})")
    else if attest.length == 2 then
      ("proved_by_two_kernels", s!"proved_by_two_kernels ({", ".intercalate attest})")
    else if attest.length == 1 then
      (s!"proved_by_{attest.head!}", s!"proved_by_{attest.head!}")
    else ("unproven", "unproven")
  { evidence := { cls, assumes := [], attestations := attest }, display, dissent, attest }

end Report
end Concrete
