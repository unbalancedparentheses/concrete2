# Safe-Memory Regression Checklist

Status: canonical tracking surface — one place for all memory/ownership hard cases, their checker behavior, test coverage, doc claims, proof status, and open gaps.

For the memory guarantee boundary, see [MEMORY_GUARANTEES.md](MEMORY_GUARANTEES.md).
For `&mut T` closure status, see [MUT_REF_CLOSURE.md](MUT_REF_CLOSURE.md).
For the public guarantee statement, see [GUARANTEE_STATEMENT.md](GUARANTEE_STATEMENT.md).

---

## 1. Field/Substructure Borrows

**Intended rule:** Borrowing a struct freezes the entire struct. No field-granular borrows. Field access through `&T` or `&mut T` auto-derefs without consuming the reference.

**Current checker behavior:** Whole-value freeze. `borrow mut x as r in R { ... }` freezes `x` entirely — no field of `x` can be read, written, moved, or re-borrowed inside the block.

**Test coverage:**
- `adversarial_memory_edge_field_borrow.con` — field access through borrow
- `adversarial_memory_edge_borrow_sequential.con` — sequential borrows of same owner
- `error_assign_frozen_by_borrow.con` — assign to frozen variable
- `error_borrow_assign_frozen.con` — assign inside borrow block
- `error_borrow_frozen.con` — access frozen owner
- `error_escape_field.con` — field-path escape
- `hardening_borrow_edge_cases.con` — mixed borrow patterns

**Doc claim:** MEMORY_GUARANTEES.md §"Where the Safe Claim Has Boundaries" — "Whole-value borrows only." MEMORY_SEMANTICS.md §5 — "no partial borrows."

**Proof-facing status:** Not in proof model. PExpr has no borrow/deref/field constructs.

**Open gaps:**
- No field-write through `&mut T` (`r.field = val`). Documented in MUT_REF_CLOSURE.md §5.
- No disjoint field borrow (two borrows of separate fields simultaneously). Deliberately conservative.

---

## 2. Array/Slice Element Borrows

**Intended rule:** Arrays are single linear values. Borrowing an array freezes the entire array. No per-element borrow tracking.

**Current checker behavior:** Whole-array freeze. Array indexing (`arr[i]`) returns the element type without consuming the array. No per-index ownership.

**Test coverage:**
- `adversarial_memory_edge_array_borrow.con` — array borrow basics
- `adversarial_linear_array.con` — linear array consumption
- `error_linear_array_leak.con` — linear array not consumed
- `bug_array_struct_field_mutation.con` — array + struct field interaction
- `bug_stack_array_borrow_copy.con` — array borrow copy semantics

**Doc claim:** MEMORY_SEMANTICS.md §6 — "no per-element borrows." MEMORY_GUARANTEES.md — "Whole-array borrows only."

**Proof-facing status:** Not in proof model. PExpr has no array constructs.

**Open gaps:**
- No array element access through `&mut T` (`r[i]` and `r[i] = val`). Documented in MUT_REF_CLOSURE.md §5.
- No slice splitting (disjoint sub-array borrows). Future work.

---

## 3. Control-Flow Joins

**Intended rule:** Both branches of if/else must agree on consumption of pre-existing linear variables. Match arms must agree. If-without-else cannot consume. Break/continue cannot skip unconsumed linear variables.

**Current checker behavior:** Fully enforced via `mergeVarStates` (if/else), `mergeMatchStates` (match), `checkNoBranchConsumption` (if-without-else), and break/continue scope-exit checks.

**Test coverage:**
- `adversarial_memory_edge_controlflow.con` — complex control flow
- `adversarial_memory_edge_match_agree.con` — match agreement
- `adversarial_deep_branch_linear.con` — deep nesting
- `adversarial_mut_ref_branch_both_consume.con` — both branches consume `&mut T`
- `adversarial_mut_ref_branch_neither.con` — neither branch consumes
- `error_memory_edge_branch_disagree.con` — if/else disagree
- `error_memory_edge_if_no_else_consume.con` — if-without-else consumes
- `error_branch_disagree.con` — basic branch disagree
- `error_deep_branch_disagree.con` — deep nesting disagree
- `error_enum_match_disagree.con` — match arm disagree
- `error_mut_ref_branch_disagree.con` — `&mut T` branch disagree
- `bug_int_match_disagree.con` — integer match disagree (regression)

