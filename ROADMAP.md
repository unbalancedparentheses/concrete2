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

The core language, stdlib foundation, report surfaces, and project workflow are real. Phase H proved the language against real programs. The next question is no longer "can Concrete express this?" but "can Concrete demonstrate its thesis-level ideas clearly enough to justify the project?"

## Linear Execution Order

Use this as the current critical path. The numbered sections below are backlog areas and reference inventories. This list is the execution order unless evidence forces a change.

**Priority rule:** work from this list top-to-bottom. Do not start package management, new backends, concurrency, broad proof syntax, source-level contracts, package ecosystems, or showcase polish just because they have their own section below.

**Current guardrails:**
1. finish or consciously set aside the current adversarial-test work before starting another broad test-writing pass
2. add source file / line / span plumbing before rewriting thesis-facing errors; Elm-clear diagnostics need locations and snippets, not just nicer prose
3. keep specs in Lean-attached / artifact-registry form until proof obligations, proof diagnostics, source locations, and stale-proof reporting are usable
4. postpone QBE/Yul/other backend work until proof attachment, evidence artifacts, predictable-profile claims, and the backend trust boundary are trustworthy
5. keep the next implementation small: source locations in `--check predictable` / `--report effects`, then upgrade those errors

1. finish the first thesis demo: predictable packet-decoder core, non-predictable I/O shell, effects/evidence report, proof-backed parser property, adversarial regressions
2. add source locations to thesis-facing diagnostics and reports
3. make predictable-profile failures Elm-clear: recursion, unbounded loops, allocation, blocking, FFI, trusted/host boundary
4. make proof-evidence failures Elm-clear: proved, missing, stale, qualified-identity mismatch, body mismatch, unsupported target, obligation failed
5. add a machine-readable effects/evidence report for the facts already in the human report
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
17. add CI/CD evidence gates: tests, predictable check, stale-proof check, report artifact generation, proof-obligation status, trust-drift check
18. return to stdlib/example polish: split/trim, path decomposition, minimal FFI pressure test
19. only then expand packaging/artifacts, broader formalization, showcase corpus, QBE/backend experiments, concurrency, and long-horizon research

## 1. Real-Program Validation Complete

**Status:** complete enough to stop treating it as the main track.

Phase H did its job: it exposed real-program pressure, forced the linearity and output questions into the open, and produced a focused backlog. Do not reopen it as open-ended exploration.

**Landed during cleanup:**
1. match-as-expression — value-producing `match` for branch-produced values, including linear cases

**Moved forward as a separate polish track:**
1. ~~output cleanup~~ — done: all examples use `print`/`println` variadic builtins, no raw `print_string`/`print_char`/`print_int` in user-facing code
2. `string.split` / `string.trim`
3. path decomposition
4. minimal FFI pressure test
5. runtime/stack findings classification
6. maybe `string ==`

**References:** [phase-h-findings](research/workloads/phase-h-findings.md), [text-and-output-design](research/stdlib-runtime/text-and-output-design.md), [cleanup-ergonomics](research/language/cleanup-ergonomics.md)

## 2. Thesis Validation

**Status:** in progress. This is now the main track. Follow the **Linear Execution Order** above before pulling in work from later phases.

Concrete's deepest claim is the combination of:

1. capability-visible architecture
2. bounded / predictable execution
3. proof-backed evidence tied to the compiler pipeline

This phase exists to test whether those ideas hold up in implementation, reports, and real examples.

