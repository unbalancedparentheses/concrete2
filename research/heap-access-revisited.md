# Heap Access Revisited: Is `(&p).x` the Right Choice?

**Status:** Decided — keep Option B (explicit borrow) with `(&p).x`
**Affects:** Phase 5 (Allocator system), Phase 6 (Borrow regions)
**Date:** 2026-03-07

## Context

In [heap-ownership-design.md](heap-ownership-design.md), we decided on Option B (explicit borrow) for accessing `Heap<T>` values. This means:

```
let p: Heap<Point> = alloc(Point { x: 1.0, y: 2.0 }) with(Alloc = arena);
defer destroy(p);

let x: Float64 = (&p).x;           // must borrow to access
```

Instead of transparent access (Option A):

```
let x: Float64 = p.x;              // transparent, like Zig/Rust
```

The question: after researching how other languages handle this, is `(&p).x` still the right call?

---

## How Other Languages Handle Heap Access

| Language | Syntax | Visual marker? | Verbosity |
|----------|--------|---------------|-----------|
| **Rust** `Box<T>` | `box_val.field` | None — auto-deref, looks identical to stack | Very low |
| **Zig** `*T` | `ptr.field` | None — one level auto-deref for structs | Low |
| **Austral** `Pointer[T]` | `!(ref->field)` + borrow block | Yes — `->`, `!`, `borrow` blocks | High |
| **C++** `unique_ptr<T>` | `uptr->field` | Yes — `->` vs `.` | Moderate |
| **Concrete** `Heap<T>` | `(&p).field` | Yes — `(&p)` prefix | Low-moderate |

### Codegen reality

All five languages generate **identical machine code** for the actual field access: load pointer, then load field at offset. The only difference is syntax.

For stack values, all five generate: load field from known stack offset (one instruction).
For heap values, all five generate: load pointer from stack, then load field from pointer + offset (two instructions).

The auto-deref (Rust, Zig) and explicit deref (`(&p)`, `->`, `!`) are purely compile-time — zero runtime cost difference.

---

## Revisiting the Arguments

### Why we chose Option B (explicit borrow)

From [heap-ownership-design.md](heap-ownership-design.md):

1. **LLM-written code:** Writing cost is zero, reading cost is the bottleneck. `(&p).x` tells the reader "this touches the heap."
2. **Greppability:** Every heap access has a visible marker — you can grep for all heap dereferences.
3. **No special compiler rules:** `Heap<T>` is opaque, borrowing works through existing `&` mechanism.

### What the research shows

1. **Zig and Rust choose transparency** (no visual marker). Both are wildly successful systems languages. The lack of visual marker for heap access has not been a significant pain point in either community.

2. **Austral's extreme explicitness is genuinely painful.** `!(ref->sun->pos->x)` with borrow blocks everywhere — even Austral's creator acknowledges the verbosity.

3. **C++'s `->` is moderate** and has survived 40+ years. The `.` vs `->` distinction is the most battle-tested "heap access marker" in programming history.

4. **Concrete's `(&p).x` is between Zig/Rust and Austral** on the explicitness spectrum:

```
Rust:    p.x             (most transparent)
Zig:     ptr.x           (transparent)
C++:     ptr->x          (visual marker, minimal overhead)
Concrete: (&p).x         (visual marker, slightly more overhead)
Austral: !(ref->field)   (most explicit)
```

### The real question

Does the LLM argument still hold? Let's be precise:

**What LLMs struggle with (that explicit borrow helps):**
- Nothing, actually. LLMs don't struggle with `p.x` vs `(&p).x`. They struggle with implicit Drop (solved by `defer`), lifetime elision (solved by no lifetime params), and trait dispatch (solved by no operator overloading).

**What explicit borrow DOES help with:**
- Human code review: "this line touches the heap" is visible without checking declarations
- Grep-based auditing: `grep '(&' ` finds heap accesses (but this is a weak grep pattern)
- Static analysis: heap vs stack access is syntactically distinct

**What explicit borrow COSTS:**
- Visual noise: `(&p).x` repeated dozens of times in heap-heavy code
- Parentheses: `(&p).x` requires parentheses because `&p.x` would parse as `&(p.x)` — borrowing the field, not the Heap wrapper
- Mental overhead: programmers must remember that `Heap<T>` needs borrowing, unlike every other struct

---

## Reconsidering the Options

### Keep Option B: `(&p).x` (current choice)

```
let x: Float64 = (&p).x;
let y: Float64 = (&p).y;
let sum: Float64 = (&p).x + (&p).y;

borrow p as pr in R {
    let x: Float64 = pr.x;
    let y: Float64 = pr.y;
    compute(pr);
}
```

