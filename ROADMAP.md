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

## Priority Map

| Phase | Items | Human goal |
|---|---:|---|
| 1. Compiler Integrity | 1-4 | Make serious compiler failures reproducible, reduced, and permanent regressions. |
| 2. Concrete-to-Lean Proof Pressure | 5-16 | Prove real Concrete functions with Lean through an end-to-end user workflow. |
| 3. Predictable Core | 17-24 | Make bounded, predictable, failure-aware code usable before broadening scope. |
| 4. Pre-Stdlib Pressure Workloads | 25-30 | Use real workloads to discover what the stdlib must actually provide. |
| 5. Stdlib and Syntax Freeze | 31-40 | Define, build, polish, and freeze the first-release core stdlib and syntax surface. |
| 6. Tooling, Tests, and Wrong-Code Corpus | 41-50 | Make examples, docs, formatting, fuzzing, and wrong-code capture normal workflow. |
| 7. Performance, Artifacts, and Contract Hardening | 51-68 | Put budgets, schemas, reports, artifacts, and explicit failure behavior around the compiler. |
| 8. Release Credibility and Showcase | 69-87 | Prepare honest public claims, profiles, showcases, install paths, and release criteria. |
| 9. Proof Expansion and TCB | 88-113 | Grow ProofCore and proof claims after the narrow proof workflow is real. |
| 10. Backend, Target, and Incremental Pipeline | 114-130 | Stabilize backend contracts, targets, incremental builds, and semantic regression coverage. |
| 11. Package System and Dependency Trust | 131-143 | Add packages only after artifacts and trust summaries know what they must carry. |
| 12. Editor, Artifact UX, and Compatibility | 144-151 | Expose facts, diagnostics, proof state, artifacts, and stability policy to users and tools. |
| 13. Runtime Profiles, Allocation, and Predictability | 152-167 | Define concurrency, allocation, stack, failure, timing, and overflow boundaries. |
| 14. Public Readiness and User Tooling | 168-173 | Make the language easier to adopt, audit, and evolve publicly. |
| 15. Long-Horizon Research Backlog | 174-185 | Keep speculative language/runtime/research ideas visible but clearly gated. |

## Operating Rules

- Do the numbered list top-to-bottom unless a later item is explicitly research-only or parallelizable.
- When an item is completed, move it to [CHANGELOG.md](CHANGELOG.md) and renumber the remaining active list.
- Judge new language features by grammar cost, audit cost, and proof cost, not just expressiveness.
- Do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until earlier evidence/diagnostic/tooling steps make them concrete.
- Keep specs in Lean-attached / artifact-registry form until obligations and diagnostics are strong enough to support source-level contracts honestly.
- Build a normal fact CLI before MCP/editor integrations.
- Keep QBE and other backend work waiting until proof/evidence attachment, optimization policy, and backend trust boundaries are trustworthy.
- Parallelize only low-risk inventories and docs while the active implementation path is proof/diagnostic/compiler-contract work.

## Active List

The active roadmap starts after the proof/memory/determinism/diagnostics/policy/adversarial-foundation work already recorded in [CHANGELOG.md](CHANGELOG.md).

### Phase 1: Compiler Integrity

1. add an explicit miscompile-hunting workflow: oracle-based wrong-code discovery, reducer-driven shrinking, stable corpus promotion, and a rule that every real wrong-code bug becomes a named regression
2. add a malformed-artifact attack set for snapshots, facts, proof registries, bundles, package metadata, and partial/corrupted outputs; require explicit diagnostics, never silent fallback or downgrade
3. add state-desynchronization attack tests that try to force disagreement between obligations, proof status, diagnostics, facts, reports, fingerprints, and snapshots; these should fail loudly, not drift quietly
4. define a crash/miscompile-to-regression promotion policy so every serious compiler failure becomes a reduced repro, a tracked corpus entry, and a permanent regression test rather than tribal memory

### Phase 2: Concrete-to-Lean Proof Pressure

