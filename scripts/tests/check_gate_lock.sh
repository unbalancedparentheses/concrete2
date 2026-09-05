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
# CHECKED. Unchecked under a shell without errexit, a failed `mktemp -d` left TMP empty, making
# SB="/sandbox" — after which this gate wrote /sandbox/probe.sh and repeatedly deleted
# /sandbox/.gate.lock. A temp-directory failure must not reach into a root-level directory.
TMP="$(mktemp -d)" || { echo "FATAL: could not create a sandbox directory" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: sandbox directory is not usable" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Captured BEFORE any probe, so the non-interference check at the end has something to compare to.
REAL_LOCK_START="absent"
[ -d "$ROOT_DIR/.gate.lock" ] && REAL_LOCK_START="present:$(cat "$ROOT_DIR/.gate.lock/owner" 2>/dev/null | tr '\n' ' ')"

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

# THE ENVIRONMENT IS CONTROLLED, NOT INHERITED. This gate asserts what an UNHELD lock does, so it
# must not inherit a live `CONCRETE_GATE_LOCK` from a parent. Run under `run_ci_gates_local.sh` —
# which now holds the lock for the whole pass and exports a token this gate's children legitimately
# satisfy by ancestry — every "must be REFUSED" case returned ACQUIRED and the gate failed. Measured
# 2026-08-21. Each probe below sets the token it means to test, and this default clears it.
probe(){ ( cd "$SB" && env -u CONCRETE_GATE_LOCK bash probe.sh 2>"$TMP/err" ); }

echo "=== the four states ==="

rm -rf "$SB/.gate.lock"
[ "$(probe)" = "ACQUIRED" ] \
  && ok "a free tree acquires the lock" \
  || no "a free tree could not acquire the lock — the lock is broken shut"

# THE REGRESSION THIS GATE EXISTS FOR. A dead creator must NOT be reclaimed.
# THE HELD STATE IS CONSTRUCTED, NOT INHERITED FROM THE PROBE ABOVE.
#
# These controls used to write an owner file into the lock directory the PREVIOUS probe had left
# behind — which only existed because a gate that acquired the lock LEAKED it. When that leak was
# fixed (it was the cause of FAST-SURFACE-GATES 8/3 and weeks of red CI) the directory was gone, the
# owner write went nowhere, and these controls silently began testing a FREE tree: the dead-creator
# control then reported the lock had been "RECLAIMED" when nothing had been held at all.
# A control whose precondition is another control's bug fails the moment the bug is fixed.
mkdir -p "$SB/.gate.lock"
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
mkdir -p "$SB/.gate.lock"
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
# THE POSITIVE CONTROL: a token that names a REAL lock held by a LIVE process must proceed. This is
# the case that must keep working, and it is measured with a genuine lock rather than an arbitrary
# value, because this test previously passed `CONCRETE_GATE_LOCK=12345` and asserted that proceeding
# was correct — enshrining a fail-OPEN path as the specification. Any nonempty value bypassed the
# lock entirely, so `CONCRETE_GATE_LOCK=1 bash check_foo.sh` ran holding nothing while every message
# implied otherwise.
mkdir -p "$SB/.gate.lock"
printf 'pid=%s\ncmd=holder.sh\n' "$$" > "$SB/.gate.lock/owner"
R="$( cd "$SB" && CONCRETE_GATE_LOCK="$$:$SB/.gate.lock" bash probe.sh 2>/dev/null )"
[ "$R" = "ACQUIRED" ] \
  && ok "a child inheriting a token that names a live, real lock proceeds without taking its own" \
  || no "re-entrancy is broken ($R) — a runner would deadlock against the gates it invokes"

# ...and that inheritance must not create a SECOND lock directory of its own.
[ -d "$SB/.gate.lock" ] && [ "$(sed -n 's/^cmd=//p' "$SB/.gate.lock/owner")" = "holder.sh" ] \
  && ok "an inheriting child creates no lock of its own and does not overwrite the holder's" \
  || no "an inheriting child disturbed the holder's lock"

echo ""
echo "=== a token that does NOT name a live lock is refused (fail-closed) ==="
# Three ways a token can be a lie, each refused separately: no such directory, a directory whose
# recorded owner disagrees with the token, and an owner that is dead.
rm -rf "$SB/.gate.lock"
R="$( cd "$SB" && CONCRETE_GATE_LOCK="12345" bash probe.sh 2>/dev/null )"
[ "$R" = "REFUSED" ] \
  && ok "a bare value naming no lock directory is refused" \
  || no "a forged token '12345' was accepted ($R) — the gate would run holding nothing"

R="$( cd "$SB" && CONCRETE_GATE_LOCK="$$:$SB/.gate.lock" bash probe.sh 2>/dev/null )"
[ "$R" = "REFUSED" ] \
  && ok "a token naming a lock directory that does not exist is refused" \
  || no "a token pointing at a missing lock was accepted ($R)"

mkdir -p "$SB/.gate.lock"; printf 'pid=999999\ncmd=other.sh\n' > "$SB/.gate.lock/owner"
R="$( cd "$SB" && CONCRETE_GATE_LOCK="$$:$SB/.gate.lock" bash probe.sh 2>/dev/null )"
[ "$R" = "REFUSED" ] \
  && ok "a token whose pid disagrees with the lock's recorded owner is refused" \
  || no "a token was accepted against a lock owned by someone else ($R)"

printf 'pid=999999\ncmd=dead.sh\n' > "$SB/.gate.lock/owner"
R="$( cd "$SB" && CONCRETE_GATE_LOCK="999999:$SB/.gate.lock" bash probe.sh 2>/dev/null )"
[ "$R" = "REFUSED" ] \
  && ok "a token whose owner pid is dead is refused" \
  || no "a stale token from a dead run was accepted ($R)"

# THE CASE THAT SEPARATES "names a lock" FROM "holds a lock". Everything a token asserts can be
# fabricated — make a directory, write a live pid into `owner` — so the property that makes
# re-entrancy legitimate is that the holder is an ANCESTOR of this process. Here the owner is alive
# and the directory is real, and it must STILL be refused, because that process is a sibling.
if [ -r /proc/self/stat ]; then
  ( exec sleep 60 ) & SIBLING=$!
  printf 'pid=%s\ncmd=sibling.sh\n' "$SIBLING" > "$SB/.gate.lock/owner"
  R="$( cd "$SB" && CONCRETE_GATE_LOCK="$SIBLING:$SB/.gate.lock" bash probe.sh 2>/dev/null )"
  [ "$R" = "REFUSED" ] \
    && ok "a token naming a LIVE process that is not an ancestor is refused" \
    || no "a fabricated token naming an unrelated live process was accepted ($R) — any caller could forge one"
  kill "$SIBLING" 2>/dev/null; wait "$SIBLING" 2>/dev/null || true
else
  # NOT counted as a pass. Reporting a skip through `ok` produced the same 15/0 total whether or not
  # the ancestry property was ever tested, which is exactly a vacuous control.
  echo "  SKIP ancestry check: no /proc on this platform; the weaker token checks apply there"
fi
rm -rf "$SB/.gate.lock"

echo ""
echo "=== release is creator-only ==="
# A release by a non-creator would hand the tree to a concurrent run — the same failure as reclaiming
# on a dead PID, which this library refuses to do.
mkdir -p "$SB/.gate.lock"; printf 'pid=999999\ncmd=other.sh\n' > "$SB/.gate.lock/owner"
( cd "$SB" && CONCRETE_GATE_LOCK="999999:$SB/.gate.lock" bash -c '. "'"$ROOT_DIR"'/scripts/tests/lib/fresh.sh"; _gate_lock_release' ) >/dev/null 2>&1
[ -d "$SB/.gate.lock" ] \
  && ok "a non-creator cannot release another run's lock" \
  || no "a non-creator released the lock — a concurrent run would be handed the tree"
rm -rf "$SB/.gate.lock"

# THE PAIRED POSITIVE CONTROL. Without it this section only ever asserted that release does NOT
# happen, so replacing `_gate_lock_release` with a no-op would leave this gate fully green — a
# refusal-only control that cannot distinguish "correctly declined" from "does nothing at all".
# The creator acquires and releases in one process, and the lock must be GONE afterwards.
( cd "$SB" && env -u CONCRETE_GATE_LOCK bash -c '. scripts/tests/lib/fresh.sh; _gate_lock_acquire && _gate_lock_release' ) >/dev/null 2>&1
[ ! -d "$SB/.gate.lock" ] \
  && ok "a creator DOES release its own lock (the control that makes the refusal meaningful)" \
  || no "the creator did not release its lock — every run would wedge the repository for the next one"
rm -rf "$SB/.gate.lock"

echo ""
echo "=== the lock's LIFETIME is the run's lifetime ==="
# THE REGRESSION THIS SECTION EXISTS FOR. Release used to be entirely explicit, on the stated theory
# that "gates set their own trap". MEASURED: 137 of the 167 gates that take this lock install no EXIT
# trap at all, and 29 more install one AFTER acquiring — which would silently replace a release armed
# at acquisition. So the first gate in a run that actually rebuilt kept the lock forever, every later
# lock-taking gate refused, and aggregators counted each refusal as a FAILURE: FAST-SURFACE-GATES 8/3
# and weeks of red CI, produced entirely by the leak.
#
# Every probe below runs in the sandbox tree, never against the repository's own lock.
mkdir -p "$SB"
_mkprobe() { printf '%s\n' "$2" > "$SB/$1"; }
_held()   { [ -d "$SB/.gate.lock" ]; }
_clear()  { rm -rf "$SB/.gate.lock"; }
_run()    { ( cd "$SB" && env -u CONCRETE_GATE_LOCK bash "$1" >"$TMP/out" 2>"$TMP/err" ); }

_mkprobe ok.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
exit 0'
_clear; _run ok.sh; rc=$?
{ [ "$rc" = "0" ] && ! _held; } \
  && ok "a gate that acquires and SUCCEEDS leaves no lock" \
  || no "lock survived a successful gate (rc=$rc held=$(_held && echo yes || echo no))"

_mkprobe bad.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
exit 3'
_clear; _run bad.sh; rc=$?
{ [ "$rc" = "3" ] && ! _held; } \
  && ok "a gate that acquires and FAILS leaves no lock, and keeps its exit code" \
  || no "lock survived a failing gate, or its exit code changed (rc=$rc)"

# TWO SEQUENTIAL LOCK-TAKING GATES. This is the aggregate failure in miniature: under the leak the
# second could never acquire.
_clear; _run ok.sh; a=$?; _run ok.sh; b=$?
{ [ "$a" = "0" ] && [ "$b" = "0" ] && ! _held; } \
  && ok "two lock-taking gates run in sequence and BOTH acquire" \
  || no "the second sequential gate could not acquire (first=$a second=$b)"

# A GATE'S OWN CLEANUP IS PRESERVED, whether it is installed before or after the acquisition.
_mkprobe trap_before.sh 'source scripts/tests/lib/fresh.sh
trap "echo CLEANUP > cleanup.marker" EXIT
_gate_lock_acquire || exit 9
exit 0'
_clear; rm -f "$SB/cleanup.marker"; _run trap_before.sh
{ [ -f "$SB/cleanup.marker" ] && ! _held; } \
  && ok "a cleanup trap installed BEFORE the acquisition still runs, and the lock is released" \
  || no "trap-before-acquire: cleanup=$([ -f "$SB/cleanup.marker" ] && echo ran || echo lost) lock=$(_held && echo held || echo free)"

# THE 29-GATE CASE, and the one a release armed at acquisition would have silently lost.
_mkprobe trap_after.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
trap "echo CLEANUP > cleanup.marker" EXIT
exit 0'
_clear; rm -f "$SB/cleanup.marker"; _run trap_after.sh
{ [ -f "$SB/cleanup.marker" ] && ! _held; } \
  && ok "a cleanup trap installed AFTER the acquisition runs AND does not clobber the release" \
  || no "trap-after-acquire: cleanup=$([ -f "$SB/cleanup.marker" ] && echo ran || echo lost) lock=$(_held && echo HELD || echo free)"

# A RESET DROPS THE GATE'S CLEANUP, NOT THE REPOSITORY LOCK.
_mkprobe trap_reset.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
trap "echo CLEANUP > cleanup.marker" EXIT
trap - EXIT
exit 0'
_clear; rm -f "$SB/cleanup.marker"; _run trap_reset.sh
{ [ ! -f "$SB/cleanup.marker" ] && ! _held; } \
  && ok "'trap - EXIT' drops the gate's own cleanup but still releases the lock" \
  || no "trap reset: cleanup=$([ -f "$SB/cleanup.marker" ] && echo ran || echo dropped) lock=$(_held && echo HELD || echo free)"

# TERMINATING SIGNALS. SIGKILL is excluded on purpose and asserted below.
# `sleep 60 & wait` RATHER THAN `sleep 60`. Bash defers a trapped signal until the current
# FOREGROUND command finishes, so a plain `sleep 60` would swallow SIGTERM for a full minute and the
# control would time out instead of observing the release. Waiting on a background child lets the
# trap run at once.
_mkprobe hold.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
echo ready > ready.marker
sleep 60 &
wait $!'
for sig in TERM INT HUP; do
  _clear; rm -f "$SB/ready.marker"
  # `exec` so $! is the gate process itself. Without it the pid is the wrapping subshell, and a
  # signal sent there never reaches the shell that holds the lock — SIGTERM and SIGHUP appeared not
  # to release while SIGINT did, purely because INT reached the group and the others did not.
  ( cd "$SB" && exec env -u CONCRETE_GATE_LOCK bash hold.sh >/dev/null 2>&1 ) & pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -f "$SB/ready.marker" ] && break; sleep 0.2; done
  if [ ! -f "$SB/ready.marker" ]; then
    no "SIG$sig: the probe never acquired, so this control proves nothing"
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  else
    kill -"$sig" "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    _held && no "SIG$sig did not release the lock" || ok "SIG$sig releases the lock"
  fi
