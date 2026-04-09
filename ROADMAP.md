# Concrete Roadmap

This document answers one question: **what should happen next, in order.**

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references, see [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), and [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by grammar cost, audit cost, and proof cost, not only by expressiveness.

## Current Position

The Lean 4 compiler implements the full pipeline:

`Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → EmitSSA → LLVM IR`

The core language, stdlib foundation, report surfaces, and project workflow are real. Phase H proved the language against real programs. Function-level source locations for `--check predictable` / `--report effects` and Elm-style predictable-profile errors are landed. The next question is no longer "can Concrete express this?" but "can Concrete demonstrate its thesis-level ideas clearly enough to justify the project?"

## Linear Roadmap

Do this list top-to-bottom. This is the roadmap. Completed history belongs in [CHANGELOG.md](CHANGELOG.md), and detailed design belongs in `research/`.

**Priority rule:** do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish until the earlier evidence/diagnostic/tooling steps make those later tasks concrete.

Current guardrails: keep specs in Lean-attached / artifact-registry form until obligations and diagnostics work; build a normal fact CLI before the MCP; keep QBE/Yul/other backend work waiting until proof/evidence attachment and the backend trust boundary are trustworthy.

1. make proof-evidence failures Elm-clear: proved, missing, stale, qualified-identity mismatch, body mismatch, unsupported target, obligation failed
2. add machine-readable diagnostic records for the facts already used by human predictable/effects/proof output
3. add a machine-readable effects/evidence report for the facts already in the human report
4. add audit/explain CLI: `--explain authority main.foo` shows why a function has File/Alloc/Unsafe/trusted/proof status, with the call path that created each requirement — this is the first step toward Concrete as a fact-producing audit machine, not just a compiler
5. add authority path tracing as a first-class query: reviewer asks "why does this function need Network?", compiler answers with the call chain from the function to the capability source
6. move proof/spec/result attachment out of hardcoded compiler tables and into a reproducible registry artifact
7. add `--report obligations`: named proof obligations, status, dependencies, linked function/spec/proof IDs
8. add a source-to-ProofCore extraction report so reviewers can inspect what semantics a proof targets
9. name Lean-attached specs explicitly; keep source-level spec syntax out until the workflow earns it
10. prototype semantic diff / trust drift for capability, allocation, recursion, loop-boundedness, blocking, FFI, trusted, evidence level, and proof freshness
11. prototype module/package policy checks for the existing thesis properties
12. define the thesis threat/accident model and build one attacker-style demo that introduces authority/resource/proof drift and shows Concrete catching it
13. validate fixed-capacity usefulness with a no-alloc parser/validator or ring-buffer-style example
14. design and implement the smallest bounded-capacity type path that makes predictable examples practical
15. add stack-depth reporting for functions that pass the no-recursion profile
16. classify host calls, cleanup paths, determinism sources, failure paths, and memory/UB boundaries for predictable/proved code
17. add report consistency and fact consistency tests: verify that report claims match executable semantics and compiler behavior — reports are product surface, not debug output
18. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, trust-drift check
19. add testing hardening: grammar fuzzing for parser robustness, property-based stdlib traces (Vec/HashMap/String operation sequences), fmt round-trip and idempotency tests
20. return to stdlib/example polish: split/trim, path decomposition, minimal FFI pressure test
21. add a compiler fact query CLI over the machine-readable facts
22. add an MCP server for Claude, ChatGPT, Codex, and research agents to query compiler facts after the CLI is useful
23. produce an agent-readable performance research packet from benchmark, report, proof/evidence, size, and guardrail facts
24. define optimization policy before backend work: what transformations are allowed, what evidence must be preserved, what the compiler is permitted to break — backend work without policy will drift
25. evaluate QBE or another backend only after optimization policy and backend/source evidence boundaries are explicit
26. establish no-std / freestanding split direction: predictable code should work without an allocator, relevant for embedded / SPARK-like credibility — design before implementing
27. expand packaging/artifacts only after reports, registry, policies, and CI gates have proved what artifacts must carry
28. add formatter coverage: idempotency, round-trip correctness, edge-case testing — not before proof/evidence work, but roadmap-visible
29. improve standalone vs project UX: single-file examples should conveniently use stdlib without a project scaffold — if showing examples stays annoying, adoption suffers
30. expand formalization only after obligations, extraction reports, proof diagnostics, and attached specs are artifact-backed
31. build a broader showcase corpus after the thesis workflow is credible
32. start concurrency only after the predictable-execution / analyzable-concurrency stance is explicit
33. pull research-gated language features (const generics, comptime, REPL, broad cleanup/drop redesign, C/Rust differential testing) into implementation only when a current example or proof needs them
34. broaden the pure Core proof fragment after proof artifacts and diagnostics are usable
35. stabilize the provable subset as an explicit user-facing target
36. support artifact-driven user-program proofs end-to-end
37. push selected compiler-preservation proofs where they protect evidence claims
38. evaluate loop invariants only after specs and proof obligations are real
31. evaluate ghost/proof-only code only after a proof-backed example needs it and the erasure story is explicit
32. curate a public showcase corpus after the evidence workflow is credible
33. improve onboarding so a newcomer can build one small program without project-author help
34. define the stability / experimental boundary for public users
35. sharpen the positioning against Rust, Zig, Lean, SPARK, Ada, Austral, Dafny, F*, and Why3 into one short page
36. polish the packet/parser flagship example as the canonical thesis demo
37. build an ELF or binary-format inspector showcase
38. build an FFI showcase with a `trusted` wrapper and `with(Unsafe)` isolated at the boundary
39. build an ownership-heavy data-structure showcase with linear ownership and deterministic cleanup
40. build a privilege-separated tool where capability signatures prove the trusted core cannot touch files/network/processes
41. stabilize SSA as the backend contract before experimenting with another backend
42. evaluate QBE as the first lightweight second backend; either land a small path or record a clear rejection
43. add cross-backend validation if a second backend lands
44. add source-level debug-info support when codegen maturity becomes the bottleneck
45. decide the analyzable-concurrency subset before implementing general concurrency
46. implement OS threads + typed channels only after the concurrency stance is documented
47. keep evented I/O as a later opt-in model, not the default concurrency story
48. strengthen `--report alloc` so every user-visible allocation is attributed to a source location and call path
49. add structural bounded-allocation reports where the compiler can explain the bound
50. add `BoundedAlloc(N)` only where the bound is structurally explainable
51. define a tighter bounded-allocation profile between `NoAlloc` and unrestricted allocation
52. define stack-boundedness reporting and enforcement boundaries
53. separate source-level stack-depth claims from backend/target stack claims
54. define backend and target assumptions for timing, stack, calls, layout, undefined behavior, and proof/evidence boundaries
55. define failure-path boundedness: abort, assertions, impossible branches, OOM-excluded profiles, `defer`, drops, and cleanup paths
56. define arithmetic-overflow policy for predictable/proved profiles versus performance-oriented profiles
57. validate predictable execution with bounded examples: fixed-buffer parser, bounded-state controller, fixed-capacity ring buffer, or equivalent
58. implement incremental compilation artifacts after report/proof/policy artifacts are well-shaped
59. split interface artifacts from body artifacts
60. design and parse the package manifest
61. add version constraints, dependency resolution, and a lockfile
62. add workspace and multi-package support
63. add package-aware test selection
64. validate cross-target FFI/ABI from package boundaries
65. add module/package authority budgets after package graphs are real
66. define provenance-aware publishing before public package distribution
67. add coverage tooling over tests, report facts, policy checks, obligations, and proof artifacts
68. add editor/LSP support after diagnostics are structured
69. add dependency auditing for capability, allocation, FFI, trust, evidence, and predictability drift
70. add release / compatibility discipline when external users depend on the language
71. research typestate only if a current state-machine/protocol example needs it
72. research arena allocation after bounded-capacity and allocation-profile work exposes a concrete gap
73. research target-specific timing models after source-level predictability and backend boundaries are explicit
74. research exact WCET / runtime models only with a target/hardware model
75. research exact stack-size claims across optimized machine code only with deeper backend/target integration
76. research cache / pipeline behavior as target-level analysis, not a source-language promise
77. research binary-format DSLs only if the packet/ELF examples show repeated parser boilerplate
78. research hardware capability mapping after source-level capabilities and package policies are stable
79. research capability sandbox profiles after authority reports and package policies are useful
80. research a Miri-style interpreter only after the memory/UB model and proof subset are precise enough to execute symbolically

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