5. define the narrow Concrete-to-Lean proof pressure set before stdlib work: choose 3-5 small real Concrete functions, at least one conditional-heavy parser/validator function, one helper-composition function, and one intentionally excluded function so the workflow exercises proved, stale, blocked, missing, and ineligible states
6. make ProofCore extraction for the pressure set reproducible and inspectable: each selected function should have a stable extracted form, fingerprint, eligibility reason, and obligation entry that can be reviewed without reading compiler internals
7. generate or maintain Lean theorem stubs for the pressure set from compiler artifacts: function identity, spec name, proof target, parameters, and extracted expression should appear in a predictable Lean-facing shape that a user can complete manually
8. validate Lean theorem identity and attachment integrity as a checked boundary: fabricated proof names, missing theorem references, mismatched spec/theorem pairs, and registry/body mismatches must fail explicitly before user proof artifacts are treated as trustworthy
9. wire actual Lean kernel checking into the narrow proof workflow: a proof should count as proved only when the referenced Lean theorem exists and the relevant Lean module checks under the pinned toolchain, not merely because a registry entry names it
10. add end-to-end Lean attachment regression coverage for the narrow proof slice: registry entries, proof names, theorem identities, extracted proof targets, actual Lean checking, stale detection, and proof-status facts should be tested together as one workflow
11. add stale-proof repair pressure tests: mutate a proved Concrete function, require the report to show the exact fingerprint/body drift, then restore or update the attachment and verify the status returns to proved
12. add blocked/ineligible proof pressure tests: include unsupported constructs, capability/trusted boundaries, and effectful functions so the proof workflow explains why a function is not proved without overclaiming
13. make build / check / report / prove feel like one coherent product workflow for the narrow slice: proof status, stale detection, blocked/ineligible states, and artifact-backed evidence should be part of the normal toolchain story rather than sidecar research output
14. define the user proof-authoring and maintenance workflow explicitly for that slice: how a user writes or updates specs and proofs, regenerates artifacts, diagnoses stale or blocked proofs, and lands proof-preserving refactors without reading compiler internals
15. add a proof-workflow debug bundle or report bundle for the pressure set: source, extracted ProofCore, obligations, registry entries, Lean theorem names, fingerprints, diagnostics, and proof-status facts should be captured together for review and bug reports
16. gate the narrow Concrete-to-Lean proof workflow in CI once stable: at minimum run extraction, registry validation, Lean theorem checking for the pressure set, stale-proof checks, and proof-status consistency as one evidence gate

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
39. review syntax friction exposed by the pressure sets and stdlib/examples, but only through LL(1)-preserving changes: in particular, decide whether to unify qualification syntax by moving `Type#Variant` to the same `::` family as module qualification, clean up declaration modifier ordering such as `pub struct Copy Pair`, improve generic-construction ergonomics where surrounding type context already fixes the instantiation (for example allowing `let p: Pair<Int, Int> = Pair { ... }` with elaboration-time resolution rather than parser-level inference tricks), and revisit explicit field visibility only if real examples justify it; keep all such changes local, parser-regular, evidence-driven, and explicitly reject scope-heavy or context-sensitive additions such as bare enum variants, block `defer`, parser-driven generic inference, or multiple competing syntaxes for the same construct
40. freeze the first-release stdlib surface explicitly: record which modules and syntax forms are stable, which remain experimental, and which are intentionally deferred so the first release does not keep drifting

### Phase 6: Tooling, Tests, and Wrong-Code Corpus

41. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
42. add structured logging/tracing/observability primitives for real services and tools: leveled logs, structured fields, spans/events where justified, and an honest split between minimal core APIs and hosted/runtime integrations
43. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
44. add documentation-comment extraction and doc generation from source so API reference material is produced from canonical declarations/comments instead of drifting handwritten docs
45. add doc tests so code examples in docs and generated API reference can compile or run as regression tests rather than silently rotting
46. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
47. add dedicated fuzzing infrastructure where there is a real oracle: grammar fuzzing, structure-aware parser fuzzing, coverage-guided fuzzing for high-risk surfaces, and a path to keep discovered crashes/miscompiles as stable regressions
48. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
49. build and maintain a named wrong-code regression corpus: every discovered miscompile, codegen bug, obligation bug, checker soundness bug, and proof-pipeline regression should land as a stable reproduction, not just disappear into the general suite
50. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful

### Phase 7: Performance, Artifacts, and Contract Hardening

51. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
52. add explicit compiler performance budgets on top of profiling: acceptable compile-time regressions, artifact-generation overhead, and memory-growth limits that CI and review can enforce
53. add compile-time regression profiling: parse/check/elaboration/proof/report time, artifact-generation cost, and enough baseline data to keep the compiler usable as the proof pipeline grows
54. add compiler memory profiling and scaling baselines: peak memory, artifact-generation overhead, and growth characteristics on larger proof/fact workloads
55. add runtime/allocation profiling workflow: profiler-friendly output, allocation hot spots, allocation-path visibility, source-location attribution, and a path to correlate profiling results with `--report alloc` / evidence artifacts
56. add large-workspace and many-artifact scaling tests: many modules, many facts, many obligations, repeated snapshot/report workflows, and enough volume to expose nonlinear behavior before package/editor use depends on it
57. deepen leak-risk reporting once the first no-leak boundary and leak reports exist: add richer allocation/cleanup path explanations, trusted/FFI leak attribution, and more precise leak-risk classes where the strong no-leak guarantee does not apply
58. deepen allocation/leak regression coverage once the first reporting surfaces exist: adversarial tests for cleanup-path classification, leak-risk classification, trusted/FFI leak boundaries, and `--report alloc` consistency on larger examples
59. define a real warning/lint discipline: separate hard errors, warnings, deny-in-CI warnings, and advisory lints so diagnostics can get stricter without turning every issue into a compile failure
60. add compiler-debuggable dump modes for the important IR boundaries: typed/core IR, ProofCore, obligations, diagnostics, lowering, and SSA should all have stable human-readable dumps suitable for debugging and regression review
61. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
62. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
63. document and version the fact/query JSON API before external tools depend on it: schema version, stable kind names, field names, location encoding, fingerprint fields, empty-result behavior, and error-result behavior
64. make canonical qualified function identity consistent across all fact families; avoid mixing `parse_byte` and `main.parse_byte` in machine-readable facts unless the distinction is explicit and documented
65. define and implement clear invalid-query diagnostics: malformed/unknown `--query` requests should produce either a structured query error or a deliberate empty answer, not ambiguous success
66. harden malformed artifact, registry, and snapshot handling beyond query errors: corrupted files, duplicate/conflicting entries, partial snapshots, and broken bundles should fail with explicit diagnostics and regression coverage instead of drifting silently
67. continue the compiler-as-a-contract cleanup: remove silent fallbacks, implicit downgrade paths, and “best effort” report behavior where the compiler should instead fail explicitly or emit a structured internal diagnostic
68. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation

### Phase 8: Release Credibility and Showcase

69. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
70. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, policy declarations, and package-boundary evidence summaries as normal build artifacts
71. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale; the corpus must include borrow/aliasing programs and cleanup/leak-boundary programs, not only parsers and containers
72. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec; include explicit borrow/aliasing and cleanup/leak-boundary examples in that quality bar
73. publish a supported-workload matrix before the first major release: explicitly separate first-class supported workloads, showcase-only workloads, and research-only workloads so the public claim matches the actual language surface
74. keep a canonical “claims today” surface current before the first major release: one short public document that states what Concrete guarantees today, what it does not guarantee yet, and what assumptions/backends/trusted boundaries remain
75. publish named user-facing profiles before the first major release: make `safe`, `predictable`, `provable`, and the longer-term `high-integrity` direction explicit, and say which are current, which are partial, and which remain future-facing
76. harden semantic diff / trust-drift review into a first-class workflow over stable facts and package/release artifacts, not just a research note or one-off diff tool
77. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
78. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete; include C-header scaffolding and stale-proof repair suggestions before broader migration automation
79. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
80. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
81. build a named big-workload flagship set, not just small pressure examples: at minimum one real protocol/parser security example, one crypto/security proof example, one privilege-separated tool, one ownership-heavy medium program, and one bounded/no-alloc medium program
82. require each big-workload flagship to have honest proof/trust boundary framing, report/snapshot/diff coverage, and an oracle when possible (fuzzing, differential testing, round-trip properties, or model-based checks) so they function as real validation workloads instead of marketing demos
83. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders; the example bar must explicitly include parser/decoder, ownership-heavy, borrow/aliasing, trusted-wrapper/FFI, fixed-capacity, cleanup/leak-boundary, the named big-workload programs, and the named profile surfaces
84. define the release/install distribution matrix before the first real public release: release binaries, supported host triples, checksums/signing, install paths, and which distribution channels are first-class versus deferred
85. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
86. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
87. add a REPL and lightweight playground workflow once the parser/checker diagnostics and project UX are stable enough that quick experimentation will reflect the real language instead of a toy front-end

