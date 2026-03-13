# Testing

Status: stable reference

This document describes the main test surfaces for Concrete and what each one is intended to catch.

## Main Suites

### Main End-to-End Suite

Primary entrypoint:

```bash
./run_tests.sh              # fast parallel (default)
./run_tests.sh --full       # complete suite
./run_tests.sh --filter X   # only tests matching X
```

Purpose:

- exercise the normal compile-and-run path
- validate language behavior end to end
- catch regressions in parsing, checking, elaboration, lowering, codegen, and runtime-facing builtins

Runs in `--fast` mode by default: parallel on all CPU cores, network tests skipped. Supports `--full`, `--filter`, `--stdlib`, `--stdlib-module`, `--O2`, `--codegen`, and `--report` for targeted runs. Partial runs display a clear warning with mode, filter, and skip count.

Current suite: 600 tests (189 stdlib), including 44 report assertions, 46 golden tests, and 16 collections verified.

### SSA-Specific Suite

Primary entrypoint:

```bash
bash test_ssa.sh
```

Purpose:

- exercise the SSA-based backend path explicitly
- catch regressions in lowering, SSA verification, SSA cleanup, and LLVM emission
- make sure SSA-specific behavior stays healthy even when the main suite passes

### In-Language Test Runner

The compiler has a built-in test runner invoked via `--test`:

```bash
./lake/build/bin/concrete file.con --test
```

This compiles all `#[test]` functions in the module (including submodules), generates a test-runner `main()`, and executes it. Each test function must:

- take no parameters
- not be generic
- return `i32` (0 = pass, non-zero = fail)

Example:

```
mod math {
    #[test]
    fn test_add() -> i32 {
        if 2 + 3 == 5 { return 0; }
        return 1;
    }
}
```

Output:

```
PASS: test_add
```

The process exits 0 if all tests pass, 1 if any fail.

## What The Tests Are For

- `run_tests.sh` = whole-language behavior and broad regression coverage (parallel by default, with fast/full/filter/targeted modes)
- `test_ssa.sh` = backend/SSA coverage
- `--test` flag = in-language test execution for `#[test]` functions

Both external suites matter. The main suite answers “does Concrete still work?” The SSA suite answers “does the real backend path still work correctly?” The `--test` flag is intended for module-level testing within user and stdlib code.

Stdlib tests run through the real compiler path via `concrete std/src/lib.con --test`. Module-targeted testing is available via `--stdlib-module <name>` (e.g., `--stdlib-module map`, `--stdlib-module string`), which runs `--test --module std.<name>` to target a single stdlib module without bootstrapping the whole tree.

## Golden / Inspection Tests

Concrete also has golden or inspection-oriented coverage around internal outputs such as:

- emitted Core
- emitted SSA
- compiler reports

These are useful for locking down architecture behavior even when user-visible output would not show a regression immediately.

Where report output is tested, prefer stable semantic assertions (sections, facts, counts, or field/value relationships) over brittle raw string snapshots whenever possible.

## Recommended Verification Flow

### Daily driver (default)

```bash
lake build && ./run_tests.sh
```

This runs `--fast` mode: parallel on all cores, network tests skipped. It is the standard developer workflow for edit-test loops. The summary clearly warns that it is a partial run.

### Pre-merge (full coverage)

```bash
lake build && ./run_tests.sh --full
```

Runs the complete suite including network/TCP tests. Use this before merging.

### Targeted workflows

```bash
./run_tests.sh --filter struct_loop   # only tests matching "struct_loop"
./run_tests.sh --stdlib               # only stdlib module + collection verification
./run_tests.sh --stdlib-module map    # only tests for stdlib module "map"
./run_tests.sh --O2                   # only -O2 optimized-build regressions
./run_tests.sh --codegen              # only codegen differential + SSA structure
./run_tests.sh --report               # only --report output verification
./run_tests.sh -j 1                   # serial execution (debug ordering issues)
```

Use `--filter` when iterating on a single area. Use `--stdlib` after touching `std/src/`. Use `--stdlib-module <name>` to iterate on one stdlib module (e.g., map, string, vec, fs, deque, bitset). Use `--O2` after lowering changes. Run `./run_tests.sh -h` for the full options reference.

### Other suites

```bash
bash test_ssa.sh                      # SSA-specific backend coverage
bash test_parser_fuzz.sh              # parser crash/hang fuzzing
```

## Parser Fuzzing

Primary entrypoint:

```bash
bash test_parser_fuzz.sh [iterations]
```

Purpose:

- generate random/malformed `.con` inputs (random bytes, random tokens, broken programs, corrupted valid programs)
- verify the parser never crashes (segfault, abort) or hangs (timeout)
- a clean compilation failure (exit 1 with error) is expected and fine

Default: 500 iterations with 5-second timeout per input.

## Property and Trace Tests

These tests exercise invariants beyond single-example happy paths:

- `fmt_parse_roundtrip.con` — round-trip property: `parse(format(x)) == x` for int ranges, powers of 10, and edge values
- `vec_trace.con` — Vec operation traces: push/get/set/length invariants, growth preservation, interleaved push/set
- `hashmap_trace.con` — HashMap operation traces: insert/get/remove/overwrite invariants, tombstone recovery, growth stress

## Bug Regression Corpus

Every real compiler bug should become a permanent regression test. These tests exist alongside the main suite and are named for the bug pattern they reproduce, not for the feature they exercise.

