# Memory Guarantees

Status: active reference

This document separates three things that are easy to blur together:

1. what Concrete already enforces today
2. what guarantee is reasonable to state publicly today
3. what still needs semantic and proof-facing closure before the strongest claim is justified

For the value/reference categories, see [VALUE_MODEL.md](VALUE_MODEL.md).
For the broader safety model, see [SAFETY.md](SAFETY.md).

## Already Enforced Today

Concrete already has a real checker-backed ownership and borrow discipline for safe code.

The current implementation enforces:

- linear ownership discipline
- use-after-move rejection
- unconsumed linear-value rejection at scope exit
- mutable-vs-shared borrow conflict checking
- borrow escape checking for borrow blocks
- explicit cleanup via `destroy(...)` / `defer`
- trusted/unsafe separation without relaxing linearity

This is not only a documentation claim. It is backed by checker logic and targeted tests for:

- linearity violations
- borrow errors
- use-after-move
- unconsumed values
- borrow escape
- defer/cleanup interaction

## Public Claim That Is Safe Today

The safe public claim today is:

**Concrete already enforces a real ownership/borrow discipline for its safe subset, with explicit cleanup and explicit unsafe/trusted boundaries.**

More concretely, the language is already trying to reject:

- use-after-free through the safe ownership model
- double free through linear ownership and explicit destruction
- leaks from forgotten linear values
- dangling safe references from borrow-block escape
- invalid mutable/shared borrow overlap in the checked safe subset

This is a strong design claim about the current checker.

## What Is Not Yet Fully Closed

The remaining gap is not "invent ownership." The remaining gap is to make the exact guarantee boundary centralized, explicit, and proof-facing.

The still-open closure work is:

- one checker-matching memory/reference semantics document
- one tighter safe-subset theorem/contract statement
- closure on harder edge cases
- proof/evidence integration for the memory model

### Hard Edge Cases Still Needing Centralized Closure

These areas are the ones that need one explicit, project-wide statement rather than scattered rules:

- field and substructure borrows
- array/slice element borrows
- borrowed values across control-flow joins
- heap-owner invalidation patterns such as arena reset/free-style APIs
- future concurrency interaction
- pointer/reference boundary cases
- destruction with outstanding borrows

The checker already covers many practical cases. What is missing is the final consolidated semantics and public guarantee wording for all of them together.

## Stronger Claim Not Yet Ready

The project is not yet ready to state the strongest public theorem-like claim in one centralized place, for example:

**For safe Concrete code, there is no use-after-free, no double free, no dangling safe reference, and no invalid aliasing through safe references.**

That is the direction of the design, but the exact public statement still needs:

- the explicit memory/reference semantics item in the roadmap
- the proof-facing articulation of that model
- closure on the hard edge cases above

## Why This Matters

Without this document, it is too easy to make either of two mistakes:

- understate the language by talking as if the checker does not already enforce a serious ownership model
- overstate the language by claiming the fully centralized safe-memory theorem before the remaining semantic closure work is done

The right current position is:

**Concrete already has the core ownership/borrow design and a real checker. What remains is the final semantic consolidation and proof-facing articulation that turns checker behavior into the strongest explicit public guarantee.**
