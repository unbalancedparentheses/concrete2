# Compiler Pass Contracts

This document describes each pass in the Concrete compiler pipeline, its signature, preconditions, postconditions, error conditions, and the invariant it establishes.

## Pipeline Overview

```
Source Text
    │
    ▼
  Parse ─── String → List Module
    │
    ▼
  Resolve ── List Module → List ResolvedModule
    │
    ▼
  Check ─── List Module → Unit
    │
    ▼
  Elab ──── List Module → List CModule
    │
    ▼
  CoreCanonicalize ── List CModule → List CModule
    │
    ▼
  CoreCheck ── List CModule → Unit
    │
    ▼
  Mono ──── List CModule → List CModule
    │
    ▼
  Lower ─── CModule → SModule
    │
    ▼
  SSAVerify ── List SModule → Unit
    │
    ▼
  SSACleanup ── List SModule → List SModule
    │
    ▼
  EmitSSA ── List SModule → String (LLVM IR)
    │
    ▼
  clang ─── executable
```

---

## 1. Parse

**Signature:** `parse : String → Except String (List Module)`

**Preconditions:**
- Input is a UTF-8 source string.

**Postconditions:**
- All tokens consumed. AST is syntactically well-formed.
- Module hierarchy (submodules) preserved.
- No semantic validation performed.

**Error conditions:**
- Unexpected token, unterminated string, mismatched brackets/braces.
- Nested generic ambiguity handled (`>>` split into `> >`).

**Invariant established:** Syntactically valid AST with all tokens consumed.

---

## 2. Resolve

**Signature:** `resolveProgram : List Module → Except Diagnostics (List ResolvedModule)`

Resolve is strictly a shallow/interface validation pass. It operates on `FileSummary` artifacts and surface AST — it never inspects function bodies for declaration-level information and does not perform any post-elaboration semantic checks.

**Preconditions:**
- Syntactically valid AST from Parse with module files resolved.
- `FileSummary` artifacts built for all modules (via `buildSummaryTable`).

**Postconditions:**
- All name references validated: function calls, struct/enum literals, static method calls, function references, variable identifiers.
- Deep type validation: all type names in annotations, parameters, return types, generics, refs, arrays, and function pointer types are known.
- `Self` only used inside impl/trait-impl blocks.
- Import validation: imported modules exist, imported symbols are public.
- Submodule definitions registered in global scope.

**What Resolve does NOT check:**
- **Instance method calls (`.methodCall`)** are skipped entirely. The method name depends on the receiver type, which is only known after type checking. This is an intentional boundary — method resolution requires type information that only Check can provide.
- **Trait impl completeness** — CoreCheck owns this (validates all required methods provided and signatures match, operating on Core IR after elaboration).
- **Trait impl signature compatibility** — CoreCheck owns this too.
- **Type correctness** — Resolve only checks that names exist, not that types are used correctly.
- **FFI safety, repr validation, Copy/Destroy rules** — all declaration-level semantic checks that can be stated on Core IR belong in CoreCheck.

**Error conditions** (all errors use the structured `ResolveError` inductive with span-bearing `Diagnostic` output via `Diagnostic.render`):
- Unknown function, struct type, enum, enum variant, static method, function reference.
- Unknown type name in any type position.
- `Self` outside impl block.
- Import referencing unknown module or non-public symbol.

**Invariant established:** All name references resolve to known definitions. Types are named validly. Imports reference existing public symbols.

---

## 3. Check

**Signature:** `checkProgram : List Module → Except String Unit`

**Preconditions:**
- Syntactically valid AST from Parse.
- All names validated by Resolve (no unknown functions, types, or imports).

**Postconditions:**
- Types are consistent across expressions, statements, and function signatures.
- Linearity discipline enforced: linear variables consumed exactly once.
- Capability discipline validated: callers possess required capabilities.
- `defer` and borrow blocks are well-formed.
- Cross-module imports resolved via export tables.

**Error conditions** (all errors use the structured `CheckError` inductive, rendered to identical strings via `CheckError.message`):
- Type mismatch, undeclared variable/function/type.
- Linear variable double-consumed or left unconsumed.
- Missing capability for effect-requiring calls.
- Invalid borrow nesting, consuming borrowed references.

