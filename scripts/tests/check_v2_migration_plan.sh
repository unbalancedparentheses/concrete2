#!/usr/bin/env bash
# THE V1 -> V2 SUBJECT-DIGEST MIGRATION, DRY RUN (R-0004 package 3).
#
# Every stored `#[proof_fingerprint]` in the corpus is a V1 value: a body-only fingerprint answering
# a weaker question than the V2 subject digest, which also binds the declaration's signature,
# contracts, capabilities and constant environment. Activating V2 makes every stored V1 value NOT
# COMPARABLE at once — correctly — so activation without migration would turn the corpus
# `needs_recheck` in a single commit.
#
# THIS GATE IS ABOUT THE DENOMINATOR. A migration plan that lists only what it would change is
# indistinguishable from one that silently skips things, so the population must RECONCILE:
#
#     stored fingerprints in code  =  plan rows  +  every exclusion, named
#
# WHAT CANNOT BE MIGRATED MATTERS MORE THAN WHAT CAN. A stale link is pinned to a body that no longer
# exists; recording the CURRENT digest for it would assert that a proof was established against a
# body it was never checked against — manufacturing freshness, which is the exact forgery this
# package exists to prevent.
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
BIN="$ROOT_DIR/.lake/build/bin/concrete"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIXTURES="$(grep -rlE '#\[proof_fingerprint' examples --include='*.con' | sort)"

echo "=== the population reconciles ==="

# COUNTED FROM CODE, NOT FROM PROSE. A first attempt counted every textual occurrence and read 52,
# because fixture COMMENTS discuss `#[proof_fingerprint]` — the fourth time this repo has confused
# prose for code in a measurement. Comment lines are excluded.
CODE=0; ROWS=0; UNREACHED=""
for f in $FIXTURES; do
  n=$( { grep -v '^\s*//' "$f" || true; } | { grep -o '#\[proof_fingerprint' || true; } | wc -l)
  r=$( { "$BIN" "$f" --report migration 2>/dev/null || true; } | { grep -cE '^  \[' || true; } )
  CODE=$((CODE + n)); ROWS=$((ROWS + r))
  [ "$n" != "$r" ] && UNREACHED="$UNREACHED $f($n/$r)"
done
echo "  stored in code: $CODE   plan rows: $ROWS"

if [ "$CODE" -gt 0 ] && [ "$ROWS" -gt 0 ]; then
  ok "the census is live ($CODE stored, $ROWS planned) — the reconciliation below is not vacuous"
else
  no "census found nothing (stored=$CODE rows=$ROWS); every assertion below would be vacuous"
fi

# EXACTLY ONE fingerprint is unreachable by any obligation, and it is the fixture whose entire
# purpose is an invalid attribute. Pinned by NAME: "one is excluded" would be satisfied by a
# different one going missing.
if [ "$CODE" = "44" ] && [ "$ROWS" = "43" ]; then
  ok "44 stored fingerprints = 43 plan rows + 1 unreachable"
else
  no "population moved: $CODE stored / $ROWS planned (expected 44 / 43)"
fi
if [ "$(tr -s ' ' '\n' <<<"$UNREACHED" | grep -c . || true)" = "1" ] \
   && grep -q 'contract_negatives/invalid_attribute' <<<"$UNREACHED"; then
  ok "the one unreachable fingerprint is contract_negatives/invalid_attribute, by name"
else
  no "the unreachable set changed — expected exactly contract_negatives/invalid_attribute, got:$UNREACHED"
fi

echo "=== every row has a disposition, and they reconcile ==="

DISP="$(for f in $FIXTURES; do
          { "$BIN" "$f" --report migration 2>/dev/null || true; } | { grep -oE '^  \[[a-z_]+\]' || true; }
        done | sort | uniq -c)"
cnt(){ { grep -oE "[0-9]+ +\\[$1\\]" <<<"$DISP" || true; } | { grep -oE '^[0-9]+' || true; } | head -1; }
MIG="$(cnt migrate)"; REF="$(cnt replay_refused)"; STALE="$(cnt stale_no_honest_value)"
MIG="${MIG:-0}"; REF="${REF:-0}"; STALE="${STALE:-0}"
echo "  migrate=$MIG replay_refused=$REF stale_no_honest_value=$STALE"

if [ "$(( MIG + REF + STALE ))" = "$ROWS" ]; then
  ok "every plan row carries exactly one disposition ($MIG + $REF + $STALE = $ROWS)"
else
  no "dispositions do not sum to the plan: $MIG + $REF + $STALE != $ROWS"
fi
if [ "$MIG" = "33" ] && [ "$REF" = "6" ] && [ "$STALE" = "4" ]; then
  ok "the plan is exactly 33 migrate / 6 replay-refused / 4 stale-with-no-honest-value"
else
  no "the plan moved: $MIG migrate / $REF refused / $STALE stale — say which links changed and why"
fi

echo "=== a stale link is never given a manufactured value ==="

# THE LOAD-BEARING REFUSAL. `elf_header_drifted` is a different program sharing every declaration
# name with `elf_header`; two of its functions drifted from what their proofs were pinned to.
# Recording the current V2 digest for those would assert a proof that was never established against
# the present body.
DRIFT="$("$BIN" examples/elf_header_drifted/src/main.con --report migration 2>/dev/null || true)"
if [ "$( { grep -c '\[stale_no_honest_value\]' <<<"$DRIFT" || true; } )" = "2" ]; then
  ok "both drifted claims refuse a v2 value, naming that no honest one exists"
else
  no "the drift fixture no longer refuses two stale links: $(grep -c 'stale_no_honest_value' <<<"$DRIFT" || true)"
fi
# ...and the refusal is TARGETED: the same fixture's undrifted claims still migrate. A plan that
# refused the whole file would satisfy the leg above while migrating nothing.
if [ "$( { grep -c '\[migrate\]' <<<"$DRIFT" || true; } )" -ge 1 ]; then
  ok "the same fixture's undrifted claims still migrate — the refusal is per-claim"
else
  no "nothing in the drift fixture migrates; the stale refusal is blanket, not targeted"
fi
# No migrated row may carry a v1 value as its target, and every one must be a v2 value.
BADTARGET="$(for f in $FIXTURES; do
               { "$BIN" "$f" --report migration 2>/dev/null || true; } | { grep '\[migrate\]' || true; }
             done | { grep -vc -- '-> v2:' || true; })"
if [ "$BADTARGET" = "0" ]; then
  ok "every migrated row targets a v2-prefixed digest"
else
  no "$BADTARGET migrated row(s) do not target a v2 value"
fi

echo "=== the dry run writes nothing ==="

# A plan that mutated the corpus while reporting would be indistinguishable from an applied
# migration, and there is no undo for that.
BEFORE="$(git status --porcelain -- examples | sort)"
for f in $FIXTURES; do "$BIN" "$f" --report migration >/dev/null 2>&1 || true; done
AFTER="$(git status --porcelain -- examples | sort)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "running the plan leaves every fixture untouched"
else
  no "the dry run MODIFIED the corpus — it is not a dry run"
  diff <(printf '%s' "$BEFORE") <(printf '%s' "$AFTER") | head -5 | sed 's/^/      /'
fi

GATE_DONE=1
echo "V2-MIGRATION-PLAN: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
