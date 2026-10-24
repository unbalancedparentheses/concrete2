# Bug 209: a `git status` killed on a timeout left a stale `index.lock` in agent worktrees

**Status:** FIXED (in this repository: review runs; the owning tool is outside it, see Structural
owner). First filed 2026-10-23 with the wrong cause (a Codex review); corrected 2026-10-24.
**Found:** 2026-10-23, during the Hetzner gate-host and checker-cause work: four times an empty
`.git/worktrees/<name>/index.lock` appeared in the agent's own worktree, and the next `git commit` or
`git merge` there failed with "Unable to create ... index.lock: File exists" while no git process
was running. Each time it followed a `codex exec --sandbox read-only` review in that worktree.
**Severity:** loud. No wrong result: the next git write in that worktree refused until someone
removed the lock by hand.

## Reproducer

In a scratch worktree with every tracked file's stat data dirty (`git ls-files -z | xargs -0 touch`),
poll `.git/worktrees/<name>/index.lock` every 10 ms and log the git processes and their parents
whenever it exists, while a Codex session runs there and for seven minutes after it ends.

Observed (2026-10-24): during the session, Codex's own sandboxed `git status` takes the lock for
about 50 ms and releases it; with `GIT_OPTIONAL_LOCKS=0` it takes none (the variable reaches both the
sandboxed commands and the Codex CLI's own `git status --porcelain`, logged through a `git` shim on
PATH). AFTER the session, the lock keeps appearing every one to two minutes. The process caught
holding it was `git -C <worktree> status --short`, started by `llm-archive checkpoint`.

Killing a `git status` with SIGKILL while it holds the lock leaves it behind, 0 bytes (2 of 60 kills
at 0.25 s): the shape every stale lock had.

Expected: a tool that only reads a repository never leaves anything in it.

## Cause

`llm-archive` (the user's session archiver, `~/projects/llm-archive`, run by launchd) records the
working directory of every Claude and Codex session and, for its handoff journal, runs
`git -C <cwd> status --short` there through `projects.git_output`, which is `subprocess.run(...,
timeout=...)`; `journal.py` calls it with `git_timeout=1`. `git status` refreshes the index under
`index.lock` whenever it can. In a worktree of about 4,000 files on a loaded machine the refresh can
take longer than a second; `subprocess.run` then kills git, which cannot remove its lock. The lock
followed Codex reviews because each review is a recorded session whose directory the archiver then
visits.

The first filing blamed Codex: its sandboxed `git status` does take the lock, and the timing
matched. Codex releases it normally; the watcher above separates the two.

## Fix

- Here: the review runs keep `GIT_OPTIONAL_LOCKS=0` (`scripts/review/review.sh`, `/creview`,
  AGENTS.md; pinned by `check_review_tool.sh`). It is correct hardening, since a reviewer only
  reads, but it was not the cause.
- The owner of the cause is `llm-archive`: its read-only git calls (`projects.git_output`) must run
  with `GIT_OPTIONAL_LOCKS=0`, so a status reads the index and writes nothing and a timeout kill
  leaves nothing behind. That change is in the user's repository, not this one.
- Until it lands, a lock that no process owns (`lsof <path>/index.lock` empty) may be removed, as
  AGENTS.md already says.

## Containment

`check_review_tool.sh`: the fake reviewer records `GIT_OPTIONAL_LOCKS` for every call, and two legs
require that every call saw `0`, with the gate itself exporting `1` so an inherited value cannot
satisfy them. Nothing in this repository can contain a tool outside it.

## Structural cause

Read-only observers of a repository (a session archiver, a reviewer) ran git porcelain that writes:
git's default refreshes the index under a lock whenever it can, and a reader that may be killed or
timed out leaves that lock for the next writer. The observer did not own the path it wrote. Class 16,
artifacts at paths no run owns: 179 and 191 were intermediates and test files at shared names; here
it is a lock file in a repository the observer only meant to read.

## Structural owner

Every tool that inspects a worktree it does not own runs git with `GIT_OPTIONAL_LOCKS=0`. Here that
is `scripts/review/review.sh` (enforced by `check_review_tool.sh`). For the cause itself,
`llm-archive`'s `projects.git_output`. Class 16 in [STRUCTURAL_CLASSES.md](STRUCTURAL_CLASSES.md).

## Residual

Any other tool that runs git porcelain in these worktrees from outside (an editor's git integration,
a desktop app) can do the same until it sets the variable.
