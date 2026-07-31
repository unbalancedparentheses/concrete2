# Prover-Neutral Obligations

Status: normative architecture for the prover-neutral obligation layer.

Supersedes the sketches in [NOTES/concrete-design.md](NOTES/concrete-design.md) §Q5
and [NOTES/why3-architecture-and-positioning.md](NOTES/why3-architecture-and-positioning.md),
which remain as provenance. Those live under `NOTES/`, are non-normative, and are
outside this gate's `PRESENT_DOCS` list — which is why the design in them was
independently re-derived more than once. This file is the version that binds.

## Positioning

**Concrete sits above a Why3-style layer.** The frontend is the value: a no-GC systems
language with linear ownership, capabilities-as-effects, and a graded evidence ledger.
The backend — neutral obligation IR, transformations, driver-per-prover dispatch — is
what Why3 solved and what Concrete should copy rather than reinvent. Multi-prover
dispatch alone is *catching up to* Why3, not a justification for a new language.

The one place Concrete improves on it: **Why3's VC generator and transformations are
trusted. Ours carry soundness registers.**

## THE NORMATIVE RULE (decide once, decide now)

> **`ProofSubjectDigest` is computed over the NEUTRAL term. Never over a host AST.**

Everything else in this document is negotiable. This is not.

Rationale, and why it cannot wait:

- **Freshness becomes host-independent by construction.** Every prover agrees on
  staleness without any of them seeing another's AST. A host-shaped digest makes
  freshness a Lean property and every other prover a second-class citizen.
- **The window is closing.** Digests are *stored*. Once artifacts carry a digest
  computed over a Lean AST, changing the basis invalidates every stored claim
  simultaneously and forces a migration of every fingerprint in `examples/`. At the
  time of writing no `subjectDigest` field exists in `Concrete/`, so the migration
  cost is zero. It only grows.
- **It pays off with one prover.** This is R-0004's decoupling, valuable even if no
  second prover ever ships. It is identity-and-freshness work that happens to also
  unlock portability.
- **It closes a live defect.** The multi-kernel fold currently matches kernels on the
  obligation *id* (`Report.lean`, `foldMultiKernelResults`), not on a subject digest —
  exactly the gap the graduation criteria named. Digest-matching fixes it.

## The record

```
NeutralObligation {
  function      : { qualName, fingerprint }
  spec          : { name, version }
  subjectDigest : Hash                  -- over the NEUTRAL term (see above)
  body          : neutral PExpr
  goal          : neutral PExpr
  hypotheses    : [neutral PExpr]
  dependencies  : [qualName]
  trustedDeps   : [qualName]            -- audited escape hatches travel with the claim
  attestations  : [HostAttestation]
}

HostAttestation {
  host                 : "lean" | "rocq" | "isabelle"
  proofRef             : String
  status               : proved | stale | blocked | ineligible | trusted
  strength             : kernel_decision | verified_checker | replayed_certificate
                       | trusted_solver | trusted_modulo_toolchain | hand_proof
  certificate          : Option Artifact          -- RETAINED, not merely referenced
  checkedAgainstDigest : Hash                     -- /= subjectDigest  =>  stale
}
```

Two encoding invariants that must survive serialization:

- **`.call` and `.applyVar` stay distinct** — the two-namespace `globals`/`callables`
  resolution that closed bug 061.
- **`displayName` is excluded from the digest.** Identity is `CallableId`; the display
  name is explicitly not identity.

## The three trust boundaries

```
runtime property
      ^   (1) obligation sufficiency        PROVABLE      -> register A
   obligation
      ^   (2) transformation soundness      PROVABLE      -> register B
   transformed goal
      ^   (3) cross-semantics agreement     NOT PROVABLE  -> conformance vectors
   host eval ports
```

**(1) Register A — obligation sufficiency.** *If the flat goal holds, the semantic
obligation holds.* One row per obligation family. See
[VC_BRIDGE_REGISTER.md](VC_BRIDGE_REGISTER.md). This is the ceiling on everything: a
perfectly checked proof of an insufficient obligation still lets a program fault.

**(2) Register B — transformation soundness.** *If the transformed goal holds, the
input goal holds.* One row per transformation pass. This is where Concrete improves on
Why3, whose transformations are trusted. Difficulty is skewed and the register must say
so: `eliminate_div_mod` is a rewriting argument; `eliminate_algebraic` requires the
axiomatization be conservative over the datatype theory, which is model-theoretic.

