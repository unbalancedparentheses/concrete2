# Concrete Candidate Ideas

**Status:** Open research direction
**Affects:** Compiler architecture, language design, tooling
**Date:** 2026-03-09

## Purpose

This note converts broad inspirations from other languages into actual candidate ideas for Concrete.

The goal is not to list abstract principles. The goal is to identify:

- concrete compiler changes
- concrete language features
- concrete tooling ideas
- ideas that should probably be rejected

Everything here should still be filtered through [feature-admission-checklist.md](feature-admission-checklist.md).

## Best Candidate Compiler Changes

These are not "language features" in the user-facing sense, but they are concrete engineering directions for the compiler.

### 1. Add a `FileSummary` pass

Concrete idea:

```
ParsedFile -> FileSummary
```

`FileSummary` would contain:

- module identity
- imports
- exported names
- type declarations
- function signatures
- impl headers
- trait headers
- trait-impl headers

Why this is a strong candidate:

- makes cross-file dependencies explicit
- supports parallel and incremental compilation
- reduces whole-program frontend coupling
- fits the explicit import/module model

Related note:

- [file-summary-frontend.md](file-summary-frontend.md)

### 2. Split `Resolve` into shallow resolution and body resolution

Concrete idea:

- `ResolveShallow`: declarations, imports, interfaces
- `ResolveBodies`: names inside expressions/statements using imported summaries

Why this is a strong candidate:

- gives clearer phase ownership
- reduces the size of the current "resolve everything" pass
- aligns the compiler structure with the summary-based frontend goal

### 3. Make Core IR the semantic authority earlier

Concrete idea:

- push more semantic ownership out of `Check` and into elaborated Core
- simplify `Check` into a frontend validation step
- make more correctness arguments about Core rather than about the surface AST

Why this is a strong candidate:

- fewer duplicated semantic rules
- clearer proof target
- easier to reason about pass contracts

### 4. Enforce a hard monomorphization boundary

Concrete idea:

- guarantee that no generics survive past a specific boundary before SSA/lowering
- document this as a compiler invariant

Why this is a strong candidate:

- simplifies backend passes
- improves codegen predictability
- reduces the number of IRs and passes that need to understand polymorphism

### 5. Use linearity and ownership information in lowering/optimization

Concrete idea:

- optimize moves, destruction ordering, borrow handling, and storage reuse using linearity facts
- let ownership information influence lowering decisions directly

Why this is a strong candidate:

- makes semantic guarantees operationally useful
- fits the language instead of bolting optimization on later
- could simplify some generated control/data-flow

### 6. Introduce a more declarative internal engine for coverage/capabilities

Concrete idea:

- represent match coverage, capability propagation, or borrow-region checks in a more logic-like internal form

Why this is a plausible candidate:

- may reduce ad hoc checking code
- may improve reliability and maintainability

Risk:

- only worth it if it actually simplifies the implementation

## Best Candidate Language Features

These are actual language-level possibilities, but they should be added carefully.

### 7. Narrow layout-control features for ABI-sensitive code

Concrete idea:

- extend or refine `#[repr(C)]`
- possibly add a very small explicit layout/alignment control surface

Why it might fit:

- low-level systems code needs representation control
- explicit layout is better than implicit compiler choice at FFI boundaries

Risk:

- layout features create complexity fast
- must remain narrow, explicit, and mechanically checkable

### 8. Derived structural equality for predictable types

Concrete idea:

- allow `==` for structs/enums when the semantics are compiler-derived, structural, and non-overridable

Why it might fit:

- removes boilerplate
- keeps behavior predictable
- can stay within the "no user-defined operator behavior" rule

Risk:

- this category of convenience must stay small

Related note:

- [derived-equality-design.md](derived-equality-design.md)

### 9. Sharper explicit interface around modules/imports

Concrete idea:

- strengthen import/export rules so cross-file dependencies are even more declaration-driven
- possibly add explicit interface artifacts later if the compiler architecture wants them

Why it might fit:

- improves auditability
- supports the summary-based frontend
- makes module reasoning simpler

This is close to a compiler feature and a language feature at the same time.

## Best Candidate Tooling Ideas

These are not core language features, but they could materially improve the Concrete experience.

### 10. Explicit project/build model in the main tool

Concrete idea:

- make project structure, target config, and FFI configuration explicit in the main `concrete` tool
- keep it small and boring

Why it might fit:

- reduces external build complexity
- makes the compilation model easier to understand
- fits the language's bias toward visible configuration

Risk:

- build systems easily grow into complicated hidden machinery

### 11. Compiler output modes focused on auditability

Concrete idea:

- better `--emit-core`, `--emit-ssa`, layout inspection, capability summaries, import summaries
- maybe a pass-boundary debugging mode

Why it fits:

- directly serves the auditability story
- helps compiler development and user understanding
- keeps internal decisions visible

This is a very strong fit because it improves visibility without changing semantics.

## Design-Process Changes Worth Adopting

These are not user-facing features, but they are Concrete-specific decisions worth making.

### 12. Require every design note to state pass ownership

Concrete idea:

Every design note should answer:

- which pass owns the rule?
- what invariant does it establish?
- what imported information does it need?
- what proof burden does it add?

Why it fits:

- reduces ambiguity
- keeps features from smearing across passes
- improves roadmap discipline

### 13. Require every feature proposal to state what it rejects

Concrete idea:

Every accepted feature should explicitly state nearby alternatives that are being rejected and why.

Why it fits:

- prevents silent drift
- keeps the language small by design
- helps preserve philosophy under pressure

Concrete already does some of this informally. Making it systematic would help.

## Ideas That Are Probably Bad Fits

These are useful to name explicitly.

### 14. Source-generating macro systems

Why probably reject:

- destroys file-local parsing
- couples early phases tightly
- tends to make semantics less visible
- weakens the summary-based frontend direction

### 15. Hidden dispatch features

Examples:

- trait objects
- closures with hidden captures
- broad implicit method lookup

Why probably reject:

- weakens static call-graph clarity
- hides behavior and state
- complicates reasoning and proofs

### 16. Inference-heavy abstraction layers

Examples:

- rich implicit effect inference
- complicated trait-resolution search behavior
- features whose meaning depends on broad global context

Why probably reject:

- makes diagnostics murkier
- increases phase coupling
- weakens explicitness

### 17. Convenience sugar that inserts non-obvious work

Why probably reject:

- Concrete should not trade reliability for shorthand
- repeated small sugars can blur the whole language model

## Ranking By Actionability

Most actionable now:

1. `FileSummary` pass
2. split `Resolve`
3. move semantic authority toward Core
4. document hard monomorphization boundary
5. auditability-focused compiler output modes
6. pass-ownership requirement in design docs

Promising but should wait:

7. ownership-informed optimization
8. narrow layout-control features
9. explicit build/project model
10. declarative internal coverage/capability engine
11. derived structural equality

Probably reject unless a very strong case appears:

12. source-generating macros
13. hidden dispatch mechanisms
14. inference-heavy abstraction systems
15. convenience sugar with hidden work

## Recommendation

Concrete should focus first on ideas that:

- strengthen compiler boundaries
- reduce hidden coupling
- make imports and semantics more explicit
- improve auditability without adding language surface

That means the highest-value next steps are mostly compiler and process changes, not new syntax.

This is a good sign. A language trying to stay simple should get a lot of leverage from architecture and discipline before it reaches for more features.

## Related Notes

- [feature-admission-checklist.md](feature-admission-checklist.md)
- [borrowed-ideas.md](borrowed-ideas.md)
- [file-summary-frontend.md](file-summary-frontend.md)
- [derived-equality-design.md](derived-equality-design.md)
