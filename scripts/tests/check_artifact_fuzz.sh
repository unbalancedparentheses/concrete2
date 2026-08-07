#!/usr/bin/env bash
# R-0462 — fuzz the COMPILED BINARY against the safety claims.
#
# Register A asserts: if the obligation holds, the runtime property holds. R-0460 discharges
# that as theorems, row by row. This is the empirical shadow of the same statement, and it
# reaches something no theorem in this repo does: it runs the artifact, so it crosses
# surface -> Core -> SSA -> LLVM, which NO register row covers.
#
# Distinct from `--report bridge-check`, which evaluates the OBLIGATION on sampled inputs and
# looks for one that refutes it. That tests an obligation against a model. This tests the
# CLAIM against the thing that ships.
#
# H23 is the existence proof: a bounds obligation read `proved_by_multi_kernel (3: lean, rocq,
# isabelle)` and the binary aborted on its first run. Every kernel-side surface reported
# success. A fuzzer pointed at the binary catches it in seconds — which is what this does.
#
# Method: `--report artifact-fuzz` emits a `#[test]` driver calling every fuzzable function
# with inputs its `#[requires]` admits; append it to the source and run `--test`, which
# compiles via clang and executes. Exit 134 (SIGABRT) means a trap.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fresh.sh"
require_fresh_binary || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
COMPILER="$ROOT_DIR/.lake/build/bin/concrete"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -x "$COMPILER" ] || { echo "FAIL compiler not built — run 'make build'"; exit 1; }

# Run one of the two drivers for $1. $2 is BEGIN/END marker prefix ("" or "MECHANISM ").
# Echoes: trap | clean | nodriver | error:<code>
fuzz_one() {
  local src="$1" kind="${2:-}"
  local srcdir; srcdir="$(dirname "$src")"
  local name; name="$(basename "$(dirname "$srcdir")")"
  # Copy the whole source DIRECTORY. Multi-file examples resolve sibling modules relative to
  # the file's own directory, so a lone copy in $TMP fails with a resolve error (E0101) — which
  # reads as "the fuzzer is broken" when it means "the fuzzer moved the file from its modules".
  local sandbox="$TMP/${name}_${kind// /}"
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  cp -r "$srcdir/." "$sandbox/" 2>/dev/null || { echo nodriver; return; }
  local work="$sandbox/$(basename "$src")"
  local plan; plan="$("$COMPILER" "$src" --report artifact-fuzz 2>/dev/null)"
  local body
  body="$(printf '%s' "$plan" | sed -n "/BEGIN ${kind}DRIVER/,/END ${kind}DRIVER/p" | sed '1d;$d')"
  # An empty body means the driver has no calls: not "clean", but "nothing was exercised".
  printf '%s' "$body" | grep -q "acc = acc +" || { echo nodriver; return; }
  printf '%s' "$body" >> "$work"
  local out; out="$("$COMPILER" "$work" --test 2>&1)"
  if printf '%s' "$out" | grep -q "exited with code 134"; then echo trap
  elif printf '%s' "$out" | grep -qE "^PASS|tests passed|^OK"; then echo clean
  else echo "error:$(printf '%s' "$out" | grep -oE 'error\[[a-z]+\]: \([A-Z0-9]+\)' | head -1)"
  fi
}

echo "=== MECHANISM: the harness can detect a trap in the compiled artifact ==="
# This assertion exists because of an outcome that is good news read carelessly. After R-0461
# and R-0464, NO fixture in this repo claims a proved obligation on a function that traps —
# that is precisely what those fixes accomplished. So the soundness check below finds nothing,
# and a check that finds nothing is indistinguishable from one that cannot find anything.
#
# The mechanism driver calls the `unproved` functions, which are KNOWN to trap and which the
# compiler never claimed were safe. A trap here is not a defect; its ABSENCE would mean the
# harness is blind and every clean result below is worthless.
MECH=0
for ex in examples/trap_semantics_gap examples/unsound_hypothesis examples/error_conventions; do
  R="$(fuzz_one "$ex/src/main.con" "MECHANISM ")"
  if [ "$R" = "trap" ]; then
    ok "$(basename "$ex"): harness detects the trap by RUNNING the binary (exit 134)"
    MECH=1
  elif [ "$R" = "nodriver" ]; then
    echo "  (skip $(basename "$ex") — no unproved fuzzable function)"
  else
    no "$(basename "$ex"): mechanism driver gave '$R' — expected a detected trap"
  fi
