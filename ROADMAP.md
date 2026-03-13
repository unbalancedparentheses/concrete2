# Concrete Roadmap

Status: roadmap

This document is forward-looking only.

Use it for:
- active priorities
- remaining major work
- sequencing constraints between unfinished areas

Do not use it as the source of truth for current semantics or past implementation history.
Use it to decide what to do next, in what order, and what documents/code areas to consult while doing it.

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For current compiler structure and pass boundaries, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For project identity and differentiators, see [docs/IDENTITY.md](docs/IDENTITY.md).
For current language and subsystem references, see:
- [docs/FFI.md](docs/FFI.md)
- [docs/ABI_LAYOUT.md](docs/ABI_LAYOUT.md)
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md)

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged not only by expressiveness, but also by its grammar cost, audit cost, and proof cost.

## Current State

The Lean 4 compiler implements the core surface language plus the full internal IR pipeline: Core IR, elaboration, Core validation, monomorphization, SSA lowering, SSA verification/cleanup, and SSA codegen.

The project currently has:

- centralized ABI/layout authority in `Layout.lean`
- native diagnostics through the main semantic passes
- explicit audit/report outputs
- explicit `trusted fn` / `trusted impl` / `trusted extern fn` boundaries
- a real stdlib foundation (`vec`, `string`, `io`, `bytes`, `slice`, `text`, `path`, `fs`, `env`, `process`, `net`, `fmt`, `hash`, `rand`, `time`, `parse`, `test`)
- foundational and extended collections (`Vec`, `HashMap`, `HashSet`, `Deque`, `BinaryHeap`, `OrderedMap`, `OrderedSet`, `BitSet`)
- in-language `#[test]` execution and stdlib test coverage through the real compiler path

Still clearly not implemented:

- `transmute`
- backend plurality over SSA (for example C / Wasm, and later maybe MLIR)
- kernel formalization
- a runtime
- fully authoritative standalone resolution

## Priority Snapshot

### Milestones

| Phase | Focus | Status | Blocks |
|------|-------|--------|--------|
| **A** | Fast feedback and compiler stability | Done enough; aggregate lowering hardened, test runner parallelized, SSA invariants mechanically defended | B, C, D |
| **B** | Semantic cleanup | Done | D |
| **C** | Tooling and stdlib hardening | Done; all 8 items complete (LL(1) CI, linearity fixes, HashMap retired, module-targeted testing, diagnostics polish, integration tests, report hardening, audit reports) | later system maturity |
| **D** | Backend and trust multipliers | Active | A, most of B |
| **E** | Runtime and execution model | Deferred | C, D |
| **F** | Capability and safety productization | Deferred | D, E |
| **G** | Language surface and feature discipline | Deferred | B, D, E, F |
| **H** | Package and dependency ecosystem | Deferred | C, E, G |
| **I** | Project and operational maturity | Deferred | C, D, E, F, G, H |

### Recent Progress

- **Test runner parallelized and narrowed** (commits `1619220`, `6049d89`): `run_tests.sh` defaults to parallel (`nproc` cores), adds `--fast` (default), `--full`, `--filter`, `--stdlib`, `--O2`, `--codegen`, `--report` modes. Partial runs warn clearly. `--fast` is the documented standard developer workflow. This is a strong Phase A solution, but it is still script-level orchestration rather than a deeper artifact-cached or dependency-aware test system.
- **Aggregate loop lowering hardened** (commit `e68acc0`): aggregate loop variables promoted to entry-block allocas. Field assignment GEPs directly into stable storage.
- **Aggregate if/else and match lowering hardened** (commit `8e606d9`): if/else branches with modified struct variables merge via entry-block allocas instead of `phi %Struct`. Match arms get var snapshot/restore between arms. Void-typed match results filtered from phi/store paths.
- **Void-in-phi codegen bug fixed**: a branch-inside-loop case that called a void function was incorrectly producing `phi ptr [void, ...]` in LLVM IR. Regression coverage now exists for that shape.
- **SSA verifier now rejects aggregate phi nodes**: `SSAVerify.lean` checks that no phi node carries an aggregate type (struct, enum, string, array). This is a mechanical invariant, not just regression coverage.
- **Audit**: all phi emission sites in Lower.lean confirmed to check `isAggregateForPromotion` before creating phi nodes. No remaining accidental aggregate transport found.
- **Stdlib test depth increased**: Option, Result, Text, and Slice now have broader in-language test coverage.
- **Linearity checker fixed for generic types**: four fixes to `Check.lean` unblock user-defined generic collections with function pointer fields:
  - `isCopyType` now correctly handles `.generic` (struct isCopy lookup) and `.typeVar` (Copy bound check) instead of returning false for all generics
  - trusted functions can consume linear variables inside loops (loop-depth check skipped when `isTrustedFn`)
  - self-consuming methods (`fn drop(self)`) now mark the receiver as consumed
  - if-without-else where the then-branch returns no longer blocks linear consumption in that branch
