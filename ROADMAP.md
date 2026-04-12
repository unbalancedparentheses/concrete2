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
3. ~~make the memory/reference model explicit enough for broader proofs and stronger public guarantees~~ **done with one explicit gap** — canonical MEMORY_SEMANTICS.md matching Check.lean; public safe-memory claim in MEMORY_GUARANTEES.md with honest boundaries; hard edge cases documented with status (field/substructure borrows: conservative whole-value freeze; array/slice element borrows: conservative whole-array; control-flow joins: fully enforced; owner invalidation: enforced within safe model; concurrency: explicitly deferred); fixed integer-match consumption tracking bug (value-pattern match now checks arm agreement and propagates state like enum-match); expanded adversarial memory edge-case tests; remaining near-term gap: `&mut T` linear-consumption semantics across call/use are not fully closed yet
4. define the exact `&mut T` ownership/consumption semantics as the first memory-model closure task: on call, on return, on rebinding, on repeated use, on method calls, and across control-flow joins
5. enforce the `&mut T` rule in the checker and make illegal double-use fail early: exclusive references must be consumed/invalidated consistently on use instead of behaving differently by expression shape
6. make checker and codegen agree on `&mut T` states so exclusive-reference misuse cannot survive checking and reach a codegen crash
7. add a dedicated adversarial `&mut T` regression suite: call-use, return-use, rebind/copy attempts, branch/match agreement, method chains, cleanup interactions, and aliasing edge cases
8. keep the public safe-memory claim explicitly narrower until the `&mut T` closure work is complete, then widen it deliberately once checker, codegen, docs, and tests agree
9. define the no-leak guarantee boundary explicitly for safe code, pull leak-risk reporting into the same closure phase, and distinguish the strong no-leak claim from weaker allocation/cleanup audit reporting outside that strongest safe subset
10. make effect/trust proof boundaries explicit enough for broader proofs: capabilities, blocking/host calls, allocation, FFI, `trusted` code, and exactly where proofs stop versus where assumptions begin
11. write the precise public theorem/guarantee statement for Concrete's safe and proof-backed subsets: what safe code guarantees, what proof-backed code guarantees, what trusted code invalidates, and which backend/target assumptions still remain
12. define the language-semantics versus proof-semantics boundary explicitly: where the proof model matches the language exactly, where it is intentionally narrower, and how users should read that boundary
13. make the proof-claim taxonomy explicit across docs, reports, and release criteria: enforced by checker, reported by compiler, proved in Lean, trusted assumption, and backend/target assumption
14. define the user-facing proof contract explicitly: what a proof artifact means, when it is stale, what invalidates it, what compatibility is promised, and what “proved” does and does not mean for users
15. add a safe-memory regression checklist artifact that tracks the hard cases, the current checker behavior, the doc claim, the test coverage, and the remaining proof-facing gap in one place
16. build dedicated memory-model pressure tests, adversarial regressions, and examples that force the checker and docs to agree on the hard cases: field/substructure borrows, array/slice element borrows, borrow across control-flow joins, owner invalidation patterns, and borrow-heavy container code
17. make compiler artifacts and reports deterministic/reproducible before CI evidence becomes central: the same source and toolchain inputs should produce the same facts, fingerprints, obligations, reports, and codegen outputs unless a deliberate nondeterministic mode is requested
18. add a deterministic artifact regression suite over facts, fingerprints, obligations, reports, and snapshots so artifact drift is caught as a compiler bug rather than discovered informally
19. add compiler self-consistency checks over artifact families: proof status, obligations, diagnostics, reports, facts, and fingerprints should be checked for internal agreement instead of trusting renderers not to drift
20. add a proof/guarantee consistency gate so docs, report wording, JSON facts, and release criteria cannot silently disagree on terms like `proved`, `trusted`, `blocked`, and `ineligible`
21. define pass invariants and contracts explicitly for Parse, Resolve, Check, Elab, CoreCheck, Mono, Lower, ProofCore, EmitSSA, and artifact emission: what each pass may assume, what it must preserve, and what later passes are allowed to rely on
22. add verifier passes for the important compiler boundaries: Core verification, ProofCore verification, SSA verification, and artifact/schema verification should fail loudly before bad internal state leaks downstream
23. add compiler crash/failure repro tooling and a debug-bundle command: preserve failing inputs, emit stable debug bundles, support testcase minimization/reduction, and capture the IR/report state needed to reproduce parser/checker/proof/codegen failures
24. make the structured/source-spanned diagnostic engine uniform across parser, resolver, checker, elaboration, CoreCheck, report/query failures, proof/evidence failures, artifact/registry failures, package/interface failures, and backend-contract failures
25. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, report-consistency status, policy status, trust-drift check, and the new consistency/determinism gates
26. make module/package policy checks a first-class architecture feature for the existing thesis properties, not just a report-side prototype
27. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
28. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
29. design and implement the smallest bounded-capacity type path that makes predictable examples practical
30. add stack-depth reporting for functions that pass the no-recursion profile
31. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
32. define the no-std / freestanding split for predictable and embedded-oriented code
33. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
34. define concrete project/bootstrap UX: `concrete new`, starter templates, standard layout conventions, and a first supported outsider workflow for trying the language without project-author help
35. build the parser/decoder pressure set before freezing the stdlib target: JSON subset, HTTP request parser, and DNS packet parser, specifically to discover which parsing, slice/buffer, and result/error APIs are actually missing
36. build the ownership-heavy structure pressure set before freezing the stdlib target: tree, ordered map, arena-backed graph, and intrusive list, specifically to discover which ownership, cleanup, and container APIs are actually missing
37. build the trusted-wrapper / FFI pressure set before freezing the stdlib target: libc wrapper, checksum/hash wrapper, and OS call facade, specifically to discover which boundary, error/result, and hosted-only stdlib APIs are actually missing
38. build the fixed-capacity / no-alloc pressure set before freezing the stdlib target: ring buffer, bounded queue, and fixed parser state machine, specifically to discover which bounded-capacity and predictable-subset APIs are actually missing
39. define the first complete stdlib target for the stable subset using pressure from those example sets: name the exact modules and APIs that must exist for the first supported use cases, mark what is intentionally out of scope, record which surfaces are borrowed from Rust/Zig/Austral or other influences, and separate proof/predictability-friendly modules from hosted-only modules
35. polish the stdlib and examples against that target: split or trim APIs that do not belong in the stable subset, clean up path/module decomposition, keep one minimal FFI pressure test, remove accidental API sprawl, and make the stable-subset stdlib feel complete rather than exploratory
36. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
37. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
38. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
39. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
40. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful
41. define a stable benchmark harness before performance packets: selected benchmark programs drawn from the same small/medium/big workload ladder, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
42. add explicit compiler performance budgets on top of profiling: acceptable compile-time regressions, artifact-generation overhead, and memory-growth limits that CI and review can enforce
43. add compile-time regression profiling: parse/check/elaboration/proof/report time, artifact-generation cost, and enough baseline data to keep the compiler usable as the proof pipeline grows
44. add compiler memory profiling and scaling baselines: peak memory, artifact-generation overhead, and growth characteristics on larger proof/fact workloads
45. add runtime/allocation profiling workflow: profiler-friendly output, allocation hot spots, allocation-path visibility, source-location attribution, and a path to correlate profiling results with `--report alloc` / evidence artifacts
46. add large-workspace and many-artifact scaling tests: many modules, many facts, many obligations, repeated snapshot/report workflows, and enough volume to expose nonlinear behavior before package/editor use depends on it
47. deepen leak-risk reporting once the first no-leak boundary and leak reports exist: add richer allocation/cleanup path explanations, trusted/FFI leak attribution, and more precise leak-risk classes where the strong no-leak guarantee does not apply
48. deepen allocation/leak regression coverage once the first reporting surfaces exist: adversarial tests for cleanup-path classification, leak-risk classification, trusted/FFI leak boundaries, and `--report alloc` consistency on larger examples
49. define a real warning/lint discipline: separate hard errors, warnings, deny-in-CI warnings, and advisory lints so diagnostics can get stricter without turning every issue into a compile failure
50. add compiler-debuggable dump modes for the important IR boundaries: typed/core IR, ProofCore, obligations, diagnostics, lowering, and SSA should all have stable human-readable dumps suitable for debugging and regression review
51. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
52. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
53. document and version the fact/query JSON API before external tools depend on it: schema version, stable kind names, field names, location encoding, fingerprint fields, empty-result behavior, and error-result behavior
54. make canonical qualified function identity consistent across all fact families; avoid mixing `parse_byte` and `main.parse_byte` in machine-readable facts unless the distinction is explicit and documented
55. define and implement clear invalid-query diagnostics: malformed/unknown `--query` requests should produce either a structured query error or a deliberate empty answer, not ambiguous success
56. harden malformed artifact, registry, and snapshot handling beyond query errors: corrupted files, duplicate/conflicting entries, partial snapshots, and broken bundles should fail with explicit diagnostics and regression coverage instead of drifting silently
57. define and check module/interface artifacts before package management: exported types, function signatures, capabilities, proof expectations, policy requirements, fact schema version, dependency fingerprints, and enough body/interface separation for later incremental compilation
58. expand packaging/artifacts only after reports, registry, policies, interface artifacts, and CI gates have proved what artifacts must carry
59. define proof-aware package artifacts explicitly: packages should eventually ship facts, obligations, proof status, trusted assumptions, and policy declarations as normal build artifacts
60. build and curate a broader public showcase corpus after the thesis workflow is credible, and shape it deliberately as small, medium, and big programs rather than a pile of demos: small programs should isolate one property, medium programs should test composition, and a few bigger programs should prove the language survives scale
61. turn the showcase corpus into a curated showcase set where each example proves a different thesis claim, each has honest framing, each has report/snapshot/diff coverage, each demonstrates at least one concrete thing the compiler catches, and each is chosen with an oracle in mind when possible: fuzzing, differential testing, round-trip properties, model-based tests, or comparison against another mature implementation/spec
62. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
63. write the migration/adoption playbook: what C/Rust/Zig code should move first, how to wrap existing libraries honestly, how to introduce Concrete into an existing system, and what should stay outside Concrete
64. build the user-facing documentation set deliberately: a FAQ for predictable/proof/capability questions, a Concrete comparison guide against Rust, Zig, SPARK/Ada, Lean 4, and related tools, and the supporting material needed before the language book can stop churning
65. define the showcase maintenance policy: showcase examples are first-class regression targets, must keep honest framing, must retain report/snapshot/diff coverage, and regressions in them count as serious thesis breaks; maintain the small/medium/big balance rather than letting the corpus collapse into only tiny demos
66. define first public release criteria: the first stable supported subset, required examples across small, medium, and big workloads, required diagnostics, required proof workflow, required stdlib/project UX, and the minimum evidence/policy/tooling story for outsiders
67. ship the first real public language release once those criteria are actually met: version the release honestly, publish the supported subset and known limits, ship installable artifacts, and make the release promise narrower than the full roadmap
68. write the real language book/tutorial path only after the first stable supported subset and first public release criteria are concrete enough that teaching the language will not churn with every compiler refactor
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
77. research miscompile-focused differential validation before implementing it broadly: identify trustworthy oracles, artifact/codegen consistency checks, backend sanity checks, and the smallest high-value wrong-code detection corpus
78. research optimization/debug transparency before deeper backend work: which transformations need explainable dumps, which passes need validation hooks, and how optimized/unoptimized evidence should be related without overclaiming
79. stabilize SSA as the backend contract before experimenting with another backend
80. evaluate a normalized mid-level IR only after traceability and backend-contract reports expose a concrete gap between typed Core and SSA; do not add a Rust-MIR-sized layer by default
81. define a target/toolchain model before serious cross-compilation: target triple, data layout, linker, runtime/startup files, libc/no-libc expectation, clang/llc boundary, sanitizer/coverage hooks, and target assumptions
82. evaluate sanitizer, source-coverage, LTO, and toolchain-integrated optimization support only after the backend contract and target/toolchain model are explicit
83. evaluate QBE as the first lightweight second backend once backend/source evidence boundaries and optimization policy are explicit; either land a small path, record a clear rejection, or document why another backend would be warranted instead
84. add cross-backend validation if a second backend lands
85. add source-level debug-info support when codegen maturity becomes the bottleneck
86. implement incremental compilation artifacts after report/proof/policy/interface artifacts are well-shaped: parsed/resolved/typed/lowered caches, dependency keys, invalidation rules, fact/proof invalidation, and clear rebuild explanations
87. split interface artifacts from body artifacts at package/workspace scale
88. research module-cycle and interface-hygiene enforcement before hardening it at package scale: import-cycle policy, interface/body mismatch handling, invalidation boundaries, and package-facing visibility rules
89. design and parse the package manifest
90. add version constraints, dependency resolution, and a lockfile
91. add workspace and multi-package support
92. add package-aware test selection
93. validate cross-target FFI/ABI from package boundaries
94. add module/package authority budgets after package graphs are real
95. define provenance-aware publishing before public package distribution
96. define package/dependency trust policy explicitly: how dependencies summarize trusted assumptions, how trust widens across package boundaries, how package-level evidence is reviewed, and how trust inheritance is made visible
97. add compiler-as-service / editor / LSP support after diagnostics and facts are structured; expose parser/checker/report/query entrypoints without forcing full executable compilation
98. define the LSP/editor feature scope explicitly: go-to-definition, hover/type info, diagnostics, formatting, rename, code actions, and fact/proof-aware language features
99. add fact/proof-aware editor UX: capability/evidence hover, predictable/proof status per function, and jump/link surfaces for obligations, extraction, and traceability
100. add a small human-friendly artifact viewer UX (CLI/TUI/web) for facts, diff, evidence, and proof state once the JSON/schema surfaces stabilize
101. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
102. add release / compatibility discipline when external users depend on the language
103. define explicit language/versioning/deprecation policy across syntax, stdlib APIs, and proof/fact artifacts so users know what stability guarantees exist and how removals happen
104. add stdlib quality gates for the bounded systems surface: API stability expectations, allocation/capability discipline, proof/predictability friendliness for core modules, and compatibility rules for example-grade helper APIs
105. decide the analyzable-concurrency / predictable-execution subset before implementing general concurrency
106. implement OS threads + typed channels only after the concurrency stance is documented
107. keep evented I/O as a later opt-in model, not the default concurrency story
108. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
109. add structural bounded-allocation reports where the compiler can explain the bound
110. add `BoundedAlloc(N)` only where the bound is structurally explainable
111. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
112. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
113. define stack-boundedness reporting and enforcement boundaries
114. separate source-level stack-depth claims from backend/target stack claims
115. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
116. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
117. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
118. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
119. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
120. add coverage tooling over tests, report facts, policy checks, obligations, and proof artifacts
121. improve onboarding so a newcomer can build one small program without project-author help
122. define the stability / experimental boundary for public users
123. expand formalization only after obligations, extraction reports, proof diagnostics, attached specs, the explicit ProofCore boundary, and the broader memory/effect model are artifact-backed
124. research typestate only if a current state-machine/protocol example needs it
125. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
126. research target-specific timing models after source-level predictability and backend boundaries are explicit
127. research exact WCET / runtime models only with a target/hardware model
128. research exact stack-size claims across optimized machine code only with deeper backend/target integration
129. research cache / pipeline behavior as target-level analysis, not a source-language promise
130. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
131. research hardware capability mapping after source-level capabilities and package policies are stable
132. research capability sandbox profiles after authority reports and package policies are useful
133. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically

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
