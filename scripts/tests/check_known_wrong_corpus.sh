#!/usr/bin/env bash
# Known-wrong corpus gate — the counterexample fixtures for OPEN holes.
#
# H23 and H24 are documented with reproductions in examples/. Those fixtures are `skip`
# in the example manifest, because the corpus checks that programs succeed and these
# deliberately do not. Skipped means nothing runs them, and a counterexample fixture that
# silently stops reproducing is worse than none: the hole stays open, the docs keep citing
# a file that no longer demonstrates it, and nobody finds out.
#
# So this gate asserts each fixture STILL EXHIBITS the behaviour its hole documents.
#
# READ THIS BEFORE "FIXING" A FAILURE HERE. A red assertion means the documented
# behaviour changed. That is usually GOOD NEWS — the hole got fixed — and the correct
# response is to update docs/KNOWN_HOLES.md and flip the assertion into its
# post-fix form, NOT to make the fixture wrong again. These assertions are written to be
# inverted when R-0461 / R-0464 land; each one names what it should become.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
COMPILER="$ROOT_DIR/.lake/build/bin/concrete"
[ -x "$COMPILER" ] || { echo "error: build first ($COMPILER missing)" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# A trap is death by SIGNAL (128+signum; abort() is SIGABRT => 134). Same discipline as
# check_checked_arith.sh, and for the same reason: a nonzero exit of the program's own
# choosing is not a trap, and conflating them is how H22 hid.
expect_trap(){ local code="$1" what="$2"
  if [ "$code" -ge 128 ]; then ok "$what traps at runtime (signal exit $code)"
  else no "$what did NOT trap (exit $code) — if the fix landed, update KNOWN_HOLES"; fi; }

echo "=== H23: an unproven invariant still launders into a proved obligation ==="
H23="examples/unsound_hypothesis/src/main.con"
V23="$("$COMPILER" "$H23" --report vcs 2>/dev/null)"
# Both halves matter. Asserting only "bounds0 is proved" would keep passing if the
# invariant ever became provable — the fixture would then be vacuous while still green.
printf '%s' "$V23" | grep -A2 "#bounds0" | grep -q "proved" \
  && ok "bounds obligation still reads proved (R-0461 must make this 'assumed')" \
  || no "bounds0 no longer proved — H23 may be FIXED; update KNOWN_HOLES and flip this"
printf '%s' "$V23" | grep -A2 "#O2" | grep -q "unproven" \
  && ok "the invariant it rests on is still unproven (fixture is non-vacuous)" \
  || no "O2 is no longer unproven — the fixture stopped demonstrating H23"
"$COMPILER" "$H23" -o "$TMP/h23" >/dev/null 2>&1
"$TMP/h23" >/dev/null 2>&1; expect_trap $? "H23 fixture (proved bounds, out-of-range index)"

echo "=== H24: trap conditions are still weaker than IntArith's ==="
H24="examples/trap_semantics_gap/src/main.con"
V24="$("$COMPILER" "$H24" --report vcs 2>/dev/null)"
printf '%s' "$V24" | grep -A2 "#div0" | grep -q "proved" \
  && ok "div obligation still reads proved (R-0464 must cover signed MIN / -1)" \
  || no "div0 no longer proved — H24's insufficiency half may be FIXED; update the docs"
# The applicability half: shifts generate NOTHING. Asserted by absence, which is exactly
# why it was invisible — there is no obligation to inspect, so only a test that looks for
# the ABSENCE can see it.
printf '%s' "$V24" | grep -qi "shift" \
  && no "a shift obligation now exists — H24's applicability half may be FIXED" \
  || ok "shifts still generate NO obligation at all (applicability gap)"
"$COMPILER" "$H24" -o "$TMP/h24" >/dev/null 2>&1
"$TMP/h24" >/dev/null 2>&1; expect_trap $? "H24 fixture (proved division, MIN / -1)"

echo "=== the differential surfaces still do not catch H24 ==="
# Recorded as an assertion because the register USED to claim bridge-check probes
# sufficiency. It does not: it evaluates the obligation against the same obligation, so
# `b != 0` holds at (MIN, -1) and nothing is refuted. If this ever goes green the
# surface got stronger and VC_BRIDGE_REGISTER.md's correction needs revisiting.
BC="$("$COMPILER" "$H24" --report bridge-check 2>/dev/null)"
printf '%s' "$BC" | grep -q "no counterexample" \
  && ok "bridge-check still reports no counterexample on the aborting function" \
  || no "bridge-check now flags it — it may probe sufficiency after all; update the register"

echo ""
echo "KNOWN-WRONG-CORPUS: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
