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
| **A** | Fast feedback and compiler stability | Active; core aggregate-loop storage fix landed, hardening still open | B, C, D |
| **B** | Semantic cleanup | Active | D |
| **C** | Tooling and stdlib hardening | Active | later system maturity |
| **D** | Backend and trust multipliers | Pending | A, most of B |

### Recent Progress

- The core Phase A architecture fix for mutable aggregate loops has landed (commit `e68acc0`): aggregate loop variables are promoted to entry-block allocas instead of flowing through `phi` nodes. Field assignment GEPs directly into stable storage — no temp-alloca round-trip, no unbounded stack growth.
- Measured on representative cases: aggregate phis eliminated (0 across all loop tests), allocas reduced from 4 in-loop to 2 in-entry, fieldAssign allocas hoisted for non-promoted path too.
- Explicit `-O2` regression tests added for all three struct-loop patterns (simple, break, nested).
- **Remaining aggregate phi sites**: `if`/`else` branch merging still creates whole-aggregate `phi` for struct variables modified in branches, and `match` expressions can still merge aggregate results the same way. These are less critical than loops (no stack growth, no iteration amplification) but they are the next target for Phase A item 2.
- That lowers the immediate risk, but it does **not** finish Phase A. Faster local testing, non-loop aggregate-merge cleanup, broader optimized-build regressions, stdlib stress coverage, and SSA invariant tightening remain ahead of the LL(1) checker and the rest of Phase C.
- Read the `Now` list as "remaining highest-priority work", not as "what has never been started."

### Now

This list is ordered to match the active execution phases: Phase A first, then Phase B, then Phase C, then the front edge of Phase D.
Within Phase A, the fast feedback loop comes first on purpose: it is the immediate force multiplier for every compiler change that follows.

1. Make the edit-test loop materially faster.
   - make common local test paths parallel by default where safe instead of effectively serial
   - add narrower runner modes for one-file, one-subsystem, and one-stdlib-area workflows
   - make optimized-build targeted regressions easy to run without paying for the full suite
   - keep the fast path explicit: quick local verification first, full-suite confidence second
   - done means: ordinary compiler work no longer depends on waiting for the full serial test path after each change
2. Finish hardening aggregate lowering and merge transport for mutable aggregates and borrows.
   - the core stable-storage promotion change has landed; keep building on that design instead of reintroducing whole-aggregate loop transport
   - eliminate or narrow whole-aggregate `phi` transport at `if`/`else` merge points when stable storage identity or narrower transport is the real semantic model
   - do the same for `match` expressions that currently merge aggregate results through a single whole-aggregate `phi`
   - remove or narrow remaining full aggregate writeback through loop `phi` nodes where stable storage identity is the real semantic model
   - reduce aggregate `phi` usage to cases that are semantically necessary, preferring scalars or pointer identities over whole-aggregate SSA transport
   - treat borrow+aggregate lowering fragility as a compiler architecture bug, not an LLVM quirk to paper over
   - grow regression coverage around optimized builds and stdlib cases that stress aggregate lowering and merge paths
   - tighten SSA invariants around the promoted-storage path so the design is mechanically defended, not just empirically passing
   - done means: optimized-build borrow/aggregate cases are stable, remaining aggregate transport is intentional rather than accidental, and this class of failure is covered by durable regressions
3. Finish tightening the builtin-vs-stdlib boundary.
   - keep builtins minimal, compiler/runtime-facing, and explicitly non-user-facing
   - remove remaining string-based semantic dispatch in compiler tables, pass-local special cases, and backend helper selection
   - make ordinary language behavior depend on internal identities or explicit language items, not raw function-name matching
   - keep stringly handling confined to true foreign-symbol, linker-symbol, or user-facing report/rendering boundaries
   - treat any compiler rule that changes semantics based on an ordinary public name as architecture debt
   - keep the stdlib bytes-first and low-level rather than letting string-heavy convenience APIs dominate the surface
   - done means: ordinary public names no longer carry compiler-known semantics through raw matching
4. Add an external LL(1) grammar checker as a standing syntax guardrail.
   - add a compact reference grammar at `grammar/concrete.ebnf`
   - add a small checker at `scripts/check_ll1.py`
   - put it in CI
   - treat parser-state rewind/backtracking regressions as bugs
   - done means: syntax regressions trip a dedicated CI check instead of silently re-entering the parser
5. Keep deepening and hardening the stdlib.
   - deepen `fs`, `net`, and `process`
   - add more failure-path and integration tests
   - keep error, handle, and checked/unchecked conventions uniform
   - add stdlib-aware module-targeted test infrastructure instead of relying only on `std/src/lib.con --test`
   - done means: systems modules have stronger failure-path coverage and stdlib tests can target one area without bootstrapping the whole tree
6. Improve diagnostics fidelity and rendering quality.
   - better range precision
   - notes and secondary labels
   - clearer presentation for transformed constructs
   - reduce brittle string-matched report/test coupling where structured checks are possible
   - done means: diagnostics quality improvements are visible in ordinary compiler output, not only in internal plumbing
7. Preserve SSA as the only backend boundary and keep the build/project model explicit and boring.
   - replace raw LLVM string emission with a structured LLVM backend before adding backend plurality
   - keep target-specific work behind an explicit backend abstraction over SSA
   - treat MLIR as a later optional backend family, not the default immediate answer
   - done means: the backend consumes a structured contract over SSA and textual LLVM concatenation is no longer the critical path

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
4. deepen failure-path and integration testing in systems modules
5. make report assertions part of ordinary hardening

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
4. push formalization over Core -> SSA
5. add deferred audit/report outputs

Exit criterion:
backend work no longer feels fragile, and proofs, reports, and tooling all build on the same stable compiler boundaries.

### Why These Phases Matter

- **Phase A** matters because a slow feedback loop drags down every compiler task, and backend-sensitive lowering bugs destroy trust in every other part of the compiler.
- **Phase B** matters because a compiler is much easier to trust, prove, and maintain when ordinary names stay ordinary.
- **Phase C** matters because syntax guardrails, diagnostics, and testing infrastructure are what make a compiler sustainable instead of heroic.
- **Phase D** matters because this is where Concrete stops being only a working compiler and becomes a trustworthy compiler platform.

### Next

1. Push formalization over the cleaned Core -> SSA architecture.
   - prioritize proof targets that directly depend on the compiler architecture cleanup: Core soundness, capability discipline, linearity/resource soundness, and Core -> SSA preservation
2. Add deferred audit/report outputs such as allocation summaries and cleanup/destruction reports.
3. Keep diagnostics converging on one high-quality surface across compiler modes.
4. Turn the testing strategy into durable infrastructure.
   - keep fuzz/property/trace/report/differential tests alive in CI
   - grow the regression corpus from real bugs
   - make report assertions part of ordinary compiler hardening
   - make stdlib testing module-targeted rather than only single-root bootstrap testing
5. Turn explicit pipeline artifacts into stronger tooling/caching building blocks once the current architecture cleanup settles.
   - keep artifact boundaries explicit and inspectable
   - move toward serialization/caching only on top of already boring pass contracts
   - let tooling consume the same compiler facts rather than growing parallel ad-hoc models

### Later

1. Backend plurality over SSA, but only after the current backend becomes structurally cleaner first.
2. Runtime maturity and eventual self-hosting pressure.
3. Proof-driven narrowing of future feature additions.
4. A clearer hosted vs freestanding / `no_std` split, but only after the runtime and stdlib boundaries are more stable.
5. Execution-cost analysis as an audit/report extension.
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
