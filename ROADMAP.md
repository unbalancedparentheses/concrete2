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
- a structured non-string LLVM backend
- backend plurality over SSA (for example C / Wasm, and later maybe MLIR)
- kernel formalization
- a runtime
- fully authoritative standalone resolution

## Priority Snapshot

### Milestones

| Phase | Focus | Status | Blocks |
|------|-------|--------|--------|
| **A** | Fast feedback and compiler stability | Done enough; aggregate lowering hardened, test runner parallelized, SSA invariants mechanically defended | B, C, D |
| **B** | Semantic cleanup | Active | D |
| **C** | Tooling and stdlib hardening | Active | later system maturity |
| **D** | Backend and trust multipliers | Pending | A, most of B |
| **E** | Runtime and execution model | Deferred | C, D |
| **F** | Capability and safety productization | Deferred | D, E |
| **G** | Language surface and feature discipline | Deferred | B, D, E, F |
| **H** | Project and operational maturity | Deferred | C, D, E, F, G |

### Recent Progress

- **Test runner parallelized and narrowed** (commits `1619220`, `6049d89`): `run_tests.sh` defaults to parallel (`nproc` cores), adds `--fast` (default), `--full`, `--filter`, `--stdlib`, `--O2`, `--codegen`, `--report` modes. Partial runs warn clearly. `--fast` is the documented standard developer workflow. This is a strong Phase A solution, but it is still script-level orchestration rather than a deeper artifact-cached or dependency-aware test system.
- **Aggregate loop lowering hardened** (commit `e68acc0`): aggregate loop variables promoted to entry-block allocas. Field assignment GEPs directly into stable storage.
- **Aggregate if/else and match lowering hardened** (commit `8e606d9`): if/else branches with modified struct variables merge via entry-block allocas instead of `phi %Struct`. Match arms get var snapshot/restore between arms. Void-typed match results filtered from phi/store paths.
- **SSA verifier now rejects aggregate phi nodes**: `SSAVerify.lean` checks that no phi node carries an aggregate type (struct, enum, string, array). This is a mechanical invariant, not just regression coverage.
- **Audit**: all phi emission sites in Lower.lean confirmed to check `isAggregateForPromotion` before creating phi nodes. No remaining accidental aggregate transport found.
- 521 tests pass (0 failures), including SSA structure verification and -O2 regressions for all aggregate lowering paths.

### Now

This list is ordered to match the active execution phases: Phase A is done enough, so active work now starts in Phase B, then Phase C, then the front edge of Phase D.

1. Finish tightening the builtin-vs-stdlib boundary.
   - problem: remaining string-based semantic dispatch still makes ordinary names carry compiler meaning and expands the trusted computing base
   - why now: Phase A is complete enough to stop dominating roadmap pressure; Phase B starts by shrinking semantic magic
   - primary surfaces: [research/builtin-vs-stdlib.md](research/builtin-vs-stdlib.md), [Concrete/Intrinsic.lean](/Users/unbalancedparen/projects/concrete/Concrete/Intrinsic.lean), [Concrete/BuiltinSigs.lean](/Users/unbalancedparen/projects/concrete/Concrete/BuiltinSigs.lean), [Concrete/Check.lean](/Users/unbalancedparen/projects/concrete/Concrete/Check.lean), [Concrete/Elab.lean](/Users/unbalancedparen/projects/concrete/Concrete/Elab.lean), [Concrete/CoreCheck.lean](/Users/unbalancedparen/projects/concrete/Concrete/CoreCheck.lean), [Concrete/EmitSSA.lean](/Users/unbalancedparen/projects/concrete/Concrete/EmitSSA.lean)
   - first slices:
     - keep builtins minimal, compiler/runtime-facing, and explicitly non-user-facing
     - remove remaining string-based semantic dispatch in compiler tables, pass-local special cases, and backend helper selection
     - make ordinary language behavior depend on internal identities or explicit language items, not raw function-name matching
     - keep stringly handling confined to true foreign-symbol, linker-symbol, or user-facing report/rendering boundaries
     - keep improving testing ergonomics where it directly speeds semantic-cleanup work, but treat deeper artifact-aware testing as later infrastructure rather than a blocker for Phase B
     - keep the stdlib bytes-first and low-level rather than letting string-heavy convenience APIs dominate the surface
   - constraints:
     - any compiler rule that changes semantics based on an ordinary public name is architecture debt
     - do not move user-facing convenience back into compiler builtins
   - done means: ordinary public names no longer carry compiler-known semantics through raw matching
