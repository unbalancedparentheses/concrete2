# Why Concrete

Concrete is a low-level language optimized for auditability, explicit trust, and proof-friendly compiler architecture.

It is not trying to win by having the most features. Its intended strength is that important low-level properties stay explicit enough to inspect, report, audit, and eventually prove.

## What Makes It Different

### Auditability

Concrete should become unusually good at showing:

- where authority enters
- where allocation happens
- where cleanup happens
- where `trusted` enters
- what layout/ABI a type really has
- what monomorphized code actually exists

### Explicit Trust

Concrete treats trust and authority as explicit language/compiler surfaces:

- capabilities
- `Unsafe`
- `trusted fn`
- `trusted impl`
- `trusted extern fn`
- audit/report outputs

### Small Semantic Surface

Concrete is trying to stay small enough that:

- ordinary names are ordinary
- semantics are explicit
- compiler magic is minimized
- the trusted computing base stays easier to reason about

### Proof-Friendly Structure

The compiler is being shaped around:

- clear Core semantics
- SSA as a real backend boundary
- explicit pass structure
- formalization targets that match the architecture

## What Concrete Is Not Trying To Be

Concrete is not primarily trying to out-compete:

- Rust on macro power or ecosystem scale
- Zig on comptime or cross-compilation ergonomics
- Odin on minimal syntax alone
- other systems languages on feature count for its own sake

The goal is a language that is unusually explicit, inspectable, and honest.

## Start Here

- Read the repository [README](../../../README.md)
- Read the project [identity doc](../../IDENTITY.md)
- Check the [roadmap](../../../ROADMAP.md)
- Check the [changelog](../../../CHANGELOG.md)
