# Standard Library Design Notes

This document records the direction for Concrete's standard library after the core compiler architecture work.

The standard library is not just "APIs we need eventually." It is one of the main ways the language proves that its design is viable for correctness-focused low-level work.

## Design Rules

The stdlib should follow a small number of hard rules:

1. Allocation must be visible.
If an API allocates, that fact should be visible in the signature, capability set, or returned ownership shape.

2. Ownership must be obvious.
Owned resources, borrowed views, and transferred values should be easy to distinguish from the type alone.

3. Effects must stay explicit.
I/O, environment access, process control, networking, and time should not be hidden behind “convenience” wrappers.

4. Resource-backed APIs should avoid laziness.
The stdlib should not hide evaluation order, blocking, cleanup, or resource lifetime behind lazy streams or iterator pipelines.

5. Safe-facing APIs should prefer typed structure over ambient convention.
Use small types and explicit enums, not sentinel values, magic integers, or “just know the convention” APIs.

6. The stdlib should avoid baking in a runtime model too early.
Concurrency/runtime design should be handled by the separate concurrency research track.

## Current Situation

The `std/` tree exists, but it is still early:

- `vec`
- `string`
- `io`
- `alloc`
- `mem`
- `ptr`
- `option`
- `result`
- `math`
- `test`
- `libc`

This is a useful base, but not yet a mature standard library.

Several current modules are still incomplete or need correctness work:

- `vec`
- `string`
- `io`

Before adding a lot more surface area, those modules need to become trustworthy.

## What The Stdlib Needs First

The next milestone should not be "more modules everywhere." It should be "a coherent low-level foundation."

### 1. Make the current core modules solid

First priority:

- `vec`
- `string`
- `io`

They should stop feeling like prototypes and start feeling like stable low-level building blocks.

### 2. Add an owned byte buffer type

Concrete needs an owned byte-oriented buffer more than it needs richer high-level string APIs.

This should become the foundation for:

- file I/O
- network I/O
- parsing
- binary protocols
- formatting

### 3. Add borrowed views

Concrete should have explicit non-owning views, such as:

- slice/span-like views over contiguous memory
- borrowed string/text views

These fit the language well because they preserve explicit ownership while still making low-level APIs practical.

### 4. Build real file/process/env/path modules

The stdlib should eventually expose coherent modules for:

- file open/read/write/flush/seek
- paths and owned path buffers
- environment access
- process arguments and process control

These should become the foundation for “real program” boundaries:

- files and directories
- path handling
- process spawning and exit
- environment access
- later, time and networking surfaces

### 5. Wrap networking builtins in a real stdlib layer

The builtins exist, but they still need a higher-level stdlib surface that is explicit without being raw.

### 6. Improve formatting and testing support

Concrete should have:

- a small explicit formatting layer
- stronger stdlib test helpers

### 7. Grow collections carefully

After `vec` is solid, then expand collections further.

The stdlib should prefer:

- explicit allocation
- explicit ownership
- eager operations

It should avoid hidden control flow or trait-heavy abstraction layers.

## Best Ideas To Borrow

Concrete should borrow ideas selectively. The right question is not "what is popular?" but "what strengthens Concrete without betraying its design?"

### From Rust

Useful ideas:

- `Result` / `Option`-centric API design
- borrowed views like slices and string views
- path/path-buffer separation
- `OwnedFd` / `BorrowedFd` style handle ownership
- `BorrowedBuf` / `BorrowedCursor` style explicit buffered I/O APIs

Why these fit:

- they keep ownership visible
- they make I/O and handles safer without hiding the machine
- they map well onto Concrete's ownership/capability story

What not to copy:

- heavy iterator-combinator ecosystems
- trait-driven APIs that hide dispatch

### From Zig

Useful ideas:

- allocator-explicit library design
- direct, practical low-level APIs
- stdlib as a systems interface rather than a convenience layer
- `MultiArrayList` as a future data-oriented collection idea

Why these fit:

- allocator-explicit design is one of the strongest matches for Concrete
- Zig’s stdlib discipline is close to Concrete’s intended culture

### From Go

