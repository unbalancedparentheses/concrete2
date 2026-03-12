# Reference Docs

This book is the main narrative guide, but Concrete also has stable reference documents in the repository root `docs/` directory.

Use them when you need exact current direction rather than the book's higher-level walkthrough.

## Core References

- [`docs/IDENTITY.md`](../../IDENTITY.md)
  Project identity, differentiators, non-goals, and what Concrete must eventually be able to show.

- [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md)
  Compiler pipeline, pass boundaries, artifact flow, and subsystem direction.

- [`docs/PASSES.md`](../../PASSES.md)
  Pass-by-pass ownership and responsibility breakdown.

- [`docs/STDLIB.md`](../../STDLIB.md)
  Stable stdlib direction, systems-module conventions, and collection priorities.

- [`docs/TESTING.md`](../../TESTING.md)
  Test surfaces, fast/full workflows, targeted modes, fuzzing, differential tests, and regression strategy.

## Language And Runtime References

- [`docs/VALUE_MODEL.md`](../../VALUE_MODEL.md)
  The current value and ownership model.

- [`docs/LANGUAGE_INVARIANTS.md`](../../LANGUAGE_INVARIANTS.md)
  The invariants the language and compiler are trying to preserve.

- [`docs/FFI.md`](../../FFI.md)
  FFI direction, `extern fn`, `trusted extern fn`, and boundary rules.

- [`docs/ABI_LAYOUT.md`](../../ABI_LAYOUT.md)
  Layout and ABI-facing rules.

- [`docs/DIAGNOSTICS.md`](../../DIAGNOSTICS.md)
  Diagnostic direction and quality expectations.

## Planning And History

- [`ROADMAP.md`](../../../ROADMAP.md)
  Forward-looking execution plan.

- [`CHANGELOG.md`](../../../CHANGELOG.md)
  Landed milestones and completed work.

- [`research/README.md`](../../../research/README.md)
  Exploratory design notes and longer-horizon research direction.
