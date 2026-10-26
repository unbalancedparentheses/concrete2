# Bug 305 — a break, continue or return out of a borrow mut block lost the writes made through its reference

<!-- bug-ledger
summary: Lower pointed a borrow block's reference at a copy of the owner in a fresh slot and loaded the copy back into the owner only when the block fell through its end; a `break`, `continue` (labelled or not) or `return` leaving a `borrow mut` block early skipped that write-back, so the writes made through the reference were lost on that exit: the loop exit or continue edge carried the owner's old value, and an enclosing deferred call reading the owner read it too (silent wrong code)
fixtures: regress_305_borrow_block_early_exit.con
class: 8 — a borrow block's reference was a copy with a write-back on one exit
silent: yes
exit: 0b
-->

**Status:** FIXED (branch `wip/bug-305`)
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

On the owner decisions: the fix does not order a write-back against deferred calls (OD2's "one
defined order for cleanup, loan end and write-back"); it removes the write-back, so the owner holds
every write through the reference when each write is made, which is what the interpreter does. The
`return`-with-`defer` case above follows from that and is described here, not pinned by the fixture.

## Structural cause

Class 8: storage decided ad hoc in Lower. The borrow block had its own storage scheme (a copy with
a write-back at the fall-through end) beside the one every other borrow uses (the owner's slot),
and only the fall-through exit was given the step that kept the two in agreement.

## Structural owner

R-0501 (S10 Place MIR): places and loans explicit, every reference a place. Until then a borrow
block's reference is lowered by the same path as `&owner`.

Codex confirmation 2026-10-26: CONFIRMED — Mutable borrow blocks use a separate copy whose write-back is absent from early-exit paths, losing mutations and exposing stale owner values to outer deferred calls.
