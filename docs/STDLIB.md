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

The most important stdlib work is still the core:

1. make `vec`, `string`, and `io` trustworthy
2. add `bytes`
3. add `slice`
4. add borrowed text views
5. add `path`
6. strengthen `fs`
7. strengthen `env` / `process`
8. add `net`
9. add small `fmt`
10. improve `test`

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

### `std.net`

Only after the buffer/slice/handle story is stable:

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
