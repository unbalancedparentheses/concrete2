# Text And Output Design

Status: partially addressed

Phase H removed the most painful standalone gaps by adding:

- `print_string`
- `print_int`
- `print_char`
- `string_substr`
- `string_push_char`
- `string_append`
- `string_append_int`
- `string_append_bool`

## What Is Now Possible

Building mixed-type output strings without intermediate allocations:

```con
let mut msg: String = "Expected ':' at position ";
string_append_int(&mut msg, pos as Int);
string_append(&mut msg, &", got '");
string_push_char(&mut msg, ch as Int);
string_append(&mut msg, &"'");
```

This is still verbose compared to interpolation, but it is:
- zero-grammar-cost (no new syntax)
- leak-free (no intermediate string allocations to track)
- explicit about allocation (requires `Alloc` capability)
- composable with the existing builder pattern

## Remaining Problem

Concrete still lacks:

- string interpolation syntax (would cut verbosity 3-5x for mixed-type messages)
- a `format(pattern, ...)` variadic function
- parser-oriented string helpers beyond raw slicing

## Design Decision

The current approach is **builder builtins** — `string_append`, `string_append_int`, `string_append_bool`, `string_push_char` — rather than interpolation syntax.

Why:
- fits the design policy (no new syntax, no hidden work, one clear pass)
- avoids grammar cost and proof cost of interpolation
- eliminates the main pain point (intermediate allocations for number→string→append→drop)
- interpolation can be revisited later if the builder pattern proves too verbose at 10k+ LOC scale

## What To Watch During Phase H

The JSON parser will be the first sustained test of this approach. If error message construction becomes a dominant source of code noise, that's evidence for revisiting interpolation.
