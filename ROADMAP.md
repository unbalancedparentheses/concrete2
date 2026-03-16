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
For the safety model (capabilities, trusted, Unsafe, proof boundary, high-integrity profile), see [docs/SAFETY.md](docs/SAFETY.md).
For current language and subsystem references, see:
- [docs/FFI.md](docs/FFI.md)
- [docs/ABI.md](docs/ABI.md)
- [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md)
- [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md)

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
- a real artifact-driven compiler driver with stable serialized artifacts, stable IDs, and source-to-Core traceability

## Priority Snapshot

### Milestones

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
| **L** | Project and operational maturity | Not started |
| **M** | Concurrency maturity and runtime plurality | Not started |
| **N** | Allocation profiles and bounded allocation | Not started |
| **O** | Research phase and evidence-gated features | Not started |

### Cross-Phase Carry-Overs

Completed phases can still seed work that is intentionally finished later. Do not reopen those phases unless their original exit criteria were wrong. Track the carry-over here instead.

| Item | First Real Shape | Current Owning Phase | Status |
|------|------------------|---------------------|--------|
| Empirical cross-target FFI/ABI validation | **E** | **J / L** | Not started |
| Verified FFI envelopes as a real user-facing boundary product | **E** | **L** | Research / partial direction only |
| Structural boundedness reports as a real maintained report mode | **E** | **N** | Not started |
| Capability sandbox profiles as enforced build/profile contracts | **E** | **N / O** | Research / partial direction only |
| Proof-backed authority reports tied to validated Core / proof-facing evidence | **F** | **I** | Not started |
| Authority budgets as enforceable package/subsystem contracts | **F** | **J** | Research only |
| Artifact-driven compiler driver with stable artifact IDs, serialization, interface/body splits, and build-graph orchestration | **D** | **J / L** | Partial only |
| Machine-readable reports as a maintained surface | **D / F** | **L** | Not started |
| Report-first review workflows over authority / alloc / layout / trusted / FFI evidence | **F** | **L** | Research only |
| Reproducible trust bundles linking source, compiler, reports, proofs, and artifact identity | **I** | **L** | Not started |
| Package/release trust-drift diffing | **J** | **L** | Not started |
| Serious showcase workload turned into a flagship public review artifact | **H** | **K** | Not started |

### Recent Progress

- **Cross-cutting differentiator ideas now have explicit phase ownership**: proof-carrying audit artifacts, authority budgets as build contracts, verified FFI envelopes, structural boundedness reports, reproducible trust bundles, serious showcase workloads, capability sandbox profiles, proof-backed authority reports, machine-readable reports, report-first review workflows, and trust-drift diffing should all live in named phases rather than only in scattered research notes.
- **Phase E complete** (all 11 items): `docs/EXECUTION_MODEL.md` is the central reference. Covers hosted/freestanding model, runtime boundary, abort-on-OOM (builtins + stdlib), FFI ownership boundary, `#[repr(C)]` by-value calling convention for extern fn, target/platform support policy, stdlib execution model alignment, execution profiles direction, performance validation direction, verified FFI envelopes direction, and concurrency design (threads-first, structured, capability-gated).
- **Test runner parallelized and narrowed** (commits `1619220`, `6049d89`): `run_tests.sh` defaults to parallel (`nproc` cores), adds `--fast` (default), `--full`, `--filter`, `--stdlib`, `--O2`, `--codegen`, `--report` modes. Partial runs warn clearly. `--fast` is the documented standard developer workflow. This is a strong Phase A solution, but it is still script-level orchestration rather than a deeper artifact-cached or dependency-aware test system.
- **Aggregate loop lowering hardened** (commit `e68acc0`): aggregate loop variables promoted to entry-block allocas. Field assignment GEPs directly into stable storage.
- **Aggregate if/else and match lowering hardened** (commit `8e606d9`): if/else branches with modified struct variables merge via entry-block allocas instead of `phi %Struct`. Match arms get var snapshot/restore between arms. Void-typed match results filtered from phi/store paths.
- **Void-in-phi codegen bug fixed**: a branch-inside-loop case that called a void function was incorrectly producing `phi ptr [void, ...]` in LLVM IR. Regression coverage now exists for that shape.
- **SSA verifier now rejects aggregate phi nodes**: `SSAVerify.lean` checks that no phi node carries an aggregate type (struct, enum, string, array). This is a mechanical invariant, not just regression coverage.
- **Audit**: all phi emission sites in Lower.lean confirmed to check `isAggregateForPromotion` before creating phi nodes. No remaining accidental aggregate transport found.
- **Stdlib test depth increased**: Option, Result, Text, and Slice now have broader in-language test coverage.
- **Linearity checker fixed for generic types**: four fixes to `Check.lean` unblock user-defined generic collections with function pointer fields:
  - `isCopyType` now correctly handles `.generic` (struct isCopy lookup) and `.typeVar` (Copy bound check) instead of returning false for all generics
  - ~~trusted functions could consume linear variables inside loops~~ (removed in Phase G: trusted is now strictly pointer-ops containment)
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
  - **ABI maturity statement**: `docs/ABI.md` — stability matrix, platform assumptions (64-bit only), FFI safety model, struct/enum layout rules, known limitations section. `#[repr(C)]` structs have C-compatible layout and are passed by value in `extern fn` calls (Phase E item 5 closed the calling convention gap).
  - **Layout verification tests**: 4 tests in `PipelineTest.lean` — scalar sizes/alignments (17 checks), builtin sizes (String/Vec/HashMap), repr(C) struct layout (field offsets + packed variant), pass-by-pointer decisions (10 type checks). Model-based (Lean helpers), not empirical cross-target.
- **Phase D item 5 complete** (real-program corpus growth):
  - **4 new integration programs**: calculator (3-module RPN evaluator with trait dispatch, 200 lines), type registry (3-module catalog with validation/metrics, 248 lines), pipeline processor (4-module data transformation, 223 lines), stress workload (4-module bytecode interpreter with 11-variant enum, 280 lines).
  - Programs exercise: cross-module function calls, Vec<i32> with vec_set for stack semantics, enum matching (up to 11 variants), trait dispatch, generic functions, capability propagation, while loops, numeric computation chains.
  - Integration corpus now 12 programs (was 8), including stress-style workload.
- **Phase D item 7 complete** (deferred audit reports):
  - **Next report modes named**: `--report authority` (transitive capability analysis), `--report proof` (ProofCore eligibility), `--report high-integrity` (deferred to Phase F). Documented in `docs/PASSES.md`.
  - **59 report assertions stable**: all 8 report modes (caps, unsafe, layout, interface, alloc, mono, authority, proof) regression-tested with semantic grep patterns, not brittle snapshots. Cross-validation test verifies layout report sizes match runtime sizeof.
- **3 compiler bugs fixed** (discovered during integration test writing):
  - **Cross-module struct field offset** (`Elab.lean`): imported struct definitions were missing from `CModule`, causing `Layout.fieldOffset` to return 0 for all fields. Fix: include imported structs in CModule output.
  - **i32 literal type mismatch** (`Elab.lean`): integer literals defaulted to i64 in binary ops with i32 operands, producing LLVM type mismatches. Fix: re-elaborate literal with concrete operand type when types differ.
  - **Cross-module &mut borrow consumed as move** (`Check.lean`): function call argument processing consumed variables even for reference parameters. Fix: skip consumption for `&T`/`&mut T` parameter types.
  - Bug documentation in `docs/bugs/`, regression tests in `lean_tests/bug_*.con`.
  - **Bug 004 — Array variable-index assignment** (`Lower.lean:1460`): `arr[i] = val` with runtime variable `i` generated GEP with wrong base type (`i64` instead of element type) and wrong store width. Literal indices worked correctly. Documented in `docs/bugs/004_array_variable_index_assign.md`, reproduction test in `lean_tests/bug_array_var_index_assign.con`. Status: **fixed**.
  - **Bug 005 — Enum fields inside structs can panic layout computation** (`Layout.lean`): named structs containing enum-typed fields can crash layout/alignment computation instead of lowering correctly. Discovered during Phase H policy-engine work when a `Rule` struct with `Action`/`Verdict` enum fields was pushed through collection-oriented layout pressure. Documented in `docs/bugs/005_enum_field_struct_layout_panic.md`. Status: **fixed**.
  - **Bug 006 — Cross-module string literal name collisions** (`Lower.lean`): different modules could emit conflicting `@str.N` globals, causing corrupt strings and crashes in cross-module string flows. Documented in `docs/bugs/006_cross_module_string_literal_collision.md`. Status: **fixed**.
  - **Bug 007 — No easy print path for standalone programs**: added `print_string`, `print_int`, `print_char` builtins with `Console` capability. User-defined functions take precedence. Documented in `docs/bugs/007_no_print_string_builtin.md`. Status: **fixed**.
  - **Bug 008 — If-else expressions**: if-else now works as an expression (`let x = if cond { a } else { b };`). Added `ifExpr` to AST/Core, `parseExprBlock` in parser, elaboration, and lowering with alloca+condBr+store+load pattern and proper type casts. Documented in `docs/bugs/008_if_else_expression_aggregate_types.md`. Status: **fixed**.
  - **Bug 009 — `const` declarations parsed but not lowered**: constants now inline correctly during lowering. Added `constants` field to `LowerState` and constant lookup in `lowerExpr` `.ident` handler. Documented in `docs/bugs/009_const_declarations_not_lowered.md`. Status: **fixed**.
