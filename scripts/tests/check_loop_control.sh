#!/usr/bin/env bash
# Loop-control gate (ROADMAP Phase 6 #4).
#
# break / continue / labeled loops / while-as-expression are implemented; this
# gate pins their behavior so further control-flow work (defer, more patterns)
# builds on a fixed semantics. It locks four things:
#
#   1. CONTROL FLOW — unlabeled break exits the innermost loop only; labeled
#      `break 'l` exits the named loop; `for` supports break + continue.
#   2. WHILE-AS-EXPRESSION VALUE — `break <v>` and the `else { v }` block produce
#      the loop's value, correctly at non-i64 widths (regression: the value used
#      to be stored as i64 into a narrower result slot and read back as 0).
#   3. LINEAR CLEANUP — break/continue that would skip an unconsumed linear value
#      are rejected (E0210 / E0211); a linear consumed before the break is fine.
#   4. TYPE AGREEMENT — a while-expression's break value and else value must have
#      the same type (E0222).
#
# Fixtures live in tests/programs/loop_control/ (not picked up by the main suite,
# which only scans tests/programs/*.con). See docs/LOOP_CONTROL.md.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/tests/lib/selfprint.sh"
cd "$ROOT_DIR"
C="$ROOT_DIR/.lake/build/bin/concrete"
[ -x "$C" ] || { echo "error: build first ($C missing)" >&2; exit 2; }
D="tests/programs/loop_control"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# run_expect <fixture> <expected-stdout>
run_expect(){
  local name="$1" exp="$2"
  gate_selfprint_wrap "$D/$name.con" "$TMP/$name.w.con"
  if ! "$C" "$TMP/$name.w.con" -o "$TMP/$name.bin" >"$TMP/$name.err" 2>&1; then
    no "$name: expected to compile, but it failed"; sed 's/^/        /' "$TMP/$name.err" | head -3; return
  fi
  local got; got="$("$TMP/$name.bin" 2>/dev/null)"
  [ "$got" = "$exp" ] && ok "$name -> $got" || no "$name: got '$got', want '$exp'"
}

# reject_with <fixture> <E-code>
reject_with(){
  local name="$1" code="$2"
  local out; out="$("$C" "$D/$name.con" -o "$TMP/$name.bin" 2>&1)"
  if grep <<<"$out" -qE 'error\['; then
    grep <<<"$out" -q "($code)" \
      && ok "$name rejected with $code" \
      || { no "$name rejected, but not with $code"; grep <<<"$out" -oE '\([A-Z0-9]+\)[^|]*' | head -1 | sed 's/^/        got: /'; }
  else
    no "$name: expected rejection ($code), but it compiled"
  fi
}

echo "=== 1. control flow: break scope, labeled break, for break/continue ==="
run_expect break_inner_only 3
run_expect labeled_break 1
run_expect for_break_continue 8

echo "=== 2. while-as-expression value (non-i64 width regression) ==="
run_expect loop_result_break_i32 7
run_expect loop_result_completes_i32 42

echo "=== 3. linear cleanup across break/continue ==="
run_expect break_after_consume_linear 0
reject_with neg_break_leaks_linear E0210
reject_with neg_continue_leaks_linear E0211

echo "=== 4. while-expression break/else type agreement ==="
reject_with neg_while_expr_removed E0001

echo "=== 5. the bounded-loop classifier is FAIL-CLOSED ==="
# The `predictable` profile advertises "bounded iteration, compiler-enforced"
# (docs/PREDICTABLE_BOUNDARIES.md). It was enforcing something much weaker: the condition had
# to LOOK like a comparison and the step list had to be non-empty, with nothing tying the two
# together. Both loops below were classified `bounded`, the module passed
# `--check predictable`, and the effects report said `0 unbounded loops` -- for code that runs
# forever. This is a LIVENESS claim, so no safety obligation could ever have noticed it.
BIN_LC="$ROOT_DIR/.lake/build/bin/concrete"
if lake build >/dev/null 2>&1 && [ -x "$BIN_LC" ]; then
  TD_LC="$(mktemp -d)"; trap 'rm -rf "$TD_LC"' EXIT
  cat > "$TD_LC/loops.con" <<'CON'
mod loopcls {
    fn honest(n: i32) -> i32 {
        let mut z: i32 = 0;
        for (let mut i: i32 = 0; i < n; i = i + 1) { z = z + 1; }
        return z;
    }
    fn never_ends(n: i32) -> i32 {
        let mut z: i32 = 0;
        for (let mut i: i32 = 0; i < n; z = z + 1) { z = z + 1; }
        return z;
    }
    fn wrong_way(n: i32) -> i32 {
        let mut z: i32 = 0;
        for (let mut i: i32 = 0; i < n; i = i - 1) { z = z + 1; }
        return z;
    }
}
CON
  EFF="$("$BIN_LC" "$TD_LC/loops.con" --report effects 2>/dev/null)"
  NUNB="$(printf '%s' "$EFF" | grep -c 'loops: unbounded')"
  [ "$NUNB" = "2" ] \
    && ok "a step on an unrelated variable, and a step AWAY from the bound, both read unbounded" \
    || no "expected 2 unbounded loops, got $NUNB — a non-terminating loop reads as bounded"
  printf '%s' "$EFF" | grep -q 'loops: bounded' \
    && ok "and the honest i = i + 1 loop is still bounded (not merely rejecting everything)" \
    || no "a genuinely bounded loop is now misclassified — the rule is too strict to be useful"
  "$BIN_LC" "$TD_LC/loops.con" --check predictable >/dev/null 2>&1 \
    && no "--check predictable ADMITS a module containing two infinite loops" \
    || ok "--check predictable rejects the module"
else
  no "build failed or binary missing; the loop-classifier checks did not run"
fi

echo ""
echo "LOOP-CONTROL: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
