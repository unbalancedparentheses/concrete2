# 10x Improvements For Concrete

**Status:** Open

This note collects the relatively small number of changes that could make Concrete dramatically better, not just incrementally better.

The point is not to list every possible feature. The point is to identify the things that would multiply Concrete's value as a language and toolchain.

## What Counts As A 10x Improvement

A "10x improvement" here is something that would significantly change one or more of these:

- trust
- auditability
- practical usability
- low-level credibility
- distinctiveness relative to Rust, Zig, and other systems languages

Concrete should avoid broadening itself in ten directions at once. The most valuable improvements are the ones that strengthen its identity:

- explicit
- low-level
- proof-friendly
- auditable
- coherent

## Highest-Leverage Improvements

### 0. A truly excellent compiler pipeline

Concrete's compiler architecture is already pointed in the right direction. A real multiplier now is making the pipeline not merely "working" but unusually stable, inspectable, and proof-friendly.

That means a pipeline with these properties:

- semantic boundaries are explicit and hard to blur
- mutable state lowering is stable under optimization, not accidentally backend-sensitive
- backend emission consumes a verified contract instead of re-deciding language meaning
- artifacts are inspectable and reusable by tooling, not just internal pass glue
- ordinary language behavior is not keyed off raw names or incidental compiler tables

The target is not just "bootstrap the language." The target is:

- a compiler that is easy to reason about
- a compiler that is hard to destabilize accidentally
- a compiler whose artifacts can support proofs, reports, tooling, and future incremental work

The highest-return pipeline work now is:

1. **Stabilize loop lowering for mutable aggregates**
   - stop transporting mutable aggregate loop state as whole values through aggregate `phi` nodes when stable storage identity is the real semantic model
   - prefer storage/pointer identity over repeated aggregate writeback
   - treat borrow+loop+aggregate fragility as a lowering architecture problem, not as an LLVM quirk to patch around

2. **Finish shrinking string-based semantic logic**
   - ordinary names should stay ordinary
   - compiler-known behavior should ride on explicit intrinsic identities, language items, or other explicit boundaries
   - raw string matching should remain only at true foreign/linker/reporting boundaries

3. **Make SSA a stronger backend contract**
   - Lower should produce one boring, explicit backend IR
   - `SSAVerify` and cleanup should define and enforce the contract that all backends rely on
   - backend work should become "consume the verified SSA contract," not "reinterpret the program again"

4. **Replace raw LLVM text emission with a structured backend**
   - this is the immediate backend architecture gain
   - it removes a major source of brittleness
   - it makes later backend plurality much less dangerous

5. **Turn pipeline artifacts into first-class compiler products**
   - summaries, resolved imports, checked/elaborated artifacts, monomorphized programs, and SSA programs should become reusable compiler facts
   - that supports inspection, caching, tooling, and eventually more serious incremental workflows

Why this is 10x:

- it compounds every later improvement instead of competing with them
- it makes proofs more realistic
- it makes reports and tooling more valuable
- it reduces backend fragility and "mystery compiler" behavior
- it moves Concrete toward being a stable long-term compiler project, not just a successful bootstrap

### 1. Real formalization

If Core semantics and lowering become genuinely proven, Concrete changes category.

This would move the language from:

- "well-designed"

to:

- "meaningfully more trustworthy than most systems languages"

The most important proof targets remain:

- Core soundness
- linearity/resource soundness
- effect/capability discipline
- lowering preservation
- layout/FFI correctness where feasible

Why this is 10x:

- it is Concrete's clearest differentiator
- it compounds the value of all the compiler architecture work
- it turns "explicit design" into "machine-checked trust"

### 2. Excellent audit outputs

Concrete is unusually well-positioned to become an *inspectable* compiler, not just a compiler that rejects bad programs.

High-value compiler outputs include:

