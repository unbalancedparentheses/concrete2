#!/usr/bin/env bash
# Stale-compiler-artifact guard.
#
# Every gate that runs the compiler tests whatever binary happens to be on disk. When that binary
# predates the checked-out source, the gate still runs, still prints assertions, and still reports
# PASS/FAIL -- about a compiler that no longer exists. That is worse than an ordinary failure: a
# failure says "something is wrong", while a stale run produces plausible evidence for the wrong
# artifact.
#
# This happened four times in one session: `git checkout <branch>` without `lake build`, then
# reading the previous branch's behaviour as the current branch's. Once a shipped feature looked
# unimplemented; once three "parse errors" were about to be written up as a finding. Neither was
# real.
#
# `make` already protects the normal path -- the test targets depend on `build`. This protects the
# path used while iterating: `bash scripts/tests/check_foo.sh` run directly.
#
# MECHANISM: build, don't guess. An earlier version of this file compared mtimes, and measurement
# killed it: `lake build` completes successfully WITHOUT relinking the binary when the compiled
# output is unchanged, so a source file touched at 23:01 sits "newer" than a 22:53 binary that is
# in fact current. The guard fired permanently, and its own advice ("run lake build") could not
# clear it. A content fingerprint has the same shape of problem -- it needs a build-side hook to
# record what the binary was built FROM, which does not exist today.
#
# Delegating to lake sidesteps both: lake already knows whether the binary corresponds to the
# source, and a no-op build costs ~130ms (measured), which is affordable at the top of a gate.

_FRESH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# ---------------------------------------------------------------------------
# EXCLUSIVE REPOSITORY LOCK.
#
# Gates share one `.lake` tree, one compiler binary, and one working tree. Two running at once is
# not slow, it is WRONG: `require_fresh_binary` rebuilds, so a second gate can read a half-relinked
# binary or a half-written olean and produce a confident verdict about an artifact that never
# existed. This has happened repeatedly in this repository — a 24-failure run that was pure build
# interleaving, a review whose gate aborted mid-measurement, and a "reconnaissance only" full-gate
# run — and every time the response was an intention to be more careful. Intentions have now failed
# often enough to be treated as a defect in the harness rather than in the operator.
#
# MECHANISM: `mkdir`, not `flock`. `mkdir` is atomic on every POSIX filesystem and exists
# everywhere; `flock` is util-linux and absent from stock macOS, which is an active CI platform —
# the exact portability trap that made receipt issuance refuse there. A lock that cannot be taken on
# one supported platform is not a lock, it is a platform-specific outage.
#
# NO EXIT TRAP, deliberately. Gates set their own `trap ... EXIT`/`ERR`, and installing one here
# would silently clobber theirs — replacing a concurrency bug with a reporting bug. Instead the lock
# records its owner's PID and a later run RECLAIMS it when that PID is gone, so a killed run heals
# the lock instead of wedging the repository.
#
# RE-ENTRANT within one run: a runner that holds the lock exports `CONCRETE_GATE_LOCK`, and the
# gates it invokes inherit it rather than deadlocking against their own parent.
_GATE_LOCK_DIR="$_FRESH_ROOT/.gate.lock"