### Phase 9: Proof Expansion and TCB

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
103. keep explicit trusted-computing-base accounting current for the strongest claims: Concrete checker assumptions, Lean kernel assumptions, registry/trusted-code assumptions, backend/toolchain assumptions, and target/runtime assumptions should stay visible in one canonical place as the project evolves
104. build a small reference interpreter for the proof-relevant subset once the `Core -> ProofCore` boundary and memory/UB model are precise enough: use it as a semantic oracle for the restricted subset, compare interpreter results against proof semantics and compiled behavior, and keep it intentionally smaller and more trustworthy than the full compiler
105. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
106. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
107. add AI-assisted proof repair and authoring support only on top of stable proof artifacts, explicit statuses, and kernel-checked validation: suggestions may help with stale-proof repair, attachment updates, and theorem scaffolding, but the trust anchor must remain Lean checking plus compiler artifact validation
108. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
109. push selected compiler-preservation proofs where they protect evidence claims
110. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, the explicit ProofCore boundary, and the built-in proof workflow are real enough to support them honestly
111. evaluate loop invariants only after specs, proof obligations, and the proof UX/repair loop are real enough that users can diagnose failures without compiler-internal knowledge
112. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
113. pull research-gated language features into implementation only when a current example or proof needs them

### Phase 10: Backend, Target, and Incremental Pipeline

114. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
115. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
116. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
117. stabilize SSA as the backend contract before experimenting with another backend
118. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
119. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
120. evaluate SIMD/vector types and architecture-specific intrinsics only after the backend contract and target/toolchain model are explicit: decide portable-vs-target-specific surface, proof/predictability implications, and whether the feature belongs in core language, stdlib, or trusted boundary
121. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
122. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
123. add cross-backend validation if a second backend lands
124. add source-level debug-info support when codegen maturity becomes the bottleneck
125. make the target/toolchain model concrete enough to support an explicit WASM target decision: either land a narrow WASM path with honest runtime/tooling limits or record a clear deferral with reasons
126. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
127. add clean-build versus incremental-build equivalence checks: the same source and toolchain state must produce identical facts, obligations, diagnostics, reports, and codegen outputs whether built from scratch or through incremental caches
128. add compiler-process resource-hygiene checks for long-running workflows: repeated report/query/snapshot/incremental runs should not leak memory, file descriptors, temp artifacts, or subprocess state
129. extend the first reducer/minimizer into a broader workflow: add package-aware and multi-file reduction, richer syntax-aware rewrites, and wrong-code / artifact-mismatch predicates on top of the landed single-file crash/verifier/consistency reducer
130. define a canonical semantic test matrix: every important language rule and artifact guarantee should map to positive, negative, adversarial, and artifact-level regression coverage

### Phase 11: Package System and Dependency Trust

131. split interface artifacts from body artifacts at package/workspace scale
132. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
133. design and parse the package manifest
134. add build-script/custom-build-logic support only after the package manifest is stable enough to host it: code generation, C library compilation, resource embedding, and environment detection should be explicit and constrained rather than arbitrary hidden shelling-out
135. add version constraints, dependency resolution, and a lockfile
136. add workspace and multi-package support
137. add package-aware test selection
138. generate C headers from public C-ABI-facing Concrete declarations so library-grade `extern \"C\"` / `repr(C)` surfaces do not require manually maintained `.h` files
139. validate cross-target FFI/ABI from package boundaries
140. add module/package authority budgets after package graphs are real
141. define provenance-aware publishing before public package distribution
142. define package registry server protocol and trust model before a public ecosystem push: upload/download, index/search, yanking/deprecation, checksums/signatures, authentication, and compatibility with provenance/evidence artifacts
143. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible

### Phase 12: Editor, Artifact UX, and Compatibility

144. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
145. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
146. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
147. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
148. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
149. add release / compatibility discipline when external users depend on the language
150. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
151. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs

### Phase 13: Runtime Profiles, Allocation, and Predictability

152. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
153. define the async/evented-I/O stance explicitly before deep runtime work: whether evented I/O stays library-level, whether async/await is intentionally out of scope, and what concurrency/runtime promises Concrete will or will not make
154. implement OS threads + typed channels only after the concurrency stance is documented
155. keep evented I/O as a later opt-in model, not the default concurrency story
156. explicitly defer inline assembly until the backend contract, target/toolchain model, and trust-boundary story are strong enough to contain it honestly
157. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
158. add structural bounded-allocation reports where the compiler can explain the bound
159. add `BoundedAlloc(N)` only where the bound is structurally explainable
160. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
161. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
162. define stack-boundedness reporting and enforcement boundaries
163. separate source-level stack-depth claims from backend/target stack claims
164. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
165. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
166. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
167. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent

### Phase 14: Public Readiness and User Tooling

168. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
169. add coverage tooling over tests, report facts, policy checks, obligations, proof artifacts, and doc tests
170. add memory-profiler and leak-debug integration for user programs once runtime/allocation profiling exists: heap snapshots or allocation tracing where the target allows it, leak-focused workflows, and a path to correlate runtime findings with `--report alloc`
171. improve onboarding so a newcomer can build one small program without project-author help
172. define the stability / experimental boundary for public users
173. define the language evolution policy on top of that boundary: edition/versioning rules, deprecation windows, breaking-change policy, and how experimental features graduate into the supported subset

### Phase 15: Long-Horizon Research Backlog

174. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
175. research typestate only if a current state-machine/protocol example needs it
176. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
177. research target-specific timing models after source-level predictability and backend boundaries are explicit
178. research exact WCET / runtime models only with a target/hardware model
179. research exact stack-size claims across optimized machine code only with deeper backend/target integration
180. research cache / pipeline behavior as target-level analysis, not a source-language promise
181. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
182. research hardware capability mapping after source-level capabilities and package policies are stable
183. research capability sandbox profiles after authority reports and package policies are useful
184. broaden the small reference interpreter toward fuller Miri-style UB checking only if the first proof-subset interpreter proves valuable and the memory/UB model can support the added operational complexity
185. research persistent equality / rewrite state across phases only after the backend contract, semantic diff workflow, and proof/evidence pipeline are stronger; use [persistent-equality-and-rewrite-state](research/compiler/persistent-equality-and-rewrite-state.md) as the starting point
## Reference Map

The thesis references are [core-thesis](research/thesis-validation/core-thesis.md), [objective-matrix](research/thesis-validation/objective-matrix.md), [thesis-validation](research/thesis-validation/thesis-validation.md), [validation-examples](research/thesis-validation/validation-examples.md), [predictable-execution](research/predictable-execution/predictable-execution.md), [effect-taxonomy](research/predictable-execution/effect-taxonomy.md), [diagnostic-ux](research/compiler/diagnostic-ux.md), and [backend-traceability](research/compiler/backend-traceability.md).

The proof/evidence references are [concrete-to-lean-pipeline](research/proof-evidence/concrete-to-lean-pipeline.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [spec-attachment](research/proof-evidence/spec-attachment.md), [effectful-proofs](research/proof-evidence/effectful-proofs.md), [provable-systems-subset](research/proof-evidence/provable-systems-subset.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md), [proof-ux-and-verification-influences](research/proof-evidence/proof-ux-and-verification-influences.md), [proof-ux-and-authoring-loop](research/proof-evidence/proof-ux-and-authoring-loop.md), [verification-product-model](research/proof-evidence/verification-product-model.md), [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), and [proof-evidence-artifacts](research/proof-evidence/proof-evidence-artifacts.md).

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
