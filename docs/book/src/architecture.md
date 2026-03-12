# Architecture

Concrete's compiler pipeline is intentionally explicit:

```text
Source -> Parse -> Resolve -> Check -> Elab -> CoreCanonicalize -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA -> clang
```

The important part is not only that these passes exist. It is that each pass has a clear boundary:

- parsing owns syntax
- resolution owns name binding
- checking owns the remaining surface-sensitive semantic work
- elaboration ends the surface language
- CoreCheck is the main post-elaboration semantic authority
- lowering produces the backend-oriented SSA program
- SSA verification and cleanup define the backend contract

## Why The Architecture Matters

Concrete is trying to become a language where:

- semantics stay explicit
- compiler magic stays narrow
- backend work does not re-decide language meaning
- proofs, reports, and tooling can all build on the same boundaries

That is why the project cares so much about Core, SSA, verifier boundaries, and removing raw string-based semantic dispatch.

## Current Direction

Recent architectural themes include:

- replacing semantic raw-name handling with typed identities
- hardening lowering around mutable aggregate storage and merge points
- expanding direct testing of reports, SSA shape, and optimized builds
- keeping the backend boundary explicit and inspectable

## Where To Go Deeper

Read the stable architecture references:

- [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md)
- [`docs/PASSES.md`](../../PASSES.md)
- [`docs/LANGUAGE_INVARIANTS.md`](../../LANGUAGE_INVARIANTS.md)
- [`docs/VALUE_MODEL.md`](../../VALUE_MODEL.md)
