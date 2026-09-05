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
  #
  # THE INHERITED TOKEN IS VERIFIED, NOT TRUSTED. Any nonempty value used to bypass acquisition
  # outright, so `CONCRETE_GATE_LOCK=1 bash check_foo.sh` ran with NO lock held at all while every
  # message claimed one was — a fail-open authority path in the one mechanism whose whole purpose is
  # to refuse. The token now names the lock it refers to (`pid:absolute-dir`), and all three of those
  # facts must hold: the directory still exists, its recorded owner is the token's pid, and that pid
  # is alive. Anything else is a stale or forged token and is refused.
  if [ -n "${CONCRETE_GATE_LOCK:-}" ]; then
    local tok_pid tok_dir tok_owner
    tok_pid="${CONCRETE_GATE_LOCK%%:*}"
    tok_dir="${CONCRETE_GATE_LOCK#*:}"
    # SHAPE-CONSTRAINED. The token must name something that looks like a lock, matching the
    # constraint the release path enforces. This does NOT make the token unforgeable: a PARENT process
    # can always create a directory, write its own pid into `owner`, and pass a valid-looking token —
    # and no check inside this file can prevent that, because a parent controls its children's
    # environment completely. That is stated rather than papered over: this lock defends against
    # ACCIDENTAL concurrency between cooperating runs, which is the failure that has actually
    # happened here repeatedly. It is not an adversarial boundary.
    case "$tok_dir" in */.gate.lock) ;; *) tok_dir="" ;; esac
    if [ -n "$tok_pid" ] && [ -n "$tok_dir" ] && [ "$tok_dir" != "$CONCRETE_GATE_LOCK" ] && [ -d "$tok_dir" ]; then
      tok_owner="$(sed -n 's/^pid=//p' "$tok_dir/owner" 2>/dev/null || true)"
      if [ "$tok_owner" = "$tok_pid" ] && kill -0 "$tok_pid" 2>/dev/null; then
        # ANCESTRY, not just existence. Everything above can be FABRICATED by the caller: make a
        # directory, write your own pid into `owner`, and the token validates. The property that
        # actually makes re-entrancy legitimate is that the holder is an ANCESTOR of this process —
        # "one run, one lock" is a statement about a process tree. Equality with this repository's own
        # lock path cannot be required instead, because gates legitimately run inside a disposable
        # COPY of the tree and inherit a token naming the real repository's lock.
        if [ -r /proc/self/stat ]; then
          local _p=$$ _ppid _guard=0
          while [ "$_p" != "1" ] && [ "$_p" != "0" ] && [ "$_guard" -lt 64 ]; do
            [ "$_p" = "$tok_pid" ] && return 0
            _ppid="$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null)" || break
            [ -n "$_ppid" ] || break
            _p="$_ppid"; _guard=$((_guard+1))
          done
          [ "$_p" = "$tok_pid" ] && return 0
          echo "GATE-PRECONDITION-FAILED: lock-token-not-ancestor" >&2
    echo "REPOSITORY LOCK TOKEN NOT HELD BY AN ANCESTOR — refusing to run this gate." >&2
          echo "  CONCRETE_GATE_LOCK names pid $tok_pid, which is not in this process's parent chain." >&2
          echo "  A token that merely points at a directory can be fabricated; re-entrancy is only" >&2
          echo "  legitimate for a lock a parent of this process actually holds." >&2
          return 1
        fi
        # No /proc: ancestry is not determinable, so fall back to the weaker checks already passed.
        return 0
      fi
    fi
    echo "GATE-PRECONDITION-FAILED: lock-token-invalid" >&2
    echo "REPOSITORY LOCK TOKEN INVALID — refusing to run this gate." >&2
    echo "  CONCRETE_GATE_LOCK='$CONCRETE_GATE_LOCK' does not name a live lock this run holds." >&2
    echo "  A gate that proceeds on an unverified token reports a verdict while holding nothing." >&2
    echo "  Unset it to acquire a lock normally." >&2
    return 1
  fi

  local owner_pid owner_desc
  if mkdir "$_GATE_LOCK_DIR" 2>/dev/null; then
    # THE OWNER RECORD IS PART OF ACQUISITION, not best-effort metadata. This was `|| true`, so a
    # failed write left a lock directory with no owner while acquisition reported SUCCESS — after
    # which every re-entrant child REJECTED the exported token (its owner check cannot match), and
    # test_mutation.sh counted those refusals as mutation kills. A lease nobody can verify is not a
    # lease, so the directory is removed and acquisition fails.
    if ! printf 'pid=%s\ncmd=%s\n' "$$" "${0##*/}" > "$_GATE_LOCK_DIR/owner" 2>/dev/null; then
      rmdir "$_GATE_LOCK_DIR" 2>/dev/null || rm -rf "$_GATE_LOCK_DIR" 2>/dev/null || true
      echo "GATE-PRECONDITION-FAILED: lock-owner-unrecordable" >&2
      echo "error: took the lock directory but could not record its owner — releasing it." >&2
      return 1
    fi
    export CONCRETE_GATE_LOCK="$$:$_GATE_LOCK_DIR"
    # THE LOCK'S LIFETIME IS THIS PROCESS'S LIFETIME, ARMED AT THE MOMENT OF CREATION.
    #
    # Release used to be entirely explicit, on the stated theory that "gates set their own trap".
    # They do not: of the 167 gates that call require_fresh_binary, 137 install no EXIT trap at all.
    # So the first gate in a run that actually rebuilt kept the lock forever, every later
    # lock-taking gate refused, and the aggregator counted each refusal as a FAILURE —
    # FAST-SURFACE-GATES 8/3, and weeks of red CI, produced entirely by this leak.
    #
    # Armed HERE rather than in require_fresh_binary, because the lock must cover the WHOLE gate
    # run: releasing it when the rebuild finishes would reopen the window while the gate is still
    # collecting evidence about the binary it just verified.
    #
    # `_GATE_LOCK_CREATED` distinguishes the creator from a re-entrant child that merely inherited a
    # valid token. Only the creator arms, and only the creator releases.
    _GATE_LOCK_CREATED=1
    _gate_lock_arm_release
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

  echo "GATE-PRECONDITION-FAILED: repository-busy" >&2
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