- **Compiler hardening pass complete** (all 5 items):
  - **Lower.lean errors**: 6 silent defaults converted to `throw` — `lookupStructFields`, `fieldIndex`, `variantIndex`, `variantFields`, `structNameFromTy` propagate errors through `LowerM`. `lowerModule` returns `Except String SModule` — failed function lowering is now a compile error.
  - **Layout/EmitSSA hard errors**: all `dbg_trace` fallback defaults converted to `panic!` (6 in Layout.lean, 1 in EmitSSA.lean). Previously impossible because generic struct/enum definitions survived monomorphization with unsubstituted type variables (`.named "T"`). Fixed by: (a) adding `substStructTypeArgs` in Layout.lean (parallel to existing `substEnumTypeArgs`), applied in `tySize`, `tyAlign`, and `fieldOffset`; (b) adding `typeArgs` parameter to `enumPayloadOffset`, threading concrete type args from Lower.lean through 3 call sites; (c) substituting type args in `variantFields` before passing fields to `variantFieldOffset`; (d) scanning function types in EmitSSA to emit substituted type defs for generic structs/enums instead of skipping them; (e) erasing newtypes in imported function signatures at module boundaries.
  - **Integer inference**: vec intrinsic hint propagation + defensive SSAVerify check catches integer bit-width mismatches (`i32 + i64`).
  - **Borrow edge cases**: tested and working.
  - **Cross-module types**: enums, traits (via wrappers), type aliases, and newtypes all work. Type alias bug fixed — was broken even in single-module usage (function signatures carried unresolved alias names). Newtype erasure at import boundaries prevents leaked newtype names from reaching Layout/EmitSSA.
  - Hardening tests in `lean_tests/hardening_*.con`.
- 663 tests pass (184 stdlib), including 32 pass-level Lean tests, 44 report assertions, 46 golden tests, 20 integration/regression/hardening tests, and 16 collections verified.
- **Phase 3 testing complete** (system-level validation): 864 tests pass. Added 6 large mixed-feature programs (200-340 lines each), ~75 O2 differential tests, 20 report consistency cross-checks, ABI interop test (Concrete↔C sizeof/offsetof), 5 diagnostic quality tests, `test_fuzz.sh` (1500 programs: parser/typecheck/valid), `test_perf.sh` (compile time/runtime/IR size/binary size regression tracking).

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

## Cross-Cutting Idea Placement

These ideas are important enough that they should always have an explicit roadmap home, even when the implementation work remains exploratory.

- **Phase E** owns verified FFI envelopes, structural boundedness reports, and capability sandbox profiles as part of the execution-model and runtime-safety story.
- **Phase F** owns proof-backed authority reports as part of the safety/reporting product surface.
- **Phase H** owns serious showcase workloads and the first real pressure-testing of whether reports, authority boundaries, and evidence remain useful under sustained real code.
- **Phase I** owns proof-carrying audit artifacts: the first credible tie between validated Core, proof eligibility, selected proof references, and user-facing review artifacts.
- **Phase J** owns authority budgets as enforced build contracts at package/subsystem boundaries, because packages are where authority drift stops being only a local function concern.
- **Phase K** owns the public-facing flagship workload and review narrative that demonstrates why Concrete is different in practice, not only in architecture notes.
- **Phase L** owns machine-readable reports, report-first review workflows, reproducible trust bundles, and trust-drift diffing as maintained operational surfaces.
- **Phase O** owns any remaining evidence-gated extensions that still need staging before they deserve stable implementation contracts.

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

**Exit criterion met:** syntax guardrails, diagnostics, stdlib testing, and audit reports behave like durable infrastructure. The LL(1) grammar checker runs in CI. Module-targeted stdlib testing is real (`--stdlib-module <name>`). Integration tests exercise multi-collection pipelines and all 8 report modes. Report outputs are regression-tested with 59 content assertions. Audit reports explain capability authority, trust boundaries, allocation patterns, transitive authority chains, and proof eligibility through ordinary compiler workflows.

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
2. linearity checker fixed for generic types (isCopyType, self-consumption, if-return divergence; the later trusted-loop relaxation was removed in Phase G)
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
Also still missing from the architecture despite the named artifact types: fully artifact-driven pass plumbing, stable artifact identity, serialization/versioning, and a stronger compiler-driver/build-graph layer. These are tracked later in Phases H/J and the proof/evidence thread.
3. ~~strengthen the SSA verifier/cleanup boundary into a clearer backend contract~~ **Done** (D2): SSA backend contract documented in `docs/PASSES.md` — SSAVerify guarantees (8 invariants), SSACleanup guarantees (8 postconditions), EmitSSA assumptions (5 preconditions), invariant chain.
4. ~~define a clearer FFI / ABI maturity path~~ **Done**: `docs/ABI.md` — stability matrix, platform assumptions (64-bit only), FFI safety model, struct layout rules (repr(C)/packed/align), enum representation, pass-by-pointer convention for internal calls, by-value passing for `#[repr(C)]` structs in `extern fn` calls (Phase E item 5). 4 layout verification tests in `PipelineTest.lean` (scalar sizes, builtin sizes, repr(C) layout, pass-by-ptr decisions). Layout model assumptions are verified against Lean helpers, not by empirical cross-target compilation.
5. ~~grow a stronger real-program and invariant-testing corpus on top of the faster loop~~ **Done**: 4 new integration programs (calculator 200 lines, type registry 248 lines, pipeline processor 223 lines, stress bytecode interpreter 280 lines). Integration corpus now 12 programs. Stress workload exercises 11-variant enum, multiple Vec instances, 21-instruction execution loop, cross-module types/functions. Programs discovered 3 compiler bugs (all now fixed — see `docs/bugs/`): cross-module struct field offset, i32 literal type mismatch, and cross-module &mut borrow consumed as move.
6. ~~push formalization over Core -> SSA~~ **Done** (D2): `ValidatedCore` explicit in `Pipeline.lean`, `ProofCore` extraction in `ProofCore.lean`, formal evaluation semantics in `Proof.lean` with 17 proven theorems (abs/max/clamp correctness, structural lemmas, arithmetic). Source-to-Core traceability and proof fragment extension (structs, enums, match, recursion) remain as future work.
7. ~~add deferred audit/report outputs~~ **Done**: all 8 report modes implemented — `--report authority` (transitive authority with BFS chain traces), `--report proof` (ProofCore eligibility), plus original 6 (caps, unsafe, layout, interface, alloc, mono). `--report high-integrity` deferred to Phase F. Regression-tested with 59 stable semantic assertions.

Exit criterion:
backend work no longer feels fragile, proofs, reports, and tooling all build on the same stable compiler boundaries, targeted test runs are artifact-aware and dependency-aware, failures are easy to isolate and rerun, semantic tests avoid unnecessary full-pipeline cost, pass-level and end-to-end testing play distinct roles under explicit coverage/determinism rules, and selected Concrete functions can actually be proved in Lean 4 over validated Core.

#### Phase E: Runtime And Execution Model

Goal: make the language's execution model explicit instead of leaving runtime behavior and environment assumptions as a loose later concern.

This phase begins the high-integrity profile direction:

- explicit execution restrictions
- bounded/no-allocation modes
- analyzable concurrency constraints
- a runtime story that can later support critical-system use without pretending every feature belongs everywhere

Order inside this phase matters:

- first settle the runtime contract (environment, failure, allocation, FFI/runtime boundary, ABI, target policy)
- then align stdlib/profile/performance consequences with that contract
- only then define the initial concurrency stance that sits on top of the settled runtime model

