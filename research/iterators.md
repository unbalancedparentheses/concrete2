# Iterators And Traversal Surfaces

Status: resolved — per-container traversal APIs landed, no iterator tower

Priority: P1 (was); now closed

## Question

Should Concrete add iterator support, and if so, what is the smallest form that helps real programs without importing a large abstraction culture from Rust or functional languages?

## Resolution

The traversal story is now complete with three tiers:

1. **`for_each`** — side-effect traversal (printing, logging)
   - `Vec<T>.for_each(fn(&T))`
   - `HashMap<K,V>.for_each(fn(&K, &V))` / `keys_for_each` / `values_for_each`
   - `HashSet<K>.for_each(fn(&K))`

2. **`fold<A>`** — stateful traversal with explicit accumulator, no closures needed
   - `Vec<T>.fold<A>(init, fn(A, &T) -> A) -> A`
   - `HashMap<K,V>.fold<A>(init, fn(A, &K, &V) -> A) -> A` / `keys_fold<A>` / `values_fold<A>`
   - `HashSet<K>.fold<A>(init, fn(A, &K) -> A) -> A`

3. **`keys()` / `elements()` / `values()`** — materialization to Vec when you need a collection

`fold<A>` was blocked by a compiler bug: method-level generics (`fn fold<A>` inside `impl<K,V>`) parsed but crashed at lowering because (a) self parameter types lost their generic args and (b) generic structs were only instantiated once at the LLVM level. Fixed in `c0c5b54`.

## Design Decisions

- **No cursors**: would require borrowing lifetimes, which go against Concrete's design (inference-heavy, murkier diagnostics, phase coupling)
- **No closures**: `fold` threads state through the return value instead of capturing mutable locals
- **No iterator trait**: per-container APIs cover the need; a shared protocol adds complexity without proven benefit
- **No lazy adapter chains**: explicit traversal only

## What Was Considered And Rejected

- Rust-style `trait Iterator<T> { fn next(&mut self) -> Option<T>; }` — requires trait system + lifetimes for cursors
- C-style `fn for_each_ctx(ctx: *mut u8, f: fn(*mut u8, &K))` — too low-level for a default stdlib pattern
- Cursor/handle-based iteration — requires lifetime tracking which Concrete won't add

## Evidence

Phase H programs showed the traversal pressure:
- kvstore needed parallel `Vec<String>` because HashMap had no traversal (now uses HashMap + fold)
- integrity monitor used O(n) linear manifest scanning (now uses HashMap + HashSet with fold)
- `for_each` alone was insufficient because it can't accumulate without closures

## Current Recommendation

The traversal surface is sufficient. Revisit only if:
- real programs show a pattern that `fold` + `for_each` + materialization can't cover
- there is repeated evidence for a shared iteration protocol across containers
