# Changelog

Status: changelog

This file tracks major completed milestones for Concrete.

It is intentionally milestone-oriented rather than release-oriented. The project is still evolving quickly, so the useful unit of history is “what architectural or language capability landed,” not tagged versions.

For current priorities and remaining work, see [ROADMAP.md](ROADMAP.md).

## Major Milestones

### Structured LLVM backend completed

The LLVM backend no longer relies on raw LLVM string emission. `LLVMModule` is now the single source of truth for backend construction, and all emitted LLVM IR flows through structured types before printing.

What landed:
- user function codegen emits through structured LLVM module fields
- extern declarations emit through structured LLVM module fields
- type definitions emit through structured LLVM module fields
- globals emit through structured LLVM module fields
- the main wrapper, test runner, and vec builtins were converted from prebuilt text blobs into structured module output
- string/conversion builtins were rewritten into structured `LLVMFnDef` / `LLVMGlobal` / `LLVMFnDecl` output
- the `rawSections` escape hatch was deleted
- the legacy `Concrete/Codegen/` backend path was deleted

This is a major Phase D milestone because the backend is now structurally unified: every emitted LLVM construct is represented in structured data before the final printer turns it into text.

### Phase C complete: tooling and stdlib hardening

Phase C is done with all 8 items complete. This phase turned syntax guardrails, diagnostics, stdlib testing, and audit reports into durable infrastructure.

What landed:
- **Module-targeted stdlib testing**: `--stdlib-module <name>` in `run_tests.sh` runs tests for a single stdlib module (e.g., `--stdlib-module map`, `--stdlib-module string`) using `--test --module std.<name>`. Developers can iterate on one module without bootstrapping the whole tree.
- **Diagnostics/formatter polish**: fixed empty `{}` edge case in formatter (enum literals need braces to avoid parser ambiguity), fixed `String.trimLeft` deprecation, eliminated compiler warnings in `Check.lean`.
- **Integration testing deepened**: added `report_integration.con` (exercises all 6 report modes with caps/unsafe/alloc/layout/interface/mono) and `integration_collection_pipeline.con` (multi-collection pipeline with Vec, generics, enums, structs, mixed allocation patterns).
- **Report assertions hardened**: 44 report tests with content checks across all 6 modes, replacing crash-only checks with assertions that verify specific output content (struct sizes, public API exports, capability traces, allocation patterns, specialization details).
- **Reports as audit product**: 6 report modes (`caps`, `unsafe`, `layout`, `interface`, `mono`, `alloc`) with:
  - capability "why" traces showing which callees contribute each capability with `(intrinsic)`/`(extern)` tags
  - trust boundary analysis showing what unsafe operations trusted functions wrap (extern calls, pointer dereference, memory management)
  - allocation/cleanup summaries tracking alloc/free/defer patterns with leak warnings for functions that allocate without cleanup
  - summary totals and aligned columns across all reports
- **Formatter golden tests**: 4 formatter-specific golden tests with idempotency checking
- **LL(1) grammar checker in CI** (completed earlier in Phase C)
- **Linearity checker fixes** (completed earlier in Phase C)
- **Builtin HashMap retirement** (completed earlier in Phase C)

Test suite: 600 tests passing (189 stdlib), including 44 report assertions, 46 golden tests, and 16 collections verified.

### Builtin HashMap interception retired

Deleted ~1,400 lines of compiler-internal HashMap machinery across 6 Lean files. HashMap is now an ordinary stdlib type compiled through the normal generic struct path — no compiler interception, no hardcoded layout, no hand-written LLVM IR runtime.

What was removed:
- 7 intrinsic IDs (`mapNew`..`mapFree`) and their resolution/capability mappings from `Intrinsic.lean`
- ~106 lines of type checking intercepts from `Check.lean`
- ~74 lines of elaboration intercepts from `Elab.lean`
- ~75 lines of LLVM wrapper functions from `EmitSSA.lean`
- ~636 lines of hand-written LLVM IR runtime from `Codegen/Builtins.lean` (hash, probe, insert, get, contains, remove, grow — for both int and string key variants)
- Hardcoded 5-field `%struct.HashMap` type definition from `Layout.lean`
- `HashMap` removed from `builtinTypeNames` (it is now resolved through normal imports)

