# Recent External Ideas

**Status:** Open research direction
**Affects:** Tooling, stdlib design, backend design, language boundaries
**Date:** 2026-03-09

## Purpose

This note tracks recent ideas from other languages that may be useful for Concrete.

The point is not to copy trends.

The point is to identify recent developments that:

- fit Concrete's philosophy
- improve auditability or reliability
- improve compiler structure or tooling
- avoid hidden machinery

This note is intentionally curated to include only ideas that are actually recommended for Concrete.

## Good Fit

### 1. Make hidden allocation even harder

**Source language:** Odin  
**Where from:** 2025 Q1 newsletter

#### What it is

Odin disallowed dynamic array and map literals that allocate implicitly unless a compatibility feature flag is enabled.

#### How it works

The language/toolchain no longer treats allocation-hiding literal forms as normal default syntax. If a program wants that older behavior, it must opt in explicitly.

#### Why this is interesting for Concrete

Concrete already wants allocation to remain visible in signatures and at call sites. The lesson here is not the exact Odin syntax change. The lesson is:

**Do not let convenience syntax silently create heap activity.**

#### Concrete translation

- keep `Alloc` visible in signatures
- keep allocator binding visible at call sites
- resist new literal or collection sugar that would allocate implicitly

Reference:

- [Odin 2025 Q1 Newsletter](https://odin-lang.org/news/newsletter-2025-q1/)

### 2. Sharper low-level stdlib design

**Source language:** Odin  
**Where from:** `core:os` redesign writeup

#### What it is

Odin has been redesigning low-level OS APIs around explicit allocators, typed error values, and more consistent resource types.

#### How it works

APIs that allocate require explicit allocator arguments. Error handling is more typed and uniform. File/process/system interactions are expressed through clearer library boundaries instead of ad hoc primitives.

#### Why this is interesting for Concrete

This is one of the safest places to borrow ideas. Concrete does not need more hidden language features; it needs excellent low-level library design.

#### Concrete translation

- allocator-explicit stdlib APIs
- typed errors rather than vague sentinel values
- obvious ownership of returned buffers/resources
- obvious borrowed vs owned text/buffer types

Reference:

- [Moving Towards a New `core:os`](https://odin-lang.org/news/moving-towards-a-new-core-os/)

### 3. Better inspectability and compiler/tooling graph awareness

**Source language:** Zig  
**Where from:** Zig 0.14.0 release notes

#### What it is

Zig has continued investing in file watching, incremental compilation work, and a more explicit build/module graph model.

#### How it works

The compiler/build system tracks module relationships and build steps explicitly enough to support faster rebuild loops and clearer tooling behavior.

#### Why this is interesting for Concrete

The most relevant lesson is not "copy Zig's build system." The relevant lesson is:

**Make compiler artifacts and module relationships explicit enough that tooling can inspect and reuse them.**

This lines up directly with the `FileSummary` direction.

#### Concrete translation

- explicit file summaries
- inspectable module/import graph
- cacheable compiler artifacts
- watch/rebuild tooling later, after architecture is stable

Reference:

- [Zig 0.14.0 Release Notes](https://ziglang.org/download/0.14.0/release-notes.html)

### 4. Curated diagnostics

**Source language:** Rust  
**Where from:** Rust 1.85 / `#[diagnostic::do_not_recommend]`

#### What it is

Rust added a way to keep technically-correct but misleading suggestions out of diagnostics.

#### How it works

The compiler and library ecosystem can mark certain suggestions as undesirable so diagnostics remain more relevant and less confusing.

#### Why this is interesting for Concrete

Concrete should treat diagnostics as part of the reliability story, not as an afterthought. A correct-but-confusing diagnostic is still a problem.

#### Concrete translation

- keep errors phase-owned
- keep messages curated, not merely mechanically generated
- prefer fewer, higher-signal diagnostics over noisy but "complete" output

Reference:

- [Rust 1.85.0 announcement](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)

### 5. Project-wide rename and find-references from compiler data

**Source language:** Gleam  
**Where from:** Gleam 1.10.0

#### What it is

Gleam improved project-wide rename and find-references by retaining richer reference information in the compiler and language server.

#### How it works

The compiler tracks more information about how values and types refer to one another across modules, and the language server uses that data for editor operations.

#### Why this is interesting for Concrete

This is a strong tooling lesson:

**Compiler artifacts should serve the language server, not just code generation.**

This fits well with summary-based frontend work and explicit compiler products.

#### Concrete translation

- retain cross-file reference data in compiler artifacts
- expose rename/find-references through one compiler-backed toolchain
- make module summaries useful for tooling, not just compilation

Reference:

- [Gleam v1.10.0: Global rename and find references](https://gleam.run/news/global-rename-and-find-references/)

## Deferred But Worth Remembering

### Explicit ABI escape hatches

**Source language:** Rust  
**Where from:** Rust 1.88 / naked functions stabilization

#### What it is

Rust stabilized naked functions for writing functions with no compiler-generated prologue/epilogue, using a tightly constrained unsafe assembly body.

#### How it works

The function is marked as unsafe/naked, and the body is heavily restricted so the programmer explicitly owns the ABI-sensitive details.

#### Why this is interesting for Concrete

A feature like this could eventually be useful for:

- runtimes
- bootstrapping
- context switching
- interrupt/trap handlers
- compiler-builtins-style low-level hooks

#### Why it is deferred

Concrete should not consider this until:

- ABI/layout rules are sharper
- the `Unsafe` boundary is tighter
- runtime/bootstrap requirements are clearer
- the allowed body shape can be stated precisely

So this is worth remembering, but it is not a current recommendation.

References:

- [Rust 1.88.0 announcement](https://blog.rust-lang.org/2025/06/26/Rust-1.88.0/)
- [Stabilizing naked functions](https://blog.rust-lang.org/2025/07/03/stabilizing-naked-functions/)

## Main Takeaways

The strongest recent external ideas for Concrete are not new abstraction features. They are:

- stricter visibility around allocation
- sharper low-level stdlib design
- more explicit compiler/tooling artifacts
- curated diagnostics
- careful, narrow low-level escape hatches

The best recent ideas mostly strengthen the same philosophy Concrete already has.

That is a good sign: Concrete does not need a new identity. It mainly needs to sharpen and operationalize the one it already has.

## Related Notes

- [borrowed-ideas.md](borrowed-ideas.md)
- [concrete-candidate-ideas.md](concrete-candidate-ideas.md)
- [feature-admission-checklist.md](feature-admission-checklist.md)
- [high-leverage-improvements.md](high-leverage-improvements.md)
