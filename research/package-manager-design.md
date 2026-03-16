# Package Manager Design

Status: open

This note sketches a Concrete package manager that is:

- Cargo-simple on the surface
- Nix-inspired underneath in reproducibility and graph discipline
- Concrete-specific in authority, trust, and evidence

It is intentionally narrower than Cargo and much simpler than Nix.
The goal is not to build a universal package/build language.
The goal is to make Concrete usable for real projects without losing auditability.

## Core Claim

Concrete should not copy Cargo wholesale, and it should definitely not copy the full Nix language.

The right shape is:

- a boring manifest
- a small CLI
- an explicit package/dependency graph artifact
- reproducible inputs and outputs
- authority/evidence integrated from day one

## Design Goals

1. Keep the user surface small and obvious.
2. Make builds reproducible and graph-shaped, not shell folklore.
3. Treat packages as authority and trust boundaries, not only dependency buckets.
4. Reuse compiler artifacts instead of rediscovering the world on every build.
5. Leave room for evidence bundles, trust drift, and proof-facing outputs later.

## Manifest Shape

One package should be described by one `Concrete.toml`.

Example:

```toml
[package]
name = "artifact_verifier"
version = "0.1.0"
edition = "2026"

[targets]
bin = ["src/main.con"]
lib = ["src/lib.con"]

[dependencies]
std = "builtin"
sha2 = { path = "../sha2" }
hex = { registry = "default", version = "0.2.1" }

[authority_budget]
package = ["Alloc", "File"]
forbid = ["Network", "Process"]

[profile.dev]
opt = "O0"

[profile.release]
opt = "O2"
```

The manifest should stay declarative.
No embedded scripting language.
No arbitrary build hooks in the MVP.

## CLI Shape

The first commands should be:

- `concrete build`
- `concrete run`
- `concrete test`
- `concrete check`
- `concrete report`
- `concrete graph`

Later:

- `concrete add`
- `concrete update`
- `concrete audit`

The package manager should not become a second compiler.
It should resolve graphs, manage lockfiles, and invoke the compiler with explicit inputs.

## Dependency Sources

The MVP should support only:

1. `builtin`
   - for std
2. `path`
   - for local packages and workspaces
3. `registry`
   - later, curated remote index

Avoid early support for:

- arbitrary git dependencies everywhere
- build scripts
- package-time code generation
- complex feature unification

## Workspace Model

Keep the first workspace surface simple:

```toml
[workspace]
members = ["packages/*"]
```

The workspace should provide:

- shared lockfile
- shared package graph
- shared authority/trust policy checks
- shared incremental rebuild context

## Lockfile

Concrete should have a lockfile from the start.

It should pin:

- exact resolved versions
- source identity or hashes
- registry identity
- package graph shape

Later, it may also pin:

- authority/trust metadata
- evidence/report schema versions

This is important because reproducibility is part of Concrete's identity, not an optional afterthought.

## Package Graph Artifact

This is the most important Nix-like idea to steal.

The package manager should produce an explicit graph artifact describing:

- package IDs
- versions
- source roots
- target roots
- resolved dependency edges
- profiles
- authority budgets
- trust/evidence metadata

The compiler should consume this graph instead of reconstructing project structure ad hoc from the filesystem.

This graph artifact should eventually support:

- incremental compilation
- report reuse
- evidence bundles
- trust-drift comparison

## Authority Budgets

This is where Concrete should go beyond Cargo.

Packages should be able to declare not only what they depend on, but what authority they may require at all.

Examples:

- parser package may require no ambient authority
- CLI package may require `File`
- binary may forbid `Process`

Then the build should fail if transitive authority exceeds the declared budget.

This turns capabilities from local function facts into subsystem policy.

## Reproducibility: Nix Ideas Worth Copying

Concrete should borrow several ideas from Nix:

### 1. Input-addressed thinking

Track exact build inputs:

- source
- compiler version
- dependency graph
- target/profile

Not necessarily full Nix-style derivations at first, but the same discipline.

### 2. Build as an explicit graph

Builds should be graph nodes with declared dependencies and outputs.

This fits:

- artifact-driven compiler work
- incremental compilation
- evidence/review outputs

### 3. Description separate from execution

Manifest and graph evaluation should be distinct from compilation.

This keeps the package manager simple and auditable.

### 4. Reproducibility as a first-class feature

Concrete should care early about:

- lockfiles
- deterministic graph resolution
- explicit toolchain identity
- comparable outputs

This aligns with later trust bundles and report-first review workflows.

## Nix Ideas Not Worth Copying

Concrete should not copy:

- the Nix language itself
- lazy evaluation complexity
- highly abstract package expressions
- “everything is a derivation” maximalism

Concrete needs build honesty, not another complicated programming language.

## Cargo Ideas Worth Copying

Concrete should copy the parts of Cargo that reduce friction:

- simple manifest layout
- obvious package layout conventions
- small command set
- workspace model
- lockfile expectation

But it should avoid Cargo’s more complex edges early:

- feature unification explosion
- build.rs-style arbitrary hooks
- overly implicit dependency magic

## Compiler Boundary

The package manager should own:

- manifest parsing
- dependency resolution
- workspace graph construction
- lockfile management
- invoking the compiler with resolved graph inputs

The compiler should own:

- parsing
- elaboration
- checking
- reports
- proof/evidence artifacts

That separation matters.
Otherwise the package manager becomes a shadow semantic engine.

## MVP Sequence

1. `Concrete.toml`
2. path dependencies
3. workspace support
4. lockfile
5. `build` / `run` / `test` / `check`
6. explicit package graph artifact
7. stdlib/project resolution cleanup
8. authority budgets
9. curated registry
10. trust-drift and evidence integration

## Long-Term Differentiators

The package manager becomes uniquely Concrete when it supports:

- authority budgets
- trust/evidence metadata in the package graph
- machine-readable report outputs per package
- trust-drift diffing across versions
- reproducible trust bundles

That is the real opportunity:
not to out-Cargo Cargo,
but to make package/dependency management part of Concrete's auditability story.

## Open Questions

1. What should “just work” in single-file mode versus requiring a package?
2. How much semver complexity is worth carrying in the first registry design?
3. Should authority budgets start package-wide only, or allow target/subsystem granularity immediately?
4. How much of the package graph should become a stable, serialized public artifact?
5. Should std be modeled as a normal builtin package or as a special case in the resolver?