What replaced it: the stdlib `HashMap<K, V>` in `std/src/map.con` (a 7-field struct with fn pointer fields for hash/eq) compiles natively through monomorphization, the same path as any user-defined generic struct. 6 new stdlib tests (4 HashMap, 2 HashSet) provide collection verification coverage.

This was enabled by the linearity checker fixes in the previous milestone.

### Linearity checker: generic types, self-consumption, and divergence

Four fixes to the type checker's linearity analysis (`Check.lean`) that together unblock user-defined generic collections with function pointer fields — the same pattern as `HashMap`:

1. **`isCopyType` for generic and type-variable types** — `.generic` types now look up the struct's `isCopy` flag instead of returning `false`; `.typeVar` types check whether their bounds include `Copy`. Previously all generic instantiations were treated as linear.
2. **Trusted function loop-consumption relaxation** — `trusted impl` methods can now consume linear variables inside loops. The linearity checker skips the loop-depth restriction when `isTrustedFn` is set, because trusted code asserts soundness manually.
3. **Self-consuming method calls** — methods that take `self` by value (not `&self`/`&mut self`) now mark the receiver variable as consumed. Previously `f.drop()` left `f` unconsumed.
4. **If-without-else divergence** — consuming a linear variable inside an if-then that unconditionally returns is now allowed. The checker detects that the then-branch diverges and skips the branch-consumption check, enabling the common `if bad { x.drop(); return err; }` guard pattern.

Validated by four independent regression tests and a full IntMap (user-defined hash map with fn pointer fields for hash/eq) that compiles and runs end-to-end. 544 tests passing, 0 failures.

### Phase A completion: fast feedback and aggregate-lowering hardening

- Hardened mutable aggregate lowering so aggregate state no longer flows accidentally through whole-aggregate phi nodes:
  - loop-carried aggregate variables are promoted to stable entry-block allocas instead of being transported as aggregate phi values
  - aggregate merges in `if`/`else` and `match` now lower through alloca+store/load patterns instead of `phi %Struct`
  - void-typed match results are filtered out of phi/store paths
- Added mechanical SSA protection for this architecture:
  - `SSAVerify` now rejects aggregate phi nodes (`struct`, `enum`, `string`, `array`) with a hard error instead of relying only on regression coverage
  - lowering phi-emission sites were audited so aggregate transport is intentionally blocked rather than incidentally absent
- Strengthened regression coverage around the new lowering path:
  - added `-O2` regressions for struct-loop lowering patterns
  - added SSA-shape verification for aggregate-merge cases so aggregate phi nodes are caught close to the source
- Upgraded the main test runner into a practical fast-feedback workflow:
  - `run_tests.sh` now defaults to parallel execution on available cores
  - added `--fast` (default), `--full`, `--filter`, `--stdlib`, `--O2`, `--codegen`, and `--report` modes
  - partial runs now report mode/filter/skip information clearly
  - documented `--fast` as the standard developer loop and `--full` as the pre-merge check
- This completed Phase A well enough for the roadmap to shift primary attention to Phase B semantic cleanup while leaving deeper testing architecture work for later phases.

### Stdlib test-runner activation and compiler fixes

- The stdlib test corpus now runs through the real compiler path via `concrete std/src/lib.con --test`, so module-local `#[test]` coverage in `std/src` is active CI protection instead of latent coverage.
- Fixed parser precedence around unary `*` / `&` with postfix field access so expressions like `*self.data` and `&self.field` bind correctly.
- Fixed lowering/codegen issues exposed by stdlib execution:
  - built-in `String` field access now lowers through a synthetic `String` struct definition so field offsets are computed correctly
  - `&mut` field method chains now write back into the parent struct instead of mutating a temporary copy
  - reference/pointer-typed values are no longer incorrectly spilled to allocas by `ensurePtr`
  - `char` / `bool` integer casts now use the proper integer-extension path instead of the old alloca/store/load fallback
- This brought the project to 488 passing tests in the main suite, including active stdlib-module coverage.

### Stdlib API cleanup and new collections

- Unified get/set convention across `String`, `Vec`, `Bytes`:
  - `get` is now checked (returns `Option`), `get_unchecked` is the raw fast path
  - `set` is now checked (returns `bool`), `set_unchecked` is the raw fast path
  - `Vec::pop` now returns `Option<T>` instead of unchecked raw access
