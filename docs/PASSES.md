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

**Preconditions:**
- Syntactically valid AST from Parse with module files resolved.

**Postconditions:**
- All name references validated: function calls, struct/enum literals, static method calls, function references, variable identifiers.
- Deep type validation: all type names in annotations, parameters, return types, generics, refs, arrays, and function pointer types are known.
- `Self` only used inside impl/trait-impl blocks.
- Trait impl completeness checked: all required methods provided (name-level, not signature-level).
- Import validation: imported modules exist, imported symbols are public.
- Submodule definitions registered in global scope.

**What Resolve does NOT check:**
- **Instance method calls (`.methodCall`)** are skipped entirely. The method name depends on the receiver type, which is only known after type checking. This is an intentional boundary — method resolution requires type information that only Check can provide.
- **Trait impl signature compatibility** — Check owns parameter/return type agreement.
- **Type correctness** — Resolve only checks that names exist, not that types are used correctly.

**Error conditions:**
- Unknown function, struct type, enum, enum variant, static method, function reference.
- Unknown type name in any type position.
- `Self` outside impl block.
- Trait impl missing a required method or referencing unknown trait.
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

**Invariant established:** Types consistent, linearity valid, capabilities valid. All names resolve within module scopes.

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

**Error conditions:**
- None (pure transformation, always succeeds).

**Invariant established:** Types normalized, match arms sorted, struct fields in definition order.

---

## 6. CoreCheck

**Signature:** `coreCheckProgram : List CModule → Except String Unit`

**Preconditions:**
- Canonicalized Core IR.

**Postconditions:**
- Capability discipline re-validated at Core level: caller capSet ⊇ callee capSet.
- Operand types match operators (numeric ops on numeric types, etc.).
- Match expressions cover all enum variants (or have wildcard).
- `break`/`continue` only inside loops.

**Error conditions** (all errors use the structured `CoreCheckError` inductive, rendered to identical strings via `CoreCheckError.message`):
- Insufficient capabilities for callee.
- Type mismatch on operator arguments.
- Incomplete match coverage.
- `break`/`continue` outside loop context.

**Invariant established:** Capabilities valid in Core IR, operand types match, match coverage complete.

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

## Cross-Pass Invariants

| Property | Established by | Relied upon by |
|----------|---------------|----------------|
| Syntactic validity | Parse | All subsequent passes |
| Name resolution | Resolve | Check, Elab (names exist, imports valid) |
| Type consistency | Check | Elab, CoreCheck |
| Linearity | Check | (enforced at surface level) |
| Capabilities | Check, CoreCheck | EmitSSA (no runtime checks) |
| Full type annotations | Elab | Mono, Lower, EmitSSA |
| No type variables | Mono | Lower, EmitSSA |
| SSA form / dominance | Lower, SSAVerify | SSACleanup, EmitSSA |
| No dead blocks | SSACleanup | EmitSSA |
