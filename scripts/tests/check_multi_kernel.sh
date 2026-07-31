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
PASS=0; FAIL=0; INCONC=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
# An assertion that could not be evaluated — the tool never ran far enough to say
# anything about the property. Counted and printed separately because "the property
# is wrong" and "I could not test it" are different facts, and reporting the second
# as the first is exactly the conflation this gate exists to prevent (see the
# `refused` vs `error` distinction in Main.lean). Never silently green: the count is
# in the summary line.
inconc(){ echo "  INCONC $1"; INCONC=$((INCONC+1)); }

# Run `isabelle build` in directory $1, retrying transient failures, and classify:
#   0 = built (every proof in the session succeeded)
#   1 = Isabelle RAN and reported a real diagnostic about the theory
#   2 = could not run to a diagnostic (heap contention, killed, session error)
# Leaves the last attempt's combined output in ISA_OUT.
#
# Discriminated on a POSITIVE list of theory-level markers, not on the `***` prefix:
# Isabelle prefixes session/infrastructure errors that way too (`*** Bad theory
# import`), so a `***` test classifies an unrunnable session as a verdict about the
# theory. Verified: a ROOT naming a missing theory produced `***` and was
# misclassified before this list existed.
#
# The list is deliberately the SAME set classifyIsabelleFailure keys on, so this gate
# also locks that classifier's assumption. A theory-level failure mode missing from
# the list degrades to `2` (inconclusive) rather than a silent pass — the safe
# direction, since inconclusive is printed and counted.
#
# Motivation: consecutive runs of one commit in one shell gave 64/3 then 67/0, all
# three failures being isabelle assertions. Ruled out as unsoundness — Isabelle
# content-hashes the session, so a stale heap cannot yield a false success — so it is
# contention/timing, retried here, and reported as inconclusive if unresolved rather
# than as "the marker changed".
ISA_THEORY_MARKERS='Failed to apply initial proof method|Failed to finish proof|Inner syntax error|Failed to parse prop|ORACLE PRESENT|Type unification failed'
isa_build(){
  attempt=1
  while [ "$attempt" -le 3 ]; do
    ISA_OUT="$( cd "$1" && isabelle build -D . 2>&1 )"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf '%s' "$ISA_OUT" | grep -qE "$ISA_THEORY_MARKERS" && return 1
    attempt=$((attempt+1))
  done
  return 2
}
# Assert that obligation $1's OWN rows contain substring $2, in output $3.
#
# Row-anchored on purpose. A bare `grep "$2" <whole output>` passes when ANY
# obligation in the file has the cell, so with several obligations it can confirm a
# claim about the wrong row — e.g. "add_bounded: rocq:lia = closed" would pass on a
# file where only div_safe closed. `grep -A3 "[$1]"` restricts the match to the
# obligation's own key line and the cell/class lines that follow it.
has(){
  printf '%s' "$3" | grep -A3 -- "$1" | grep -q -- "$2" \
    && ok "$1: $2" || no "$1: expected '$2' in its own row"
}

FAMILIES="examples/two_kernel_demo/src/families.con"