2. Add an external LL(1) grammar checker as a standing syntax guardrail.
   - problem: the language claims LL(1) discipline, but parser regressions can still slip in without a dedicated grammar guardrail
   - why now: this is the first Phase C tool that protects the language shape without destabilizing semantics
   - primary surfaces: [research/external-ll1-checker.md](research/external-ll1-checker.md), `grammar/`, `scripts/`, CI config
   - first slices:
     - add a compact reference grammar at `grammar/concrete.ebnf`
     - add a small checker at `scripts/check_ll1.py`
     - put it in CI
     - treat parser-state rewind/backtracking regressions as bugs
   - constraints:
     - keep the checker external and simple enough to audit
     - do not let the reference grammar drift away from the actual parser unnoticed
   - done means: syntax regressions trip a dedicated CI check instead of silently re-entering the parser
3. Keep deepening and hardening the stdlib.
   - problem: stdlib breadth is real now, but systems modules still need stronger failure-path behavior, consistency, and targeted test workflows
   - why now: once Phase A and Phase B stop dominating every change, stdlib quality becomes the main usability multiplier
   - primary surfaces: [docs/STDLIB.md](docs/STDLIB.md), [std/src/](/Users/unbalancedparen/projects/concrete/std/src), [run_tests.sh](/Users/unbalancedparen/projects/concrete/run_tests.sh)
   - first slices:
     - deepen `fs`, `net`, and `process`
     - add more failure-path and integration tests
     - keep error, handle, and checked/unchecked conventions uniform
     - add stdlib-aware module-targeted test infrastructure instead of relying only on `std/src/lib.con --test`
   - constraints:
     - do not let API growth outrun failure-path coverage
     - do not let module conventions drift case-by-case
   - done means: systems modules have stronger failure-path coverage and stdlib tests can target one area without bootstrapping the whole tree
4. Improve diagnostics fidelity and rendering quality.
   - problem: diagnostics still lose precision around transformed constructs and rely too much on brittle string-exact expectations
   - why now: diagnostics are the main user-visible quality multiplier once the compiler architecture is stable enough to trust
   - primary surfaces: [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [Concrete/Diagnostic.lean](/Users/unbalancedparen/projects/concrete/Concrete/Diagnostic.lean), [Concrete/Check.lean](/Users/unbalancedparen/projects/concrete/Concrete/Check.lean), [Concrete/CoreCheck.lean](/Users/unbalancedparen/projects/concrete/Concrete/CoreCheck.lean), diagnostic tests
   - first slices:
     - better range precision
     - notes and secondary labels
     - clearer presentation for transformed constructs
     - reduce brittle string-matched report/test coupling where structured checks are possible
   - constraints:
     - do not make tests depend on full rendered strings when structured assertions can work
     - do not improve rendering by smearing away the actual semantic source location
   - done means: diagnostics quality improvements are visible in ordinary compiler output, not only in internal plumbing
5. Preserve SSA as the only backend boundary and keep the build/project model explicit and boring.
   - problem: textual LLVM emission is still a brittle choke point, and backend plurality would multiply instability if the backend contract stays loose
   - why now: this is the front edge of Phase D and the prerequisite for serious backend, tooling, and proof leverage
   - primary surfaces: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PASSES.md](docs/PASSES.md), [Concrete/SSAVerify.lean](/Users/unbalancedparen/projects/concrete/Concrete/SSAVerify.lean), [Concrete/SSACleanup.lean](/Users/unbalancedparen/projects/concrete/Concrete/SSACleanup.lean), [Concrete/EmitSSA.lean](/Users/unbalancedparen/projects/concrete/Concrete/EmitSSA.lean), [Concrete/Pipeline.lean](/Users/unbalancedparen/projects/concrete/Concrete/Pipeline.lean)
   - first slices:
     - replace raw LLVM string emission with a structured LLVM backend before adding backend plurality
     - keep target-specific work behind an explicit backend abstraction over SSA
     - treat MLIR as a later optional backend family, not the default immediate answer
   - constraints:
     - keep SSA as the only backend boundary
     - do not add another backend family until the LLVM path is structurally cleaner
   - done means: the backend consumes a structured contract over SSA and textual LLVM concatenation is no longer the critical path

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

