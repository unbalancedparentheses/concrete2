# Concrete Roadmap

This roadmap reflects the rewrite of Concrete in Lean 4. The previous prototype served its purpose. This is a fresh start with a focus on getting a working compiler quickly, then layering on features incrementally.

## Guiding Principles

1. **Start with textual MLIR output.** Emit `.mlir` files as strings, pipe through `mlir-opt` and `mlir-translate`. No MLIR bindings needed upfront. This alone saves months.
2. **Start with a tiny language subset.** Get something compiling to native code in weeks, not months. Add features incrementally.
3. **Use Lean's `partial` and `sorry` liberally.** Don't fight the termination checker. Don't prove anything yet. Just write code that works.
4. **Use [melior](https://github.com/mlir-rs/melior) as a reference** for when we eventually write proper MLIR bindings. Don't design from scratch.
5. **Study [Austral](https://github.com/austral/austral)'s type checker.** It solved linear type checking with a similar philosophy in ~15k lines of OCaml. Translate the approach to Lean.
6. **Skip the runtime.** A language without green threads is still useful. Ship the compiler first, add the runtime later.
7. **Proofs come last.** Implement first, formalize second. The code structure should be proof-ready, but `sorry` is fine for now.
8. **Type check the AST directly.** No separate kernel IR in the compiler. The formal model for proofs is a separate Lean artifact, not a compilation phase.
9. **Keep the type checker modular.** Linearity checking, capability checking, and borrow checking in separate modules. This makes each independently testable and eventually formalizable.

---

## Phase 0: Bootstrap (weeks)

Get a minimal Concrete program compiling to a native binary via textual MLIR.

- [ ] Set up Lean 4 project with Lake
- [ ] Lexer for the Concrete subset (LL(1) tokens)
- [ ] Parser: functions, `let`, `if/else`, `for`, `while`, `return`
- [ ] AST definition as Lean inductive types
- [ ] Primitive types: `Int`, `Uint`, `Bool`, `Float64`
- [ ] Arithmetic and comparison operators
- [ ] Emit textual MLIR (LLVM dialect) as strings
- [ ] Shell out to `mlir-opt` and `mlir-translate` to produce object files
- [ ] Link with system linker to produce binaries
- [ ] First program: fibonacci compiles and runs

**Exit criteria:** `fn main() -> Int { return fib(10) }` compiles to a native binary and prints the result.

---

## Phase 1: Structs and Basic Linear Types (1-2 months)

Add data types and the core linearity discipline.

- [ ] Structs (records) with named fields
- [ ] Struct construction and field access
- [ ] Basic linear type checking: values must be consumed exactly once
- [ ] `destroy()` and `defer` for resource cleanup
- [ ] `Copy` marker for types that escape linearity
- [ ] Move semantics: reject use-after-move
- [ ] Basic error messages for linearity violations
- [ ] String type (linear)
- [ ] `Result<T, E>` and `?` operator
- [ ] Modules with `public`/`private` visibility
- [ ] `import` statements

**Exit criteria:** A program with structs, linear resource management, and `defer destroy(x)` compiles and runs correctly. Use-after-move and unconsumed values are rejected at compile time.

---

## Phase 2: Enums, Pattern Matching, Type Inference (1-2 months)

Complete the algebraic data type story.

- [ ] Enum types (algebraic data types)
- [ ] `match` with exhaustiveness checking
- [ ] Pattern matching respects linearity (linear values in patterns must be consumed)
- [ ] Borrowing in patterns (`&Some(n)`)
- [ ] Local type inference within function bodies
- [ ] Function signatures remain fully annotated
- [ ] `Option<T>` in standard library
- [ ] Array/slice types
- [ ] Basic formatter (canonical output, one way to write it)

**Exit criteria:** Pattern matching over enums works with exhaustiveness and linearity checking. Local type inference reduces annotation burden inside function bodies.

---

## Phase 3: Borrowing and Regions (2-3 months)

Add the borrowing system with lexical regions.

- [ ] Immutable borrows (`&T`)
- [ ] Mutable borrows (`&mut T`)
- [ ] Lexical region checking: references cannot escape their region
- [ ] `borrow x as y in R { ... }` syntax
- [ ] Anonymous borrows for single-expression use (`length(&f)`)
- [ ] Enforce: while borrowed, original is unusable
- [ ] Enforce: mutable borrows are exclusive
- [ ] Enforce: no nested borrows of the same value
- [ ] Interaction between `defer` and borrow scopes
- [ ] Good error messages for borrow violations

**Exit criteria:** Borrowing works with lexical regions. The compiler rejects dangling references, aliased mutable borrows, and borrows that escape their region.

---

## Phase 4: Generics and Traits (2-3 months)

Add parametric and ad-hoc polymorphism.

- [ ] Generic functions (`fn sort<T: Ord>(...)`)
- [ ] Generic types (`type List<T>`)
- [ ] Trait definitions and implementations
- [ ] Receiver modes: `&self`, `&mut self`, `self` (consuming)
- [ ] Trait bounds on generics
- [ ] Linearity-aware generics: `Option<Int>` is `Copy`, `Option<File>` is linear
- [ ] Monomorphization for code generation

**Exit criteria:** Generic data structures and trait-bounded functions compile and run. Linearity is correctly propagated through generic instantiation.

---

## Phase 5: Capabilities (1-2 months)

Add the effect tracking system.

- [ ] Capability annotations: `with(File)`, `with(Network, Alloc)`, etc.
- [ ] `!` suffix desugars to `with(Std)`
- [ ] Monotonic propagation: if callee needs `File`, caller must declare `File`
- [ ] Transitive enforcement across the call graph
- [ ] Pure functions: no capabilities = no effects
- [ ] `Unsafe` capability for FFI, raw pointers, transmute
- [ ] Parametricity: capabilities checked before monomorphization
- [ ] Error messages for missing capabilities
- [ ] Standard capability set: `File`, `Network`, `Alloc`, `Clock`, `Random`, `Env`, `Process`, `Console`

**Exit criteria:** Capability checking works transitively. Pure functions are enforced. `grep with(Network)` finds every function that touches the network.

---

## Phase 6: Allocation and FFI (1-2 months)

Explicit allocator passing and foreign function interface.

- [ ] `with(Alloc)` capability for heap allocation
- [ ] Allocator binding at call sites: `f() with(Alloc = arena)`
- [ ] Lexically scoped allocator propagation
- [ ] `Allocator` trait with `alloc`, `free`, `realloc`
- [ ] Standard allocators: `GeneralPurposeAllocator`, `Arena`, `FixedBufferAllocator`
- [ ] `foreign("symbol")` for C function binding
- [ ] `Address[T]` raw pointer type
- [ ] Safe creation (`address_of`), unsafe usage (gated by `Unsafe`)
- [ ] C-compatible type mapping for FFI signatures

**Exit criteria:** Programs can use explicit allocators, call C functions, and work with raw pointers behind the `Unsafe` capability.

---

## Phase 7: Tooling (ongoing, parallel with above)

- [ ] Package manager (dependency resolution, builds)
- [ ] Linter (enforce conventions)
- [ ] Test runner (built-in `test` blocks)
- [ ] REPL
- [ ] Language server (editor integration)
- [ ] Good compilation error messages (ongoing refinement throughout all phases)
- [ ] Cross-compilation support
- [ ] WebAssembly target
- [ ] C code generation target

---

## Phase 8: MLIR Bindings (when textual MLIR becomes a bottleneck)

Replace string-based MLIR emission with proper bindings.

- [ ] Lean 4 FFI bindings to the MLIR C API
- [ ] Use [melior](https://github.com/mlir-rs/melior) as design reference
- [ ] Core IR: contexts, modules, operations, types, blocks, regions
- [ ] LLVM dialect bindings
- [ ] Pass management
- [ ] Diagnostics integration

**Exit criteria:** The compiler uses the MLIR C API directly instead of emitting text. Faster compilation, better error integration.

---

## Phase 9: Runtime

The runtime handles green threads, preemptive scheduling, message passing, and deterministic replay.

### Phase 9a: Initial Runtime in C

The first runtime is implemented in C to unblock development. This is a systems project, not a compiler project.

- [ ] Green thread implementation (stack allocation, switching)
- [ ] Preemptive scheduler (timer-based preemption via signals)
- [ ] Copy-only message passing between threads
- [ ] Deterministic replay (record inputs, replay execution)
- [ ] Profiling (built-in, low overhead when disabled)
- [ ] Tracing (structured output)
- [ ] Integration with the Concrete compiler (runtime linkage)

**Exit criteria:** Concrete programs can spawn green threads, send messages, and be deterministically replayed.

### Phase 9b: Rewrite Runtime in Concrete

Once the compiler is mature (Phase 6+ complete), rewrite the runtime in Concrete itself using the `Unsafe` capability. This is the ultimate dogfooding — if writing the runtime in Concrete is painful, the language design has a problem.

- [ ] Scheduler logic in Concrete with `Unsafe` for system calls
- [ ] Message passing in Concrete (type-checked, copy-only)
- [ ] Allocator pools for green thread stacks in Concrete
- [ ] Profiling and tracing infrastructure in Concrete
- [ ] Timer management in Concrete via `foreign("sigaction")` etc.
- [ ] Keep only assembly stubs in C/assembly (~20 lines per architecture for stack switching)

**Exit criteria:** The runtime is implemented in Concrete except for architecture-specific assembly stubs. The C runtime is retired.

---

## Phase 10: Formalization (ongoing, parallel)

The formal verification is a separate Lean artifact that lives alongside the compiler. It defines a simplified formal model of Concrete — a small mathematical language used only for proofs, not a compilation phase.

This can start at any point and proceed incrementally.

### Phase 10a: Define the Formal Model

- [ ] Define abstract syntax as Lean inductive types (~15 term constructors, ~10 type constructors)
  - Types: primitives, function types with capability sets, products, sums, references with regions, raw pointers, universal quantification
  - Terms: variables, lambda, application, let, pairs, injections, case analysis, destroy, region introduction, borrow, foreign calls, literals
- [ ] Define typing rules as inductive propositions (`HasType : Ctx → CapSet → Term → Ty → Prop`)
  - Linear context splitting: `Γ = Γ₁.split Γ₂` ensures each linear variable used exactly once
  - Capability propagation: `C' ⊆ C` ensures callee capabilities are subset of caller's
  - Borrow rules: references cannot escape their region
- [ ] Define operational semantics (`Step : Term → Term → Prop`)
  - Small-step reduction rules
  - Beta reduction, let reduction, case reduction, destroy reduction

### Phase 10b: Prove Core Theorems

- [ ] **Progress**: well-typed terms are values or can step — programs don't get stuck
- [ ] **Preservation**: stepping preserves types — evaluation doesn't break type safety
- [ ] **Linearity soundness**: every linear binding is consumed exactly once during evaluation
- [ ] **Effect soundness**: evaluation only performs effects declared in the capability set

### Phase 10c: Connect Formalization to Compiler

- [ ] Property-based testing: generate random terms, type-check with both the compiler and the formalized rules, verify they agree
- [ ] Replace `sorry` in the compiler's type checker with real proofs, one at a time
- [ ] Eventually: type checker returns proof witnesses (`HasType` terms) connecting compilation to verification

### What the formal model does NOT include

These are compiler concerns, not verification concerns:

- Surface syntax sugar (`!`, `defer`, anonymous borrows)
- Traits (elaborated to dictionary passing — extra function arguments in the model)
- Modules and imports (name resolution)
- Type inference (fully resolved before type checking)
- Error messages and error recovery
- Parsing

### How surface features map to the formal model

| Surface feature | Formal model representation |
|----------------|------------------------------|
| `fn foo!()` | Function with `CapSet = Std` |
| `defer destroy(x)` | Rewritten to explicit sequencing with `destroy` at scope exit |
| Traits | Dictionary passing — extra function arguments |
| Generics | Explicit type abstraction (`∀`) and application |
| `match` on enums | `case_` on sum types |
| Records / structs | Product types |
| Anonymous borrows (`&f`) | Named region introduction + borrow |
| Allocator binding `with(Alloc = arena)` | Explicit allocator parameter passing |

---

## Research / Open Questions

These are unresolved and do not block any phase above:

- **Capability polymorphism**: being generic over capability sets (`fn map<C>(...) with(C)`). The theory exists (Koka, Eff, Frank) but adds complexity.
- **Effect handlers**: full algebraic effects for testing and sandboxing. Would enable mocking capabilities for tests.
- **Concurrency model**: structured concurrency, actors, deterministic parallelism. Must preserve linearity and determinism.
- **Module system**: functors, module-level capability restrictions, separate compilation units, visibility beyond public/private.
- **FFI type mapping**: exact integer mappings, struct layout guarantees, calling conventions, nullable pointers, string encoding.
- **Variance**: covariance/contravariance for generic types with linearity. Needs formalization.
- **Macros**: none vs hygienic vs procedural vs comptime. If added, must be capability-tracked and phase-separated.

---

## Summary

| Phase | What | Depends on | Parallel? |
|-------|------|-----------|-----------|
| 0 | Bootstrap (fibonacci compiles) | — | — |
| 1 | Structs + linear types | 0 | — |
| 2 | Enums + pattern matching | 1 | — |
| 3 | Borrowing + regions | 2 | — |
| 4 | Generics + traits | 3 | — |
| 5 | Capabilities | 4 | — |
| 6 | Allocation + FFI | 5 | — |
| 7 | Tooling | 0+ | Yes, ongoing |
| 8 | MLIR bindings | 0+ | When needed |
| 9a | Runtime in C | 6 | — |
| 9b | Runtime in Concrete | 6, 9a | — |
| 10a | Formal model | — | Yes, anytime |
| 10b | Proofs | 10a | Yes, ongoing |
| 10c | Connect proofs to compiler | 6, 10b | — |

The critical path is **0 → 1 → 2 → 3 → 4 → 5 → 6**. Everything else is parallel or triggered by need.
