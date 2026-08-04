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
