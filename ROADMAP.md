# Concrete Roadmap

This is the implementation plan for the Concrete programming language. For the full specification, see [The Concrete Programming Language: Systems Programming for Formal Reasoning](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/).

## What's Built

The Lean 4 compiler implements the core surface language. All 188 tests pass (131 positive, 57 negative).

**Done:**
- Lexer, LL(1) parser, AST
- Types: Int, Uint, i8-i32, u8-u32, f32, f64, Bool, Char, String, arrays `[T; N]`, raw pointers `*mut T` / `*const T`
- Structs with field access, mutation, pass-by-pointer, `Heap<T>` fields
- Enums with pattern matching (exhaustiveness checked, literal and variable patterns)
- Impl blocks with methods (`&self`, `&mut self`, `self`) and static methods
- `Self` keyword in impl blocks (resolved to the implementing type)
- Traits with static dispatch, signature checking, and trait bounds on generics (`<T: Trait1 + Trait2>`)
- Generics on functions, structs, and enums
- Borrowing: `&T` (shared) and `&mut T` (exclusive), with borrow checking
- Borrow regions: `borrow x as xr in R { ... }` with escape analysis
- Linear type system: structs consumed exactly once, branches must agree, loop restrictions
- `defer`/`destroy`/`Copy`: explicit resource management, LIFO deferred cleanup, opt-in Copy marker
- Modules with `pub` visibility, imports, submodules, forward references, multi-file resolution (`mod X;` reads `X.con`), circular import detection
- Result type with `?` operator for error propagation
- Cast expressions (`as`) between numeric types
- Control flow: while (including while-as-expression), for (C-style), if/else, match, break/continue (with labeled loops `'label:`)
- Closures: fat pointer representation, copy/move captures, free variable analysis, bidirectional type inference, linear closure tracking
- Heap allocation: `alloc`/`free`, `Heap<T>` with `->` field access, `HeapArray<T>`, heap dereference (`*heap_ptr`)
- Monomorphized trait dispatch: calling trait methods on generic type variables generates specialized copies at compile time (no vtables, no runtime dispatch)
- `Option<T>` builtin enum with `Some`/`None` variants
- File I/O: `read_file`/`write_file` builtins (require File capability)
- Bitwise operators (`&`, `|`, `^`, `<<`, `>>`, `~`) and hex/binary/octal literals
- `print_int`/`print_bool` builtins (require Console capability)
- Constants, type aliases, extern fn declarations, `abort()`
- Capabilities: `with(File, Network, Alloc)` effect declarations, `!` sugar, capability polymorphism, capability checking
- Direct LLVM IR text emission, compiled via clang to native binaries

**Not yet implemented:** FFI safety (Unsafe gating, `#[repr(C)]`, transmute), MLIR backend, standard library (`Vec<T>`, `HashMap<K,V>`, String operations, stdin, int↔string conversion), networking, env vars/process args, kernel formalization, runtime.

---

## Design Decisions

