# Concrete Identity

Status: stable reference

This document states what Concrete is trying to be, what it is optimizing for, and what it is not trying to win on.

## Positioning

Concrete is a low-level language optimized for auditability, explicit trust, and proof-friendly compiler architecture.

It is not trying to win by having the largest feature set, the most metaprogramming, or the broadest ecosystem first. Its intended advantage is that important low-level properties stay explicit enough to inspect, report, audit, and eventually prove.

## Why Concrete Exists

Concrete was created to close a gap between systems programming and mechanized reasoning.

Most systems languages optimize for control, performance, and interoperability, but leave many important questions hard to answer mechanically: where authority enters, where resources are allocated and destroyed, where trust boundaries are crossed, and what the compiler really means by a program. Proof assistants make those questions tractable, but they are not the same thing as an everyday low-level systems language.

Lean 4 is central to Concrete's proof story, but Lean is still a theorem prover first, not a low-level systems language. It has a runtime and garbage collector, and it is not designed as the place where you would normally implement non-GC systems code with explicit ownership, layout, FFI, and resource management. Concrete exists so the implementation language can stay low-level and explicit while Lean 4 is leveraged to prove properties about it.

The core idea is that systems code should not only run fast or expose low-level control. It should also make important facts visible:

- what authority it has
- where resources are created and destroyed
- where `Unsafe` and `trusted` boundaries exist
- what the compiler actually means by the program

Concrete is trying to bridge that gap. The project exists to make low-level programming explicit enough to audit, honest enough to trust, and structured enough to eventually prove.

## Core Differentiators

### 1. Auditability As A First-Class Goal

Concrete should become unusually good at telling users:

- where authority enters
- where allocation happens
- where cleanup/destruction happens
- where `trusted` enters
- what layout/ABI a type really has
- what monomorphized code actually exists

Many languages treat this as secondary tooling. Concrete should treat it as part of the language/compiler identity.

### 2. Explicit Trust And Capability Boundaries

Concrete's safety story is built from explicit surfaces:

- capabilities
- `Unsafe`
- `trusted fn`
- `trusted impl`
- `trusted extern fn`
- audit/report outputs

The differentiator is not merely "has unsafe code". It is that trust and authority should be explicit, inspectable, and honest.

### 3. Small Semantic Surface

Concrete should stay small enough that:

- ordinary names are ordinary
- semantics are explicit
- compiler magic is minimized
- the trusted computing base stays easier to reason about

This is why semantic cleanup and feature discipline matter so much in the roadmap.

### 4. Proof-Friendly Compiler Architecture

Concrete's compiler is being shaped around:

- clear Core semantics
- SSA as a real backend boundary
- explicit pass structure
- formalization targets that match the architecture

This is meant to make the language unusually compatible with mechanized trust claims rather than treating proof work as an afterthought.

Concrete's long-term proof story has two layers:

- proving properties of the language/compiler in Lean
- eventually proving properties of selected Concrete programs in Lean through formalized Core semantics

Examples of the first layer:

- the type system is sound
- ownership and linearity rules are coherent
- capability and trust rules are preserved
- lowering from Core to SSA preserves meaning

Examples of the second layer:

- a function returns the right result
- a data-structure operation preserves its invariant
- a parser round-trips with a formatter
- a critical routine respects a specification

The difference matters:

- proving the language/compiler gives trust in the language rules and compiler pipeline
- proving selected Concrete programs gives trust in specific pieces of user code

Both matter, but they are not the same. One is language trust and compiler trust. The other is program trust.

That second goal is important because it turns proof-friendliness from a compiler implementation detail into a real language differentiator.

It is also important as a concrete project milestone, not only as a vague long-term ambition. Concrete should reach a point where a user can write selected Concrete code, then use Lean 4 to prove properties about that code through validated Core semantics. That is one of the clearest breakthroughs the roadmap is trying to produce.

The practical shape of that idea is important:

- Concrete is the low-level implementation language
- Lean 4 is the theorem and proof environment that Concrete leverages
- formalized Core semantics are the bridge between them

That is appealing because it points toward something stronger than "compiler in Lean". It points toward real executable systems code written in Concrete and proved with Lean 4, using Lean's theorem ecosystem without requiring the implementation itself to live inside a GC-oriented proof language runtime.

### 5. Resource / Safety Honesty Without A Giant Surface

