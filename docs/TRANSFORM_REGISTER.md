# Register B — transformation soundness

**Scope: `obligation → transformed goal`.** Every row here owes one sentence, as a
kernel-checked theorem:

> the transformed goal implies the input goal

Why3, whose pipeline shape this adopts, does **not** prove its transformations — they are
trusted. That difference is why this is a register and not a refactor.

## What this register deliberately excludes

Print fidelity. Proving "this printer emits syntax denoting the same proposition" requires a
formal semantics of the **target** syntax, and there is none for SMT-LIB or Coq's parser that
is ours. Formalising them means trusting that our formalisation matches the real parser — the
same trust relocated, not removed.

| step | ours? | status |
|---|---|---|
| obligation → transformed goal | both sides | **provable** — this register |
| transformed goal → target text | target is not | validated, plausibly forever |

That inverts how to treat print validation: it is not a temporary embarrassment to be proved
away, it is a permanent cost whose only lever is having ONE printer instead of N.

## Status

Rows discharged: **1 of 3**. The IR is `Concrete/Semantics/TermIR.lean`.

Difficulty across rows is **skewed by orders of magnitude**, and recording that is part of
the register's job — a flat row list would imply the remaining two are more of the same.

---

### Row 1 — `eliminate_tmod` — **DISCHARGED 2026-08-04**

| | |
|---|---|
| **Transformation** | Rewrite every `a tmod b` into `a - b * (a tdiv b)`. |
| **Why** | A target with quotient but no remainder currently **loses the subterm**. R-0455: "a driver states what a target cannot express so the pipeline transforms instead of silently dropping." This shrinks the operator set a driver must support by one. |
| **Theorem** | `TermIR.evalInt_elimTmod` / `evalBool_elimTmod` (meaning preservation) and `TermIR.elimTmod_sound` (the register's sentence: transformed entails input). |
| **Rests on** | `Int.mul_tdiv_add_tmod` from core Lean, plus the divisor-nonzero guard both sides share. |
| **Quantified over** | An arbitrary `SymEnv`. The transformation knows nothing about spec functions, so it must hold whatever they mean — that is what "uninterpreted" has to mean for this to be honest. |
| **Non-vacuity** | Pinned separately: `hasTmod (elimTmod t) = false` on nested, `sym`-wrapped and arithmetic-embedded occurrences. A meaning-preserving **no-op** would satisfy the soundness theorem while transforming nothing, which is the vacuity failure this project keeps finding. |

### Row 2 — `eliminate_div_mod` (fresh-variable form) — **OPEN**

Replace `a tdiv b` by a fresh variable `q` constrained by `q*b + r = a` and `|r| < |b|`.

Two concrete blockers, both worth stating because neither is "more of row 1":

1. **Needs decidable equality on `Term`.** Lean cannot derive it through the nested
   `List Term` in `sym`; it must be hand-written mutually. A first attempt compared terms by
   their `repr` **strings** — the same category of error as validating a rendering by reading
   it back, and it is recorded here so it is not retried.
2. **The real content is the magnitude constraint** `|r| < |b|`, which needs `Int.natAbs`
   reasoning. This repo has **no Mathlib**, so that is a hand proof rather than a lemma call.

Note what row 1 does *not* buy: the identity `q*b + r = a` alone, with `r` defined as
`a - q*b`, is true for **any** `q`. It constrains nothing. The magnitude bound is what pins
`q` to be the quotient, so a row that added only the identity would be sound and useless.

### Row 3 — `eliminate_algebraic` — **OPEN, and different in kind**

Axiomatize datatypes for a target without them. R-0455 flags this explicitly: the row
requires the axiomatization be **conservative over the datatype theory**, which is
model-theoretic rather than a rewriting argument. It is not a longer version of rows 1–2.

Measured constraint on the same tier (2026-07-31): SMT datatype reasoning is provable but
**not Alethe-certifiable**, which is why the non-arithmetic tier stays kernel-proved.

---

## The IR is on the production path (`Expr → Term`), and what measuring it showed

`Concrete/Report/TermOfExpr.lean` translates obligation expressions into the IR, so Register B
row 1 is a theorem about a transformation real obligations can now enter. `--report term-ir`
reports three buckets.

**Casts are modelled** (2026-08-04), as a wrap at the target width matching the reference
(`Interp.evalCast` → `IntArith.wrapToType`) — **not** as identity. A cast truncates, so
treating it as transparent would make the IR denote a different value than the program
computes, which is the silent misinterpretation this IR exists to remove. Unknown-width
targets (`Int`/`Uint`, whose overflow is profile-dependent) are still rejected rather than
given a guessed width.

That was the unblocking step. Before it, R-0455's headline defect could not be demonstrated
at all: every obligation carrying a division subterm also carried a cast
(`arr[(a / b) as Int]`), so it was dropped by BOTH layers and the IR recovered nothing.
With casts carried, the IR recovers it.

**Measured honestly across `examples/`: the IR recovers 0.** Not because cast support is
broken — because the corpus contains no obligation with a division inside a cast. The
capability is exercised by a constructed fixture in `check_transform_register.sh`, which is
the difference between "recovers 0 because there is nothing to recover" and "recovers 0
because it regressed". The report says so in those terms, so a zero cannot be read as either
over- or under-claiming.

One remaining `dropped by both` in the corpus, in `fixed_capacity` — outside the IR's
fragment for a different reason, not yet classified.

Two things this also established, both by trying and failing:

- **`exprToProver` CAN be locked by `rfl`** — after removing a `partial` keyword it never
  needed. This bullet previously said the opposite, which was true of the code and false
  about the code's necessity: seven functions in the report layer (including `exprToSmt`,
  both prover lowerings and the bv renderer) recurse only on direct subterms and were marked
  `partial` by habit. The drop the IR repairs is now a compile-time lock, not just a runtime
  count. A provable printer still does not make print fidelity provable — the target syntax
  is not ours — but the printer's own behaviour no longer sits outside the kernel.
