# Functions

A function can be defined like this:

```rust
pub fn name(arg1: i32) -> i32 {
    return arg1 * 2;
}
```

- `pub`: optional visibility outside the current module

The return type can sometimes be omitted, but explicit return types are common and fit the language's current style.

## Effects And Capabilities

Functions can state required capabilities:

```rust
fn read_config(path: String) with(File) -> Result<String, String> {
    return read_file(path);
}
```

This is one of Concrete's core ideas: authority is part of the function boundary.

## Generics

Functions can be generic:

```rust
fn name<T>(arg: T) -> T {
    return arg;
}

let x: i32 = name::<i32>(2);
```

## Methods And `Self`

Methods are written in `impl` blocks and can take:

- `self`
- `&self`
- `&mut self`

`Self` is an explicit compiler-known language item, and method lowering/mangling is one of the places where the language surface meets the compiler architecture.

## Current Direction

Functions in Concrete are intended to stay explicit about:

- argument and return shapes
- capability requirements
- trust boundaries
- ownership/borrowing behavior
