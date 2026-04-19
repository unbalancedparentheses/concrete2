# Concrete Roadmap

This document is the active execution plan. It answers one question: **what should happen next, in what order?**

Read the active list with the explicit **Active Dependency Order** below rather than assuming phase numbers are a strict execution sequence. The 14 phase numbers below are thematic buckets for remaining work, and task numbering never restarts.

For landed work, see [CHANGELOG.md](CHANGELOG.md). For detailed design, see `docs/` and `research/`.

## Current State

Concrete already has a real Lean 4 compiler pipeline:

`Parse -> Resolve -> Check -> Elab -> CoreCheck -> Mono -> Lower -> EmitSSA -> LLVM IR`

The core language, stdlib foundation, diagnostics, proof/evidence reports, project workflow, adversarial tests, trust-drift demos, and CI evidence gates are real. Recent adversarial compiler bugs are fixed and retained as regressions: LLVM function-name collisions, generic `Copy` struct validation, and top-level `main` after inline modules.

The remaining question is no longer "can Concrete compile programs?" It is:

**Can Concrete prove its thesis with real systems examples, honest trust boundaries, and a usable proof/evidence workflow?**

## First-Release Success Bar

Do not call the language releasable until these are true:

- A flagship example shows explicit authority, predictable/bounded code, at least one Lean-backed property, artifact-backed evidence, and drift detection.
- Bad changes are caught by normal tools: widened authority, new allocation/FFI/blocking, predictable-profile breaks, stale proofs, and obligation/evidence drift.
- Another engineer can audit a function without reading compiler internals: what it can touch, whether it is predictable, whether it is proved, what is trusted, and what changed.
- At least one second-domain example works, so the thesis is not only a packet-parser story.
- The supported stdlib/syntax/profile surface is narrow, documented, and stable enough for outsiders.
- Trust boundaries are explicit: compiler-enforced, analysis-reported, Lean-proved, trusted-code, backend/toolchain, and target/runtime assumptions are not mixed.
- The release does not claim a fully verified compiler; it claims Lean-backed evidence for selected user-code properties under explicit compiler, registry, backend, toolchain, and target assumptions.

## Missing Feature Coverage

For fast scanning, the remaining major missing feature surfaces are:

- Language/stdlib pressure workloads before stdlib freeze: parser/decoder, ownership-heavy, borrow-heavy, trusted-wrapper/FFI, and cleanup-heavy pressure workloads.
- Stable stdlib and syntax definition: string/text contract, core-vs-hosted split, Result helpers, endian-aware byte cursors, explicit visibility, arithmetic policy, and LL(1)-safe destructuring / `let ... else`.
- Tooling, tests, and wrong-code hardening: formatter, doc extraction, doc tests, fuzzing, reducer/minimizer workflow, named wrong-code corpus, and a lightweight playground.
- Stronger runtime/allocation/performance surfaces: allocation reporting, stack reporting, profiling, and benchmark harnesses/guardrails.
- Editor and artifact UX: compiler-as-service, editor/LSP support, and a small human-friendly artifact viewer.
- Package and workspace support: package manifest, workspace/multi-package support, dependency resolution, and lockfile.
- Incremental compilation and equivalence checking: incremental artifacts plus clean-build versus incremental-build equivalence.
- Later-stage backend and trust-multiplier work: target decisions such as WASM, second-backend evaluation, and selected compiler verification/preservation proofs.

## Priority Map

| Phase | Items | Human goal |
|---|---:|---|
| 1. Predictable Core | 23-40 | Make bounded, predictable, failure-aware code usable before broadening scope. |
| 2. Pre-Stdlib Pressure Workloads | 41-46 | Use real workloads to discover what the stdlib must actually provide. |
| 3. Stdlib and Syntax Freeze | 47-65 | Define, build, polish, and freeze the first-release stdlib, visibility, error, binary parsing, and LL(1) syntax surface. |
| 4. Tooling, Tests, and Wrong-Code Corpus | 66-77 | Make examples, docs, formatting, fuzzing, wrong-code capture, minimization, and instant feedback normal workflow. |
| 5. Performance, Artifacts, and Contract Hardening | 78-90 | Put budgets, reports, artifacts, and explicit failure behavior around the compiler. |
| 6. Release Credibility and Showcase | 91-113 | Prepare honest public positioning, C-replacement validation, and release packaging only after the broader proof/toolchain surface is stable enough to defend publicly. |
| 7. Proof Expansion and Provable Subset | 114-138 | Grow ProofCore, obligations, and provable-subset claims only after the surrounding language, stdlib, tooling, and runtime-profile surface is stable enough that the new proofs mean something durable. |
| 8. Backend, Target, and Incremental Pipeline | 139-156 | Stabilize backend contracts, targets, incremental builds, and semantic regression coverage. |
| 9. Compiler Verification and Preservation Proofs | 157-166 | Scope and prove selected compiler properties only after the proof workflow, backend contract, and artifact semantics are stable enough to justify them. |
| 10. Package System and Dependency Trust | 167-182 | Add packages only after artifacts, visibility, and trust summaries know what they must carry. |
| 11. Editor, Artifact UX, and Compatibility | 183-194 | Expose facts, diagnostics, refactoring, proof state, artifacts, compatibility tests, and stability policy to users and tools. |
| 12. Runtime Profiles, Allocation, and Predictability | 195-210 | Define concurrency, allocation, stack, failure, timing, and overflow boundaries early enough that proof and release claims do not outrun the runtime model. |
| 13. Public Readiness and User Tooling | 211-217 | Make the language easier to adopt, audit, govern, and evolve publicly. |
| 14. Long-Horizon Research Backlog | 218-229 | Keep speculative language/runtime/research ideas visible but clearly gated. |

## Active Dependency Order

Do not treat the remaining phase numbers as a strict execution sequence. They are thematic buckets. Use this dependency order when deciding what to do next:

1. **Make the surrounding language stable enough to prove against**: Phases 1, 2, and 3. First make predictable code practical, then let real workloads pressure the language, then freeze the first-release stdlib/syntax surface.
2. **Make the workflow operationally trustworthy**: Phases 4, 5, and 12. Before broadening proof claims, harden tests, wrong-code capture, artifacts, profiling, allocation/leak reporting, and runtime-profile boundaries.
3. **Broaden the provable subset on top of that stable surface**: Phases 7 and 8. Once the language/runtime/toolchain surfaces stop drifting, expand ProofCore coverage, obligation generation, backend contracts, and incremental/equivalence guarantees.
4. **Only then package the public story**: Phase 6, followed by Phases 10, 11, and 13 as needed. Public showcases, release criteria, package trust, editor UX, onboarding, and governance should rest on stable evidence rather than aspirational internals.
5. **Treat compiler verification as a later trust multiplier, not a prerequisite for the first credible release**: Phase 9 comes after the proof workflow, backend assumptions, and artifact contracts are already clear.
6. **Keep research-gated ideas fenced off**: Phase 14 stays last unless a concrete earlier example forces one of those topics forward.

