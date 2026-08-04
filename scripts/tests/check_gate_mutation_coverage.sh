#!/usr/bin/env bash
# Phase 6C #5: gate mutation-testing — prove the pipeline gates are load-bearing.
#
# For each rule FAMILY, apply a one-line source mutation that disables the rule
# (while still building) and prove the family's SPECIFIC gate goes red (KILLED).
# A mutation whose gate stays green is a SURVIVOR = a decorative gate = failure.
#
# HEAVY / NIGHTLY: the behavioral families need a `lake build` per mutation (~1-3
# min each), so this is not a per-commit gate. Grep-only families (constructor
# coverage, source-maps) need no rebuild. Run one family with FAMILY=<n>, or all
# (default). Restore is via `git checkout --` (assumes a clean tree for the
# mutated files); a final clean rebuild is done at the end.
#
# Most families' gates are OUTSIDE run_tests.sh --fast, so we invoke each gate directly.
#
# COVERAGE, stated because this harness is the thing that stops gates being decorative and
# its own coverage was never written down (2026-08-04 sweep):
#
#   180 gate scripts in scripts/tests/
#    55 guard a SOUNDNESS claim — breaking the rule would let the compiler assert something
#       false about a program (a missing trap, a false `proved`, a laundered axiom)
#    18 of those 55 have a negative control here
#    37 of those 55 have NONE
#
# Those figures are RECOMPUTED, not derived by arithmetic. A first version of this header
# said 17/38, reached by adding the four families of that pass to a previous count — wrong,
# because six of the covered gates (source-maps, copy-judgment, corecheck-boundary,
# diagnostics-quality, mono-name-collision, constructor-coverage) are not soundness gates at
# all, so "covered" and "covered AND soundness" are different sets. Same defect class this
# file exists to catch: a number restated instead of measured.
#
# The 42 are not known to be decorative. They are UNMEASURED, which is a different claim
# from safe, and the distinction is the whole reason this file exists: for a week, every
# defect found landed in the unmeasured set while the suite was green.
#
# Selection rule for extending this list: a gate qualifies if breaking the rule it guards
# would let the compiler assert something FALSE. Gates over formatting, naming, docs hygiene
# or CI plumbing are out of scope — they matter, but their failure mode is noise rather than
# a wrong claim.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
LAKE="${LAKE:-lake}"
ONLY="${FAMILY:-}"

# family i: NAME FILE GATE NEEDS_BUILD ; OLD/NEW written to temp files per family.
NAME=();  FILE=();  GATE=();  BUILD=()
OLD=();   NEW=()
add(){ NAME+=("$1"); FILE+=("$2"); GATE+=("$3"); BUILD+=("$4"); OLD+=("$5"); NEW+=("$6"); }

add "corecheck-unsafe-op" "Concrete/Check/CoreCheck.lean" "check_corecheck_boundary.sh" yes \
  'addCCError (.missingCapability "*raw_ptr" "Unsafe" "")' \
  'pure ()'
add "copy-predicate" "Concrete/Check/Layout.lean" "check_copy_judgment.sh" yes \
  '| some (isC, _, _) => isC' \
  '| some (_, _, _) => true'
add "checked-arith-trap" "Concrete/Backend/EmitSSA.lean" "check_checked_arith.sh" yes \
  $'      let mnem := if ssaIsSignedInt operandTy then "sadd" else "uadd"\n      emitStructured s (.call (some dst) iTy (.global (checkedCallName mnem operandTy)) [(iTy, lOp), (iTy, rOp)])' \
  $'      let _mnem := if ssaIsSignedInt operandTy then "sadd" else "uadd"\n      emitStructured s (.binOp dst .add iTy lOp rOp)'
add "capability-requirement" "Concrete/Check/CoreCheck.lean" "check_capability_judgment.sh" yes \
  'if !capD.satisfied then' \
  'if false then'
add "walker-constructor" "Concrete/Check/CoreCheck.lean" "check_constructor_coverage.sh" no \
  '| .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | .charLit _ => pure ()' \
  '| .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | _ => pure ()'
