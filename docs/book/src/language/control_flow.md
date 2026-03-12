# Control flow

Concrete keeps control flow explicit. The language uses familiar constructs, but the compiler is intentionally shaped so control-flow lowering stays inspectable and analyzable.

## If

The `if` keyword allows conditional branching.

```rust
fn factorial(n: i64) -> i64 {
    if n == 0 {
        return 1;
    } else {
        return n * factorial(n - 1);
    }
}
```

## Match

Pattern matching works over enums and similar structured values:

```rust
fn unwrap_or_zero(x: Result<i32, i32>) -> i32 {
    match x {
        Result#Ok { value } => {
            return value;
        },
        Result#Err { error } => {
            return error;
        }
    }
}
```

## For

A basic for loop:

```rust
fn sum_to(limit: i64) -> i64 {
    let mut result: i64 = 0;

    for (let mut n: i64 = 1; n <= limit; n = n + 1) {
        result = result + n;
    }

    return result;
}
```

## While

The `for` keyword can also be used in while-style form:

```rust
fn sum_to(limit: i64) -> i64 {
    let mut result: i64 = 0;

    let mut n: i64 = 1;
    for (n <= limit) {
        result = result + n;
        n = n + 1;
    }

    return result;
}
```

## Current Direction

Control-flow lowering has been a major recent compiler-hardening area, especially for mutable aggregate state. That matters because Concrete wants ordinary source control flow to remain compatible with explicit, auditable backend structure.
