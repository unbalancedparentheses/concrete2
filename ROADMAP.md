# Concrete Roadmap

This document is the active execution plan. It answers one question: **what should happen next, in what order?**

Read it as one continuous priority list. Phase titles are human scan markers, not separate queues, and task numbering never restarts.

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

## Priority Map

| Phase | Items | Human goal |
|---|---:|---|
| 1. Compiler Integrity and Artifact Truth | 1-2 | Make serious compiler failures, artifact drift, identity drift, schema drift, and diagnostic drift fail explicitly. |
| 2. Concrete-to-Lean Proof Pressure and Claim Boundaries | 3-18 | Prove real Concrete functions with Lean while keeping claims, profiles, and TCB boundaries honest. |
| 3. Predictable Core | 19-26 | Make bounded, predictable, failure-aware code usable before broadening scope. |
| 4. Pre-Stdlib Pressure Workloads | 27-32 | Use real workloads to discover what the stdlib must actually provide. |
| 5. Stdlib and Syntax Freeze | 33-46 | Define, build, polish, and freeze the first-release stdlib, visibility, error, binary parsing, and LL(1) syntax surface. |
| 6. Tooling, Tests, and Wrong-Code Corpus | 47-56 | Make examples, docs, formatting, fuzzing, and wrong-code capture normal workflow. |
| 7. Performance, Artifacts, and Contract Hardening | 57-69 | Put budgets, reports, artifacts, and explicit failure behavior around the compiler. |
| 8. Release Credibility and Showcase | 70-89 | Prepare honest public positioning, showcases, security process, release provenance, install paths, and release criteria. |
| 9. Proof Expansion and Provable Subset | 90-114 | Grow ProofCore, obligations, and provable-subset claims after the narrow proof workflow is real. |
| 10. Backend, Target, and Incremental Pipeline | 115-131 | Stabilize backend contracts, targets, incremental builds, and semantic regression coverage. |
| 11. Compiler Verification and Preservation Proofs | 132-141 | Scope and prove selected compiler properties without overclaiming full compiler correctness. |
| 12. Package System and Dependency Trust | 142-155 | Add packages only after artifacts, visibility, and trust summaries know what they must carry. |
| 13. Editor, Artifact UX, and Compatibility | 156-164 | Expose facts, diagnostics, proof state, artifacts, compatibility tests, and stability policy to users and tools. |
| 14. Runtime Profiles, Allocation, and Predictability | 165-180 | Define concurrency, allocation, stack, failure, timing, and overflow boundaries. |
| 15. Public Readiness and User Tooling | 181-187 | Make the language easier to adopt, audit, govern, and evolve publicly. |
| 16. Long-Horizon Research Backlog | 188-199 | Keep speculative language/runtime/research ideas visible but clearly gated. |

## Operating Rules

- Do the numbered list top-to-bottom unless a later item is explicitly research-only or parallelizable.
- When an item is completed, move it to [CHANGELOG.md](CHANGELOG.md) and renumber the remaining active list.
- Judge new language features by grammar cost, audit cost, and proof cost, not just expressiveness.
- Do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until earlier evidence/diagnostic/tooling steps make them concrete.
- Keep specs in Lean-attached / artifact-registry form until obligations and diagnostics are strong enough to support source-level contracts honestly.
- Build a normal fact CLI before MCP/editor integrations.
- Keep QBE and other backend work waiting until proof/evidence attachment, optimization policy, and backend trust boundaries are trustworthy.
- Treat compiler verification as a long-term trust multiplier after ProofCore, artifact schemas, reference-interpreter work, and backend/target assumptions are stable; do not make full compiler correctness a first-release promise.
- Parallelize only low-risk inventories and docs while the active implementation path is proof/diagnostic/compiler-contract work.

## Active List

The active roadmap starts after the proof/memory/determinism/diagnostics/policy/adversarial-foundation work already recorded in [CHANGELOG.md](CHANGELOG.md).

### Phase 1: Compiler Integrity and Artifact Truth

All Phase 1 items are complete — see [CHANGELOG.md](CHANGELOG.md) for details.