add "source-span-stamping" "Concrete/Elab/Elab.lean" "check_source_maps.sh" no \
  'declSpan := some f.span' \
  'declSpan := none'
add "mono-name-hygiene" "Concrete/IR/Mono.lean" "check_mono_name_collision.sh" yes \
  '| .generic n args => n ++ "_T_" ++ "_".intercalate (args.map tyToSuffix) ++ "_E"' \
  '| .generic n _args => n'
add "diagnostic-quality" "Concrete/Check/CoreCheck.lean" "check_diagnostics_quality.sh" yes \
  '| .insufficientCapabilities _ required _ => some s!"add '"'"'with({required})'"'"' to the calling function, or wrap the call in a trusted function"' \
  '| .insufficientCapabilities _ _ _ => none'
add "fact-invalidation" "Concrete/Report/ReportObligations.lean" "check_scoped_collector.sh" yes \
  '| _ => dropStaleHyps scope (assignedScalarsS s)' \
  '| _ => scope'
add "report-schema-row" "Concrete/Report/Report.lean" "check_vc_schema.sh" yes \
  '("kind", .str v.kind),' \
  '("knd", .str v.kind),'

# ---------------------------------------------------------------------------
# 2026-08-04: the R-0460..R-0465 gates. Registered because they were NOT here, and
# every failure of the past week landed in exactly the uncovered set: a gate that
# passed while the thing it guarded was broken. 11 of 180 gates had negative
# controls; the newest and most load-bearing had none.
#
# Each mutation below was verified by hand when the gate was written. Verified by
# hand means verified once, by whoever remembered. These entries make it repeat.
# ---------------------------------------------------------------------------

# H23's composition: drop the cap and a proved obligation resting on an unproved
# invariant reads proved again. This is the defect, restored exactly.
add "hypothesis-cap" "Main.lean" "check_known_wrong_corpus.sh" yes \
  'return Report.capOnHypothesisDebt (Report.dischargeVCs vcs omegaProved (bvCallKeys ++ bvOvfKeys))' \
  'return Report.dischargeVCs vcs omegaProved (bvCallKeys ++ bvOvfKeys)'

# H24's insufficiency: drop the quotient condition and a division reports proved
# while trapping on signed MIN / -1. Also breaks trapConditions_sufficient, so this
# one is expected to fail the BUILD as well as the gate — recorded because a
# mutation that cannot compile is a stronger result than a gate going red.
add "trap-quotient-condition" "Concrete/Semantics/IntArith.lean" "check_known_wrong_corpus.sh" yes \
  '| .div | .mod => [.divisorNonZero, .quotientInRange]' \
  '| .div | .mod => [.divisorNonZero]'

# The multi-kernel firewall: let attestation act on an unproved VC and a badge can be
# minted for something no kernel proved.
add "attestation-precondition" "Concrete/Report/Report.lean" "check_discharge_adapters.sh" yes \
  $'    actsOn := fun s => s == "proved_by_kernel_decision" || s == "proved_by_lean"\n                       || s == "proved_by_lean_replay",' \
  $'    actsOn := fun _ => true,'

# The independence coordinate: collapse Isabelle into CIC and the badge overstates
# foundational independence — two CIC kernels reported as two foundations.
add "kernel-foundation" "Concrete/Report/Evidence.lean" "check_evidence_algebra.sh" yes \
  '| "isabelle" => .hol' \
  '| "isabelle" => .cic'

# The reference evaluator's division convention: swap truncating for Lean's `/` and
# every lowering-agreement check is validated against the wrong reference at
# negative operands.
add "reference-division" "Concrete/Report/ReportObligations.lean" "check_vc_bridge_register.sh" no \
  '| .div => if b == 0 then none else some (a.tdiv b)' \
  '| .div => if b == 0 then none else some (a / b)'

