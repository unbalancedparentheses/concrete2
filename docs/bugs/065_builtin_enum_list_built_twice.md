# Bug 065 — `builtinEnumList` is constructed in two places

**Status:** OPEN
**Found:** 2026-08-02, while inventorying type-ingress paths for R-0004.

## Symptom

The list of compiler-provided enums is built independently in two passes, with
the same conditional duplicated:

* `Concrete/Elab/Elab.lean:1632`
* `Concrete/Check/Check.lean:2121`

both as `[builtinOptionEnum] ++ (if hasUserResult then [] else [builtinResultEnum])`.

## Why it matters

One fact in two places, free to drift — the defect class R-0004 exists to close
(bugs 050, 054, 055, 056, 057, 061 are all instances). If the two ever disagree,
Check and Elab hold different beliefs about what `Result` is: a program could
type-check against one definition and elaborate against another, and nothing in
the compiler would report the disagreement, because neither pass can see the
other's list.

The `hasUserResult` shadowing rule makes divergence more likely than a plain
constant would: it is a CONDITIONAL, so a change to when a user `Result` shadows
the builtin has to be made twice.

## Fix shape

One owner. A single `builtinEnums (hasUserResult : Bool)` consumed by both passes,
so the shadowing rule is stated once.

## Not urgent, but not cosmetic

No divergence exists today — this is filed before it becomes a bug rather than
after, which is the cheap moment.