Primary surfaces:
- [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md)
- [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md)
- [docs/STDLIB.md](docs/STDLIB.md)
- [research/concurrency.md](research/concurrency.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- [research/no-std-freestanding.md](research/no-std-freestanding.md)
- [research/trust-multipliers.md](research/trust-multipliers.md)
- runtime-facing stdlib and FFI boundaries

1. define the hosted vs freestanding model more explicitly — **done** — `docs/EXECUTION_MODEL.md` documents hosted-only target, stdlib layer classification (core/alloc/hosted), future freestanding direction
2. make the runtime boundary explicit — **done** — `docs/EXECUTION_MODEL.md` documents startup/shutdown/failure model, external symbol dependencies, no runtime initialization, no panic/unwind
3. define the memory / allocation strategy explicitly — **done** — `docs/EXECUTION_MODEL.md` documents libc malloc model, capability-tracked allocation, deallocation model; abort-on-OOM implemented in both compiler builtins (`__concrete_check_oom`) and stdlib wrappers (`std.alloc` heap_new/grow null-check + abort)
4. tighten the FFI/runtime ownership boundary — **done** — `docs/EXECUTION_MODEL.md` documents capability model at FFI boundary, ownership tracking across FFI calls (by-value consumes, by-ref borrows, raw pointers untracked), known gaps and future directions
5. close the FFI/ABI calling convention gaps (from Phase D Known Limitations) — **done** (calling convention fix landed; empirical cross-target validation deferred to Phase F) — `EmitSSA.lean` now detects extern fn calls and passes `#[repr(C)]` struct arguments by value (C ABI) instead of always by pointer; `externParamTyToLLVMTy` + `isReprCStruct` distinguish extern vs internal calling convention
6. define target/platform support policy explicitly — **done** — `docs/EXECUTION_MODEL.md` documents target profile (64-bit, POSIX), three-tier support model (Tier 1/2/Experimental), target-dependent components, empirical validation gaps
7. make runtime-related stdlib surfaces reflect the chosen execution model — **done** — `docs/EXECUTION_MODEL.md` documents full module-to-layer mapping with capabilities and host dependencies; `docs/STDLIB.md` updated with execution model alignment section
8. define execution profiles for high-integrity use — **done** — `docs/EXECUTION_MODEL.md` documents planned profiles (`no_alloc`, `bounded_alloc`, `no_unsafe`, `no_ffi`, `high_integrity`), enforcement via capability system, relationship to proofs
9. define how runtime-sensitive performance validation should work — **done** — `docs/EXECUTION_MODEL.md` documents performance principles, metrics, regression thresholds, and future directions (compile-time baselines, integration timing)
10. make room for verified FFI envelopes and structural boundedness reporting — **done** — `docs/EXECUTION_MODEL.md` documents FFI envelope direction (parameter checking, null safety, ownership transfer), structural boundedness properties (allocation-free, stack-bounded, terminating), existing report capabilities, and what's needed
11. define the concurrency and execution story deliberately — **done** — `docs/EXECUTION_MODEL.md` documents design principles (explicit, structured, threads-first, capability-gated), first concurrency model (OS threads, spawn/join, channels, move ownership), staging plan, and what to avoid

Deliverables:
- a documented hosted vs freestanding execution model
- a documented runtime boundary covering startup, shutdown, failure, and allocator expectations
- an explicit memory/allocation model including no-alloc or bounded-allocation profile direction
- a documented ownership/capability story across FFI/runtime boundaries
- C-compatible calling convention for `extern fn` with `#[repr(C)]` struct parameters (by-value, not pointer-only) — **done**
- empirical cross-target FFI validation (compile + link + run on x86_64 and aarch64) — **deferred to Phase F**
- a documented target/platform policy covering supported architectures, target tiers, ABI assumptions, and what counts as supported vs experimental
- runtime-facing stdlib surfaces aligned with the chosen execution model
- a clear direction for stricter sandbox/execution profiles (`no_alloc`, bounded allocation, no ambient authority, no unrestricted FFI/trusted)
- an explicit runtime-performance validation direction (profiling/perf baselines/regression expectations) aligned with the execution model
- a documented direction for verified FFI envelopes and structural boundedness reports as part of the execution-model story
- a written concurrency/execution stance for the language/runtime
- an explicit first-step concurrency model: hosted runtime, OS threads, spawn/join, channels, capability-gated concurrency, no built-in async initially

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
- [research/developer-tooling.md](research/developer-tooling.md)
- [research/trust-multipliers.md](research/trust-multipliers.md)
- [research/unsafe-structure.md](research/unsafe-structure.md)

1. improve capability and trust ergonomics — **done** — added actionable hints to all capability-related error messages in both Check.lean and CoreCheck.lean: `missingCapability` (suggests `with(Cap)` on calling function or trusted wrapper), `insufficientCapabilities` (same), `cannotInferCapVariable` (explains explicit capability binding), pointer/alloc operation errors (specific `with(Unsafe)` or `with(Alloc)` hints)
2. deepen capability/trust reporting — **done** — `--report authority` (transitive authority analysis with BFS call-chain traces per capability) and `--report proof` (ProofCore eligibility with exclusion reasons: capabilities, trusted, extern, raw pointers) implemented in `Report.lean`, dispatched from `Main.lean`, regression-tested with 15 semantic assertions
3. add stronger patterns for explicit authority wrappers and capability aliases — **done** — `cap IO = File + Console;` syntax parsed and expanded at parse time, transparent to Check/Elab/CoreCheck. Validates cap names at definition, supports `Std` macro, supports `pub cap`. Authority wrapper patterns documented in `docs/FFI.md` with stdlib examples (`trusted impl Vec`, `trusted impl TextFile`, etc.). 3 regression tests
4. make safety features easier to use correctly in ordinary programs without weakening honesty — **done** — cap aliases reduce signature repetition, per-statement error recovery reports multiple errors per function, actionable capability hints suggest specific fixes. Wrapper patterns documented in `docs/FFI.md`. Safety model unified in `docs/SAFETY.md`
5. ensure docs, diagnostics, and reports present one coherent safety story — **done** — created `docs/SAFETY.md` as the central safety reference: defines the three-way split (capabilities / trusted / Unsafe), documents all 8 report modes, error model, proof boundary, and high-integrity profile direction. Cross-references added from VALUE_MODEL.md, STDLIB.md, IDENTITY.md, DIAGNOSTICS.md, EXECUTION_MODEL.md, ARCHITECTURE.md, FFI.md, PASSES.md. Stale ABI_LAYOUT.md references replaced with ABI.md
6. define the shape of a high-integrity safety profile — **done** — `docs/SAFETY.md` defines the profile direction: same language under stricter restrictions (no Unsafe, no unrestricted FFI, no/bounded allocation, no ambient authority growth, analyzable concurrency, stronger evidence). Documents what the compiler must provide (profile-aware checks, reports, package visibility, proof relation). Connects to existing capabilities, trusted boundaries, linearity, ProofCore, and reports
7. improve bounded semantic error recovery so ordinary users get more than one useful body-local diagnostic without sacrificing honesty — **done** — `checkStmts` (Check.lean) and `elabStmts` (Elab.lean) now catch per-statement errors, restore env on failure, add placeholder types for failed let-declarations, and accumulate all diagnostics before throwing. 4 regression tests verify multi-error reporting from single function bodies

Deliverables:
- clearer user-facing capability and trust ergonomics in diagnostics/docs/reports
- stronger report outputs building on the current capability/trust reports for authority flow, `trusted`, and `Unsafe`
- explicit patterns for authority wrappers, aliases, and later authority-budget integration
- a documented high-integrity safety profile direction covering `Unsafe`, `trusted`, FFI, and ambient authority
- a documented direction for proof-backed authority reports, even if the first implementation remains report-first rather than proof-first
- bounded semantic recovery in Check and Elab so that independent errors inside a function body are collected instead of stopping at the first one — without guessing or cascading nonsense errors

Exit criterion:
Concrete's capability and trust model is not only sound in principle, but also understandable, auditable, and practical for users.

#### Phase G: Language Surface And Feature Discipline

Goal: keep the language small, coherent, and intentionally shaped instead of letting features accumulate opportunistically.

This phase is where an eventual critical/provable subset becomes a real language-design commitment instead of only a later hope.

Primary surfaces:
- [docs/DESIGN_POLICY.md](docs/DESIGN_POLICY.md) — feature admission criteria (promoted from research/design-filters.md)
- [docs/DECISIONS.md](docs/DECISIONS.md) — recorded "no" and "not yet" decisions
- [docs/LANGUAGE_SHAPE.md](docs/LANGUAGE_SHAPE.md) — long-term language shape commitments
- [docs/PROVABLE_SUBSET.md](docs/PROVABLE_SUBSET.md) — proof-eligible subset definition
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- language-design research notes

1. define explicit feature-admission criteria — **done**
   - promoted `research/design-filters.md` to `docs/DESIGN_POLICY.md` as standing policy
   - 10-point admission checklist, quick decision rule, one-line test, high-leverage priorities
2. make "no" and "not yet" decisions first-class language outcomes — **done**
   - created `docs/DECISIONS.md` with permanent decisions (no closures, no trait objects, no source-generating macros, no hidden dynamic dispatch, no inference-heavy abstraction, trusted = pointer containment only) and deferred decisions (freestanding mode, capability hiding, concurrency, pre/post conditions, derived equality, package model)
   - each entry records status, rationale, what Concrete does instead, and prerequisites for deferred items
3. revisit syntax and surface complexity with a bias toward simplification, not expansion — **done**
   - removed `main!()` / `fn name!()` bang sugar from parser, AST, and all .con files (70+ files migrated to explicit `with(Std)` / `with(Alloc)`)
   - added union example test (`union_basic.con`) to validate union feature with trusted access pattern
   - fixed 5 heap/recursive test failures caused by stale bang syntax
4. keep unsafe/trusted/foreign surface area as narrow as possible — **done**
   - removed loop-linear exception from `trusted` (was the only non-pointer privilege, muddied the semantics)
   - `trusted` now means exactly one thing: audited pointer-level containment (pointer arithmetic, deref, assign, cast without `with(Unsafe)`)
   - `trusted` is no longer a general-purpose escape hatch — it does not suppress capabilities, does not permit extern calls, and does not relax linearity
   - documented the refined model in SAFETY.md and CHANGELOG
5. make long-term language shape decisions explicit instead of letting them emerge from local convenience — **done**
   - created `docs/LANGUAGE_SHAPE.md` documenting structural commitments (dispatch model, authority model, trust model, ownership model, compilation model, phase separation), what Concrete will not become, what may change with evidence, and shape principles
   - synthesizes IDENTITY.md, DESIGN_POLICY.md, DECISIONS.md, SAFETY.md into a single coherent picture
6. define a clearly analyzable critical/provable subset — **done**
   - created `docs/PROVABLE_SUBSET.md` as the standing reference for the proof-eligible subset
   - documents the current `ProofCore` extraction boundary, the stricter `--report proof` heuristic, safe ADT criteria, pipeline position, current proved properties (17 theorems), relationship to high-integrity profile, and design constraints from permanent language decisions
   - cross-referenced from SAFETY.md, ARCHITECTURE.md, LANGUAGE_SHAPE.md

Deliverables:
- explicit feature-admission criteria used as a standing design filter
- a documented set of first-class "no" and "not yet" language decisions
- a reviewed language-surface simplification pass where needed
- a documented analyzable critical/provable subset if Concrete continues toward higher-integrity domains

Exit criterion:
Concrete has an explicit discipline for preserving a small, coherent language surface and resisting low-leverage feature growth.

#### Phase H: Real-Program Pressure Testing And Performance Validation

Goal: force Concrete to prove itself under sustained use by writing multiple real programs in the 10k-30k line range and using them to expose language, stdlib, correctness, auditability, performance, and workflow weaknesses.

This phase is intentionally after language-discipline work and before packages/adoption harden too much around toy-scale assumptions. The point is to stop evaluating Concrete only through pass tests, integration tests, and medium examples.

Primary surfaces:
- large Concrete programs and example repos
- [docs/STDLIB.md](docs/STDLIB.md)
- [docs/TESTING.md](docs/TESTING.md)
- [research/comparative-program-suite.md](research/comparative-program-suite.md)
- [research/showcase-workloads.md](research/showcase-workloads.md)
- performance validation notes
- package/workspace and report workflows as they exist at that point

1. write multiple real programs in the 10k-30k line range, not only stress tests or compiler fixtures — **not started**
2. choose programs with different pressure shapes: parser/validator/policy engine, systems utility, data-structure-heavy workload, networked or service-style component, one high-integrity-profile candidate, and at least one well-known interpreter/runtime workload (for example a MAL-style Lisp) — **not started**
   - do not treat the suite as 20 equal examples; treat it as a ladder where each program is chosen to expose a different maturity boundary
   - optimize for:
     - different pressure shapes
     - external comparability
     - a clear “why Concrete?” signal
     - enough overlap for findings to compound without filling the suite with duplicates
   - the first implementation tranche should be explicit, not implicit:
     1. policy/rule engine
     2. MAL-style Lisp interpreter
     3. JSON parser + validator
     4. grep-like text search tool
     5. bytecode VM / interpreter
     6. artifact/update verifier
   - this first wave should be treated as the real proof ladder:
     - policy/rule engine proves the authority/auditability niche
     - MAL proves parser/runtime/interpreter pressure
     - JSON and grep prove text/parser/streaming reality
     - bytecode VM proves control-flow/runtime/codegen pressure
     - artifact verifier returns to Concrete’s intended critical-software niche
   - the second wave should be explicit too:
     1. regex engine
     2. Lox interpreter
     3. small TCP/HTTP service
     4. file tree scanner + policy checker
     5. package/archive indexer
     6. HSM/key-use policy engine
   - if the suite needs to be cut down to the highest-value 12, keep:
     1. policy/rule engine
     2. MAL-style Lisp interpreter
     3. JSON parser + validator
     4. grep-like text search tool
     5. bytecode VM / interpreter
     6. artifact/update verifier
     7. regex engine
     8. small TCP/HTTP service
     9. Lox interpreter
     10. file tree scanner + policy checker
     11. package/archive indexer
     12. HSM/key-use policy engine
   - this is a reordering and prioritization, not a replacement: MAL moves up to second, and the highest-value runtime/text/identity workloads move into the early ladder
   - the phase should also maintain an explicit external-tested workload track so Concrete is measured against known specs and known tests, not only self-chosen examples:
     - MAL (Make a Lisp) as the preferred staged interpreter/runtime workload
     - Lox / Crafting Interpreters as the second major interpreter target
     - TOML parser as the next structured-parser workload with strong shared corpora
     - SQLite-style miniature database projects as a harder but high-value storage/runtime workload
     - Wren / Lua-style small VM/interpreter clones for recognizable bytecode/runtime pressure
     - Scheme/Lisp educational interpreters (SICP/Norvig-style) as secondary interpreter references, even if MAL remains the preferred Lisp target
     - regex engine projects for parser + automata + performance pressure
     - JSON test suites for parser/validator conformance
     - TOML / YAML / CSV parser suites, with TOML as the strongest shared-corpus target
     - WASM interpreter / validator subsets as a long-term semantics/runtime validation workload
     - Brainfuck interpreters as compact control-flow baselines, even if they are too toy-like to be a flagship workload
   - de-prioritize:
     - Brainfuck as a major deliverable
     - multiple near-duplicate Lisp/Scheme interpreters
     - too many pure algorithm benchmarks
     - programs that mostly test LLVM instead of Concrete
     - examples that require large amounts of ecosystem glue before they reveal meaningful language pressure
3. use those programs to drive stdlib gap discovery, diagnostics pain points, package/workspace friction, report UX problems, and readability failures under sustained use — **not started**
   - current findings already justify the phase:
     - ~~real compiler blocker: enum fields inside structs can still panic layout (`Bug 005`)~~ — **fixed**
     - ~~real standalone UX blocker: printing exists in stdlib, but standalone programs lack an easy print path without project/std setup (`Bug 007`)~~ — **fixed**: `print_string`/`print_int`/`print_char` builtins added
     - fixed by real-program pressure: cross-module string literal collisions (`Bug 006`)
     - ~~MAL exposed parser/runtime-specific gaps that should be fixed quickly:~~ — **all fixed**
       - ~~no substring extraction path for parser/reader code (`Bug 010`)~~ — **fixed**: `string_slice` existed, `string_substr` alias added
       - ~~linear string building remains awkward inside loops without a `push_char` / `append` style path (`Bug 011`)~~ — **fixed**: `string_push_char`/`string_append` builtins added
       - interpreter/runtime workloads also need stronger supporting runtime/data-structure ergonomics (frame-friendly environment patterns, richer collections); the first MAL environment slowdown was primarily an implementation issue, but it still exposed a thin toolbox for this workload class
       - ~~standalone benchmark programs have no easy path to use `std.time` without project/package setup (`Bug 012`)~~ — **fixed**: `clock_monotonic_ns` builtin added
     - ~~other real ergonomics gaps: aggregate `if` expressions (`Bug 008`) and non-working lowered `const` declarations (`Bug 009`)~~ — **both fixed**
     - standalone files still cannot conveniently use std/project dependencies such as `std.fs.read_to_string`; this forces serious examples and benchmarks toward ad hoc `trusted extern fn` wrappers even when the better library surface already exists
   - strongest current interpretation from the first parser-heavy workloads:
     - Concrete’s differentiator is not generic explicitness but visible authority plus visible ownership discipline
     - the main open Phase H question is whether these explicit patterns stabilize into disciplined idioms or remain sustained verbosity
     - future fixes should prefer compression patterns (helper APIs, cleanup idioms, stdlib conventions, qualification tools) before syntax growth
   - current benchmark interpretation is materially stronger than it was before the JSON and grep passes:
     - the earlier “Concrete is much slower than Python” story was largely a benchmark-mode artifact from `-O0` and naive ingestion paths
     - at `-O2`, the JSON parser is competitive with Python's `json.loads`
     - the grep-like tool shows that this competitiveness generalizes to a different workload shape: streaming text search rather than recursive-descent parsing
     - the bytecode VM is the first benchmark that clearly exposes a real performance gap to optimized C: Concrete is still far faster than Python, but safe collection operations in a hot dispatch loop now show a measurable abstraction cost
   - several initial complaints turned out to be misdiagnosed and should **not** be treated as roadmap gaps:
     - `print` / `println` already exist in `std.io`
     - `&&` / `||` already exist and are tested
     - ~~constants exist at the surface level; the real problem is that lowering is incomplete~~ — **fixed**: constants now inline correctly
4. build comparison implementations in Rust, Zig, and C where appropriate so Concrete is evaluated against real neighboring languages rather than in isolation — **not started**
5. compare results across correctness, runtime, memory, binary size, compile time, code size, trust/unsafe surface, and auditability rather than reducing the phase to raw speed charts — **not started**
6. identify codegen cliffs, allocation cliffs, compile-time cliffs, diagnostics pain points, and trust/capability ergonomics failures that only appear at larger scale — **not started**
   - current known examples:
     - ~~enum-typed fields inside named structs can still panic layout computation under real-program pressure (`Bug 005`)~~ — **fixed**
     - ~~standalone programs have no easy stdlib-backed print path without project setup (`Bug 007`)~~ — **fixed**
     - ~~parser/runtime workloads need substring extraction and loop-friendly string building (`Bug 010`, `Bug 011`)~~ — **both fixed**
     - interpreter workloads want stronger runtime/data-structure support even when the concrete implementation strategy is fixed
     - ~~benchmark-oriented standalone programs have no easy in-language timing path (`Bug 012`)~~ — **fixed**
     - ~~aggregate `if` expressions and non-working lowered `const` declarations are real surface gaps exposed by real-program pressure (`Bug 008`, `Bug 009`)~~ — **both fixed**
7. turn the findings into concrete language, stdlib, backend, and tooling follow-up work instead of treating the programs as mere demos — **not started**
   - fast-fix priorities from the first two serious programs:
     1. ~~fix enum-in-struct layout panic (`Bug 005`)~~ — **fixed**
     2. ~~give standalone programs an easy print path (`Bug 007`)~~ — **fixed**
     3. ~~add substring extraction or equivalent string slicing (`Bug 010`)~~ — **fixed**
     4. ~~add loop-friendly string building (`Bug 011`)~~ — **fixed**
     5. ~~give standalone benchmark programs an easy timing path (`Bug 012`)~~ — **fixed**
   - next findings-closure track from the first wave of real programs:
     1. ~~add `defer` statement for explicit scope-end cleanup~~ — **fixed**
        - highest-leverage ergonomics change landed: removes duplicated `drop_string` on early-return paths while preserving explicit cleanup
        - scoped defer semantics landed in lowering instead of the earlier flat function-scoped approximation
        - preserves explicit ownership discipline (no implicit destructors, no GC)
        - control-flow coverage now includes block exit, loop iteration exit, `break`, `continue`, early return, and implicit function end
        - current tradeoff: cleanup code is duplicated at exit sites; if real programs show IR bloat, later cleanup outlining can optimize that without changing semantics
        - follow-on work stays in cleanup ergonomics, not in whether `defer` exists
        - design notes: [research/cleanup-ergonomics.md](research/cleanup-ergonomics.md)
     2. add remaining mutation-oriented string APIs (`string_clear`, `string_starts_with`, `string_ends_with`) — **not started**
        - builder pattern proven by JSON parser; remaining gap is keyword-matching temporary allocations
     3. add a real text/output layer: formatting, interpolation, and logging-friendly output helpers — **not started**
        - builder builtins (`string_append_int`, `string_append_bool`) landed; interpolation deferred pending evidence from 10k+ LOC scale
        - design notes: [research/text-and-output-design.md](research/text-and-output-design.md)
     4. improve runtime-oriented collection maturity for interpreter/runtime workloads: maps, nested mutable structures, and frame-friendly patterns — **not started**
     5. evaluate arena allocation against the existing `Vec`-as-pool pattern and adopt it only if real programs show a clear win in clarity, performance, or boundedness — **not started**
        - design notes: [research/arena-allocation.md](research/arena-allocation.md)
     6. strengthen layout reports where real programs need them: padding visualization, clearer enum/layout detail, and better FFI-facing audit output — **not started**
        - design notes: [research/layout-reports.md](research/layout-reports.md)
     7. reduce the standalone vs project split so stdlib access, benchmarking, and examples do not require awkward scaffolding — **not started**
        - concrete example: standalone benchmarks currently cannot conveniently use `std.fs.read_to_string`, so the fastest honest ingestion path exists but is not reachable without project/package setup
     8. design qualified module access (`Module.function()` or equivalent) so larger programs do not collapse into rename pressure — **not started**
     9. decide how runtime argument access should live at the user-facing surface after the first `argc` / `argv` implementation proves itself in real command-line tools — **not started**
        - the grep-like tool made process arguments a real language/runtime surface, not just generated-C glue
     10. investigate collection hot-path performance for runtime-heavy workloads — **not started**
        - the bytecode VM shows a real gap to optimized C driven largely by repeated `vec_get` / `vec_set` / `vec_push` / `vec_pop` overhead in the dispatch loop
        - this is the first benchmark where Concrete's abstraction/safety tax is both measurable and structurally explainable
     11. document runtime/stack pressure findings from deep-recursive workloads and decide what belongs to language, runtime, stdlib, or tooling — **not started**
     12. decide whether destructuring `let` earns its place for real-program clarity and parser/runtime code — **not started**
     13. unify destruction ergonomics via general `drop(x)` / `Destroy` trait — **deferred** (revisit when stdlib has 5+ distinct drop-like functions)
     14. scoped helper abstractions for resource cleanup — **deferred** (prerequisite now satisfied; revisit at 1k+ LOC programs if explicit `defer` still leaves too much ceremony)
     15. selective borrow-friendly APIs / `&str`-style borrowed slices — **deferred** (revisit after scoped `defer` + mutation APIs are used in 2-3 programs)
   - classify every serious-program finding before acting on it:
     - language surface
     - stdlib/runtime support
     - tooling/workflow
     - backend/performance
     - formalization impact
   - use the following research notes as the design staging area before adding new surface:
     - `research/phase-h-findings.md`
     - `research/text-and-output-design.md`
     - `research/cleanup-ergonomics.md`
     - `research/module-qualification.md`
     - `research/runtime-collections.md`
     - `research/standalone-vs-project-ux.md`
     - `research/runtime-execution-pressure.md`
     - `research/arena-allocation.md`
     - `research/layout-reports.md`
   - keep the example corpus honest as fixes land:
     - when a bug, builtin, stdlib helper, or workflow improvement removes a workaround, earlier Phase H examples should be updated to use the improved path
     - examples should not preserve stale workarounds once the language/system has a better supported surface
     - the example corpus should show the current best Concrete style, not historical accident

Deliverables:
- a small corpus of serious Concrete programs large enough to pressure-test the language honestly
- a documented 20-program comparison portfolio with estimated size, workload mix, and Rust/Zig/C reference targets
- a clearly stated first-wave and second-wave implementation order, with the policy/rule engine first and the MAL-style Lisp interpreter second
- comparative benchmark and evaluation baselines grounded in real workloads instead of micro-assumptions
- cross-language comparison notes explaining not only speed but also correctness, code size, unsafe/trust surface, and auditability tradeoffs
- at least one explicit interpreter/runtime comparison target grounded in a known external workload with tests (for example MAL-style Lisp), not only ad hoc internal programs
- a documented external-tested workload track covering known-spec / known-test programs beyond the first-wave portfolio
- a concrete list of stdlib, diagnostics, package, and backend issues discovered only through sustained use
- a classified findings ledger showing which real-program issues are language, stdlib, tooling, runtime, or formalization problems
- closure of the first-wave ergonomics findings before the mid-wave programs normalize workarounds as language shape
- an example corpus that has been refreshed as fixes land, so older examples do not teach stale workaround patterns
- per-program outcome records covering correctness, performance, memory, binary size, compile-time notes, language gaps, stdlib gaps, and whether Concrete looked stronger, weaker, or just different from Rust/Zig/C
- proof that Concrete remains readable and auditable at larger scales, or an explicit record of where it fails
- a clearer basis for the package, adoption, and operational phases because they are now shaped by real code rather than only design intent

### Immediate Next Steps

After the policy engine, MAL, JSON parser, grep-like tool, and bytecode VM, the highest-value next work is:

1. use the VM result to investigate collection hot-path overhead before drawing broader performance conclusions
2. continue the first-wave ladder with the artifact/update verifier as the next flagship critical-software workload
3. keep recording per-program benchmark interpretation, not just raw timings, so the project distinguishes parser wins, streaming wins, and runtime-loop costs clearly
4. keep closing Phase H findings through the narrowest fixes first:
   - project/std resolution for real examples and benchmarks
   - runtime argument surface
   - string/text helpers that still matter after the parser and grep results
   - collection/runtime maturity for interpreter and VM workloads

Exit criterion:
Concrete has been exercised by multiple serious programs large enough to reveal structural weaknesses, and the project has used those results to drive the next package/adoption/operational phases.

Phase H should not end with only benchmark charts and example directories. It should leave behind a disciplined findings-closure path for the issues that real code exposed:

- language issues that may justify surface changes
- stdlib/runtime issues that should become library/tooling work instead of syntax creep
- workflow friction that belongs in package/project tooling
- runtime/performance constraints that should inform later execution and concurrency phases
- formalization-impacting changes that must be staged before Phase I broadens proof scope

#### Phase I: Formalization And Proof Expansion

Goal: turn the existing proof-oriented architecture into a real multi-stage formalization effort over the language, proof-eligible subset, and selected compiler boundaries.

This phase is intentionally after language-discipline work and real-program pressure testing:

- after G, because proving an unstable or overgrown surface is wasted effort
- after H, because real programs should help determine what is actually worth proving and where source-to-Core traceability must hold up
- before the later package/adoption/operational phases become the center of gravity, so the proof story remains a structural part of the language rather than an indefinitely deferred side thread

Primary surfaces:
- [research/formalization-breakdown.md](research/formalization-breakdown.md)
- [research/formalization-roi.md](research/formalization-roi.md)
- [research/proving-concrete-functions-in-lean.md](research/proving-concrete-functions-in-lean.md)
- [Concrete/ProofCore.lean](/Users/unbalancedparen/projects/concrete/Concrete/ProofCore.lean)
- [Concrete/Proof.lean](/Users/unbalancedparen/projects/concrete/Concrete/Proof.lean)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/PASSES.md](docs/PASSES.md)