Exit criterion:
ordinary development no longer depends on a slow serial full-suite loop, and there are no known backend-sensitive failures in mutable aggregate lowering or aggregate merge transport, including optimized-build stress cases.

#### Phase B: Semantic Cleanup

Goal: shrink compiler magic and make language meaning explicit.

Primary surfaces:
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [research/builtin-vs-stdlib.md](research/builtin-vs-stdlib.md)
- `Concrete/Intrinsic.lean`
- `Concrete/BuiltinSigs.lean`
- `Concrete/Check.lean`
- `Concrete/Elab.lean`
- `Concrete/CoreCheck.lean`
- `Concrete/EmitSSA.lean`

1. remove remaining string-based semantic dispatch
2. make compiler-known behavior ride on explicit identities or language items
3. keep raw string matching confined to foreign/linker/reporting boundaries
4. finish builtin-vs-stdlib boundary cleanup
5. allow tactical testing improvements only when they directly accelerate semantic-cleanup work

Exit criterion:
ordinary language behavior is no longer keyed off raw public names.

#### Phase C: Tooling And Stdlib Hardening

Goal: make the language usable and inspectable without destabilizing semantics.

Primary surfaces:
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [docs/TESTING.md](docs/TESTING.md)
- `grammar/`
- `scripts/`
- `std/src/`
- `run_tests.sh`

1. add the external LL(1) grammar checker and CI coverage
2. improve diagnostics fidelity and presentation
3. build module-targeted stdlib test infrastructure
4. turn the current fast runner into proper long-term testing infrastructure
   - module-aware and subsystem-aware entrypoints instead of only shell-level filtering
   - stdlib-aware targeted execution under an explicit module/project context
   - clearer visibility into what partial runs did and did not exercise
   - narrower recompilation and rerun scopes driven by explicit dependencies rather than ad-hoc script sections
   - treat the current fast runner as the practical Phase A baseline, not the end-state architecture for testing
5. deepen failure-path and integration testing in systems modules
6. make report assertions part of ordinary hardening

Exit criterion:
syntax guardrails, diagnostics, and stdlib testing behave like durable infrastructure rather than one-off pushes.

#### Phase D: Backend And Trust Multipliers

Goal: make the compiler strong enough to support proofs, tooling reuse, and long-term backend work.

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

1. strengthen the SSA verifier/cleanup boundary into a clearer backend contract
2. replace raw LLVM text emission with a structured backend
3. turn explicit pipeline artifacts into reusable tooling/caching building blocks
   - use those artifacts as the foundation for later test reuse, caching, and narrower rerun scopes
4. push formalization over Core -> SSA
5. add deferred audit/report outputs

Exit criterion:
backend work no longer feels fragile, and proofs, reports, and tooling all build on the same stable compiler boundaries.

#### Phase E: Runtime And Execution Model

Goal: make the language's execution model explicit instead of leaving runtime behavior and environment assumptions as a loose later concern.

Primary surfaces:
- [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)
- runtime-facing stdlib and FFI boundaries

1. define the hosted vs freestanding model more explicitly
   - decide what the language assumes from the OS, libc, allocator, and startup environment
2. make the runtime boundary explicit
   - allocator expectations
   - program startup / shutdown model
   - panic / abort / failure model
3. define the concurrency and execution story deliberately
   - decide whether threads, async, processes, or none of them are first-class language/runtime concerns
4. tighten the FFI/runtime ownership boundary
   - make it clearer what ownership, destruction, and capability assumptions survive foreign boundaries
5. make runtime-related stdlib surfaces reflect the chosen execution model instead of growing opportunistically

Exit criterion:
Concrete has an explicit execution model that explains how programs start, allocate, fail, interact with the host, and cross runtime/FFI boundaries.

#### Phase F: Capability And Safety Productization

Goal: turn capability and trust features into a strong user-facing safety system, not just an internal language property.

Primary surfaces:
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [Concrete/Report.lean](/Users/unbalancedparen/projects/concrete/Concrete/Report.lean)
- [research/capability-sandboxing.md](research/capability-sandboxing.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)

1. improve capability and trust ergonomics
   - make capability requirements easier to understand, introduce, and audit
2. deepen capability/trust reporting
   - stronger "why" traces
   - clearer authority flow
   - better `trusted` / `Unsafe` visibility
3. add stronger patterns for explicit authority wrappers and capability aliases
4. make safety features easier to use correctly in ordinary programs without weakening honesty
5. ensure docs, diagnostics, and reports present one coherent safety story

