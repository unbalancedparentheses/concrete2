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

This is a reimplementation of the [original Rust-based Concrete compiler](https://github.com/lambdaclass/concrete). For the full language specification, see [The Concrete Programming Language: Systems Programming for Formal Reasoning](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/).

## What Makes Concrete Different

Most languages treat verification as something bolted on after the fact. Concrete inverts this: the language is *designed around* a verified core.

### Pure by default, effects declared

Functions without capability annotations are pure — no side effects, no allocation, no I/O. When a function needs effects, it says so:

```rust
fn transform(data: &List<Row>) -> String {
    // pure: computes a result from its inputs, nothing more
}

fn read_file(path: String) with(File) -> String {
    // declares File capability: can do file I/O
}

fn process(input: String) with(File, Network, Alloc) -> Result<Data, Error> {
    // declares exactly which effects it performs
}

fn main!() {
    // ! is shorthand for with(Std) — all standard capabilities
}
```

Capabilities propagate: if `f` calls `g`, and `g` requires `File`, then `f` must declare `File` too. `grep with(Network)` finds every function that touches the network. Your JSON parser has no capabilities? Then it *provably* can't phone home.

### True linear types, not affine

Rust has affine types: use at most once, silently drop the rest. Concrete has linear types: use **exactly** once. You can't forget a resource.

```rust
fn process_file!() {
    let f = open("data.txt")
    defer destroy(f)           // cleanup is visible in source
    let content = read(&f)
    // destroy(f) runs here because of defer
}
```

If `f` isn't consumed on all paths, the compiler rejects the program. No implicit destructors, no hidden `drop()` calls. Every resource acquisition and release is visible in the source.

```rust
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

### No hidden control flow

When you read Concrete code, what you see is what executes:

- **No implicit function calls.** `a + b` on integers is primitive addition, not `Add::add`
- **No implicit destruction.** The compiler never inserts destructor calls — you write `defer destroy(x)`
- **No implicit allocation.** If it allocates, you see `with(Alloc)` in the signature
- **No invisible error handling.** Errors propagate only where `?` appears

### Explicit allocation

Allocation is a capability. Functions that allocate declare `with(Alloc)`. The call site binds which allocator:

```rust
fn main!() {
    let arena = Arena.new()
    defer arena.deinit()

    let list = create_list<Int>() with(Alloc = arena)
    push(&mut list, 42) with(Alloc = arena)
}
```

Allocation-free code is provably allocation-free.

### Compiler as proof artifact

The compiler is written in Lean 4 so that the core type system can be formally verified. The goal:

1. **Kernel calculus** formalized in Lean with mechanically-checked proofs
2. **Surface language** elaborates into the kernel — if elaboration succeeds, the program is sound
3. **Kernel is versioned separately** — once 1.0, it's frozen. New features must elaborate to existing kernel constructs

What a type-checked program guarantees:
- **Memory safety**: no use-after-free, no double-free, no dangling references
- **Resource safety**: linear values consumed exactly once, no leaks
- **Effect correctness**: declared capabilities match actual effects

These are mechanical guarantees from a proven type system, not conventions.

## Current Status

The compiler currently implements the core surface language (~4,700 lines of Lean 4). All 59 tests pass, and 58 of 59 examples from the [original Rust compiler](https://github.com/lambdaclass/concrete) compile and run.

### What's implemented

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
- **Control flow**: while loops, for loops, if/else, match

### Roadmap

#### Phase 1: Capabilities (effect system)

Every function declares which effects it may perform. No declaration = pure.

```rust
// Pure: no capabilities, no side effects, computes result from inputs
fn add(a: Int, b: Int) -> Int { return a + b; }

// Declares File capability: can do file I/O
fn read_config(path: String) with(File) -> String { ... }

// Multiple capabilities
fn sync_data(url: String) with(File, Network, Alloc) -> Result<Data, Error> { ... }

// ! is sugar for with(Std) — includes File, Network, Clock, Env, Random, Alloc
fn main!() { ... }
```

**Rules:**
- A function without `with()` is pure — it cannot call any function that has `with()`
- If `f` calls `g`, and `g` requires `Network`, then `f` must declare `Network`
- Capabilities propagate monotonically through the call graph
- `Unsafe` capability gates FFI, raw pointer deref, transmute
- Predefined capabilities: `File`, `Network`, `Clock`, `Env`, `Random`, `Alloc`, `Unsafe`, `Std`
- Users cannot define new capabilities

**Implementation:** New `CapSet` type in AST, parsed from `with(...)` clause. Check.lean enforces propagation — if a callee requires caps the caller doesn't have, type error. Codegen is unaffected (capabilities are erased).

#### Phase 2: Explicit resource management (`defer` + `destroy`)

Linear types that hold resources define a destructor. Cleanup is always explicit and visible.

```rust
struct File { handle: FileHandle }

destroy File with(File) {
    close_handle(self.handle)
}

fn process!() {
    let f = open("data.txt")
    defer destroy(f)        // schedules cleanup at scope exit

    let content = read(&f)
    // When scope exits: destroy(f) runs
}
```

**Rules:**
- `defer` schedules a statement to run at scope exit (LIFO order, like Zig/Go)
- `defer destroy(x)` reserves the value: cannot move `x`, cannot destroy again, cannot re-defer
- `destroy(x)` is only valid if the type defines a destructor
- Types without a destructor must be consumed by moving, returning, or destructuring
- `defer` runs on early return and on `?` error propagation
- `Copy` is explicit and opt-in: `type Copy Point { x: Float64, y: Float64 }`
- A `Copy` type cannot have a destructor and cannot contain linear fields

**Implementation:** New `Stmt.defer` in AST. Parser handles `defer <stmt>`. Check.lean tracks deferred values as "reserved" (not movable). Codegen emits deferred statements in reverse order before every `ret` and scope exit.

#### Phase 3: Allocator system

Allocation is a capability with explicit allocator binding at call sites.

```rust
fn create_list<T>() with(Alloc) -> List<T> { ... }

fn main!() {
    let arena = Arena.new()
    defer arena.deinit()

    // Bind allocator at call site
    let list = create_list<Int>() with(Alloc = arena)
    push(&mut list, 42) with(Alloc = arena)
}
```

**Rules:**
- `with(Alloc)` means the function may allocate — which allocator is bound by the caller
- `with(Alloc = expr)` at call site binds a specific allocator
- Allocator binding is lexically scoped and propagates to nested calls
- Stack allocation does not require `Alloc`
- All allocators implement the `Allocator` trait: `alloc`, `free`, `realloc`

**Implementation:** `Alloc` is a special capability. Call expressions get optional allocator binding. Codegen threads the allocator pointer as a hidden parameter to `with(Alloc)` functions.

#### Phase 4: Kernel formalization in Lean 4

Formalize the core calculus as a Lean 4 inductive type and prove key properties.

**Kernel IR:** A small typed lambda calculus with linear types and effects:
- Types: primitives, products (structs), sums (enums), functions with capability sets, references with regions
- Terms: let, application, match, borrow-in-region, destroy
- Typing rules formalized as an inductive relation in Lean

**Proofs:**
- **Progress**: well-typed terms are values or can step
- **Preservation**: stepping preserves types
- **Linearity soundness**: linear values consumed exactly once across all execution paths
- **Effect soundness**: runtime effects are subset of declared capabilities

**Implementation:** New `Concrete/Kernel/` directory with `Syntax.lean`, `Typing.lean`, `Reduction.lean`, `Soundness.lean`. The elaborator (`Check.lean`) produces kernel terms. The kernel checker verifies them independently.

#### Phase 5: Borrow regions

Explicit lexical regions that bound reference lifetimes, simpler than Rust's lifetime annotations.

```rust
borrow f as fref in R {
    // fref has type &[File, R]
    // f is unusable in this block
    let len = length(fref)
}
// f is usable again

// Short form: anonymous region for single expression
let len = length(&f)
```

**Rules:**
- References exist within lexical regions that bound their lifetime
- No lifetime parameters in function signatures — functions are implicitly generic over regions
- While borrowed, the original is unusable
- Multiple immutable borrows allowed; mutable borrows are exclusive
- References cannot escape their region
- Closures cannot capture references that outlive the borrow region

## Quick Example

```rust
struct Point {
    x: Int,
    y: Int
}

impl Point {
    fn sum(&self) -> Int {
        return self.x + self.y;
    }
}

fn main() -> Int {
    let p: Point = Point { x: 10, y: 20 };
    let s: Int = p.sum();
    return s;
}
```

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

The target pipeline (after Phase 4) adds a kernel checkpoint between elaboration and codegen:

```
Surface AST → Elaboration → Kernel IR → Kernel Checker (proven sound in Lean) → Codegen
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs all 59 tests
make clean    # or: lake clean
```

## Usage

```bash
.lake/build/bin/concrete input.con -o output
./output
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
lean_tests/      -- 59 tests (34 positive, 25 negative)
examples/        -- 59 example programs (superset of lambdaclass/concrete examples)
```

## Influences

- **[Austral](https://austral-lang.org/)** — Linear types, capability system, the most direct influence
- **Rust** — Borrowing, traits, `Result<T, E>`, pattern matching
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

## Lean 4 vs Rust Implementation

This is a reimplementation of the [lambdaclass/concrete](https://github.com/lambdaclass/concrete) compiler.

**Lean 4 implementation:**
- ~4,700 lines — the whole compiler fits in 6 files
- Direct textual LLVM IR emission — no MLIR, no complex lowering passes
- Path to formal verification of the type system using Lean's proof system
- Clean pipeline: Lexer -> Parser -> AST -> Check -> Codegen

**Rust implementation:**
- MLIR-based lowering pipeline (production compiler infrastructure)
- More modular architecture designed to scale
- Build system (`Concrete.toml`), standard library, LSP support

## License

[Apache 2.0](/LICENSE)
