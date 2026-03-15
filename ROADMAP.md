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
- full kernel formalization (initial proof workflow landed in D2 with 17 theorems over a pure Core fragment; full formalization of structs, enums, match, recursion, and source-to-Core traceability remains future work)
- a runtime
- fully authoritative standalone resolution

## Priority Snapshot

### Milestones

| Phase | Focus | Status |
|------|-------|--------|
| **A** | Fast feedback and compiler stability | Done |
| **B** | Semantic cleanup | Done |
| **C** | Tooling and stdlib hardening | Done |
| **D** | Testing, backend, and trust multipliers | Done |
| **E** | Runtime and execution model | Not started |
| **F** | Capability and safety productization | Not started |
| **G** | Language surface and feature discipline | Not started |
| **H** | Package and dependency ecosystem | Not started |
| **I** | Project and operational maturity | Not started |
| **J** | Concurrency maturity and runtime plurality | Not started |

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
- 600 tests pass (184 stdlib), including SSA structure verification, -O2 regressions for aggregate lowering paths, expanded stdlib module coverage, six linearity regression tests, native HashMap/HashSet coverage, and lli-accelerated test execution (~12s full suite).
- **Phase C completed**: all 8 items done:
  - module-targeted stdlib testing (`--stdlib-module <name>` runs tests for a single stdlib module)
  - diagnostics/formatter polish (empty `{}` edge case, deprecation fixes, compiler warnings eliminated)
  - integration testing deepened: `report_integration.con` (all 6 report modes) + `integration_collection_pipeline.con` (multi-collection pipeline with Vec, generics, enums, allocation patterns)
  - report assertions hardened: 44 report tests with content checks across all 6 modes (caps, unsafe, layout, interface, mono, alloc)
  - reports as audit product: capability "why" traces showing which callees contribute each cap, trust boundary analysis showing what trusted functions wrap, allocation/cleanup summaries with leak warnings, summary totals and aligned columns across all reports
- 600 tests pass (184 stdlib), including 44 report assertions, 46 golden tests, integration tests, and 16 collections verified.
- **Phase D1 complete** (testing infrastructure):
  - **Compiler output cache**: file-keyed cache in `run_tests.sh`, 26/57 hits per fast run
  - **Failure artifacts**: `.test-failures/` with timestamped output and exact rerun commands
  - **Dependency gates**: `compile_gate()` skips downstream assertions when compilation fails
  - **Pass-level Lean tests**: `PipelineTest.lean` with 28 tests — parse (4), frontend/check/elab (8), monomorphize (2), SSA lowering (2), SSA verify (3), SSA cleanup (2), SSA emit (2), full pipeline (5). Each pass tested in isolation without unnecessary downstream cost.
  - **Test metadata**: `test_manifest.toml` with per-test reference metadata (category, kind, passes, profile, owner_pass — not consumed by the runner, serves as documentation and future tooling source). `test_dep_map.toml` maps compiler source files to affected test sections (consumed by `--affected` mode).
  - **Dependency-aware selection**: `run_tests.sh --affected` auto-detects changed files via `git diff` and runs only affected sections. `--affected Concrete/Report.lean` runs 72 tests; `--affected Concrete/Lower.lean` runs 248 tests.
  - **Coverage matrix and determinism policy**: `docs/TESTING.md` rewritten with full coverage matrix (by failure mode and by compiler pass), determinism rules (fixed seeds, no wall-clock dependence, timeout classes, network isolation, parallel safety), compile-time baselines, and failure isolation documentation.
  - **Real-program corpus**: 8 integration tests including 5 multi-feature programs (150-250 lines each): generic pipeline (5-layer borrow chain), state machine (4×5 nested match), compiler stress (deep generic dispatch, 5-variant enum), multi-module (cross-module types/traits/enums), recursive structures (expression evaluator + stack machine).
