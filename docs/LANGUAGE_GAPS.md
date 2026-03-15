# Language Gaps Discovered During Phase H

Gaps found while writing the first real program (policy engine, `examples/policy_engine/`). Each claim has been fact-checked against the codebase and corrected where wrong.

## True Blockers

### 1. Enum fields in structs panic the layout engine (Bug 005)

The natural domain model:

```con
struct Copy Rule {
    action: Action,      // enum
    verdict: Verdict,    // enum
    principal: i32,
}
```

Panics in `Layout.tyAlign` when the struct is stored in `Vec<Rule>`. Workaround: flatten enums to `i32` tags.

**Effect:** Pushes programs toward C-style integer encoding instead of using the type system. This is the single biggest gap.

### 2. Standalone programs lack an always-available print path (Bug 007)

The stdlib has correct, capability-annotated `print`/`println` in `std/src/io.con:57-71`. But standalone `.con` files compiled without a `Concrete.toml` project cannot `import std.io` — the module is unresolvable.

The usable path lives in stdlib/project setup rather than in an always-available surface. This blocks Phase H examples from producing output without handwritten `trusted extern fn putchar` boilerplate.

**What exists:** `std.io.{print, println, eprint, eprintln}` with `Console` capability.
**What doesn't exist:** A way for standalone files to reach them, or a compiler builtin equivalent.

### 3. No string formatting or interpolation

Building `"[ALLOW] admin read source_code"` requires 7 chained `string_concat` calls. No `format(pattern, ...)` or string interpolation exists.

**Effect:** String-heavy code is verbose and error-prone. Every intermediate string is a potential leak if cleanup is missed.

## Real Ergonomic Pain (Not Blockers)

### 4. If-else is a statement, not an expression (Bug 008)

```con
// Can't do:
let label: String = if v == 1 { "ALLOW" } else { "DENY" };

// Must write:
let mut label: String = "DENY";
if v == 1 { label = "ALLOW"; }
```

Confirmed: `AST.lean` defines `ifElse` only in `inductive Stmt`, not `inductive Expr`.

### 5. No qualified name access across modules

When two modules export functions with the same name (e.g., `from_tag`), there's no way to disambiguate except renaming one. `Module.function()` syntax does not exist. Confirmed: call expressions take a plain `String` name, not a qualified path.

### 6. Const declarations are parsed but broken at SSA lowering (Bug 009)

`const foo: i32 = 10;` parses but produces "use of undefined register %foo" at compile time. Constants exist in the grammar but don't lower. Workaround: `fn FOO() -> i32 { return 0; }`.

### 7. No destructuring let

`let (a, b) = ...;` is not supported. `parseLet` only expects a single identifier.

## Not Actually Missing (Previously Claimed Incorrectly)

- **print/println** — Exists in stdlib (`std.io`). The gap is standalone access, not absence.
- **Constants** — `const` is in the parser and grammar. The gap is a lowering bug (009), not a missing feature.
- **`&&` / `||`** — Work correctly. Used throughout tests (e.g., `lean_tests/integration_text_processing.con:31`).
- **Enums as values** — Work generally. The gap is specifically enum fields inside structs (Bug 005).

## Summary

The top 3 findings from Phase H:
1. **Fix enum-in-struct layout (Bug 005)** — unblocks natural domain modeling
2. **Provide a print path for standalone programs (Bug 007)** — unblocks real examples producing output
3. **Add string formatting** — cuts string-building verbosity by 5-7x