Syntax choices that diverge from the [spec blog post](https://federicocarrone.com/series/concrete/the-concrete-programming-language-systems-programming-for-formal-reasoning/). None of these change the language's philosophy — they are surface syntax decisions made during implementation of the Lean 4 compiler.

| Spec says | We use | Why |
|-----------|--------|-----|
| `type Point { x: Float64, y: Float64 }` (unified `type` keyword) | `struct Point { ... }` / `enum Option<T> { ... }` (separate keywords) | Already implemented; separate declarations are clearer in the current parser. Same semantics. |
| `[100]Uint8` (size before type) | `[Uint8; 100]` a.k.a. `[T; N]` | Already implemented; matches the rest of the current type grammar. Same semantics. |
| `public` / `private` | `pub` / (default private) | Already implemented; more concise. Same semantics. |
| `module Main` (declaration) | `mod Main { ... }` (block) | Already implemented. Same semantics. |
| `Address[T]` (raw pointer) | `*mut T` / `*const T` | Already implemented; distinguishes mutability directly in the type. |
| `fn malloc(...) = foreign("malloc")` | `extern fn malloc(...)` | Already implemented; concise foreign-function declaration. Same semantics. |
| `destroy File with(File) { ... }` (standalone declaration) | `impl Destroy for File with(File) { ... }` (trait impl) | Reuses existing trait/impl machinery. Destroy is a built-in trait instead of a special declaration form. Same philosophy: explicit destruction, no implicit RAII. |
| `.concrete` file extension | `.con` | Shorter. Can revisit later. |
| Allocator returns `&mut [T]` (borrow-checked reference) | Allocator returns `Heap<T>` (linear owned type) | Allocated memory is owned, not borrowed. `Heap<T>` avoids circular dependency with borrow regions (Phase 6). Access requires explicit borrow. See [research/heap-ownership-design.md](research/heap-ownership-design.md). |
| Cap polymorphism deferred as "future work" | Cap polymorphism in Phase 1 | Without it, generic combinators (map, filter, fold) require duplication per capability set. The spec says "the theory is well-understood (Koka, Eff, Frank)." |
| Spec shows `with &x, &y { ... }` as borrow block syntax | `borrow x as xr in R { ... }` only | Earlier draft included `with &x { ... }` but this clashes with `with(Cap)` capability syntax. We use only the spec's `borrow ... as ... in R` form. |

**Spec blog post also shows `import X as Y` alias syntax** — not yet implemented, will add to the module system when needed.

---

## Language Invariants

These rules apply across all phases. They come directly from the spec and must never be violated.

1. **Pure by default.** A function without `with()` is pure. It cannot call any function that has `with()`. This is the core invariant.

2. **True linear types.** Every linear value must be consumed exactly once. Not zero (leak = compile error). Not twice (double-use = compile error). Forgetting a resource is rejected. **What counts as "consuming" a value** — this is the canonical list, referenced by all phases:
   - Passing it as a by-value argument to a function or method (including `destroy(x)`)
   - Returning it from a function (`return x`)
   - Moving it into a struct field during construction (`Point { x: val }`)
   - Moving it into a closure capture (Phase 2)
   - `break val` inside a loop-as-expression (Phase 4)
   - Destructuring via `match` or `let` (the original is consumed, the fields become new bindings)
   - Storing into an array element during array literal construction (`[val1, val2]`)
   - Each phase that adds a new consumption form must update this list.
   - **NOT consumption**: borrowing (`&x`, `&mut x`), taking address for raw pointer (`&x as *const T`), deferring (`defer destroy(x)` reserves but does not consume until execution).

3. **No hidden control flow.** `a + b` on integers is primitive addition, not a method call. The compiler never inserts destructor calls — you write `defer destroy(x)` explicitly. If it allocates, you see `with(Alloc)`. Errors propagate only where `?` appears. **Note on `defer`:** `defer` schedules code at scope exit, but the programmer writes `defer` explicitly at the point of scheduling. The compiler emits the deferred call at the point of scope exit — this is the ONE mechanism where the compiler inserts code you didn't write at that exact source location. It does not violate the invariant because (a) the programmer wrote the `defer` statement, (b) the execution point (scope exit) is deterministic and visible from the block structure, and (c) no implicit function dispatch occurs — the exact function being called is the one written in the `defer` statement.

4. **No variable shadowing.** Each variable name must be unique within its scope. This extends to region names in borrow blocks (Phase 6) — `borrow x as xr in R` introduces `xr` and `R` into scope, and neither may shadow existing names.

5. **No uninitialized variables.** All variables must be initialized at declaration.

6. **No operator overloading.** Operators (`+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`) on primitives (Int, Uint, i8-i64, u8-u64, f32, f64, Bool) are built-in. They are not trait method calls. User-defined types (structs, enums) cannot use these operators — you must write named functions (e.g., `fn eq(a: &Point, b: &Point) -> Bool`). There is no `Eq` trait, no `Ord` trait, no `Add` trait.

7. **No implicit conversions.** No silent coercion between types. Explicit `as` casts only. `Int` and `i64` are distinct types even if both are 64-bit — cast between them explicitly.

8. **No null.** Optional values use `Option<T>`.

9. **No exceptions.** Errors are values (`Result<T, E>`), propagated with `?`.

10. **No global mutable state.** All global interactions mediated through capabilities.

11. **No interior mutability** in safe code. All mutation flows through `&mut`. Exception: `UnsafeCell<T>` in Phase 8 (standard library), gated by `Unsafe` capability. **Before Phase 8, interior mutability simply does not exist** — the borrow checker is closed with no escape hatches.

12. **Local-only type inference.** Function signatures must be fully annotated (parameters and return type). Inside function bodies, local variable types may be inferred from the right-hand side of `let` bindings. Inference direction: **right-to-left only** — the type of `let x = expr;` is the type of `expr`. There is no constraint solving or unification across statements. Exception: closure parameter types may be inferred bidirectionally when the closure appears as an argument to a function with a known signature (Phase 2). You can always understand a function's interface without reading its body.

13. **LL(1) grammar.** Every parsing decision with a single token of lookahead. No ambiguity, no backtracking. This is a permanent constraint — future evolution is bounded by LL(1).

14. **`abort()` is immediate process termination.** Deferred cleanup does NOT run on abort. Out-of-memory and stack overflow trigger abort. This is outside the language's semantic model. **Exit code:** `abort()` calls the C `abort()` function, which raises `SIGABRT`. On POSIX systems this produces exit code 134. The exact exit code is platform-dependent — tests should check for nonzero exit, not a specific code.

15. **Reproducible builds.** Same source + same compiler = identical binary. No timestamps, random seeds, or environment-dependent data in output.

16. **First error stops compilation.** The compiler reports the first error it encounters and stops. It does not attempt error recovery or multi-error reporting. The `CheckM` monad is `ExceptT String (StateM TypeEnv)` — a single error halts checking. This simplifies the implementation and produces clear, actionable error messages.

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
- `!` is mutually exclusive with explicit `with()`. You cannot write `fn foo!() with(Unsafe)`. Instead write `fn foo() with(Std, Unsafe)`. The `!` sugar only expands to exactly `Std`, no more.
- `with(Std, Unsafe)` is valid — it means "all standard capabilities plus Unsafe." `Std` always expands to its 8 members during checking; there is no `Std` constructor in `CapSet` at the checker level.
- Users cannot define new capabilities
- Capabilities are not runtime values — type-level only, erased before codegen
- Capabilities are checked before monomorphization — generic functions don't change capability requirements at different instantiations
- Changing a public function's capability set is a breaking API change (in both directions)
- Each method in an `impl` block or `trait impl` declares its own capabilities independently
- Mutually recursive functions: each function's declared caps are trusted. If `f with(File)` calls `g with(Network)` and `g` calls `f`, both declarations are trusted — the checker does not compute a fixed-point. If `f` doesn't declare `Network` but calls `g`, that's an error at the call site in `f`.
- `fn main!()` has `Std` which includes `Alloc` but excludes `Unsafe`. A `main!()` that needs FFI must call through a wrapper: `fn ffi_helper() with(Unsafe) { ... }` — and `main!()` cannot call it directly because `Std` does not include `Unsafe`. For FFI from main, use `fn main() with(Std, Unsafe) { ... }` (no `!` sugar).

### Capability polymorphism

> **Note:** The spec blog post defers capability polymorphism as "future work" because it "adds complexity to the type system and the Lean formalization." We promote it to Phase 1 because without it, generic combinators (map, filter, fold) must be duplicated per capability set, which makes the language impractical. The spec says "the theory is well-understood (Koka, Eff, Frank)" — we build on that. The formalization (Phase 9) must account for cap vars from the start.

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
- `!` and `cap` variables do not interact. If a function has `cap C`, the caller's `!` (Std) counts as having those capabilities for the superset check. `C` is inferred from the argument, not from `!`.
- If a function-typed argument itself has a cap variable (e.g., `fn zip_with<T, U, V, cap C, cap D>(f: fn(T) with(C) -> U, g: fn(U) with(D) -> V) with(C, D)`), each cap variable is inferred independently from its respective argument. If the same cap variable appears in two positions, the sets must be equal (not unioned).

### Implementation

**Prerequisites:** This phase also adds `Ty.fn` (function type) to the `Ty` inductive, since capability polymorphism requires representing `fn(T) with(C) -> U` as a type. This is also needed by Phase 2 (closures).

- **AST**:
  - Add `Ty.fn_ (params : List Ty) (capSet : CapSet) (retTy : Ty)` — function type with capabilities. Pretty-print as `fn(Int, Bool) -> String` (pure) or `fn(Int, Bool) with(File) -> String` (effectful).
  - `FnDef` gets `capParams : List String := []` and `capSet : CapSet := CapSet.empty`
  - `FnSigDef` (trait method signatures) gets `capSet : CapSet := CapSet.empty`
  - `ImplTraitBlock` gets `capSet : CapSet := CapSet.empty` (for capabilities on the impl, used by `destroy` in Phase 3). **Note:** Phase 3 references this same field — do NOT add a separate `implCapSet` field. It is the same `capSet` field on `ImplTraitBlock`.
  - New `CapSet` inductive type:
    ```
    inductive CapSet where
      | empty                              -- no capabilities (pure)
      | concrete (caps : List String)      -- concrete set, e.g., ["File", "Network"]
      | var (name : String)                -- capability variable, e.g., "C"
      | union (a b : CapSet)               -- union of two sets
    ```
  - **CapSet normalization:** Before any comparison, normalize `CapSet` to a flat `List String` (for concrete caps) + `List String` (for cap variables). `union (concrete ["File"]) (concrete ["Network"])` normalizes to `concrete ["File", "Network"]`. `union (var "C") (concrete ["File"])` stays as a union. `Std` is NOT a CapSet constructor — the parser expands `!` and `Std` to `concrete ["File", "Network", "Clock", "Env", "Random", "Process", "Console", "Alloc"]` at parse time.
  - Also modify `FnSig` (the checker's internal representation, currently at Check.lean lines ~31-35) to add `capSet : CapSet := CapSet.empty`. This is how the checker tracks capabilities for registered functions.
- **Token/Lexer**: Add `with_` keyword. Add `cap_` keyword. `!` after an identifier in function position is not a new token — the parser handles it (see below).
- **Parser**:
  - Parse `with(Cap1, Cap2)` after params and before `->` on function declarations
  - Parse `cap C` in generic param lists (after type params): `<T, U, cap C>`
  - `!` sugar: after parsing `fn` + identifier, if next token is `!`, consume it and set capSet to `CapSet.concrete ["File", "Network", "Clock", "Env", "Random", "Process", "Console", "Alloc"]` (i.e., `Std` minus `Unsafe`). The `!` is NOT a separate identifier — it's consumed by the parser as a modifier. If `!` appears AND there is also a `with(...)`, that is a parse error: "cannot combine ! sugar with explicit with()"
  - Parse `fn(T, U) with(C) -> R` as a type (`Ty.fn_`). If no `with()`, use `CapSet.empty`.
- **Check.lean**:
  - Store each function's cap set in `FnDef.capSet`, `FnSigDef.capSet`, and `FnSig.capSet`
  - **Superset check algorithm:** To check `callerCaps ⊇ calleeCaps`:
    1. Normalize both to flat lists of concrete cap names and cap variables
    2. For each concrete cap in callee: verify it exists in caller's concrete caps. If missing, error: `"function '{calleeName}' requires capability '{missingCap}' but caller '{callerName}' does not declare it"`
    3. For each cap variable in callee: it was already inferred at this call site (see below). The inferred concrete caps are checked against the caller via step 2.
  - **Cap variable inference algorithm:** When calling a function with `cap C` parameter:
    1. Find the function-typed argument corresponding to `C` (the argument whose type is `fn(...) with(C) -> ...`)
    2. Look at the actual argument's type — if it's a closure or function reference, extract its concrete cap set
    3. `C` is bound to that concrete set for this call site
    4. If `C` appears in the function's own `with()` clause, the inferred concrete caps are added to the callee's requirements and checked against the caller
    5. If the actual argument has an unresolved cap variable (e.g., the argument is itself cap-polymorphic), that is an error: `"cannot infer capability variable '{C}' from polymorphic argument"`
  - Recursive functions: each function's declared caps are trusted (no fixed-point). If `f` declares `with(File)` and calls itself, that's fine. Same for mutually recursive functions.
  - Method calls: look up the method's cap set from the impl block, check against caller's caps
  - Trait method calls: cap set comes from the trait impl, not the trait definition. **Matching rule:** the trait impl's method cap set must be a **subset** of the trait definition's method cap set (the impl can require fewer capabilities, not more). This is because callers rely on the trait's declared capabilities as an upper bound. If the trait says `fn read(&self) with(File)` and the impl says `fn read(&self)` (pure), that's valid — the impl is more restricted. If the impl says `fn read(&self) with(File, Network)`, error: `"impl method 'read' declares capability 'Network' not declared in trait"`
- **Codegen**: No change. Capabilities are erased at compile time.

### Backward compatibility

Adding capabilities to the compiler will cause existing tests and examples to fail if they call `extern fn` or other effectful operations without `with()`. **Strategy:** Phase 1 adds the capability system but does NOT gate `extern fn` calls behind `Unsafe` yet — that is Phase 7's job. Phase 1 only gates: calling functions that explicitly declare `with(Cap)`. Existing functions without `with()` remain pure and continue to work. Existing `extern fn` calls remain unchecked until Phase 7. All 59 existing tests must continue to pass after Phase 1.

### Tests

- `cap_pure.con`: pure function cannot call effectful function → error
- `cap_propagation.con`: caller missing callee's capability → error
- `cap_basic.con`: `with(File)` function calls `with(File)` function → ok
- `cap_bang.con`: `main!()` can call anything (except Unsafe) → ok
- `cap_poly.con`: `map<T, U, cap C>` infers C from argument → ok
- `cap_poly_multi.con`: `fn zip_with<T, U, V, cap C, cap D>(...)` with two cap vars → ok
- `error_cap_poly_fail.con`: caller doesn't have inferred cap set → error
- `cap_method.con`: method with `with(File)` on impl, called from `with(File)` function → ok
- `error_cap_method.con`: method with `with(File)`, called from pure function → error "requires capability 'File'"

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
  - Capturing a linear value **moves** it into the closure (original is consumed in the enclosing scope — its `VarState` becomes `consumed`)
  - Capturing a primitive type (Int, Bool, etc.) **copies** it (primitives are always Copy). Original stays live in enclosing scope.
  - Capturing a `Copy`-marked type copies it (once Phase 3 adds the `Copy` marker; until then, all structs are linear and capturing moves)
  - Capturing a `&T` borrows it — closure cannot outlive the borrow region
  - Capturing a `&mut T` borrows exclusively — no other borrows while closure exists
- **Closure linearity:** A closure is linear (must be called exactly once) if it captures any linear values. A closure is non-linear (can be called zero or more times) if it captures only copyable values or nothing. The linearity of a closure is NOT part of `Ty.fn_` — it is tracked separately in the checker via a `isLinear : Bool` annotation on the closure expression. A linear closure assigned to a variable makes that variable linear.
- Closure capabilities: if the body calls functions requiring capabilities, the closure type carries those capabilities in `Ty.fn_`'s `capSet`. The checker computes this from the body.
- **Escaping closures:** A closure "escapes" its defining scope if it is returned from a function, stored in a struct field, or passed to a function whose parameter type outlives the current scope. Escaping closures cannot capture references (`&T`, `&mut T`) — only owned values. Error: `"closure captures reference '&{name}' that would escape its borrow region"`
- Closures that escape cannot capture the enclosing function's capability context implicitly — they must declare their own capabilities with `with(...)`.
- Function types: `fn(Int) -> Bool` (pure), `fn(Int) with(File) -> Bool` (effectful)
- Closures cannot be recursive — a closure cannot call itself because it has no name to reference. (Named functions can be recursive; closures cannot.)
- Disambiguation: `fn` followed by `(` in expression position (not after `pub`, not at top level of module) is a closure. At top level, `fn` starts a function definition.
- **Mutable variables and capture:** If a `let mut` variable is captured, the capture follows the same rules as above (copy if Copy, move if linear). The closure captures the current value at the point of capture, not a reference to the variable. After a move-capture, the original variable cannot be assigned to or read in the enclosing scope.

### Implementation

**Prerequisite:** `Ty.fn_` from Phase 1 must exist.

- **AST**:
  ```
  inductive CaptureMode where
    | copy    -- value is copied, original stays live
    | move    -- value is moved, original is consumed

  Expr.closure (params : List Param)
               (capSet : CapSet)
               (retTy : Option Ty)
               (body : List Stmt)
               (captures : List (String × CaptureMode))
               (isLinear : Bool)
  ```
  The `captures` and `isLinear` fields are filled in by the checker, not the parser. The parser sets `captures := []` and `isLinear := false`.
- **Parser**: When `fn` appears in expression position (after `=`, `,`, `(`, `return`), parse as closure. If params have type annotations, use them; if not, leave types as `Ty.unknown` for bidirectional inference.
- **Check.lean**:
  - Analyze closure body for free variables (variables referenced in the body that are not parameters of the closure and not global functions) → those are captures
  - For each capture: look up the variable's type in the enclosing scope.
    - If the type is a primitive or `Copy` type → `CaptureMode.copy`, original stays live
    - Otherwise → `CaptureMode.move`, mark original as `consumed` in enclosing scope
  - The closure's linearity: `isLinear = true` if any capture is `CaptureMode.move`
  - If `isLinear = true`, the variable holding the closure is tracked as linear (must be used exactly once — i.e., called exactly once). Calling a linear closure consumes it. Error if called twice: `"linear closure '{name}' already called"`. Error if never called: `"linear closure '{name}' was never consumed"`
  - **Bidirectional type inference for closure params:** works in two positions:
    1. Function argument: if closure is argument `i` of a function call, and the function's parameter `i` has type `fn(T1, T2) with(C) -> R`, infer closure param types from `T1, T2` and cap set from `C`
    2. Variable with explicit type: if `let f: fn(Int) -> Bool = fn(x) { ... };`, infer `x: Int`
    3. Otherwise (standalone closure with no type context): all untyped params are errors. Error: `"cannot infer type of closure parameter '{name}' without type context"`
  - Compute closure's cap set from its body (same capability checking as regular functions). If the closure body calls `with(File)` functions, the closure's type is `fn(...) with(File) -> ...`. Verify the expected type (from bidirectional inference) has a compatible cap set.
  - Check captured borrows don't escape their region
  - Inside the closure body, create a fresh linearity scope where each captured variable starts as `unconsumed`. Move-captured variables are linear in the closure body (must be consumed exactly once within the body). Copy-captured variables follow their type's rules.
- **Codegen**:
  - **All closures use fat pointer representation:** `{ ptr fn, ptr env }`. For no-capture closures, `env = null`. This uniform representation means `Ty.fn_` always has the same LLVM type regardless of captures. Do NOT generate plain function pointers for no-capture closures — always use the fat pointer for consistency.
  - With captures: generate a struct `%closure_env.N` containing each captured value. Allocate it (stack `alloca` if non-escaping, heap if escaping via Phase 5). The generated function takes `ptr %env` as first param, bitcasts to `%closure_env.N*`, loads each field.
  - Without captures: generate the function body as a normal function. Set `env = null` in the fat pointer.
  - Calling a closure: load `fn` and `env` from the fat pointer. Call `fn(env, arg1, arg2, ...)`. The callee ignores `env` if it's null (no captures case — the function just doesn't use the first param).

### Tests

- `closure_basic.con`: simple closure, no captures → ok
- `closure_capture_copy.con`: capture Int (primitive, always Copy) → ok, original still usable
- `closure_capture_move.con`: capture linear struct → original consumed, error if used after
- `closure_linear.con`: closure with linear capture must be called exactly once
- `closure_cap.con`: closure with `with(File)` captures + capability → ok
- `closure_generic.con`: closure as argument to generic `map<T, U, cap C>` with type inference → ok
- `error_closure_escape_borrow.con`: capture &T that escapes → error
- `error_closure_double_call.con`: call linear closure twice → error
- `error_closure_uncalled.con`: linear closure never called → error "was never consumed"
- `error_closure_infer.con`: standalone closure with untyped params and no context → error

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
// Structs: add Copy keyword after struct
struct Copy Point {
    x: Float64,
    y: Float64
}

// Enums: add Copy keyword after enum
enum Copy Direction {
    North,
    South,
    East,
    West
}

// Generic Copy type: only Copy if T is Copy
struct Copy Pair<T> {    // error if T is not Copy at instantiation
    first: T,
    second: T
}
```

Note: The spec uses `type Copy Name { ... }` (unified `type` keyword). Since we use separate `struct`/`enum` keywords (see Design Decisions), our syntax is `struct Copy Name { ... }` and `enum Copy Name { ... }`.

### Rules

**Destroy:**
- `Destroy` is a built-in trait with one method: `fn destroy(self) -> Unit`
- **`destroy` is a reserved identifier.** The parser parses `destroy(x)` as a normal function call `Expr.call "destroy" [] [x]`. The checker intercepts calls to the identifier `destroy` and resolves them via `Destroy` trait lookup. Users cannot define a function named `destroy` — error: `"'destroy' is a reserved identifier"`.
- `with()` on the `impl Destroy for T` declares capabilities the destructor needs
- Calling `destroy(x)` requires the caller to have those capabilities. Error: `"calling 'destroy' on type 'File' requires capability 'File'"`
- `destroy(x)` is only valid if the type implements `Destroy`. Error: `"type 'Point' does not implement Destroy"`
- Types without `Destroy` must be consumed by moving, returning, or destructuring
- **Generic types and Destroy:** `impl Destroy for Container<T>` can destructure `self` to access inner fields and consume them. If the inner `T` is linear, the destroy implementation must consume it (e.g., call `destroy(self.data)` if `T: Destroy`, or move it elsewhere). The impl does NOT require `T: Destroy` by default — it requires whatever the body needs.

```
struct Wrapper<T> { inner: T }

impl Destroy for Wrapper<T> {
    fn destroy(self) -> Unit {
        let inner: T = self.inner;  // destructure, consuming self
        destroy(inner);              // only works if T: Destroy
    }
}
```

**Defer:**
- `defer` is **block-scoped** (like Zig, NOT function-scoped like Go). It runs when the enclosing `{ }` block exits.

```
fn example!() {
    let f: File = open("a");
    defer destroy(f);        // runs when outer block exits

    {
        let g: File = open("b");
        defer destroy(g);    // runs when inner block exits
        // ... use g ...
    }  // ← destroy(g) runs here

    // f is still live here, g is gone
}  // ← destroy(f) runs here
```

- `defer` runs in LIFO order at scope exit
- `defer destroy(x)` reserves the value: cannot move `x` after deferring, cannot destroy again, cannot re-defer. The variable's `VarState` becomes `reserved`. Error on move: `"variable '{name}' is reserved by defer"`. Error on re-defer: `"variable '{name}' is already deferred"`.
- `defer` runs on normal exit, early return, and `?` error propagation
- **`defer` and `?` ordering:** When `?` encounters an error, deferred statements from **all enclosing scopes within the current function** run first (innermost scope first, LIFO within each scope), then the error value is returned. This means `defer destroy(f)` before a `?` will clean up `f` even if `?` propagates an error.
- `defer` does NOT run on `abort()`
- `defer` can only defer expression statements (function calls, method calls, `destroy()`). `defer let x = ...` or `defer return` are parse errors. Error: `"defer can only defer expression statements"`
- `defer` inside a loop body: each iteration that executes the `defer` adds a deferred action to that iteration's scope. The deferred action runs when the loop body block exits (at end of each iteration, or on `break`/`continue`).
- `break`/`continue` inside `defer` is forbidden (Phase 4 check)
- **`defer` in `if/else` branches:** If `defer destroy(x)` appears in only one branch, both branches must still agree on `x`'s consumption. Example:

```
let x: Resource = make_resource();
if cond {
    defer destroy(x);  // x is reserved+deferred here
    // ... use x ...
}  // destroy(x) runs on true branch exit
else {
    consume(x);         // x is consumed here
}
// Both branches consumed x — valid
```

If one branch defers and the other does nothing with `x`, that's a linearity error (one path consumes, other doesn't).

- **`defer` closures (Phase 2 interaction):** `defer my_closure();` is valid if `my_closure` is a closure variable. If the closure is linear, the `defer` guarantees it's called exactly once at scope exit. However, if the scope exits via `abort()`, the deferred closure does NOT run — this means a linear closure may not be consumed on the abort path. This is acceptable because `abort()` is outside the semantic model (see Invariant 14).

**Copy:**
- `Copy` is explicit and opt-in via `struct Copy` / `enum Copy`
- A type implementing `Destroy` cannot be `Copy`. Error: `"type 'File' implements Destroy and cannot be Copy"`
- A `Copy` type cannot implement `Destroy` and cannot contain linear fields. Error: `"Copy type 'Wrapper' contains linear field 'inner' of type 'Resource'"`
- Primitive types (Int, Uint, i8-i64, u8-u64, f32, f64, Bool, Char) are built-in `Copy`
- `String` is linear (not `Copy`)
- `&T` is `Copy`; `&mut T` is not `Copy`
- Arrays of `Copy` types are `Copy`; arrays of linear types are linear
- Enums can be `Copy` if all variant fields are `Copy`. `enum Copy Option<T>` requires `T` to be `Copy` at every instantiation.
- `Heap<T>` and `HeapArray<T>` are always linear, never `Copy`.

**Abort:**
- `abort()` is a built-in function that immediately terminates the process
- Deferred cleanup does NOT run on abort
- Out-of-memory triggers abort. Stack overflow triggers abort.
- `abort()` does not require any capability — it is always available
- `abort()` returns type `Never` (bottom type) — it can appear anywhere any type is expected

### Implementation

- **AST**:
  - `Stmt.defer (body : Stmt)` — the body must be an expression statement
  - `StructDef` gets `isCopy : Bool := false` — true for `struct Copy` definitions
  - `EnumDef` gets `isCopy : Bool := false` — true for `enum Copy` definitions
  - Phase 1 already added `ImplTraitBlock.capSet : CapSet` — this same field is used for `impl Destroy for T with(Cap) { ... }`. Do NOT add a separate `implCapSet` field.
  - `Expr.abort` — built-in abort expression
  - Add `Ty.never` to the `Ty` inductive — the bottom type. In the checker, `Ty.never` is compatible with any expected type (it can unify with anything). In codegen, code after `abort()` is `unreachable`.
- **Token/Lexer**: Add `defer_` keyword. `abort` is recognized as a built-in identifier (not a keyword — it parses as a function call). `Copy` is recognized as a keyword `copy_` when it appears after `struct` or `enum`.
- **Parser**:
  - Parse `defer <expr-stmt>;` — only allow expression statements after `defer`
  - Parse `struct Copy Name { ... }` and `enum Copy Name { ... }` — after `struct`/`enum`, if next token is `Copy` (capitalized identifier), consume it and set `isCopy = true`, then parse the rest normally
  - `impl Destroy for T with(Cap) { ... }` already parses via existing impl-trait parsing; the `with(Cap)` on the `impl` line is stored in `ImplTraitBlock.capSet` (added in Phase 1)
  - `destroy(x)` parses as a normal function call `Expr.call "destroy" [] [x]`
- **Check.lean**:
  - **Pre-register `Destroy` trait:** At initialization, add a hardcoded `TraitDef { name := "Destroy", typeParams := [], methods := [FnSigDef { name := "destroy", params := [Param "self" Ty.selfTy], retTy := Ty.unit, selfKind := some SelfKind.value, ... }], isPublic := true }` to the type environment. If a user writes `trait Destroy { ... }`, error: `"'Destroy' is a built-in trait and cannot be redeclared"`
  - **Intercept `destroy` calls:** When checking `Expr.call "destroy" [] [x]`, do not look up a normal function named `destroy`. Instead, look up the `Destroy` impl for the type of `x`. If found, check the impl's `capSet` against the caller's capabilities. Mark `x` as `consumed`. If not found, error: `"type '{typeName}' does not implement Destroy"`. If a user defines `fn destroy(...)`, error: `"'destroy' is a reserved identifier"`
  - Track deferred values as "reserved" in `VarState` — add a `reserved` state (not movable, not destroyable, not re-deferable)
  - When exiting a block scope: the codegen handles emitting deferred calls. The checker verifies that reserved values are still valid at scope exit.
  - Verify `Copy`/`Destroy` mutual exclusivity: if a type has `isCopy = true` and also has an `impl Destroy`, error: `"type '{name}' implements Destroy and cannot be Copy"`
  - For `Copy` types: verify all fields are themselves `Copy` (recursive check). For generic `Copy` types, defer the check to instantiation — `struct Copy Pair<T>` is only valid if the actual `T` is `Copy`.
  - `abort()` is always allowed, returns `Ty.never`. Any code after `abort()` in the same block is dead code (the checker can skip it or warn).
- **Codegen**:
  - Track deferred statements per block scope (stack of deferred lists: `List (List Stmt)`)
  - At block exit: emit all deferred statements in that scope, LIFO order
  - Before every `ret` instruction: emit all deferred statements from all enclosing scopes, innermost first, LIFO within each scope
  - Before `?` propagation branch (the error path): emit all deferred statements from all enclosing scopes within the current function, innermost first, LIFO within each scope. Then branch to return the error.
  - `destroy(x)` compiles to `call void @TypeName_destroy(ptr %x)` (where TypeName is the type that implements Destroy)
  - `abort()` compiles to `call void @abort()` followed by `unreachable`

### Tests

- `defer_basic.con`: defer runs at scope exit → ok
- `defer_lifo.con`: multiple defers run in reverse order → ok
- `defer_early_return.con`: defer runs on early return → ok
- `defer_try.con`: defer runs on `?` error propagation → ok
- `defer_block_scope.con`: defer in inner block runs at block exit, not function exit → ok
- `defer_loop.con`: defer inside loop runs at end of each iteration → ok
- `destroy_trait.con`: implement Destroy, call destroy() → ok
- `destroy_generic.con`: Destroy impl for generic type, destructures and consumes inner → ok
- `copy_struct.con`: `struct Copy` type can be used multiple times → ok
- `copy_enum.con`: `enum Copy` type can be used multiple times → ok
- `abort_basic.con`: abort() terminates immediately → ok (exit code nonzero)
- `error_defer_move.con`: move after defer → error "variable 'x' is reserved by defer"
- `error_defer_not_expr.con`: `defer let x = 5;` → error "defer can only defer expression statements"
- `error_copy_destroy.con`: Copy type with Destroy impl → error "implements Destroy and cannot be Copy"
- `error_copy_linear_field.con`: Copy type containing linear field → error "contains linear field"
- `error_destroy_no_impl.con`: destroy(x) on type without Destroy → error "does not implement Destroy"
- `error_destroy_reserved.con`: user defines `fn destroy(...)` → error "'destroy' is a reserved identifier"

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
- **Linear types and break/continue:** Before executing `break` or `continue`, the checker verifies that all linear variables declared within the **loop body block** (from the start of the block to the break/continue point) are consumed. This includes variables in nested blocks inside the loop body. Variables from outside the loop remain live and are not affected. Specifically:

```
while cond {
    let x: LinearStruct = make();    // declared in loop body
    {
        let y: LinearStruct = make(); // declared in nested block inside loop body
        if done {
            consume(y);
            consume(x);
            break;                    // ok: both x and y consumed before break
        }
    }
    consume(x);
}
```

```
while cond {
    let x: LinearStruct = make();
    if done { break; }               // error: "break would skip unconsumed linear variable 'x'"
    consume(x);
}
```

- **Match bindings inside loops:** Variables bound in `match` arms are scoped to that arm's block. If `break` or `continue` appears inside a match arm, the bound variables must be consumed within that arm before the break/continue.

```
while cond {
    match val {
        Foo#A { x } => {
            consume(x);              // x must be consumed before break
            break;
        },
        Foo#B { y } => {
            consume(y);
            continue;
        },
    }
}
```

- `break` inside `defer` is forbidden — compile error: `"break is not allowed inside defer"`
- `continue` inside `defer` is forbidden — compile error: `"continue is not allowed inside defer"`
- Applies to innermost loop only by default. Labeled loops (`'label: while ...`) allow `break 'label` and `continue 'label` to target outer loops.
- For `break val`, all break expressions and the `else` clause must agree on type
- **`for` loops and break:** `break` and `break val` work in `for` loops identically to `while` loops. However, `for`-as-expression (using `break val` to produce a value) is NOT supported — only `while`-as-expression exists. `for` loops are always statements.
- While-as-expression: `while` in expression position (RHS of `let`, argument, etc.) produces a value. The `else` clause is mandatory when using `break val` — it provides the value when the loop condition becomes false without breaking. A `while` without `break val` or without `else` in expression position is a type error.
- The `else` clause is a block `{ ... }` whose **last expression** is the produced value (no `return` needed — it is the value of the block). Same rule as `break val` — the expression at the end of the else block is the produced value.
- `break` (without value) in expression-position while is also valid if `else` is present — both produce `Unit`.
- **`break` and `defer` interaction:** When `break` exits a loop, deferred statements from the current iteration's scopes run before the loop exits. This is tested in `break_defer.con`.

