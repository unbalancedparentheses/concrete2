<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

Concrete is a systems programming language with **linear types** and a compiler written entirely in **Lean 4**. It compiles to LLVM IR via textual emission, producing native binaries through clang.

## Design Principles

1. **Linear by default** - Struct-typed values must be consumed exactly once. No leaks, no use-after-free.
2. **Pure by default** - Functions are pure unless they take mutable references or perform I/O.
3. **Explicit is better than implicit** - No hidden control flow, no implicit conversions, no implicit destruction.
4. **Fits in your head** - Small language, small compiler (~3,500 lines of Lean 4).
5. **LL(1) grammar** - Parseable with single token lookahead, no ambiguity.

## Compilation Pipeline

```
Source (.con)
    |
    v
  Lexer (Concrete/Lexer.lean)
    |
    v
  Parser (Concrete/Parser.lean) -- LL(1) recursive descent
    |
    v
  AST (Concrete/AST.lean)
    |
    v
  Type Checker (Concrete/Check.lean) -- types + linearity + borrowing
    |
    v
  Code Generator (Concrete/Codegen.lean) -- emits LLVM IR text
    |
    v
  clang -- LLVM IR -> native binary
```

## Quick Example

```rust
struct Point {
    x: Int,
    y: Int
}

impl Point {
    fn sum(&self) -> Int {
        return self.x + self.y;
    }
}

fn main() -> Int {
    let p: Point = Point { x: 10, y: 20 };
    let s: Int = p.sum();
    return s;
}
```

### Linear Types in Action

```rust
struct Resource { value: Int }

fn consume(r: Resource) -> Int {
    return r.value;
}

fn main() -> Int {
    let r: Resource = Resource { value: 42 };
    let v: Int = consume(r);  // r is consumed here
    // Using r again would be a compile error: "linear variable 'r' used after move"
    return v;
}
```

## Language Features

- **Types**: Int (i64), Uint (u64), i8, i16, i32, u8, u16, u32, f32, f64, Bool, Char, String, arrays `[T; N]`
- **Structs** with field access and mutation
- **Enums** with pattern matching (exhaustiveness checked)
- **Impl blocks** with methods (`&self`, `&mut self`, `self`) and static methods
- **Traits** with static dispatch
- **Generics** on functions and structs
- **Borrowing**: `&T` (shared) and `&mut T` (exclusive), with borrow checking
- **Linear type system**: structs consumed exactly once, branches must agree on consumption
- **Modules** with `pub` visibility and imports
- **Result type** with `?` operator for error propagation
- **Cast expressions** (`as`) between numeric types
- **For loops**, while loops, if/else chains
- **Constants**, type aliases, extern fn declarations
- **Raw pointers** (`*mut T`, `*const T`)

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs all 59 tests
make clean    # or: lake clean
```

## Usage

```bash
.lake/build/bin/concrete input.con -o output
./output
```

## Project Structure

```
Concrete/
  Token.lean     -- Token types
  Lexer.lean     -- Tokenizer
  AST.lean       -- Abstract syntax tree
  Parser.lean    -- LL(1) recursive descent parser
  Check.lean     -- Type checker + linearity checker + borrow checker
  Codegen.lean   -- LLVM IR code generation
Main.lean        -- Entry point
lean_tests/      -- Test suite (59 tests)
examples/        -- Example .con programs
std/             -- Standard library .con files
```

## Tests

59 tests: 34 positive (compile + run + check output) and 25 negative (expected type/linearity errors).

```bash
./run_tests.sh
```

## License

[Apache 2.0](/LICENSE)