**(3) Conformance — irreducibly tested, and the design says so.** No single kernel can
bridge two kernels; no checker sees both. Relating Lean's `eval` to another host's
therefore **cannot be a proof**. It is a spec plus an adversarial conformance vector
suite: `(neutral program, neutral input) -> expected PVal`, which every host's `eval`
must reproduce. This is `tested_by_oracle`, and the composition rule below folds it in
explicitly rather than laundering it as kernel evidence.

Registers A and B carry a **fingerprint of the generator or transformation they
justify** and fail loudly on drift. Without it a discharged row silently goes vacuous
when its subject changes — the `#[proof_fingerprint]` defect one layer up, at the layer
hardest to audit.

## Composition

```
proved_by_two_kernels(ob) :=
     exists two hosts h1 h2 with hi.status == proved
  /\ h1.checkedAgainstDigest == h2.checkedAgainstDigest == ob.subjectDigest
  /\ both eval ports conform on the vector suite covering ob.body
  /\ ob.trustedDeps identical in both attestations
  /\ each hi's lowering agreed with the reference evaluator
```

The `trustedDeps`-identical clause is load-bearing: two kernels can each prove a claim
while resting on *different* trusted dependencies, and that is not agreement.

## Evidence vocabulary — two coordinates, never fused

```
strength     : per attestation (see HostAttestation)
independence : { implementations: N, foundations: one | CIC x CIC | CIC x HOL,
                 bridge: 0 }
portability  : statable_in  >=  proved_in
```

`proved_by_two_kernels` is a **display label** over the tuple, never a claim in its own
right. Routing is a *strength* statement; redundancy sampling is an *independence*
statement; neither may masquerade as the other.

**The re-check ladder, stated honestly.** Where a *transferable* certificate exists
(LRAT, Alethe), a third party re-checks independently of us and of the producing
toolchain. Where none exists — `omega`, `lia`, `presburger` — the claim is
`trusted_modulo_toolchain`: `lia` has no certificate export, and a `.vo` is re-checkable
only by the same Rocq version. Claiming otherwise would be a promise the architecture
cannot keep for the tier that produces most claims.

## Where the hosts split

Adding a prover must cost one printer and one record, not a pipeline.

| shared, one copy | per host |
|---|---|
| obligation extractor `CExpr -> neutral PExpr` | operator-table column |
| neutral encoder / decoder | term pretty-printer |
| transformation passes | `eval` port |
| conformance-vector generator | theorem-statement emitter |
| evidence ledger and composition | tactic mapping, `attest`, replay driver |

Drivers are **data** — printing, transformations, built-ins, command, and
result-classification patterns including resource exhaustion — not code. A driver
declares what a target *cannot* express so the pipeline can transform; it must never
cause a goal to be silently dropped.

## Two speeds, both first-class

| | discharge | portable |
|---|---|---|
| arithmetic | *decided* by a procedure, automatic | yes |
| non-arithmetic | *proved*, hand or semi-automatic | statement yes, proof later |

`lia` cannot see through `eval`. Stating obligations over extracted semantics makes them
**expressible**, not **dischargeable** — it moves the barrier from "cannot express" to
"cannot automate". Do not plan as though unification removes the barrier.

## Host roles

| | job | per-PR |
|---|---|---|
| Lean | host and definition: Core, `eval`, PExpr, preservation; `decide`, `bv_decide` | yes |
| Rocq | workhorse re-checker; `Function` termination; micromega | yes, on **cost** grounds |
| Isabelle | `sledgehammer` on datatype/quantifier goals; `smt` reconstruction; HOL audience | no, periodic audit |
| solvers | discharge engines, never evidence | n/a |

Rocq runs per-PR because it costs 0.3-1s against Isabelle's ~30s, as insurance against a
latent `omega` bug. That is a cost-and-unmeasured-risk argument, **not** a measured
independence argument — divergence measured zero for Rocq too. Stating it honestly is
what keeps the per-PR/periodic split from looking arbitrary.

## What this architecture does not claim

- Not that the compiled binary is correct. Proofs are over Core; codegen is a separate
  trust layer.
- Not that two `eval` ports are *provably* the same semantics. Boundary (3) is tested,
  permanently.
- Not that the I/O boundary is verified. `trusted` functions are *contained* by
  capabilities and enumerated, not proved.
- Not that nonlinear SMT results are replayable. Proof reconstruction is linear-only
  across z3, cvc5 and veriT.
