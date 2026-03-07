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

## Design Decisions

Syntax choices that diverge from the [spec blog post](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/). None of these change the language's philosophy — they are surface syntax decisions made during implementation of the Lean 4 compiler.

| Spec says | We use | Why |
|-----------|--------|-----|
| `type Point { x: Float64, y: Float64 }` (unified `type` keyword) | `struct Point { ... }` / `enum Option<T> { ... }` (separate keywords) | Already implemented; Rust/Zig familiarity. Same semantics. |
| `[100]Uint8` (size before type) | `[Uint8; 100]` a.k.a. `[T; N]` | Already implemented; Rust-style. Same semantics. |
| `public` / `private` | `pub` / (default private) | Already implemented; more concise. Same semantics. |
| `module Main` (declaration) | `mod Main { ... }` (block) | Already implemented. Same semantics. |
| `Address[T]` (raw pointer) | `*mut T` / `*const T` | Already implemented; Rust-style, distinguishes mutability. |
| `fn malloc(...) = foreign("malloc")` | `extern fn malloc(...)` | Already implemented; Rust/C-style. Same semantics. |
| `destroy File with(File) { ... }` (standalone declaration) | `impl Destroy for File with(File) { ... }` (trait impl) | Reuses existing trait/impl machinery. Destroy is a built-in trait instead of a special declaration form. Same philosophy: explicit destruction, no implicit RAII. |
| `.concrete` file extension | `.con` | Shorter. Can revisit later. |

**Spec blog post also shows `import X as Y` alias syntax** — not yet implemented, will add to the module system when needed.

---

## Language Invariants

These rules apply across all phases. They come directly from the spec and must never be violated.

1. **Pure by default.** A function without `with()` is pure. It cannot call any function that has `with()`. This is the core invariant.
2. **True linear types, not affine.** Every linear value must be consumed exactly once. Not zero (leak = compile error). Not twice (double-use = compile error). Unlike Rust (at most once), forgetting a resource is rejected.
3. **No hidden control flow.** `a + b` on integers is primitive addition, not a method call. The compiler never inserts destructor calls. If it allocates, you see `with(Alloc)`. Errors propagate only where `?` appears.
4. **No variable shadowing.** Each variable name must be unique within its scope.
5. **No uninitialized variables.** All variables must be initialized at declaration.
6. **No operator overloading.** Operators on primitives are built-in. They are not trait method calls.
7. **No implicit conversions.** No silent coercion between types. Explicit `as` casts only.
8. **No null.** Optional values use `Option<T>`.
9. **No exceptions.** Errors are values (`Result<T, E>`), propagated with `?`.
10. **No global mutable state.** All global interactions mediated through capabilities.
11. **No interior mutability** in safe code. All mutation flows through `&mut`. Exception: `UnsafeCell<T>` in the standard library, gated by `Unsafe` capability.
12. **Local-only type inference.** Function signatures must be fully annotated (parameters and return type). Inside function bodies, local variable types may be inferred. You can always understand a function's interface without reading its body.
13. **LL(1) grammar.** Every parsing decision with a single token of lookahead. No ambiguity, no backtracking. This is a permanent constraint — future evolution is bounded by LL(1).
14. **`abort()` is immediate process termination.** Deferred cleanup does NOT run on abort. Out-of-memory and stack overflow trigger abort. This is outside the language's semantic model.
15. **Reproducible builds.** Same source + same compiler = identical binary. No timestamps, random seeds, or environment-dependent data in output.

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
- Predefined capabilities: `File`, `Network`, `Clock`, `Env`, `Random`, `Process`, `Console`, `Alloc`, `Unsafe`
- `Std` = `File + Network + Clock + Env + Random + Process + Console + Alloc`. Excludes `Unsafe`.
- `Std` is a flat shorthand, not a hierarchy. You cannot request "half of Std."
- `!` on a function name is sugar for `with(Std)`: `fn main!()` = `fn main() with(Std)`
- Users cannot define new capabilities
- Capabilities are not runtime values — type-level only, erased before codegen
- Capabilities are checked before monomorphization — generic functions don't change capability requirements at different instantiations
- Changing a public function's capability set is a breaking API change (in both directions)
- Each method in an `impl` block or `trait impl` declares its own capabilities independently

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