### Implementation

- **AST**: `Stmt.break_ (value : Option Expr)`, `Stmt.continue_`. `Expr.whileExpr (cond : Expr) (body : List Stmt) (elseBody : List Stmt)` for while-as-expression. No `Expr.forExpr` — for loops are statements only.
- **Token/Lexer**: Add `break_` and `continue_` keywords.
- **Parser**: Parse `break;`, `break expr;`, `continue;` inside loops. In expression position, parse `while cond { ... } else { ... }` as `Expr.whileExpr`. Error if `for` loop appears in expression position: `"for loops cannot be used as expressions; use while-as-expression instead"`
- **Check.lean**:
  - Track loop nesting depth. `break`/`continue` outside loop → error: `"break outside of loop"`
  - Track whether we're inside a `defer` body. `break`/`continue` inside defer → error: `"break is not allowed inside defer"`
  - Before `break`/`continue`: collect all linear variables declared since the start of the current loop body block (including nested blocks), verify all consumed. Error: `"break would skip unconsumed linear variable '{name}'"`
  - For `break expr`: collect all break expression types + else clause type, verify agreement. Error: `"break expression type 'Int' does not match else clause type 'Bool'"`
- **Codegen**: `break` → emit deferred statements for loop body scopes, then `br label %loop.exit`. `continue` → emit deferred statements for loop body scopes, then `br label %loop.header`. For `break val`: pre-allocate result slot (`alloca`) before loop, each `break val` stores to the slot before jumping, `else` clause stores to the same slot. After loop, load from slot.

