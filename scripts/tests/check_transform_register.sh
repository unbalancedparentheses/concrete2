#!/usr/bin/env bash
# Register B gate — transformation soundness (R-0455).
#
# Register B's rows are theorems, so a green BUILD is the proof. This gate exists to make
# deleting or weakening a row LOUD, and to hold the register document to the code — the same
# discipline check_vc_bridge_register.sh applies to Register A, added at the same time as the
# first row rather than after the document had drifted.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
IR="Concrete/Semantics/TermIR.lean"
REG="docs/TRANSFORM_REGISTER.md"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$IR" ]  || { echo "FAIL $IR missing"; exit 1; }
[ -f "$REG" ] || { echo "FAIL $REG missing"; exit 1; }

echo "=== the IR is provable at all: structural, not partial ==="
# The reference evaluator this IR replaces (ReportObligations.evalIntEnv) is a `partial def`,
# so the kernel cannot reduce it and no theorem can say anything about it. If these become
# partial, every row below silently stops meaning anything.
if grep -qE "^\s*partial def (evalInt|evalBool|elimTmod)\b" "$IR"; then
  no "an evaluator or transformation is 'partial' — the kernel cannot reduce it, so the rows are vacuous"
else
  ok "evaluators and transformations are structurally recursive (kernel-reducible)"
fi

echo "=== Row 1: eliminate_tmod is discharged by real theorems ==="
for t in evalInt_elimTmod evalBool_elimTmod elimTmod_sound; do
  grep -qE "^\s*theorem $t\b" "$IR" && ok "row 1 theorem present: $t" \
    || no "row 1 theorem MISSING: $t"
done
for bad in sorry admit native_decide; do
  grep -qE "\b$bad\b" "$IR" \
    && no "$IR contains '$bad' — a Register B row is not actually proved" \
    || ok "no '$bad' in the transformation register"
done

echo "=== Row 1 is NON-VACUOUS: the transformation has effect ==="
# A meaning-preserving no-op satisfies the soundness theorem while transforming nothing.
grep -q "def hasTmod" "$IR" \
  && ok "hasTmod exists (effect is observable)" \
  || no "hasTmod missing — nothing shows the transformation changes anything"
