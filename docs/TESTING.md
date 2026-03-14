# Testing

Status: stable reference

This document describes the test architecture, coverage matrix, determinism policy, and execution model for Concrete.

## Test Architecture

The test system has four layers, ordered by cost:

| Layer | Tool | Cost | What it catches |
|-------|------|------|-----------------|
| **Pass-level** | `PipelineTest.lean` (Lean executable) | <1s, no I/O | Parse errors, type errors, elaboration bugs, monomorphization bugs, SSA verify/cleanup invariants, emit correctness |
| **Artifact** | `run_tests.sh --report`, `--codegen` | ~1s each, no clang | Report output regressions, SSA structure, LLVM IR shape, codegen differentials |
| **End-to-end** | `run_tests.sh` positive/negative | ~0.5s each, needs clang | Full compile-and-run behavior, runtime correctness |
| **Stress/integration** | `run_tests.sh` integration tests | ~1s each, needs clang | Multi-feature interactions, deep call chains, realistic programs |

### Pass-Level Lean Tests

`PipelineTest.lean` exercises individual compiler passes directly on in-memory source strings. No subprocess, no clang, no file I/O.

Current coverage (28 tests):
- **Parse (4)**: valid programs parse, malformed input rejected
- **Frontend (8)**: parse→check→elaborate on structs/enums/traits/generics, type errors and undefined vars rejected
- **Monomorphize (2)**: generic and trait programs monomorphize
- **SSA Lowering (2)**: `lowerModule` produces functions with blocks
- **SSA Verify (3)**: `ssaVerifyProgram` accepts valid SSA from simple/enum/generic programs
- **SSA Cleanup (2)**: `ssaCleanupProgram` runs without crash, double-cleanup is idempotent
- **SSA Emit (2)**: `emitSSAProgram` produces LLVM IR, test mode works
- **Full pipeline (5)**: source → LLVM IR for 5 program shapes

Run: `lake build pipeline-test && .lake/build/bin/pipeline-test`

### Artifact Tests

Report and codegen tests consume cached compiler output without invoking clang.

- **Report tests (44 assertions)**: content checks across all 6 `--report` modes (caps, unsafe, layout, interface, mono, alloc)
- **Codegen differential tests**: SSA optimization verification (constant folding, strength reduction), codegen structure (GEP offsets, enum tags, aggregate promotion), cross-representation consistency (packed struct, enum payload, Core→SSA agreement)

Compiler output is cached by `(file, flags)` key. Multi-assertion report tests reuse a single compilation (26/57 cache hits per fast run).

### End-to-End Tests

Compile-and-run tests in `lean_tests/`:
- **Positive (182)**: compile, run, check exit code matches expected value
- **Negative (151)**: compile, expect specific error message in stderr
- **Abort (1)**: compile, run, expect crash
- **Test flag (4)**: `--test` mode with pass/fail/mixed/submodule programs
- **O2 (5)**: same programs compiled with `-O2`, check same results

### Stdlib Tests

189 `#[test]` functions across all stdlib modules, compiled through the real compiler path. Module-targeted testing via `--stdlib-module <name>`.

15 collection modules verified for test presence and correctness.

### Integration / Stress Tests

Named real-program corpus:
- `integration_text_processing.con` — string/parsing pipeline
- `integration_data_structures.con` — struct/enum data flow
- `integration_error_handling.con` — Result/Option error chains
- `integration_generic_pipeline.con` (~150 lines) — 5-layer borrow chain, trait dispatch, complex enum matching
- `integration_state_machine.con` (~170 lines) — 4-state × 5-command nested match, struct construction in match arms
- `integration_compiler_stress.con` (~200 lines) — deep generic instantiation, multi-trait dispatch, nested enum matching
- `integration_multi_module.con` + `helper.con` — cross-module types, traits, and enum matching
- `integration_recursive_structures.con` (~200 lines) — recursive expression evaluation, stack-based computation

## Coverage Matrix

### By failure mode