# RELEASE — for an entry point that acquired the lock itself and knows its run is over.
#
# There is still no EXIT trap installed here (that would clobber gates' own traps), so release is
# EXPLICIT: a long-running entry point such as the mutation campaign calls this from its own cleanup
# path. Without it, the first gate to acquire a lock left it behind forever, and the next gate in the
# same tree refused — which the mutation campaign then counted as a KILL, manufacturing evidence
# from its own lock leak (measured 2026-08-21).
#
# ONLY THE CREATOR MAY RELEASE. A re-entrant child that merely inherited the token must not remove a
# lock its parent is still working under; that would hand the tree to a concurrent run, which is the
# same failure as reclaiming on a dead PID.
# THE RELEASE IS COMPOSED INTO EXISTING TRAPS, NEVER SUBSTITUTED FOR THEM.
#
# MEASURED before writing this: 29 of the gates that take this lock install their own `trap ... EXIT`
# AFTER the acquisition. A release armed at acquisition would have been silently replaced in exactly
# those 29 — present in the source, absent at runtime, which is the failure mode this repository
# keeps finding in its own controls.
#
# So `trap` itself is wrapped. Any later installation on a terminating signal is COMPOSED with the
# release rather than replacing it, and the gate's own cleanup runs FIRST, because it may still need
# the tree the lock protects. Queries (`-p`, `-l`) and non-terminating signals — notably ERR, which
# nine gates use — pass through untouched.
#
# SIGKILL cannot be trapped by anyone, so a lock stranded by `kill -9` still needs an operator. That
# limit is stated rather than papered over, and the refusal message already says it.
_GATE_LOCK_RELEASE_SNIPPET='_gate_lock_release >/dev/null 2>&1 || true'

