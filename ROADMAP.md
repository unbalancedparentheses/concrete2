# Concrete Roadmap

This document answers one question: what should happen next, in order.

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references, see [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), and [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by grammar cost, audit cost, and proof cost, not only by expressiveness.

## Current Position

The Lean 4 compiler implements the full current pipeline:

`Parse -> Resolve -> Check -> Elab -> CoreCheck -> Mono -> Lower -> EmitSSA -> LLVM IR`

Major landed state belongs in [CHANGELOG.md](CHANGELOG.md). The short version is:
- the core compiler pipeline, stdlib foundation, report surfaces, and project workflow are real
- the main missing structural pieces are package/artifact architecture, broader formalization, backend plurality, and a fuller runtime story

Current active work:
- finishing the remaining high-leverage Phase H cleanup items exposed by real programs

Next major build-out:
- **Phase J Foundation** — artifact, package, and workspace architecture

## Phase Status

| Phase | Focus | Status |
|------|-------|--------|
| A-G | Core language, safety, testing, execution model | Done |
| H | Real-program pressure testing | Active — discovery complete, cleanup in progress |
| I | Formalization and proof expansion | Not started |
| J | Package and dependency ecosystem | Not started |
| K | Adoption and showcase | Not started |
| L1 | Project and operational maturity | Not started |
| L2 | Backend plurality and codegen maturity | Not started |
| M | Concurrency maturity and runtime plurality | Not started |
| N | Allocation profiles and bounded allocation | Not started |
| O | Research phase and evidence-gated features | Not started |

Phase H detail lives in:
- [research/workloads/phase-h-summary.md](research/workloads/phase-h-summary.md)
- [research/workloads/phase-h-findings.md](research/workloads/phase-h-findings.md)

The phase itself succeeded in purpose: Concrete was exercised by real programs, structural weaknesses were exposed, and the project now has evidence-backed priorities. What remains from Phase H is follow-through, not discovery:
- package/project/tooling follow-through now lives in **Phase J**
- stdlib/language friction follow-through now lives in **Phase H Cleanup**
- runtime/stack pressure classification and cross-language comparison follow-through remain recorded in the Phase H notes
- long-horizon questions remain recorded in the research notes until evidence justifies implementation

Interpretation:
- **Phase H is still active as cleanup**
- **Phase J is the next major architectural build-out**
- small high-leverage H cleanup items should still land whenever they are cheaper than beginning a large J subproject

## Linear Sequence

### 1. Phase H Cleanup: Finish The Remaining Real-Program Follow-Through

Discovery is complete. The remaining work is to turn the highest-leverage findings into stable language/stdlib/tooling improvements without reopening H as an open-ended exploration phase.

Do next:
1. extract shared stdlib modules where examples are still duplicating obvious support code
   - especially parser/storage/integrity helpers like SHA-256 and common string/bytes utilities
3. finish the next string-ergonomics layer
   - `starts_with`
   - `ends_with`
   - `contains`
4. improve collection patterns for linear values where examples still fight the container surface
5. classify the remaining runtime/stack pressure findings cleanly as language, runtime, stdlib, or tooling
6. keep cross-language comparison follow-through recorded and land it only where it still changes judgment

Recently landed from this cleanup track:
- match on integers and bools: parser support for negative int and bool literal patterns, CoreCheck exhaustiveness for non-enum matches (default arm required unless Bool is fully covered)
- fix `import` / `pub` visibility so private impl methods and private trait-impl methods no longer leak across module boundaries via import or method-call syntax

Do later, only if evidence still demands it:
- string `==`
- destructuring `let`

Why first:
- these are still the most visible daily-writing friction points found by real programs
- several of them are cheap compared to the structural work in J
- keeping them explicit prevents the roadmap from pretending all remaining work is architectural

Primary references:
- [research/workloads/phase-h-findings.md](research/workloads/phase-h-findings.md)
- [research/stdlib-runtime/text-and-output-design.md](research/stdlib-runtime/text-and-output-design.md)
- [research/stdlib-runtime/runtime-collections.md](research/stdlib-runtime/runtime-collections.md)
- [research/stdlib-runtime/iterators.md](research/stdlib-runtime/iterators.md)
- [research/language/cleanup-ergonomics.md](research/language/cleanup-ergonomics.md)

Exit criterion:
- examples stop reimplementing obvious string/helpers repeatedly
- the current best Concrete style is visible in the example corpus
- remaining language-pressure candidates are clearly evidence-backed rather than general frustration
- the remaining runtime/stack questions are classified rather than left ambient

### 2. Phase J Foundation: Artifact And Package Architecture

This is the next major architectural priority. It is the largest structural blocker left in the project once the short Phase H cleanup tail is under control.

Do next:
1. incremental compilation: serialize pipeline artifacts, cache by source hash, skip unchanged modules
2. define the third-party dependency model: version constraints, lockfile semantics, dependency resolution
3. split interface-facing artifacts from body-bearing artifacts
4. define workspace and multi-package behavior
5. make package/dependency reasoning operate on explicit graph artifacts
6. make testing tooling package-aware
7. define the first authority-budget path at module/package scope
8. complete empirical cross-target FFI/ABI validation for the package/workspace model
9. define the provenance-aware publishing direction early enough that package identity and graph artifacts do not need redesign later

Why first:
- without this, serious projects still pay workflow tax
- later proof, adoption, and operational work all depend on cleaner artifact and package boundaries
- it is a stronger bottleneck than any one local language-ergonomics issue

Primary references:
- [research/compiler/artifact-driven-compiler.md](research/compiler/artifact-driven-compiler.md)
- [research/packages-tooling/package-model.md](research/packages-tooling/package-model.md)
- [research/packages-tooling/package-manager-design.md](research/packages-tooling/package-manager-design.md)
- [research/packages-tooling/package-testing-tooling.md](research/packages-tooling/package-testing-tooling.md)
- [research/compiler/compiler-dataflow-ideas.md](research/compiler/compiler-dataflow-ideas.md)

Exit criterion:
- incremental rebuilds exist
- package/dependency semantics are explicit
- workspaces are real
- interface/body artifact boundaries are no longer muddy
- package graph artifacts are explicit enough to support later trust/publishing work
- the first authority-budget path is structurally possible
- cross-target FFI/ABI validation is no longer hand-wavy
- the package graph is not heading toward a publishing/trust-model redesign

### 3. Phase I: Formalization And Proof Expansion

Once the artifact/package model is cleaner and the language surface has absorbed the biggest real-program friction, deepen the proof story.

Do next:
1. broaden the pure Core proof fragment
2. stabilize the provable subset as an actual target
3. add source-to-Core and Core-to-proof traceability
4. make proof-backed authority reports a real artifact rather than only a research direction
5. make the user-program proof workflow real and artifact-driven
6. push selected compiler-preservation work further where it is tractable

Primary references:
- [research/proof-evidence/formalization-breakdown.md](research/proof-evidence/formalization-breakdown.md)
- [research/proof-evidence/formalization-roi.md](research/proof-evidence/formalization-roi.md)
- [research/proof-evidence/proving-concrete-functions-in-lean.md](research/proof-evidence/proving-concrete-functions-in-lean.md)
- [research/proof-evidence/proof-addon-architecture.md](research/proof-evidence/proof-addon-architecture.md)

Exit criterion:
- the proof workflow is broader, clearer, and tied to stable artifacts rather than only to a narrow pure fragment

### 4. Phase K: Adoption, Positioning, And Showcase Pull

Only after the package floor and the biggest ergonomics problems are under better control should Concrete optimize for public pull.

Do next:
1. define signature domains where Concrete should be unusually strong
2. curate the public showcase corpus
3. improve onboarding and example presentation
4. define the public stability / experimental surface
5. sharpen positioning relative to neighboring systems languages

Primary references:
- [research/workloads/adoption-strategy.md](research/workloads/adoption-strategy.md)
- [research/workloads/showcase-workloads.md](research/workloads/showcase-workloads.md)
- [research/meta/complete-language-system.md](research/meta/complete-language-system.md)

### 5. Phase L1: Project And Operational Maturity

Turn the language/compiler into a durable operational system.

Do next:
1. machine-readable reports
2. verified FFI envelopes and reportable FFI boundary facts
3. trust bundles and report-first review workflows
4. semantic query/search over compiler facts
5. semantic compatibility checks and trust-drift diffing
6. review-policy gates over authority, trusted, FFI, and proof-facing facts
7. coverage tooling over tests, reports, and proof-facing artifacts
8. release/compatibility discipline
9. editor/LSP baseline, developer feedback loop, and dependency auditing

Primary references:
- [research/proof-evidence/evidence-review-workflows.md](research/proof-evidence/evidence-review-workflows.md)
- [research/proof-evidence/proof-evidence-artifacts.md](research/proof-evidence/proof-evidence-artifacts.md)
- [research/proof-evidence/trust-multipliers.md](research/proof-evidence/trust-multipliers.md)
- [research/packages-tooling/developer-tooling.md](research/packages-tooling/developer-tooling.md)

### 6. Phase L2: Backend Plurality And Codegen Maturity

Backend plurality should remain explicit and late.

Do next:
1. stabilize SSA as the backend contract in practice
2. evaluate QBE as the first lightweight second-backend experiment
3. add cross-backend validation and stronger emitted-code inspection
4. improve debug-info and codegen maturity

Primary references:
- [research/compiler/qbe-backend.md](research/compiler/qbe-backend.md)
- [research/compiler/qbe-in-concrete.md](research/compiler/qbe-in-concrete.md)
- [research/compiler/mlir-backend-shape.md](research/compiler/mlir-backend-shape.md)
- [research/compiler/optimization-policy.md](research/compiler/optimization-policy.md)

### 7. Phase M: Concurrency Maturity And Runtime Plurality

Keep the concurrency story explicit, auditable, and small.

Intended shape:
- structured concurrency as semantic center
- OS threads plus message passing as the base primitive
- evented I/O only as a later specialized model

Primary references:
- [research/stdlib-runtime/concurrency.md](research/stdlib-runtime/concurrency.md)
- [research/stdlib-runtime/long-term-concurrency.md](research/stdlib-runtime/long-term-concurrency.md)

### 8. Phase N: Allocation Profiles And Bounded Allocation

Strengthen allocation behavior as an audit and high-integrity surface.

Do next:
1. strengthen `--report alloc`
2. add enforceable `NoAlloc`
3. add structural boundedness reports where they remain explainable
4. only explore `BoundedAlloc(N)` where the story remains structurally explainable

Primary references:
- [research/stdlib-runtime/allocation-budgets.md](research/stdlib-runtime/allocation-budgets.md)
- [research/stdlib-runtime/arena-allocation.md](research/stdlib-runtime/arena-allocation.md)
- [research/stdlib-runtime/execution-cost.md](research/stdlib-runtime/execution-cost.md)

### 9. Phase O: Research And Evidence-Gated Features

Keep high-value ideas visible without forcing premature language growth.

Candidates:
- typestate
- arena allocation
- execution boundedness
- layout reports
- binary-format DSLs
- ghost/proof-only syntax
- hardware capability mapping
- capability sandbox profiles
- Miri-style interpreter direction

Primary references:
- [research/meta/high-leverage-systems-ideas.md](research/meta/high-leverage-systems-ideas.md)
- [research/meta/ten-x-improvements.md](research/meta/ten-x-improvements.md)
- [research/language/typestate.md](research/language/typestate.md)

## Design Constraints

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over phi transport
- avoid parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable

## Current Risks

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
- formalization scope is still narrow
- type-coercion completeness is not proved, only hardened
- the linearity checker is tested heavily but not formally audited

## Longer-Horizon Multipliers

1. proof-backed trust claims
2. stronger audit outputs
3. a smaller trusted computing base
4. a better capability/sandboxing story

Important carry-forwards from earlier phases that are still owned later:
- proof-backed authority reports belong to **Phase I** and later **L1**
- verified FFI envelopes, compatibility checking, trust-drift diffing, and coverage tooling belong to **L1**
- structural boundedness reports belong to **N**
- capability sandbox profiles belong to **O** unless earlier evidence forces them forward

For more:
- [research/meta/ten-x-improvements.md](research/meta/ten-x-improvements.md)
- [research/language/capability-sandboxing.md](research/language/capability-sandboxing.md)
- [research/proof-evidence/trust-multipliers.md](research/proof-evidence/trust-multipliers.md)
- [research/meta/ai-assisted-optimization.md](research/meta/ai-assisted-optimization.md)
