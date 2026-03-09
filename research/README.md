# Research Notes

This directory contains design notes, open questions, and architectural explorations for Concrete.

## Language Decisions

- [derived-equality-design.md](derived-equality-design.md) — possible derived structural equality for user-defined types
- [heap-ownership-design.md](heap-ownership-design.md) — chosen `Heap<T>` ownership model
- [heap-access-revisited.md](heap-access-revisited.md) — follow-up on heap access syntax and tradeoffs
- [no-closures.md](no-closures.md) — why Concrete excludes closures
- [no-trait-objects.md](no-trait-objects.md) — why Concrete excludes trait objects
- [union.md](union.md) — whether unions fit Concrete's design

## Standard Library

- [stdlib-design.md](stdlib-design.md) — stdlib direction and module priorities
- [pre-post-conditions.md](pre-post-conditions.md) — design space around contracts/specification support

## Compiler Architecture

- [file-summary-frontend.md](file-summary-frontend.md) — summary-based frontend direction
- [mlir-backend-shape.md](mlir-backend-shape.md) — where an MLIR backend should sit in the pipeline

## Meta / Planning

- [design-filters.md](design-filters.md) — feature-admission checklist and high-leverage design filters
- [candidate-ideas.md](candidate-ideas.md) — Concrete-specific candidate compiler/language/tooling ideas
- [external-ideas.md](external-ideas.md) — useful ideas borrowed from other languages

## Status Conventions

Research notes generally fall into one of these buckets:

- **Decided** — a direction has been chosen
- **Open** — still exploratory
- **Process guideline** — a filter or project rule rather than a direct feature

The roadmap should only absorb items from here when they become concrete technical work.