# The artifact fuzzer's claim classification: treat every function as claimed and a
# trap in an admittedly-unproved function is reported as a Register A counterexample —
# a false alarm, which is how a fuzzer gets switched off.
add "fuzz-claim-classes" "Concrete/Report/ReportObligations.lean" "check_artifact_fuzz.sh" yes \
  'artifactFuzzDriverFor (cases.filter (fun c => c.claim != "unproved")) "artifact_fuzz_all"' \
  'artifactFuzzDriverFor cases "artifact_fuzz_all"'

# ---------------------------------------------------------------------------
# 2026-08-04, second pass: a sweep of the SOUNDNESS gates that had no control.
#
# Selection rule, so the next person can extend it the same way: a gate qualifies
# if breaking the rule it guards would let the compiler assert something FALSE
# about a program — a missing trap, a false `proved`, a laundered axiom. Gates over
# formatting, naming, docs hygiene or CI plumbing are out of scope; they matter, but
# their failure mode is noise, not a wrong claim.
# ---------------------------------------------------------------------------

# Bug 053, restored exactly: make every unary op read as non-side-effecting and a
# DISCARDED integer negation is deleted, taking the documented MIN trap with it. The
# compiled program exits 0 where the interpreter aborts.
add "trap-preservation-unary" "Concrete/IR/SSACleanup.lean" "check_trap_inventory.sh" yes \
  'if !(IntArith.unaryOpCanTrap op ty) then false' \
  'if true then false'

# NO FALSE GREEN, the obligation red-team's first clause: make the constant-divisor
# verdict unconditionally true and `x / 0` at compile time reads proved.
add "const-divisor-verdict" "Concrete/Report/ReportObligations.lean" "check_obligation_redteam.sh" yes \
  '| some k => (some (decide (k ≠ 0)), none)' \
  '| some k => (some (decide (k == k)), none)'

# The same false-green in the bounds family: a constant index outside the array
# reads proved.
add "const-bounds-verdict" "Concrete/Report/ReportObligations.lean" "check_obligation_redteam.sh" yes \
  '| some k => (some (decide (0 ≤ k) && decide (k < (Int.ofNat n))), none)' \
  '| some k => (some (decide (k == k)), none)'

# The FOLD path, which is what check_int_arith_semantics.sh actually guards:
# interpret == fold-then-interpret == compiled. Make a trapping constant operation fold
# to a value and the trap disappears under constant folding — the interpreter aborts
# while the folded/compiled program returns 0.
#
# Chosen after a first attempt failed for an INSTRUCTIVE reason. Removing the div
# overflow trap from `evalIntBinOp` does not compile: `div_obligation_necessary`
# (R-0460) rejects it. That is stronger protection than a gate — but it meant the
# family proved the THEOREM was load-bearing while claiming to prove the gate was, and
# a control that validates something other than its stated subject is exactly the
# false-green this harness exists to prevent. `foldIntBinOp` is covered by no theorem,
# so a mutation there reaches the gate.
add "fold-drops-trap" "Concrete/Semantics/IntArith.lean" "check_int_arith_semantics.sh" yes \
  '| .trap _    => some none' \
  '| .trap _    => some (some 0)'

# ---------------------------------------------------------------------------
# 2026-08-04, third pass: the remaining soundness gates, batch 1.
# Each mutation removes a RUNTIME CHECK or a trust boundary, so the compiled program
# does something the compiler said it would not.
# ---------------------------------------------------------------------------

# H8's check: stop emitting the array bounds check and an out-of-range index reads
# and writes past the array instead of aborting. The obligation layer is untouched,
# so this is the pure lowering failure — proved obligation, unchecked artifact.
# INFLATE the length rather than deleting the call or replacing the length outright. Two
# earlier attempts died on a lint, not on the check: `pure ()` left `idxI64` unused, and a
# constant length left `len` unused, and this project treats an unused binding as a build
# error. A mutation that cannot compile proves nothing about the gate (see fold-drops-trap).
# `len + 999999999` keeps both bindings live and makes the check pass for every real index.
add "bounds-check-emission" "Concrete/IR/Lower.lean" "check_array_bounds.sh" yes \
  '[idxI64, .intConst (Int.ofNat len) .int] .unit)' \
  '[idxI64, .intConst (Int.ofNat len + 999999999) .int] .unit)'