- 647 tests pass (184 stdlib), including 28 pass-level Lean tests, 44 report assertions, 46 golden tests, 8 integration tests, and 16 collections verified.
- **Phase D2 complete** (backend/artifact/proof):
  - **`ValidatedCore` artifact**: explicit pipeline type in `Concrete/Pipeline.lean`. `Pipeline.coreCheck` is the only constructor; `Pipeline.monomorphize` takes `ValidatedCore`, enforcing that validation happened. `Pipeline.elaborate` now returns `ElaboratedProgram` (elab + canonicalize only), and `Pipeline.coreCheck` validates it into `ValidatedCore`.
  - **`ProofCore` extraction**: `Concrete/ProofCore.lean` filters `ValidatedCore` into the pure, proof-eligible fragment — pure functions (empty capability set, not trusted), safe structs (no repr(C)/packed), safe enums (no builtin overrides). `extractProofCore` flattens module trees and reports inclusion/exclusion counts.
  - **Formal proof workflow**: `Concrete/Proof.lean` defines evaluation semantics for a pure Core fragment (integers, booleans, arithmetic, let bindings, conditionals, function calls with fuel-bounded termination). Embeds three Concrete programs (abs, max, clamp) and proves 17 theorems: concrete correctness (abs_positive, abs_negative, abs_zero, max_right, max_left, max_self, clamp_in_range, clamp_below, clamp_above), structural lemmas (eval_lit, eval_bool_lit, eval_var_bound), conditional reduction (eval_if_true, eval_if_false), and arithmetic (eval_add_lits, eval_sub_lits, eval_mul_lits).
  - **SSA backend contract**: `docs/PASSES.md` now documents the full SSA invariant chain — what SSAVerify guarantees (8 invariants), what SSACleanup guarantees (8 postconditions), what EmitSSA assumes (5 preconditions), and the overall invariant flow.
  - **Updated docs**: `docs/ARCHITECTURE.md` and `docs/PASSES.md` updated with ValidatedCore, ProofCore, proof semantics, and SSA contract.
- **Phase D item 4 complete** (FFI/ABI maturity):
  - **ABI maturity statement**: `docs/ABI.md` — stability matrix, platform assumptions (64-bit only), FFI safety model, struct/enum layout rules, known limitations section. `#[repr(C)]` provides C-compatible in-memory layout; calling convention uses pointer indirection for all structs (known gap documented).
  - **Layout verification tests**: 4 tests in `PipelineTest.lean` — scalar sizes/alignments (17 checks), builtin sizes (String/Vec/HashMap), repr(C) struct layout (field offsets + packed variant), pass-by-pointer decisions (10 type checks). Model-based (Lean helpers), not empirical cross-target.
- **Phase D item 5 complete** (real-program corpus growth):
  - **4 new integration programs**: calculator (3-module RPN evaluator with trait dispatch, 200 lines), type registry (3-module catalog with validation/metrics, 248 lines), pipeline processor (4-module data transformation, 223 lines), stress workload (4-module bytecode interpreter with 11-variant enum, 280 lines).
  - Programs exercise: cross-module function calls, Vec<i32> with vec_set for stack semantics, enum matching (up to 11 variants), trait dispatch, generic functions, capability propagation, while loops, numeric computation chains.
  - Integration corpus now 12 programs (was 8), including stress-style workload.
- **Phase D item 7 complete** (deferred audit reports):
  - **Next report modes named**: `--report authority` (transitive capability analysis), `--report proof` (ProofCore eligibility), `--report high-integrity` (deferred to Phase E). Documented in `docs/PASSES.md`.
  - **44 report assertions stable**: all 6 report modes (caps, unsafe, layout, interface, alloc, mono) regression-tested with semantic grep patterns, not brittle snapshots. Cross-validation test verifies layout report sizes match runtime sizeof.
- **3 compiler bugs fixed** (discovered during integration test writing):
  - **Cross-module struct field offset** (`Elab.lean`): imported struct definitions were missing from `CModule`, causing `Layout.fieldOffset` to return 0 for all fields. Fix: include imported structs in CModule output.
  - **i32 literal type mismatch** (`Elab.lean`): integer literals defaulted to i64 in binary ops with i32 operands, producing LLVM type mismatches. Fix: re-elaborate literal with concrete operand type when types differ.
  - **Cross-module &mut borrow consumed as move** (`Check.lean`): function call argument processing consumed variables even for reference parameters. Fix: skip consumption for `&T`/`&mut T` parameter types.
  - Bug documentation in `docs/bugs/`, regression tests in `lean_tests/bug_*.con`.
