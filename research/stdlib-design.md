# Standard Library Design Notes

This document records the direction for Concrete's standard library after the core compiler architecture work.

The standard library is not just "APIs we need eventually." It is one of the main ways the language proves that its design is viable for correctness-focused low-level work.

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

### `std.slice`

Borrowed contiguous views.

This should cover:

- immutable slice/span
- mutable slice/span
- explicit pointer + length semantics

### `std.text`

A borrowed text view separated from owned `String`.

`String` can remain the owned growable text/buffer type, but most APIs should not require ownership.

### `std.fs`

Real file-system APIs:

- owned file handle
- borrowed file view where useful
- explicit read/write APIs over buffers
- later: path/path-buffer split

### `std.net`

A real networking layer over the existing builtins:

- owned socket/stream/listener handles
- explicit buffer-oriented I/O
- no raw unsafe integer/socket APIs in safe-facing surfaces

### `std.fmt`

A small explicit formatting layer.

Not macro-heavy formatting. Not hidden allocation.

### Later: `std.collections.multi_array`

Only after the basic containers are solid.

This is where a Zig-inspired data-oriented collection could fit.

## What To Avoid

Concrete should not let the stdlib smuggle in abstractions that the language itself rejects.

Avoid:

- trait-heavy iterator ecosystems
- lazy resource streams
- hidden allocation
- hidden dispatch
- interior-mutability-style escape hatches in the stdlib
- generic “convenience APIs” that obscure ownership/effects

## Recommended Build Order

1. Make `vec`, `string`, and `io` correct and complete.
2. Add `bytes` / buffer as the core low-level owned container.
3. Add borrowed views for slices and strings.
4. Build real file/path/process/env modules.
5. Wrap networking builtins in a proper stdlib layer.
6. Add formatting helpers and stronger test support.
7. Expand collections only after the core is solid.

## Long-Term Goal

The standard library should make Concrete usable for real low-level programs without betraying the language’s core promise:

code should stay explicit, auditable, and mechanically understandable.
