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

1. [ten-x-improvements.md](ten-x-improvements.md) — the biggest long-term multipliers for Concrete (`P0`, `Open`)
2. [formalization-roi.md](formalization-roi.md) — what to prove first and why (`P0`, `Open`)
3. [proving-concrete-functions-in-lean.md](proving-concrete-functions-in-lean.md) — how selected Concrete functions could be proved in Lean 4 (`P0`, `Open`)
4. [high-integrity-profile.md](high-integrity-profile.md) — what a stricter high-integrity / provable Concrete profile could be (`P0`, `Open`)
5. [authority-budgets.md](authority-budgets.md) — package/subsystem authority limits and authority-aware dependency policy (`P0`, `Open`)
6. [proof-evidence-artifacts.md](proof-evidence-artifacts.md) — tying reports, artifacts, reproducibility, and later proof references into one evidence story (`P0`, `Open`)
7. [package-model.md](package-model.md) — what the eventual project/package model must decide (`P0`, `Open`)
8. [trust-multipliers.md](trust-multipliers.md) — proof-backed reports, sandbox profiles, authority budgets, FFI envelopes, trust bundles, and showcase workloads (`P0`, `Open`)

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
- [no-std-freestanding.md](no-std-freestanding.md) — future hosted vs freestanding / `no_std` split (`P1`, `Open`)
- [concurrency.md](concurrency.md) — concurrency direction before async-style features (`P1`, `Open`)
- [execution-cost.md](execution-cost.md) — structural cost reports, bounded instruction counts, and WCET direction (`P1`, `Open`)
- [pre-post-conditions.md](pre-post-conditions.md) — contracts/specification support and why it stays later/optional (`P1`, `Open`)

## Compiler Architecture

- [formalization-roi.md](formalization-roi.md) — best order for proving Core, effects, ownership, and Core→SSA preservation (`P0`, `Open`)
- [proving-concrete-functions-in-lean.md](proving-concrete-functions-in-lean.md) — how Concrete functions could be represented and proved in Lean 4 (`P0`, `Open`)
- [proof-evidence-artifacts.md](proof-evidence-artifacts.md) — how reports, artifacts, proofs, and reproducibility could reinforce each other (`P0`, `Open`)
- [trust-multipliers.md](trust-multipliers.md) — how authority, runtime, proof, and evidence work could combine into Concrete-specific differentiators (`P0`, `Open`)
- [package-model.md](package-model.md) — package identity, dependency semantics, workspaces, and the boundary to authority-aware dependencies (`P0`, `Open`)
- [file-summary-frontend.md](file-summary-frontend.md) — summary-based frontend direction and artifact boundaries (`P1`, `Adopted`)
- [mlir-backend-shape.md](mlir-backend-shape.md) — where MLIR should sit if it earns its complexity later (`P1`, `Research`)

## Process And Quality

- [testing-strategy.md](testing-strategy.md) — gaps beyond current suites: fuzzing, property tests, report consistency, and differential testing (`P1`, `Open`)
- [design-filters.md](design-filters.md) — feature-admission checklist and high-leverage design filters (`P1`, `Process`)

## Meta And Long-Horizon Direction

- [ten-x-improvements.md](ten-x-improvements.md) — the relatively small set of changes that could dramatically raise Concrete's value (`P0`, `Open`)
- [competitive-gap-analysis.md](competitive-gap-analysis.md) — what other systems languages may still have, which gaps matter, and where Concrete should aim to be stronger instead (`P1`, `Open`)
- [complete-language-system.md](complete-language-system.md) — what still separates a strong language/compiler from a complete language system (`P1`, `Open`)
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