- **Compiler hardening pass complete** (all 5 items):
  - **Lower.lean errors**: 6 silent defaults converted to `throw` — `lookupStructFields`, `fieldIndex`, `variantIndex`, `variantFields`, `structNameFromTy` propagate errors through `LowerM`. `lowerModule` returns `Except String SModule` — failed function lowering is now a compile error.
  - **Layout/EmitSSA hard errors**: all `dbg_trace` fallback defaults converted to `panic!` (6 in Layout.lean, 1 in EmitSSA.lean). Previously impossible because generic struct/enum definitions survived monomorphization with unsubstituted type variables (`.named "T"`). Fixed by: (a) adding `substStructTypeArgs` in Layout.lean (parallel to existing `substEnumTypeArgs`), applied in `tySize`, `tyAlign`, and `fieldOffset`; (b) adding `typeArgs` parameter to `enumPayloadOffset`, threading concrete type args from Lower.lean through 3 call sites; (c) substituting type args in `variantFields` before passing fields to `variantFieldOffset`; (d) scanning function types in EmitSSA to emit substituted type defs for generic structs/enums instead of skipping them; (e) erasing newtypes in imported function signatures at module boundaries.
  - **Integer inference**: vec intrinsic hint propagation + defensive SSAVerify check catches integer bit-width mismatches (`i32 + i64`).
  - **Borrow edge cases**: tested and working.
  - **Cross-module types**: enums, traits (via wrappers), type aliases, and newtypes all work. Type alias bug fixed — was broken even in single-module usage (function signatures carried unresolved alias names). Newtype erasure at import boundaries prevents leaked newtype names from reaching Layout/EmitSSA.
  - Hardening tests in `lean_tests/hardening_*.con`.
- 663 tests pass (184 stdlib), including 32 pass-level Lean tests, 44 report assertions, 46 golden tests, 20 integration/regression/hardening tests, and 16 collections verified.

### Compiler Improvement Checklist

| # | Item | Status |
|---|------|--------|
| 1 | Speed up the edit-test loop | Done — parallel runner, `--affected`, `--filter`, `--manifest`, cached compilations, lli acceleration |
| 2 | Harden lowering (mutable-state storage, aggregate merge transport) | Done — all `dbg_trace` defaults converted to `throw`/`panic!`, type variable leakage fixed, newtype erasure at module boundaries |
| 3 | Remove string-based semantic dispatch from ordinary language behavior | Done — Phase B exit criterion met: all semantic dispatch uses explicit identity types (`BuiltinTraitId`, `BuiltinEnumId`, `IntrinsicId`). Residual structural string mechanics (parser keywords, mangling, LLVM naming) are tolerated. |
| 4 | Strengthen SSA verifier/cleanup into a clearer backend contract | Done — 8 invariants documented and mechanically enforced end-to-end (SSAVerify runs both pre- and post-cleanup) |
| 5 | Make structured LLVM backend easier to reuse/verify/defend | Done — structured `LLVMModule` emission complete, builtins extracted into standalone `EmitBuiltins.lean` (no SSA/Core dependency), SSA contract documented |
| 6 | Backend plurality (C/Wasm, later MLIR) | Not started |

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

1. ~~make common test paths materially faster through safer parallelization and narrower runner modes~~ **Done** — parallel runner, `--fast`/`--full`/`--filter`/`--affected`/`--manifest` modes, cached compilations, lli acceleration
2. ~~finish hardening aggregate lowering for mutable aggregates and borrows after the core stable-storage promotion change~~ **Done** — aggregate loop vars promoted to entry-block allocas, field assignment GEPs into stable storage
3. ~~keep shrinking accidental aggregate transport at loops and non-loop merge points where stable storage identity is the real semantic model~~ **Done** — if/else and match merge via entry-block allocas, SSA verifier rejects aggregate phi nodes
4. ~~add optimized-build regressions and stdlib coverage for borrow+aggregate cases, including non-loop merge paths~~ **Done** — O2 regression tests, stdlib coverage for Option/Result/Text/Slice
5. ~~tighten SSA invariants around these lowering patterns and the promoted-storage path~~ **Done** — SSAVerify rejects aggregate phi nodes, integer bit-width check added

Exit criterion met: ordinary development uses parallel fast suite (~25-35s), no known backend-sensitive failures in aggregate lowering or merge transport.

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

#### Phase D: Testing, Backend, And Trust Multipliers — **Done**

Goal: make the compiler strong enough to support proofs, tooling reuse, and long-term backend work.

Phase D was split into D1 (testing architecture) and D2 (backend/artifact/proof), plus items 3–7. All items are complete. See Recent Progress for details on what landed.

**What D1 delivered:** pass-level Lean tests (32 tests across all compiler passes), test metadata (`test_manifest.toml`, `test_dep_map.toml`), dependency-aware selection (`--affected`), compiler output cache (26/57 hits), failure artifact preservation, coverage matrix and determinism policy in `docs/TESTING.md`, compile-once report reuse.