**Doc claim:** MEMORY_SEMANTICS.md §7. MEMORY_GUARANTEES.md property 8.

**Proof-facing status:** If/then/else is in PExpr. Match is not.

**Open gaps:** None known. This area is fully enforced and well-tested.

---

## 4. Owner Invalidation Patterns

**Intended rule:** A variable frozen by a borrow block cannot be read, written, moved, or re-borrowed. A consumed variable cannot be used. A reserved variable cannot be moved. Trusted code does not relax these rules.

**Current checker behavior:** Fully enforced. `variableFrozenByBorrow`, `variableUsedAfterMove`, `variableReservedByDefer`, `cannotMoveLinearBorrowed`, `assignToBorrowed`, `assignToFrozen`.

**Test coverage:**
- `error_memory_edge_move_while_borrowed.con` — move frozen variable
- `error_memory_edge_use_after_move.con` — use after move
- `error_memory_edge_linear_reassign.con` — reassign linear
- `error_borrow_after_move.con` — borrow consumed variable
- `error_use_after_move.con` — basic use-after-move
- `error_assign_overwrites_linear.con` — overwrite linear
- `error_trusted_use_after_move.con` — trusted code respects linearity
- `error_trusted_linear_reassign.con` — trusted code respects no-reassign
- `error_trusted_leak.con` — trusted code must consume linear values

**Doc claim:** MEMORY_GUARANTEES.md properties 1, 5, 7, 10. MEMORY_SEMANTICS.md §1, §10, §11.

**Proof-facing status:** Not in proof model (no mutation/borrow constructs in PExpr).

**Open gaps:**
- `assignToBorrowed` — error exists but is currently unreachable (freeze check fires first). See §9.
- Arena/bulk-free invalidation — outside checker's reach. Documented in MEMORY_GUARANTEES.md.

---

## 5. `&mut T` Feature Gaps

**Intended rule:** `&mut T` borrow-block refs are linear, consumed on function call. Function parameter `&mut T` refs are reborrowable. Deref read/write does not consume. See MUT_REF_SEMANTICS.md.

**Current checker behavior:** Two-kind model enforced. Borrow-block refs tracked in `env.borrowRefs`. Function parameter refs not in `borrowRefs`, so not consumed on call.

**Test coverage:** 11 adversarial + 8 error tests (see §5 in inventory above).

**Doc claim:** MEMORY_GUARANTEES.md property 11. MUT_REF_SEMANTICS.md. MUT_REF_CLOSURE.md.

**Proof-facing status:** Not in proof model.

**Open gaps (documented in MUT_REF_CLOSURE.md §5):**
- **Reborrowing** (`&mut *r`) — no syntax or checker support.
- **Field write through `&mut T`** (`r.field = val`) — no codegen (needs GEP through pointer).
- **Array element access through `&mut T`** (`r[i]`, `r[i] = val`) — no checker or codegen support.
- **`&mut T` in struct fields** — storing a `&mut T` inside a struct; struct becomes linear.
- These are all future work, explicitly outside the current strong claim.

---

## 6. Cleanup/Leak-Boundary Cases

**Intended rule:** Every linear variable must be consumed or reserved by scope exit. `defer` marks variables as `reserved` (read-only, cannot move). Defers run LIFO. Break/continue must not skip unconsumed linear variables.

**Current checker behavior:** Fully enforced. `checkScopeExit` accepts only `.consumed` and `.reserved`. `defer` sets `.reserved`. Break/continue checks enforce scope cleanup.