### Tests

- `break_basic.con`: break exits loop → ok
- `break_value.con`: break with value, loop as expression → ok
- `break_defer.con`: break inside loop with defer — defer runs before loop exit → ok
- `continue_basic.con`: continue skips iteration → ok
- `break_for.con`: break inside for loop → ok
- `error_break_outside.con`: break outside loop → error "break outside of loop"
- `error_break_linear.con`: break skips unconsumed linear variable → error
- `error_continue_linear.con`: continue skips unconsumed linear variable → error
- `error_break_in_defer.con`: break inside defer → error "break is not allowed inside defer"

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

### `Heap<T>`: linear owned heap allocation

The spec's allocator trait returns `&mut [T]` — a borrow-checked reference. But allocated memory is **owned**, not borrowed. You get it, you must free it. That's linear ownership.

`Heap<T>` is a built-in linear type representing heap-allocated ownership of a `T`:

```
// Built-in linear types (not user-definable)
Heap<T>          // single heap-allocated value
HeapArray<T>     // dynamically-sized heap-allocated array

trait Allocator {
    fn alloc<T>(&mut self, val: T) -> Result<Heap<T>, AllocError>;
    fn alloc_array<T>(&mut self, count: Uint) -> Result<HeapArray<T>, AllocError>;
    fn free<T>(&mut self, ptr: Heap<T>) -> T;
    fn free_array<T>(&mut self, arr: HeapArray<T>);
    fn realloc_array<T>(&mut self, arr: HeapArray<T>, new_count: Uint) -> Result<HeapArray<T>, AllocError>;
}

impl Destroy for Heap<T> with(Alloc) {
    fn destroy(self) -> Unit { /* frees via bound allocator */ }
}

impl Destroy for HeapArray<T> with(Alloc) {
    fn destroy(self) -> Unit { /* frees via bound allocator */ }
}
```

**Why `Heap<T>` instead of `&mut [T]` or `*mut u8`:**
- **No raw pointers** in the allocator API — fully type-safe
- **No borrow regions needed** — `Heap<T>` is owned, not borrowed. No circular dependency with Phase 6.
- **Linearity enforces cleanup** — forget to free a `Heap<T>`? Compile error.
- **No `Unsafe` boundary** — the entire allocator interface is safe

### Accessing heap values: `->` operator

`Heap<T>` is opaque. To access the value inside, use the `->` arrow operator (like C/C++):

```
fn main!() {
    let arena: Arena = Arena.new();
    defer arena.deinit();

    let p: Heap<Point> = alloc(Point { x: 1.0, y: 2.0 }) with(Alloc = arena);
    defer destroy(p);

    // Read — arrow operator borrows and accesses the field
    let x: Float64 = p->x;
    let y: Float64 = p->y;

    // Write — arrow operator with mutable borrow
    p->x = 3.0;
    p->y = 4.0;

    // Method call on inner value
    let s: Float64 = p->sum();

    // Pass reference to function
    compute(&p);

    // Multiple accesses — borrow block (Phase 6)
    borrow p as pr in R {
        let x: Float64 = pr.x;     // pr is &Point, normal dot
        let y: Float64 = pr.y;
        compute(pr);
    }
}
```

**Why `->` (not transparent `p.x`):** In a world where most code is LLM-generated, writing cost is zero and reading cost is the bottleneck. The `->` operator makes every heap access visible — you can grep for `->` to find all heap dereferences, and code reviewers (human or LLM) see exactly when heap memory is touched without checking declarations. This is the same distinction C/C++ has maintained for 50 years with `.` vs `->`. See [research/heap-ownership-design.md](research/heap-ownership-design.md) for the full design rationale.

**`->` semantics:** `p->x` on `Heap<T>` is sugar for "borrow `p` to get `&T`, then access field `x`." For writes, `p->x = val` is sugar for "mutably borrow `p` to get `&mut T`, then assign to field `x`." The `->` is NOT a user-extensible operator — it is a built-in compiler rule that only works on `Heap<T>` and `HeapArray<T>`.

**Token note:** `->` is already used for return types in function signatures (`fn foo() -> Int`). In expression position, `->` means heap field access. The parser distinguishes by context: after a function parameter list `)`, `->` is a return type arrow; after an expression, `->` is heap access. This is unambiguous in an LL(1) grammar.

**Rules:**
- `p.x` directly on `Heap<Point>` is a type error — you must use `->`. Error: `"cannot access field 'x' on Heap<Point> with '.'; use '->' for heap access: p->x"`
- `p->x` where `p: Heap<T>` borrows `p` as `&T` and accesses field `x`. Returns the field's type.
- `p->x = val` where `p: Heap<T>` mutably borrows `p` as `&mut T` and assigns to field `x`.
- `p->method(args)` where `p: Heap<T>` borrows `p` and calls `method` on the inner `&T` (or `&mut T` for `&mut self` methods).
- `&p` where `p: Heap<T>` gives `&T` (pointer to the heap value). This is for passing to functions that take `&T`.
- `&mut p` where `p: Heap<T>` gives `&mut T`.
- `borrow p as pr in R { ... }` works on `Heap<T>` — `pr` has type `&T`, uses normal `.` syntax. **Note on Phase 6 dependency:** The `borrow ... as ... in R` syntax is defined in Phase 6 (borrow regions). Phase 5 can be implemented before Phase 6 using `->` for field access and `&p` for function arguments. The `borrow` block form becomes available after Phase 6.
- `HeapArray<T>` supports indexing via `->`: `arr->[i]` returns `&T`. `arr->[i] = val` assigns to the element. Bounds checking is performed at runtime — out-of-bounds access calls `abort()`.
- While any borrow is active (from `->`, `&p`, or `borrow` block), `Heap<T>` is frozen (cannot move, destroy, or re-borrow mutably) — same as any borrow. For `->`, the borrow is scoped to the single expression.
- **Allocator identity:** The type system does NOT track which allocator a `Heap<T>` was allocated from. If you allocate with arena A and destroy with arena B, that is a runtime bug but not a compile-time error. This is an intentional limitation — tracking allocator provenance would require dependent types. In practice, the `defer` pattern (`alloc → defer destroy → use`) naturally pairs allocation and deallocation.

