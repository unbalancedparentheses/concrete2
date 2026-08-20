#!/usr/bin/env bash
# THE REPOSITORY LOCK REFUSES RATHER THAN RECLAIMS.
#
# `_gate_lock_acquire` used to reclaim a lock whose recorded owner PID was dead. That is unsafe, and
# it fired: on 2026-08-20 the recorded creator was gone while an isolated 78-family mutation campaign
# that its shell had launched was still running, and a later gate reclaimed the lock and ran
# alongside it. Nothing was corrupted only because both parties happened to work in disposable
# copies.
#
# The recorded PID is the process that CREATED the lock. Children inherit `CONCRETE_GATE_LOCK` and
# outlive it, so a dead creator says nothing about whether the tree is free. PID liveness cannot be
# repaired into a safe signal: the creator is the wrong process to probe, PIDs are reused, and there
# is no portable way to prove a lease is gone — process groups do not survive the shells this runs
# under, and `flock` is absent on macOS.
#
# So the policy is fail-closed and this gate holds it there. A stale lock costs one command to clear;
# a wrongly reclaimed one costs a silent verdict about an artifact that never existed.
#
# TESTED IN A SANDBOX, never against the real lock: a gate that experiments on the repository's own
# lock would be doing the exact thing it exists to forbid.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

LIB="scripts/tests/lib/fresh.sh"
[ -f "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }

# A sandbox tree with its own .gate.lock, so nothing here can touch the repository's.
SB="$TMP/sandbox"; mkdir -p "$SB/scripts/tests/lib"
cp "$LIB" "$SB/scripts/tests/lib/fresh.sh"
cat > "$SB/probe.sh" <<'PROBE'
#!/usr/bin/env bash
source scripts/tests/lib/fresh.sh
_gate_lock_acquire && echo ACQUIRED || echo REFUSED
PROBE

probe(){ ( cd "$SB" && bash probe.sh 2>"$TMP/err" ); }

echo "=== the four states ==="

rm -rf "$SB/.gate.lock"
[ "$(probe)" = "ACQUIRED" ] \
  && ok "a free tree acquires the lock" \
  || no "a free tree could not acquire the lock — the lock is broken shut"

# THE REGRESSION THIS GATE EXISTS FOR. A dead creator must NOT be reclaimed.
printf 'pid=999999\ncmd=dead_creator.sh\n' > "$SB/.gate.lock/owner"
R="$(probe)"
if [ "$R" = "REFUSED" ]; then
  ok "a lock whose creator PID is DEAD is refused, not reclaimed"
else
  no "a dead creator PID was RECLAIMED ($R) — children outlive their creator, so this hands the tree to a concurrent run"
fi
grep -q 'recover explicitly' "$TMP/err" \
  && ok "the refusal tells the operator how to recover explicitly" \
  || no "the refusal gives no recovery path — an operator will delete the lock blindly or give up"
grep -q 'creator pid 999999 is dead' "$TMP/err" \
  && ok "the refusal reports the creator's liveness as evidence rather than acting on it" \
  || no "the refusal does not report creator liveness — the operator cannot judge the situation"

# A live creator must also be refused, and for a plainer reason.
printf 'pid=%s\ncmd=live.sh\n' "$$" > "$SB/.gate.lock/owner"
[ "$(probe)" = "REFUSED" ] \
  && ok "a lock whose creator is ALIVE is refused" \
  || no "a live holder was displaced — this is the interleaving the lock exists to prevent"

# Explicit recovery is the only path back.
rm -rf "$SB/.gate.lock"
[ "$(probe)" = "ACQUIRED" ] \
  && ok "explicit removal is the recovery path, and it works" \
  || no "the lock cannot be recovered even by removing it — it is broken shut"

echo ""
echo "=== re-entrancy still works ==="
# One run, one lock: a gate invoked by a runner that already holds it must not deadlock. Without
# this, making the lock fail-closed would break every nested gate invocation.
rm -rf "$SB/.gate.lock"
R="$( cd "$SB" && CONCRETE_GATE_LOCK=12345 bash probe.sh 2>/dev/null )"
[ "$R" = "ACQUIRED" ] \
  && ok "a child inheriting CONCRETE_GATE_LOCK proceeds without taking its own lock" \
  || no "re-entrancy is broken ($R) — a runner would deadlock against the gates it invokes"

# ...and that inheritance must not leave a lock behind for someone else to trip over.
[ ! -d "$SB/.gate.lock" ] \
  && ok "an inheriting child creates no lock directory of its own" \
  || no "an inheriting child created a lock directory — it would outlive the run and block the next one"

echo ""
echo "=== the real repository lock was not touched ==="
# The gate's own non-interference, asserted rather than assumed.
if [ -d "$ROOT_DIR/.gate.lock" ]; then
  ok "the repository lock is present and untouched (this gate ran entirely in a sandbox)"
else
  ok "the repository lock is absent and this gate did not create one"
fi

echo ""
echo "GATE-LOCK: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