## Operating Rules

- Follow the **Active Dependency Order** instead of treating phase numbers as a strict queue.
- When an item is completed, move it to [CHANGELOG.md](CHANGELOG.md) and renumber the remaining active list.
- Close phases on concrete outputs: examples, reports, docs, or tool surfaces with explicit success bars, not only abstract intent.
- Every canonical or flagship example must name its oracle or explicitly state that no external oracle exists yet.
- Every active phase should have a short exit checklist or equivalent “phase closes when…” surface before it is called done.
- Judge new language features by grammar cost, audit cost, and proof cost, not just expressiveness.
- Do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until earlier evidence/diagnostic/tooling steps make them concrete.
- Keep specs in Lean-attached / artifact-registry form until obligations and diagnostics are strong enough to support source-level contracts honestly.
- Build a normal fact CLI before MCP/editor integrations.
- Keep QBE and other backend work waiting until proof/evidence attachment, optimization policy, and backend trust boundaries are trustworthy.
- Treat compiler verification as a long-term trust multiplier after ProofCore, artifact schemas, reference-interpreter work, and backend/target assumptions are stable; do not make full compiler correctness a first-release promise.
- Parallelize only low-risk inventories and docs while the active implementation path is proof/diagnostic/compiler-contract work.

## Active List

The active roadmap starts after the completed compiler-integrity and proof-workflow foundation now recorded in [CHANGELOG.md](CHANGELOG.md). Former roadmap Phases 1 and 2 are historical; the active remaining work is renumbered below as Phases 1-14.

### Phase 1: Predictable Core

Expected outcome example: a bounded helper like `fn sum4(a0: Int, a1: Int, a2: Int, a3: Int, len: Int) -> Int { ... }` can be shown to run without allocation, recursion, or blocking, with explicit failure and stack assumptions.

