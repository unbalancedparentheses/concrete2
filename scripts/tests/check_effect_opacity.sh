#!/usr/bin/env bash
# R-0484: AN EMPTY CAPABILITY SET IS "NOTHING DECLARED", NOT "NOTHING HAPPENS".
#
# The two were equated. `examples/base64_cli`'s `print_bytes` takes a `&Writer`, calls
# `Writer::write`, performs real I/O, and was reported `(pure)`, counted in a `1 pure`
# total, and admitted to the provable subset ON THE GROUNDS OF PURITY — while `usage`,
# which only prints a string, was excluded for honestly declaring `Console`.
#
# The erasure is at the `trusted` boundary and travels on a function pointer:
# `console_write` calls `libc_write` and declares nothing, so its TYPE is
# capability-free, so it fits `Writer`'s `write_fn` field, so calls through the handle
# are capability-free. `println`, same module, same syscall, declares `Console`. Nothing
# checks the difference.
#
# THE REPAIR IS NOT YET IN PLACE, AND THIS GATE RECORDS WHY RATHER THAN ASSERTING A FIX.
#
# The obvious repair — refuse proof eligibility to any function that can REACH an
# indirect call — was implemented and reverted. `assessEligibility` decides TWO things
# with one bit: whether a function is admissible as effect-free, AND whether it is
# extracted for subject facts at all. Measured: a function excluded for ANY reason
# vanishes from `--report subject-facts` entirely (checked for a capability exclusion
# too, so this is the existing coupling and not something the attempt introduced).
#
# So refusing higher-order functions removed them from the evidence surface, and
# `check_shadow_body_v2.sh` caught it: its "a function used as a VALUE is an edge"
# assertion needs higher-order bodies to still produce dependency edges, precisely so a
# higher-order program does not look dependency-free. Trading a false purity claim for
# a missing dependency edge is not a repair; it moves an R-0004 evidence gap rather
# than closing one.
#
# The refusal belongs where effect-freedom is CLAIMED, not where extractability is
# decided, and separating those is a real change to the R-0004 extraction path. Until
# then this gate pins the current, defective behaviour so the defect stays measured and
# cannot drift silently. Every check below that says "still" is a known gap: when the
# repair lands, these flip and must be inverted in the same commit.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
CC="$ROOT_DIR/.lake/build/bin/concrete"
FIX="$ROOT_DIR/tests/regressions/effect_opacity/indirect_call_not_pure"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -x "$CC" ] || { echo "FATAL: compiler not built at $CC" >&2; exit 2; }

# `timeout` is coreutils and is NOT present on a stock macOS runner. run_tests.sh
# already degrades rather than skipping (see its PROJ_TIMEOUT), and this gate is
# invoked FROM run_tests.sh, so it runs on macOS too and needs the same treatment.
# A missing watchdog is worth saying out loud: a hang here would otherwise look
# like an unexplained CI stall.
if command -v timeout >/dev/null 2>&1; then
  TO="timeout 300"
else
  TO=""
  echo "  warn 'timeout' not found — running without a hang watchdog"
fi


out="$(cd "$FIX" && $TO "$CC" src/main.con --report eligibility 2>&1)"

echo "=== a genuinely effect-free function is eligible (control) ==="
# Keeps the fixture honest: if this ever fails, the fixture stopped describing the
# ordinary case and the gaps below would be measuring nothing.
if printf '%s' "$out" | grep -qE 'eligible +`indirect_call_not_pure\.plain`'; then
  ok "plain is eligible"
else
  no "plain is not eligible — the fixture no longer models the ordinary case"
fi

echo "=== KNOWN GAP: reaching an indirect call does not refuse certification ==="
# `fire` calls through a fn pointer; `fire2` reaches one a hop further away. Both are
# admitted to the provable subset on an empty capability set, which is the defect.
for fn in fire fire2; do
  if printf '%s' "$out" | grep -qE "eligible +\`indirect_call_not_pure\.$fn\`"; then
    ok "$fn is STILL eligible despite reaching an indirect call (expected; defect open)"
  else
    no "$fn is no longer eligible: the repair landed — invert this check and update R-0484"
  fi
done

echo "=== KNOWN GAP: totals still count the opaque functions as provable ==="
if printf '%s' "$out" | grep -q "4 functions — 3 eligible, 1 excluded"; then
  ok '3 eligible, 1 excluded (only main, as entry point) — the defect, pinned'
else
  no "totals moved; re-measure before changing this line"
  printf '%s\n' "$out" | grep "Totals:" | sed 's/^/       /'
fi

echo "=== KNOWN GAP: the original cross-package instance ==="
# The measured instance R-0484 came from. Even once the rule is fixed, this one needs
# the proof call graph to contain dependency modules: a call into `std` resolves to a
# name with no node, so nothing propagates.
b64="$ROOT_DIR/examples/base64_cli"
if [ -d "$b64" ]; then
  bout="$(cd "$b64" && $TO "$CC" src/main.con --report eligibility 2>&1)"
  if printf '%s' "$bout" | grep -qE 'eligible +`base64_cli\.print_bytes`'; then
    ok "base64_cli.print_bytes is STILL eligible — cross-package opacity remains open (expected)"
  else
    no "print_bytes is no longer eligible: the gap closed, so invert this check and update R-0484"
  fi
else
  no "examples/base64_cli is missing; the known-gap check did not run"
fi

echo
echo "EFFECT-OPACITY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
