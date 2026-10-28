# Bug 310 — a generic main is accepted by Check: the native build loses its entry point and --interp runs it

**Status:** FIXED (branch `wip/stmt7-generic-main`)
**Found:** 2026-10-28, by the class-13 spec audit (`wip/class13-audit`, `research/process/class13-audit-2026-10/`): one program per clause of each normative rule, native against `--interp`.
**Severity:** loud natively (a `link` error that names no rule), while `--interp` runs a program STMT-7 forbids: the two consumers disagree.

<!-- bug-ledger
summary: a generic main is accepted by Check: the native build loses its entry point and --interp runs it
coverage: reproducer tests/regressions/bug310_a_generic_main_is_accepted_by_check_the_native_b/repro.con, pinned by run_tests.sh (`run_err` legs for the reproducer, `error_310_generic_main_bounded.con` and `error_310_submodule_generic_main.con`) and check_spec.sh S4 (`STMT-7/generic-main`)
class: 13
silent: no
-->

## Reproducer

`tests/regressions/bug310_a_generic_main_is_accepted_by_check_the_native_b/repro.con`: `fn main<T>() -> Int { return 42; }`.

## Observed

On main ca49fada Check accepts the program. The native build fails at `link`: `error[link]: no `main` function found; an executable needs an entry point`, with no code and no rule. `--interp` runs the generic body and prints 42. `fn main<T: Copy>()` behaves the same.

## Expected

[STMT-7@2](../spec/statements.md#STMT-7): the entry point is a module-level `fn main()` with no parameters. A `main` with a type parameter is refused at check with E0310, on both consumers.

## Cause

`Concrete/Check/Check.lean`, `checkModule`'s `mainParamErrs`, refused only value parameters (bug 111). Nothing instantiates a generic `main`, so Mono dropped it and EmitSSA found no entry point, while the interpreter called the generic body directly.

## Structural cause

Class 13: a documented rule with no enforcing site for one of its clauses. STMT-7's site checked
the clause bug 111 hit (value parameters) and not the rest of the signature it names; no gate asked
for one negative program per clause. The class-13 audit found three more in the same pass (the
TYPE-11 destructure, SYN-3 destructure-binder and duplicate-member gaps).

## Structural owner

R-0499 (the Core checker as the one judgment of a well-formed program, entry signature included).
Until then, check_spec.sh S12 (`wip/spec-code-coverage`) maps every rule code to its enforcing
declarations and requires a negative witness for each.

## Containment while open

Fixed with the filing: Check refuses a `main` with type parameters (`CheckError.mainIsGeneric`,
E0310, `rule: STMT-7@2`). A capability parameter (`fn main<cap C>()`) is left as it is: both
consumers run it, and whether STMT-7 covers it is a question for the rule's owner, not this fix.

## Fix

`mainParamErrs` refuses a `main` that declares a type parameter, after the value-parameter check,
with E0310 and its own message; STMT-7 gains the reject example `generic-main`.

Codex confirmation 2026-10-28: CONFIRMED — `mainParamErrs` ignores type parameters, allowing a generic entry point that native compilation loses while the interpreter executes it (loud natively, silent acceptance in --interp; OD: none).
