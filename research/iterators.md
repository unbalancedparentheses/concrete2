# Iterators And Traversal Surfaces

Status: open

Priority: P1

## Question

Should Concrete add iterator support, and if so, what is the smallest form that helps real programs without importing a large abstraction culture from Rust or functional languages?

## Current Evidence

Phase H programs already show real traversal pressure:

- `HashMap.keys()` / `values()` and `for_each()` were worth adding
- the key-value store still needs a side `Vec<String>` for key enumeration because `HashMap` has no maintained traversal surface beyond callback-style helpers
- the file integrity monitor and other collection-heavy workloads want explicit traversal without falling back to index-heavy boilerplate everywhere

This is enough evidence to justify research on iteration support.

It is not yet evidence for:

- a large lazy-iterator adapter ecosystem
- inference-heavy chaining
- trait-heavy iterator combinator design
- hidden allocation or state-machine lowering

## Design Filter

The right filter is:

- explicit
- allocation-free by default
- understandable in signatures and codegen
- useful for real container traversal
- not a second mini-language for collection pipelines

If a traversal feature weakens those properties, it is probably the wrong direction for Concrete.

## Likely Good Direction

Start with narrow, explicit traversal surfaces:

1. container-specific traversal helpers first
   - `HashMap.for_each`
   - `HashSet.for_each`
   - explicit key/value/entry traversal helpers
2. only consider a shared iterator protocol if several containers converge on the same minimal shape
3. keep eager, explicit collection-building separate from traversal itself

This suggests a sequence like:

- first: complete explicit traversal APIs for the main runtime-oriented containers
- later: evaluate whether a tiny shared iteration trait/protocol earns its complexity
- do not start from generic adapters and work backward

## What To Avoid

Concrete should avoid copying the full Rust iterator culture:

- long lazy adapter chains
- combinators that hide control flow or allocation
- large trait bounds and inference pressure
- iterator-driven surface growth that makes diagnostics and proofs harder to explain

The same caution applies to Python-style generator culture or functional-stream abstractions.

## Concrete-Shaped Goal

The goal is not “iterators everywhere.”

The goal is:

- ordinary map/set/container traversal without awkward side structures
- explicit traversal that remains easy to audit
- no hidden semantic machinery

If that can be achieved with a few boring container APIs, that is preferable to a grand abstraction.

## Near-Term Roadmap Fit

This belongs under Phase H follow-up and collection maturity:

- add the smallest missing traversal support that real programs need
- re-evaluate after more real workloads use it
- only then decide whether a shared iterator abstraction exists at all

## Current Recommendation

Adopt this stance:

- yes to narrow explicit traversal support
- maybe later to a tiny shared iteration protocol
- no to a broad iterator ecosystem unless repeated evidence somehow forces it
