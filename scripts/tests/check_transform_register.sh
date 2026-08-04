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

echo ""
echo "TRANSFORM-REGISTER: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