**Tasks:**
1. enforceable `NoAlloc` — done when functions outside the allowed allocation profile fail clearly at compile time
2. define the reported operational/trust effect set — done when the compiler has a clear taxonomy and report model for `may_block`, `crosses_ffi`, `uses_trusted`, recursion/call-cycle status, unknown loop bounds, concurrency usage, and allocation class
3. build a unified per-function effects/evidence report — done when one report can show authority, allocation class, recursion status, loop-boundedness status, blocking status, FFI/trusted boundaries, and evidence level together
4. implement boundedness and timing-relevant reports from that model — done when the compiler can surface unknown loop bounds, recursion, blocking operations, FFI timing boundaries, concurrency usage, stack-risk indicators, and other structural sources of execution uncertainty
5. define and enforce a first predictable-execution profile — done when recursion, unknown-bound loops, unrestricted allocation, blocking operations, unrestricted FFI, and disallowed concurrency fail clearly at compile time
6. validate the effect taxonomy in practice — done when the reported operational/trust effects are useful on real examples without collapsing into noise
7. validate failure semantics for restricted profiles — done when the first profile has an explicit answer for abort, assertions, impossible branches, excluded OOM paths, and whether failure paths run bounded cleanup or terminate immediately
8. validate fixed-capacity stdlib viability — done when at least one bounded no-allocation example uses a realistic fixed-capacity or equivalent restricted-data-structure approach cleanly
9. verify no hidden compiler-introduced allocation in analyzed profiles — done when the project can state whether lowering/codegen ever synthesizes allocation beyond user-visible allocation primitives and either forbid it or report it explicitly
10. verify no indirect-call escape in analyzed profiles — done when the project can state whether trait lowering, function values, or any other mechanism can introduce indirect calls that weaken call-graph analysis, and either forbid them in analyzed profiles or report them explicitly
11. define the Concrete-to-Lean proof pipeline — done when the compiler has a clear extraction and traceability story from checked Concrete into Lean-proof artifacts
12. define how specifications attach to Concrete functions — done when one function, one spec, and one theorem can be linked without ambiguity
13. define a useful provable systems subset — done when the project can name a restricted but still meaningful class of no-GC systems functions that fit the proof workflow
14. prove selected user-facing functions and report properties — done when the project can demonstrate end-to-end proof-backed evidence on a meaningful restricted fragment, starting with parser/validator safety properties and selected report-correctness claims
15. define the backend/source trust boundary for evidence claims — done when it is explicit which claims hold at source/report level and where backend assumptions begin, including the point where LLVM/backend timing assumptions begin to dominate
16. validate the analyzable-concurrency stance — done when the project has a concrete answer on whether thesis-level validation remains single-threaded or admits a restricted concurrency subset
17. validate determinism classification for analyzed code — done when the compiler can say whether a function depends on time, randomness, unordered iteration, or other nondeterministic sources that disqualify stronger predictability claims
18. classify cleanup cost on success and failure paths — done when the compiler can report whether `defer`, drop, or other cleanup paths allocate, block, or introduce unbounded work
19. classify host-call-backed operations clearly — done when stdlib/libc/syscall-backed operations are marked for blocking behavior, timing opacity, and trust boundaries rather than being treated as transparent
20. validate proof maintenance cost — done when at least one proof-backed example survives a nontrivial refactor and the project can judge whether proof drift is tolerable
21. prototype semantic diff / trust drift for thesis properties — done when the compiler can show that a change introduced or removed allocation, recursion, FFI, trusted use, broader authority, blocking, or boundedness status
22. prototype package/module-level thesis policies — done when selected modules or packages can be checked against profile-style restrictions such as `NoAlloc`, no FFI, or capability limits
23. prototype machine-readable effects/evidence output — done when at least the thesis-level facts are available as structured output, not only human terminal text
24. move proof/spec/result registration out of hardcoded compiler tables — done when selected proof attachments can be loaded from a reproducible artifact or registry tied to function identity, body fingerprint, and proof result
25. add source locations to reports and checks — done when effects, proof, obligation, fingerprint, predictable-profile, and trust diagnostics point at concrete source files and lines instead of only function names
26. make thesis diagnostics Elm-clear — done when stale proofs, predictable-profile failures, capability escalation, trust-boundary crossings, allocation violations, recursion cycles, and unbounded loops are explained with short labels, source snippets where possible, direct causes, and actionable fixes
27. mark which report claims are reported, enforced, proved, or trusted-assumption-based — done when the evidence level is visible in the unified report
28. add adversarial validation for every thesis claim — done when each major reported, enforced, or proved property has targeted pass cases, fail cases, near-miss cases, misleading cases designed to trick the checker, and regressions from real bugs
29. validate the thesis with flagship bounded and evidence-carrying examples — done when a small set of examples demonstrates capability visibility, predictable execution, proof-backed evidence, policy enforcement, and adversarial hardening together

