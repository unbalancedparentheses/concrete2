# Diagnostics

Status: stable reference

This document describes Concrete's diagnostics model and the remaining diagnostics work.

For pass ownership, see [PASSES.md](PASSES.md). For active priorities, see [../ROADMAP.md](../ROADMAP.md).

## Current Model

Concrete has structured error kinds across the semantic pipeline:

- `ResolveError`
- `CheckError`
- `ElabError`
- `CoreCheckError`
- `SSAVerifyError`

The parser and AST now carry source spans, and semantic diagnostics render with source locations.

## Current Strengths

Today the compiler already has:

- structured per-pass error kinds
- span-bearing diagnostics
- stable rendered messages for the semantic passes
- a shared `Diagnostic` type

This means diagnostics are no longer mostly raw strings, and pass ownership is visible in emitted errors.

## Remaining Work

The next diagnostics work is intentionally staged:

### 1. Native diagnostics plumbing

Move more of the compiler to return `Except Diagnostics` natively and remove ad hoc string-to-diagnostic bridging.

This should happen before broader behavior changes.

### 2. Better span/range fidelity

Improve the precision of source reporting:

- range-aware spans
- better postfix/operator-site highlighting
- cleaner attachment of diagnostics to transformed constructs

### 3. Rendering quality

Add richer presentation support:

- secondary labels
- notes
- suggestions
- more consistent multi-line formatting

### 4. Optional later accumulation

Only after the plumbing and rendering model are stable should the compiler consider multi-error accumulation in `Check` / `Elab`.

That is intentionally deferred because it is a larger control-flow change, not just a formatting upgrade.

## Current Architectural Rule

Diagnostics work should proceed in this order:

1. native diagnostics plumbing
2. better span/range fidelity
3. better rendering
4. only then consider multi-error accumulation

This preserves architectural clarity and avoids mixing plumbing changes with behavioral changes.

## First-Error Policy

The main semantic pipeline is still fail-fast today.

That is documented in [LANGUAGE_INVARIANTS.md](LANGUAGE_INVARIANTS.md) as part of the current implementation model:

- first error stops compilation
- no broad semantic recovery
- no multi-error accumulation in the main path yet

If that changes later, this document should become the place where the policy and rollout are recorded.
