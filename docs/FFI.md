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
- extern calls require `Unsafe`
- extern parameter and return types must be FFI-safe

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

- calling `extern fn`
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

## Future Refinement

This doc should expand if the FFI surface grows substantially, for example:

- better compiler reports for *why* `Unsafe` is required
- stronger stdlib wrapper patterns around unsafe operations
- more explicit calling-convention rules
- ABI notes for additional targets
- low-level FFI helper patterns in the stdlib

For the exploratory direction behind those ideas, see [../research/unsafe-structure.md](../research/unsafe-structure.md).
