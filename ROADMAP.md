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

Completed proof-foundation milestones now live in [CHANGELOG.md](CHANGELOG.md): crypto flagship, ELF flagship, eligibility-first proof flow, explicit `Core -> ProofCore`, ProofCore consolidation, qualified proof identity, proof normalization, stable attached specs, first-slice mechanical obligations, proof-oriented diagnostics, explicit memory/reference semantics, the `&mut T` closure arc, the no-codegen-crash rule, the first explicit no-leak guarantee boundary, the effect/trust proof boundary specification, the public guarantee statement, and the language-semantics vs proof-semantics boundary specification.

The active roadmap below starts after that completed proof/memory closure work. If an item is done, move it to [CHANGELOG.md](CHANGELOG.md) instead of leaving it in the numbered task list.
3. make the proof-claim taxonomy explicit across docs, reports, and release criteria: enforced by checker, reported by compiler, proved in Lean, trusted assumption, and backend/target assumption
4. define the user-facing proof contract explicitly: what a proof artifact means, when it is stale, what invalidates it, what compatibility is promised, and what “proved” does and does not mean for users
5. add a safe-memory regression checklist artifact that tracks the hard cases, the current checker behavior, the doc claim, the test coverage, and the remaining proof-facing gap in one place
6. build dedicated memory-model pressure tests, adversarial regressions, and examples that force the checker and docs to agree on the hard cases: field/substructure borrows, array/slice element borrows, borrow across control-flow joins, owner invalidation patterns, and borrow-heavy container code
7. build a dedicated borrow/aliasing pressure set whose main job is to expose `&mut` and aliasing mistakes: sequential exclusive-reference use, method-call chains on borrowed owners, branch/match use of exclusive references, field/element borrow stress cases, and borrow-heavy adapters/containers
8. build a dedicated cleanup/leak-boundary pressure set whose main job is to expose cleanup and leak-classification mistakes: nested `defer` paths, destroy/free wrappers, cleanup through helper APIs, alloc/free facades, and trusted/FFI cleanup boundaries
9. make compiler artifacts and reports deterministic/reproducible before CI evidence becomes central: the same source and toolchain inputs should produce the same facts, fingerprints, obligations, reports, and codegen outputs unless a deliberate nondeterministic mode is requested
10. add a deterministic artifact regression suite over facts, fingerprints, obligations, reports, and snapshots so artifact drift is caught as a compiler bug rather than discovered informally
11. add compiler self-consistency checks over artifact families: proof status, obligations, diagnostics, reports, facts, and fingerprints should be checked for internal agreement instead of trusting renderers not to drift
12. add a proof/guarantee consistency gate so docs, report wording, JSON facts, and release criteria cannot silently disagree on terms like `proved`, `trusted`, `blocked`, and `ineligible`
13. define pass invariants and contracts explicitly for Parse, Resolve, Check, Elab, CoreCheck, Mono, Lower, ProofCore, EmitSSA, and artifact emission: what each pass may assume, what it must preserve, and what later passes are allowed to rely on
14. add verifier passes for the important compiler boundaries: Core verification, ProofCore verification, SSA verification, and artifact/schema verification should fail loudly before bad internal state leaks downstream
15. add compiler crash/failure repro tooling and a debug-bundle command: preserve failing inputs, emit stable debug bundles, support testcase minimization/reduction, and capture the IR/report state needed to reproduce parser/checker/proof/codegen failures
16. make the structured/source-spanned diagnostic engine uniform across parser, resolver, checker, elaboration, CoreCheck, report/query failures, proof/evidence failures, artifact/registry failures, package/interface failures, and backend-contract failures
17. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, report-consistency status, policy status, trust-drift check, and the new consistency/determinism gates
18. add error-context and backtrace support so deep `Result`-based failures can accumulate human-meaningful context, capture stack traces where the runtime/target allows it, and surface that information consistently in diagnostics and developer tooling
19. make module/package policy checks a first-class architecture feature for the existing thesis properties, not just a report-side prototype
20. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
21. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
22. design and implement the smallest bounded-capacity type path that makes predictable examples practical
23. add stack-depth reporting for functions that pass the no-recursion profile
24. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
25. define the no-std / freestanding split for predictable and embedded-oriented code
26. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
27. define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow for trying the language without project-author help
28. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, and DNS packet parser, specifically to discover which parsing, slice/buffer, and result/error APIs are actually missing
29. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, and container APIs are actually missing
30. build the borrow/aliasing program pressure set before freezing the stdlib target: sequential `&mut` workflows, borrow-heavy adapters, field/element borrow stress programs, iterator-like borrowing patterns, and other programs whose main job is to force the aliasing surface into the open
31. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, and OS call facade, specifically to discover which boundary, error/result, and hosted-only stdlib APIs are actually missing
32. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, and fixed parser state machine, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
33. build the cleanup/leak-boundary program pressure set before freezing the stdlib target: nested defer-driven helpers, alloc/free facades, cleanup-heavy service code, and trusted/FFI cleanup boundaries that force leak reporting and destroy ergonomics to become honest
34. define the first complete stdlib target for the stable subset using pressure from those example sets: name the exact modules and APIs that must exist for the first supported use cases, mark what is intentionally out of scope, record which surfaces are borrowed from Rust/Zig/Austral or other influences, and separate proof/predictability-friendly modules from hosted-only modules
35. polish the stdlib and examples against that target: split or trim APIs that do not belong in the stable subset, clean up path/module decomposition, keep one minimal FFI pressure test, remove accidental API sprawl, and make the stable-subset stdlib feel complete rather than exploratory
36. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
37. add structured logging/tracing/observability primitives for real services and tools: leveled logs, structured fields, spans/events where justified, and an honest split between minimal core APIs and hosted/runtime integrations
38. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
39. add documentation-comment extraction and doc generation from source so API reference material is produced from canonical declarations/comments instead of drifting handwritten docs
40. add doc tests so code examples in docs and generated API reference can compile or run as regression tests rather than silently rotting
41. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
42. add dedicated fuzzing infrastructure where there is a real oracle: grammar fuzzing, structure-aware parser fuzzing, coverage-guided fuzzing for high-risk surfaces, and a path to keep discovered crashes/miscompiles as stable regressions
43. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
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
61. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation
62. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
63. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, and policy declarations as normal build artifacts
64. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale; the corpus must include borrow/aliasing programs and cleanup/leak-boundary programs, not only parsers and containers
65. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec; include explicit borrow/aliasing and cleanup/leak-boundary examples in that quality bar
66. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
67. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete; include C-header scaffolding and stale-proof repair suggestions before broader migration automation
68. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
69. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
70. build a named big-workload flagship set, not just small pressure examples: at minimum one real protocol/parser security example, one crypto/security proof example, one privilege-separated tool, one ownership-heavy medium program, and one bounded/no-alloc medium program
71. require each big-workload flagship to have honest proof/trust boundary framing, report/snapshot/diff coverage, and an oracle when possible (fuzzing, differential testing, round-trip properties, or model-based checks) so they function as real validation workloads instead of marketing demos
72. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders; the example bar must explicitly include parser/decoder, ownership-heavy, borrow/aliasing, trusted-wrapper/FFI, fixed-capacity, cleanup/leak-boundary, and the named big-workload programs
73. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
74. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
75. add a REPL and lightweight playground workflow once the parser/checker diagnostics and project UX are stable enough that quick experimentation will reflect the real language instead of a toy front-end
76. polish the packet/parser flagship example as the canonical thesis demo
77. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
78. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
79. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
80. build a fixed-capacity / no-alloc showcase that proves the predictable subset is practical for real bounded systems code
81. build a real cryptography example only after the proof/artifact boundary is stronger: good candidates are constant-time equality + verification use, an HMAC verification core, an Ed25519 verification helper/core subset, or hash/parser/encoding correctness around a crypto-adjacent component
82. refine and stabilize the explicit `Core -> ProofCore` phase after the flagship has forced it into the open: keep the extraction semantics small, testable, and shared by obligations, specs, proofs, and future proof tools
83. extend ProofCore and its semantics to cover more real Concrete constructs in a principled order: structs/fields, pattern matching, arrays/slices, borrows/dereferences, casts, cleanup/defer/drop behavior, and other constructs the flagship examples actually force into scope
84. broaden proof obligation generation beyond the first pipeline slice so loop-related, memory-related, and contract-related proof work becomes mechanically inspectable instead of ad hoc
85. broaden the pure Core proof fragment after proof artifacts, diagnostics, the explicit ProofCore phase, normalization, and obligation generation are usable
86. deepen the memory/reference model for proofs once the first explicit version exists: sharpen ownership, aliasing, mutation, pointer/reference, cleanup, and layout reasoning where real examples require it
87. deepen the effect/trust proof boundaries once the first explicit version exists: prove more right up to capability, allocation, blocking, FFI, and trusted edges without pretending the edges disappear
88. add a dedicated proof-regression test pipeline covering `Core -> ProofCore`, normalization stability, obligation generation, exclusion reasons, stale proof behavior, and proof artifact drift
89. stabilize the provable subset as an explicit user-facing target
90. define public release criteria for the provable subset: supported constructs, unsupported constructs, trust assumptions, proof artifact stability expectations, and what evidence claims users may rely on semantically
91. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
92. validate proof attachments against actual Lean symbols and theorem identities: fabricated proof names, missing theorem references, and mismatched spec/theorem pairs must fail explicitly instead of surviving as registry-shaped metadata
93. add end-to-end Lean attachment regression coverage: registry entries, proof names, theorem identities, extracted proof targets, and stale detection should be tested together so the Lean bridge is a checked boundary rather than a naming convention
94. support artifact-driven user-program proofs end-to-end
95. define the user proof-authoring and maintenance workflow explicitly: how a user writes/updates specs and proofs, regenerates artifacts, diagnoses stale or blocked proofs, and lands proof-preserving refactors without reading compiler internals
96. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
97. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
98. push selected compiler-preservation proofs where they protect evidence claims
99. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, and the explicit ProofCore boundary are real
100. evaluate loop invariants only after specs and proof obligations are real
101. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
102. pull research-gated language features into implementation only when a current example or proof needs them
103. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
104. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
105. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
106. stabilize SSA as the backend contract before experimenting with another backend
107. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
108. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
109. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
110. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
111. add cross-backend validation if a second backend lands
112. add source-level debug-info support when codegen maturity becomes the bottleneck
113. make the target/toolchain model concrete enough to support an explicit WASM target decision: either land a narrow WASM path with honest runtime/tooling limits or record a clear deferral with reasons
114. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
115. add clean-build versus incremental-build equivalence checks: the same source and toolchain state must produce identical facts, obligations, diagnostics, reports, and codegen outputs whether built from scratch or through incremental caches
116. add compiler-process resource-hygiene checks for long-running workflows: repeated report/query/snapshot/incremental runs should not leak memory, file descriptors, temp artifacts, or subprocess state
117. turn crash-repro tooling into a real reducer/minimizer workflow for parser/checker/proof/codegen failures so regressions can be shrunk automatically into stable repro cases
118. define a canonical semantic test matrix: every important language rule and artifact guarantee should map to positive, negative, adversarial, and artifact-level regression coverage
119. split interface artifacts from body artifacts at package/workspace scale
120. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
121. design and parse the package manifest
122. add build-script/custom-build-logic support only after the package manifest is stable enough to host it: code generation, C library compilation, resource embedding, and environment detection should be explicit and constrained rather than arbitrary hidden shelling-out
123. add version constraints, dependency resolution, and a lockfile
124. add workspace and multi-package support
125. add package-aware test selection
126. generate C headers from public C-ABI-facing Concrete declarations so library-grade `extern "C"` / `repr(C)` surfaces do not require manually maintained `.h` files
127. validate cross-target FFI/ABI from package boundaries
128. add module/package authority budgets after package graphs are real
129. define provenance-aware publishing before public package distribution
130. define package registry server protocol and trust model before a public ecosystem push: upload/download, index/search, yanking/deprecation, checksums/signatures, authentication, and compatibility with provenance/evidence artifacts
131. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible
132. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
133. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
134. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
135. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
136. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
137. add release / compatibility discipline when external users depend on the language
138. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
139. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs
140. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
141. implement OS threads + typed channels only after the concurrency stance is documented
142. keep evented I/O as a later opt-in model, not the default concurrency story
143. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
144. add structural bounded-allocation reports where the compiler can explain the bound
145. add `BoundedAlloc(N)` only where the bound is structurally explainable
146. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
147. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
148. define stack-boundedness reporting and enforcement boundaries
149. separate source-level stack-depth claims from backend/target stack claims
150. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
151. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
152. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
153. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
154. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
155. add coverage tooling over tests, report facts, policy checks, obligations, proof artifacts, and doc tests
156. add memory-profiler and leak-debug integration for user programs once runtime/allocation profiling exists: heap snapshots or allocation tracing where the target allows it, leak-focused workflows, and a path to correlate runtime findings with `--report alloc`
157. improve onboarding so a newcomer can build one small program without project-author help
158. define the stability / experimental boundary for public users
159. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
160. research typestate only if a current state-machine/protocol example needs it
161. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
162. research target-specific timing models after source-level predictability and backend boundaries are explicit
163. research exact WCET / runtime models only with a target/hardware model
164. research exact stack-size claims across optimized machine code only with deeper backend/target integration
165. research cache / pipeline behavior as target-level analysis, not a source-language promise
166. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
167. research hardware capability mapping after source-level capabilities and package policies are stable
168. research capability sandbox profiles after authority reports and package policies are useful
169. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically
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
