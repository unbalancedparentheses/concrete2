# Bug 306 — the interpreter ran a for loop's step inside the body's scope, before the body's deferred calls

<!-- bug-ledger
summary: Elab desugars `for (init; cond; step) { body }` to a `.while_` whose body list ends with the step and which also carries the step separately; the interpreter evaluated the whole list as the body's block, so on fall-through the step ran before the body's deferred calls (a deferred call reading the counter saw the stepped value), while on `continue` it ran after them; the binary runs the body's block, then the step, on both (silent divergence: the differential reference was wrong)
fixtures: regress_306_for_step_after_body_defers.con
class: 12 — the step is kept twice in Core's `.while_`, and each consumer cut the body's block out of it on its own
silent: yes
exit: 0b
-->

**Status:** OPEN — a repair is on `wip/bug-306-r2` and waits for the owner's answer to OD2 (below)
**Found:** 2026-10-27, by the differential fuzzer's new borrow mode (`fuzz_differential.py --mode
borrow`): every remaining mismatch of 1000 programs on a build with bugs 301 – 305 fixed was this
one, and none remained with `for` loops off (`BorrowGen.fors`).
**Severity:** silent. `--interp`, the reference of every differential gate, disagreed with the
binary; here the binary is right.

## Reproducer

```
fn show(p: &i64) with(Console) { println(*p); }
fn f() with(Console) {
    for (let mut k: i64 = 0; k < 3; k = k + 1) {
        defer show(&k);
        if k == 1 { continue; }
    }
}
fn main() with(Console) { f(); }
```

## Observed

On main ea21a2e8 `--interp` prints `1 1 3`, the binary `0 1 2`. Without the `continue` line
`--interp` prints `1 2 3`, the binary `0 1 2`. `regress_306_for_step_after_body_defers.con`:
the binary exits 42, `--interp` on main prints 254.

## Expected

The body's block ends, running its deferred calls, before the step: STMT-6 (docs/spec/statements.md)
has `continue` leave the loop body's scopes and still run the step, and a fall-through end of the
body is the same exit (OWN-2). The binary does this on both paths; the interpreter did on
`continue` only.

## Cause

`Interp/Interp.lean`, `evalWhile`: on a true condition it evaluated `body` (which for a `for` loop
ends with the step, appended by Elab's desugaring) with one `evalStmts`, whose block runs its
deferred calls at its end, after the step; on `.cont` it ran `step` after the shortened block.
Lower (`lowerStmt`'s `.while_`) lowers `body.take (body.length - step.length)` as the block and the
step after it (Codex confirmation, 2026-10-26).

## Fix

`CStmt.whileBodyBlock body step` (Elab/Core.lean) names the body's own block once; Lower and the
interpreter both use it, and the interpreter runs the step after the block on fall-through as on
`continue`.

**Owner decision (OD2).** The Codex review of this repair (2026-10-27, round 1) found that running
the body's deferred calls before the step, on fall-through as on `continue`, implements the exit
order OD2 leaves to the owner ("one defined order for cleanup, loan end and write-back"), and that
the fixture pins it. So the repair does not land until the owner answers. The options: (1) the
body's deferred calls run before the step on every path (the binary today, and this branch);
(2) the step runs inside the body's scope, before its deferred calls, on every path (Lower would
change, and `continue` would run the step before the deferred calls); (3) leave the two paths
different (the interpreter today). Recommendation: option 1, which STMT-6's rationale describes for
`continue`. Until then the binary and the interpreter disagree, and the differential gates see it
only when a `for` body defers a call that reads what the step writes.

## Structural cause

Class 12: one fact kept in two places. Core's `.while_` carries the step inside the body list and
again as its own field, and each consumer decided by itself which statements form the body's block.
CoreCheck checks the whole list as one block and the step again (no runtime effect; noted by the
Codex confirmation); the proof model reads the list with the step and refuses `defer` and
`continue` in loops.

## Structural owner

R-0496 (S7: the interpreter is Core's semantics) and the Core loop form: a `.while_` whose body does
not contain its step. Until then `CStmt.whileBodyBlock` is the one place that cuts it out.

Codex confirmation 2026-10-26: CONFIRMED — The interpreter incorrectly includes the appended for-loop step in the body's defer scope on fall-through, while native lowering correctly runs body defers before the step on both fall-through and continue.
