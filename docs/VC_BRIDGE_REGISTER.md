# VC Bridge Register — the Core→obligation lowering, rule by rule

Status: contract document (per-rule register; the VC-side counterpart of
[PROOF_OBLIGATIONS_REGISTER.md](PROOF_OBLIGATIONS_REGISTER.md)).

## Why this exists

`PROOF_OBLIGATIONS_REGISTER.md` inventories the **ProofCore/PExpr** extraction
surface: every trusted link, what it assumes, what it rejects, and the theorem that
will eventually justify it. That discipline is why the `concrete prove` bridge is
auditable rather than merely working.

The **other** bridge had no such register. `Core → obligation` — the lowering that
turns a function body into propositions like `a + b ∈ [-2³¹, 2³¹-1]` — is the bridge
every runtime-safety claim rests on, including every `proved_by_two_kernels` badge.
Multi-kernel agreement cannot detect a fault in it: all kernels check *the same*
lowered proposition, so a mis-lowering produces unanimous agreement on the wrong
formula. `--report multi-kernel` says so, and `independent_of.bridge` records it
structurally as `"no"`.

This register is the path from that disclaimer to evidence. Each row names a lowering
rule, what it emits, what it assumes, what it refuses, the example that forced it, and
the theorem that will discharge it. A discharged row permanently strengthens every
badge that depends on it. Until then the row is an honest, enumerated IOU rather than
an open-ended aspiration.

**Gated.** `scripts/tests/check_vc_bridge_register.sh` fails if a family generator
exists in `Concrete/Report/ReportObligations.lean` without a row here. A new
obligation family cannot ship undocumented.

**Owned by R-0460**, which discharges these rows one at a time. Not R-0449: realization
proves a *target prover's* theories sound in its own model, which is a different axis and
cannot close a row here. Not R-0455 either — that register asserts *transformed goal
implies input goal*, while every row here asserts *flat goal implies runtime property*.

**Why this register outranks another kernel.** Across the multi-kernel arc, agreement
between kernels surfaced zero real defects; every disagreement seen was injected by a
mutation test. The one real fault found — `Z.div` vs `Z.quot` disagreeing at `(-7)/2`,
recorded in the div row below — came from a differential test against an independent
evaluator. That is structural, not luck: kernels are redundant checkers of *this
register's output*, so they cannot see a fault in the register itself. Each row
discharged here removes trust that no number of kernels can remove.

## What "faithful" means for a row

A lowering rule is faithful when, for every program the rule fires on:

1. **Sufficiency** — if the emitted obligation holds, the runtime property holds. The
   direction that matters: an insufficient obligation means a "proved" program can
   still fault.
2. **Hypothesis soundness** — every hypothesis attached to the obligation is actually
   established at that program point. An unsound extra hypothesis makes the obligation
   trivially dischargeable and the proof vacuous.

   > **This clause has a live, reproduced instance: H23.** A loop `#[invariant]` is
   > attached as a hypothesis whether or not its preservation VC (O2) is discharged, and
   > no status composition relates them — so a guaranteed out-of-bounds access reports
   > `proved_by_multi_kernel (3: lean, rocq, isabelle)` and the binary then aborts. See
   > `examples/unsound_hypothesis/`, owned by R-0461. Note what this means for the rows
   > below: their "Assumes" clauses say the enclosing guards and `#[requires]` are sound
   > at the operation's program point, and that assumption is currently **false in the
   > presence of loop invariants** — so every row inherits the defect, not just one.
3. **Applicability** — the rule fires wherever the property can be violated. A rule
   that silently declines to fire produces no obligation and therefore no failure.

Sufficiency (1) is the one a differential test can probe; (2) and (3) are where
proofs are needed, since no test enumerates program points.

## Register

### `overflowObligations` — checked arithmetic cannot trap