**Invariant established:** Types consistent, linearity valid, capabilities valid, FFI-safe types at extern boundaries. All names resolve within module scopes.

**FFI safety validation:**
- `#[repr(C)]` structs cannot have type parameters.
- All fields of `#[repr(C)]` structs must be FFI-safe types.
- All `extern fn` parameters and return types must be FFI-safe.
- FFI-safe types: integer types, float types, Bool, Char, `()`, raw pointers (`*mut T`, `*const T`), and `#[repr(C)]` structs.

**Unsafe boundary validation:**
- Dereferencing raw pointers (`*ptr` on `*mut T` or `*const T`) requires `Unsafe` capability.
- Assigning through raw pointers (`*ptr = val` on `*mut T`) requires `Unsafe` capability.
- Pointer-involving casts require `Unsafe` capability: pointer-to-pointer, pointer-to-integer, integer-to-pointer, array-to-pointer, pointer-to-reference.
- Reference-to-pointer casts (`&x as *const T`, `&mut x as *mut T`) are safe and do not require `Unsafe`, since they preserve compiler-known provenance.

---

## 4. Elab (Elaboration)

**Signature:** `elabProgram : List Module → Except String (List CModule)`

**Preconditions:**
- Check has passed (types and linearity validated).

**Postconditions:**
- Surface AST desugared to Core IR (`CModule`/`CExpr`/`CStmt`).
- All expressions carry full type annotations.
- Method calls desugared to plain function calls.
- Arrow expressions desugared.
- `for` loops desugared to `while` with iterators.
- Trait method resolution applied.
- Cross-module import resolution via export tables.

**Error conditions** (all errors use the structured `ElabError` inductive, rendered to identical strings via `ElabError.message`):
- Unresolved trait method, unknown type in elaboration context.
- Import resolution failures.

**Invariant established:** Fully type-annotated Core IR. Methods/arrows/for desugared. Generic type parameters still present.

---

## 5. CoreCanonicalize

**Signature:** `canonicalizeProgram : List CModule → List CModule`

**Preconditions:**
- Valid Core IR from Elab.

**Postconditions:**
- Types normalized: `Ty.generic "Heap" [t]` → `Ty.heap t`, etc.
- Match arms sorted: specific constructors before wildcards/variables.
- Struct literal fields reordered to match definition order.
- Function signatures and expressions normalized.
- Submodules recursively canonicalized (trait defs, trait impls, types in submodule declarations are all normalized).

**Error conditions:**
- None (pure transformation, always succeeds).

**Invariant established:** Types normalized, match arms sorted, struct fields in definition order. Applies uniformly across top-level modules and all nested submodules.

---

## 6. CoreCheck

**Signature:** `coreCheckProgram : List CModule → Except String Unit`

CoreCheck is the post-elaboration semantic authority. It owns all legality rules that can be stated on Core IR, including both function-body validation and declaration-level checks. It recursively processes submodules, so declaration checks apply uniformly to inline `mod X { ... }` blocks.

**Preconditions:**
- Canonicalized Core IR.

**Postconditions:**
- Capability discipline re-validated at Core level: caller capSet ⊇ callee capSet.
- Operand types match operators (numeric ops on numeric types, etc.).
- Core-level capability requirements are enforced for lowered operations, builtins, and extern calls.
- Return statements agree with the elaborated function return type.
- Match structure is validated after elaboration, including wrong-enum arms, duplicate variants, and variant field-count agreement.
- Match expressions cover all enum variants (or have wildcard).
- `break`/`continue` only inside loops.
- Declaration-level checks validated across all modules and submodules:
  - Copy/Destroy conflict detection.
  - Copy struct fields must be Copy types.
  - `#[repr(C)]` validation (no generics, FFI-safe fields).
  - `#[repr(packed)]`/`#[repr(align(N))]` conflict and power-of-two checks.
  - Extern fn parameter and return type FFI safety.
  - Builtin trait (`Destroy`) redeclaration prevention.
  - Reserved function name detection.
  - Trait impl completeness: all required methods provided, return type signatures match trait definition.
  - Unknown trait detection.