1. broaden the pure Core proof fragment beyond integers/booleans/arithmetic/conditionals to cover richer data and control structure — **not started**
2. define and stabilize the clearly analyzable / provable subset promised in Phase G as an actual proof target rather than only a language aspiration — **not started**
3. expand `ProofCore` carefully so it remains a filter over `ValidatedCore`, not a second semantic authority — **not started**
4. add source-to-Core and Core-to-ProofCore traceability strong enough for external proof workflows and report/evidence integration — **not started**
5. prove more language guarantees around capabilities, ownership, trust boundaries, and other rules that users are meant to rely on — **not started**
6. push selected compiler-preservation work further where it is tractable and high-value, especially around explicit artifact boundaries — **not started**
7. make the user-program proof workflow more real: exporting/referencing proof subjects, documenting proof-facing artifacts, and tying the workflow to ordinary compiler outputs — **not started**

Deliverables:
- a substantially broader formal semantics than the current pure Core fragment
- a documented and implementation-aligned provable subset rooted in `ValidatedCore` / `ProofCore`
- stronger traceability from source to validated Core to proof-facing artifacts
- a clearer split between language-guarantee proofs, user-program proofs, and compiler-preservation proofs
- a practical path for selected Concrete programs to be proved in Lean without pretending the entire language is already formalized
- a proof roadmap grounded in the language that survived real-program pressure testing, not only in idealized fragments