Useful ideas:

- clear, boring standard-library API surfaces
- straightforward file/network/process packages
- practical interfaces for common systems tasks without abstraction theatrics

Why these fit:

- Go is a good reminder that low-level-adjacent APIs benefit from clarity more than cleverness
- Concrete should learn from Go’s readability and packaging discipline without copying its semantics or weak type/resource model

What not to copy:

- implicit nil-heavy API patterns
- concurrency assumptions leaking into too much of the library surface

### From Swift

Useful ideas:

- clear value-oriented API surfaces
- strong separation between owned values and borrowed/temporary views where performance matters
- practical systems-facing libraries with explicit handle/resource types

Why these fit:

- Swift is a useful reference for keeping APIs readable while still being serious about systems boundaries
- it is a reminder that low-level-facing libraries do not need to become unreadable to stay powerful

What not to copy:

- runtime assumptions that are too tied to Swift’s broader execution model

### From Gleam

Useful ideas:

- standard-library readability
- consistent API shape
- preference for a small, coherent surface over a sprawling one

Why these fit:

- Gleam is a useful counterexample to “serious language means sprawling stdlib surface”
- Concrete should preserve this bias toward coherence and readability even while targeting lower-level work

### From Odin

Useful ideas:

- low-level OS/file APIs with explicit allocators where allocation occurs
- typed error returns instead of vague sentinel-style failure signaling
- explicit resource-handle types instead of raw integer-ish handles in safe-facing APIs

Illustrative API shape from Odin's `core:os` direction:

```odin
data, err := os.read_entire_file(path, context.allocator)
if err != os.Error.None {
    // handle error
}

file, err := os.open(path)
if err != os.Error.None {
    // handle error
}
```

Why these fit:

- allocation stays visible in the API shape
- ownership of returned resources is obvious
- error handling stays explicit and typed
- low-level APIs stay practical without becoming implicit or magical

Concrete should copy the API-shape lesson, not the exact syntax: stdlib modules should make allocation, ownership, and failure modes obvious from signatures and types.

Reference:

- [Moving Towards a New `core:os`](https://odin-lang.org/news/moving-towards-a-new-core-os/)

### From C++

Useful ideas:

- `span` as a non-owning contiguous view
- `string_view` as a non-owning text view

Only the concepts are useful. Concrete should avoid C++-style complexity and customization machinery.

### From Clojure

Useful ideas:

- transducers as a separation between transformation logic and concrete collection representation

This is interesting for Concrete only if kept:

- eager
- explicit
- free of hidden control flow

Concrete should not import lazy sequence semantics here.

### From Elixir

Useful ideas:

- clear separation between eager collection APIs and streaming/resource-backed APIs

What not to copy:

- lazy stream semantics that hide evaluation or resource timing

### From newer research

Useful ideas to study:

- `GhostCell` as a research direction for permission-separated shared mutable structures

This is not a near-term stdlib feature. It is useful mainly as a design reference for future advanced data structures.

## What Concrete Should Add

If the above is translated into Concrete-specific stdlib work, the best next modules are:

### `std.bytes`

An owned byte buffer type.

This should support:

- append
- reserve
- clear
- split
- slice

This becomes the foundation for low-level text and binary work.

This should probably be the first major new stdlib type after `vec`/`string`/`io` are corrected.

### `std.slice`

Borrowed contiguous views.

This should cover:

- immutable slice/span
- mutable slice/span
- explicit pointer + length semantics

This is one of the most important non-owning abstractions in the whole stdlib.

### `std.text`

A borrowed text view separated from owned `String`.

`String` can remain the owned growable text/buffer type, but most APIs should not require ownership.

This is how Concrete avoids turning every text API into an allocation API.

### `std.fs`

Real file-system APIs:

- owned file handle
- borrowed file view where useful
- explicit read/write APIs over buffers
- later: path/path-buffer split

`std.fs` should feel like a small explicit systems interface, not a convenience façade.

### `std.path`

Paths deserve their own module rather than being treated as a detail of `fs`.

Concrete should eventually have:

- borrowed path views
- owned path buffers
- normalization/join/split helpers that stay explicit and allocation-visible

Path handling is a foundational low-level concern and should not be hidden inside unrelated file APIs.

### `std.net`

A real networking layer over the existing builtins:

- owned socket/stream/listener handles
- explicit buffer-oriented I/O
- no raw unsafe integer/socket APIs in safe-facing surfaces

Networking should follow the same ownership and effect rules as files:

- explicit handles
- explicit buffer use
- no hidden runtime commitments

### `std.fmt`

A small explicit formatting layer.

Not macro-heavy formatting. Not hidden allocation.

Formatting should be useful enough for diagnostics and tools, but not become a second string-magic subsystem.

### Later: `std.collections.multi_array`

Only after the basic containers are solid.

This is where a Zig-inspired data-oriented collection could fit.

## High-Value Later Additions

After the core foundation is solid, Concrete should add only a few more modules, carefully.

### `std.time`

Useful for:

- clocks
- durations
- timestamps
- sleeping/timers later, but only once the runtime story is clearer

### `std.rand`

Only if kept explicit and capability-gated.

Useful for practical systems work, but it should not become ambient magic.

### `std.hash`

Useful for:

- hashing APIs
- map/set internals
- checksums and digests later

### `std.collections.map`

Once `Vec`, `bytes`, and borrowed views are solid, a real map API becomes worthwhile.

Concrete should still keep the collection surface small.

### `std.collections.set`

Only after `map` is solid, and probably built on top of it.

### `std.iter` (or equivalent), very carefully

Not a trait-heavy iterator universe.

If anything like this is added, it should stay:

- small
- explicit
- eager

### `std.sync`

Much later, and only once the concurrency design is clearer.

This should not be added casually.

### `std.ffi`

A small module for explicit FFI-facing helpers and safer wrappers around low-level interop patterns.

### `std.layout`

Potentially useful for exposing layout/size/alignment information in a principled way if the language wants a stdlib-facing low-level reflection surface.

### `std.parse`

Only after `bytes`, `text`, and `fmt` are in good shape.

Useful for:

- integer parsing
- float parsing
- path/text parsing helpers
- other small explicit parsers

## Low-Level Spine Concrete Still Needs

Looking across Rust, Zig, Odin, Go, Swift, and related systems-oriented languages, the core missing low-level spine is fairly clear.

Concrete does not need Rust’s breadth, but it does need a strong low-level foundation in these areas:

1. **Bytes**
An owned byte buffer is the most important missing foundational type.

2. **Slices / spans**
Non-owning contiguous views are essential for low-level APIs.

3. **Borrowed text views**
Owned `String` is not enough. Borrowed text needs its own type.

4. **Path types**
Path handling should be explicit and not hidden inside `fs`.

5. **Real `fs` / `env` / `process` APIs**
These are core systems boundaries, not optional extras.

6. **Networking**
A real stdlib networking layer over the current builtins is necessary for serious systems use.

7. **Time**
Durations, clocks, timestamps, and later timer-related APIs are basic low-level requirements.

8. **Allocator-visible containers**
Concrete should stay disciplined here and make allocation visible in collection growth and owned-buffer APIs.

9. **Formatting and parsing**
These should be explicit, buffer-oriented, and small.

10. **Owned handle types**
Files, sockets, listeners, and later subprocess handles should not be raw low-level integers in safe APIs.

This is the real stdlib foundation Concrete needs before it should worry about broader convenience layers.

## What To Avoid

Concrete should not let the stdlib smuggle in abstractions that the language itself rejects.

Avoid:

- trait-heavy iterator ecosystems
- lazy resource streams
- hidden allocation
- hidden dispatch
- interior-mutability-style escape hatches in the stdlib
- generic “convenience APIs” that obscure ownership/effects

Also avoid standardizing too early:

- a giant iterator ecosystem
- lazy stream APIs over resources
- a large collection zoo before `bytes`, `slice`, `fs`, and `net` are solid
- runtime-coupled APIs whose shape only makes sense under one concurrency model
- future/promise ecosystems
- too many string-heavy utilities before `bytes`, `slice`, and `text` are solid

## Candidate Module Map

This is a plausible medium-term stdlib shape:

- `std.alloc`
- `std.mem`
- `std.ptr`
- `std.bytes`
- `std.slice`
- `std.text`
- `std.string`
- `std.vec`
- `std.option`
- `std.result`
- `std.fs`
- `std.path`
- `std.env`
- `std.process`
- `std.net`
- `std.fmt`
- `std.test`
- `std.math`
- `std.libc`

Not all of these should be expanded immediately, but this is a better target shape than continuing to grow the current tree ad hoc.

## Error Design

Safe-facing stdlib APIs should prefer:

- small enum error types per module
- explicit typed failure in signatures
- no opaque integer-ish error codes in safe APIs

Low-level bindings may still expose raw platform error values where necessary, but the safe stdlib surface should translate them into explicit error types.

As a rule:

- thin low-level bindings may expose platform-shaped results
- safe-facing stdlib modules should wrap them in typed errors and explicit resource types

## Handle Ownership

For `fs`, `net`, and later process/runtime-facing modules, the stdlib should make handle ownership explicit:

- owned handle types for resources that must be closed/destroyed
- borrowed handle/view types where temporary non-owning access is useful
- no raw fd/socket integers in safe APIs

This is one of the highest-value ways to make the stdlib align with Concrete’s ownership model.

The default should be:

- owned handle at module boundaries
- borrowed handle when temporary access is enough
- raw handle only in explicitly low-level/unsafe layers

## Allocator Policy

Allocator-explicit design is a good fit for Concrete, but the stdlib should make the rule clear.

In general:

- APIs that allocate should make allocation visible in the signature
- owned buffers/collections should clearly indicate when `Alloc` is required
- APIs should either take allocator/runtime authority explicitly or require `with(Alloc)` in a way that is easy to audit

The exact mechanism can vary by module, but the stdlib should never hide allocation behind “convenience” calls.

In practice this likely means:

- `bytes`, `string`, and collection growth are allocator-visible
- whole-file/whole-buffer helpers remain explicit that they allocate
- path/process/network helpers should not smuggle allocation into “simple” calls without making it visible

## Runtime Boundary Note

The stdlib should avoid assuming one ambient runtime model too early.

In practice this means:

- keep blocking behavior explicit in APIs
- avoid forcing “async everywhere”
- avoid shaping `fs`, `net`, and process modules around one runtime convention before the concurrency design is settled

The actual concurrency/runtime direction belongs in [`research/concurrency.md`](concurrency.md), not in the stdlib plan.

## Recommended Build Order

1. Make `vec`, `string`, and `io` correct and complete.
2. Add `bytes` / buffer as the core low-level owned container.
3. Add borrowed views for slices and strings.
4. Add `std.path`.
5. Build real file/process/env modules around explicit handles and typed errors.
6. Wrap networking builtins in a proper stdlib layer.
7. Add `std.time`.
8. Add formatting helpers and stronger test support.
9. Add parsing helpers once `bytes`, `text`, and `fmt` are solid.
10. Expand collections only after the core is solid.

## Adoption Filter

A stdlib idea is a good fit for Concrete if it:

- makes allocation more visible, not less
- makes ownership easier to read from types
- improves low-level correctness without adding hidden control flow
- stays compatible with explicit effects/capabilities
- can be explained without a large abstraction tower

A stdlib idea is a poor fit if it:

- hides resource lifetime
- assumes a runtime model everywhere
- depends on heavy trait/generic indirection for ordinary use
- turns simple data movement into “clever” code

## Later Summary

Beyond the core foundation, the best additions are probably:

- `std.time`
- `std.rand`
- `std.hash`
- `std.collections.map`
- `std.collections.set`
- maybe a small `std.parse`
- later `std.sync`
- later `std.ffi` helpers

The important point is that Concrete’s stdlib should stay small and sharp.
It does not need to imitate Rust’s breadth.

## Long-Term Goal

The standard library should make Concrete usable for real low-level programs without betraying the language’s core promise:

code should stay explicit, auditable, and mechanically understandable.
