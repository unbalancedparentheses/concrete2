# Enums

Enums define tagged unions. Variants can carry payloads or be empty.

Example:

```rust
mod option {
    enum Option<T> {
        Some {
            value: T,
        },
        None,
    }

    impl<T> Option<T> {
        pub fn is_some(&self) -> bool {
            match self {
                Option#Some { value } => {
                    return true;
                },
                Option#None => {
                    return false;
                }
            }
        }

        pub fn is_none(&self) -> bool {
            return !self.is_some();
        }
    }
}
```

Enums are matched with `match`, and variants are introduced with the `Type#Variant` syntax.

```rust
mod Enum {
    enum A {
        X {
            a: i32,
        },
        Y {
            b: i32,
        }
    }

    fn main() -> i32 {
        let x: A = A#X {
            a: 2,
        };

        let mut result: i32 = 0;

        match x {
            A#X { a } => {
                result = a;
            },
            A#Y { b } => {
                result = b;
            }
        }

        return result;
    }
}
```

## Why Enums Matter In Concrete

Enums matter both as language-level sum types and as layout-sensitive types:

- they participate in ordinary control flow and error handling
- they matter to ABI/layout rules
- they appear in trusted/FFI boundaries
- they are important to report/audit surfaces

`Result` is especially important because it is one of the language's core ergonomic/dataflow types.
