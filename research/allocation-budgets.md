# Allocation Budgets

Status: research

## Problem

Concrete already gates allocation behind `with(Alloc)`. But `Alloc` is binary — either you can allocate or you can't. For embedded, real-time, and safety-critical code, the useful questions are finer:

- Does this function allocate at all? (`NoAlloc`)
- Does this function allocate at most N bytes? (`BoundedAlloc(N)`)
- Does this function only allocate on the stack? (no heap)

No mainstream systems language answers these at the type level today.

## What Already Exists

- `with(Alloc)` capability on function signatures
- `--report alloc` showing which functions allocate and how
- `--report authority` with BFS call-chain tracing
- Intrinsic-level mapping: `vec_new`, `vec_push`, `alloc`, `free` → `Alloc` capability
- CoreCheck validates capability requirements transitively

## Design Options

### Option A: Refine Alloc into sub-capabilities

```con
fn parse_keyword(s: &String, pos: i32) -> i32 { ... }              // pure, no Alloc
fn build_message(code: i32) with(Alloc) -> String { ... }          // allocates
fn push_element(v: &mut Vec<i32>, x: i32) with(BoundedAlloc) { ... } // bounded
```

`NoAlloc` is just the absence of `Alloc` — already works. The new piece is `BoundedAlloc` as a sub-capability of `Alloc` that means "allocates, but provably bounded."

### Option B: Allocation profiles as compiler attributes

```con
#[no_alloc]
fn parse_keyword(s: &String, pos: i32) -> i32 { ... }

#[alloc_budget(256)]
fn process_request(req: &Request) with(Alloc) -> Response { ... }
```

Profiles are checked by the compiler but don't change the capability signature. This keeps the capability system simple.

### Option C: Report-only (no enforcement)

Extend `--report alloc` to classify functions as:
- pure (no allocation)
- bounded (all allocation paths have known upper bounds)
- unbounded (contains loops with allocation, recursion with allocation, etc.)

This is the cheapest option and may be sufficient for most audit use cases.

## Recommendation

**Start with Option C** (report-only classification), then graduate to **Option A** (sub-capabilities) once the report proves valuable.

Option C is ~200-300 lines in Report.lean. It leverages the existing call graph and intrinsic mapping. The classification algorithm:
1. Walk the call graph from each function
2. If no path reaches an allocation intrinsic → `NoAlloc`
3. If all allocation paths are inside non-recursive, bounded-iteration code → `Bounded`
4. Otherwise → `Unbounded`

Option A requires ~800-1200 lines across Check.lean, CoreCheck.lean, Report.lean, and stdlib annotations. The hard part is defining how budgets compose across function calls and what "bounded" means precisely.

## Difficulty Assessment

| Level | Effort | What you get |
|-------|--------|-------------|
| Report-only classification | 1-2 days | `--report alloc` shows NoAlloc/Bounded/Unbounded per function |
| Sub-capability enforcement | 1-2 weeks | Compile-time rejection of allocation in NoAlloc contexts |
| Byte-level budgets | 3-4 weeks | `BoundedAlloc(N)` with compositional accounting |

### What makes this tractable

- Capability infrastructure is parametric — adding new capability names is trivial
- `capsContain` in Shared.lean already handles arbitrary capability checking
- Post-monomorphization, all calls are direct — no dynamic dispatch complicates analysis
- Intrinsic.lean already maps every allocation operation to `Alloc`

### What makes byte-level budgets hard

- Composition: if `f` allocates at most 100 bytes and calls `g` which allocates at most 50, the budget is 150 — but only if `g` is called once. Loops multiply.
- Realloc: `vec_push` may or may not trigger realloc depending on current capacity. Bounding this requires knowing the initial capacity and number of pushes.
- String operations: `string_append` growth depends on input length. True bounds require dependent types or runtime checks.

## Interaction with Other Features

- **Arena allocation**: Arenas have a fixed budget by construction (arena size = budget). `BoundedAlloc` + arenas compose naturally.
- **defer**: No interaction — defer is about cleanup timing, not allocation.
- **Proof story**: `NoAlloc` is directly provable in Lean (function body contains no allocation intrinsic calls). `BoundedAlloc` requires more sophisticated reasoning.
- **High-integrity profile**: Allocation budgets are a natural building block for restricted execution profiles.

## Evidence Needed

The JSON parser's pure helper functions (`skip_ws`, `is_digit`, `is_ws`, `match_keyword`) are already NoAlloc by construction. A report that proves this mechanically would immediately add audit value. The parser functions (`parse_string`, `parse_value`) allocate but their allocation is bounded by input length — classifying this is harder but valuable.
