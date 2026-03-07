# Concrete Roadmap

This is the implementation plan for the Concrete programming language. For the full specification, see [The Concrete Programming Language: Systems Programming for Formal Reasoning](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/).

## What's Built

The Lean 4 compiler implements the core surface language in ~4,700 lines. All 59 tests pass. 58 of 59 examples from the [original Rust compiler](https://github.com/lambdaclass/concrete) compile and run.

**Done:**
- Lexer, LL(1) parser, AST
- Types: Int, Uint, i8-i32, u8-u32, f32, f64, Bool, Char, String, arrays `[T; N]`, raw pointers `*mut T` / `*const T`
- Structs with field access, mutation, and pass-by-pointer
- Enums with pattern matching (exhaustiveness checked, literal and variable patterns)
- Impl blocks with methods (`&self`, `&mut self`, `self`) and static methods
- Traits with static dispatch and signature checking
- Generics on functions, structs, and enums
- Borrowing: `&T` (shared) and `&mut T` (exclusive), with borrow checking
- Linear type system: structs consumed exactly once, branches must agree, loop restrictions
- Modules with `pub` visibility, imports, submodules, forward references
- Result type with `?` operator for error propagation
- Cast expressions (`as`) between numeric types
- Control flow: while, for (C-style and condition-only), if/else, match
- Constants, type aliases, extern fn declarations
- Direct LLVM IR text emission, compiled via clang to native binaries
- CI: build warnings check, 59 test suite, example compilation, runtime crash detection

**Not yet implemented:** Capabilities, closures, `defer`/`destroy`, `break`/`continue`, explicit `Copy` marker, allocator system, borrow regions, FFI safety (Unsafe gating), MLIR backend, kernel formalization, standard library, runtime.

---

## Phase 1: Capabilities (effect system)

The core differentiator. Every function declares which effects it may perform. No declaration = pure.

### Syntax

```
// Pure: no capabilities, no side effects
fn add(a: Int, b: Int) -> Int { return a + b; }

// Declares File capability
fn read_config(path: String) with(File) -> String { ... }

// Multiple capabilities
fn sync_data(url: String) with(File, Network, Alloc) -> Result<Data, Error> { ... }

// ! is sugar for with(Std)
fn main!() { ... }
```

### Rules

- A function without `with()` is pure — it cannot call any function that has `with()`
- If `f` calls `g`, and `g` requires `Network`, then `f` must declare `Network`
- Capabilities propagate monotonically through the call graph
- `Unsafe` capability gates FFI, raw pointer deref, transmute
- Predefined capabilities: `File`, `Network`, `Clock`, `Env`, `Random`, `Alloc`, `Unsafe`
- `Std` includes all predefined capabilities except `Unsafe`
- Users cannot define new capabilities
- Capabilities are checked before monomorphization — generic functions don't change capability requirements at different instantiations

### Capability polymorphism

Without this, generic combinators can't work:

```
// Without cap polymorphism — duplication explosion:
fn map_pure<T, U>(list: List<T>, f: fn(T) -> U) -> List<U> { ... }
fn map_file<T, U>(list: List<T>, f: fn(T) with(File) -> U) with(File) -> List<U> { ... }
```

Solution — capability variables:

```
fn map<T, U, cap C>(list: List<T>, f: fn(T) with(C) -> U) with(C) -> List<U> {
    match list {
        List#Nil => return List#Nil,
        List#Cons { head, tail } => {
            let new_head: U = f(head);
            let new_tail: List<U> = map(tail, f);
            return List#Cons { head: new_head, tail: new_tail };
        }
    }
}

// C is inferred from the passed function:
map(data, fn(x) { x * 2 })                     // C = {} (pure)
map(data, fn(x) with(File) { read_line(x) })   // C = {File}
```

Rules:
- `cap C` declares a capability variable in the generic parameter list, after type params
- A capability variable unifies with a concrete capability set at the call site
- The caller must have at least the inferred set: if `C = {File, Alloc}`, caller needs `with(File, Alloc)`
- Multiple cap vars allowed: `fn foo<T, cap C, cap D>(...)` for functions taking multiple function arguments with different effects
- `C` cannot be constructed or passed as a value — exists only in signatures

### Implementation

- **AST**: `FnDef` gets `capParams : List String` and `capSet : CapSet`. New `CapSet` type: `concrete (caps : List String) | var (name : String) | union (a b : CapSet)`. Function types carry a `CapSet`.
- **Token/Lexer**: Add `with_` keyword. Recognize capability names as identifiers.
- **Parser**: Parse `with(Cap1, Cap2)` after params and before `->`. Parse `cap C` in generic param lists. Parse `!` suffix on function name as sugar for `with(Std)`.
- **Check.lean**: Store each function's cap set in `FnSig`. At call sites, check `callerCaps ⊇ calleeCaps`. For cap variables: collect concrete caps from arguments' function types, unify, check propagation. Error: "function 'f' requires capability 'Network' but caller does not declare it".
- **Codegen**: No change. Capabilities are erased.

### Tests

- `cap_pure.con`: pure function cannot call effectful function → error
- `cap_propagation.con`: caller missing callee's capability → error
- `cap_basic.con`: `with(File)` function calls `with(File)` function → ok
- `cap_bang.con`: `main!()` can call anything → ok
- `cap_poly.con`: `map<T, U, cap C>` infers C from argument → ok

---

## Phase 2: Closures

Needed before `defer` and allocators because those features benefit from passing behavior as values.

### Syntax

```
// Anonymous function
let doubled: List<Int> = map(data, fn(x: Int) -> Int { return x * 2; });

// Type inference for closure params
let doubled: List<Int> = map(data, fn(x) { return x * 2; });

// Closures with capabilities
let handler: fn(Request) with(File) -> Response = fn(req: Request) with(File) -> Response {
    let data: String = read_file(req.path);
    return Response { body: data };
};

// Capture from enclosing scope
let offset: Int = 10;
let shifted: List<Int> = map(data, fn(x) { return x + offset; });
```

### Rules

- Closures capture variables from the enclosing scope
- Capture rules follow linearity:
  - Capturing a linear value **moves** it into the closure (original is consumed)
  - Capturing a `Copy` value copies it
  - Capturing a `&T` borrows it — closure cannot outlive the borrow region
  - Capturing a `&mut T` borrows exclusively — no other borrows while closure exists
- Closures that capture linear values are themselves linear (must be called exactly once)
- Closures that capture only `Copy` values are `Copy`
- Closure capabilities: if the body uses `with(File)`, the closure type carries `with(File)`
- Function types: `fn(Int) -> Bool` (pure), `fn(Int) with(File) -> Bool` (effectful)

### Implementation

- **AST**: `Expr.closure (params : List Param) (capSet : CapSet) (retTy : Option Ty) (body : List Stmt)`.
- **Parser**: When `fn` appears in expression position (not top level), parse as closure.
- **Check.lean**: Analyze closure body for free variables → those are captures. For each capture, apply move/copy/borrow rule. Compute closure's cap set from its body. Check captured borrows don't escape. Linear captures → linear closure type.
- **Codegen**: Lower to struct (captures) + function pointer. Generated function takes capture struct as hidden first param. Calls through closure: load fn ptr + capture struct, call with struct prepended to args.

### Tests

- `closure_basic.con`: simple closure, no captures → ok
- `closure_capture_copy.con`: capture Int (Copy) → ok, original still usable
- `closure_capture_move.con`: capture linear struct → original consumed
- `closure_linear.con`: closure with linear capture must be called exactly once
- `error_closure_escape_borrow.con`: capture &T that escapes → error

---

## Phase 3: Explicit resource management (`defer` + `destroy` + `Copy`)

Linear types that hold resources implement `Destroy`. Cleanup is always explicit. No implicit RAII.

### `destroy` as a trait

Uses the existing trait/impl model — no new declaration syntax:

```
// Destroy is a built-in trait
trait Destroy {
    fn destroy(self) -> Unit;
}

impl Destroy for File with(File) {
    fn destroy(self) -> Unit {
        close_handle(self.handle);
    }
}
```

### `defer`

```
fn process!() {
    let f: File = open("data.txt");
    defer destroy(f);           // schedules cleanup at scope exit

    let content: String = read(&f);
    // When scope exits: destroy(f) runs
}

// Multiple defers: LIFO order
fn multi!() {
    let f1: File = open("a.txt");
    defer destroy(f1);
    let f2: File = open("b.txt");
    defer destroy(f2);
    // On exit: destroy(f2), then destroy(f1)
}
```

### Explicit `Copy` marker

```
type Copy Point {
    x: Float64,
    y: Float64
}
```

### Rules

- `Destroy` is a built-in trait with one method: `fn destroy(self) -> Unit`
- `destroy(x)` is sugar for `x.destroy()` — consumes `x`
- `with()` on the impl declares capabilities the destructor needs
- `defer` schedules a statement to run at scope exit (LIFO, like Zig/Go)
- `defer destroy(x)` reserves the value: cannot move, cannot destroy again, cannot re-defer
- `defer` runs on normal exit, early return, and `?` error propagation
- `destroy(x)` is only valid if the type implements `Destroy`
- Types without `Destroy` must be consumed by moving, returning, or destructuring
- A type implementing `Destroy` cannot be `Copy`
- A `Copy` type cannot implement `Destroy` and cannot contain linear fields
- `Copy` is explicit and opt-in via `type Copy`
- Primitive types (Int, Bool, Float64, etc.) are built-in `Copy`
- `String` is linear
- `&T` is `Copy`; `&mut T` is not `Copy`

### Implementation

- **AST**: `Stmt.defer (body : Stmt)`. No new declaration — `Destroy` is a pre-registered `TraitDef`.
- **Token/Lexer**: Add `defer_` keyword.
- **Parser**: Parse `defer <stmt>;`. Parse `type Copy Name { ... }` for Copy-marked types. `impl Destroy for T { ... }` already parses.
- **Check.lean**: Pre-register `Destroy` trait. `destroy(x)` resolves as method call on `Destroy`. Track deferred values as "reserved" (not movable). Verify `Copy`/`Destroy` mutual exclusivity. For `Copy` types, verify all fields are `Copy`.
- **Codegen**: Collect `defer` statements per scope. Before every `ret` (including early returns and `?` propagation), emit deferred statements in reverse order. `destroy(x)` compiles to `TypeName_destroy(x)`.

### Tests

- `defer_basic.con`: defer runs at scope exit → ok
- `defer_lifo.con`: multiple defers run in reverse order → ok
- `defer_early_return.con`: defer runs on early return → ok
- `defer_try.con`: defer runs on `?` error propagation → ok
- `destroy_trait.con`: implement Destroy, call destroy() → ok
- `copy_marker.con`: Copy type can be used multiple times → ok
- `error_defer_move.con`: move after defer → error "reserved"
- `error_copy_destroy.con`: Copy type with Destroy impl → error
- `error_copy_linear_field.con`: Copy type containing linear field → error

---

## Phase 4: `break` and `continue`

### Syntax

```
// Simple break
while condition {
    if done { break; }
}

// Break with value (loop as expression)
let result: Int = while i < length(list) {
    let val: Int = get(list, i);
    if val % 2 == 0 { break val; }
    i = i + 1;
} else {
    0    // default if loop never breaks
};

// Continue
while i < n {
    i = i + 1;
    if skip(i) { continue; }
    process(i);
}
```

### Rules

- `break` exits the innermost loop
- `break expr` exits and produces a value (loop-as-expression)
- `continue` skips to the next iteration
- **Linear types**: `break`/`continue` must not skip over unconsumed linear values declared inside the loop. Linear variables from outside the loop remain live.
- `break` inside `defer` is forbidden
- Applies to innermost loop only (no labeled breaks in v1)
- For `break val`, all break expressions and the `else` clause must agree on type

### Implementation

- **AST**: `Stmt.break_ (value : Option Expr)`, `Stmt.continue_`. `Expr.whileExpr` for while-as-expression with else clause.
- **Token/Lexer**: Add `break_` and `continue_` keywords.
- **Parser**: Parse `break;`, `break expr;`, `continue;` inside loops.
- **Check.lean**: Track loop nesting depth. `break`/`continue` outside loop → error. Before `break`, verify inner linear variables consumed. For `break expr`, check type agreement.
- **Codegen**: `break` → `br label %loop.exit`. `continue` → `br label %loop.header`. For `break val`: pre-allocate result slot before loop, store before jump, load after loop. `else` clause stores into same slot.

### Tests

- `break_basic.con`: break exits loop → ok
- `break_value.con`: break with value, loop as expression → ok
- `continue_basic.con`: continue skips iteration → ok
- `error_break_outside.con`: break outside loop → error
- `error_break_linear.con`: break skips unconsumed linear variable → error

---

## Phase 5: Allocator system

Allocation is a capability with explicit allocator binding at call sites. Per-call binding, not scope-based — every allocation is visible on the line where it happens.

### Syntax

```
fn create_list<T>() with(Alloc) -> List<T> { ... }
fn push<T>(list: &mut List<T>, val: T) with(Alloc) { ... }

fn build_list() with(Alloc) -> List<Int> {
    let list: List<Int> = create_list<Int>();  // uses caller's bound allocator
    push(&mut list, 42);                       // uses caller's bound allocator
    return list;
}

fn main!() {
    let arena: Arena = Arena.new();
    defer arena.deinit();

    // Bind allocator for this call and nested with(Alloc) calls
    let list: List<Int> = build_list() with(Alloc = arena);

    // Different allocator for a different call
    let gpa: GeneralPurposeAllocator = GeneralPurposeAllocator.new();
    defer gpa.deinit();
    let temp: List<Int> = build_list() with(Alloc = gpa);
}
```

### Allocator trait

```
trait Allocator {
    fn alloc<T>(&mut self, count: Uint) -> Result<&mut T, AllocError>;
    fn free<T>(&mut self, ptr: &mut T);
    fn realloc<T>(&mut self, ptr: &mut T, new_count: Uint) -> Result<&mut T, AllocError>;
}
```

### Rules

- `with(Alloc)` in signature means the function may allocate
- `with(Alloc = expr)` at call site binds a specific allocator
- Inside the called function, nested `with(Alloc)` sub-calls use the bound allocator automatically
- Binding propagates down the call chain but every function in the chain must declare `with(Alloc)`
- If a function calls two `with(Alloc)` functions with different allocators, it binds each separately
- Stack allocation does not require `Alloc`
- A function without `with(Alloc)` cannot call anything with `with(Alloc)` — always explicit

### Why per-call, not scope-based

A scope-based binding like `with(Alloc = arena) { ... }` hides which lines inside the block allocate. Per-call is verbose but every allocation is visible on the line where it happens. You can audit a function line by line and know exactly what allocates.

### Implementation

- **AST**: `Expr.call` gets `allocBind : Option Expr`.
- **Parser**: After `)` of a function call, optionally parse `with(Alloc = expr)`.
- **Check.lean**: If calling a function with `Alloc` in its cap set, caller must either (a) have `Alloc` in its own cap set (propagation), or (b) provide `with(Alloc = expr)`. Verify expr implements `Allocator`.
- **Codegen**: Functions with `Alloc` get hidden `ptr %allocator` first parameter. `with(Alloc = arena)` → pass arena pointer. Without explicit binding (inside a `with(Alloc)` function) → forward received `%allocator`.

### Tests

- `alloc_basic.con`: bind allocator at call site → ok
- `alloc_propagate.con`: allocator propagates through nested calls → ok
- `alloc_different.con`: different allocators for different calls → ok
- `error_alloc_missing.con`: call with(Alloc) function without binding or declaring Alloc → error

---

## Phase 6: Borrow regions

Explicit lexical regions that bound reference lifetimes. Simpler than Rust — no lifetime annotations in function signatures.

### Three levels of explicitness

```
// Level 1: Inline borrow — anonymous region for one expression (already works today)
let len: Int = length(&f);

// Level 2: Block borrow — anonymous region for a block
let result: Data = with &db, &cache {
    let r: Data = query(&db, &cache);
    process(r)
};

// Level 3: Full explicit — named region, named reference
borrow db as db_ref in R {
    // db_ref has type &[Database, R]
    // db is unusable in this block
    let result: Data = query(db_ref);
}
// db is usable again
```

### Rules

- Level 1 (`&x` in expression): anonymous region spanning that expression. Already implemented.
- Level 2 (`with &x, &mut y { ... }`): anonymous region spanning the block. Originals frozen inside.
- Level 3 (`borrow x as y in R { ... }`): named region, named reference. Required when you need the region name in a type.
- All three desugar to the same kernel construct (borrow-in-region)
- While borrowed, the original is frozen (unusable)
- Multiple immutable borrows allowed; mutable borrows exclusive
- References cannot escape their region
- Closures cannot capture references that outlive the borrow region
- Functions are implicitly generic over regions — no lifetime params in signatures

### Implementation

- **AST**: `Stmt.borrowBlock (vars : List (String × Bool)) (body : List Stmt)` for Level 2. `Stmt.borrowIn (var : String) (ref : String) (region : String) (body : List Stmt)` for Level 3.
- **Token/Lexer**: Add `borrow_` keyword.
- **Parser**: Parse `with &x, &mut y { ... }` and `borrow x as y in R { ... }`.
- **Check.lean**: For all levels: freeze original, create reference binding, check body, unfreeze. For Level 3, register region name for use in types.
- **Codegen**: All produce same IR as current `&x` — pointer to storage. Regions are type-checker only, erased in codegen.

### Tests

- `borrow_block.con`: block borrow freezes original → ok
- `borrow_named.con`: named region, named reference → ok
- `error_borrow_escape.con`: reference escapes region → error
- `error_borrow_frozen.con`: use original inside borrow block → error

---

## Phase 7: FFI and C interop

Needed before the runtime (Phase 10a is written in C) and for any real-world systems programming use.

Basic `extern fn` declarations already exist. This phase adds safety gating through the `Unsafe` capability and C-compatible struct layout.

### Syntax

```
// Extern function declarations (basic parsing exists today)
extern fn malloc(size: Uint) -> *mut u8;
extern fn free(ptr: *mut u8);
extern fn write(fd: Int, buf: *const u8, count: Uint) -> Int;

// Calling extern functions requires Unsafe capability
fn allocate(size: Uint) with(Unsafe) -> *mut u8 {
    return malloc(size);
}

// C-compatible struct layout
#[repr(C)]
struct CPoint { x: f64, y: f64 }

// Passing structs to C
extern fn draw_point(p: *const CPoint);

fn render(p: &CPoint) with(Unsafe) {
    draw_point(p as *const CPoint);
}
```

### Rules

- `extern fn` declares a function with C ABI, no body
- Calling an `extern fn` requires `with(Unsafe)` — FFI is never silent
- Only C-compatible types in extern signatures: integer types, float types, `Bool`, raw pointers (`*mut T`, `*const T`)
- Structs with `#[repr(C)]` attribute get C-compatible memory layout (fields in declaration order, platform alignment)
- Structs without `#[repr(C)]` cannot be passed to extern functions by value
- No automatic string conversion — pass `*const u8` and length explicitly
- Raw pointer dereference requires `with(Unsafe)`
- `transmute` requires `with(Unsafe)`

### Implementation

- **AST**: `ExternFn` already exists. Add `Attr.reprC` to struct definitions. Add `Expr.transmute`.
- **Token/Lexer**: Add `unsafe_` as a recognized capability name. Add `#[repr(C)]` attribute parsing.
- **Parser**: Parse `#[repr(C)]` before struct definitions. Parse `transmute<T>(expr)`.
- **Check.lean**: Verify all `extern fn` call sites have `with(Unsafe)`. Verify extern param/return types are C-compatible. Verify `*ptr` dereference has `with(Unsafe)`. Verify `transmute` has `with(Unsafe)` and sizes match.
- **Codegen**: `extern fn` emits `declare` (already works). `#[repr(C)]` structs use C layout rules. `transmute` → `bitcast`.

### Tests

- `ffi_basic.con`: call extern fn with Unsafe → ok
- `ffi_repr_c.con`: pass #[repr(C)] struct to extern → ok
- `error_ffi_no_unsafe.con`: call extern fn without Unsafe → error
- `error_ffi_bad_type.con`: pass non-C-compatible type to extern → error

---

## Phase 8: MLIR backend

Replace direct LLVM IR text emission with MLIR-based compilation pipeline. This gives proper optimization passes, better diagnostics, and a foundation for multiple backends.

### Why

The current codegen emits LLVM IR as text strings — it works but has no optimization (every variable is an `alloca`, no inlining, no constant folding). MLIR provides structured IR construction, dialect-based lowering, and access to LLVM's full optimization pipeline.

### Architecture

```
Current:  Surface AST → Check → Codegen.lean (text emission) → .ll file → clang → binary
Target:   Surface AST → Check → Codegen.lean (MLIR API calls) → MLIR Module → LLVM IR → binary
```

### Phase 8a: Lean-MLIR FFI bindings

Build Lean 4 `@[extern]` bindings to the MLIR C API.

- Wrap core types: `MLIRContext`, `MLIRModule`, `MLIRBlock`, `MLIROperation`, `MLIRType`, `MLIRValue`
- Use [melior](https://github.com/raviqqe/melior) (Rust MLIR bindings) as design reference
- Build system: link against MLIR/LLVM shared libraries via `lakefile.lean`
- New file: `Concrete/MLIR/Bindings.lean`

### Phase 8b: LLVM dialect codegen

Replace `Codegen.lean` text emission with MLIR operation construction.

- Target LLVM dialect directly (1:1 mapping with current textual IR)
- Same semantics, structured construction instead of string concatenation
- New file: `Concrete/MLIR/Codegen.lean` (parallel to existing `Codegen.lean`)
- Validate: all 59 tests pass with MLIR backend
- Keep textual backend as fallback during transition

### Phase 8c: Optimization passes

Wire up LLVM optimization passes through MLIR's pass manager.

- `mem2reg` — promotes allocas to SSA registers (biggest single win)
- Dead code elimination, constant folding, inlining
- Add compiler flags: `-O0` (default, current behavior), `-O1`, `-O2`
- Benchmark: compare output binary performance textual vs MLIR

### Phase 8d: Custom Concrete dialect (future, optional)

A Concrete-specific MLIR dialect for domain-specific optimizations.

- Linear type annotations in IR for linearity-aware optimization
- Capability annotations for effect-guided dead code elimination
- Lower: Concrete dialect → LLVM dialect
- This is speculative — only pursue if 8a-8c reveal clear benefits

### Tests

- All existing 59 tests must pass with MLIR backend
- Binary output must be identical or functionally equivalent
- Performance regression tests for -O2 vs -O0

---

## Phase 9: Standard library

Written in Concrete itself, exercising capabilities, linear types, and allocators.

- `Option<T>`, `Result<T, E>` — algebraic types with methods
- `List<T>`, `Vec<T>` — with `Alloc` capability
- `String` operations — linear, with `Alloc` for concatenation
- `IO` — file, network, console, behind capabilities
- `Arena`, `GeneralPurposeAllocator`, `FixedBufferAllocator` — implementing `Allocator` trait
- `Math` — pure functions, no capabilities
- `Testing` — test runner utilities

---

## Phase 10: Runtime

### Phase 10a: Runtime in C

Needed for real-world use. Written in C, called via FFI (Phase 7).

- Green threads (stack allocation, context switching)
- Preemptive scheduler (timer-based via signals)
- Copy-only message passing between threads
- Deterministic replay (record inputs, replay execution)
- Built-in profiling and tracing (low overhead when disabled)

### Phase 10b: Runtime in Concrete

Once the compiler is mature, rewrite the runtime in Concrete using `Unsafe`. If writing the runtime is painful, the language design has a problem.

- Scheduler logic with `Unsafe` for system calls
- Message passing (type-checked, copy-only)
- Allocator pools for thread stacks
- Keep only assembly stubs in C (~20 lines per architecture for stack switching)

---

## Phase 11: Kernel formalization in Lean 4

**This phase can start in parallel with any of the above.** The formal model is independent of the surface language implementation — it only needs the language *design* to be stable, not the compiler.

Broken into subphases that each deliver value independently.

### Phase 11a: Kernel syntax + type checker (no proofs)

Define the kernel IR and write an independent type checker. Even without proofs, two independent checkers catching disagreements is valuable.

**Kernel IR** — a small typed lambda calculus:
- Types: primitives, products (structs), sums (enums), functions with capability sets, references with regions, linear/copy qualifiers
- Terms: let, application, match, borrow-in-region, destroy, defer
- Typing rules as a Lean function: `checkKernel : KernelTerm → Except String KernelType`

**Implementation:**
- New `Concrete/Kernel/Syntax.lean`: kernel IR as Lean inductive types (~15 term constructors, ~10 type constructors)
- New `Concrete/Kernel/Check.lean`: kernel type checker
- Modify `Check.lean` to emit kernel terms alongside surface checking
- Validation pass: run kernel checker on output, fail if it disagrees with surface checker

**What the kernel does NOT include** (these are surface/elaboration concerns):
- Syntax sugar (`!`, `defer`, anonymous borrows)
- Traits (elaborated to dictionary passing)
- Modules and imports (name resolution)
- Type inference (fully resolved before kernel)
- Error messages

**How surface features map to kernel:**

| Surface | Kernel |
|---------|--------|
| `fn foo!()` | Function with `CapSet = Std` |
| `defer destroy(x)` | Explicit sequencing with `destroy` at scope exit |
| Traits | Dictionary passing — extra function arguments |
| Generics | Explicit type abstraction (`∀`) and application |
| `match` on enums | `case` on sum types |
| Structs | Product types |
| `&f` inline borrow | Named region introduction + borrow |
| `with(Alloc = arena)` | Explicit allocator parameter |

### Phase 11b: Linearity proof

Most tractable proof and most novel claim. Essentially a counting argument on the typing derivation.

**Scope:** Primitives, let, application, match, destroy. No closures, no generics.

**Implementation:**
- `Concrete/Kernel/Soundness/Linearity.lean`
- Theorem: `∀ (t : KernelTerm) (τ : KernelType), hasType t τ → linearValuesConsumedOnce t`
- Lean verifies proof at build time

### Phase 11c: Progress + preservation

Standard PL theory proofs for the linear lambda calculus fragment.

- **Progress**: well-typed non-value terms can step
- **Preservation**: stepping preserves types

**Scope:** Primitives, products, sums, conditionals, let, application.

**Implementation:**
- `Concrete/Kernel/Reduction.lean`: small-step operational semantics
- `Concrete/Kernel/Soundness/Progress.lean`
- `Concrete/Kernel/Soundness/Preservation.lean`

### Phase 11d: Effect soundness

Add capability sets to kernel, prove runtime effects ⊆ declared capabilities.

Relatively straightforward once progress/preservation exist — capabilities are an extra tag on function types.

**Implementation:**
- Extend `Kernel/Syntax.lean` with capability sets
- `Concrete/Kernel/Soundness/Effects.lean`

### Phase 11e: Regions and generics

The hardest part. May require restricting kernel relative to surface.

- Region-annotated references, prove references don't escape
- Universal type quantification, prove substitution preserves typing

**Implementation:**
- Extend `Kernel/Syntax.lean` with regions and type variables
- `Concrete/Kernel/Soundness/Regions.lean`
- `Concrete/Kernel/Soundness/Generics.lean`

### Phase 11f: Connect proofs to compiler

Wire the kernel checker into the compilation pipeline so that every compiled program is checked against the proven-sound kernel.

- `Check.lean` becomes an elaborator that produces kernel terms
- Kernel checker runs on elaborated output
- Compilation fails if kernel checker rejects what surface checker accepted
- This is the final "proof artifact" — the binary you ship was checked by a verified type system

---

## Phase 12: Tooling

Parallel with everything above. Start early, grow incrementally.

- Package manager (`Concrete.toml`, dependency resolution)
- Formatter (one canonical format, like `gofmt`)
- Linter
- Test runner (built-in `test` blocks)
- REPL
- Language server (LSP — editor integration)
- Cross-compilation
- WebAssembly target (via MLIR after Phase 8)
- C codegen target (via MLIR after Phase 8)

---

## Research / Open Questions

These do not block any phase above:

- **Effect handlers**: full algebraic effects for testing/sandboxing (mock capabilities in tests)
- **Concurrency model**: structured concurrency, actors, deterministic parallelism — must preserve linearity
- **Macros**: if added, must be hygienic, phase-separated, and capability-tracked
- **Variance**: covariance/contravariance for generic types with linearity
- **Module functors**: module-level capability restrictions, separate compilation units

---

## Summary

| Phase | Feature | Depends on | Parallel? |
|-------|---------|------------|-----------|
| **1** | Capabilities + cap polymorphism | — | — |
| **2** | Closures | — | — |
| **3** | `defer` + `destroy` + `Copy` | 1 | — |
| **4** | `break` / `continue` | — | Yes, with 1-3 |
| **5** | Allocator system | 1, 3 | — |
| **6** | Borrow regions | — | Yes, with 1-5 |
| **7** | FFI + C interop | 1 (Unsafe cap) | Yes, with 2-6 |
| **8a** | MLIR FFI bindings | — | Yes, anytime |
| **8b** | MLIR LLVM dialect codegen | 8a | — |
| **8c** | MLIR optimization passes | 8b | — |
| **9** | Standard library | 1-6 | — |
| **10a** | Runtime in C | 7 (FFI) | — |
| **10b** | Runtime in Concrete | 9, 10a | — |
| **11a** | Kernel IR + checker | — | Yes, anytime |
| **11b** | Linearity proof | 11a | Yes, ongoing |
| **11c** | Progress + preservation | 11b | Yes, ongoing |
| **11d** | Effect soundness | 11c | Yes, ongoing |
| **11e** | Regions + generics | 11d | Yes, ongoing |
| **11f** | Connect proofs to compiler | 6, 11e | — |
| **12** | Tooling | — | Yes, ongoing |

**Critical path for language features:** 1 → 3 → 5 (capabilities → resource management → allocators). Phases 2, 4, 6 are independent and can be done in parallel.

**Critical path for production use:** 1-6 → 7 → 10a (language features → FFI → runtime).

**MLIR** (Phase 8) is independent of language features — can start anytime, biggest win is after language features stabilize.

**Formalization** (Phase 11) is independent of the compiler — can start anytime, needs only the language design (not the implementation) to be stable.