| Failure mode | Test layer | Test count | Key tests |
|-------------|-----------|-----------|-----------|
| Parser crash/hang | Fuzz | 500 iter | `test_parser_fuzz.sh` |
| Parse rejection | Pass-level + E2E | 4 + ~20 | `parse/*`, `error_resolve_*` |
| Name resolution | Pass-level + E2E | 2 + ~10 | `frontend/*`, `error_resolve_*`, `module_*` |
| Type/capability errors | Pass-level + E2E | 8 + ~60 | `frontend/*`, `error_type_*`, `error_cap_*`, `error_borrow_*` |
| Linearity violations | E2E | ~15 | `error_unconsumed*`, `error_use_after_*`, `error_linear_*`, `linear_*` |
| Elaboration/trait bugs | Pass-level + E2E | 2 + ~20 | `mono/*`, `trait_*`, `generic_*`, `error_trait_*` |
| Lowering invariants | Pass-level + E2E | 5 + ~30 | `lower/*`, `verify/*`, `struct_*`, `enum_*`, `regress_*` |
| SSA verification | Pass-level | 3 | `verify/valid-*` |
| SSA cleanup | Pass-level | 2 | `cleanup/*` |
| Codegen structure | Artifact | ~16 | `codegen_*`, struct/enum GEP/tag checks |
| LLVM emission | Pass-level + Artifact | 2 + ~10 | `emit/*`, cross-representation checks |
| Runtime behavior | E2E | ~180 | All positive run_ok tests |
| -O2 regressions | E2E | 5 | `struct_loop_*`, `struct_nested_*`, `struct_if_else_*` |
| Report accuracy | Artifact | 44 | `report_integration.con`, `report_*_check.con` |
| Stdlib correctness | Stdlib | 189 | All `#[test]` functions |
| Collection integrity | Stdlib | 15 modules | Collection verification section |
| Multi-module | E2E | 22 | `module_*`, `summary_*`, `module_file/` |
| Formatter | Property | 4 | `fmt_parse_roundtrip.con`, golden tests |

### By compiler pass

| Pass | Direct pass-level tests | Owned E2E tests | Total coverage |
|------|------------------------|----------------|---------------|
| `parse` | 4 | ~20 | Strong |
| `resolve` | (via frontend) | ~12 | Moderate |
| `check` | (via frontend) | ~60 | Strong |
| `elab` | (via frontend) | ~20 | Moderate |
| `core_check` | (via frontend) | ~10 | Moderate |
| `mono` | 2 | ~15 | Moderate |
| `lower` | 2 | ~30 | Strong |
| `ssa_verify` | 3 | ~5 | Moderate |
| `ssa_cleanup` | 2 | ~5 | Moderate |
| `emit_ssa` | 2 | ~180 | Strong |
| `report` | — | 44 | Strong |
| `format` | — | 4 | Light |

## Dependency-Aware Test Selection

### `--affected` mode

`run_tests.sh --affected` detects changed files via `git diff` and selects only the test sections that exercise those compiler passes.

```bash
./run_tests.sh --affected                     # auto-detect from git diff
./run_tests.sh --affected Concrete/Lower.lean  # explicit file list
```

The mapping from compiler source files to test sections lives in `test_dep_map.toml`. The mapping is conservative — when in doubt, more sections run.

Example mappings:
- `Concrete/Check.lean` → positive, negative, passlevel (type/cap/linearity tests)
- `Concrete/Lower.lean` → positive, codegen, O2, passlevel (lowering + backend tests)
- `Concrete/Report.lean` → report (report output tests only)
- `std/src/*` → stdlib, collection (stdlib tests only)
- Unknown files → full suite (safe fallback)

### Explanation

After an `--affected` run, the summary shows which files triggered which sections:

```
=== Affected mode ===
  changed files: Concrete/Lower.lean,Concrete/SSACleanup.lean
  sections: codegen,O2,passlevel,positive
```

## Structured Test Metadata

### Manifest

`test_manifest.toml` is the structured source of truth for test metadata. Each test entry includes:

- `file` — path relative to repo root
- `category` — semantic category (`unit`, `semantic`, `lowering`, `codegen`, `report`, `integration`, `stress`, `stdlib`, `regression`, `property`, `fuzz`)
- `kind` — execution kind (`run_ok`, `run_err`, `run_abort`, `run_test`, `check_report`, `check_codegen`, `check_O2`, `lean_pass`)
- `passes` — which compiler passes this test exercises
- `profile` — run profile (`fast`, `slow`, `network`)
- `expected` — expected output
- `owner_pass` — primary compiler pass whose correctness this test defends
- `needs_clang` — whether clang is needed
- `multi_module` — whether the test uses `mod X;` file imports

### Dependency Map

`test_dep_map.toml` maps compiler source files to affected test sections and categories. Used by `--affected` mode.

## Determinism and Flakiness Policy

### Rules

1. **Fixed seeds**: all randomized tests use fixed seeds unless deliberately exploring. `test_parser_fuzz.sh` uses `$RANDOM` seeded from iteration count, not wall-clock time.

2. **No wall-clock dependence**: no test depends on absolute time, execution speed, or timing. `std.time` tests check only that monotonic clock moves forward, not that specific durations elapse.

