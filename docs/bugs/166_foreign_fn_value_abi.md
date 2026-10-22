# Bug 166 — a foreign function taken as a value is called with the Concrete ABI

**Status:** FIXED (branch `soundness-holes`)
**Found:** 2026-10-22, by the Codex review (round 5) of the symbol-name work (branch `symbols`).
**Severity:** silent wrong code at the C boundary. A direct call of an `extern fn` whose parameter
or result is a small `#[repr(C)]` struct is flattened to the C ABI (a struct of 8 bytes or less
travels in an integer register). The same extern passed as a function VALUE and called through it
uses the Concrete ABI (a pointer to the struct), so C receives the struct's address as its field.
Needs a `trusted extern fn` (or `with(Unsafe)`), so safe code cannot reach it without a trusted
boundary, but nothing at that boundary warns.

## Reproducer

`tests/regressions/bug166_foreign_fn_value_abi/repro.con`:

```con
#[repr(C)]
struct Copy Pair { v: Int }

trusted extern fn take_pair(p: Pair) with() -> Int;

fn apply(f: fn(Pair) -> Int, p: Pair) -> Int {
    return f(p);
}

fn main() -> Int {
    return apply(take_pair, Pair { v: 7 });
}
```

`--emit-llvm`: `declare i64 @take_pair(i64)`, but `apply` calls `%t0 = call i64 %f(ptr %p)` and
`main` passes `ptr @take_pair`. Expected: the call through `f` passes `Pair` the way C declares it,
or the program is refused. The defect predates the symbol work (it is the ABI, not the name).

## Cause

`EmitSSA` decides the extern ABI (`isExternCall`, `externABIFlattenParam` / `Ret`) only for a
DIRECT callee. A function type `fn(Pair) -> Int` carries no calling convention, so an indirect
call through a value cannot know that its target is a C function.

## Structural cause

Calling convention is a property of the callee's declaration that the function TYPE does not
carry ([structural class](STRUCTURAL_CLASSES.md) 14, trusted std and FFI code with no checked
contract: the C boundary's ABI is decided at one call form and not at the other).

## Structural owner

R-0283 / R-0287 (ABI checks for the C boundary): either an adapter with the Concrete ABI is
generated when a foreign function is taken as a value, or the convention is part of the function
type and a mismatch is refused. The narrow containment, under exit 0b: refuse taking as a value an
`extern fn` whose signature contains a `#[repr(C)]` aggregate.

## Fix

The first of the two structural options: an adapter. The C calling convention stays decided at
one place, the direct call of a foreign callee. When a function body refers to a foreign function
as a VALUE (`SVal.fnRef`, as a call argument, a stored field, a phi operand or a returned value)
and that function's type has a `#[repr(C)]` aggregate among its parameters or as its result,
`EmitSSA.foreignValueAdapters` replaces the reference with `ffi$<k>-<C symbol>`, a Concrete-ABI
function of the same type (`_C.<module>.ffi$0-take_pair`) whose body is the direct call. The
flattening is then the direct call's own. The foreign predicate is the one `isExternCall` uses
(the resolver's `foreignCalls` binding or an extern spelling, and not a Concrete definition), so
the two cannot disagree about which references are foreign. A signature with no `#[repr(C)]`
aggregate has the same LLVM signature in both conventions and keeps referring to the C symbol, so
the IR of every existing foreign function value (`console_write` and the rest) is unchanged. The
`$` keeps the adapter's name out of every source spelling. There is one adapter per C symbol
AND Concrete signature (`ffi$0-take_two`, `ffi$1-take_two`): two externs bound to one
`#[link_name]` can flatten to one C signature from different Concrete ones, and `-`, which no
C symbol contains, keeps the index and the symbol apart (Codex review). No language rule changed: the program
means what it did, and a foreign function value now does what the direct call does.

The adapter is an emission artifact: it does not appear in Core, `--emit-ssa` or any report, and
its address differs from the C symbol's (and from another module's adapter for the same
function). That is observable only by comparing function values, which bug 140's comparison rule
(on `wip/train1`, E0229) refuses, or by handing the value to C as a raw pointer.

Regression fixture: `tests/programs/regress_166_foreign_fn_value_abi.con` with its C side
`regress_166_foreign_fn_value_abi.c`: an 8-byte struct argument, a 16-byte struct argument (two
registers), an 8-byte struct result and a second binding of `take_two` taking two 8-byte structs, each called through a fn value and directly; linked and
run it exits 42 (`run_tests.sh`, the C-linked legs). Before the fix the two disagree and it exits
1. The original reproducer's IR now passes `ptr @_C.main.ffi$0-take_pair` (the run_tests.sh leg
that pinned the Concrete-ABI call is replaced by one that requires the adapter).

Not covered, recorded: aggregates over 16 bytes are flattened to a pointer by
`externABIFlattenParam` for every call form; whether that matches the x86-64 SysV `byval`
convention is a question about the direct call (R-0283 / R-0287), not about values.

## Containment while open (historical)

`scripts/tests/run_tests.sh` (codegen section, "bug 166 pin") requires the reproducer's IR to
show the Concrete-ABI call through the value (`call i64 %f(ptr %p)`) next to the C declaration
`declare i64 @take_pair(i64)`; when the call changes, that leg fails until this document, the
corpus entry and the leg are updated together.