- **User-defined IntMap validated end-to-end**: a full hash map with fn pointer fields for hash/eq (same pattern as `HashMap`) compiles and runs correctly through the native compiler path, proving the linearity fix chain works.
- **Builtin HashMap interception retired**: ~1,400 lines of compiler-internal HashMap machinery deleted (7 intrinsic IDs, type checking/elaboration intercepts, LLVM wrapper functions, hand-written LLVM IR runtime with hash/probe/insert/get/contains/remove/grow for int and string keys, hardcoded 5-field struct type). HashMap is now an ordinary stdlib type compiled through the normal generic struct path. 6 new stdlib tests (4 HashMap, 2 HashSet) replace 11 deleted builtin-API tests. HashMap and HashSet are now in the collection verification section of the test runner.
- **Structured LLVM backend completed**: all backend emission now flows through structured `LLVMModule` data before printing. User functions, declarations, type definitions, globals, wrappers, test runner logic, vec builtins, and string/conversion builtins all emit through structured types; `rawSections` and the old `Concrete/Codegen/` backend path are gone.
- 600 tests pass (189 stdlib), including SSA structure verification, -O2 regressions for aggregate lowering paths, expanded stdlib module coverage, six linearity regression tests, native HashMap/HashSet coverage, and lli-accelerated test execution (~12s full suite).
- **Phase C completed**: all 8 items done:
  - module-targeted stdlib testing (`--stdlib-module <name>` runs tests for a single stdlib module)
  - diagnostics/formatter polish (empty `{}` edge case, deprecation fixes, compiler warnings eliminated)
  - integration testing deepened: `report_integration.con` (all 6 report modes) + `integration_collection_pipeline.con` (multi-collection pipeline with Vec, generics, enums, allocation patterns)
  - report assertions hardened: 44 report tests with content checks across all 6 modes (caps, unsafe, layout, interface, mono, alloc)
  - reports as audit product: capability "why" traces showing which callees contribute each cap, trust boundary analysis showing what trusted functions wrap, allocation/cleanup summaries with leak warnings, summary totals and aligned columns across all reports
- 600 tests pass (189 stdlib), including 44 report assertions, 46 golden tests, integration tests, and 16 collections verified.

### Now

Phases A, B, and C are done. Phase D is active. The compiler has a working stdlib, module-targeted testing, hardened reports (6 modes with why-traces, trust boundaries, allocation tracking), a fully structured LLVM backend, and 600 tests passing. Active work is backend and trust multipliers.

1. Push the backend/artifact/proof stack (Phase D):
   - problem: the structured backend is now in place, but the SSA/backend contract still needs tightening, pipeline artifacts are not yet doing enough real work, and the proof-facing validated-Core path is still more described than implemented
   - why now: the structured backend win removes the biggest backend-shape blocker, so Phase D can now focus on contract strength, artifact reuse, and the first real Lean 4 proof workflow for selected Concrete functions
   - primary surfaces: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PASSES.md](docs/PASSES.md), [Concrete/SSAVerify.lean](/Users/unbalancedparen/projects/concrete/Concrete/SSAVerify.lean), [Concrete/SSACleanup.lean](/Users/unbalancedparen/projects/concrete/Concrete/SSACleanup.lean), [Concrete/EmitSSA.lean](/Users/unbalancedparen/projects/concrete/Concrete/EmitSSA.lean), [Concrete/Pipeline.lean](/Users/unbalancedparen/projects/concrete/Concrete/Pipeline.lean)
   - first slices:
     - record the fully structured backend conversion as landed in the roadmap/changelog/docs
     - strengthen SSA/backend contract
     - turn explicit pipeline artifacts into reusable tooling/caching building blocks
     - make `ValidatedCore` explicit in `Concrete/Pipeline.lean` rather than leaving it only as a documented post-`CoreCheck` boundary
     - make validated Core a first-class proof-oriented artifact boundary after `CoreCheck` and before `Mono`
     - preserve source-to-Core traceability well enough that selected functions can later be understood and proved in Lean
     - stage the user-program proof workflow explicitly:
       - formalize a small pure Core fragment
       - define ProofCore as a restricted, proof-oriented view of validated Core rather than a separate rival semantic IR
       - manually embed selected Concrete functions against that Core
       - prove first concrete examples
       - only later add export/tooling for Lean-side proof workflows
     - push formalization over Core → SSA
   - constraints:
     - keep SSA as the only backend boundary
     - do not add another backend family until the LLVM path is structurally cleaner
     - treat MLIR as a later optional backend family, not the default immediate answer
     - once the structured LLVM path and SSA contract are solid, evaluate MLIR deliberately as a potential replacement or additional backend family rather than as an early escape hatch
   - done means: `ValidatedCore` is a named, explicit artifact in the pipeline rather than only a documented conceptual boundary, the backend consumes a structured contract over SSA, pipeline artifacts support reuse, and the first real Lean 4 proof workflow exists for selected Concrete functions over validated Core

### Phase A Notes

Phase A is done enough for the roadmap.

- The fast runner is the standard developer path: `./run_tests.sh` for edit-test, `./run_tests.sh --full` before merge.
- Aggregate lowering and merge transport are mechanically defended by `SSAVerify`.
- Remaining testing improvements are no longer Phase A blockers; the larger wins now live under later stdlib-aware and artifact-aware testing work.

### Compiler Excellence Order

The compiler-improvement order should stay:

