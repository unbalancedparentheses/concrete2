# Feature Admission Checklist

**Status:** Process guideline
**Affects:** Language design, compiler architecture, roadmap decisions
**Date:** 2026-03-09

## Purpose

Use this checklist as a gate before adopting any language feature, compiler feature, or borrowed idea from another language.

Concrete is not trying to maximize shorthand or copy fashionable features. The standard should be higher:

- does this preserve simplicity?
- does this improve reliability?
- does this fit the verification story?
- does this keep semantics explicit?

If a proposal only improves ergonomics while making the compiler harder to explain, it is probably a bad fit.

## Feature Admission Checklist

### 1. Can it be explained as a simple invariant?

If the rule needs many exceptions, fallback cases, or "except when..." clauses, reject it.

### 2. Does it make behavior more visible or less visible?

Prefer features that expose effects, ownership, dispatch, layout, or control flow.

Reject features that hide work behind familiar syntax.

### 3. Does it reduce compiler phase coupling?

Prefer ideas that keep parse, resolve, check, and elab boundaries clean.

Reject ideas that make early phases depend on later semantic information.

### 4. Are cross-file dependencies declaration-level only?

Prefer summaries, signatures, layouts, and explicit imports.

Reject anything that makes one file depend on another file's bodies.

### 5. Is dispatch still statically known or explicitly indirect?

Prefer monomorphization, named functions, and explicit function pointers.

Reject hidden dynamic dispatch, hidden captures, or broad implicit lookup.

### 6. Does it preserve predictable code generation?

The user should be able to form a rough mental model of runtime behavior from the source.

If the compiler may insert surprising work, be very skeptical.

### 7. Does it improve diagnostics or make them murkier?

A good feature should have obvious ownership for error reporting.

If failures become "somewhere in inference/magic," reject it.

### 8. Can the compiler own it with one clear pass?

Each rule should have an obvious home.

If multiple passes must partially own it, that is a warning sign.

### 9. Does it help or hurt the proof story?

Prefer rules that elaborate into simpler core forms.

Reject rules that require semantic duplication, hidden state, or many meta-level exceptions.

### 10. Is the benefit real for audited low-level code?

Concrete is not trying to maximize shorthand.

If the gain is mainly convenience for writing code faster, that is not enough.

## Quick Decision Rule

Adopt ideas that are:

- explicit
- local
- phase-separated
- summary-friendly
- easy to lower away

Reject ideas that are:

- implicit
- global
- inference-heavy
- body-dependent
- hard to model formally

## One-Line Test

A feature is promising if it makes the compiler and the language easier to explain at the same time.

## Applying This To Borrowed Ideas

The best ideas to borrow from other languages are usually not convenience features. They are usually constraints, interfaces, or compiler boundaries.

Examples of strong fits:

- file-summary or declaration-only import models
- explicit proof-obligation discipline for new features
- a single semantic IR as the main authority
- clear monomorphization boundaries
- internal analyses that simplify reasoning without changing the user model

Examples of risky fits:

- hidden convenience syntax
- broad inference that crosses phase boundaries
- source-generating macro systems
- implicit global lookup rules
- features whose main benefit is reducing keystrokes

## Relationship To Other Research Notes

This checklist is meant to complement:

- [file-summary-frontend.md](file-summary-frontend.md)
- [no-closures.md](no-closures.md)
- [no-trait-objects.md](no-trait-objects.md)
- [derived-equality-design.md](derived-equality-design.md)

Those notes analyze specific design choices. This document is the general filter to apply before writing notes like those in the first place.
