# Research Notes

This directory contains design notes, open questions, and architectural explorations for Concrete.

These files are exploratory unless they explicitly say otherwise. Once a design becomes a stable project rule or implementation contract, it should move into `docs/`.

## Language Decisions

Status key:
- `Decided` = direction chosen
- `Open` = still exploratory
- `Process` = decision filter or project rule
- `Adopted` = design influenced implementation, but the note remains useful as background

- [derived-equality-design.md](derived-equality-design.md) — possible derived structural equality for user-defined types (`Open`)
- [heap-ownership-design.md](heap-ownership-design.md) — chosen `Heap<T>` ownership model (`Adopted`)
- [heap-access-revisited.md](heap-access-revisited.md) — follow-up on heap access syntax and tradeoffs (`Open`)
- [no-closures.md](no-closures.md) — why Concrete excludes closures (`Decided`)
- [no-trait-objects.md](no-trait-objects.md) — why Concrete excludes trait objects (`Decided`)
- [union.md](union.md) — whether unions fit Concrete's design (`Open`)

## Standard Library

- [stdlib-design.md](stdlib-design.md) — stdlib direction and module priorities (`Open`, partially adopted as ordering guidance)
- [pre-post-conditions.md](pre-post-conditions.md) — design space around contracts/specification support (`Open`)
- [concurrency.md](concurrency.md) — concurrency direction before async-style features (`Open`)

## Compiler Architecture

- [file-summary-frontend.md](file-summary-frontend.md) — summary-based frontend direction (`Adopted`)
- [mlir-backend-shape.md](mlir-backend-shape.md) — where an MLIR backend should sit in the pipeline (`Research`)

## Meta / Planning

- [design-filters.md](design-filters.md) — feature-admission checklist and high-leverage design filters (`Process`)
- [candidate-ideas.md](candidate-ideas.md) — Concrete-specific candidate compiler/language/tooling ideas (`Research`)
- [external-ideas.md](external-ideas.md) — useful ideas borrowed from other languages (`Research`)

The roadmap should only absorb items from here when they become concrete technical work.
