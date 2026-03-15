# Execution Model

Status: reference

This document defines Concrete's execution model: how programs start, allocate, fail, and interact with the host environment. It covers the hosted/freestanding distinction, the runtime boundary, and the memory/allocation strategy.

For the value and ownership model, see [VALUE_MODEL.md](VALUE_MODEL.md).
For ABI and layout details, see [ABI_LAYOUT.md](ABI_LAYOUT.md) and [ABI.md](ABI.md).
For stdlib module inventory, see [STDLIB.md](STDLIB.md).

---

## Hosted vs Freestanding

Concrete currently targets a **hosted** environment only. All programs assume:

- a POSIX-like OS with process model, file descriptors, and virtual memory
- libc is available and linked (malloc, free, printf, read, write, etc.)
- 64-bit address space (pointer size = 8 bytes, hardcoded in Layout)
- `main` is the entry point, called by the OS/libc startup code

### What "hosted" means concretely

The compiler generates a `main` function that calls the user's `main` (renamed to `user_main` internally). The generated `main`:

1. Calls `user_main`
2. Optionally prints the return value (for scalar types: i32/i64 → `printf "%lld"`, bool → `"true"`/`"false"`)
3. Returns `0` to the OS

There is no Concrete runtime initialization. No global constructors, no GC setup, no thread-local storage initialization, no allocator setup. The program starts in `main`, calls libc functions directly, and exits when `main` returns.

### What "freestanding" would mean (future)

A future freestanding mode would remove the assumption of libc and OS facilities. This is not implemented but the direction is documented here so the hosted boundary remains explicit.

Freestanding would mean:

- no libc-backed assumptions by default
- no ambient runtime (no implicit malloc/free)
- allocation only if explicitly provided
- explicit target contract for startup, failure, and memory
- stdlib limited to a core subset (Option, Result, math, ptr, slice, mem)

The hosted/freestanding split is a later milestone (see `research/no-std-freestanding.md`). The current priority is making the hosted boundary explicit so the split is straightforward when needed.

### Stdlib layer classification

The stdlib naturally divides into layers by host dependency:

| Layer | Modules | Host assumption |
|-------|---------|-----------------|
| **Core** | `option`, `result`, `mem`, `slice`, `math`, `fmt`, `hash`, `parse` | None — pure computation, no libc |
| **Alloc** | `alloc`, `vec`, `string`, `bytes`, `text`, `deque`, `heap`, `ordered_map`, `ordered_set`, `bitset`, `map`, `set` | malloc/realloc/free only |
| **Hosted** | `io`, `fs`, `env`, `process`, `net`, `time`, `rand` | Full POSIX libc |

Today these are all compiled together. The classification exists to guide future separation and to make host dependencies auditable now.

---

## Runtime Boundary

### What constitutes the "runtime"

Concrete does not have a runtime in the traditional sense (no GC, no green threads, no event loop). The runtime boundary is the set of external symbols and conventions that a compiled Concrete program depends on at link time.

### Startup

