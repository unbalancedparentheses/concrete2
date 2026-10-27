# Bug 307 — a call argument &mut x passed a temporary copy of x and wrote it back after the call, so a raw pointer derived from it did not alias x

<!-- bug-ledger
summary: Lower lowered a call argument `&mut x` whose local was not yet slot-backed by copying `x` into a temporary `mutref.` slot, passing the temporary and loading it back into `x` after the call; the callee's reference was not `x`'s storage, so a raw pointer a trusted callee derived from it (`p as *mut T`, returned or stored) pointed at the temporary after the call: a write through it was lost to `x` and a later write to `x` was not seen through it (silent wrong code)
fixtures: regress_307_call_arg_mut_borrow_aliases.con
class: 8 — a call argument's `&mut x` had its own storage scheme beside `addrOfLocal`'s
silent: yes
exit: 0b
-->

**Status:** OPEN — a repair is on `wip/bug-307` and waits for the owner's answer to OD2 and OD15 (below)
**Found:** 2026-10-27, auditing the wildcard cases of `IR/Lower.lean` for the borrow hunt that found
bugs 301 – 306 (the call case's `.borrowMut (.ident ..)` argument path).
**Severity:** silent wrong code. After the call the native binary reads a stale value through the
pointer or in the local; `--interp` is right.

## Reproducer

```
trusted fn leak(p: &mut i64) -> *mut i64 { return p as *mut i64; }
trusted fn wr(p: *mut i64, v: i64) { *p = v; }
fn a() -> i64 {
    let mut x: i64 = 1;
    let q: *mut i64 = leak(&mut x);
    wr(q, 5);
    return x;
}
fn main() with(Console) { println(a()); }
```

## Observed

On main ea21a2e8 the binary prints `1`, `--interp` `5`; with `x = 7; return rd(q);` after the call,
the binary prints `1` and `--interp` `7`. `let r = &mut x; leak(r)` was right: only the direct
argument spelling took the copy. `regress_307_call_arg_mut_borrow_aliases.con` (both directions,
two calls borrowing the same local, and a plain `&mut` argument): main's binary exits 24,
`--interp` 42.

## Expected

The reference passed is `x`'s own storage, so a raw pointer derived from it aliases `x` while `x`
lives; returning a raw pointer from trusted code is the documented low-level escape
(docs/spec/references.md), and the interpreter, the reference, gives `5` and `7`.

## Cause

`IR/Lower.lean`, `lowerExpr`'s `.call` case: an argument of the shape `.borrowMut (.ident x _)`
with `x` not promoted got a fresh `mutref.` slot holding a copy of `x`, the call received the
slot, and the slot was loaded back into `x` after the call (`mutBorrows`). Every other `&mut x`
goes through `placeAddr` / `addrOfLocal`, which promotes `x` itself (Codex confirmation,
2026-10-27).

## Fix

Call arguments are lowered as the expressions they are: `&mut x` promotes `x` (lazily where the
call is, which dominates the call; a branch or loop around the call promotes `x` before it, from
the address-taken walk), and the copy and write-back are gone.

**Owner decisions (OD2, OD15).** The Codex review of this repair (2026-10-27, round 1) found that
removing the copy and write-back of a `&mut` argument chooses observable aliasing and write-back
behaviour of `&mut` arguments (OD2), and that the fixture's expectation, a raw pointer derived from
the argument aliasing the local after the call, is an operational aliasing rule (OD15). The Codex
confirmation of the bug had answered that no owner decision was needed; the review's answer
governs, so the repair does not land until the owner answers. The options: (1) a `&mut x` argument
is `x`'s storage (this branch; native then agrees with the interpreter); (2) keep the copy and
write-back and state that a raw pointer derived from a `&mut` argument is valid only for the call
(the interpreter would change, and so would every `--interp` result above); (3) refuse a raw pointer
derived from a `&mut` parameter outliving the call (a checker rule). Recommendation: option 1, the
storage every other spelling of `&mut x` already has.

## Structural cause

Class 8: storage decided ad hoc in Lower. A second storage scheme for one spelling of a borrow (a
copy with a write-back, like the borrow block's of bug 305) beside the owner's slot, kept in
agreement with it only when nothing outlived the call.

## Structural owner

R-0501 (S10 Place MIR): every reference a place. Until then every `&mut x` is lowered by one path.

Codex confirmation 2026-10-27: CONFIRMED — Direct mutable-borrow call arguments to unpromoted locals use unregistered copy-in/copy-out slots, so escaped raw pointers lose the local's storage identity and produce the reported silent wrong code.