# ---------------------------------------------------------------------------
# 2026-08-04, batch 2 of the remaining soundness gates.
# ---------------------------------------------------------------------------

# Checked integer NEGATION: make `-x` compute `0 - 0` so it neither traps at MIN nor
# returns the right value. Bug 053's sibling — that one deleted a discarded negation,
# this one keeps it and makes it wrong. Operands changed rather than the call replaced,
# because dropping the call leaves `mnem` unused and this project errors on that.
add "checked-negation" "Concrete/Backend/EmitSSA.lean" "check_arith_redteam.sh" yes \
  '[(iTy, .intLit 0), (iTy, valOp)]' \
  '[(iTy, .intLit 0), (iTy, .intLit 0)]'

# Proof FRESHNESS (bugs 059/060): make staleness detection always answer "fresh", so a
# proof whose subject has changed underneath it keeps reading proved. The stored digest
# is still there and still compared — the comparison just always agrees, which is the
# shape a real staleness bug takes.
add "proof-staleness" "Concrete/Proof/ProofCore.lean" "check_proof_freshness.sh" yes \
  $'    | some h => shortHash currentFp != h\n    | none   => a.expectedFp != currentFp' \
  $'    | some h => shortHash currentFp == shortHash currentFp && h != h\n    | none   => a.expectedFp != a.expectedFp'

# H2's check: route float→int through a raw `fptosi` instead of the checked helper.
# LLVM says raw fptosi is POISON on NaN/±inf/out-of-range, so this is undefined
# behaviour reachable from safe source.
add "checked-float-cast" "Concrete/Backend/EmitSSA.lean" "check_float_cast.sh" yes \
  'emitStructured s (.call (some dst) dstLLTy (.global (checkedF2ICallName srcTy targetTy)) [(srcLLTy, valOp)])' \
  'emitStructured s (.cast dst .fptosi srcLLTy valOp dstLLTy)'

# Wrapping arithmetic must NOT trap: make `wrapping_add` emit the CHECKED add and a
# documented-wrapping operation aborts instead of wrapping. The inverse direction of
# the checked-arith family — that one removes a trap, this one adds one where the
# language promises none.
add "wrapping-stays-unchecked" "Concrete/Backend/EmitSSA.lean" "check_wrapping_arith.sh" yes \
  '| .wrappingAdd => emitStructured s (.binOp dst .add iTy lOp rOp)' \
  '| .wrappingAdd => emitStructured s (.call (some dst) iTy (.global (checkedCallName "sadd" operandTy)) [(iTy, lOp), (iTy, rOp)])'