echo "=== Lean baseline (no external kernels) ==="
BASE="$("$COMPILER" "$DEMO" --report multi-kernel 2>/dev/null)"
has "add_bounded" "lean:omega = closed"   "$BASE"
has "add_bounded" "=> proved_by_lean"     "$BASE"
has "mul_unbounded" "=> unproven"         "$BASE"
# externals not requested -> off, never a false verdict
has "add_bounded" "rocq:lia = off"        "$BASE"   # externals not requested -> off

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
    // SEPARATE clauses on purpose. Conjoined into one #[requires], the div term drops
    // the LEAN goal too, so the row reads `lean:omega = refused` => `unproven` and the
    // dangerous case is never exercised. The bug this guards is a dropped Rocq goal
    // reported as `refused` on an obligation LEAN PROVED — which looks like Rocq
    // contradicting Lean. That needs lean = closed AND rocq = not-asked, i.e. a div
    // hypothesis that only the Rocq lowering drops.
    #[overflow_checked]
    #[requires(0 <= a)]
    #[requires(a <= 100)]
    #[requires(0 <= b)]
    #[requires(b <= 100)]
    #[requires(a / 2 <= 50)]
    fn add_with_div_hyp(a: i32, b: i32) -> i32 { return a + b; }
}
EOF
  P="$("$COMPILER" "$TMP/src/main.con" --report multi-kernel --rocq 2>/dev/null)"
  # a div hypothesis is outside the fragment -> the Rocq goal is dropped, so the
  # kernel is NOT asked. Must NOT read as a false disagreement ("refused").
  has "add_with_div_hyp" "rocq:lia = not-asked" "$P"
  # the load-bearing half: Lean DID close it, so a `refused` here would read as the
  # second kernel contradicting the first.
  has "add_with_div_hyp" "lean:omega = closed" "$P"
  printf '%s' "$P" | grep -A2 "add_with_div_hyp" | grep -q "=> proved_by_lean" \
    && ok "div-hyp: lean-proved obligation keeps its class when Rocq is not asked" \
    || no "div-hyp should be proved_by_lean, not unproven"
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

  echo "=== bridge DIVERSITY: Core->Rocq extraction vs the interpreter ==="
  # The gap multi-kernel names as a non-attestation: every kernel checks a lowering
  # produced by ONE Core->VC bridge, so a bridge bug is invisible to all of them.
  # This takes a SECOND independent path from Core to a value and compares.
  for f in "$DEMO" "$FAMILIES"; do
    "$COMPILER" "$f" --report bridge-diversity >/dev/null 2>&1
    [ $? -eq 0 ] && ok "bridge-diversity agrees on $(basename "$f")" \
                  || no "bridge-diversity should agree on $(basename "$f")"
  done
  BD="$("$COMPILER" "$FAMILIES" --report bridge-diversity 2>/dev/null)"
  # Coverage must be stated, not implied: a function outside the fragment is NAMED
  # rather than silently skipped, so "N agree" cannot be read as "everything agrees".
  printf '%s' "$BD" | grep -q "OUTSIDE the extractable fragment" \
    && ok "functions outside the fragment are named, not silently skipped" \
    || no "unextractable functions should be reported"
  printf '%s' "$BD" | grep -q "read_at" \
    && ok "array-indexing function correctly reported as outside the fragment" \
    || no "read_at should be outside the fragment"

  echo "=== extraction semantics: truncating vs flooring division really differ ==="
  # The extraction maps `/` to Z.quot (truncating, matching Int.tdiv), NOT Z.div
  # (flooring). This locks the fact that the distinction is real, so the choice
  # cannot be "simplified" to Z.div without a gate failing. Injecting Z.div for
  # Z.quot makes div_safe DISAGREE on (-7)/2 — that is what this protects.
  DTMP="$(mktemp -d)"
  cat > "$DTMP/d.v" <<'EOF'
From Stdlib Require Import ZArith.
Open Scope Z_scope.
Goal Z.quot (-7) 2 = -3. Proof. reflexivity. Qed.
Goal Z.div  (-7) 2 = -4. Proof. reflexivity. Qed.
EOF
  ( cd "$DTMP" && coqc -native-compiler no d.v >/dev/null 2>&1 )
  [ $? -eq 0 ] && ok "Z.quot truncates and Z.div floors — the mapping choice matters" \
                || no "division semantics changed — revisit extractBinOp"
  # And lock the marker the disagreement classifier reads.
  cat > "$DTMP/u.v" <<'EOF'