done

# THE STATED LIMIT, ASSERTED so that a change to it is noticed rather than assumed.
_clear; rm -f "$SB/ready.marker"
# `exec` so $! is the gate process itself. Without it the pid is the wrapping subshell, and a
  # signal sent there never reaches the shell that holds the lock — SIGTERM and SIGHUP appeared not
  # to release while SIGINT did, purely because INT reached the group and the others did not.
  ( cd "$SB" && exec env -u CONCRETE_GATE_LOCK bash hold.sh >/dev/null 2>&1 ) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -f "$SB/ready.marker" ] && break; sleep 0.2; done
if [ -f "$SB/ready.marker" ]; then
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  _held \
    && ok "SIGKILL leaves the lock — untrappable by anyone, so recovery stays an operator action" \
    || no "SIGKILL released the lock, which no trap can do: the lifetime mechanism is not what it claims"
else
  no "the SIGKILL limit control never acquired, so it proves nothing"
fi
_clear

# RE-ENTRANCY: a child must not release the lock its parent is still working under.
_mkprobe child.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
exit 0'
_mkprobe parent.sh 'source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
bash child.sh || exit 8
[ -d .gate.lock ] && echo PARENT_STILL_HOLDS > parent.marker || echo PARENT_LOST_LOCK > parent.marker
exit 0'
_clear; rm -f "$SB/parent.marker"; _run parent.sh
m="$(cat "$SB/parent.marker" 2>/dev/null)"
[ "$m" = "PARENT_STILL_HOLDS" ] \
  && ok "a re-entrant child does NOT release its parent's lock" \
  || no "the child released the parent's lock (marker=${m:-none}) — that hands the tree to a concurrent run"
