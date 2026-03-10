# Documentation Guide

This directory holds the stable reference docs for Concrete's implementation and language model.

Use these files as the primary reference once a design has moved out of exploration:

- [ARCHITECTURE.md](ARCHITECTURE.md) — compiler pipeline, artifact flow, pass boundaries, and architecture phase reference
- [PASSES.md](PASSES.md) — pass-by-pass contracts and ownership boundaries
- [LANGUAGE_INVARIANTS.md](LANGUAGE_INVARIANTS.md) — the language rules that must hold across every phase
- [VALUE_MODEL.md](VALUE_MODEL.md) — value, borrow, ownership, and resource-model rules

The `book/` subdirectory is for tutorial-style and user-facing structured documentation.

## How To Read The Docs

- Read [../README.md](../README.md) first for project overview, current status, and build/test instructions.
- Read [../ROADMAP.md](../ROADMAP.md) for active and future work.
- Read [../CHANGELOG.md](../CHANGELOG.md) for completed milestones.
- Use this `docs/` directory for stable reference material, not exploratory design notes.

## Scope Boundary

- `docs/` = stable reference and implementation contracts
- `research/` = exploratory notes, possible future work, and design investigations

If a topic is still being explored or debated, it belongs in `research/` first. Once it becomes a stable project rule or compiler boundary, it should move into `docs/`.