**Error conditions** (all errors use the structured `CoreCheckError` inductive, rendered to identical strings via `CoreCheckError.message`):
- Insufficient capabilities for callee.
- Type mismatch on operator arguments.
- Missing capability for a Core-level builtin or operation.
- Return type mismatch.
- Incomplete match coverage.
- Wrong enum variant used in match.
- Duplicate match arm.
- Wrong field count for enum variant arm.
- `break`/`continue` outside loop context.
- Copy/Destroy conflict, non-Copy field in Copy struct.
- `#[repr(C)]` with generics, non-FFI-safe fields.
- `#[repr(packed)]` + `#[repr(align)]` conflict, non-power-of-two alignment.
- Non-FFI-safe extern fn parameters/return types.
- Builtin trait redeclared, unknown trait, missing trait method, trait method signature mismatch.
- Reserved function name.

**Invariant established:** Capabilities valid in Core IR, operand types match, return types agree, match structure/coverage valid, declaration-level trait/FFI/repr rules satisfied. All checks apply uniformly across top-level modules and nested submodules.

---

## 7. Mono (Monomorphization)

**Signature:** `monoProgram : List CModule → Except String (List CModule)`

**Preconditions:**
- CoreCheck has passed.

**Postconditions:**
- No type variables remain in any function body.
- All generic function calls instantiated with concrete types.
- Monomorphized function copies appended to module (e.g., `fn_for_i32_bool`).
- Original generic functions retained but unreferenced by concrete code.

**Error conditions:**
- Unbounded polymorphic recursion (infinite specialization).

**Invariant established:** All generics fully instantiated. No type variables in emitted code.

---

## 8. Lower

**Signature:** `lowerModule : CModule → SModule`

**Preconditions:**
- Monomorphized Core IR (no type variables).

**Postconditions:**
- Structured control flow (if/else, while, for, match) converted to basic blocks with branches.
- SSA form: each variable assignment produces a unique register.
- Phi nodes inserted at control flow merge points.
- String literals extracted as globals.
- Generic functions filtered out (only concrete/monomorphized lowered).
- Every block has exactly one terminator (`br`, `condBr`, `ret`, `unreachable`).

**Error conditions:**
- None at the API level (pure transformation). Internal `LowerM` may fail on unknown types/struct lookups.

**Invariant established:** SSA form with explicit blocks, branches, phi nodes. Control flow fully linearized.

---

## 9. SSAVerify

**Signature:** `ssaVerifyProgram : List SModule → Except String Unit`

**Preconditions:**
- SSA IR from Lower.

**Postconditions:**
- Every block has exactly one terminator.
- All register uses dominated by their definitions.
- Phi node incoming values come from correct predecessor blocks.
- All branch targets reference existing block labels.
- Phi nodes have entries for all predecessor blocks.
- No duplicate register definitions within a block.

**Error conditions** (all errors use the structured `SSAVerifyError` inductive, rendered to identical strings via `SSAVerifyError.message`):
- Use-before-def (register used without dominating definition).
- Branch to non-existent label.
- Phi missing entry for a predecessor.
- Duplicate register definition.
- Block with no terminator or multiple terminators.

**Invariant established:** Dominance correct, branch targets valid, phi coverage complete, no duplicate defs.

---

## 10. SSACleanup

**Signature:** `ssaCleanupProgram : List SModule → List SModule`

**Preconditions:**
- SSAVerify has passed.

**Postconditions:**
- Dead (unreachable) blocks eliminated.
- Trivial phi nodes (single incoming value) replaced with direct register use.
- Empty blocks (containing only an unconditional branch) folded by redirecting predecessors.
- Semantics preserved.

**Error conditions:**
- None (pure transformation, always succeeds).

**Invariant established:** Dead blocks, trivial phis, and empty blocks removed. SSA form maintained.

---

## 11. EmitSSA

**Signature:** `emitSSAProgram : List SModule → String`

**Preconditions:**
- Cleaned-up SSA IR (all modules verified and optimized).

**Postconditions:**
- Valid LLVM IR text emitted.
- Struct and enum type definitions generated.
- String literal globals emitted.
- All user functions emitted with correct LLVM signatures.
- Builtin functions (Vec, HashMap, String ops) included.
- `main` wrapper generated for entry point.
- External declarations (malloc, free, printf, etc.) emitted.

**Error conditions:**
- None at the API level (pure string generation).

**Invariant established:** Well-formed LLVM IR text suitable for clang compilation.

---

## Artifact Flow

