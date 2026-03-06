<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

There's a tension at the heart of systems programming. We want languages expressive enough to build complex systems, yet simple enough to reason about with confidence. We want performance without sacrificing safety. We want the freedom to write low-level code and the guarantees that come from formal verification.

Concrete is an attempt to resolve these tensions through commitment to a single organizing principle: **every design choice must answer the question, can a machine reason about this?**

## On This Specification

This document describes what we're building, not what we've finished building. The formal verification in Lean is ongoing work. Until that verification is complete, this specification likely contains mistakes, ambiguities, and internal contradictions.

We state this not as an apology but as a feature of our approach. Most language specifications accumulate contradictions silently over years, edge cases where the spec says one thing and the implementation does another, or where two parts of the spec conflict in ways nobody noticed. These contradictions become load-bearing bugs that can never be fixed without breaking existing code.

By pairing this specification with a formal verification effort in Lean 4, we force contradictions into the open. When we formalize a typing rule in Lean, the proof assistant will reject inconsistencies. Features that seem reasonable on paper will turn out to be unsound, and we'll have to redesign them. This is the point. We'd rather discover that our linearity rules have a hole *before* a million lines of code depend on the broken behavior.

The specification and the formalization will co-evolve. As we prove properties in Lean, we'll update this document. As we write this document, we'll discover what needs proving. The goal is convergence: eventually, this specification will be a human-readable projection of a machine-checked artifact.

## The Core Idea

Most languages treat verification as something bolted on after the fact. You write code, then maybe you write tests, maybe you run a linter, maybe you bring in a theorem prover for critical sections. The language itself remains agnostic about provability.

Concrete inverts this relationship. The language is *designed around* provable guarantees. The type system enforces memory safety, resource safety, and effect correctness. A separate formalization in Lean 4 proves these guarantees sound: mechanically-checked proofs of progress, preservation, linearity soundness, and effect soundness.

### What "Correct" Means

When we say a type-checked program is "correct by construction," we mean correct with respect to specific properties:

- **Memory safety**: no use-after-free, no double-free, no dangling references
- **Resource safety**: linear values consumed exactly once, no leaks
- **Effect correctness**: declared capabilities match actual effects

