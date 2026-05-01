# Capability Polymorphism

**Status:** Open research direction
**Affects:** capability model, type system, stdlib design, higher-order functions, concurrency
**Date:** 2026-05-01

## Purpose

This note defines how higher-order code in Concrete should remain usable when callbacks have arbitrary capability requirements. Without an answer here, the standard library either bans higher-order code or duplicates every combinator across capability sets.

This is a prerequisite for the structured concurrency direction in [async-concurrency-evidence.md](../stdlib-runtime/async-concurrency-evidence.md). Scope methods like `s.spawn(f, ...)` and combinators like `iter.map(f)` need a single signature that works whether `f` is pure, does I/O, spawns tasks, or holds `with(Concurrent)`.

## The Problem

A simple `map` looks like:

```con
fn map<T, U>(xs: List<T>, f: fn(T) -> U) -> List<U>
```

This signature only accepts pure callbacks. The moment a user wants to map a function that prints, allocates, or reads a file, the signature is wrong. The naive workaround is to duplicate the combinator:

```con
fn map<T, U>(xs: List<T>, f: fn(T) -> U) -> List<U>
fn map_io<T, U>(xs: List<T>, f: fn(T) with(File) -> U) with(File) -> List<U>
fn map_async<T, U>(xs: List<T>, f: fn(T) with(Async) -> U) with(Async) -> List<U>
```

This explodes combinatorially as the capability lattice grows. Every user-defined combinator has the same problem. The result is either a tiny stdlib that refuses higher-order use, or a sprawling stdlib that bakes capability assumptions into every API.

Capability polymorphism is the way out: let `map` carry whatever its callback carries, no more and no less.

## Core Idea

Add a type-parameter form for capability sets. A function can be generic in the capability set it requires.

Sketch:

```con
fn map<T, U, C>(xs: List<T>, f: fn(T) with(C) -> U) with(C) -> List<U>
```

Reading: `map` requires whatever capability set `C` its callback `f` requires. If `f` is pure, `C` is empty and `map` is pure. If `f` requires `with(File)`, `map` requires `with(File)`. If `f` requires `with(Async, File)`, `map` requires `with(Async, File)`.

The capability set `C` is a *type-level* value. Concrete already has the elaboration machinery for type parameters; this extends it to capability sets.

## Capability Set Operators

A working polymorphic system needs at least three operators on capability sets:

1. **Singleton:** `{File}` is a capability set containing one element.
2. **Union:** `C1 ∪ C2` is the smallest capability set containing both. Useful for composition: a function that calls two callbacks with capability sets `C1` and `C2` requires `C1 ∪ C2`.
3. **Subset:** `C1 ⊆ C2` is the rule that `with(C2)` may call code requiring `with(C1)`.

The capability lattice already has subsumption rules (`Concurrent` implies `Async`, `Std` implies most platform capabilities). Polymorphism builds on those: a generic signature `with(C)` is satisfiable by any caller that holds a superset of `C`.

## Subtyping Rules

The lattice has built-in implications:

- `Concurrent` implies `Async`.
- `Std` implies the platform capabilities included in `Std`.
- Resource-bounded capabilities tighten by intersection: `Heap(64K)` implies `Heap(N)` for any `N >= 64K`.

These should compose with polymorphism cleanly. A function declared `with(Async)` is callable from a `with(Concurrent)` context because `{Concurrent} ⊇ {Async}` (after lattice expansion).

The checker needs to expand capability sets through the lattice before comparing them. This is the same kind of subtype check Concrete already performs, applied to capability sets instead of types.

## Inference

Most capability-polymorphic uses should not require explicit annotations.

Inference rules:

1. If a function calls a callback with capability set `C`, the function's required capability set includes `C`.
2. If a function calls multiple callbacks, the required set is the union.
3. The function's declared capability set must be a superset of the inferred set.

For library authors, this means the polymorphic parameter `C` is usually elidable in higher-order signatures. A practical surface might allow:

```con
fn map<T, U>(xs: List<T>, f: fn(T) -> U) with(f) -> List<U>
```

Where `with(f)` reads as "with whatever capabilities `f` requires." This is a notational shortcut for the explicit `<C>` form. It mirrors how Effekt and Koka handle effect-polymorphic signatures.

## Bounds On Capability Sets

Some combinators want to *constrain* the capability set rather than just propagate it. Examples:

- A pure `map` that rejects callbacks with side effects: `with(C) where C ⊆ {}`.
- A spawn combinator that requires the callback to be safe to run on another task: `with(C) where C ⊆ {Async, File, Net, ...}` — explicitly excluding `Concurrent` because the spawned task might run sequentially.
- A bounded-resource combinator that rejects callbacks whose resource bounds exceed a budget.

Bounds on capability sets are the analog of trait bounds in Rust generics. The syntax should make them visible without being noisy. A possible form:

```con
fn map_pure<T, U>(xs: List<T>, f: fn(T) -> U) where caps(f) ⊆ {} -> List<U>
```

This is more research than the basic propagation case. The basic case should ship first.

## Interaction With Concurrency

