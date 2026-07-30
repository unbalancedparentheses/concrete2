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

  echo "=== lowering agreement: each kernel's rendering means the SAME proposition ==="
  # Ground-pinned instances of the driver's own rendering, decided by the prover and
  # compared against the independent concrete evaluator. Exit 0 = every rendering
  # checked has the reference truth table.
  "$COMPILER" "$DEMO" --report lowering-agreement --rocq >/dev/null 2>&1
  [ $? -eq 0 ] && ok "demo: rocq lowering agrees with the reference evaluator" \
                || no "demo: rocq lowering should agree"
  "$COMPILER" "$FAMILIES" --report lowering-agreement --rocq >/dev/null 2>&1
  [ $? -eq 0 ] && ok "families (overflow+bounds+div): rocq lowerings all agree" \
                || no "families: rocq lowerings should agree"
  AG="$("$COMPILER" "$FAMILIES" --report lowering-agreement --rocq 2>/dev/null)"
  # every family must actually be CHECKED, not silently skipped
  for k in "#ovf0" "#bounds0" "#div0"; do
    printf '%s' "$AG" | grep -q -- "$k" \
      && ok "agreement check covers $k" || no "agreement check should cover $k"
  done
  # a kernel not requested must not be silently reported as agreeing
  printf '%s' "$AG" | grep -q "isabelle:presburger: off" \
    && ok "un-requested kernel reads 'off', not 'agrees'" \
    || no "un-requested kernel should read 'off'"

  echo "=== verdict classification: 'refused' vs 'error' rests on real coqc markers ==="
  # The classifier calls a nonzero coqc exit `refused` ONLY on a tactic-failure
  # marker; anything else is `error` (our bug). Both exit 1, so this locks the
  # empirical assumption — if Rocq renames these messages, this fails loudly rather
  # than silently turning our own broken scripts into "the kernel disagrees".
  MKTMP="$(mktemp -d)"
  cat > "$MKTMP/refuse.v" <<'EOF'
From Stdlib Require Import ZArith.
From Stdlib Require Import Lia.
Open Scope Z_scope.
Goal forall (a b : Z), (-2147483648 <= (a * b) /\ (a * b) <= 2147483647).
Proof. lia. Qed.
EOF
  cat > "$MKTMP/broken.v" <<'EOF'
