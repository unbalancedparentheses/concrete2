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

Concrete is a no-GC systems language where the compiler can make four things visible:

1. what a function can touch
2. whether it allocates, blocks, recurses, or runs unboundedly
3. where it crosses trust boundaries
4. whether those claims are reported, enforced, or proved

Short version:

- Rust makes memory safety explicit.
- Lean makes proofs explicit.
- Concrete is trying to make operational power explicit.

## What Concrete Can Show Today

The clearest current example is a packet decoder split into:

1. an I/O shell that is expected to fail the predictable profile
2. a parser core that passes the predictable profile
3. one parser-core function that already appears as `proved` in the report

That means Concrete can already demonstrate, in one example:

1. visible authority boundaries
2. compiler-enforced predictable-core checks
3. compiler-visible evidence levels

## The Packet-Decoder Shape

```con
struct Header {
    version: u8,
    kind: u8,
    len: u16,
}

// Capability-free helper in the parser core.
fn parse_byte(data: Int, offset: Int) -> Int {
    return data + offset;
}

// Predictable parser core: no I/O, no FFI, no blocking.
fn decode_header(buf: &Bytes) -> Result<Header, ParseError> {
    if buf.len() < 4 {
        return Result#Err { error: ParseError#TooShort };
    }

    let version: u8 = buf.get_unchecked(0);
    let kind: u8 = buf.get_unchecked(1);
    let b2: u8 = buf.get_unchecked(2);
    let b3: u8 = buf.get_unchecked(3);
    let len: u16 = ((b2 as u16) << 8) | (b3 as u16);

    if len > buf.len() as u16 {
        return Result#Err { error: ParseError#LengthOutOfBounds };
    }

    return Result#Ok {
        value: Header { version, kind, len }
    };
}
```

The shell does I/O and should fail the predictable profile. The parser core should pass. That split is the point.

## What The Compiler Reports

Concrete is trying to make the function boundary informative enough that you can ask:

1. what authority does this function have?
2. does it allocate?
3. does it recurse?
4. are its loops bounded?
5. does it block?
6. does it cross FFI or trusted boundaries?
7. is the answer merely reported, enforced, or proved?

The effects/evidence report is the center of gravity:

- `reported` — the compiler can classify it
- `enforced` — the compiler can reject violations
- `proved` — a linked Lean theorem backs the claim
- `trusted-assumption` — the claim depends on an explicit trust boundary

## The First Predictable Profile

Concrete now has a first `--check predictable` slice. It rejects functions that:

1. recurse or participate in call cycles
2. contain unbounded or mixed loop classifications
3. allocate
4. cross FFI
5. block through file/network/process-style authority

This is intentionally per-function and per-core, not a fake "whole program must be predictable" story.

## The Proof Direction

The compiler is written in Lean 4. The aim is not only to prove the compiler, but to connect selected Concrete functions to Lean theorems and surface that link back in compiler reports.

Today, the first proof slice is live:

1. a small parser-core function has a Lean theorem
2. the report shows that function as `proved`
3. the packet-decoder example demonstrates the intended end-to-end shape

The next proof step is to move from the helper-level theorem to a real parser-core safety property.

## Why This Is Different

Most systems languages give you some of these, but not all in one place:

1. **Rust** gives strong safety, but most operational properties are still implicit in bodies and callees.
2. **Zig** gives explicit systems control, but not this kind of compiler-visible effects/evidence model.
3. **Lean** gives theorem proving, but it is not trying to be a no-GC systems language with explicit authority boundaries.

Concrete is trying to combine:

1. capability-visible architecture
2. predictable execution checks
3. proof-backed evidence tied to compiler artifacts

## Current Research Center

The current center of gravity is [research/thesis-validation/](research/thesis-validation/):

1. [core-thesis.md](research/thesis-validation/core-thesis.md)
2. [objective-matrix.md](research/thesis-validation/objective-matrix.md)
3. [thesis-validation.md](research/thesis-validation/thesis-validation.md)

Those notes define the current experimental track:

1. capability-visible architecture
2. predictable execution
3. proof-backed evidence

## Current State

The compiler implements the full pipeline:

`Parse -> Resolve -> Check -> Elab -> CoreCheck -> Mono -> Lower -> EmitSSA -> LLVM IR`

What exists:

1. capability and trust-boundary checking
2. a unified effects/evidence report
3. a first predictable-execution profile check
4. a first Lean proof slice connected to the report
5. a real stdlib and example corpus
6. real compiler reports, tests, and example programs

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