**Prerequisites:** This phase also adds `Ty.fn` (function type) to the `Ty` inductive, since capability polymorphism requires representing `fn(T) with(C) -> U` as a type. This is also needed by Phase 2 (closures).

- **AST**:
  - Add `Ty.fn_ (params : List Ty) (capSet : CapSet) (retTy : Ty)` — function type with capabilities
  - `FnDef` gets `capParams : List String` and `capSet : CapSet`
  - `FnSigDef` (trait method signatures) gets `capSet : CapSet`
  - `ImplTraitBlock` gets `capSet : CapSet` (for capabilities on the impl, used by `destroy`)
  - New `CapSet` type: `empty | concrete (caps : List String) | var (name : String) | union (a b : CapSet)`
- **Token/Lexer**: Add `with_` keyword. Add `cap_` keyword. `!` after an identifier in function position is not a new token — the parser handles it (see below).
- **Parser**:
  - Parse `with(Cap1, Cap2)` after params and before `->` on function declarations
  - Parse `cap C` in generic param lists (after type params): `<T, U, cap C>`
  - `!` sugar: after parsing `fn` + identifier, if next token is `!`, consume it and set capSet to `CapSet.concrete ["File", "Network", "Clock", "Env", "Random", "Process", "Console", "Alloc"]` (i.e., `Std` minus `Unsafe`). The `!` is NOT a separate identifier — it's consumed by the parser as a modifier.
  - Parse `fn(T, U) with(C) -> R` as a type (`Ty.fn_`)
- **Check.lean**:
  - Store each function's cap set in `FnDef.capSet` and `FnSigDef.capSet`
  - At call sites: check `callerCaps ⊇ calleeCaps`. Error: "function 'f' requires capability 'Network' but caller 'g' does not declare it"
  - For cap variables: at each call site, collect concrete caps from the function-typed arguments, unify `C` with that set, check caller has the unified set
  - Recursive functions: each function's declared caps are trusted (no fixed-point). If `f` declares `with(File)` and calls itself, that's fine.
  - Method calls: look up the method's cap set from the impl block, check against caller's caps
  - Trait method calls: cap set comes from the trait impl (not the trait definition — the impl may be more specific)
- **Codegen**: No change. Capabilities are erased at compile time.

### Tests

- `cap_pure.con`: pure function cannot call effectful function → error
- `cap_propagation.con`: caller missing callee's capability → error
- `cap_basic.con`: `with(File)` function calls `with(File)` function → ok
- `cap_bang.con`: `main!()` can call anything (except Unsafe) → ok
- `cap_poly.con`: `map<T, U, cap C>` infers C from argument → ok
- `cap_poly_multi.con`: `fn zip_with<T, U, V, cap C, cap D>(...)` with two cap vars → ok
- `error_cap_poly_fail.con`: caller doesn't have inferred cap set → error
- `cap_method.con`: method with `with(File)` on impl, called from `with(File)` function → ok

---

## Phase 2: Closures

Needed before `defer` and allocators because those features benefit from passing behavior as values.

### Syntax

