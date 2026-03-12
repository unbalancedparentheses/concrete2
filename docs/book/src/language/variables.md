# Variables

Variables are introduced with `let`:

```rust
let x: i32 = 2;
```

Mutable variables use `mut`:

```rust
let mut x: i32 = 2;
x = x + 1;
```

## Current Notes

Today, Concrete still expects explicit types in many places. This matches the language's general bias toward explicitness.

That explicitness is useful for:

- compiler clarity
- diagnostics
- auditability
- avoiding hidden inference-driven behavior while the language is still maturing

## Ownership And Use

Variable use is also affected by Concrete's ownership model:

- ordinary copyable values can be reused normally
- linear values must be consumed exactly once
- borrows and mutable borrows make aliasing and mutation explicit

So variables are not only names bound to values; they participate directly in the ownership/resource model.