### Collections

`Vec<T>` wraps `HeapArray<T>`:

```
struct Vec<T> {
    buf: HeapArray<T>,
    len: Uint,
    cap: Uint,
}

impl Vec<T> {
    fn push(&mut self, val: T) with(Alloc) { ... }
    fn get(&self, index: Uint) -> &T { ... }
}

impl Destroy for Vec<T> with(Alloc) {
    fn destroy(self) -> Unit { /* destroy elements, free buf */ }
}
```

`Vec<T>` is linear because it contains `HeapArray<T>` (linear). Implements `Destroy with(Alloc)`.

### `alloc()` and `free()` as built-in functions

`alloc(val)` and `free(ptr)` are **built-in functions** that the checker resolves through the bound allocator, similar to how `destroy(x)` resolves through the Destroy trait. They are NOT methods on a specific allocator object. The dispatching happens through the hidden allocator parameter.

```
// alloc(val) is sugar for: <bound allocator>.alloc(val)
let p: Heap<Point> = alloc(Point { x: 1.0, y: 2.0 }) with(Alloc = arena);

// free(ptr) is sugar for: <bound allocator>.free(ptr)
let val: Point = free(p) with(Alloc = arena);

// alloc_array, free_array, realloc_array follow the same pattern
let arr: HeapArray<Int> = alloc_array<Int>(100) with(Alloc = arena);
```

The identifiers `alloc`, `free`, `alloc_array`, `free_array`, and `realloc_array` are **reserved identifiers** (like `destroy`). The checker intercepts calls to these names and routes them through the `Allocator` trait impl for the bound allocator's type.

### Rules

- `with(Alloc)` in signature means the function may allocate
- `with(Alloc = expr)` at call site binds a specific allocator for that call and all nested `with(Alloc)` calls
- **Allocator propagation in detail:** When a function `f with(Alloc)` calls another function `g with(Alloc)` without explicit `with(Alloc = expr)`:
  1. The allocator that was bound when `f` was called is automatically forwarded to `g`
  2. This forwarding is transitive: if `g` calls `h with(Alloc)` without binding, `h` also gets the same allocator
  3. An explicit `with(Alloc = other)` at any point in the chain overrides the forwarded allocator for that call and its nested calls
  4. Different calls within the same function can use different allocators: `g() with(Alloc = arena1)` then `h() with(Alloc = arena2)` is valid
  5. At the codegen level, the allocator is a hidden `ptr %allocator` parameter — always the **last** parameter (after `self` if present, after regular params). Forwarding means passing this param through unchanged.
- Stack allocation does not require `Alloc`
- A function without `with(Alloc)` cannot call anything with `with(Alloc)` — always explicit
- **`with()` at call site is ONLY for `Alloc`.** You cannot write `foo() with(File = f)` — only `Alloc` has call-site binding. Mixing capabilities and bindings in one `with()` at a call site is a parse error: `foo() with(File, Alloc = arena)` is invalid. The call-site `with()` can only contain `Alloc = expr`.
- **Closures and Alloc (Phase 2 interaction):** A closure inside a `with(Alloc)` function can call `with(Alloc)` functions — it captures the allocator parameter from its environment (same as any other captured value). The closure's type must include `Alloc` in its cap set. If the closure escapes, the allocator must still be valid when the closure runs (the programmer's responsibility — same as allocator identity issue).

### Parser disambiguation

The `with(...)` syntax appears in two contexts:
1. **Declaration**: `fn foo() with(File, Alloc) -> T { ... }` — capability declaration on function signature. Contains capability names, no `=`.
2. **Call site**: `foo() with(Alloc = arena)` — allocator binding on function call. Contains `Alloc = expr`.

The parser distinguishes them by position: after `)` of a function *declaration* (before `->` or `{`), it's a capability declaration. After `)` of a function *call expression*, it's a call-site binding. The `=` inside `with()` also disambiguates — declarations never have `=`.

### Implementation

- **AST**:
  - `Expr.call` gets `allocBind : Option Expr := none`. `Expr.methodCall` also gets `allocBind : Option Expr := none`.
  - Add `Ty.heap (inner : Ty)` and `Ty.heapArray (inner : Ty)` to the `Ty` inductive — these are the types for `Heap<T>` and `HeapArray<T>`.
  - `Heap<T>` and `HeapArray<T>` are always linear (never Copy). `isCopyType (.heap _) => false`, `isCopyType (.heapArray _) => false`.
- **Parser**: After `)` of a function call, if next tokens are `with` `(` `Alloc` `=`, parse the expression and store in `allocBind`. Error if call-site `with()` contains anything other than `Alloc = expr`: `"call-site with() can only bind Alloc"`.
- **Check.lean**:
  - If calling a function with `Alloc` in its cap set, caller must either (a) have `Alloc` in its own cap set (allocator is forwarded from caller's hidden param), or (b) provide `with(Alloc = expr)` at the call site. Verify expr's type implements `Allocator` trait. Error: `"function '{name}' requires Alloc but no allocator is bound"`
  - **Intercept built-in allocator functions:** `alloc`, `free`, `alloc_array`, `free_array`, `realloc_array` are reserved identifiers. When checking a call to these names, resolve through the `Allocator` trait impl for the bound allocator type. Error if user defines these: `"'{name}' is a reserved identifier"`
  - Type check `alloc(val)`: return type is `Result<Heap<T>, AllocError>` where `T` is the type of `val`. `free(ptr)`: takes `Heap<T>`, returns `T`. `alloc_array<T>(count)`: returns `Result<HeapArray<T>, AllocError>`.
- **Codegen**: Functions with `Alloc` in their cap set get a hidden `ptr %allocator` as the last parameter. `with(Alloc = arena)` → pass arena's pointer. Inside a `with(Alloc)` function calling another `with(Alloc)` function without explicit binding → forward `%allocator`.

### Testing strategy

Phase 5 depends on having at least one `Allocator` implementation for tests. Since `Arena`, `GeneralPurposeAllocator`, etc. are in Phase 8 (standard library), Phase 5 tests use a **built-in test allocator**: a simple wrapper around `malloc`/`free` that implements the `Allocator` trait. This test allocator is NOT part of the language — it exists only in test code and uses `Unsafe` internally.

### Tests

- `alloc_basic.con`: bind allocator at call site, allocate and free → ok
- `alloc_propagate.con`: allocator propagates through nested calls → ok
- `alloc_different.con`: different allocators for different calls → ok
- `alloc_method.con`: method call with allocator binding → ok
- `heap_arrow.con`: `p->x` on `Heap<Point>` → ok
- `heap_arrow_mut.con`: `p->x = val` on `Heap<Point>` → ok
- `error_alloc_missing.con`: call with(Alloc) function without binding → error "requires Alloc but no allocator is bound"
- `error_alloc_no_cap.con`: function without Alloc calls with(Alloc) function → error
- `error_heap_direct_access.con`: `p.x` on `Heap<Point>` without borrow → error "cannot access field"
- `error_heap_leak.con`: allocate `Heap<T>` without consuming → error "linear variable was never consumed"

---

## Phase 6: Borrow regions

Explicit lexical regions that bound reference lifetimes. No lifetime annotations in function signatures.

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

- Level 1 (`&x` in expression): anonymous region spanning that expression. Already implemented. The anonymous region is scoped to the single expression — e.g., `length(&f)` creates a region that ends when `length` returns.
- Level 2 (`borrow x as y in R { ... }`): named region, named reference. Required when you need the region name in a type or when you need a borrow that spans multiple statements.
- While borrowed, the original is frozen (unusable for Level 1; frozen for the block in Level 2)
- Multiple immutable borrows allowed; mutable borrows exclusive
- References cannot escape their region. Specifically:
  - Cannot be returned from a function
  - Cannot be stored in a struct field that outlives the region
  - Cannot be assigned to a variable declared outside the borrow block
  - Cannot be captured by a closure that escapes the borrow block
  - Error: `"reference with region '{R}' cannot escape its borrow block"`
- Region names follow the no-shadowing rule (Invariant 4). `borrow x as xr in R` introduces `xr` (the reference) and `R` (the region) into scope. Neither may shadow existing names. Error: `"region name '{R}' shadows existing name"`
- Nested borrow blocks with different region names are fine:

```
borrow x as xr in R1 {
    borrow y as yr in R2 {
        // xr: &[X, R1], yr: &[Y, R2]
        // both usable here
    }
}
```

- Functions are implicitly generic over regions — **no lifetime params in function signatures**. The surface syntax for function parameters uses `&T` and `&mut T` without region annotations. The checker internally assigns anonymous regions.
- **Region inference for function calls:** When a function takes `&T` and returns `&U`, the compiler assumes the output reference's region is the intersection (most restrictive) of the input reference regions. Concretely:
  - One input ref → output gets the same region. `fn first(list: &List<T>) -> &T` — the returned `&T` has the same region as the input `&List<T>`.
  - Multiple input refs of the same region → output gets that region.
  - Multiple input refs with different regions → error: `"ambiguous output region: function takes references from regions '{R1}' and '{R2}'; use an explicit borrow block to disambiguate"`. The programmer must restructure using a borrow block.
- **`&[T, R]` is not surface syntax.** Region-annotated reference types exist only in the checker's internal representation. The programmer never writes `&[T, R]` — they write `&T`. Region annotations are inferred from the borrow block structure. This keeps the surface language simple.
- **`Heap<T>` and borrow blocks (Phase 5 interaction):** The `borrow p as pr in R { ... }` syntax works on `Heap<T>` — it borrows the heap value, giving `pr: &T` (or `&mut T`). This uses the same AST node (`Stmt.borrowIn`) as borrowing stack values. The only difference is in codegen: borrowing a stack value takes the address of an alloca; borrowing a `Heap<T>` loads the inner pointer from the `Heap<T>` wrapper.
- **Closures and regions (Phase 2 interaction):** A closure can capture a reference `&T` from an enclosing borrow block, but the closure cannot escape that block. The checker verifies this via the escape analysis. If a closure captures a reference with region `R` and the closure's type is assigned to a variable outside region `R`'s scope, error: `"closure captures reference from region '{R}' that would escape"`. Non-escaping closures (called within the borrow block, not stored or returned) can freely capture references.

### Implementation

- **AST**:
  - Add `Ty.refRegion (inner : Ty) (region : String)` and `Ty.refMutRegion (inner : Ty) (region : String)` — region-annotated reference types (checker-internal, not surface syntax)
  - `Stmt.borrowIn (var : String) (ref : String) (region : String) (isMut : Bool) (body : List Stmt)` for `borrow [mut] x as y in R { ... }`
- **Token/Lexer**: Add `borrow_` keyword. Add `in_` keyword (or reuse existing `in` if already tokenized for `for` loops). Add `as_` keyword.
- **Parser**: Parse `borrow x as y in R { ... }` and `borrow mut x as y in R { ... }`. `x` must be an identifier (the variable to borrow). `y` is the reference name. `R` is the region name. All three are identifiers.
- **Check.lean**:
  - For Level 1 (`&x`): existing behavior — freeze `x` for the expression, create anonymous region
  - For Level 2: check that `R` and `y` don't shadow existing names. Register region `R` in scope. Freeze original `var`. Create reference binding `ref` with internal type `Ty.refRegion T R` (or `Ty.refMutRegion T R`). Check body. At block exit: unfreeze original, remove `R` and `y` from scope.
  - **Escape check algorithm:** When a reference with region `R` would be assigned to a variable, the checker verifies that the variable's scope is enclosed within region `R`'s scope. This is a simple scope-nesting check: region `R` is introduced by a `borrow` block, and any variable declared outside that block cannot hold a reference tagged with `R`. Also check: return statements cannot return values that contain references with non-anonymous regions; struct construction cannot store region-tagged references in fields.
  - Region inference for function calls: match input/output region names, infer when unambiguous. When ambiguous, error.
- **Codegen**: All forms produce same IR as current `&x` — pointer to the alloca/storage (for stack values) or pointer to the heap memory (for `Heap<T>`). Regions are type-checker only, completely erased in codegen.

### Tests

- `borrow_named.con`: named region, named reference → ok
- `borrow_mut_named.con`: mutable borrow in named region → ok
- `borrow_multi.con`: multiple borrows of different variables in nested regions → ok
- `borrow_heap.con`: borrow block on `Heap<T>` (Phase 5 interaction) → ok
- `error_borrow_escape.con`: reference escapes region → error "cannot escape its borrow block"
- `error_borrow_frozen.con`: use original inside borrow block → error
- `error_borrow_closure_escape.con`: closure captures reference from borrow region and escapes → error
- `error_borrow_shadow.con`: region name shadows existing variable → error "shadows existing name"

---

## Phase 7: FFI and C interop

Needed before the runtime (Phase 12 is written in C) and for any real-world systems programming use.

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
- Calling an `extern fn` requires `with(Unsafe)` — FFI is never silent. Error: `"calling extern function '{name}' requires Unsafe capability"`
- Only C-compatible types in extern signatures: integer types (i8-i64, u8-u64, Int, Uint), float types (f32, f64), `Bool`, raw pointers (`*mut T`, `*const T`). Error: `"type '{type}' is not C-compatible and cannot be used in extern function signatures"`
- **`Bool` ABI:** Concrete's `Bool` maps to LLVM `i1` internally. In extern function signatures, `Bool` is promoted to `i8` for C ABI compatibility (C's `_Bool` is typically `i8`). The codegen emits `zext i1 to i8` before passing to extern and `trunc i8 to i1` when receiving.
- Structs with `#[repr(C)]` attribute get C-compatible memory layout (fields in declaration order, platform alignment). **`#[repr(C)]` is the only attribute in Concrete.** No general attribute system exists — `#[repr(C)]` is parsed as a special form before struct definitions. Other attributes are not supported.
- Structs without `#[repr(C)]` cannot be passed to extern functions by value. Error: `"struct '{name}' cannot be passed to extern function; add #[repr(C)] for C-compatible layout"`
- **No automatic string conversion.** Concrete's `String` is a linear type and cannot be passed to C. To pass string data to C: obtain a `*const u8` pointer and a length. The mechanism depends on `String`'s internal representation (Phase 8). Until Phase 8, use `extern fn` with raw pointers and test with string literals via array-of-u8.
- Raw pointer dereference (`*ptr`) requires `with(Unsafe)`. Error: `"dereferencing raw pointer requires Unsafe capability"`
- **Raw pointer operations:** Pointers support these operations:
  - `*ptr` — dereference (requires `Unsafe`). Returns `T` (copy for Copy types, move for linear types).
  - `&x as *const T` / `&mut x as *mut T` — create pointer from reference (safe, no `Unsafe` needed)
  - `ptr as *const U` / `ptr as *mut U` — pointer cast (requires `Unsafe`)
  - No pointer arithmetic in safe code. Pointer arithmetic requires `Unsafe` and is provided via `extern fn` or `transmute`.
