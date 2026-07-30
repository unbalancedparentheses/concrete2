#!/usr/bin/env bash
# Multi-kernel evidence gate (spike/multi-prover-evidence).
#
# Locks the structural claims of `--report multi-kernel`:
#   * the linear no-overflow obligation graduates when kernels agree;
#   * the weakly-bounded obligation stays `unproven` across ALL kernels
#     (the "teeth": the badge is earned, not stamped);
#   * cells are three-valued — a dropped goal reads `not-asked`, never a
#     false `refused`; an absent tool reads `unavailable`/`off`.
#
# Skip-if-absent (matches check_assumptions.sh convention): the Lean baseline
# always runs; the Rocq and Isabelle assertions run only when coqc / isabelle
# are on PATH, so this gate passes in the default dev shell and does the full
# check under `nix develop .#provers`.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

COMPILER=".lake/build/bin/concrete"
if [ ! -x "$COMPILER" ]; then
  echo "error: compiler not found at $COMPILER. Run 'make build' first." >&2
  exit 2
fi

DEMO="examples/two_kernel_demo/src/main.con"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
# assert the report line for obligation $1 contains substring $2, in output $3
has(){ printf '%s' "$3" | grep -q -- "$2" && ok "$1: $2" || no "$1: expected '$2'"; }

FAMILIES="examples/two_kernel_demo/src/families.con"

echo "=== Lean baseline (no external kernels) ==="
BASE="$("$COMPILER" "$DEMO" --report multi-kernel 2>/dev/null)"
has "add_bounded" "lean:omega = closed"   "$BASE"
has "add_bounded" "=> proved_by_lean"     "$BASE"
has "mul_unbounded" "=> unproven"         "$BASE"
# externals not requested -> off, never a false verdict
has "off-cells" "rocq:lia = off"          "$BASE"

echo "=== bridge differential-check (feature #1): fuzzer teeth + soundness ==="
BC="$("$COMPILER" "$DEMO" --report bridge-check 2>/dev/null)"
# proved obligation: no counterexample
printf '%s' "$BC" | grep -A2 "add_bounded" | grep -q "no counterexample" \
  && ok "proved add_bounded: no concrete counterexample" || no "add_bounded should have no counterexample"
# unproved obligation: fuzzer finds a real overflow (teeth)
printf '%s' "$BC" | grep -A2 "mul_unbounded" | grep -q "violation found by fuzzer" \
  && ok "unproved mul_unbounded: fuzzer finds a real overflow (teeth)" || no "fuzzer should find mul_unbounded overflow"
# no PROVED obligation is ever refuted -> exit 0
"$COMPILER" "$DEMO" --report bridge-check >/dev/null 2>&1
[ $? -eq 0 ] && ok "bridge-check exits 0 (no proved obligation refuted)" || no "bridge-check should exit 0 here"

echo "=== all runtime-safety families flow through the layer (overflow/bounds/div) ==="
FAM="$("$COMPILER" "$FAMILIES" --report multi-kernel 2>/dev/null)"
has "bounds" "#bounds0"                    "$FAM"
has "div"    "#div0"                       "$FAM"
has "bounds" "0 ≤ i < 4"                   "$FAM"
has "div"    "d ≠ 0"                       "$FAM"

if command -v coqc >/dev/null 2>&1; then
  echo "=== Rocq (coqc/lia) present ==="
  R="$("$COMPILER" "$DEMO" --report multi-kernel --rocq 2>/dev/null)"
  has "add_bounded" "rocq:lia = closed"                  "$R"
  has "add_bounded" "=> proved_by_two_kernels (lean, rocq)" "$R"
  # teeth: no kernel can bound a*b, so it stays unproven even with Rocq
  printf '%s' "$R" | grep -A2 "mul_unbounded" | grep -q "=> unproven" \
    && ok "mul_unbounded stays unproven with Rocq (teeth)" \
    || no "mul_unbounded should stay unproven with Rocq"

  echo "=== not-asked vs refused (finding 1) ==="
  TMP="$(mktemp -d)"; mkdir -p "$TMP/src"
  cat > "$TMP/src/main.con" <<'EOF'
mod probe {
    #[overflow_checked]
    #[requires(0 <= a && a <= 100 && 0 <= b && b <= 100 && a / 2 <= 50)]
    fn add_with_div_hyp(a: i32, b: i32) -> i32 { return a + b; }
}
EOF
  P="$("$COMPILER" "$TMP/src/main.con" --report multi-kernel --rocq 2>/dev/null)"
  # a div hypothesis is outside the fragment -> the Rocq goal is dropped, so the
  # kernel is NOT asked. Must NOT read as a false disagreement ("refused").
  has "div-hyp" "rocq:lia = not-asked" "$P"
  rm -rf "$TMP"

  echo "=== bounds + div families reach Rocq too ==="
  FR="$("$COMPILER" "$FAMILIES" --report multi-kernel --rocq 2>/dev/null)"
  printf '%s' "$FR" | grep -A2 "#bounds0" | grep -q "rocq:lia = closed" \
    && ok "array-bounds obligation closed by Rocq" || no "bounds should close in Rocq"
  printf '%s' "$FR" | grep -A2 "#div0" | grep -q "rocq:lia = closed" \
    && ok "div-nonzero obligation closed by Rocq" || no "div should close in Rocq"

  echo "=== release gate: --require-two-kernels FAILS on an unprovable obligation (#4) ==="
  "$COMPILER" "$DEMO" --report multi-kernel --rocq --require-two-kernels >/dev/null 2>&1
  [ $? -eq 1 ] && ok "gate exits 1 when an obligation is below 2 kernels" \
                || no "gate should exit 1 on failure"

  if command -v z3 >/dev/null 2>&1; then
    echo "=== solver certificate-check (#2): solver_trusted -> solver_checked ==="
    SC="$("$COMPILER" examples/contract_negatives/lowering_operators/src/main.con --report solver-cert 2>/dev/null)"
    printf '%s' "$SC" | grep -q "=> solver_checked" \
      && ok "nonlinear VC: z3 corroborated by Rocq nia -> solver_checked" \
      || no "expected a solver_checked graduation"
  else
    echo "=== z3 absent — skipping solver-cert assertion ==="
  fi
else
  echo "=== Rocq absent — skipping coqc assertions ==="
fi

if command -v isabelle >/dev/null 2>&1; then
  echo "=== Isabelle (presburger) present ==="
  A="$("$COMPILER" "$DEMO" --report multi-kernel --all-provers 2>/dev/null)"
  has "add_bounded" "isabelle:presburger = closed" "$A"
  has "add_bounded" "=> proved_by_multi_kernel"    "$A"

  echo "=== ledger fold: obligation-ledger produces the multi-kernel class (#4) ==="
  L="$("$COMPILER" "$FAMILIES" --report obligation-ledger --all-provers 2>/dev/null)"
  printf '%s' "$L" | grep -q "proved_by_multi_kernel" \
    && ok "obligation-ledger folds proved_by_multi_kernel via a real ledger path" \
    || no "ledger should show proved_by_multi_kernel under --all-provers"
  echo "=== release gate PASSES when every obligation reaches >=2 kernels (#4) ==="
  "$COMPILER" "$FAMILIES" --report multi-kernel --all-provers --require-two-kernels >/dev/null 2>&1
  [ $? -eq 0 ] && ok "gate exits 0 when all obligations have >=2 kernels" \
                || no "gate should exit 0 when all pass"
else
  echo "=== Isabelle absent — skipping isabelle assertions ==="
fi

echo ""
echo "MULTI-KERNEL: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