From Stdlib Require Import ZArith.
Open Scope Z_scope.
Definition f (a : Z) : Z := Z.add a 1.
Goal f 1 = 3. Proof. reflexivity. Qed.
EOF
  U_OUT="$( cd "$DTMP" && coqc -native-compiler no u.v 2>&1 )"
  printf '%s' "$U_OUT" | grep -q "Unable to unify" \
    && ok "a mismatched equation still prints 'Unable to unify' (DISAGREE marker)" \
    || no "reflexivity-mismatch marker changed — bridge-diversity classifier needs updating"
  rm -rf "$DTMP"

  echo "=== FLAGSHIP: elf_header carries every evidence surface at once ==="
  # The "really works on non-toy code" proof: a 244-line example that is
  # multi-kernel proved, bridge-fuzzed, lowering-checked AND extraction-checked.
  ELF="examples/elf_header/src/main.con"
  "$COMPILER" "$ELF" --report bridge-check >/dev/null 2>&1
  [ $? -eq 0 ] && ok "elf_header: bridge-check (concrete fuzz vs VC) passes" \
                || no "elf_header bridge-check should pass"
  "$COMPILER" "$ELF" --report bridge-diversity >/dev/null 2>&1
  [ $? -eq 0 ] && ok "elf_header: Core->Rocq extraction agrees with the interpreter" \
                || no "elf_header bridge-diversity should agree"
  "$COMPILER" "$ELF" --report lowering-agreement --rocq >/dev/null 2>&1
  [ $? -eq 0 ] && ok "elf_header: rocq lowering means the same proposition" \
                || no "elf_header lowering-agreement should pass"
  EBD="$("$COMPILER" "$ELF" --report bridge-diversity 2>/dev/null)"
  for fn in check_magic check_class check_data check_version validate_header; do
    printf '%s' "$EBD" | grep -q "\[$fn\]  agree" \
      && ok "elf_header: $fn agrees across both evaluators" \
      || no "elf_header: $fn should agree"
  done
  CV="$("$COMPILER" examples/crypto_verify/src/main.con --report bridge-diversity 2>/dev/null)"
  for fn in compute_tag verify_tag check_nonce verify_message main; do
    printf '%s' "$CV" | grep -q "\[$fn\]  agree" \
      && ok "crypto_verify: $fn agrees across both evaluators" \
      || no "crypto_verify: $fn should agree"
  done
  # crypto_verify is FULLY covered — no function falls outside the fragment. That
  # depends on the early-return guard pattern (`if !ok { return 0; } ...`), which
  # verify_message uses and which is only sound because blockTerminates checks the
  # `then` branch really leaves the function.
  printf '%s' "$CV" | grep -q "OUTSIDE the extractable fragment" \
    && no "crypto_verify should have NO function outside the fragment" \
    || ok "crypto_verify is fully covered (every function bridge-checked)"

  echo "=== guard soundness: a non-terminating then-branch is NOT modelled as if/else ==="
  # `if c { x = 1; } rest` must NOT extract: both paths continue into `rest` with
  # different state, which the let-chain encoding cannot express. Extracting it as
  # `if c then 1 else rest` would silently check the WRONG function, which is worse
  # than not checking it.
  GTMP="$(mktemp -d)"; mkdir -p "$GTMP/src"
  cat > "$GTMP/src/main.con" <<'EOF'