- Fixed `std.io` print semantics:
  - Removed type-suffixed names (`print_int`, `print_bool`, `print_char`, `print_string`, `eprint_string`)
  - `print` now uses `write(1, ...)` (no trailing newline), `println` writes + newline, added `eprintln` for stderr
  - `read_line` annotated with `with(Alloc)`
- Converted `Text` and `Slice` to use `impl` method syntax (from C-style free functions)
- Fixed `test.con` to properly drop owned `String` messages on all code paths
- Updated all internal callers (`parse.con`, `fmt.con`, `hash.con`, `test.con`) to use new accessor names
- Added 5 new collections to the stdlib (33 modules total):
  - `std.deque.Deque<T>` — ring buffer with power-of-2 masking, push/pop front/back, checked/unchecked access
  - `std.heap.BinaryHeap<T>` — binary heap with fn-pointer comparator (works as min-heap or max-heap)
  - `std.ordered_map.OrderedMap<K, V>` — sorted array with binary search, fn-pointer comparator
  - `std.ordered_set.OrderedSet<K>` — thin wrapper over `OrderedMap<K, u8>`
  - `std.bitset.BitSet` — u64-word-backed bitset with set/unset/test, popcount, union, intersect
- All new collections have inline `#[test]` functions covering basic operations, edge cases, and stress tests

### Testing strategy expansion

- Added parser fuzzing infrastructure (`test_parser_fuzz.sh`): generates random/malformed inputs and verifies the parser never crashes or hangs
- Added `fmt`/`parse` round-trip property tests (`fmt_parse_roundtrip.con`): verifies `parse(format(x)) == x` across ranges, powers, and edge values
- Added `Vec` trace tests (`vec_trace.con`): push/get/set/length invariants, growth preservation, interleaved operations
- Added `HashMap` trace tests (`hashmap_trace.con`): insert/get/remove/overwrite invariants, tombstone recovery, growth stress
- Added report consistency tests:
  - capability reports (`report_caps_check.con`)
  - unsafe / trusted-boundary reports (`report_unsafe_rawptr.con`)
  - layout reports with runtime cross-validation (`report_layout_check.con`)
  - interface visibility reports (`report_interface_check.con`)
  - monomorphization reports (`report_mono_check.con`)
- Added codegen differential tests (16 assertions across `--emit-ssa`, `--emit-llvm`, `--emit-core`):
  - SSA optimization verification: constant folding (`2+3→5`), strength reduction (`*8→shl 3`), absence of un-optimized ops
  - Codegen structure: struct GEP offsets, enum tag load/compare, monomorphization naming, LLVM struct type definitions, mutable borrow stores
  - Cross-representation consistency: packed struct syntax in LLVM matches `--report layout`, enum payload size agreement, Core→SSA function signature mapping
- This completed the first planned testing-strategy expansion: parser fuzzing, property tests, trace tests, report consistency tests, and selected differential tests are now permanent coverage in the main suite

### Builtin / stdlib boundary cleanup

- Introduced `IntrinsicId` as the compiler-internal identity for builtins, replacing raw string matching in compiler dispatch paths
- Removed the ad hoc builtin `abs` special case; `abs` now lives in the stdlib as a trait method (`Numeric::abs`) resolved through normal trait dispatch + monomorphization
- Migrated the remaining monomorphic math wrappers (`sqrt`, `sin`, `cos`, `tan`, `pow`, `log`, `exp`, `floor`, `ceil`) out of compiler intrinsics and into `std.math` as `trusted extern fn`
- Added `trusted extern fn` as an explicit audited foreign-binding category:
  - ordinary `extern fn` still requires `with(Unsafe)`
  - `trusted extern fn` exposes narrow trusted foreign symbols without leaking `Unsafe` to callers
  - audit reports now distinguish trusted extern functions from ordinary extern functions
- Removed dead intrinsic entries and then removed 17 I/O / File / Network / Process / Env intrinsics by migrating them to stdlib wrappers
- Deleted large hand-written LLVM builtin/codegen paths that were no longer needed after the stdlib/trusted-extern migration
- Tightened the public stdlib surface so more operations now route through ordinary stdlib APIs instead of compiler-known names

