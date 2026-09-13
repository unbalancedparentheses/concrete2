# Error Handling Design: Explicit Result Flow

Status: design/freeze reference (postfix `?` removed 2026-09-08)

Concrete represents recoverable failure with `Result<T, E>`. It does not have exceptions,
unwinding, implicit error conversion, or a postfix propagation operator. Every propagation edge is
written as an exhaustive `match`, and the error arm contains the `return` that exits the function.

For the failure model, see [FAILURE_STRATEGY.md](FAILURE_STRATEGY.md). For the permanent language
decision, see [ANTI_FEATURES.md](ANTI_FEATURES.md) and
[DECISIONS.md](../project/DECISIONS.md). For stdlib conventions, see
[ERROR_CONVENTIONS.md](ERROR_CONVENTIONS.md).

## The decision

The previously implemented postfix `?` operator is removed. It compressed a match and an early
return into punctuation at an expression site. That saved source characters but made reviewers
mentally reconstruct:

- which call can exit the current function;
- which error type leaves the function;
- whether a conversion occurs;
- which deferred cleanup runs at that boundary; and
- whether a refactor moved or duplicated a linear value.

That trade is not worthwhile for an audit-first language. Model-authored code makes explicit arms
cheap to generate; human review remains the scarce resource. The lexer recognizes `?` only so the
parser can reject it with a targeted migration diagnostic.

## Canonical same-error propagation

```concrete
fn parse_header(data: [i32; 8]) -> Result<Header, ParseError> {
    let version: i32 = match validate_version(data[0]) {
        Result::Ok { value } => value,
        Result::Err { error } => {
            return Result::<Header, ParseError>::Err { error: error };
        },
    };

    return Result::<Header, ParseError>::Ok {
        value: Header { version: version },
    };
}
```

The success arm yields the payload. The error arm returns the error explicitly. Nothing converts,
drops, allocates, or acquires authority implicitly.

## Canonical cross-error propagation

When one stage has a narrower error type, conversion is visible in the error arm:

```concrete
fn handle(req: Request) -> Result<Response, ServiceError> {
    let validated: Validated = match validate(req) {
        Result::Ok { value } => value,
        Result::Err { error } => {
            return Result::<Response, ServiceError>::Err {
                error: to_service_validation(error),
            };
        },
    };
    return process(validated);
}
```

`map_err` may remain useful as an ordinary named combinator, but it does not create a hidden return:
the caller still matches the mapped `Result` and writes the returning arm.

## Cleanup and authority

An error arm's `return` is a normal return. All `defer` actions for scopes it exits run in the same
LIFO order as any other explicit return. Terminal aborts and signals still do not run cleanup.

Calling a fallible function uses the capabilities declared by that function. Propagating its
returned value requires no new capability, and the language performs no implicit allocation or
conversion while doing so.

## Linear values

`Result<T, E>` participates in the ordinary conservation rules:

- matching consumes the `Result` value;
- the selected payload becomes a new binding;
- the success arm cannot silently discard a linear error payload;
- the error arm cannot silently discard a linear success payload; and
- returning a payload transfers ownership exactly once.

The explicit match is therefore both the control-flow spelling and the ownership accounting
surface. There is no special propagation exception in the checker or Core IR.

## Result and Option helper floor

Helpers are library operations, not alternate control flow. The stable useful floor is:

| Type | Helper | Purpose | Constraint |
|---|---|---|---|
| `Result<T, E>` | `is_ok`, `is_err` | inspect the variant | borrowed receiver |
| `Result<T, E>` | `unwrap_or_else` | consume either arm without dropping a loser | explicit function pointer |
| `Result<T, E>` | `map` | transform the success payload | explicit function pointer |
| `Result<T, E>` | `map_err` | transform the error payload | explicit function pointer |
| `Result<T, E>` | `and_then` | sequence a fallible step | explicit function pointer |
| `Result<T, E>` | `unwrap_or`, `ok`, `err` | select one branch | `Copy` payload bounds where the other arm is discarded |
| `Option<T>` | `is_some`, `is_none` | inspect the variant | borrowed receiver |
| `Option<T>` | `unwrap_or_else`, `map`, `and_then` | explicit transformation/fallback | explicit function pointer |

Concrete has no closures, implicit trait resolution, or implicit `From` conversion. Helper APIs
therefore accept named function pointers and explicit type arguments where required. A helper that
returns a `Result` never propagates it out of its caller by itself.

## Parser and service patterns

Parsers should use a flat, named error enum and keep each failure branch adjacent to the check that
can produce it. Services should convert stage-specific errors in a visible arm at the stage
boundary. A long sequence of nearly identical arms is not, by itself, evidence that new syntax is
needed; first prefer:

1. a named validation function with a narrower responsibility;
2. an ordinary `and_then` or `map_err` combinator when it improves the data flow;
3. a single match around a multi-step function rather than one match per internal check; and
4. generated source outside the language when repetition is truly mechanical and the output is
   reviewed as ordinary Concrete code.

## Rejected alternatives

- **Postfix `?`:** permanently removed; hides an early return behind punctuation.
- **Implicit error conversion:** rejected; depends on hidden trait/conversion lookup.
- **Exceptions or unwinding:** permanently excluded by the execution model.
- **Try/catch blocks:** rejected; create a second failure-control model.
- **Result-specific statement syntax:** rejected; duplicates exhaustive `match` semantics.
- **Closure-taking combinators:** unavailable because capturing closures are permanently excluded.

## Validation requirements

The language and documentation stay aligned only if all of these remain true:

1. postfix `?` is rejected with the dedicated removal message;
2. the surface AST and Core IR have no propagation node;
3. Check, Elab, Mono, lowering, interpreter, proof extraction, and evidence identity contain no
   propagation-specific path;
4. same-type and cross-type explicit propagation compile and execute correctly;
5. explicit error returns run `defer` cleanup in nested scopes;
6. ignored fallible results remain rejected by the must-use rule; and
7. docs, book, site mirrors, tests, and examples show exhaustive match plus explicit return.

Historical changelog entries may record when postfix `?` existed. They are history, not current
language documentation, and its retired diagnostics remain reserved rather than being reassigned.
