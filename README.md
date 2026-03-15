<div align="center">
<img src="./logo.png" height="150" style="border-radius:20%">

# The Concrete Programming Language
[![CI](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml/badge.svg)](https://github.com/unbalancedparentheses/concrete2/actions/workflows/lean_action_ci.yml)
[![Telegram Chat][tg-badge]][tg-url]
[![license](https://img.shields.io/github/license/lambdaclass/concrete)](/LICENSE)

[tg-badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftg.sumanjay.workers.dev%2Fconcrete_proglang%2F&logo=telegram&label=chat&color=neon
[tg-url]: https://t.me/concrete_proglang

</div>

Status: project entry point

>Most ideas come from previous ideas - Alan C. Kay, The Early History Of Smalltalk

Concrete is a systems programming language for **correctness-focused low-level work**. The design rule is simple: if the compiler cannot explain what a feature means, the feature probably does not belong. The language stays explicit, LL(1)-parseable, and hostile to hidden control flow.

Concrete is not trying to win by piling on features. Its real pitch is **auditable low-level programming with explicit authority and trust boundaries, built on a small language and a proof-friendly compiler**.

In practice, that means:

- visible capabilities instead of ambient effects
- visible `trusted` and `Unsafe` boundaries instead of hand-wavy escape hatches
- explicit ownership and cleanup instead of hidden runtime behavior
- compiler artifacts and reports that try to explain what the program means

The compiler is written in [Lean 4](https://leanprover.github.io/lean4/doc/setup.html), and the long-term goal is two-layered:

- prove properties of the language/compiler itself
- prove selected Concrete programs through explicit Core semantics

For the longer identity and proof story, see [docs/IDENTITY.md](docs/IDENTITY.md) and [research/proving-concrete-functions-in-lean.md](research/proving-concrete-functions-in-lean.md).

## Current Stage

Concrete is past the "interesting design" stage and into "serious language project with real architecture."

What is already real:

- a complete internal compiler pipeline with explicit artifacts such as `ValidatedCore` and `ProofCore`
- a coherent safety model built around capabilities, `trusted`, `Unsafe`, and compiler reports
- a structured LLVM backend with SSA verification and documented backend contracts
- an initial Lean-side proof workflow over a pure Core fragment
- a large regression suite covering the compiler, stdlib, reports, ABI edges, and optimization-sensitive cases

What is not proven yet:

- large-program ergonomics under sustained use
- package/workspace workflow
- operational maturity as a long-term language toolchain
- broader formalization beyond the current pure proof fragment

That is why the next major phase is [Phase H](ROADMAP.md): large-program pressure testing and performance validation. The next proof point is not another small feature. It is whether Concrete stays readable, explicit, and fast enough when it has to carry real software.

## What Concrete Looks Like

These are the kinds of boundaries Concrete tries to make obvious in source code.
The interesting claim is mechanical, not rhetorical: the verifier below can read a manifest, but it cannot silently grow `Network` or `Process`, and the raw C edge stays inside one small trusted wrapper.

Pure policy core:

```con
struct ManifestMeta {
    size: Int,
    version: Int,
    requests_network: Bool,
}

enum Decision {
    Allow,
    Deny,
}

fn approve_manifest(meta: ManifestMeta, expected_size: Int, max_version: Int) -> Decision {
    if meta.requests_network {
        return Decision#Deny;
    }
    if meta.version > max_version {
        return Decision#Deny;
    }
    if meta.size != expected_size {
        return Decision#Deny;
    }
    return Decision#Allow;
}
```

Audited low-level wrapper:

```con
trusted extern fn fopen(name: *mut u8, mode: *mut u8) -> *const u8;
trusted extern fn fclose(file: *const u8) -> i32;
trusted extern fn fseek(file: *const u8, offset: i64, whence: i32) -> i32;
trusted extern fn ftell(file: *const u8) -> i64;
trusted extern fn malloc(size: u64) -> *mut u8;
trusted extern fn free(ptr: *mut u8);

// helper functions like string_to_cstr(...) and mode_cstr(...)
// stay inside the trusted wrapper layer too.
// Parsing details are omitted here; the point is the boundary shape.
trusted fn load_manifest_meta(path: &String) with(File) -> ManifestMeta {
    let path_buf: *mut u8 = string_to_cstr(path);
    let mode_buf: *mut u8 = mode_cstr(114); // "r"
    let fp: *const u8 = fopen(path_buf, mode_buf);
    free(mode_buf);
    free(path_buf);
    fseek(fp, 0, 2);
    let size: i64 = ftell(fp);
    fclose(fp);
    return ManifestMeta {
        size: size as Int,
        version: 1,
        requests_network: false,
    };
}

fn verify_update(path: &String, expected_size: Int, max_version: Int) with(File) -> Decision {
    let meta: ManifestMeta = load_manifest_meta(path);
    return approve_manifest(meta, expected_size, max_version);
}
```

Explicit resource cleanup:

```con
struct AuditHandle { fd: Int }

impl Destroy for AuditHandle {
    fn destroy(&self) {
        // close the descriptor here
    }
}

fn inspect_handle(h: AuditHandle) -> Int {
    defer destroy(h);
    return h.fd;
}
```

These examples show why Concrete is aimed at critical low-level components instead of general convenience:

- the decision logic is pure and testable on its own
- the verifier's authority is explicit: `with(File)` and nothing else
- the raw C boundary is concentrated inside a small trusted wrapper instead of leaking everywhere
- cleanup is written in the function body with `defer destroy(...)`, not hidden in a runtime or convention
- the compiler surface makes a stronger audit claim than Rust, Zig, or C usually do by default: where authority exists, where trust starts, and where cleanup happens

For more examples, see [`examples/`](examples).

## Why Concrete Exists

Concrete was created to close a gap between low-level programming and mechanized reasoning.

Most systems languages optimize for control, performance, and interoperability, but they leave many important questions harder to answer mechanically than they should be. Concrete is trying to make those questions easier:

- what authority it has
- where resources are created and destroyed
- where `Unsafe` and `trusted` boundaries exist
- what the compiler actually means by the program

Lean 4 matters here because it gives Concrete a credible path to proving both compiler properties and selected user programs, without turning the implementation language itself into a proof assistant. The deeper version of that story lives in [docs/IDENTITY.md](docs/IDENTITY.md).

## Where Concrete Fits

Concrete is not trying to replace Rust, C++, or Go as a general-purpose systems language. Its strongest case is narrower: software that must be small, explicit, reviewable, and honest about power.

The most compelling targets are mission-critical components with narrow authority and clear trust boundaries, for example:

- boot, update, and artifact verification tools
- key-handling and cryptographic policy helpers
- policy engines and authorization layers
- configuration, manifest, and protocol validators
- safety/security guard processes with tightly bounded behavior
- audited wrappers around critical C libraries or hardware interfaces
- small supervisory/control kernels inside larger systems

If the full roadmap lands, the more interesting destination is not only "safer CLI tools." It is small high-consequence components such as:

- spacecraft or satellite command gatekeepers
- industrial control safety interlocks
- medical-device policy kernels
- secure update and attestation roots
- cryptographic control-plane decision cores
- cross-domain or high-assurance data-release policy engines

This is the kind of software where Concrete should eventually offer something meaningfully different from Rust: not a broader ecosystem, but a stronger story around explicit authority, auditable trust boundaries, restricted profiles, and proof/evidence-friendly compilation.

Concrete is a poor fit for software that mainly wins from ecosystem breadth, heavy async frameworks, or very large general-purpose application stacks. The goal is not "systems language for everything." The goal is "systems language for software that must be explicit enough to inspect, constrain, and trust."

## Why Not Rust, Zig, or C?

Because Concrete is trying to optimize for a different balance.

- **Compared to Rust:** Concrete is aiming for a smaller surface, less abstraction machinery, more explicit authority, and a compiler architecture that is easier to audit and formalize.
- **Compared to Zig:** Concrete shares the low-level explicitness, but pushes harder on ownership discipline, capability tracking, and proof-oriented structure.
- **Compared to C:** Concrete wants the same kind of low-level reach without leaving ownership, effects, and trust boundaries to convention.

The goal is not to out-feature those languages. The goal is to be unusually good at auditable, correctness-focused systems code.

## Doc Map

- [docs/README.md](docs/README.md) — stable documentation index
- [docs/IDENTITY.md](docs/IDENTITY.md) — project identity, differentiators, and current maturity
- [ROADMAP.md](ROADMAP.md) — active and future work
- [CHANGELOG.md](CHANGELOG.md) — completed milestones
- [docs/TESTING.md](docs/TESTING.md) — test structure and verification layers
- [research/README.md](research/README.md) — exploratory design notes

## Try It Now

```bash
make build
.lake/build/bin/concrete input.con -o output && ./output
```

Concrete already enforces linearity. The compiler rejects programs that forget or reuse resources:

```
struct Resource { value: Int }

fn consume(r: Resource) -> Int {
    return r.value;
}

fn main() -> Int {
    let r: Resource = Resource { value: 42 };
    let v: Int = consume(r);  // r is consumed here
    // Using r again: compile error "linear variable 'r' used after move"
    // Forgetting to use r: compile error "linear variable 'r' was never consumed"
    return v;
}
```

## Building

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) (v4.28.0+) and clang.

```bash
make build    # or: lake build
make test     # runs the full test suite
make clean    # or: lake clean
```

## License

Concrete was originally specified and created by Federico Carrone at LambdaClass.

[Apache 2.0](/LICENSE)