Current regression tests:

- `string_multi_fn.con` — string constant naming collision across multiple functions
- `if_else_while.con` — SSA domination error from then-branch variable leakage into else-branch
- `while_seq_scoping.con` — SSA domination error from while-loop body variables leaking past the exit block into subsequent loops

The goal is a named corpus rather than an accidental pile of old tests. When a bug is fixed, the regression test is added to `run_tests.sh` alongside the fix.

## Codegen Differential Tests

These tests assert specific properties of the compiler's intermediate representations (`--emit-ssa`, `--emit-llvm`, `--emit-core`), catching codegen regressions closer to their source rather than waiting for end-to-end output to accidentally change.

Located in the `=== Codegen differential tests ===` section of `run_tests.sh`.

### SSA optimization verification

- Constant folding: `codegen_constfold.con` — verifies `2 + 3` folds to `ret i64 5` with no residual `add i64`
- Strength reduction: `codegen_strength.con` — verifies `x * 8` becomes `shl i64 %x, 3` with no residual `mul i64`

### Codegen structure verification

- Struct field access: `struct_basic.con` — second field GEP at offset 8 (`gep i8 %p, i64 8`)
- Enum dispatch: `enum_basic.con` — tag loaded as `i32`, compared with `eq i1`
- Monomorphization naming: `report_mono_check.con` — `identity_for_Int` and `identity_for_i32` specializations exist
- LLVM struct types: `struct_basic.con` — `%struct.Point = type { i64, i64 }`
- Mutable borrow codegen: `borrow_mut.con` — `store i64` generated for mutable borrow write-back
- Aggregate promotion (loop): `struct_loop_field_assign.con` — `alloca %Point` present, no `phi %Point`
- Aggregate promotion (if/else): `struct_if_else_merge.con` — `alloca %Pair` present, no `phi %Pair`
- Aggregate promotion (match): `struct_match_merge.con` — `alloca %Pair` present, no `phi %Pair`

### Cross-representation consistency

- Packed struct: `report_layout_check.con` — LLVM `<{` syntax matches `--report layout` `#[packed]`
- Enum payload size: `report_layout_check.con` — LLVM `[N x i8]` payload matches `--report layout` `max_payload`
- Core-SSA agreement: `struct_basic.con` — Core IR preserves `fn sum_point(p: Point) -> Int`, SSA maps it to `define i64 @sum_point`

## Report Tests

Report tests verify the output of `--report` modes against expected content. Located in the `=== Report output tests ===` section of `run_tests.sh`.

Current coverage (44 assertions across 6 modes):

- **caps**: pure function detection, single/multi-capability, trusted extern, capability "why" traces (which callees contribute each cap)
- **unsafe**: trusted boundaries, trusted extern vs regular extern, raw pointer signatures, trust boundary analysis (what trusted functions wrap)
- **layout**: struct sizes/alignment, packed structs, enum tags/payload, runtime size cross-validation
- **interface**: public API exports, capability annotations, private function exclusion
- **mono**: generic function counts, specialization details
- **alloc**: allocation sources, cleanup patterns (free/defer), returned-allocation warnings, allocating function totals

Integration test programs:
- `report_integration.con` — exercises all 6 report modes with caps/unsafe/alloc/layout/interface/mono on a single program with pure functions, generic functions, trusted extern, trusted wrappers, and allocation patterns
- `integration_collection_pipeline.con` — multi-collection pipeline with Vec, generics, enums, structs, and mixed allocation patterns (alloc/free/defer); verifies both runtime correctness and report accuracy

## Future Refinement

The test structure may later become more explicitly layered, for example:

- parser-focused tests
- Core/Elab tests
- CoreCheck tests
- lowering/SSA tests
- codegen tests

But the current split already provides strong practical coverage:

- full end-to-end behavior (run_tests.sh positive/negative/abort tests)
- explicit SSA-path coverage (test_ssa.sh)
- golden baseline tests (test_golden.sh)
- report consistency tests (--report flag assertions)
- codegen differential tests (--emit-ssa/--emit-llvm/--emit-core assertions)
- parser fuzzing (test_parser_fuzz.sh)
- property and trace tests (fmt/parse round-trip, Vec/HashMap traces)

## Next Refinement

The current testing pipeline is good, but the next major improvement is not "add more shell flags." It is to make the loop smarter and cheaper.

The likely bottleneck is no longer the compiler frontend itself. It is repeated process startup, repeated `clang` work, and broad reruns when only a narrow scope changed.

The highest-value next steps are:

- artifact-aware test reuse instead of recompiling and rerunning everything through the full shell path
- dependency-aware narrower rerun scopes instead of relying only on string filters
- clearer test classes (`fast`, `unit`, `integration`, `optimization/regression`, `report/golden`, `slow/network/stress`) so local runs and CI can choose better defaults
- more real-program integration cases plus more property/fuzz/differential coverage

Promising implementation directions include:

- Lean-level unit tests for `Check`, `Elab`, `Lower`, and `EmitSSA` that avoid filesystem and linker overhead entirely
- faster integration execution paths that reduce per-test `clang` and process-spawn cost, as long as they preserve the semantic value of the current end-to-end suite
- artifact-driven caching and reuse once the pipeline artifact story is strong enough

The goal is a much tighter development loop without weakening the architectural coverage that the current suite already provides.
