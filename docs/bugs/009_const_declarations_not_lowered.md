# Bug 009: Const Declarations Parsed But Not Lowered

**Status:** Open
**Discovered:** 2026-03-15
**Regression test:** `examples/constants.con` (existing example, currently broken)

## Symptom

`const` declarations are accepted by the parser but produce SSA verification errors at compile time:

```
error[ssa-verify]: main: block 'entry': use of undefined register %foo
```

## Reproduction

```con
mod Example {
    const foo: i32 = 10;

    fn main() -> i32 {
        return foo + 5;
    }
}
```

This fails with "use of undefined register %foo". The parser accepts it (no parse error), but the lowering pass does not emit a definition for the constant.

## Root Cause

The parser handles `const` declarations (`Parser.lean:1550`), but `Lower.lean` likely does not emit an SSA register or inline the constant value during lowering. The constant name appears as an unresolved register reference.

## Impact

- `examples/constants.con` is broken — it doesn't compile
- Programs that want named constants must use `fn FOO() -> i32 { return 0; }` as a workaround
- The feature appears to exist (parsed, shown in reports) but doesn't work end-to-end