**What D2 delivered:** `ValidatedCore` pipeline artifact, `ProofCore` extraction, formal evaluation semantics with 17 proven theorems, SSA backend contract in `docs/PASSES.md`.

**What items 3–7 delivered:** SSA backend contract (item 3), ABI/FFI maturity statement with known limitations (item 4), 12-program integration corpus (item 5), formalization over Core→SSA (item 6), next report modes named (item 7). Integration testing also discovered 3 compiler bugs (now fixed — see `docs/bugs/`).

**What remains as future aspirations** (not blockers for Phase D exit): structured test definitions replacing shell orchestration, artifact-aware test reuse beyond the current cache, richer pass-level coverage for Check/Elab edge cases. These are tracked in the Compiler Hardening section and Phase E.
3. ~~strengthen the SSA verifier/cleanup boundary into a clearer backend contract~~ **Done** (D2): SSA backend contract documented in `docs/PASSES.md` — SSAVerify guarantees (8 invariants), SSACleanup guarantees (8 postconditions), EmitSSA assumptions (5 preconditions), invariant chain.
4. ~~define a clearer FFI / ABI maturity path~~ **Done**: `docs/ABI.md` — stability matrix, platform assumptions (64-bit only), FFI safety model, struct layout rules (repr(C)/packed/align), enum representation, pass-by-pointer convention. 4 layout verification tests in `PipelineTest.lean` (scalar sizes, builtin sizes, repr(C) layout, pass-by-ptr decisions). **Known gap:** `#[repr(C)]` structs have C-compatible in-memory layout but are passed by pointer (not by value) in `extern fn` calls — C code must accept a struct pointer, not a by-value struct. Layout model assumptions are verified against Lean helpers, not by empirical cross-target compilation.
5. ~~grow a stronger real-program and invariant-testing corpus on top of the faster loop~~ **Done**: 4 new integration programs (calculator 200 lines, type registry 248 lines, pipeline processor 223 lines, stress bytecode interpreter 280 lines). Integration corpus now 12 programs. Stress workload exercises 11-variant enum, multiple Vec instances, 21-instruction execution loop, cross-module types/functions. Programs discovered 3 compiler bugs (all now fixed — see `docs/bugs/`): cross-module struct field offset, i32 literal type mismatch, and cross-module &mut borrow consumed as move.
6. ~~push formalization over Core -> SSA~~ **Done** (D2): `ValidatedCore` explicit in `Pipeline.lean`, `ProofCore` extraction in `ProofCore.lean`, formal evaluation semantics in `Proof.lean` with 17 proven theorems (abs/max/clamp correctness, structural lemmas, arithmetic). Source-to-Core traceability and proof fragment extension (structs, enums, match, recursion) remain as future work.
7. ~~add deferred audit/report outputs~~ **Done**: next report modes named in `docs/PASSES.md` (`--report authority`, `--report proof`, `--report high-integrity` deferred to Phase E). All 6 existing modes (caps, unsafe, layout, interface, alloc, mono) regression-tested with 44 stable semantic assertions.

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
- [research/concurrency.md](research/concurrency.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)
- [research/trust-multipliers.md](research/trust-multipliers.md)
- runtime-facing stdlib and FFI boundaries

1. define the hosted vs freestanding model more explicitly — **not started**
2. make the runtime boundary explicit — **not started**
3. define the memory / allocation strategy explicitly — **not started**
4. define the concurrency and execution story deliberately — **not started**
   - first target: hosted runtime, OS-thread-based concurrency, explicit `spawn`/`join`/channel APIs, move-first ownership across threads, no built-in `async`/`await` initially
   - concurrency should be capability-gated and live in stdlib/runtime surfaces before any core-language syntax is considered
5. tighten the FFI/runtime ownership boundary — **not started**
6. close the FFI/ABI calling convention gaps (from Phase D Known Limitations) — **not started**
7. make runtime-related stdlib surfaces reflect the chosen execution model — **not started**
8. define execution profiles for high-integrity use — **not started**
9. make room for verified FFI envelopes and structural boundedness reporting — **not started**
10. define how runtime-sensitive performance validation should work — **not started**