N="$(grep -c "hasTmod (elimTmod" "$IR" || true)"
[ "$N" -ge 3 ] \
  && ok "$N effect locks (nested / sym-wrapped / arithmetic-embedded)" \
  || no "only $N effect locks (expected >=3) — vacuity is under-pinned"
grep -q "elimTmod (.bin .add (.var \"a\") (.lit 1)) = .bin .add (.var \"a\") (.lit 1)" "$IR" \
  && ok "a term without tmod is returned unchanged (pass is not gratuitous)" \
  || no "missing the no-change lock"

echo "=== uninterpreted symbols are quantified over, not assumed away ==="
grep -q "abbrev SymEnv" "$IR" \
  && ok "SymEnv exists — spec functions are carried, not dropped" \
  || no "no SymEnv: uninterpreted symbols cannot be represented"
grep -qE "theorem evalInt_elimTmod \(env : List \(String × Int\)\) \(se : SymEnv\)" "$IR" \
  && ok "row 1 holds for an ARBITRARY symbol environment" \
  || no "row 1 is not quantified over SymEnv — it would only hold for symbols we interpret"

echo "=== the register document agrees with the code ==="
STATED="$(grep -oE 'Rows discharged: \*\*[0-9]+ of [0-9]+\*\*' "$REG" | grep -oE '[0-9]+ of [0-9]+' | head -1)"
DN="${STATED%% of *}"
ACTUAL="$(grep -cE '^### Row [0-9]+ .*\*\*DISCHARGED' "$REG" || true)"
if [ "$DN" = "$ACTUAL" ]; then
  ok "the register states $DN discharged and has $ACTUAL discharged row(s)"
else
  no "the register says $DN discharged but $ACTUAL rows are marked DISCHARGED — stale in one direction"
fi
# Every theorem a DISCHARGED row names must exist. Catches both a row claiming a proof that
# was never written and a theorem renamed without updating the register.
MISS=0
for t in $(grep -oE '`TermIR\.[a-zA-Z_]+`' "$REG" | tr -d '`' | sed 's/TermIR\.//' | sort -u); do
  grep -qE "^\s*(theorem|def) $t\b" "$IR" || { no "the register names '$t' but it does not exist in $IR"; MISS=1; }
done
[ "$MISS" = "0" ] && ok "every name the register cites exists in the IR"
# And the OPEN rows must not name a proved theorem — that would understate the compiler.
grep -q "Row 2 — .*OPEN" "$REG" && grep -q "Row 3 — .*OPEN" "$REG" \
  && ok "rows 2 and 3 are recorded OPEN with their blockers" \
  || no "rows 2/3 are no longer marked OPEN — verify before claiming them"
# The print-step exclusion is the register's honest boundary; losing it would over-claim.
grep -q "validated, plausibly forever" "$REG" \
  && ok "the print step is excluded explicitly (not silently in scope)" \
  || no "the print/target-text boundary is gone — Register B would appear to cover printing"

echo "=== R-0455: tactics are DATA, and no driver silently loses a field ==="
# R-0455's measured defect: `rocqNiaLowering` was a full clone of `rocqLowering` whose only
# substantive difference was `lia` becoming `nia`. Reaching a different tactic cost a driver.
RO="Concrete/Report/ReportObligations.lean"
grep -q "tactics : List String" "$RO" \
  && ok "ProverLowering carries tactics as a field" \
  || no "no tactics field — the tactic is a template literal again and a clone is the only way to change it"
grep -q "def rocqNiaLowering : ProverLowering :=" "$RO" \
  && ok "rocqNiaLowering is a field override, not a cloned record" \
  || no "rocqNiaLowering is a full record again — the duplication R-0455 measured has returned"
grep -q "def rocqScript" "$RO" \
  && ok "one shared Rocq script builder" \
  || no "rocqScript gone — each Rocq driver templates its own script"
# Inline render literals: the count that measures the duplication. 5 before this slice, 3 now.
N="$(grep -c "render := fun vars hyps concl =>" "$RO" || true)"
[ "$N" -le 3 ] \
  && ok "$N inline render literals (was 5 before R-0455's slice; ratchet <=3)" \
  || no "$N inline render literals — a driver went back to templating its own script"

# THE FIELD THAT MATTERS MOST, and the reason this block exists. Collapsing the Rocq clone
# dropped `batchRender` from rocqLowering. That does not fail the build and does not stop
# `coqc` closing the proof — it leaves the AGREEMENT check with nothing to check, so every
# Rocq cell read "LOWERING DISAGREES" and the badge silently vanished: 78/78 became three
# failures with `rocq:lia = closed` sitting beside a refused attestation.
for d in rocqLowering isabelleLowering; do
  BLOCK="$(awk -v pat="def $d" 'index($0,pat){f=1} f{print} f&&/^$/{exit}' "$RO")"
  printf '%s' "$BLOCK" | grep -q "batchRender" \
    && ok "$d keeps batchRender (the agreement script, distinct from render)" \
    || no "$d has NO batchRender — its lowering-agreement check would have nothing to check"
done

echo "=== the IR is FED by real obligations, and the measurement is honest ==="
# Row 1 was a true theorem about a transformation nothing ran. `ofExpr` is the producer.
# The translation moved to its own module so ReportObligations can import it (evalIntEnv is
# now a wrapper over it). The measurement report stayed in TermOfExpr.lean.
OF="Concrete/Report/TermTranslate.lean"
[ -f "$OF" ] && ok "Expr -> Term translation exists" \
             || no "$OF missing — the IR has no producer and row 1 is idle"
grep -q "def ofExpr" "$OF" \
  && ok "ofExpr present" || no "ofExpr missing"
# Casts are now MODELLED (2026-08-04). The property that matters is not whether they are
# handled but HOW: a cast truncates, so passing the operand through unchanged would make the
# IR denote a different value than the program computes. This assertion previously forbade
# handling `.cast` at all, which was right while they were rejected and became exactly
# backwards once they were modelled — it fired on the improvement.
grep -qE "^\s*\| \.cast _ e ty" "$OF" \
  && ok "ofExpr carries casts (they are no longer dropped)" \
  || no "ofExpr no longer handles .cast — div-inside-cast obligations are dropped again"
grep -q "some (.cast w signed t)" "$OF" \
  && ok "a cast becomes a CAST node carrying width and signedness, not a pass-through" \
  || no "ofExpr does not build a .cast node — a cast may be being treated as identity"
grep -q "IntArith.intBitWidth ty" "$OF" \
  && ok "unknown-width targets (Int/Uint) are still rejected rather than given a made-up width" \
  || no "the width guard is gone — a cast with no fixed width would be modelled at a guess"
# And the evaluation must be the REFERENCE's wrap, pinned against IntArith on a value that
# actually wraps, so "modelled" cannot drift into "modelled differently".
grep -q "= some (IntArith.wrapToType .i8 200)" "Concrete/Report/TermOfExpr.lean" \
  && ok "the IR's cast agrees with IntArith.wrapToType on a wrapping value" \
  || no "the wrap is no longer pinned to the reference — the IR could denote a different value"
# Out-of-fragment operators rejected rather than approximated.
# Relations are CANONICALISED (geq -> swapped le), not rejected: rejecting them would have
# narrowed what the reference evaluator can evaluate the moment evalBoolEnv started routing
# through this translation, since the old evaluator handled geq/gt/neq directly.
LK="Concrete/Report/TermOfExpr.lean"
grep -q "= some (.bin .le (.var \"b\") (.var \"a\")) := rfl" "$LK" \
  && ok "geq is canonicalised by swapping operands (meaning preserved, relation set minimal)" \
  || no "the geq canonicalisation lock is gone — geq is either dropped or aliased wrongly"
grep -q "example : ofExpr (.binOp sp .bitand (.ident sp \"a\") (.ident sp \"b\")) = none := rfl" "$LK" \
  && ok "bit ops are still REJECTED (no transformation targets the bv sort yet)" \
  || no "bit ops are no longer pinned as rejected"
# The measurement must report all three buckets, so a zero cannot read as "nothing is lost".
for b in "carried by both layers" "DROPPED by the string layer only" "dropped by BOTH"; do
  grep -q "$b" Main.lean \
    && ok "term-ir reports: $b" \
    || no "term-ir does not report '$b' — a zero would be unreadable"
done
grep -q "fact about this corpus rather than about the IR" Main.lean \
  && ok "the report says a corpus zero is about the corpus, not about the IR" \
  || no "the report no longer qualifies the zero — it would under- or over-claim"

# THE CAPABILITY ITSELF, exercised rather than asserted. `examples/` contains no obligation
# with a division inside a cast, so the corpus number is 0 and would stay 0 if cast support
# regressed. This fixture is the difference between "recovers 0 because nothing to recover"
# and "recovers 0 because it is broken".
COMPILER="$ROOT_DIR/.lake/build/bin/concrete"
if [ -x "$COMPILER" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  cat > "$T/divcast.con" <<'FIXTURE'
mod ds {
    #[requires(b != 0)]
    #[requires(a / b < 10)]
    pub fn f(a: i32, b: i32) -> i32 {
        let arr: [i32; 4] = [1, 2, 3, 4];
        return arr[(a / b) as Int];
    }
}
pub fn main() with(Std) -> Int { return 0; }
FIXTURE
  OUT="$("$COMPILER" "$T/divcast.con" --report term-ir 2>/dev/null)"
  W="$(printf '%s' "$OUT" | grep -oE 'string layer only: [0-9]+' | grep -oE '[0-9]+')"
  B="$(printf '%s' "$OUT" | grep -oE 'by BOTH: *[0-9]+' | grep -oE '[0-9]+')"
  [ "${W:-0}" -ge 1 ] \
    && ok "the IR RECOVERS a division-inside-cast obligation the string layer drops (${W})" \
    || no "the IR recovers 0 on the div-inside-cast fixture — cast modelling has regressed"
  [ "${B:-1}" = "0" ] \
    && ok "and that obligation is no longer dropped by both layers" \
    || no "the fixture's obligation is still dropped by both (${B}) — casts are not carried"
else
  echo "  (skip capability fixture — compiler not built)"
fi

echo "=== the lowering path is kernel-reducible (no gratuitous `partial`) ==="
# A `partial def` is opaque to the kernel: no theorem and no `rfl` example can say anything
# about it. That limitation blocked three separate locks this week before anyone checked
# whether the keyword was NEEDED. Seven functions in the report layer — including the SMT
# printer, both prover lowerings and the bv renderer — recurse only on direct subterms and
# were marked partial by habit. Removing the keyword was the entire fix.
RO="Concrete/Report/ReportObligations.lean"
for f in exprToSmt exprToProver exprToProverU exprToLeanProp arithToBVW; do
  if grep -qE "^partial def $f\b" "$RO"; then
    no "$f is 'partial' again — its behaviour becomes unprovable and its locks impossible"
  else
    ok "$f is structural (kernel-reducible)"
  fi
done
# And the locks that only became possible because of it. A drop the IR exists to repair,
# pinned at compile time rather than counted at runtime.
LK="Concrete/Report/TermOfExpr.lean"
grep -q "(.binOp sp .lt (.binOp sp .div (.ident sp \"a\") (.ident sp \"b\")) (.intLit sp 10)) = none := rfl" "$LK" \
  && ok "the string layer's div-subterm DROP is pinned by rfl" \
  || no "the drop lock is gone — the defect the IR repairs is only measured, not pinned"
grep -q "= some \"a < 10\" := rfl" "$LK" \
  && ok "and a term inside the fragment still renders (the drop lock is not vacuous)" \
  || no "no positive rendering lock — 'returns none' could hold for everything"

echo "=== obligation DISCOVERY is complete on the arithmetic fragment ==="
# Registers A/B/C all begin AFTER an obligation exists. None of them can notice an obligation
# that was never generated — a missed shift is a green report, not a failed proof. This is the
# first statement about the prior question, and it exists only because `collectShiftsE` stopped
# being `partial`.
DC="Concrete/Report/DiscoveryComplete.lean"
if grep -qE "^partial def collectShiftsE\b" "$RO"; then
  no "collectShiftsE is 'partial' again — the discovery-completeness theorem cannot be stated"
else
  ok "collectShiftsE is total (the theorem is expressible)"
fi
grep -q "theorem collectShiftsE_complete" "$DC" \
  && ok "discovery completeness is a theorem: a present shift is always found" \
  || no "the discovery-completeness theorem is gone — missed obligations are unconstrained again"
# A completeness theorem is only as strong as its antecedent. `hasShift` is narrow, and a
# reader who checks the theorem NAME rather than the predicate will over-read it. Both the
# non-vacuity witness and the honest boundary must stay in the build.
grep -q "hasShift (.binOp spD .add" "$DC" \
  && ok "the antecedent is satisfiable (theorem is not vacuous)" \
  || no "no non-vacuity witness — 'complete' could hold because hasShift is never true"
grep -q "= false := by simp \[hasShift\]" "$DC" \
  && ok "the coverage GAP (shift under a call) is pinned, not left to be discovered" \
  || no "the boundary example is gone — the theorem reads as global completeness"
# The four walkers that recovered structural recursion outright.
for f in exprIntTy exprIntervalMax cartesianEnvs cartesianEnvsPer; do
  grep -qE "^partial def $f\b" "$RO" \
    && no "$f is 'partial' again" \
    || ok "$f is structural"
done

echo "=== discovery completeness covers all FOUR runtime-safety families ==="
for t in collectShiftsE_complete collectDivisorsE_complete collectArithE_complete \
         collectIndexUsesE_complete; do
  grep -q "theorem $t" "$DC" \
    && ok "$t" \
    || no "$t is gone — that family's discovery is unconstrained again"
done
for f in collectDivisorsE collectIndexUsesE collectArithE; do
  grep -qE "^partial def $f\b" "$RO" \
    && no "$f is 'partial' again — its completeness theorem cannot be stated" \
    || ok "$f is total"
done

echo "=== the bounds bug this work FOUND stays fixed (end-to-end, not just by rfl) ==="
# `(a)[i]` produced NO array-bounds obligation: absent from the report, not merely unproven,
# while `a[i]` got one. The Lean lock alone would not have caught it — the corpus contained no
# parenthesised array access, which is why the whole suite stayed green while the bug existed.
BIN="./.lake/build/bin/concrete"
# The binary must actually EMBODY the current source. Without this the check happily
# interrogates a stale build and reports OK for a fix that no longer compiles -- verifying
# that something was done rather than that it had effect. Caught by mutating the fix and
# watching this very assertion pass against the previous binary.
#
# An mtime comparison was tried first and is WRONG: lake does not relink on a cache hit, so a
# perfectly current binary can be older than its source. Building is the only honest signal.
if lake build >/dev/null 2>&1 && [ -x "$BIN" ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  cat > "$TMPD/paren.con" <<'CON'
mod parenbounds {
    fn plain(a: [i32; 16], i: i32) -> i32 { return a[i]; }
    fn parened(a: [i32; 16], i: i32) -> i32 { return (a)[i]; }
}
CON
  NVC="$("$BIN" "$TMPD/paren.con" --report vcs 2>/dev/null | grep -c 'array_bounds')"
  [ "$NVC" = "2" ] \
    && ok "both a[i] and (a)[i] generate an array-bounds VC (got $NVC)" \
    || no "expected 2 array-bounds VCs, got $NVC — a parenthesised access is silently unchecked again"
else
  no "build FAILED or binary missing — the end-to-end bounds check ran against nothing"
fi
grep -q "def arrayRootName" "$RO" \
  && ok "arrayRootName roots an access through its parens" \
  || no "arrayRootName is gone"
# It must NOT over-peel: a field path has no name for the length lookup, so peeling it would
# manufacture an obligation about the wrong array. A wrong obligation beats no obligation only
# in the sense that it is louder; it is still unsound.
grep -qE "^  \| \.fieldAccess" "$RO" && grep -A6 "def arrayRootName" "$RO" | grep -q "fieldAccess" \
  && no "arrayRootName peels .fieldAccess — the length lookup would read the WRONG array" \
  || ok "arrayRootName stops at .paren (no wrong-array obligations)"

echo "=== bounds: a WRONG obligation is worse than a missing one (shadowing) ==="
# The severe one. `arraySizeMap` used to take the FIRST binding of a name, so
#     let a: [i32; 16] = [0; 16];  let a: [i32; 4] = [7; 4];  return a[10];
# produced `0 <= 10 AND 10 < 16` for a FOUR-element array. That obligation is TRUE, so the
# report read "2 proved, 0 outstanding" for a program that traps at runtime -- a false claim,
# certified. The map now refuses to answer when a name has conflicting sizes, and the access is
# NAMED instead of silently dropped.
if [ -n "${TMPD:-}" ]; then
  cat > "$TMPD/shadow.con" <<'CON'
mod shadowbounds {
    fn shadow() -> i32 {
        let a: [i32; 16] = [0; 16];
        let b: i32 = a[0];
        let a: [i32; 4] = [7; 4];
        return a[10] + b;
    }
}
CON
  SH="$("$BIN" "$TMPD/shadow.con" --report vcs 2>/dev/null)"
  printf '%s' "$SH" | grep -q "10 < 16" \
    && no "the shadowed access is STILL sized from the wrong binding (10 < 16 on a 4-element array)" \
    || ok "no obligation is generated from the wrong binding"
  printf '%s' "$SH" | grep -q "OUTSIDE the bounds fragment" \
    && ok "the unresolvable access is NAMED, not silently dropped" \
    || no "the access vanished silently — coverage can be over-read again"
  # And the naming must survive the zero-VC path, which returns early.
  printf '%s' "$SH" | grep -q "shadowbounds.shadow: a" \
    && ok "naming works on the empty-VC path too" \
    || no "a function with only unresolvable accesses reports nothing at all"

  echo "=== bounds: sizes the old map could not see ==="
  cat > "$TMPD/sizes.con" <<'CON'
mod sizecov {
    fn let_inferred(i: i32) -> i64 { let a = [0; 16]; return a[i]; }
    fn nested(i: i32) -> i32 { if i > 0 { let a: [i32; 8] = [0; 8]; return a[i]; } return 0; }
}
CON
  NS="$("$BIN" "$TMPD/sizes.con" --report vcs 2>/dev/null | grep -c 'array_bounds')"
  [ "$NS" = "2" ] \
    && ok "unannotated-let and nested-let arrays both get bounds VCs (got $NS)" \
    || no "expected 2 array-bounds VCs, got $NS — an array size the compiler can see is being ignored"
else
  no "temp dir unavailable; the bounds obligation checks did not run"
fi
grep -q "all.filter fun (nm, n) => all.all" "$RO" \
  && ok "arraySizeMap drops names with conflicting sizes rather than guessing" \
  || no "the conflicting-size filter is gone — wrong-array obligations can return"

echo ""
echo "TRANSFORM-REGISTER: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
