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

Concrete is a systems programming language designed around a single organizing principle: **every design choice must answer the question, can a machine reason about this?**

The compiler is written entirely in [Lean 4](https://leanprover.github.io/lean4/doc/setup.html), a theorem prover. This is not an implementation detail — it's the point. The goal is a language whose core type system is mechanically verified: proofs of progress, preservation, linearity soundness, and effect soundness, checked by Lean itself.

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

Linear types work today — the compiler rejects programs that forget or reuse resources:

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

Most languages treat verification as something bolted on after the fact. Concrete inverts this: the language is *designed around* a verified core. Here is what a Concrete program will look like when the language is complete:

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

Everything is visible: resource acquisition, cleanup scheduling, error propagation, effect declarations, allocator binding. Nothing happens behind your back.

### Pure by default, effects declared

Functions without capability annotations are pure — no side effects, no allocation, no I/O. When a function needs effects, it declares them with `with()`:

- A function without `with()` is pure — it cannot call any function that has `with()`
- If `f` calls `g`, and `g` requires `Network`, then `f` must declare `Network`
- Capabilities propagate monotonically through the call graph
- `grep with(Network)` finds every function that touches the network
- Your JSON parser has no capabilities? Then it *provably* can't phone home

Predefined capabilities: `File`, `Network`, `Clock`, `Env`, `Random`, `Alloc`, `Unsafe`. `Std` includes all except `Unsafe`. Users cannot define new capabilities.

### True linear types

Concrete has linear types: use **exactly** once. Forgetting a resource is a compile error, not silent cleanup inserted behind your back.

- `defer destroy(x)` schedules cleanup at scope exit (LIFO order, like Zig/Go)
- `defer` reserves the value: cannot move `x` after deferring its destruction
- `destroy(x)` is only valid if the type defines a destructor
- Types without a destructor must be consumed by moving, returning, or destructuring
- `Copy` is explicit and opt-in — a `Copy` type cannot have a destructor and cannot contain linear fields

### No hidden control flow

When you read Concrete code, what you see is what executes:

- **No implicit function calls.** `a + b` on integers is primitive addition, not `Add::add`
- **No implicit destruction.** The compiler never inserts destructor calls — you write `defer destroy(x)`
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
2. **Surface language** elaborates into the kernel — if elaboration succeeds, the program is sound
3. **Kernel is versioned separately** — once 1.0, it's frozen. New features must elaborate to existing kernel constructs

What a type-checked program guarantees:
- **Memory safety**: no use-after-free, no double-free, no dangling references
- **Resource safety**: linear values consumed exactly once, no leaks
- **Effect correctness**: declared capabilities match actual effects

## Why Concrete

Concrete is built for code that must be inspectable, auditable, and eventually mechanically verified.

### Clarity guarantees

| Question | Concrete |
|----------|----------|
| Can you tell if a function allocates? | Yes — `with(Alloc)` in signature |
| Can you tell if a function does I/O? | Yes — `with(File)`, `with(Network)` |
| Can you tell where cleanup happens? | Yes — `defer destroy(x)` is explicit |
| Can you tell if `a + b` calls a function? | Yes — primitive operators are always primitive |
| Can you tell if a value is forgotten? | Yes — linearity makes it a compile error |
| Can you audit unsafe code? | Yes — `grep with(Unsafe)` at the function boundary |

### Critical software

| Need | Concrete |
|------|----------|
| Memory safety proofs | Mechanically verified in Lean 4 |
| "This module can't touch the network" | `grep with(Network)` — provable |
| "This JSON parser can't phone home" | No capabilities = provably pure |
| "No resource leaks" | Compile error if not consumed |
| "Where does this allocate?" | `grep with(Alloc)` — exact list |
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

The compiler implements the core surface language in ~4,700 lines of Lean 4. All 65 tests pass. 58 of 59 legacy examples compile and run in the current implementation.

**`defer`/`destroy`, explicit allocation, borrow regions, closures, FFI safety, MLIR backend, and the kernel formalization are not yet implemented.** See the full [ROADMAP.md](ROADMAP.md) for the implementation plan. What works today:

- **Types**: Int, Uint, i8-i32, u8-u32, f32, f64, Bool, Char, String, arrays `[T; N]`, raw pointers
- **Structs** with field access and mutation
- **Enums** with pattern matching (exhaustiveness checked)
- **Impl blocks** with methods (`&self`, `&mut self`, `self`) and static methods
- **Traits** with static dispatch
- **Generics** on functions, structs, and enums
- **Borrowing**: `&T` (shared) and `&mut T` (exclusive), with borrow checking
- **Linear type system**: structs consumed exactly once, branches must agree
- **Modules** with `pub` visibility and imports
- **Result type** with `?` operator for error propagation
- **Cast expressions** (`as`) between numeric types
- **Capabilities**: `with(File, Network, Alloc)` effect declarations, `!` sugar for Std, capability checking at all call sites
- **Control flow**: while loops, for loops, if/else, match

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full implementation plan with syntax, rules, and implementation details for each phase.

| Phase | Feature | Parallel? |
|-------|---------|-----------|
| **1** | Capabilities + cap polymorphism | — |
| **2** | Closures | — |
| **3** | `defer` + `destroy` + `Copy` | — |
| **4** | `break` / `continue` | Yes, with 1-3 |
| **5** | Allocator system | — |
| **6** | Borrow regions | Yes, with 1-5 |
| **7** | FFI + C interop | Yes, with 2-6 |
| **8** | MLIR backend + optimization | Yes, anytime |
| **9** | Standard library | — |
| **10** | Runtime (C, then Concrete) | — |
| **11** | Kernel formalization + proofs | Yes, anytime |
| **12** | Tooling | Yes, ongoing |

Critical path: **1 → 3 → 5** (capabilities → resource management → allocators). Formalization (Phase 11) and MLIR (Phase 8) can start in parallel at any time.

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
  Type Checker (Concrete/Check.lean) -- types + linearity + borrowing + capabilities
    |
    v
  Code Generator (Concrete/Codegen.lean) -- emits LLVM IR text
    |
    v
  clang -- LLVM IR -> native binary
```

Target pipeline after Phase 8 (MLIR) and Phase 11 (formalization):

```
Surface AST → Elaboration → Kernel IR → Kernel Checker (proven sound) → MLIR Codegen → LLVM → binary
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs all 65 tests
make clean    # or: lake clean
```

## Project Structure

```
Concrete/
  Token.lean     -- Token types
  Lexer.lean     -- Tokenizer
  AST.lean       -- Abstract syntax tree
  Parser.lean    -- LL(1) recursive descent parser
  Check.lean     -- Type checker + linearity checker + borrow checker
  Codegen.lean   -- LLVM IR code generation
Main.lean        -- Entry point
lean_tests/      -- 65 tests (37 positive, 28 negative)
examples/        -- 59 example programs (superset of lambdaclass/concrete examples)
```

## Influences

- **[Austral](https://austral-lang.org/)** — Linear types, capability system, the most direct influence
- **Zig** — Explicit allocator passing, `defer`
- **[Koka](https://koka-lang.github.io/)** / Eff / Frank — Algebraic effect systems
- **Lean 4** — Theorem prover for kernel formalization
- **[Roc](https://www.roc-lang.org/)** — `!` syntax for impure functions
- **Ada/SPARK** — Formal verification in production systems

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
| Implicit conversions | No silent data loss |
| Undefined behavior (safe code) | Kernel semantics fully defined |

## Implementation Snapshot

**Current Lean 4 implementation:**
- ~4,700 lines — the whole compiler fits in 6 files
- Direct textual LLVM IR emission — no MLIR, no complex lowering passes
- Path to formal verification of the type system using Lean's proof system
- Clean pipeline: Lexer -> Parser -> AST -> Check -> Codegen

**Next major build-out:**
- MLIR-based lowering pipeline
- Build system (`Concrete.toml`), standard library, LSP support
- Kernel formalization and proof development in Lean

## License

[Apache 2.0](/LICENSE)