Verdict: Mildly verbose for single accesses, borrow blocks help for multiple accesses. The `(&p)` parentheses are the main annoyance.

### Switch to Option A: `p.x` transparent (Zig/Rust style)

```
let x: Float64 = p.x;
let y: Float64 = p.y;
let sum: Float64 = p.x + p.y;
compute(&p);
```

Verdict: Clean. But you can't tell heap from stack at the access site. The type `Heap<Point>` is visible at declaration, allocation, and destruction — just not at field access.

### New Option C: Dot-through-borrow `p.x` with compiler rule

Allow `p.x` on `Heap<T>` as sugar for `(&p).x`. The compiler auto-inserts the borrow for field access only. But NOT for passing to functions — you still write `(&p)` or `borrow` to get a reference.

```
let x: Float64 = p.x;          // OK: sugar for (&p).x
let y: Float64 = p.y;          // OK: sugar for (&p).y
compute(&p);                     // still need explicit borrow for function args
p.x = 3.0;                      // OK: sugar for (&mut p).x = 3.0
```

This is a middle ground:
- Field access (the most common operation) is transparent
- Function arguments still require explicit borrow (visible in code)
- The type `Heap<T>` at the declaration tells you it's heap-allocated
- `alloc()` and `destroy()` are explicit
- Only field access is transparent — not method calls, not function arguments

Verdict: Pragmatic. Reduces the most common source of verbosity while keeping borrows visible for function calls.

---

## Analysis: What Actually Matters for Auditability

When auditing code for heap usage, what do you actually need to see?

1. **Where is memory allocated?** → `alloc(...)` — always visible
2. **Where is memory freed?** → `destroy(p)` or `defer destroy(p)` — always visible
3. **What function signatures require heap?** → `with(Alloc)` — always visible
4. **Which variables hold heap data?** → `Heap<T>` in the type — always visible
5. **Where are individual heap field accesses?** → This is what `(&p).x` shows

Items 1-4 are the important audit points. Item 5 is low-value — knowing that line 47 reads `p.x` from the heap (vs. stack) doesn't change your security audit or performance analysis. The allocation site, deallocation site, and function signatures are what matter.

Put differently: if you know a variable is `Heap<Point>`, every `.x` access on it is a heap access. The type tells you this. The per-access marker `(&p)` is redundant information.

---

## The LLM Argument, Revisited

The original argument was: "In an LLM world, writing is free and reading is the bottleneck. Option B is better for reading."

But the research and analysis show:
1. LLMs don't struggle with `p.x` vs `(&p).x` — they struggle with implicit Drop and lifetime elision (already solved)
2. The per-access visual marker `(&p)` provides low-value information (the allocation/deallocation sites and types provide the high-value information)
3. The borrow block form (`borrow p as pr in R`) remains valuable for multi-statement borrows and is still available

The LLM argument for Option B is weaker than initially thought. The LLM argument for explicitness is strong for **allocation, deallocation, capabilities, and destruction** — but not for individual field accesses.

---

## Recommendation

**Keep Option B (`(&p).x`) as the default.** Reasons:

1. **Consistency is more important than convenience.** If `Heap<T>` is opaque and requires borrowing for function arguments, having field access also require borrowing is consistent. Having field access be transparent while function arguments require borrowing is an inconsistency that LLMs and humans must learn as a special case.

2. **The borrow block alleviates the verbosity.** For code that does multiple heap accesses, `borrow p as pr in R { pr.x; pr.y; compute(pr); }` is clean. The `(&p).x` form is only needed for one-off accesses.

3. **The parentheses are mild.** `(&p).x` is not `!(ref->sun->pos->x)`. It's one extra character pair. The Zig/Rust transparent approach saves typing but Concrete's philosophy explicitly trades writing convenience for reading clarity.

4. **It's easy to relax later, hard to tighten.** If Concrete starts with explicit borrow and users/LLMs find it unbearable, we can add transparent field access as sugar later (Option C). But if we start transparent and later want explicit, that's a breaking change to every program.

5. **We already decided this.** Reopening settled decisions is expensive. The arguments haven't changed enough to justify the churn.

However, **if after implementing Phase 5 and writing real code, the `(&p).x` pattern proves genuinely painful, revisit Option C** (transparent field access only, explicit borrow for function args). This can be added as a non-breaking change.

---

## Open Questions

1. **Should we document Option C as a future escape valve?** "If verbosity is unbearable, we can add `p.x` as sugar for `(&p).x` without breaking existing code."
2. **Borrow block naming:** Is `borrow p as pr in R { ... }` the best syntax? Could it be shorter? `let pr = &p { ... }`? This is a Phase 6 question.
