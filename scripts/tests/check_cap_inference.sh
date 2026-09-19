#!/usr/bin/env bash
# BUG 063: "I DO NOT KNOW THIS TYPE" MUST NOT BE RECORDED AS "THIS CALLBACK NEEDS NO AUTHORITY".
#
# `peekExprType` is a cheap syntactic peek and answers `.placeholder` for what it does not
# handle. The cap-variable inference consumer mapped that onto `CapSet.empty`. Absence of
# information stored as a positive fact — and not a conservative approximation of the
# missing analysis, but the opposite one.
#
# The symptom was a wrong ACCUSATION rather than a wrong answer. A capability-polymorphic
# combinator accepted a callback written as a bare name and rejected every DERIVED form —
# struct field, call result, array element, parenthesised — with
#
#   E0220: type mismatch in argument 'f' of 'apply':
#          expected fn(i64) with() -> i64, got fn(i64) with(Console) -> i64
#
# `with()` is not something the program wrote. DECISIONS.md recommends a struct of
# function pointers as THE answer for pluggable interfaces, so the rejected form is the
# intended use.
#
# WHY IT WAS WORTH FIXING BEFORE IT BIT. With `C := {}` fabricated, `missingCaps` found
# nothing missing, so the AUTHORITY check passed; the program survived only because
# `expectTy` compares fn types for equality and happened to sit downstream. Relax that
# comparison to subsetting — the natural direction for passing a low-authority callback
# where a high-authority one is expected — and the only thing rejecting these programs
# disappears, turning a rejected-valid-program into an authority hole.
#
# THE ERROR CODE IS THE ASSERTION, not merely that something failed. E0242 means the
# capability leg refused. E0220 means the fallback is back and type equality is doing the
# work. A gate that only checked "does it fail" would pass either way, and would go on
# passing after the subset relaxation — testing `expectTy`, not capabilities.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
CC="$ROOT_DIR/.lake/build/bin/concrete"
FIX="$ROOT_DIR/tests/regressions/cap_inference"

if command -v timeout >/dev/null 2>&1; then TO="timeout 300"; else TO=""
  echo "  warn 'timeout' not found — running without a hang watchdog"; fi

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -x "$CC" ] || { echo "FATAL: compiler not built at $CC" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "=== every derived fn-pointer form reaches a cap-polymorphic parameter ==="
d="$FIX/derived_forms"
out="$(cd "$d" && $TO "$CC" check . 2>&1)"
if [ -z "$(printf '%s' "$out" | grep -E 'error\[')" ]; then
  ok "struct field, call result, array element, parenthesised and bare name all check"
else
  no "a derived fn-pointer form is still rejected"
  printf '%s\n' "$out" | grep -E 'error\[' | awk 'NR<=3' | sed 's/^/       /'
fi

# Behaviour, not just acceptance: each of the six calls must actually run. 2*5 + 2 = 12.
if (cd "$d" && $TO "$CC" build . -o "$TMP/derived" >/dev/null 2>&1); then
  "$TMP/derived" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 12 ]; then
    ok "all six calls dispatch correctly (exit 12)"
  else
    no "compiled but produced $rc, not 12 — a call is dispatching to the wrong target"
  fi
else
  no "derived_forms does not build"
fi

echo "=== a capability-FREE callback still works through the same combinator ==="
# The old fallback answered `empty` for everything, so it was accidentally right here.
# Fixing only the capability-carrying forms would break this one.
if printf '%s' "$out" | grep -qE 'error\['; then
  no "cannot assess: derived_forms does not check"
else
  ok "the empty-capset form is unaffected (it is the same fixture's last call)"
fi

echo "=== what remains unknowable SAYS SO, and says it in the right register ==="
u="$FIX/uninferable"
uout="$(cd "$u" && $TO "$CC" check . 2>&1)"
if printf '%s' "$uout" | grep -q "E0242"; then
  ok "a generic callee's return type yields E0242 cannotInferCapVariable"
else
  no "the uninferable case does not report E0242"
  printf '%s\n' "$uout" | grep -E 'error\[' | awk 'NR<=2' | sed 's/^/       /'
fi
if printf '%s' "$uout" | grep -q "capability variable 'C'"; then
  ok "the diagnostic NAMES the variable it could not infer"
else
  no "the diagnostic does not name the cap variable — it points somewhere unhelpful"
fi

echo "=== CONTROL: the refusal comes from the capability leg, not from type equality ==="
# This is the leg that would silently stop working if the fallback returned. E0220 here
# would mean a fabricated empty binding passed the authority check and `expectTy` caught
# the collision afterwards — the pre-fix behaviour, and the one that survives only until
# fn-type comparison is relaxed to subsetting.
if printf '%s' "$uout" | grep -q "E0220"; then
  no "E0220 is present: an empty binding was fabricated and type equality is doing the work"
else
  ok "no E0220 — nothing invented a capability set to compare against"
fi

echo
echo "CAP-INFERENCE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