```
// Anonymous function
let doubled: List<Int> = map(data, fn(x: Int) -> Int { return x * 2; });

// Type inference for closure params (bidirectional from expected type)
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

- Closures capture variables from the enclosing scope (implicit capture, not explicit)
- Capture rules follow linearity:
  - Capturing a linear value **moves** it into the closure (original is consumed)
  - Capturing a primitive type (Int, Bool, etc.) **copies** it (primitives are always Copy)
  - Capturing a `Copy`-marked type copies it (once Phase 3 adds the `Copy` marker; until then, all structs are linear and capturing moves)
  - Capturing a `&T` borrows it — closure cannot outlive the borrow region
  - Capturing a `&mut T` borrows exclusively — no other borrows while closure exists
- Closures that capture linear values are themselves linear (must be called exactly once)
- Closures that capture only copyable values (primitives, Copy types) can be called multiple times
- Closure capabilities: if the body uses `with(File)`, the closure type carries `with(File)`
- Closures that escape their defining scope cannot capture capabilities from the enclosing function — they must declare their own
- Function types: `fn(Int) -> Bool` (pure), `fn(Int) with(File) -> Bool` (effectful)
- Disambiguation: `fn` followed by `(` in expression position (not after `pub`, not at top level of module) is a closure. At top level, `fn` starts a function definition.

### Implementation

**Prerequisite:** `Ty.fn_` from Phase 1 must exist.

- **AST**: `Expr.closure (params : List Param) (capSet : CapSet) (retTy : Option Ty) (body : List Stmt) (captures : List String)`. The `captures` field is filled in by the checker, not the parser.
- **Parser**: When `fn` appears in expression position (after `=`, `,`, `(`, `return`), parse as closure. If params have type annotations, use them; if not, leave types as `Ty.unknown` for bidirectional inference.
- **Check.lean**:
  - Analyze closure body for free variables → those are captures
  - For each capture: if the captured variable's type is a primitive or `Copy` type, mark as copy-capture (original stays live); otherwise, mark as move-capture (original is consumed in enclosing scope)
  - Bidirectional type inference for untyped closure params: if the closure is an argument to a function expecting `fn(T) -> U`, infer param types from `T`
  - Compute closure's cap set from its body. Check capability propagation.
  - Linear captures → the closure itself is linear (must be used exactly once)
  - Check captured borrows don't escape their region
- **Codegen**:
  - No captures: closure compiles to a plain function pointer
  - With captures: generate a struct containing captured values + a function pointer. The generated function takes `ptr %env` as hidden first param, loads captures from the struct.
  - Calling a closure: if `Ty.fn_`, check if env pointer is null (no captures) or non-null (has captures). Pass env as first arg.
  - LLVM representation: `{ ptr fn, ptr env }` (fat pointer). For no-capture closures, `env = null`.

### Tests

- `closure_basic.con`: simple closure, no captures → ok
- `closure_capture_copy.con`: capture Int (primitive, always Copy) → ok, original still usable
- `closure_capture_move.con`: capture linear struct → original consumed
- `closure_linear.con`: closure with linear capture must be called exactly once
- `closure_cap.con`: closure with `with(File)` captures + capability → ok
- `error_closure_escape_borrow.con`: capture &T that escapes → error
- `error_closure_double_call.con`: call linear closure twice → error

---

## Phase 3: Explicit resource management (`defer` + `destroy` + `Copy`)

Linear types that hold resources implement `Destroy`. Cleanup is always explicit. No implicit RAII.

### `destroy` as a trait

The [spec blog post](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/) uses a standalone `destroy File with(File) { ... }` declaration. We use the trait/impl model instead — same philosophy (explicit destruction, no implicit RAII), reuses existing impl/trait machinery:

```
// Destroy is a built-in trait (pre-registered, not user-declared)
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

### `abort()`

```
fn out_of_memory!() {
    abort();  // immediate process termination
    // deferred cleanup does NOT run
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

**Destroy:**
- `Destroy` is a built-in trait with one method: `fn destroy(self) -> Unit`
- `destroy(x)` is syntactic sugar that resolves to the `Destroy` impl for `x`'s type — it is NOT a keyword or built-in function, it is a normal function call that the checker resolves via trait lookup
- `with()` on the `impl Destroy for T` declares capabilities the destructor needs
- Calling `destroy(x)` requires the caller to have those capabilities
- `destroy(x)` is only valid if the type implements `Destroy`
- Types without `Destroy` must be consumed by moving, returning, or destructuring

**Defer:**
- `defer` is **block-scoped** (like Zig, NOT function-scoped like Go). It runs when the enclosing `{ }` block exits.
- `defer` runs in LIFO order at scope exit
- `defer destroy(x)` reserves the value: cannot move `x` after deferring, cannot destroy again, cannot re-defer
- `defer` runs on normal exit, early return, and `?` error propagation
- `defer` does NOT run on `abort()`
- `defer` can only defer expression statements (function calls, method calls, `destroy()`). `defer let x = ...` or `defer return` are parse errors.
- `defer` inside a loop body: each iteration that executes the `defer` adds a deferred action to that iteration's scope. The deferred action runs when the loop body block exits (at end of each iteration, or on `break`/`continue`).
- `break`/`continue` inside `defer` is forbidden (Phase 4 check)

**Copy:**
- `Copy` is explicit and opt-in via `type Copy`
- A type implementing `Destroy` cannot be `Copy`
- A `Copy` type cannot implement `Destroy` and cannot contain linear fields
- Primitive types (Int, Bool, Float64, etc.) are built-in `Copy`
- `String` is linear (not `Copy`)
- `&T` is `Copy`; `&mut T` is not `Copy`
- Arrays of `Copy` types are `Copy`; arrays of linear types are linear

**Abort:**
- `abort()` is a built-in function that immediately terminates the process
- Deferred cleanup does NOT run on abort
- Out-of-memory triggers abort. Stack overflow triggers abort.
- `abort()` does not require any capability — it is always available

### Implementation

- **AST**:
  - `Stmt.defer (body : Stmt)` — the body must be an expression statement
  - `StructDef` gets `isCopy : Bool` — true for `type Copy` definitions
  - `ImplTraitBlock` gets `implCapSet : CapSet` — for `impl Destroy for File with(File) { ... }`
  - `Expr.abort` — built-in abort expression
- **Token/Lexer**: Add `defer_` keyword. Add `abort_` as built-in identifier.
- **Parser**:
  - Parse `defer <expr-stmt>;` — only allow expression statements after `defer`
  - Parse `type Copy Name { ... }` as a struct definition with `isCopy = true`
  - `impl Destroy for T with(Cap) { ... }` already parses via existing impl-trait parsing; extend to capture `with(Cap)` on the `impl` line
  - `destroy(x)` parses as a normal function call — the checker resolves it
- **Check.lean**:
  - Pre-register `Destroy` trait in the type environment (not user-declarable)
  - When checking `destroy(x)`: look up `Destroy` impl for `x`'s type. If found, treat as consuming `x`. If not found, error: "type T does not implement Destroy"
  - Track deferred values as "reserved" (not movable, not destroyable, not re-deferable)
  - When exiting a block scope: verify all deferred actions reference valid reserved values
  - Verify `Copy`/`Destroy` mutual exclusivity: if a type has `isCopy = true` and also has an `impl Destroy`, error
  - For `Copy` types: verify all fields are themselves `Copy` (recursive check)
  - `abort()` is always allowed, returns `Never` (bottom type)
- **Codegen**:
  - Track deferred statements per block scope (stack of deferred lists)
  - Before every `ret` instruction: emit all deferred statements from all enclosing scopes, innermost first, LIFO within each scope
  - Before `?` propagation branch (the error path): emit all deferred statements from the current function's scopes
  - `destroy(x)` compiles to `call void @TypeName_destroy(ptr %x)`
  - `abort()` compiles to `call void @abort()` followed by `unreachable`

### Tests

- `defer_basic.con`: defer runs at scope exit → ok
- `defer_lifo.con`: multiple defers run in reverse order → ok
- `defer_early_return.con`: defer runs on early return → ok
- `defer_try.con`: defer runs on `?` error propagation → ok
- `defer_block_scope.con`: defer in inner block runs at block exit, not function exit → ok
- `defer_loop.con`: defer inside loop runs at end of each iteration → ok
- `destroy_trait.con`: implement Destroy, call destroy() → ok
- `copy_marker.con`: Copy type can be used multiple times → ok
- `abort_basic.con`: abort() terminates immediately → ok (exit code nonzero)
- `error_defer_move.con`: move after defer → error "variable reserved by defer"
- `error_defer_not_expr.con`: `defer let x = 5;` → error "defer can only defer expression statements"
- `error_copy_destroy.con`: Copy type with Destroy impl → error
- `error_copy_linear_field.con`: Copy type containing linear field → error
- `error_destroy_no_impl.con`: destroy(x) on type without Destroy → error

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

- `break` exits the innermost loop (applies to both `while` and `for` loops)
- `break expr` exits and produces a value (loop-as-expression)
- `continue` skips to the next iteration
- **Linear types**: `break`/`continue` must not skip over unconsumed linear values declared between the start of the current iteration and the break/continue point. Linear variables from outside the loop remain live. Example: `let x = LinearStruct {}; if cond { continue; }` → error, `x` not consumed on the continue path.
- `break` inside `defer` is forbidden — compile error
- `continue` inside `defer` is forbidden — compile error
- Applies to innermost loop only (no labeled breaks in v1)
- For `break val`, all break expressions and the `else` clause must agree on type
- While-as-expression: `while` in expression position (RHS of `let`, argument, etc.) produces a value. The `else` clause is mandatory when using `break val` — it provides the value when the loop condition becomes false without breaking. A `while` without `break val` or without `else` in expression position is a type error.
- `break` (without value) in expression-position while is also valid if `else` is present — both produce `Unit`.

### Implementation

- **AST**: `Stmt.break_ (value : Option Expr)`, `Stmt.continue_`. `Expr.whileExpr (cond : Expr) (body : List Stmt) (elseBody : List Stmt)` for while-as-expression.
- **Token/Lexer**: Add `break_` and `continue_` keywords.
- **Parser**: Parse `break;`, `break expr;`, `continue;` inside loops. In expression position, parse `while cond { ... } else { ... }` as `Expr.whileExpr`.
- **Check.lean**:
  - Track loop nesting depth. `break`/`continue` outside loop → error
  - Track whether we're inside a `defer` body. `break`/`continue` inside defer → error
  - Before `break`/`continue`: scan linear variables declared in the current iteration scope, verify all consumed. Error: "break would skip unconsumed linear variable 'x'"
  - For `break expr`: collect all break expression types + else clause type, verify agreement
- **Codegen**: `break` → `br label %loop.exit`. `continue` → `br label %loop.header`. For `break val`: pre-allocate result slot (`alloca`) before loop, each `break val` stores to the slot before jumping, `else` clause stores to the same slot. After loop, load from slot.

### Tests

- `break_basic.con`: break exits loop → ok
- `break_value.con`: break with value, loop as expression → ok
- `continue_basic.con`: continue skips iteration → ok
- `break_for.con`: break inside for loop → ok
- `error_break_outside.con`: break outside loop → error
- `error_break_linear.con`: break skips unconsumed linear variable → error
- `error_continue_linear.con`: continue skips unconsumed linear variable → error
- `error_break_in_defer.con`: break inside defer → error

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

    // Method calls with allocator binding
    list.push(42) with(Alloc = arena);
}
```

### Why `Alloc` is special

`Alloc` is the only capability with call-site binding syntax (`with(Alloc = expr)`). No other capability has this — `File`, `Network`, etc. are pure permissions with no associated runtime value. `Alloc` is different because the allocator is a runtime object that must be threaded through the call chain.

### How `main!()` gets an allocator

`Std` includes `Alloc`, so `main!()` has the `Alloc` capability. But `main!()` still must bind an allocator at each call site:

```
fn main!() {
    let arena: Arena = Arena.new();
    // Must explicitly bind: no "default allocator" magic
    let list: List<Int> = create_list<Int>() with(Alloc = arena);
}
```

There is NO default allocator. If `main!()` calls a `with(Alloc)` function without `with(Alloc = expr)`, that is a compile error. Having `Alloc` in your capability set means you're *allowed* to allocate, not that you *have* an allocator. The binding provides the allocator.

### Allocator trait

```
trait Allocator {
    fn alloc(&mut self, size: Uint, align: Uint) -> Result<*mut u8, AllocError>;
    fn free(&mut self, ptr: *mut u8, size: Uint, align: Uint);
    fn realloc(&mut self, ptr: *mut u8, old_size: Uint, new_size: Uint, align: Uint) -> Result<*mut u8, AllocError>;
}
```

Note: The allocator interface uses raw pointers (`*mut u8`), not references. This avoids a circular dependency with borrow regions (Phase 6). Generic allocation helpers (like `alloc_one<T>()`) are standard library wrappers (Phase 9) that call the raw `alloc` with `size_of::<T>()` and `align_of::<T>()`.

### Rules

- `with(Alloc)` in signature means the function may allocate
- `with(Alloc = expr)` at call site binds a specific allocator for that call and all nested `with(Alloc)` calls
- Inside a `with(Alloc)` function: nested calls to `with(Alloc)` functions forward the received allocator automatically (no explicit binding needed)
- If a function calls two `with(Alloc)` functions with different allocators, it binds each separately at each call site
- Stack allocation does not require `Alloc`
- A function without `with(Alloc)` cannot call anything with `with(Alloc)` — always explicit

### Parser disambiguation

The `with(...)` syntax appears in two contexts:
1. **Declaration**: `fn foo() with(File, Alloc) -> T { ... }` — capability declaration on function signature
2. **Call site**: `foo() with(Alloc = arena)` — allocator binding on function call

The parser distinguishes them by position: after `)` of a function *declaration* (before `->` or `{`), it's a capability declaration. After `)` of a function *call expression*, it's a call-site binding. The `=` inside `with()` also disambiguates — declarations never have `=`.

### Implementation

- **AST**: `Expr.call` gets `allocBind : Option Expr`. `Expr.methodCall` also gets `allocBind : Option Expr`.
- **Parser**: After `)` of a function call, if next tokens are `with` `(` `Alloc` `=`, parse the expression and store in `allocBind`.
- **Check.lean**: If calling a function with `Alloc` in its cap set, caller must either (a) have `Alloc` in its own cap set AND be inside a call chain that propagates an allocator, or (b) provide `with(Alloc = expr)` at the call site. Verify expr's type implements `Allocator`. Error: "function 'f' requires Alloc but no allocator is bound"
- **Codegen**: Functions with `Alloc` in their cap set get a hidden `ptr %allocator` as the first parameter. `with(Alloc = arena)` → pass arena's pointer. Inside a `with(Alloc)` function calling another `with(Alloc)` function without explicit binding → forward `%allocator`.

### Tests

- `alloc_basic.con`: bind allocator at call site → ok
- `alloc_propagate.con`: allocator propagates through nested calls → ok
- `alloc_different.con`: different allocators for different calls → ok
- `alloc_method.con`: method call with allocator binding → ok
- `error_alloc_missing.con`: call with(Alloc) function without binding → error
- `error_alloc_no_cap.con`: function without Alloc calls with(Alloc) function → error

---

## Phase 6: Borrow regions

Explicit lexical regions that bound reference lifetimes. Simpler than Rust — no lifetime annotations in function signatures.

### Two levels of explicitness

```
// Level 1: Inline borrow — anonymous region for one expression (already works today)
let len: Int = length(&f);

// Level 2: Full explicit — named region, named reference
borrow db as db_ref in R {
    // db_ref has type &[Database, R]
    // db is unusable in this block
    let result: Data = query(db_ref);
}
// db is usable again

// Mutable borrow
borrow mut data as data_ref in R {
    // data_ref has type &mut [Data, R]
    modify(data_ref);
}
```

Note: The spec blog post shows `borrow f as fref in R { ... }` as the explicit form. An earlier draft of this roadmap included a `with &x, &y { ... }` block borrow syntax (Level 2), but this clashes with the `with(...)` capability syntax. We use only two levels: inline `&x` (already works) and explicit `borrow ... as ... in R { ... }` (from the spec).

### Rules

- Level 1 (`&x` in expression): anonymous region spanning that expression. Already implemented.
- Level 2 (`borrow x as y in R { ... }`): named region, named reference. Required when you need the region name in a type or when you need a borrow that spans multiple statements.
- While borrowed, the original is frozen (unusable for Level 1; frozen for the block in Level 2)
- Multiple immutable borrows allowed; mutable borrows exclusive
- References cannot escape their region (cannot be returned, stored in a struct that outlives the region, or captured by an escaping closure)
- Closures cannot capture references that outlive the borrow region
- Functions are implicitly generic over regions — no lifetime params in function signatures
- Region inference for function calls: when a function takes `&T` and returns `&U`, the compiler assumes the output's region is the same as the input's. Multiple input regions → ambiguity → require explicit borrow block.

### Implementation

- **AST**:
  - Add `Ty.refRegion (inner : Ty) (region : String)` and `Ty.refMutRegion (inner : Ty) (region : String)` — region-annotated reference types
  - `Stmt.borrowIn (var : String) (ref : String) (region : String) (isMut : Bool) (body : List Stmt)` for `borrow [mut] x as y in R { ... }`
- **Token/Lexer**: Add `borrow_` keyword.
- **Parser**: Parse `borrow x as y in R { ... }` and `borrow mut x as y in R { ... }`.
- **Check.lean**:
  - For Level 1 (`&x`): existing behavior — freeze `x` for the expression, create anonymous region
  - For Level 2: register region name `R` in scope, freeze original `var`, create reference binding `ref` with type `&[T, R]` or `&mut [T, R]`, check body, unfreeze original at block exit
  - Escape check: any reference with region `R` cannot appear in the return type, cannot be stored in a binding that's live after the borrow block exits
  - Region inference for function calls: match input/output region names, infer when unambiguous
- **Codegen**: All forms produce same IR as current `&x` — pointer to the alloca/storage. Regions are type-checker only, completely erased in codegen.

### Tests

- `borrow_named.con`: named region, named reference → ok
- `borrow_mut_named.con`: mutable borrow in named region → ok
- `borrow_multi.con`: multiple borrows of different variables in nested regions → ok
- `error_borrow_escape.con`: reference escapes region → error
- `error_borrow_frozen.con`: use original inside borrow block → error
- `error_borrow_closure_escape.con`: closure captures reference from borrow region and escapes → error

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

// Type transmutation
fn reinterpret(x: u32) with(Unsafe) -> f32 {
    return transmute<f32>(x);  // reinterpret bits
}
```

### Rules

- `extern fn` declares a function with C ABI, no body
- Calling an `extern fn` requires `with(Unsafe)` — FFI is never silent
- Only C-compatible types in extern signatures: integer types (i8-i64, u8-u64, Int, Uint), float types (f32, f64), `Bool` (maps to C `_Bool` / `i8` in ABI), raw pointers (`*mut T`, `*const T`)
- Structs with `#[repr(C)]` attribute get C-compatible memory layout (fields in declaration order, platform alignment)
- Structs without `#[repr(C)]` cannot be passed to extern functions by value
- No automatic string conversion — pass `*const u8` and length explicitly
- Raw pointer dereference (`*ptr`) requires `with(Unsafe)`
- `transmute<T>(expr)` requires `with(Unsafe)` and `size_of(typeof(expr)) == size_of(T)`. Reinterprets bits as target type.
- Creating a raw pointer (`&x as *const T`) is safe — using one is not

### Migration

Existing `extern fn` calls in examples and tests do NOT currently require `Unsafe`. After Phase 1 (capabilities) and Phase 7 are implemented, these will need updating to declare `with(Unsafe)`. Affected examples: `malloc.con`, any example using `extern fn`.

### Implementation

- **AST**: `ExternFn` already exists. Add `Attr.reprC : Bool` to `StructDef`. Add `Expr.transmute (targetTy : Ty) (inner : Expr)`. Add `Expr.ptrDeref (inner : Expr)`.
- **Token/Lexer**: `Unsafe` is recognized as a capability name (just an identifier). `#[repr(C)]` requires parsing: `#` already tokenized as `hash`; parser handles `[`, `repr`, `(`, `C`, `)`, `]` as an attribute.
- **Parser**: Parse `#[repr(C)]` before struct definitions, set `reprC = true`. Parse `transmute<T>(expr)` — `transmute` is a keyword or built-in identifier, followed by `<`, type, `>`, `(`, expr, `)`. Parse `*expr` as `Expr.ptrDeref`.
- **Check.lean**: Verify all `extern fn` call sites have `with(Unsafe)`. Verify extern param/return types are C-compatible (reject structs without repr(C), reject String, reject enums). Verify `*ptr` deref has `with(Unsafe)`. Verify `transmute` has `with(Unsafe)` and sizes match. Error: "calling extern function 'malloc' requires Unsafe capability"
- **Codegen**: `extern fn` emits `declare` (already works). `#[repr(C)]` structs use C layout rules (fields in order, natural alignment, struct padding). `transmute` → `bitcast` for pointers, or store-to-alloca + load-with-different-type for value types. `*ptr` → `load T, ptr %val`.

### Tests

- `ffi_basic.con`: call extern fn with Unsafe → ok
- `ffi_repr_c.con`: pass #[repr(C)] struct to extern → ok
- `ffi_transmute.con`: transmute u32 to f32 with Unsafe → ok
- `ffi_ptr_deref.con`: dereference raw pointer with Unsafe → ok
- `error_ffi_no_unsafe.con`: call extern fn without Unsafe → error
- `error_ffi_bad_type.con`: pass non-C-compatible type to extern → error
- `error_ptr_deref_no_unsafe.con`: dereference raw pointer without Unsafe → error
- `error_transmute_size.con`: transmute between types of different sizes → error

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
- Use [melior](https://github.com/raviqqe/melior) (Rust MLIR bindings) as design reference for API surface
- Build system: link against MLIR/LLVM shared libraries via `lakefile.lean`
- New file: `Concrete/MLIR/Bindings.lean`

### Phase 8b: LLVM dialect codegen

Replace `Codegen.lean` text emission with MLIR operation construction.

- Target LLVM dialect directly (1:1 mapping with current textual IR)
- Same semantics, structured construction instead of string concatenation
- New file: `Concrete/MLIR/Codegen.lean` (parallel to existing `Codegen.lean`)
- Validate: all existing tests pass with MLIR backend
- Keep textual backend as fallback during transition
- Compiler flag: `--backend=text` (default initially) vs `--backend=mlir`

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

- All existing tests must pass with MLIR backend (`--backend=mlir`)
- Binary output must be functionally equivalent (same exit codes, same behavior)
- Performance regression tests for -O2 vs -O0

---

## Phase 9: Standard library

Written in Concrete itself, exercising capabilities, linear types, and allocators.

- `Option<T>`, `Result<T, E>` — algebraic types with methods (Result already exists as a built-in; promote to stdlib)
- `List<T>`, `Vec<T>` — with `Alloc` capability
- `String` operations — linear, with `Alloc` for concatenation
- `IO` — file (`with(File)`), network (`with(Network)`), console (`with(Console)`), behind capabilities
- `Arena`, `GeneralPurposeAllocator`, `FixedBufferAllocator` — implementing `Allocator` trait
- `UnsafeCell<T>` — interior mutability, gated by `Unsafe`
- `Math` — pure functions, no capabilities
- `Testing` — test runner utilities
- `Decimal`, `BigInt`, `BigDecimal` — exact arithmetic types (pure)

---

## Phase 10: Runtime

### Phase 10a: Runtime in C

Needed for real-world use. Written in C, called via FFI (Phase 7).

- Green threads (stack allocation, context switching)
- Preemptive scheduler (timer-based via signals)
- Copy-only message passing between threads (the `Copy` marker from Phase 3 determines what can be sent)
- Deterministic replay (record inputs via capability boundaries, replay execution)
- Built-in profiling and tracing (low overhead when disabled, structured output for tooling)

### Phase 10b: Runtime in Concrete

Once the compiler is mature, rewrite the runtime in Concrete using `Unsafe`. If writing the runtime is painful, the language design has a problem.

- Scheduler logic with `Unsafe` for system calls
- Message passing (type-checked at compile time, copy-only)
- Allocator pools for thread stacks
- Keep only assembly stubs in C (~20 lines per architecture for stack switching)

---

## Phase 11: Kernel formalization in Lean 4

**This phase can start in parallel with any of the above.** The formal model is independent of the surface language implementation — it only needs the language *design* to be stable, not the compiler.

Broken into subphases that each deliver value independently.

### Kernel versioning

The kernel is versioned separately from the surface language. Once the kernel reaches 1.0, it is **frozen** — no new constructs. New surface features must elaborate to existing kernel constructs. If a proposed surface feature cannot be expressed in the kernel, the feature does not ship. This is the key constraint that keeps the verified core tractable.

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
| `type Copy T` | Type with `Copy` qualifier in kind |
| Closures | Lambda with explicit environment product type |

**Trust boundary:** The kernel checker and its proofs are mechanically verified by Lean. What remains trusted: Lean's proof checker itself, the elaborator (surface → kernel), and the code generator (kernel → machine code).

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

- **Effect handlers**: full algebraic effects for testing/sandboxing (mock capabilities in tests). Example: `handle File in f() { open(path) => resume(MockFile.new(path)) }`
- **Concurrency model**: structured concurrency, actors, deterministic parallelism — must preserve linearity and effect tracking
- **Macros**: if added, must be hygienic, phase-separated, and capability-tracked. No macros is also a valid final answer.
- **Variance**: covariance/contravariance for generic types with linearity
- **Module functors**: module-level capability restrictions, separate compilation units
- **Trait objects / dynamic dispatch**: currently all dispatch is static. If `dyn Trait` is ever added, it must interact correctly with capabilities and linearity.

---

## Summary

| Phase | Feature | Depends on | Parallel? |
|-------|---------|------------|-----------|
| **1** | Capabilities + cap polymorphism | — | — |
| **2** | Closures | 1 (Ty.fn) | — |
| **3** | `defer` + `destroy` + `Copy` + `abort` | 1 | — |
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

**Critical path for language features:** 1 → 3 → 5 (capabilities → resource management → allocators). Phases 4, 6 are independent and can be done in parallel. Phase 2 depends on Phase 1 for `Ty.fn`.

**Critical path for production use:** 1-6 → 7 → 10a (language features → FFI → runtime).

**MLIR** (Phase 8) is independent of language features — can start anytime, biggest win is after language features stabilize.

**Formalization** (Phase 11) is independent of the compiler — can start anytime, needs only the language design (not the implementation) to be stable. Kernel is frozen at 1.0.