- **`hasTmod ∘ elimTmod` composes with the translation**, pinned by `rfl`: a real obligation
  expression carrying `mod` is translated and then eliminated.

## Obligation DISCOVERY, the question the three registers never asked

Registers A, B and C all begin *after* an obligation exists. None of them can observe an
obligation that was **never generated** — a missed shift produces no failed proof and no
`unproven` marker, just a green report. It is the pipeline's worst failure mode precisely
because nothing downstream is capable of noticing it.

`collectShiftsE_complete` (`Concrete/Report/DiscoveryComplete.lean`) is the first statement
about that prior question: if a shift is present in the arithmetic fragment, the walker that
feeds shift-amount obligation generation finds it. Contrapositive: an empty result means
there was nothing to find, not that the walker looked past it.

Three qualifications, all load-bearing:

- **It exists only because the walker stopped being `partial`.** Unlike the seven functions
  above, `collectShiftsE` recurses under `List.flatMap`, so deleting the keyword is not
  enough — it needs `attach` plus a `decreasing_by` discharging a list-membership size bound.
- **Well-founded ≠ kernel-reducible.** A WF definition does *not* reduce by `rfl`; the kernel
  will not unfold `WellFounded.fix`. It gains equation lemmas and a recursion principle, so it
  becomes reasoning-accessible — enough for a theorem, not enough for `decide`. This was
  checked by trying `rfl` and watching it fail, not assumed.
- **The antecedent is narrow, and that is pinned.** `hasShift` is false for a shift nested in
  a call argument, which the walker *does* traverse. A completeness theorem is only as strong
  as its predicate, and `∀ e, P e → Q e` reads like global completeness to anyone who checks
  the theorem's name instead of `P`. The gap is a build-enforced example rather than a remark.

**All four families now have one** (`collectDivisorsE`, `collectIndexUsesE`, `collectArithE`
followed; each sat in a `mutual` block, where `partial` is all-or-nothing, so the whole block
had to be totalised before any of them could be discussed). Of the report layer's 17
`partial def`s, 6 remain — none on the discovery path.

### The bug this found

Writing `hasIndex` meant answering "which array expressions does bounds discovery actually
RECORD?", and the answer was: a bare `.ident`. So `(a)[i]` generated **no array-bounds
obligation at all** — not an unproven VC, not a warning, absent from `--report vcs` entirely,
while the semantically identical `a[i]` produced one. Confirmed on a real program before being
believed, then fixed by rooting the access through `arrayRootName`.

Three things worth recording about it:

- **The corpus never covered it.** The full suite stayed at 1702/0 before and after the fix.
  A `rfl` lock could not have caught what no fixture exercised, so the regression check is
  end-to-end (compile a program, count `array_bounds` VCs) and lives in the gate.
- **Memory safety was never at risk.** Codegen emits `__cc_bounds_check` at every access
  regardless. What was missing is the PROOF — and, until now, any indication it was missing.
  A release gate demanding all VCs proved would have passed this program by having nothing
  to fail.
- **`b.data[i]` is still not recorded, deliberately.** The length lookup is keyed by variable
  NAME (`varTyMap`), so a field path has no name to resolve. Peeling `.fieldAccess` the way
  `.paren` is peeled would produce an obligation about the WRONG array; a wrong obligation is
  merely louder than a missing one, not safer. Closing it needs type resolution for arbitrary
  array expressions, which is a real change and is now a named gap rather than a silent one.

That is the argument for discovery completeness in one example: the defect was not a failed
proof or a bad translation, and no register could see it. It was a question nobody had asked.

## Drivers as data (R-0455, same slice)

`tactics` is now a **field** on `ProverLowering`, ordered for cheap-then-expensive attempts.
Measured cost of it having been a template literal: `rocqNiaLowering` was a full clone of
`rocqLowering` whose only substantive difference was the word `lia` becoming `nia`. Reaching
a different tactic cost an entire driver that then had to be kept in step with its twin.

It is now a two-field override, and both Rocq drivers share one `rocqScript` builder. Inline
`render` literals: **5 → 3**, ratcheted by the gate.

**One thing this refactor got wrong, recorded because the failure mode is invisible.**
Collapsing the clone dropped `batchRender` from `rocqLowering`. That does not fail the build
and does not stop `coqc` closing the proof — `batchRender` builds the *agreement* script (N
pinned instances of one obligation), which is a different shape from `render`. Losing it left
the agreement check with nothing to check, so every Rocq cell read `LOWERING DISAGREES` and
the badge silently vanished: 78/78 became three failures with `rocq:lia = closed` sitting
beside a refused attestation. The gate now asserts each driver keeps it, mutation-verified.

Isabelle's scripts are deliberately **not** yet derived from a shared builder: its batch form
(one theory, N indexed lemmas) differs structurally from its single form, and collapsing them
without changing emitted output needs that split handled first.

## Gate

`scripts/tests/check_transform_register.sh` asserts every discharged row names a theorem that
exists, that no row uses `sorry`/`admit`/`native_decide`, that the non-vacuity locks survive,
and that the discharged count matches the rows — in both directions, so the register cannot
understate the compiler either.
