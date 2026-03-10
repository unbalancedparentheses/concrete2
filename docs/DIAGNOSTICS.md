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

The parser and AST now carry source spans, including range-capable spans, and semantic diagnostics render with source locations.

## Current Strengths

Today the compiler already has:

- structured per-pass error kinds
- span-bearing diagnostics
- native `Except Diagnostics` plumbing through `Check`, `Elab`, `CoreCheck`, and `SSAVerify`
- range-aware rendering support in `Diagnostic`
- hint text on a growing set of semantic diagnostics
- stable rendered messages for the semantic passes
- a shared `Diagnostic` type
- module/function-level multi-error accumulation in `Check` and `Elab`

This means diagnostics are no longer mostly raw strings, and pass ownership is visible in emitted errors.

## Remaining Work

The remaining diagnostics work is now mostly about fidelity and presentation, not basic plumbing.

### 1. Better span/range fidelity

Improve the precision of source reporting:

- range-aware spans
- better postfix/operator-site highlighting
- cleaner attachment of diagnostics to transformed constructs

### 2. Rendering quality

Add richer presentation support:

- secondary labels
- notes
- suggestions
- more consistent multi-line formatting

### 3. Optional later accumulation refinement

Concrete already accumulates across functions/modules in `Check` and `Elab`. Further accumulation work should only happen if it improves real diagnostic quality without making control flow much harder to reason about.

This remains intentionally secondary to span fidelity and rendering quality.

## Current Architectural Rule

Diagnostics work should proceed in this order:

1. improve span/range fidelity
2. improve rendering quality
3. only then consider broader accumulation/refinement

The basic diagnostics plumbing is already in place. Remaining work should avoid reopening that boundary unless there is a clear payoff.

## Current Accumulation Policy

Concrete is no longer purely fail-fast in the semantic pipeline.

Current behavior:

- `Resolve` accumulates diagnostics across shallow/interface and body-level work
- `Check` and `Elab` now accumulate across functions/modules
- there is still no broad semantic recovery inside a single body; accumulation is deliberately coarse-grained

If this changes further later, this document should be the place where the policy and rollout are recorded.