N=${#NAME[@]}
PASS=0; FAIL=0

# PRECONDITION: every file this run will mutate must be clean.
#
# Restore is `git checkout --`, which discards whatever is in the working tree. If a file
# is already modified when we start — by a previous run that died, or by someone's
# in-progress edit — this script silently destroys that work, and worse, a mutation
# stranded by an earlier abort is treated as pristine source. The later families then run
# their gates against a doubly-mutated tree and their KILLED/SURVIVED verdicts are wrong
# without saying so.
#
# Observed 2026-07-31: a `pkill` of this script left Concrete/Check/Layout.lean mutated,
# because the EXIT trap does not fire on signal-based termination (now also trapped
# below). Recovery depended on someone running `git status`, not on the tooling.
# check_multi_kernel.sh already refuses to run dirty for exactly this reason; this is the
# same guard.
DIRTY=""
for f in $(printf "%s\n" "${FILE[@]}" | sort -u); do
  git diff --quiet -- "$f" 2>/dev/null || DIRTY="$DIRTY $f"
done
if [ -n "$DIRTY" ]; then
  echo "error: refusing to run — these files have uncommitted changes and would be" >&2
  echo "       DESTROYED by the restore step:$DIRTY" >&2
  echo "       Commit, stash, or 'git checkout --' them first. If a previous run was" >&2
  echo "       killed, verify the diff is yours before discarding it." >&2
  exit 2
fi

TMP=$(mktemp -d)
# INT/TERM as well as EXIT: plain EXIT did not restore the tree when this script was
# killed (observed 2026-07-31, Layout.lean left mutated). The handler re-raises so the
# exit status still reflects the signal.
#
# KNOWN LIMIT, measured rather than assumed: bash defers a trap until the current
# foreground command returns, so a TERM delivered while `lake build` is running does not
# take effect for however long that build has left — verified by sending TERM to a run
# mid-build and watching it continue. Restoration is therefore reliable but NOT prompt.
# If you must stop a run immediately, kill the build too, then check `git status` before
# doing anything else; the dirty-tree guard above will refuse the next run rather than
# silently treating a stranded mutation as pristine source, which is the failure this
# pair of mechanisms exists to prevent.
restore_all(){ rm -rf "$TMP"; git checkout -- $(printf "%s " "${FILE[@]}" | tr " " "\n" | sort -u) 2>/dev/null; }
trap 'restore_all' EXIT
trap 'restore_all; trap - INT TERM; kill -s INT $$' INT
trap 'restore_all; trap - INT TERM; kill -s TERM $$' TERM

apply(){ # file oldfile newfile
  python3 - "$1" "$2" "$3" <<'PY'
import sys
f,ofl,nfl=sys.argv[1],sys.argv[2],sys.argv[3]
src=open(f).read(); old=open(ofl).read(); new=open(nfl).read()
assert src.count(old)>=1, f"OLD not found in {f}"
open(f,'w').write(src.replace(old,new,1))
PY
}

run_one(){
  local i="$1"
  local nm="${NAME[$i]}" file="${FILE[$i]}" gate="scripts/tests/${GATE[$i]}" needs="${BUILD[$i]}"
  printf '%s\n' "${OLD[$i]}" > "$TMP/old"; printf '%s\n' "${NEW[$i]}" > "$TMP/new"
  # strip the trailing newline the printf added (match raw substring)
  perl -i -pe 'chomp if eof' "$TMP/old" "$TMP/new"
  echo "--- family $((i+1))/$N: $nm ($file -> ${GATE[$i]}) ---"
  if ! apply "$file" "$TMP/old" "$TMP/new" 2>"$TMP/aerr"; then
    echo "  FAIL $nm: could not apply mutation ($(cat "$TMP/aerr"))"; FAIL=$((FAIL+1)); git checkout -- "$file" 2>/dev/null; return
  fi
  local killed=0 note=""
  if [ "$needs" = yes ]; then
    if ! "$LAKE" build >"$TMP/build.log" 2>&1; then
      killed=1; note="(killed by build — type system rejected the mutation)"
    fi
  fi
  if [ "$killed" -eq 0 ]; then
    if bash "$gate" >"$TMP/gate.log" 2>&1; then
      note="(SURVIVED — gate stayed green)"
    else
      killed=1; note="(killed by ${GATE[$i]})"
    fi
  fi
  git checkout -- "$file" 2>/dev/null
  if [ "$killed" -eq 1 ]; then echo "  ok   $nm KILLED $note"; PASS=$((PASS+1));
  else echo "  FAIL $nm $note"; FAIL=$((FAIL+1)); fi
}

echo "=== gate mutation coverage: $N families ==="
if [ -n "$ONLY" ]; then run_one "$((ONLY-1))"; else for i in $(seq 0 $((N-1))); do run_one "$i"; done; fi

# leave a clean binary behind
echo "--- restoring clean build ---"
"$LAKE" build >/dev/null 2>&1 || echo "  warn: clean rebuild failed; run 'lake build'"

echo
echo "GATE-MUTATION-COVERAGE: PASS=$PASS FAIL=$FAIL (of $N families)"
[ "$FAIL" -eq 0 ]
