# Borrowed Ideas That Fit Concrete

**Status:** Open research direction
**Affects:** Language design, compiler architecture, tooling direction
**Date:** 2026-03-09

## Purpose

Concrete should not copy features from other languages casually.

But it should absolutely copy good constraints, good interfaces, and good compiler boundaries when they fit the language's goals:

- simplicity
- reliability
- auditability
- explicitness
- eventual formal verification

The best borrowed ideas are the ones that improve auditability and compiler structure without pulling in hidden machinery.

## General Rule

**Copy constraints before copying features.**

Zig, Austral, SPARK, and Odin are useful mostly because they say "no" in structurally helpful places.

That is often more valuable than their surface syntax.

## Strongest Candidates

These appear to fit Concrete best.

### 1. Zig-style declaration-only interfaces for imports

Not Zig's exact syntax necessarily. The important principle is that cross-file compilation should depend on explicit signatures, layouts, and summary-level declarations rather than arbitrary bodies.

Why it fits:

- helps the file-summary frontend direction directly
- keeps cross-file dependencies declaration-level
- improves parallelism and incremental compilation
- preserves explicit compiler phase boundaries

This is one of the strongest architectural fits for Concrete.

### 2. Austral/SPARK-style verification-friendly design discipline

Not as a separate language mode. The useful lesson is process:

**Every new feature should come with a statement of what proof obligations, invariants, or compiler responsibilities it adds.**

Why it fits:

- improves design rigor without changing the language surface
- sharpens roadmap and research docs
- helps prevent convenience-driven complexity
- supports the long-term verification goal directly

This is less a feature than a design rule, which is part of why it fits so well.

### 3. Rust-style MIR discipline, without Rust's frontend complexity

Concrete already has Core IR and SSA. The useful lesson from Rust is not "copy MIR exactly." The useful lesson is:

**Pick one IR to be the semantic authority and desugar into it aggressively and early.**

Why it fits:

- reduces ad hoc semantic logic in frontend passes
- gives clearer pass ownership
- makes later correctness arguments easier
- improves diagnosability and compiler structure

For Concrete, this should remain an internal compiler discipline, not a user-facing complexity source.

### 4. MLton-style decisive monomorphization boundary

Concrete already leans this way. The useful part is the mindset:

**Generics should disappear decisively before lower backend stages.**

Why it fits:

- simplifies backend invariants
- keeps SSA/codegen concrete
- reduces the number of passes that must understand polymorphism
- fits the explicit, ahead-of-time model

This is a very strong backend and IR design constraint for Concrete.

### 5. Futhark-style uniqueness-for-optimization mindset

Not the whole language. The useful lesson is that ownership and linearity information should be used intentionally by the compiler rather than treated as checks that happen and then get forgotten.

Why it fits:

- Concrete already has linearity
- linearity can inform lowering and optimization choices
- strengthens the connection between semantic guarantees and generated code

This is a compiler-design lesson more than a surface-language feature.

### 6. Datalog-style internal reasoning engines

Not user-facing logic programming. The idea is to consider logic-style internal engines for:

- match coverage
- capability propagation
- borrow-region constraints
- maybe certain forms of exhaustiveness or flow validation

Why it fits:

- could simplify internal reasoning
- may reduce ad hoc checker logic
- can improve reliability if the implementation becomes more declarative

This only fits if it remains purely internal and actually simplifies the compiler.

## Good Candidates With Constraints

These may fit, but they need tighter boundaries.

### 7. Odin/Zig-style build tool as part of the language experience

An explicit project/build model could fit Concrete better than a feature-rich build ecosystem.

Why it might fit:

- can make imports, targets, FFI, and build configuration more visible
- avoids ecosystem-level complexity and hidden resolution behavior
- supports a boring, auditable workflow

Risk:

- project tooling can easily grow into another language
- configuration systems tend to accumulate hidden rules

This is only a good fit if it stays small and explicit.

### 8. Ada/SPARK-style representation clauses, but much narrower

Concrete may eventually want a small layout-control surface for ABI-sensitive work.

Why it might fit:

- low-level systems code really does need representation control
- explicit layout rules are better than relying on unspecified behavior
- this aligns with FFI and auditability

Risk:

- layout control creates semantic surface quickly
- too many knobs would damage simplicity and proof tractability

This only fits if the representation model stays narrow, explicit, and mechanically checkable.

### 9. Go-style structural conveniences when semantics are fully predictable

Derived equality is the main example already under discussion.

The general lesson is:

**A convenience may fit if it is compiler-derived, non-overridable, predictable, and obvious from the type structure.**

Why it might fit:

- avoids boilerplate
- can improve readability
- does not necessarily require hidden dispatch or user-defined magic

Risk:

- many individually harmless conveniences can collectively blur the language model
- "obvious enough" is easy to overestimate

This category should stay small.

## Most Questionable Candidate

### 10. Koka-style effect discipline, but frozen and concrete

There is a useful idea here:

**Effect propagation should be treated as a central semantic object, not as scattered checks.**

Concrete already benefits from this.

Why it might fit:

- internal capability reasoning could become cleaner
- may improve semantic uniformity in the compiler

Risk:

- rich effect systems tend to pull languages toward more abstraction and inference
- user-facing effect polymorphism can become subtle fast
- it is easy to leave the "simple and explicit" design space here

So the safe version is:

- stronger internal normalization of capabilities: probably good
- richer user-facing effect abstraction: high risk

## Ranking By Fit

From strongest to weakest fit:

1. Zig-style declaration-only import / file-summary model
2. Austral/SPARK-style proof-obligation discipline for feature admission
3. Rust-style "one semantic IR owns the truth"
4. MLton-style decisive monomorphization boundary
5. Futhark-style ownership-informed optimization
6. Datalog-style internal reasoning engines
7. Odin/Zig-style explicit build/tooling model
8. Narrow Ada/SPARK-style representation clauses
9. Rare compiler-derived structural conveniences
10. Richer effect-discipline ideas

## Main Pattern

The best borrowed ideas for Concrete are usually:

- architectural constraints
- compiler boundaries
- explicit interfaces
- process discipline

The riskiest borrowed ideas are usually:

- user-facing conveniences
- implicit semantics
- abstraction systems with broad inference

That is why the most promising inspirations here are mostly about making the compiler and language easier to reason about, not about making the surface language more expressive.

## Recommendation

Concrete should be aggressive about borrowing:

- explicit compiler boundaries
- summary-based interfaces
- proof-oriented design discipline
- simple whole-program lowering constraints

Concrete should be conservative about borrowing:

- ergonomic sugar
- inference-heavy abstraction systems
- anything that hides dispatch, allocation, or cross-file dependencies

The standard should remain:

**A borrowed idea is good only if it makes Concrete easier to explain, not just easier to write.**

## Related Notes

- [feature-admission-checklist.md](feature-admission-checklist.md)
- [file-summary-frontend.md](file-summary-frontend.md)
- [derived-equality-design.md](derived-equality-design.md)
- [no-closures.md](no-closures.md)
- [no-trait-objects.md](no-trait-objects.md)