### LL(1) parser cleanup

- Removed all remaining parser save/restore backtracking sites
- Left-factored top-level `mod` parsing
- Removed retry-based parsing around `&self` / `&mut self`
- Tightened turbofish/type-position parsing so `::` commits instead of rewinding
- Moved enum-dot fallback handling into postfix parsing instead of speculative rewind
- Parser implementation now matches the language’s strict LL(1) design goal much more closely

### Lowering bug fixes (string dedup + variable scoping)

- Fixed string constant naming collision: multiple functions with string literals independently generated `str.0`, `str.1`, etc. The second lowering pass concatenated per-function lists, producing duplicate LLVM globals. Fix: `lowerFn` now returns string literals alongside the function definition; `lowerModule` collects, deduplicates by value, and renames references per-function. The redundant second lowering pass is removed.
- Fixed SSA domination error in if/else with while loops: restoring pre-if variable state before the else-branch only overwrote existing variables, leaving then-branch locals (loop body registers) visible in the else-branch scope. Fix: replace the per-variable restore with a full variable map replacement so the else-branch starts with exactly the pre-if variable set.
- Fixed the same variable leakage bug in while loop exits: body-local variables leaked into subsequent code after the loop. Fix: replace the per-variable phi restore at all four while-loop exit points with full variable map replacement.
- Added regression tests: `string_multi_fn.con`, `if_else_while.con`

### Trusted boundaries

- Added `trusted fn` and `trusted impl` to the language surface
- Propagated trusted boundaries through AST, Core, lowering metadata, and audit reporting
- `CoreCheck` now relaxes raw pointer dereference, raw pointer assignment, and pointer-cast checks inside trusted code
- Kept `extern fn` calls under `with(Unsafe)` even inside `trusted`
- Added tests for trusted functions, trusted impls, trusted pointer operations, and invalid trusted usage
- Added trusted trait-impl support and grouped trusted boundary reporting at the source level
- Migrated builtins, stdlib, and user code to one explicit trust/effect model with honest capability annotations
- Fixed trusted pointer arithmetic end-to-end by teaching SSA verification and codegen how to handle pointer + integer lowering

### Stdlib collections: HashMap and HashSet

- Added `std.map.HashMap<K, V>` — open-addressing hash map with linear probing, fn-pointer hash/eq (Zig-style)
- Added `std.set.HashSet<K>` — thin wrapper around `HashMap<K, u8>`
- Added hash/eq helper functions in `std.hash`: `hash_u64`, `hash_i32`, `hash_i64`, `hash_string`, `eq_u64`, `eq_i32`, `eq_i64`, `eq_string`
- Fixed compiler bug: function pointers loaded from struct fields were emitted as direct calls (`@name`) instead of indirect calls (`%name`), causing linker errors. Fix spans Lower, SSACleanup, and EmitSSA.

### Test framework

- Added `--test` CLI flag: `concrete file.con --test` compiles and runs all `#[test]` functions
- `#[test]` attribute tracked through the full IR pipeline (AST → Core → Mono → SSA)
- Generated test runner calls each test, prints `PASS: <name>` / `FAIL: <name>`, exits 0/1
- Test collection is recursive through submodules
- Validation: `#[test]` functions must have no parameters, not be generic, and return `i32`
- Validation: `#[test]` on non-function declarations is a parse error

### Compiler architecture

- Replaced the old direct AST backend with the full pipeline:
  `Parse -> Resolve -> Check -> Elab -> CoreCanonicalize -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA -> clang`
- Added explicit Core IR, elaboration, monomorphization, SSA lowering, SSA verification, SSA cleanup, and SSA-consuming codegen
- Removed the legacy AST backend and `--compile-legacy`
- Added `Concrete/Pipeline.lean` with explicit artifact types:
  - `ParsedProgram`
  - `SummaryTable`
  - `ResolvedProgram`
  - `ElaboratedProgram`
  - `MonomorphizedProgram`
  - `SSAProgram`
- Introduced `IntrinsicId` so the remaining compiler-known operations are identified internally instead of by raw string names

### Frontend and semantic boundaries

