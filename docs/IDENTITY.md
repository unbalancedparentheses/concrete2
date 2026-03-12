# Concrete Identity

Status: stable reference

This document states what Concrete is trying to be, what it is optimizing for, and what it is not trying to win on.

## Positioning

Concrete is a low-level language optimized for auditability, explicit trust, and proof-friendly compiler architecture.

It is not trying to win by having the largest feature set, the most metaprogramming, or the broadest ecosystem first. Its intended advantage is that important low-level properties stay explicit enough to inspect, report, audit, and eventually prove.

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

### 5. Resource / Safety Honesty Without A Giant Surface

Concrete is aiming for a strong ownership/capability/trust story without requiring the language to become maximally large or magical.

The goal is not to out-Rust Rust on every dimension. The goal is to offer a smaller, more explicit system that is easier to audit and reason about.

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
