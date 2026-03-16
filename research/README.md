# Research Notes

Status: exploratory index

This directory contains design notes, open questions, architectural explorations, and long-horizon ideas for Concrete.

These files are exploratory unless they explicitly say otherwise. Once a design becomes a stable project rule or implementation contract, it should move into `docs/`.

## How To Use This Directory

- use `ROADMAP.md` for active project sequencing
- use `docs/` for stable rules and implementation contracts
- use `research/` for design work that is still being explored, sharpened, or staged for later phases

## Priority Key

- `P0` = highest-value current research, directly connected to active or next roadmap phases
- `P1` = important follow-on research, likely to matter in later phases
- `P2` = useful background, optional direction, or long-horizon exploration

## Status Key

- `Open` = still exploratory
- `Adopted` = design influenced implementation, but the note remains useful as background
- `Excluded` = intentionally not in the language surface
- `Process` = decision filter or project rule
- `Research` = broader exploration, not a current design commitment

## Start Here

If you want the highest-leverage current research first:

1. [high-leverage-systems-ideas.md](high-leverage-systems-ideas.md) — consolidated view of six recurring system-level ideas: allocation budgets, arenas, execution boundedness, layout reports, typestate, and authority budgets (`P0`, `Open`)
2. [phase-h-findings.md](phase-h-findings.md) — classified findings from the first real programs, with language vs stdlib vs tooling vs runtime splits (`P0`, `Open`)
3. [text-and-output-design.md](text-and-output-design.md) — formatting, interpolation, builders, and parser-oriented text support after the first Phase H programs (`P0`, `Open`)
4. [runtime-collections.md](runtime-collections.md) — what collection maturity should mean for interpreter/runtime workloads (`P1`, `Open`)
5. [standalone-vs-project-ux.md](standalone-vs-project-ux.md) — smoothing the split between single-file examples and project-based stdlib usage (`P1`, `Open`)
6. [module-qualification.md](module-qualification.md) — qualified access and namespace pressure in larger multi-module programs (`P1`, `Open`)
7. [runtime-execution-pressure.md](runtime-execution-pressure.md) — stack/runtime pressure signals from deep-recursive and runtime-heavy Phase H workloads (`P1`, `Open`)
8. [comparative-program-suite.md](comparative-program-suite.md) — the 20-program cross-language suite for correctness, auditability, and performance comparison against Rust, Zig, and C (`P1`, `Open`)
9. [ten-x-improvements.md](ten-x-improvements.md) — the biggest long-term multipliers for Concrete (`P0`, `Open`)
10. [formalization-roi.md](formalization-roi.md) — what to prove first and why (`P0`, `Open`)
11. [proving-concrete-functions-in-lean.md](proving-concrete-functions-in-lean.md) — how selected Concrete functions could be proved in Lean 4 (`P0`, `Open`)
12. [formalization-breakdown.md](formalization-breakdown.md) — the full formalization effort broken into proof tracks, dependencies, and milestones (`P0`, `Open`)
13. [high-integrity-profile.md](high-integrity-profile.md) — what a stricter high-integrity / provable Concrete profile could be (`P0`, `Open`)
14. [authority-budgets.md](authority-budgets.md) — package/subsystem authority limits and authority-aware dependency policy (`P0`, `Open`)
15. [proof-evidence-artifacts.md](proof-evidence-artifacts.md) — tying reports, artifacts, reproducibility, and later proof references into one evidence story (`P0`, `Open`)
16. [package-model.md](package-model.md) — what the eventual project/package model must decide (`P0`, `Open`)
17. [trust-multipliers.md](trust-multipliers.md) — proof-backed reports, sandbox profiles, authority budgets, FFI envelopes, trust bundles, and showcase workloads (`P0`, `Open`)
18. [artifact-driven-compiler.md](artifact-driven-compiler.md) — stable artifacts, serialization, IDs, traceability, interface/body splits, and the real compiler driver (`P0`, `Open`)
19. [adoption-strategy.md](adoption-strategy.md) — signature domains, showcases, onboarding, stability surface, and positioning for real user pull (`P1`, `Open`)
20. [evidence-review-workflows.md](evidence-review-workflows.md) — evidence bundles, machine-readable reports, trust-drift diffing, and report-first review workflows (`P0`, `Open`)

## Language Decisions

