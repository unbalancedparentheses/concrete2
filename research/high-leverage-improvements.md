# High-Leverage Improvements

**Status:** Open research direction
**Affects:** Compiler architecture, language design, tooling, stdlib priorities
**Date:** 2026-03-09

## Purpose

This note is about leverage.

The question is not "what features could Concrete add?"

The better question is:

**What changes would make Concrete dramatically better without making it dramatically more complicated?**

For Concrete, the best 10x improvements are likely to be:

- architectural clarifications
- stronger boundaries
- better tooling visibility
- carefully chosen library work

not an explosion of surface-language features.

## Main Thesis

Concrete gets stronger when it becomes:

- easier to explain
- easier to audit
- easier to compile predictably
- easier to verify

The highest-leverage improvements are the ones that improve several of those dimensions at once.

## The Best 10x Improvements

### 1. Summary-based frontend

If cross-file dependencies become summary-level instead of body-level, several things get better at once:

- frontend structure becomes simpler
- parallel compilation becomes easier
- incremental compilation becomes easier
- import boundaries become more explicit
- the compiler becomes easier to reason about

This is one of the rare changes that helps architecture, performance, and clarity simultaneously.

Related note:

- [file-summary-frontend.md](file-summary-frontend.md)

### 2. Core as semantic authority

Concrete already has Core IR and Core validation. The highest-leverage next step is to make Core more decisively the place where language meaning lives.

Benefits:

- fewer duplicated rules in `Check`
- clearer proof target
- clearer pass ownership
- cleaner lowering story

This is a major leverage point because it simplifies both implementation and explanation.

### 3. ABI/layout subsystem clarity

For a low-level language, layout and FFI credibility matter enormously.

Concrete becomes much more real if it has:

- a clear size/alignment model
- explicit enum payload rules
- explicit field-offset logic
- a single source of truth for FFI-safe decisions

This is higher leverage than many syntax features because it affects trust in the language for real systems work.

### 4. Audit-focused tooling and compiler outputs

Concrete should not only be explicit in source code. It should also be inspectable in tooling.

High-value outputs include:

- capability summaries
- `Unsafe` usage summaries
- allocation summaries
- monomorphization reports
- type layout reports
- cleanup/destruction reports
- import/interface summaries
- pass-boundary inspection modes

This could become one of Concrete's strongest differentiators.

Very few languages make the compiler itself an audit tool.

### 5. Small but excellent standard library

Concrete does not need a huge stdlib early.

It needs a sharp one in the right places:

- bytes and buffers
- borrowed slices and text views
- allocator-explicit collections
- file/path/process/env
- networking
- formatting

The leverage comes from making low-level code practical without compromising the language's explicitness.

### 6. Explicit project/build model

A boring, explicit build story has much higher value than it first appears.

Benefits:

- easier reproducibility
- easier FFI setup
- easier target configuration
- less hidden environment coupling
- clearer mental model for users

For Concrete, this may be more valuable than many advanced language features.

### 7. Proof-driven narrowing

One of the biggest multipliers is rejecting the wrong ideas early.

If the project gets better at saying:

- this complicates the proof story too much
- this weakens pass boundaries
- this hides too much semantics
- this adds surface area without real low-level value

then Concrete gets stronger without writing more code.

This is leverage through disciplined omission.

## What Is Probably Not 10x

These things may still matter, but they are less likely to be transformative right now:

- lots of new syntax
- broad convenience sugar
- sophisticated abstraction features
- large-library surface before the core libraries are excellent
- backend diversification before the current backend boundary is fully clean

These tend to add complexity faster than they add leverage.

## A Useful Pattern

The best improvements usually do at least three of these:

- simplify compiler structure
- improve user trust
- improve auditability
- improve proof tractability
- improve future performance/tooling options

If an idea only improves ergonomics, it is probably not a top-tier priority for Concrete.

## Suggested Priority Order

If the goal is highest leverage rather than most visible change:

1. summary-based frontend
2. Core as semantic authority
3. ABI/layout subsystem cleanup
4. audit-focused compiler/tooling outputs
5. small but excellent stdlib
6. explicit build/project model
7. proof integration over the stabilized architecture

## Strongest Differentiator

The most underappreciated opportunity is this:

**Make Concrete not just explicit as a language, but inspectable as a toolchain.**

That means:

- the source is explicit
- the compiler phases are explicit
- the artifacts are inspectable
- the unsafe/effect/allocation boundaries are queryable
- layout and cleanup behavior are visible

That combination would make Concrete unusually strong for:

- auditing
- generated code review
- low-level security-sensitive software
- verification-oriented engineering

This is a better differentiator than trying to out-feature bigger languages.

## Recommendation

Concrete should spend its effort first on improvements that multiply clarity across the whole project.

That means:

- architecture before ornament
- tooling visibility before convenience syntax
- ABI/layout credibility before feature expansion
- proof-friendly boundaries before richer abstractions

The highest-leverage path is not to make Concrete bigger quickly.

It is to make Concrete sharper.

## Related Notes

- [feature-admission-checklist.md](feature-admission-checklist.md)
- [file-summary-frontend.md](file-summary-frontend.md)
- [concrete-candidate-ideas.md](concrete-candidate-ideas.md)
- [mlir-backend-shape.md](mlir-backend-shape.md)