### Phase 2: Concrete-to-Lean Proof Pressure and Claim Boundaries

1. ~~define the narrow Concrete-to-Lean proof pressure set before stdlib work: choose 3-5 small real Concrete functions, at least one conditional-heavy parser/validator function, one helper-composition function, and one intentionally excluded function so the workflow exercises proved, stale, blocked, missing, and ineligible states~~ — **done**: 6-function pressure set in `examples/proof_pressure/` covering proved (2), stale (1), missing (1), blocked (1), ineligible (2); design doc in `docs/PROOF_PRESSURE_SET.md`; 7 regression gates in trust-gate evidence section
2. ~~make ProofCore extraction for the pressure set reproducible and inspectable: each selected function should have a stable extracted form, fingerprint, eligibility reason, and obligation entry that can be reviewed without reading compiler internals~~ — **done**: fixed effects/evidence discrepancy (was using hardcoded proofs, now uses obligations); 24 trust-gate assertions cover extraction forms, status/blockers, obligation deps/sources, eligibility reasons, effects consistency, and determinism
3. generate or maintain Lean theorem stubs for the pressure set from compiler artifacts: function identity, spec name, proof target, parameters, and extracted expression should appear in a predictable Lean-facing shape that a user can complete manually
4. validate Lean theorem identity and attachment integrity as a checked boundary: fabricated proof names, missing theorem references, mismatched spec/theorem pairs, and registry/body mismatches must fail explicitly before user proof artifacts are treated as trustworthy
5. wire actual Lean kernel checking into the narrow proof workflow: a proof should count as proved only when the referenced Lean theorem exists and the relevant Lean module checks under the pinned toolchain, not merely because a registry entry names it
6. add end-to-end Lean attachment regression coverage for the narrow proof slice: registry entries, proof names, theorem identities, extracted proof targets, actual Lean checking, stale detection, and proof-status facts should be tested together as one workflow
7. add stale-proof repair pressure tests: mutate a proved Concrete function, require the report to show the exact fingerprint/body drift, then restore or update the attachment and verify the status returns to proved
8. add blocked/ineligible proof pressure tests: include unsupported constructs, capability/trusted boundaries, and effectful functions so the proof workflow explains why a function is not proved without overclaiming
9. make build / check / report / prove feel like one coherent product workflow for the narrow slice: proof status, stale detection, blocked/ineligible states, spec/claim scope, and artifact-backed evidence should be part of the normal toolchain story rather than sidecar research output
10. scope `require-proofs` enforcement to the user package: today `enforceRequireProofs` checks all obligations including stdlib, which makes the policy unusable in practice; scope it to project modules only (matching how `enforcePredictable` and `enforceDeny` already filter by `depNames`), then add a real passing boundary test once scoped enforcement exists
11. define the user proof-authoring and maintenance workflow explicitly for that slice: how a user writes or updates specs and proofs, regenerates artifacts, diagnoses stale or blocked proofs, and lands proof-preserving refactors without reading compiler internals
12. add a proof-workflow debug bundle or report bundle for the pressure set, then harden it toward a stable evidence bundle: source, extracted ProofCore, obligations, registry entries, Lean theorem names, fingerprints, diagnostics, proof-status facts, and relevant toolchain identity should be captured together for review, bug reports, CI, and later release evidence
13. gate the narrow Concrete-to-Lean proof workflow in CI once stable: at minimum run extraction, registry validation, Lean theorem checking for the pressure set, stale-proof checks, and proof-status consistency as one evidence gate
14. keep a canonical “claims today” surface current before the first major release: one short public document that states what Concrete guarantees today, what it does not guarantee yet, what proof/enforcement/report/trusted claim class each promise belongs to, and what assumptions/backends/trusted boundaries remain
15. publish named user-facing profiles before the first major release: make `safe`, `predictable`, `provable`, and the longer-term `high-integrity` direction explicit, and say which are current, which are partial, and which remain future-facing
16. keep explicit trusted-computing-base accounting current for the strongest claims: Concrete checker assumptions, Lean kernel assumptions, registry/trusted-code assumptions, backend/toolchain assumptions, and target/runtime assumptions should stay visible in one canonical place as the project evolves

