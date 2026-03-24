# Concrete Roadmap

This document answers one question: **what should happen next, in order.**

For landed milestones, see [CHANGELOG.md](CHANGELOG.md).
For compiler structure, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md).
For identity and safety, see [docs/IDENTITY.md](docs/IDENTITY.md) and [docs/SAFETY.md](docs/SAFETY.md).
For subsystem references, see [docs/FFI.md](docs/FFI.md), [docs/ABI.md](docs/ABI.md), [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md), [docs/STDLIB.md](docs/STDLIB.md), [docs/VALUE_MODEL.md](docs/VALUE_MODEL.md), and [docs/EXECUTION_MODEL.md](docs/EXECUTION_MODEL.md).

Concrete should stay small enough to remain readable, auditable, and mechanically understandable. New work should be judged by grammar cost, audit cost, and proof cost, not only by expressiveness.

## Where We Are

The Lean 4 compiler implements the full pipeline:

`Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → EmitSSA → LLVM IR`

The core language, stdlib foundation, report surfaces, and project workflow are real. Phase H (real-program pressure testing) is nearly complete: discovery is done, cleanup is wrapping up. The main missing structural pieces are package/artifact architecture, broader formalization, backend plurality, and a fuller runtime story.

## 1. Finish Phase H Cleanup

**Status:** active — discovery complete, cleanup wrapping up.

The remaining work is narrow and evidence-backed. Do not reopen H as open-ended exploration.

**Tasks:**
1. match-as-expression: value-producing `match` so linear types can be bound from branches without dummy-init workarounds — done when `let x = match ... { }` parses and type-checks
2. clean up stdlib output surface so examples stop using builtin-shaped `print_string` / `print_char` — done when stdlib output reads like coherent library code rather than builtin vocabulary
3. classify remaining runtime/stack pressure findings as language, runtime, stdlib, or tooling — done when every finding has a clear owner and runtime/stack questions are not ambient

**Not next:**
1. string `==` operator
2. broader destructuring syntax

**References:** [phase-h-findings](research/workloads/phase-h-findings.md), [text-and-output-design](research/stdlib-runtime/text-and-output-design.md), [cleanup-ergonomics](research/language/cleanup-ergonomics.md)

## 2. Package and Artifact Architecture (Phase J)

**Status:** not started. This is the next major architectural build-out once H cleanup is done.

**Tasks:**
1. incremental compilation: serialize artifacts, cache by source hash, skip unchanged modules — done when unchanged modules are skipped on rebuild
2. third-party dependency model: version constraints, lockfile, resolution — done when package/dependency semantics are explicit
3. split interface artifacts from body artifacts — done when interface/body boundaries are clean enough for separate caching
4. workspace and multi-package support — done when workspaces are real
5. package-aware testing tooling — done when tests can target individual packages
6. first authority-budget path at module/package scope — done when the authority-budget path is structurally possible
7. cross-target FFI/ABI validation — done when validation is empirical, not hand-wavy
8. provenance-aware publishing direction — done when the package graph is not heading toward a trust-model redesign

**References:** [artifact-driven-compiler](research/compiler/artifact-driven-compiler.md), [package-model](research/packages-tooling/package-model.md), [package-manager-design](research/packages-tooling/package-manager-design.md), [package-testing-tooling](research/packages-tooling/package-testing-tooling.md)

## 3. Formalization and Proof Expansion (Phase I)

**Status:** not started. Do this after package/artifact boundaries are cleaner.

**Tasks:**
1. broaden the pure Core proof fragment — done when the provable subset covers more than the current narrow pure fragment
2. stabilize the provable subset as an actual target — done when users can know what is and isn't provable
3. source-to-Core and Core-to-proof traceability — done when proof claims trace back to source
4. proof-backed authority reports as real artifacts — done when reports are artifacts, not just a research direction
5. user-program proof workflow, artifact-driven — done when a user can prove a property end-to-end
6. push selected compiler-preservation work where tractable — done when preservation proofs cover the highest-value passes

**References:** [formalization-breakdown](research/proof-evidence/formalization-breakdown.md), [formalization-roi](research/proof-evidence/formalization-roi.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md)

## 4. Adoption and Showcase (Phase K)

**Status:** not started. Only after the package model and the biggest ergonomics gaps are under control.

**Tasks:**
1. define domains where Concrete should be unusually strong — done when signature strengths are written down
2. curate public showcase corpus — done when there are polished examples for each signature domain
3. improve onboarding and example presentation — done when a newcomer can build something in under an hour
4. define stability / experimental surface — done when users know what is stable and what is not
5. sharpen positioning vs neighboring systems languages — done when the pitch is one paragraph, not a lecture

**Demo types, ranked by impact:**
1. "Spot the bug" side-by-side — C/Rust/Concrete, C has a hidden capability leak
2. Live audit of a real dependency — `with()` signatures reveal what code touches
3. Privilege-separated tool end-to-end — hasher can't touch network, reporter can't read files
4. Formal proof demo — correct because proved, not because tested
5. Performance benchmark against C — SHA-256, JSON parsing
6. Capability escalation attack (blocked) — compiler says no
7. Rewrite a 500-line C file — capabilities make security explicit
8. Interactive playground / REPL — highest reach, highest cost
9. Package ecosystem demo — practical stdlib usage
10. Conference talk with storytelling — narrative-driven