# ARMING COMPOSES TOO. A gate may already have installed its cleanup BEFORE it asked for the lock —
# 1 of the 167 does exactly that — and arming by plain assignment DESTROYED that cleanup. The first
# version of this function did, and the control for it failed on the first run: cleanup=lost.
# Whatever is already installed runs first, then the release.
# ONE COMPONENT MANAGES THIS LOCK DELIBERATELY, AND MUST BE ABLE TO SAY SO.
#
# The mutation supervisor decides whether to release by asking `supervisor_must_hold_lock`: when the
# campaign's process group is not proven empty, it REFUSES to release, because handing the tree to
# the next run while work may still be writing it is the failure the whole boundary exists to
# prevent. Composing an unconditional release into its EXIT trap would have silently reversed that
# decision — verified by running it: the supervisor's trap became
# `{ _sup_exit_cleanup ; } ; _gate_lock_release`, releasing exactly when it had decided to hold.
#
# `_GATE_LOCK_SELF_MANAGED=1` opts out of both the arming and the composition. It is for components
# that release on their own explicit rule, not for gates that would simply rather not clean up.
_gate_lock_arm_release() {
  [ "${_GATE_LOCK_SELF_MANAGED:-0}" = "1" ] && return 0
  local s prev
  for s in EXIT INT TERM HUP; do
    prev="$(builtin trap -p "$s" 2>/dev/null)"
    # `trap -p` prints: trap -- 'CMD' SIG   (nothing at all when no handler is installed)
    if [ -n "$prev" ]; then
      prev="${prev#*\'}"; prev="${prev%\'*}"
    fi
    if [ -n "$prev" ]; then
      builtin trap "{ $prev ; } ; $_GATE_LOCK_RELEASE_SNIPPET" "$s" 2>/dev/null || true
    else
      builtin trap "$_GATE_LOCK_RELEASE_SNIPPET" "$s" 2>/dev/null || true
    fi
  done
}

trap() {
  case "${1:-}" in
    -p|-l|"") builtin trap "$@"; return $? ;;
  esac
  local cmd="$1"; shift
  [ "$#" -gt 0 ] || { builtin trap "$cmd"; return $?; }
  local s rc=0 composed
  for s in "$@"; do
    case "$s" in
      EXIT|0|INT|2|TERM|15|HUP|1)
        if [ "${_GATE_LOCK_CREATED:-0}" != "1" ] || [ "${_GATE_LOCK_SELF_MANAGED:-0}" = "1" ]; then
          builtin trap "$cmd" "$s" || rc=1
        elif [ "$cmd" = "-" ]; then
          # A reset drops the GATE'S cleanup, not the repository lock it holds on everyone's behalf.
          builtin trap "$_GATE_LOCK_RELEASE_SNIPPET" "$s" || rc=1
        else
          composed="{ $cmd ; } ; $_GATE_LOCK_RELEASE_SNIPPET"
          builtin trap "$composed" "$s" || rc=1
        fi ;;
      *) builtin trap "$cmd" "$s" || rc=1 ;;
    esac
  done
  return $rc
}

_gate_lock_release() {
  [ -n "${CONCRETE_GATE_LOCK:-}" ] || return 0
  local tok_pid tok_dir owner
  tok_pid="${CONCRETE_GATE_LOCK%%:*}"
  tok_dir="${CONCRETE_GATE_LOCK#*:}"
  [ "$tok_pid" = "$$" ] || return 0
  [ -d "$tok_dir" ] || return 0
  owner="$(sed -n 's/^pid=//p' "$tok_dir/owner" 2>/dev/null || true)"
  [ "$owner" = "$$" ] || return 0
  # NAMED `.gate.lock`, and the removal is CHECKED. This is an `rm -rf` of a path that arrived in an
  # environment variable, so the shape is constrained; and a release that silently failed while
  # unsetting the token left the lock in place with nothing holding it, which wedges the repository
  # until someone deletes it by hand.
  case "$tok_dir" in
    */.gate.lock) ;;
    *) echo "warning: refusing to release '$tok_dir' — not a .gate.lock path" >&2; return 1 ;;
  esac
  if ! rm -rf "$tok_dir" 2>/dev/null; then
    echo "warning: could not release the repository lock at $tok_dir" >&2
    echo "         remove it explicitly before the next run: rm -rf $tok_dir" >&2
    return 1
  fi
  if [ -d "$tok_dir" ]; then
    echo "warning: the repository lock at $tok_dir still exists after release" >&2
    return 1
  fi
  unset CONCRETE_GATE_LOCK
  return 0
}

