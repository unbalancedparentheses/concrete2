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

### JSON Parser

What it proved:

- Concrete’s capability system makes authority boundaries legible at the signature level in a way that is immediately useful in real code
- the ownership model is real enough to shape parser structure, not just to decorate APIs
- the language can already carry a non-trivial recursive-descent parser with pools, modules, `Copy` structs, `Vec` generics, and recursive value construction

What felt strong:

- visible authority plus visible ownership discipline is Concrete’s clearest differentiator
- pure helpers are visibly pure, allocating functions visibly allocate, and effectful output visibly declares capabilities
- the builder-builtin approach is verbose but honest: no hidden allocations, no extra grammar, no disguised effects
- module structure, builtin interception, `Copy` structs, and generic `Vec` support were strong enough to carry a real parser

What felt awkward:

- explicit linear-ownership pressure still forces code reshaping patterns that do not yet feel idiomatic
- `drop_string` pressure remains a real signal: cleanup is honest, but repeated destruction can become easy to forget and mechanically noisy
- `&mut` string-building patterns are workable but repetitive
- the lack of destructuring or non-enum pattern-style binding makes some parser/test code more verbose than it needs to be
- repeated multi-pool argument plumbing becomes noisy without better helper/abstraction patterns

What it implies:

- the central Phase H question is no longer “can Concrete carry real programs?” but “do explicit patterns stabilize into disciplined idioms or sustained verbosity?”
- future fixes should prefer compression patterns over hidden magic:
  - helper APIs
  - cleanup idioms
  - stronger stdlib conventions
  - qualification and abstraction tools that preserve explicitness
- syntax growth should remain the last step, not the first response, unless repeated real-program evidence shows that library and workflow patterns are insufficient

What closed after scoped `defer` landed:

- the JSON parser now uses `defer` throughout and dropped roughly 40 lines of cleanup boilerplate
- the biggest win was `defer cleanup(...)` in `main`, which turned repeated `if err != 0 { cleanup(...); return err; }` blocks into plain early returns
- repeated keyword-matching and output cleanup paths also became smaller and less error-prone
- this is evidence that explicit cleanup can become materially less noisy without hiding ownership or destruction

### JSON Parser Benchmark

What it exposed:

- alloca inside loop bodies grows the stack every iteration (LLVM never frees until function return); with 24 String-sized allocas in `parse_value`, deep recursion hit stack overflow at ~130k iterations
- string literal assignment inside a loop generated invalid IR: `ensureValAsPtr` had no `.strConst` case, producing `store %struct.String @global` instead of materializing the string
- compiling without `-O2` made the benchmark 3.6x slower than necessary: per-character `string_char_at` calls dominate at -O0 but are fully inlined at -O2

What closed:

- Bug 013: alloca hoisting — all allocas now emitted in function entry block via `entryAllocas` field in EmitSSAState
- Bug 014: string literal in loop — `.strConst` case added to `ensureValAsPtr`, routes through `materializeStrConst`
- Bug 015: missing `-O2` — clang invocations now pass `-O2` for both regular and test compilation

What it proved:

- at -O2, Concrete's JSON parser parses 9.3MB in ~40ms, matching or slightly beating Python's `json.loads` (46ms) on the same file
- earlier measurements showing Concrete at 185ms total were benchmark-mode artifacts: 145ms parse at -O0 + 40ms byte-by-byte string construction
- the parser implementation is strong; the optimizer/backend story matters a lot for real workloads
- `string_reserve` pre-allocation dropped the load phase from 40ms to 3ms at -O2 (LLVM inlines the push loop into a near-memcpy)

What was added:

- `string_reserve(&mut String, cap)` builtin across all compiler passes (Intrinsic, BuiltinSigs, Check, Elab, EmitBuiltins)
- `Bytes.to_string()` zero-copy ownership transfer in std/src/bytes.con
- regression tests: alloca hoisting stress, string literal in loop, string_reserve

Benchmark results (9.3MB JSON, warm cache):

| | Load | Parse | Total |
|---|---|---|---|
| Concrete -O0 (old default) | 40ms | 145ms | 185ms |
| Concrete -O2 (new default) | 3ms | 40ms | 43ms |
| Python json.loads | — | 46ms | 46ms |

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

## Standing Phase H Question

For every serious program, ask:

- are explicit authority and ownership patterns becoming stable idioms?
- or are they remaining honest but exhausting ceremony?

That question is now one of the most important evaluation criteria for the phase.
