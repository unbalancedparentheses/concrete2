# Compiler Architecture

Status: stable reference

This document is the architecture/reference companion to [ROADMAP.md](../ROADMAP.md).

Use it for:
- pipeline shape
- pass boundaries
- artifact flow
- architecture work phases (A1-A10)
- invariants and subsystem boundaries

For active priorities and remaining work, see [ROADMAP.md](../ROADMAP.md). For landed milestones, see [CHANGELOG.md](../CHANGELOG.md).

## Current Pipeline

```text
Source -> Parse -> Resolve -> Check -> Elab -> CoreCanonicalize -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA -> clang
```

The old AST backend is gone. The current compiler goes through the full Core -> SSA pipeline, with structured diagnostics across the semantic passes.

Recent architecture-level cleanups worth calling out:

- parser save/restore backtracking sites were removed so the implementation now matches the language's strict LL(1) goal
- compiler-known operations are being identified by internal intrinsic IDs instead of raw string matching
- `trusted fn`, `trusted impl`, and `trusted extern fn` now flow through the normal parser -> Core -> SSA pipeline
- the first planned testing-strategy expansion is complete: parser fuzzing, property tests, trace tests, report consistency tests, and selected differential tests now exercise the pipeline more directly
- stdlib `#[test]` execution now runs through the real compiler path via `concrete std/src/lib.con --test`, and recent parser/lowering/codegen fixes were driven by making that path actually execute the stdlib test corpus

One important remaining cleanup in this area is removing the last string-based semantic dispatch from compiler tables and special-case paths. Ordinary language behavior should not depend on raw function-name matching outside true foreign-symbol boundaries.

## Artifact Flow

The current artifact boundary is explicit in code via `Concrete/Pipeline.lean`:

- `ParsedProgram`
- `SummaryTable`
- `ResolvedProgram`
- `ElaboratedProgram`
- `MonomorphizedProgram`
- `SSAProgram`

The frontend boundary is:

```text
ParsedModule -> FileSummary -> ResolvedImports -> checked/elaborated module -> monomorphized Core -> SSA module
```

`FileSummary` and `ResolvedImports` still carry full impl/trait-impl bodies because imported method checking and elaboration need them. Splitting interface-only and body-bearing artifacts is a future incremental-compilation concern.

## Proof Boundary Placement

If Concrete is going to support Lean-side proofs of selected Concrete functions, the proof boundary should sit **after `CoreCheck` and before `Mono`**.

That is the point where the program has become:

- explicit typed Core
- normalized by `CoreCanonicalize`
- validated by `CoreCheck`

This is the right place because:

- surface sugar is gone
- the main semantic legality checks have already run
- the object is still close to source meaning
- backend-oriented lowering has not started yet

The intended long-term shape is:

```text
Source
  -> Parse
  -> Resolve
  -> Check
  -> Elab
  -> CoreCanonicalize
  -> CoreCheck
  -> ValidatedCore artifact
  -> optional proof-oriented export for selected functions
  -> Mono
  -> Lower
  -> SSA ...
```

This does not require a separate "verification compiler."
The goal is to treat validated Core as the semantic authority and let a proof-oriented view of that artifact serve Lean-side reasoning.

### Proof Architecture Summary

Keep as-is:

- `CoreCheck` is the semantic authority
- validated Core after `CoreCheck` is the main proof boundary
- `Mono` stays after the proof boundary
- SSA stays backend-only territory, mainly for compiler-preservation proofs
- explicit `Unsafe` / `trusted` / FFI boundaries remain visible in the language and reports

Still change:

- make `ValidatedCore` a first-class pipeline artifact
- define `ProofCore` as a restricted view of `ValidatedCore`
- preserve source-to-Core traceability
- later add export support for selected functions
- keep proof scopes staged and explicit

Fine for now:

- no separate verification compiler
- no proof pass in ordinary compilation
- no surface-AST proof target
- no MLIR/backend layer in the proof story yet

Main caution:

- `ProofCore` must not become a second semantic authority

## Pass Definitions

### 1. Parse

**Input:** source text  
**Output:** surface AST with source spans

Lexing, parsing, syntax error reporting. Preserves user-written structure. LL(1), no semantic reasoning.

Does not do:
- type reasoning
- name resolution
- capability or linearity checks

### 2. Resolve

**Input:** surface AST  
**Output:** resolved AST

Resolve imports and modules. Bind identifiers to declarations. Distinguish type names from value names. Resolve trait names, method candidates, impl scopes, `Self`, aliases, and qualified names.

Does not do:
- borrow checking
- linearity
- final typing decisions

This phase answers: `what does each name refer to?`

### 3. Check

**Input:** resolved AST plus imported summary artifacts  
**Output:** checked surface program

Owns the remaining surface-context-dependent work:
- linearity and borrow tracking
- type inference
- cap-polymorphic call resolution
- reserved-name early gate

### 4. Elaborate

