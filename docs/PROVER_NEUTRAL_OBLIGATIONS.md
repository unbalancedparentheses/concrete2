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

## Open questions — recorded because they are not settled

These are places where the architecture above made a choice by default rather than by
argument. Written down so the choice is revisitable instead of invisible.

### 1. Two-speed model: RESOLVED by measurement — it stands, for a different reason

The original justification given for the two-speed model was "`lia` cannot see through
`eval`". That is a claim about `lia`, and it was the wrong argument. Measured against
cvc5 1.3.4 and z3:

| goal | proved? | Alethe certificate? |
|---|---|---|
| ground integer | yes | **yes** |
| quantified integer (`∀x. x>0 → x≥0`) | yes | **yes** |
| ground **datatype** (`fst (mk 1 2) = 1`) | yes | **no** — `DUMMY_SKOLEM` |
| quantified datatype (exhaustiveness) | yes | **no** |
| recursive datatype, needs induction (`len (app a b) = len a + len b`) | yes, with `--conjecture-gen --quant-ind` | **no** |

Two findings, and the second is the load-bearing one:

1. **Solvers CAN find these proofs.** cvc5 discharged a genuine inductive refinement
   lemma over a recursive datatype automatically. Expressibility and ADT support are not
   the barrier, and `eliminate_algebraic` is not required to make the goal reach a
   solver.
2. **They cannot CERTIFY them.** cvc5's Alethe output rejects *any* datatype-bearing
   proof — a trivial ground selector goal with no quantifier and no recursion already
   fails. Quantified integer goals certify fine, so this is datatypes specifically, not
   quantifiers and not induction.

So the two-speed model stands, restated correctly: **non-arithmetic obligations are
`proved` rather than `decided` because a solver's datatype reasoning cannot be replayed,
not because a solver cannot do it.** Routing refinement to cvc5 would buy automation by
trading a kernel-checked proof for an unreplayable `solver_trusted` verdict — which
violates the invariant at the top of this document and is strictly worse for the thesis
even though it is cheaper.

Consequence for the exhaustiveness family: cvc5 and z3 both prove it, but neither can
certify it, so it should be discharged by a **kernel** (Lean `decide`, Rocq case
analysis, Isabelle) rather than by SMT. That is cheap anyway — it is decidable finite
case analysis — so the route is unchanged; only the reason is now correct.

Watch item, gate-locked in `check_multi_kernel.sh`: if Alethe gains datatype support,
refinement and exhaustiveness both become *certifiably* automatic, and the plan should
move them earlier. Measured on cvc5 1.3.4; stated as a version fact, not a permanent
one.

### 2. Deep vs shallow embedding: RESOLVED by measurement — use both, for disjoint jobs

Measured in Rocq by stating the *same* obligation each way, plus one meta-theorem:

| case | shallow | deep |
|---|---|---|
| per-function obligation, concrete fuel | `unfold; lia` | closes (the AST just computes) |
| per-function obligation, **symbolic** fuel | n/a — shallow has no fuel | needs `destruct` on fuel **once per AST level** before it computes |
| **meta-theorem** — fuel monotonicity over *all* programs | **not expressible** | `induction` on fuel, closes |

They are not competitors. The cost structure is the argument:

- **Deep is required for meta-theory.** A statement quantified over programs — every
  preservation theorem, register B's transformation soundness, bridge soundness — cannot
  be written over a shallow embedding, because shallow gives one function at a time and
  no way to range over programs.
- **Shallow is cheaper for per-function properties**, and the gap *grows with AST
  depth*: symbolic fuel forces a case split per level before anything computes. Refinement,
  constant-time and functional-correctness proofs all pay that tax deep and avoid it
  shallow, because they are properties of one function rather than of the semantics.

**The resolution.** Deep (`PExpr` + `eval`) remains the definition of meaning. Shallow
(`CoreExtract`) is a *derived per-function view*. Each function's shallow form owes one
obligation — *the shallow extraction agrees with `eval` on this function* — which is
exactly what `--report core-semantics-diff` differentially tests today, and which should
become a **register row per extraction rule** so it is proved rather than sampled. Per-
function properties are then proved on the shallow view and transported to the deep one
across that agreement.

**Consequence, and it de-prioritises the largest item in the plan.** The second `eval`
port was justified partly by non-arithmetic proof ergonomics. That justification does not
survive this measurement: per-function proofs are *better* done shallow, and shallow
extraction to another host is a **printer** (the P3 factoring), not an `eval` port. Porting
`eval` buys exactly one thing — meta-theory *in that host*, i.e. letting Isabelle check
the preservation theorems itself. That is a real but much narrower benefit than "Isabelle
can prove non-arithmetic properties", which the printer already delivers.

So the ordering changes: **statement portability via shallow printers comes before the
`eval` port**, and the `eval` port should be justified on meta-theory grounds alone or
deferred.

### 3. Proof UX is absent from this architecture

Nothing above addresses what it is like to *write* a proof against this system:
~30s/goal on the Isabelle path, no counterexample surfaced from a failed obligation, and
a failure that reports `unproven` without saying why. Every item in this document is
about the integrity of evidence, none about the ergonomics of producing it.

For a language that wants users rather than only auditors, that may matter more than an
additional kernel. It is an omission, not a considered tradeoff.

## What this architecture does not claim

- Not that the compiled binary is correct. Proofs are over Core; codegen is a separate
  trust layer.
- Not that two `eval` ports are *provably* the same semantics. Boundary (3) is tested,
  permanently.
- Not that the I/O boundary is verified. `trusted` functions are *contained* by
  capabilities and enumerated, not proved.
- Not that nonlinear SMT results are replayable. Proof reconstruction is linear-only
  across z3, cvc5 and veriT.
