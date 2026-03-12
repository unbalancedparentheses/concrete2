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
- bytes-first rather than string-first for low-level APIs
- coherent in naming and verb choice across modules
- small and sharp rather than broad
- neutral about the eventual concurrency/runtime model unless a dependency is unavoidable

For low-level internals, the split is now:

- semantic effects remain visible in public signatures (`with(Alloc)`, `with(File)`, etc.)
- pointer-level implementation unsafety is contained by `trusted fn` / `trusted impl`
- foreign boundaries (`extern fn`) remain under `with(Unsafe)` even inside trusted code

See [../research/trusted-boundary.md](../research/trusted-boundary.md).

It should avoid:

- lazy resource-hiding APIs
- a giant iterator/future ecosystem
- hidden allocation
- overly broad collection sprawl before the fundamentals are solid
- builtin/runtime-hook names leaking directly into the public API surface

Public stdlib APIs should also be simpler and clearer than the builtin/runtime machinery they wrap. The stdlib is part of Concrete's safety story: if the public surface is confusing, ownership-hiding, or effect-blurring, the language becomes harder to audit even if the compiler internals are sound.

## What Would Make It Excellent

The stdlib does not need to become huge to become dramatically better. The biggest gains come from making it:

- more coherent
- more explicit
- more ownership-honest
- more audit-friendly

The core principles are:

1. **Bytes first, not String first.**
   `Bytes`, `Slice`, `Text`, and `Path` should remain the center of low-level I/O, parsing, formatting, and networking.

2. **One public vocabulary everywhere.**
   The same verbs and API shapes should recur across modules:
   - `open`, `create`, `read`, `write`, `write_all`, `close`
   - `get`, `get_unchecked`
   - `set`, `set_unchecked`
   - `insert`, `remove`, `contains`, `len`, `is_empty`

3. **Builtins stay minimal and ugly; stdlib stays clean.**
   Compiler/runtime hooks can be low-level and implementation-shaped. The user-facing stdlib should wrap them in coherent, typed APIs.

4. **Effects and trust stay visible.**
   The best stdlib for Concrete is one where it is easy to answer:
   - does this allocate?
   - does this block?
   - does this require `Unsafe`?
   - does this rely on `trusted` internally?
   - what capability does it need?

5. **Systems modules should feel like one family.**
   `fs`, `net`, `process`, `env`, and `time` should share the same approach to typed errors, handles, cleanup, and capability visibility.

6. **Collections should be few but excellent.**
   It is better to have a small number of deeply-tested, explicit, low-level collections than a broad and inconsistent collection zoo.

## Foundation First

The first wave of stdlib foundation work has landed:

- `vec`, `string`, and `io` have had real correctness/completeness work
- `bytes`, `slice`, `text`, `path`, and `fs` now exist
- `env`, `process`, and `net` are implemented

The next stdlib work should build on that foundation instead of restarting it.
The trust/effect coherence pass is now in place:

- builtins, stdlib, and user code follow one explicit trust/effect model
- `Alloc`, `File`, `Network`, `Process`, etc. stay visible in public signatures
- `trusted` is used only for internal pointer-level implementation techniques
- `extern fn` calls stay under `with(Unsafe)` even inside trusted code

## Current Foundation Status

Implemented:

1. stronger `vec`, `string`, and `io` — done
2. `bytes` — done
3. `slice` — done
4. borrowed text views via `text` — done
5. `path` — done
6. first real `fs` — done
7. `env` and `process` — done
8. `net` (TCP) — done

Typed error hardening is now in place across `fs`, `net`, `env`, and `bytes`.

The stdlib deepening arc is now underway. `fmt`, `hash`, `rand`, and `time` are implemented. `io` has been hardened with typed error returns.

Still the main near-term stdlib work:

1. deepen `fs`, `net`, and `process`
2. keep error and handle conventions uniform
3. expand failure-path and integration testing
4. carefully chosen collections
5. keep pushing deeper systems-module polish and stronger integration coverage

## Collection Priorities

The current collection spine is:

- `Vec`
- `HashMap`
- `HashSet`

The next collection work should stay narrow and low-level.

Highest-priority additions after the current core:

1. **Deque / ring buffer**
   Useful for queues, schedulers, buffering, and general systems work.

2. **Priority queue**
   Important for schedulers, search algorithms, and event-driven systems.

3. **Ordered map / ordered set**
   Tree-based containers for deterministic iteration and range-based access.

4. **Bitset / bit array**
   Useful for flags, dataflow, graph/search algorithms, and compiler-style workloads.

Useful later, but not early priorities:

- fixed-capacity vectors/lists
- arenas / slabs / slot maps
- small inline-buffer collections

The rule is: add collections only when they improve low-level work materially, and keep their ownership, allocation, and error behavior as explicit as `Vec` and `HashMap`.

## Core Module Direction

### `std.bytes`

Owned byte buffer type for:

- file I/O
- network I/O
- parsing
- formatting

Accessors follow an explicit checked/unchecked split:

- `get` / `set` are bounds-checked (`Option<u8>` / `bool`)
- `get_unchecked` / `set_unchecked` are raw fast paths with no bounds check

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
- typed error returns via `FsError` enum with `Result<T, FsError>`
- `File::open` and `File::create` return `Result<File, FsError>` (null-checked fopen)
- `read_file` returns `Result<Bytes, FsError>`; `write_file` returns `Result<u64, FsError>` (reports bytes written)
- `append_file` — open in append mode, returns `Result<u64, FsError>`
- `file_exists` — probe via fopen, returns `bool`
- `read_to_string` — read file into `String`, returns `Result<String, FsError>`
- methods on an already-validated `File` handle (`write_bytes`, `read_bytes`, `seek`, `tell`, `close`) keep raw returns

Still planned:

- stronger path integration
- later process/environment interplay

### `std.env`

Environment variable access:

- get/set/unset wrapping libc
- `get()` returns `Option<String>` — `None` for absent vars, `Some` for present (including empty)
- `set` and `unset` remain void

### `std.process`

Unix process control:

- exit, getpid
- `fork()` returns `ForkResult` (Parent/Child/Err) — 3-variant union, not a standard Result
- `kill()` returns `Result<bool, ProcessError>`
- `Child::wait()` returns `Result<ExitStatus, ProcessError>` with typed `ExitStatus` (Exited with code / Signaled with raw status)
- `spawn(cmd, args)` returns `Result<Child, ProcessError>` — fork+execvp
- Signal constants: `sig_int()`, `sig_kill()`, `sig_term()`
- owned Child handle with wait/pid

### `std.net`

TCP networking layer:

- owned TcpListener and TcpStream handles
- explicit buffer-based read/write
- no hidden runtime coupling
- typed error returns via `NetError` enum with `Result<T, NetError>`
- `TcpListener::bind` returns `Result<TcpListener, NetError>` (checks socket/setsockopt/inet_pton/bind/listen)
- `TcpListener::accept` returns `Result<TcpStream, NetError>` (checks accept)
- `TcpStream::connect` returns `Result<TcpStream, NetError>` (checks socket/connect)
- `TcpStream::write_all` — loop until all bytes sent, returns `bool`
- `TcpStream::read_all` — read until EOF into `Bytes`, returns total bytes read
- `write`, `read` keep `i64` returns (negative = error); `close` stays void

Near-term improvement goals:

- deeper integration coverage with real listener/stream round-trips
- cleaner user-facing naming where builtin hooks still leak through
- keep owned-handle and typed-error patterns uniform with `fs` and `process`

### `std.fmt`

Pure-Concrete formatting module:

- `format_int` / `format_uint` — signed/unsigned decimal
- `format_hex` — `0x` prefixed hexadecimal
- `format_bin` — `0b` prefixed binary
- `format_oct` — `0o` prefixed octal
- `format_bool` — `"true"` / `"false"`
- `pad_left` / `pad_right` — fixed-width padding with fill character

No libc dependency beyond alloc/string.

The long-term goal is for `fmt` and `parse` to behave like one coherent subsystem: explicit, buffer-oriented, and round-trip-friendly where appropriate.

### `std.hash`

Pure-Concrete FNV-1a hash:

- `fnv1a_bytes` — hash a `Bytes` buffer
- `fnv1a_string` — hash a `String`

Hash/eq helpers for use as fn pointers with `HashMap`/`HashSet`:

- `hash_u64`, `hash_i32`, `hash_i64` — multiplicative hash with xorshift mixing
- `hash_string` — delegates to `fnv1a_string`
- `eq_u64`, `eq_i32`, `eq_i64`, `eq_string` — pointer-based equality

Deterministic, no libc dependency.

### `std.map`

Open-addressing hash map with linear probing:

- `HashMap<K, V>` — generic over key/value types
- Takes `hash_fn: fn(&K) -> u64` and `eq_fn: fn(&K, &K) -> bool` at construction (Zig-style, no traits)
- Initial capacity 16, power-of-2, grows at 75% load factor
- Tombstone deletion preserves probe chains
- API: `new`, `insert` (returns `Option<V>`), `get` (returns `Option<&V>`), `contains`, `remove` (returns `Option<V>`), `len`, `is_empty`, `clear`, `drop`

### `std.set`

Thin wrapper around `HashMap<K, u8>`:

- `HashSet<K>` — generic over key type
- Takes same `hash_fn`/`eq_fn` as `HashMap`
- API: `new`, `insert` (returns `bool`), `contains`, `remove` (returns `bool`), `len`, `is_empty`, `clear`, `drop`

### `std.rand`

Thin wrapper over libc `rand`/`srand`:

- `seed(s: u32)` — deterministic seeding
- `random_int() -> i32` — raw random integer
- `random_range(lo: i32, hi: i32) -> i32` — bounded random in `[lo, hi)`

### `std.time`

Monotonic clock and sleep via libc `clock_gettime`/`nanosleep`/`time`:

- `Duration` — `from_secs`, `from_millis`, `from_nanos`
- `Instant` — `now()` (monotonic clock), `elapsed()` (duration since capture)
- `sleep(dur: &Duration)` — nanosleep wrapper
- `unix_timestamp() -> i64` — seconds since epoch