**Input:** resolved, checked AST  
**Output:** typed Core IR

This is where surface language ends.

- remove surface sugar (`!`, `?`)
- lower method calls into explicit function/impl dispatch
- normalize pattern matching, borrow-region syntax, struct/enum constructors
- attach concrete types to expressions and bindings

Does not produce:
- unresolved identifiers
- sugar
- multiple representations of the same meaning

This phase answers: `what does the program mean in the language's semantic core?`

### 5. CoreCanonicalize

**Input:** typed Core IR  
**Output:** normalized Core IR

Normalizes Core into a more stable shape before validation.

### 6. CoreCheck

**Input:** typed Core IR  
**Output:** validated Core IR

Owns post-elaboration legality:
- capability enforcement
- operator and condition legality
- match coverage/shape
- return-type checks
- declaration-level trait/FFI/repr checks
- structural control-flow invariants

This is the main post-elaboration semantic authority.

### 7. Monomorphize

**Input:** validated Core IR with generics  
**Output:** monomorphic Core IR

Instantiate generic functions/types. Specialize trait-dispatch calls. Produce concrete copies used by the program.

### 8. Lower

**Input:** monomorphic Core IR  
**Output:** SSA IR

Flatten structured semantics into explicit control flow. Make memory/layout operations explicit. Produce backend-oriented SSA.

### 9. SSA Verify / Cleanup

**Input:** SSA IR  
**Output:** verified and cleaned SSA IR

Validate SSA invariants and perform modest cross-backend cleanup:
- constant folding
- dead code elimination
- CFG cleanup
- trivial phi/copy cleanup

### 10. EmitSSA

**Input:** verified and cleaned SSA IR  
**Output:** LLVM IR text

Pure backend emission over SSA. No re-interpretation of language semantics.

Recent backend cleanups:

- string literals are now extracted and deduplicated in one lowering path instead of via a fragile redundant second lowering pass
- SSA variable maps are restored correctly across `if`/`else` and `while` exits
- trusted pointer arithmetic now verifies and lowers correctly end to end

## Core IR Design

The core IR is a smaller, stricter language — not another AST. Defined in `Concrete/Core.lean`.

Includes:
- literals, locals, calls
- explicit borrows and moves/consumption
- struct/enum construction and field projection
- explicit match, loops, branches
- explicit destroy/defer-lowered cleanup
- explicit heap operations
- capability-bearing calls

Excludes:
- parser sugar (`!`, `?`, inline borrows)
- unresolved identifiers
- multiple ways to express the same meaning
- frontend convenience forms

### Proof-Oriented Core Direction

For proving selected Concrete functions in Lean, the intended direction is **not** to invent a fully separate semantic IR.

Instead:

- validated Core remains the main semantic object
- a future **ProofCore** should be a restricted, proof-oriented view of validated Core

That proof-oriented view should initially target:

- pure functions
- algebraic data
- structured control flow
- explicit calls and recursion

and initially exclude or fence off:

- FFI
- `Unsafe`
- `trusted`
- raw-pointer-heavy operations
- host-environment-dependent effects

This keeps the proof workflow attached to the same architectural boundary the compiler already treats as authoritative.

## Boundary Rules

### Codegen should not know

- whether something came from method-call syntax
- whether `?` was used
- surface borrow syntax details
- `!` sugar, alias syntax, most trait syntax

All of that should be gone before codegen.

### Parser should not know

- whether a borrow is legal
- whether a capability is available
- whether a move is allowed
- trait coherence decisions

It should only know syntax.

### Builtin vs stdlib boundary

| Category | Lives in | Examples |
|----------|----------|----------|
| Syntax features | Parser | `if`, `match`, `fn`, `struct`, `enum` |
| Checker/elaboration intrinsics | Elaborate + Validate | intercepted calls (`alloc`, `free`, `vec_*`, `map_*`), type constructors |
| Runtime/codegen intrinsics | Lower + EmitSSA | memory layout, calling conventions, POSIX wrappers |
| Ordinary library code | `std/` source files | string utilities, I/O wrappers, collection helpers |

The direction of travel is explicit:

- keep the intrinsic/builtin layer small and compiler-facing
- move public polymorphic operations onto stdlib traits + monomorphization where possible (`Numeric::abs`, etc.)
- keep stdlib names coherent even when the underlying runtime hooks remain low-level

## Pass Invariants

Each pass guarantees specific properties about its output:

| Pass | Guarantees |
|------|-----------|
| **Parse** | Syntactically valid AST. LL(1), no ambiguity. |
| **Check** | Types resolve. Linearity holds. Borrows valid. Capabilities propagated. |
| **Elab** | No surface sugar. Every `CExpr` has concrete `Ty`. Method calls desugared to mangled function calls. |
| **CoreCheck** | Types consistent across operators and calls. Core capabilities satisfied. Return types agree after elaboration. Match structure and coverage valid. Declaration-level legality holds. |
| **Lower** | Explicit control flow only. Every block has exactly one terminator. Field indices match struct definitions. Break/continue resolved to branch targets. |

