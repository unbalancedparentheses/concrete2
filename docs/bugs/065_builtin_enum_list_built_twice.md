# Bug 065 — `builtinEnumList` is constructed in two places

**Status:** FIXED 2026-08-02
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

## Fixed

One owner: `builtinOptionEnum`, `builtinResultEnum`, `hasUserResultEnum` and
`builtinEnums` now live in `Concrete/Frontend/AST.lean`, consumed by both passes.

Placed in AST rather than `Resolve/Intrinsic` — the obvious home, since that is
where `resultEnumName` lives — because these are `EnumDef` VALUES and AST imports
Intrinsic, not the reverse. Putting them there cycles.

`hasUserResultEnum` takes BOTH the module's enums and its imported ones, so the
input asymmetry is gone by construction rather than by both sites remembering.

## Original fix shape

One owner. A single `builtinEnums (hasUserResult : Bool)` consumed by both passes,
so the shadowing rule is stated once.

## The inputs ALREADY differ — but no symptom is demonstrated

The two sites do not merely duplicate the list; they compute `hasUserResult` from
DIFFERENT inputs:

```
Elab.lean:1630   m.enums.any (== Result) || imports.enums.any (== Result)
Check.lean:2120  m.enums.any (== Result)                    -- imports NOT consulted
```

So an IMPORTED user `Result` suppresses the builtin in Elab and does not in
Check. That is a genuine disagreement in the code.

**It is not yet a demonstrated defect.** A program importing a user `Result`
compiles cleanly, so the differing belief does not surface as wrong behaviour in
the obvious case — probably because a duplicate name in `allEnums` resolves to
the first entry and the two orders happen to agree here. A witness would need a
case where resolution order or exhaustiveness actually depends on which `Result`
is present.

Recorded this way deliberately: "the inputs differ" is measured, "it produces a
wrong answer" is not, and stating the second would be the overreach this bug is
an instance of.

## Fixed

One owner: `builtinOptionEnum`, `builtinResultEnum`, `hasUserResultEnum` and
`builtinEnums` now live in `Concrete/Frontend/AST.lean`, consumed by both passes.

Placed in AST rather than `Resolve/Intrinsic` — the obvious home, since that is
where `resultEnumName` lives — because these are `EnumDef` VALUES and AST imports
Intrinsic, not the reverse. Putting them there cycles.

`hasUserResultEnum` takes BOTH the module's enums and its imported ones, so the
input asymmetry is gone by construction rather than by both sites remembering.

## Original fix shape

One owner. A single `builtinEnums (hasUserResult : Bool)` plus one shared
`hasUserResult` computation consumed by both passes, so the shadowing rule and
its inputs are each stated once. Worth doing regardless of whether a witness is
found: the value of one owner is that the question stops being askable.