Exit criterion:
Formalization is no longer only “proof-friendly architecture plus initial theorems.” Concrete has an explicit, broadened proof workflow, a clearer provable subset, and stronger traceability between user code, validated Core, and proof-facing artifacts.

#### Phase J: Package And Dependency Ecosystem

Goal: make Concrete usable for real multi-module and multi-package projects with explicit, stable project-facing semantics.

For serious use, this phase is unavoidable. High-integrity or proof-oriented code still needs a clean project model, dependency semantics, and workspace behavior that are explicit rather than ad hoc.

Primary surfaces:
- [research/authority-budgets.md](research/authority-budgets.md)
- [research/artifact-driven-compiler.md](research/artifact-driven-compiler.md)
- [research/developer-tooling.md](research/developer-tooling.md)
- [research/trust-multipliers.md](research/trust-multipliers.md)
- project/package metadata
- import resolution and project-root semantics
- stdlib vs third-party package boundaries
- workspace and dependency tooling

1. design and implement incremental compilation — serialize pipeline artifacts (`ResolvedProgram`, `ValidatedCore`, `SSAProgram`) to disk, add cache invalidation by source hash, skip unchanged modules — **not started**. This is the prerequisite for packages to scale: without it, every build recompiles the world. The artifact pipeline is already much stronger than before, but real incrementality still depends on cleaner interface/body artifact splitting, stable identities, and driver/cache work — not only serialization.
2. define the package and dependency model explicitly — **not started**
3. define stdlib vs third-party package boundaries — **not started**
4. define workspace and multi-package behavior — **not started**
5. make dependency and package UX part of the language-user experience — **not started**
6. ensure docs, tooling, and CI reflect the same package/project model — **not started**
7. split interface-facing artifacts from body-bearing artifacts cleanly enough to support package and dependency boundaries — **not started**
8. make package/dependency reasoning operate on explicit graph artifacts instead of ad hoc file-level reconstruction — **not started**
9. define the first real project-facing CLI workflow (`concrete build`, `concrete test`, `concrete run`) on top of the package model — **not started**
10. design the first enforceable authority-budget path at module/package/subsystem scope, starting with report-backed policy rather than a second effect system — **not started**