23. ~~validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example: at minimum a ring buffer, bounded queue, fixed parser state machine, or bounded-state controller should prove the bounded subset is not toy-only~~ — **done**: `examples/fixed_capacity/` — bounded message validator with ring buffer for replay detection, 23 functions all passing `--check predictable`, `predictable = true` policy enforced, zero allocation, all loops bounded; ring buffer pattern uses fixed `[u8; 64]` array with modular head/count and Copy state struct returned by value; 5 pure validation functions (proof-eligible, blocked on `struct literal` and `if-without-else` extraction), 13 trusted byte-access functions (narrow boundary); 8 runtime tests cover valid messages, replay rejection, and 5 error codes; validated findings: fixed arrays + trusted pointer access + Copy structs + bounded for loops = practical no-alloc pattern; gaps discovered: no safe array indexing (all array access requires trusted pointer arithmetic), extraction blocked on struct literal and if-without-else, no trusted blocks (must factor into separate functions); 12 trust-gate fixedcap tests
24. ~~design and implement the smallest bounded-capacity type path that makes predictable examples practical~~ — **done**: two compiler bugs fixed + example rewritten to safe-indexing pattern. Compiler fixes: `isCopyTy` in CoreCheck.lean and `isCopyTyPostMono` in Verify.lean both had missing `.array` case — Copy structs with fixed-array fields were rejected; added `| .array elem _ => isCopyTy/isCopyTyPostMono allStructs allEnums elem`. Example rewrite: `examples/fixed_capacity/src/main.con` now uses `struct Copy MsgBuf { data: [u8; 256], len: i32 }` and `struct Copy RingBuf { data: [i32; 16], head: i32, count: i32 }` with safe `arr[i]` indexing — all 16 validation/ring-buffer/byte-reading functions are now `trusted: no, evidence: enforced`; only 4 test-packet builders remain trusted. 20 functions total, predictable profile passes, zero allocation, 8 runtime tests pass. Trust-gate fixedcap tests updated for new function signatures
25. ~~add stack-depth reporting for functions that pass the no-recursion profile~~ — **done**: `--report stack-depth` computes per-function frame size (params + locals via Layout.tySize), max call depth (longest path in acyclic call graph), and worst-case stack bound (sum of frame sizes along deepest chain). Recursive functions shown as "unbounded". Uses existing call graph and recursion classification from ProofCore. 12 trust-gate stackdepth tests
26. ~~classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code~~ — **done**: `docs/PREDICTABLE_BOUNDARIES.md` — 8-section classification document covering: (1) host calls reachable from predictable code (only write(2) for Console; all heap/string/FFI/blocking excluded), (2) cleanup paths (defer LIFO, no abort/OOM reachable, stack-only resources), (3) determinism sources (source-level shape deterministic; timing/binary/cache not claimed), (4) failure paths (integer overflow wraps silently, array OOB is UB gap, stack overflow via OS guard, no OOM/abort), (5) memory/UB boundaries (ownership enforced, no UAF/double-free/null-deref in safe code; array OOB and overflow remain), (6) proved function additional boundaries (PExpr theorem vs binary gap, per-function only, unbounded integer gap), (7) profile interaction summary table, (8) verification commands
27. ~~define the panic/abort/failure strategy explicitly before broader runtime and backend claims: decide abort-only versus any unwinding model, specify cleanup/no-leak behavior under failure, define FFI consequences, and state what proof-backed code may assume about panic/failure paths~~ — **done**: `docs/FAILURE_STRATEGY.md` — abort-only (permanent, no unwinding), defer runs on all normal exits (return, `?`, break, scope exit) but NOT on abort/signals, no-leak on normal paths via linear ownership + defer, leak-on-abort acceptable (OS reclaims), FFI is trust-based (longjmp is UB, extern contracts not verified), proved code avoids all failure sources by construction (no capabilities, no raw pointers). 8 summary commitments. Failure taxonomy: explicit errors (Result), abort (OOM/user/stdlib), hardware traps (SIGSEGV/SIGFPE), undefined behavior (array OOB, integer overflow)
28. ~~define explicit failure-only discipline for the predictable profile so “predictable” excludes hidden exception-style control flow and keeps error handling legible~~ — **done**: `docs/PREDICTABLE_FAILURE_DISCIPLINE.md` — allowed: explicit `Result` return, error codes, sentinel values, `?` propagation; excluded: abort (Process cap), OOM (Alloc), stack overflow from recursion, blocking I/O failure, FFI failure, longjmp; remaining gaps: integer overflow (silent wrap) and array OOB (UB) — neither is hidden control flow; verification: `--check predictable` + `--report effects` + `--report stack-depth`; PROFILES.md updated with stack-depth and failure discipline status
29. ~~add one canonical parse/validate error-flow example for the predictable subset: explicit `Result`-style propagation, explicit failure taxonomy, and no hidden runtime behavior~~ — **done**: `examples/parse_validate/` — canonical error-flow example demonstrating explicit error propagation with no hidden runtime behavior. Custom `Copy` error enum (`ParseError` with 6 named categories: TooShort, BadVersion, BadType, PayloadTooBig, Truncated, BadChecksum), custom `Copy` result enum (`ParseResult` with Ok/Err variants), 9 pure functions (all evidence: enforced, zero trusted, zero allocation). 8 runtime tests validating all 6 error categories plus 2 success paths. `predictable = true` policy enforced. Discovered SSA-verify dominator bug with accumulator-style match (many sequential match + mutable counter triggers E0703); workaround: early-return style instead. All validation functions pass `--check predictable`, all pure with `caps: (pure)`, `compute_checksum` has bounded loop. 10 trust-gate parsevalidate tests
30. ~~add one service-style error propagation example for the predictable subset: a slightly larger workflow that keeps failure categories explicit and reviewable without hidden effects~~ — **done**: `examples/service_errors/` — 4-stage service-style request handler (validate → authorize → rate-limit → process) with explicit error propagation. 3 stage-specific error enums (`ValidateError`, `AuthError`, `RateLimitError`) plus unified `ServiceError` with deterministic error codes (101-103, 201-202, 301). Custom `Request` struct, `Response` struct, `ServiceResult` enum. 12 pure functions, all evidence: enforced, zero trusted, zero allocation, zero FFI. 9 runtime tests covering: success path, 3 validation failures (bad user, bad action, payload too large), 2 auth failures (invalid token, insufficient permission), 1 rate limit failure, admin action, action-2 path. `predictable = true` policy enforced. 10 trust-gate serviceerrors tests. 4 pipeline adversarial programs added: stage conversion with unified AppError, severity classification, partial success with intermediate state, fan-in first-failure reporting
31. add a tiny source-level interpreter for the predictable/core subset as an early semantic oracle before broader backend and proof claims: start with `examples/fixed_capacity/` and `examples/parse_validate/`, compare interpreter behavior against compiled behavior, and use the interpreter to catch semantic drift while the language is still moving quickly
32. ~~treat diagnostics as a first-class product surface in the predictable core: predictable/proof/policy/ownership failures should explain the violated rule, source location, why it matters, and one plausible next step~~ — **done**: `docs/DIAGNOSTIC_UX.md` — diagnostic quality standard defining 3 tiers (good, missing "why", bare/generic), target format with rule/why/hint fields, priority categories ranked by user confusion: (1) predictable/policy violations E0610-E0612, (2) extraction blockers E0803 with per-construct explanations for 9 unsupported constructs, (3) ownership/linearity E0205-E0234 with consequence explanations, (4) stale proof repair E0800. Implementation approach: expand hint strings in Check.lean/Policy.lean/ProofCore.lean — no new types needed, existing Diagnostic fields sufficient
33. ~~write a canonical trusted-boundary design guide before more low-level examples pile up: show how to isolate `trusted` or FFI code in tiny wrappers~~ — **done**: `docs/TRUSTED_BOUNDARY_GUIDE.md` — 4 canonical wrapper patterns: (1) raw pointer reads bounded by caller (packet parser, `examples/packet/`), (2) FFI shell around POSIX/libc (file reader, `examples/elf_header/`), (3) safe alternative when trusted is unnecessary (`examples/fixed_capacity/`), (4) multi-layer orchestration with different trust levels (`examples/verify/`). Audit checklist for trusted fn (7 items) and trusted extern fn (4 items). Report/evidence material: `--report unsafe`, `--report effects`, `--query audit:`. Cross-references to FFI.md, SAFETY.md, PREDICTABLE_BOUNDARIES.md, TRUSTED_COMPUTING_BASE.md
34. ~~define the no-std / freestanding split for predictable and embedded-oriented code, with concrete examples such as `fixed_capacity` in freestanding style versus `parse_validate` in hosted-stdio style~~ — **done**: `docs/FREESTANDING_SPLIT.md` — two execution targets defined: freestanding (no stdlib, no capabilities, no libc, no entry point — pure computation only) and hosted (full stdlib, `pub fn main() -> Int`, libc-linked, all capabilities available). Feature table covering 18 items. Concrete examples: `fixed_capacity` validation core is freestanding-ready, `parse_validate` is hosted. Proposed `[profile] target = "freestanding"` in Concrete.toml. Freestanding is a strict subset of predictable — all freestanding code passes `--check predictable` by construction. Use cases: embedded firmware, kernel modules, WASM libraries, cryptographic primitives
35. ~~define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction~~ — **done**: `docs/STANDALONE_VS_PROJECT.md` — two compilation modes: standalone file (`concrete myfile.con`, no manifest, no stdlib, no policy) vs project (`concrete build` with `Concrete.toml`, stdlib auto-imported, policy enforcement, module system). Proposed `--stdlib` flag for single-file stdlib access without full project setup. Standalone `clamp_value` example, project `parse_validate` example. Migration path defined. Policy enforcement project-only by design
36. ~~define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow~~ — **done**: `docs/PROJECT_BOOTSTRAP.md` — `concrete new <name> [--template <template>]` command design, standard layout (`Concrete.toml` + `src/main.con`), 3 starter templates (predictable: error enum + bounded loop + policy; library: public exports, no main; ffi: trusted extern fn + trusted wrapper + pure validator), complete Concrete.toml field reference, first outsider workflow (new → build → run → check)
37. ~~add a canonical example inventory with exact example names, owning phase, expected claim, oracle strategy, and promotion status so the workload/showcase set cannot drift into unnamed ideas~~ — **done**: `docs/EXAMPLE_INVENTORY.md` — inventory of all 20 named examples across 4 promotion levels: 3 flagship (crypto_verify, elf_header, proof_pressure), 5 canonical (fixed_capacity, parse_validate, service_errors, thesis_demo, packet), 10 pressure (grep, http, integrity, json, kvstore, lox, mal, policy_engine, toml, verify), 2 supporting (project, snippets). Each entry records: path, owning phase, claim exercised, oracle strategy, test gate count. Multi-phase ownership table for 4 shared examples. Promotion log tracking level changes
38. ~~define example lifecycle and promotion policy explicitly: pressure example, canonical example, flagship example, and permanent regression target should have different bars and a clear promotion path~~ — **done**: `docs/EXAMPLE_LIFECYCLE.md` — 4 promotion levels with explicit bars: pressure (compiles), canonical (trust-gate tested), flagship (proof-backed or multi-phase), permanent regression target (3+ test sections, removal requires roadmap item). Promotion path: pressure → canonical → flagship → permanent. Anti-patterns: unnamed workload, test-free canonical, duplicate workload, phantom flagship. New example checklist
39. ~~define a no-duplicate-example rule for the roadmap: when one example serves multiple phases, reuse it with explicit multi-phase ownership instead of creating near-duplicate programs that fragment validation effort~~ — **done**: `docs/EXAMPLE_NO_DUPLICATES.md` — rule: reuse with multi-phase ownership instead of duplicating. When to reuse (same features, additive gates, no code change needed) vs. when to create new (fundamentally different claim, structural conflict, profile incompatibility). Current multi-phase examples: crypto_verify, elf_header, proof_pressure, thesis_demo. Near-duplicates to watch: parse_validate/service_errors (distinct), packet/fixed_capacity (distinct), integrity/verify (potential merge candidate)
40. ~~add a per-phase exit checklist for the active roadmap, starting with Predictable Core: each phase should have a small “phase closes when...” list tied to concrete outputs~~ — **done**: `docs/PHASE_EXIT_CHECKLISTS.md` — exit criteria for phases 1-7 with verifiable artifacts. Phase 1 (Predictable Core): 10 criteria covering canonical examples, boundary docs, stack-depth reporting, error propagation patterns, example governance, diagnostic UX, trusted boundary guide, no-std split, and semantic oracle. Current status: 14/18 items done, 4 remaining (31, 34-36). Phase 2-7 have concrete exit criteria tied to specific outputs. Phases 8-14 deferred until earlier phases approach completion