- `transmute<T>(expr)` requires `with(Unsafe)`. Size check: `size_of(typeof(expr)) == size_of(T)`. Error: `"cannot transmute between types of different sizes: '{source}' ({n} bytes) and '{target}' ({m} bytes)"`. **`transmute` only works on concrete (non-generic) types.** You cannot `transmute<T>(x)` where `T` is a type parameter — the size is not known at compile time. Error: `"cannot transmute to generic type '{T}'"`
- Creating a raw pointer (`&x as *const T`) is safe — using one is not
- **Callback function pointers to C:** Only no-capture closures (plain function pointers) can be passed to C as callback pointers. Closures with captures use a fat pointer `{ ptr fn, ptr env }` which is not C-compatible. If a captured closure is passed to an extern function parameter typed as a function pointer, error: `"closure with captures cannot be passed to C; use a function without captures"`. The C-compatible function pointer type for extern signatures is `*const fn(T) -> U` (a raw pointer to a function).

### Migration

Existing `extern fn` calls in examples and tests do NOT currently require `Unsafe`. After Phase 1 (capabilities) and Phase 7 are implemented, these will need updating to declare `with(Unsafe)`. Affected examples: `malloc.con`, any example using `extern fn`. **Migration steps per affected test/example:**
1. Add `with(Unsafe)` to any function that calls `extern fn`
2. If called from `main!()`, either change to `fn main() with(Std, Unsafe)` or wrap in a helper

### Implementation

- **AST**: `ExternFn` already exists. Add `StructDef.reprC : Bool := false`. Add `Expr.transmute (targetTy : Ty) (inner : Expr)`. Add `Expr.ptrDeref (inner : Expr)`.
- **Token/Lexer**: `Unsafe` is recognized as a capability name (just an identifier). `transmute` is a built-in identifier (reserved, like `destroy`). `#[repr(C)]` parsing: `#` already tokenized as `hash`; parser handles the sequence `# [ repr ( C ) ]` as a special form.
- **Parser**: Parse `#[repr(C)]` before struct definitions, set `reprC = true`. If `#[` is followed by anything other than `repr(C)]`, error: `"unknown attribute; only #[repr(C)] is supported"`. Parse `transmute<T>(expr)` — `transmute` is a reserved identifier followed by `<`, type, `>`, `(`, expr, `)`. Parse `*expr` as `Expr.ptrDeref`.
- **Check.lean**: Verify all `extern fn` call sites have `with(Unsafe)`. Verify extern param/return types are C-compatible (reject structs without repr(C), reject String, reject enums, reject closures with captures). Verify `*ptr` deref has `with(Unsafe)`. Verify `transmute` has `with(Unsafe)`, types are concrete (not generic), and sizes match. For size computation: maintain a `sizeOf : Ty → Option Nat` function for primitive types and `#[repr(C)]` structs.
- **Codegen**: `extern fn` emits `declare` (already works). `#[repr(C)]` structs use C layout rules (fields in order, natural alignment, struct padding). `Bool` in extern signatures: `zext i1 to i8` on call, `trunc i8 to i1` on return. `transmute` → `bitcast` for pointers, or store-to-alloca + load-with-different-type for value types. `*ptr` → `load T, ptr %val`.

### Tests

- `ffi_basic.con`: call extern fn with Unsafe → ok
- `ffi_repr_c.con`: pass #[repr(C)] struct to extern → ok
- `ffi_transmute.con`: transmute u32 to f32 with Unsafe → ok
- `ffi_ptr_deref.con`: dereference raw pointer with Unsafe → ok
- `error_ffi_no_unsafe.con`: call extern fn without Unsafe → error "requires Unsafe capability"
- `error_ffi_bad_type.con`: pass non-C-compatible type to extern → error "not C-compatible"
- `error_ptr_deref_no_unsafe.con`: dereference raw pointer without Unsafe → error
- `error_transmute_size.con`: transmute between types of different sizes → error
- `error_transmute_generic.con`: transmute to generic type → error "cannot transmute to generic type"

---

## Phase 7b: Monomorphized trait dispatch on generics

Trait bounds (`<T: Describe>`) are checked but you cannot call trait methods on generic type variables. This phase adds monomorphized dispatch: `val.describe()` where `val: T` and `T: Describe` compiles to a direct call to the concrete type's implementation at compile time.

### Why this fits the philosophy

- **No hidden control flow.** Monomorphization generates a separate copy of the function for each concrete type. The call `val.describe()` compiles to `Point_describe(val)` — a direct, statically-known function call. No vtable, no indirection, no runtime dispatch.
- **All code paths known at compile time.** The compiler knows exactly which function is called at every instantiation. `grep describe` finds every implementation.
- **No trait objects.** Dynamic dispatch (`dyn Trait`) is explicitly excluded — it violates "all code paths known at compile time" and "no implicit function calls." Concrete uses monomorphization only.

### Syntax

```
trait Describe {
    fn describe(&self) -> Int;
}

struct Point { x: Int, y: Int }

impl Describe for Point {
    fn describe(&self) -> Int {
        return self.x + self.y;
    }
}

// T: Describe means we can call .describe() on values of type T
fn show<T: Describe>(val: &T) -> Int {
    return val.describe();
}

fn main() -> Int {
    let p: Point = Point { x: 10, y: 20 };
    return show::<Point>(&p);  // compiles to show_Point(&p) which calls Point_describe
}
```

### Rules

- Trait method calls on generic type variables are resolved at monomorphization time
- For `<T: Describe>`, calling `val.describe()` where `val: &T` resolves to `ConcreteType_describe(val)` based on the type argument at the call site
- Multiple bounds (`<T: A + B>`) allow calling methods from any bound trait
- Monomorphization generates a specialized function for each concrete type instantiation
- If a function `fn foo<T: Describe>(x: &T)` is called as `foo::<Point>(&p)` and `foo::<Counter>(&c)`, the compiler generates `foo_Point` and `foo_Counter`
- Error if the concrete type at instantiation does not implement the required trait (already implemented in Phase E)

### Implementation

- **Check.lean**: When checking a method call on a type variable `T` that has trait bounds, look up the method in the bound traits. Verify the method signature matches. Return the method's return type. The concrete dispatch is resolved during codegen.
- **Codegen.lean**: During monomorphization, when generating code for a trait method call on a type variable, substitute the concrete type's method name. `val.describe()` where `T = Point` becomes `call @Point_describe(ptr %val)`.

### Tests

- `trait_dispatch_basic.con`: call trait method on generic type variable → ok
- `trait_dispatch_multi.con`: multiple trait bounds, call methods from both → ok
- `trait_dispatch_chain.con`: generic function calls another generic function → ok
- `error_trait_dispatch_missing.con`: call method not in any bound trait → error "no method"

---

## Phase 7c: Heap dereference

Currently `Heap<T>` only supports `->` for struct field access. This phase adds `*heap_ptr` to load the full value from a `Heap<T>`, which is needed for pattern matching on heap-allocated enums and for recursive data structures.

### Why this fits the philosophy

- **Fully explicit.** `*ptr` is visible in the source — you see every heap read.
- **No hidden control flow.** Loading a value from a pointer is a single LLVM `load` instruction.
- **Linear types enforced.** If `T` is linear, `*heap_ptr` moves the value out. The `Heap<T>` wrapper is consumed (must still be freed, but the inner value is now owned separately).