Deliverables:
- incremental compilation: serialized pipeline artifacts, source-hash-based cache invalidation, module-level rebuild granularity
- a documented package/dependency model with project-root and resolution semantics
- a defined boundary between stdlib and third-party packages
- a documented workspace/multi-package model
- dependency/package tooling and CI behavior aligned with the same model
- an authority-budget path at package or subsystem boundaries
- a credible path for package- or subsystem-level capability budgets to become enforceable build policy
- a documented dependency-trust direction for packages, workspaces, and third-party inputs
- a cleaner split between interface-bearing and body-bearing compiler artifacts for package/workspace use
- an explicit package/dependency graph artifact strong enough to support later driver, cache, and report reuse work
- a project-facing CLI model that grows out of the package/driver architecture instead of shell conventions
- a first explicit module/package authority-budget path grounded in the package graph and existing capability reports

Exit criterion:
Concrete has an explicit package/dependency model that supports real projects without relying on ad-hoc repo-local conventions, has a credible path to enforcing authority budgets at package or subsystem boundaries, and no longer depends on muddy interface/body artifact boundaries to reason about packages.

#### Phase K: Adoption, Positioning, And Showcase Pull

Goal: make Concrete easier to want, try, understand, and remember, not only easier to admire architecturally.

This phase turns the language from a coherent technical project into something with visible user pull:

- a clearer signature-domain story
- memorable public examples
- smoother onboarding and developer experience
- an explicit public stability surface
- sharper comparison/positioning against adjacent languages

This phase is intentionally after the package/project, real-program pressure-testing, and formalization phases and before full operational maturity:

- after J, because adoption claims are weak without a coherent project/package model
- after H, because the public story should be shaped by real programs, not only internal architecture
- after I, because a visible proof/formalization story is part of Concrete's differentiation and should be represented honestly once it has a real phase
- before L, because real user pressure should help shape which operational surfaces actually matter
- before M, because long-term concurrency maturity is not part of the first convincing user story

Primary surfaces:
- [README.md](README.md)
- [docs/IDENTITY.md](docs/IDENTITY.md)
- [research/adoption-strategy.md](research/adoption-strategy.md)
- [research/showcase-workloads.md](research/showcase-workloads.md)
- [research/complete-language-system.md](research/complete-language-system.md)
- project templates, examples, docs, and editor/onboarding surfaces

1. define one or two signature domains where Concrete should be unusually strong — **not started**
2. build a small set of serious public showcase programs, not only internal tests — **not started**
3. make onboarding, examples, and project-start flow part of the product story — **not started**
4. make report UX, docs, and examples feel useful to ordinary users instead of only compiler contributors — **not started**
5. define an explicit public stability/experimental surface so users know what they can rely on — **not started**
6. document Concrete's positioning relative to adjacent systems languages and where it should intentionally not compete — **not started**
7. define explicit adoption non-goals so the project does not blur itself into a generic systems-language pitch — **not started**

Deliverables:
- a documented signature-domain strategy for the language
- a small public showcase corpus that demonstrates Concrete's identity, not just compiler coverage
- smoother first-use and onboarding guidance through templates/examples/docs
- a clearer public explanation of what is stable, experimental, or intentionally deferred
- a sharper comparison/positioning story explaining where Concrete is strongest and where it is not trying to win
- explicit adoption non-goals that protect the language from feature-growth-for-attention
- concrete success signals for the phase: a new user can identify the target domains, run a showcase, inspect reports, and understand the stable/experimental surface without reading internal compiler docs

Exit criterion:
Concrete has a credible adoption story: users can understand what it is for, try it through polished examples, and see why it is distinct without reading the whole compiler roadmap.

#### Phase L: Project And Operational Maturity

Goal: turn Concrete from a strong compiler project into a durable, distributable, maintainable system.

This phase is where the evidence story becomes operational:

- maintained editor/tooling surfaces
- reproducible and reviewable outputs
- explicit compatibility policy
- certification-style traceability between source, reports, proofs, and builds

Primary surfaces:
- [README.md](README.md)
- [docs/README.md](docs/README.md)
- [research/artifact-driven-compiler.md](research/artifact-driven-compiler.md)
- [research/developer-tooling.md](research/developer-tooling.md)
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
   - target shape: source/build identity + report outputs + artifact IDs + proof-facing references bundled into one reviewable output
9. define whether evidence authenticity and build/dependency trust need explicit operational policy — **not started**
   - include package/dependency trust drift as a first-class review question, not just a changelog problem
10. define debugging/observability expectations as a maintained product surface — **not started** (this item covers the operational/maintenance policy around debug info quality, stack trace fidelity, and inspection workflows; implementation work is captured below)
11. define whether and how artifact serialization / disk-backed compiler artifacts become part of the supported workflow — **not started** (incremental compilation is in Phase H; this item covers the stability/versioning policy for serialized artifacts)
12. define the long-term bootstrap/self-hosting stance explicitly — **not started**
13. make the compiler-driver/build-graph layer explicit instead of leaving orchestration as thin CLI glue — **not started**
14. define stable artifact identity/versioning rules for reports, caches, proof/export subjects, and build outputs — **not started**
15. make machine-readable report output a maintained operational surface, not just an ad hoc export path — **not started**
16. design a report-first review workflow for high-integrity and audit-heavy codepaths, including policy failures over authority/alloc/layout/trusted/FFI evidence — **not started**
17. define package and release diffing for trust drift: authority growth, allocation drift, layout drift, and trusted-boundary expansion — **not started**
18. turn editor/LSP support into an explicit maintained product surface, starting from compiler-owned diagnostics/navigation rather than a separate semantic engine — **not started**
19. define cross-compilation workflow expectations as part of the supported operational/build story, not only as backend target policy — **not started**
20. implement and maintain usable debug-info emission as part of the supported tooling surface — at minimum, DWARF from EmitSSA sufficient for source locations and stack traces in lldb/gdb — **not started**
21. implement and maintain the first explicit non-cleanup optimization layer — SSA-level function inlining with a stated policy that preserves capability/trust honesty and debug/report quality — **not started**