**Immediate Order Inside Phase 2:**
1. stabilize the first predictable-execution slice with tests and clear per-function diagnostics
2. expose evidence level in the unified report so "reported", "enforced", "proved", and "trusted assumption" are visible distinctions
3. use the packet decoder as the first flagship thesis example: the parsing core should pass the predictable profile while the I/O shell is expected to fail
4. prove one small parser-core property from that example through the Concrete-to-Lean pipeline so the first end-to-end thesis demo is visible and concrete
5. harden each thesis claim with adversarial tests so the demo is not only persuasive when it works, but difficult to fake accidentally
6. upgrade proof/predictability diagnostics before adding more proof syntax — stale proof, body mismatch, blocking, allocation, unbounded loop, recursion, and capability errors should say what happened, why it matters, and what the likely next edit is

**Proof Workflow Sequence:**

Do proof workflow before proof syntax.

1. proof failure diagnostics — done when proof states distinguish `proved`, `proof stale`, `proof missing`, body/fingerprint mismatch, obligation failure, and unsupported proof target
2. inspectable proof obligations — done when a report or artifact can show obligations such as `decode_header_rejects_short`, their status, and their dependencies
3. source-to-ProofCore extraction report — done when users can inspect what checked Concrete semantics were extracted for proof
4. Lean-attached specs first — done when the current proof slice can name the spec/theorem for a Concrete function without changing Concrete source syntax
5. external spec/proof/result registry next — done when specs, proof identities, proof results, fingerprints, obligation names, and trusted assumptions are loaded from a reproducible artifact instead of hardcoded compiler tables
6. optional source-level spec markers later — done only if the Lean-attached/external workflow works and users need small Concrete syntax to point at specs or contracts
7. loop invariants — done when specs and obligations exist and the prover needs user-provided facts to reason through bounded loops
8. ghost code — done only after a proof-backed example needs proof-only state, and the erasure/trust story is explicit
9. effectful-proof boundary model — done when proofs can clearly stop at or model capabilities, FFI, `trusted`, blocking host calls, allocation, and backend assumptions