### Syntax

```
enum List {
    Cons { value: Int, next: Heap<List> },
    Nil {}
}

fn sum_list!(head: Heap<List>) -> Int {
    let node: List = *head;  // load value from heap
    free(head);               // free the heap wrapper (inner value already moved out)
    match node {
        List#Cons { value, next } => {
            return value + sum_list(next);
        },
        List#Nil {} => {
            return 0;
        },
    }
}
```

### Rules

- `*heap_ptr` where `heap_ptr: Heap<T>` loads and returns a value of type `T`
- If `T` is `Copy`, the value is copied and the `Heap<T>` remains valid (still must be freed)
- If `T` is linear, the value is moved out. The `Heap<T>` wrapper transitions to a "hollow" state — it must still be freed (to release the memory) but the inner value is now owned by the caller
- `*heap_ptr` does NOT require `Unsafe` — it is safe because `Heap<T>` is always valid (no null, no dangling pointers in safe code)
- This is distinct from `*raw_ptr` on raw pointers (`*mut T`, `*const T`), which DOES require `Unsafe` (Phase 7)

### Implementation

- **Check.lean**: In `checkExpr` for `.deref`, add case: if inner expression has type `.heap t`, return `t`. Mark the heap variable as partially consumed (hollow — must still be freed). Currently `.deref` only handles `.ref` and `.refMut`.
- **Codegen.lean**: In `genExpr` for `.deref`, add case: if inner type is `.heap t`, emit `load` of the inner struct/enum from the heap pointer. For struct types, load the full struct. For enum types, load the tag + payload.

### Tests

- `heap_deref_basic.con`: `*heap_ptr` to get value from `Heap<T>` → ok
- `heap_deref_enum.con`: `*heap_ptr` on `Heap<EnumType>`, then match → ok
- `heap_deref_recursive.con`: recursive linked list via `Heap<List>` with `*` and match → ok
- `error_heap_deref_no_free.con`: deref heap but don't free wrapper → error "was never consumed"

---

## Phase 8: Standard library

Written in Concrete itself (or as compiler builtins where necessary), exercising capabilities, linear types, and allocators.

### Phase 8a: String operations

**Priority: highest** — blocks any text-processing program.

- `string_concat(a: &String, b: &String) -> String` — concatenation, requires `Alloc`
- `string_slice(s: &String, start: Int, end: Int) -> String` — substring, requires `Alloc`
- `string_char_at(s: &String, index: Int) -> Int` — returns char code at index (or -1)
- `string_contains(haystack: &String, needle: &String) -> Bool` — substring search
- `string_split(s: &String, delim: &String) -> HeapArray<String>` — split into parts, requires `Alloc`
- `string_trim(s: &String) -> String` — trim whitespace, requires `Alloc`
- `string_eq(a: &String, b: &String) -> Bool` — string equality comparison
- All take borrows to avoid consuming the original strings (linear ownership preserved)

### Phase 8b: int↔string conversion

**Priority: highest** — blocks any program that formats output or parses input.

- `int_to_string(n: Int) -> String` — requires `Alloc` (allocates the result)
- `string_to_int(s: &String) -> Result<Int, Int>` — returns `Result#Ok` with the parsed value or `Result#Err` with error code
- `bool_to_string(b: Bool) -> String` — requires `Alloc`
- `float_to_string(f: f64) -> String` — requires `Alloc`

### Phase 8c: stdin / Console I/O

**Priority: high** — blocks any interactive program.

- `read_line() -> String` — read a line from stdin, requires `Console` capability
- `print_string(s: &String)` — print a string to stdout, requires `Console`
- `print_char(c: Int)` — print a single character, requires `Console`
- `eprint_string(s: &String)` — print to stderr, requires `Console`

### Phase 8d: Vec<T>

**Priority: high** — blocks any program that needs dynamic-size collections.

- `Vec<T>` wraps `HeapArray<T>` with length tracking and growth
- `Vec.new() -> Vec<T>` — requires `Alloc`
- `Vec.push(&mut self, item: T)` — append, requires `Alloc` (may reallocate)
- `Vec.pop(&mut self) -> Option<T>` — remove last element
- `Vec.get(&self, index: Int) -> Option<&T>` — bounds-checked access
- `Vec.len(&self) -> Int` — current length
- `Vec.capacity(&self) -> Int` — current capacity
- Linear: `Vec<T>` must be consumed (via `destroy` or `free`)
- If `T` is linear, dropping a non-empty `Vec<T>` is an error — must drain first

### Phase 8e: HashMap<K, V>

**Priority: medium** — needed for many real programs, buildable once Vec exists.

- `HashMap<K, V>` — open addressing or separate chaining using `Vec`
- Requires a `Hash` trait: `trait Hash { fn hash(&self) -> Int; }`
- Requires `Eq` as a method (not operator overload — consistent with Concrete philosophy): `fn eq(&K, &K) -> Bool`
- `HashMap.new() -> HashMap<K, V>` — requires `Alloc`
- `HashMap.insert(&mut self, key: K, value: V) -> Option<V>` — returns old value if key existed
- `HashMap.get(&self, key: &K) -> Option<&V>` — lookup
- `HashMap.remove(&mut self, key: &K) -> Option<V>` — remove and return
- `HashMap.len(&self) -> Int`
- Linear: must be consumed. If `V` is linear, must drain before destroy.
- **Philosophy note:** No operator overloading means no `map[key]` syntax. Use `map.get(&key)` and `map.insert(key, value)`. This is explicit and consistent with language invariant #6.

### Phase 8f: Environment and process

**Priority: medium** — needed for CLI tools and system programs.

- `get_env(name: &String) -> Option<String>` — requires `Env` capability
- `set_env(name: &String, value: &String)` — requires `Env` capability
- `get_args() -> HeapArray<String>` — requires `Process` capability, returns command-line arguments
- `exit(code: Int)` — requires `Process` capability, terminates with exit code

### Phase 8g: Networking

**Priority: medium** — needed for servers, HTTP clients, distributed systems.

- TCP socket API gated by `Network` capability
- `tcp_connect(host: &String, port: Int) -> Result<Socket, Int>` — requires `Network`
- `tcp_listen(host: &String, port: Int) -> Result<Listener, Int>` — requires `Network`
- `tcp_accept(listener: &Listener) -> Result<Socket, Int>` — requires `Network`
- `socket_read(sock: &mut Socket, buf: &mut HeapArray<u8>, max: Int) -> Result<Int, Int>` — requires `Network`
- `socket_write(sock: &mut Socket, data: &HeapArray<u8>) -> Result<Int, Int>` — requires `Network`
- `socket_close(sock: Socket)` — consumes the socket (linear)
- `Socket` and `Listener` are linear types — must be explicitly closed

### Phase 8h: Other standard library

- `Option<T>`, `Result<T, E>` — promote to stdlib with methods (Result already exists as built-in; `Option<T>` already implemented as compiler builtin)
- `List<T>` — linked list with `Alloc` capability
- `Arena`, `GeneralPurposeAllocator`, `FixedBufferAllocator` — implementing `Allocator` trait
- `UnsafeCell<T>` — interior mutability, gated by `Unsafe`
- `Math` — pure functions, no capabilities
- `Testing` — test runner utilities
- `Decimal`, `BigInt`, `BigDecimal` — exact arithmetic types (pure)

---

## Phase 9: Kernel formalization in Lean 4

**This phase can start in parallel with any of the above.** The formal model is independent of the surface language implementation — it only needs the language *design* to be stable, not the compiler.

Broken into subphases that each deliver value independently.

### Kernel versioning

The kernel is versioned separately from the surface language. Once the kernel reaches 1.0, it is **frozen** — no new constructs. New surface features must elaborate to existing kernel constructs. If a proposed surface feature cannot be expressed in the kernel, the feature does not ship. This is the key constraint that keeps the verified core tractable.

### Phase 9a: Kernel syntax + type checker (no proofs)

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

### Phase 9b: Linearity proof

Most tractable proof and most novel claim. Essentially a counting argument on the typing derivation.

**Scope:** Primitives, let, application, match, destroy. No closures, no generics.

**Implementation:**
- `Concrete/Kernel/Soundness/Linearity.lean`
- Theorem: `∀ (t : KernelTerm) (τ : KernelType), hasType t τ → linearValuesConsumedOnce t`
- Lean verifies proof at build time

### Phase 9c: Progress + preservation

Standard PL theory proofs for the linear lambda calculus fragment.

- **Progress**: well-typed non-value terms can step
- **Preservation**: stepping preserves types

**Scope:** Primitives, products, sums, conditionals, let, application.

**Implementation:**
- `Concrete/Kernel/Reduction.lean`: small-step operational semantics
- `Concrete/Kernel/Soundness/Progress.lean`
- `Concrete/Kernel/Soundness/Preservation.lean`

### Phase 9d: Effect soundness

Add capability sets to kernel, prove runtime effects ⊆ declared capabilities.

Relatively straightforward once progress/preservation exist — capabilities are an extra tag on function types.

**Implementation:**
- Extend `Kernel/Syntax.lean` with capability sets
- `Concrete/Kernel/Soundness/Effects.lean`

### Phase 9e: Regions and generics

The hardest part. May require restricting kernel relative to surface.

- Region-annotated references, prove references don't escape
- Universal type quantification, prove substitution preserves typing

**Implementation:**
- Extend `Kernel/Syntax.lean` with regions and type variables
- `Concrete/Kernel/Soundness/Regions.lean`
- `Concrete/Kernel/Soundness/Generics.lean`

### Phase 9f: Connect proofs to compiler

Wire the kernel checker into the compilation pipeline so that every compiled program is checked against the proven-sound kernel.

- `Check.lean` becomes an elaborator that produces kernel terms
- Kernel checker runs on elaborated output
- Compilation fails if kernel checker rejects what surface checker accepted
- This is the final "proof artifact" — the binary you ship was checked by a verified type system

---

## Phase 10: Tooling

Parallel with everything above. Start early, grow incrementally.

- Package manager (`Concrete.toml`, dependency resolution)
- Formatter (one canonical format, like `gofmt`)
- Linter
- Test runner (built-in `test` blocks)
- REPL
- Language server (LSP — editor integration)
- Cross-compilation
- WebAssembly target (via MLIR after Phase 11)
- C codegen target (via MLIR after Phase 11)

---

## Phase 11: MLIR backend

Replace direct LLVM IR text emission with MLIR-based compilation pipeline. This gives proper optimization passes, better diagnostics, and a foundation for multiple backends.

### Why

The current codegen emits LLVM IR as text strings — it works but has no optimization (every variable is an `alloca`, no inlining, no constant folding). MLIR provides structured IR construction, dialect-based lowering, and access to LLVM's full optimization pipeline.

### Architecture

```
Current:  Surface AST → Check → Codegen.lean (text emission) → .ll file → clang → binary
Target:   Surface AST → Check → Codegen.lean (MLIR API calls) → MLIR Module → LLVM IR → binary
```

### Phase 11a: Lean-MLIR FFI bindings

Build Lean 4 `@[extern]` bindings to the MLIR C API.