1. speed up the edit-test loop so compiler work can iterate quickly
2. finish hardening lowering around mutable-state storage identity and aggregate merge transport after the core stable-storage fix
3. remove remaining string-based semantic dispatch from ordinary language behavior
4. strengthen the SSA verifier/cleanup boundary into a clearer backend contract
5. replace textual LLVM emission with a structured backend
6. only then expand toward backend plurality, deeper caching/incrementality, and more ambitious tooling reuse

This is the highest-leverage path for turning the current compiler into a stable long-term project rather than just a working bootstrap.
If there is a tradeoff between starting a deeper compiler refactor and first making the local test loop materially faster, prefer the faster test loop unless the refactor is needed to unblock basic correctness.

### Execution Phases

#### Phase A: Fast Feedback And Compiler Stability

Goal: make the current pipeline fast to iterate on, boring, and hard to break.
Order inside this phase matters: first improve the local development loop, then use that faster loop to finish lowering hardening and regression growth.

Primary surfaces:
- [docs/TESTING.md](docs/TESTING.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/PASSES.md](docs/PASSES.md)
- `run_tests.sh`
- `Concrete/Lower.lean`
- `Concrete/SSAVerify.lean`
- `Concrete/SSACleanup.lean`
- `Concrete/EmitSSA.lean`
- `lean_tests/`

1. make common test paths materially faster through safer parallelization and narrower runner modes
2. finish hardening aggregate lowering for mutable aggregates and borrows after the core stable-storage promotion change
3. keep shrinking accidental aggregate transport at loops and non-loop merge points where stable storage identity is the real semantic model
4. add optimized-build regressions and stdlib coverage for borrow+aggregate cases, including non-loop merge paths
5. tighten SSA invariants around these lowering patterns and the promoted-storage path

Deliverables:
- a standard fast local workflow that does not require the serial full suite
- hardened aggregate lowering behavior for loops, if/else merges, and match merges
- optimized-build regression coverage for the backend-sensitive lowering paths
- verifier-enforced SSA invariants for promoted aggregate storage and merge transport

Exit criterion:
ordinary development no longer depends on a slow serial full-suite loop, and there are no known backend-sensitive failures in mutable aggregate lowering or aggregate merge transport, including optimized-build stress cases.

#### Phase B: Semantic Cleanup — **done**

Goal: shrink compiler magic and make language meaning explicit.

**Exit criterion met:** no compiler pass changes behavior based on an ordinary public name through raw string matching.  All semantic dispatch rides on explicit identity types (`BuiltinTraitId`, `BuiltinEnumId`, `IntrinsicId`, `isEntryPoint`) or centralized constants in `Intrinsic.lean`.  Structural string handling (parser keywords, `Ty` type-name fields, mangling, LLVM naming, diagnostics) remains as tolerated implementation mechanics — further cleanup is opportunistic, not a blocker.

Key commits: d0b2f53, 4e557e0, daef46a, 40f1ce4.  See `Concrete/Intrinsic.lean` for the centralized identity definitions.

Landed deliverables:
- centralized semantic identity definitions in `Concrete/Intrinsic.lean`
- no ordinary-language behavior controlled by raw public-name string matching in compiler passes
- a clearer separation between real semantic identity and tolerated structural string mechanics

#### Phase C: Tooling And Stdlib Hardening — **done**

Goal: make the language usable and inspectable without destabilizing semantics.

**Exit criterion met:** syntax guardrails, diagnostics, stdlib testing, and audit reports behave like durable infrastructure. The LL(1) grammar checker runs in CI. Module-targeted stdlib testing is real (`--stdlib-module <name>`). Integration tests exercise multi-collection pipelines and all 6 report modes. Report outputs are regression-tested with 44 content assertions. Audit reports explain capability authority, trust boundaries, and allocation patterns through ordinary compiler workflows.

Primary surfaces:
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [docs/TESTING.md](docs/TESTING.md)
- `grammar/`
- `scripts/`
- `std/src/`
- `run_tests.sh`

Done:
1. LL(1) grammar checker in CI (Python, C, Rust implementations; runs in parallel with build)
2. linearity checker fixed for generic types (isCopyType, self-consumption, trusted loop relaxation, if-return divergence)
3. builtin HashMap interception retired (~1,400 lines deleted; HashMap is now an ordinary stdlib type)
4. module-targeted stdlib test infrastructure (`--stdlib-module <name>` in run_tests.sh)
5. diagnostics/formatter polish (empty `{}` edge case, deprecation fixes, compiler warnings eliminated)
6. integration testing: report_integration.con (all 6 report modes) + integration_collection_pipeline.con (multi-collection pipeline with allocation patterns)
7. report assertions hardened: 44 report tests covering caps/unsafe/layout/interface/mono/alloc with content checks (not just crash checks)
8. reports as audit product: capability "why" traces, trust boundary analysis, allocation/cleanup summaries, summary totals, aligned columns

Landed deliverables:
- LL(1) grammar checking as CI infrastructure
- module-targeted stdlib testing through the real compiler path
- an expanded integration/report test corpus with stable semantic assertions
- audit reports that explain capability authority, trust boundaries, and allocation behavior

Exit criterion:
syntax guardrails, diagnostics, and stdlib testing behave like durable infrastructure rather than one-off pushes.

#### Phase D: Backend And Trust Multipliers

Goal: make the compiler strong enough to support proofs, tooling reuse, and long-term backend work.