| | |
|---|---|
| **Emits** | For each `+`/`-`/`*` under `#[overflow_checked]`: `lo ≤ e ∧ e ≤ hi` for the operand type's range. |
| **Assumes** | The operand type's `lo`/`hi` match `Concrete.Semantics.IntArith`'s range for that width; the surrounding `#[requires]` and enclosing guards are all sound at the operation's program point. |
| **Rejects** | Non-`#[overflow_checked]` arithmetic (no obligation — the wrapping/saturating forms are separate ops); `div`/`mod` sub-terms (dropped from the lowering, so the goal reads `not-asked`, never a false verdict). |
| **Forced by** | `examples/two_kernel_demo/src/main.con` (`add_bounded` graduates, `mul_unbounded` must not). |
| **Cross-checked today** | `--report bridge-check` fuzzes concrete inputs against a *proved* obligation; `--report core-semantics-diff` cross-checks the arithmetic model used to build it. **Neither probes sufficiency** — see the correction below. On the H24 fixture `bridge-check` reports `ok — proved; 9 inputs checked, no counterexample` for the very function that aborts. |
| **Discharging theorem (TODO)** | `overflow_obligation_sufficient`: if the emitted bounds hold for every reachable assignment, `IntArith.checked{Add,Sub,Mul}` does not trap at that site. |

### `boundsObligations` — array indexing is in range

| | |
|---|---|
| **Emits** | For each fixed-size array index: `0 ≤ i ∧ i < n`, with `n` from the array's declared size. |
| **Assumes** | `arraySizeMap` resolves the indexed identifier to the right declared size (params and annotated lets); the array is not aliased to a different-length one. |
| **Rejects** | Indices into non-fixed-size or dynamically-sized containers; index expressions outside the linear fragment. |
| **Forced by** | `examples/two_kernel_demo/src/families.con` (`read_at`). |
| **Cross-checked today** | `bridge-check` fuzz; NOT covered by `core-semantics-diff` — array indexing is outside the extractable fragment. |
| **Discharging theorem (TODO)** | `bounds_obligation_sufficient`: the emitted range implies the interpreter's `arrayIndex` never faults, and `arraySizeMap` is sound w.r.t. declared sizes. |

### `divObligations` — no division by zero

| | |
|---|---|
| **Emits** | For each `/` and `%`, **two** obligations, one per condition in `IntArith.trapConditions .div`: `divisor ≠ 0` (`div_nonzero`) and `¬(dividend = MIN ∧ divisor = -1)` (`div_quotient_in_range`, key `…#div{n}q`). Separate VCs deliberately — a division can discharge the first and fail the second, and folding them into one status is how the weaker condition masked the stronger (H24, closed R-0464 2026-08-03). The quotient row is emitted only for signed operand types, which are the only ones with a MIN to exclude. |
| **Assumes** | The divisor expression is evaluated exactly once at that point (no side-effecting re-evaluation); truncating semantics (`Int.tdiv`/`Int.tmod`) — the sign convention does not affect the obligation, but it does affect any model built alongside it. |
| **Rejects** | Divisors outside the linear fragment (dropped, reads `not-asked`). |
| **Forced by** | `examples/two_kernel_demo/src/families.con` (`div_safe`). |
| **Cross-checked today** | `bridge-check` fuzz; `core-semantics-diff` cross-checks the truncating-division model — and caught a real fault there (`Z.div` vs `Z.quot` disagreeing at `(-7)/2`). |
| **Discharging theorem (TODO)** | `div_obligation_sufficient`: the two conditions TOGETHER imply `IntArith.evalIntBinOp .div`/`.mod` does not trap at that site. Still a TODO — `familyForTrapCondition`'s totality proves every condition has a family, not that the families' propositions are strong enough. That is Register A's job, and this row is why the distinction matters. |

### `shiftObligations` — shift amounts in range

| | |
|---|---|
| **Emits** | For each `<<` and `>>`: `0 ≤ amount ∧ amount < bitWidth(ty)`, where `ty` is the **shifted operand's** type — matching `IntArith.shiftAmountInRange`, which takes the value's type, not the amount's. Taking the amount's type would state a condition about the wrong width and pass while checking nothing. |
| **Assumes** | The amount expression is evaluated exactly once at that point; the shifted operand's type is a known fixed width (an unknown width emits nothing — see Rejects). |
| **Rejects** | Shifts whose shifted operand has no resolvable integer type, and amounts outside the linear fragment (dropped, reads `not-asked`). |
| **Forced by** | `examples/trap_semantics_gap/src/main.con` (`tg::s`, `1 << 40`). |
| **Cross-checked today** | `check_known_wrong_corpus.sh` asserts the family exists and uses the shifted operand's width; `IntArith`'s `shiftAmountInRange` examples pin the boundary (31 ok, 32 not, negative not). |
| **Discharging theorem (TODO)** | `shift_obligation_sufficient`: `0 ≤ n < w` implies `IntArith.evalIntBinOp .shl`/`.shr` does not trap at that site. |

