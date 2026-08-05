#!/usr/bin/env bash
# Bug 066: a match guard's effects must be observable, and identical under the
# interpreter and the compiled binary.
#
# Return values agree even when the bug is present — only the EFFECTS diverge — so
# every leg compares interpreter output against compiled output, never exit codes.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
fatal() { local rc=$?; echo "FATAL: check_match_guard_effects stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2; exit "$rc"; }
trap fatal ERR
CC=".lake/build/bin/concrete"
[ -x "$CC" ] || { echo "error: build first" >&2; exit 2; }
PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Compare interpreter and compiled OUTPUT for one program.
differential() {
  local name="$1" label="$2"
  local i c
  # `|| true` on both: a grep that filters every line exits 1, and pipefail would
  # abort the gate on a program whose output is entirely numeric.
  i="$( { "$CC" "$T/$name.con" --interp 2>&1 | grep -v '^[0-9]*$' || true; } | tr '\n' ',')"
  if ! "$CC" "$T/$name.con" -o "$T/$name.bin" >/dev/null 2>&1; then
    no "$label — compile failed"; return
  fi
  c="$( { "$T/$name.bin" 2>&1 || true; } | tr '\n' ',')"
  if [ -z "$c" ]; then
    no "$label — compiled produced no output; inconclusive, not agreement"
  elif [ "$i" = "$c" ]; then
    ok "$label (both [$c])"
  else
    no "$label — interp=[$i] compiled=[$c]"
  fi
}

hdr='mod g {
    enum Copy E { A { v: Int }, B { v: Int } }
    fn t1() with(Console) -> Bool { print("T1\n"); return true; }
    fn f1() with(Console) -> Bool { print("F1\n"); return false; }
    fn f2() with(Console) -> Bool { print("F2\n"); return false; }
    pub fn main() with(Console) -> Int {'
ftr='    }
}'

# 1. A guard that runs and whose arm is taken.
cat > "$T/taken.con" <<EOF
$hdr
        let e: E = E::A { v: 7 };
        match e { E::A { v } if t1() => { print("took\n"); return 1; },
                  E::A { v } => { return 2; }, E::B { v } => { return 0; } }
$ftr
EOF
differential taken "a succeeding guard's effect is observable"

# 2. A FAILING guard whose effect must still run before falling through. This is the
#    case a naive fix (threading the env only on success) would still get wrong.
cat > "$T/fell.con" <<EOF
$hdr
        let e: E = E::A { v: 7 };
        match e { E::A { v } if f1() => { return 1; },
                  E::A { v } => { print("fallback\n"); return 2; },
                  E::B { v } => { return 0; } }
$ftr
EOF
differential fell "a FAILING guard's effect survives the fall-through"

# 3. Two failing guards, so the ORDER of accumulated effects is checked.
cat > "$T/two.con" <<EOF
$hdr
        let e: E = E::A { v: 7 };
        match e { E::A { v } if f1() => { return 1; },
                  E::A { v } if f2() => { return 2; },
                  E::A { v } => { print("fallback\n"); return 3; },
                  E::B { v } => { return 0; } }
$ftr
EOF
differential two "two failing guards accumulate their effects in order"

# 4. A guard on a NON-MATCHING pattern must not run at all. The unguarded A arm is
#    required for exhaustivity: a GUARDED arm does not satisfy it, since the guard may
#    fail — which is correct, and worth noting so the extra arm does not look stray. — guards are evaluated
#    only after their pattern matches.
cat > "$T/nomatch.con" <<EOF
$hdr
        let e: E = E::B { v: 7 };
        match e { E::A { v } if t1() => { return 1; },
                  E::A { v } => { return 3; },
                  E::B { v } => { print("tookB\n"); return 2; } }
$ftr
EOF
differential nomatch "a guard whose pattern does not match never runs"
if { "$CC" "$T/nomatch.con" --interp 2>&1 || true; } | grep -q "T1"; then
  no "a guard ran for a pattern that did not match"
else
  ok "no guard effect leaked from a non-matching pattern"
fi

echo "MATCH-GUARD-EFFECTS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
