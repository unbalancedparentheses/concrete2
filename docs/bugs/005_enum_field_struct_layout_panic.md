# Bug 005: Enum Fields Inside Structs Can Panic Layout Computation

**Status:** Fixed
**Discovered:** 2026-03-15
**Regression test:** not added yet

## Symptom

The compiler can panic while lowering or laying out a struct that contains enum-typed fields, especially when that struct is later stored inside `Vec`-style collections or otherwise forced through layout computation.

The immediate trigger discovered during Phase H policy-engine work was a `Rule` struct containing `Action` and `Verdict` enum fields. `Layout.tyAlign` could not compute alignment for the enum field inside the named struct and crashed instead of producing a normal compiler error or a correct layout.

## Reproduction Shape

```con
enum Copy Action {
    Read {},
    Write {},
}

enum Copy Verdict {
    Allow {},
    Deny {},
}

struct Copy Rule {
    action: Action,
    verdict: Verdict,
}
```

The crash was observed once this struct shape was used in a collection-oriented workload rather than only in isolation.

## Current Workaround

Use integer tags (`i32`) instead of enum fields inside the affected struct and keep conversion helpers at the edges:

- `Action` <-> `i32`
- `Verdict` <-> `i32`

This keeps the program moving, but it is a compiler workaround, not a language decision.

## Impact

- blocks natural domain modeling for real programs that want enums inside named structs
- pushes Phase H example programs toward encoding tags manually instead of using the language honestly
- weakens confidence in layout handling for mixed aggregate types

## Fix Direction

Investigate `Concrete/Layout.lean`, especially the paths used by `tyAlign` / `tySize` for named structs whose fields include enums.

The fix should ensure:

- enum-typed fields inside structs have a normal layout/alignment path
- the compiler does not panic on this shape
- the shape is covered by a regression test, ideally including a collection-oriented use such as `Vec<Rule>` or equivalent lowering pressure
