# The Standard Library

Concrete does not need a huge standard library. It needs a strong one.

The stdlib direction is:

- explicit about allocation
- explicit about ownership
- explicit about handles and resources
- bytes-first rather than string-first for low-level APIs
- coherent in naming and API shape
- small and sharp rather than broad

This is part of Concrete's safety and audit story. If the public stdlib hides authority, ownership, allocation, or cleanup, the language becomes harder to reason about even if the compiler internals are sound.

## Current Shape

Concrete already has a real stdlib foundation, including:

- `vec`, `string`, `io`
- `bytes`, `slice`, `text`, `path`
- `fs`, `env`, `process`, `net`
- `fmt`, `hash`, `rand`, `time`, `parse`
- `HashMap`, `HashSet`, `Deque`, `BinaryHeap`, `OrderedMap`, `OrderedSet`, `BitSet`

The goal is not breadth for its own sake. The goal is a low-level library surface that feels coherent across modules.

## Design Rules

The main stdlib rules are:

- keep effects visible in signatures
- keep pointer-level unsafety contained under `trusted fn` / `trusted impl`
- keep foreign boundaries explicit
- keep systems modules (`fs`, `net`, `process`, `env`, `time`) consistent in error and handle style
- prefer a few deeply-tested collections over a broad inconsistent zoo

## Where To Go Deeper

For the stable stdlib direction, read [`docs/STDLIB.md`](../../STDLIB.md).

That document covers:

- module direction
- collection priorities
- systems-module conventions
- error/handle/style rules
- what remains to deepen and harden