Deliverables:
- a documented release and compatibility policy for language, stdlib, reports, and tooling surfaces
- reproducible build/test/CI expectations that are operationally maintained
- an explicit distribution and installation story
- maintained baseline docs and editor/tooling expectations
- an explicit bootstrap-trust and compatibility policy
- a practical evidence/traceability story linking source, reports, proofs, and build artifacts
- a documented direction for reproducible trust bundles as the operational form of the evidence story
- a machine-readable report story strong enough for CI, review tooling, and later certification workflows
- a report-first high-integrity review workflow that turns authority/alloc/layout/trusted/FFI facts into a coherent operational surface
- a practical trust-drift diffing story for packages and releases
- a documented deprecation/migration policy for language, reports, and tooling surfaces
- an explicit direction for editor/tooling support as a maintained product surface
- an explicit operational trust policy for builds, dependencies, and evidence authenticity if trust bundles become real outputs
- a documented debugging/observability direction covering debug info quality, stack traces, symbol fidelity, and inspection workflows
- an explicit policy for stable serialized artifacts, disk caches, and incremental state if they become supported operational surfaces
- an explicit bootstrap/self-hosting policy describing whether Concrete should remain Lean-hosted, partially self-host, or intentionally avoid self-hosting
- an explicit compiler-driver/build-graph architecture that orchestrates packages, targets, reports, artifacts, and caches without becoming a second semantic authority
- stable identity/versioning rules for user/tool-visible artifacts so reports, proof exports, caches, and evidence bundles can remain reproducible and comparable
- an explicit editor/LSP baseline (diagnostics, go-to-definition, hover/navigation) grounded in compiler artifacts
- an explicit cross-compilation workflow story for supported vs experimental targets, including how target selection interacts with packages, reports, and artifacts
- emitted debug metadata good enough for ordinary debugger workflows to show source locations and stack traces
- a first explicit optimization layer beyond cleanup, with function inlining treated as policy-governed backend work rather than accidental folklore

Exit criterion:
Concrete is not only architecturally strong internally, but also operable, reproducible, documentable, and maintainable as a long-term project, with a real driver/artifact model rather than only a pass library plus CLI entry points.

#### Phase M: Concurrency Maturity And Runtime Plurality

Goal: give Concrete a long-term concurrency model that stays explicit, auditable, and small instead of collapsing into an "async everywhere" ecosystem.

This phase is intentionally later than Phase E.
Phase E defines the execution model and first runtime boundary.
Phase M exists to do the larger concurrency design correctly once runtime, safety, formalization, package, adoption, and operational foundations are stable enough to support it.

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
4. define explicit cancellation and supervision structure for concurrent work — **not started**
5. integrate concurrency into capability reporting, boundedness reporting, and high-integrity profiles — **not started**
6. define whether and how evented I/O fits under the same explicit runtime/capability contract — **not started**
7. keep runtime plurality explicit and prevent fragmentation into incompatible concurrency cultures — **not started**

Deliverables:
- a documented long-term concurrency contract for the language/runtime
- a stable threads-plus-channels baseline with explicit ownership transfer rules
- an explicit structured-concurrency lifecycle model for ordinary concurrent work
- an explicit cancellation/supervision model for concurrent work that stays visible and scope-owned by default
- a documented shareability/synchronization discipline for concurrent code
- report/profile integration for concurrency, blocking, and runtime authority
- a documented evented-I/O direction that fits the same explicit contract without becoming the default for all code

Exit criterion:
Concrete has one coherent concurrency story: structured by default, threads-first underneath, message-passing biased, and able to admit specialized evented runtime models later without losing auditability or runtime clarity.

#### Phase N: Allocation Profiles And Bounded Allocation

Goal: turn allocation behavior into a stronger audit and high-integrity surface without forcing Concrete into a large effect calculus or dependent-type design.

This phase is intentionally late.
Concrete should first validate its real-program pressures, proof expansion, package model, operational maturity, and concurrency/runtime shape.
Only then should it attempt a stricter bounded-allocation story beyond today's binary `with(Alloc)` capability.

The intended shape is deliberately narrow:

- strengthen `--report alloc` into a more explanatory summary surface
- add enforceable `NoAlloc` checking as the first real profile
- explore a restricted `BoundedAlloc(N)` subset only where the bound is structurally explainable
- prefer capacity-aware APIs and explicit restrictions over clever inference

Primary surfaces:
- [research/allocation-budgets.md](research/allocation-budgets.md)
- [research/high-integrity-profile.md](research/high-integrity-profile.md)
- [research/arena-allocation.md](research/arena-allocation.md)
- [research/execution-cost.md](research/execution-cost.md)
- [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md)
- [docs/SAFETY.md](docs/SAFETY.md)
- allocation-related stdlib and report tooling

1. make `--report alloc` more structurally useful: classify functions as `NoAlloc`, direct alloc, transitive alloc, and structurally unbounded/unknown — **not started**
2. add an enforceable `NoAlloc` profile/check that rejects direct or transitive allocation in marked code — **not started**
3. define which allocation operations are admissible in bounded contexts and which stdlib APIs need bounded-capacity or within-capacity variants — **not started**
4. design a conservative function-summary model for restricted allocation bounds that composes across direct calls — **not started**
5. restrict bounded-allocation checking to structurally explainable cases (for example: no recursion, bounded loops only, no dynamic-growth container calls without explicit bounded variants) — **not started**
6. prototype a limited `BoundedAlloc(N)` form for the high-integrity profile and evaluate whether the ergonomics and diagnostics justify keeping it — **not started**
7. connect allocation-profile results to reports, package/policy surfaces, and the longer proof/evidence story without making reports a second semantic authority — **not started**
8. add structural execution-boundedness reporting alongside allocation profiles so high-integrity review can see both memory and control-flow boundedness together — **not started**

Deliverables:
- a stronger `--report alloc` output that classifies and explains allocation behavior per function
- an enforceable `NoAlloc` profile for code that must not allocate
- a documented restricted bounded-allocation model with explicit non-goals
- bounded-friendly stdlib/API patterns where they are needed for real use
- a prototype or adopted design for limited `BoundedAlloc(N)` checking, or an explicit decision to stop at `NoAlloc` plus reports if the complexity is not justified
- report/profile integration that makes allocation behavior part of Concrete's evidence story for high-integrity code
- structural execution-boundedness reporting that pairs naturally with `NoAlloc` and restricted bounded-allocation claims

Exit criterion:
Concrete can explain and enforce "does this function allocate?" cleanly, and it has either a credible restricted `BoundedAlloc(N)` model with good diagnostics or a deliberate documented decision to keep bounded allocation report-first rather than fully enforced.

#### Phase O: Research Phase And Evidence-Gated Features

Goal: keep high-value ideas visible, evaluated, and explicitly decided without forcing premature language growth or letting good ideas silently disappear.

This phase exists for ideas that are clearly interesting but not yet justified as committed roadmap work.
Its job is to turn "maybe" into one of three outcomes:

- adopted in a later roadmap revision
- kept as an open long-horizon direction
- explicitly rejected with reasons

Primary surfaces:
- [research/high-leverage-systems-ideas.md](research/high-leverage-systems-ideas.md)
- [research/typestate.md](research/typestate.md)
- [research/arena-allocation.md](research/arena-allocation.md)
- [research/layout-reports.md](research/layout-reports.md)
- [research/execution-cost.md](research/execution-cost.md)
- [research/authority-budgets.md](research/authority-budgets.md)

1. keep a small canonical list of research-backed systems ideas visible and cross-linked — **not started**
2. record the dependency fit for each idea: which existing phase it belongs with if adopted later — **not started**
3. require evidence from real programs, report usage, or package/runtime pressure before turning evidence-gated ideas into language surface — **not started**
4. explicitly evaluate typestate after more real programs, rather than inferring need from theory alone — **not started**
5. evaluate whether heap-vs-stack allocation should remain report/profile information or become an explicit capability split (`AllocHeap` / `AllocStack`) — **not started**
6. record "not now" or "not worth it" decisions for ideas that fail the design filters, instead of letting them silently drift — **not started**

Deliverables:
- a maintained canonical research index for the highest-leverage undecided ideas
- explicit adoption, defer, or reject records for evidence-gated features
- a clearer mapping from research ideas to the phases they would naturally join if adopted
- an explicit decision record for whether heap-vs-stack allocation distinction belongs in reports/profiles only or in the capability surface
- protection against accidental feature loss-by-forgetting as the roadmap evolves

Exit criterion:
Concrete has an explicit place for serious but undecided ideas, and the project records why those ideas were adopted, deferred, or rejected instead of letting them linger ambiguously outside the roadmap.

### Why These Phases Matter