require_fresh_binary() {
  local bin="${1:-$_FRESH_ROOT/.lake/build/bin/concrete}"

  # THE LOCK COMES FIRST, before the rebuild below. Acquiring it after `lake build` would leave the
  # exact window this exists to close: two gates rebuilding the same tree at once.
  _gate_lock_acquire || return 1

  if command -v lake >/dev/null 2>&1; then
    local out
    if ! out="$(cd "$_FRESH_ROOT" && lake build 2>&1)"; then
      # A MACHINE-READABLE MARKER, because a consumer needs to distinguish "this gate ran and
      # disagreed" from "this gate never started". The mutation campaign reads gate logs to decide
      # whether a nonzero exit is rule evidence, and it cannot: the build output is filtered to
      # `^error` lines here, so the compiler diagnostic that names the mutated file never reaches the
      # log the campaign inspects. Its detector was therefore INERT and every such failure was scored
      # as a gate kill. One stable line fixes that for every consumer.
      echo "GATE-PRECONDITION-FAILED: compiler-build" >&2
      echo "COMPILER BUILD FAILED — refusing to run this gate against a stale binary." >&2
      echo "$out" | grep -E '^error' | head -20 >&2
      return 1
    fi
  else
    # NO LAKE MEANS NO VERDICT. This printed a warning and CONTINUED, running the gate against
    # whatever binary happened to be on disk — which is precisely the stale-artifact evidence this
    # file exists to prevent, permitted by the guard itself. A warning is not a control: it scrolls
    # past in a 200-gate run and the PASS lines that follow look identical to verified ones.
    #
    # Refused by default, with a named, explicit override for the environments that genuinely have no
    # toolchain and accept the consequence. The override has to be typed, so it cannot be reached by
    # accident.
    if [ "${CONCRETE_ALLOW_UNVERIFIED_BINARY:-0}" = "1" ]; then
      # A MACHINE-READABLE TAINT, not just a warning. In this mode the gate DOES run, so it is not a
      # precondition failure — but its verdict describes a binary nobody verified, and a human-readable
      # warning is indistinguishable from verified evidence to any consumer that reads logs or
      # artifacts. The campaign refuses completion when it sees this.
      echo "GATE-FRESHNESS-UNVERIFIED: no-toolchain" >&2
      echo "WARNING: 'lake' not on PATH and CONCRETE_ALLOW_UNVERIFIED_BINARY=1 — compiler freshness" >&2
      echo "         NOT verified. This gate's result describes an unverified binary." >&2
    else
      echo "CANNOT VERIFY COMPILER FRESHNESS — refusing to run this gate." >&2
      echo "  'lake' is not on PATH, so there is no way to establish that the binary on disk" >&2
      echo "  corresponds to the checked-out source. A gate that runs anyway produces plausible" >&2
      echo "  evidence about an artifact that may no longer exist, which is worse than no evidence." >&2
      echo "GATE-PRECONDITION-FAILED: no-toolchain" >&2
      echo "  Install the toolchain, or set CONCRETE_ALLOW_UNVERIFIED_BINARY=1 to accept that." >&2
      return 1
    fi
  fi

  if [ ! -x "$bin" ]; then
    echo "GATE-PRECONDITION-FAILED: missing-compiler" >&2
    echo "MISSING COMPILER ARTIFACT: '$bin' does not exist or is not executable." >&2
    return 1
  fi

  return 0
}