- [builtin-vs-stdlib.md](builtin-vs-stdlib.md) — what belongs in compiler/runtime builtins versus the public stdlib (`P0`, `Open`, partially adopted)
- [capability-sandboxing.md](capability-sandboxing.md) — ways to make `with(...)` better at expressing restricted authority and sandboxing (`P0`, `Open`, partially adopted)
- [high-integrity-profile.md](high-integrity-profile.md) — stricter profile/subset for critical code across runtime, safety, language discipline, and evidence (`P0`, `Open`)
- [high-integrity-examples.md](high-integrity-examples.md) — concrete allowed/restricted examples for the future high-integrity profile (`P0`, `Open`)
- [authority-budgets.md](authority-budgets.md) — package/subsystem authority budgets and dependency policy (`P0`, `Open`)
- [unsafe-structure.md](unsafe-structure.md) — how to make `Unsafe` more inspectable and better contained without complicating the language (`P1`, `Open`, partially adopted)
- [trusted-boundary.md](trusted-boundary.md) — explicit `trusted fn` / `trusted impl` design for containing implementation unsafety (`P1`, `Adopted`)
- [derived-equality-design.md](derived-equality-design.md) — possible derived structural equality for user-defined types (`P2`, `Open`)
- [heap-ownership-design.md](heap-ownership-design.md) — chosen `Heap<T>` ownership model (`P1`, `Adopted`)
- [heap-access-revisited.md](heap-access-revisited.md) — follow-up on heap access syntax and tradeoffs (`P2`, `Open`)
- [external-ll1-checker.md](external-ll1-checker.md) — external grammar + LL(1) checker as a syntax guardrail (`P1`, `Open`)
- [ll1-grammar.md](ll1-grammar.md) — strict LL(1) rule, known parser backtrack sites, and cleanup criteria (`P1`, `Process`)
- [union.md](union.md) — whether unions fit Concrete's design (`P2`, `Open`)

## Excluded By Design

- [no-closures.md](no-closures.md) — why Concrete excludes closures (`P1`, `Excluded`)
- [no-trait-objects.md](no-trait-objects.md) — why Concrete excludes trait objects (`P1`, `Excluded`)

## Standard Library And Runtime Direction

- [stdlib-design.md](stdlib-design.md) — stdlib direction, module priorities, and style rules (`P1`, `Open`, partially adopted)
- [stdlib-api-cleanup.md](stdlib-api-cleanup.md) — cleaning builtin-style names and ownership surprises out of the public stdlib surface (`P1`, `Open`)
- [text-and-output-design.md](text-and-output-design.md) — formatting, interpolation, builders, and parser/text support after first-wave real programs (`P0`, `Open`)
- [runtime-collections.md](runtime-collections.md) — interpreter/runtime-oriented collection maturity, patterns, and API gaps (`P1`, `Open`)
- [arena-allocation.md](arena-allocation.md) — arena/bump allocation as a possible explicit resource model for parser/interpreter-style workloads (`P1`, `Open`)
- [no-std-freestanding.md](no-std-freestanding.md) — future hosted vs freestanding / `no_std` split (`P1`, `Open`)
- [concurrency.md](concurrency.md) — concurrency direction before async-style features (`P1`, `Open`)
- [long-term-concurrency.md](long-term-concurrency.md) — layered long-term concurrency target: structured concurrency over threads first, evented I/O later (`P1`, `Open`)
- [target-platform-policy.md](target-platform-policy.md) — support tiers, ABI promises, and what counts as a supported vs experimental target (`P1`, `Open`)
- [allocation-budgets.md](allocation-budgets.md) — `NoAlloc`, restricted `BoundedAlloc(N)`, and stronger allocation reports (`P0`, `Open`)
- [execution-cost.md](execution-cost.md) — structural cost reports, bounded instruction counts, and WCET direction (`P1`, `Open`)
- [layout-reports.md](layout-reports.md) — stronger layout/ABI audit reports, including padding and enum details (`P1`, `Open`)
- [pre-post-conditions.md](pre-post-conditions.md) — contracts/specification support and why it stays later/optional (`P1`, `Open`)
- [standalone-vs-project-ux.md](standalone-vs-project-ux.md) — what should just work in single-file mode versus the package/project model (`P1`, `Open`)

## Compiler Architecture