**References:** [adoption-strategy](research/workloads/adoption-strategy.md), [showcase-workloads](research/workloads/showcase-workloads.md)

## 5. Project and Operational Maturity (Phase L1)

**Status:** not started. This turns the compiler into a durable reviewable operational system.

**Tasks:**
1. machine-readable reports — done when report output is structured and parseable
2. verified FFI envelopes and reportable FFI boundary facts — done when FFI boundaries are auditable from report output
3. trust bundles and report-first review workflows — done when reviews can be driven by compiler-emitted trust reports
4. semantic query/search over compiler facts — done when you can ask questions about the program and get structured answers
5. compatibility checks and trust-drift diffing — done when version bumps surface semantic/trust changes automatically
6. review-policy gates — done when CI can enforce authority, trust, FFI, and proof-facing policies
7. coverage tooling over tests, reports, and proof artifacts — done when coverage gaps across all three are visible
8. release/compatibility discipline — done when there is a versioning policy and it is enforced
9. editor/LSP baseline and dependency auditing — done when there is basic editor support and dependency audit tooling

**References:** [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), [proof-evidence-artifacts](research/proof-evidence/proof-evidence-artifacts.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [developer-tooling](research/packages-tooling/developer-tooling.md)

## 6. Backend Plurality (Phase L2)

**Status:** not started. Keep explicit and late.

**Tasks:**
1. stabilize SSA as the backend contract — done when SSA is the only interface between front and back end in practice
2. evaluate QBE as first lightweight second backend — done when there is a working QBE path or a clear rejection with reasons
3. cross-backend validation and emitted-code inspection — done when two backends produce equivalent output for the test suite
4. debug-info and codegen maturity — done when debug builds produce usable source-level debugging

**References:** [qbe-backend](research/compiler/qbe-backend.md), [qbe-in-concrete](research/compiler/qbe-in-concrete.md), [mlir-backend-shape](research/compiler/mlir-backend-shape.md), [optimization-policy](research/compiler/optimization-policy.md)

## 7. Concurrency (Phase M)

**Status:** not started. Keep the model explicit, small, and late.

**Tasks:**
1. structured concurrency as semantic center — done when concurrency primitives enforce structured lifetimes
2. OS threads + message passing as base primitive — done when thread + channel programs work end-to-end
3. evented I/O only as later specialized model — done when the async story is explicit and opt-in, not default

**References:** [concurrency](research/stdlib-runtime/concurrency.md), [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md)

## 8. Allocation Profiles (Phase N)

**Status:** not started. Do this after the broader compiler/runtime structure is more stable.

**Tasks:**
1. strengthen `--report alloc` — done when the report accurately attributes every allocation to its source
2. enforceable `NoAlloc` — done when `NoAlloc` functions that allocate fail to compile
3. structural boundedness reports where explainable — done when the compiler can report which functions have bounded allocation
4. `BoundedAlloc(N)` only where structurally explainable — done when bounded allocation is enforced without requiring user annotation on every call

References: [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [arena-allocation](research/stdlib-runtime/arena-allocation.md), [execution-cost](research/stdlib-runtime/execution-cost.md)

## 9. Research and Evidence-Gated Features (Phase O)

**Status:** not started. Keep visible without forcing premature language growth.

Candidates:
1. typestate
2. arena allocation
3. execution boundedness
4. layout reports
5. binary-format DSLs
6. ghost/proof-only syntax
7. hardware capability mapping
8. capability sandbox profiles
9. Miri-style interpreter

References: [high-leverage-systems-ideas](research/meta/high-leverage-systems-ideas.md), [ten-x-improvements](research/meta/ten-x-improvements.md), [typestate](research/language/typestate.md)

---

## Design Constraints

- keep the parser LL(1)
- keep SSA as the only backend boundary
- prefer stable storage for mutable aggregate loop state over phi transport
- avoid parallel semantic lowering paths
- keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
- keep trust, capability, and foreign boundaries explicit and auditable

## Current Risks

- mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
- formalization scope is still narrow
- type-coercion completeness is not proved, only hardened
- the linearity checker is tested heavily but not formally audited

## Longer-Horizon Multipliers

1. proof-backed trust claims
2. stronger audit outputs
3. a smaller trusted computing base
4. a better capability/sandboxing story

Important carry-forwards from earlier phases that are still owned later:
- proof-backed authority reports belong to **Phase I** and later **L1**
- verified FFI envelopes, compatibility checking, trust-drift diffing, and coverage tooling belong to **L1**
- structural boundedness reports belong to **N**
- capability sandbox profiles belong to **O** unless earlier evidence forces them forward

References: [ten-x-improvements](research/meta/ten-x-improvements.md), [capability-sandboxing](research/language/capability-sandboxing.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [ai-assisted-optimization](research/meta/ai-assisted-optimization.md)
