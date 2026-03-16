# Phase H Findings

Status: open findings ledger

This note records what real programs exposed during Phase H and classifies each issue before it turns into roadmap or language work.

The goal is to prevent three failure modes:

- treating every workaround as a language-design problem
- treating every ergonomics issue as syntax debt
- letting real-program findings disappear into commit history

## Classification

Each finding should be tagged as one or more of:

- `language`
- `stdlib/runtime`
- `tooling/workflow`
- `backend/performance`
- `formalization impact`

## First-Wave Programs

### Policy Engine

What it exposed:

- enum fields inside structs originally panicked layout
- standalone examples needed an always-available print path
- string-heavy output wanted a better append path than repeated `string_concat`

What closed:

- Bug 005: enum-in-struct layout
- Bug 007: standalone print builtins
- Bug 011: in-place string building

What remains:

- formatting/interpolation
- qualified module access pressure in larger multi-module code

### MAL Interpreter

What it exposed:

- parser-heavy code needed substring extraction
- loop-carried string building needed mutation-oriented helpers
- standalone benchmarking wanted an always-available timing path
- interpreter runtimes want stronger collection/data-structure support
- deep recursion raises runtime/stack questions beyond pure language surface

What closed:

- Bug 010: substring extraction
- Bug 011: in-place string building
- Bug 012: standalone timing

What remains:

- runtime-oriented collection maturity
- final runtime argument surface design
- runtime/stack pressure clarity

### JSON Parser

What it proved:

- Concrete’s capability system makes authority boundaries legible at the signature level in a way that is immediately useful in real code
- the ownership model is real enough to shape parser structure, not just to decorate APIs
- the language can already carry a non-trivial recursive-descent parser with pools, modules, `Copy` structs, `Vec` generics, and recursive value construction

What felt strong:

- visible authority plus visible ownership discipline is Concrete’s clearest differentiator
- pure helpers are visibly pure, allocating functions visibly allocate, and effectful output visibly declares capabilities
- the builder-builtin approach is verbose but honest: no hidden allocations, no extra grammar, no disguised effects
- module structure, builtin interception, `Copy` structs, and generic `Vec` support were strong enough to carry a real parser

What felt awkward:

- explicit linear-ownership pressure still forces code reshaping patterns that do not yet feel idiomatic
- `drop_string` pressure remains a real signal: cleanup is honest, but repeated destruction can become easy to forget and mechanically noisy
- `&mut` string-building patterns are workable but repetitive
- the lack of destructuring or non-enum pattern-style binding makes some parser/test code more verbose than it needs to be
- repeated multi-pool argument plumbing becomes noisy without better helper/abstraction patterns

What it implies:

- the central Phase H question is no longer “can Concrete carry real programs?” but “do explicit patterns stabilize into disciplined idioms or sustained verbosity?”
- future fixes should prefer compression patterns over hidden magic:
  - helper APIs
  - cleanup idioms
  - stronger stdlib conventions
  - qualification and abstraction tools that preserve explicitness
- syntax growth should remain the last step, not the first response, unless repeated real-program evidence shows that library and workflow patterns are insufficient

What closed after scoped `defer` landed:

- the JSON parser now uses `defer` throughout and dropped roughly 40 lines of cleanup boilerplate
- the biggest win was `defer cleanup(...)` in `main`, which turned repeated `if err != 0 { cleanup(...); return err; }` blocks into plain early returns
- repeated keyword-matching and output cleanup paths also became smaller and less error-prone
- this is evidence that explicit cleanup can become materially less noisy without hiding ownership or destruction

### JSON Parser Benchmark

What it exposed:

- alloca inside loop bodies grows the stack every iteration (LLVM never frees until function return); with 24 String-sized allocas in `parse_value`, deep recursion hit stack overflow at ~130k iterations
- string literal assignment inside a loop generated invalid IR: `ensureValAsPtr` had no `.strConst` case, producing `store %struct.String @global` instead of materializing the string
- compiling without `-O2` made the benchmark 3.6x slower than necessary: per-character `string_char_at` calls dominate at -O0 but are fully inlined at -O2

What closed:

- Bug 013: alloca hoisting — all allocas now emitted in function entry block via `entryAllocas` field in EmitSSAState
- Bug 014: string literal in loop — `.strConst` case added to `ensureValAsPtr`, routes through `materializeStrConst`
- Bug 015: missing `-O2` — clang invocations now pass `-O2` for both regular and test compilation

What it proved:

- at -O2, Concrete's JSON parser parses 9.3MB in ~40ms, matching or slightly beating Python's `json.loads` (46ms) on the same file
- earlier measurements showing Concrete at 185ms total were benchmark-mode artifacts: 145ms parse at -O0 + 40ms byte-by-byte string construction
- the parser implementation is strong; the optimizer/backend story matters a lot for real workloads
- `string_reserve` pre-allocation dropped the load phase from 40ms to 3ms at -O2 (LLVM inlines the push loop into a near-memcpy)

What was added:

