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
# The repair refuses to certify what cannot be shown: a function that can REACH an
# indirect call has effects this compiler cannot see and does not get to be called pure.
# `Concrete/Proof/ProofCore.lean` already makes exactly that argument for `no recursion`
# and `--report stack-depth`; effect-freedom was the third guarantee on the same call
# graph and the only one still assuming.
#
# SCOPE, STATED: this closes the class WITHIN a compilation unit. The cross-package case
# — a user function reaching a handle defined in `std` — is NOT yet closed, because the
# proof call graph contains only the user program's modules, so a call into `std`
# resolves to a name with no node and nothing propagates. `base64_cli.print_bytes` is
# therefore still reported eligible, and that is asserted below rather than hidden, so
# this gate tells the truth about how far the repair reaches.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
CC="$ROOT_DIR/.lake/build/bin/concrete"
FIX="$ROOT_DIR/tests/regressions/effect_opacity/indirect_call_not_pure"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -x "$CC" ] || { echo "FATAL: compiler not built at $CC" >&2; exit 2; }

out="$(cd "$FIX" && timeout 300 "$CC" src/main.con --report eligibility 2>&1)"

echo "=== a genuinely effect-free function stays eligible (positive control) ==="
# Without this the gate would pass on a compiler that simply called everything opaque,
# which would be a different bug with the same green.
if printf '%s' "$out" | grep -qE 'eligible +`indirect_call_not_pure\.plain`'; then
  ok "plain is still eligible"
else
  no "plain lost eligibility — the rule is over-broad, not conservative"
fi

echo "=== reaching an indirect call refuses certification ==="
for fn in fire fire2; do
  if printf '%s' "$out" | grep -A1 -E "excluded +\`indirect_call_not_pure\.$fn\`" \
     | grep -q "effects may enter through an indirect call"; then
    ok "$fn is excluded, and for the effect reason"
  else
    no "$fn is not excluded for reaching an indirect call"
    printf '%s\n' "$out" | grep -A1 -E "\`indirect_call_not_pure\.$fn\`" | sed 's/^/       /'
  fi
done

echo "=== the exclusion is TRANSITIVE, not per-body ==="
# fire2 makes no indirect call itself; it calls fire. The defect this came from reached
# the indirect call two hops down, so a per-body predicate would have missed it.
if printf '%s' "$out" | grep -A1 -E 'excluded +`indirect_call_not_pure\.fire2`' \
   | grep -q "effects may enter through an indirect call"; then
  ok "a caller two hops from the indirect call is also refused"
else
  no "transitivity is not being applied — only direct indirect calls are caught"
fi

echo "=== totals agree with the per-function verdicts ==="
if printf '%s' "$out" | grep -q "4 functions — 1 eligible, 3 excluded"; then
  ok "1 eligible, 3 excluded"
else
  no "unexpected totals"
  printf '%s\n' "$out" | grep "Totals:" | sed 's/^/       /'
fi

echo "=== KNOWN GAP: the cross-package case is not yet closed ==="
# Asserted so the limit is visible and a future fix flips a failing check rather than
# silently widening a passing one. When the proof call graph learns about dependency
# modules, this check should START FAILING and be inverted in the same commit.
b64="$ROOT_DIR/examples/base64_cli"
if [ -d "$b64" ]; then
  bout="$(cd "$b64" && timeout 300 "$CC" src/main.con --report eligibility 2>&1)"
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
