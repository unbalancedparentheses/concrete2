<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![CI](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml/badge.svg)](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml)
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

Concrete is a small systems programming language for evidence-carrying software.

It is built in Lean 4 and aims to make authority, resource risk, trust boundaries, and proof evidence visible to the compiler, reviewers, CI, and AI tools.

## The Language

Concrete is a compiled, statically typed systems language that targets LLVM IR. It is not a proof assistant; it is a no-GC systems language that Lean 4 can reason about.

- **No garbage collector.** Memory is managed through ownership and borrowing, checked at compile time. There is no runtime GC, no reference counting behind the scenes.
- **Linear type system.** Every non-Copy value must be consumed exactly once. The compiler rejects programs that leak, double-free, or use after move.
- **Copy vs linear.** Types are either `Copy` (freely duplicated — integers, small structs) or linear (must be explicitly consumed or destroyed). Structs opt in to `Copy`; heap-owning types are linear by default.
- **Capability-based effects.** Side effects are tracked through capabilities declared in function signatures: `with(File)`, `with(Console)`, `with(Alloc)`. A function with no capabilities is pure — it cannot do I/O, allocate, or touch the outside world.
- **Explicit trust boundaries.** `trusted` marks code the compiler cannot fully verify (pointer arithmetic, FFI). Everything else is checked. The boundary is visible and auditable.
- **Explicit allocation.** Heap allocation requires the `Alloc` capability. Stack allocation is the default. If a function doesn't say `with(Alloc)`, it doesn't allocate.

The compiler is written in Lean 4.

## The Thesis

Most systems languages give you safety or control. Concrete is trying to be a small, modern, SPARK-like systems language where the following are visible at the function boundary:

1. what authority a function has (capabilities)
2. whether it allocates, blocks, recurses, or runs unboundedly
3. where it crosses trust boundaries
4. whether those claims are reported, enforced, or proved

Short version:

- Rust makes memory safety explicit.
- Zig makes low-level control explicit.
- SPARK makes specifications and assurance central.
- Lean 4 makes proof a practical implementation and theorem-proving environment.
- Concrete is trying to make operational power and evidence explicit in native systems code.

## What This Looks Like

The clearest example is [examples/thesis_demo/src/main.con](examples/thesis_demo/src/main.con):

```con
fn parse_byte(data: Int, offset: Int) -> Int {
    return data + offset;
}

fn check_length(len: Int) -> Int {
    if len < 10 { return 1; }
    return 0;
}

fn validate(data: Int, len: Int) -> Int {
    if check_length(len) != 0 { return 1; }

    let mut checksum: Int = 0;
    for (let mut i: Int = 0; i < len; i = i + 1) {
        checksum = checksum + parse_byte(data, i);
    }

    if checksum == 0 { return 2; }
    return 0;
}

fn report(result: Int) with(Console) {
    if result == 0 { println("ok"); }
    else { println("fail"); }
}

pub fn main() with(Std) -> Int {
    let result: Int = validate(42, 10);
    report(result);
    return result;
}
```

Read the signatures. `parse_byte`, `check_length`, and `validate` have no capabilities — they are pure. `report` can write to the console and nothing else. `main` has `Std` (the full standard capability set) because it is the entry point.

The compiler can tell you what each function does:

```
parse_byte     evidence: proved           — Lean theorem: ∀ a b, parse_byte(a,b) = a+b
check_length   evidence: proved           — Lean theorem: rejects iff len < 10
validate       evidence: enforced         — passes all 5 predictable-execution gates
report         evidence: enforced         — Console only, no blocking, no allocation
main           evidence: reported         — has blocking I/O through Std
```

The split is the point. Concrete is not pretending the whole program is predictable. It is making the core/shell boundary explicit.

## What The Compiler Reports

The effects/evidence report (`--report effects`) summarizes every function across seven axes: capabilities, allocation, recursion, loop boundedness, FFI, trust, and evidence level.

Evidence levels:

- **proved** — a linked Lean 4 theorem backs the claim
- **enforced** — the compiler can reject violations (passes all 5 predictable gates)
- **reported** — the compiler can classify it but cannot enforce the predictable profile
- **trusted-assumption** — the claim depends on an explicit trust boundary

The predictable profile (`--check predictable`) rejects functions that:

1. recurse or participate in call cycles
2. contain unbounded loops
3. allocate (or declare the Alloc capability)
4. cross FFI boundaries
5. block through file/network/process capabilities

This is per-function, not whole-program.

## The Proof Direction