- Established the summary-based frontend with `FileSummary` and `ResolvedImports`
- Split `Resolve` into shallow/interface resolution and body-level name resolution
- Moved most post-elaboration legality checks out of `Check.lean` and into `CoreCheck.lean`
- Made `CoreCheck` the main post-elaboration semantic authority
- Centralized `Self` type resolution via shared helpers

### Diagnostics

- Added structured diagnostic types across semantic passes:
  - `ResolveError`
  - `CheckError`
  - `ElabError`
  - `CoreCheckError`
  - `SSAVerifyError`
- Threaded source spans through the AST/parser
- Moved the main semantic pipeline to native `Diagnostics` transport instead of mostly string-based bridging
- Added range-capable spans, hint text, and broader error accumulation across functions/modules in `Check` and `Elab`
- Added report/inspection modes:
  - `--report caps`
  - `--report unsafe`
  - `--report layout`
  - `--report interface`
  - `--report mono`
- Added report consistency coverage so capability, unsafe/trusted, layout, interface, and monomorphization reports are now regression-tested against real semantics and emitted LLVM

### ABI / layout / low-level semantics

- Added `#[repr(C)]` for structs
- Added `#[repr(packed)]` and `#[repr(align(N))]`
- Added `sizeof::<T>()` and `alignof::<T>()`
- Centralized layout logic in `Concrete/Layout.lean`
- Unified FFI-safety checks and LLVM type-definition generation through `Layout`
- Fixed aligned struct/enum layout and enum payload offset handling
- Fixed builtin `Option` / `Result` layout to size payloads from actual instantiations instead of hardcoded `i64` assumptions

### Language capabilities

- Capabilities and capability polymorphism
- Function pointers (closures intentionally omitted)
- Borrow regions
- Linear ownership tracking
- `defer`, `Destroy`, and `Copy`
- Monomorphized trait dispatch
- Multi-file modules and `Self`
- `newtype`
- Raw-pointer `Unsafe` gating for dereference, assignment, and pointer-involving casts

### Runtime-facing builtins

- String builtins
- File I/O builtins
- Networking builtins
- `Vec<T>` and `HashMap<K, V>` builtin/runtime-backed support

### Standard library foundation

- Hardened the early `vec`, `string`, and `io` modules with correctness and completeness fixes
- Added:
  - `std.bytes`
  - `std.slice`
  - `std.text`
  - `std.path`
  - `std.fs`
- Expanded libc/math/test support to better support the growing stdlib surface

### Standard library systems layer

- Added `std.env` — environment variable access (get/set/unset)
- Added `std.process` — Unix process control (exit, getpid, fork, kill, Child with wait)
- Added `std.net` — TCP networking (TcpListener with bind/accept/close, TcpStream with connect/read/write/close)
- Extended `std.libc` with process (setenv, unsetenv, getpid, fork, execvp, waitpid, kill) and networking (socket, bind, listen, accept, connect, close, send, recv, htons, htonl, inet_pton, setsockopt) declarations
- Added module-level `#[test]` functions to `bytes` and `path`

### Stdlib hardening — typed error surfaces

- Added typed error enums to `std.fs`: `FsError`, `FileResult`, `ReadResult`, `WriteResult` — all `fopen` calls are now null-checked, `write_file` returns typed `WriteResult`
- Added typed error enums to `std.net`: `NetError` (including `SetsockoptFailed`, `AddressFailed`), `ListenResult`, `StreamResult` — all syscall returns checked including `setsockopt` and `inet_pton`
- Added typed wrappers to `std.process`: `ForkResult`, `KillResult`, `WaitResult`, `ExitStatus`, `ProcessError` — `fork`/`kill`/`wait` return typed results with POSIX wait-status interpretation
- Changed `std.env::get()` to return `Option<String>` — distinguishes absent vars from empty ones
- Made `Bytes` accessors explicit: `get`/`set` are now bounds-checked (returning `Option<u8>`/`bool`), `get_unchecked`/`set_unchecked` are the raw fast paths
- Made `Option<T>` pub for cross-module use
- Added failure-path `#[test]` functions across stdlib modules:
  - `bytes`: checked get/set in-bounds and out-of-bounds
  - `fs`: open/create/read/write on nonexistent paths
  - `env`: get absent var, set-then-get round-trip
  - `net`: connect and bind with invalid addresses
  - `process`: kill invalid pid, fork-wait typed round-trip

