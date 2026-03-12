# Structs

Structs define product types with named fields:

```rust
struct Point {
    x: i32,
    y: i32,
}
```

Structs can be generic:

```rust
struct GenericStruct<T> {
    x: T,
}
```

You can associate methods with a type using `impl`:

```rust
impl Point {
    pub fn new(x: i32, y: i32) -> Point {
        let point: Point = Point {
            x: x,
            y: y,
        };

        return point;
    }

    pub fn add_x(&mut self, value: i32) {
        self.x = self.x + value;
    }
}
```

## Mutation And Layout

Structs are important to Concrete in two ways:

1. as ordinary user-facing data types
2. as low-level layout-bearing types for ABI and FFI work

That is why the project has dedicated layout/ABI documentation and attributes like `#[repr(C)]`.

## Current Direction

Struct lowering and mutation were major recent compiler-hardening areas. The current architecture prefers stable storage for mutable aggregate state instead of transporting whole struct values through fragile backend patterns.
