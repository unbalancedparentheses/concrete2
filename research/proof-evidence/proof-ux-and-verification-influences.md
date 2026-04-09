# Proof UX And Verification Influences

**Status:** Open

This note is a small filter for ideas from verification-oriented languages.

It only tracks ideas that still add something Concrete does not substantially
already have.

## Already Close To Concrete

These influences are important, but they are mostly already part of Concrete's
identity.

### Austral

Concrete already has or is close to:

- a deliberately small language surface
- visible capabilities in function interfaces
- linear ownership without a large abstraction tower
- auditability as an explicit language goal

### Rust

Concrete already has or is close to:

- explicit trusted / unsafe boundary thinking
- compiler guarantees over convention
- review discipline around dangerous code

Concrete should keep Rust's engineering seriousness, but should not copy the
borrow-checker / lifetime / trait complexity wholesale.

### SPARK, Partially

Concrete already has or is close to:

- restricted analyzable profiles
- reported / enforced / proved / trusted-assumption evidence levels
- explicit trust-boundary discipline

### F*, Partially

Concrete already has or is close to:

- explicit source / proof / backend trust-boundary research
- effect and trust clarity as central design axes

### ATS, Partially

Concrete already has or is close to:

- low-level resource-aware programming
- linearity
- no hidden GC assumption

Concrete should not copy ATS's density of proof terms into normal source.

## New Ideas Worth Copying

### From SPARK

Copy later, only once the current extracted-Core proof pipeline is boring:

- contracts on functions
- loop invariants as a first-class proof tool
- ghost code

Why it matters:

SPARK shows that contracts, invariants, and ghosts are useful for proving
ordinary imperative code. Concrete should treat them as proof/specification
surfaces, not as replacements for capabilities, predictable-profile checks, or
the current evidence reports.

## From Dafny

Copy:

- proof UX
- function/spec integration that feels normal to users
- actionable failed-proof diagnostics
- proof-maintenance ergonomics

Here, **proof UX** means the user experience of writing, debugging, attaching,
inspecting, and maintaining proofs.

For Concrete, good proof UX means:

- specs have an obvious home
- generated obligations can be inspected
- stale proofs, missing proofs, identity mismatches, and body mismatches are
  reported distinctly
- failed proofs explain the missing obligation when possible
- ordinary refactors do not turn every proof into a research project

## From Why3 / WhyML

Copy:

- explicit proof-obligation / verification-condition artifacts
- inspectable separation between code, specs, generated obligations, proof
  attempts, and proof results
- proof session persistence / replay as a normal workflow

Concrete should eventually be able to say:

- this checked Concrete function extracted to this proof artifact
- this spec generated these obligations
- these obligations were discharged by these proofs or assumptions
- this report claim is connected to those results

## From F*

Copy:

- stronger effectful-proof architecture
- explicit extraction-boundary methodology
- clear labels for what is proved at the source / Core / proof-IR level versus
  what is trusted in extraction, runtime, FFI, backend, or target

Concrete should not become F*. The useful lesson is that effects and proof
boundaries must be designed together.

## From Cyclone

Copy lightly:

- practical checked subsets for low-level code
- an engineering attitude of making dangerous operations visible and boring

Concrete already has the stronger central mechanisms: capabilities, linear
ownership, trusted boundaries, and predictable-profile checks.

## From Idris / Agda

Copy carefully:

- proof/spec attachment should be expressive and direct when users choose it

Do not copy:

- a full dependent-type surface as the normal language
- proof-heavy source code as the default style

## Reduced Shortlist

The strongest new ideas to test are:

1. **SPARK-style contracts, loop invariants, and ghost code**
2. **Dafny-style proof usability and proof diagnostics**
3. **Why3-style proof-obligation artifacts and proof-session workflow**
4. **F*-style effectful-proof and extraction-boundary discipline**

## Rule

Do not add these because another verification system has them.

Add them only if they make Concrete's existing thesis easier to audit:

- authority is visible
- operational behavior is reportable / enforceable
- proof evidence attaches to extracted Concrete semantics
- trust assumptions stay explicit