done
[ "$MECH" = "1" ] \
  && ok "the fuzzer is proven able to find a real trap (soundness results below mean something)" \
  || no "NO mechanism case fired — the fuzzer may be structurally blind; treat clean results as unverified"

echo "=== SOUNDNESS: no function the compiler CLAIMS is safe traps ==="
# The check the task is actually about. `claimed` = has runtime-safety obligations and they all
# read proved, so a trap is a counterexample to Register A, to the obligation generator, or to
# the lowering. `unclaimed` = no safety obligation at all, so a trap means one should have
# existed — the applicability half of H24, where the shift family was absent and the binary
# aborted with nothing stated.
CLAIMED_TOTAL=0
for d in examples/*/; do
  src="$d/src/main.con"
  [ -f "$src" ] || continue
  PLAN="$("$COMPILER" "$src" --report artifact-fuzz 2>/dev/null)"
  N="$(printf '%s' "$PLAN" | grep -oE 'claimed   \(all safety obligations proved\): [0-9]+' | grep -oE '[0-9]+$')"
  U="$(printf '%s' "$PLAN" | grep -oE 'unclaimed \(no safety obligation at all\):   [0-9]+' | grep -oE '[0-9]+$')"
  [ -n "${N:-}" ] || N=0
  [ -n "${U:-}" ] || U=0
  CLAIMED_TOTAL=$((CLAIMED_TOTAL + N + U))
  [ "$((N + U))" -gt 0 ] || continue
  R="$(fuzz_one "$src" "")"
  case "$R" in
    clean)    ok "$(basename "$d"): $N claimed + $U unclaimed function(s), no trap" ;;
    nodriver) ;;
    trap)     no "$(basename "$d") TRAPPED — a claimed-safe function is refuted by the ARTIFACT" ;;
    *)        no "$(basename "$d"): driver failed ($R) — not exercised" ;;
  esac
done
# Coverage must be VISIBLE. "No traps" over zero functions is not evidence of anything, and
# this suite has been burned by a green result that tested nothing (mutation coverage passing
# 10/10 beside two live holes; 49 lli tests that could not run).
if [ "$CLAIMED_TOTAL" -gt 0 ]; then
  ok "soundness check covered $CLAIMED_TOTAL claimed/unclaimed function(s)"
else
  echo "  NOTE: 0 claimed/unclaimed fuzzable functions in examples/ — the soundness check is"
  echo "        VACUOUS here. Not a failure, and not evidence either. Coverage is limited by"
  echo "        the callability rules in \`artifactFuzzCases\` (public, integer-or-int-array"
  echo "        params, integer return, no capabilities, contract checkable over int params)."
  ok "coverage reported honestly rather than implied by a green run"
fi

echo "=== the plan states its own coverage ==="
P="$("$COMPILER" examples/trap_semantics_gap/src/main.con --report artifact-fuzz 2>/dev/null)"
printf '%s' "$P" | grep -qE "fuzzable functions: [0-9]+ of [0-9]+" \
  && ok "the report states how many functions were fuzzable out of the total" \
  || no "no coverage ratio printed — a clean run would not say how little was tried"
printf '%s' "$P" | grep -q "unproved  (NOT fuzzed" \
  && ok "the report distinguishes claimed / unclaimed / unproved" \
  || no "the report does not classify by claim — every trap would be ambiguous"

echo ""
echo "ARTIFACT-FUZZ: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