**References:** [core-thesis](research/thesis-validation/core-thesis.md), [objective-matrix](research/thesis-validation/objective-matrix.md), [thesis-validation](research/thesis-validation/thesis-validation.md), [noalloc-enforcement](research/thesis-validation/noalloc-enforcement.md), [boundedness-reports](research/thesis-validation/boundedness-reports.md), [proof-slice](research/thesis-validation/proof-slice.md), [validation-examples](research/thesis-validation/validation-examples.md), [concrete-to-lean-pipeline](research/proof-evidence/concrete-to-lean-pipeline.md), [spec-attachment](research/proof-evidence/spec-attachment.md), [effectful-proofs](research/proof-evidence/effectful-proofs.md), [provable-systems-subset](research/proof-evidence/provable-systems-subset.md), [provable-properties](research/proof-evidence/provable-properties.md), [predictable-execution](research/predictable-execution/predictable-execution.md), [effect-taxonomy](research/predictable-execution/effect-taxonomy.md), [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [execution-cost](research/stdlib-runtime/execution-cost.md), [backend-traceability](research/compiler/backend-traceability.md), [diagnostic-ux](research/compiler/diagnostic-ux.md), [failure-semantics](research/language/failure-semantics.md), [memory-ub-boundary](research/language/memory-ub-boundary.md), [trusted-code-policy](research/language/trusted-code-policy.md), [interrupt-signal-model](research/language/interrupt-signal-model.md)

## 3. Stdlib and Example Polish Backlog

**Status:** deferred. Do after the current thesis/tooling critical path, except for small example polish that directly improves the thesis demo.

**Tasks:**
1. clean up stdlib output surface so examples stop using builtin-shaped `print_string` / `print_char` — done when stdlib output reads like coherent library code rather than builtin vocabulary
2. `string.split` and `string.trim` — parser examples reimplement split by hand repeatedly; no workaround exists — done when `String` has `split`, `trim`, `trim_left`, `trim_right` methods
3. path decomposition: `parent`, `file_name`, `extension` — path construction exists but decomposition is completely absent — done when `Path` or `PathBuf` has all three methods
4. minimal FFI pressure test — FFI is implemented but has zero small end-to-end validations — done when there is one minimal example that calls C from Concrete with `with(Unsafe)` at the boundary and `trusted` wrappers
5. write a classification of remaining runtime/stack pressure findings into language, runtime, stdlib, or tooling — done when there is a document in `research/` that assigns each finding to exactly one owner
6. string `==` operator only if the examples still justify it — done when `==` and `!=` work on `String` values

**References:** [phase-h-findings](research/workloads/phase-h-findings.md), [text-and-output-design](research/stdlib-runtime/text-and-output-design.md), [cleanup-ergonomics](research/language/cleanup-ergonomics.md)

## 4. Package and Artifact Architecture Backlog

**Status:** deferred. Do after machine-readable thesis reports, external proof/spec/result artifacts, obligation reports, policy gates, and CI evidence gates prove what the artifacts need to carry.

**Tasks:**
1. incremental compilation: serialize pipeline artifacts, cache by source hash, skip unchanged modules — done when unchanged modules are skipped on rebuild
2. split interface artifacts from body artifacts — done when interface/body boundaries are clean enough for separate caching (needed before dependency resolution can be fast)
3. third-party dependency model: version constraints, lockfile, resolution — done when package/dependency semantics are explicit
4. workspace and multi-package support — done when a multi-package project builds and tests from a single root (depends on dependency model)
5. package-aware testing tooling — done when tests can target individual packages (depends on workspaces)
6. cross-target FFI/ABI validation — done when validation is empirical, not hand-wavy (depends on package boundaries being real)
7. first authority-budget path at module/package scope — done when the authority-budget path is structurally possible (depends on package graph)
8. package manifest parsing and version-constraint support — done when the toolchain can parse its own manifest format and version constraints without ad hoc logic
9. provenance-aware publishing direction — done when the package graph is not heading toward a trust-model redesign (design-only, no implementation yet)

**References:** [artifact-driven-compiler](research/compiler/artifact-driven-compiler.md), [package-model](research/packages-tooling/package-model.md), [package-manager-design](research/packages-tooling/package-manager-design.md), [package-testing-tooling](research/packages-tooling/package-testing-tooling.md)

## 5. Formalization and Proof Expansion Backlog

**Status:** staged. Selected proof workflow work is on the linear path now. Broad proof expansion, source-level spec syntax, loop invariants, ghost code, and compiler-preservation proofs stay later.

**Tasks:**
1. broaden the pure Core proof fragment — done when the provable subset covers more than the current narrow pure fragment
2. stabilize the provable subset as an actual target — done when users can know what is and isn't provable
3. source-to-Core and Core-to-proof traceability — done when proof claims trace back to source
4. inspectable proof-obligation / verification-condition pipeline — done when generated obligations are artifacts with names, dependencies, statuses, and links to source/extracted Core
5. spec-location progression — done when the workflow explicitly supports Lean-attached specs first, external spec/proof/result artifacts next, and source-level spec markers only after that proves useful
6. proof failure diagnostics and proof UX — done when users can understand missing proofs, stale proofs, body mismatches, obligation failures, and unsupported proof targets without reading compiler internals
7. proof-backed authority reports as real artifacts — done when reports are artifacts, not just a research direction
8. user-program proof workflow, artifact-driven — done when a user can prove a property end-to-end
9. push selected compiler-preservation work where tractable — done when preservation proofs cover the highest-value passes
10. evaluate loop invariants and ghost code only after specs/obligations are real — done when at least one proof-backed example justifies proof-only source constructs and their erasure story is explicit

**References:** [formalization-breakdown](research/proof-evidence/formalization-breakdown.md), [formalization-roi](research/proof-evidence/formalization-roi.md), [proving-concrete-functions-in-lean](research/proof-evidence/proving-concrete-functions-in-lean.md), [proof-addon-architecture](research/proof-evidence/proof-addon-architecture.md), [proof-ux-and-verification-influences](research/proof-evidence/proof-ux-and-verification-influences.md)

## 6. Adoption and Showcase Backlog

**Status:** deferred. The packet-decoder thesis demo and one attacker-style thesis demo are on the linear path now. Broader showcase/adoption polish waits until proof/predictability/artifact workflow is credible.

The showcase corpus should deliberately rebalance away from mostly text-heavy examples and toward binary parsing, ownership-heavy structures, capability-separated tools, FFI boundaries, and no-allocation-friendly systems code.

**Tasks:**
1. define domains where Concrete should be unusually strong — done when signature strengths are written down
2. curate public showcase corpus — done when there are polished examples for each signature domain
3. improve onboarding and example presentation — done when a newcomer can build something in under an hour
4. define stability / experimental surface — done when users know what is stable and what is not
5. sharpen positioning vs neighboring systems languages — done when the pitch is one paragraph, not a lecture
6. build one attacker-style thesis demo — done when a malicious or accidental refactor introduces authority, allocation, recursion, blocking, FFI, trust, or proof drift, and Concrete catches it with report/policy/proof evidence

**Examples to build (ranked by what they prove about the language):**
1. Packet parser — binary protocol decoding with capability-controlled I/O, shows `with()` separation between parser and network
2. ELF inspector — structured binary parsing with `#[repr(C)]`, `packed`, raw pointers; no `Unsafe` in user code
3. FFI showcase — C library interop (e.g., zlib or sqlite) with `with(Unsafe)` at the boundary and `trusted` wrappers
4. Ownership-heavy data structure — linked list or tree using `Heap<T>`, linear ownership, and deterministic cleanup
5. Privilege-separated tool — hasher can't touch network, reporter can't read files (capability demo)
6. No-alloc example — fixed-buffer state machine or ring buffer (depends on Phase 8 allocation-profile work being far enough along)

**Presentation formats (ranked by reach):**
1. Live audit of a real dependency — `with()` signatures reveal what code touches
2. Capability escalation attack (blocked) — compiler says no
3. Formal proof demo — correct because proved, not because tested
4. "Spot the bug" side-by-side — C/Rust/Concrete, C has a hidden capability leak
5. Performance benchmark against C — SHA-256, JSON parsing
6. Interactive playground / REPL — highest reach, highest cost
7. Package ecosystem demo — practical stdlib usage
8. Conference talk with storytelling — narrative-driven

**References:** [adoption-strategy](research/workloads/adoption-strategy.md), [showcase-workloads](research/workloads/showcase-workloads.md)

## 7. Project and Operational Maturity Backlog

**Status:** staged. Machine-readable thesis reports, source-location-rich evidence, review gates, and CI evidence gates are on the linear path now. Broader editor/dependency/release maturity waits.

**Tasks:**
1. machine-readable reports — done when report output is structured and parseable
2. verified FFI envelopes and reportable FFI boundary facts — done when FFI boundaries are auditable from report output
3. trust bundles and report-first review workflows — done when reviews can be driven by compiler-emitted trust reports
4. semantic query/search over compiler facts — done when you can ask questions about the program and get structured answers
5. compatibility checks and trust-drift diffing — done when version bumps surface semantic/trust changes automatically
6. review-policy gates — done when CI can enforce authority, trust, FFI, and proof-facing policies
7. CI/CD evidence gates — done when tests, `--check predictable`, stale-proof checks, proof-obligation status, report generation, and semantic/trust drift checks can be enforced in a noninteractive CI job
8. source-location-rich report artifacts — done when machine-readable reports include source spans, qualified identities, fingerprints, artifact IDs, proof/spec/obligation IDs, evidence level, and trust assumptions
9. agent-readable performance research packet — done when a noninteractive command can emit the current benchmark table, perf-baseline delta, compile-time summary, binary/IR-size summary, allocation/effects facts, hot examples, known perf hypotheses, and safety/evidence guardrails for an optimization agent
10. coverage tooling over tests, reports, and proof artifacts — done when coverage gaps across all three are visible
11. editor/LSP baseline — done when there is basic editor support with go-to-definition and diagnostics
12. dependency auditing — done when dependencies can be audited for capability and trust properties
13. release/compatibility discipline — done when there is a versioning policy and it is enforced

**References:** [evidence-review-workflows](research/proof-evidence/evidence-review-workflows.md), [proof-evidence-artifacts](research/proof-evidence/proof-evidence-artifacts.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [developer-tooling](research/packages-tooling/developer-tooling.md), [diagnostic-ux](research/compiler/diagnostic-ux.md), [performance-research-packets](research/compiler/performance-research-packets.md)

## 8. Backend Plurality Backlog

**Status:** deferred. Do not start a second backend until proof attachment, evidence artifacts, predictable-profile claims, and the backend trust boundary are clearer.

**Tasks:**
1. stabilize SSA as the backend contract — done when SSA is the only interface between front and back end in practice
2. evaluate QBE as first lightweight second backend — done when there is a working QBE path or a clear rejection with reasons
3. cross-backend validation and emitted-code inspection — done when two backends produce equivalent output for the test suite
4. debug-info and codegen maturity — done when debug builds produce usable source-level debugging

**References:** [qbe-backend](research/compiler/qbe-backend.md), [qbe-in-concrete](research/compiler/qbe-in-concrete.md), [mlir-backend-shape](research/compiler/mlir-backend-shape.md), [optimization-policy](research/compiler/optimization-policy.md)

## 9. Concurrency Backlog

**Status:** deferred. Keep thesis-level predictability single-thread-friendly until the analyzable concurrency stance is explicit.

**Tasks:**
1. structured concurrency as semantic center — done when concurrency primitives enforce structured lifetimes
2. OS threads + message passing as base primitive — done when thread + channel programs work end-to-end; likely first pieces are `std.thread`, typed channels, and only the minimum `std.sync` surface needed to make that model usable
3. evented I/O only as later specialized model — done when the async story is explicit and opt-in, not default

**References:** [concurrency](research/stdlib-runtime/concurrency.md), [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md)

## 10. Allocation Profiles Backlog

**Status:** staged. Fixed-capacity usefulness and the smallest bounded-capacity path are on the linear path now. General allocation-profile design stays later.

**Tasks:**
1. strengthen `--report alloc` — done when the report accurately attributes every allocation to its source
2. enforceable `NoAlloc` — done when `NoAlloc` functions that allocate fail to compile
3. structural boundedness reports where explainable — done when the compiler can report which functions have bounded allocation
4. `BoundedAlloc(N)` only where structurally explainable — done when bounded allocation is enforced without requiring user annotation on every call
5. bounded-capacity types (`Vec<T, 64>`, `String<256>`, fixed-capacity ring buffers) — done when the type system can express capacity limits at the type level, bridging the gap between NoAlloc (too restrictive for most embedded/systems work) and unrestricted allocation (no bounds); this is the usability path for the predictable-execution profile

**References:** [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [arena-allocation](research/stdlib-runtime/arena-allocation.md), [execution-cost](research/stdlib-runtime/execution-cost.md)

## 11. Predictable Execution Backlog

**Status:** staged. Stack-depth reporting and classification of host calls, cleanup, determinism, failure, memory/UB, and backend assumptions are on the linear path now. Exact timing/WCET remains later.

**Tasks:**
1. define a restricted analyzable execution profile — done when there is a documented profile covering a recursion ban, no unrestricted allocation, loop-bound rules, concurrency limits, blocking-operation limits, and FFI boundaries
2. define the reported operational/trust effect set — done when the compiler has a clear taxonomy and report model for `may_block`, `crosses_ffi`, `uses_trusted`, recursion/call-cycle status, unknown loop bounds, concurrency usage, and allocation class
3. implement boundedness and timing-relevant reports from that model — done when the compiler can surface unknown loop bounds, recursion, blocking operations, FFI timing boundaries, concurrency usage, stack-risk indicators, and other sources of execution uncertainty
4. make the restricted profile enforceable where structurally possible — done when recursion, unknown-bound loops, unrestricted allocation, blocking operations, unrestricted FFI, indirect-call escapes, and disallowed concurrency fail clearly at compile time rather than relying on convention
5. define the concurrency subset for analyzable systems — done when the project has a clear answer on whether this profile is single-threaded first or uses a Ravenscar-style restricted concurrency model
6. define a tighter bounded-allocation subprofile — done when there is a clear next-stage profile for structurally bounded allocation rather than only a binary no-allocation rule
7. compute max stack depth from call graph and frame layout — done when the compiler can report a concrete worst-case stack depth for any function in the predictable profile (structurally computable once recursion is banned: max call-chain depth × max frame size from the call graph + layout info already available)
8. define stack-boundedness reporting and enforcement boundaries — done when the project can say which stack facts are source-level structural claims and which require backend/target measurement
9. verify there are no hidden compiler-introduced allocations in the restricted profile — done when the compiler can state whether any lowering or backend-introduced helper path allocates and either ban it from the profile or surface it explicitly
10. define the backend and target assumptions — done when it is explicit what can be claimed at the source/compiler level versus what requires target-specific timing models, including the LLVM timing trust boundary
11. define failure-path boundedness rules for the profile — done when the project can say whether abort is immediate, whether `defer` or cleanup runs on failure, and what boundedness guarantees hold on the failure path
12. define arithmetic overflow behavior as a profile-level choice — done when the predictable profile can require trapping arithmetic (no silent corruption, bounded failure path), the performance path can allow wrapping (zero-cost, deterministic), and the effects report surfaces which mode each function uses
13. define the memory / UB model for predictable and proof-backed subsets — done when raw pointer validity, aliasing expectations, OOB behavior, uninitialized memory, integer casts, overflow, abort, trusted operations, and impossible branches are classified as checked, reported, trusted, excluded, or formally modeled
14. validate the model with bounded examples — done when there are small examples such as a fixed-buffer parser, bounded-state controller, or ring buffer that fit the profile cleanly

**References:** [predictable-execution](research/predictable-execution/predictable-execution.md), [effect-taxonomy](research/predictable-execution/effect-taxonomy.md), [allocation-budgets](research/stdlib-runtime/allocation-budgets.md), [execution-cost](research/stdlib-runtime/execution-cost.md), [concurrency](research/stdlib-runtime/concurrency.md), [long-term-concurrency](research/stdlib-runtime/long-term-concurrency.md), [backend-traceability](research/compiler/backend-traceability.md), [failure-semantics](research/language/failure-semantics.md), [memory-ub-boundary](research/language/memory-ub-boundary.md), [trusted-code-policy](research/language/trusted-code-policy.md), [interrupt-signal-model](research/language/interrupt-signal-model.md)

## 12. Research and Evidence-Gated Feature Backlog

**Status:** not started. Keep visible without forcing premature language growth.

**Candidates:**
1. typestate
2. arena allocation
3. target-specific timing models
4. exact WCET / runtime models
5. exact stack-size analysis across optimized machine code
6. cache / pipeline behavior modeling
7. layout reports
8. binary-format DSLs
9. ghost/proof-only syntax
10. hardware capability mapping
11. capability sandbox profiles
12. Miri-style interpreter

**References:** [high-leverage-systems-ideas](research/meta/high-leverage-systems-ideas.md), [ten-x-improvements](research/meta/ten-x-improvements.md), [typestate](research/language/typestate.md)

---

## Design Constraints

1. keep the parser LL(1)
2. keep SSA as the only backend boundary
3. prefer stable storage for mutable aggregate loop state over phi transport
4. avoid parallel semantic lowering paths
5. keep builtins minimal and implementation-shaped; keep stdlib clean and user-facing
6. keep trust, capability, and foreign boundaries explicit and auditable
7. make serious errors and report failures explain themselves: a user should know the violated rule, the source location, the reason it matters, and one plausible next action

## Current Risks

1. mutable aggregate lowering can still be too backend-sensitive if promoted storage is incomplete
2. formalization scope is still narrow
3. type-coercion completeness is not proved, only hardened
4. the linearity checker is tested heavily but not formally audited

## Longer-Horizon Multipliers

1. proof-backed trust claims
2. stronger audit outputs
3. a smaller trusted computing base
4. a better capability/sandboxing story

**References:** [ten-x-improvements](research/meta/ten-x-improvements.md), [capability-sandboxing](research/language/capability-sandboxing.md), [trust-multipliers](research/proof-evidence/trust-multipliers.md), [ai-assisted-optimization](research/meta/ai-assisted-optimization.md)
