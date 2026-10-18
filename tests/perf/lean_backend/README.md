# Factorial backend comparison

`factorial.con` is compiled from the same Concrete source through LLVM, the
experimental Lean Compiler Backend (LCB), and the retained original QBE 1.3.
The function uses explicit wrapping operations; the measured inputs, 0 through
20, have exact factorial results within signed 64-bit range.

From the integration worktree, after building Concrete and the backend with Nix:

```sh
nix develop -c env LCB_BIN=/private/tmp/concrete-lcb-result/bin/lcb QBE_SOURCE=/Users/unbalancedparen/projects/lean-compiler-backend/third_party/qbe python3 scripts/bench_lcb.py --iterations 10000000 --trials 9 --out /private/tmp/concrete-lcb-factorial.json
```

The script checks the retained QBE source hashes, uses the Nix C compiler at
`-O2` without LTO, and calls a separately compiled factorial function with changing
inputs in 1 through 20. Each invocation first checks 0! through 20!. The timed
region excludes startup and those checks, but includes the external function
call, input generation and checksum accumulation. Every timed checksum must
equal a separately calculated Python result. Trials interleave all three backends
in a reproducibly shuffled order. Raw reports retain samples, tool/source hashes,
host details and load averages. Build timings have different scopes and must not
be interpreted as compiler-speed comparisons.

The [dated integration note](../../../research/compiler/lean-backend-integration.md#factorial-runtime-baseline)
records the first measurements and their limits. Native ARM64 macOS execution is
required; this is a small runtime benchmark, not general application performance.