- capability summaries
- `Unsafe` summaries
- allocation summaries
- cleanup/destruction summaries
- monomorphization reports
- layout reports
- interface/import summaries

Why this is 10x:

- it makes Concrete useful for audits and reviews, not only compilation
- it helps ordinary users understand effect and resource boundaries
- it strengthens the capability/sandboxing story without complicating syntax

The strongest version of this is security-oriented, not only developer-oriented:

- mechanically see where authority enters a system
- mechanically see where allocation and cleanup happen
- mechanically see where trusted implementation techniques are used
- mechanically see where foreign behavior enters through `Unsafe` or `trusted extern fn`

Very few low-level languages aim to make those boundaries this visible.

### 3. A very strong stdlib style

Concrete does not need a huge stdlib. It needs a *strong* one.

The stdlib should stay:

- explicit
- coherent
- low-level
- ownership-honest
- handle-oriented
- typed-error-oriented

Why this is 10x:

- many languages are weakened more by sloppy library surfaces than by weak core language features
- a strong stdlib makes the language feel real quickly
- a coherent stdlib helps Concrete preserve its philosophy in actual code, not just in docs

### 4. A great formatter and tooling baseline

A formatter alone can make a language feel much more mature.

The key first tooling steps are:

- formatter
- better diagnostics presentation
- artifact/report inspection workflows
- later, editor/LSP support

Why this is 10x:

- it reduces friction immediately
- it makes codebases more uniform
- it makes adoption and contribution easier

The deeper version of this is compiler-artifact-driven tooling:

- artifact/report inspection workflows
- stable compiler outputs that editor tooling can consume
- explicit import/module graph data
- later, serialization and caching on top of those same artifacts

Tooling gets much better when the compiler is already structured as a producer of durable facts instead of ephemeral pass-local state.

### 5. A clean hosted vs freestanding split

Concrete will eventually be much stronger if it can support a clear split between:

- hosted / libc / OS-backed code
- freestanding / `no_std`-style code

Why this is 10x:

- increases credibility for embedded/kernel/runtime work
- strengthens sandboxing and platform-boundary reasoning
- forces the stdlib/runtime boundary to stay honest

See [no-std-freestanding.md](no-std-freestanding.md).

### 6. A better capability/sandboxing story

Concrete already has one of the stronger base stories here. It could become much better through:

- better capability reports
- capability aliases
- explicit authority-wrapper patterns
- better `Unsafe` inspection
- later, finer-grained capabilities where they earn their place

Why this is 10x:

- security- and audit-focused users care deeply about least authority
- it multiplies the value of the existing `with(...)` system
- it improves the hosted vs freestanding story too

This is also one of the clearest security multipliers available to Concrete:

- less ambient authority
- easier least-authority review
- clearer sandbox boundaries
- fewer “safe-looking but globally powerful” APIs

Part of that improvement is shrinking string-based semantic logic in the compiler itself. A language is easier to audit when ordinary names stay ordinary and special behavior is carried by explicit identities and boundaries instead of raw string matching.

See [capability-sandboxing.md](capability-sandboxing.md).

Closely related:

- a stronger `Unsafe` structure and audit story — see [unsafe-structure.md](unsafe-structure.md)
- the `trusted fn` / `trusted impl` boundary for containing pointer-level implementation unsafety behind safe APIs, keeping the three-way split clean: semantic effects (capabilities) / implementation trust (`trusted`) / foreign boundaries (`Unsafe`) — see [trusted-boundary.md](trusted-boundary.md)
- builtin minimization and stdlib-owned public APIs, which shrink the trusted computing base and make those boundaries easier to audit — see [builtin-vs-stdlib.md](builtin-vs-stdlib.md)

### 7. A truly strong concurrency/runtime model

This is the biggest long-term opportunity, but also the easiest place to lose discipline.

If Concrete eventually does concurrency, the value is not "async/await because everyone has it." The value would be:

- structured concurrency
- explicit blocking vs non-blocking authority
- capability-based runtime access
- explicit cancellation and cleanup

Why this could be 10x:

- Rust's async story is powerful but often hard to reason about
- a cleaner model would be a real differentiator for systems work

This remains intentionally deferred until the current runtime/library boundary is stronger.

See [concurrency.md](concurrency.md).

## Lessons From Other Languages

This section focuses on *transferable ideas*, not feature shopping.

### Zig

Useful ideas:

- allocator-explicit design
- low hidden-cost culture
- practical low-level stdlib surfaces
- freestanding-friendly thinking

What Concrete can learn:

- make allocation visible in the stdlib and runtime boundary
- prefer clear low-level APIs over abstraction-heavy library culture
- keep hosted/freestanding design in view even before a formal `no_std` mode exists

### Odin

Useful ideas:

- direct, practical systems APIs
- explicit allocator usage
- context-driven integration hooks

What Concrete can learn:

- some library customization points are worth making easy
- but implicit global/context-driven behavior should be handled carefully because it can blur authority

Concrete should probably borrow:

- allocator-consciousness

without borrowing:

- too much implicit context machinery

### Gleam

Useful ideas:

- consistent `Result<T, E>` use
- small, readable surface
- strong clarity around fallible APIs
- good beginner-to-production documentation style

What Concrete can learn:

- consistency beats cleverness for fallible stdlib APIs
- a language can feel "simple" even with strong typing if the library surface is disciplined

Concrete has already moved in this direction with uniform `Result<T, ModuleError>` usage in the stdlib.

### Pony

Useful ideas:

- capabilities as real authority, not decorative effect labels
- ownership/aliasing discipline tied to concurrency and sharing

What Concrete can learn:

- authority can be part of the everyday model, not just advanced theory
- explicit wrapper and capability-based design can make concurrency/resource control much stronger

Concrete should borrow the seriousness about authority, not Pony's full model wholesale.

### Koka

Useful ideas:

- effects as something users can understand and inspect
- effect-aware reasoning without exceptions or ambient behavior

What Concrete can learn:

- capability/effect information becomes much more valuable when tooling and reports make it visible
- effect systems should help ordinary reasoning, not just type-theory elegance

### Austral / Vale / Ada / SPARK

Useful ideas:

- high-integrity low-level style
- explicit resource and authority boundaries
- proof-aware or contract-aware systems thinking

What Concrete can learn:

- readability and explicitness matter as much as formal strength
- high-assurance systems programming benefits from a smaller, more disciplined surface

## What To Avoid

Concrete should avoid trying to become "10x better" by simply accreting the full surface area of other languages.

In particular, avoid:

- large abstraction-heavy ecosystems
- hidden runtime assumptions
- convenience features that blur ownership/effect/resource boundaries
- overcomplicated capability syntax
- broad language growth without proof/audit leverage

The right multiplier is not breadth. It is leverage.

## Recommended Order

If Concrete wants the biggest step-function improvements, a plausible order is:

1. stabilize the compiler pipeline further: loop-lowering/storage identity, string-dispatch cleanup, stronger SSA/backend contracts
2. replace textual LLVM emission with a structured backend
3. improve audit outputs further
4. add formatter/tooling baseline on top of explicit compiler artifacts
5. keep strengthening the stdlib style and systems layer
6. push formalization much harder
7. later, design hosted vs freestanding support
8. later, deepen capability/sandboxing
9. much later, do concurrency/runtime only if it can be done in a way that stays recognizably Concrete

## Bottom Line

The biggest improvements are not "more features."

They are the things that make Concrete:

- more trustworthy
- more inspectable
- more coherent
- more usable in real low-level work

That means the real 10x improvements are:

- compiler-pipeline excellence
- proofs
- audit outputs
- stdlib quality
- tooling baseline
- hosted/freestanding clarity
- stronger sandboxing
- eventually, a better concurrency/runtime model
