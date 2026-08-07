#!/usr/bin/env bash
# Vacuity ratchet: a gate that guards against gates which cannot fail.
#
# `all(P(x) for x in xs)` is TRUE when `xs` is empty. So is "the forbidden string does not appear
# in this output" when there is no output. Both read as a pass, and neither has checked anything.
# The general hazard:
#
#     every universal property holds over the empty collection
#
# This is not theoretical here. Promoting an impure-call defect from a report line to a check
# error made a positive control in check_contract_negatives.sh pass BECAUSE the fixture was
# rejected wholesale: its report was empty, so "no `impure call` in the cn.good block" was true
# for want of a cn.good block. The gate was green and proved nothing. See H27.
#
# WHAT THIS DOES, and what it deliberately does not. It counts two greppable shapes and fails if
# the count RISES above a recorded baseline. It does not attempt to prove any individual
# assertion vacuous — that needs the runtime collection, not the source text. A ratchet stops the
# population growing while the existing ones are fixed; calling it a proof of non-vacuity would
# be the same overclaiming this file exists to catch.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# --- shape 1: universal JSON assertions with no non-emptiness witness --------------------------
# `all(... for x in coll)` passes over an empty coll. A guard is anything that forces the
# collection to be inhabited: a len() check, an index, or an explicit conjunct.
BASELINE_UNIVERSAL=23
# Excludes THIS file. The first run counted 24 against a baseline of 23 because the examples in
# these comments and in the self-test heredoc match the pattern — the instrument counted itself.
# Worth leaving as a note: a scanner that includes its own source reports its own documentation
# as findings, and the drift looks exactly like a real regression.
count_universal(){ local tot=0
  for f in scripts/tests/check_*.sh; do
    [ "$(basename "$f")" = "check_gate_vacuity.sh" ] && continue
    while IFS= read -r line; do
      printf '%s' "$line" | grep -qE "len\(|\[0\]|\breturn\b" || tot=$((tot+1))
    done < <(grep -hoE "\"[^\"]*all\([^\"]*for [a-z]+ in [^\"]*\"" "$f")
  done
  echo "$tot"; }

U="$(count_universal)"
echo "=== universal assertions without a non-emptiness witness ==="
echo "  count: $U   baseline: $BASELINE_UNIVERSAL"
if [ "$U" -le "$BASELINE_UNIVERSAL" ]; then
  ok "no new unguarded universal assertions (<= baseline)"
  [ "$U" -lt "$BASELINE_UNIVERSAL" ] && echo "  NOTE: count DROPPED to $U — lower BASELINE_UNIVERSAL to $U to keep the ratchet tight."
else
  no "unguarded universal assertions rose $BASELINE_UNIVERSAL -> $U; add a len(...)>0 conjunct to the new one"
fi

# --- shape 2: absence helpers that accept empty input -------------------------------------------
# An `assert_absent`-style helper must treat "no output" as a failure. Every definition of one
# has to contain an emptiness check; this finds definitions that do not.
echo "=== absence helpers that treat empty output as success ==="
badhelpers=""
for f in $(grep -lE "^[a-z_]*absent[a-z_]*\(\)" scripts/tests/check_*.sh); do
  [ "$(basename "$f")" = "check_gate_vacuity.sh" ] && continue
  # the helper body is the line plus the following few; look for an emptiness guard nearby
  if ! grep -A6 -E "^[a-z_]*absent[a-z_]*\(\)" "$f" | grep -qE '\-z "\$|VACUOUS|isEmpty'; then
    badhelpers="$badhelpers $(basename "$f")"
  fi
done
if [ -z "$badhelpers" ]; then
  ok "every absence helper rejects empty input"
else
  no "absence helper(s) accept empty input:$badhelpers"
fi

# --- shape 3: this gate must itself be able to fail ---------------------------------------------
# A ratchet whose counter is broken silently reports success forever, which is the very defect
# being ratcheted. Prove the counter responds to a known-bad input.
echo "=== the ratchet can fail ==="
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
cat > "$TMPD/check_probe.sh" <<'EOF'
assert_json "probe" "all(x['k'] for x in d['items'])" foo
EOF
probe="$(grep -hoE "\"[^\"]*all\([^\"]*for [a-z]+ in [^\"]*\"" "$TMPD/check_probe.sh" | wc -l)"
if [ "$probe" -eq 1 ]; then
  ok "the counter detects an unguarded universal assertion in a synthetic file"
else
  no "the counter did not detect a known-bad assertion — the ratchet is broken"
fi

echo ""
echo "GATE-VACUITY: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