### Stdlib deepening — fmt, time, rand, hash + io hardening

- Added `std.fmt` — pure-Concrete formatting: `format_int`, `format_uint`, `format_hex`, `format_bin`, `format_oct`, `format_bool`, `pad_left`, `pad_right`
- Added `std.hash` — FNV-1a hash: `fnv1a_bytes`, `fnv1a_string` (pure Concrete, no libc dependency)
- Added `std.rand` — deterministic random: `seed`, `random_int`, `random_range` (wraps libc rand/srand)
- Added `std.time` — monotonic clock and sleep: `Duration` (from_secs/from_millis/from_nanos), `Instant` (now/elapsed), `sleep`, `unix_timestamp` (wraps clock_gettime/nanosleep/time)
- Hardened `std.io`: `File::create` and `File::open` now return `OpenResult` with null-checked fopen (added `IoError`, `OpenResult` enums)
- Extended `std.libc` with time (time, clock_gettime, nanosleep) and random (rand, srand) declarations
- Added failure-path tests: `fs::test_write_to_readonly`, `net::test_connect_refused`, `process::test_wait_invalid_pid`
- Added module-level `#[test]` functions across all four new modules

### Stdlib uniformity + deepening + parse

- Made `Result<T, E>` pub for cross-module use as a generic error container
- Patched `Check.lean` `?` operator to support generic enums (e.g. `Result<File, FsError>`) with type substitution, not just named enums
- Unified error/result types across stdlib: removed module-specific result enums (`OpenResult`, `FileResult`, `ReadResult`, `WriteResult`, `ListenResult`, `StreamResult`, `KillResult`, `WaitResult`), replaced with `Result<T, ModuleError>` everywhere
- `std.io`: `File::create`/`File::open` return `Result<File, IoError>`
- `std.fs`: `File::open`/`File::create` return `Result<File, FsError>`, `read_file` returns `Result<Bytes, FsError>`, `write_file` returns `Result<u64, FsError>` (now reports bytes written)
- `std.net`: `TcpListener::bind` returns `Result<TcpListener, NetError>`, `TcpStream::connect` returns `Result<TcpStream, NetError>`, `TcpListener::accept` returns `Result<TcpStream, NetError>`
- `std.process`: `kill` returns `Result<bool, ProcessError>`, `Child::wait` returns `Result<ExitStatus, ProcessError>`, `ForkResult` kept as 3-variant union
- Added `std.parse` — inverse of `fmt`: `parse_int`, `parse_uint`, `parse_hex`, `parse_bin`, `parse_oct`, `parse_bool` (all return `Option<T>`), plus `Cursor` struct for structured input parsing (`peek`, `advance`, `skip_whitespace`, `expect_char`)
- Added checked accessors: `String::get` returns `Option<char>`, `Vec::get` returns `Option<&T>` (reference-in-generic monomorphizes correctly)
- Systems deepening:
  - `std.fs`: `append_file`, `file_exists`, `read_to_string`, write-then-read roundtrip test
  - `std.net`: `TcpStream::write_all` (loop until all sent), `TcpStream::read_all` (read until EOF into Bytes)
  - `std.process`: signal constants (`sig_int`, `sig_kill`, `sig_term`), `spawn` (fork+execvp), `SpawnFailed` error variant

### Stdlib test deepening

- Deepened `std.test`: added `assert_gt`, `assert_lt`, `assert_ge`, `assert_le`, `str_eq`, `assert_str_eq`
- Added `std.net` integration tests: `test_tcp_roundtrip` (fork-based listener/client pair), `test_tcp_write_all_read_all` (write_all + read_all with Bytes)
- Added standalone `net_tcp_roundtrip.con` lean_test using builtins (`tcp_listen`, `tcp_accept`, `tcp_connect`, `socket_send`, `socket_recv`, `socket_close`)

### Testing / status milestones

- End-to-end main suite has continued to grow through the milestones above; current suite size and latest status live in `README.md` and `ROADMAP.md`, not here
- SSA-specific suite passing
- Golden SSA/IR testing integrated
- CI updated to exercise SSA-specific coverage as well as the main path
- Added stronger stdlib failure-path and integration coverage, including socket round-trip tests and parser/process edge cases
