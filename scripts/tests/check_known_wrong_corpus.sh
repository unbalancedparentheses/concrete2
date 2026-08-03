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

echo "=== H23 (CLOSED 2026-08-03): the cap holds, on every surface ==="
# Was: "an unproven invariant still launders into a proved obligation". R-0461 closed it,
# so these assertions are INVERTED — they now guard the fix against regression rather than
# document the hole. The fixture stays in the corpus for exactly that reason.
#
# What R-0461 fixed is the CLAIM and the GATE, not the program. The binary still traps, and
# it should: the bounds check is the runtime doing its job on an index that really is out of
# range. A cap that silenced the trap would be a worse bug than the one it replaced.
H23="examples/unsound_hypothesis/src/main.con"
V23="$("$COMPILER" "$H23" --report vcs 2>/dev/null)"
printf '%s' "$V23" | grep -A2 "#bounds0" | grep -q "assumed" \
  && ok "bounds obligation is capped to 'assumed' (R-0461)" \
  || no "bounds0 is NOT capped — H23 has REGRESSED; capOnHypothesisDebt is not firing"
printf '%s' "$V23" | grep -A3 "#bounds0" | grep -q "rests on (unproved).*#O2" \
  && ok "the report names the unproved VC the cap rests on" \
  || no "bounds0 does not name its outstanding debt — the cap fired without saying why"
# Non-vacuity, unchanged in spirit: if the invariant ever became provable the cap would
# correctly stop firing, and the two assertions above would then be testing nothing.
printf '%s' "$V23" | grep -A2 "#O2" | grep -q "unproven" \
  && ok "the invariant it rests on is still unproven (fixture is non-vacuous)" \
  || no "O2 is no longer unproven — the fixture stopped exercising the cap"
# The badge surface, which is where H23's headline actually appeared. The ledger and the
# multi-kernel report derived their class separately, so fixing one left the other lying.
printf '%s' "$("$COMPILER" "$H23" --report multi-kernel 2>/dev/null)" \
  | grep -A3 "#bounds0" | grep -q "=> assumed" \
  && ok "the multi-kernel badge is capped too (no proved_by_* on this obligation)" \
  || no "the multi-kernel report still badges bounds0 as proved — surfaces disagree"
# And the release gate. Display without enforcement is how the first fix would have been
# half a fix: the report read 'assumed' while `check` still exited 0.
H23DIR="$TMP/h23policy"; mkdir -p "$H23DIR/src"; cp "$H23" "$H23DIR/src/main.con"
printf '[policy]\nforbid-assume = true\n' > "$H23DIR/Concrete.toml"
# Captured, not piped: `check` exits non-zero BECAUSE the gate fired, and under
# `set -o pipefail` that non-zero propagates past a matching grep and reads as FAIL.
P23="$( cd "$H23DIR" && "$COMPILER" check src/main.con 2>&1 )"
printf '%s' "$P23" | grep -q "E0617" \
  && ok "release policy rejects the capped obligation (E0617 under forbid-assume)" \
  || no "forbid-assume does NOT reject a capped obligation — the cap is display-only"
# The OTHER release stance. KNOWN_HOLES recorded that `require-two-kernels = true` built
# this program with exit 0 — "the strongest release stance in the system green-lights it".
# R-0465's 5th part made the gate read badges off the capped ledger rather than recount
# kernels from a second prover run, so the cap now propagates here too. Asserted because
# this composition is emergent, not designed: nothing in R-0465 set out to close it.
#
# Runs only where an external kernel exists; without one the gate reports the missing
# toolchain instead, which is a different (correct) message.
if command -v coqc >/dev/null 2>&1 || command -v isabelle >/dev/null 2>&1; then
  H23TK="$TMP/h23twokernel"; mkdir -p "$H23TK/src"; cp "$H23" "$H23TK/src/main.con"
  printf '[policy]\nrequire-two-kernels = true\n' > "$H23TK/Concrete.toml"
  T23="$( cd "$H23TK" && "$COMPILER" check src/main.con 2>&1 )"
  printf '%s' "$T23" | grep -q "E0616" \
    && ok "require-two-kernels also rejects the capped obligation (E0616)" \
    || no "require-two-kernels accepts the H23 fixture — the cap does not reach this gate"
else
  echo "  (skipped require-two-kernels assertion — no external kernel on PATH)"
fi

"$COMPILER" "$H23" -o "$TMP/h23" >/dev/null 2>&1
"$TMP/h23" >/dev/null 2>&1; expect_trap $? "H23 fixture still traps (the runtime check is correct)"

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
