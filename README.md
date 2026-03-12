<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![CI](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml/badge.svg)](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml)
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

Status: project entry point

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

Concrete is a systems programming language for **correctness-focused low-level work**. It is designed around a single organizing principle: **every design choice must answer the question, can a machine reason about this?** All code is explicit, machine-verifiable, LL(1)-parseable, with no hidden control flow.

Concrete's intended differentiator is not "more features". It is **auditable low-level programming with explicit authority and trust boundaries, on top of a small, honest, proof-friendly language and compiler**. See [docs/IDENTITY.md](docs/IDENTITY.md) for the explicit project identity.

The compiler is written in [Lean 4](https://leanprover.github.io/lean4/doc/setup.html), a theorem prover. The goal is a language whose core type system is mechanically verified: proofs of progress, preservation, linearity soundness, and effect soundness, checked by Lean itself.

Concrete is also being shaped so that this proof story does not stop at the compiler. The long-term goal is not only to formalize the language/compiler in Lean, but also to make selected Concrete programs provable in Lean through explicit Core semantics.

**No other language combines all four: linear types, a capability-based effect system, a compiler written in a theorem prover, and a design optimized for machine-generated code.**

In practical terms, Concrete is trying to give low-level programmers something unusual: the control and auditability of systems programming, but with much stronger guarantees about resources, effects, and compiler meaning.

## Why Concrete Exists

Concrete was created to close a gap between low-level programming and mechanized reasoning.

Systems languages usually optimize for control, performance, and interoperability. Proof systems usually optimize for expressing and checking mathematical claims. Concrete is trying to meet in the middle: a low-level language where authority, resources, cleanup, trust boundaries, and compiler meaning stay explicit enough to inspect, audit, and eventually prove.

In one sentence: Concrete exists to make low-level programming explicit enough to audit, honest enough to trust, and structured enough to eventually prove.

## Two Lean Goals

Concrete's Lean story has two different goals.

1. **Prove the language/compiler in Lean.**
   This means proving properties about the language definition and compiler pipeline itself: soundness, ownership/resource rules, effect/capability discipline, and preservation across internal compiler boundaries.
2. **Prove selected Concrete programs in Lean.**
   This means proving properties about particular user functions written in Concrete, through formalized Core semantics. The question is no longer "is the compiler coherent?" but "does this function satisfy its specification?"

The difference matters:

- compiler/language proofs give **language trust**
- program proofs give **program trust**

Concrete is aiming for both, in that order. See [docs/IDENTITY.md](docs/IDENTITY.md) for the project identity and [research/proving-concrete-functions-in-lean.md](research/proving-concrete-functions-in-lean.md) for the longer proof direction.

## What Makes Concrete Different

Compared to Lean itself, Concrete is a low-level programming language first, not a proof assistant. The point is not to replace Lean. The point is to write real systems code in a language whose semantics stay close enough to formal reasoning that Lean can still talk about it.

Compared to Rust, C, Zig, Odin, and similar systems languages, Concrete is more explicitly centered on auditability, explicit authority/trust boundaries, and a compiler architecture shaped for formal reasoning. It does not need to out-compete those languages on every feature, ecosystem, or toolchain axis to be valuable.

Compared to verification-first languages and tools, Concrete is trying to remain a real low-level systems language with explicit FFI, layout, ownership, trust, and runtime concerns, while still keeping a credible path to proving selected programs.

For the full language specification, see [The Concrete Programming Language: Systems Programming for Formal Reasoning](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/).

## Doc Map

- [README.md](README.md) — start here: project overview, status, build/test usage
- [docs/IDENTITY.md](docs/IDENTITY.md) — what Concrete is optimizing for and what differentiates it
- [ROADMAP.md](ROADMAP.md) — active and future work
- [CHANGELOG.md](CHANGELOG.md) — completed milestones
- [docs/README.md](docs/README.md) — stable reference docs
- [docs/PASSES.md](docs/PASSES.md) — pass-by-pass ownership boundaries and contracts
- [docs/TESTING.md](docs/TESTING.md) — test suites, coverage layers, and verification flow
- [research/README.md](research/README.md) — exploratory design notes
- [research/ten-x-improvements.md](research/ten-x-improvements.md) — the biggest long-term multipliers for Concrete
- [research/complete-language-system.md](research/complete-language-system.md) — what still separates a strong language/compiler from a complete system

## Snapshot

What Concrete has today:

- a full Lean 4 compiler pipeline through Core and SSA
- explicit capabilities, linear ownership, borrows, `defer`, trait dispatch, FFI, and layout attributes
- structured diagnostics across the semantic pipeline, with native `Diagnostics` through the main semantic passes
- explicit audit/report outputs
- explicit `trusted fn` / `trusted impl` boundaries for internal pointer-level implementation unsafety
- a coherent trust/effect model across builtins, stdlib, and user code
- a first real stdlib foundation: stronger `vec`, `string`, `io`, plus `bytes`, `slice`, `text`, `path`, `fs`, `env`, `process`, `net`, `fmt`, `hash`, `rand`, `time`, and `parse`
- foundational collections beyond `Vec`: `HashMap`, `HashSet`, `Deque`, `BinaryHeap`, `OrderedMap`, `OrderedSet`, and `BitSet`
- stdlib systems-layer hardening: typed errors across `fs`/`net`/`process`/`io`, checked/unchecked splits in `bytes`, `Option`-returning accessors in `env`
- stdlib deepening: `fmt` (integer/hex/bin/oct/bool formatting, padding), `hash` (FNV-1a), `rand` (deterministic seeding, bounded range), `time` (monotonic clock, sleep, unix timestamp), and `parse` (value parsing plus `Cursor`)
- stdlib uniformity: generic `Result<T, ModuleError>` across all modules, `parse` module (inverse of `fmt`), checked accessors on `String` and `Vec`
- built-in test runner: `concrete file.con --test` compiles and runs all `#[test]` functions, including stdlib module tests via `concrete std/src/lib.con --test`

What is still clearly missing:

- `transmute`
- structured non-string LLVM backend
- backend plurality over SSA (for example MLIR / C / Wasm)
- kernel formalization
- runtime
- stdlib deepening: stronger systems ergonomics, API cleanup, and later iterator/collection polish

## Try It Now

```
struct Counter {
    value: Int,
}

impl Counter {
    fn inc(&mut self) {
        self.value = self.value + 1;
    }
}

fn read_and_count(path: String) with(File) -> Result<Int, String> {
    let text: String = read_file(path)?;
    let mut c: Counter = Counter { value: 0 };

    if string_contains(text, "Concrete") {
        c.inc();
    }

    return Ok(c.value);
}

fn main!() -> Int {
    match read_and_count("README.md") {
        Ok(n) => return n,
        Err(_) => return 0,
    }
}
```

```bash
make build
.lake/build/bin/concrete input.con -o output && ./output
```

This example is small, but it already shows the core shape of the language:

- explicit capabilities (`with(File)`)
- explicit error propagation with `?`
- plain structs and methods
- no hidden effects in the pure-looking parts

Linear values work today too. The compiler rejects programs that forget or reuse resources:

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

Here is the low-level boundary in a smaller example:

```con
extern fn puts(ptr: *const u8) -> i32;

fn print_raw(s: &String) with(Unsafe) {
    let ptr: *const u8 = &s.ptr as *const *mut u8 as *const u8;
    puts(ptr);
}
```

This shows the intended rule:

- FFI is explicit
- raw pointers are explicit
- `Unsafe` is explicit
- crossing the boundary is visible in the function signature

## The Language Model

Concrete is trying to make five things obvious in source code:

1. whether a function is pure or effectful
2. where resources are acquired and destroyed
3. whether a value is copied, borrowed, or consumed
4. whether control flow is explicit
5. where unsafe or foreign code begins

That drives the whole surface language.

## Why This Matters For Low-Level Work

Concrete is not trying to be “safe” by hiding the machine. It is trying to make low-level code easier to trust.

For low-level programming, that means:

- FFI boundaries stay explicit
- resource destruction stays explicit
- allocation stays explicit
- side effects stay explicit
- unsafe operations stay explicit
- ownership and borrowing are checked instead of left to convention

The goal is not convenience-first systems programming. The goal is code that is still close to the machine, but substantially easier to audit, reason about, and eventually verify.

The deeper security goal is not only memory safety. It is making trust boundaries explicit and inspectable: where authority enters, where allocation happens, where foreign code begins, where trusted implementation techniques are used, and later, where proofs justify those boundaries. Concrete is trying to make those facts visible to both the compiler and the reviewer.

Readability is part of that correctness story. Low-level code that is hard to read is harder to audit, harder to review, and easier to misuse. Concrete treats readability as a design constraint, not just a style preference.

That is also why feature restraint matters. New language features should not be judged only by whether they are expressive; they should also be judged by their audit cost, proof cost, and grammar cost.

### Pure by default, effects declared

Functions without capability annotations are pure. No side effects, no allocation, no I/O. When a function needs effects, it declares them with `with()`:

- A function without `with()` is pure. It cannot call any function that has `with()`
- If `f` calls `g`, and `g` requires `Network`, then `f` must declare `Network`
- Capabilities propagate monotonically through the call graph
- `grep with(Network)` finds every function that touches the network
- Your JSON parser has no capabilities? Then it *provably* can't phone home

Predefined capabilities: `File`, `Network`, `Console`, `Env`, `Process`, `Alloc`, `Unsafe`. `Std` includes all except `Unsafe`. Users cannot define new capabilities.

### Linear values and explicit destruction

Concrete has linear types: use **exactly** once. Forgetting a resource is a compile error, not silent cleanup.

- `defer destroy(x)` schedules cleanup at scope exit, LIFO order (like Zig/Go)
- `defer` reserves the value: cannot move `x` after deferring its destruction
- `destroy(x)` is only valid if the type defines a destructor
- Types without a destructor must be consumed by moving, returning, or destructuring
- `Copy` is explicit and opt-in. A `Copy` type cannot have a destructor and cannot contain linear fields

### Borrowing instead of hidden aliasing

Concrete supports explicit shared and mutable borrows:

- `&T` is a shared borrow
- `&mut T` is an exclusive borrow
- borrow regions are explicit when a borrow must span multiple statements
- mutation flows through `&mut`, not through hidden interior mutability in safe code

### No hidden control flow or hidden work

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

### Unsafe is a boundary

Unsafe or foreign-facing operations are supposed to stay sharply visible:

- FFI is declared with `extern fn`
- raw pointers are explicit types (`*const T`, `*mut T`)
- unsafe operations are gated by `with(Unsafe)`
- the intended audit story stays simple: `grep with(Unsafe)` should find the boundary

### Long-term verification goal

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

### Why not Rust, Go, or Zig?

Concrete is closest in spirit to Rust and Zig, but it is aiming at a different balance.

- Compared to Rust: Concrete is trying to keep the surface language smaller and more explicit, with stricter rejection of hidden control flow, hidden dispatch, and trait-heavy abstraction styles.
- Compared to Go: Concrete wants much stronger compile-time guarantees about ownership, effects, and low-level correctness.
- Compared to Zig: Concrete shares the explicit low-level mindset, but pushes harder on static reasoning, linear ownership, and eventually formal verification.

The goal is not to out-feature those languages. The goal is to be unusually good at auditable, correctness-focused systems code.

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

The compiler implements the core surface language and the full internal IR pipeline in Lean 4. All 488 tests pass in the main suite, and the SSA-specific suite passes as well.

## Known Rough Edges

- stdlib direct compilation/testing is still being tightened so `std/src/*.con` follows the exact same path as ordinary user modules.
- some docs still lag behind recent stdlib naming/API cleanup and need periodic sync with landed `main`.
- builtin-vs-stdlib cleanup is still active in a few areas where older compiler-known hooks remain.
- diagnostics infrastructure is strong, but rendering quality still has room to improve (ranges, notes, and secondary labels).
- formal proofs and deferred audit outputs such as allocation/cleanup summaries are still ahead, not done.

Implemented today:

- a single staged Lean 4 compiler pipeline: Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → SSAVerify → SSACleanup → EmitSSA → clang
- explicit cacheable artifact types at each pipeline boundary (`Concrete/Pipeline.lean`), with composable runner functions and a shared frontend helper
- structured diagnostics across all semantic passes
- source spans in the AST and rendered diagnostics
- SSA as the only real backend path
- `trusted fn` / `trusted impl` through the parser, Core pipeline, CoreCheck, and audit reports
- builtins, stdlib, and user code aligned under one explicit trust/effect model

Still in progress:

- diagnostics quality and rendering polish
- optimizer work
- kernel formalization
- runtime maturity

See [ROADMAP.md](ROADMAP.md) for active priorities and remaining work. What works today:

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
- **Unsafe boundary**: raw pointer dereference/assignment and pointer-involving casts require `Unsafe`; reference-to-pointer casts remain safe
- **Compiler pipeline**: source spans in the AST, Resolve, Core IR (`--emit-core`), elaboration, Core validation, monomorphization, SSA lowering (`--emit-ssa`), SSA verification/cleanup, SSA-based compilation
- **Collections builtins**: `Vec<T>` and `HashMap<K,V>` operations with explicit `Alloc` requirements
- **Networking builtins**: TCP connect/listen/accept and socket send/recv/close under `Network`
- **Standard library builtins**:
  - **Strings**: `string_length`, `string_concat`, `string_slice`, `string_char_at`, `string_contains`, `string_eq`, `string_trim`, `drop_string`
  - **Conversions**: `int_to_string`, `string_to_int`, `bool_to_string`, `float_to_string`
  - **I/O**: `print_int`, `print_bool`, `print_string`, `print_char`, `eprint_string`, `read_line` (require Console)
  - **File**: `read_file`, `write_file` (require File)
  - **System**: `get_env` (requires Env), `exit_process` (requires Process)

### What this means today

Concrete is already usable for small low-level programs that need:

- explicit ownership and borrowing
- explicit effect tracking
- predictable control flow
- direct FFI and raw-pointer escape hatches
- inspectable internal stages (`--emit-core`, `--emit-ssa`)

That already makes it more than a language-design experiment. The current implementation is moving toward a compiler and language that are specifically strong for auditable, correctness-sensitive systems code.

It is not finished in the places that matter for broader adoption:

- no verified kernel yet
- no finalized ABI/layout model beyond the current `#[repr(C)]` baseline
- no optimizer/MLIR pipeline yet
- runtime story still incomplete

### Design Constraints

Concrete is trying to stay strong by staying narrow.

- no hidden control flow
- no hidden allocation
- no trait objects
- no closures
- no operator overloading
- no implicit conversions

Those constraints are part of the language design, not temporary omissions.

## High-Leverage Priorities

The current surface language is intentionally conservative. The highest-leverage next work is architectural sharpening, not a rush of new surface features.

In order, the strongest next improvements are:

- **Cacheable compiler artifacts**: DONE — `Concrete/Pipeline.lean` defines explicit artifact types (`ParsedProgram`, `SummaryTable`, `ResolvedProgram`, `ElaboratedProgram`, `MonomorphizedProgram`, `SSAProgram`) and composable runner functions; `Main.lean` consumes these boundaries instead of threading types through ad-hoc `match` chains
- **Small SSA optimization group**: DONE — `SSACleanup.lean` covers constant folding, dead code elimination, CFG cleanup, and trivial phi/copy cleanup
- **Diagnostics infrastructure**: build on typed errors with better ranges, notes, and rendering
- **Stdlib hardening**: typed errors, checked/unchecked splits, and deeper file/network/process ergonomics across the existing foundation
- **Explicit build/project model**: keep reproducibility, target configuration, and FFI setup boring and visible

Already established architecture in this arc:

- **Summary-based frontend**: `FileSummary` and `ResolvedImports` now form the cross-file frontend boundary, with prebuilt function, extern, and impl-method signatures reused across `Resolve`, `Check`, and `Elab`
- **Core as semantic authority**: `CoreCheck` now owns post-elaboration legality checks that can be stated on Core IR; `Check` is mostly surface/inference-specific work
- **ABI/layout subsystem clarity**: `Layout.lean` is now the shared authority for size, alignment, field offsets, enum layout, LLVM type definitions, and FFI-safety checks used by both `CoreCheck` and `EmitSSA`
- **Audit-focused compiler outputs**: `--report caps|unsafe|layout|interface|mono` now exposes capability summaries, unsafe-signature summaries, layout reports, public interface summaries, and monomorphization reports

The main rule is: architecture before ornament, tooling visibility before convenience syntax, and proof-friendly boundaries before feature expansion.

## Stdlib Status

The standard library exists with a systems layer in place and a first hardening pass complete.

Current stdlib modules: `mem`, `alloc`, `libc`, `math`, `ptr`, `string`, `vec`, `io`, `test`, `option`, `result`, `bytes`, `slice`, `text`, `path`, `fmt`, `parse`, `hash`, `map`, `set`, `rand`, `time`, `fs`, `env`, `process`, `net`.

The current arc is hardening what exists rather than adding more surface area:

- typed error surfaces across `fs`, `net`, `process` (no more raw integer returns from syscalls)
- explicit checked/unchecked accessor split in `bytes`
- `Option`-returning APIs where absence is meaningful (`env::get`, `Bytes::get`)

Stdlib deepening now in place:

- `fmt` — integer/hex/bin/oct/bool formatting, left/right padding
- `parse` — inverse of `fmt`: value parsers (`parse_int`, `parse_uint`, `parse_hex`, `parse_bin`, `parse_oct`, `parse_bool`) + `Cursor` for structured input
- `hash` — FNV-1a for bytes and strings
- `rand` — deterministic seeding, bounded range
- `time` — monotonic clock, sleep, unix timestamp
- Unified error handling: generic `Result<T, ModuleError>` across all modules (`io`, `fs`, `net`, `process`)
- Systems deepening: `fs` helpers (`append_file`, `file_exists`, `read_to_string`), `net` helpers (`write_all`, `read_all`), `process` helpers (`spawn`, signal constants)

The next stdlib focus: deeper systems-module polish, stronger failure-path and integration testing, and carefully chosen collections

See [`docs/STDLIB.md`](docs/STDLIB.md) for the stable stdlib direction.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for active priorities, remaining major work, and sequencing.
See [CHANGELOG.md](CHANGELOG.md) for completed milestones and major landed architecture/language work.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PASSES.md](docs/PASSES.md) for the detailed compiler pipeline, artifact flow, pass boundaries, and compiler contracts.
See [docs/ABI_LAYOUT.md](docs/ABI_LAYOUT.md) for the current layout and FFI boundary, and [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) for the diagnostics model.
See [docs/FFI.md](docs/FFI.md) for the explicit foreign/unsafe boundary and [docs/STDLIB.md](docs/STDLIB.md) for the current stable stdlib direction.
See [docs/TESTING.md](docs/TESTING.md) for the test structure.
See [docs/README.md](docs/README.md) for the stable documentation index and [research/README.md](research/README.md) for exploratory design notes.

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
| **11** | Structured LLVM backend + backend plurality over SSA | Not started |
| **12** | Kernel formalization + proofs | Not started |
| **13** | Tooling | Not started |
| **14** | Runtime (C, then Concrete) | Not started |

