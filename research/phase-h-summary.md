# Phase H Summary

Status: canonical reference

This is the stable "what we learned" document for Phase H. It covers every serious program built, what each proved and exposed, the aggregate performance picture, the compiler bugs found and fixed, and the open questions that carry forward.

## Programs Built

Six real programs, in order of construction:

1. **Policy engine** — rule evaluation with enum/struct composition
2. **MAL interpreter** — ~1150-line Make-A-Lisp with linked-list environments, symbol interning, cons cell pool
3. **JSON parser** — ~450-line recursive-descent parser with string pools, `Copy` structs, `Vec` generics, recursive value construction
4. **cgrep** — ~220-line grep-like tool with `-n`, `-c`, `-v`, `-i` flags, multiple files, error reporting
5. **Bytecode VM** — stack-based VM with 22 opcodes, CALL/RET, fib(35) benchmark
6. **conhash** — artifact integrity verifier with SHA-256, capability-based audit trail

## Performance Picture

All numbers at `-O2` on Apple Silicon, warm cache.

### Text/parser workloads

| Workload | Concrete | Python | C / system |
|---|---|---|---|
| JSON parse 9.3MB | 40ms | 46ms (`json.loads`) | — |
| JSON load 9.3MB | 3ms (with `string_reserve`) | — | — |
| grep 13MB count-only | 35ms | 34ms | 83ms (macOS `grep`) |
| grep 13MB with output | 95ms | — | 88ms (macOS `grep`) |

Concrete is competitive with Python and macOS `grep` on text workloads. The key discovery was that the `-O2` flag matters enormously — earlier `-O0` measurements showed Concrete 3-4x slower, which was entirely an optimizer artifact.

### Compute-heavy workloads

| Workload | Concrete | Python | C |
|---|---|---|---|
| VM fib(35) (before inline fix) | ~785ms | 15,223ms | ~260ms |
| VM fib(35) (after inline fix) | ~257ms | 15,223ms | ~260ms |
| SHA-256 9.3MB | ~23ms | ~20ms (`hashlib`, C OpenSSL) | ~25ms (`shasum`, Perl/C) |

The VM was the clearest performance gap: Concrete was 3x slower than C on a dispatch-heavy loop. Investigation revealed the dominant cost was **function call overhead from non-inlined vec builtins** (`vec_get`/`vec_set`/`vec_push`/`vec_pop`). Adding `alwaysinline` to the generated LLVM IR for these functions eliminated the gap entirely: 785ms → 257ms, matching C's 260ms.

SHA-256 shows that pure bitwise computation (no collection overhead) compiles to near-C quality at `-O2`.

### What the numbers mean

- On text/parser workloads, Concrete at `-O2` is in the same band as Python and system tools. No performance apology needed.
- On hot-loop runtime code, the 3x gap to C was entirely caused by non-inlined vec builtin function calls. With `alwaysinline`, Concrete matches C.
- On pure computation (bitwise, arithmetic), LLVM `-O2` handles Concrete output well. No language-level overhead visible.

## Compiler Bugs Found and Fixed

Every bug below was discovered by a real program, not a synthetic test.

| Bug | Found by | Root cause | Fix |
|---|---|---|---|
| 005: enum-in-struct layout | Policy engine | Layout engine panic on enum fields in structs | Layout fix |
| 007: standalone print | Policy engine | No always-available print path for standalone examples | `print_string`, `print_int`, `print_char` builtins |
| 008: if-expression | Constants example | If-else not usable as expression | `ifExpr` AST node, lowering via alloca+condBr |
| 009: const lowering | Constants example | Constants not inlined | `constants` field in LowerState |
| 010: substring extraction | MAL interpreter | Missing `string_slice`/`string_substr` | Distinct intrinsics with correct semantics |
| 011: in-place string building | Policy engine, MAL | No mutation-oriented string APIs | `string_push_char`, `string_append` builtins |
| 012: standalone timing | MAL interpreter | No timing facility for benchmarks | `clock_monotonic_ns()` builtin |
| 013: alloca hoisting | JSON benchmark | `alloca` inside loops grows stack every iteration | `entryAllocas` field, entry-block emission |
| 014: string literal in loop | JSON benchmark | `ensureValAsPtr` missing `.strConst` case | Added case, routes through `materializeStrConst` |
| 015: missing `-O2` | JSON benchmark | Clang invoked without optimization flags | `-O2` now default for regular and test compilation |

Total: 11 compiler bugs found and fixed from 6 programs. This is strong evidence that real-program pressure is the most productive way to find bugs in this compiler.

