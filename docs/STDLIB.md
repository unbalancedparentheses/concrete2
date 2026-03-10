# Standard Library Direction

Status: provisional reference

This document captures the current stable direction for the standard library.

For the exploratory design notes behind it, see [../research/stdlib-design.md](../research/stdlib-design.md). For active priorities, see [../ROADMAP.md](../ROADMAP.md).

Use this file for the stable direction.
Use [../research/stdlib-design.md](../research/stdlib-design.md) for the broader exploratory comparisons, language borrowings, and future-facing design space.
If this file and the research note ever differ, treat this file as the stable project direction and the research note as exploratory background.

## Design Rules

The Concrete stdlib should stay:

- explicit about allocation
- explicit about ownership
- explicit about handles/resources
- small and sharp rather than broad
- neutral about the eventual concurrency/runtime model unless a dependency is unavoidable

It should avoid:

- lazy resource-hiding APIs
- a giant iterator/future ecosystem
- hidden allocation
- overly broad collection sprawl before the fundamentals are solid

## Foundation First

The first wave of stdlib foundation work has started to land:

- `vec`, `string`, and `io` have had real correctness/completeness work
- `bytes`, `slice`, `text`, `path`, and `fs` now exist

The next stdlib work should build on that foundation instead of restarting it.

## Current Foundation Status

Implemented or substantially started:

1. stronger `vec`, `string`, and `io`
2. `bytes`
3. `slice`
4. borrowed text views via `text`
5. `path`
6. first real `fs`

Still the main near-term stdlib work:

1. strengthen `fs`
2. add `env` / `process`
3. add `net`
4. add small `fmt`
5. improve `test`
6. then move to `time`, `rand`, `hash`, parsing, and carefully chosen collections

## Core Module Direction

### `std.bytes`

Owned byte buffer type for:

- file I/O
- network I/O
- parsing
- formatting

### `std.slice`

Borrowed contiguous views:

- immutable slice
- mutable slice
- explicit pointer + length semantics

### `std.text`

Separate borrowed text views from owned `String`.

### `std.path`

Paths deserve their own module and types:

- borrowed path view
- owned path buffer
- path manipulation without hidden filesystem effects

### `std.fs`

Handle-oriented file APIs:

- owned file handles
- borrowed handle/view types where needed
- no raw fd-like integers in safe-facing APIs

The first version now exists, but it should still deepen in:

- clearer typed error surfaces
- more complete byte-oriented read/write helpers
- stronger path integration
- later process/environment interplay

### `std.net`

Next major systems layer after the current foundation:

- owned socket/listener/stream handles
- explicit buffer-based read/write
- no hidden runtime coupling

## Error and Handle Design

Stdlib APIs should prefer:

- small enum error types per module
- no opaque integer-like error codes in safe-facing APIs
- explicit owned handle types
- borrowed handle/view types only where they clearly help

## Allocation Policy

Allocator-sensitive APIs should make allocation visible:

- via allocator/capability-aware APIs
- via `with(Alloc)` when allocation occurs
- via return types that make ownership obvious

## Later Additions

After the foundation is solid, the likely next additions are:

- `std.time`
- `std.rand`
- `std.hash`
- `std.collections.map`
- `std.collections.set`
- a small eager `std.iter` if it earns its place
- later `std.sync`
- later `std.ffi`
- later `std.parse`

## Current Position

This is not trying to imitate Rust’s breadth.

The goal is a stdlib that is:

- low-level enough for systems work
- explicit enough for auditability
- small enough to stay coherent

The current state is no longer just a plan. A first useful low-level foundation is in place, and the next work is to deepen the systems layer without losing explicitness.
