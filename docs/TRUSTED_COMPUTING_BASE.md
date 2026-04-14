# Trusted Computing Base

Status: public reference

This document names the main trusted components behind Concrete's strongest current claims.

The point is not to eliminate trust with one document.
The point is to keep the trust boundary explicit.

## Why This Exists

Concrete makes stronger claims than an ordinary compiler:

- checked safe-code guarantees
- proof/evidence artifacts
- Lean-backed proof attachments
- trust-drift and consistency checks

Those claims are only honest if the trusted computing base stays visible.

## TCB Layers

### 1. Concrete checker and compiler

Trusted for:

- parsing, resolution, checking, elaboration, lowering, reporting, and artifact production
- enforcing the documented safe-code rules
- generating accurate proof/evidence artifacts

Not currently claimed:

- full formal proof of compiler correctness
- proof of code-generation correctness

### 2. Lean kernel

Trusted for:

- checking attached theorems and proof objects
- enforcing the theorem-level proof discipline Concrete relies on

This is the core trust anchor for the “proved” label.

### 3. Proof attachment / registry / fingerprint machinery

Trusted for:

- correctly binding source functions, specs, and theorem identities
- correctly detecting stale or mismatched proof attachments

Concrete is actively reducing this trust surface with attachment validation and stale checks, but it is still part of the TCB.

### 4. Backend and toolchain

Trusted for:

- LLVM IR handling
- optimization correctness
- object generation, linking, and final binary behavior within normal toolchain assumptions

Concrete does not claim to verify this layer today.

### 5. Runtime / target / OS / hardware

Trusted for:

- ABI behavior
- calling conventions
- allocator and libc behavior where used
- OS and hardware behavior outside the source-language model

This especially matters for:

- FFI
- timing/stack/layout assumptions
- hosted runtime behavior

### 6. Trusted and foreign program boundaries

Trusted for:

- correctness of code behind `trusted` boundaries
- correctness of foreign code behind FFI boundaries
- correctness of wrappers that intentionally concentrate unsafety

Concrete's goal is to keep this trust visible and narrow, not to pretend it disappears.

## Strongest Current Claims And Their TCB

### Safe checked subset

Depends primarily on:

- Concrete checker/compiler

Also depends on:

- backend/runtime behaving within normal assumptions where those claims cross into execution

### Lean-backed proof claims

Depends on:

- Concrete proof extraction and artifact pipeline
- proof attachment/registry machinery
- Lean kernel

Does not imply:

- binary correctness
- verified backend behavior

### Predictable/high-integrity direction

Depends on:

- compiler profile checks and reports
- explicit boundary classification
- eventual package/profile review workflows

This is one reason high-integrity should be treated as an explicit profile surface, not a slogan.

## Practical Rule

When a claim gets stronger, ask:

1. which layer is enforcing it?
2. which layer is proving it?
3. which layer is still trusted?
4. which layer is backend/target assumed?

If those answers are unclear, the claim is too vague.
