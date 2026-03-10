# Changelog

This file tracks major completed milestones for Concrete.

It is intentionally milestone-oriented rather than release-oriented. The project is still evolving quickly, so the useful unit of history is “what architectural or language capability landed,” not tagged versions.

For current priorities and remaining work, see [ROADMAP.md](ROADMAP.md).

## Major Milestones

### Compiler architecture

- Replaced the old direct AST backend with the full pipeline:
  `Parse -> Resolve -> Check -> Elab -> CoreCanonicalize -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA -> clang`
- Added explicit Core IR, elaboration, monomorphization, SSA lowering, SSA verification, SSA cleanup, and SSA-consuming codegen
- Removed the legacy AST backend and `--compile-legacy`
- Added `Concrete/Pipeline.lean` with explicit artifact types:
  - `ParsedProgram`
  - `SummaryTable`
  - `ResolvedProgram`
  - `ElaboratedProgram`
  - `MonomorphizedProgram`
  - `SSAProgram`

### Frontend and semantic boundaries

- Established the summary-based frontend with `FileSummary` and `ResolvedImports`
- Split `Resolve` into shallow/interface resolution and body-level name resolution
- Moved most post-elaboration legality checks out of `Check.lean` and into `CoreCheck.lean`
- Made `CoreCheck` the main post-elaboration semantic authority
- Centralized `Self` type resolution via shared helpers

### Diagnostics

- Added structured diagnostic types across semantic passes:
  - `ResolveError`
  - `CheckError`
  - `ElabError`
  - `CoreCheckError`
  - `SSAVerifyError`
- Threaded source spans through the AST/parser
- Added report/inspection modes:
  - `--report caps`
  - `--report unsafe`
  - `--report layout`
  - `--report interface`
  - `--report mono`

### ABI / layout / low-level semantics

- Added `#[repr(C)]` for structs
- Added `#[repr(packed)]` and `#[repr(align(N))]`
- Added `sizeof::<T>()` and `alignof::<T>()`
- Centralized layout logic in `Concrete/Layout.lean`
- Unified FFI-safety checks and LLVM type-definition generation through `Layout`
- Fixed aligned struct/enum layout and enum payload offset handling
- Fixed builtin `Option` / `Result` layout to size payloads from actual instantiations instead of hardcoded `i64` assumptions

### Language capabilities

- Capabilities and capability polymorphism
- Function pointers (closures intentionally omitted)
- Borrow regions
- Linear ownership tracking
- `defer`, `Destroy`, and `Copy`
- Monomorphized trait dispatch
- Multi-file modules and `Self`
- `newtype`
- Raw-pointer `Unsafe` gating for dereference, assignment, and pointer-involving casts

### Runtime-facing builtins

- String builtins
- File I/O builtins
- Networking builtins
- `Vec<T>` and `HashMap<K, V>` builtin/runtime-backed support

### Testing / status milestones

- End-to-end main suite expanded to 266 passing tests
- SSA-specific suite passing
- Golden SSA/IR testing integrated
- CI updated to exercise SSA-specific coverage as well as the main path