Exit criterion:
Concrete's capability and trust model is not only sound in principle, but also understandable, auditable, and practical for users.

#### Phase G: Language Surface And Feature Discipline

Goal: keep the language small, coherent, and intentionally shaped instead of letting features accumulate opportunistically.

Primary surfaces:
- [research/design-filters.md](research/design-filters.md)
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

Exit criterion:
Concrete has an explicit discipline for preserving a small, coherent language surface and resisting low-leverage feature growth.

#### Phase H: Project And Operational Maturity

Goal: turn Concrete from a strong compiler project into a durable, distributable, maintainable system.

Primary surfaces:
- [README.md](README.md)
- [docs/README.md](docs/README.md)
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
   - decide the expected level of editor/LSP/tool support instead of leaving it accidental

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
- **Phase H** matters because long-term projects fail just as easily from weak operational discipline as from weak compiler architecture.

### Next

1. Push formalization over the cleaned Core -> SSA architecture.
   - prioritize proof targets that directly depend on the compiler architecture cleanup: Core soundness, capability discipline, linearity/resource soundness, and Core -> SSA preservation
2. Add deferred audit/report outputs such as allocation summaries and cleanup/destruction reports.
3. Keep diagnostics converging on one high-quality surface across compiler modes.
4. Turn the testing strategy into durable infrastructure.
   - keep fuzz/property/trace/report/differential tests alive in CI
   - grow the regression corpus from real bugs
   - make report assertions part of ordinary compiler hardening
   - keep pushing beyond shell-level orchestration toward artifact-aware reuse once the explicit pipeline-artifact work is ready
5. Turn explicit pipeline artifacts into stronger tooling/caching building blocks once the current architecture cleanup settles.
   - keep artifact boundaries explicit and inspectable
   - move toward serialization/caching only on top of already boring pass contracts
   - let tooling consume the same compiler facts rather than growing parallel ad-hoc models
   - use explicit artifacts to enable better test reuse and narrower recompilation instead of keeping all fast paths inside shell orchestration
6. Prepare for the eventual runtime, safety, language-discipline, and operational-maturity phases by keeping package/build/docs/runtime decisions explicit instead of accidental.

### Later

1. Backend plurality over SSA, but only after the current backend becomes structurally cleaner first.
2. Runtime and execution-model maturity as an explicit phase once the compiler/tooling architecture is stable enough to support it well.
3. Capability and safety productization as an explicit phase after the backend/trust foundations are strong enough.
4. Language-surface and feature-discipline work as an explicit phase once the runtime/safety direction is clear.
5. Project and operational maturity as an explicit phase once the current compiler/tooling architecture is stable enough to productize.
6. Proof-driven narrowing of future feature additions.
7. A clearer hosted vs freestanding / `no_std` split, but only after the runtime and stdlib boundaries are more stable.
8. Execution-cost analysis as an audit/report extension.
   - structural boundedness reports first
   - abstract cost estimation later
   - never at the cost of clarity in the core language

## Backend Work Order

Backend work should happen in this order:

1. Replace direct LLVM IR text emission with a structured LLVM backend.
2. Make backend plurality explicit over the SSA boundary.
3. Only then evaluate additional backend families such as C or Wasm.
4. Treat MLIR as optional and only if it still earns its complexity after the LLVM/backend-boundary cleanup.

The immediate backend problem is stringly LLVM emission, not lack of MLIR.

## Not Yet

The roadmap should also constrain what not to do before prerequisites are stable:

- do not add backend plurality before the structured LLVM/backend-contract work is done
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

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete, non-loop aggregate merge transport remains too broad, optimized-build coverage is too narrow, or SSA invariants are too weak
- remaining string-based semantic logic still expands the trusted computing base unnecessarily
- textual LLVM emission remains a brittle backend choke point
- tooling/caching work can regress into ad-hoc duplication if artifacts stop being explicit and reusable
- audit/report work is still weaker than the language's long-term value proposition requires
- a slow local test loop will drag down every architecture task even when the technical direction is correct

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

Concrete already has the compiler pipeline and a meaningful stdlib base. The main unfinished work is now structural rather than speculative: faster feedback loops, hardening the new stable-storage lowering direction, shrinking the compiler's semantic surface, strengthening the SSA/backend contract, adding syntax guardrails, hardening the stdlib, improving diagnostics quality, and then pushing formalization and runtime work in that order.