1. OS/libc calls `main(argc, argv)` (Concrete ignores argc/argv today)
2. `main` calls `user_main` (the user's `fn main()`)
3. No global initialization, no module init functions, no static constructors

### Shutdown

1. `user_main` returns
2. `main` optionally prints the return value
3. `main` returns `0`
4. OS reclaims process resources

There is no cleanup hook, no `atexit` registration, no destructor ordering. Linear ownership and `defer` handle resource cleanup within function scope. When the process exits, the OS reclaims everything.

### Failure

Concrete has no panic/unwind mechanism. Failure modes:

| Failure | What happens | Who handles it |
|---------|-------------|----------------|
| Explicit error return | `Result<T, E>` propagated via `?` | User code |
| `exit(code)` | libc `exit()` terminates process | OS |
| Out-of-memory | `malloc` returns null, program proceeds with null pointer | Undefined (see allocation section) |
| Null pointer dereference | Hardware trap (SIGSEGV) | OS kills process |
| Integer overflow | Wraps (LLVM default for `add`/`sub`/`mul`) | Silent — no trap |
| Array out-of-bounds | Checked accessors return `Option`; unchecked is UB | User code / UB |
| Stack overflow | OS stack guard page, SIGSEGV | OS kills process |

There is no structured panic. No stack unwinding. No catch mechanism. This is intentional — it keeps the execution model simple and compatible with freestanding targets in the future. Error handling is explicit through return types.

### External symbol dependencies

Every compiled Concrete program links against these categories of external symbols:

**Always required** (emitted by the compiler):

| Symbol | Source | Used by |
|--------|--------|---------|
| `malloc` | libc | String builtins, Vec builtins, user `Alloc` code |
| `free` | libc | String/Vec deallocation, `drop_string` |
| `realloc` | libc | Vec growth |
| `memcpy` / `llvm.memcpy.p0.p0.i64` | libc / LLVM intrinsic | Vec operations, string operations |
| `memset` | libc | Vec pop (Option zero-init) |
| `memcmp` | libc | `string_eq`, `string_contains` |
| `printf` | libc | Main wrapper (result printing) |
| `snprintf` | libc | `int_to_string`, `float_to_string` |
| `strtol` | libc | `string_to_int` |
| `llvm.smax.i64` / `llvm.smin.i64` | LLVM intrinsics | `string_slice` |
| `abort` | libc | Declared but not currently called |

**Conditionally required** (from user stdlib imports):

| Symbol | Source | Used by stdlib module |
|--------|--------|-----------------------|
| `fopen`, `fclose`, `fread`, `fwrite`, `fseek`, `ftell` | libc | `std.io`, `std.fs` |
| `read`, `write` | libc | `std.io` |
| `getenv`, `setenv`, `unsetenv` | libc | `std.env` |
| `fork`, `execvp`, `waitpid`, `kill`, `getpid` | libc | `std.process` |
| `socket`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `close` | libc | `std.net` |
| `htons`, `htonl`, `inet_pton`, `setsockopt` | libc | `std.net` |
| `clock_gettime`, `nanosleep`, `time` | libc | `std.time` |
| `rand`, `srand` | libc | `std.rand` |
| `exit`, `raise` | libc | `std.libc` |

### Test mode

In test mode (`concrete file.con --test`), the compiler generates a test runner `main` instead of the normal main wrapper. The test runner:

1. Calls each `#[test]` function in order
2. Prints `PASS: <name>` or `FAIL: <name>` for each
3. Returns `0` if all pass, `1` if any fail

---

## Memory and Allocation Strategy

### Current model: libc malloc

All heap allocation goes through libc `malloc`/`realloc`/`free`. There is no custom allocator, no arena, no bump allocator, no GC. The compiler emits direct calls to these functions in:

- **String builtins** (`EmitBuiltins.lean`): `string_concat`, `string_slice`, `string_trim`, `int_to_string`, `float_to_string`, `bool_to_string` all call `malloc` for new buffers. `drop_string` and `string_concat` call `free`.
- **Vec builtins** (`EmitBuiltins.lean`): `vec_new_{size}` calls `malloc` with initial capacity × element size. `vec_push_{size}` calls `realloc` when full (2× growth). `vec_free` calls `free`.
- **User code** via `std.alloc`: `heap_new<T>()`, `grow<T>()`, `dealloc<T>()` wrap malloc/realloc/free with `trusted` + `Alloc` capability.

### Allocation is capability-tracked

The `Alloc` capability marks functions that allocate. This is enforced by `CoreCheck` — a function calling `heap_new`, `Vec::new`, or `String::concat` must declare `with(Alloc)` or be called by a function that does. This makes allocation visible in:

- `--report caps`: shows which functions require `Alloc` and why
- `--report alloc`: shows allocation/cleanup patterns and warns about functions that allocate without cleanup

### Allocation failure

**Abort on OOM.** All allocation paths check for null returns from `malloc`/`realloc` and abort the process immediately if allocation fails. This matches Rust's default allocator behavior and is appropriate for hosted programs.

The abort-on-OOM guarantee covers two layers:

1. **Compiler builtins** (`EmitBuiltins.lean`): All 11 `malloc`/`realloc` call sites in string and vec builtins pipe through `__concrete_check_oom`, a compiler-emitted helper that null-checks and calls `abort()`.
2. **Stdlib wrappers** (`std/src/alloc.con`): `heap_new<T>()` and `grow<T>()` null-check their `malloc`/`realloc` results and call `abort()` on failure.

This means any allocation reachable through the standard API is OOM-safe. Direct `extern fn malloc` calls from user `trusted` code are not checked — the user is responsible for null-checking in that case.

Future directions beyond abort-on-OOM:

1. **Propagate OOM as error**: builtins return `Result<T, AllocError>`. Correct but invasive — changes the signature of every allocating operation.
2. **Allocator trait**: user-provided allocator with configurable failure behavior. Most flexible but highest complexity.

### Deallocation model

Concrete uses linear ownership + `defer` for deterministic deallocation:

- **Linear types**: structs and enums must be consumed exactly once. The compiler enforces this at check time.
- **`defer`**: schedules cleanup at scope exit. The standard pattern is `defer vec.free();` or `defer string.drop();`.
- **`Destroy` trait**: types implementing `Destroy` get their `destroy()` method called when they go out of scope (not yet automatic — users must call it or use `defer`).

There is no automatic destructor insertion (RAII). Resource cleanup is explicit. This is intentional — it keeps the execution model transparent and avoids hidden control flow.

### Stack allocation

Local variables and temporaries are stack-allocated via LLVM `alloca`. The compiler uses entry-block allocas for:

- aggregate variables that are modified across control flow (promoted from phi nodes to stable storage)
- temporary structs for pass-by-pointer ABI
- local variables that need an address (e.g., `&mut` borrows)

Stack size is not bounded or checked by the compiler. Stack overflow is caught by the OS guard page.

### Memory layout

All memory layout decisions are centralized in `Concrete/Layout.lean`:

- Type sizes and alignments follow platform conventions (i8=1, i16=2, i32=4, i64=8, f64=8, ptr=8, bool=1)
- Structs use C-like field layout with natural alignment padding (unless `#[repr(packed)]`)
- Enums use tag + padded payload (i32 tag, payload aligned to max variant alignment)
- `#[repr(C)]` provides C-compatible layout for FFI structs
- `#[repr(align(N))]` sets minimum alignment

See [ABI_LAYOUT.md](ABI_LAYOUT.md) for full details.

### Future directions

| Direction | Description | Phase |
|-----------|-------------|-------|
| Abort on OOM | Check malloc returns in builtins, abort on null | E (done) |
| Bounded allocation profile | Compile-time cap on allocation count/size for high-integrity use | E/F |
| Allocator parameter | User-provided allocator for collections (Zig-style) | G+ |
| No-alloc mode | Compile without malloc/free for freestanding targets | G+ |
| Arena/bump allocators | Stdlib allocator implementations beyond libc malloc | G+ |

---

## FFI and Runtime Ownership Boundary

This section documents how ownership, capabilities, and resource tracking interact with the FFI boundary. For FFI type rules and safety checks, see [FFI.md](FFI.md). For ABI and calling convention details, see [ABI.md](ABI.md).

### Capability model at the FFI boundary

Extern functions participate in the capability system:

| Declaration | Capability requirement | Use case |
|------------|----------------------|----------|
| `extern fn foo(...)` | Caller must have `Unsafe` | Raw foreign calls |
| `trusted extern fn bar(...)` | No capability required | Audited pure functions (math, abs) |
| `trusted fn wrap(...) with(Alloc, Unsafe)` calling extern fn | Caller must have `Alloc` and `Unsafe` | Wrappers that audit raw pointer use but still expose `Unsafe` |

The standard pattern is a three-layer stack:

1. **libc declaration** (`std.libc`): raw `extern fn malloc(size: u64) -> *mut u8`
2. **trusted wrapper** (`std.alloc`): `trusted fn heap_new<T>() with(Alloc, Unsafe) -> *mut T` — calls malloc, null-checks, casts the pointer. The `trusted` marker means raw pointer operations inside are audited, but `Unsafe` is still visible to callers.
3. **user code**: calls `heap_new<T>()` with both `Alloc` and `Unsafe` capabilities

Today `trusted` allows raw pointer operations without additional checks inside the function body, but it does **not** hide capabilities from callers. The declared `with(...)` set is the caller-visible contract. A future capability-hiding mechanism (where a trusted wrapper could absorb `Unsafe` and expose only `Alloc`) is not yet implemented.

### Ownership across FFI calls

The linearity checker tracks ownership at the Concrete level:

- **By-value arguments to extern fn consume the variable.** If you pass a linear type by value, it is marked consumed. The compiler assumes the foreign function took ownership.
- **By-reference arguments (`&T`, `&mut T`) borrow without consuming.** The original variable remains usable after the call.
- **Raw pointers (`*mut T`, `*const T`) are Copy.** No ownership tracking. The compiler cannot see what C code does with a pointer.

### What the compiler cannot track

Once data crosses the FFI boundary, the compiler has no visibility:

| Scenario | Compiler behavior | Risk |
|----------|------------------|------|
| Passing `*mut T` to extern fn | No tracking (Copy type) | C code may free, leak, or corrupt |
| Extern fn returns `*mut T` | No obligation to free | Caller may leak if they drop the pointer |
| Trusted code extracts `.ptr` from `Vec`/`String` | `Vec`/`String` is consumed, but buffer is now a raw pointer | Double-free if both Concrete and C free it |
| Extern fn writes beyond buffer bounds | No defense | Buffer overflow / UB |

These gaps are intentional — they match the cost model of C FFI in Rust, Zig, and other systems languages. The mitigation is:

1. **`trusted fn` wrappers** that present a safe interface
2. **Capability tracking** that makes FFI usage visible in reports
3. **`--report unsafe`** that shows which trusted functions wrap which extern calls

### What is NOT allowed at the FFI boundary

The compiler enforces that only FFI-safe types appear in `extern fn` signatures:

- **Allowed**: integers, floats, bool, char, `()`, raw pointers (`*mut T`, `*const T`), `#[repr(C)]` structs
- **Rejected at compile time**: `String`, `Vec<T>`, `HashMap<K,V>`, non-repr(C) structs, enums, arrays, references

This prevents accidentally passing a managed Concrete type to C code that doesn't understand its layout.

### Calling convention

`#[repr(C)]` structs in `extern fn` signatures are passed by value following the platform C ABI. LLVM handles the register/stack lowering for the target architecture. Internal Concrete function calls use pointer-based passing for all aggregates.

For full calling convention details, see [ABI.md](ABI.md).

### Known gaps and future directions

| Gap | Description | Planned mitigation |
|-----|-------------|-------------------|
| Raw pointer leaks | `*mut T` from extern fn can be dropped without freeing | Linear pointer wrappers or `must_use` annotation |
| No verified FFI envelopes | Extern fn contracts are trust-based, not mechanically checked | Verified FFI envelopes (Phase E item 9) |
| No cross-language ownership protocol | No way to express "C takes ownership" vs "C borrows" | Ownership annotations on extern fn parameters |

---

## Summary

| Aspect | Current state | Future direction |
|--------|--------------|------------------|
| Environment | Hosted only (POSIX + libc) | Freestanding mode later |
| Startup | `main` → `user_main`, no init | No change needed |
| Shutdown | Return from `main`, OS cleanup | No change needed |
| Failure | No panic, no unwind, explicit errors, abort-on-OOM | Allocator traits |
| Allocation | libc malloc/realloc/free, abort-on-OOM | Allocator traits, arenas |
| Deallocation | Linear ownership + explicit `defer` | Automatic `Destroy` insertion possible |
| Stack | Unbounded, OS guard page | Bounded stack analysis for high-integrity |
| Capability tracking | `Alloc` tracks allocation, `Unsafe` tracks pointers | Authority budgets, sandboxing |
| FFI ownership | Linear types consumed by-value; raw pointers untracked | Verified FFI envelopes, ownership annotations |
| FFI calling convention | `#[repr(C)]` structs passed by value for extern fn | Already implemented |
