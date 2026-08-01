# Bug 065: `--report stack-depth` drops recursive callees from the call graph, so a caller of unbounded code reports a finite stack bound

**Status:** Open
**Discovered:** 2026-07-31, while auditing the user-exposed surface for
under-gated features (`--report stack-depth` had zero references in
`scripts/tests/`).

## Symptom

A non-recursive function that calls recursive functions is reported with a
finite stack bound, and the report's summary presents that bound as the
program's maximum.

```concrete
mod rec {
  fn is_even(n: Int) -> Bool { if n == 0 { return true; } return is_odd(n - 1); }
  fn is_odd(n: Int) -> Bool { if n == 0 { return false; } return is_even(n - 1); }
  fn fact(n: Int) -> Int { if n <= 1 { return 1; } return n * fact(n - 1); }
  fn main() -> Int { if is_even(4) { return fact(3); } return 0; }
}
```

```
$ concrete rec.con --report stack-depth
  is_even
    frame: 16 bytes  depth: unbounded (recursive)  stack: unbounded
  is_odd
    frame: 16 bytes  depth: unbounded (recursive)  stack: unbounded
  fact
    frame: 16 bytes  depth: unbounded (recursive)  stack: unbounded
  main
    frame: 8 bytes  depth: 0  stack: 8 bytes

Totals: 4 functions, 1 bounded, 3 recursive (unbounded)
Max stack bound: 8 bytes (main)
```

`main` calls `is_even` (mutual cycle) and `fact` (direct recursion). Its stack
usage is unbounded. It is reported as `depth: 0  stack: 8 bytes` — its own frame
only — and the summary line then reads `Max stack bound: 8 bytes (main)`, which
states a bound for the program that the program does not have.

`--report recursion` on the same input is correct: it names `rec.fact` as direct
recursion and `rec.is_odd -> rec.is_even -> rec.is_odd` as a mutual cycle. The
two reports disagree, and only the recursion one is right.

## Root cause

`computeCallDepths` filters recursive callees out of every caller's callee set
(`Concrete/Report/Report.lean:496`):

```lean
let callees := getCallees fn |>.filter (fun c =>
  !isRecursive c && frameSizes.any (fun (n, _) => n == c))
```

The filter's purpose is to stop the DFS from descending into a cycle, which it
does. But removing the edge also removes the *fact* of the call, so the caller's
fold never sees a contributor it cannot bound, and returns its own frame as the
answer. Unboundedness is a property that must propagate up the call graph; here
it is discarded at exactly the edge that carries it.

The same shape appears in the guard one line earlier
(`if isRecursive fn || visited.contains fn then ((0, getFrame fn), memo)`): a
cycle discovered through `visited` also yields a finite pair rather than an
unbounded one. `recMap` normally classifies real cycles first, so this is the
second door to the same wrong answer, not an independent defect.

The summary then compounds it. `maxStack` folds over `bounded` only
(`:578`), so recursive functions are excluded from the maximum by construction —
correct in isolation, since they have no bound to contribute, but it means the
printed maximum is the largest bound among functions whose bounds are themselves
computed with the missing edges.

## Severity

Contained to this report. `stackBound` has exactly one consumer — the report
string itself:

```
$ grep -rn 'stackBound\|stack_bound' Concrete/ Main.lean
Main.lean:2299:      IO.println (Report.stackDepthReport validCore.coreModules locMap pc)
```

It reaches no claim record, no policy decision, no release bundle, and no
evidence class. So this is a false user-facing number, **not** laundered
evidence, and it does not belong in `docs/KNOWN_HOLES.md`.

The profile gate is also unaffected: `--check predictable` rejects recursion
outright (`Report.lean:585` onward), so a program in the predictable profile has
no recursive functions and therefore no dropped edges. The defect is only
reachable on programs that the predictable profile already refuses — which is
precisely why it survived: the report is exercised most where it is right.

What makes it worth a number rather than a silent fix is that `stack:` is
evidence-shaped output on a project whose stated rule is that every construct is
`proved`, `enforced`, `reported`, `assumed` or `trusted`. `8 bytes` reads as a
measured bound. `unbounded` is the honest value and the compiler has everything
it needs to say so.

## Candidate fix

Make the DFS return an unboundedness flag rather than a number, and let it
propagate: a function is unbounded if it is itself recursive **or** if any
transitive callee is. Render `stack: unbounded (calls unbounded: fact)` — naming
the reached callee, since that is the fact the reader needs. The summary must
then report `Max stack bound: unbounded` (or omit the maximum) whenever any
reachable function is unbounded, instead of maximizing over the bounded subset.

Gate: `scripts/tests/check_stack_depth.sh` does not exist — this report has no
gate at all, which is how the defect shipped. It needs the fixture above
(direct recursion, mutual recursion, and a bounded caller of each), plus a
class-level assertion that no function reported with a finite `stack:` value can
reach a function reported `unbounded`. That assertion is checkable from the
report text against `--report recursion` output, and it catches the whole class
rather than this one call shape. A mutation restoring the `!isRecursive c`
filter must make the gate fail.