From Stdlib Require Import ZArith.
From Stdlib Require Import Lia.
Open Scope Z_scope.
Goal forall (a b : Z), (a ~= b).
Proof. lia. Qed.
EOF
  R_OUT="$(cd "$MKTMP" && coqc -native-compiler no refuse.v 2>&1)"
  printf '%s' "$R_OUT" | grep -q "Tactic failure" \
    && ok "a genuine lia refusal still prints 'Tactic failure'" \
    || no "lia refusal marker changed — classifyRocqFailure needs updating"
  B_OUT="$(cd "$MKTMP" && coqc -native-compiler no broken.v 2>&1)"
  printf '%s' "$B_OUT" | grep -q "Tactic failure" \
    && no "a malformed script must NOT look like a tactic failure" \
    || ok "a malformed script does not print 'Tactic failure' (reads as error)"
  rm -rf "$MKTMP"

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

  echo "=== lowering agreement holds for the HOL kernel too ==="
  # Isabelle is the case that motivated pinning variables rather than substituting
  # literals: an unquantified proposition gets a fresh free type variable per numeral
  # (0 <= (100::'b)), so the lemma stops being about integers and presburger cannot
  # prove it. This asserts the typed binder survives into the agreement instances.
  "$COMPILER" "$FAMILIES" --report lowering-agreement --isabelle >/dev/null 2>&1
  [ $? -eq 0 ] && ok "families: isabelle lowerings agree with the reference evaluator" \
                || no "families: isabelle lowerings should agree (typed binder retained?)"
  "$COMPILER" "$DEMO" --report lowering-agreement --rocq --isabelle >/dev/null 2>&1
  [ $? -eq 0 ] && ok "demo: rocq AND isabelle lowerings both agree" \
                || no "demo: both lowerings should agree"

  echo "=== [policy] require-two-kernels is first-class, not just a CLI flag ==="
  # The release requirement lives in the package's Concrete.toml, so it holds for
  # `concrete build` regardless of which flags a CI job happens to pass.
  ( cd examples/multi_kernel_policy/allow && "$ROOT_DIR/$COMPILER" build -o /tmp/mkp_allow_gate >/dev/null 2>&1 )
  [ $? -eq 0 ] && ok "policy project whose obligations all reach 2 kernels BUILDS" \
                || no "allow project should build under require-two-kernels"
  BLK="$( cd examples/multi_kernel_policy/blocked && "$ROOT_DIR/$COMPILER" build -o /tmp/mkp_blocked_gate 2>&1 )"
  rc=$?
  [ $rc -ne 0 ] && ok "policy project with an unprovable obligation is REJECTED" \
                || no "blocked project should be rejected under require-two-kernels"
  printf '%s' "$BLK" | grep -q "E0616" \
    && ok "rejection carries the policy code E0616" || no "expected E0616"

  echo "=== certificate REPLAY: the solver's proof is kernel-checked, not stamped ==="
  # The solver-cert report can only ever show `solver_replayed` if this mechanism
  # works, and `solver_replayed` must be REACHABLE or the class is dead code. The
  # nonlinear VCs the report selects cannot be reconstructed (asserted below), so the
  # mechanism is exercised here directly, in the exact shape the driver emits.
  RTMP="$(mktemp -d)"
  printf 'session VCsess = HOL +\n  theories VC\n' > "$RTMP/ROOT"
  write_replay_thy() {  # $1 = oracle flag, $2 = goal body
    cat > "$RTMP/VC.thy" <<EOF
theory VC imports Main begin
declare [[smt_oracle = $1, smt_timeout = 60]]
lemma replayed: "$2"
  by (smt (verit))
ML \\<open>
  val n = length (Thm_Deps.all_oracles [@{thm replayed}]);
  val _ = if n = 0 then writeln "REPLAY-VERIFIED: no oracle"
          else error "ORACLE PRESENT - proof was stamped, not checked";
\\<close>
end
EOF
  }
  LINEAR_GOAL='ALL a b::int. (0 <= a & a <= 100) --> (0 <= b & b <= 100) --> a + b <= 200'
  write_replay_thy false "$LINEAR_GOAL"
  ( cd "$RTMP" && isabelle build -D . >/dev/null 2>&1 )
  [ $? -eq 0 ] && ok "a LINEAR goal replays: veriT's proof reconstructed, asserted oracle-free" \
                || no "linear replay should succeed (is VERIT_SOLVER set? see flake.nix)"
  # Teeth: with smt_oracle = true the method STAMPS the goal instead of checking it.
  # That is the exact trust leak replay exists to close, so it must FAIL here.
  write_replay_thy true "$LINEAR_GOAL"
  ORC="$( cd "$RTMP" && isabelle build -D . 2>&1 )"
  printf '%s' "$ORC" | grep -q "ORACLE PRESENT" \
    && ok "smt_oracle = true is DETECTED and rejected (stamping cannot pass as replay)" \
    || no "oracle mode must be rejected — the no-oracle assertion has no teeth"
  # Locks the measured limitation. If Isabelle ever reconstructs nonlinear
  # arithmetic, this fails loudly and solver_replayed becomes reachable for the
  # nonlinear VCs — which is a capability upgrade we want to be told about.
  write_replay_thy false 'ALL a::int. 0 <= a --> 0 <= a * a'
  ( cd "$RTMP" && isabelle build -D . >/dev/null 2>&1 )
  [ $? -ne 0 ] && ok "NONLINEAR replay still unsupported (documented ceiling holds)" \
                || no "nonlinear replay now WORKS — upgrade solver-cert to reach solver_replayed"
  rm -rf "$RTMP"

  echo "=== isabelle refusal vs malformed-theory markers (classifier assumption) ==="
  ITMP="$(mktemp -d)"
  printf 'session VCsess = HOL +\n  theories VC\n' > "$ITMP/ROOT"
  printf 'theory VC imports Main begin\nlemma "ALL a b::int. (-2147483648 <= (a * b) & (a * b) <= 2147483647)"\n  by presburger\nend\n' > "$ITMP/VC.thy"
  I_OUT="$(cd "$ITMP" && isabelle build -D . 2>&1)"
  printf '%s' "$I_OUT" | grep -q "Failed to apply initial proof method" \
    && ok "a genuine presburger refusal still prints 'Failed to apply initial proof method'" \
    || no "isabelle refusal marker changed — classifyIsabelleFailure needs updating"
  printf 'theory VC imports Main begin\nlemma "ALL a b::int. (a <=> b)"\n  by presburger\nend\n' > "$ITMP/VC.thy"
  I_BAD="$(cd "$ITMP" && isabelle build -D . 2>&1)"
  printf '%s' "$I_BAD" | grep -q "Failed to apply initial proof method" \
    && no "a malformed theory must NOT look like a proof-method failure" \
    || ok "a malformed theory does not print the refusal marker (reads as error)"
  rm -rf "$ITMP"
else
  echo "=== Isabelle absent — skipping isabelle assertions ==="
fi

echo ""
echo "MULTI-KERNEL: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
