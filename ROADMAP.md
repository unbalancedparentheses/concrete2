# Concrete Roadmap

This document answers "what do we do next?" It has one authoritative priority list with two tracks.

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references: [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by its grammar cost, audit cost, and proof cost — not only by expressiveness.

---

## Priorities

Two tracks run in parallel. Neither blocks the other. Work from either track in any session.

### Track A: Language & Stdlib Ergonomics

Makes writing Concrete code less painful today. Identified by the Phase H examples audit (12 programs, 6k+ lines).

| | Item | Why | Status |
|---|------|-----|--------|
| **Now** | ~~String `eq`, `clone`, `drop`~~ | Every example reimplements these | Done (`8ea8524`) |
| **Now** | Match on integers | 5/12 examples use if/else chains for dispatch | Not started |
| **Now** | Fix `import` in project mode | `pub` functions fail with "not public" in project mode | Not started |
| **Next** | Extract shared stdlib modules | SHA-256 duplicated, string-to-bytes reimplemented everywhere | Not started |
| **Next** | Remaining string APIs | `starts_with`, `ends_with`, `contains` in std.string | Not started |
| **Later** | `==` on strings | Needs operator overloading or trait-based equality | Not started |
| **Later** | Destructuring `let` | Evaluate whether it earns its grammar cost | Not started |

### Track B: Project Architecture

Makes Concrete viable as a multi-module, multi-package system. This is structurally prerequisite for serious adoption.

| | Item | Why | Status |
|---|------|-----|--------|
| **Now** | Incremental compilation | Serialize artifacts, cache by source hash, skip unchanged modules | Not started |
| **Now** | Third-party dependency model | Version constraints, lockfile, dep resolution | Not started |
| **Next** | Workspace / multi-package | Real projects need more than one package | Not started |
| **Next** | Split interface vs body artifacts | Prerequisite for fast incremental and separate compilation | Not started |
| **Next** | Authority budgets at module scope | First enforceable trust boundary beyond `trusted fn` | Not started |
| **Later** | Package-aware testing | Test isolation, per-package test runs | Not started |
| **Later** | Provenance-aware publishing | Package graph strong enough for trust bundles | Not started |

### Not Now

Do not start before the tracks above are further along:

- Backend plurality (Phase L2) — SSA contract needs to stabilize first
- Major concurrency surface (Phase M) — compiler/backend boundaries need to be more stable
- Deep formalization (Phase I) — the proof fragment is narrow (17 theorems); broaden only when the language surface is more settled
- Features that increase grammar/audit/proof cost without clear leverage

---

## Current State

The Lean 4 compiler implements the core surface language plus the full pipeline: Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → EmitSSA → LLVM IR.

What exists:
- centralized ABI/layout in `Layout.lean`
- native diagnostics, 8 report modes with 59 assertions
- `trusted fn` / `trusted impl` / `trusted extern fn` boundaries
- stdlib: `vec`, `string`, `io`, `bytes`, `slice`, `text`, `path`, `fs`, `env`, `process`, `net`, `fmt`, `hash`, `rand`, `time`, `parse`, `test`
- collections: `Vec`, `HashMap`, `HashSet`, `Deque`, `BinaryHeap`, `OrderedMap`, `OrderedSet`, `BitSet`
- `#[test]` execution through the real compiler, `concrete build`/`test`/`run`
- 12 example programs (grep, http, json, kvstore, lox, mal, integrity, verify, vm, toml, policy_engine, project)

What doesn't exist yet: `transmute`, backend plurality, full formalization, a runtime, standalone resolution, artifact-driven compiler driver.

## Phase Status

| Phase | Focus | Status |
|------|-------|--------|
| A–G | Core language, safety, testing, execution model | Done |
| **H** | Real-program pressure testing | **Done** (cleanup tail only) |
| **I** | Formalization and proof expansion | Not started |
| **J** | Package and dependency ecosystem | Not started |
| K | Adoption and showcase | Not started |
| L1 | Project/operational maturity | Not started |
| L2 | Backend plurality | Not started |
| M–O | Concurrency, allocation profiles, research | Not started |

Phase H detail: [research/workloads/phase-h-summary.md](research/workloads/phase-h-summary.md), [research/workloads/phase-h-findings.md](research/workloads/phase-h-findings.md).

## Phase Descriptions

### Phase I: Formalization And Proof Expansion

Broaden the pure Core proof fragment. Stabilize the provable subset. Add source-to-Core traceability. Make user-program proofs practical (artifact-driven, addon-friendly, layered SMT + Lean).

References: [research/proof-evidence/](research/proof-evidence/)

### Phase J: Package And Dependency Ecosystem

Incremental compilation, third-party deps, workspaces, interface/body artifact split, authority budgets at package scope, provenance-aware publishing.

Partially done: stdlib is builtin dep, CLI workflow (`build`/`test`/`run`) works.

References: [research/packages-tooling/](research/packages-tooling/), [research/compiler/artifact-driven-compiler.md](research/compiler/artifact-driven-compiler.md)

### Phases K–O (later)

- **K**: Adoption — signature domains, showcase programs, onboarding, positioning
- **L1**: Operational maturity — releases, CI, distribution, LSP, machine-readable reports, trust bundles
- **L2**: Backend plurality — QBE experiment, cross-backend validation, debug-info, C/Wasm later
- **M**: Concurrency — structured concurrency, threads + message passing, evented I/O later
- **N**: Allocation profiles — `--report alloc`, `NoAlloc` checking, `BoundedAlloc(N)`
- **O**: Research — typestate, arenas, execution boundedness, ghost syntax, hardware capabilities

## Design Constraints

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over phi transport
- avoid parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable

## Current Risks

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
- formalization scope is narrow (17 theorems, no structs/enums/match/recursion)
- type coercion gaps: SSAVerify catches mismatches, but elaborator hint propagation not proven exhaustive
- linearity checker: edge cases tested, `borrowCount` is dead code, not formally audited

## Longer-Horizon Multipliers

1. **Proof-backed trust claims** — prove effect/capability honesty, ownership soundness, Core→SSA preservation
2. **Stronger audit outputs** — capability traces, allocation/cleanup/trusted locations, layout/ABI facts
3. **Smaller trusted computing base** — shrink builtins, move behavior into stdlib, keep trust boundaries grep-able
4. **Better capability/sandboxing** — stronger reports, authority wrappers, hosted vs freestanding split

For more: [research/meta/ten-x-improvements.md](research/meta/ten-x-improvements.md), [research/language/capability-sandboxing.md](research/language/capability-sandboxing.md).