### Phase 3: Predictable Core

17. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
18. design and implement the smallest bounded-capacity type path that makes predictable examples practical
19. add stack-depth reporting for functions that pass the no-recursion profile
20. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
21. define the panic/abort/failure strategy explicitly before broader runtime and backend claims: decide abort-only versus any unwinding model, specify cleanup/no-leak behavior under failure, define FFI consequences, and state what proof-backed code may assume about panic/failure paths
22. define the no-std / freestanding split for predictable and embedded-oriented code
23. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
24. define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow for trying the language without project-author help

### Phase 4: Pre-Stdlib Pressure Workloads

25. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, and DNS packet parser, specifically to discover which parsing, slice/buffer, and result/error APIs are actually missing
26. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, and container APIs are actually missing
27. build the borrow/aliasing program pressure set before freezing the stdlib target: sequential `&mut` workflows, borrow-heavy adapters, field/element borrow stress programs, iterator-like borrowing patterns, and other programs whose main job is to force the aliasing surface into the open
28. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, and OS call facade, specifically to discover which boundary, error/result, and hosted-only stdlib APIs are actually missing
29. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, and fixed parser state machine, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
30. build the cleanup/leak-boundary program pressure set before freezing the stdlib target: nested defer-driven helpers, alloc/free facades, cleanup-heavy service code, and trusted/FFI cleanup boundaries that force leak reporting and destroy ergonomics to become honest

### Phase 5: Stdlib and Syntax Freeze

31. define the string/text encoding contract explicitly before the stable subset and stdlib freeze: make `String` and text encoding expectations, invalid-sequence handling, and byte-vs-text APIs precise so docs, stdlib, and FFI boundaries do not drift
32. define the first-release core stdlib target with a quality bar closer to the best practical languages: Rust/OCaml-level module clarity, Zig/Odin-level systems utility, and Clojure/Elixir-level documentation/discoverability for the supported subset; name the exact proof/predictability-friendly modules and APIs that must exist, and mark what is intentionally out of scope
33. define explicit stdlib design principles before polishing APIs: small orthogonal modules, obvious naming, predictable ownership/borrowing conventions, stable data/text/byte boundaries, and minimal hidden magic; use this as the filter for every new stdlib API
34. build the foundational core modules to that standard: bytes/text/string, option/result, slices/views, fixed-capacity helpers, deterministic collections, cleanup/destroy helpers, parsing/formatting helpers, and the minimum numeric/time/path APIs the pressure examples actually require
35. define the hosted stdlib split on top of the core target: OS/runtime-heavy modules, FFI-support modules, logging/runtime integrations, and other non-core surfaces should be explicitly separated from the bounded/provable-friendly core with a clear capability/trust story
36. polish stdlib API shape, naming, and module layout against those targets: remove accidental API sprawl, make common tasks feel direct, keep advanced functionality visible but not intrusive, and make the core/hosted boundary obvious in the docs and module tree
37. make the stdlib documentation and examples first-class: every important module should have crisp docs, small examples, doc-tested happy paths, and obvious “start here” entry points so the stdlib feels teachable rather than merely available
38. validate the stdlib with canonical stdlib-backed example programs, not just unit tests: parser, ownership-heavy, FFI-boundary, fixed-capacity, and cleanup-heavy examples should all feel complete against the target surface and expose missing APIs quickly
39. add LL(1)-preserving pattern destructuring for real parser and enum-heavy code: support explicit `let` destructuring and `let ... else` forms that are local, desugarable to match, and do not introduce bare enum variant resolution or inference magic
40. add Result/error helper APIs before considering new syntax: `map_err`, `unwrap_or`, `with_context`, and related library-only helpers should cover real error-handling pressure without adding `?`-style sugar
41. define and implement explicit field/module visibility before stdlib freeze: `pub` fields, private-by-default or documented default visibility, and an `internal`/package-facing direction should be settled before packages depend on accidental visibility
42. add endian-aware byte cursor APIs for parser/decoder credibility: checked `read_u16_be`, `read_u32_le`, byte cursor bounds handling, checked narrowing, and allocation-free fixed-buffer parsing helpers should be library-first, not bitfield syntax
43. review syntax friction exposed by the pressure sets and stdlib/examples, but only through LL(1)-preserving changes: in particular, decide whether to unify qualification syntax by moving `Type#Variant` to the same `::` family as module qualification, clean up declaration modifier ordering such as `pub struct Copy Pair`, improve generic-construction ergonomics where surrounding type context already fixes the instantiation (for example allowing `let p: Pair<Int, Int> = Pair { ... }` with elaboration-time resolution rather than parser-level inference tricks), and revisit explicit field visibility only if real examples justify it; keep all such changes local, parser-regular, evidence-driven, and explicitly reject scope-heavy or context-sensitive additions such as bare enum variants, block `defer`, parser-driven generic inference, or multiple competing syntaxes for the same construct
44. freeze the first-release stdlib surface explicitly: record which modules and syntax forms are stable, which remain experimental, and which are intentionally deferred so the first release does not keep drifting

