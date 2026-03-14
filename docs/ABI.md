# ABI and FFI Maturity Statement

This document describes Concrete's current ABI stability, FFI safety model, platform assumptions, and what is intentionally left unstable.

## Stability Summary

| Area | Status | Stable? |
|------|--------|---------|
| FFI-safe scalar types (i8–i64, u8–u64, f32, f64, bool) | Implemented, tested | **Yes** |
| `#[repr(C)]` struct layout | Implemented, tested | **Yes** — follows C struct layout rules |
| `#[repr(packed)]` struct layout | Implemented, tested | **Yes** — no padding between fields |
| `#[repr(align(N)]` minimum alignment | Implemented, tested | **Yes** — power-of-two enforced |
| `extern fn` declarations | Implemented, tested | **Yes** — requires `Unsafe` capability |
| `trusted extern fn` declarations | Implemented, tested | **Yes** — no capability required |
| FFI safety validation | Implemented, tested | **Yes** — CoreCheck enforces at compile time |
| Non-repr struct layout | Implemented | **No** — compiler may change field ordering or padding |
| Enum representation | Implemented | **No** — i32 tag + payload is an implementation detail |
| Pass-by-pointer convention | Implemented | **No** — which types are passed by pointer may change |
| Calling convention | LLVM default | **No** — no explicit calling convention annotation |
| String/Vec/HashMap internal layout | Implemented | **No** — opaque to FFI; sizes may change |
| Linker symbol naming | Implemented | **No** — mangling scheme is not specified |

## Platform Assumptions

Concrete currently targets **64-bit platforms only**. The following sizes are hardcoded in `Concrete/Layout.lean`:

| Type | Size (bytes) | Alignment (bytes) | Notes |
|------|-------------|-------------------|-------|
| `Int` / `Uint` | 8 | 8 | Always 64-bit |
| `i32` / `u32` | 4 | 4 | |
| `i16` / `u16` | 2 | 2 | |
| `i8` / `u8` | 1 | 1 | |
| `f64` | 8 | 8 | |
| `f32` | 4 | 4 | |
| `Bool` | 1 | 1 | LLVM `i1`, stored as `i8` in aggregates |
| `Char` | 1 | 1 | ASCII byte |
| `()` (unit) | 0 | 1 | Zero-sized |
| Pointers (`&T`, `*mut T`, etc.) | 8 | 8 | 64-bit pointers |
| `String` | 24 | 8 | `ptr + i64 len + i64 cap` |
| `Vec<T>` | 24 | 8 | `ptr + i64 len + i64 cap` |
| `HashMap<K,V>` | 40 | 8 | 5 × 8-byte fields |
| Enum tag | 4 | 4 | Always `i32` discriminant |

**No 32-bit support.** There is no conditional compilation, no target triple awareness, and no platform-dependent layout logic. All layout decisions are compile-time constants in Lean.

### Supported targets

| Target | Status | Notes |
|--------|--------|-------|
| x86_64-apple-darwin | **Primary** | Development and CI target |
| aarch64-apple-darwin | **Primary** | Apple Silicon, development target |
| x86_64-linux-gnu | Expected to work | Same ABI assumptions; not CI-tested |
| aarch64-linux-gnu | Expected to work | Same ABI assumptions; not CI-tested |
| 32-bit targets | **Not supported** | Pointer size hardcoded to 8 bytes |
| Windows | **Not tested** | May work with MSVC ABI differences in struct layout |

## FFI Safety Model

### What is FFI-safe

A type is FFI-safe (can appear in `extern fn` signatures and `#[repr(C)]` struct fields) if it is one of:

- Integer types: `i8`, `i16`, `i32`, `Int` (i64), `u8`, `u16`, `u32`, `Uint` (u64)
- Float types: `f32`, `f64`
- `Bool`, `Char`, `()` (unit)
- Raw pointers: `*mut T`, `*const T`
- `#[repr(C)]` structs (recursively: all fields must also be FFI-safe)

### What is NOT FFI-safe

- `String`, `Vec<T>`, `HashMap<K,V>` — opaque managed types
- References: `&T`, `&mut T` — not raw pointers
- Enums — even with all-FFI-safe variant fields
- Non-`#[repr(C)]` structs
- Generic types (type parameters)
- `Heap<T>`, `HeapArray<T>` — managed heap types

### Validation

FFI safety is enforced at compile time by `CoreCheck`:

- `extern fn` parameters and return types must be FFI-safe
- `#[repr(C)]` struct fields must be FFI-safe
- `#[repr(C)]` structs cannot have type parameters (no generic repr(C))
- `#[repr(packed)]` and `#[repr(align(N))]` cannot be combined
- `#[repr(align(N))]` requires `N` to be a power of two
- `#[repr(C)]` cannot be applied to enums

Violations are compile errors — there is no way to bypass FFI safety without modifying the compiler.