### Phase 2: Pre-Stdlib Pressure Workloads

Expected outcome example: real programs such as a JSON subset parser, DNS packet parser, ring buffer, and intrusive list compile cleanly enough to reveal exactly which stdlib, result/error, byte, and ownership APIs are still missing.

41. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, DNS packet parser, and at least one fixed-buffer binary parser with explicit endian handling, specifically to discover which parsing, slice/buffer, byte-cursor, and result/error APIs are actually missing
42. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, mutation, and container APIs are actually missing
43. build the borrow/aliasing program pressure set before freezing the stdlib target: sequential `&mut` workflows, borrow-heavy adapters, field/element borrow stress programs, iterator-like borrowing patterns, reborrow-heavy examples, and other programs whose main job is to force the aliasing surface into the open
44. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, OS call facade, and one C-ABI library example, specifically to discover which boundary, error/result, header-generation, and hosted-only stdlib APIs are actually missing
45. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, fixed parser state machine, and bounded-state controller, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
46. build the cleanup/leak-boundary program pressure set before freezing the stdlib target: nested defer-driven helpers, alloc/free facades, cleanup-heavy service code, cleanup-heavy FFI wrappers, and trusted/FFI cleanup boundaries that force leak reporting, destroy ergonomics, and honest no-leak-vs-audit-only framing to become explicit

### Phase 3: Stdlib and Syntax Freeze

Expected outcome example: parser-facing code such as `let len = cur.read_u16_be();` and proof-friendly helpers such as `res.map_err(...)` exist in a stable stdlib/syntax surface that is explicit, teachable, and still LL(1).

47. define the string/text encoding contract explicitly before the stable subset and stdlib freeze: make `String` and text encoding expectations, invalid-sequence handling, and byte-vs-text APIs precise so docs, stdlib, and FFI boundaries do not drift
48. define the first-release core stdlib target with a quality bar closer to the best practical languages: Rust/OCaml-level module clarity, Zig/Odin-level systems utility, and Clojure/Elixir-level documentation/discoverability for the supported subset; name the exact proof/predictability-friendly modules and APIs that must exist, and mark what is intentionally out of scope
49. define explicit stdlib design principles before polishing APIs: small orthogonal modules, obvious naming, predictable ownership/borrowing conventions, stable data/text/byte boundaries, and minimal hidden magic; use this as the filter for every new stdlib API
50. build the foundational core modules to that standard: bytes/text/string, option/result, slices/views, fixed-capacity helpers, deterministic collections, cleanup/destroy helpers, parsing/formatting helpers, and the minimum numeric/time/path APIs the pressure examples actually require
51. define the hosted stdlib split on top of the core target: OS/runtime-heavy modules, FFI-support modules, logging/runtime integrations, and other non-core surfaces should be explicitly separated from the bounded/provable-friendly core with a clear capability/trust story
52. publish a stable-subset refusal list / anti-features document before the first stdlib freeze: make explicit what the stable subset will not include yet, such as hidden async/runtime models, implicit conversions, broad inference tricks, hidden effect mechanisms, and premature contracts/ghost code
53. define arithmetic policy by profile as a public language surface before freeze: trap/modular/checked expectations and profile-specific overflow semantics must be explicit in docs, examples, and diagnostics rather than an internal assumption
54. make Result/error-flow ergonomics a first-class stdlib quality target: canonical helpers plus examples should make parse/validate and service-style error flows readable without hidden control flow
55. polish stdlib API shape, naming, and module layout against those targets: remove accidental API sprawl, make common tasks feel direct, keep advanced functionality visible but not intrusive, and make the core/hosted boundary obvious in the docs and module tree
56. make the stdlib documentation and examples first-class: every important module should have crisp docs, small examples, doc-tested happy paths, and obvious “start here” entry points so the stdlib feels teachable rather than merely available
57. validate the stdlib with canonical stdlib-backed example programs, not just unit tests: parser, ownership-heavy, FFI-boundary, fixed-capacity, and cleanup-heavy examples should all feel complete against the target surface and expose missing APIs quickly
58. add LL(1)-preserving pattern destructuring for real parser and enum-heavy code: support explicit `let` destructuring and `let ... else` forms that are local, desugarable to match, and do not introduce bare enum variant resolution or inference magic
59. add Result/error helper APIs before considering new syntax: `map_err`, `unwrap_or`, `with_context`, and related library-only helpers should cover real error-handling pressure without adding `?`-style sugar
60. define and implement explicit field/module visibility before stdlib freeze: `pub` fields, private-by-default or documented default visibility, and an `internal`/package-facing direction should be settled before packages depend on accidental visibility
61. add endian-aware byte cursor APIs for parser/decoder credibility: checked `read_u16_be`, `read_u32_le`, byte cursor bounds handling, checked narrowing, and allocation-free fixed-buffer parsing helpers should be library-first, not bitfield syntax
62. review syntax friction exposed by the pressure sets and stdlib/examples, but only through LL(1)-preserving changes: in particular, decide whether to unify qualification syntax by moving `Type#Variant` to the same `::` family as module qualification, clean up declaration modifier ordering such as `pub struct Copy Pair`, improve generic-construction ergonomics where surrounding type context already fixes the instantiation (for example allowing `let p: Pair<Int, Int> = Pair { ... }` with elaboration-time resolution rather than parser-level inference tricks), and revisit explicit field visibility only if real examples justify it; keep all such changes local, parser-regular, evidence-driven, and explicitly reject scope-heavy or context-sensitive additions such as bare enum variants, block `defer`, parser-driven generic inference, or multiple competing syntaxes for the same construct
63. add a syntax/ergonomics kill list before freeze and drive it with real examples: recurring pain points such as verbose error propagation, fixed-array boilerplate, awkward qualification, and repetitive enum/result ceremony should each get library relief, syntax relief, or an explicit deferral; examples should name concrete offenders from `parse_validate`, `fixed_capacity`, and the parser/ownership pressure sets
64. make module/interface hygiene a first-release constraint before package management: examples such as a `parser_core` plus `io_shell`, or a pure validator plus effectful wrapper, should prove explicit public/internal boundaries, capability exposure, and interface drift detection work before package graphs are trusted
65. freeze the first-release stdlib surface explicitly: record which modules and syntax forms are stable, which remain experimental, and which are intentionally deferred so the first release does not keep drifting

