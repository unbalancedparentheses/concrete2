# Bug 313 — duplicate member names inside one declaration reach llvm-as or are accepted (no rule or site checks fields, variants, methods or parameters)

**Status:** FIXED (branch `wip/member-collisions`)
**Found:** 2026-10-28, by the class-13 spec audit (`wip/class13-audit`, `research/process/class13-audit-2026-10/`): one program per clause of each normative rule, native against `--interp`.
**Severity:** loud for methods and variants (a lower layer leaks: `llvm-as` natively, an internal error or an accepted run under `--interp`, so the consumers disagree); the other duplicate members are accepted, the first declaration winning.

<!-- bug-ledger
summary: duplicate member names inside one declaration reach llvm-as or are accepted (no rule or site checks fields, variants, methods or parameters)
coverage: reproducer tests/regressions/bug313_duplicate_member_names_inside_one_declaration_re/repro.con, pinned by run_tests.sh (`run_err` legs for the reproducer and the nine `error_313_*` fixtures) and check_spec.sh S4 (`MOD-5/duplicate-variant`, `MOD-5/duplicate-method`)
class: 13
silent: no
-->

## Reproducer

`tests/regressions/bug313_duplicate_member_names_inside_one_declaration_re/repro.con`: an impl with two methods `fn g(&self) -> Int`.

## Observed

On main ca49fada Check accepts it; the native build fails in `llvm-as` (`LLVM IR validation failed`, a redefined symbol) and `--interp` stops on `call 'S_g' by name reaches 2 definitions in different modules`. The same holds for two static methods and for a trait impl that defines a method twice. `enum E { A, A }` fails in `llvm-as` natively and runs under `--interp`. Two fields of a struct or of a variant, two type parameters of a function or struct, two capability parameters and a trait declaring a method twice are accepted by both consumers.

## Expected

No rule said it. [MOD-3](../spec/modules.md#MOD-3) binds each module-level name once and [TRAIT-5](../spec/traits.md#TRAIT-5) refuses two impls of one type declaring one method; the pipeline contracts ([PASS-5 – PASS-10](../spec/pipeline.md), README S4) require that no lower layer such as `llvm-as` sees a program the front end accepted badly. The new [MOD-5@1](../spec/modules.md#MOD-5) states the rule: a declaration binds each of its member names once, refused at check with E0324.

## Cause

No site existed. `Concrete/Check/Check.lean`'s `declarationCollisions` judges module-level names only (and leaves methods of one type to TRAIT-5, whose `Coherence.pairwise` compares impls pairwise, never one impl with itself); nothing walked the member lists of a declaration.

## Structural cause

Class 13: a rule with no enforcing site, here with no written rule at all. The uniqueness of names
was stated per namespace as each bug arrived (module names after bug 082 and 218, value parameters
under SCOPE-1, methods across impls under TRAIT-5), so the member lists inside one declaration fell
between them. Same audit: bugs 310, 311 and 312.

## Structural owner

R-0499 (the Core checker as the one well-formedness judgment of declarations). Until then
`memberCollisions` is MOD-5's one site over every member list of every declaration, and
check_spec.sh S12 (`wip/spec-code-coverage`) asks for a negative witness per rule code.

## Containment while open

Fixed with the filing.

## Fix

`memberCollisions` (Check.lean, `spec: MOD-5`), run by `checkModule` beside
`declarationCollisions`, refuses the second of two members of one name in: a struct's fields, an
enum's variants, a variant's fields, a trait's methods, one impl's methods, and the type and
capability parameters of a struct, enum, newtype, trait, impl, function or method. The code is
E0324 (ledger, `codes.tsv`, the `MOD-5@1` rule tag); `docs/spec/modules.md` gains MOD-5 with two
reject examples. Two impls of one type stay TRAIT-5's (E0594), value parameters SCOPE-1's (E0301).

Codex confirmation 2026-10-28: CONFIRMED — duplicate methods within one impl and duplicate enum variants escape into LLVM validation failures, a pipeline defect independent of OD6; the acceptance of the other duplicate forms alone does not establish unsoundness under the cited rules (loud; OD: none).
