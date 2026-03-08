<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![CI](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml/badge.svg)](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml)
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

Concrete is a systems programming language designed around a single organizing principle: **every design choice must answer the question, can a machine reason about this?** All code is explicit, machine-verifiable, LL(1)-parseable, with no hidden control flow.

The compiler is written in [Lean 4](https://leanprover.github.io/lean4/doc/setup.html), a theorem prover. The goal is a language whose core type system is mechanically verified: proofs of progress, preservation, linearity soundness, and effect soundness, checked by Lean itself.

**No other language combines all four: linear types, a capability-based effect system, a compiler written in a theorem prover, and a design optimized for machine-generated code.**

For the full language specification, see [The Concrete Programming Language: Systems Programming for Formal Reasoning](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/).

## Try It Now

```
struct Point { x: Int, y: Int }

impl Point {
    fn sum(&self) -> Int {
        return self.x + self.y;
    }
}

fn main() -> Int {
    let p: Point = Point { x: 10, y: 20 };
    let s: Int = p.sum();
    return s;  // => 30
}
```

```bash
make build
.lake/build/bin/concrete input.con -o output && ./output
```

Linear types work today. The compiler rejects programs that forget or reuse resources:

```
struct Resource { value: Int }

fn consume(r: Resource) -> Int {
    return r.value;
}

fn main() -> Int {
    let r: Resource = Resource { value: 42 };
    let v: Int = consume(r);  // r is consumed here
    // Using r again: compile error "linear variable 'r' used after move"
    // Forgetting to use r: compile error "linear variable 'r' was never consumed"
    return v;
}
```

## The Vision

Concrete is designed around a verified core. Here is what a Concrete program will look like when the language is complete:

```
module Main

import FileSystem.{open, read, write}
import Parse.{parse_csv}

// Pure: no capabilities, computes result from inputs
fn transform(data: &List<Row>) -> String {
    ...
}

// Declares exactly which effects it performs
fn process_file(input: String, output: String) with(File, Alloc) -> Result<Unit, Error> {
    let in_file = open(input)?
    defer destroy(in_file)             // cleanup visible in source, runs at scope exit

    let content = read(&in_file)
    let data = parse_csv(content)?
    let result = transform(&data)

    let out_file = open(output)?
    defer destroy(out_file)

    write(&mut out_file, result)
    Ok(())
}

fn main!() {                           // ! is sugar for with(Std)
    let arena = Arena.new()
    defer arena.deinit()

    match process_file("in.csv", "out.txt") with(Alloc = arena) {
        Ok(()) => println("Done"),
        Err(e) => println("Error: " + e.message())
    }
}
```

Resource acquisition, cleanup, error propagation, effect declarations, and allocator binding are all visible in the source.

### Pure by default, effects declared

Functions without capability annotations are pure. No side effects, no allocation, no I/O. When a function needs effects, it declares them with `with()`:

- A function without `with()` is pure. It cannot call any function that has `with()`
- If `f` calls `g`, and `g` requires `Network`, then `f` must declare `Network`
- Capabilities propagate monotonically through the call graph
- `grep with(Network)` finds every function that touches the network
- Your JSON parser has no capabilities? Then it *provably* can't phone home

Predefined capabilities: `File`, `Network`, `Console`, `Env`, `Process`, `Alloc`, `Unsafe`. `Std` includes all except `Unsafe`. Users cannot define new capabilities.

### Linear types

Concrete has linear types: use **exactly** once. Forgetting a resource is a compile error, not silent cleanup.

- `defer destroy(x)` schedules cleanup at scope exit, LIFO order (like Zig/Go)
- `defer` reserves the value: cannot move `x` after deferring its destruction
- `destroy(x)` is only valid if the type defines a destructor
- Types without a destructor must be consumed by moving, returning, or destructuring
- `Copy` is explicit and opt-in. A `Copy` type cannot have a destructor and cannot contain linear fields

### No hidden control flow

When you read Concrete code, what you see is what executes:

- **No implicit function calls.** `a + b` on integers is primitive addition, not `Add::add`
- **No implicit destruction.** The compiler never inserts destructor calls. You write `defer destroy(x)`
- **No implicit allocation.** If it allocates, you see `with(Alloc)` in the signature
- **No invisible error handling.** Errors propagate only where `?` appears

### Explicit allocation

Allocation is a capability with explicit allocator binding at call sites:

- `with(Alloc)` in a function signature means it may allocate
- `with(Alloc = arena)` at the call site binds a specific allocator
- Stack allocation does not require `Alloc`
- Allocation-free code is provably allocation-free

### Compiler as proof artifact

The compiler is in Lean 4 so the core type system can be formally verified:

1. **Kernel calculus** formalized in Lean with mechanically-checked proofs
2. **Surface language** elaborates into the kernel. If elaboration succeeds, the program is sound
3. **Kernel is versioned separately.** Once 1.0, it's frozen. New features must elaborate to existing kernel constructs

What a type-checked program guarantees:
- **Memory safety**: no use-after-free, no double-free, no dangling references
- **Resource safety**: linear values consumed exactly once, no leaks
- **Effect correctness**: declared capabilities match actual effects

## Why Concrete

Concrete is built for code that must be inspectable and mechanically verified.

### Clarity guarantees

| Question | Concrete |
|----------|----------|
| Can you tell if a function allocates? | Yes.`with(Alloc)` in signature |
| Can you tell if a function does I/O? | Yes.`with(File)`, `with(Network)` |
| Can you tell where cleanup happens? | Yes.`defer destroy(x)` is explicit |
| Can you tell if `a + b` calls a function? | Yes.primitive operators are always primitive |
| Can you tell if a value is forgotten? | Yes.linearity makes it a compile error |
| Can you audit unsafe code? | Yes.`grep with(Unsafe)` at the function boundary |

### Critical software

| Need | Concrete |
|------|----------|
| Memory safety proofs | Mechanically verified in Lean 4 |
| "This module can't touch the network" | `grep with(Network)`, provable |
| "This JSON parser can't phone home" | No capabilities = provably pure |
| "No resource leaks" | Compile error if not consumed |
| "Where does this allocate?" | `grep with(Alloc)`, exact list |
| Deterministic resource ordering | Explicit `defer` in LIFO order |
| Ecosystem / libraries | Early stage |
| Compiler maturity | Research stage |

### LLM-friendly design

| LLM task | Concrete |
|----------|----------|
| Generate correct code | Explicit effects, explicit cleanup, LL(1) grammar |
| Read/audit generated code | What you see is what executes |
| Find all I/O in a codebase | `grep with(File)` or `grep with(Network)` |
| Find all allocations | `grep with(Alloc)` |
| Verify no resource leaks | Compiler-enforced linearity |
| Verify security boundaries | Capabilities propagate through call graph |
| Fix compilation errors | One error at a time, explicit cause |

## Current Status

The compiler implements the core surface language and the new internal IR pipeline in Lean 4. All 201 tests pass.

**MLIR backend, kernel formalization, and the runtime are not yet implemented.** The compiler now has Core IR, elaboration, Core validation, and SSA lowering, but the legacy AST-based codegen path is still the authoritative compilation path. Backend unification onto SSA is still in progress. See the full [ROADMAP.md](ROADMAP.md) for the implementation plan. What works today:

- **Types**: Int, Uint, i8-i32, u8-u32, f32, f64, Bool, Char, String, arrays `[T; N]`, raw pointers
- **Structs** with field access, mutation, and `Heap<T>` fields
- **Enums** with pattern matching (exhaustiveness checked), built-in `Option<T>` and `Result<T, E>`
- **Impl blocks** with methods (`&self`, `&mut self`, `self`), static methods, and `Self` keyword
- **Traits** with monomorphized static dispatch (no vtables), signature checking, and trait bounds (`<T: Trait1 + Trait2>`)
- **Generics** on functions, structs, and enums with monomorphization
- **Borrowing**: `&T` (shared) and `&mut T` (exclusive), with borrow checking and named regions
- **Linear type system**: structs consumed exactly once, branches must agree, `defer`/`destroy`/`Copy`
- **Heap allocation**: `alloc`/`free`, `Heap<T>` with `->` field access, `*heap_ptr` dereference, `HeapArray<T>`
- **Modules** with `pub` visibility, imports, multi-file resolution, circular import detection
- **Result type** with `?` operator for error propagation
- **Cast expressions** (`as`) between numeric types
- **Capabilities**: `with(File, Network, Alloc, Console, Env, Process, Unsafe)` effect declarations, `!` sugar, capability polymorphism
- **Control flow**: while (including as expression), for, if/else, match, break/continue with labeled loops
- **Function pointers**: first-class values, `Copy` semantics, no closures (explicit design choice)
- **Bitwise operators**: `&`, `|`, `^`, `<<`, `>>`, `~` with hex/binary/octal literals
- **FFI**: `extern fn` declarations with `Unsafe` capability gating
- **Compiler pipeline**: Core IR (`--emit-core`), elaboration, SSA lowering (`--emit-ssa`)
- **Standard library builtins**:
  - **Strings**: `string_length`, `string_concat`, `string_slice`, `string_char_at`, `string_contains`, `string_eq`, `string_trim`, `drop_string`
  - **Conversions**: `int_to_string`, `string_to_int`, `bool_to_string`, `float_to_string`
  - **I/O**: `print_int`, `print_bool`, `print_string`, `print_char`, `eprint_string`, `read_line` (require Console)
  - **File**: `read_file`, `write_file` (require File)
  - **System**: `get_env` (requires Env), `exit_process` (requires Process)

## Near-Term Design Priorities

The current surface language is intentionally conservative. The highest-value design additions after the architecture work are:

- **`newtype`** for nominal zero-cost wrappers over existing representations
- **Explicit representation/layout control** for ABI-sensitive low-level code (`repr(C)`, alignment, packed layout)
- **A sharper `unsafe` model** that clearly states which invariants move from the compiler to the programmer
- **A more explicit value/reference model** so pass-by-value, borrows, raw pointers, and heap ownership stay operationally obvious

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full implementation plan with syntax, rules, and implementation details for each phase.

| Phase | Feature | Status |
|-------|---------|--------|
| **1** | Capabilities + cap polymorphism | Done |
| **2** | Function pointers (closures removed by design) | Done |
| **3** | `defer` + `destroy` + `Copy` | Done |
| **4** | `break` / `continue` / while-as-expression / labeled loops | Done |
| **5** | Allocator system (`Heap<T>`, `->`, `*heap_ptr`) | Done |
| **6** | Borrow regions | Done |
| **7** | FFI + C interop (Unsafe gating) | Done |
| **7b** | Monomorphized trait dispatch + trait bounds | Done |
| **7c** | Heap dereference + `Option<T>` + `Result<T,E>` | Done |
| **8** | Standard library builtins (strings, I/O, conversions, env) | Done |
| **9** | Bitwise operators + hex/bin/oct literals | Done |
| **10** | `Self` keyword + multi-file modules | Done |
| **11** | MLIR backend + optimization | Not started |
| **12** | Kernel formalization + proofs | Not started |
| **13** | Tooling | Not started |
| **14** | Runtime (C, then Concrete) | Not started |

Next critical path: **backend unification onto SSA + migration out of `Check.lean`** so the new IR pipeline becomes the semantic and backend source of truth. After that: optimization, a real `Resolve` pass, and kernel formalization.

### What fits the philosophy and what does not

Every feature must answer: **can a machine reason about this?**

| Feature | Fits? | Why |
|---------|-------|-----|
| Monomorphized trait dispatch | Yes | Compile-time specialization, all code paths known statically |
| Function pointers (no closures) | Yes | Bare code addresses, no hidden captures, no implicit allocation |
| `Option<T>` / `Result<T,E>` | Yes | Stated replacement for Null/exceptions, just enums |
| FFI with `Unsafe` capability | Yes | Foreign calls explicitly gated, `grep with(Unsafe)` finds them all |
| String/IO builtins via capabilities | Yes | Pure string ops need no capabilities; I/O requires Console/File |
| `Vec<T>` with explicit `Alloc` | Yes | Library type, every allocation visible via `with(Alloc)` |
| General iterator protocol | **No** | Hidden `next()` calls violate "no implicit function calls" |
| Closures | **No** | Hidden captures are implicit allocation and implicit data flow |
| Trait objects / dynamic dispatch | **No** | Function target not statically known, violates "all code paths known at compile time" |
| Operator overloading | **No** | Explicitly rejected: "`a + b` on integers is primitive addition, not `Add::add`" |

## Compilation Pipeline

```
Source (.con)
    |
    v
  Lexer (Concrete/Lexer.lean)
    |
    v
  Parser (Concrete/Parser.lean) -- LL(1) recursive descent
    |
    v
  AST (Concrete/AST.lean)
    |
    v
  Check.lean -- current frontend checker / resolver
    |
    v
  Elab.lean -- surface AST -> Core IR
    |
    v
  CoreCheck.lean -- Core validation
    |
    v
  Lower.lean -- Core IR -> SSA IR
    |
    v
  Codegen.lean -- current LLVM codegen (legacy path still authoritative)
    |
    v
  clang -- LLVM IR -> native binary
```

Target pipeline:

```
Surface AST → Resolve → Elaborate → CoreCanonicalize → CoreCheck → Monomorphize → Lower → SSAVerify → SSACleanup → SSA Codegen → LLVM/MLIR backend → binary
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs all 201 tests
make clean    # or: lake clean
```

## Project Structure

```
Concrete/
  Token.lean     -- Token types
  Lexer.lean     -- Tokenizer
  AST.lean       -- Abstract syntax tree
  Parser.lean    -- LL(1) recursive descent parser
  Check.lean     -- Current frontend checker / resolver
  Core.lean      -- Core IR
  Elab.lean      -- Surface AST -> Core IR
  CoreCheck.lean -- Core validation
  Lower.lean     -- Core IR -> SSA IR
  SSA.lean       -- SSA IR
  Codegen.lean   -- LLVM IR code generation
Main.lean        -- Entry point
lean_tests/      -- 201 tests
examples/        -- 62 example programs
```

## Influences

- **[Austral](https://austral-lang.org/)**: linear types, capability system, the most direct influence
- **Zig**: explicit allocator passing, `defer`
- **[Koka](https://koka-lang.github.io/)** / Eff / Frank: algebraic effect systems
- **Lean 4**: theorem prover for kernel formalization
- **[Roc](https://www.roc-lang.org/)**: `!` syntax for impure functions
- **Ada/SPARK**: formal verification in production systems

## Anti-Features

Things Concrete deliberately does not have:

| Missing | Why |
|---------|-----|
| Garbage collection | Predictable latency, explicit resource management |
| Hidden control flow | Auditability, debuggability |
| Hidden allocation | Performance visibility, allocator control |
| Interior mutability | Simple reasoning, verification tractability |
| Reflection / eval | All code paths known at compile time |
| Global mutable state | Effect tracking, reproducibility |
| Variable shadowing | Clarity, fewer subtle bugs |
| Null | Type safety via `Option<T>` |
| Exceptions | Errors as values, explicit propagation |
| Closures | Not supported by design |
| Implicit conversions | No silent data loss |
| Undefined behavior (safe code) | Kernel semantics fully defined |

## Implementation Snapshot

**Current Lean 4 implementation:**
- ~7,500 lines, the whole compiler fits in 6 files
- Direct textual LLVM IR emission, no MLIR, no complex lowering passes
- Path to formal verification of the type system using Lean's proof system
- Clean pipeline: Lexer -> Parser -> AST -> Check -> Codegen

**Next steps:**
- MLIR-based lowering pipeline for optimization
- Kernel formalization and proof development in Lean
- Generic data structures: `Vec<T>`, `HashMap<K,V>`
- Networking capabilities

## License

[Apache 2.0](/LICENSE)