### Phase 6: Tooling, Tests, and Wrong-Code Corpus

45. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
46. add structured logging/tracing/observability primitives for real services and tools: leveled logs, structured fields, spans/events where justified, and an honest split between minimal core APIs and hosted/runtime integrations
47. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
48. add documentation-comment extraction and doc generation from source so API reference material is produced from canonical declarations/comments instead of drifting handwritten docs
49. add doc tests so code examples in docs and generated API reference can compile or run as regression tests rather than silently rotting
50. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
51. add dedicated fuzzing infrastructure where there is a real oracle: grammar fuzzing, structure-aware parser fuzzing, coverage-guided fuzzing for high-risk surfaces, and a path to keep discovered crashes/miscompiles as stable regressions
52. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
53. build and maintain a named wrong-code regression corpus: every discovered miscompile, codegen bug, obligation bug, checker soundness bug, and proof-pipeline regression should land as a stable reproduction, not just disappear into the general suite
54. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful

### Phase 7: Performance, Artifacts, and Contract Hardening

55. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
56. add explicit compiler performance budgets on top of profiling: acceptable compile-time regressions, artifact-generation overhead, and memory-growth limits that CI and review can enforce
57. add compile-time regression profiling: parse/check/elaboration/proof/report time, artifact-generation cost, and enough baseline data to keep the compiler usable as the proof pipeline grows
58. add compiler memory profiling and scaling baselines: peak memory, artifact-generation overhead, and growth characteristics on larger proof/fact workloads
59. add runtime/allocation profiling workflow: profiler-friendly output, allocation hot spots, allocation-path visibility, source-location attribution, and a path to correlate profiling results with `--report alloc` / evidence artifacts
60. add large-workspace and many-artifact scaling tests: many modules, many facts, many obligations, repeated snapshot/report workflows, and enough volume to expose nonlinear behavior before package/editor use depends on it
61. deepen leak-risk reporting once the first no-leak boundary and leak reports exist: add richer allocation/cleanup path explanations, trusted/FFI leak attribution, and more precise leak-risk classes where the strong no-leak guarantee does not apply
62. deepen allocation/leak regression coverage once the first reporting surfaces exist: adversarial tests for cleanup-path classification, leak-risk classification, trusted/FFI leak boundaries, and `--report alloc` consistency on larger examples
63. define a real warning/lint discipline: separate hard errors, warnings, deny-in-CI warnings, and advisory lints so diagnostics can get stricter without turning every issue into a compile failure
64. add compiler-debuggable dump modes for the important IR boundaries: typed/core IR, ProofCore, obligations, diagnostics, lowering, and SSA should all have stable human-readable dumps suitable for debugging and regression review
65. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
66. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
67. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation

### Phase 8: Release Credibility and Showcase

68. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
69. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, policy declarations, and package-boundary evidence summaries as normal build artifacts
70. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale; the corpus must include borrow/aliasing programs and cleanup/leak-boundary programs, not only parsers and containers
71. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec; include explicit borrow/aliasing and cleanup/leak-boundary examples in that quality bar
72. publish a supported-workload matrix before the first major release: explicitly separate first-class supported workloads, showcase-only workloads, and research-only workloads so the public claim matches the actual language surface
73. harden semantic diff / trust-drift review into a first-class workflow over stable facts and package/release artifacts, not just a research note or one-off diff tool: this should grow to include proof-target drift, theorem/attachment drift, claim-scope drift, and package-boundary evidence drift
74. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
75. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete; include C-header scaffolding and stale-proof repair suggestions before broader migration automation
76. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
77. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
78. build a named big-workload flagship set, not just small pressure examples: at minimum one real protocol/parser security example, one crypto/security proof example, one privilege-separated tool, one ownership-heavy medium program, and one bounded/no-alloc medium program
79. require each big-workload flagship to have honest proof/trust boundary framing, report/snapshot/diff coverage, and an oracle when possible (fuzzing, differential testing, round-trip properties, or model-based checks) so they function as real validation workloads instead of marketing demos
80. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders; the example bar must explicitly include parser/decoder, ownership-heavy, borrow/aliasing, trusted-wrapper/FFI, fixed-capacity, cleanup/leak-boundary, the named big-workload programs, the named profile surfaces, and a release evidence contract for each flagship example (proof/report/diff artifacts plus explicit assumptions)
81. define a public security and soundness disclosure policy before first release: how users report compiler soundness bugs, miscompiles, stdlib safety bugs, proof-evidence bugs, and trusted-boundary issues, plus expected triage and embargo handling
82. define the release/install distribution matrix before the first real public release: release binaries, supported host triples, checksums/signing, install paths, and which distribution channels are first-class versus deferred
83. define reproducible release-build expectations for the compiler and distribution artifacts: what must be bit-for-bit reproducible, what may vary, how rebuilds are verified, and how non-reproducible components are documented
84. define compiler-release supply-chain provenance: signed release binaries, checksums, source commit identity, Lean/toolchain identity, build environment metadata, and verification instructions for users
85. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
86. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
87. add a REPL and lightweight playground workflow once the parser/checker diagnostics and project UX are stable enough that quick experimentation will reflect the real language instead of a toy front-end

### Phase 9: Proof Expansion and Provable Subset

88. polish the packet/parser flagship example as the canonical thesis demo
89. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
90. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
91. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
92. build a fixed-capacity / no-alloc showcase that proves the predictable subset is practical for real bounded systems code
93. build a real cryptography example only after the proof/artifact boundary is stronger: good candidates are constant-time equality + verification use, an HMAC verification core, an Ed25519 verification helper/core subset, or hash/parser/encoding correctness around a crypto-adjacent component
94. refine and stabilize the explicit `Core -> ProofCore` phase after the flagship has forced it into the open: keep the extraction semantics small, testable, and shared by obligations, specs, proofs, and future proof tools
95. extend ProofCore and its semantics to cover more real Concrete constructs in a principled order: structs/fields, pattern matching, arrays/slices, borrows/dereferences, casts, cleanup/defer/drop behavior, and other constructs the flagship examples actually force into scope
96. broaden proof obligation generation beyond the first pipeline slice so loop-related, memory-related, and contract-related proof work becomes mechanically inspectable instead of ad hoc
97. broaden the pure Core proof fragment after proof artifacts, diagnostics, the explicit ProofCore phase, normalization, and obligation generation are usable
98. deepen the memory/reference model for proofs once the first explicit version exists: sharpen ownership, aliasing, mutation, pointer/reference, cleanup, and layout reasoning where real examples require it
99. deepen the effect/trust proof boundaries once the first explicit version exists: prove more right up to capability, allocation, blocking, FFI, and trusted edges without pretending the edges disappear
100. add a dedicated proof-regression test pipeline covering `Core -> ProofCore`, normalization stability, obligation generation, exclusion reasons, stale proof behavior, and proof artifact drift
101. stabilize the provable subset as an explicit user-facing target
102. define public release criteria for the provable subset: supported constructs, unsupported constructs, trust assumptions, proof artifact stability expectations, and what evidence claims users may rely on semantically
103. build a small reference interpreter for the proof-relevant subset once the `Core -> ProofCore` boundary and memory/UB model are precise enough: use it as a semantic oracle for the restricted subset, compare interpreter results against proof semantics and compiled behavior, and keep it intentionally smaller and more trustworthy than the full compiler
104. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
105. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
106. add AI-assisted proof repair and authoring support only on top of stable proof artifacts, explicit statuses, and kernel-checked validation: suggestions may help with stale-proof repair, attachment updates, and theorem scaffolding, but the trust anchor must remain Lean checking plus compiler artifact validation
107. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
108. push selected compiler-preservation proofs where they protect evidence claims
109. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, the explicit ProofCore boundary, and the built-in proof workflow are real enough to support them honestly
110. evaluate loop invariants only after specs, proof obligations, and the proof UX/repair loop are real enough that users can diagnose failures without compiler-internal knowledge
111. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
112. pull research-gated language features into implementation only when a current example or proof needs them

