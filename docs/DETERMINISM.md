# Compiler Determinism

Status: verified — all compiler output paths are deterministic given the same source and toolchain.

## Guarantee

The same source file compiled with the same Concrete compiler binary produces identical output across runs for all artifact families:

| Output path | Flag | Status |
|---|---|---|
| All 17 report modes | `--report <mode>` | Deterministic |
| All query modes | `--query <kind>` | Deterministic |
| LLVM IR | `--emit-llvm` | Deterministic |
| SSA IR | `--emit-ssa` | Deterministic |
| Core IR | `--emit-core` | Deterministic |
| Compiled binary | `-o <path>` | Deterministic (LLVM codegen) |
| Snapshot JSON | `snapshot` | Deterministic except `timestamp` field |

## Why It Works

The compiler avoids the classic nondeterminism sources:

1. **No HashMap/HashSet iteration in output paths.** All internal collections are `List`-based. Function ordering follows source order throughout the pipeline.
2. **No random values in output.** No `IO.rand` or PRNG usage in artifact generation.
3. **No environment-dependent data in artifacts.** No absolute paths, PIDs, or machine identifiers in output.
4. **Explicit sorting where needed.** Capabilities are sorted via `mergeSort` in `CapSet.normalize`. Fact lists are concatenated in fixed order in `collectCoreFacts`.
5. **Deterministic register naming.** SSA register names use a monotonic counter (`ssa.t0`, `ssa.t1`, ...).
6. **Deterministic fingerprints.** Body fingerprints are computed by structural string concatenation over normalized syntax trees, with no hashing or randomization.

## Known Non-Deterministic Fields

| Field | Location | Why | Handling |
|---|---|---|---|
| `timestamp` in snapshot JSON | `Main.lean` snapshot command | Intentional metadata — records when the snapshot was taken | Strip before comparison with `concrete diff` or `jq 'del(.timestamp)'` |
| Temp file paths | `Main.lean` `--test` mode | Internal, not in output artifacts | Not visible to users |

## Cross-Version Determinism

Determinism is guaranteed **within the same compiler version**. Across versions:

- Report text/format may change
- Fingerprint values may change (extraction or normalization changes)
- JSON schema may evolve
- LLVM IR may change (lowering/codegen changes)

The snapshot `concrete diff` command is the intended tool for detecting cross-version drift.

## Verification

The deterministic artifact regression suite (`scripts/tests/test_determinism.sh`) verifies byte-for-byte reproducibility across all output paths on every test run.
