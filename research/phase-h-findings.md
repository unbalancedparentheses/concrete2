# Phase H Findings

Status: open findings ledger

This note records what real programs exposed during Phase H and classifies each issue before it turns into roadmap or language work.

The goal is to prevent three failure modes:

- treating every workaround as a language-design problem
- treating every ergonomics issue as syntax debt
- letting real-program findings disappear into commit history

## Classification

Each finding should be tagged as one or more of:

- `language`
- `stdlib/runtime`
- `tooling/workflow`
- `backend/performance`
- `formalization impact`

## First-Wave Programs

### Policy Engine

What it exposed:

- enum fields inside structs originally panicked layout
- standalone examples needed an always-available print path
- string-heavy output wanted a better append path than repeated `string_concat`

What closed:

- Bug 005: enum-in-struct layout
- Bug 007: standalone print builtins
- Bug 011: in-place string building

What remains:

- formatting/interpolation
- qualified module access pressure in larger multi-module code

### MAL Interpreter

What it exposed:

- parser-heavy code needed substring extraction
- loop-carried string building needed mutation-oriented helpers
- standalone benchmarking wanted an always-available timing path
- interpreter runtimes want stronger collection/data-structure support
- deep recursion raises runtime/stack questions beyond pure language surface

What closed:

- Bug 010: substring extraction
- Bug 011: in-place string building
- Bug 012: standalone timing

What remains:

- runtime-oriented collection maturity
- standalone vs project workflow friction
- runtime/stack pressure clarity

## Current Open Findings

### Formatting / interpolation

- Class: `stdlib/runtime`, possibly `language`
- Why it matters: real programs need readable output, logs, diagnostics, and message assembly
- Current state: manual string building remains too verbose

### Qualified module access

- Class: `language`, `tooling/workflow`
- Why it matters: larger programs should not depend on renaming to avoid collisions
- Current state: no `Module.function()`-style access path

### Destructuring let

- Class: `language`
- Why it matters: parser/runtime code wants clearer binding of paired results
- Current state: still an open surface question, not a confirmed must-add

### Runtime-oriented collections

- Class: `stdlib/runtime`
- Why it matters: interpreters, analyzers, and schedulers want maps, nested mutable structures, and clearer frame-friendly patterns
- Current state: existing collection surface is usable but thin for this workload

### Standalone vs project UX

- Class: `tooling/workflow`
- Why it matters: examples and benchmarks should not need awkward scaffolding to reach common stdlib utilities
- Current state: improved by builtins, but still a visible split

### Runtime / stack pressure

- Class: `backend/performance`, `stdlib/runtime`
- Why it matters: deep-recursive workloads expose execution-model limits that should be understood before later runtime/concurrency work
- Current state: observed in MAL benchmarks, still not classified into final ownership

## Rule

Before any new surface change is adopted from a Phase H finding:

1. classify the issue
2. decide whether it belongs in language, stdlib, tooling, or runtime
3. write the narrowest design that solves the real problem
4. record why library/workflow fixes are insufficient if syntax is being proposed
