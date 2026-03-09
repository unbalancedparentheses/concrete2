# Compiler Roadmap

## Phase 1: Correctness Foundations

### 1. Layout Alignment — DONE (cd137cb)
- Added `tyAlign`, `alignUp` to `Layout.lean` — natural alignment for all types
- `fieldOffset`, `tySize`, enum payload offsets all use aligned layout
- Builtins/runtime brought into line (Codegen/Builtins.lean, EmitSSA.lean)
- This was the most dangerous silent-correctness gap: mixed-size structs/enums
  were silently corrupted because LLVM alloca used natural alignment while
  our GEP offsets assumed packed (no padding)
- Layout.lean is now a real layout subsystem, not a byte-count helper

### 2. Stricter SSAVerify — DONE
- Instruction-order use-before-def within blocks now checked
- Strict-dominance distinction closes the self-domination loophole
- Phi nodes reject non-predecessor incoming blocks
- SSAVerify is now much closer to a real backend gatekeeper
- Remaining future tightening: richer CFG/type checks if SSA grows more complex

### 3. Resolve: Deepen or Mark Provisional — PARTIALLY DONE
- Resolve now validates imports/exports, deep type references, `Self`, function names, static methods, enum variants, and trait impl completeness
- Bare impl method names were removed from the global scope to avoid false positives
- The remaining intentional boundary: `.methodCall` still belongs to `Check`, because receiver-type information is required

## Phase 2: Simplify

### 4. Delete Legacy Backend
- Remove `Concrete/Codegen/` (~1200 lines) and `--compile-legacy` flag
- **Only after**:
  - Golden tests stay green
  - SSA path remains stable
  - A final confidence pass beyond the standard suite
  - The structured diagnostics migration is far enough along that the fallback is no longer useful for isolating regressions
- 201/201 is necessary but not sufficient

### 5. Harden PASSES.md
- Turn descriptions into enforceable contracts
- Each pass guarantees X; downstream assumes X
- Violations belong to exactly one pass
- Make it the authoritative specification, not just documentation

## Phase 3: Real Diagnostics

### 6. Span Tracking
- DONE for the surface AST and parser
- `Expr` and `Stmt` now carry spans
- Resolve diagnostics now render with source locations
- Remaining work: use the same span plumbing across the rest of the semantic passes and eventually move to range spans

### 7. Structured Error Kinds
- IN PROGRESS
- Resolve now has a structured `ResolveError` layer with stable rendered messages
- Next passes: `Check`, `Elab`, `CoreCheck`, `SSAVerify`
- Build on `Diagnostic.lean` and existing span plumbing

## Phase 4: Language Features

Only after Phases 1-3 are solid.

- `newtype` — zero-cost wrappers with distinct types
- `repr(C)` — explicit C-compatible layout control
- Sharper `unsafe` — tighter boundaries on what unsafe permits

## Current State

- SSA is the default backend (`201/201` main tests, `134/134` SSA tests)
- Layout uses natural alignment (`tyAlign`, `alignUp`, aligned `fieldOffset`/`tySize`)
- Enum payload access uses `enumPayloadOffset` / `variantFieldOffset`, not hardcoded offsets
- AST nodes now carry source spans and the parser populates them from token positions
- Resolve diagnostics now render with line/column and use a structured `ResolveError` layer
- Resolve is materially deeper than before, but method-call resolution still intentionally lives in `Check`
- SSAVerify now checks instruction-order use-before-def within blocks and stricter phi validity
- Legacy codegen still exists as `--compile-legacy` fallback, but only temporarily while diagnostics finish migrating
- `docs/PASSES.md` now documents pass boundaries, and those boundaries should keep tightening as diagnostics and resolution improve