### Phase 10: Backend, Target, and Incremental Pipeline

113. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
114. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
115. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
116. stabilize SSA as the backend contract before experimenting with another backend
117. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
118. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
119. evaluate SIMD/vector types and architecture-specific intrinsics only after the backend contract and target/toolchain model are explicit: decide portable-vs-target-specific surface, proof/predictability implications, and whether the feature belongs in core language, stdlib, or trusted boundary
120. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
121. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
122. add cross-backend validation if a second backend lands
123. add source-level debug-info support when codegen maturity becomes the bottleneck
124. make the target/toolchain model concrete enough to support an explicit WASM target decision: either land a narrow WASM path with honest runtime/tooling limits or record a clear deferral with reasons
125. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
126. add clean-build versus incremental-build equivalence checks: the same source and toolchain state must produce identical facts, obligations, diagnostics, reports, and codegen outputs whether built from scratch or through incremental caches
127. add compiler-process resource-hygiene checks for long-running workflows: repeated report/query/snapshot/incremental runs should not leak memory, file descriptors, temp artifacts, or subprocess state
128. extend the first reducer/minimizer into a broader workflow: add package-aware and multi-file reduction, richer syntax-aware rewrites, and wrong-code / artifact-mismatch predicates on top of the landed single-file crash/verifier/consistency reducer
129. define a canonical semantic test matrix: every important language rule and artifact guarantee should map to positive, negative, adversarial, and artifact-level regression coverage

### Phase 11: Compiler Verification and Preservation Proofs

130. define precisely what “compiler proof” means for Concrete: distinguish user-code property proofs, ProofCore semantic proofs, pass-preservation proofs, and any future end-to-end compiler correctness claim
131. separate public user-code proof claims from compiler-correctness claims so reports never imply the compiler itself is fully verified when only selected user properties are Lean-backed
132. inventory the compiler-verification trusted base and unproved assumptions: parser, checker, elaborator, CoreCheck, monomorphization, lowering, SSA emission, LLVM/toolchain, runtime, target model, and proof registry attachment
133. prove ProofCore normalization preserves ProofCore semantics for the supported expression fragment before relying on normalized proof targets as equivalent to extracted targets
134. prove `Core -> ProofCore` extraction sound for the supported constructs: if extraction succeeds, the ProofCore expression represents the intended pure Core meaning under the documented assumptions
135. prove selected checker/report/artifact facts agree with compiler state: proof eligibility, predictable status, capabilities, trusted boundaries, fingerprints, obligations, and traceability should not drift from the data that produced them
136. prove small internal compiler invariants before broad pass preservation: no post-mono type variables, well-formed qualified identities, well-formed SSA facts, consistent module/interface artifacts, and stable diagnostic attachment where applicable
137. prove selected pass-preservation properties for a restricted pure subset, starting with transformations that directly affect proof/evidence claims rather than trying to verify the whole compiler at once
138. use the small reference interpreter as an executable semantic oracle for the proof-relevant subset and compare interpreter behavior against ProofCore semantics and compiled behavior where the target model permits
139. decide whether full end-to-end compiler correctness is in scope; if yes, define the restricted source subset, target/backend assumptions, proof architecture, and explicit non-goals before implementation begins

### Phase 12: Package System and Dependency Trust

