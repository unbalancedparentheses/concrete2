# Concrete Roadmap

This document answers one question: **what should happen next, in order.**

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
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

Completed proof-foundation milestones now live in [CHANGELOG.md](CHANGELOG.md): crypto flagship, ELF flagship, eligibility-first proof flow, explicit `Core -> ProofCore`, ProofCore consolidation, qualified proof identity, proof normalization, stable attached specs, and first-slice mechanical obligations.

1. ~~close the remaining obligation-model correctness gaps~~ **done** — added `blocked` status for eligible-but-unextractable functions; stale takes precedence over blocked when spec has mismatched fingerprint; trust and ineligibility override matching registry entries; dependencies exclude non-proved callees; source vs profile exclusion carries distinct reasons; 7 adversarial obligation-semantics tests
2. ~~make proof-oriented diagnostics first-class~~ **done** — `ProofDiagnosticKind`, `ProofDiagnosticSeverity`, and `ProofDiagnostic` types in ProofCore; diagnostics generated during `extractProofCore` from obligations + unsupported constructs; `--report proof-diagnostics` human-readable report; `proof_diagnostic` JSON facts in snapshots; `blocked` state in proof-status and obligation reports; 8 adversarial diagnostic tests
3. make the memory/reference model explicit enough for broader proofs and stronger public guarantees: consolidate one checker-matching semantics document; define the safe-memory guarantee statement for safe code; close the hard edge cases (field/substructure borrows, array/slice element borrows, control-flow joins, heap-owner invalidation patterns, future concurrency interaction); and connect that model cleanly to proof/evidence artifacts
4. make effect/trust proof boundaries explicit enough for broader proofs: capabilities, blocking/host calls, allocation, FFI, `trusted` code, and exactly where proofs stop versus where assumptions begin
5. write the precise public theorem/guarantee statement for Concrete's safe and proof-backed subsets: what safe code guarantees, what proof-backed code guarantees, what trusted code invalidates, and which backend/target assumptions still remain
6. define the language-semantics versus proof-semantics boundary explicitly: where the proof model matches the language exactly, where it is intentionally narrower, and how users should read that boundary
7. make the proof-claim taxonomy explicit across docs, reports, and release criteria: enforced by checker, reported by compiler, proved in Lean, trusted assumption, and backend/target assumption
8. define the user-facing proof contract explicitly: what a proof artifact means, when it is stale, what invalidates it, what compatibility is promised, and what “proved” does and does not mean for users
9. make module/package policy checks a first-class architecture feature for the existing thesis properties, not just a report-side prototype
10. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
11. make the structured/source-spanned diagnostic engine uniform across parser, resolver, checker, elaboration, CoreCheck, report/query failures, proof/evidence failures, artifact/registry failures, package/interface failures, and backend-contract failures
12. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, report-consistency status, policy status, and trust-drift check
13. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
14. design and implement the smallest bounded-capacity type path that makes predictable examples practical
15. add stack-depth reporting for functions that pass the no-recursion profile
16. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
17. define the no-std / freestanding split for predictable and embedded-oriented code
18. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
19. define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow for trying the language without project-author help
20. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, and DNS packet parser, specifically to discover which parsing, slice/buffer, and result/error APIs are actually missing
21. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, and container APIs are actually missing
22. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, and OS call facade, specifically to discover which boundary, error/result, and hosted-only stdlib APIs are actually missing
23. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, and fixed parser state machine, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
24. define the first complete stdlib target for the stable subset using pressure from those example sets: name the exact modules and APIs that must exist for the first supported use cases, mark what is intentionally out of scope, record which surfaces are borrowed from Rust/Zig/Austral or other influences, and separate proof/predictability-friendly modules from hosted-only modules
25. polish the stdlib and examples against that target: split or trim APIs that do not belong in the stable subset, clean up path/module decomposition, keep one minimal FFI pressure test, remove accidental API sprawl, and make the stable-subset stdlib feel complete rather than exploratory
26. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
27. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
28. define formatter quality gates explicitly: idempotency, syntax preservation, comment stability, predictable output, and CI enforcement
29. make the core/shell split a real pit of success: examples, diagnostics, library patterns, and policy defaults should push users toward bounded/provable cores and effectful shells by default
30. write the standard architecture cookbook for Concrete: bounded parser + shell, trusted FFI wrapper + safe facade, privilege-separated service, ownership-heavy data structure, and fixed-capacity pipeline patterns, with example programs drawn from the same small/medium/big workload ladder the roadmap uses elsewhere
31. define the first stable supported subset as a public milestone: the first production-shaped slice of Concrete that outsiders can rely on without having to understand the whole research roadmap, and tie it to a concrete workload bar across small, medium, and big programs rather than a few isolated demos
32. write the thesis paper once the flagship examples, explicit ProofCore boundary, and evidence/policy/drift workflow are coherent enough to defend the core claim in one crisp story, using the small/medium/big workload ladder to show both isolated properties and larger-program survival
33. add grammar fuzzing for parser robustness and diagnostic stability
34. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
35. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
36. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful
33. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
34. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
35. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
36. document and version the fact/query JSON API before external tools depend on it: schema version, stable kind names, field names, location encoding, fingerprint fields, empty-result behavior, and error-result behavior
37. make canonical qualified function identity consistent across all fact families; avoid mixing `parse_byte` and `main.parse_byte` in machine-readable facts unless the distinction is explicit and documented
38. define and implement clear invalid-query diagnostics: malformed/unknown `--query` requests should produce either a structured query error or a deliberate empty answer, not ambiguous success
39. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation
40. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
41. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, and policy declarations as normal build artifacts
42. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale
43. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec
44. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
45. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete
46. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
47. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
48. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders
49. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
50. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
51. polish the packet/parser flagship example as the canonical thesis demo
52. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
53. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
54. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
55. build a fixed-capacity / no-alloc showcase that proves the predictable subset is practical for real bounded systems code
56. build a real cryptography example only after the proof/artifact boundary is stronger: good candidates are constant-time equality + verification use, an HMAC verification core, an Ed25519 verification helper/core subset, or hash/parser/encoding correctness around a crypto-adjacent component
57. refine and stabilize the explicit `Core -> ProofCore` phase after the flagship has forced it into the open: keep the extraction semantics small, testable, and shared by obligations, specs, proofs, and future proof tools
58. extend ProofCore and its semantics to cover more real Concrete constructs in a principled order: structs/fields, pattern matching, arrays/slices, borrows/dereferences, casts, cleanup/defer/drop behavior, and other constructs the flagship examples actually force into scope
59. broaden proof obligation generation beyond the first pipeline slice so loop-related, memory-related, and contract-related proof work becomes mechanically inspectable instead of ad hoc
60. broaden the pure Core proof fragment after proof artifacts, diagnostics, the explicit ProofCore phase, normalization, and obligation generation are usable
61. deepen the memory/reference model for proofs once the first explicit version exists: sharpen ownership, aliasing, mutation, pointer/reference, cleanup, and layout reasoning where real examples require it
62. deepen the effect/trust proof boundaries once the first explicit version exists: prove more right up to capability, allocation, blocking, FFI, and trusted edges without pretending the edges disappear
63. add a dedicated proof-regression test pipeline covering `Core -> ProofCore`, normalization stability, obligation generation, exclusion reasons, stale proof behavior, and proof artifact drift
64. stabilize the provable subset as an explicit user-facing target
65. define public release criteria for the provable subset: supported constructs, unsupported constructs, trust assumptions, proof artifact stability expectations, and what evidence claims users may rely on semantically
66. stabilize proof artifact/schema compatibility alongside the fact/query schema: proof-status, obligations, extraction, traceability, fingerprints, spec identifiers, and proof identifiers need explicit compatibility rules before external users or tools depend on them
67. support artifact-driven user-program proofs end-to-end
68. define the user proof-authoring and maintenance workflow explicitly: how a user writes/updates specs and proofs, regenerates artifacts, diagnoses stale or blocked proofs, and lands proof-preserving refactors without reading compiler internals
69. make proof extraction and obligation generation scale to larger projects without collapsing usability: measure cost, identify bottlenecks, and keep the proof workflow tractable as the codebase grows
70. add proof replay/caching on top of the artifact model so unchanged proof targets, fingerprints, and obligations do not have to be recomputed or revalidated from scratch in every workflow
71. push selected compiler-preservation proofs where they protect evidence claims
72. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, the registry work, and the explicit ProofCore boundary are real
73. evaluate loop invariants only after specs and proof obligations are real
74. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
75. pull research-gated language features into implementation only when a current example or proof needs them
76. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
77. stabilize SSA as the backend contract before experimenting with another backend
78. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
79. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
80. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
81. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
82. add cross-backend validation if a second backend lands
83. add source-level debug-info support when codegen maturity becomes the bottleneck
84. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
85. split interface artifacts from body artifacts at package/workspace scale
86. design and parse the package manifest
87. add version constraints, dependency resolution, and a lockfile
88. add workspace and multi-package support
89. add package-aware test selection
90. validate cross-target FFI/ABI from package boundaries
91. add module/package authority budgets after package graphs are real
92. define provenance-aware publishing before public package distribution
93. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible
94. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
95. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
96. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
97. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
98. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
99. add release / compatibility discipline when external users depend on the language
100. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
101. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs
102. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
103. implement OS threads + typed channels only after the concurrency stance is documented
104. keep evented I/O as a later opt-in model, not the default concurrency story
105. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
106. add structural bounded-allocation reports where the compiler can explain the bound
107. add `BoundedAlloc(N)` only where the bound is structurally explainable
108. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
109. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
110. define stack-boundedness reporting and enforcement boundaries
111. separate source-level stack-depth claims from backend/target stack claims
112. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
113. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
114. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
115. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
116. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
117. add coverage tooling over tests, report facts, policy checks, obligations, and proof artifacts
118. improve onboarding so a newcomer can build one small program without project-author help
119. define the stability / experimental boundary for public users
120. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
121. research typestate only if a current state-machine/protocol example needs it
122. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
123. research target-specific timing models after source-level predictability and backend boundaries are explicit
124. research exact WCET / runtime models only with a target/hardware model
125. research exact stack-size claims across optimized machine code only with deeper backend/target integration
126. research cache / pipeline behavior as target-level analysis, not a source-language promise
127. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
128. research hardware capability mapping after source-level capabilities and package policies are stable
129. research capability sandbox profiles after authority reports and package policies are useful
130. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically

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
