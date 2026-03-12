# Research Notes

Status: exploratory index

This directory contains design notes, open questions, and architectural explorations for Concrete.

These files are exploratory unless they explicitly say otherwise. Once a design becomes a stable project rule or implementation contract, it should move into `docs/`.

## Language Decisions

Status key:
- `Open` = still exploratory
- `Adopted` = design influenced implementation, but the note remains useful as background
- `Excluded` = intentionally not in the language surface
- `Process` = decision filter or project rule

- [builtin-vs-stdlib.md](builtin-vs-stdlib.md) — what belongs in compiler/runtime builtins vs the user-facing stdlib (`Open`, partially adopted)
- [capability-sandboxing.md](capability-sandboxing.md) — ways to make `with(...)` better at expressing restricted authority and sandboxing (`Open`, partially adopted by the trusted/capability split)
- [derived-equality-design.md](derived-equality-design.md) — possible derived structural equality for user-defined types (`Open`)
- [heap-ownership-design.md](heap-ownership-design.md) — chosen `Heap<T>` ownership model (`Adopted`)
- [heap-access-revisited.md](heap-access-revisited.md) — follow-up on heap access syntax and tradeoffs (`Open`)
- [external-ll1-checker.md](external-ll1-checker.md) — external grammar + Python LL(1) checker as a CI guardrail for future syntax changes (`Open`)
- [ll1-grammar.md](ll1-grammar.md) — strict LL(1) grammar rule, known parser backtrack sites, and the cleanup criteria for claiming full LL(1) (`Process`)
- [trusted-boundary.md](trusted-boundary.md) — explicit `trusted fn` / `trusted impl` design for containing implementation unsafety (`Adopted`)
- [unsafe-structure.md](unsafe-structure.md) — how to make `Unsafe` more inspectable and better contained without complicating the language (`Open`, partially adopted by the trusted split)
- [union.md](union.md) — whether unions fit Concrete's design (`Open`)

## Excluded by Design

- [no-closures.md](no-closures.md) — why Concrete excludes closures (`Excluded`)
- [no-trait-objects.md](no-trait-objects.md) — why Concrete excludes trait objects (`Excluded`)

## Standard Library

- [stdlib-design.md](stdlib-design.md) — stdlib direction and module priorities (`Open`, partially adopted as ordering guidance)
- [stdlib-api-cleanup.md](stdlib-api-cleanup.md) — cleaning builtin-style names and ownership surprises out of the public stdlib surface (`Open`)
- [no-std-freestanding.md](no-std-freestanding.md) — how a future hosted vs freestanding / `no_std` split could work in Concrete (`Open`)
- [pre-post-conditions.md](pre-post-conditions.md) — design space around contracts/specification support (`Open`)
- [concurrency.md](concurrency.md) — concurrency direction before async-style features (`Open`)

## Runtime And Scheduling

- [execution-cost.md](execution-cost.md) — static execution cost analysis: structural reports, bounded instruction counts, and WCET (`Open`)

## Process And Quality

- [testing-strategy.md](testing-strategy.md) — gaps beyond current end-to-end/module tests: fuzzing, property tests, report consistency, and differential testing (`Open`)

## Compiler Architecture

- [file-summary-frontend.md](file-summary-frontend.md) — summary-based frontend direction (`Adopted`)
- [formalization-roi.md](formalization-roi.md) — highest-return-on-investment order for proving Core, effects, ownership, and Core→SSA preservation (`Open`)
- [proving-concrete-functions-in-lean.md](proving-concrete-functions-in-lean.md) — how Concrete functions could eventually be represented and proved in Lean, and what subset should be targeted first (`Open`)
- [mlir-backend-shape.md](mlir-backend-shape.md) — where an MLIR backend should sit in the pipeline (`Research`)

## Meta / Planning

- [design-filters.md](design-filters.md) — feature-admission checklist and high-leverage design filters (`Process`)
- [candidate-ideas.md](candidate-ideas.md) — Concrete-specific candidate compiler/language/tooling ideas (`Research`)
- [competitive-gap-analysis.md](competitive-gap-analysis.md) — what other systems languages may still have, which gaps matter, and where Concrete should aim to be stronger instead (`Open`)
- [complete-language-system.md](complete-language-system.md) — what still separates a strong language/compiler from a complete language system (`Open`)
- [ten-x-improvements.md](ten-x-improvements.md) — the relatively small set of changes that could dramatically raise Concrete's value (`Open`)
- [external-ideas.md](external-ideas.md) — useful ideas borrowed from other languages (`Research`)

The roadmap should only absorb items from here when they become concrete technical work.

## Placement Rule

- stable rule/reference -> `docs/`
- active plan/sequencing -> `ROADMAP.md`
- landed milestone/history -> `CHANGELOG.md`
- exploratory note -> `research/`