Next critical path: **keep deepening the stdlib and its test infrastructure, improve diagnostics quality, then push formalization.** The summary-based frontend, `CoreCheck` semantic-authority shift, ABI/layout subsystem, cacheable pipeline artifacts (`Concrete/Pipeline.lean`), SSA cleanup, audit/report outputs, structured diagnostics, and the trusted/effect coherence migration are done enough for the current architecture phase.

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
  Resolve.lean -- current early name-resolution pass
    |
    v
  Check.lean -- frontend checker with structured errors
    |
    v
  Elab.lean -- surface AST -> Core IR with structured errors
    |
    v
  CoreCheck.lean -- Core validation
    |
    v
  Mono.lean -- Core monomorphization
    |
    v
  Lower.lean -- Core IR -> SSA IR
    |
    v
  SSAVerify.lean / SSACleanup.lean -- SSA validation + cleanup
    |
    v
  EmitSSA.lean -- LLVM IR from SSA (default path)
    |
    v
  clang -- LLVM IR -> native binary
```

Concrete's frontend is currently a staged whole-program pipeline, and the summary layer is now its established cross-file boundary: `FileSummary` acts as the declaration-level interface artifact, `ResolvedImports` is the per-module imported-summary artifact, and `Check`/`Elab` share a summary-driven import path over prebuilt function, extern, and impl-method signatures. Impl method summaries preserve `Self` structurally in the summary artifact and use a shared `resolveSelfTy` helper for pass-local interpretation, which keeps the artifact close to the source-level declaration shape. `FileSummary` and `ResolvedImports` still carry full impl/trait-impl bodies because imported method checking and elaboration need them today; splitting interface-only and body-bearing portions is a future incremental-compilation refinement, not a blocker for the current architecture phase. In parallel, semantic authority has been pushed down into `CoreCheck`: it owns more Core capability enforcement for lowered operations and builtins, return-type checking, more match validation, and declaration-level trait/FFI/repr rules. At this point, most of what remains in `Check` is the surface-context-dependent work: linearity/borrow tracking, type inference, name resolution fallout, and cap-polymorphic call handling. The language design is deliberately trying to make that possible: LL(1) syntax, explicit imports, and no source-generating macros in the current design. The goal is a compiler that is easier to reason about, easier to parallelize, and better aligned with the long-term verification story. See [research/file-summary-frontend.md](research/file-summary-frontend.md).

Target pipeline:

```
Surface AST → Resolve → Elaborate → CoreCanonicalize → CoreCheck → Monomorphize → Lower → SSAVerify → SSACleanup → SSA Codegen → structured LLVM backend → binary
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs all 488 tests
make clean    # or: lake clean
```

## Project Structure

```
Concrete/
  Token.lean     -- Token types
  Lexer.lean     -- Tokenizer
  AST.lean       -- Abstract syntax tree
  Parser.lean    -- LL(1) recursive descent parser
  Resolve.lean   -- Early name resolution
  Check.lean     -- Frontend checker
  Core.lean      -- Core IR
  Elab.lean      -- Surface AST -> Core IR
  CoreCheck.lean -- Core validation
  Mono.lean      -- Core monomorphization
  Lower.lean     -- Core IR -> SSA IR
  SSA.lean       -- SSA IR
  SSAVerify.lean -- SSA validation
  SSACleanup.lean -- SSA cleanup
  EmitSSA.lean   -- LLVM IR from SSA
  Pipeline.lean  -- Cacheable artifact types and composable pipeline runners
Main.lean        -- Entry point
lean_tests/      -- 344 test programs
examples/        -- 66 example programs
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
- ~15,500 lines of Lean across parser, checker, Core IR, SSA pipeline, and backends
- Direct textual LLVM IR emission from the SSA backend, compiled with `clang`
- Real staged pipeline: Parse -> Resolve -> Check -> Elab -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA
- Structured diagnostics across the semantic pipeline, with source spans in the AST and typed errors in `Resolve`, `Check`, `Elab`, `CoreCheck`, and `SSAVerify`
- Clear path to formal verification because the compiler is already implemented in Lean and now has explicit internal IR boundaries

**Next steps:**
- Strengthen shared diagnostics infrastructure with richer spans, secondary labels/notes, and phase-aware rendering
- Then deepen with carefully chosen collections and more systems-module polish
- Push kernel formalization and proof development in Lean

## License

[Apache 2.0](/LICENSE)
