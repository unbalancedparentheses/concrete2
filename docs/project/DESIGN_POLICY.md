# Design Policy

Status: standing policy

This document defines the admission criteria for language features, compiler features, and borrowed ideas. It is the gate that every proposed change must pass through.

For recorded decisions (permanent "no" and deferred "not yet"), see [DECISIONS.md](DECISIONS.md).
For the language identity, see [IDENTITY.md](IDENTITY.md).
For the original research note, see [../research/meta/design-filters.md](../../research/meta/design-filters.md).

## Admission Principle

Concrete is not trying to maximize shorthand or track trends. The standard for admission is:

- preserves simplicity
- improves reliability
- fits the verification story
- keeps semantics explicit

If an idea improves ergonomics while making the compiler harder to explain, it is a bad fit.

## Feature Admission Checklist

Every proposed feature must pass all fifteen checks. Failing any one is grounds for rejection.

### 1. Can it be explained as a simple invariant?

If the rule needs many exceptions, fallback cases, or "except when..." clauses, reject it.

### 2. Does it make behavior more visible or less visible?

Prefer features that expose effects, ownership, dispatch, layout, or control flow. Reject features that hide work behind familiar syntax.

### 3. Does it reduce compiler phase coupling?

Prefer ideas that keep parse, resolve, check, and elab boundaries clean. Reject ideas that make early phases depend on later semantic information.

### 4. Are cross-file dependencies declaration-level only?

Prefer summaries, signatures, layouts, and explicit imports. Reject anything that makes one file depend on another file's bodies.

### 5. Is dispatch still statically known or explicitly indirect?

Prefer monomorphization, named functions, and explicit function pointers. Reject hidden dynamic dispatch, hidden captures, or broad implicit lookup.

### 6. Does it preserve predictable code generation?

The user should be able to form a rough mental model of runtime behavior from the source. If the compiler may insert surprising work, be very skeptical.

### 7. Does it improve diagnostics or make them murkier?

A good feature should have obvious ownership for error reporting. If failures become "somewhere in inference/magic," reject it.

### 8. Can the compiler own it with one clear pass?

Each rule should have an obvious home. If multiple passes must partially own it, that is a warning sign.

### 9. Does it help or hurt the proof story?

Prefer rules that elaborate into simpler core forms. Reject rules that require semantic duplication, hidden state, or many meta-level exceptions.

### 10. Is the benefit real for audited low-level code?

Concrete is not trying to maximize shorthand. If the gain is mainly convenience for writing code faster, that is not enough.

### 11. Can its meaningful behavior cross a contract boundary?

A feature must say how its safety, functional behavior, effects, failure modes,
and resource consequences appear in summaries and obligations. A feature that
works operationally but disappears from public contracts creates an
unverifiable island.

### 12. Can unsupported coverage fail visibly?

Every new construct must define its verification lowering, a conservative
abstraction, or a precise unsupported-fragment diagnostic. Silence is not an
admissible fallback. Policy may permit named holes, but it may not erase them.

### 13. Is its evidence represented as precisely as its claim?

A feature must define distinct typed identities for its subject, claim,
dependencies, artifacts, checker rules, and freshness where those concepts can
change independently. Interchangeable strings, optional authoritative fields,
first-match lookup, and display-derived status are rejection signals. Reports
project validated facts; they do not manufacture them.

### 14. Does it remain honest under hostile input and later revocation?

Proof modules, generated artifacts, dependency tables, receipts, package
bundles, and checker output are adversarial inputs. A feature must define
resource limits, malformed/duplicate/surplus behavior, negative controls,
mutation tests, and how a checker or assumption advisory degrades existing
claims without collapsing unaffected evidence dimensions.

### 15. Does it preserve independently changing semantic identities?

A verification feature must not collapse implementation, mathematical model,
exported contract, proposition, policy, relation kind, or claim scope merely
because two are currently derived together. It must state which identity moves
under each semantic change and which dependency consumers become stale.

Exact identity is not correspondence: a digest may prevent substitution while
saying nothing about whether a model faithfully represents the implementation.
Raw digest strings, display-name attachment, implicit equivalence, unlabelled
trust, and one status standing in for several independently degradable claims
are grounds for rejection.

Identity keys contain the subject of a fact, not alternative answers for that
fact. Relation strength and evidence mode are coherent payload: placing them in
the key so contradictory trusted/proved or refinement/equivalence rows can
coexist recreates first-match ambiguity. Silence creates a missing obligation,
never an assumption.

## Quick Decision Rule

**Adopt** ideas that are: explicit, local, phase-separated, summary-friendly, easy to lower away.

**Reject** ideas that are: implicit, global, inference-heavy, body-dependent, hard to model formally.

## One-Line Test

A feature is promising if it makes the compiler and the language easier to explain at the same time.

## Main Rule for Borrowed Ideas

**Copy constraints before copying features.**

Zig, Austral, SPARK, and Odin are often most useful because they say "no" in structurally helpful places. Concrete should borrow their disciplined constraints, not their convenience features.

## High-Leverage Priorities

The highest-leverage improvements for Concrete are:

1. Typed, compositional contracts
2. Exhaustive and fail-visible verification-coverage accounting
3. Core and the verification IR as semantic authorities
4. Independently replayable evidence artifacts and proof-aware interfaces
5. Typed evidence identities and separately degradable claim dimensions
6. Total contract-callable functions and source-level specification power
7. Declaration-isolated checking and non-vacuous assurance infrastructure
8. Summary-based frontend (declaration-level cross-file info)
9. ABI/layout subsystem clarity
10. Audit-focused tooling, explainability, and compiler outputs
11. Small but excellent standard library
12. Explicit project/build model
13. Proof-driven narrowing

These are high leverage because they improve compiler structure, user trust, auditability, proof tractability, and future tooling options simultaneously.

## Ordering Principle

- Architecture before ornament
- Tooling visibility before convenience syntax
- ABI/layout credibility before feature expansion
- Proof-friendly boundaries before richer abstractions
- Faithfulness and artifact replay alongside each graduated contract family

The [verification charter](../verification/VERIFICATION_CHARTER.md) defines the product-level
direction these admission rules protect.
The [evidence architecture](../verification/EVIDENCE_ARCHITECTURE.md) and
[Verification IR](../verification/VERIFICATION_IR.md) define the representation and semantic
boundaries these checks require.

Concrete gets stronger by becoming sharper, not merely bigger.