The first active Phase D pressure is now testing-system infrastructure. Phase C made testing credible; Phase D should make it materially smarter and faster by using compiler artifacts and dependency information instead of relying mostly on shell-level orchestration.

Testing is not just support work here. It should become a first-class compiler subsystem with explicit artifact boundaries, pass-level coverage, performance expectations, and determinism rules rather than growing only as a larger shell script plus more cases.

The current test infrastructure is good for a research-stage compiler, but its limits should stay explicit. The suite has breadth and the right broad categories, yet too much behavior still lives in a large shell script, too many semantic tests still pay full process/filesystem/codegen cost, report assertions still recompile the same programs repeatedly, and failure reproduction/isolation is weaker than it should be for a fast parallel workflow.

The bar for Phase D should be unusually high: not merely "good enough CI" or "lots of tests," but a testing system that feels best-in-class for a compiler project. That means the fastest credible feedback loop, the clearest explanation of what was tested and why, the cheapest path from change to affected coverage, the best failure isolation and reproduction story, and the strongest mix of end-to-end, pass-level, invariant, differential, and proof-adjacent validation that the project can realistically support.

Primary surfaces:
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/PASSES.md](docs/PASSES.md)
- [research/ten-x-improvements.md](research/ten-x-improvements.md)
- [research/formalization-roi.md](research/formalization-roi.md)
- `Concrete/Pipeline.lean`
- `Concrete/SSAVerify.lean`
- `Concrete/SSACleanup.lean`
- `Concrete/EmitSSA.lean`
- `Concrete/Report.lean`

1. turn explicit pipeline artifacts into reusable tooling/caching building blocks
   - use those artifacts as the foundation for artifact-aware test reuse, caching, and narrower rerun scopes
   - move test execution beyond shell-level filtering toward dependency-aware reruns
   - classify tests more clearly (`fast`, `unit`, `integration`, `optimization/regression`, `report/golden`, `slow/network/stress`) so local runs and CI can choose better defaults
   - make test classification real compiler metadata rather than only runner conventions
   - deliverables:
     - a documented artifact model for parse/Core/validated-Core/mono/SSA/report outputs with stable identity rules
     - a reusable cache key strategy tied to those artifacts rather than ad hoc runner behavior
     - a targeted-run path that can explain why a test was selected or skipped
     - explicit change-to-test mapping good enough that a developer can see which tests are affected by a file, pass, module, or report-mode change
2. make testing architecture a first-class subsystem
   - add pass-level Lean tests for `Check`, `Elab`, `Lower`, `SSAVerify`, and `EmitSSA` where end-to-end execution is unnecessary cost
   - define a clearer coverage matrix by failure mode (parser crash resistance, semantic regressions, lowering invariants, backend structure, runtime behavior, diagnostics, reports, stdlib behavior, optimization regressions)
   - add performance-regression tracking for compile time, suite time, and artifact reuse efficiency so "faster" stays defended rather than anecdotal
   - define determinism/flakiness policy explicitly (network isolation, seeds, timeouts, quarantine/repair expectations)
   - push test selection toward dependency- and ownership-aware scopes instead of string matching alone
   - deliverables:
     - a pass-level Lean test suite covering at least `Check`, `Elab`, `Lower`, `SSAVerify`, and `EmitSSA`
     - a written coverage matrix in `docs/TESTING.md`
     - a small benchmark set with recorded compile/test timing baselines
     - an explicit determinism/flakiness policy in `docs/TESTING.md`
     - per-test timing output and preserved failure artifacts for targeted debugging
     - a reproducible single-test rerun path for failures discovered under parallel execution
     - a lower-cost semantic-test path that avoids full compiler/codegen/process overhead when that cost is unnecessary
     - failure output that tells the developer what failed, how long it took, what artifacts were kept, and the exact rerun command
3. strengthen the SSA verifier/cleanup boundary into a clearer backend contract
   - deliverables:
     - a documented SSA contract naming what cleanup guarantees and what every backend may assume
     - verifier checks for the remaining backend-critical invariants that are still only convention
     - at least one backend-facing regression group tied directly to that contract
4. define a clearer FFI / ABI maturity path
   - decide what ABI stability, if any, is promised
   - decide what remains intentionally unstable for now
   - make platform-variance expectations explicit instead of accidental
   - add clearer verification/testing expectations for ABI compatibility
   - identify the first concrete cross-platform ABI/layout checks rather than leaving verification purely abstract
   - deliverables:
     - a written ABI/FFI maturity statement in the docs
     - an initial cross-platform layout/ABI verification matrix for the supported targets
5. grow a stronger real-program and invariant-testing corpus on top of the faster loop
   - add more nontrivial integration programs instead of only many small regressions
   - add more real multi-module programs instead of mostly single-file feature-pair exercises
   - deepen FFI/file/network integration beyond toy cases
   - keep expanding property/fuzz/differential coverage, especially around parser/formatter/report/IR invariants
   - deliverables:
     - a named integration corpus of real programs rather than only isolated regressions
     - explicit property/fuzz/differential suites with stable entrypoints
     - 2-3 real multi-module programs in the roughly 100-300 line range that combine multiple language features under realistic pressure
     - cached multi-assertion report testing so one compiler run can satisfy multiple report assertions against the same program
     - deeper integration coverage for FFI, file, and network behavior
     - at least one stress-style integration program large enough to act as a real compiler workload, not only a feature sampler
