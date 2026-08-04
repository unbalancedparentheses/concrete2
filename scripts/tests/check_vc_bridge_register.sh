#!/usr/bin/env bash
# VC-bridge register gate.
#
# docs/VC_BRIDGE_REGISTER.md inventories the Core→obligation lowering rule by rule:
# what each emits, assumes, rejects, which example forced it, and the theorem that
# will discharge it. That bridge is the one every runtime-safety claim rests on, and
# the one multi-kernel agreement provably cannot check — all kernels check the SAME
# lowered proposition, so a mis-lowering yields unanimous agreement on the wrong
# formula.
#
# This gate keeps the register honest in both directions:
#   * every obligation-family generator in the code has a register row, so a new
#     family cannot ship undocumented;
#   * every row names a real generator, so the register cannot accumulate rows for
#     rules that no longer exist (the drift direction docs usually fail in).
#
# Cheap: pure grep, no build, no provers.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

REG="docs/VC_BRIDGE_REGISTER.md"
SRC="Concrete/Report/ReportObligations.lean"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$REG" ] || { echo "error: $REG missing" >&2; exit 2; }
[ -f "$SRC" ] || { echo "error: $SRC missing" >&2; exit 2; }

echo "=== every obligation family generator has a register row ==="
# The families are the top-level `def <name>Obligations (modules : List Module)`
# generators. Derived from the source, not hardcoded, so adding a family is what
# trips this gate rather than someone remembering to update a list here.
FAMILIES="$(grep -oE '^def [a-zA-Z]+Obligations \(modules' "$SRC" \
            | sed -E 's/^def ([a-zA-Z]+Obligations) .*/\1/' | sort -u)"

if [ -z "$FAMILIES" ]; then
  no "found no obligation-family generators in $SRC (pattern changed?)"
else
  COUNT=$(printf '%s\n' "$FAMILIES" | grep -c '[^[:space:]]')
  ok "discovered $COUNT obligation-family generator(s) in the source"
  for f in $FAMILIES; do
    if grep -q "\`$f\`" "$REG"; then
      ok "$f has a register row"
    else
      no "$f has NO row in $REG — a new obligation family must be registered"
    fi
  done
fi

echo "=== every register row names a real generator (no stale rows) ==="
# Rows are `### \`name\`` headings. A row for a deleted generator is drift in the
# other direction and would quietly overstate coverage.
ROWS="$(grep -oE '^### `[a-zA-Z]+Obligations`' "$REG" \
        | sed -E 's/^### `([a-zA-Z]+Obligations)`/\1/' | sort -u)"
if [ -z "$ROWS" ]; then
  no "no register rows found in $REG (heading format changed?)"
else
  for r in $ROWS; do
    grep -qE "^def $r \(modules" "$SRC" \
      && ok "row $r corresponds to a real generator" \
      || no "row $r names no generator in $SRC — stale register row"
  done
fi

echo "=== each row states what it assumes, rejects, and what will discharge it ==="
# A row that omits these is a title, not a contract. Checked per row so an
# incomplete row cannot hide behind a complete one.
for r in $ROWS; do
  # slice from this row's heading to the next `###`/`##`
  SEC="$(awk -v pat="^### \`$r\`" '
    $0 ~ pat {f=1; next}
    f && /^#{2,3} / {exit}
    f {print}' "$REG")"
  # A row may declare itself a PROJECTION — it selects existing obligations rather
  # than lowering anything, so it has no contract to state and nothing to discharge.
  # Giving such a row invented Emits/Assumes fields would be worse than exempting it:
  # it would assert a contract that does not exist.
  if printf '%s' "$SEC" | grep -q '\*\*Kind\*\*: projection'; then
    ok "$r is a declared projection (no lowering contract to state)"
    continue
  fi
  MISSING=""
  printf '%s' "$SEC" | grep -q '\*\*Emits\*\*'    || MISSING="$MISSING Emits"
  printf '%s' "$SEC" | grep -q '\*\*Assumes\*\*'  || MISSING="$MISSING Assumes"
  printf '%s' "$SEC" | grep -q '\*\*Rejects\*\*'  || MISSING="$MISSING Rejects"
  printf '%s' "$SEC" | grep -q 'Discharging theorem' || MISSING="$MISSING DischargingTheorem"
  if [ -z "$MISSING" ]; then
    ok "$r states Emits / Assumes / Rejects / discharging theorem"
  else
    no "$r is missing:$MISSING"
  fi
done

echo "=== the register does not claim rows are discharged when they are not ==="
# The status line is the one place a reader looks for "how much of this is real".
# If a row ever gets discharged, this must be updated deliberately, not drift.
grep -qE 'Rows discharged: \*\*[0-9]+ of [0-9]+\*\*' "$REG" \
  && ok "register states an explicit discharged-row count" \
  || no "register must state 'Rows discharged: **N of M**'"

echo "=== R-0460: the sufficiency theorem exists and is actually proved ==="
# A register row is discharged by a THEOREM, not by a row saying so. The build being green
# is the proof; this only checks the row was not quietly emptied.
IA="Concrete/Semantics/IntArith.lean"
grep -q "^theorem trapConditions_sufficient" "$IA" \
  && ok "trapConditions_sufficient is present" \
  || no "trapConditions_sufficient MISSING — the div/mod row is undischarged again"
for bad in sorry admit native_decide; do
  grep -qE "\b$bad\b" "$IA" \
    && no "$IA contains '$bad' — the sufficiency theorem is not actually proved" \
    || ok "no '$bad' in the trap semantics"
done
# The defect the theorem caught. `resultInRange` shipped as the constant `true`, which made
# the statement false for + - * while the row looked one step from discharged.
if grep -qE "^\s*\|\s*\.resultInRange => true" "$IA"; then
  no "resultInRange is the constant 'true' again — the sufficiency claim is vacuous for + - *"
else
  ok "resultInRange is op-specific (not the vacuous placeholder it shipped as)"
fi
# And the honest limit: shifts are covered only vacuously, so the row must NOT read discharged.
# A DECLARATION, not a mention: the docstring legitimately discusses the shift row in order
# to say the theorem does not cover it. Matching bare text flagged that explanation — the
# same "gate describes the defect it guards against" noise this suite has hit before.
if grep -qE "^(private )?theorem shift_obligation_sufficient" "$IA"; then
  no "a shift sufficiency theorem is DECLARED — but evalIntBinOp does not model shifts, so it would be vacuous"
else
  ok "no shift sufficiency theorem is declared (evalIntBinOp does not model shifts)"
fi
grep -q "VACUOUS" "$IA" \
  && ok "the vacuity of the shift case is stated where the theorem lives" \
  || no "nothing warns that the theorem's shift case is vacuous — it reads as covering shifts"

echo ""
echo "VC-BRIDGE-REGISTER: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