mod guard {
    // then-branch FALLS THROUGH (no return): must be refused by the fragment
    fn fallthrough(a: i32) -> i32 {
        let mut x: i32 = a;
        if a > 0 { x = 1; }
        return x;
    }
    // then-branch RETURNS: a real guard, must be extracted
    fn realguard(a: i32) -> i32 {
        if a > 0 { return 1; }
        return 0;
    }
}
EOF
  GD="$("$COMPILER" "$GTMP/src/main.con" --report bridge-diversity 2>/dev/null)"
  printf '%s' "$GD" | grep -q "\[realguard\]  agree" \
    && ok "a real early-return guard IS extracted and agrees" \
    || no "realguard should be extracted"
  printf '%s' "$GD" | grep -qE "fallthrough" \
    && printf '%s' "$GD" | grep -A3 "OUTSIDE" | grep -q "fallthrough" \
    && ok "a fall-through then-branch is refused, not silently mis-extracted" \
    || no "fallthrough must be OUTSIDE the fragment"
  rm -rf "$GTMP"

  echo "=== flag parsing: a valid flag COMBINATION is not a usage error ==="
  # `--rocq --isabelle --require-two-kernels` used to fall through to the usage dump,
  # so a caller checking only the exit code read a usage error as a failed gate.
  "$COMPILER" "$DEMO" --report multi-kernel --rocq --isabelle >/dev/null 2>&1
  [ $? -eq 0 ] && ok "--rocq --isabelle is accepted" || no "--rocq --isabelle should work"
  "$COMPILER" "$DEMO" --report multi-kernel --bogus-flag >/dev/null 2>&1
  [ $? -eq 1 ] && ok "an unknown flag is still rejected" || no "unknown flags must be rejected"

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
declare [[smt_oracle = $1, smt_timeout = 180]]
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
  isa_build "$RTMP"
  case $? in
    0) ok "a LINEAR goal replays: veriT's proof reconstructed, asserted oracle-free" ;;
    1) no "linear replay failed and Isabelle said why (diagnostic below)"
       printf '%s\n' "$ISA_OUT" | grep '^\*\*\*' | head -3 >&2 ;;
    *) inconc "linear replay: isabelle build never reached a diagnostic in 3 attempts" ;;
  esac
  # Teeth: with smt_oracle = true the method STAMPS the goal instead of checking it.
  # That is the exact trust leak replay exists to close, so it must FAIL here.
  write_replay_thy true "$LINEAR_GOAL"
  isa_build "$RTMP"
  case $? in
    2) inconc "oracle-mode teeth: isabelle build never reached a diagnostic" ;;
    *) printf '%s' "$ISA_OUT" | grep -q "ORACLE PRESENT" \
         && ok "smt_oracle = true is DETECTED and rejected (stamping cannot pass as replay)" \
         || no "oracle mode must be rejected — the no-oracle assertion has no teeth" ;;
  esac
  # Locks the measured limitation. If Isabelle ever reconstructs nonlinear
  # arithmetic, this fails loudly and solver_replayed becomes reachable for the
  # nonlinear VCs — which is a capability upgrade we want to be told about.
  write_replay_thy false 'ALL a::int. 0 <= a --> 0 <= a * a'
  isa_build "$RTMP"
  case $? in
    0) no "nonlinear replay now WORKS — upgrade solver-cert to reach solver_replayed" ;;
    1) ok "NONLINEAR replay still unsupported (documented ceiling holds)" ;;
    *) inconc "nonlinear ceiling: isabelle build never reached a diagnostic" ;;
  esac
  rm -rf "$RTMP"

  echo "=== isabelle refusal vs malformed-theory markers (classifier assumption) ==="
  ITMP="$(mktemp -d)"
  printf 'session VCsess = HOL +\n  theories VC\n' > "$ITMP/ROOT"
  printf 'theory VC imports Main begin\nlemma "ALL a b::int. (-2147483648 <= (a * b) & (a * b) <= 2147483647)"\n  by presburger\nend\n' > "$ITMP/VC.thy"
  isa_build "$ITMP"
  case $? in
    2) inconc "refusal marker: isabelle build never reached a diagnostic" ;;
    *) printf '%s' "$ISA_OUT" | grep -q "Failed to apply initial proof method" \
         && ok "a genuine presburger refusal still prints 'Failed to apply initial proof method'" \
         || no "isabelle refusal marker changed — classifyIsabelleFailure needs updating" ;;
  esac
  printf 'theory VC imports Main begin\nlemma "ALL a b::int. (a <=> b)"\n  by presburger\nend\n' > "$ITMP/VC.thy"
  isa_build "$ITMP"
  case $? in
    2) inconc "malformed-theory marker: isabelle build never reached a diagnostic" ;;
    *) printf '%s' "$ISA_OUT" | grep -q "Failed to apply initial proof method" \
         && no "a malformed theory must NOT look like a proof-method failure" \
         || ok "a malformed theory does not print the refusal marker (reads as error)" ;;
  esac
  rm -rf "$ITMP"
else
  echo "=== Isabelle absent — skipping isabelle assertions ==="
fi

