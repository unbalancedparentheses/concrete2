# Concrete Roadmap

This document is forward-looking. Use it to decide what to do next, in what order, and what documents/code areas to consult while doing it.

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For current compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For project identity, see [docs/IDENTITY.md](docs/IDENTITY.md).
For the safety model, see [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references: [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged not only by expressiveness, but also by its grammar cost, audit cost, and proof cost.

## What's Next (in order)

The examples audit (12 programs, 6k+ lines) identified where Concrete's friction actually lives. The following is ordered by impact on real code — do them in this order.

### 1. String ergonomics — the #1 pain point

Every example is 30-40% string ceremony. This is the single change that would make Concrete code look like a real language instead of C-with-capabilities.

- add `eq(a: &String, b: &String) -> bool` to `std.string` — reimplemented in kvstore, grep, and others
- add `clone(s: &String) -> String` to `std.string` — every example has its own `clone_string` helper
- add `.drop()` method on String for consistency with Vec (currently uses freestanding `drop_string`)
- `print`/`println` should accept `&String` directly
- `==` on strings (long-term, once operator overloading or trait-based equality exists)

The `str_eq` helper is reimplemented in kvstore and elsewhere. `drop_string` vs `.drop()` inconsistency is confusing. These changes would eliminate hundreds of lines across the examples.

### 2. Match on integers

The VM dispatch loop is 20 if/else branches because there's no `match` on `i32`. This is a parser+check change, not a deep compiler change. It would immediately improve every example that dispatches on tags (vm, json, toml, lox, mal — that's 5 of 12 examples).

### 3. Extract shared stdlib modules

SHA-256 is duplicated between integrity and verify. String-to-bytes conversion is reimplemented in multiple examples. A `std.crypto.sha256` module and better String APIs would cut duplication and make examples look like they belong to a real ecosystem.

### 4. Fix `import` in project mode

`import math.{add}` fails with "not public" in project mode even when the function is `pub`. This works fine in single-file mode. This is a real bug that would bite anyone trying to write multi-module projects.

### 5. Deferred (important but not where the friction is)

Phase I formalization, Phase J package ecosystem, and QBE backend are important but they don't improve the experience of writing Concrete today. The examples tell you where the friction is, and it's all in items 1-4.

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
- full kernel formalization (initial proof workflow landed in D2 with 17 theorems over a pure Core fragment; full formalization of structs, enums, match, recursion, and source-to-Core traceability remains future work)
- a runtime
- fully authoritative standalone resolution
- a real artifact-driven compiler driver with stable serialized artifacts, stable IDs, and source-to-Core traceability

## Phase Status

| Phase | Focus | Status |
|------|-------|--------|
| **A** | Fast feedback and compiler stability | Done |
| **B** | Semantic cleanup | Done |
| **C** | Tooling and stdlib hardening | Done |
| **D** | Testing, backend, and trust multipliers | Done |
| **E** | Runtime and execution model | Done |
| **F** | Capability and safety productization | Done |
| **G** | Language surface and feature discipline | Done |
| **H** | Real-program pressure testing and performance validation | Active |
| **I** | Formalization and proof expansion | Not started |
| **J** | Package and dependency ecosystem | Not started |
| **K** | Adoption, positioning, and showcase pull | Not started |
| **L1** | Project and operational maturity | Not started |
| **L2** | Backend plurality and codegen maturity | Not started |
| **M** | Concurrency maturity and runtime plurality | Not started |
| **N** | Allocation profiles and bounded allocation | Not started |
| **O** | Research phase and evidence-gated features | Not started |

## Priority Order For Closing The Gap To Rust

1. **Package/project model first** — clean `Concrete.toml` resolution, stdlib/project dependency resolution, workspaces, `concrete build`/`test`/`run`, incremental/artifact reuse. Without this, serious programs keep paying workflow tax.
2. **Stdlib and ergonomics without abandoning explicitness** — string ergonomics (`eq`, `clone`, `.drop()`), match on integers, shared stdlib modules, fix `import` in project mode, cleaner collection patterns. The goal is better compression of honest code.
3. **Hot-path performance after the workflow floor is fixed** — collection hot loops, backend/inlining policy for `vec_*` operations, keep validating against parser/streaming/VM/verifier workloads.
4. **Interop and product maturity** — FFI workflow, generated headers, machine-readable reports, debug-info, observability, editor/LSP baseline, release/compatibility discipline.

## Phase Details

### Phase H: Real-Program Pressure Testing And Performance Validation (Active)

Goal: force Concrete to prove itself under sustained use by writing multiple real programs and using them to expose language, stdlib, correctness, auditability, performance, and workflow weaknesses.

Primary surfaces:
- large Concrete programs and example repos
- [docs/STDLIB.md](docs/STDLIB.md), [docs/TESTING.md](docs/TESTING.md)
- [research/workloads/comparative-program-suite.md](research/workloads/comparative-program-suite.md)
- [research/workloads/showcase-workloads.md](research/workloads/showcase-workloads.md)

Open work:
- add remaining mutation-oriented string APIs (`string_clear`, `string_starts_with`, `string_ends_with`)
- evaluate arena allocation against the existing `Vec`-as-pool pattern
- strengthen layout reports where real programs need them
- document runtime/stack pressure findings from deep-recursive workloads
- decide whether destructuring `let` earns its place for real-program clarity
- unify destruction ergonomics via general `drop(x)` / `Destroy` trait — **deferred** (revisit when stdlib has 5+ distinct drop-like functions)
- scoped helper abstractions for resource cleanup — **deferred**
- selective borrow-friendly APIs / `&str`-style borrowed slices — **deferred**
- build comparison implementations in Rust, Zig, and C
- compare results across correctness, runtime, memory, binary size, compile time, code size, trust/unsafe surface, and auditability
- identify codegen cliffs, allocation cliffs, compile-time cliffs, diagnostics pain points, and trust/capability ergonomics failures
- turn findings into concrete language, stdlib, backend, and tooling follow-up work

Current Phase H judgment: performance credibility is established across JSON, verifier, VM, and other compute-heavy workloads. The remaining high-value work is ergonomic rather than raw speed. Phase H is past open-ended discovery — it has a short cleanup tail but is no longer the strategic center. The next major center of gravity should move toward Phase J package/workspace maturity.

Exit criterion: Concrete has been exercised by multiple serious programs large enough to reveal structural weaknesses, and the project has used those results to drive the next phases.

### Phase I: Formalization And Proof Expansion

Goal: turn the existing proof-oriented architecture into a real multi-stage formalization effort over the language, proof-eligible subset, and selected compiler boundaries.

Primary surfaces:
- [research/proof-evidence/formalization-breakdown.md](research/proof-evidence/formalization-breakdown.md)
- [research/proof-evidence/formalization-roi.md](research/proof-evidence/formalization-roi.md)
- [research/proof-evidence/proving-concrete-functions-in-lean.md](research/proof-evidence/proving-concrete-functions-in-lean.md)
- [Concrete/ProofCore.lean](/Users/unbalancedparen/projects/concrete/Concrete/ProofCore.lean)
- [Concrete/Proof.lean](/Users/unbalancedparen/projects/concrete/Concrete/Proof.lean)

1. broaden the pure Core proof fragment beyond integers/booleans/arithmetic/conditionals
2. define and stabilize the provable subset as an actual proof target
3. expand `ProofCore` carefully so it remains a filter over `ValidatedCore`
4. add source-to-Core and Core-to-ProofCore traceability
5. prove more language guarantees around capabilities, ownership, trust boundaries
6. push selected compiler-preservation work further
7. make the user-program proof workflow more real: artifact-driven, addon-friendly, layered (SMT + Lean)

Deliverables: broader formal semantics, documented provable subset, stronger traceability, practical path for selected programs to be proved in Lean, layered proof workflow.

### Phase J: Package And Dependency Ecosystem

Goal: make Concrete usable for real multi-module and multi-package projects with explicit, stable project-facing semantics.

Primary surfaces:
- [research/packages-tooling/authority-budgets.md](research/packages-tooling/authority-budgets.md)
- [research/compiler/artifact-driven-compiler.md](research/compiler/artifact-driven-compiler.md)
- project/package metadata, import resolution, stdlib vs third-party boundaries

1. design and implement incremental compilation — serialize pipeline artifacts, cache invalidation by source hash, skip unchanged modules
2. define the package and dependency model explicitly — **partially done** (stdlib is builtin; remaining: third-party deps, version constraints, lockfile)
3. define stdlib vs third-party package boundaries — **partially done**
4. define workspace and multi-package behavior
5. make dependency and package UX part of the language-user experience
6. split interface-facing artifacts from body-bearing artifacts
7. make package/dependency reasoning operate on explicit graph artifacts
8. project-facing CLI workflow — **done** (`concrete build`, `concrete test`, `concrete run`)
9. package-aware testing tooling
10. first enforceable authority-budget path at module/package scope
11. provenance-aware publishing model
12. package graph strong enough for later evidence/trust bundles

### Phase K: Adoption, Positioning, And Showcase Pull

Goal: make Concrete easier to want, try, understand, and remember.

1. define signature domains where Concrete should be unusually strong
2. build serious public showcase programs
3. make onboarding, examples, and project-start flow part of the product story
4. define explicit public stability/experimental surface
5. document positioning relative to adjacent systems languages
6. define explicit adoption non-goals

### Phase L1: Project And Operational Maturity

Goal: turn Concrete from a strong compiler project into a durable, distributable, maintainable system. This is where the evidence story becomes operational.

Key items: release/compatibility discipline, reproducible CI, distribution/installation story, editor/LSP baseline, certification-style traceability, trust bundles, machine-readable reports, report-first review workflows, semantic query/search, trust-drift diffing, compiler-driver/build-graph layer, per-function inspection, coverage tooling, developer feedback loop (`check`/`watch`), dependency auditing.

### Phase L2: Backend Plurality And Codegen Maturity

Goal: make backend work explicit, testable, and replaceable over the SSA boundary.

Key items: backend plurality over SSA, QBE as first lightweight experiment, cross-backend validation, debug-info emission, SSA-level function inlining, emitted-code inspection, cross-compilation workflow. C/Wasm later; MLIR only if it earns its complexity.

### Phase M: Concurrency Maturity And Runtime Plurality

Goal: give Concrete a long-term concurrency model that stays explicit, auditable, and small.

Intended shape: structured concurrency as semantic center, OS threads plus message passing as base primitive, evented I/O as later specialized model, no unrestricted detached async ecosystem.

### Phase N: Allocation Profiles And Bounded Allocation

Goal: turn allocation behavior into a stronger audit and high-integrity surface.

Intended shape: strengthen `--report alloc`, add enforceable `NoAlloc` checking, explore restricted `BoundedAlloc(N)` only where structurally explainable, prefer capacity-aware APIs over clever inference.

### Phase O: Research Phase And Evidence-Gated Features

Goal: keep high-value ideas visible, evaluated, and explicitly decided without forcing premature language growth.

Candidates: typestate, arena allocation, execution boundedness, layout reports, authority budgets, binary-format DSLs, ghost/proof-only syntax, hardware capability mapping, MIRI-style interpreter.

## Cross-Phase Carry-Overs

Completed phases can still seed work that is intentionally finished later. Do not reopen those phases unless their original exit criteria were wrong.

| Item | First Real Shape | Current Owning Phase | Status |
|------|------------------|---------------------|--------|
| Empirical cross-target FFI/ABI validation | **E** | **J / L1** | Not started |
| Verified FFI envelopes | **E** | **L1** | Research only |
| Structural boundedness reports | **E** | **N** | Not started |
| Capability sandbox profiles | **E** | **N / O** | Research only |
| Proof-backed authority reports | **F** | **I** | Not started |
| Authority budgets as enforceable contracts | **F** | **J** | Research only |
| Artifact-driven compiler driver | **D** | **J / L1** | Partial only |
| Backend plurality over SSA | **D** | **L2** | Research only |
| Machine-readable reports | **D / F** | **L1** | Not started |
| Report-first review workflows | **F** | **L1** | Research only |
| Semantic query/search tooling | **F / H** | **L1** | Research only |
| Reproducible trust bundles | **I** | **L1** | Not started |
| Cryptographically committed evidence bundles | **I / J / L1** | **L1** | Research only |
| Review-policy gates | **F** | **L1** | Research only |
| Package/release trust-drift diffing | **J** | **L1** | Not started |
| Structured/type-aware fuzzing | **D / H** | **L1 / O** | Research only |
| Semantic compatibility checking | **J** | **L1** | Research only |
| Coverage tooling | **D / H** | **L1** | Research only |
| Binary-linked proof-facing exports | **I** | **I / L1** | Research only |
| Symbolic-execution addon | **I** | **I / L1** | Research only |
| Dynamic UB interpreter | **E / F** | **O** | Research only |
| Serious showcase workload as flagship review artifact | **H** | **K** | Not started |
| Hardware capability mapping | **E / M** | **O** | Research only |
| Developer-feedback-loop tooling | **A / C** | **L1** | Research only |

### Pre-H Carry-Over Work Order

1. **Now** — artifact-driven compiler driver, stable artifact IDs, build-graph orchestration, machine-readable reports, first review workflow baseline, cross-target FFI validation, authority budgets
2. **Soon** — verified FFI envelopes, proof-backed authority reports, trust bundles, semantic query/search, review-policy gates, coverage tooling
3. **Later** — backend plurality, structural boundedness reports, capability sandbox profiles, deeper test-system productization

## Longer-Horizon Multipliers

1. **Proof-backed trust claims** — prove effect/capability honesty, ownership soundness, `trusted`/`Unsafe` honesty, Core->SSA preservation
2. **Stronger audit outputs** — why a capability is required, where allocation/cleanup/`trusted` happens, layout/ABI facts, structural boundedness
3. **A smaller trusted computing base** — keep shrinking builtins, keep moving behavior into stdlib, keep trust boundaries grep-able
4. **A better capability/sandboxing story** — stronger reports, "why" traces, capability aliases, authority wrappers, later hosted vs freestanding split

For more: [research/meta/ten-x-improvements.md](research/meta/ten-x-improvements.md), [research/language/capability-sandboxing.md](research/language/capability-sandboxing.md), [research/stdlib-runtime/long-term-concurrency.md](research/stdlib-runtime/long-term-concurrency.md).

## Current Design Constraints

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over whole-aggregate `phi` transport
- avoid reintroducing parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable
- prefer boring artifact boundaries over clever implicit compiler coupling

## Not Yet

Do not do before prerequisites are stable:

- backend plurality before SSA/backend-contract work is done
- MLIR as the immediate answer to the current backend problem
- major runtime/concurrency surface area before compiler/backend boundaries are more stable
- surface features that increase grammar cost, audit cost, or proof cost without clear leverage
- parallel semantic lowering paths for convenience
- letting ordinary public names regain compiler-known meaning through string matching
- parallelized test execution that makes failures non-reproducible

## Current Risks

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
- formalization scope is still narrow (17 theorems, no structs/enums/match/recursion yet)
- type coercion gaps: SSAVerify catches `i32 + i64` mismatches, but elaborator hint propagation hasn't been proven exhaustive
- linearity checker: edge cases tested and working, `borrowCount` is dead code, not formally audited

## Implementation Rule

For any roadmap item: (1) start from the phase description here, (2) use the linked docs as semantic/reference authority, (3) inspect listed code surfaces before changing behavior, (4) preserve phase ordering unless there is an explicit dependency reason otherwise.

## Status Legend

- **Done**: implemented and no longer on the active roadmap.
- **Done enough**: complete for the current architecture phase.
- **Active**: current roadmap work.
- **Deferred**: intentionally postponed until prerequisites are stable.
- **Research**: explored in docs/research but not yet roadmap-committed.

---

## Archive: Completed Work

Phases A-G are complete. For full details, see [CHANGELOG.md](CHANGELOG.md). Below is the detailed history preserved for reference.

### Phase A: Fast Feedback And Compiler Stability — Done

Goal: make the current pipeline fast to iterate on, boring, and hard to break.

1. ~~make common test paths materially faster~~ **Done** — parallel runner, `--fast`/`--full`/`--filter`/`--affected`/`--manifest` modes, cached compilations, lli acceleration
2. ~~finish hardening aggregate lowering~~ **Done** — aggregate loop vars promoted to entry-block allocas, field assignment GEPs into stable storage
3. ~~keep shrinking accidental aggregate transport~~ **Done** — if/else and match merge via entry-block allocas, SSA verifier rejects aggregate phi nodes
4. ~~add optimized-build regressions and stdlib coverage~~ **Done** — O2 regression tests, stdlib coverage for Option/Result/Text/Slice
5. ~~tighten SSA invariants~~ **Done** — SSAVerify rejects aggregate phi nodes, integer bit-width check added

### Phase B: Semantic Cleanup — Done

Goal: shrink compiler magic and make language meaning explicit. All semantic dispatch uses explicit identity types (`BuiltinTraitId`, `BuiltinEnumId`, `IntrinsicId`). Key commits: d0b2f53, 4e557e0, daef46a, 40f1ce4. See `Concrete/Intrinsic.lean`.

### Phase C: Tooling And Stdlib Hardening — Done

Goal: make the language usable and inspectable without destabilizing semantics. LL(1) grammar checker in CI, linearity checker fixed for generic types, builtin HashMap interception retired (~1,400 lines deleted), module-targeted stdlib testing, 44 report assertions, reports as audit product.

### Phase D: Testing, Backend, And Trust Multipliers — Done

Goal: make the compiler strong enough to support proofs, tooling reuse, and long-term backend work.

**D1 delivered:** pass-level Lean tests (32 tests), test metadata, dependency-aware selection (`--affected`), compiler output cache, failure artifacts, coverage matrix.

**D2 delivered:** `ValidatedCore` pipeline artifact, `ProofCore` extraction, formal evaluation semantics with 17 proven theorems, SSA backend contract.

**Items 3-7 delivered:** SSA backend contract, ABI/FFI maturity statement, 12-program integration corpus, formalization over Core->SSA, 8 report modes. 3 compiler bugs discovered and fixed.

### Phase E: Runtime And Execution Model — Done

Goal: make the language's execution model explicit. All 11 items complete. `docs/EXECUTION_MODEL.md` is the central reference. Covers hosted/freestanding model, runtime boundary, abort-on-OOM, FFI ownership boundary, `#[repr(C)]` by-value calling convention, target/platform policy, execution profiles direction, concurrency design (threads-first, structured, capability-gated).

### Phase F: Capability And Safety Productization — Done

Goal: turn capability and trust features into a strong user-facing safety system. Actionable capability hints, `--report authority` and `--report proof`, `cap` alias syntax, `docs/SAFETY.md` as central reference, high-integrity profile direction, bounded semantic error recovery.

### Phase G: Language Surface And Feature Discipline — Done

Goal: keep the language small, coherent, and intentionally shaped. `docs/DESIGN_POLICY.md` (feature admission criteria), `docs/DECISIONS.md` (no/not-yet decisions), removed `main!()`/`fn name!()` bang sugar, `trusted` refined to pointer-ops-only containment, `docs/LANGUAGE_SHAPE.md`, `docs/PROVABLE_SUBSET.md`.

### Phase H Completed Items

- ~~text/output direction~~ — resolved: `print`/`println` with mixed args sufficient
- ~~artifact verifier as flagship workload~~ — done
- ~~runtime argument surface~~ — done: `std.args` module
- ~~grep string/output bottlenecks~~ — done: buffered libc I/O
- ~~qualified module access~~ — done: `mod::fn` works
- ~~collection/runtime maturity~~ — done: `for_each`, `fold<A>`, `keys()`/`values()`/`elements()`
- ~~Bug 018 (stack array borrow-copy)~~ — fixed: `f8f1bf8`
- ~~Bug 019 (method-level generics crash)~~ — fixed: `c0c5b54`
- ~~standalone vs project split~~ — fixed: package mode with builtin std resolution
- ~~qualified submodule access and collision handling~~ — done
- ~~runtime argument access~~ — done: `std.args` module
- mixed-arg `print`/`println` builtins landed (commit `1b0d21f`)
- collection maturity: `for_each`, `fold<A>`, `keys()`/`values()`/`elements()` complete
- `defer` statement for explicit scope-end cleanup landed

### Compiler Hardening (between Phase D and Phase E) — All Done

1. ~~Audit Layout.lean for silent fallback defaults~~ — all `dbg_trace` fallbacks converted to `panic!`, type variable leakage fixed
2. ~~Systematic integer type inference hardening~~ — vec intrinsic hint propagation, defensive SSAVerify check
3. ~~Linearity/borrow checker audit~~ — edge cases tested, `borrowCount` identified as dead code
4. ~~Cross-module type propagation completeness~~ — enums, traits (via wrappers), type aliases all work
5. ~~Backend error reporting instead of silent wrong code~~ — 6 silent defaults converted to `throw` in Lower.lean, 7 `dbg_trace` fallbacks to `panic!`

### Bug Fix History

- **Bug 004** — Array variable-index assignment: fixed
- **Bug 005** — Enum fields inside structs panic layout: fixed
- **Bug 006** — Cross-module string literal collisions: fixed
- **Bug 007** — No easy print path for standalone: fixed (`print_string`/`print_int`/`print_char` builtins)
- **Bug 008** — If-else expressions: fixed (if-else as expression with alloca+condBr+store+load)
- **Bug 009** — `const` declarations not lowered: fixed (constants inline correctly)
- **Bug 010** — No substring extraction: fixed (`string_slice`/`string_substr`)
- **Bug 011** — Awkward string building in loops: fixed (`string_push_char`/`string_append`)
- **Bug 012** — No timing path for standalone benchmarks: fixed (`clock_monotonic_ns` builtin)
- **Bug 016** — Cross-module HashMap linking: fixed
- **Bug 017** — macOS socket constants: fixed
- **Bug 018** — Stack-array borrow-copy: fixed
- **Bug 019** — Method-level generics crash at lowering: fixed

### Historical Progress Notes

- 663 tests pass (184 stdlib) at Phase D completion
- 911 tests pass (2 skipped) at system-level validation completion
- Builtin HashMap interception retired: ~1,400 lines of compiler-internal HashMap machinery deleted
- Structured LLVM backend completed: all emission through structured `LLVMModule` data
- Linearity checker fixed for generic types: four fixes to `Check.lean`
- User-defined IntMap validated end-to-end
- Phase 3 testing: 6 large mixed-feature programs, ~75 O2 differential tests, ABI interop test, `test_fuzz.sh` (1500 programs), `test_perf.sh`

### Phase H Example Program Portfolio

First wave (all compiling/running):
1. Policy/rule engine
2. MAL-style Lisp interpreter
3. JSON parser + validator
4. grep-like text search tool
5. bytecode VM / interpreter
6. artifact/update verifier

Second wave (all compiling/running):
1. TOML parser
2. File integrity monitor
3. Key-value store
4. Simple HTTP server
5. Lox tree-walk interpreter (1,052 loc)

Benchmark findings:
- JSON parser competitive with Python's `json.loads` at `-O2`
- grep tool roughly Python-class, competitive with system grep depending on output mode
- bytecode VM far faster than Python, matched comparable C heap-`Vec` after fixing vec builtin inlining
- the earlier "Concrete is much slower than Python" story was largely a `-O0` and naive ingestion artifact
