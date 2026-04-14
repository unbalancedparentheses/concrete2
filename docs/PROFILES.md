# Profiles

Status: evolving reference

This document names the main Concrete profiles and explains what they mean for users.

Concrete is one language. Profiles are stricter, compiler-visible ways to use it.
They are not separate languages.

## Why Profiles Exist

Concrete is trying to support several kinds of trust claims at once:

- ordinary safe systems code
- bounded and predictable code
- proof-backed code
- later, stricter high-integrity code

Those should not blur together.
Profiles make the boundaries explicit.

## Current Profile Family

### Safe

This is the ordinary checked Concrete surface.

What it means:

- ownership and cleanup rules are enforced
- capability boundaries are visible in signatures
- `trusted` and `with(Unsafe)` remain explicit
- the current safe-memory guarantee applies within its documented boundary

What it does not mean:

- not all code is proof-backed
- not all code is predictable
- not all backend/runtime behavior is verified

References:

- [MEMORY_GUARANTEES.md](MEMORY_GUARANTEES.md)
- [GUARANTEE_STATEMENT.md](GUARANTEE_STATEMENT.md)

### Predictable

This is the restricted execution-oriented profile.

What it means today:

- the compiler can already report and check parts of predictable execution
- boundedness-related restrictions are becoming explicit
- this profile is aimed at code that should be easier to audit for execution shape

Typical restrictions/directions:

- no unrestricted allocation
- no recursion in selected checked paths
- no hidden blocking/host interaction in the selected subset
- clearer stack/failure-path boundaries

References:

- [../research/predictable-execution/predictable-execution.md](../research/predictable-execution/predictable-execution.md)
- [../research/predictable-execution/effect-taxonomy.md](../research/predictable-execution/effect-taxonomy.md)

### Provable

This is the proof-backed subset.

What it means:

- code is eligible for the current `Core -> ProofCore` extraction boundary
- proof claims are about the extracted proof model, not about the final binary
- proof artifacts, obligations, stale detection, and attached specs are part of the workflow

What it does not mean:

- not a proof of the whole compiler
- not a proof of backend correctness
- not a proof of all runtime behavior

References:

- [PROVABLE_SUBSET.md](PROVABLE_SUBSET.md)
- [PROOF_CONTRACT.md](PROOF_CONTRACT.md)
- [PROOF_SEMANTICS_BOUNDARY.md](PROOF_SEMANTICS_BOUNDARY.md)

### High-Integrity

This is the stricter long-term profile direction.

It is not the current default and it is not fully implemented today.

What it is for:

- code that must be easier to review, constrain, and eventually certify
- stricter authority, allocation, FFI, and failure-path discipline
- stronger evidence requirements at package and review boundaries

Likely shape:

- same language
- tighter restrictions
- profile-aware compiler checks
- profile-aware reports and package summaries

Reference:

- [../research/language/high-integrity-profile.md](../research/language/high-integrity-profile.md)

## Relationship Between Profiles

The intended shape is:

- `safe` is the broad checked surface
- `predictable` is a stricter execution-oriented surface
- `provable` is the proof-backed surface
- `high-integrity` is the stricter long-term synthesis of auditability, boundedness, and stronger evidence

These are related, but they are not synonyms.

In particular:

- predictable is not automatically proved
- proved is not automatically high-integrity
- safe is not automatically predictable

## Current Reality

Today, Concrete already has real pieces of:

- safe
- predictable-reporting / predictable-gated checks
- provable

High-integrity should be read as a named direction that Concrete is intentionally designing toward, not as a claim that the profile is already complete.

## Practical Rule

When talking about Concrete publicly:

- say which profile you mean
- say whether the claim is enforced, proved, reported, or trusted
- do not use “safe”, “predictable”, “proved”, and “high-integrity” interchangeably