3. **Timeout classes**: tests have three implicit timeout tiers:
   - Fast tests: 10s (most E2E tests)
   - Slow tests: 30s (compilation + complex runtime)
   - Network tests: 60s (TCP round-trip with fork/accept)

4. **Network isolation by default**: `--fast` mode (the default) skips all network tests. Network tests run only under `--full`. The `SKIP_FLAKY_TCP_TEST=1` environment variable provides an additional escape hatch.

5. **Stable temp directory handling**: test artifacts use `$TMPDIR` or `/tmp`, never the working directory. Compiler output cache uses a per-run temp directory cleaned up on exit.

6. **Parallel safety**: all tests are independent. No test reads another test's output or depends on execution order. The test runner uses job-based parallelism (`-j N`) without shared mutable state between test processes.

7. **Quarantine/repair expectations**: if a test becomes flaky:
   - Identify the non-determinism source (timing, file system, network, uninitialized memory)
   - Fix the root cause or move the test to `--full` only
   - Do not delete or skip flaky tests without a tracking comment
   - The `SKIP_FLAKY_TCP_TEST` pattern is the model for temporary quarantine

### Known flakiness risks

- **TCP round-trip test**: depends on `fork()` + local socket bind. Can fail under port contention or slow CI. Quarantined behind `--full` and `SKIP_FLAKY_TCP_TEST`.
- **Parser fuzz**: timeout-based crash detection could theoretically race on very slow machines. The 5s timeout is generous for the parser's workload.

## Compile-Time and Suite-Time Baselines

### Current baselines (as of Phase D1)

| Metric | Value |
|--------|-------|
| Pass-level tests | <1s (28 tests, no I/O) |
| Fast suite (`--fast`) | ~25-35s (635 tests, parallel) |
| Full suite (`--full`) | ~40-50s (637 tests, includes network) |
| Cache hit rate | 26/57 compilations saved per fast run |
| Compiler build | ~30-45s (`lake build`) |
| lli-accelerated suite | ~12s (when `LLI_PATH` is set) |

### Tracking

Suite time is not yet automatically tracked between runs. The baselines above are manual snapshots. Future work: record timing per section in the summary output and warn on regressions beyond a threshold.

## Failure Isolation

### Artifact preservation

Failed tests automatically save artifacts to `.test-failures/`:
- Timestamped output (stdout + stderr)
- Exact rerun command
- Compiler flags used

Example:
```
$ cat .test-failures/lean_tests_struct_basic_con
# Failure: lean_tests/struct_basic.con
# Time: 2026-03-13 14:22:01
# Rerun: .lake/build/bin/concrete lean_tests/struct_basic.con -o /tmp/test_rerun && /tmp/test_rerun
<compiler output>
```

### Dependency gates

Report test groups use `compile_gate()` to skip downstream assertions when compilation fails. This prevents cascading false failures and makes the first error obvious.

## Execution Modes

| Mode | Sections | Use case |
|------|----------|----------|
| `--fast` (default) | all except network | Daily driver |
| `--full` | everything | Pre-merge |
| `--affected` | auto-detected | After specific compiler changes |
| `--affected FILE` | mapped sections | Targeted rerun |
| `--filter PAT` | all, filtered by path | Iterate on one area |
| `--stdlib` | stdlib + collection | After stdlib changes |
| `--stdlib-module M` | one stdlib module | Iterate on one module |
| `--O2` | O2 regressions | After lowering changes |
| `--codegen` | codegen + O2 | After backend changes |
| `--report` | report | After report changes |

## Recommended Verification Flow

### Daily driver (default)

```bash
lake build && ./run_tests.sh
```

Runs `--fast` mode: parallel on all cores, network tests skipped.

### After changing a specific compiler pass

```bash
lake build && ./run_tests.sh --affected
```

Auto-detects changed files and runs only affected test sections.

### Pre-merge (full coverage)

```bash
lake build && ./run_tests.sh --full
```

### Targeted workflows

```bash
./run_tests.sh --filter struct_loop   # iterate on one area
./run_tests.sh --stdlib               # after touching std/src/
./run_tests.sh --stdlib-module map    # iterate on one stdlib module
./run_tests.sh --O2                   # after lowering changes
./run_tests.sh --codegen              # after backend changes
./run_tests.sh --report               # after report changes
./run_tests.sh -j 1                   # debug ordering issues
```

### Other suites

```bash
bash test_ssa.sh                      # SSA-specific backend coverage
bash test_parser_fuzz.sh              # parser crash/hang fuzzing
```
