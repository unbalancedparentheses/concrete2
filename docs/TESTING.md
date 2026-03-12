# Testing

Status: stable reference

This document describes the main test surfaces for Concrete and what each one is intended to catch.

## Main Suites

### Main End-to-End Suite

Primary entrypoint:

```bash
bash run_tests.sh
```

Purpose:

- exercise the normal compile-and-run path
- validate language behavior end to end
- catch regressions in parsing, checking, elaboration, lowering, codegen, and runtime-facing builtins

This is the broadest regression suite and the main “does the compiler still work?” check.

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

- `run_tests.sh` = whole-language behavior and broad regression coverage
- `test_ssa.sh` = backend/SSA coverage
- `--test` flag = in-language test execution for `#[test]` functions

Both external suites matter. The main suite answers “does Concrete still work?” The SSA suite answers “does the real backend path still work correctly?” The `--test` flag is intended for module-level testing within user and stdlib code.

## Golden / Inspection Tests

Concrete also has golden or inspection-oriented coverage around internal outputs such as:

- emitted Core
- emitted SSA
- compiler reports

These are useful for locking down architecture behavior even when user-visible output would not show a regression immediately.

## Recommended Verification Flow

For normal compiler work:

```bash
make build
bash run_tests.sh
bash test_ssa.sh
```

Use more targeted tests or inspection output when working on:

- lowering / SSA cleanup
- diagnostics rendering
- layout / ABI
- report generation

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

### Cross-representation consistency

- Packed struct: `report_layout_check.con` — LLVM `<{` syntax matches `--report layout` `#[packed]`
- Enum payload size: `report_layout_check.con` — LLVM `[N x i8]` payload matches `--report layout` `max_payload`
- Core-SSA agreement: `struct_basic.con` — Core IR preserves `fn sum_point(p: Point) -> Int`, SSA maps it to `define i64 @sum_point`

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
