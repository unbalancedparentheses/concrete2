# Ownership Model: Copy, Linear, Destroy (design record)

**Superseded as the normative text (2026-10-23).** The ownership rules are stated, with stable
IDs and runnable examples, in [docs/spec/ownership.md](../spec/ownership.md): Copy (OWN-D1), use
after move (OWN-1), consumption at every exit (OWN-2), branch agreement (OWN-3), loops (OWN-4),
discards (OWN-5 to OWN-7), sub-place reads (OWN-8), overwrites (OWN-9), mutability (OWN-10),
moves in code that may not run (OWN-11), `defer` (OWN-12), explicit destruction (OWN-13), Copy
declarations (OWN-14) and value flow per constructor (OWN-15). Where this document and the spec
differ, the spec governs. This document keeps the reasoning, in particular why the language is
linear rather than affine, and the history of each rule.

## The one law

Concrete is linear: a non-Copy value is used exactly once and never silently disappears. The
rules that make this precise are the ownership chapter of the specification, linked below; this
section only orients.

## Three distinct concepts (do not conflate them)

The bugs this model fixed all came from treating these as one:

| concept | question it answers | stated in |
|---|---|---|
| **Copy** | may I *duplicate* it (use it twice)? | [OWN-D1](../spec/ownership.md#OWN-D1), [OWN-14](../spec/ownership.md#OWN-14), [TYPE-14](../spec/types.md#TYPE-14) |
| **linear** (= non-Copy) | must I *account for* it exactly once? | [OWN-1](../spec/ownership.md#OWN-1), [OWN-2](../spec/ownership.md#OWN-2) |
| **Destroy** | is there an *explicit consuming cleanup* verb? | [OWN-13](../spec/ownership.md#OWN-13) |

Two things follow that are easy to get wrong. `Copy` answers "duplicable", not "droppable": an
`&mut T` is not duplicable, and it is linear here because the rule is about accounting, not only
aliasing. And `Destroy` is not "the reason a value is linear": a permit, receipt or proof witness
owns no heap and has no `Destroy`, yet must not vanish. `Destroy` only names the cleanup of the
linear values that need one.

## Where each rule is stated

| topic | rule |
|---|---|
| use after move; what moves (`let`, arguments, `return`, scrutinees, stores, literals) | [OWN-1](../spec/ownership.md#OWN-1), [OWN-15](../spec/ownership.md#OWN-15) |
| every owned linear binding (parameters included) is consumed before every exit | [OWN-2](../spec/ownership.md#OWN-2) |
| branches agree; diverging branches are exempt | [OWN-3](../spec/ownership.md#OWN-3) |
| loops do not consume outer values | [OWN-4](../spec/ownership.md#OWN-4) |
| `_`, `let _`, statement discards, `discard(e)` | [OWN-5](../spec/ownership.md#OWN-5), [OWN-6](../spec/ownership.md#OWN-6), [OWN-7](../spec/ownership.md#OWN-7) |
| no by-value read of a non-Copy part of a place | [OWN-8](../spec/ownership.md#OWN-8), [MEM-4](../spec/memory.md#MEM-4) |
| no overwrite of a live linear value | [OWN-9](../spec/ownership.md#OWN-9) |
| `mut`, moves in code that may not run, `defer` | [OWN-10](../spec/ownership.md#OWN-10), [OWN-11](../spec/ownership.md#OWN-11), [OWN-12](../spec/ownership.md#OWN-12) |
| one binding per name; state per binding identity | [SCOPE-1](../spec/scope.md#SCOPE-1) |
| guards are read-only | [PAT-4](../spec/patterns.md#PAT-4) |
| destructuring `let`, `let ... else`, `if let` / `while let` over linear values | [PAT-5](../spec/patterns.md#PAT-5), [PAT-6](../spec/patterns.md#PAT-6) |
| functional update `S { ..base }` copies only Copy fields | [TYPE-7](../spec/types.md#TYPE-7) |

### Notes that are not rules

- **Parameters are owned locals (H17, ruled 2026-07-05).** The caller moved the value in, so the
  callee holds the obligation; there are no terminal parameter sinks, and a terminal consumer
  destructures into Copy raw parts (`fn destroy(self) { let File { fd } = self; }`). `&mut T`
  parameters are borrows: exclusive, with no consume obligation.
- **Getting rid of a value on purpose.** A Copy value may simply be dropped. A linear one is
  consumed (passed on, returned, `destroy()`ed) or destructured exhaustively with its parts handed
  off; a `_` inside an exhaustive match may ignore a Copy payload, and a resource payload is bound
  and released (`Option::Some { f } => { f.destroy(); }`).
- **Generic helpers that return one of two linear arguments** (`max<T>(a, b)`) always leak the
  other, so they require `T: Copy` (`std.math.max/min/clamp`, the `std.test` asserts).
- **A loop that never ends, or `abort()`,** is a block whose end is unreachable, so it need not
  consume its locals: a server's accept loop legitimately holds a resource for ever.

## Why linear, not affine (the decision, 2026-07-01)

Concrete had drifted into using **two** predicates for "may this disappear": named
bindings used `!isCopy` (linear), but the `_` wildcard used `ownsResource` (affine —
it allowed a resource-free non-Copy value to be silently dropped). The result was an
incoherent middle band: `match e { _ => {} }` would drop an `Option<i32>` or a plain
view struct, while the *same value bound to a name* required consumption. Naming a
value was stricter than `_`-ing it.

Three coherent fixes were on the table:

1. **Copy-centric** — drop iff `Copy`. Correct axis, but needs conditional `Copy` for
   generics or `Option<i32>` feels artificially linear.
2. **Resource-centric** — must-consume iff `ownsResource`. Too weak: it cannot express
   affine/protocol **tokens** that own no heap yet must not vanish — central to a
   capability-based language.
3. **Linear (chosen)** — non-Copy = used exactly once; `_` ignores only `Copy`.
   Expresses tokens natively (a token is a linear value that owns nothing), one law,
   no implicit weakening.

This is textbook substructural typing: `Copy` is **contraction** (may use more than
once), discardability is **weakening** (may use zero times); a *linear* type permits
neither. Precedents: **Austral** (explicit linear, no implicit `Drop` — the closest
sibling) and **Linear Haskell** (multiplicities). Unlike Rust — which is affine with
an *implicit* `Drop` that runs cleanup for you — Concrete makes cleanup explicit, so
it must reject silent disappearance rather than paper over it with a destructor.

Aggregate drop glue does not change this rule. If source code explicitly consumes an
owner (`v.drop()` / `defer v.drop()` / `destroy(v)`), the implementation of that
operation may recursively destroy the live owned fields or collection elements. The
outer disposal decision remains visible in source; the compiler still must not insert
an implicit scope-end destructor for an otherwise-live linear value.

## Conditional `Copy` (history, 2026-07-05)

Superseded by decision D6 (2026-10-23), now [TYPE-14](../spec/types.md#TYPE-14): whether an
instantiation is Copy is decided from the declaration alone, from its type arguments rather than
by inspecting fields after substitution. What follows records the conditional mark as it landed.


`Copy` on a generic declaration is a *conditional* mark: the instantiation is `Copy`
iff every field/payload is `Copy` after substitution. `Option<T>` is `Copy` iff `T`
is; `Result<T, E>` iff `T` and `E` are; `struct Copy Box<T>` iff `T` is; arrays were
always structural (`[T; N]` Copy iff `T`). A catch-all `_` over `Option<i32>` is
valid *for the right reason* — the whole value is genuinely unrestricted — while
`Option<File>` stays linear. A non-qualifying instantiation of a `Copy`-marked
generic is **demoted to linear, not an error** (Mono demotes specializations to a
fixpoint; `verifyCopyFieldsPostMono` asserts the invariant "isCopy ⇒ all fields
Copy" machine-wide). The hard rule is preserved: no Copy value ever contains a
non-Copy one. This is a convenience layered on the linear rule, **not a
foundation**; the linear rule stands without it.

## Where it lives

- Predicate: `Concrete/Check/Check.lean` — `isCopyType` (the `Copy` decision) and the
  discard/consume checks that key on it (`checkScopeExit`, the per-block
  `checkBlockLocalsConsumed`, the match-arm `_` gate, the `Stmt.expr` discard check).
- Move-through-let and the divergence helpers (`blockNonTerminating`) are in the same
  file.
- Diagnostics: `E0205` use-after-move, `E0208` never-consumed, `E0286` discarded
  must-use, `E0287` discarded non-Copy statement, `E0288` `_`-drops-non-Copy
  (`wildcardDiscardsNonCopy`), `E0289` `let _` removed.
- Gates: `scripts/tests/check_linear_discard.sh` (the `_`/discard rules),
  `scripts/tests/check_linear_nested_scope.sh` (nested-scope + move-through-let +
  divergence), `scripts/tests/check_linear_conservation.sh` (every value-flow site
  moves a linear value exactly once — array-lit/struct-lit/destructure/arg/return/
  match; the anti-duplication backstop), `scripts/tests/check_ignored_result.sh`
  (`Result`/`Option` must-use).
- Related docs: `docs/verification/KNOWN_HOLES.md` (H6 and H9 entries), `docs/language/IGNORED_RESULT.md`.
