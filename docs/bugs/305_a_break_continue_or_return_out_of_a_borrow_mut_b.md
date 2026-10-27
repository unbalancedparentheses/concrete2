# Bug 305 — a break, continue or return out of a borrow mut block lost the writes made through its reference

<!-- bug-ledger
summary: Lower pointed a borrow block's reference at a copy of the owner in a fresh slot and loaded the copy back into the owner only when the block fell through its end; a `break`, `continue` (labelled or not) or `return` leaving a `borrow mut` block early skipped that write-back, so the writes made through the reference were lost on that exit: the loop exit or continue edge carried the owner's old value, and an enclosing deferred call reading the owner read it too (silent wrong code)
fixtures: regress_305_borrow_block_early_exit.con
class: 8 — a borrow block's reference was a copy with a write-back on one exit
silent: yes
exit: 0b
-->

**Status:** OPEN — a repair is on `wip/bug-305` and waits for the owner's answer to OD2 (below)
**Found:** 2026-10-26, hunting silent wrong code in Lower's handling of borrows and address-taken
locals after bugs 285 and 287 (hand probes of every `CStmt` constructor; `.borrowIn`).
**Severity:** silent wrong code. The native binary loses writes made through the reference on an
early exit; `--interp` is right.

## Reproducer

```
fn brk(c: i64) -> i64 {
    let mut n: i64 = 0;
    let mut i: i64 = 0;
    while i < 3 {
        borrow mut n as r in R {
            *r = *r + 10;
            if i == c { break; }
        }
        i = i + 1;
    }
    return n * 100 + i;
}
fn main() with(Console) { println(brk(1)); }
```

## Observed

On main ea21a2e8 the binary prints `1001`, `--interp` `2001`. The same with `continue` (a loop of
three iterations adding 10 each, continuing out of the block in the second: binary 20, `--interp`
30), and with a `return` out of the block while an enclosing `defer show(&n)` reads the owner: the
deferred call prints the owner's value before the block (binary 1, `--interp` 7).
`regress_305_borrow_block_early_exit.con` (`break`, `continue`, a labelled `break` out of two
loops, and a read of the owner after a conditional `break`): main's binary exits 52, `--interp` 42.

## Expected

The reference denotes the owner (MEMORY_SEMANTICS §4, "Create the reference": `ref` has type
`&mut T` for the owner), so a write through it is a write to the owner, whichever way the block is
left; the interpreter, the reference, binds the reference to the owner's place (`Interp.lean`,
`.borrowIn`) and gives `2001`, `30` and `7`.

## Cause

`IR/Lower.lean`, `lowerStmt`'s `.borrowIn` case: it allocated a fresh `borrow.` slot, stored the
owner's current value in it, bound the reference to that slot, and after lowering the body loaded
the slot back into the owner, only if the block had not terminated. The exits (`.break_`,
`.continue_`, `.return_`) snapshot the variable table and branch, so on an early exit the owner
kept its value from before the block (Codex confirmation, 2026-10-26, traced all three).

## Fix

The block's reference is lowered as `&owner` / `&mut owner` is (`lowerExpr` of the borrow of the
owner): the owner's own storage, promoting it to a slot as any address-take does. The
address-taken walk already names a borrow block's owner (`cstmtAddrTaken`'s `.borrowIn` case), so
a branch or loop around the block promotes the owner before it, and a block in straight-line code
promotes it where the block starts, which dominates the body. There is no copy and no write-back,
on any exit.

**Owner decision (OD2).** The Codex review of this repair (2026-10-26, round 1) found that it picks
a side on OD2 ("one defined order for cleanup, loan end and write-back", ROADMAP exit 2n): with the
reference aliasing the owner, an enclosing deferred call that reads the owner after a `return` out
of the block sees the writes (7 above; main's binary prints 1), which fixes that order observably.
So the repair does not land until the owner answers. The options:

1. The reference aliases the owner (this branch). Every exit keeps the writes; an enclosing
   deferred call sees them. Native then agrees with the interpreter on every case above. This is
   the observable order of the 2026-10-23 proposal (inner deferred calls, then loan end and
   write-back, then the enclosing scopes' cleanup).
2. Keep the copy and write it back on every exit, at a defined point among the deferred calls
   (the exit-order rule OD2 would state); any order other than option 1's makes `return` with an
   enclosing `defer` read the owner's old value while `break` and `continue` keep the writes.
3. Refuse a `break`, `continue` or `return` out of a `borrow mut` block (a language rule).

Recommendation: option 1. The `break` and `continue` cases (no deferred call involved) lose writes
under every option except an explicit refusal, so they stay silent wrong code on main until then.

## Structural cause

Class 8: storage decided ad hoc in Lower. The borrow block had its own storage scheme (a copy with
a write-back at the fall-through end) beside the one every other borrow uses (the owner's slot),
and only the fall-through exit was given the step that kept the two in agreement.

## Structural owner

R-0501 (S10 Place MIR): places and loans explicit, every reference a place. Until then a borrow
block's reference is lowered by the same path as `&owner`.

Codex confirmation 2026-10-26: CONFIRMED — Mutable borrow blocks use a separate copy whose write-back is absent from early-exit paths, losing mutations and exposing stale owner values to outer deferred calls.
