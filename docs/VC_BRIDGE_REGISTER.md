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

## What "faithful" means for a row

A lowering rule is faithful when, for every program the rule fires on:

1. **Sufficiency** — if the emitted obligation holds, the runtime property holds. The
   direction that matters: an insufficient obligation means a "proved" program can
   still fault.
2. **Hypothesis soundness** — every hypothesis attached to the obligation is actually
   established at that program point. An unsound extra hypothesis makes the obligation
   trivially dischargeable and the proof vacuous.
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
| **Cross-checked today** | `--report bridge-check` fuzzes concrete inputs against a *proved* obligation (probes sufficiency); `--report core-semantics-diff` cross-checks the arithmetic model used to build it. |
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
| **Emits** | For each `/` and `%`: `divisor ≠ 0`. |
| **Assumes** | The divisor expression is evaluated exactly once at that point (no side-effecting re-evaluation); truncating semantics (`Int.tdiv`/`Int.tmod`) — the sign convention does not affect the obligation, but it does affect any model built alongside it. |
| **Rejects** | Divisors outside the linear fragment (dropped, reads `not-asked`). |
| **Forced by** | `examples/two_kernel_demo/src/families.con` (`div_safe`). |
| **Cross-checked today** | `bridge-check` fuzz; `core-semantics-diff` cross-checks the truncating-division model — and caught a real fault there (`Z.div` vs `Z.quot` disagreeing at `(-7)/2`). |
| **Discharging theorem (TODO)** | `div_obligation_sufficient`: `divisor ≠ 0` implies `IntArith.tdiv`/`tmod` do not trap at that site. |

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
`independent_of.bridge = "no"` reports. The differential surfaces
(`bridge-check`, `core-semantics-diff`) probe sufficiency on sampled inputs for two of
the four rows and cover neither hypothesis soundness nor applicability — those need
the theorems.
