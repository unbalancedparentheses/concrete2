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

### 2. Stricter SSAVerify (NEXT)
- Highest-value correctness pass now that layout is solid
- Instruction-order use-before-def within blocks (not just block dominance)
- Keep dominance checks across blocks
- Make SSAVerify the real backend gatekeeper: if it passes, codegen must succeed
- Consider: type-checking across phi edges, verifying alloca dominance

### 3. Resolve: Deepen or Mark Provisional
- Currently in the critical path but only checks local variable scoping
- Function calls and type references are not validated (deferred to Check)
- Either: extend into a real resolution pass (own full name resolution)
- Or: mark it explicitly provisional and keep it out of critical architectural claims
- Decision depends on how much Check/Elab already cover

## Phase 2: Simplify

### 4. Delete Legacy Backend
- Remove `Concrete/Codegen/` (~1200 lines) and `--compile-legacy` flag
- **Only after**:
  - Golden tests stay green
  - SSA path remains stable
  - A final confidence pass beyond the standard suite
- 201/201 is necessary but not sufficient

### 5. Harden PASSES.md
- Turn descriptions into enforceable contracts
- Each pass guarantees X; downstream assumes X
- Violations belong to exactly one pass
- Make it the authoritative specification, not just documentation

## Phase 3: Real Diagnostics

### 6. Span Tracking
- Thread `Span` (line/col) through `Expr`/`Stmt` AST nodes from the parser
- Populate `Diagnostic.span` — every error gets `file:line:col`
- Biggest UX improvement possible

### 7. Structured Error Kinds
- Replace stringly pass errors with per-pass error enums
- Enables: machine-readable errors, IDE integration, suggested fixes
- Build on `Diagnostic.lean` infrastructure already in place

## Phase 4: Language Features

Only after Phases 1-3 are solid.

- `newtype` — zero-cost wrappers with distinct types
- `repr(C)` — explicit C-compatible layout control
- Sharper `unsafe` — tighter boundaries on what unsafe permits

## Current State (post cd137cb)

- SSA is the default backend (201/201 legacy, 134/134 SSA)
- Layout.lean uses natural alignment (tyAlign, alignUp, aligned fieldOffset/tySize)
- Enum payload access uses enumPayloadOffset/variantFieldOffset, not hardcoded offsets
- Diagnostic.lean wraps string errors (no spans yet)
- Resolve.lean checks local vars only
- SSAVerify checks dominance but not instruction order
- Legacy codegen still exists as `--compile-legacy` fallback
- docs/PASSES.md documents all 10 passes (descriptions, not contracts)