- `string_reserve(&mut String, cap)` builtin across all compiler passes (Intrinsic, BuiltinSigs, Check, Elab, EmitBuiltins)
- `Bytes.to_string()` zero-copy ownership transfer in std/src/bytes.con
- regression tests: alloca hoisting stress, string literal in loop, string_reserve

Benchmark results (9.3MB JSON, warm cache):

| | Load | Parse | Total |
|---|---|---|---|
| Concrete -O0 (old default) | 40ms | 145ms | 185ms |
| Concrete -O2 (new default) | 3ms | 40ms | 43ms |
| Python json.loads | — | 46ms | 46ms |

### Grep-Like Tool Benchmark

What it proved:

- the JSON result generalizes to a structurally different workload: streaming/text scanning rather than recursive descent over one preloaded buffer
- Concrete at `-O2` is competitive on line-oriented text processing and pattern matching, not only parser-style workloads
- output cost now shows up separately from match cost in a useful way: count-only is much cheaper than printing matched lines

What surfaced:

- runtime argument access (`argc` / `argv`) is now a real user-facing need for systems utilities, not just an implementation detail
- standalone/project friction still matters because richer stdlib/project surfaces are easier to justify once programs start behaving like real command-line tools

Benchmark results (13MB log-like file, 200k lines, pattern `error`):

| Tool | Count-only | With output |
|---|---|---|
| Concrete `cgrep` | 35ms | 95ms |
| Python | 34ms | — |
| macOS `grep` | 83ms | 88ms |

What it implies:

- Concrete's `-O2` performance is now credible across at least two recognizable text workloads
- the next useful pressure point should be runtime/control-flow heavy code again (bytecode VM) or a flagship critical-software workload (artifact/update verifier), not another parser-only benchmark

### Bytecode VM Benchmark

What it proved:

- Concrete is now clearly in a real systems-language band on runtime-heavy code, not only on parser/text workloads
- the VM exposed a backend/codegen policy issue that real parser/text workloads did not: tiny vec builtins were not being inlined in the dispatch loop
- the current collection surface is good enough to build a real VM, and the remaining performance question turned out to be optimizer shaping rather than an inherent collection-cost wall

Benchmark results (`fib(35)` workload):

| VM | Time |
|---|---|
| Concrete `-O2` before vec inlining fix | ~785ms |
| Concrete `-O2` after vec inlining fix | ~257ms |
| C `-O2` heap-`Vec` version | ~260ms |
| Python | 15,223ms |

What it exposed:

- the dominant initial gap to C was not bounds checks or a fundamental safety tax; it was function-call overhead from non-inlined `vec_get`, `vec_set`, `vec_push`, `vec_pop`, and `vec_len` in the hot dispatch loop
- once vec builtins were marked `alwaysinline`, the gap to the comparable C heap-`Vec` implementation disappeared on this benchmark

What it implies:

- Concrete is still about 59x faster than Python here, so the language/runtime path is clearly credible
- this benchmark no longer supports the claim that Concrete currently pays a large unavoidable abstraction cost in safe collection code
- future performance work should focus first on backend inlining policy and other compiler/codegen cliffs before assuming the surface model itself is too expensive

### Artifact Verifier (conhash)

What it proved:

- Concrete's capability system is not just a correctness feature — it is the audit trail itself
- an auditor can verify from signatures alone that the hasher (`with(Alloc)`) never touches the filesystem or network, the file reader (`with(File, Alloc)`) cannot leak data to the console, and the reporter (`with(Console)`) cannot read or modify files
- SHA-256 implemented in pure Concrete (bitwise ops on `u32`) matches `shasum` and Python `hashlib` at ~23ms on 9.3MB — LLVM -O2 optimizes Concrete's bit manipulation to near-C quality
- this is the first Phase H program where the capability annotations are the *point*, not a side benefit

What it exposed:

- the `trusted` boundary is clean: only `read_file_raw` and `sha256` (which needs raw pointer arithmetic for padding/block processing) require `trusted`, everything else is safe Concrete
- linearity friction with conditional initialization (`if argc >= 3 { ... }`) required a helper function workaround — evidence for the destructuring/conditional-init open finding

Benchmark results (9.3MB file):

| Tool | SHA-256 time |
|---|---|
| Concrete `conhash` | ~23ms |
| `shasum` (Perl/C) | ~25ms |
| Python `hashlib` (C openssl) | ~20ms |

## Phase H Retrospective

### What Phase H proved

Concrete is credible on real programs. Policy engine, MAL interpreter, JSON parser, grep, bytecode VM, and artifact verifier all worked. This is no longer a toy-language question.

`-O2` changes the performance story completely. JSON and grep show Concrete competitive with Python on real text workloads. Earlier "Concrete is much slower" conclusions were mostly `-O0` artifacts.

Real workloads found real compiler bugs: enum-in-struct layout panic, cross-module string literal collision, alloca-in-loops stack blowup, string literal in loop invalid IR, const lowering gap, if-expression gap, standalone print/timing gaps, substring/loop string-building gaps. These were valuable because they came from programs, not synthetic cases.