140. split interface artifacts from body artifacts at package/workspace scale
141. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
142. harden package-aware visibility and encapsulation before package management: public/internal/private API boundaries, exported field policy, sealed/internal modules where needed, and diagnostics for accidental API leakage should be explicit before package graphs are trusted
143. design and parse the package manifest
144. add build-script/custom-build-logic support only after the package manifest is stable enough to host it: code generation, C library compilation, resource embedding, and environment detection should be explicit and constrained rather than arbitrary hidden shelling-out
145. add version constraints, dependency resolution, and a lockfile
146. add workspace and multi-package support
147. add package-aware test selection
148. generate C headers from public C-ABI-facing Concrete declarations so library-grade `extern \"C\"` / `repr(C)` surfaces do not require manually maintained `.h` files
149. validate cross-target FFI/ABI from package boundaries
150. add module/package authority budgets after package graphs are real
151. define provenance-aware publishing before public package distribution
152. define package registry server protocol and trust model before a public ecosystem push: upload/download, index/search, yanking/deprecation, checksums/signatures, authentication, and compatibility with provenance/evidence artifacts
153. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible

### Phase 13: Editor, Artifact UX, and Compatibility

154. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
155. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
156. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
157. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
158. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
159. add release / compatibility discipline when external users depend on the language
160. build a backwards-compatibility regression corpus once public users exist: old accepted programs, old facts/reports, old proof artifacts, deprecated syntax/API examples, and expected migration diagnostics should remain testable across releases
161. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
162. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs

### Phase 14: Runtime Profiles, Allocation, and Predictability

163. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
164. define the async/evented-I/O stance explicitly before deep runtime work: whether evented I/O stays library-level, whether async/await is intentionally out of scope, and what concurrency/runtime promises Concrete will or will not make
165. implement OS threads + typed channels only after the concurrency stance is documented
166. keep evented I/O as a later opt-in model, not the default concurrency story
167. explicitly defer inline assembly until the backend contract, target/toolchain model, and trust-boundary story are strong enough to contain it honestly
168. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
169. add structural bounded-allocation reports where the compiler can explain the bound
170. add `BoundedAlloc(N)` only where the bound is structurally explainable
171. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
172. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
173. define stack-boundedness reporting and enforcement boundaries
174. separate source-level stack-depth claims from backend/target stack claims
175. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
176. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
177. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
178. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent

### Phase 15: Public Readiness and User Tooling

179. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
180. add coverage tooling over tests, report facts, policy checks, obligations, proof artifacts, and doc tests
181. add memory-profiler and leak-debug integration for user programs once runtime/allocation profiling exists: heap snapshots or allocation tracing where the target allows it, leak-focused workflows, and a path to correlate runtime findings with `--report alloc`
182. improve onboarding so a newcomer can build one small program without project-author help
183. define the stability / experimental boundary for public users
184. define the language evolution policy on top of that boundary: edition/versioning rules, deprecation windows, breaking-change policy, and how experimental features graduate into the supported subset
185. define public governance and decision process for language evolution: how syntax changes, profile changes, stdlib stabilization, breaking changes, and security-relevant decisions are proposed, reviewed, accepted, and documented

### Phase 16: Long-Horizon Research Backlog

186. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
187. research typestate only if a current state-machine/protocol example needs it
188. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
189. research target-specific timing models after source-level predictability and backend boundaries are explicit
190. research exact WCET / runtime models only with a target/hardware model
191. research exact stack-size claims across optimized machine code only with deeper backend/target integration
192. research cache / pipeline behavior as target-level analysis, not a source-language promise
193. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
194. research hardware capability mapping after source-level capabilities and package policies are stable
195. research capability sandbox profiles after authority reports and package policies are useful
196. broaden the small reference interpreter toward fuller Miri-style UB checking only if the first proof-subset interpreter proves valuable and the memory/UB model can support the added operational complexity
197. research persistent equality / rewrite state across phases only after the backend contract, semantic diff workflow, and proof/evidence pipeline are stronger; use [persistent-equality-and-rewrite-state](research/compiler/persistent-equality-and-rewrite-state.md) as the starting point
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
