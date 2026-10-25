# Bug 264 — lifecycle gate occupies the slot it expects a dependent task to use

**Status:** FIXED on `fix/work-queue-lifecycle-gate` (pending landing).
**Found:** 2026-10-25, sequential landing validation after repairing bug 263.
**Severity:** loud test failure, not a compiler defect.

## Reproducer

Run `nix develop -c bash scripts/tests/check_work_queue.sh` at `525ea19e`.
The sequential retry reported `62 passed, 1 failed`: `after landing: 'bug-201'`.
The fake R-0547 task was correctly marked done and its worktree removed, but the subsequent
dependent-dispatch assertion expected R-0539 to own the only slot. This gate uses fake agents;
native and interpreter compiler execution are not relevant.

## Cause

The lifecycle scenario reconciled R-0547's completion with `QUEUE_MAX_AGENTS=1`. A tick both
monitors existing work and dispatches new work. While R-0539 still waited for R-0547 to land,
the dispatcher could correctly start ready bug-201. The test then simulated the landing and
expected R-0539 to start, although the one allowed slot was occupied. Completion-only ticks
elsewhere in the gate already set the cap to zero.

## Fix

Use `QUEUE_MAX_AGENTS=0` for completion reconciliation and assert the slot stays empty.
Then explicitly dispatch with capacity before landing: unrelated bug-201 must start while
R-0539 remains blocked. Release that unrelated work with the existing kill-switch mechanism,
then restore the cap of one for the post-landing tick. Thus the dependency must block actual
dispatch before landing and permit it afterwards. No scheduler code or dispatch policy changes.
Coverage is `scripts/tests/check_work_queue.sh`'s lifecycle scenario, including the new
empty-slot precondition and the existing landed-event and dependent-dispatch assertions.

## Structural cause

A test intended to observe lifecycle reconciliation also enabled unrelated dispatch, then
asserted a result incompatible with that permitted dispatch. This is test-state isolation,
outside the compiler structural classes. The same gate's usage-limit scenarios already use
zero-cap ticks to reconcile an exited run without dispatching another agent.

## Structural owner

R-0539's landing/readiness lifecycle and the work-queue gate: make preconditions explicit in
the scenario instead of changing production scheduling to satisfy an overconstrained test.
