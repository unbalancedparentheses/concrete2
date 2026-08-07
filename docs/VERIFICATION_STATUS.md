# Verification Status

Status: canonical capability map for `main`

Last reviewed: 2026-08-07

This page answers three questions without collapsing unlike claims:

1. What can Concrete prove or enforce today?
2. What is missing?
3. What is experimental or actively being developed?

For exact public guarantees, [CLAIMS_TODAY.md](CLAIMS_TODAY.md) remains
authoritative. For product direction, see
[VERIFICATION_CHARTER.md](VERIFICATION_CHARTER.md). For current defects and
containment, see [KNOWN_HOLES.md](KNOWN_HOLES.md). The ROADMAP owns work order,
not present-tense capability claims.

## Read every support claim on three axes

“Supported” is ambiguous unless all three axes are named:

- **construct:** what program or value shape the proof is about;
- **property:** safety, functional correctness, termination, relational
  behavior, or resources;
- **evidence:** compiler enforcement, runtime check, solver trust, one kernel,
  or independently replayed kernels.

The proof subject matters too. A theorem over extracted `ProofCore` semantics is
not an end-to-end theorem about the emitted binary.

## Systems available on `main`

Concrete currently has two proof paths plus compiler enforcement.

### Extracted-semantics proofs

Eligible functions are extracted to `ProofCore`/`PExpr` and may carry attached
Lean theorems with body-fingerprint freshness checks.

Supported theorem shapes include:

- fixed-input results;
- universal boundary or branch properties;
- complete input/output specifications;
- refinement against a specification function;
- bounded-loop and loop-state refinement;
- explicit composition through a complete proof function table.

The extracted model supports integers, booleans, comparisons, conditionals,
lets, non-recursive direct calls, selected fixed-width operations, structs,
enums and supported matches, fixed arrays, functional array update, selected
casts, bounded loops, loop-carried scalar/array state, and modeled
`break`/`continue` control.

The claim is: Lean checked a theorem about the extracted semantics bound to the
recorded proof subject. It is not a compiler-correctness or binary-correctness
claim.

### Generated obligations

Concrete generates and classifies obligations for:

- array bounds;
- overflow, division/modulo traps, and invalid shifts;
- call-site preconditions;
- function preconditions and postconditions;
- assertions and explicit assumptions;
- loop invariant initialization and preservation;
- loop-exit/postcondition linkage;
- loop-variant non-negativity and decrease.

Linear arithmetic can be closed by kernel-checked decision procedures. Selected
bit-vector properties use `bv_decide` with its separately disclosed trust
boundary. External SMT results remain `solver_trusted` unless independently
replayed; runtime checks and assumptions remain distinct evidence classes.

### Independent-kernel evidence

The supported `main` path can replay the linear-integer runtime-safety fragment
through Lean and optional Rocq/Isabelle backends. A badge records the kernels,
foundational diversity, versions, and the fact that the shared bridge is not
independently verified.

Broader non-arithmetic theory tiers—booleans, structures, arrays as logical
values, uninterpreted functions, and defined-spec refinement across kernels—are
experimental branch work until merged and graduated. They are not `main`
capabilities merely because a spike demonstrates them.

### Compiler enforcement

The checker enforces properties including linear ownership, consumption,
borrow exclusivity, restricted safe-reference escape, explicit capabilities,
trusted/unsafe boundaries, and match exhaustiveness. These are `enforced`, not
kernel theorems.

## Capability matrix

| Area | `main` status | Proof subject/evidence | Important boundary |
|---|---|---|---|
| pure scalar functional correctness | shipped | attached Lean theorem over `ProofCore` | not binary correctness |
| structs, enums, fixed arrays in extracted proofs | shipped subset | Lean/`ProofCore` | only admitted extraction forms |
| bounded loop/state refinement | shipped subset | Lean with reusable loop lemmas | not arbitrary mutation or termination inference |
| arithmetic and bounds safety VCs | shipped | kernel decision, SMT, runtime, or explicit gap | Core→obligation bridge remains H19 |
| source contracts and loop VCs | shipped local surface | obligation/evidence ledger | automatic call composition is incomplete |
| multi-kernel linear arithmetic | shipped opt-in | Lean plus optional Rocq/Isabelle | shared lowering is not bridge-verified |
| non-arithmetic multi-kernel theories | experimental | spike evidence | not a supported `main` feature |
| recursive total correctness | unsupported | — | needs well-founded decreases and extraction |
| heap/reference functional correctness | unsupported | — | needs a memory and alias model |
| two-state mutation specifications | unsupported | — | needs `old` plus frame/modifies semantics |
| relational properties | unsupported | — | needs paired-execution semantics |
| proved resource bounds | unsupported/partial reporting | reports and enforcement only | no general stack/allocation/time proof |
| proof-aware package composition | planned | versioned interface evidence | no consumer-side behavioral compatibility gate yet |
| emitted-binary correctness | unsupported | differential/validation evidence only | compiler, LLVM, linker, runtime and target remain trusted |

## Missing foundations

The highest-priority missing foundations are:

1. typed and identity-resolved contracts preserved in Core;
2. stable lexical binding identities for proof transformations;
3. capture-safe substitution with an evaluation-equivalence gate;
4. one typed VC calculus and structured obligation comparison;
5. family-by-family migration away from handwritten discovery walkers;
6. stronger Core-to-obligation faithfulness evidence for H19;
7. dependency-closed, compositional contracts across calls and packages.

After those foundations come `old`/frame conditions, recursion and termination,
heap/reference models, relational verification, resource contracts, and a
workload-driven specification library.

## Current structural trust boundary

[KNOWN_HOLES.md](KNOWN_HOLES.md) owns exact hole status. The central open proof
boundary is H19: all kernels may agree on a proposition produced by one shared,
incorrect lowering. Semantic sufficiency theorems, differential checks,
negative controls, artifact fuzzing, and multiple kernels reduce risk but do
not constitute a general soundness theorem for VC generation.

H23 and H24 are closed incidents with retained regression fixtures. They are
evidence for why hypothesis provenance, single-source trap semantics, negative
controls, and cross-surface consistency are required; they are not current
warnings that override every proof result.

## Experimental and active development

Development branches may contain work not available on `main`. As of the review
date, active directions include:

- broader multi-kernel theory fragments;
- contract checking and containment for name-based substitution;
- a separate weakest-precondition/requirement-calculus branch;
- structured rather than display-string differential comparison;
- stable binding identities and capture-safe substitution;
- remaining negative-control and corpus-coverage measurements.

Experimental results must remain labeled experimental until their code,
negative controls, documentation, known-hole status, and release policy land
together on `main`.

## Explicit non-claims

Concrete does not currently claim:

- that every eligible function is proved;
- that every proof is a full functional specification;
- automatic proof of arbitrary termination or liveness;
- general constant-time or non-interference proofs;
- complete heap, alias, allocation, stack, or time proofs;
- automatic compositional verification across every call or dependency;
- correctness of compilation, LLVM, linking, the runtime, OS, or hardware.