_gate_lock_acquire() {
  # Already held by an ancestor of this process: one run, one lock.
  if [ -n "${CONCRETE_GATE_LOCK:-}" ]; then return 0; fi

  local owner_pid owner_desc
  if mkdir "$_GATE_LOCK_DIR" 2>/dev/null; then
    printf 'pid=%s\ncmd=%s\n' "$$" "${0##*/}" > "$_GATE_LOCK_DIR/owner" 2>/dev/null || true
    export CONCRETE_GATE_LOCK="$$"
    return 0
  fi

  # HELD. NO AUTOMATIC RECLAIM — and this used to reclaim on a dead owner PID, which is a defect,
  # not a convenience.
  #
  # The recorded PID is the process that CREATED the lock. Re-entrant children inherit
  # `CONCRETE_GATE_LOCK` and keep working after that creator exits, so a dead creator does NOT mean
  # the tree is free. Observed 2026-08-20: owner pid was dead while an isolated 78-family mutation
  # campaign, launched by that creator's shell, was still running — and a later gate DID reclaim the
  # lock on that basis and ran alongside it. Nothing was corrupted only because both parties happened
  # to work in disposable copies. The mechanism defeats the lock's entire purpose.
  #
  # PID liveness cannot be repaired into a safe signal here. The creator is the wrong process to
  # probe, PIDs are reused, and there is no portable way to prove a whole lease is gone — process
  # groups do not survive the shells this runs under, and `flock` is absent on macOS.
  #
  # So the policy is fail-closed: refuse, and require an explicit human recovery step. A stale lock
  # costs one command to clear; a wrongly reclaimed one costs a verdict about an artifact that never
  # existed, and costs it silently.
  owner_pid="$(sed -n 's/^pid=//p' "$_GATE_LOCK_DIR/owner" 2>/dev/null || true)"
  owner_desc="$(tr '\n' ' ' < "$_GATE_LOCK_DIR/owner" 2>/dev/null || true)"
  local liveness="unknown"
  if [ -n "$owner_pid" ]; then
    if kill -0 "$owner_pid" 2>/dev/null; then liveness="ALIVE"; else liveness="dead"; fi
  fi
  # Whether other gate work is running is reported as EVIDENCE for the operator's decision, never
  # used to reclaim automatically. A dead creator with live gates is the exact trap above.
  local live_gates
  live_gates="$(ps -eo cmd 2>/dev/null | grep -cE '(scripts/tests/(check|run)_|scripts/ci/)[a-z0-9_]*\.sh' || true)"

  echo "REPOSITORY BUSY — refusing to run this gate." >&2
  echo "  Lock holder: ${owner_desc:-unknown owner} (creator pid ${owner_pid:-?} is $liveness)" >&2
  echo "  Gate-like processes currently running: ${live_gates:-0}" >&2
  echo "" >&2
  echo "  Gates share one .lake tree and one binary. Running alongside a rebuild yields a verdict" >&2
  echo "  about an artifact that never existed, which is worse than no verdict at all." >&2
  if [ "$liveness" = "dead" ]; then
    echo "" >&2
    echo "  The recorded creator is gone, but that does NOT mean the tree is free: children that" >&2
    echo "  inherited this lock outlive their creator, and reclaiming on a dead PID has already" >&2
    echo "  handed the tree to a concurrent run once. Verify nothing is working the tree, then" >&2
    echo "  recover explicitly:" >&2
    echo "      rm -rf $_GATE_LOCK_DIR" >&2
  else
    echo "  Wait for it to finish." >&2
  fi
  return 1
}

require_fresh_binary() {
  local bin="${1:-$_FRESH_ROOT/.lake/build/bin/concrete}"

  # THE LOCK COMES FIRST, before the rebuild below. Acquiring it after `lake build` would leave the
  # exact window this exists to close: two gates rebuilding the same tree at once.
  _gate_lock_acquire || return 1

  if command -v lake >/dev/null 2>&1; then
    local out
    if ! out="$(cd "$_FRESH_ROOT" && lake build 2>&1)"; then
      echo "COMPILER BUILD FAILED — refusing to run this gate against a stale binary." >&2
      echo "$out" | grep -E '^error' | head -20 >&2
      return 1
    fi
  else
    # No lake on PATH. Say so rather than passing silently: an unverifiable guard that prints
    # nothing is indistinguishable from a guard that checked and approved.
    echo "WARNING: 'lake' not on PATH — compiler freshness NOT verified for this gate." >&2
  fi

  if [ ! -x "$bin" ]; then
    echo "MISSING COMPILER ARTIFACT: '$bin' does not exist or is not executable." >&2
    return 1
  fi

  return 0
}
