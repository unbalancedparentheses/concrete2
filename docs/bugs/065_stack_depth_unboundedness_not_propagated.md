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

**Corrected 2026-07-31, same day as filing: an earlier draft of this section
called the defect "contained to the report". That was wrong.** It rested on

```
$ grep -rn 'stackBound\|stack_bound' Concrete/ Main.lean
Main.lean:2299:      IO.println (Report.stackDepthReport validCore.coreModules locMap pc)
```

which scoped the search to Lean sources. Enforcement of this number lives in
**shell**, and there are three consumers:

| Consumer | What it does with the max |
|---|---|
| `scripts/tests/check_policy.sh:161` | greps `Max stack bound:\s*[0-9]+` and enforces `[policy] max_stack_bytes = N` against it |
| `scripts/tests/check_assumptions.sh:128` | same, for `[allocation] stack_max_bytes = N` |
| `scripts/tests/capture_release_bundle.sh:128` | greps the same line into the release bundle as `evidence.max_stack_bytes` |

So the number is a **policy verdict** and a **published evidence field**, not
report-only. `docs/project/POLICY_FILES.md:74` and `docs/verification/ASSUMPTION_FILES.md:95` both
list it under "Enforced fields" — correctly, since the gates implement it; the
key is simply absent from `Concrete/`, which is what the first grep saw.

The guard that should catch this cannot fire. `check_policy.sh` fails closed when
the report has **no** max bound:

```bash
if [ -z "$actual_max" ]; then
  echo "  FAIL max_stack_bytes=$max_stack but stack-depth report has no max bound"
```

but the defect's effect is that a finite `Max stack bound:` is *always* printed —
the summary maximizes over the bounded subset, which is never empty. So the
fail-closed branch is unreachable on precisely the programs that need it, and a
budget would pass on a program with unbounded stack rather than refuse it.

Not live today, and the reason matters: all five projects that set the budget —
`crypto_verify`, `parse_validate`, `fixed_capacity`, `hmac_sha256`,
`constant_time_tag`, three of them flagships — are recursion-free
(`--report recursion` reports 0 direct and 0 mutual for each), so every enforced
number is currently correct. But that is a property of the corpus, not of the
mechanism: the first recursive function to enter a budgeted project converts a
silent pass into a published `evidence.max_stack_bytes` that is false.

Still not filed in `docs/verification/KNOWN_HOLES.md`, because no shipped claim is false
today. The judgement call is narrow and worth stating plainly rather than
burying: if a recursive function ever lands in one of those five projects before
this is fixed, this becomes an H-numbered evidence hole with no further
investigation required.

The profile gate is unaffected for the same corpus reason: `--check predictable`
refuses recursion outright (`Report.lean:585` onward), so a predictable-profile
program has no dropped edges. That is also why the defect survived — the report
is exercised most where it happens to be right.

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

The policy path needs its own leg, because fixing the report alone would trip it:
once an unbounded program prints no numeric max, `check_policy.sh`'s
`-z "$actual_max"` branch fires and the budget fails closed — which is the
correct behaviour and must be asserted deliberately rather than discovered by a
red release gate. Add a negative project that sets `max_stack_bytes` and contains
recursion, and assert `check_policy.sh` REFUSES it. Assert the same for
`check_assumptions.sh`, and that `capture_release_bundle.sh` writes something
other than a number for `evidence.max_stack_bytes` — its fallback is already
`"?"`, so confirm consumers of the bundle tolerate it, or give the field an
explicit `"unbounded"` value rather than a punctuation mark.