The structured concurrency direction depends on capability polymorphism. Specifically:

```con
s.spawn<F, T, E, C>(f: F, args: ...) -> Handle<T, E>
    where F: fn(args) with(C) -> Result<T, E>,
          C ⊆ caps(s)
```

Reading: `s.spawn` accepts a callback with any capability set `C` that is a subset of the scope's capability set. A scope opened with `with(Async)` accepts callbacks with `with(Async)` or weaker; a scope opened with `with(Concurrent)` accepts everything `Async` accepts plus `Concurrent`-requiring callbacks.

Without this rule, `spawn` either accepts only pure functions or hard-codes a fixed capability set. Neither is acceptable for a real stdlib.

## Interaction With Linear Types

Capabilities are not linear in the value-uniqueness sense. They are static type-level annotations on functions, not runtime tokens. A function declared `with(File)` does not consume a `File` token; it requires that the calling context holds the `File` capability authority.

This matters because polymorphic capability sets compose through type checking, not through ownership transfer. A combinator can be polymorphic in capabilities without affecting the linearity of the values it manipulates.

The two systems are independent. Capabilities track *what authority* is required; linearity tracks *what values* must be consumed.

## Effects Versus Capabilities

Concrete's capability system is closer to second-class capabilities (Effekt) than to first-class algebraic effects (Koka). Capabilities are statically required permissions, not user-handleable effects.

This note does not propose adding effect handlers. Capability polymorphism is enough to solve the higher-order combinator problem. Algebraic effects would be a much larger commitment with a different audit story, and the simpler capability model fits Concrete's evidence-bearing direction better.

If effect handlers are ever added, they should be a separate construct on top of capabilities, not a replacement for them.

## What Concrete Should Ship First

A minimal polymorphism feature set:

1. Capability-set type parameters in function signatures.
2. Inference of required capability set from callback uses.
3. Capability-set elision shortcut (`with(f)` or equivalent) for the common case.
4. Subtype check on capability sets that respects the lattice.
5. Compiler error messages that explain capability mismatch in terms of the lattice (`with(File)` required by `f`, not held by caller).

This is enough to write a usable higher-order stdlib without combinatorial duplication.

What can wait:

1. Bounds on capability sets (`where C ⊆ {...}`).
2. Capability-set difference / subtraction.
3. First-class capability values at runtime.
4. Effect handlers.

## Prior Art

- **Effekt** (Brachthäuser et al.) treats capabilities as second-class with lexical scoping. Function signatures carry an effect set; effect polymorphism is the default. This is the closest theoretical match for Concrete's capability model.
- **Koka** (Daan Leijen / Microsoft Research) has row-polymorphic effects with full algebraic-effect machinery. More expressive than Concrete needs, and the polymorphism story is mature.
- **Frank** (Lindley / McBride / Hammond) has effect polymorphism via "effect ability." Smaller surface than Koka, more research-oriented.
- **Roc** has abilities and is exploring capability propagation through generic code.

Concrete should study how these languages handle inference and error messages, because those are where effect-polymorphic systems most often fail in practice. A capability-polymorphic stdlib that produces unintelligible type errors when callers misalign is worse than one that requires explicit annotations.

## What Not To Add

- No first-class capability values at the term level. Capabilities should remain static signatures, not values that flow through the program. First-class capabilities are a different language with a different audit story.
- No row-polymorphic effects in the Koka style. The expressiveness gain is real but the syntax cost and elaboration complexity are also real, and the simpler set-polymorphic story is enough for stdlib use cases.
- No implicit capability widening. A `with(File)` function is not silently promoted to `with(File, Net)`. Widening is always explicit at the call site or via subsumption through the lattice.
- No capability subtraction in the user-facing surface. `C1 - C2` adds checker complexity and rarely answers a question users actually have.

## What Compiler Reports Should Show

For each higher-order signature, the compiler should be able to report:

1. The declared capability set (with type parameters expanded).
2. The inferred capability set from the function body.
3. Whether the inferred set matches the declared set (mismatch is an error).
4. For each call site, the capability set required at that site after substitution.

This connects capability polymorphism to the broader evidence story: a function's effect surface is a reportable fact, not a hidden implementation detail.

## One-Line Test

A capability-polymorphic feature is good if writing a higher-order combinator requires no more annotation than writing the same combinator in a non-polymorphic language, while the call-site capability set is still computed correctly and reported.

## Relationship To Other Notes

- [../stdlib-runtime/async-concurrency-evidence.md](../stdlib-runtime/async-concurrency-evidence.md) — depends on this for scope/spawn signatures
- [../stdlib-runtime/concurrency.md](../stdlib-runtime/concurrency.md) — near-term threads-first plan; capability polymorphism is needed before the long-term direction
- [../stdlib-runtime/stdlib-design.md](../stdlib-runtime/stdlib-design.md) — stdlib shape; this note constrains it
- [no-trait-objects.md](no-trait-objects.md) — related decision about higher-order machinery
- [../stdlib-runtime/iterators.md](../stdlib-runtime/iterators.md) — iterators are the canonical higher-order combinator surface