**Test coverage:**
- 13 adversarial defer tests (defer_basic through complex_defer_destroy)
- 16 test_defer_* suite (block scope, break, continue, early return, loops, nesting)
- `error_memory_edge_defer_then_move.con` — move reserved variable
- `error_defer_move.con` — move after defer
- `error_defer_linear_reuse.con` — reuse deferred variable
- `error_heap_leak.con`, `error_heap_leak_no_free.con` — heap leak detection
- `error_trusted_leak.con` — trusted code must consume
- `error_destroy_reserved.con` — destroy reserved variable
- `error_break_linear_skip.con` — break skips unconsumed

**Doc claim:** MEMORY_GUARANTEES.md property 2, "No-Leak Guarantee Boundary." MEMORY_SEMANTICS.md §9.

**Proof-facing status:** Not in proof model (defer/cleanup not in PExpr).

**Open gaps:**
- `continueSkipsUnconsumedLinear` — **covered** by `error_continue_skip_linear.con`.
- `breakInDefer` / `continueInDefer` — currently unreachable (see §9).
- Arena/FFI/circular-ownership leak paths — outside checker reach. Documented in MEMORY_GUARANTEES.md "No-Leak Guarantee Boundary."

---

## 7. Borrow Escape

**Intended rule:** References created by borrow blocks cannot be assigned to variables outside the block.

**Current checker behavior:** Enforced via `referenceEscapesBorrowBlock` check on assignments.

**Test coverage:**
- `error_borrow_escape.con` — basic escape
- `error_escape_return.con` — escape via return
- `error_escape_field.con` — escape via field storage

**Doc claim:** MEMORY_GUARANTEES.md property 4. MEMORY_SEMANTICS.md §4.

**Proof-facing status:** Not in proof model.

**Open gaps:** None known.

---

## 8. Loop Consumption

**Intended rule:** Linear variables from outer scopes cannot be consumed inside loop bodies. Linear variables declared inside loops follow normal scope rules per iteration.

**Current checker behavior:** Enforced via `loopDepth` tracking in `consumeVar`.

**Test coverage:**
- `error_memory_edge_loop_consume_outer.con` — outer linear consumed in loop
- `error_loop_consume.con` — basic loop consumption
- `error_mut_ref_loop_consume.con` — `&mut T` in loop
- `error_break_linear_skip.con` — break skips linear
- `adversarial_mut_ref_loop_deref.con` — deref in loop (allowed)
- `adversarial_for_loop_linear.con` — linear in for loop

**Doc claim:** MEMORY_GUARANTEES.md property 6. MEMORY_SEMANTICS.md §7.

**Proof-facing status:** Not in proof model (no loops in PExpr).

**Open gaps:**
- `continueSkipsUnconsumedLinear` — **covered** by `error_continue_skip_linear.con`.

---

## 9. Error Kind Coverage Status

### Covered by new tests

| Error kind | Test file | Status |
|------------|-----------|--------|
| `continueSkipsUnconsumedLinear` | `error_continue_skip_linear.con` | **Covered** |
| `cannotMutBorrowImmutable` | `error_mut_borrow_immutable.con` | **Covered** |

### Currently unreachable (defensive code)

These error kinds exist in `Check.lean` but cannot be triggered in the current model:

| Error kind | Why unreachable | Notes |
|------------|-----------------|-------|
| `breakInDefer` | `inDeferBody` flag (Check.lean:67) is never set to `true`. Defer takes a single call expression, not a block — break/continue cannot appear syntactically. | Defensive for future `defer { ... }` block syntax. |
| `continueInDefer` | Same as `breakInDefer`. | Same. |
| `assignToBorrowed` | Inside a borrow block the owner is frozen (`assignToFrozen` fires first at line 1842). Outside a borrow block there are no active borrow refs. The `activeBorrowRefs` check (line 1848) is shadowed by the freeze check. | Would become reachable if borrow refs could exist outside borrow blocks. |
| `variableAlreadyMutBorrowed` | In borrow block creation (line 2010), the freeze check (`variableFrozenByBorrow`, line 2008) fires first since the owner is frozen by an outer borrow. | Would become reachable with non-block-scoped borrows. |

These are not bugs — they are defensive checks for constructs that the current model does not permit but that future extensions might introduce.
