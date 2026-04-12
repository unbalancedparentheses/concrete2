# Memory Guarantees

Status: active reference

This document separates what the checker enforces today, what is safe to claim publicly, and what still needs closure. For the full operational semantics, see [MEMORY_SEMANTICS.md](MEMORY_SEMANTICS.md).

For the value/reference categories, see [VALUE_MODEL.md](VALUE_MODEL.md).
For the broader safety model, see [SAFETY.md](SAFETY.md).

## What the Checker Enforces Today

These properties are mechanically enforced by `Check.lean` and verified by adversarial tests:

1. **No use-after-move.** A linear variable in `consumed` state cannot be read, borrowed, or moved. (Test: `error_memory_edge_use_after_move.con`)

2. **No forgotten linear values.** Every linear variable must be consumed or reserved (via `defer`) by scope exit. (Test: linearity tests across the suite)

3. **No borrow conflict.** Mutable borrows are exclusive; shared borrows are incompatible with mutable borrows. (Tests: `error_borrow_mut_conflict.con`, `error_double_mut_borrow.con`)

4. **No borrow escape.** References created by borrow blocks cannot be assigned to variables that outlive the block. (Tests: `error_borrow_escape.con`, `error_escape_return.con`, `error_escape_field.con`)

5. **No frozen-variable access.** A variable frozen by an active borrow block cannot be read, written, moved, or re-borrowed. (Test: `error_memory_edge_move_while_borrowed.con`)

6. **No cross-loop consumption.** A linear variable from an outer scope cannot be consumed inside a loop body. (Test: `error_memory_edge_loop_consume_outer.con`)

7. **No linear reassignment.** Linear variables cannot be reassigned. (Test: `error_memory_edge_linear_reassign.con`)

8. **Branch agreement.** If/else branches and match arms must agree on consumption of pre-existing linear variables. (Tests: `error_memory_edge_branch_disagree.con`, `error_memory_edge_if_no_else_consume.con`, `bug_int_match_disagree.con`)

9. **No skip past linear.** Break and continue cannot skip unconsumed linear variables. (Test: `error_break_linear_skip.con`)

10. **Trusted code does not relax linearity.** `trusted` permits pointer arithmetic and raw pointer operations but does not suppress ownership, borrow, or scope-exit rules.

## Public Claim That Is Safe Today

**For safe Concrete code (no `trusted`, no `with(Unsafe)`), the checker enforces:**

- No use of a value after it has been moved.
- No leak of a linear value — every owned resource is consumed or has deferred cleanup.
- No conflicting borrows — mutable access is exclusive, shared access precludes mutation.
- No dangling safe references — references cannot escape their borrow block.
- No silent reassignment of linear resources.
- Deterministic cleanup ordering via `defer` (LIFO).

**What this rejects at compile time:**

| Bug class | Enforcement mechanism |
|-----------|----------------------|
| Use-after-free | Linear value consumed by `free`/`destroy` → subsequent use is use-after-move |
| Double free | Linear value consumed once → second free is use-after-move |
| Memory leak | Linear value forgotten → scope-exit error |
| Dangling reference | Borrow block scoping → escape analysis |
| Data race (aliasing) | Mutable borrow is exclusive; owner is frozen during borrow |

## Where the Safe Claim Has Boundaries

These are honest boundaries, not bugs:

### Conservative (safe but restrictive)

- **Whole-value borrows only.** Borrowing a struct freezes the entire struct. Disjoint field borrows are not supported. This prevents some valid programs but never permits an invalid one.
- **Whole-array borrows only.** No per-element borrow tracking. Same rationale.
- **Scoped borrows only.** No Rust-style NLL or lifetime inference. References are confined to their borrow block. This is more restrictive than necessary but structurally sound.

### Outside the checker's reach

- **Raw pointers.** Once a value is behind `*mut T` / `*const T`, the checker does not track it. Raw pointer soundness is the responsibility of `trusted` code and is an audit concern.
- **Arena/bulk-free patterns.** If an arena is freed while references to its contents exist, the references dangle. The checker cannot see the arena-allocation relationship.
- **Cross-function reference use.** The checker trusts function signatures. If `fn foo(x: &T)` internally does something unsound with the reference (via `trusted`), the caller's checker does not detect it.
- **Concurrency.** The model assumes single-threaded execution. Shared-memory concurrency would require `Send`/`Sync`-like constraints that do not exist yet. This is an **explicitly deferred boundary**.

### Not yet proof-backed

The checker enforces the above properties, but:

- There is no formal proof of checker soundness.
- The guarantees are validated by adversarial tests and code review, not by a mechanized proof.
- The proof/evidence pipeline (ProofCore, obligations, diagnostics) does not yet cover memory model properties.

## Stronger Claim: Direction But Not Yet Justified

The goal is to eventually state:

**For safe Concrete code, there is no use-after-free, no double free, no dangling safe reference, and no invalid aliasing through safe references.**

This requires:

- ~~one checker-matching memory/reference semantics document~~ **done** — [MEMORY_SEMANTICS.md](MEMORY_SEMANTICS.md)
- ~~closure on hard edge cases~~ **done** — edge cases documented with status in MEMORY_SEMANTICS.md §13, adversarial tests for each, integer-match consumption bug fixed
- proof-facing articulation of the memory model (future: connect to ProofCore/obligations)
- formal checker soundness argument or mechanized proof (future)

## Why This Matters

Without this document, it is too easy to make either of two mistakes:

- understate the language by talking as if the checker does not already enforce a serious ownership model
- overstate the language by claiming the fully centralized safe-memory theorem before formal proof work is done

The right current position is:

**Concrete enforces a real ownership/borrow discipline with explicit cleanup and explicit trust boundaries. The enforced properties are documented, tested, and match the checker implementation. What remains is the proof-facing articulation that turns checker behavior into a formally backed guarantee.**
