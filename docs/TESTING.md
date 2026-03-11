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

## Future Refinement

The test structure may later become more explicitly layered, for example:

- parser-focused tests
- Core/Elab tests
- CoreCheck tests
- lowering/SSA tests
- codegen tests

But the current split already provides the two most important practical checks:

- full end-to-end behavior
- explicit SSA-path coverage