Deliverables:
- a documented hosted vs freestanding execution model
- a documented runtime boundary covering startup, shutdown, failure, and allocator expectations
- an explicit memory/allocation model including no-alloc or bounded-allocation profile direction
- a written concurrency/execution stance for the language/runtime
- an explicit first-step concurrency model: hosted runtime, OS threads, spawn/join, channels, capability-gated concurrency, no built-in async initially
- a documented ownership/capability story across FFI/runtime boundaries
- C-compatible calling convention for `extern fn` with `#[repr(C)]` struct parameters (by-value, not pointer-only)
- empirical cross-target FFI validation (compile + link + run on x86_64 and aarch64)
- runtime-facing stdlib surfaces aligned with the chosen execution model
- a clear direction for stricter sandbox/execution profiles (`no_alloc`, bounded allocation, no ambient authority, no unrestricted FFI/trusted)
- a documented direction for verified FFI envelopes and structural boundedness reports as part of the execution-model story
- an explicit runtime-performance validation direction (profiling/perf baselines/regression expectations) aligned with the execution model

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
- [research/trust-multipliers.md](research/trust-multipliers.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)

1. improve capability and trust ergonomics — **not started**
2. deepen capability/trust reporting — **not started**
3. add stronger patterns for explicit authority wrappers and capability aliases — **not started**
4. make safety features easier to use correctly in ordinary programs without weakening honesty — **not started**
5. ensure docs, diagnostics, and reports present one coherent safety story — **not started**
6. define the shape of a high-integrity safety profile — **not started**

Deliverables:
- clearer user-facing capability and trust ergonomics in diagnostics/docs/reports
- stronger report outputs building on the current capability/trust reports for authority flow, `trusted`, and `Unsafe`
- explicit patterns for authority wrappers, aliases, and later authority-budget integration
- a documented high-integrity safety profile direction covering `Unsafe`, `trusted`, FFI, and ambient authority
- a documented direction for proof-backed authority reports, even if the first implementation remains report-first rather than proof-first

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

1. define explicit feature-admission criteria — **not started**
2. make "no" and "not yet" decisions first-class language outcomes — **not started**
3. revisit syntax and surface complexity with a bias toward simplification, not expansion — **not started**
4. keep unsafe/trusted/foreign surface area as narrow as possible — **not started**
5. make long-term language shape decisions explicit instead of letting them emerge from local convenience — **not started**
6. define a clearly analyzable critical/provable subset — **not started**

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
- [research/trust-multipliers.md](research/trust-multipliers.md)
- project/package metadata
- import resolution and project-root semantics
- stdlib vs third-party package boundaries
- workspace and dependency tooling

1. define the package and dependency model explicitly — **not started**
2. define stdlib vs third-party package boundaries — **not started**
3. define workspace and multi-package behavior — **not started**
4. make dependency and package UX part of the language-user experience — **not started**
5. ensure docs, tooling, and CI reflect the same package/project model — **not started**

Deliverables:
- a documented package/dependency model with project-root and resolution semantics
- a defined boundary between stdlib and third-party packages
- a documented workspace/multi-package model
- dependency/package tooling and CI behavior aligned with the same model
- an authority-budget path at package or subsystem boundaries
- a credible path for package- or subsystem-level capability budgets to become enforceable build policy
- a documented dependency-trust direction for packages, workspaces, and third-party inputs

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
- [research/trust-multipliers.md](research/trust-multipliers.md)
- CI config
- release/build tooling
- project/package metadata
- editor/tool integration surfaces

1. make the project and package model operationally solid — **not started**
2. add release and compatibility discipline — **not started**
3. harden reproducibility and CI operations — **not started**
4. make the distribution and installation story explicit — **not started**
5. turn docs and editor/tool integration into maintained product surfaces — **not started**
6. add explicit compatibility and bootstrap-trust policy — **not started**
7. make certification-style evidence and traceability practical — **not started**
8. make reproducible trust bundles practical if the evidence story earns it — **not started**
9. define whether evidence authenticity and build/dependency trust need explicit operational policy — **not started**

Deliverables:
- a documented release and compatibility policy for language, stdlib, reports, and tooling surfaces
- reproducible build/test/CI expectations that are operationally maintained
- an explicit distribution and installation story
- maintained baseline docs and editor/tooling expectations
- an explicit bootstrap-trust and compatibility policy
- a practical evidence/traceability story linking source, reports, proofs, and build artifacts
- a documented direction for reproducible trust bundles as the operational form of the evidence story
- a documented deprecation/migration policy for language, reports, and tooling surfaces
- an explicit direction for editor/tooling support as a maintained product surface
- an explicit operational trust policy for builds, dependencies, and evidence authenticity if trust bundles become real outputs