! _held \
  && ok "...and the parent's own exit does release it" \
  || no "the parent kept the lock after exiting"
_clear

# POSITIVE CONTROL FOR THE WHOLE SECTION: the lock must still EXCLUDE. If releasing on exit had
# quietly turned the lock into a no-op, every control above would pass and the mechanism would be
# gone. A live, non-ancestor holder must still refuse an independent run.
_clear; rm -f "$SB/ready.marker"
# `exec` so $! is the gate process itself. Without it the pid is the wrapping subshell, and a
  # signal sent there never reaches the shell that holds the lock — SIGTERM and SIGHUP appeared not
  # to release while SIGINT did, purely because INT reached the group and the others did not.
  ( cd "$SB" && exec env -u CONCRETE_GATE_LOCK bash hold.sh >/dev/null 2>&1 ) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -f "$SB/ready.marker" ] && break; sleep 0.2; done
if [ -f "$SB/ready.marker" ]; then
  _run ok.sh; rc=$?
  [ "$rc" != "0" ] \
    && ok "CONTROL: an independent run is still REFUSED while a live holder has the lock" \
    || no "an independent run acquired while another process held the lock — the lock excludes nothing"
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
else
  no "the exclusion control never acquired, so it proves nothing"
fi
_clear

# THE DELIBERATE-HOLD OPT-OUT, EXERCISED IN BOTH DIRECTIONS.
#
# The mutation supervisor decides release by its own rule: a campaign group that is not proven empty
# must KEEP the lock. An unconditional release composed into its EXIT trap would reverse that — and
# did, until `_GATE_LOCK_SELF_MANAGED` was added. Both directions are asserted here, because an
# opt-out nobody tests is an opt-out that silently becomes universal.
_mkprobe selfmanaged.sh '_GATE_LOCK_SELF_MANAGED=1
source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
trap "echo OWN_CLEANUP > cleanup.marker" EXIT
exit 0'
_clear; rm -f "$SB/cleanup.marker"; _run selfmanaged.sh
{ [ -f "$SB/cleanup.marker" ] && _held; } \
  && ok "a self-managed holder keeps its lock on exit, and its own cleanup still runs" \
  || no "self-managed: cleanup=$([ -f "$SB/cleanup.marker" ] && echo ran || echo lost) lock=$(_held && echo held || echo RELEASED-against-its-decision)"
