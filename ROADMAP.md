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

## Linear Roadmap

Do this list top-to-bottom. This is the roadmap. Completed history belongs in [CHANGELOG.md](CHANGELOG.md), and detailed design belongs in `research/`. When items leave the active roadmap, update the changelog in the same cleanup.

**Priority rule:** do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until the earlier evidence/diagnostic/tooling steps make those later tasks concrete.

Current guardrails: keep specs in Lean-attached / artifact-registry form until obligations and diagnostics work; build a normal fact CLI before the MCP; keep QBE/Yul/other backend work waiting until proof/evidence attachment, optimization policy, and the backend trust boundary are trustworthy.

1. document and version the fact/query JSON API before external tools depend on it: schema version, stable kind names, field names, location encoding, fingerprint fields, empty-result behavior, and error-result behavior
2. make canonical qualified function identity consistent across all fact families; avoid mixing `parse_byte` and `main.parse_byte` in machine-readable facts unless the distinction is explicit and documented
3. define and implement clear invalid-query diagnostics: malformed/unknown `--query` requests should produce either a structured query error or a deliberate empty answer, not ambiguous success
4. add semantic fact queries after the thin filter works: `--query why-capability:main:File`, `--query predictable:decode_header`, `--query proof:decode_header`, `--query trust:call_raw`, `--query allocation:uses_alloc`, and `--query evidence:decode_header`; output answer-shaped JSON
5. make authority tracing / audit explanation a first-class query: explain whether authority is declared directly or required through a call path; answer review questions from compiler facts instead of forcing reviewers to grep reports
6. move proof/spec/result attachment out of hardcoded compiler tables and into a reproducible registry artifact
7. add `--report obligations`: named proof obligations, status, dependencies, linked function/spec/proof IDs
8. add a source-to-ProofCore extraction report so reviewers can inspect what semantics a proof targets
9. name Lean-attached specs explicitly; keep source-level spec syntax out until the workflow earns it
10. prototype semantic diff / trust drift for capability, allocation, recursion, loop-boundedness, blocking, FFI, trusted, evidence level, proof freshness, and proof-obligation status
11. add a fact artifact snapshot command for project/CI use: generate the fact JSON, predictable/profile status, proof status, obligations, policies, and trusted assumptions as stable build artifacts
12. prototype module/package policy checks for the existing thesis properties
13. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
14. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, report-consistency status, policy status, and trust-drift check
15. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the normal fact CLI is useful
16. define a stable benchmark harness before performance packets: selected benchmark programs, repeatable runner, baseline artifacts, size/output checks, and enough metadata to compare patches honestly
17. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
18. make the AI optimization loop explicit: generate packet, propose patch, run benchmarks, run evidence gates, reject patches that weaken proof/trust/predictability unless requested
19. add grammar fuzzing for parser robustness and diagnostic stability
20. add property-based tests for formatter/parser round-trips, selected stdlib containers, and fixed traces over Vec, String/Text, HashMap, parser cores, and report facts
21. add targeted differential/codegen tests only where there is an executable oracle and a known backend risk
22. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
23. design and implement the smallest bounded-capacity type path that makes predictable examples practical
24. add stack-depth reporting for functions that pass the no-recursion profile
25. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
26. define the no-std / freestanding split for predictable and embedded-oriented code
27. define standalone-file versus project UX so examples and small tools can use the stdlib without accidental workflow friction
28. return to stdlib/example polish: split/trim, path decomposition, minimal FFI pressure test
29. continue cleanup/destroy ergonomics only when examples force it: unified `drop(x)` / Destroy-style API, scoped cleanup helpers, borrow-friendly owner APIs, and report coverage for cleanup paths
30. add a code formatter or make the existing formatter robust enough to be the default documentation/example workflow
31. expand packaging/artifacts only after reports, registry, policies, and CI gates have proved what artifacts must carry
32. expand formalization only after obligations, extraction reports, proof diagnostics, and attached specs are artifact-backed
33. build a broader showcase corpus after the thesis workflow is credible
34. define optimization policy before substantial backend work: allowed optimizations, evidence-preservation expectations, debug/release behavior, and report/codegen validation expectations
35. evaluate QBE or another backend only after backend/source evidence boundaries and optimization policy are explicit
36. start concurrency only after the predictable-execution / analyzable-concurrency stance is explicit
37. pull research-gated language features into implementation only when a current example or proof needs them
38. broaden the pure Core proof fragment after proof artifacts and diagnostics are usable
39. stabilize the provable subset as an explicit user-facing target
40. support artifact-driven user-program proofs end-to-end
41. push selected compiler-preservation proofs where they protect evidence claims
42. evaluate contracts / source-level preconditions only after Lean-attached specs, obligations, diagnostics, and the registry work
43. evaluate loop invariants only after specs and proof obligations are real
44. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
45. curate a public showcase corpus after the evidence workflow is credible
46. improve onboarding so a newcomer can build one small program without project-author help
47. define the stability / experimental boundary for public users
48. sharpen the positioning against Rust, Zig, Lean 4, SPARK/Ada, Austral, Dafny, F*, and Why3 into one short page
49. polish the packet/parser flagship example as the canonical thesis demo
50. build an ELF or binary-format inspector showcase
51. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
52. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
53. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
54. strengthen memory/layout audit reports with source locations, qualified names, repr/packed/align facts, trusted-pointer boundaries, and backend/target caveats
55. stabilize SSA as the backend contract before experimenting with another backend
56. evaluate QBE as the first lightweight second backend; either land a small path or record a clear rejection
57. add cross-backend validation if a second backend lands
58. add source-level debug-info support when codegen maturity becomes the bottleneck
59. decide the analyzable-concurrency subset before implementing general concurrency
60. implement OS threads + typed channels only after the concurrency stance is documented
61. keep evented I/O as a later opt-in model, not the default concurrency story
62. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
63. add structural bounded-allocation reports where the compiler can explain the bound
64. add `BoundedAlloc(N)` only where the bound is structurally explainable
65. evaluate const-generics / comptime only when bounded capacity or artifact generation needs a narrow version of it
66. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
67. define stack-boundedness reporting and enforcement boundaries
68. separate source-level stack-depth claims from backend/target stack claims
69. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
70. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
71. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
72. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
73. implement incremental compilation artifacts after report/proof/policy artifacts are well-shaped
74. split interface artifacts from body artifacts
75. design and parse the package manifest
76. add version constraints, dependency resolution, and a lockfile
77. add workspace and multi-package support
78. add package-aware test selection
79. validate cross-target FFI/ABI from package boundaries
80. add module/package authority budgets after package graphs are real
81. define provenance-aware publishing before public package distribution
82. add coverage tooling over tests, report facts, policy checks, obligations, and proof artifacts
83. add editor/LSP support after diagnostics are structured
84. add dependency auditing for capability, allocation, FFI, trust, evidence, predictability, and proof-obligation drift
85. add release / compatibility discipline when external users depend on the language
86. research typestate only if a current state-machine/protocol example needs it
87. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
88. research target-specific timing models after source-level predictability and backend boundaries are explicit
89. research exact WCET / runtime models only with a target/hardware model
90. research exact stack-size claims across optimized machine code only with deeper backend/target integration
91. research cache / pipeline behavior as target-level analysis, not a source-language promise
92. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
93. research hardware capability mapping after source-level capabilities and package policies are stable
94. research capability sandbox profiles after authority reports and package policies are useful
95. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically

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
