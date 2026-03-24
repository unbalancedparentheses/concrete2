# Concrete Roadmap

This document answers one question: **what should happen next, in order.**

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references, see [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), and [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by grammar cost, audit cost, and proof cost, not only by expressiveness.

## Where We Are

The Lean 4 compiler implements the full pipeline:

`Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → EmitSSA → LLVM IR`

The core language, stdlib foundation, report surfaces, and project workflow are real. Phase H (real-program pressure testing) is nearly complete — discovery is done, cleanup is wrapping up. The main missing structural pieces are package/artifact architecture, broader formalization, backend plurality, and a fuller runtime story.

## What Happens Next

### 1. Finish Phase H Cleanup

**Status:** active — discovery complete, cleanup wrapping up.

The remaining work is narrow and evidence-backed. Do not reopen H as open-ended exploration.

Do next:
1. match-as-expression: value-producing `match` so linear types can be bound from branches without dummy-init workarounds
2. classify remaining runtime/stack pressure findings as language, runtime, stdlib, or tooling
3. clean up stdlib output surface so examples stop using builtin-shaped `print_string` / `print_char`

Do later, only if evidence demands it:
- string `==` operator
- broader destructuring syntax

Exit criterion:
- examples show the intended Concrete style without workarounds
- expression ergonomics pressure is classified as "needs a feature" vs "needs a better idiom"
- runtime/stack questions are classified, not ambient

References: [phase-h-findings](research/workloads/phase-h-findings.md), [text-and-output-design](research/stdlib-runtime/text-and-output-design.md), [cleanup-ergonomics](research/language/cleanup-ergonomics.md)

### 2. Package and Artifact Architecture (Phase J)

**Status:** not started. Largest structural blocker once H cleanup is done.

Do next:
1. incremental compilation: serialize artifacts, cache by source hash, skip unchanged modules
2. third-party dependency model: version constraints, lockfile, resolution
3. split interface artifacts from body artifacts
4. workspace and multi-package support
5. package-aware testing tooling
6. first authority-budget path at module/package scope
7. cross-target FFI/ABI validation
8. provenance-aware publishing direction (before package identity needs redesign)

Exit criterion:
- incremental rebuilds exist
- package/dependency semantics are explicit
- workspaces are real
- package graph supports later trust/publishing work

References: [artifact-driven-compiler](research/compiler/artifact-driven-compiler.md), [package-model](research/packages-tooling/package-model.md), [package-manager-design](research/packages-tooling/package-manager-design.md), [package-testing-tooling](research/packages-tooling/package-testing-tooling.md)

### 3. Formalization and Proof Expansion (Phase I)

**Status:** not started.

Do next:
1. broaden the pure Core proof fragment
2. stabilize the provable subset as an actual target
3. source-to-Core and Core-to-proof traceability
4. proof-backed authority reports as real artifacts
5. user-program proof workflow, artifact-driven

Exit criterion:
- proof workflow is broader, clearer, and tied to stable artifacts

References: [formalization-breakdown](research/proof-evidence/formalization-breakdown.md), [formalization-roi](research/proof-evidence/formalization-roi.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md)

### 4. Adoption and Showcase (Phase K)

**Status:** not started. Only after package model and ergonomics are solid.

Do next:
1. define domains where Concrete should be unusually strong
2. curate public showcase corpus
3. improve onboarding and example presentation
4. define stability / experimental surface
5. sharpen positioning vs neighboring systems languages

Demo types, ranked by impact:
1. "Spot the bug" side-by-side — C/Rust/Concrete, C has a hidden capability leak
2. Live audit of a real dependency — `with()` signatures reveal what code touches
3. Privilege-separated tool end-to-end — hasher can't touch network, reporter can't read files
4. Formal proof demo — correct because proved, not because tested
5. Performance benchmark against C — SHA-256, JSON parsing
6. Capability escalation attack (blocked) — compiler says no
7. Rewrite a 500-line C file — capabilities make security explicit
8. Interactive playground / REPL — highest reach, highest cost
9. Package ecosystem demo — practical stdlib usage
10. Conference talk with storytelling — narrative-driven

References: [adoption-strategy](research/workloads/adoption-strategy.md), [showcase-workloads](research/workloads/showcase-workloads.md)

### 5. Project and Operational Maturity (Phase L1)

**Status:** not started.

Do next:
1. machine-readable reports
2. verified FFI envelopes
3. trust bundles and report-first review workflows
4. semantic query/search over compiler facts
5. compatibility checks and trust-drift diffing
6. review-policy gates
7. coverage tooling over tests, reports, and proof artifacts
8. release/compatibility discipline
9. editor/LSP baseline and dependency auditing

References: [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [developer-tooling](research/packages-tooling/developer-tooling.md)

### 6. Backend Plurality (Phase L2)

**Status:** not started. Keep explicit and late.

Do next:
1. stabilize SSA as the backend contract
2. evaluate QBE as first lightweight second backend
3. cross-backend validation and emitted-code inspection
4. debug-info and codegen maturity

References: [qbe-backend](research/compiler/qbe-backend.md), [qbe-in-concrete](research/compiler/qbe-in-concrete.md), [mlir-backend-shape](research/compiler/mlir-backend-shape.md), [optimization-policy](research/compiler/optimization-policy.md)

### 7. Concurrency (Phase M)

**Status:** not started.

Intended shape:
- structured concurrency as semantic center
- OS threads + message passing as base primitive
- evented I/O only as later specialized model

References: [concurrency](research/stdlib-runtime/concurrency.md), [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md)

### 8. Allocation Profiles (Phase N)

**Status:** not started.

Do next:
1. strengthen `--report alloc`
2. enforceable `NoAlloc`
3. structural boundedness reports where explainable
4. `BoundedAlloc(N)` only where structurally explainable

References: [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [arena-allocation](research/stdlib-runtime/arena-allocation.md), [execution-cost](research/stdlib-runtime/execution-cost.md)

### 9. Research and Evidence-Gated Features (Phase O)

**Status:** not started. Keep visible without forcing premature language growth.

Candidates: typestate, arena allocation, execution boundedness, layout reports, binary-format DSLs, ghost/proof-only syntax, hardware capability mapping, capability sandbox profiles, Miri-style interpreter.

References: [high-leverage-systems-ideas](research/meta/high-leverage-systems-ideas.md), [ten-x-improvements](research/meta/ten-x-improvements.md), [typestate](research/language/typestate.md)

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