- **Phase A** matters because a slow feedback loop drags down every compiler task, and backend-sensitive lowering bugs destroy trust in every other part of the compiler.
- **Phase B** matters because a compiler is much easier to trust, prove, and maintain when ordinary names stay ordinary.
- **Phase C** matters because syntax guardrails, diagnostics, and testing infrastructure are what make a compiler sustainable instead of heroic.
- **Phase D** matters because this is where Concrete stops being only a working compiler and becomes a trustworthy compiler platform, starting with testing architecture strong enough to support every later backend and proof ambition.
- **Phase E** matters because a language is not really settled until its execution model is explicit.
- **Phase F** matters because Concrete's safety model should be a user-visible strength, not only an internal design claim. Error recovery also lives here — getting one error at a time is the most visible DX gap.
- **Phase G** matters because languages decay when feature growth has no explicit discipline.
- **Phase H** matters because languages often look coherent until they are forced to carry real programs. Large-code pressure testing is how Concrete earns confidence in its stdlib, diagnostics, package model, and performance story.
- **Phase I** matters because Concrete's proof story is too central to remain only a cross-cutting aspiration. This is where formalization becomes a real workstream instead of “initial theorems plus later hope.”
- **Phase J** matters because package and dependency semantics are part of the language experience once real projects exist. Incremental compilation is the first item — without it, multi-package builds recompile the world.
- **Phase K** matters because technically coherent languages still fail if nobody can quickly understand why to use them, what they are for, or how to get started well.
- **Phase L** matters because long-term projects fail just as easily from weak operational discipline as from weak compiler architecture.
- **Phase M** matters because concurrency is one of the easiest places for a language to lose clarity, and Concrete should only broaden it once it can do so without importing async fragmentation and hidden runtime culture.
- **Phase N** matters because allocation behavior is one of Concrete's clearest opportunities to become unusually strong for high-integrity and audit-heavy low-level code, but only if it is implemented conservatively enough to stay explainable.
- **Phase O** matters because valuable ideas should not have only two states, “immediate phase work” or “forgotten”. Concrete needs an explicit place to evaluate and either adopt or reject evidence-gated features.

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

This section is for later work that remains meaningful after the current phase structure.
Do not use it to restate phases that already exist above.

1. Backend plurality over SSA, but only after the current backend becomes structurally cleaner first.
2. Proof-driven narrowing of future feature additions.
3. A clearer hosted vs freestanding / `no_std` split, but only after the runtime and stdlib boundaries are more stable.
4. Execution-cost analysis as an audit/report extension.
   - structural boundedness reports first
   - abstract cost estimation later
   - never at the cost of clarity in the core language
5. Broaden the Lean-side proof workflow beyond the current pure-fragment scope (17 theorems over integers/booleans/arithmetic/conditionals). Next targets: structs, enums, match expressions, recursive functions, source-to-Core traceability, and export/tooling for external proof use.
6. Potential later expansion of the Lean proof story beyond Core-level properties.
   - later broaden selected-function proofs toward effects, resources, capabilities, runtime interaction, and only then concurrency
   - later consider backend-level proof concerns such as richer compiler-preservation work across deeper lowering stacks or optional backend-family layers
   - do not treat either broader end-to-end program proofs or backend/MLIR-layer proof work as near-term substitutes for the validated-Core-first plan
7. Treat contracts, richer invariants, and similar verification extensions as post-roadmap evaluation work, not as part of the main current philosophy.
   - only evaluate them after the simpler Concrete + Lean 4 proof story has proven insufficient
   - keep them out of the main phase plan until the core language, proof boundary, runtime model, and operational story are already stable
   - if adopted at all, treat them as a final optional verification-extension stage rather than as a prerequisite for the main roadmap
8. Implement a real artificial-life showcase/stress-test in Concrete.
   - target a program in the spirit of Rabrg's `artificial-life` reproduction of "Computational Life: How Well-formed, Self-replicating Programs Emerge from Simple Interaction"
   - a 240x135 grid of 64-instruction Brainfuck-like programs, randomly initialized, locally paired, concatenated, executed for bounded steps, then split back apart
   - use it as a serious end-to-end stress test for runtime/performance, collections/buffers, formatting/reporting, and later proof/audit ambitions
   - treat it as a showcase workload once the runtime, stdlib, and backend are mature enough rather than as immediate Phase C compiler work
9. Develop proof-backed authority reports as a later extension of the current capability/trust reports.
   - make it explicit which authority facts are compiler-checked, which depend on validated Core extraction, and which still rest on trusted/foreign assumptions
   - keep the first versions narrow and high-signal rather than pretending to prove the whole world
10. Move toward verified FFI envelopes once the runtime/ABI boundary is explicit.
   - make foreign boundaries carry ABI, ownership, destruction, and capability assumptions more explicitly than raw `extern fn`
   - prefer wrapper/envelope approaches over broad new surface syntax
11. Treat reproducible trust bundles as the operational destination of the evidence story.
   - package reports, proof references, build identity, and artifact fingerprints together for audit/review workflows
   - only do this once the package/runtime/compatibility story is stable enough to make the bundle worth trusting
12. Treat performance and incrementality as an explicit later maturity thread rather than ambient compiler folklore.
   - define profiling methodology and performance regression expectations
   - include a clear position on early optimization families such as function inlining rather than leaving all non-cleanup optimization implicit
   - define optimization policy explicitly enough that backend work has stated goals and stated non-goals
   - treat debug-info / observability maturity as a real backend quality axis, not accidental fallout of codegen work
   - make optimization policy explicit enough that "faster" does not silently trade away auditability or proof-friendliness
   - only add artifact serialization and incremental compilation once the artifact boundaries and compatibility story are boring enough to sustain them
13. Treat bootstrap/self-hosting as an explicit strategic choice, not ambient ambition.
   - decide whether Concrete should remain Lean-hosted, partially self-host, or eventually self-host
   - evaluate it against trust, proof leverage, implementation cost, and operational complexity rather than aesthetics
   - do not let self-hosting aspirations outrun the proof/runtime/package/operational story
14. Keep a small set of research-backed systems ideas explicitly in view even when they are not yet phase-committed.
   - canonical summary: [research/high-leverage-systems-ideas.md](research/high-leverage-systems-ideas.md)
   - allocation budgets / `NoAlloc` / restricted `BoundedAlloc(N)` are now phase-committed in Phase N
   - arena allocation remains a serious candidate because it formalizes the existing pool pattern in parser/interpreter-style programs
   - execution boundedness / cost reporting remains a report-first candidate because it fits the audit and high-integrity story well
   - layout reports remain a likely quick win because the layout subsystem already exists and mostly needs stronger productization
   - typestate remains evidence-gated: ownership already covers the simplest irreversible transitions, and phantom-type typestate should only land if real programs justify it
   - authority budgets remain a strong long-term dependency/supply-chain idea, but package-level enforcement depends on the package model
   - if any of these ideas are later rejected, record that explicitly instead of letting them silently disappear
15. Make the artifact model operationally real rather than nominal.
   - ensure pass APIs consume/produce named artifacts directly rather than drifting back to parsed-module-plus-table plumbing
   - introduce missing durable artifacts where needed (for example a checked-program boundary if the architecture continues to justify one, but do not freeze that exact split before the pass plumbing proves it)
   - keep artifact ownership explicit enough that tooling and reports do not rebuild semantic facts ad hoc
16. Make source-to-Core-to-proof-to-SSA traceability a first-class compiler property.
   - preserve stable source-origin identity through validated Core, proof/export subjects, monomorphized instances, and SSA origins
   - treat this as necessary for proof credibility, report credibility, and later debugging/evidence workflows
17. Treat interface/body artifact splitting as a major architecture thread, not only an incremental-compilation detail.
   - package, workspace, and dependency semantics should depend on explicit interface artifacts rather than body-bearing summaries wherever possible
   - avoid letting import/package reasoning stay coupled to more implementation detail than it needs
18. Make the compiler-driver/build-graph layer explicit.
   - own package graph, target selection, cache lookup/store, report generation from artifacts, and invalidation rules in one orchestrator layer
   - do not let shell scripts and scattered CLI entry points become the accidental long-term build architecture

## Backend Work Order

The structured LLVM backend and SSA backend contract are done. Remaining backend work in priority order:

1. ~~Replace direct LLVM IR text emission with a structured LLVM backend.~~ **Done** — EmitSSA emits structured LLVM IR through `LLVMTy`/`LLVMFnDecl`/`SInst` types, not string concatenation.
2. ~~Document the SSA backend contract.~~ **Done** — SSAVerify guarantees, SSACleanup postconditions, EmitSSA preconditions documented in `docs/PASSES.md`.
3. ~~Close the calling convention gap for `extern fn` with struct parameters~~ — **Done** (Phase E item 5): `#[repr(C)]` struct arguments passed by value in extern fn calls
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
- [research/optimization-policy.md](research/optimization-policy.md)
- [research/target-platform-policy.md](research/target-platform-policy.md)
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

Concrete has a complete compiler pipeline, a real stdlib (33 modules, 16 collections), 864 tests passing, a fully structured LLVM backend, audit reports, explicit artifact boundaries (`ValidatedCore`, `ProofCore`), a documented SSA backend contract, a first Lean 4 proof workflow (17 theorems over a pure Core fragment), a 20-program integration/regression/hardening corpus, and bug tracking in `docs/bugs/`. Phases A–G are done. Phase H is active: real-program pressure has already produced the policy engine, MAL-style interpreter work, JSON parser pressure, multiple bug fixes, and a concrete findings-closure track for ergonomics, report UX, and runtime/tooling follow-up. Compiler hardening is complete: Lower.lean fallbacks are hard errors (`throw`), Layout.lean/EmitSSA.lean fallbacks are hard errors (`panic!`) with type variable leakage fixed, SSAVerify catches integer bit-width mismatches, cross-module type aliases are fixed, and borrow edge cases have been audited.