6. push formalization over Core -> SSA
   - treat validated Core after `CoreCheck` as the main proof boundary for user-program proofs
   - formalize a small pure Core fragment first
   - define a proof-oriented Core fragment as a restricted view of validated Core, not a separate semantic authority
   - validate the proof boundary with manual embeddings of selected functions
   - only then add compiler/export support for Lean-side proof workflows
   - treat "selected Concrete functions proved in Lean 4" as a core Phase D deliverable, not just a later research aspiration
   - deliverables:
     - `ValidatedCore` represented explicitly in `Concrete/Pipeline.lean`
     - a small formalized pure Core fragment in Lean
     - a first proof batch of selected Concrete functions over that boundary
7. add deferred audit/report outputs
   - deliverables:
     - the next report modes named explicitly before implementation starts
     - regression-tested report outputs with stable semantic assertions rather than brittle snapshots

Exit criterion:
backend work no longer feels fragile, proofs, reports, and tooling all build on the same stable compiler boundaries, targeted test runs are artifact-aware and dependency-aware, failures are easy to isolate and rerun, semantic tests avoid unnecessary full-pipeline cost, pass-level and end-to-end testing play distinct roles under explicit coverage/determinism rules, and selected Concrete functions can actually be proved in Lean 4 over validated Core.

#### Phase E: Runtime And Execution Model

Goal: make the language's execution model explicit instead of leaving runtime behavior and environment assumptions as a loose later concern.

This phase begins the high-integrity profile direction:

- explicit execution restrictions
- bounded/no-allocation modes
- analyzable concurrency constraints
- a runtime story that can later support critical-system use without pretending every feature belongs everywhere

Primary surfaces:
- [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)
- runtime-facing stdlib and FFI boundaries

1. define the hosted vs freestanding model more explicitly
   - decide what the language assumes from the OS, libc, allocator, and startup environment
2. make the runtime boundary explicit
   - allocator expectations
   - program startup / shutdown model
   - panic / abort / failure model
3. define the memory / allocation strategy explicitly
   - allocator model(s)
   - no-alloc / bounded-allocation story
   - region/arena patterns, if any
   - interaction between allocation, `Destroy`, capabilities, and reports
4. define the concurrency and execution story deliberately
   - decide whether threads, async, processes, or none of them are first-class language/runtime concerns
   - prefer analyzable concurrency constraints over unconstrained surface growth if Concrete is meant to serve critical systems later
5. tighten the FFI/runtime ownership boundary
   - make it clearer what ownership, destruction, and capability assumptions survive foreign boundaries
6. make runtime-related stdlib surfaces reflect the chosen execution model instead of growing opportunistically
7. define execution profiles for high-integrity use
   - make room for profiles such as `no_alloc`, bounded-allocation, or other explicitly restricted execution modes
   - keep these profiles aligned with the actual runtime and allocator model instead of bolting them on later

Deliverables:
- a documented hosted vs freestanding execution model
- a documented runtime boundary covering startup, shutdown, failure, and allocator expectations
- an explicit memory/allocation model including no-alloc or bounded-allocation profile direction
- a written concurrency/execution stance for the language/runtime
- a documented ownership/capability story across FFI/runtime boundaries
- runtime-facing stdlib surfaces aligned with the chosen execution model

Exit criterion:
Concrete has an explicit execution model that explains how programs start, allocate, fail, interact with the host, and cross runtime/FFI boundaries.

#### Phase F: Capability And Safety Productization

Goal: turn capability and trust features into a strong user-facing safety system, not just an internal language property.

This phase carries the safety side of the eventual high-integrity profile:

- stricter authority rules
- clearer limits around `Unsafe`, `trusted`, and FFI
- a safety story that remains usable in ordinary code but can also become stricter in higher-assurance modes

Primary surfaces:
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [Concrete/Report.lean](/Users/unbalancedparen/projects/concrete/Concrete/Report.lean)
- [research/authority-budgets.md](research/authority-budgets.md)
- [research/capability-sandboxing.md](research/capability-sandboxing.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)

1. improve capability and trust ergonomics
   - make capability requirements easier to understand, introduce, and audit
2. deepen capability/trust reporting
   - stronger "why" traces
   - clearer authority flow
   - better `trusted` / `Unsafe` visibility
3. add stronger patterns for explicit authority wrappers and capability aliases
   - keep open the later path to authority budgets that can limit what a module, package, or binary is allowed to require at all
4. make safety features easier to use correctly in ordinary programs without weakening honesty
5. ensure docs, diagnostics, and reports present one coherent safety story
6. define the shape of a high-integrity safety profile
   - decide how `Unsafe`, `trusted`, FFI, and ambient authority should be constrained in stricter code profiles
   - make the restrictions explicit enough that they can later support audit-heavy or critical-system use

Deliverables:
- clearer user-facing capability and trust ergonomics in diagnostics/docs/reports
- stronger report outputs for authority flow, `trusted`, and `Unsafe`
- explicit patterns for authority wrappers, aliases, and later authority-budget integration
- a documented high-integrity safety profile direction covering `Unsafe`, `trusted`, FFI, and ambient authority

