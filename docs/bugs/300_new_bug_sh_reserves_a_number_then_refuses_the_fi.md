# Bug 300 — new_bug.sh reserves a number, then refuses the filing for want of a discovery row naming it

**Status:** OPEN
**Found:** 2026-10-26, FILL-IN(new_bug.sh) by what (workload, probe, review, example)
**Severity:** FILL-IN(new_bug.sh) what goes wrong for a user (silent wrong code, unsound claim, crash, refusal)

<!-- bug-ledger
summary: new_bug.sh reserves a number, then refuses the filing for want of a discovery row naming it
coverage: reproducer tests/regressions/bug300_new_bug_sh_reserves_a_number_then_refuses_the_fi/repro.con, pinned by FILL-IN(new_bug.sh) the gate leg that pins it (for example check_example_outputs.sh, open-bug reproducers leg)
class: 12
silent: no
-->

## Reproducer

`tests/regressions/bug300_new_bug_sh_reserves_a_number_then_refuses_the_fi/repro.con`: FILL-IN(new_bug.sh) the smallest program that shows the defect.

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