echo "=== COMPOSITION: a disagreeing lowering must not earn the badge or pass the gate ==="
# The gate previously tested lowering-agreement and the release gate as SEPARATE
# assertions, never a corrupted lowering against the gate — so the composition hole
# was invisible: agreement caught the corruption, and the badge/gate never asked it.
# This mutates the Rocq operator column (<= rendered as <), rebuilds, and asserts the
# badge drops that kernel AND --require-two-kernels fails. Same shape as the original
# finding: a surface asserting more than it checked.
#
# HEAVY (two rebuilds) and it MUTATES TRACKED SOURCE, so it runs LAST and only under
# MULTI_KERNEL_MUTATE=1 — the nightly-only convention of
# check_gate_mutation_coverage.sh. Both properties are load-bearing: an earlier
# version of this block sat mid-suite and its rebuild poisoned every assertion after
# it (67/0 became 61/9), and an abort mid-mutation left the mutated file in the tree,
# where the next run backed THAT up and "restored" to it.
if [ "${MULTI_KERNEL_MUTATE:-0}" = "1" ]; then
  MUT="Concrete/Report/ReportVC.lean"
  # Refuse to run on an already-modified file: backing up a dirty (possibly
  # already-mutated) copy and restoring it is how a mutation becomes permanent.
  if ! git diff --quiet -- "$MUT" 2>/dev/null; then
    no "composition mutation skipped — $MUT has uncommitted changes (clean it first)"
  else
  # Restore from git on ANY exit path, not just the happy one.
  trap 'git checkout -- "$MUT" 2>/dev/null; rm -f "$MUT.compose.bak"; (lake build >/dev/null 2>&1 || true)' EXIT
  cp "$MUT" "$MUT.compose.bak"
  awk '/^def obBinOpRocq/{f=1} f&&/\.leq => some \("<=", false\)/{sub(/some \("<=", false\)/, "some (\"<\", false)"); f=0} {print}' \
    "$MUT.compose.bak" > "$MUT"
  if ! grep -q 'some ("<", false) | .lt' "$MUT"; then
    no "composition mutation did not apply (obBinOpRocq shape changed?)"
    cp "$MUT.compose.bak" "$MUT"; rm -f "$MUT.compose.bak"
  else
    rm -rf .concrete-cache
    if lake build >/dev/null 2>&1; then
      MB="$("$COMPILER" "$FAMILIES" --report multi-kernel --rocq 2>/dev/null)"
      printf '%s' "$MB" | grep -q "LOWERING DISAGREES" \
        && ok "corrupted lowering is NAMED in the multi-kernel report" \
        || no "multi-kernel report should name the disagreeing lowering"
      printf '%s' "$MB" | grep -A4 "add_bounded" | grep -q "proved_by_two_kernels" \
        && no "badge still claims two kernels on a disagreeing lowering" \
        || ok "badge drops the disagreeing kernel (no proved_by_two_kernels)"
      "$COMPILER" "$FAMILIES" --report multi-kernel --rocq --require-two-kernels >/dev/null 2>&1
      [ $? -eq 1 ] && ok "--require-two-kernels FAILS on a disagreeing lowering" \
                    || no "release gate must not pass a disagreeing lowering"
    else
      no "composition mutation broke the build"
    fi
    git checkout -- "$MUT" 2>/dev/null || cp "$MUT.compose.bak" "$MUT"
    rm -f "$MUT.compose.bak"
    rm -rf .concrete-cache
    lake build >/dev/null 2>&1 || no "restore rebuild failed"
  fi
  trap - EXIT
  fi
else
  echo "  (skipped — set MULTI_KERNEL_MUTATE=1; mutates tracked source, needs 2 rebuilds)"
fi


echo ""
if [ "$INCONC" -gt 0 ]; then
  echo "MULTI-KERNEL: PASS=$PASS  FAIL=$FAIL  INCONCLUSIVE=$INCONC"
  echo "  NOTE: $INCONC assertion(s) could not be evaluated (the tool never reached a"
  echo "  diagnostic after 3 attempts). They verified NOTHING — do not read them as green."
else
  echo "MULTI-KERNEL: PASS=$PASS  FAIL=$FAIL"
fi
[ "$FAIL" -eq 0 ]