Exit criterion:
Concrete's capability and trust model is not only sound in principle, but also understandable, auditable, and practical for users.

#### Phase G: Language Surface And Feature Discipline

Goal: keep the language small, coherent, and intentionally shaped instead of letting features accumulate opportunistically.

This phase is where an eventual critical/provable subset becomes a real language-design commitment instead of only a later hope.

Primary surfaces:
- [research/design-filters.md](research/design-filters.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- grammar docs and language references
- language-design research notes

1. define explicit feature-admission criteria
   - grammar cost
   - audit cost
   - proof cost
   - implementation complexity
2. make "no" and "not yet" decisions first-class language outcomes
3. revisit syntax and surface complexity with a bias toward simplification, not expansion
4. keep unsafe/trusted/foreign surface area as narrow as possible
5. make long-term language shape decisions explicit instead of letting them emerge from local convenience
6. define a clearly analyzable critical/provable subset if Concrete is going to target higher-integrity domains
   - make the subset explicit rather than leaving it as an accidental intersection of current features
   - treat contracts and richer proof annotations as optional later research, not a required part of the language philosophy

Deliverables:
- explicit feature-admission criteria used as a standing design filter
- a documented set of first-class "no" and "not yet" language decisions
- a reviewed language-surface simplification pass where needed
- a documented analyzable critical/provable subset if Concrete continues toward higher-integrity domains

Exit criterion:
Concrete has an explicit discipline for preserving a small, coherent language surface and resisting low-leverage feature growth.

#### Phase H: Package And Dependency Ecosystem

Goal: make Concrete usable for real multi-module and multi-package projects with explicit, stable project-facing semantics.

For serious use, this phase is unavoidable. High-integrity or proof-oriented code still needs a clean project model, dependency semantics, and workspace behavior that are explicit rather than ad hoc.

Primary surfaces:
- [research/authority-budgets.md](research/authority-budgets.md)
- project/package metadata
- import resolution and project-root semantics
- stdlib vs third-party package boundaries
- workspace and dependency tooling

1. define the package and dependency model explicitly
   - import/package resolution model for real projects
   - dependency/version semantics
2. define stdlib vs third-party package boundaries
   - what is special, what is ordinary, and what is versioned how
3. define workspace and multi-package behavior
   - roots, workspaces, local dependencies, and expected project layouts
4. make dependency and package UX part of the language-user experience rather than a repo-local convention
   - include package- or subsystem-level authority budgets so dependencies can be checked against declared capability limits
5. ensure docs, tooling, and CI reflect the same package/project model

Deliverables:
- a documented package/dependency model with project-root and resolution semantics
- a defined boundary between stdlib and third-party packages
- a documented workspace/multi-package model
- dependency/package tooling and CI behavior aligned with the same model
- an authority-budget path at package or subsystem boundaries

Exit criterion:
Concrete has an explicit package/dependency model that supports real projects without relying on ad-hoc repo-local conventions, and it has a credible path to enforcing authority budgets at package or subsystem boundaries.

#### Phase I: Project And Operational Maturity

Goal: turn Concrete from a strong compiler project into a durable, distributable, maintainable system.

This phase is where the evidence story becomes operational:

- maintained editor/tooling surfaces
- reproducible and reviewable outputs
- explicit compatibility policy
- certification-style traceability between source, reports, proofs, and builds

Primary surfaces:
- [README.md](README.md)
- [docs/README.md](docs/README.md)
- [research/proof-evidence-artifacts.md](research/proof-evidence-artifacts.md)
- CI config
- release/build tooling
- project/package metadata
- editor/tool integration surfaces

1. make the project and package model operationally solid
   - define how projects, dependencies, roots, and standard-library integration are expected to work in ordinary use
2. add release and compatibility discipline
   - decide what compatibility promises exist for language, stdlib, reports, and tooling surfaces
   - make breaking changes deliberate instead of ambient
3. harden reproducibility and CI operations
   - keep builds and tests reproducible enough to trust failures
   - make CI/reporting workflows clear, boring, and maintainable
4. make the distribution and installation story explicit
   - document and streamline how users obtain, build, and run Concrete
   - reduce dependence on repo-local tribal knowledge
5. turn docs and editor/tool integration into maintained product surfaces
   - keep top-level docs coherent with the actual workflow
   - decide whether editor/LSP support is a serious maintained goal and what minimum UX is expected for navigation, diagnostics, formatting, and reports
   - define the minimum supported editor/tooling baseline even before full LSP exists
6. add explicit compatibility and bootstrap-trust policy
   - decide what can break freely now and what should stabilize first
   - state whether reports/tooling/IRs have compatibility expectations
   - decide whether self-hosting is a goal, whether diverse-double-compilation/bootstrap trust matters, and how far reproducibility should go
7. make certification-style evidence and traceability practical where it fits Concrete's identity
   - tie source, reports, proofs, and build artifacts together clearly enough for high-integrity review workflows
   - prefer explicit evidence and traceability over process folklore

Deliverables:
- a documented release and compatibility policy for language, stdlib, reports, and tooling surfaces
- reproducible build/test/CI expectations that are operationally maintained
- an explicit distribution and installation story
- maintained baseline docs and editor/tooling expectations
- an explicit bootstrap-trust and compatibility policy
- a practical evidence/traceability story linking source, reports, proofs, and build artifacts

Exit criterion:
Concrete is not only architecturally strong internally, but also operable, reproducible, documentable, and maintainable as a long-term project.

### Why These Phases Matter

- **Phase A** matters because a slow feedback loop drags down every compiler task, and backend-sensitive lowering bugs destroy trust in every other part of the compiler.
- **Phase B** matters because a compiler is much easier to trust, prove, and maintain when ordinary names stay ordinary.
- **Phase C** matters because syntax guardrails, diagnostics, and testing infrastructure are what make a compiler sustainable instead of heroic.
- **Phase D** matters because this is where Concrete stops being only a working compiler and becomes a trustworthy compiler platform.
- **Phase E** matters because a language is not really settled until its execution model is explicit.
- **Phase F** matters because Concrete's safety model should be a user-visible strength, not only an internal design claim.
- **Phase G** matters because languages decay when feature growth has no explicit discipline.
- **Phase H** matters because package and dependency semantics are part of the language experience once real projects exist.
- **Phase I** matters because long-term projects fail just as easily from weak operational discipline as from weak compiler architecture.

### Next

1. Turn testing from shell-level fast paths into artifact-aware, dependency-aware execution.
   - reuse compiler artifacts instead of recompiling/rerunning unnecessarily
   - rerun only the scopes actually affected by a change instead of relying only on string filters
   - classify tests more clearly (`fast`, `unit`, `integration`, `optimization/regression`, `report/golden`, `slow/network/stress`) so local runs and CI can choose smarter defaults
2. Grow a stronger real-program and invariant-testing corpus on top of that faster loop.
   - add more nontrivial integration programs instead of only many small regressions
   - keep expanding property/fuzz/differential coverage, especially around parser/formatter/report/IR invariants
3. Strengthen the SSA verifier/cleanup boundary into a clearer backend contract.
   - make the SSA/backend interface explicit enough for backend plurality later
   - turn SSA verification into a contract that any backend can rely on
5. Push formalization over the cleaned Core -> SSA architecture.
   - prioritize proof targets that directly depend on the compiler architecture cleanup: Core soundness, capability discipline, linearity/resource soundness, and Core -> SSA preservation
   - stage the user-program proof workflow explicitly: validated Core after `CoreCheck` as proof boundary, small pure ProofCore fragment, manual embedding of selected functions, first concrete proofs, later export/tooling
6. Turn explicit pipeline artifacts into stronger tooling/caching building blocks.
   - keep artifact boundaries explicit and inspectable
   - move toward serialization/caching only on top of already boring pass contracts
   - use explicit artifacts to enable better test reuse and narrower recompilation
7. Prepare for eventual Lean-side proof of selected Concrete functions by keeping Core semantics small, explicit, and suitable as the proof boundary.
   - keep the proof boundary after `CoreCheck` and before `Mono`
   - treat ProofCore as a restricted view of validated Core rather than a second semantic IR
8. Preserve a small set of long-horizon differentiator ideas in research without turning them into immediate roadmap thrash.
   - first-class audit mode and authority tracing
   - proof-carrying reports and proof-oriented module contracts
   - verified FFI envelopes
   - reproducible trust bundles
   - keep richer contracts and invariants in research until it is clear they fit Concrete's philosophy instead of assuming they belong on the main roadmap

### Later

1. Backend plurality over SSA, but only after the current backend becomes structurally cleaner first.
2. Runtime and execution-model maturity as an explicit phase once the compiler/tooling architecture is stable enough to support it well.
3. Capability and safety productization as an explicit phase after the backend/trust foundations are strong enough.
4. Language-surface and feature-discipline work as an explicit phase once the runtime/safety direction is clear.
5. Package and dependency ecosystem as an explicit phase once stdlib/tooling/runtime direction is stable enough to support real projects well.
6. Project and operational maturity as an explicit phase once the current compiler/tooling architecture is stable enough to productize.
7. Proof-driven narrowing of future feature additions.
8. A clearer hosted vs freestanding / `no_std` split, but only after the runtime and stdlib boundaries are more stable.
9. Execution-cost analysis as an audit/report extension.
   - structural boundedness reports first
   - abstract cost estimation later
   - never at the cost of clarity in the core language
10. Lean-side proof of selected Concrete functions over formalized Core, starting with pure fragments rather than raw surface syntax or FFI-heavy code.
11. Potential later expansion of the Lean proof story, but only after the narrow Core-based workflow works cleanly.
   - later broaden selected-function proofs toward effects, resources, capabilities, runtime interaction, and only then concurrency
   - later consider backend-level proof concerns such as richer compiler-preservation work across deeper lowering stacks or optional backend-family layers
   - do not treat either broader end-to-end program proofs or backend/MLIR-layer proof work as near-term substitutes for the validated-Core-first plan
12. Treat contracts, richer invariants, and similar verification extensions as post-roadmap evaluation work, not as part of the main current philosophy.
   - only evaluate them after the simpler Concrete + Lean 4 proof story has proven insufficient
   - keep them out of the main phase plan until the core language, proof boundary, runtime model, and operational story are already stable
   - if adopted at all, treat them as a final optional verification-extension stage rather than as a prerequisite for the main roadmap
13. Implement a real artificial-life showcase/stress-test in Concrete.
   - target a program in the spirit of Rabrg's `artificial-life` reproduction of "Computational Life: How Well-formed, Self-replicating Programs Emerge from Simple Interaction"
   - a 240x135 grid of 64-instruction Brainfuck-like programs, randomly initialized, locally paired, concatenated, executed for bounded steps, then split back apart
   - use it as a serious end-to-end stress test for runtime/performance, collections/buffers, formatting/reporting, and later proof/audit ambitions
   - treat it as a showcase workload once the runtime, stdlib, and backend are mature enough rather than as immediate Phase C compiler work

## Backend Work Order

Backend work should happen in this order:

1. Replace direct LLVM IR text emission with a structured LLVM backend.
2. Make backend plurality explicit over the SSA boundary.
3. Only then evaluate additional backend families such as C or Wasm.
4. Treat MLIR as optional and only if it still earns its complexity after the SSA/backend-contract cleanup.
5. Once the SSA contract and artifact story are solid, evaluate whether MLIR should remain optional, become a sibling backend family, or replace the direct LLVM path for some stages.

The immediate backend problem is stringly LLVM emission, not lack of MLIR.

## Not Yet

The roadmap should also constrain what not to do before prerequisites are stable:

- do not add backend plurality before the SSA/backend-contract work is done
- do not treat MLIR as the immediate answer to the current backend problem
- do not add major runtime/concurrency surface area before compiler/backend boundaries are more stable
- do not add surface features that increase grammar cost, audit cost, or proof cost without clear leverage
- do not grow parallel semantic lowering paths for convenience
- do not let ordinary public names regain compiler-known meaning through ad-hoc string matching
- do not parallelize test execution in ways that make failures non-reproducible or hide ordering/resource bugs

These are not style preferences. They are project-protection rules.

## Implementation Rule

For any roadmap item:

1. start from the phase and item description here
2. use the linked docs in that phase as the semantic/reference authority
3. inspect the listed code surfaces before changing behavior
4. preserve the phase ordering unless there is an explicit dependency reason to do otherwise

If a task needs detailed current semantics, the docs and code own that detail; the roadmap owns ordering, priorities, and completion criteria.

## Longer-Horizon Multipliers

These are not the immediate implementation queue, but they remain some of the highest-leverage ways to make Concrete unusually strong for safety-, security-, and audit-focused low-level work.

1. **Proof-backed trust claims**
   - prove effect/capability honesty
   - prove ownership/linearity soundness
   - prove `trusted` / `Unsafe` honesty
   - prove Core -> SSA preservation
2. **Stronger audit outputs**
   - why a capability is required
   - where allocation happens
   - where cleanup/destruction happens
   - where `trusted` enters
   - what layout/ABI a type actually has
3. **A smaller trusted computing base**
   - keep shrinking compiler-known builtins
   - keep moving user-facing behavior into stdlib traits and ordinary code
   - keep trust boundaries explicit and grep-able
4. **A better capability/sandboxing story**
   - stronger capability reports
   - better "why" traces
   - capability aliases
   - explicit authority wrappers
   - later, a cleaner hosted vs freestanding split

For more on these longer-horizon themes, see:
- [research/ten-x-improvements.md](research/ten-x-improvements.md)
- [research/capability-sandboxing.md](research/capability-sandboxing.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)

## Status Legend

- **Done**: implemented and no longer on the active roadmap.
- **Done enough**: complete for the current architecture phase, though refinement is still possible later.
- **Active**: current roadmap work.
- **Deferred**: intentionally postponed until prerequisites are stable.
- **Research**: explored in docs/research but not yet roadmap-committed.

## Dependency Notes

- Stdlib growth depends on the current artifact boundaries, layout subsystem, and diagnostics staying stable.
- Formalization depends on keeping Core and SSA as the clear semantic and backend boundaries.
- Tooling and caching quality depend on explicit reusable artifacts rather than pass-local reconstruction.
- Multi-backend work is deferred until the SSA boundary stays boring and shared.
- Loop lowering should preserve stable storage identity for mutable aggregate state instead of normalizing everything into whole-aggregate SSA transport.
- The new promoted-storage path for aggregate loop variables is the preferred architecture; follow-up work should harden and extend it rather than reintroducing aggregate transport by convenience.
- Runtime work should not pull frontend semantics or stdlib design into premature complexity.

## Current Risks

- the SSA/backend contract is still weaker than the newly structured backend deserves
- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete or SSA invariants are too weak
- tooling/caching work can regress into ad-hoc duplication if artifacts stop being explicit and reusable
- formalization has not started; the proof boundary exists architecturally but no proofs are written yet

## Current Design Constraints

These are current choices that should continue constraining future work unless explicitly revisited elsewhere:

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over whole-aggregate `phi` transport
- avoid reintroducing parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable
- prefer boring artifact boundaries over clever implicit compiler coupling

## Summary

Concrete has a complete compiler pipeline, a real stdlib (33 modules, 16 collections), module-targeted testing (600 tests, 189 stdlib), a fully structured LLVM backend, and audit reports that explain capability authority, trust boundaries, and allocation patterns. Phases A-C are done. The main unfinished work is now Phase D: strengthening the SSA/backend contract, making artifacts do more real work, and pushing formalization over the validated Core boundary.