## Architecture Work Phases

### A1: Define Core IR

New file: `Concrete/Core.lean`

Define `CoreTy`, `CoreExpr`, `CoreStmt`, `CoreFn`, `CoreModule`.

**Status:** Done. Core IR exists and is inspectable via `--emit-core`.

### A2: Elaboration Phase

New file: `Concrete/Elab.lean`

Convert resolved AST -> Core IR.

**Status:** Done for the implemented language.

### A3: Resolution Phase

New file: `Concrete/Resolve.lean`

Extract name resolution, module resolution, and symbol binding from `Check.lean` into a dedicated pass.

**Status:** Done. `Resolve.lean` has a shallow phase (`resolveShallow`) and a body phase (`resolveBodies`).

### A3b: Summary-Based Frontend

Introduce an explicit summary layer between parsing and body-level checking.

**Status:** Done enough for the current architecture phase. `FileSummary` and `ResolvedImports` are the current cross-file boundary.

### A4: Core Validation

New file: `Concrete/CoreCheck.lean`

Type check, capability check, and validate legality on Core IR.

**Status:** Done enough. `CoreCheck.lean` is the post-elaboration semantic authority.

### A4b: Core As Semantic Authority

Make the architecture rule explicit:
- surface syntax elaborates away aggressively
- Core is the semantic authority before lowering

**Status:** Done enough for the current architecture phase.

### A5: Codegen on SSA IR

Make code generation consume SSA IR instead of the surface AST.

**Status:** Done. `EmitSSA.lean` is the sole codegen path.

### A6: Structured Diagnostics

Replace string-based errors with typed diagnostic data.

**Status:** Done for all semantic passes. Remaining work is richer spans, notes, and rendering.

### A7: Builtin vs Stdlib Boundary

Write down and enforce a hard rule for what lives in syntax, checker/elaboration, codegen/runtime, vs stdlib.

**Status:** In progress. `IntrinsicId` exists, `abs` has been migrated to stdlib trait dispatch, trusted extern has replaced the old math intrinsic path, and a large batch of I/O / File / Network / Process / Env intrinsics has already moved to stdlib wrappers.

### A8: Monomorphization as Separate Pass

Extract monomorphization into its own explicit pass over Core IR.

**Status:** Done. `Mono.lean` exists and runs before lowering.

### A9: Lower / SSA

Add and stabilize the lowering pass that produces SSA as the backend-oriented IR.

**Status:** Done.

### A9b: SSA Verify / Cleanup

New files: `Concrete/SSAVerify.lean`, `Concrete/SSACleanup.lean`

Validate SSA invariants and perform structural cleanup before codegen.

**Status:** Done.

### A10: Formal Kernel Proofs

Build mechanized proofs over the validated Core IR.

**Status:** Not started.

## Architecture Priority Table

| Priority | Phase | Description | New files | Status |
|----------|-------|-------------|-----------|--------|
| 1 | A1 | Core IR definition | `Concrete/Core.lean` | **DONE** |
| 2 | A2 | Elaboration phase | `Concrete/Elab.lean` | **DONE** |
| 3 | A3 | Resolution phase cleanup | `Concrete/Resolve.lean` | **DONE** |
| 4 | A4 | Core validation | `Concrete/CoreCheck.lean` | **DONE enough** |
| 5 | A5 | Codegen consumes SSA IR | `Concrete/EmitSSA.lean` | **DONE** |
| 6 | A6 | Structured diagnostics | `Concrete/Diagnostic.lean` | **DONE enough** |
| 7 | A7 | Builtin vs stdlib boundary | documentation + migration | Active |
| 8 | A8 | Monomorphization cleanup | `Concrete/Mono.lean` | **DONE** |
| 9 | A9 | SSA / lowering IR | `Concrete/Lower.lean` | **DONE** |
| 10 | A9b | SSA verify / cleanup | `Concrete/SSAVerify.lean`, `Concrete/SSACleanup.lean` | **DONE** |
| 11 | A10 | Formal kernel proofs | `Concrete/Kernel/*.lean` | Not started |

## Internal Semantic Spec Notes

These invariants should stay documented alongside the code:
- what counts as consumption
- what counts as borrowing
- what elaboration removes versus what stays explicit in Core
- what codegen is allowed to assume about verified SSA
- pass input/output contracts

## Why This Structure

This structure gives:
- easier reasoning about each phase in isolation
- easier testing by phase
- easier refactoring
- easier proofs later
- clearer ownership of responsibilities
- less accidental coupling between features

It also makes new features cheaper because you know where they belong:
- syntax feature -> Parse + Elab
- semantic rule -> CoreCheck
- optimization/backend -> Lower + SSA + EmitSSA
- library feature -> `std/` only