`defer` was high leverage. It removed significant cleanup boilerplate, now has credible scope semantics, and explicit cleanup still works but with much less noise.

Concrete's differentiator is real. Visible authority in signatures, visible ownership/cleanup in code — now proven under real code, not just in docs. The artifact verifier is the clearest demonstration: capability signatures *are* the security audit.

### What the main open question became

Not "can Concrete express real programs?" but "do its explicit patterns become stable idioms or stay as exhausting ceremony?"

### Priority fixes from Phase H evidence

1. **~~Standalone vs project dependency resolution~~** — CLOSED: `concrete build` now works with `Concrete.toml`, `mod X;` directory modules, and cross-module imports; `cgrep` and `conhash` examples converted to use `std.fs.read_to_string` / `std.fs.read_file`; current `std = { path = "..." }` is a temporary hack — Phase J should make std a builtin dependency
   - update: builtin std resolution is now landed as well; std is found automatically relative to the compiler binary, with `CONCRETE_STD` as an override for unusual setups
2. **Formatting / interpolation / text output** — too much manual string building for real programs
3. **Runtime-oriented collection maturity** — MAL and the VM both need maps, nested mutable structures, runtime-friendly patterns
4. **Backend inlining / codegen policy cliffs** — the VM showed that tiny builtin calls in hot loops can distort performance dramatically if LLVM is not given enough shape information
5. **User-facing runtime argument surface** — `argc`/`argv` work in practice, but the final public shape is not settled
6. **~~Qualified module access~~** — CLOSED for the first real workload cases: file-based `mod::fn` access, mixed imported + qualified access, two-submodule qualified access, top-level + qualified coexistence, qualified submodule `extern fn`, and qualified submodule struct/import interaction are now covered by targeted tests
   - remaining limitation: parent/submodule or sibling-submodule functions with the same leaf name still collide at the LLVM symbol layer because function definitions still emit bare names; this is a backend naming issue, not a remaining resolution/elaboration design gap
7. **Runtime / stack pressure classification** — MAL exposed this; still needs a cleaner language-vs-runtime-vs-tooling decision

## Current Open Findings

### Formatting / interpolation

- Class: `stdlib/runtime`, possibly `language`
- Why it matters: real programs need readable output, logs, diagnostics, and message assembly
- Current state: manual string building remains too verbose

### Qualified module access

- Class: `language`, `tooling/workflow`
- Why it matters: larger programs should not depend on renaming to avoid collisions
- Current state: first real qualified-access path is now landed and regression-tested for the covered cases
- Remaining limitation: leaf-name collisions across parent/submodule or sibling submodules still need backend symbol-prefixing work; this is not a blocker for the now-landed qualified-access surface, but it does prevent calling the namespace story fully complete

### Destructuring let

- Class: `language`
- Why it matters: parser/runtime code wants clearer binding of paired results
- Current state: still an open surface question, not a confirmed must-add

### Runtime-oriented collections

- Class: `stdlib/runtime`
- Why it matters: interpreters, analyzers, and schedulers want maps, nested mutable structures, and clearer frame-friendly patterns
- Current state: existing collection surface is usable but thin for this workload

### Standalone vs project UX

- Class: `tooling/workflow`
- Why it matters: examples and benchmarks should not need awkward scaffolding to reach common stdlib utilities
- Current state: **closed for current workflow purposes** — `concrete build`, `concrete run`, and `concrete test` now work in package mode; std is resolved automatically relative to the compiler binary, with `CONCRETE_STD` as an override; remaining work is broader package/workspace maturity, not basic std access

### Runtime argument surface

- Class: `stdlib/runtime`, `tooling/workflow`
- Why it matters: real command-line tools need a stable way to access process arguments without dropping into generated-C details or ad hoc wrappers
- Current state: first `argc` / `argv` support exists and works for `cgrep`, but the final user-facing surface is still undecided

### Backend inlining / codegen policy cliffs

- Class: `backend/performance`
- Why it matters: the bytecode VM initially showed a large gap to C that disappeared once vec builtins were marked `alwaysinline`; this is strong evidence that backend shaping can dominate perceived language cost
- Current state: the first major VM performance cliff was fixed; future performance analysis should check for similar missed-inlining or missed-shaping cases before proposing new unsafe or unchecked surfaces

### Runtime / stack pressure

- Class: `backend/performance`, `stdlib/runtime`
- Why it matters: deep-recursive workloads expose execution-model limits that should be understood before later runtime/concurrency work
- Current state: observed in MAL benchmarks, still not classified into final ownership

## Rule

Before any new surface change is adopted from a Phase H finding:

1. classify the issue
2. decide whether it belongs in language, stdlib, tooling, or runtime
3. write the narrowest design that solves the real problem
4. record why library/workflow fixes are insufficient if syntax is being proposed

## Standing Phase H Question

For every serious program, ask:

- are explicit authority and ownership patterns becoming stable idioms?
- or are they remaining honest but exhausting ceremony?

That question is now one of the most important evaluation criteria for the phase.
