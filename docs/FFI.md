# FFI and Unsafe Boundary

Status: stable reference

This document describes the current foreign-function interface boundary and the role of `Unsafe` in Concrete.

For layout and representation rules, see [ABI_LAYOUT.md](ABI_LAYOUT.md). For active priorities, see [../ROADMAP.md](../ROADMAP.md).

## Core Principles

Concrete keeps the foreign boundary explicit:

- FFI functions are declared with `extern fn`
- raw pointers are explicit types (`*const T`, `*mut T`)
- unsafe operations are gated by `with(Unsafe)`
- safe code does not silently cross into foreign or pointer-sensitive behavior

## Extern Functions

Extern declarations are the language-level entry point to foreign code:

```con
extern fn puts(ptr: *const u8) -> i32;
```

Current rules:

- `extern fn` has no Concrete body
- extern calls require `Unsafe` by default
- extern parameter and return types must be FFI-safe

### Trusted Extern Functions

A `trusted extern fn` is an audited foreign binding that callers can use without `with(Unsafe)`:

```con
trusted extern fn sqrt(x: Float64) -> Float64;
```

This is the right tool for well-known, pure libc functions (math, `abs`, etc.) where requiring `Unsafe` at every call site adds noise without safety value.

Rules:

- `trusted extern fn` uses the existing `trusted` keyword — no new syntax
- callers do not need `with(Unsafe)`
- parameter and return types must still be FFI-safe
- the declaration itself is the audit boundary — it asserts the foreign function is safe to call with any valid arguments of the declared types
- `--report unsafe` shows trusted extern declarations in a separate "Trusted extern functions" section

Keep the category narrow. `trusted extern fn` is for pure, well-understood foreign functions — not a general "safe FFI" escape hatch. If a foreign function has side effects, mutates global state, or can crash on valid inputs, it should remain a regular `extern fn` under `with(Unsafe)`.

## FFI-Safe Types

FFI-safe types currently include:

- integer types
- float types
- `Bool`
- `Char`
- `()`
- raw pointers (`*const T`, `*mut T`)
- `#[repr(C)]` structs

The implementation authority for this check is `Layout.isFFISafe`.

## Unsafe Boundary

Concrete currently requires `Unsafe` for:

- calling `extern fn` (but not `trusted extern fn`)
- dereferencing raw pointers
- assigning through raw pointers
- pointer-involving casts, except reference-to-pointer casts

Safe exception:

- `&x as *const T`
- `&mut x as *mut T`

These preserve compiler-known provenance and do not invent an address.

## Intentional Design Rule

The goal is not to hide low-level operations behind “safe-feeling” library APIs.

The audit story should stay simple:

- `grep with(Unsafe)` finds the boundary
- extern declarations are visible in signatures
- raw pointers stay explicit in types

Concrete is aiming for an unsafe boundary that is:

- operationally obvious
- explicitly gated
- easier to audit than a broad ambient low-level model

## Trusted Split

Concrete now has the three-way split described in the research notes:

- **capabilities** (`with(Alloc)`, `with(File)`, etc.) = semantic effects visible to callers
- **`trusted`** = containment of internal pointer-level implementation techniques behind a safe API
- **`with(Unsafe)`** = authority to cross foreign boundaries (FFI, transmute) — always explicit, even inside trusted code

That means:

- `trusted` does **not** suppress ordinary capabilities
- `trusted fn`/`trusted impl` does **not** permit `extern fn` calls without `with(Unsafe)`
- `trusted extern fn` is a separate, narrower mechanism: it marks a specific foreign binding as safe to call, rather than granting blanket trust to a block of code
- builtin and stdlib internals are aligned to this same model instead of relying on silent exemptions

## Future Refinement

This doc should expand if the FFI surface grows substantially, for example:

- better compiler reports for *why* `Unsafe` is required
- stronger stdlib wrapper patterns around unsafe operations
- more explicit calling-convention rules
- ABI notes for additional targets
- low-level FFI helper patterns in the stdlib
- continued hardening of builtin and stdlib internals around the implemented `trusted` boundary

For the exploratory direction behind those ideas, see [../research/unsafe-structure.md](../research/unsafe-structure.md) and [../research/trusted-boundary.md](../research/trusted-boundary.md).
