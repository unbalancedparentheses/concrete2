# The Language

Concrete is a low-level language centered on explicit semantics, explicit authority, and auditability.

The current implementation already has:

- structs, enums, functions, modules, methods
- generics and trait-based dispatch
- borrows and mutable borrows
- linear ownership tracking
- capabilities via `with(...)`
- explicit `Unsafe`
- FFI support
- `defer`, `Destroy`, and layout attributes

But the language is still evolving. Some surfaces will continue to tighten as the compiler, stdlib, and execution model mature.

## Design Direction

Concrete is intentionally aiming for:

- a small semantic surface
- explicit effects and authority
- explicit trust boundaries
- compiler architecture that is easy to inspect and eventually prove against

That means the language is not optimized for maximum shorthand or maximum metaprogramming. It is optimized for clarity at the low-level boundary.

## Reading The Language Chapters

The rest of this section introduces the current language shape:

- [Modules](./modules.md)
- [Variables](./variables.md)
- [Functions](./functions.md)
- [Structs](./structs.md)
- [Enums](./enums.md)
- [Control flow](./control_flow.md)

These chapters describe the current implementation direction, not a frozen language reference.