Concrete is aiming for a strong ownership/capability/trust story without requiring the language to become maximally large or magical.

The goal is not to out-Rust Rust on every dimension. The goal is to offer a smaller, more explicit system that is easier to audit and reason about.

### 6. Explainability As Part Of The Product

Concrete should not stop at "accepted" or "rejected". It should become unusually good at answering:

- why a capability is required
- why code crosses an `Unsafe` or `trusted` boundary
- why a value is dropped or consumed where it is
- why a layout, ABI, or monomorphization outcome occurred

This is part of the same identity as auditability. A language built for explicit reasoning should also be built to explain its own decisions clearly.

### 7. Reproducible And Inspectable Compiler Outputs

Concrete should eventually produce artifacts and builds that are not only correct enough to use, but inspectable and reproducible enough to trust operationally.

That means moving toward:

- explicit, durable compiler artifacts
- reproducible enough builds and tests to trust failures
- outputs that support reports, audits, tooling, and later proof workflows from the same underlying facts

This is not a separate identity from the proof story. It is part of what makes a low-level language operationally trustworthy.

### 8. A Future High-Integrity Profile

Concrete should eventually support a clearly defined high-integrity or provable subset/profile for critical code.

The important idea is not "add more syntax for verification." The important idea is:

- restricted execution profiles such as no-allocation or bounded-allocation modes
- tighter restrictions around `Unsafe`, `trusted`, FFI, and ambient authority
- analyzable concurrency rules rather than unconstrained concurrency by default
- stronger evidence, reports, and traceability for review-heavy code

This fits Concrete better than a large contract system as a first move. It preserves the language's bias toward explicitness, analyzability, and smaller trusted surfaces.

## Competitive Stance

Concrete does not need to beat every systems language on every axis.

It is not primarily trying to out-compete:

- Rust on ecosystem scale, borrow-checker polish, or macro power
- Zig on comptime, build integration, or cross-compilation ergonomics
- Odin on minimal syntax or data-oriented workflow simplicity
- Vale on every ownership-region experiment

Concrete should instead be strongest where those languages are not explicitly centered:

- auditability
- explicit authority/trust boundaries
- proof-friendly compiler structure
- a smaller and more honest semantic surface
- a path toward high-integrity profiles for critical systems without requiring Concrete to become a giant verification-first language

Compared to Lean, Concrete is not trying to be a proof assistant. It is trying to be the low-level language that Lean 4 can reason about well.

Compared to mainstream systems languages, Concrete's intended difference is not "more features". It is unusually explicit authority, trust, resource, and compiler-meaning boundaries, with a style that should stay closer to Austral's clarity than to feature accumulation.

Compared to verification-first languages, Concrete is trying to keep low-level runtime, FFI, layout, and ownership concerns first-class instead of treating them as secondary escape hatches.

For a fuller comparison of what other languages may still have even after Concrete's planned phases, see [../research/competitive-gap-analysis.md](../research/competitive-gap-analysis.md).

## Non-Goals

Concrete should avoid drifting into these as identity goals:

- feature-count competition for its own sake
- hidden semantic behavior keyed off ordinary public names
- cleverness that makes auditability or proof work harder
- large convenience surfaces inside the compiler instead of the stdlib
- treating self-hosting or ecosystem size as more important than semantic and trust clarity

## What Concrete Must Be Able To Show

To justify its identity, Concrete should eventually be able to show users:

- what code requires which authority, and why
- what code crosses `Unsafe` and `trusted` boundaries
- what runtime/layout/ABI choices actually occurred
- what code was generated after monomorphization
- where allocation and destruction happen

If Concrete cannot show these things clearly, it is not yet delivering its intended differentiator.

Concrete should also be able to explain those facts clearly and, over time, reproduce them reliably enough that users can trust them across machines and environments.

## Why The Proof Direction Is Useful

This direction is useful because it lets Concrete justify a stronger claim than "the compiler seems well-designed."

It means:

- the language and compiler can be reasoned about in Lean
- selected Concrete programs can eventually be reasoned about in Lean too

That matters because it validates the language design, validates the compiler architecture choices around Core and SSA, creates a real differentiator for security- and audit-sensitive code, and helps keep future language growth disciplined.

It is also one of the clearest reasons Concrete exists at all: systems languages usually give low-level power, proof systems usually give reasoning power, and Concrete is trying to make those two meet cleanly.