### Phase 4: Tooling, Tests, and Wrong-Code Corpus

Expected outcome example: a proved parser helper and an ownership-heavy negative test both live in normal workflows with formatter output, doc examples, fuzz/property hooks where relevant, and named wrong-code regressions if the compiler ever drifts.

66. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
67. add structured logging/tracing/observability primitives for real services and tools: leveled logs, structured fields, spans/events where justified, and an honest split between minimal core APIs and hosted/runtime integrations
68. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
69. add documentation-comment extraction and doc generation from source so API reference material is produced from canonical declarations/comments instead of drifting handwritten docs
70. add doc tests so code examples in docs and generated API reference can compile or run as regression tests rather than silently rotting
71. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
72. add dedicated fuzzing infrastructure where there is a real oracle: grammar fuzzing, structure-aware parser fuzzing, coverage-guided fuzzing for high-risk surfaces, and a path to keep discovered crashes/miscompiles as stable regressions
73. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
74. make reducer/minimizer workflow part of normal compiler hardening earlier, not only late backend work: minimize SSA verifier failures, wrong-code cases, fact/report mismatches, and crashers into named regressions; examples should include the `parse_validate` E0703 dominator issue, fixed-capacity drift, and future proof/evidence inconsistencies
75. add a lightweight playground / instant-feedback path before the full REPL: support single-file compile/run plus effects/predictable/proof-status summaries for examples like `clamp_value`, `parse_validate`, and `fixed_capacity` so language shaping is not gated on full project setup
76. build and maintain a named wrong-code regression corpus: every discovered miscompile, codegen bug, obligation bug, checker soundness bug, and proof-pipeline regression should land as a stable reproduction, not just disappear into the general suite
77. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful

### Phase 5: Performance, Artifacts, and Contract Hardening

Expected outcome example: a proof-bearing function ships with stable report artifacts, benchmark numbers, allocation/leak visibility, and compiler dumps that let a reviewer connect source behavior to evidence and performance.

78. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
79. add explicit compiler performance budgets on top of profiling: acceptable compile-time regressions, artifact-generation overhead, and memory-growth limits that CI and review can enforce
80. add compile-time regression profiling: parse/check/elaboration/proof/report time, artifact-generation cost, and enough baseline data to keep the compiler usable as the proof pipeline grows
81. add compiler memory profiling and scaling baselines: peak memory, artifact-generation overhead, and growth characteristics on larger proof/fact workloads
82. add runtime/allocation profiling workflow: profiler-friendly output, allocation hot spots, allocation-path visibility, source-location attribution, and a path to correlate profiling results with `--report alloc` / evidence artifacts
83. add large-workspace and many-artifact scaling tests: many modules, many facts, many obligations, repeated snapshot/report workflows, and enough volume to expose nonlinear behavior before package/editor use depends on it
84. deepen leak-risk reporting once the first no-leak boundary and leak reports exist: add richer allocation/cleanup path explanations, trusted/FFI leak attribution, and more precise leak-risk classes where the strong no-leak guarantee does not apply
85. deepen allocation/leak regression coverage once the first reporting surfaces exist: adversarial tests for cleanup-path classification, leak-risk classification, trusted/FFI leak boundaries, and `--report alloc` consistency on larger examples
86. define a real warning/lint discipline: separate hard errors, warnings, deny-in-CI warnings, and advisory lints so diagnostics can get stricter without turning every issue into a compile failure
87. add compiler-debuggable dump modes for the important IR boundaries: typed/core IR, ProofCore, obligations, diagnostics, lowering, and SSA should all have stable human-readable dumps suitable for debugging and regression review
88. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
89. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
90. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation

### Phase 6: Release Credibility and Showcase

Expected outcome example: a flagship packet/header validator has explicit authority, one Lean-backed property, report/snapshot/diff coverage, and a release evidence bundle that tells an outsider exactly what is proved and what is assumed.

91. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
92. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, policy declarations, and package-boundary evidence summaries as normal build artifacts
93. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale; the corpus must include borrow/aliasing programs, cleanup/leak-boundary programs, at least one ownership-heavy medium example, and at least one bounded/no-alloc medium example, not only parsers and containers
94. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec; include explicit borrow/aliasing, cleanup/leak-boundary, privilege/authority, ownership-heavy, and bounded/no-alloc examples in that quality bar
95. require capability-shaped APIs in at least one flagship example so authority passing and narrowing are visible in the source/API surface, not only in reports
96. require one privilege-separated capability-first showcase in the public corpus so capability discipline is demonstrated as a core thesis example rather than an incidental side property
97. publish a supported-workload matrix before the first major release: explicitly separate first-class supported workloads, showcase-only workloads, and research-only workloads so the public claim matches the actual language surface
98. harden semantic diff / trust-drift review into a first-class workflow over stable facts and package/release artifacts, not just a research note or one-off diff tool: this should grow to include proof-target drift, theorem/attachment drift, claim-scope drift, package-boundary evidence drift, and a reviewer-facing proof-diff story that answers what changed, what is still proved, and which assumptions moved
99. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
100. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete; include C-header scaffolding and stale-proof repair suggestions before broader migration automation
101. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
102. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
103. make mechanically auditable C-replacement examples a named release bar: replace at least one C packet validator, one C state machine, one syscall wrapper, and one checksum/length-check helper with Concrete examples that have a smaller trusted surface and richer report/evidence output than the original C versions
104. build a named big-workload flagship set, not just small pressure examples: at minimum one real protocol/parser security example, one crypto/security proof example, one privilege-separated tool, one ownership-heavy medium program, and one bounded/no-alloc medium program; the set should be explicit enough that no core thesis area is represented only by snippets
105. require each big-workload flagship to have honest proof/trust boundary framing, report/snapshot/diff coverage, and an oracle when possible (fuzzing, differential testing, round-trip properties, or model-based checks) so they function as real validation workloads instead of marketing demos
106. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders; the example bar must explicitly include parser/decoder, ownership-heavy, borrow/aliasing, trusted-wrapper/FFI, fixed-capacity, cleanup/leak-boundary, the named big-workload programs, the named profile surfaces, and a release evidence contract for each flagship example (proof/report/diff artifacts plus explicit assumptions)
107. define a public security and soundness disclosure policy before first release: how users report compiler soundness bugs, miscompiles, stdlib safety bugs, proof-evidence bugs, and trusted-boundary issues, plus expected triage and embargo handling
108. define the release/install distribution matrix before the first real public release: release binaries, supported host triples, checksums/signing, install paths, and which distribution channels are first-class versus deferred
109. define reproducible release-build expectations for the compiler and distribution artifacts: what must be bit-for-bit reproducible, what may vary, how rebuilds are verified, and how non-reproducible components are documented
110. define compiler-release supply-chain provenance: signed release binaries, checksums, source commit identity, Lean/toolchain identity, build environment metadata, and verification instructions for users
111. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
112. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
113. add a REPL and lightweight playground workflow once the parser/checker diagnostics and project UX are stable enough that quick experimentation will reflect the real language instead of a toy front-end

### Phase 7: Proof Expansion and Provable Subset

Expected outcome example: helper-composition code such as `fn validate_header(...) -> Bool { if !check_magic(...) { return false; } return check_class(c); }` can carry a Lean-backed claim that successful return implies multiple structural invariants, not just one tiny helper fact.

114. polish the packet/parser flagship example as the canonical thesis demo; likely candidates are the packet, HTTP, DNS, or ELF parser surfaces, but at least one must become the explicit flagship with oracle-backed validation
115. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary; good candidates are a libc wrapper, checksum/hash wrapper, OS call facade, or C-ABI library example
116. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup; likely candidates are an ordered map, intrusive list, tree, or arena-backed graph
117. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes; it should be a real medium program, not only a tiny policy toy
118. build a fixed-capacity / no-alloc showcase that proves the predictable subset is practical for real bounded systems code; likely candidates are a ring buffer, bounded queue, bounded-state controller, or fixed parser state machine
119. build a real cryptography example only after the proof/artifact boundary is stronger: good candidates are constant-time equality + verification use, an HMAC verification core, an Ed25519 verification helper/core subset, or hash/parser/encoding correctness around a crypto-adjacent component; the goal is to prove the system is useful on security-sensitive code rather than only format parsing
120. refine and stabilize the explicit `Core -> ProofCore` phase after the flagship has forced it into the open: keep the extraction semantics small, testable, and shared by obligations, specs, proofs, and future proof tools
121. extend ProofCore and its semantics to cover more real Concrete constructs in a principled order: structs/fields, pattern matching, arrays/slices, borrows/dereferences, casts, cleanup/defer/drop behavior, and other constructs the flagship examples actually force into scope
122. broaden proof obligation generation beyond the first pipeline slice so loop-related, memory-related, and contract-related proof work becomes mechanically inspectable instead of ad hoc
123. broaden the pure Core proof fragment after proof artifacts, diagnostics, the explicit ProofCore phase, normalization, and obligation generation are usable
124. deepen the memory/reference model for proofs once the first explicit version exists: sharpen ownership, aliasing, mutation, pointer/reference, cleanup, and layout reasoning where real examples require it
125. deepen the effect/trust proof boundaries once the first explicit version exists: prove more right up to capability, allocation, blocking, FFI, and trusted edges without pretending the edges disappear
126. add a dedicated proof-regression test pipeline covering `Core -> ProofCore`, normalization stability, obligation generation, exclusion reasons, stale proof behavior, and proof artifact drift
127. stabilize the provable subset as an explicit user-facing target
128. define public release criteria for the provable subset: supported constructs, unsupported constructs, trust assumptions, proof artifact stability expectations, and what evidence claims users may rely on semantically
129. build a small reference interpreter for the proof-relevant subset once the `Core -> ProofCore` boundary and memory/UB model are precise enough: use it as a semantic oracle for the restricted subset, compare interpreter results against proof semantics and compiled behavior, and keep it intentionally smaller and more trustworthy than the full compiler
130. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
131. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
132. add AI-assisted proof repair and authoring support only on top of stable proof artifacts, explicit statuses, and kernel-checked validation: suggestions may help with stale-proof repair, attachment updates, and theorem scaffolding, but the trust anchor must remain Lean checking plus compiler artifact validation
133. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
134. push selected compiler-preservation proofs where they protect evidence claims
135. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, the explicit ProofCore boundary, and the built-in proof workflow are real enough to support them honestly
136. evaluate loop invariants only after specs, proof obligations, and the proof UX/repair loop are real enough that users can diagnose failures without compiler-internal knowledge
137. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
138. pull research-gated language features into implementation only when a current example or proof needs them

### Phase 8: Backend, Target, and Incremental Pipeline

Expected outcome example: the same pure function and proof artifacts produce equivalent facts, obligations, diagnostics, and outputs across clean builds, incremental builds, and supported backend/target configurations under documented assumptions.

139. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
140. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
141. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
142. stabilize SSA as the backend contract before experimenting with another backend
143. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
144. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
145. write a host-boundary / platform-boundary design note before broader runtime and package claims: make core vs hosted vs freestanding expectations, host/runtime responsibilities, and artifact boundary assumptions explicit without importing Roc’s managed-effect model
146. evaluate SIMD/vector types and architecture-specific intrinsics only after the backend contract and target/toolchain model are explicit: decide portable-vs-target-specific surface, proof/predictability implications, and whether the feature belongs in core language, stdlib, or trusted boundary
147. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
148. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
149. add cross-backend validation if a second backend lands
150. add source-level debug-info support when codegen maturity becomes the bottleneck
151. make the target/toolchain model concrete enough to support an explicit WASM target decision: either land a narrow WASM path with honest runtime/tooling limits or record a clear deferral with reasons
152. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
153. add clean-build versus incremental-build equivalence checks: the same source and toolchain state must produce identical facts, obligations, diagnostics, reports, and codegen outputs whether built from scratch or through incremental caches
154. add compiler-process resource-hygiene checks for long-running workflows: repeated report/query/snapshot/incremental runs should not leak memory, file descriptors, temp artifacts, or subprocess state
155. extend the first reducer/minimizer into a broader workflow: add package-aware and multi-file reduction, richer syntax-aware rewrites, and wrong-code / artifact-mismatch predicates on top of the landed single-file crash/verifier/consistency reducer
156. define a canonical semantic test matrix: every important language rule and artifact guarantee should map to positive, negative, adversarial, and artifact-level regression coverage

### Phase 9: Compiler Verification and Preservation Proofs

Expected outcome example: a simple function like `fn add1(x: Int) -> Int { return x + 1; }` is not only user-proved for a property, but also backed by proofs that `Core -> ProofCore` extraction and selected normalization/preservation steps keep its intended pure meaning intact.

157. define precisely what “compiler proof” means for Concrete: distinguish user-code property proofs, ProofCore semantic proofs, pass-preservation proofs, and any future end-to-end compiler correctness claim
158. separate public user-code proof claims from compiler-correctness claims so reports never imply the compiler itself is fully verified when only selected user properties are Lean-backed
159. inventory the compiler-verification trusted base and unproved assumptions: parser, checker, elaborator, CoreCheck, monomorphization, lowering, SSA emission, LLVM/toolchain, runtime, target model, and proof registry attachment
160. prove ProofCore normalization preserves ProofCore semantics for the supported expression fragment before relying on normalized proof targets as equivalent to extracted targets
161. prove `Core -> ProofCore` extraction sound for the supported constructs: if extraction succeeds, the ProofCore expression represents the intended pure Core meaning under the documented assumptions
162. prove selected checker/report/artifact facts agree with compiler state: proof eligibility, predictable status, capabilities, trusted boundaries, fingerprints, obligations, and traceability should not drift from the data that produced them
163. prove small internal compiler invariants before broad pass preservation: no post-mono type variables, well-formed qualified identities, well-formed SSA facts, consistent module/interface artifacts, and stable diagnostic attachment where applicable
164. prove selected pass-preservation properties for a restricted pure subset, starting with transformations that directly affect proof/evidence claims rather than trying to verify the whole compiler at once
165. use the small reference interpreter as an executable semantic oracle for the proof-relevant subset and compare interpreter behavior against ProofCore semantics and compiled behavior where the target model permits
166. decide whether full end-to-end compiler correctness is in scope; if yes, define the restricted source subset, target/backend assumptions, proof architecture, and explicit non-goals before implementation begins

### Phase 10: Package System and Dependency Trust

Expected outcome example: a package exporting `pub fn parse_version(...) -> Int` also exports package-level facts about proof status, trusted assumptions, and authority surface so downstream users can review trust widening before adoption.

167. split interface artifacts from body artifacts at package/workspace scale
168. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
169. harden package-aware visibility and encapsulation before package management: public/internal/private API boundaries, exported field policy, sealed/internal modules where needed, and diagnostics for accidental API leakage should be explicit before package graphs are trusted
170. design and parse the package manifest
171. add build-script/custom-build-logic support only after the package manifest is stable enough to host it: code generation, C library compilation, resource embedding, and environment detection should be explicit and constrained rather than arbitrary hidden shelling-out
172. add version constraints, dependency resolution, and a lockfile
173. add workspace and multi-package support
174. add package-aware test selection
175. generate C headers from public C-ABI-facing Concrete declarations so library-grade `extern \"C\"` / `repr(C)` surfaces do not require manually maintained `.h` files
176. validate cross-target FFI/ABI from package boundaries
177. add module/package authority budgets after package graphs are real
178. define package/runtime boundary artifacts explicitly: packages should declare what they require from host/runtime/platform surfaces, not only what they export at the source level
179. add package discoverability and package-quality gates so docs, examples, trust summaries, and compatibility surfaces are part of package readiness rather than an afterthought
180. define provenance-aware publishing before public package distribution
181. define package registry server protocol and trust model before a public ecosystem push: upload/download, index/search, yanking/deprecation, checksums/signatures, authentication, and compatibility with provenance/evidence artifacts
182. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible

### Phase 11: Editor, Artifact UX, and Compatibility

Expected outcome example: hovering over `fn check_nonce(...) -> Bool` in an editor shows capability status, proof status, predictable status, and theorem/obligation links from the same underlying artifact model.

183. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
184. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
185. treat refactoring support as an explicit product goal, not an incidental side effect of LSP work: rename, move, extract-helper, interface extraction, and dead-code cleanup should preserve or clearly update facts/proofs where possible; examples should include moving a parser helper between modules, renaming a proof-attached validator, and extracting a capability-free core from an effectful shell
186. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
187. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
188. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
189. set a stronger docs/tooling UX bar for external users: generated docs, language-server quality, newcomer navigation, and project-level discoverability must be treated as first-class deliverables rather than polish work
190. add one canonical “how to use Result well” docs-and-examples surface so explicit error handling stays teachable, consistent, and visible in user-facing tooling
191. add release / compatibility discipline when external users depend on the language
192. build a backwards-compatibility regression corpus once public users exist: old accepted programs, old facts/reports, old proof artifacts, deprecated syntax/API examples, and expected migration diagnostics should remain testable across releases
193. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
194. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs

### Phase 12: Runtime Profiles, Allocation, and Predictability

Expected outcome example: a bounded queue or parser helper can carry claims like “no allocation” or “bounded allocation,” explicit overflow policy, and explicit failure-path assumptions rather than hand-wavy runtime promises.

195. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
196. define the async/evented-I/O stance explicitly before deep runtime work: whether evented I/O stays library-level, whether async/await is intentionally out of scope, and what concurrency/runtime promises Concrete will or will not make
197. implement OS threads + typed channels only after the concurrency stance is documented
198. keep evented I/O as a later opt-in model, not the default concurrency story
199. explicitly defer inline assembly until the backend contract, target/toolchain model, and trust-boundary story are strong enough to contain it honestly
200. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
201. add structural bounded-allocation reports where the compiler can explain the bound
202. add `BoundedAlloc(N)` only where the bound is structurally explainable
203. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
204. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
205. define stack-boundedness reporting and enforcement boundaries
206. separate source-level stack-depth claims from backend/target stack claims
207. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
208. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
209. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
210. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent

### Phase 13: Public Readiness and User Tooling

Expected outcome example: a new user can install Concrete, run one proof-bearing example, inspect its evidence bundle, and understand what is proved, enforced, reported, or trusted without reading the compiler source.

211. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
212. add coverage tooling over tests, report facts, policy checks, obligations, proof artifacts, and doc tests
213. add memory-profiler and leak-debug integration for user programs once runtime/allocation profiling exists: heap snapshots or allocation tracing where the target allows it, leak-focused workflows, and a path to correlate runtime findings with `--report alloc`
214. improve onboarding so a newcomer can build one small program without project-author help
215. define the stability / experimental boundary for public users
216. define the language evolution policy on top of that boundary: edition/versioning rules, deprecation windows, breaking-change policy, and how experimental features graduate into the supported subset
217. define public governance and decision process for language evolution: how syntax changes, profile changes, stdlib stabilization, breaking changes, and security-relevant decisions are proposed, reviewed, accepted, and documented

### Phase 14: Long-Horizon Research Backlog

Expected outcome example: future ideas such as typestate, arena proofs, richer timing models, or Miri-style semantic checking stay clearly gated until Concrete already has a stable artifact/proof/evidence foundation.

218. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
219. research typestate only if a current state-machine/protocol example needs it
220. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
221. research target-specific timing models after source-level predictability and backend boundaries are explicit
222. research exact WCET / runtime models only with a target/hardware model
223. research exact stack-size claims across optimized machine code only with deeper backend/target integration
224. research cache / pipeline behavior as target-level analysis, not a source-language promise
225. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
226. research hardware capability mapping after source-level capabilities and package policies are stable
227. research capability sandbox profiles after authority reports and package policies are useful
228. broaden the small reference interpreter toward fuller Miri-style UB checking only if the first proof-subset interpreter proves valuable and the memory/UB model can support the added operational complexity
229. research persistent equality / rewrite state across phases only after the backend contract, semantic diff workflow, and proof/evidence pipeline are stronger; use [persistent-equality-and-rewrite-state](research/compiler/persistent-equality-and-rewrite-state.md) as the starting point
## Reference Map

The thesis references are [core-thesis](research/thesis-validation/core-thesis.md), [objective-matrix](research/thesis-validation/objective-matrix.md), [thesis-validation](research/thesis-validation/thesis-validation.md), [validation-examples](research/thesis-validation/validation-examples.md), [predictable-execution](research/predictable-execution/predictable-execution.md), [effect-taxonomy](research/predictable-execution/effect-taxonomy.md), [diagnostic-ux](research/compiler/diagnostic-ux.md), and [backend-traceability](research/compiler/backend-traceability.md).

The proof/evidence references are [concrete-to-lean-pipeline](research/proof-evidence/concrete-to-lean-pipeline.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [spec-attachment](research/proof-evidence/spec-attachment.md), [effectful-proofs](research/proof-evidence/effectful-proofs.md), [provable-systems-subset](research/proof-evidence/provable-systems-subset.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md), [proof-ux-and-verification-influences](research/proof-evidence/proof-ux-and-verification-influences.md), [proof-ux-and-authoring-loop](research/proof-evidence/proof-ux-and-authoring-loop.md), [verification-product-model](research/proof-evidence/verification-product-model.md), [vericoding-and-evidence-product](research/proof-evidence/vericoding-and-evidence-product.md), [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), and [proof-evidence-artifacts](research/proof-evidence/proof-evidence-artifacts.md).

The language/runtime references are [failure-semantics](research/language/failure-semantics.md), [high-integrity-profile](research/language/high-integrity-profile.md), [memory-ub-boundary](research/language/memory-ub-boundary.md), [trusted-code-policy](research/language/trusted-code-policy.md), [contracts-and-invariants-gating](research/language/contracts-and-invariants-gating.md), [interrupt-signal-model](research/language/interrupt-signal-model.md), [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [arena-allocation](research/stdlib-runtime/arena-allocation.md), [execution-cost](research/stdlib-runtime/execution-cost.md), and [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md).

The compiler/package references are [semantic-diff-and-trust-drift](research/compiler/semantic-diff-and-trust-drift.md), [miri-style-interpreter](research/compiler/miri-style-interpreter.md), [persistent-equality-and-rewrite-state](research/compiler/persistent-equality-and-rewrite-state.md), [package-model](research/packages-tooling/package-model.md), and [proof-aware-package-boundaries](research/packages-tooling/proof-aware-package-boundaries.md).

The tooling/package/backend/showcase references are [artifact-driven-compiler](research/compiler/artifact-driven-compiler.md), [semantic-query-interface](research/compiler/semantic-query-interface.md), [performance-research-packets](research/compiler/performance-research-packets.md), [developer-tooling](research/packages-tooling/developer-tooling.md), [package-model](research/packages-tooling/package-model.md), [package-manager-design](research/packages-tooling/package-manager-design.md), [qbe-backend](research/compiler/qbe-backend.md), [qbe-in-concrete](research/compiler/qbe-in-concrete.md), [showcase-workloads](research/workloads/showcase-workloads.md), [adoption-strategy](research/workloads/adoption-strategy.md), and [phase-h-findings](research/workloads/phase-h-findings.md).

---

## Design Constraints

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over phi transport
- avoid parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable
- make serious errors and report failures explain themselves: a user should know the violated rule, the source location, the reason it matters, and one plausible next action

## Current Risks

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
- formalization scope is still narrow
- type-coercion completeness is not proved, only hardened
- the linearity checker is tested heavily but not formally audited

## Longer-Horizon Multipliers

- proof-backed trust claims
- stronger audit outputs
- a smaller trusted computing base
- a better capability/sandboxing story

**References:** [ten-x-improvements](research/meta/ten-x-improvements.md), [capability-sandboxing](research/language/capability-sandboxing.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [ai-assisted-optimization](research/meta/ai-assisted-optimization.md)
