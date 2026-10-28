# Bug 311 — a destructuring let in another module binds a struct's private fields (TYPE-11 enforced only for literals, reads and writes)

**Status:** OPEN
**Found:** 2026-10-28, FILL-IN(new_bug.sh) by what (workload, probe, review, example)
**Severity:** FILL-IN(new_bug.sh) what goes wrong for a user (silent wrong code, unsound claim, crash, refusal)

<!-- bug-ledger
summary: a destructuring let in another module binds a struct's private fields (TYPE-11 enforced only for literals, reads and writes)
coverage: reproducer tests/regressions/bug311_a_destructuring_let_in_another_module_binds_a_st/repro.con, pinned by FILL-IN(new_bug.sh) the gate leg that pins it (for example check_example_outputs.sh, open-bug reproducers leg)
class: 13
silent: yes
-->

## Reproducer

`tests/regressions/bug311_a_destructuring_let_in_another_module_binds_a_st/repro.con`: FILL-IN(new_bug.sh) the smallest program that shows the defect.

## Observed

FILL-IN(new_bug.sh) what the binary and `--interp` do (exit status, output, diagnostic).

## Expected

FILL-IN(new_bug.sh) what the normative rule says, with a link to it.

## Cause

FILL-IN(new_bug.sh) the code that produces it (file, function).

## Structural cause

FILL-IN(new_bug.sh) the design fact that let this bug exist: which class of
[STRUCTURAL_CLASSES.md](STRUCTURAL_CLASSES.md) it is an instance of (or the new class it adds),
and the other bugs of that class.

## Structural owner

FILL-IN(new_bug.sh) the roadmap task, exit or verified-pipeline stage that removes the
cause for the whole class, not only this spelling.

## Containment while open

FILL-IN(new_bug.sh) the gate leg that pins the current behaviour, and what a user
does meanwhile. A silent defect is stopped at once by repair or fail-closed containment
([defect disposition rule](../../ROADMAP.md#the-current-execution-queue)).
