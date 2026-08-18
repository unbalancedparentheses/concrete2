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

  # Held. Reclaim only if the recorded owner is genuinely gone — a live holder must never be
  # displaced, because displacing it recreates the very interleaving this prevents.
  owner_pid="$(sed -n 's/^pid=//p' "$_GATE_LOCK_DIR/owner" 2>/dev/null || true)"
  owner_desc="$(tr '\n' ' ' < "$_GATE_LOCK_DIR/owner" 2>/dev/null || true)"
  if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
    rm -rf "$_GATE_LOCK_DIR"
    if mkdir "$_GATE_LOCK_DIR" 2>/dev/null; then
      printf 'pid=%s\ncmd=%s\n' "$$" "${0##*/}" > "$_GATE_LOCK_DIR/owner" 2>/dev/null || true
      export CONCRETE_GATE_LOCK="$$"
      echo "note: reclaimed a stale gate lock left by pid $owner_pid" >&2
      return 0
    fi
  fi

  echo "REPOSITORY BUSY — refusing to run this gate." >&2
  echo "  Another gate or build holds the lock: ${owner_desc:-unknown owner}" >&2
  echo "  Gates share one .lake tree and one binary. Running alongside a rebuild yields a verdict" >&2
  echo "  about an artifact that never existed, which is worse than no verdict at all." >&2
  echo "  Wait for it to finish, or remove $_GATE_LOCK_DIR if you are certain it is stale." >&2
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