- Wrap core types: `MLIRContext`, `MLIRModule`, `MLIRBlock`, `MLIROperation`, `MLIRType`, `MLIRValue`
- Use [melior](https://github.com/raviqqe/melior) as a design reference for the API surface
- Build system: link against MLIR/LLVM shared libraries via `lakefile.lean`
- New file: `Concrete/MLIR/Bindings.lean`

### Phase 11b: LLVM dialect codegen

Replace `Codegen.lean` text emission with MLIR operation construction.

- Target LLVM dialect directly (1:1 mapping with current textual IR)
- Same semantics, structured construction instead of string concatenation
- New file: `Concrete/MLIR/Codegen.lean` (parallel to existing `Codegen.lean`)
- Validate: all existing tests pass with MLIR backend
- Keep textual backend as fallback during transition
- Compiler flag: `--backend=text` (default initially) vs `--backend=mlir`

### Phase 11c: Optimization passes

Wire up LLVM optimization passes through MLIR's pass manager.

- `mem2reg` — promotes allocas to SSA registers (biggest single win)
- Dead code elimination, constant folding, inlining
- Add compiler flags: `-O0` (default, current behavior), `-O1`, `-O2`
- Benchmark: compare output binary performance textual vs MLIR

### Phase 11d: Custom Concrete dialect (future, optional)

A Concrete-specific MLIR dialect for domain-specific optimizations.

- Linear type annotations in IR for linearity-aware optimization
- Capability annotations for effect-guided dead code elimination
- Lower: Concrete dialect → LLVM dialect
- This is speculative — only pursue if 11a-11c reveal clear benefits

### Tests

- All existing tests must pass with MLIR backend (`--backend=mlir`)
- Binary output must be functionally equivalent (same exit codes, same behavior)
- Performance regression tests for -O2 vs -O0

---

## Phase 12: Concurrency and Runtime

### Phase 12a: Runtime in C

Needed for real-world use. Written in C, called via FFI (Phase 7).

- Green threads (stack allocation, context switching)
- Preemptive scheduler (timer-based via signals)
- Copy-only message passing between threads (the `Copy` marker from Phase 3 determines what can be sent)
- Deterministic replay (record inputs via capability boundaries, replay execution)
- Built-in profiling and tracing (low overhead when disabled, structured output for tooling)

### Phase 12b: Runtime in Concrete

Once the compiler is mature, rewrite the runtime in Concrete using `Unsafe`. If writing the runtime is painful, the language design has a problem.

- Scheduler logic with `Unsafe` for system calls
- Message passing (type-checked at compile time, copy-only)
- Allocator pools for thread stacks
- Keep only assembly stubs in C (~20 lines per architecture for stack switching)

---

## Error Message Conventions

All compiler error messages follow these conventions for consistency:

- **Format:** `"<description>"` — lowercase first letter, no period at end, single quotes around identifiers and types
- **Type names:** Use the surface syntax: `'Int'`, `'Heap<Point>'`, `'fn(Int) -> Bool'`
- **Variable names:** Use the source name: `'x'`, `'my_var'`
- **Function names:** Use the source name: `'foo'`, `'main'`
- **Examples of exact error strings:**
  - Type mismatch: `"type mismatch: expected 'Int', got 'Bool'"`
  - Linearity: `"linear variable 'x' was never consumed"`
  - Linearity: `"linear variable 'x' used after move"`
  - Capability: `"function 'read_file' requires capability 'File' but caller 'process' does not declare it"`
  - Borrow: `"cannot borrow 'x' as mutable because it is already borrowed"`
  - Destroy: `"type 'Point' does not implement Destroy"`
  - Defer: `"variable 'f' is reserved by defer"`
  - Heap: `"cannot access field 'x' on Heap<Point> directly; use p->x or a borrow block"`

When implementing a new phase, follow this format exactly. Tests assert on substrings of error messages (e.g., the test checks that the error contains `"requires capability"`, not the full string), so the exact wording matters but minor variations are tolerable.

---

## Backward Compatibility Per Phase

Each phase must preserve all existing tests. Here is what changes per phase:

| Phase | Existing tests affected? | Migration needed? |
|-------|------------------------|-------------------|
| **1** (Capabilities) | No — Phase 1 adds `with()` syntax but does NOT gate existing functions. Existing pure functions remain pure. Existing `extern fn` calls are NOT gated by Unsafe until Phase 7. | None |
| **2** (Closures) | No — adds new syntax, no existing syntax changes | None |
| **3** (defer/destroy/Copy) | No — adds new syntax, no existing syntax changes. Existing structs default to `isCopy = false` (linear), which is already the behavior. | None |
| **4** (break/continue) | No — adds new keywords, existing loops don't use them | None |
| **5** (Allocator) | No — adds new types and syntax | None |
| **6** (Borrow regions) | No — extends existing borrow checking, adds `borrow` block syntax | None |
| **7** (FFI) | **Yes** — existing `extern fn` calls now require `with(Unsafe)`. | Update affected tests/examples to add `with(Unsafe)` to calling functions |
| **7b** (Trait dispatch) | No — adds monomorphization for generic trait calls | None |
| **7c** (Heap deref) | No — adds `*heap_ptr` syntax | None |
| **8** (Stdlib) | No — adds new builtins and types | None |
| **9** (Kernel) | No — parallel formalization, does not change compiler behavior | None |
| **10** (Tooling) | No — separate tools | None |
| **11** (MLIR) | No — alternative backend, textual backend kept as fallback | None |
| **12** (Concurrency) | No — adds runtime, does not change existing language semantics | None |

---

## Cross-Phase Interaction Rules

These rules govern how features from different phases interact. An LLM implementing Phase N must understand these interactions if the dependent phase is already implemented.

### Closures + Capabilities (Phase 2 + Phase 1)
- A closure inherits the capability context of its defining scope. If the closure body calls `with(File)` functions, the closure's type carries `with(File)`.
- A closure assigned to a variable or passed as an argument has a `Ty.fn_` type with a concrete `capSet`. The caller must have those capabilities.
- Closures cannot "upgrade" capabilities — a closure in a pure function cannot have `with(File)` even if the closure declares it (the containing function would need `File` too).

### Closures + Allocators (Phase 2 + Phase 5)
- A closure inside a `with(Alloc)` function can call `with(Alloc)` functions — it captures the hidden allocator parameter like any other capture.
- The closure's type must include `Alloc` in its `capSet`.
- If the closure escapes, the captured allocator must still be valid when the closure runs — this is the programmer's responsibility (no compile-time tracking of allocator lifetime across escaping closures).

### Defer + Closures (Phase 3 + Phase 2)
- `defer my_closure();` is valid — it schedules a closure call at scope exit.
- If the closure is linear (must be called exactly once), `defer` guarantees it's called at scope exit — satisfying the linearity requirement.
- Exception: `abort()` skips deferred calls, so a linear closure may not be consumed on the abort path. This is acceptable per Invariant 14 (abort is outside the semantic model).

### Defer + Break (Phase 3 + Phase 4)
- When `break` exits a loop, all deferred actions from the current iteration's scopes execute before the loop exits.
- When `continue` skips to the next iteration, all deferred actions from the current iteration's scopes execute before the next iteration starts.
- `break` and `continue` inside a `defer` body are forbidden.

### Heap<T> + Borrow Regions (Phase 5 + Phase 6)
- `borrow p as pr in R { ... }` on `Heap<T>` uses the same AST node as borrowing stack values (`Stmt.borrowIn`).
- In codegen, borrowing a stack value takes `&alloca`; borrowing `Heap<T>` loads the inner pointer from the Heap wrapper.
- The region `R` governs the reference lifetime identically for stack and heap borrows.

### Allocator + Closures (Phase 5 + Phase 2)
- When a closure captures an allocator parameter and later calls `alloc()`, it uses the captured allocator.
- If the call site binds a different allocator (`closure_call() with(Alloc = other)`), the explicit binding takes precedence.

---

## Research / Open Questions

These do not block any phase above:

- **Effect handlers**: full algebraic effects for testing/sandboxing (mock capabilities in tests). Example: `handle File in f() { open(path) => resume(MockFile.new(path)) }`
- **Concurrency model**: structured concurrency, actors, deterministic parallelism — must preserve linearity and effect tracking
- **Macros**: if added, must be hygienic, phase-separated, and capability-tracked. No macros is also a valid final answer.
- **Variance**: covariance/contravariance for generic types with linearity
- **Module functors**: module-level capability restrictions, separate compilation units
- **Trait objects / dynamic dispatch**: permanently excluded. All dispatch is static (monomorphization) or explicitly indirect (closures, struct of closures). See [research/no-trait-objects.md](research/no-trait-objects.md).

---

## Summary

| Phase | Feature | Depends on | Parallel? |
|-------|---------|------------|-----------|
| **1** | Capabilities + cap polymorphism | — | — |
| **2** | Closures | 1 (Ty.fn) | — |
| **3** | `defer` + `destroy` + `Copy` + `abort` | 1 | — |
| **4** | `break` / `continue` / labeled loops | — | Yes, with 1-3 |
| **5** | Allocator system | 1, 3 | — |
| **6** | Borrow regions | — | Yes, with 1-5 |
| **7** | FFI + C interop | 1 (Unsafe cap) | Yes, with 2-6 |
| **7b** | Monomorphized trait dispatch | 7 (traits) | — |
| **7c** | Heap dereference | 5 (Heap<T>) | — |
| **8a** | String operations | 1-6 | — |
| **8b** | int↔string conversion | 8a | — |
| **8c** | stdin / Console I/O | 1 (Console cap) | — |
| **8d** | Vec<T> | 5 (HeapArray) | — |
| **8e** | HashMap<K, V> | 8d (Vec) | — |
| **8f** | Environment / process | 1 (Env, Process caps) | — |
| **8g** | Networking | 1 (Network cap), 7 (FFI) | — |
| **8h** | Other stdlib | 8a-8g | — |
| **9a** | Kernel IR + checker | — | Yes, anytime |
| **9b** | Linearity proof | 9a | Yes, ongoing |
| **9c** | Progress + preservation | 9b | Yes, ongoing |
| **9d** | Effect soundness | 9c | Yes, ongoing |
| **9e** | Regions + generics | 9d | Yes, ongoing |
| **9f** | Connect proofs to compiler | 6, 9e | — |
| **10** | Tooling | — | Yes, ongoing |
| **11a** | MLIR FFI bindings | — | Yes, anytime |
| **11b** | MLIR LLVM dialect codegen | 11a | — |
| **11c** | MLIR optimization passes | 11b | — |
| **12a** | Runtime in C | 7 (FFI) | — |
| **12b** | Runtime in Concrete | 8, 12a | — |

**Critical path for language features:** 1 → 3 → 5 (capabilities → resource management → allocators). Phases 4, 6 are independent and can be done in parallel. Phase 2 depends on Phase 1 for `Ty.fn`.

**Critical path for production use:** 1-7 → 8 → 12a (language features → stdlib → runtime).

**MLIR** (Phase 11) is independent of language features — can start anytime, biggest win is after language features stabilize.

**Formalization** (Phase 9) is independent of the compiler — can start anytime, needs only the language design (not the implementation) to be stable. Kernel is frozen at 1.0.
