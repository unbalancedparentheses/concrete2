# Bug 335 — The layout and stack-depth reports panic on a project file that uses std's Bytes and report zero sizes

**Status:** OPEN
**Found:** 2026-10-30, by the cleanup pass's identity sweeps (every report kind over the examples: `examples/cli_tool` panicked identically on both binaries); confirmed by Codex review
**Severity:** the reports print a Lean `PANIC` (on stderr), exit 0, and state sizes, alignments, offsets and frame sizes computed with 0 for the unknown type

<!-- bug-ledger
summary: The layout and stack-depth reports panic on a project file that uses std's Bytes and report zero sizes
class: 11
coverage: reproducer tests/regressions/bug335_the_layout_and_stack_depth_reports_panic_on_a_pr/repro.con (the main of a project; also examples/cli_tool); no gate pins it yet, the open status is the rationale
silent: no
ruling: Outside the spec: tooling — the layout and stack-depth reports are report surfaces, not language behaviour; compilation is unaffected
-->

## Reproducer

`tests/regressions/bug335_the_layout_and_stack_depth_reports_panic_on_a_pr/repro.con`, the main
of a project (std is found as the bundled dependency; outside a project `std.cli` does not resolve):

```
$ mkdir -p p/src && cp repro.con p/src/main.con
$ printf '[package]\nname = "repro335"\nversion = "0.1.0"\n' > p/Concrete.toml
$ cd p/src && concrete main.con --report layout       # likewise --report stack-depth
PANIC at ... Concrete.Check.Layout:242:6: Layout.tyAlign: unknown named type 'Bytes'
PANIC at ... Concrete.Check.Layout:301:6: Layout.tySize: unknown named type 'Bytes'
...
$ echo $?
0
```

`examples/cli_tool/src/main.con` shows the same (`concrete main.con --report layout` in its
`src/`).

## Observed

On main `14121934` (OVH): `--report layout` and `--report stack-depth` print a run of Lean
`PANIC` lines for `Bytes` (`Layout.tyAlign`, `Layout.tySize`), then the report, and exit 0. The
report's numbers for any type that contains `Cli` are computed with size and alignment 0 for
`Bytes`. `concrete build` of the same project succeeds and the binary exits 0: compilation is not
affected.

## Expected

No language rule decides it (report surfaces). A report either computes the layout of every type
the program uses, std's included, or refuses with a diagnostic and a failure status; it never
prints a number derived from a default. The compiler's own layout for the build is correct
(`concrete build` lowers with the whole program's definitions).

## Cause

Codex review (2026-10-30), verdict REAL: the report's listing scope is used as its layout
universe. `Main.lean` (around 1724–1736) loads the enclosing project, then removes the dependency
modules and scopes the Core to the requested file; both reports receive only that scoped Core
(around 2896 and 3520). `Report.buildLayoutCtx` (`Concrete/Report/ReportInterface.lean`, around
634) collects type definitions from those modules alone, and the stack-depth report uses it too.
`std.cli`'s `Cli` has a field of type `Bytes`, defined in another std module the import closure
does not reach (`Concrete/Resolve/FileSummary.lean`, around 677 and 709). The unknown-type
branches of `Concrete/Check/Layout.lean` (242, 301) `panic!`, and Lean's `panic!` returns the
default `Nat`, 0, so the reports continue with wrong numbers and exit 0. `concrete build` keeps the
whole validated Core, and `Lower` supplements layout definitions from the entire program
(`Concrete/IR/Lower.lean`, around 2895–2929), so the build path is unaffected.

## Structural cause

Class 11 of [STRUCTURAL_CLASSES.md](STRUCTURAL_CLASSES.md), absence read as a fact: a type the
layout table does not know is given size and alignment 0 (the `panic!` default) instead of failing,
like 052's `destroyable` default and 065's dropped callees. It also shows class 7's pattern (the
build and the reports compute layout over different universes).

## Structural owner

For the instance: one layout context built from the whole validated program and shared by
`Lower` and the reports (the reports then filter what they list, not what they know). For the
class: the layout functions return an error for an unknown type instead of `panic!` with a
default, so no caller can continue with 0; R-0494's single verdict authority is the reporting
side of the same rule.

## Containment while open

No gate pins it yet; the record's open status is the rationale. A user who needs layouts for
types that contain std's `Bytes` reads them from the build (`--emit-llvm`), not from these two
reports, and treats any report run that prints `PANIC` as invalid. A silent defect is stopped at once by repair or fail-closed containment
([defect disposition rule](../../ROADMAP.md#the-current-execution-queue)).