**Provenance of this row.** The family did not exist until R-0464 (2026-08-03), and its
absence was invisible to this document's own gate: `check_vc_bridge_register.sh` walks from
generators to rows, so a family with no generator has nothing to be missing. The totality
example against `IntArith.allTrapConditions` walks the other way — from the semantics to the
families — which is the direction that detects absence. Both directions are needed, and this
row exists because the second one was added.

### `callSiteObligations` — callee preconditions hold at each call

| | |
|---|---|
| **Emits** | For each direct call to a function with `#[requires]`: the callee's preconditions instantiated at the call site's actual arguments. |
| **Assumes** | Substitution of actuals for formals is capture-free; the callee's `#[requires]` list is complete as written. |
| **Rejects** | Indirect calls through function pointers (no statically-known callee contract). |
| **Forced by** | `examples/contract_negatives/` (call-precondition negatives). |
| **Cross-checked today** | Not covered by either differential surface. |
| **Discharging theorem (TODO)** | `call_obligation_sufficient`: discharging the instantiated preconditions establishes the callee's `#[requires]` on entry. |

### `multiKernelObligations` — the prover-neutral view

**Kind**: projection (not a lowering rule — no Emits/Assumes/Rejects contract).

It selects the linear, non-constant obligations of the three families above and hands
them to external kernels. It emits no new obligation and introduces no assumption of
its own, so it has nothing to discharge: its faithfulness is exactly that of the rows
above, plus the per-prover rendering, which `--report lowering-agreement` checks
separately by construction rather than by proof.

## Status

Rows discharged: **0 of 4**. Every row is currently trusted, which is what
`independent_of.bridge = "no"` reports.

**Correction, 2026-07-31: the differential surfaces do NOT probe sufficiency.** This
document previously said they did, for two of the four rows. They cannot, and H24 shows it
concretely: `bridge-check` evaluates the *obligation* on sampled inputs and looks for an
input where the obligation is false. On `a / b` the obligation is `b ≠ 0`, which is true
at `(i32::MIN, -1)` — so it reports `ok — proved; 9 inputs checked, no counterexample`
about a function that aborts on that input.

The distinction matters for what these surfaces are worth: `bridge-check` tests **lowering
fidelity** — does the printed obligation mean what the obligation means — by checking the
obligation against an evaluator of the *same* obligation. Sufficiency asks a different
question, *does the obligation imply the runtime property*, and nothing in the loop is a
witness to the runtime property. So sufficiency needs either the theorems (R-0460) or the
artifact itself (R-0462), and no amount of fuzzing the obligation substitutes.

H24 is therefore also the clearest validation of R-0462's priority: **every** static
surface reports success on `examples/trap_semantics_gap/` — `vcs` says
`proved_by_kernel_decision`, `bridge-check` says no counterexample, `core-semantics-diff`
says nothing (both functions are outside the extractable fragment, correctly named rather
than silently skipped) — and the binary aborts on the first run. Fuzzing the compiled
artifact would have found both gaps immediately.

The rows still cover neither hypothesis soundness (H23) nor applicability (H24's shift
gap) — those need the theorems.

**The register is also INCOMPLETE, and its gate cannot say so.** Two gaps found 2026-07-31
(H24), both reproduced in `examples/trap_semantics_gap/`:

- The div row's `Emits` is **insufficient** — it omits signed `MIN / -1`, which
  `IntArith` traps on. A program is reported proved and aborts.
- There is **no shift row, because there is no shift family**, while `IntArith` traps on
  out-of-range shifts. Nothing generates an obligation, so nothing can fail.

`check_vc_bridge_register.sh` asserts every family *generator* has a row. It therefore
cannot detect a missing family — there is no generator to notice. Registering rows against
the **trap definition** (`IntArith`) rather than against the existing generators is what
would make that detectable, and is R-0464's first objective. Until then, read "0 of 4" as
counting the rows we know to write, not the rows that exist.