## Language Features That Landed During Phase H

- **`string_reserve`** — pre-allocate string capacity, eliminated load-phase bottleneck
- **`Bytes.to_string()`** — zero-copy ownership transfer
- **Runtime argv** — `__concrete_get_argc()` / `__concrete_get_argv(idx)` via mutable LLVM globals
- **Scoped `defer`** — true scope-exit cleanup with LIFO ordering, covering block exit, loop iteration, break, continue, early return, nested scopes. Removed ~40 lines of cleanup boilerplate from the JSON parser.
- **`concrete build`** — project compilation from `Concrete.toml` with dependency resolution, directory modules, cross-module imports. `cgrep` and `conhash` converted to use `std.fs` imports.

## What Phase H Proved

### The language works for real programs

Six structurally different programs compiled and ran correctly. This is no longer a question.

### The differentiator is real

Concrete's visible authority + visible ownership discipline is not just a design aspiration — it shaped real code in useful ways:

- **JSON parser**: pure helpers are visibly pure, allocating functions visibly allocate, effectful output visibly declares capabilities. An auditor can see this from signatures alone.
- **conhash**: capability signatures *are* the security audit. `sha256() with(Alloc)` provably never touches the filesystem. `read_file_raw() with(File, Alloc)` cannot leak to the console. `report_*() with(Console)` cannot read files. Only `main()` and `verify_artifact()` bridge these boundaries.

The artifact verifier is the strongest demonstration: the capability annotations are not a side benefit — they are the point.

### `-O2` changes everything

The performance narrative before `-O2` was "Concrete is 3-4x slower than Python." After `-O2`: "Concrete matches Python on text workloads and is 19x faster on runtime-heavy code." This was the single highest-leverage discovery of Phase H.

### `defer` was high leverage

Scope-aware `defer` removed significant cleanup boilerplate without hiding ownership or destruction. The JSON parser dropped ~40 lines. Early-return paths became plain returns. This is evidence that explicit cleanup can become materially less noisy through library/workflow patterns rather than syntax growth.

### Real programs find real bugs

11 compiler bugs from 6 programs. Every bug was structurally interesting (layout panics, invalid IR, stack overflow from allocas, missing codegen cases). Synthetic test suites did not find these.

## What Phase H Left Open

### The central question

Not "can Concrete express real programs?" but "do its explicit patterns become stable idioms or stay as exhausting ceremony?"

Every program answered this partially:
- `defer` turned ceremony into idiom (evidence: JSON parser cleanup)
- `string_append` / `string_push_char` turned string building from painful to tolerable
- Capability signatures turned from overhead into audit value (evidence: conhash)

But some patterns remain genuinely verbose:
- Manual `drop_string` calls when `defer` isn't applicable
- No destructuring or pattern binding for non-enum types
- Multi-pool argument plumbing in complex programs
- Manual string building for formatted output

### Open findings carrying forward

1. **Formatting / interpolation** — `stdlib/runtime`, possibly `language`. Manual string building remains too verbose for real programs.
2. **Qualified module access** — `language`, `tooling/workflow`. No `Module.function()` path; name collisions required renaming (`hex_digit` → `conhash_hex_digit` in conhash).
3. **Collection hot-path performance** — `backend/performance`. ~~3.4x gap to C on VM dispatch loop.~~ **RESOLVED**: gap was caused by non-inlined vec builtins. Adding `alwaysinline` to generated LLVM IR eliminated it (785ms → 257ms, matching C's 260ms).
4. **Runtime-oriented collections** — `stdlib/runtime`. Interpreters want maps, nested mutable structures, frame-friendly patterns.
5. **Runtime argument surface** — `stdlib/runtime`. `argc`/`argv` work but the final user-facing shape is undecided.
6. **Destructuring let** — `language`. Parser/runtime code wants clearer binding of paired results.
7. **Runtime / stack pressure** — `backend/performance`, `stdlib/runtime`. Deep recursion limits not classified.

### What comes next

Phase J (package/project model) is the #1 priority:
- builtin std resolution (current path-based std is a temporary hack)
- `concrete build/test/run` maturity
- workspace support
- incremental compilation direction

Then: text/output ergonomics, collection hot-path performance, interop/product maturity.

## Standing Evaluation Criterion

For every serious program built after Phase H, ask:

- Are explicit authority and ownership patterns becoming stable idioms?
- Or are they remaining honest but exhausting ceremony?

That question is the most important ongoing evaluation criterion for the language.
