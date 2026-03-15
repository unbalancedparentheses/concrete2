# Bug 008: If-Else Expression Does Not Parse for Aggregate Types

**Status:** Open
**Discovered:** 2026-03-15

## Symptom

Using `if` as an expression to produce a `String` (or other aggregate type) fails at parse time:

```con
let v_label: String = if v == 1 { "ALLOW" } else { "DENY" };
```

```
error[parse]: expected expression, got if at 143:31
```

## Context

The parser rejects `if` in expression position when the target type is an aggregate. Scalar if-expressions may work in some contexts (e.g., `let x: i32 = if cond { 1 } else { 2 }`), but this has not been verified.

## Workaround

Use mutable variable + imperative if:

```con
let mut v_label: String = "DENY";
if v == 1 { v_label = "ALLOW"; }
```

## Impact

- Forces imperative style for simple conditional values
- Makes string-building code more verbose than necessary
- Minor ergonomic issue; not a blocker
