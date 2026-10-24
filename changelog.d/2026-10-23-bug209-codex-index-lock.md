### Bug 209: Stale `index.lock` Files In Agent Worktrees (2026-10-23, cause corrected 2026-10-24)

Empty `index.lock` files kept appearing in agent worktrees and blocked the next commit. They came from
`llm-archive checkpoint`, which runs `git -C <worktree> status --short` on recorded sessions'
directories under a 1-second `subprocess` timeout: a refresh slower than that is killed while it holds
the lock. The first filing blamed Codex reviews, whose sandboxed `git status` takes the lock briefly
but releases it; a watcher that logs the lock holder separated the two. `scripts/review/review.sh` and
the by-hand `/creview` rounds still run Codex with `GIT_OPTIONAL_LOCKS=0`, pinned by
`check_review_tool.sh`; the archiver's read-only git calls need the same setting. Structural class 16
(artifacts at paths no run owns).
