# Bug 011: Linear String Building Is Awkward Inside Loops

**Status:** Open (ergonomic/stdlib gap)
**Discovered:** 2026-03-15
**Discovered in:** `examples/mal/main.con`

## Symptom

Incremental string building inside loops is awkward because `String` is linear and the obvious concat/update pattern does not compose well with loop-carried variables:

```con
let mut acc: String = "";
while cond {
    let next: String = string_concat(acc, piece);
    drop_string(acc);
    acc = next;
}
```

This became painful while implementing MAL reader/parser code. Combined with the lack of substring extraction, it pushed the implementation away from ordinary string construction altogether.

## Current Workarounds

- avoid building intermediate strings where possible
- compute hashes or lengths directly from source positions
- use more manual control-flow than the domain logic naturally wants

## Impact

- parser and pretty-printing code are harder to write than they should be
- string-heavy real programs pay an unnecessary ergonomics tax
- encourages avoidance patterns instead of direct, readable code

## Fix Direction

Provide one or more loop-friendly string-building primitives, for example:

- `string_push_char(&mut String, ch: Int)` / `push_char` on `String`
- `string_append(&mut String, &String)` or `append_str`
- a builder type specialized for incremental string construction

The key requirement is that real programs can build strings incrementally without fighting linearity at every loop boundary.