Exit criterion:
Concrete is not only architecturally strong internally, but also operable, reproducible, documentable, and maintainable as a long-term project.

#### Phase J: Concurrency Maturity And Runtime Plurality

Goal: give Concrete a long-term concurrency model that stays explicit, auditable, and small instead of collapsing into an "async everywhere" ecosystem.

This phase is intentionally later than Phase E.
Phase E defines the execution model and first runtime boundary.
Phase J exists to do the larger concurrency design correctly once runtime, safety, package, and operational foundations are stable enough to support it.

The intended long-term shape is:

- structured concurrency as the semantic center
- OS threads plus message passing as the base primitive
- evented I/O as a later specialized runtime model
- no unrestricted detached async ecosystem as the primary language identity

Primary surfaces:
- [research/concurrency.md](research/concurrency.md)
- [research/long-term-concurrency.md](research/long-term-concurrency.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- [research/trust-multipliers.md](research/trust-multipliers.md)
- runtime-facing stdlib surfaces
- capability/report tooling

1. stabilize the first concrete thread/channel model introduced after Phase E — **not started**
2. define explicit cross-thread transfer/shareability rules — **not started**
3. make structured concurrency the default lifecycle model for concurrent work — **not started**
4. integrate concurrency into capability reporting, boundedness reporting, and high-integrity profiles — **not started**
5. define whether and how evented I/O fits under the same explicit runtime/capability contract — **not started**
6. keep runtime plurality explicit and prevent fragmentation into incompatible concurrency cultures — **not started**

Deliverables:
- a documented long-term concurrency contract for the language/runtime
- a stable threads-plus-channels baseline with explicit ownership transfer rules
- an explicit structured-concurrency lifecycle model for ordinary concurrent work
- a documented shareability/synchronization discipline for concurrent code
- report/profile integration for concurrency, blocking, and runtime authority
- a documented evented-I/O direction that fits the same explicit contract without becoming the default for all code

Exit criterion:
Concrete has one coherent concurrency story: structured by default, threads-first underneath, message-passing biased, and able to admit specialized evented runtime models later without losing auditability or runtime clarity.

### Why These Phases Matter

- **Phase A** matters because a slow feedback loop drags down every compiler task, and backend-sensitive lowering bugs destroy trust in every other part of the compiler.
- **Phase B** matters because a compiler is much easier to trust, prove, and maintain when ordinary names stay ordinary.
- **Phase C** matters because syntax guardrails, diagnostics, and testing infrastructure are what make a compiler sustainable instead of heroic.
- **Phase D** matters because this is where Concrete stops being only a working compiler and becomes a trustworthy compiler platform, starting with testing architecture strong enough to support every later backend and proof ambition.
- **Phase E** matters because a language is not really settled until its execution model is explicit.
- **Phase F** matters because Concrete's safety model should be a user-visible strength, not only an internal design claim.
- **Phase G** matters because languages decay when feature growth has no explicit discipline.
- **Phase H** matters because package and dependency semantics are part of the language experience once real projects exist.
- **Phase I** matters because long-term projects fail just as easily from weak operational discipline as from weak compiler architecture.
- **Phase J** matters because concurrency is one of the easiest places for a language to lose clarity, and Concrete should only broaden it once it can do so without importing async fragmentation and hidden runtime culture.

### Compiler Hardening (between Phase D and Phase E)

These are concrete, implementable improvements that emerged from the bug fixes and integration testing in Phase D. They are not full phases — they are targeted hardening work that should land before Phase E begins, because Phase E (runtime/execution model) depends on the compiler being trustworthy for the patterns it already claims to support.

1. ~~**Audit Layout.lean for silent fallback defaults**~~ **Done.** All 6 `dbg_trace` fallbacks in Layout.lean converted to `panic!`, plus 1 in EmitSSA.lean. Root cause fixed: type variable leakage (`.named "T"` surviving monomorphization) eliminated by adding `substStructTypeArgs`/`substEnumTypeArgs` in Layout.lean, threading `typeArgs` through `enumPayloadOffset` and `variantFields`, and scanning function types in EmitSSA to emit substituted type defs for generic structs/enums.

2. ~~**Systematic integer type inference hardening**~~ **Done.**
   - Vec intrinsics (`vec_push`, `vec_set`, `vec_get`) now propagate element type and `Int` hints to arguments. Cast expressions confirmed to intentionally NOT propagate target type as hint. Function call args, struct field init, let bindings, comparisons, and return statements already propagate hints correctly.
   - **Defensive backend check**: `SSAVerify.checkBinOpTypes` now validates integer bit-width consistency — `i32 + i64` is caught as a binop type mismatch. This catches any integer inference gap that makes it through elaboration. Tests: `hardening_int_literal_inference.con`.

3. ~~**Linearity/borrow checker audit**~~ **Done.**
   - Tested: multiple shared borrows of same variable (`add_refs(&val, &val)` — works), borrow of struct field (`&s.x` — works), multiple `&mut` of different variables (works), sequential `&mut` borrows of same variable (works). Identified `borrowCount` as dead code and borrow-of-return-value as undocumented but not buggy. Test: `hardening_borrow_edge_cases.con`.

4. ~~**Cross-module type propagation completeness**~~ **Done.**
   - Enums: already propagate correctly — `allEnums` includes `imports.enums` in Elab.lean.
   - Trait definitions: confirmed not importable across modules (known language limitation, not a bug — dispatch works through imported wrapper functions).
   - **Type aliases**: were broken cross-module (and had a signature-resolution bug even within a single module). Fixed: `resolveImports` now handles type alias imports, `buildFileSummary` resolves aliases in function signatures, `Elab.elabFn` resolves aliases in function parameter types. Tests: `hardening_cross_module_enum.con`, `hardening_cross_module_trait.con`, `hardening_cross_module_type_alias.con`.

5. ~~**Backend error reporting instead of silent wrong code**~~ **Done.**
   - Lower.lean: 6 silent defaults converted to `throw` — `lookupStructFields`, `fieldIndex`, `variantIndex`, `variantFields`, `structNameFromTy` propagate errors through `LowerM`.
   - Layout.lean: 6 `dbg_trace` fallbacks converted to `panic!` (type variable leakage fixed — see item 1).
   - EmitSSA.lean: 1 `dbg_trace` fallback converted to `panic!`.

### Later

1. Backend plurality over SSA, but only after the current backend becomes structurally cleaner first.
2. Runtime and execution-model maturity as an explicit phase once the compiler/tooling architecture is stable enough to support it well.
3. Capability and safety productization as an explicit phase after the backend/trust foundations are strong enough.
4. Language-surface and feature-discipline work as an explicit phase once the runtime/safety direction is clear.
5. Package and dependency ecosystem as an explicit phase once stdlib/tooling/runtime direction is stable enough to support real projects well.
6. Project and operational maturity as an explicit phase once the current compiler/tooling architecture is stable enough to productize.
7. Concurrency maturity and runtime plurality as an explicit later phase once the runtime, safety, package, and operational foundations are stable enough to support it well.
8. Proof-driven narrowing of future feature additions.
9. A clearer hosted vs freestanding / `no_std` split, but only after the runtime and stdlib boundaries are more stable.
10. Execution-cost analysis as an audit/report extension.
   - structural boundedness reports first
   - abstract cost estimation later
   - never at the cost of clarity in the core language
11. Broaden the Lean-side proof workflow beyond the current pure-fragment scope (17 theorems over integers/booleans/arithmetic/conditionals). Next targets: structs, enums, match expressions, recursive functions, source-to-Core traceability, and export/tooling for external proof use.
12. Potential later expansion of the Lean proof story beyond Core-level properties.
   - later broaden selected-function proofs toward effects, resources, capabilities, runtime interaction, and only then concurrency
   - later consider backend-level proof concerns such as richer compiler-preservation work across deeper lowering stacks or optional backend-family layers
   - do not treat either broader end-to-end program proofs or backend/MLIR-layer proof work as near-term substitutes for the validated-Core-first plan
13. Treat contracts, richer invariants, and similar verification extensions as post-roadmap evaluation work, not as part of the main current philosophy.
   - only evaluate them after the simpler Concrete + Lean 4 proof story has proven insufficient
   - keep them out of the main phase plan until the core language, proof boundary, runtime model, and operational story are already stable
   - if adopted at all, treat them as a final optional verification-extension stage rather than as a prerequisite for the main roadmap
14. Implement a real artificial-life showcase/stress-test in Concrete.
   - target a program in the spirit of Rabrg's `artificial-life` reproduction of "Computational Life: How Well-formed, Self-replicating Programs Emerge from Simple Interaction"
   - a 240x135 grid of 64-instruction Brainfuck-like programs, randomly initialized, locally paired, concatenated, executed for bounded steps, then split back apart
   - use it as a serious end-to-end stress test for runtime/performance, collections/buffers, formatting/reporting, and later proof/audit ambitions
   - treat it as a showcase workload once the runtime, stdlib, and backend are mature enough rather than as immediate Phase C compiler work
15. Develop proof-backed authority reports as a later extension of the current capability/trust reports.
   - make it explicit which authority facts are compiler-checked, which depend on validated Core extraction, and which still rest on trusted/foreign assumptions
   - keep the first versions narrow and high-signal rather than pretending to prove the whole world
16. Move toward verified FFI envelopes once the runtime/ABI boundary is explicit.
   - make foreign boundaries carry ABI, ownership, destruction, and capability assumptions more explicitly than raw `extern fn`
   - prefer wrapper/envelope approaches over broad new surface syntax
17. Treat reproducible trust bundles as the operational destination of the evidence story.
   - package reports, proof references, build identity, and artifact fingerprints together for audit/review workflows
   - only do this once the package/runtime/compatibility story is stable enough to make the bundle worth trusting
18. Treat performance and incrementality as an explicit later maturity thread rather than ambient compiler folklore.
   - define profiling methodology and performance regression expectations
   - make optimization policy explicit enough that "faster" does not silently trade away auditability or proof-friendliness
   - only add artifact serialization and incremental compilation once the artifact boundaries and compatibility story are boring enough to sustain them

## Backend Work Order

The structured LLVM backend and SSA backend contract are done. Remaining backend work in priority order:

1. ~~Replace direct LLVM IR text emission with a structured LLVM backend.~~ **Done** — EmitSSA emits structured LLVM IR through `LLVMTy`/`LLVMFnDecl`/`SInst` types, not string concatenation.
2. ~~Document the SSA backend contract.~~ **Done** — SSAVerify guarantees, SSACleanup postconditions, EmitSSA preconditions documented in `docs/PASSES.md`.
3. Close the calling convention gap for `extern fn` with struct parameters (Phase E item 6) — **not started**
4. Make backend plurality explicit over the SSA boundary — **not started**
5. Only then evaluate additional backend families such as C or Wasm — **not started**
6. Treat MLIR as optional and only if it earns its complexity — **not started**

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
   - later, structural boundedness facts and proof-backed authority summaries
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
   - later, stricter capability sandbox profiles and authority budgets

For more on these longer-horizon themes, see:
- [research/ten-x-improvements.md](research/ten-x-improvements.md)
- [research/capability-sandboxing.md](research/capability-sandboxing.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)
- [research/long-term-concurrency.md](research/long-term-concurrency.md)
- [research/complete-language-system.md](research/complete-language-system.md)

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
- formalization has started (`Concrete/Proof.lean` with 17 theorems over a pure Core fragment), but the proof scope is still narrow — structs, enums, match, and recursive functions are not yet covered, and source-to-Core traceability is not yet implemented
- **type coercion gaps**: SSAVerify now catches integer bit-width mismatches (`i32 + i64`) as a defensive backend check, so inference gaps that survive elaboration are caught before codegen. The elaborator's hint propagation covers common paths but hasn't been proven exhaustive.
- **linearity checker**: borrow edge cases (multiple shared borrows, sequential &mut, borrow-of-field) are tested and work. `borrowCount` is dead code. The checker is less over-conservative than initially feared, but hasn't been formally audited.

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

Concrete has a complete compiler pipeline, a real stdlib (33 modules, 16 collections), 663 tests (184 stdlib), a fully structured LLVM backend, audit reports, explicit artifact boundaries (`ValidatedCore`, `ProofCore`), a documented SSA backend contract, a first Lean 4 proof workflow (17 theorems over a pure Core fragment), a 20-program integration/regression/hardening corpus, and bug tracking in `docs/bugs/`. Phases A–D are done. Three compiler bugs (cross-module struct offsets, i32 literal type inference, borrow-move confusion) were found and fixed during Phase D integration testing. Compiler hardening complete: Lower.lean fallbacks are hard errors (`throw`), Layout.lean/EmitSSA.lean fallbacks are hard errors (`panic!`) with type variable leakage fixed, SSAVerify catches integer bit-width mismatches, cross-module type aliases fixed, borrow checker audited. Phase E (runtime and execution model) is next.
