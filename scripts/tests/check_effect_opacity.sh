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
# THE REPAIR REFUSES ADMISSION WITHOUT REFUSING EXTRACTION, AND THAT SPLIT IS THE POINT.
#
# A first attempt folded opacity into `eligible`. That bit decides TWO things — whether a
# function is admissible as effect-free, AND whether it is extracted for subject facts at
# all — so refusing higher-order functions removed them from the evidence surface, and
# `check_shadow_body_v2.sh` caught it: its "a function used as a VALUE is an edge"
# assertion exists precisely so a higher-order program does not look dependency-free.
# Trading a false purity claim for a missing dependency edge relocates an R-0004 gap
# instead of closing one.
#
# So `eligible` still gates extraction and a separate `admissible` gates proof admission.
# Both halves are asserted below, because a repair that only did the first half would be
# the original defect and a repair that only did the second would be the failed attempt.
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

echo "=== a genuinely effect-free function is still admitted (positive control) ==="
# Without this the gate would pass on a compiler that refused everything, which is a
# different bug with the same green.
if printf '%s' "$out" | grep -qE "eligible +\`indirect_call_not_pure\.plain\`"; then
  ok "plain is admitted"
else
  no "plain is no longer admitted — the rule is over-broad, not conservative"
fi

echo "=== the REPORTS no longer claim purity they cannot establish ==="
# This half IS live. Reports consult opacity directly, so they are honest even while
# admission is inert.
cout="$(cd "$FIX" && $TO "$CC" src/main.con --report caps 2>&1)"
if printf '%s' "$cout" | grep -qE "plain +: \(pure\)"; then
  ok "a genuinely effect-free function still reads (pure)"
else
  no "plain lost its (pure) rendering — the rule is over-broad, not conservative"
fi
for fn in fire fire2; do
  if printf '%s' "$cout" | grep -qE "$fn +: \(effects unknown: reaches an indirect call\)"; then
    ok "$fn reads as effects-unknown rather than pure"
  else
    no "$fn still reads as pure in --report caps"
  fi
done
if printf '%s' "$cout" | grep -q "1 pure"; then
  ok "the purity total counts a claim (1), not empty capability sets (would be 4)"
else
  no "the purity total is not counting a claim"
  printf '%s\n' "$cout" | grep "Totals:" | sed 's/^/       /'
fi

echo "=== KNOWN GAP: admission does not yet refuse them ==="
# `EligibilityEntry.admissible` is deliberately inert. The rule works and was reverted
# because its reach into the evidence machinery — drift coverage, replay targets — raises
# a question about whether an inadmissible claim should still be REPLAYED, which is about
# evidence semantics rather than effect-freedom. Asserted here so enabling it fails this
# check and forces the answer to be written down. See R-0484.
pout="$(cd "$FIX" && $TO "$CC" src/main.con --report proof-status 2>&1)"
for fn in fire fire2; do
  if printf '%s' "$pout" | grep -q "effects may enter through an indirect call"; then
    no "$fn IS now refused — admission was enabled; re-pin this gate and answer the replay question"
  else
    ok "$fn is still admitted (expected; admission deliberately inert)"
  fi
done

echo "=== but EXTRACTION is preserved (the failed attempt broke this) ==="
# Refusing admission must not remove the function from the evidence surface. If this
# fails, higher-order programs look dependency-free and an R-0004 gap has been moved
# rather than closed.
facts="$(cd "$FIX" && $TO "$CC" src/main.con --report subject-facts 2>/dev/null | grep -c 'v1:user:indirect_call_not_pure.fire' || true)"
if [ "${facts:-0}" -gt 0 ]; then
  ok "a refused higher-order function still has subject facts ($facts)"
else
  no "refusing admission also dropped the function from extraction — this is the failed attempt"
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