The compiler is written in Lean 4. The aim is to connect selected Concrete functions to Lean theorems and surface that link in compiler reports.

Today, the first proof slice is live:

1. `parse_byte` correctness: `∀ a b, parse_byte(a, b) = a + b`
2. `check_length` bounds guard: `∀ len < 10, rejects` and `∀ len ≥ 10, accepts`
3. parser-core composition proofs in the packet-decoder proof slice
4. the report shows those functions as `proved`

`--report proof-status` shows proved, stale, missing, ineligible, and trusted-proof-boundary states with source snippets, fingerprints, and hints.

## Why This Is Different

1. **Rust** gives strong memory safety, but most operational properties (does it block? does it allocate? are its loops bounded?) are still implicit.
2. **Zig** gives explicit systems control, but not compiler-visible effects or evidence levels.
3. **SPARK/Ada** gives contracts, proof obligations, and high-assurance workflow, but not a small modern systems surface with explicit function-level authority.
4. **Lean 4** gives theorem proving, but is not a no-GC systems language with explicit authority boundaries.

Concrete is trying to combine: Zig-like explicit systems control, SPARK-like assurance discipline, Lean 4-backed proof, capability-visible architecture, predictable execution checks, and proof-backed evidence tied to compiler artifacts.

## What Validates The Vision

Concrete is only interesting if this becomes an engineering workflow, not just a compiler demo.

The vision is only validated if:

1. a real flagship example shows explicit authority, a predictable core, a proof-backed property, artifact-backed evidence, and drift detection
2. bad changes are caught automatically: widened authority, new allocation, new FFI, new blocking, predictable-profile regressions, stale proofs, or changed obligation/evidence status
3. another engineer can answer audit questions from artifacts and queries without reading compiler internals
4. the artifact story is real: facts, proof registry, obligations, extraction, traceability, drift, and CI gates exist as build artifacts
5. a second example in a different domain also works
6. the workflow remains small enough to use in ordinary bounded systems code
7. performance is acceptable for the target systems use case
8. the trust boundary is honest about what is enforced, reported, proved, or assumed, and where backend/toolchain assumptions begin

Concrete is therefore aiming for an artifact-first workflow:

- the compiler should emit stable facts, evidence, and proof artifacts
- teams should be able to enforce policy from those artifacts
- CI and AI tooling should be able to consume them without scraping human-readable output

## Current State

The compiler implements the full pipeline:

`Parse → Resolve → Check → Elab → CoreCheck → Mono → Lower → EmitSSA → LLVM IR`

What exists:

1. linear type system with ownership, borrowing, and Copy/linear distinction
2. capability and trust-boundary checking
3. unified effects/evidence report
4. predictable-execution profile check
5. parser-core Lean proofs connected to the report
6. a real stdlib (Vec, String, HashMap, Option, Result, ...) and example corpus
7. adversarial tests proving the compiler catches violations

What does not exist yet:

1. broad proof coverage
2. bounded-capacity types
3. stack-depth reporting
4. incremental compilation and package architecture
5. backend plurality

For priorities, see [ROADMAP.md](ROADMAP.md). For landed milestones, see [CHANGELOG.md](CHANGELOG.md).

## Try It

```bash
make build
.lake/build/bin/concrete examples/thesis_demo/src/main.con --report effects
.lake/build/bin/concrete examples/thesis_demo/src/main.con --report proof-status
.lake/build/bin/concrete examples/thesis_demo/src/main.con --check predictable
.lake/build/bin/concrete examples/snippets/hello_world.con -o /tmp/hello && /tmp/hello
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build
make test
make clean
```

## Doc Map

- [docs/IDENTITY.md](docs/IDENTITY.md) — project identity and vision
- [docs/SAFETY.md](docs/SAFETY.md) — the trust and capability model
- [ROADMAP.md](ROADMAP.md) — what is next
- [CHANGELOG.md](CHANGELOG.md) — what landed
- [research/thesis-validation/core-thesis.md](research/thesis-validation/core-thesis.md) — the clearest statement of the thesis
- [research/thesis-validation/objective-matrix.md](research/thesis-validation/objective-matrix.md) — what the flagship examples are meant to prove
- [research/proof-evidence/provable-properties.md](research/proof-evidence/provable-properties.md) — what Concrete should try to prove
- [research/](research/) — design research and future directions
- [docs/](docs/README.md) — full documentation index

## License

Concrete was originally specified and created by Federico Carrone at LambdaClass.

[Apache 2.0](/LICENSE)
