# Execution Cost Tracking

Status: research

## Problem

Safety-critical and real-time code needs guarantees about execution time and resource consumption. Concrete's explicit capability model already answers "does this function allocate?" and "does this function do I/O?" but can't answer:

- Does this function terminate in bounded time?
- How many operations does this function perform in the worst case?
- Is this function free of unbounded loops or recursion?

These questions are answerable for the class of programs Concrete targets (small, auditable, no hidden dispatch).

## Three Levels of Cost Analysis

### Level 1: Structural boundedness classification (DO FIRST)

Walk the SSA CFG and classify each function as:

- **Bounded**: no loops, no recursion (straight-line code + conditionals)
- **Loop-bounded**: contains loops but no recursion; loops have statically known iteration bounds
- **Recursive**: contains direct or mutual recursion
- **Unbounded**: contains loops with dynamic bounds or recursion

This is a pure CFG analysis — no annotations needed. Output via `--report boundedness`.

**Effort**: 200-300 lines in Report.lean. Walk SSA blocks, detect back-edges (loops), check call graph for cycles (recursion). 1-2 days.

### Level 2: Abstract operation counting

Count operations (arithmetic, loads, stores, branches, calls) along worst-case paths. Requires loop bound annotations:

```con
#[bound(256)]
while i < len { ... }
```

The compiler sums operation counts across the function, multiplying by loop bounds. This gives an abstract cost metric — not wall-clock time, but proportional and comparable.

**Effort**: ~500-800 lines. Needs annotation syntax (parser change), bound propagation through SSA, ILP-style path analysis. 2-3 weeks.

### Level 3: Cycle-accurate WCET

Hardware timing model with cache effects, pipeline stalls, branch prediction. This is what tools like OTAWA and aiT do. Years of work per architecture.

**Recommendation**: Don't build this. If ever needed, integrate with an external WCET tool via LLVM IR or binary analysis. Concrete's clean SSA makes this integration straightforward.

## Difficulty Assessment

| Level | Effort | Prerequisites | Value |
|-------|--------|--------------|-------|
| Structural classification | 1-2 days | None — pure CFG walk | High: identifies which functions are provably bounded |
| Abstract cost counting | 2-3 weeks | Loop bound annotations | Medium: regression detection, scheduling |
| Cycle-accurate WCET | Months-years | External tool integration | Low: only for hard real-time certification |

### Why Level 1 is easy

Concrete's SSA IR is ideal for this analysis:
- All control flow is explicit (basic blocks + terminators)
- All calls are direct (post-monomorphization, no virtual dispatch)
- No hidden allocation (Alloc capability marks every heap operation)
- No hidden effects (capabilities track all side effects)
- No garbage collection or lazy evaluation
- Phi nodes make data flow explicit

The algorithm:
1. Build call graph from SSA program
2. Detect cycles → mark functions as `Recursive`
3. For non-recursive functions, detect back-edges in CFG → `HasLoops` or `Bounded`
4. Report classification per function

### Why Level 2 is moderate

The hard parts:
- **Loop bound syntax**: new annotation in parser, must survive through elaboration and lowering
- **Compositional accounting**: if `f` calls `g` in a loop, cost(f) = loop_bound * cost(g) + loop_body_cost. Mutual recursion makes this undecidable without bounds.
- **Conditional paths**: must take max cost across branches
- **Interaction with allocation**: `vec_push` inside a loop has amortized cost but worst-case cost includes realloc+copy

## Interaction with Other Features

- **Allocation budgets**: Orthogonal but complementary. "This function is bounded AND allocates at most N bytes" is a stronger guarantee than either alone.
- **Proof story**: Level 1 classification (bounded/unbounded) is directly provable in Lean. Level 2 bounds require annotation trust.
- **High-integrity profile**: Cost tracking is a building block. "This function is bounded, NoAlloc, pure" = candidate for formal verification.
- **`--report` system**: Natural extension. `--report boundedness` fits the existing report infrastructure perfectly.

## Evidence Needed

The JSON parser has clear examples of all categories:
- `is_ws`, `is_digit`: **Bounded** (no loops, no recursion)
- `skip_ws`: **Loop-bounded** (loop bounded by string length)
- `parse_value`: **Recursive** (calls parse_array/parse_object which call parse_value)
- `main` test harness: **Bounded** (sequential test calls, no loops)

A Level 1 report on the JSON parser would immediately show which functions are verifiable candidates.

## SSA IR Readiness

The SSA IR already has everything Level 1 needs:
- `SBlock` with `term : STerm` (explicit terminators)
- `STerm.br`/`STerm.condBr` (explicit branches)
- `SInst.call` (explicit call sites)
- Block labels for back-edge detection
- Function-level structure for call graph construction

No changes to the IR are needed for Level 1. Level 2 would need a bound annotation carried through from AST to SSA.