### Capability requirements

- `extern fn` calls require the `Unsafe` capability
- `trusted extern fn` calls require no capability (the compiler author vouches for safety)
- Regular `fn` declared inside a `trusted impl` block inherits the trusted boundary

## Struct Layout Rules

### `#[repr(C)]` structs

Follow the C ABI: fields are laid out in declaration order with natural alignment padding. Struct size is rounded up to the struct's alignment.

Example: `#[repr(C)] struct Packet { tag: i8, payload: i32, flags: i16 }`
- `tag` at offset 0, size 1
- 3 bytes padding (align `payload` to 4)
- `payload` at offset 4, size 4
- `flags` at offset 8, size 2
- 2 bytes tail padding (align struct to 4)
- Total size: 12, alignment: 4

### `#[repr(packed)]` structs

No padding between fields. Alignment is 1. Fields at consecutive byte offsets.

Same example packed: size 7 (1 + 4 + 2), alignment 1.

### `#[repr(align(N))]` structs

Minimum alignment of `N` bytes (must be power of two). Combines with natural field layout — `align` increases but never decreases alignment.

### Non-repr structs

Compiler-controlled layout. Currently follows declaration order with natural alignment, but this is **not guaranteed** and may change.

## Enum Layout

Enums use a tagged-union representation:

```
{ i32 tag, [payload_bytes x i8] payload }
```

- Tag is always `i32` (4 bytes) at offset 0
- Payload starts at `alignUp(4, max_field_alignment)`
- Payload size is the maximum variant payload size
- Total size is `alignUp(tag_offset + payload_size, max(4, payload_align))`

This representation is **not stable** and should not be relied upon across FFI boundaries. Enums are not FFI-safe.

## Pass-by-Pointer Convention

Aggregate types (structs, enums, arrays, `String`, `Vec`, `HashMap`) are passed by pointer in function calls. The caller allocates stack space, stores the value, and passes a pointer. Scalar types (integers, floats, bool, char) are passed by value.

This convention applies to internal Concrete function calls and `extern fn` declarations. It is **not stable** — the set of types passed by pointer may change.

## What We Intentionally Do Not Promise

1. **ABI compatibility across compiler versions.** Recompile everything when the compiler changes.
2. **Stable symbol names.** Function name mangling is not specified.
3. **Non-repr struct layout.** Only `#[repr(C)]` and `#[repr(packed)]` have guaranteed layout.
4. **Enum representation.** Tag size, payload offset, and discriminant values may change.
5. **32-bit support.** Not planned for the near term.
6. **Cross-language enum interop.** Enums are not FFI-safe.
7. **Stable pass-by-pointer set.** Which types are passed by pointer is an optimization decision.

## Layout Verification

The layout module (`Concrete/Layout.lean`) is the single source of truth for all type sizes, alignments, field offsets, pass-by-pointer decisions, and LLVM type mappings. Both `Lower.lean` and `EmitSSA.lean` delegate to `Layout` rather than maintaining their own layout logic.

Layout properties are verified by:

- **Compile-time computation:** All layout functions are pure Lean functions evaluated at compile time. Sizes and offsets are computed deterministically from type definitions.
- **FFI safety tests:** 17 test files in `lean_tests/` cover `repr(C)`, `repr(packed)`, `repr(align)`, extern functions, and error cases for all safety violations.
- **Report assertions:** `--report layout` produces human-readable layout information that is regression-tested.

### Cross-platform verification matrix

| Property | x86_64 | aarch64 | Verified by |
|----------|--------|---------|-------------|
| `sizeof(Int)` = 8 | Yes | Yes | Layout.lean `tySize .int = 8` |
| `sizeof(i32)` = 4 | Yes | Yes | Layout.lean `tySize .i32 = 4` |
| `sizeof(ptr)` = 8 | Yes | Yes | Layout.lean `tySize (.ref _) = 8` |
| `sizeof(String)` = 24 | Yes | Yes | Layout.lean `Builtin.stringSize = 24` |
| `sizeof(Vec)` = 24 | Yes | Yes | Layout.lean `Builtin.vecSize = 24` |
| `alignof(i64)` = 8 | Yes | Yes | Layout.lean `tyAlign .int = 8` |
| `alignof(i32)` = 4 | Yes | Yes | Layout.lean `tyAlign .i32 = 4` |
| Enum tag = i32 | Yes | Yes | Layout.lean `alignUp 4 payloadAlign` |
| repr(C) field order | Yes | Yes | `fieldOffset` iterates in declaration order |
| repr(packed) no padding | Yes | Yes | `fieldOffset` sums sizes without alignment |
| Pass-by-ptr for structs | Yes | Yes | `isPassByPtr` returns true for named types |

These properties are identical on x86_64 and aarch64 because all layout decisions are compile-time constants with no platform-dependent branches. The verification matrix confirms that both primary targets produce identical layout.
