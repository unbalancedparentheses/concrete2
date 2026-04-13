# Concrete Roadmap

This document answers one question: **what should happen next, in order.**

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md), [docs/SAFETY.md](docs/SAFETY.md), [docs/MUT_REF_SEMANTICS.md](docs/MUT_REF_SEMANTICS.md), and [docs/MUT_REF_CLOSURE.md](docs/MUT_REF_CLOSURE.md).
For subsystem references, see [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), and [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by grammar cost, audit cost, and proof cost, not only by expressiveness.

## Current Position

The Lean 4 compiler implements the full pipeline:

`Parse -> Resolve -> Check -> Elab -> CoreCheck -> Mono -> Lower -> EmitSSA -> LLVM IR`

The core language, stdlib foundation, report surfaces, proof-status diagnostics, and project workflow are real. Phase H proved the language against real programs. Function-level source locations for `--check predictable` / `--report effects`, Elm-style predictable-profile errors, and Elm-style proof/evidence status are landed.

The next question is no longer "can Concrete express this?" but "can Concrete demonstrate its thesis clearly enough to justify the project?"

## Vision Validation Criteria

Concrete's vision is only validated if real examples make the core claim hold in practice, not just in isolated reports.

The project counts as directionally correct only when all of the following are true:

1. one flagship example demonstrates the full thesis:
   - explicit authority at function boundaries
   - a predictable / bounded core
   - at least one proof-backed property
   - artifact-backed evidence
   - drift detection when the code changes
2. a bad change actually gets caught:
   - widened authority
   - new allocation / FFI / blocking
   - broken predictable profile
   - stale proof attachment
   - changed obligation / evidence status
3. another engineer can audit it without reading compiler internals:
   - what can this function touch?
   - is it predictable?
   - is it proved?
   - what is trusted?
   - what changed?
4. the artifact story is real:
   facts, registry, obligations, extraction, traceability, drift, and CI gates exist as build artifacts, not compiler-internal hacks
5. a second example in a different domain also works:
   packet parser alone is not enough; examples such as a transaction validator, ELF inspector, or crypto verification core must also fit the model
6. ergonomics are acceptable:
   the evidence/proof workflow must stay small enough that ordinary bounded systems code is still reasonable to write
7. performance is acceptable for the target use case:
   the bounded/provable core cannot be so costly that the language becomes impractical for the systems domains it targets
8. trust boundaries are explicit and honest:
   the reports must make clear what is enforced by the compiler, what is analysis-only, what is proved in Lean, and where backend / target / toolchain assumptions begin

## Highest-Leverage Multipliers

These are the biggest remaining multipliers for Concrete's thesis.

9. a stronger flagship example that is obviously real systems code
10. an explicit `Core -> ProofCore` boundary
11. module/package policy strong enough to enforce architecture, not just report it
12. a bounded-capacity predictable subset that is usable for real code
13. trust-drift and CI evidence gates as normal workflow
14. an AI-native fact interface over stable compiler artifacts
15. proof-aware package artifacts later, so packages can ship facts, obligations,
   proof status, trusted assumptions, and policy declarations as part of their build story

## Linear Roadmap

Do this list top-to-bottom. This is the roadmap. Completed history belongs in [CHANGELOG.md](CHANGELOG.md), and detailed design belongs in `research/`. When items leave the active roadmap, update the changelog in the same cleanup.

**Priority rule:** do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until the earlier evidence/diagnostic/tooling steps make those later tasks concrete.

Current guardrails: keep specs in Lean-attached / artifact-registry form until obligations and diagnostics work; build a normal fact CLI before the MCP; keep QBE/Yul/other backend work waiting until proof/evidence attachment, optimization policy, and the backend trust boundary are trustworthy.

**Proof goal:** maximize the amount of real systems code that can honestly carry Lean 4-backed evidence, rather than pretending every Concrete program should become theorem-prover-friendly all at once.

**Execution mode:** keep proof semantics, identity, supported-subset decisions, and other compiler-truth boundaries on the main linear path. Parallelize inventories, audits, regression-test expansion, CI wiring, benchmark setup, stdlib target inventories, cookbook/example planning, and public docs/landing-page work once the corresponding compiler contract is stable enough to avoid churn.

**Current parallelization rule:** while the active work is obligation cleanup / diagnostics / proof-boundary semantics, keep those implementation tasks linear. In parallel, agents can safely work on proof-diagnostics audits, regression-test inventories, registry/stale-detection audits, stdlib target inventories, cookbook/example planning, formatter corpora, benchmark setup, FAQ/comparison/landing-page work, and book-outline preparation.

Completed proof-foundation milestones now live in [CHANGELOG.md](CHANGELOG.md): crypto flagship, ELF flagship, eligibility-first proof flow, explicit `Core -> ProofCore`, ProofCore consolidation, qualified proof identity, proof normalization, stable attached specs, first-slice mechanical obligations, proof-oriented diagnostics, explicit memory/reference semantics, the `&mut T` closure arc, the no-codegen-crash rule, the first explicit no-leak guarantee boundary, the effect/trust proof boundary specification, the public guarantee statement, the language-semantics vs proof-semantics boundary specification, and the proof-claim taxonomy, the user-facing proof contract, the safe-memory regression checklist, the memory-model pressure tests, the borrow/aliasing pressure set, the cleanup/leak-boundary pressure set, the unreachable-error-kind checker audit, the compiler determinism verification, the deterministic artifact regression suite, the determinism contract, and the nondeterminism source audit.

The active roadmap below starts after that completed proof/memory closure work. If an item is done, move it to [CHANGELOG.md](CHANGELOG.md) instead of leaving it in the numbered task list.
1. finish diagnostic engine unification: parser, resolver, checker, elaboration, CoreCheck, mono, lower, and SSA verify already emit structured `Diagnostic`; remaining: report/query failures, proof/evidence failures, artifact/registry failures, package/interface failures, and backend-contract failures still use `liftStringError` in some paths
2. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, report-consistency status, policy status, trust-drift check, and the new consistency/determinism gates
3. add error-context and backtrace support so deep `Result`-based failures can accumulate human-meaningful context, capture stack traces where the runtime/target allows it, and surface that information consistently in diagnostics and developer tooling
4. make module/package policy checks a first-class architecture feature for the existing thesis properties, not just a report-side prototype
5. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
6. build and maintain an adversarial compiler-hardening corpus aimed at breaking parser, checker, verifier, proof, lowering/codegen, and artifact/report paths rather than only validating intended behavior
7. add an explicit miscompile-hunting workflow: oracle-based wrong-code discovery, reducer-driven shrinking, stable corpus promotion, and a rule that every real wrong-code bug becomes a named regression
8. add a malformed-artifact attack set for snapshots, facts, proof registries, bundles, package metadata, and partial/corrupted outputs; require explicit diagnostics, never silent fallback or downgrade
9. add state-desynchronization attack tests that try to force disagreement between obligations, proof status, diagnostics, facts, reports, fingerprints, and snapshots; these should fail loudly, not drift quietly
10. add hostile-workload scaling tests that try to break the compiler with pathological nesting, giant matches, generic blowups, module explosions, and artifact-volume spikes before outsiders hit them first
11. define a crash/miscompile-to-regression promotion policy so every serious compiler failure becomes a reduced repro, a tracked corpus entry, and a permanent regression test rather than tribal memory
12. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
13. design and implement the smallest bounded-capacity type path that makes predictable examples practical
14. add stack-depth reporting for functions that pass the no-recursion profile
15. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
16. define the panic/abort/failure strategy explicitly before broader runtime and backend claims: decide abort-only versus any unwinding model, specify cleanup/no-leak behavior under failure, define FFI consequences, and state what proof-backed code may assume about panic/failure paths
17. define the no-std / freestanding split for predictable and embedded-oriented code
18. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
19. define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow for trying the language without project-author help
20. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, and DNS packet parser, specifically to discover which parsing, slice/buffer, and result/error APIs are actually missing
21. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, and container APIs are actually missing
22. build the borrow/aliasing program pressure set before freezing the stdlib target: sequential `&mut` workflows, borrow-heavy adapters, field/element borrow stress programs, iterator-like borrowing patterns, and other programs whose main job is to force the aliasing surface into the open
23. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, and OS call facade, specifically to discover which boundary, error/result, and hosted-only stdlib APIs are actually missing
24. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, and fixed parser state machine, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
25. build the cleanup/leak-boundary program pressure set before freezing the stdlib target: nested defer-driven helpers, alloc/free facades, cleanup-heavy service code, and trusted/FFI cleanup boundaries that force leak reporting and destroy ergonomics to become honest
26. define the string/text encoding contract explicitly before the stable subset and stdlib freeze: make `String` and text encoding expectations, invalid-sequence handling, and byte-vs-text APIs precise so docs, stdlib, and FFI boundaries do not drift
27. define the first-release core stdlib target with a quality bar closer to the best practical languages: Rust/OCaml-level module clarity, Zig/Odin-level systems utility, and Clojure/Elixir-level documentation/discoverability for the supported subset; name the exact proof/predictability-friendly modules and APIs that must exist, and mark what is intentionally out of scope
28. define explicit stdlib design principles before polishing APIs: small orthogonal modules, obvious naming, predictable ownership/borrowing conventions, stable data/text/byte boundaries, and minimal hidden magic; use this as the filter for every new stdlib API
29. build the foundational core modules to that standard: bytes/text/string, option/result, slices/views, fixed-capacity helpers, deterministic collections, cleanup/destroy helpers, parsing/formatting helpers, and the minimum numeric/time/path APIs the pressure examples actually require
30. define the hosted stdlib split on top of the core target: OS/runtime-heavy modules, FFI-support modules, logging/runtime integrations, and other non-core surfaces should be explicitly separated from the bounded/provable-friendly core with a clear capability/trust story
31. polish stdlib API shape, naming, and module layout against those targets: remove accidental API sprawl, make common tasks feel direct, keep advanced functionality visible but not intrusive, and make the core/hosted boundary obvious in the docs and module tree
32. make the stdlib documentation and examples first-class: every important module should have crisp docs, small examples, doc-tested happy paths, and obvious “start here” entry points so the stdlib feels teachable rather than merely available
33. validate the stdlib with canonical stdlib-backed example programs, not just unit tests: parser, ownership-heavy, FFI-boundary, fixed-capacity, and cleanup-heavy examples should all feel complete against the target surface and expose missing APIs quickly
34. freeze the first-release stdlib surface explicitly: record which modules are stable, which remain experimental, and which are intentionally deferred so the first release does not keep drifting
35. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
36. add structured logging/tracing/observability primitives for real services and tools: leveled logs, structured fields, spans/events where justified, and an honest split between minimal core APIs and hosted/runtime integrations
37. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
38. add documentation-comment extraction and doc generation from source so API reference material is produced from canonical declarations/comments instead of drifting handwritten docs
39. add doc tests so code examples in docs and generated API reference can compile or run as regression tests rather than silently rotting
40. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
41. add dedicated fuzzing infrastructure where there is a real oracle: grammar fuzzing, structure-aware parser fuzzing, coverage-guided fuzzing for high-risk surfaces, and a path to keep discovered crashes/miscompiles as stable regressions
42. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
43. build and maintain a named wrong-code regression corpus: every discovered miscompile, codegen bug, obligation bug, checker soundness bug, and proof-pipeline regression should land as a stable reproduction, not just disappear into the general suite
44. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful
45. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
46. add explicit compiler performance budgets on top of profiling: acceptable compile-time regressions, artifact-generation overhead, and memory-growth limits that CI and review can enforce
47. add compile-time regression profiling: parse/check/elaboration/proof/report time, artifact-generation cost, and enough baseline data to keep the compiler usable as the proof pipeline grows
48. add compiler memory profiling and scaling baselines: peak memory, artifact-generation overhead, and growth characteristics on larger proof/fact workloads
49. add runtime/allocation profiling workflow: profiler-friendly output, allocation hot spots, allocation-path visibility, source-location attribution, and a path to correlate profiling results with `--report alloc` / evidence artifacts
50. add large-workspace and many-artifact scaling tests: many modules, many facts, many obligations, repeated snapshot/report workflows, and enough volume to expose nonlinear behavior before package/editor use depends on it
51. deepen leak-risk reporting once the first no-leak boundary and leak reports exist: add richer allocation/cleanup path explanations, trusted/FFI leak attribution, and more precise leak-risk classes where the strong no-leak guarantee does not apply
52. deepen allocation/leak regression coverage once the first reporting surfaces exist: adversarial tests for cleanup-path classification, leak-risk classification, trusted/FFI leak boundaries, and `--report alloc` consistency on larger examples
53. define a real warning/lint discipline: separate hard errors, warnings, deny-in-CI warnings, and advisory lints so diagnostics can get stricter without turning every issue into a compile failure
54. add compiler-debuggable dump modes for the important IR boundaries: typed/core IR, ProofCore, obligations, diagnostics, lowering, and SSA should all have stable human-readable dumps suitable for debugging and regression review
55. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
56. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
57. document and version the fact/query JSON API before external tools depend on it: schema version, stable kind names, field names, location encoding, fingerprint fields, empty-result behavior, and error-result behavior
58. make canonical qualified function identity consistent across all fact families; avoid mixing `parse_byte` and `main.parse_byte` in machine-readable facts unless the distinction is explicit and documented
59. define and implement clear invalid-query diagnostics: malformed/unknown `--query` requests should produce either a structured query error or a deliberate empty answer, not ambiguous success
60. harden malformed artifact, registry, and snapshot handling beyond query errors: corrupted files, duplicate/conflicting entries, partial snapshots, and broken bundles should fail with explicit diagnostics and regression coverage instead of drifting silently
61. continue the compiler-as-a-contract cleanup: remove silent fallbacks, implicit downgrade paths, and “best effort” report behavior where the compiler should instead fail explicitly or emit a structured internal diagnostic
62. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation
63. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
64. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, and policy declarations as normal build artifacts
65. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale; the corpus must include borrow/aliasing programs and cleanup/leak-boundary programs, not only parsers and containers
66. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec; include explicit borrow/aliasing and cleanup/leak-boundary examples in that quality bar
67. publish a supported-workload matrix before the first major release: explicitly separate first-class supported workloads, showcase-only workloads, and research-only workloads so the public claim matches the actual language surface
68. publish a canonical “claims today” surface before the first major release: one short public document that states what Concrete guarantees today, what it does not guarantee yet, and what assumptions/backends/trusted boundaries remain
69. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
70. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete; include C-header scaffolding and stale-proof repair suggestions before broader migration automation
71. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
72. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
73. build a named big-workload flagship set, not just small pressure examples: at minimum one real protocol/parser security example, one crypto/security proof example, one privilege-separated tool, one ownership-heavy medium program, and one bounded/no-alloc medium program
74. require each big-workload flagship to have honest proof/trust boundary framing, report/snapshot/diff coverage, and an oracle when possible (fuzzing, differential testing, round-trip properties, or model-based checks) so they function as real validation workloads instead of marketing demos
75. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders; the example bar must explicitly include parser/decoder, ownership-heavy, borrow/aliasing, trusted-wrapper/FFI, fixed-capacity, cleanup/leak-boundary, and the named big-workload programs
76. define the release/install distribution matrix before the first real public release: release binaries, supported host triples, checksums/signing, install paths, and which distribution channels are first-class versus deferred
77. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
78. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
79. add a REPL and lightweight playground workflow once the parser/checker diagnostics and project UX are stable enough that quick experimentation will reflect the real language instead of a toy front-end
80. polish the packet/parser flagship example as the canonical thesis demo
81. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
82. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
83. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
84. build a fixed-capacity / no-alloc showcase that proves the predictable subset is practical for real bounded systems code
85. build a real cryptography example only after the proof/artifact boundary is stronger: good candidates are constant-time equality + verification use, an HMAC verification core, an Ed25519 verification helper/core subset, or hash/parser/encoding correctness around a crypto-adjacent component
86. refine and stabilize the explicit `Core -> ProofCore` phase after the flagship has forced it into the open: keep the extraction semantics small, testable, and shared by obligations, specs, proofs, and future proof tools
87. extend ProofCore and its semantics to cover more real Concrete constructs in a principled order: structs/fields, pattern matching, arrays/slices, borrows/dereferences, casts, cleanup/defer/drop behavior, and other constructs the flagship examples actually force into scope
88. broaden proof obligation generation beyond the first pipeline slice so loop-related, memory-related, and contract-related proof work becomes mechanically inspectable instead of ad hoc
89. broaden the pure Core proof fragment after proof artifacts, diagnostics, the explicit ProofCore phase, normalization, and obligation generation are usable
90. deepen the memory/reference model for proofs once the first explicit version exists: sharpen ownership, aliasing, mutation, pointer/reference, cleanup, and layout reasoning where real examples require it
91. deepen the effect/trust proof boundaries once the first explicit version exists: prove more right up to capability, allocation, blocking, FFI, and trusted edges without pretending the edges disappear
92. add a dedicated proof-regression test pipeline covering `Core -> ProofCore`, normalization stability, obligation generation, exclusion reasons, stale proof behavior, and proof artifact drift
93. stabilize the provable subset as an explicit user-facing target
94. define public release criteria for the provable subset: supported constructs, unsupported constructs, trust assumptions, proof artifact stability expectations, and what evidence claims users may rely on semantically
95. publish explicit trusted-computing-base accounting for the strongest claims: Concrete checker assumptions, Lean kernel assumptions, registry/trusted-code assumptions, backend/toolchain assumptions, and target/runtime assumptions should be visible in one canonical place
96. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
97. validate proof attachments against actual Lean symbols and theorem identities: fabricated proof names, missing theorem references, and mismatched spec/theorem pairs must fail explicitly instead of surviving as registry-shaped metadata
98. add end-to-end Lean attachment regression coverage: registry entries, proof names, theorem identities, extracted proof targets, and stale detection should be tested together so the Lean bridge is a checked boundary rather than a naming convention
99. support artifact-driven user-program proofs end-to-end
100. define the user proof-authoring and maintenance workflow explicitly: how a user writes/updates specs and proofs, regenerates artifacts, diagnoses stale or blocked proofs, and lands proof-preserving refactors without reading compiler internals
101. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
102. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
103. push selected compiler-preservation proofs where they protect evidence claims
104. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, and the explicit ProofCore boundary are real
105. evaluate loop invariants only after specs and proof obligations are real
106. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
107. pull research-gated language features into implementation only when a current example or proof needs them
108. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
109. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
110. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
111. stabilize SSA as the backend contract before experimenting with another backend
112. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
113. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
114. evaluate SIMD/vector types and architecture-specific intrinsics only after the backend contract and target/toolchain model are explicit: decide portable-vs-target-specific surface, proof/predictability implications, and whether the feature belongs in core language, stdlib, or trusted boundary
115. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
116. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
117. add cross-backend validation if a second backend lands
118. add source-level debug-info support when codegen maturity becomes the bottleneck
119. make the target/toolchain model concrete enough to support an explicit WASM target decision: either land a narrow WASM path with honest runtime/tooling limits or record a clear deferral with reasons
120. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
121. add clean-build versus incremental-build equivalence checks: the same source and toolchain state must produce identical facts, obligations, diagnostics, reports, and codegen outputs whether built from scratch or through incremental caches
122. add compiler-process resource-hygiene checks for long-running workflows: repeated report/query/snapshot/incremental runs should not leak memory, file descriptors, temp artifacts, or subprocess state
123. extend the first reducer/minimizer into a broader workflow: add package-aware and multi-file reduction, richer syntax-aware rewrites, and wrong-code / artifact-mismatch predicates on top of the landed single-file crash/verifier/consistency reducer
124. define a canonical semantic test matrix: every important language rule and artifact guarantee should map to positive, negative, adversarial, and artifact-level regression coverage
125. split interface artifacts from body artifacts at package/workspace scale
126. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
127. design and parse the package manifest
128. add build-script/custom-build-logic support only after the package manifest is stable enough to host it: code generation, C library compilation, resource embedding, and environment detection should be explicit and constrained rather than arbitrary hidden shelling-out
129. add version constraints, dependency resolution, and a lockfile
130. add workspace and multi-package support
131. add package-aware test selection
132. generate C headers from public C-ABI-facing Concrete declarations so library-grade `extern "C"` / `repr(C)` surfaces do not require manually maintained `.h` files
133. validate cross-target FFI/ABI from package boundaries
134. add module/package authority budgets after package graphs are real
135. define provenance-aware publishing before public package distribution
136. define package registry server protocol and trust model before a public ecosystem push: upload/download, index/search, yanking/deprecation, checksums/signatures, authentication, and compatibility with provenance/evidence artifacts
137. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible
138. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
139. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
140. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
141. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
142. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
143. add release / compatibility discipline when external users depend on the language
144. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
145. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs
146. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
147. define the async/evented-I/O stance explicitly before deep runtime work: whether evented I/O stays library-level, whether async/await is intentionally out of scope, and what concurrency/runtime promises Concrete will or will not make
148. implement OS threads + typed channels only after the concurrency stance is documented
149. keep evented I/O as a later opt-in model, not the default concurrency story
150. explicitly defer inline assembly until the backend contract, target/toolchain model, and trust-boundary story are strong enough to contain it honestly
151. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
152. add structural bounded-allocation reports where the compiler can explain the bound
153. add `BoundedAlloc(N)` only where the bound is structurally explainable
154. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
155. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
156. define stack-boundedness reporting and enforcement boundaries
157. separate source-level stack-depth claims from backend/target stack claims
158. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
159. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
160. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
161. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
162. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
163. add coverage tooling over tests, report facts, policy checks, obligations, proof artifacts, and doc tests
164. add memory-profiler and leak-debug integration for user programs once runtime/allocation profiling exists: heap snapshots or allocation tracing where the target allows it, leak-focused workflows, and a path to correlate runtime findings with `--report alloc`
165. improve onboarding so a newcomer can build one small program without project-author help
166. define the stability / experimental boundary for public users
167. define the language evolution policy on top of that boundary: edition/versioning rules, deprecation windows, breaking-change policy, and how experimental features graduate into the supported subset
168. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
169. research typestate only if a current state-machine/protocol example needs it
170. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
171. research target-specific timing models after source-level predictability and backend boundaries are explicit
172. research exact WCET / runtime models only with a target/hardware model
173. research exact stack-size claims across optimized machine code only with deeper backend/target integration
174. research cache / pipeline behavior as target-level analysis, not a source-language promise
175. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
176. research hardware capability mapping after source-level capabilities and package policies are stable
177. research capability sandbox profiles after authority reports and package policies are useful
178. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically
## Reference Map

The thesis references are [core-thesis](research/thesis-validation/core-thesis.md), [objective-matrix](research/thesis-validation/objective-matrix.md), [thesis-validation](research/thesis-validation/thesis-validation.md), [validation-examples](research/thesis-validation/validation-examples.md), [predictable-execution](research/predictable-execution/predictable-execution.md), [effect-taxonomy](research/predictable-execution/effect-taxonomy.md), [diagnostic-ux](research/compiler/diagnostic-ux.md), and [backend-traceability](research/compiler/backend-traceability.md).

The proof/evidence references are [concrete-to-lean-pipeline](research/proof-evidence/concrete-to-lean-pipeline.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [spec-attachment](research/proof-evidence/spec-attachment.md), [effectful-proofs](research/proof-evidence/effectful-proofs.md), [provable-systems-subset](research/proof-evidence/provable-systems-subset.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md), [proof-ux-and-verification-influences](research/proof-evidence/proof-ux-and-verification-influences.md), [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), and [proof-evidence-artifacts](research/proof-evidence/proof-evidence-artifacts.md).

The language/runtime references are [failure-semantics](research/language/failure-semantics.md), [memory-ub-boundary](research/language/memory-ub-boundary.md), [trusted-code-policy](research/language/trusted-code-policy.md), [interrupt-signal-model](research/language/interrupt-signal-model.md), [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [arena-allocation](research/stdlib-runtime/arena-allocation.md), [execution-cost](research/stdlib-runtime/execution-cost.md), [concurrency](research/stdlib-runtime/concurrency.md), and [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md).

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