# ...and it can still release explicitly, which is how the supervisor releases when it decides to.
_mkprobe selfmanaged_rel.sh '_GATE_LOCK_SELF_MANAGED=1
source scripts/tests/lib/fresh.sh
_gate_lock_acquire || exit 9
_gate_lock_release
exit 0'
_clear; _run selfmanaged_rel.sh
! _held \
  && ok "...and an explicit release by a self-managed holder still works" \
  || no "a self-managed holder could not release explicitly"
# The opt-out must not leak into ordinary gates: the default is still automatic release.
_clear; _run ok.sh
! _held \
  && ok "CONTROL: without the opt-out, the default is still automatic release" \
  || no "the opt-out leaked into ordinary gates — every gate would strand its lock again"
_clear

# NO NEW PLATFORM AUTHORITY. The release path must not depend on flock or /proc; macOS has neither
# flock nor /proc, and this repository has already taken an outage from a /proc dependency.
# USE, NOT MENTION. The library's header explains WHY it cannot use flock ("flock is absent on
# macOS"), so grepping for the word failed on the sentence documenting the constraint — the same
# mention-versus-invocation error just fixed in the CI-reachability gate.
if sed -E 's/(^|[[:space:]])#.*$/\1/' "$LIB" | grep -qE '(^|[^[:alnum:]_])flock([[:space:]]|$)'; then
  no "the lock library CALLS flock, which macOS does not have"
else
  ok "the lock library requires no flock (checked against code, not comments)"
fi
awk '/^_gate_lock_release\(\)/,/^}/' "$LIB" | grep -q '/proc' \
  && no "the RELEASE path reads /proc — it would behave differently on macOS" \
  || ok "the release path requires no /proc"

echo "=== the real repository lock was not touched ==="
# COMPARED AGAINST A SNAPSHOT TAKEN BEFORE ANY PROBE RAN. Both branches of this used to call `ok`, so
# the assertion could not fail — it would have reported success even if this gate had deleted or
# replaced the repository's own lock, which matters because the release probe deliberately sources the
# real library. An assertion with no failing branch is decoration.
REAL_LOCK_END="absent"
[ -d "$ROOT_DIR/.gate.lock" ] && REAL_LOCK_END="present:$(cat "$ROOT_DIR/.gate.lock/owner" 2>/dev/null | tr '\n' ' ')"
if [ "$REAL_LOCK_END" = "$REAL_LOCK_START" ]; then
  ok "the repository lock is exactly as this gate found it ($REAL_LOCK_END)"
else
  no "this gate CHANGED the repository lock: was [$REAL_LOCK_START], now [$REAL_LOCK_END]"
fi

echo ""
echo "GATE-LOCK: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