### `std.io` (hardened)

Typed error handling using generic `Result`:

- `IoError` enum (`OpenFailed`)
- `File::create` and `File::open` return `Result<File, IoError>` with null-checked fopen
- `print`, `println`, `print_int`, `eprint` unchanged

### `std.parse`

Inverse of `fmt` — value parsers for converting strings to typed values:

- `parse_int(s: &String) -> Option<i64>` — handles leading `-`, returns `None` on invalid/empty
- `parse_uint(s: &String) -> Option<u64>`
- `parse_hex(s: &String) -> Option<u64>` — optional `0x`/`0X` prefix, supports a-f/A-F
- `parse_bin(s: &String) -> Option<u64>` — optional `0b`/`0B` prefix
- `parse_oct(s: &String) -> Option<u64>` — optional `0o`/`0O` prefix
- `parse_bool(s: &String) -> Option<bool>` — `"true"`/`"false"` only

`Cursor` struct for structured parsing of string input:

- `Cursor::new(s: &String) -> Cursor` — create cursor over string
- `pos`, `remaining`, `is_eof` — position queries
- `peek` / `advance` — character access with `Option<char>` return
- `skip_whitespace` — skip spaces, tabs, newlines
- `expect_char(expected: char) -> bool` — consume if matched

No libc dependency beyond what `std.string` provides.

`parse` should remain small and explicit:

- value parsing
- a tiny `Cursor`
- no parser combinator framework
- no hidden allocation
- strong round-trip behavior with `fmt`

### `std.test`

Test assertion helpers:

- `assert_eq<T>(expected, result, message) -> bool` — equality check
- `assert_ne<T>(a, b, message) -> bool` — inequality check
- `assert_true(value, message) -> bool` / `assert_false(value, message) -> bool`
- `assert_gt<T>`, `assert_lt<T>`, `assert_ge<T>`, `assert_le<T>` — comparison assertions
- `str_eq(a: &String, b: &String) -> bool` — byte-level string equality
- `assert_str_eq(a: &String, b: &String, message) -> bool` — string equality assertion

All assertions return `bool` and print the message on failure.

## Error and Result Design

Stdlib APIs use a uniform error pattern:

- Small enum error types per module (e.g. `FsError`, `NetError`, `IoError`, `ProcessError`)
- Generic `Result<T, ModuleError>` for all fallible operations — no module-specific result enums
- The `?` operator works with both named and generic enum types (patched in Check.lean)
- `std.bytes` provides `get`/`set` returning `Option<u8>`/`bool` for bounds-safe access
- `std.string` provides `get` returning `Option<char>`
- `std.vec` provides `get` returning `Option<&T>`

This replaces the earlier approach of per-module result enums (`FileResult`, `ReadResult`, `WriteResult`, `ListenResult`, `StreamResult`, `KillResult`, `WaitResult`). The generic `Result<T, E>` is now pub and used everywhere.

## Allocation Policy

Allocator-sensitive APIs should make allocation visible:

- via allocator/capability-aware APIs
- via `with(Alloc)` when allocation occurs
- via return types that make ownership obvious

This fits the implemented three-way split between:

- **capabilities** (`with(Alloc)`, `with(File)`, etc.) = semantic effects visible to callers — `with(Alloc)` stays in public signatures because allocation is a real program behavior callers should know about
- **`trusted`** = containment of internal pointer-level implementation techniques (raw ptr deref, arithmetic, casts) behind a safe API — callers do not need `Unsafe` just because a container uses raw pointers internally
- **`with(Unsafe)`** = authority to cross foreign boundaries (FFI, transmute) — always explicit, even inside `trusted` code

See [../research/trusted-boundary.md](../research/trusted-boundary.md) for the full design.

## Later Additions

After the foundation is solid, the likely next additions are:

- a small eager `std.iter` if it earns its place
- `std.collections.ordered_map` (tree-based)
- later `std.sync`
- later `std.ffi`

## Current Position

This is not trying to imitate Rust’s breadth.

The goal is a stdlib that is:

- low-level enough for systems work
- explicit enough for auditability
- small enough to stay coherent

The current state is no longer just a plan. A first useful low-level foundation is in place, including the systems layer (`env`, `process`, `net`), with typed error surfaces across the modules that touch the OS. The stdlib deepening arc has added `fmt`, `hash`, `rand`, `time`, and `parse`, and unified error handling with generic `Result<T, ModuleError>` across all modules. Systems modules have been deepened with helper functions (`fs`: `append_file`, `file_exists`, `read_to_string`; `net`: `write_all`, `read_all`; `process`: `spawn`, signal constants).

The next arc is not “add lots more modules.” It is:

- cleaner public API names and ownership behavior
- stronger builtin-vs-stdlib separation
- deeper systems-module polish
- stronger failure-path and integration testing
- carefully chosen collections in the order above

The best version of the Concrete stdlib will not be the biggest. It will be the most coherent, explicit, and auditable.