- [formalization-roi.md](formalization-roi.md) — best order for proving Core, effects, ownership, and Core→SSA preservation (`P0`, `Open`)
- [proving-concrete-functions-in-lean.md](proving-concrete-functions-in-lean.md) — how Concrete functions could be represented and proved in Lean 4 (`P0`, `Open`)
- [formalization-breakdown.md](formalization-breakdown.md) — the full proof effort split into semantic, language-guarantee, compiler-preservation, and evidence tracks (`P0`, `Open`)
- [proof-evidence-artifacts.md](proof-evidence-artifacts.md) — how reports, artifacts, proofs, and reproducibility could reinforce each other (`P0`, `Open`)
- [trust-multipliers.md](trust-multipliers.md) — how authority, runtime, proof, and evidence work could combine into Concrete-specific differentiators (`P0`, `Open`)
- [evidence-review-workflows.md](evidence-review-workflows.md) — evidence bundles, machine-readable reports, trust-drift diffing, and report-first review workflows (`P0`, `Open`)
- [package-model.md](package-model.md) — package identity, dependency semantics, workspaces, and the boundary to authority-aware dependencies (`P0`, `Open`)
- [artifact-driven-compiler.md](artifact-driven-compiler.md) — what it would take to make the named pipeline artifacts operationally real (`P0`, `Open`)
- [file-summary-frontend.md](file-summary-frontend.md) — summary-based frontend direction and artifact boundaries (`P1`, `Adopted`)
- [mlir-backend-shape.md](mlir-backend-shape.md) — where MLIR should sit if it earns its complexity later (`P1`, `Research`)

## Process And Quality

- [testing-strategy.md](testing-strategy.md) — gaps beyond current suites: fuzzing, property tests, report consistency, and differential testing (`P1`, `Open`)
- [design-filters.md](design-filters.md) — feature-admission checklist and high-leverage design filters (`P1`, `Process`)
- [optimization-policy.md](optimization-policy.md) — explicit optimization goals, non-goals, observability constraints, and regression expectations (`P1`, `Open`)
- [developer-tooling.md](developer-tooling.md) — semantic recovery, editor/LSP baseline, debugging/observability, and project-facing CLI workflow (`P1`, `Open`)
- [comparative-program-suite.md](comparative-program-suite.md) — the real-program comparison portfolio for large-scale pressure testing after the language surface stabilizes (`P1`, `Open`)
- [phase-h-findings.md](phase-h-findings.md) — classified real-program findings so Phase H drives disciplined follow-up instead of ad hoc surface growth (`P0`, `Open`)
- [module-qualification.md](module-qualification.md) — qualified access and namespace pressure in larger programs (`P1`, `Open`)
- [runtime-execution-pressure.md](runtime-execution-pressure.md) — execution-model pressure from deep-recursive/runtime-heavy workloads (`P1`, `Open`)

## Meta And Long-Horizon Direction

- [ten-x-improvements.md](ten-x-improvements.md) — the relatively small set of changes that could dramatically raise Concrete's value (`P0`, `Open`)
- [competitive-gap-analysis.md](competitive-gap-analysis.md) — what other systems languages may still have, which gaps matter, and where Concrete should aim to be stronger instead (`P1`, `Open`)
- [complete-language-system.md](complete-language-system.md) — what still separates a strong language/compiler from a complete language system (`P1`, `Open`)
- [adoption-strategy.md](adoption-strategy.md) — what Concrete needs beyond architecture to become understandable, memorable, and worth trying (`P1`, `Open`)
- [evidence-review-workflows.md](evidence-review-workflows.md) — the clearest route to making Concrete visibly better in audit-heavy practice without adding language cleverness (`P0`, `Open`)
- [showcase-workloads.md](showcase-workloads.md) — real programs Concrete should eventually implement well, including showcase/stress-test targets (`P2`, `Open`)
- [candidate-ideas.md](candidate-ideas.md) — Concrete-specific candidate compiler/language/tooling ideas (`P2`, `Research`)
- [external-ideas.md](external-ideas.md) — useful ideas borrowed from other languages (`P2`, `Research`)
- [trust-multipliers.md](trust-multipliers.md) — the strongest combined roadmap/research differentiators across auditability, proofs, runtime restrictions, and evidence (`P0`, `Open`)

## Placement Rule

- stable rule/reference -> `docs/`
- active plan/sequencing -> `ROADMAP.md`
- landed milestone/history -> `CHANGELOG.md`
- exploratory note -> `research/`

The roadmap should only absorb items from here when they become concrete technical work.