The compiler produces explicit, stable artifacts at each stage. Since the introduction of `Concrete/Pipeline.lean`, each boundary is a named artifact type with a composable runner function:

```
Source Text
    │
    ▼
  Pipeline.parse ─── String → ParsedProgram (List Module)
    │
    ▼
  Pipeline.resolveFiles ─── IO, reads sub-module files → ParsedProgram
    │
    ▼
  Pipeline.buildSummary ─── ParsedProgram → SummaryTable (List (String × FileSummary))
    │
    ├─→ FileSummary: declaration-level cross-file interface
    │     (function sigs, extern sigs, impl method sigs, structs, enums,
    │      traits, constants, type aliases, newtypes, imports, public names)
    │
    ├─→ ResolvedImports: per-module import artifact
    │     (imported functions, structs, enums, impl blocks, trait impls,
    │      impl method sigs — all resolved from FileSummary)
    │
    ▼
  Pipeline.resolve ─── ParsedProgram × SummaryTable → ResolvedProgram (List ResolvedModule)
    │
    ▼
  Pipeline.check ─── ParsedProgram × SummaryTable → Unit
    │
    ▼
  Pipeline.elaborate ─── ParsedProgram × SummaryTable → ElaboratedProgram (List CModule)
    │                     (includes elab + canonicalize + core-check)
    ▼
  Pipeline.monomorphize ─── ElaboratedProgram → MonomorphizedProgram (List CModule)
    │
    ▼
  Pipeline.lower ─── MonomorphizedProgram → SSAProgram (List SModule)
    │                  (includes lower + verify + cleanup)
    ▼
  Pipeline.emit ─── SSAProgram → String (LLVM IR)
    │
    ▼
  clang → executable
```

`Pipeline.runFrontend` composes the shared prefix (parse → resolveFiles → buildSummary → resolve → check → elaborate) used by all three CLI entry points.

`FileSummary` is the single cross-file interface artifact for the current frontend architecture phase. All passes consume signatures and type declarations from it rather than rebuilding their own views from raw ASTs. `ResolvedImports` is the single import artifact consumed by Check and Elab — it is built once from the summary table and shared, not rebuilt ad hoc in each pass.

`Layout` is the single source of truth for type sizes, alignment, field offsets, pass-by-pointer decisions, `Ty` → LLVM type mappings, LLVM type definition generation (`structTypeDef`, `enumTypeDefs`, `builtinTypeDefs`), and FFI-safety checks (`isFFISafe`). Both EmitSSA and CoreCheck delegate to Layout rather than maintaining their own layout or type-emission logic.

`Report` is the current audit/inspection surface over the pipeline:
- `--report interface` consumes `FileSummary`
- `--report caps`, `unsafe`, and `layout` consume canonicalized Core
- `--report mono` compares pre- and post-monomorphization Core modules

These reports are intended as compiler-facing audit outputs, not as a second semantic pipeline.

**Note:** `FileSummary` and `ResolvedImports` currently carry full impl/trait-impl blocks with method bodies (not just signatures). Check and Elab need these to type-check and elaborate imported method implementations. Splitting into interface-only and body portions is a future incremental-compilation concern, not a current blocker.

---

## Cross-Pass Invariants

| Property | Established by | Relied upon by |
|----------|---------------|----------------|
| Syntactic validity | Parse | All subsequent passes |
| FileSummary (declaration-level interface) | buildSummaryTable | Resolve, Check, Elab |
| ResolvedImports (per-module import artifact) | resolveImportsFromTable | Check, Elab |
| Name resolution, import validity | Resolve | Check, Elab (names exist, imports valid) |
| Type consistency | Check | Elab, CoreCheck |
| Linearity | Check | (enforced at surface level) |
| Capabilities | Check (cap-polymorphic calls), CoreCheck | EmitSSA (no runtime checks) |
| Return type agreement after elaboration | CoreCheck | Lower, EmitSSA |
| Match shape and coverage after elaboration | CoreCheck | Lower |
| Declaration-level legality (trait/FFI/repr) | CoreCheck | Lower, EmitSSA |
| Full type annotations | Elab | Mono, Lower, EmitSSA |
| No type variables | Mono | Lower, EmitSSA |
| SSA form / dominance | Lower, SSAVerify | SSACleanup, EmitSSA |
| No dead blocks | SSACleanup | EmitSSA |
