#!/usr/bin/env bash
# Enum union layout gate (audit 2026-07-16).
#
# The canonical builtin Option/Result union is shared by ALL instantiations of
# the program, so it must cover the worst ALIGNMENT-AWARE footprint
# (`end = alignUp 4 align + size`), not merely the worst tySize; and every
# alloca of an enum whose payloads need 8-byte alignment must carry an
# explicit `align 8` (the `{ i32, [N x i8] }` union declaration only carries
# 4-byte alignment, while payload loads/stores assume natural alignment).
# The byte-array storage itself is deliberate: aggregate load/store of a
# partially-initialized union is poison-safe only at byte granularity.
#
# Locks the class: footprint coverage, alloca alignment, and no align bloat
# for align-1-only programs.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fresh.sh"
require_fresh_binary || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
C="$ROOT_DIR/.lake/build/bin/concrete"
[ -x "$C" ] || { echo "error: build first ($C missing)" >&2; exit 2; }
# RUN THE COMPILED ARTIFACT, not a JIT interpretation of the IR.
#
# This leg used `lli`, and `lli` from LLVM 21.1.8 cannot run this program at all: the ORC path dies
# with `Symbol "orc_rt_alt_UnwindInfoManager_register" not found in bootstrap symbols map`,
# `--jit-kind=mcjit` reports no available targets, and `--force-interpreter` aborts with
# `Cannot load value of type %enum.Option` — which is precisely the aggregate this fixture exists to
# exercise. The emitted IR was fine throughout; the runner was not.
#
# Compiling with `clang` and executing the result gives 42007 immediately, and is a better test on
# its own terms: it exercises the artifact the compiler actually ships rather than an interpretation
# of the IR, and the interpreter's inability to load an aggregate says nothing about the layout.
# `lli` is kept as a fallback for environments without clang.
CC="$(command -v clang || command -v cc || true)"
LLI="$(command -v lli || true)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIX="$ROOT_DIR/tests/programs/regress_enum_canonical_align.con"
"$C" "$FIX" --emit-llvm > "$TMP/fix.ll" 2>"$TMP/fix.err" || { no "fixture compiles ($(head -1 "$TMP/fix.err"))"; echo "ENUM-UNION-LAYOUT: PASS=$PASS FAIL=$FAIL"; exit 1; }

# 1. Footprint coverage: worst end is Option<[i64;3]> at 8+24=32 → [28 x i8].
if grep -q '%enum.Option = type { i32, \[28 x i8\] }' "$TMP/fix.ll"; then
  ok "union covers worst footprint ({ i32, [28 x i8] })"
else
  no "union footprint (want { i32, [28 x i8] }, got: $(grep '%enum.Option = type' "$TMP/fix.ll"))"
fi

# 2. Every %enum.Option alloca carries align 8 (payloads need it here).
total=$(grep -c 'alloca %enum.Option' "$TMP/fix.ll" || true)
aligned=$(grep -c 'alloca %enum.Option, align 8' "$TMP/fix.ll" || true)
if [ "$total" -gt 0 ] && [ "$total" = "$aligned" ]; then
  ok "all $total enum allocas carry align 8"
else
  no "alloca alignment ($aligned of $total enum allocas have align 8)"
fi

# 3. Behavioral: reads back the high-alignment payload correctly.
if [ -n "$CC" ]; then
  if "$CC" -o "$TMP/fix.exe" "$TMP/fix.ll" 2>"$TMP/cc.err"; then
    out="$("$TMP/fix.exe" 2>/dev/null || true)"
    if [ "$out" = "42007" ]; then ok "compiled fixture runs: $out"; else no "compiled fixture runs (want 42007, got '$out')"; fi
  else
    no "the emitted IR did not compile: $(head -1 "$TMP/cc.err")"
  fi
elif [ -n "$LLI" ]; then
  out="$("$LLI" "$TMP/fix.ll" 2>/dev/null || true)"
  if [ "$out" = "42007" ]; then ok "fixture runs under lli: $out"; else no "fixture runs (want 42007, got '$out')"; fi
else
  # NOT A SKIP. Without a compiler or a JIT the behavioural property is UNVERIFIED, and a gate that
  # prints "skip" and still reports FAIL=0 says the layout was checked when only its shape was. The
  # two legs above read the emitted IR; nothing above this line observes the program computing the
  # right answer.
  no "no clang/cc and no lli — the behavioural leg did NOT run, so the payload read-back is unverified"
fi

# 4. Align-1-only program: no align attribute, byte-exact old shape.
cat > "$TMP/lo.con" <<'EOF'
enum Option<T> {
    Some { value: T },
    None
}

fn main() with(Console) -> Int {
    let a: [u8; 24] = [7; 24];
    let arr: Option<[u8; 24]> = Option::Some { value: a };
    match arr {
        Option::Some { value } => { print_int(value[0] as Int); },
        Option::None {} => { print_int(-2); },
    }
    return 0;
}
EOF
"$C" "$TMP/lo.con" --emit-llvm > "$TMP/lo.ll" 2>"$TMP/lo.err" || { no "align-1 fixture compiles"; echo "ENUM-UNION-LAYOUT: PASS=$PASS FAIL=$FAIL"; exit 1; }
if grep -q '%enum.Option = type { i32, \[24 x i8\] }' "$TMP/lo.ll" \
   && ! grep -q 'alloca %enum.Option, align' "$TMP/lo.ll"; then
  ok "align-1-only: byte-exact union, no align attribute"
else
  no "align-1-only shape ($(grep '%enum.Option = type' "$TMP/lo.ll"); $(grep 'alloca %enum.Option' "$TMP/lo.ll" | head -1))"
fi

echo "ENUM-UNION-LAYOUT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
