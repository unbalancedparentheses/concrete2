# Concrete Roadmap

Status: roadmap

This document is forward-looking only.

Use it for:
- active priorities
- remaining major work
- sequencing constraints between unfinished areas

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

### Now

1. Add an external LL(1) grammar checker as a standing syntax guardrail.
   - add a compact reference grammar at `grammar/concrete.ebnf`
   - add a small checker at `scripts/check_ll1.py`
   - put it in CI
   - treat parser-state rewind/backtracking regressions as bugs
2. Finish tightening the builtin-vs-stdlib boundary.
   - keep builtins minimal, compiler/runtime-facing, and explicitly non-user-facing
   - remove remaining string-based semantic dispatch in compiler tables and special-case paths
   - keep stringly handling confined to true foreign-symbol boundaries
   - keep the stdlib bytes-first and low-level rather than letting string-heavy convenience APIs dominate the surface
3. Keep deepening and hardening the stdlib.
   - deepen `fs`, `net`, and `process`
   - add more failure-path and integration tests
   - keep error, handle, and checked/unchecked conventions uniform
   - add stdlib-aware module-targeted test infrastructure instead of relying only on `std/src/lib.con --test`
4. Improve diagnostics fidelity and rendering quality.
   - better range precision
   - notes and secondary labels
   - clearer presentation for transformed constructs
   - reduce brittle string-matched report/test coupling where structured checks are possible
5. Preserve SSA as the only backend boundary and keep the build/project model explicit and boring.
   - replace raw LLVM string emission with a structured LLVM backend before adding backend plurality
   - keep target-specific work behind an explicit backend abstraction over SSA
   - treat MLIR as a later optional backend family, not the default immediate answer

### Next

1. Push formalization over the cleaned Core -> SSA architecture.
2. Add deferred audit/report outputs such as allocation summaries and cleanup/destruction reports.
3. Keep diagnostics converging on one high-quality surface across compiler modes.
4. Turn the testing strategy into durable infrastructure.
   - keep fuzz/property/trace/report/differential tests alive in CI
   - grow the regression corpus from real bugs
   - make report assertions part of ordinary compiler hardening
   - make stdlib testing module-targeted rather than only single-root bootstrap testing
5. Continue stdlib deepening with the next collection layer and stronger systems ergonomics once the current API cleanup settles.

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
- Multi-backend work is deferred until the SSA boundary stays boring and shared.
- Runtime work should not pull frontend semantics or stdlib design into premature complexity.

## Current Design Constraints

These are current choices that should continue constraining future work unless explicitly revisited elsewhere:

- keep the parser LL(1)
- keep SSA as the only backend boundary
- avoid reintroducing parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable
- prefer boring artifact boundaries over clever implicit compiler coupling

## Summary

Concrete already has the compiler pipeline and a meaningful stdlib base. The main unfinished work is now structural rather than speculative: syntax guardrails, stdlib hardening, diagnostics quality, backend cleanup, formalization, and runtime work in that order.
