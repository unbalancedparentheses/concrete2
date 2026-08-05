# Bug 066 — the interpreter discards a match guard's effects

**Status:** OPEN
**Found:** 2026-08-04, while measuring match evaluation order for R-0004's evidence
producer (guards evaluated only after the pattern matches; first successful guarded arm
wins).
**Class:** interp/compiled differential — the same class as the 2026-06-27 sweep.

## Witness

```concrete
mod g {
    enum Copy E { A { v: Int }, B { v: Int } }
    fn guard1() with(Console) -> Bool { print("GUARD-RAN\n"); return true; }
    pub fn main() with(Console) -> Int {
        let e: E = E::A { v: 7 };
        match e {
            E::A { v } if guard1() => { print("took-guarded\n"); return 1; },
            E::A { v } => { print("took-fallback\n"); return 2; },
            E::B { v } => { return 0; }
        }
    }
}
```

| | guard effect | arm taken |
|---|---|---|
| interpreter (`--interp`) | **`GUARD-RAN` missing** | took-guarded |
| compiled | `GUARD-RAN` printed | took-guarded |

Both select the correct arm. Only the guard's OBSERVABLE EFFECT differs, which is why
a return-value-only comparison would not have caught it.

## Cause

`Concrete/Interp/Interp.lean`, in the match-arm walker:

```lean
let guardOk := fun (armEnv : Env) (guard : Option CExpr) =>
  match guard with
  | none => Except.ok true
  | some g => do
    let (_, gv) ← evalExprVal fns enums armEnv g   -- <-- env DISCARDED
```

`evalExprVal : ... → Except String (Env × IVal)` returns the updated environment, which
carries accumulated output and any state the expression touched. Every other call site
threads it forward (`let (env, v) ← evalExprVal ...`); this one alone drops it with `_`.
So the guard is evaluated, its VALUE is used to select the arm, and everything else it
did is thrown away.

## Why it matters beyond printing

`Env` is not just an output buffer. Anything a guard mutates is lost, so a guard that
increments a counter, or whose call mutates through a `&mut`, leaves no trace — while
the compiled binary performs it. The interpreter is the differential oracle, so a
divergence here weakens every differential test that involves a guarded arm.

## Fix shape

`guardOk` must return the updated environment alongside the boolean
(`Except String (Env × Bool)`), and each arm must thread it into the body's evaluation —
including the FALL-THROUGH path, since a guard that fails has still run its effects and
the next arm must start from the environment it left behind.

The fall-through case is the subtle half: it is tempting to thread the env only when the
guard succeeds, which would silently discard the effects of every failed guard.

## Gate

A differential fixture asserting interpreter and compiled output agree for:

1. a guard whose effect runs and whose arm is taken;
2. a FAILING guard whose effect runs before falling through to a later arm;
3. two failing guards, so the ORDER of discarded-then-restored environments is checked;
4. a guard on a non-selected arm that must not run at all (pattern did not match).

Case 2 is the one the current code would still fail after a naive fix.