We do not guarantee termination. Recursive functions may diverge. We do not guarantee liveness or deadlock freedom. These properties are outside the current verification scope. The formalization proves progress (well-typed programs don't get stuck) and preservation (types are maintained during evaluation), which together yield memory and resource safety, not total correctness.

### The Trust Boundary

The typing rules and their properties are mechanically checked in a separate Lean formalization. What remains trusted: the Lean proof checker itself, the correspondence between the formalization and the compiler's type checker, and the code generator (typed AST to machine code).

The formalization and the compiler converge over time through three levels of trust:

1. **Informal correspondence** (initial): the compiler's type checker implements the same rules as the formalization. The gap is real but small if both codebases are kept clean.
2. **Property-based testing**: random term generation, type-checked by both the compiler and the formalized rules, verifying they agree.
3. **Proof witnesses** (eventual goal): the compiler's type checker returns proof terms — not just "yes this type-checks" but a mechanically verifiable `HasType` proof. At this level, the formalization is directly connected to compilation.

## Design Principles

From this kernel-centric design, six principles follow:

1. **Pure by default** — Functions without capability annotations are pure: no side effects, no allocation
2. **Explicit capabilities** — All effects tracked in function signatures
3. **Linear by default** — Values consumed exactly once unless marked `Copy`
4. **No hidden control flow** — All function calls, cleanup, and allocation visible in source
5. **Fits in your head** — Small enough for one person to fully understand
6. **LL(1) grammar** — Parseable with single token lookahead, no ambiguity

## The Compilation Pipeline

```
Source Code (.concrete)
       ↓
   Lexer/Parser (LL(1) recursive descent)
       ↓
   AST
       ↓
   Type Checking (directly on the AST)
     - Type checking
     - Linearity checking
     - Capability checking
     - Borrow/region checking
     - Defer rewriting
     - Allocator binding resolution
       ↓
   Typed AST
       ↓
   Code Generation (MLIR)
       ↓
   Machine Code
```

The compiler type-checks the AST directly — there is no separate kernel IR phase. The type checker is structured as clean, separated modules (linearity, capabilities, borrowing) so that each can be independently formalized and verified.

The formal verification lives alongside the compiler as a separate Lean artifact. It defines a small formal model, proves the typing rules sound, and its correspondence to the compiler's type checker is validated through testing and eventually proof witnesses.

## No Hidden Control Flow

When you read Concrete code, what you see is what executes.

**No implicit function calls.** Operators are not overloaded methods. `a + b` on integers is primitive addition, not a method call. There are no implicit conversions that invoke code.

**No implicit destruction.** The compiler never inserts destructor calls. Concrete requires you to write `defer destroy(x)`. You see the cleanup in the source.

**No implicit allocation.** Allocation happens when you call a function with `Alloc` capability bound to an allocator. String concatenation, collection growth, closure capture—if they allocate, you see `with(Alloc)` in the signature.

**No invisible error handling.** Errors propagate only where `?` appears. There are no exceptions unwinding the stack behind your back.

The cost is verbosity. The benefit is that reading the code tells you what the code does. For auditing, debugging, and formal verification, this tradeoff is correct.

## Types

### Primitives

```
Bool
Int, Int8, Int16, Int32, Int64
Uint, Uint8, Uint16, Uint32, Uint64
Float32, Float64
Char, String
Unit
```

### Algebraic Data Types

```
type Option<T> {
    Some(T),
    None
}

type Result<T, E> {
    Ok(T),
    Err(E)
}

type List<T> {
    Nil,
    Cons(T, List<T>)
}
```

### Records

```
type Point {
    x: Float64,
    y: Float64
}
```

### Standard Library Types

For domains where precision matters, the standard library includes:

- **Decimal**: fixed-point decimal arithmetic for financial calculations
- **BigInt**: arbitrary-precision integers
- **BigDecimal**: arbitrary-precision decimals

These avoid floating-point representation errors in financial systems and cryptographic applications.

## Linearity and Copy

All values in Concrete are linear by default. A linear value must be consumed exactly once, not zero times (that's a leak), not twice (that's a double-free). This is closer to Austral's strict linearity than affine types, which allow values to be dropped without explicit consumption.

Consumption happens when you pass the value to a function that takes ownership, return it, destructure it via pattern matching, or explicitly call `destroy(x)`.

```
fn example!() {
    let f = open("data.txt")
    defer destroy(f)
    let content = read(&f)
    // destroy(f) runs here because of defer
}
```

If `f` isn't consumed on all paths, the program is rejected. If you try to use `f` after moving it, the program is rejected. This is compile-time enforcement, not runtime checking.

### The Copy Marker

Some types escape linear restrictions. The rules for `Copy` are:

1. **Copy is explicit and opt-in.** You must mark a type as `Copy`; it is never inferred.
2. **Copy is structural.** A type can be `Copy` only if all its fields are `Copy`.
3. **Copy types cannot have destructors.** If a type defines `destroy`, it cannot be `Copy`.
4. **Copy types cannot contain linear fields.** A `Copy` record with a `File` field is rejected.

```
type Copy Point {
    x: Float64,
    y: Float64
}
```

The primitive numeric types and `Bool` are built-in `Copy` types. `String` is linear. For generic types, linearity depends on the type parameter: `Option<Int>` is `Copy` because `Int` is; `Option<File>` is linear because `File` is.

`Copy` is not an escape hatch from thinking about resources. It's a marker for types that have no cleanup requirements and can be freely duplicated.

### Destructors

A linear type may define a destructor:

```
type File {
    handle: FileHandle
}

destroy File with(File) {
    close_handle(self.handle)
}
```

The destructor takes ownership of `self`, may require capabilities, and runs exactly once when explicitly invoked. `destroy(x)` is only valid if the type defines a destructor. A type without a destructor must be consumed by moving, returning, or destructuring.

### Defer

The `defer` statement schedules cleanup at scope exit, borrowed directly from Zig and Go:

```
fn process_files!() {
    let f1 = open("a.txt")
    defer destroy(f1)

    let f2 = open("b.txt")
    defer destroy(f2)

    // When scope exits:
    // 1. destroy(f2) runs
    // 2. destroy(f1) runs
}
```

Multiple `defer` statements execute in reverse order (LIFO). `defer` runs at scope exit including early returns and error propagation.

### Defer Reserves the Value

When a value is scheduled with `defer destroy(x)`, it becomes reserved. The rules:

1. After `defer destroy(x)`, you cannot move `x`
2. After `defer destroy(x)`, you cannot destroy `x` again
3. After `defer destroy(x)`, you cannot `defer destroy(x)` again
4. After `defer destroy(x)`, you cannot create borrows of `x` that might overlap the deferred destruction point

The value is still owned by the current scope until exit, but it is no longer available for use. This prevents double destruction and dangling borrows.

## Borrowing

Borrowing defers consumption without extending lifetime or weakening linearity.

References let you use values without consuming them. Concrete's borrowing model simplifies lifetime annotations: references exist within lexical regions that bound their lifetime, with no lifetime parameters in function signatures.

```
borrow f as fref in R {
    // fref has type &[File, R]
    // f is unusable in this block
    let len = length(fref)
}
// f is usable again
```

Functions that accept references are generic over the region, but implicitly:

```
fn length<R>(file: &[File, R]) -> Uint {
    ...
}
```

The function cannot store the reference because it cannot name `R` outside the call.

For single-expression borrows, the region is anonymous:

```
let len = length(&f)  // borrows f for just this call
```

### Borrowing Rules

1. While borrowed, the original is unusable
2. Multiple immutable borrows allowed
3. Mutable borrows exclusive: one `&mut T` at a time, no simultaneous `&T`
4. References cannot escape their region
5. Nested borrows of the same owned value forbidden
6. Derived references can't outlive the original's region

Closures cannot capture references if the closure escapes the borrow region. This ensures references never outlive their lexical scope.

## Capabilities

### What Capabilities Are

A capability is a static permission annotation on a function. It declares which effects the function may perform. Capabilities are not runtime values—they cannot be created, passed, stored, or inspected at runtime. They exist only at the type level, checked by the compiler and erased before execution.

Capabilities are predefined names. Users cannot define new capabilities or create composite capability types. Function signatures may combine predefined capabilities using `+` in the `with()` clause, but only among names exported by the platform's capability universe. The set of capabilities is fixed per target platform and finite—user code cannot extend it. There is no capability arithmetic, no capability inheritance, no way to forge a capability your caller didn't have.

Capabilities that can be manufactured at runtime aren't capabilities—they're tokens.

### Purity

Concrete is **pure by default**, following Austral's approach to effect tracking. A function without capability annotations cannot perform IO, cannot allocate, cannot mutate external state. It computes a result from its inputs, nothing more.

Purity in Concrete has a precise definition: a function is pure if and only if it declares no capabilities and does not require `Alloc`. Equivalently, purity means an empty capability set.

Pure functions may use stack allocation and compile-time constants—these are not effects. Pure functions may diverge—termination is orthogonal to purity. A non-terminating function that performs no IO and touches no heap is still pure. This separates effect-freedom (what Concrete tracks) from totality (which Concrete does not guarantee).

Purity enables equational reasoning: a pure function called twice with the same arguments yields the same result. Totality would enable stronger claims about program termination, but enforcing it would require restricting recursion, which conflicts with systems programming.

When a function needs effects, it declares them:

```
fn read_file(path: String) with(File) -> String {
    ...
}

fn process_data() with(File, Network, Alloc) -> Result {
    ...
}
```

Capabilities propagate monotonically. If `f` calls `g`, and `g` requires `File`, then `f` must declare `File` too. No implicit granting, no ambient authority. The compiler enforces this transitively.

### The Std Capability

For application entry points, Concrete provides a shorthand. The `!` suffix declares the `Std` capability:

```
fn main!() {
    println("Hello")
}
```

This desugars to `fn main() with(Std)`. `Std` includes file operations, network, clock, environment, random, and allocation, but excludes `Unsafe`.

**Library code should prefer explicit capability lists.** This is a social convention, not a mechanical enforcement. The compiler won't reject a library function that uses `Std`. But explicit capabilities make dependencies auditable. `Std` is a convenience for applications, not a license for libraries.

### Security Model

Capabilities don't sandbox code. If a dependency declares `with(Network)`, it gets network access. What they provide is **auditability**. You can grep for `with(Network)` and find every function that touches the network. You can verify that your JSON parser has no capabilities. You can review dependency updates by diffing capability declarations.

### Capability Polymorphism

Currently, you cannot be generic over capability sets:

```
// Not allowed
fn map<T, U, C>(list: List<T>, f: fn(T) with(C) -> U) with(C) -> List<U>
```

Each capability set must be concrete. This means generic combinators must be duplicated per capability set. Capability polymorphism is future work; the theory is well-understood (effect polymorphism in Koka, Eff, Frank), but adds complexity to the type system and the Lean formalization.

### Parametricity

Generic functions cannot accidentally become effectful depending on instantiation. A function `fn map<T, U>(list: List<T>, f: fn(T) -> U) -> List<U>` is pure regardless of what `T` and `U` are. If `f` requires capabilities, that must be declared in the signature.

Capabilities are checked before monomorphization. When generic code is specialized to concrete types, capability requirements don't change. A pure generic function stays pure at every instantiation.

## Allocation

Allocation deserves special attention because it's often invisible. In most languages, many operations allocate behind your back: string concatenation, collection growth, closure creation.

Concrete treats allocation as a capability, with explicit allocator passing inspired by Zig. Functions that allocate declare `with(Alloc)`. The call site binds which allocator:

```
fn main!() {
    let arena = Arena.new()
    defer arena.deinit()

    let list = create_list<Int>() with(Alloc = arena)
    push(&mut list, 42) with(Alloc = arena)
}
```

Inside `with(Alloc)`, the bound allocator propagates through nested calls. At the boundary, you see exactly where allocation happens and which allocator serves it.

Stack allocation does not require `Alloc`:

```
fn example() {
    let x: Int = 42                    // stack
    let arr: [100]Uint8 = zeroed()     // stack
}
```

Allocation-free code is provably allocation-free.

### Allocator Binding Scope

Allocator binding is lexically scoped. A binding applies within the static extent of the call being evaluated and any nested calls that require `with(Alloc)`.

A nested binding may shadow an outer binding:

```
fn outer() with(Alloc) {
    inner()                         // uses outer binding
    inner() with(Alloc = arena2)    // shadows within this call
}
```

Closures capture allocator bindings only if the closure is invoked within the lexical scope where the binding is in effect. If a closure escapes that scope, it cannot rely on an implicit allocator binding and must instead accept an explicit allocator parameter or be rejected by the type checker.

### Allocator Types

```
// General-purpose heap allocator
let gpa = GeneralPurposeAllocator.new()
defer gpa.deinit()

// Arena allocator, free everything at once
let arena = Arena.new(gpa)
defer arena.deinit()

// Fixed buffer allocator, no heap
let buf: [1024]Uint8 = zeroed()
let fba = FixedBufferAllocator.new(&buf)
```

All allocators implement a common `Allocator` trait.

### Allocator Interface

```
trait Allocator {
    fn alloc<T>(&mut self, count: Uint) -> Result<&mut [T], AllocError>
    fn free<T>(&mut self, ptr: &mut [T])
    fn realloc<T>(&mut self, ptr: &mut [T], new_count: Uint) -> Result<&mut [T], AllocError>
}
```

The interface is minimal. `alloc` returns a mutable slice or fails. `free` releases memory. `realloc` resizes in place or relocates. All three take `&mut self`—allocators are stateful resources, not ambient services.

Custom allocators implement this trait. The standard library allocators (`GeneralPurposeAllocator`, `Arena`, `FixedBufferAllocator`) are implementations, not special cases.

## Error Handling

Errors are values, using `Result<T, E>` and the `?` operator for propagation:

```
fn parse(input: String) -> Result<Config, ParseError> {
    ...
}

fn load_config!() -> Result<Config, Error> {
    let f = open("config.toml")?
    defer destroy(f)

    let content = read(&f)
    let config = parse(content)?
    Ok(config)
}
```

The `?` operator propagates errors. When `?` triggers an early return, all `defer` statements in scope run first. Cleanup happens even on error paths.

No exceptions. No panic.

### Abort

Abort is immediate process termination, outside normal control flow and outside the language's semantic model. Following Zig's approach:

- Out-of-memory conditions trigger abort
- Stack overflow triggers abort
- Explicit `abort()` terminates immediately
- **Deferred cleanup does not run on abort**

`defer` is for normal control flow, not catastrophic failure. Abort is the escape hatch when `Result` isn't enough. The process stops. There are no guarantees about state after abort begins.

## Pattern Matching

Exhaustive pattern matching with linear type awareness:

```
fn describe(opt: Option<Int>) -> String {
    match opt {
        Some(n) => format("Got {}", n),
        None => "Nothing"
    }
}
```

Linear types in patterns must be consumed:

```
fn handle!(result: Result<Data, File>) {
    match result {
        Ok(data) => use_data(data),
        Err(f) => destroy(f)
    }
}
```

Borrowing in patterns:

```
fn peek(opt: &Option<Int>) -> Int {
    match opt {
        &Some(n) => n,
        &None => 0
    }
}
```

## Traits

Traits provide bounded polymorphism:

```
trait Ord {
    fn compare(&self, other: &Self) -> Ordering
}

trait Show {
    fn show(&self) -> String
}

fn sort<T: Ord>(list: List<T>) with(Alloc) -> List<T> {
    ...
}
```

### Receiver Modes and Linear Types

Trait methods take the receiver in one of three forms:

- `&self` — borrows the value immutably
- `&mut self` — borrows the value mutably
- `self` — takes ownership, consuming the value

If a trait method takes `self`, calling it consumes the value. This follows linear consumption rules:

```
trait Consume {
    fn consume(self)
}

fn use_once<T: Consume>(x: T) {
    x.consume()  // x is consumed here
    // x.consume()  // ERROR: x already consumed
}
```

A trait implementation for a linear type must respect the receiver mode. An `&self` method cannot consume the value. An `&mut self` method cannot let the value escape. A `self` method consumes it.

## Type Inference

Type inference is **local only**. Function signatures must be fully annotated. Inside bodies, local types may be inferred:

```
fn process(data: List<Int>) with(Alloc) -> List<Int> {
    let doubled = map(data, fn(x) { x * 2 })  // inferred
    let filtered = filter(doubled, fn(x) { x > 0 })  // inferred
    filtered
}
```

You can always understand a function's interface without reading its body.

## Modules

```
module FileSystem

public fn open(path: String) with(File) -> Result<File, IOError> {
    ...
}

public fn read<R>(file: &[File, R]) with(File) -> String {
    ...
}

private fn validate(path: String) -> Bool {
    ...
}
```

Visibility is `public` or `private` (default).

### Capabilities as Public Contract

Capabilities are part of a function's signature and therefore part of the public API contract. Changing the required capability set of a public function is a breaking change. This applies in both directions: adding a capability requirement breaks callers who don't have it; removing one changes the function's guarantees.

When reviewing dependency updates, diff the capability declarations. A library that adds `with(Network)` to a function that previously had none is a significant change, even if the types remain identical.

```
import FileSystem
import FileSystem.{open, read, write}
import FileSystem as FS
```

## Unsafe and FFI

The `Unsafe` capability gates operations the type system cannot verify: foreign function calls, raw pointer operations, type transmutation, inline assembly, and linearity bypasses.

```
fn transmute<T, U>(value: T) with(Unsafe) -> U

fn ptr_read<T>(ptr: Address[T]) with(Unsafe) -> T

fn ptr_write<T>(ptr: Address[T], value: T) with(Unsafe)
```

`Unsafe` propagates through the call graph like any other capability. Grep for `with(Unsafe)` to find all trust boundaries.

### Raw Pointers

Raw pointers exist for FFI and low-level memory manipulation:

```
Address[T]       // raw pointer to T
```

Raw pointers are `Copy`. They carry no lifetime information and no linearity guarantees. This is safe because:

- Creating a raw pointer is safe. `address_of(r)` extracts an address.
- Holding a raw pointer is safe. It's a number.
- Using a raw pointer requires `Unsafe`. Dereference, arithmetic, and casting are gated.

```
fn to_ptr<T>(r: &T) -> Address[T] {
    address_of(r)  // safe
}

fn deref<T>(ptr: Address[T]) with(Unsafe) -> T {
    read_ptr(ptr)  // unsafe: no guarantee ptr is valid
}
```

### Foreign Functions

Declare foreign functions with `Unsafe` and the `foreign` directive:

```
fn malloc(size: Uint) with(Unsafe) -> Address[Unit] =
    foreign("malloc")

fn free(ptr: Address[Unit]) with(Unsafe) =
    foreign("free")
```

The compiler generates calling convention glue and links the symbol. Foreign signatures are restricted to C-compatible types. Details of the type mapping are deferred to a future FFI specification.

## What You're Giving Up

Concrete is not a general-purpose language. It's for code that must be correct: cryptographic implementations, financial systems, safety-critical software, blockchain infrastructure.

**No garbage collection.** Memory is managed through linear types and explicit destruction. No GC pauses, no unpredictable latency, no hidden memory pressure.

**No implicit allocation.** Allocation requires the `Alloc` capability. `grep with(Alloc)` finds every function that might touch the heap.

**No interior mutability.** All mutation flows through `&mut` references. An immutable reference `&T` guarantees immutability, no hidden mutation behind an immutable facade. This forbids patterns like shared caches and memoization behind shared references. If you need a cache, pass `&mut`. If you need lazy initialization, initialize before borrowing. For advanced patterns that genuinely require interior mutability, the standard library provides `UnsafeCell<T>` gated by the `Unsafe` capability.

**No reflection, no eval, no runtime metaprogramming.** All code paths are determined at compile time. There is no way to inspect types at runtime, call methods by name dynamically, or generate code during execution.

If macros are added in a future version, they will be constrained to preserve the "can a machine reason about this?" principle:

- **Hygienic** — no accidental variable capture
- **Phase-separated** — macro expansion completes before type checking
- **Syntactic** — macros transform syntax trees, not strings
- **Capability-tracked** — procedural macros that execute arbitrary code at compile time will require capability annotations, extending effect tracking to the compile-time phase

**No implicit global state.** All global interactions (file system, network, clock, environment) are mediated through capabilities.

**No variable shadowing.** Each variable name is unique within its scope.

**No null.** Optional values use `Option<T>`.

**No undefined behavior in safe code.** The type system semantics are fully defined and proven sound in Lean. The `Unsafe` capability explicitly reintroduces the possibility of undefined behavior for FFI and low-level operations.

**No concurrency primitives.** The language provides no threads, no async/await, no channels. Concurrency is a library concern. This may change, but any future concurrency model must preserve determinism and linearity, likely through structured or deterministic concurrency. This is a design constraint, not an open question.

### Anti-Features Summary

| Concrete does not have | Rationale |
|------------------------|-----------|
| Garbage collection | Predictable latency, explicit resource management |
| Hidden control flow | Auditability, debuggability |
| Hidden allocation | Performance visibility, allocator control |
| Interior mutability | Simple reasoning, verification tractability |
| Reflection / eval | Static analysis, all paths known at compile time |
| Global mutable state | Effect tracking, reproducibility |
| Variable shadowing | Clarity, fewer subtle bugs |
| Null | Type safety via `Option<T>` |
| Exceptions | Errors as values, explicit propagation |
| Implicit conversions | No silent data loss or coercion |
| Function overloading | Except through traits with explicit bounds |
| Uninitialized variables | Memory safety |
| Macros | Undecided; if added, will be hygienic and capability-aware |
| Concurrency primitives | Undecided; must preserve linearity and determinism |
| Undefined behavior (in safe code) | Type system semantics fully defined and proven sound |

## Implementation

### Implemented in Lean 4

The Concrete compiler is implemented in [Lean 4](https://lean-lang.org/). Lean serves as both the implementation language for the compiler (parser, type checker, code generator) and the language for formal verification of the typing rules. The compiler and the formalization live in the same codebase.

The runtime (green threads, preemptive scheduler, stack switching) is implemented in C, as these require low-level control over memory layout and system primitives that are outside Lean's domain.

### Formal Verification Approach

The compiler and the formal verification are separate concerns that converge over time.

**The compiler** type-checks the AST directly — no separate kernel IR. The type checker is structured as clean, separated modules (linearity checking, capability checking, borrow checking) so each can be independently formalized.

**The formalization** is a separate Lean artifact that defines a small formal model and proves the typing rules sound. It does not appear in the compilation pipeline. The formal model models only the features that matter for proofs — surface sugar, syntax variants, and error recovery are excluded.

#### What the formalization defines

**Abstract syntax** — a small mathematical language (~15 constructors for terms, ~10 for types) used only for reasoning:

```lean
inductive Ty where
  | prim : PrimTy → Ty
  | arrow : Ty → CapSet → Ty → Ty        -- function type with capabilities
  | prod : Ty → Ty → Ty                   -- product (records)
  | sum : Ty → Ty → Ty                    -- sum (enums)
  | ref_ : Ty → Region → Ty              -- immutable borrow in region
  | mutRef : Ty → Region → Ty            -- mutable borrow in region
  | forall_ : Kind → Ty → Ty             -- polymorphism (generics)
  | addr : Ty → Ty                        -- raw pointer

inductive Term where
  | var : Nat → Term
  | lam : Ty → Term → Term                -- function
  | app : Term → Term → Term              -- application
  | let_ : Ty → Term → Term → Term        -- let binding
  | pair : Term → Term → Term             -- construct product
  | letPair : Term → Term → Term          -- destructure product
  | inj : Nat → Term → Ty → Term          -- construct sum variant
  | case_ : Term → List Term → Term       -- pattern match (exhaustive)
  | destroy : Term → Term                  -- consume linear value
  | region : Term → Term                   -- introduce borrow region
  | borrow : Term → Term → Term            -- create borrow
  | foreign_ : String → Ty → Term         -- FFI
  | lit : Literal → Term                   -- literals
```

**Typing rules** as inductive propositions — the core of what gets proven:

```lean
-- "In context Γ, with capabilities C, term e has type τ"
inductive HasType : Ctx → CapSet → Term → Ty → Prop where
  | var :
      Γ.lookup x = some (τ, lin) →
      HasType Γ C (.var x) τ

  | app :
      HasType Γ₁ C e₁ (.arrow τ₁ C' τ₂) →
      HasType Γ₂ C e₂ τ₁ →
      C' ⊆ C →                            -- caller has callee's capabilities
      Γ = Γ₁.split Γ₂ →                   -- linear context splits between subterms
      HasType Γ C (.app e₁ e₂) τ₂

  | destroy :
      HasType Γ C e τ →
      τ.isLinear →
      HasType Γ C (.destroy e) .unit
  ...
```

The key is `Γ = Γ₁.split Γ₂` — the linear context splits between subexpressions, ensuring each linear variable is used exactly once. This is the standard technique from linear logic.

**Operational semantics** — how terms evaluate:

```lean
inductive Step : Term → Term → Prop where
  | beta : Step (.app (.lam τ body) arg) (body.subst arg)
  | letStep : Step (.let_ τ val body) (body.subst val)
  | destroyStep : Step (.destroy (.constructor fields)) .unit
  ...
```

#### What gets proven

Four theorems:

1. **Progress**: well-typed terms are values or can step — programs don't get stuck
2. **Preservation**: stepping preserves types — evaluation doesn't break type safety
3. **Linearity soundness**: every linear binding is consumed exactly once during evaluation
4. **Effect soundness**: evaluation only performs effects declared in the capability set

```lean
theorem progress :
    HasType Γ C e τ →
    Value e ∨ ∃ e', Step e e' := by
  sorry  -- filled in incrementally

theorem preservation :
    HasType Γ C e τ →
    Step e e' →
    HasType Γ' C e' τ := by
  sorry

theorem linearity_soundness :
    HasType Γ C e τ →
    ∀ x ∈ Γ, x.isLinear → usageCount x e = 1 := by
  sorry

theorem effect_soundness :
    HasType Γ C e τ →
    Step e e' →
    effectsOf e' ⊆ C := by
  sorry
```

Every `sorry` is a proof obligation tracked by Lean. They compile and run — they just mark where proofs are owed. They get replaced incrementally, one at a time, as the formalization matures.

#### What the formalization does NOT model

- Surface syntax sugar (`!`, `defer`, anonymous borrows)
- Traits (elaborated to dictionary passing before anything the formalization cares about)
- Modules and imports (name resolution is a surface concern)
- Type inference (fully resolved before type checking)
- Error messages
- Parsing

These are compiler concerns, not verification concerns. Keeping them out of the formalization is what makes the proofs tractable.

#### How surface features map to the formal model

| Surface feature | Formalization representation |
|----------------|------------------------------|
| `fn foo!()` | Function with `CapSet = Std` |
| `defer destroy(x)` | Rewritten to explicit sequencing with `destroy` at scope exit |
| Traits | Dictionary passing — extra function arguments |
| Generics | Explicit type abstraction (`∀`) and application |
| `match` on enums | `case_` on sum types |
| Records / structs | Product types |
| Anonymous borrows (`&f`) | Named region introduction + borrow |
| Allocator binding `with(Alloc = arena)` | Explicit allocator parameter passing |

### Determinism

Concrete aims for **bit-for-bit reproducible builds**: same source + same compiler = identical binary. No timestamps, random seeds, or environment-dependent data in output.

For debugging, **deterministic replay**: random generation requires `Random` with explicit seed, system time requires `Clock`. Same inputs produce identical execution.

### The Grammar

LL(1). Every parsing decision with a single token of lookahead. No ambiguity, no backtracking.

This is a permanent design constraint, not an implementation detail. Future language evolution is bounded by what LL(1) can express. We accept this constraint for tooling simplicity and error message quality.

### Compilation Targets

**Native** via MLIR/LLVM, **C** for portability, **WebAssembly** for browser and edge. Cross-compilation is first-class.

### Tooling

Concrete ships with package manager, formatter, linter, test runner, and REPL. Part of the distribution, not external dependencies.

### Profiling and Tracing

Profiling and tracing are first-class:

- Built into the runtime, not bolted on
- Low overhead when disabled
- Structured output for tooling integration

Code is read more often than written, but executed more often than read. Performance visibility matters for systems programming.

## What You Can Say About Programs

If a program type-checks:

**"This function is pure."** No capabilities declared. No side effects, no IO, no allocation.

**"This resource is used exactly once."** Linear type. No leaks, no double-free, no use-after-free.

**"These are the only effects this code can perform."** Capability set is explicit and complete.

**"This code cannot escape the type system."** Unsafe operations require `with(Unsafe)`.

**"Allocation happens here, using this allocator."** Call site binds the allocator.

**"Cleanup happens here."** `defer destroy(x)` is visible.

**"This build is reproducible."** Same inputs, same binary.

Mechanical guarantees from a type system whose rules are proven sound in a separate Lean formalization. Not conventions, proofs.

## Example

```
module Main

import FileSystem.{open, read, write}
import Parse.{parse_csv}

fn process_file(input_path: String, output_path: String) with(File, Alloc) -> Result<Unit, Error> {
    let in_file = open(input_path)?
    defer destroy(in_file)

    let content = read(&in_file)
    let data = parse_csv(content)?
    let output = transform(&data)

    let out_file = open(output_path)?
    defer destroy(out_file)

    write(&mut out_file, output)
    Ok(())
}

fn transform(data: &List<Row>) -> String {
    ...
}

fn main!() {
    let arena = Arena.new()
    defer arena.deinit()

    match process_file("input.csv", "output.txt") with(Alloc = arena) {
        Ok(()) => println("Done"),
        Err(e) => println("Error: " + e.message())
    }
}
```

Everything is visible: resource acquisition, cleanup scheduling, error propagation, allocator binding.

## Who Should Use This

Concrete trades convenience for explicitness, flexibility for auditability. Prototyping is slower. Some patterns become verbose. You'll miss interior mutability for certain data structures.

But for cryptographic primitives, consensus protocols, financial transaction systems, medical device firmware, the trade is worth it. Strong claims about program behavior, mechanically verified.

A language you can trust the way you trust mathematics: not because someone promises it works, but because you can check the proof.

## Quick Reference

| Annotation | Meaning |
|------------|---------|
| `fn foo() -> T` | Pure function, no capabilities |
| `fn foo!() -> T` | Shorthand for `with(Std)` |
| `fn foo() with(C) -> T` | Requires capability set `C` |
| `with(Alloc)` | Function may allocate |
| `with(Alloc = a)` | Bind allocator `a` at call site |
| `T` | Linear type, consumed exactly once |
| `type Copy T` | Unrestricted type, freely duplicated |
| `&T` or `&[T, R]` | Immutable reference in region `R` |
| `&mut T` | Mutable reference |
| `Address[T]` | Raw pointer (unsafe to use) |
| `borrow x as y in R { }` | Explicit borrow with named region |
| `defer expr` | Run `expr` at scope exit |
| `destroy(x)` | Consume via destructor |
| `foreign("symbol")` | Foreign function binding |

## Standard Capabilities

The `Std` capability (accessed via `!`) bundles these individual capabilities:

| Capability | Gates |
|------------|-------|
| `File` | Open, read, write, close files. Directory operations. |
| `Network` | Sockets, HTTP, DNS resolution. |
| `Alloc` | Heap allocation. Requires allocator binding at call site. |
| `Clock` | System time, monotonic time, sleep. |
| `Random` | Random number generation. Requires explicit seed for reproducibility. |
| `Env` | Environment variables, command line arguments. |
| `Process` | Spawn processes, exit codes, signals. |
| `Console` | Stdin, stdout, stderr. |

Capabilities not in `Std`:

| Capability | Gates |
|------------|-------|
| `Unsafe` | Raw pointer operations, FFI calls, transmute, inline assembly. Never implicit. |

A function with no capability annotation is pure. A function with `!` has access to everything except `Unsafe`. A function with explicit `with(File, Alloc)` has exactly those capabilities.

Capabilities are not hierarchical. `Std` is a shorthand for a set, not a super-capability. You cannot request "half of Std."

## Comparison

| Feature | Concrete | Rust | Zig | Austral | Go |
|---------|----------|------|-----|---------|-----|
| Memory safety | Linear types | Ownership + borrow checker | Runtime checks (optional) | Linear types | GC |
| Linearity | Strict (exactly once) | Affine (at most once) | None | Strict | None |
| GC | None | None | None | None | Yes |
| Effect tracking | Capabilities | None | None | Capabilities | None |
| Pure by default | Yes | No | No | Yes | No |
| Explicit allocation | Capability + binding | Global allocator | Allocator parameter | No | GC |
| Null | None (`Option<T>`) | None (`Option<T>`) | Optional (`?T`) | None (`Option[T]`) | Yes (`nil`) |
| Exceptions | None | Panic (discouraged) | None | None | Panic |
| Error handling | `Result` + `?` | `Result` + `?` | Error unions | `Result` | Multiple returns |
| Lifetime annotations | None (lexical regions) | Yes | None | None | N/A (GC) |
| Formal verification | Type system proven sound in Lean | External tools | None | None | None |
| Defer | Yes | No (RAII) | Yes | No | Yes |
| Interior mutability | None | `Cell`, `RefCell`, etc. | Pointers | None | Pointers |
| Unsafe escape hatch | `with(Unsafe)` | `unsafe` blocks | No safe/unsafe distinction | `Unsafe_Module` | No distinction |
| Macros | None (undecided) | Procedural + declarative | Comptime | None | None |
| Concurrency | None (undecided) | `async`, threads, channels | Threads, async | None | Goroutines, channels |
| Formatter | Ships with language | rustfmt (separate) | zig fmt | None | gofmt |
| Grammar | LL(1) | Complex | Simple | Simple | LALR |

## Open Questions

These are unresolved design decisions:

**Concurrency**

No concurrency primitives exist. The language is currently single-threaded. Any future model must preserve:
- Linearity (no data races from aliasing)
- Determinism (reproducible execution)
- Effect tracking (concurrency as capability)

Candidates: structured concurrency (like Trio/libdill), deterministic parallelism (like Haskell's `par`), actor model with linear message passing. Not decided.

**Capability Polymorphism**

Currently impossible:
```
fn map<T, U, C>(list: List<T>, f: fn(T) with(C) -> U) with(C) -> List<U>
```

This forces duplicating combinators for each capability set. The theory exists (Koka, Eff, Frank), but adds complexity. Open question: is the duplication acceptable, or do we need polymorphism?

**Effect Handlers**

Capabilities track effects but don't handle them. Full algebraic effects would allow:
```
fn with_mock_filesystem<T>(f: fn() with(File) -> T) -> T {
    handle File in f() {
        open(path) => resume(MockFile.new(path))
        read(file) => resume(mock_data)
    }
}
```

This enables testing, sandboxing, effect interception. Significant implementation complexity. Not committed.

**Module System**

Current design is minimal. Open questions:
- Parameterized modules (functors)?
- Module-level capability restrictions?
- Visibility modifiers beyond public/private?
- Separate compilation units?

**FFI Type Mapping**

The spec says "C-compatible types" without defining them. Need to specify:
- Integer mappings (is `Int` C's `int` or `intptr_t`?)
- Struct layout guarantees
- Calling conventions
- Nullable pointer representation
- String encoding at boundaries

**Variance**

Generic types have variance implications. `List<T>` is covariant in `T`. `fn(T) -> U` is contravariant in `T`. The spec doesn't address this. For linear types, variance interacts with consumption. Needs formalization.

**Macros**

No macro system. Options:
- None (keep it simple)
- Hygienic macros (Scheme-style)
- Procedural macros (Rust-style)
- Compile-time evaluation (Zig-style comptime)

Procedural macros would need capability restrictions. Not decided.

## Influences

The type system is formalized in [Lean 4](https://lean-lang.org/), which also serves as the compiler's implementation language. Coq could serve the verification role; we chose Lean for its performance, active development, and the ability to use one language for both compiler and proofs.

[Austral](https://austral-lang.org/) shaped the type system more than any other language. Linear types in Concrete are strict: every value must be consumed exactly once. The capability system for effect tracking also comes from Austral.

From [Rust](https://www.rust-lang.org/): borrowing, traits, error handling, pattern matching. Concrete uses lexical regions instead of lifetime annotations, which simplifies the model but covers fewer cases. `Result<T, E>` and the `?` operator are lifted directly.

[Zig](https://ziglang.org/)'s influence shows in explicit allocator passing and defer. Zig functions that allocate take an allocator parameter; Concrete expresses the same idea through `with(Alloc)` and allocator binding at call sites.

[Go](https://go.dev/) had defer first. Go also shipped gofmt, which ended style debates by making one canonical format. We ship a formatter too.

The `!` syntax for impure functions comes from [Roc](https://www.roc-lang.org/). `fn main!()` marks impurity at a glance.

[Koka](https://koka-lang.github.io/koka/doc/index.html), [Eff](https://www.eff-lang.org/), and [Frank](https://github.com/frank-lang/frank) are the algebraic effects languages. Concrete's capabilities are a simplified version of their effect systems. Capability polymorphism would bring us closer to their expressiveness; it's future work.

[Haskell](https://www.haskell.org/) proved that pure-by-default is practical. [Clean](https://clean.cs.ru.nl/) had uniqueness types (precursor to linear types) and purity before Haskell did.

[Cyclone](https://cyclone.thelanguage.org/) pioneered region-based memory, the research line that led to lifetimes and our lexical regions. [ATS](https://www.ats-lang.org/) showed linear types and theorem proving can coexist. [Ada/SPARK](https://www.adacore.com/about-spark) proved formal verification works in production: avionics, rail, security-critical systems.

[CompCert](https://compcert.org/) and [seL4](https://sel4.systems/) established that you can mechanically verify real systems software. A verified C compiler and a verified microkernel. That's the standard we're aiming for.

We also took ideas, specs and features from:
- [Erlang](https://www.erlang.org) (Preemptive scheduler, message passing, runtime)
- [Commonware](https://commonware.xyz/blogs/commonware-runtime.html) (Deterministic runtime)
- [Pony](https://www.ponylang.io) / [Gleam](https://gleam.run) (Typed message passing)
- [Loom](https://github.com/tokio-rs/loom) (Concurrency permutation testing)
- [Resonate](https://blog.resonatehq.io/deterministic-simulation-testing) (Deterministic simulation testing)
- [Vale](https://verdagon.dev/blog/perfect-replayability-prototyped) (Perfect Replayability)
- [Elixir](https://elixir-lang.org/)
- [Inko](https://inko-lang.org/)
- [Odin](https://odin-lang.org/)
- [Elm](https://elm-lang.org/)
- [Lua](https://www.lua.org/)
- [Clojure](https://clojure.org/)
- [Nim](https://nim-lang.org/)
- [Acton](https://www.acton-lang.org)

## Glossary

**Affine type**: A type whose values can be used at most once. Concrete uses strict linear types instead: values must be consumed exactly once.

**Capability**: A token that grants permission to perform an effect. Functions declare required capabilities; callers must have them. Capabilities propagate: if `f` calls `g`, and `g` needs `File`, then `f` needs `File`.

**Consumption**: Using a linear value in a way that fulfills its "exactly once" obligation. Methods of consumption: pass to a function taking ownership, return, destructure via pattern match, call `destroy()`.

**Copy type**: A type exempt from linearity. Values can be duplicated freely. Must be explicitly marked. Cannot have destructors or linear fields.

**Destruction**: Consuming a linear value by invoking its destructor. `destroy(x)` calls the type's destructor and consumes `x`.

**Effect**: An observable interaction with the world outside pure computation: IO, allocation, mutation, non-determinism. Concrete tracks effects through capabilities.

**Elaboration**: The compiler phase that transforms surface syntax into kernel IR. Type checking, linearity checking, and capability checking happen here.

**Formal model**: A simplified version of Concrete (~15 term constructors, ~10 type constructors) defined in Lean for reasoning about the type system. It is a mathematical object used for proofs, not a compiler phase. The compiler type-checks the AST directly; the formalization proves the typing rules sound.

**Lexical region**: A scope that bounds reference lifetimes. References created in a region cannot escape it. Regions are always lexical and never appear in signatures.

**Linear type**: A type whose values must be used exactly once. Not zero (leak), not twice (double-use). Concrete's default.

**Purity**: Absence of effects. A pure function computes a result from its inputs without IO, allocation, or mutation. In Concrete, functions without capability annotations are pure.

**Raw pointer**: An `Address[T]` value. Carries no lifetime or linearity information. Safe to create and hold; unsafe to use.

**Reference**: A borrowed view of a value. `&T` for immutable, `&mut T` for mutable. The original value is inaccessible while borrowed.

**Std**: The standard capability set. Shorthand for `File`, `Network`, `Alloc`, `Clock`, `Random`, `Env`, `Process`, `Console`. Excludes `Unsafe`.

**Unsafe**: The capability that permits operations the type system cannot verify: FFI, raw pointer dereference, transmute.

## Error Messages

These are representative error messages. The actual compiler may differ.

**Linearity violation: value not consumed**
```
error[E0201]: linear value `f` is never consumed
  --> src/main.concrete:4:9
   |
 4 |     let f = open("data.txt")
   |         ^ this value has type `File` which is linear
   |
   = help: linear values must be consumed exactly once
   = help: add `defer destroy(f)` or pass `f` to a function that takes ownership
```

**Linearity violation: value consumed twice**
```
error[E0202]: value `f` consumed twice
  --> src/main.concrete:7:12
   |
 5 |     let content = read_all(f)
   |                           - first consumption here
 6 |
 7 |     destroy(f)
   |            ^ second consumption here
   |
   = help: after passing `f` to `read_all`, you no longer own it
```

**Borrow escape**
```
error[E0301]: reference cannot escape its region
  --> src/main.concrete:3:12
   |
 2 |     borrow data as r in R {
   |                       --- region R starts here
 3 |         return r
   |                ^ cannot return reference with region R
 4 |     }
   |     - region R ends here
   |
   = help: references are only valid within their borrow region
```

**Missing capability**
```
error[E0401]: function requires capability `Network` which is not available
  --> src/main.concrete:8:5
   |
 8 |     fetch(url)
   |     ^^^^^^^^^^ requires `Network`
   |
   = note: the current function has capabilities: {File, Alloc}
   = help: add `Network` to the function's capability declaration:
   |
 2 | fn process(url: String) with(File, Alloc, Network) -> Result<Data, Error>
   |                                    +++++++++
```

**Capability leak through closure**
```
error[E0402]: closure captures capability `File` but escapes its scope
  --> src/main.concrete:5:18
   |
 5 |     let handler = fn() { read(&config_file) }
   |                   ^^^^ this closure requires `File`
 6 |     return handler
   |            ------- closure escapes here
   |
   = help: closures that escape cannot capture capabilities
   = help: pass the file as a parameter instead
```

**Mutable borrow conflict**
```
error[E0302]: cannot borrow `data` as immutable because it is already borrowed as mutable
  --> src/main.concrete:4:17
   |
 3 |     borrow mut data as m in R {
   |                       - mutable borrow occurs here
 4 |         let len = length(&data)
   |                          ^^^^^ immutable borrow attempted here
   |
   = help: mutable borrows are exclusive; no other borrows allowed
```

**Unsafe operation without capability**
```
error[E0501]: operation requires `Unsafe` capability
  --> src/main.concrete:6:5
   |
 6 |     ptr_read(addr)
   |     ^^^^^^^^^^^^^^ unsafe operation
   |
   = note: reading from raw pointers may cause undefined behavior
   = help: add `Unsafe` to the function's capabilities:
   |
 2 | fn dangerous(addr: Address[Int]) with(Unsafe) -> Int
   |                                  ++++++++++++
```

## References

### Languages

- [Lean 4](https://lean-lang.org/) — theorem prover and programming language
- [Austral](https://austral-lang.org/) — linear types and capabilities for systems programming
  - [Specification](https://austral-lang.org/spec/spec.html)
- [Rust](https://www.rust-lang.org/) — ownership, borrowing, traits
- [Zig](https://ziglang.org/) — explicit allocators, defer, no hidden control flow
- [Roc](https://www.roc-lang.org/) — pure functional, `!` for effects
- [Koka](https://koka-lang.github.io/koka/doc/index.html) — algebraic effects and handlers
- [Eff](https://www.eff-lang.org/) — algebraic effects research language
- [Frank](https://github.com/frank-lang/frank) — effects as calling conventions
- [Clean](https://clean.cs.ru.nl/) — uniqueness types, pure by default
- [ATS](https://www.ats-lang.org/) — linear types with theorem proving
- [Cyclone](https://cyclone.thelanguage.org/) — region-based memory for C
- [Ada/SPARK](https://www.adacore.com/about-spark) — formal verification in systems programming

### Verified Systems

- [CompCert](https://compcert.org/) — verified C compiler
- [seL4](https://sel4.systems/) — verified microkernel
- [CertiKOS](https://flint.cs.yale.edu/certikos/) — verified concurrent OS kernel
- [Iris](https://iris-project.org/) — higher-order concurrent separation logic

### Papers

- [Linear Logic](https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html) — Wadler's papers on linear logic
- [Linearity and Uniqueness: An Entente Cordiale](https://granule-project.github.io/papers/esop22-paper.pdf) — linear vs unique vs affine
- [Cyclone](https://cyclone.thelanguage.org/) — region-based memory safety for C
- [An Introduction to Algebraic Effects and Handlers](https://www.eff-lang.org/handlers-tutorial.pdf) — Matija Pretnar
- [Capability Myths Demolished](https://srl.cs.jhu.edu/pubs/SRL2003-02.pdf) — what capabilities actually provide
- [The Next 700 Programming Languages](https://www.cs.cmu.edu/~crary/819-f09/Landin66.pdf) — Landin's classic
- [Hints on Programming Language Design](https://www.cs.yale.edu/flint/cs428/doc/HintsPL.pdf) — Tony Hoare
- [Growing a Language](https://www.cs.virginia.edu/~evans/cs655/readings/steele.pdf) — Guy Steele
- [RustBelt: Securing the Foundations of the Rust Programming Language](https://plv.mpi-sws.org/rustbelt/popl18/paper.pdf) — formal verification of Rust
- [Stacked Borrows: An Aliasing Model for Rust](https://plv.mpi-sws.org/rustbelt/stacked-borrows/paper.pdf) — Ralf Jung on aliasing
- [Ownership is Theft: Experiences Building an Embedded OS in Rust](https://patpannuto.com/pubs/levy15ownership.pdf) — Tock OS
- [A History of Haskell: Being Lazy with Class](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/07/history.pdf) — design decisions
- [Why Functional Programming Matters](https://www.cs.kent.ac.uk/people/staff/dat/miranda/whyfp90.pdf) — John Hughes
- [On the Criteria To Be Used in Decomposing Systems into Modules](https://www.win.tue.nl/~wstomv/edu/2ip30/references/criteria_for_modularization.pdf) — Parnas
- [Clean](https://clean.cs.ru.nl/) — uniqueness types specification
- [Using Lightweight Formal Methods to Validate a Key-Value Storage Node](https://www.amazon.science/publications/using-lightweight-formal-methods-to-validate-a-key-value-storage-node-in-amazon-s3) — practical verification at AWS

### Blog Posts

**Language Design Philosophy**
- [Worse is Better](https://www.dreamsongs.com/RiseOfWorseIsBetter.html) — Richard Gabriel on simplicity vs correctness
- [The Hundred-Year Language](https://paulgraham.com/hundred.html) — Paul Graham
- [Less is more: language features](https://blog.ploeh.dk/2015/04/13/less-is-more-language-features/) — Mark Seemann on constraints
- [Out of the Tar Pit](https://curtclifton.net/papers/MosessonClifton06.pdf) — Moseley and Marks on complexity
- [Design Principles Behind Smalltalk](https://www.cs.virginia.edu/~evans/cs655/readings/smalltalk.html) — Dan Ingalls
- [What to Know Before Debating Type Systems](https://cdsmith.wordpress.com/2011/01/09/an-old-article-i-wrote/) — Chris Smith
- [Execution in the Kingdom of Nouns](https://steve-yegge.blogspot.com/2006/03/execution-in-kingdom-of-nouns.html) — Steve Yegge

**Austral and Linear Types**
- [Introducing Austral](https://borretti.me/article/introducing-austral) — Fernando Borretti's rationale
- [How Austral's Linear Type Checker Works](https://borretti.me/article/how-australs-linear-type-checker-works) — implementation decisions
- [How Capabilities Work in Austral](https://borretti.me/article/how-capabilities-work-austral) — how capabilities compose
- [Type Systems for Memory Safety](https://borretti.me/article/type-systems-memory-safety) — survey of approaches
- [Linear types can change the world!](https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html) — Wadler
- [Retrofitting Linear Types](https://www.tweag.io/blog/2017-03-13-linear-types/) — adding linear types to Haskell

**Rust Design Decisions**
- [The Problem with Single-threaded Shared Mutability](https://manishearth.github.io/blog/2015/05/17/the-problem-with-shared-mutability/) — why shared mutability is forbidden
- [Rust: A unique perspective](https://limpet.net/mbrubeck/2019/02/07/rust-a-unique-perspective.html) — ownership from first principles
- [The Edition Guide: Non-Lexical Lifetimes](https://doc.rust-lang.org/edition-guide/rust-2018/ownership-and-lifetimes/non-lexical-lifetimes.html) — why NLL moved beyond lexical scopes
- [Polonius: the future of the borrow checker](https://smallcultfollowing.com/babysteps/blog/2018/04/27/an-alias-based-formulation-of-the-borrow-checker/) — Niko Matsakis
- [After NLL: Moving from borrowed data](https://smallcultfollowing.com/babysteps/blog/2018/11/10/after-nll-moving-from-borrowed-data-and-the-sentinel-pattern/) — borrow checker limitations
- [Ralf Jung's Blog](https://www.ralfj.de/blog/) — Stacked Borrows, unsafe, formal semantics
- [Learn Rust With Entirely Too Many Linked Lists](https://rust-unofficial.github.io/too-many-lists/) — ownership through pain
- [The Rustonomicon](https://doc.rust-lang.org/nomicon/) — dark arts of unsafe

**Graydon Hoare (Rust creator)**
- [The Rust I Wanted Had No Future](https://graydon2.dreamwidth.org/307105.html) — original vision
- [Not Rust](https://graydon2.dreamwidth.org/307291.html) — what Rust deliberately avoided
- [What next for compiled languages?](https://graydon2.dreamwidth.org/253769.html) — language evolution

**Zig Design Decisions**
- [Allocgate](https://github.com/ziglang/zig/issues/10052) — why Zig's allocator design changed
- [What is Zig's Comptime](https://kristoff.it/blog/what-is-zig-comptime/) — compile-time execution design

**Effects and Capabilities**
- [Algebraic Effects for the Rest of Us](https://overreacted.io/algebraic-effects-for-the-rest-of-us/) — Dan Abramov
- [What Color is Your Function?](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/) — Bob Nystrom on effect tracking
- [Structured Concurrency](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/) — Nathaniel Smith
- [Eff Programming Language](https://www.eff-lang.org/) — algebraic effects research language
- [Koka: Programming with Row-polymorphic Effect Types](https://koka-lang.github.io/koka/doc/book.html) — official book

**Roc and Purity**
- [Roc FAQ](https://www.roc-lang.org/faq) — official FAQ and design rationale
- [Why Roc Uses Platform/App Split](https://www.roc-lang.org/platforms) — effect isolation design

**Go Design Decisions**
- [Go at Google: Language Design in the Service of Software Engineering](https://go.dev/talks/2012/splash.article) — Rob Pike
- [Simplicity is Complicated](https://go.dev/talks/2015/simplicity-is-complicated.slide) — Rob Pike
- [Errors are values](https://go.dev/blog/errors-are-values) — Rob Pike
- [Go Proverbs](https://go-proverbs.github.io/) — design philosophy
- [Toward Go 2](https://go.dev/blog/toward-go2) — Russ Cox on language evolution

**Memory and Allocators**
- [Untangling Lifetimes: The Arena Allocator](https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator) — Ryan Fleury
- [Always Bump Downwards](https://fitzgeraldnick.com/2019/11/01/always-bump-downwards.html) — Nick Fitzgerald
- [Memory Allocation Strategies](https://www.gingerbill.org/series/memory-allocation-strategies/) — Bill Hall's series

**Error Handling Design**
- [The Error Model](https://joeduffyblog.com/2016/02/07/the-error-model/) — Joe Duffy on Midori's approach
- [Error Handling in a Correctness-Critical Rust Project](https://sled.rs/errors) — sled database

**Formal Methods in Practice**
- [Proofs About Programs](https://www.hillelwayne.com/post/theorem-prover-showdown/) — Hillel Wayne
- [Formal Methods Only Solve Half My Problems](https://brooker.co.za/blog/2022/06/02/formal.html) — Marc Brooker at AWS
- [How AWS Uses Formal Methods](https://lamport.azurewebsites.net/tla/amazon-excerpt.html) — Amazon's TLA+ experience

**Lean 4**
- [Functional Programming in Lean](https://lean-lang.org/functional_programming_in_lean/) — official book
- [Theorem Proving in Lean 4](https://lean-lang.org/theorem_proving_in_lean4/) — official book
- [Metaprogramming in Lean 4](https://github.com/leanprover-community/lean4-metaprogramming-book) — macros and tactics

**Type System Design**
- [Parse, Don't Validate](https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/) — Alexis King
- [Names Are Not Type Safety](https://lexi-lambda.github.io/blog/2020/11/01/names-are-not-type-safety/) — Alexis King
- [Types as Axioms, or: Playing God with Static Types](https://lexi-lambda.github.io/blog/2020/08/13/types-as-axioms-or-playing-god-with-static-types/) — Alexis King
- [The Expression Problem](https://homepages.inf.ed.ac.uk/wadler/papers/expression/expression.txt) — Philip Wadler

**Bob Harper**
- [Dynamic languages are static languages](https://existentialtype.wordpress.com/2011/03/19/dynamic-languages-are-static-languages/)
- [Modules matter most](https://existentialtype.wordpress.com/2011/04/16/modules-matter-most/)

### Talks

- [Effects for Less](https://www.youtube.com/watch?v=0jI-AlWEwYI) — Alexis King on effects (essential)
- [The Road to Zig 1.0](https://www.youtube.com/watch?v=Unq712gqu2U) — Andrew Kelley
- [Is It Time to Rewrite the OS in Rust?](https://www.youtube.com/watch?v=HgtRAbE1nBM) — Bryan Cantrill
- [Propositions as Types](https://www.youtube.com/watch?v=IOiZatlZtGU) — Philip Wadler
- [Correctness by Construction](https://www.youtube.com/watch?v=nV3r1rB5_6E) — Derek Dreyer on RustBelt
- [Simple Made Easy](https://www.infoq.com/presentations/Simple-Made-Easy/) — Rich Hickey
- [Constraints Liberate, Liberties Constrain](https://www.youtube.com/watch?v=GqmsQeSzMdw) — Runar Bjarnason
- [Growing a Language](https://www.youtube.com/watch?v=_ahvzDzKdB0) — Guy Steele (watch this)
- [Why Algebraic Effects Matter](https://www.youtube.com/watch?v=7GcrT0SBSnI) — Daan Leijen
- [Outperforming Imperative with Pure Functional Languages](https://www.youtube.com/watch?v=vzfy4EKwG_Y) — Richard Feldman
- [Why Roc?](https://www.youtube.com/watch?v=cpQwtwVKAfU) — Richard Feldman
- [Preventing the Collapse of Civilization](https://www.youtube.com/watch?v=pW-SOdj4Kkk) — Jonathan Blow on why new languages matter
- [Ideas about a new programming language for games](https://www.youtube.com/watch?v=TH9VCN6UkyQ) — Jonathan Blow on Jai
- [Linear Types for Low-latency, High-throughput Systems](https://www.youtube.com/watch?v=t0mhvd3-60Y) — Jean-Philippe Bernardy
- [seL4 and Formal Verification](https://www.youtube.com/watch?v=Sj3b8Sltx1s) — Gernot Heiser

### Books

- [Types and Programming Languages](https://www.cis.upenn.edu/~bcpierce/tapl/) — Pierce
- [Practical Foundations for Programming Languages](https://www.cs.cmu.edu/~rwh/pfpl/) — Harper
- [Certified Programming with Dependent Types](https://adam.chlipala.net/cpdt/) — Chlipala
- [Software Foundations](https://softwarefoundations.cis.upenn.edu/) — interactive Coq textbook
- [Programming Language Foundations in Agda](https://plfa.github.io/) — Wadler and Kokke
- [The Little Typer](https://mitpress.mit.edu/9780262536431/the-little-typer/) — Friedman and Christiansen
- [Crafting Interpreters](https://craftinginterpreters.com/) — Bob Nystrom

## Roadmap

Check out our feature roadmap [here](ROADMAP.md).
