# Text And Output Design

Status: open

Phase H removed the most painful standalone gaps by adding:

- `print_string`
- `print_int`
- `print_char`
- `string_substr`
- `string_push_char`
- `string_append`

That fixed the first-wave blockers. It did not finish the text/output story.

## Remaining Problem

Concrete still lacks a strong general-purpose text/output layer for real programs:

- formatting / interpolation
- logging-friendly message construction
- parser-oriented string helpers beyond raw slicing
- a clearer split between compiler builtins and stdlib text APIs

## Design Questions

1. Should formatting be a stdlib function family, a macro-like surface, or explicit interpolation syntax?
2. What minimum formatting capability is enough for real programs without importing a large dynamic formatting system?
3. What parser/text helpers belong in stdlib rather than user-space utilities?
4. Which current text operations should remain builtins versus becoming stdlib wrappers?

## Initial Scope

Prioritize:

- `format(...)` or equivalent minimal formatting surface
- interpolation syntax only if it clearly beats a library design
- text builder patterns that avoid repeated linear-allocation boilerplate
- parser helpers that appear repeatedly in Phase H programs

## Non-Goals

- a large printf-style formatting language by default
- hiding allocation or authority costs
- turning common output into an implicit runtime feature
