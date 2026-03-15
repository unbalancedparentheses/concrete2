# Language Gaps Discovered During Phase H

Gaps found while writing the first real programs (`examples/policy_engine/` and `examples/mal/`). Each claim has been fact-checked against the codebase and corrected where wrong.

## True Blockers

### ~~1. Enum fields in structs panic the layout engine (Bug 005)~~ — FIXED

**Status:** Fixed. Enum fields in structs now work correctly, including in `Vec<Rule>` and similar containers. The layout engine handles enum alignment properly.

### 2. Standalone programs lack an always-available print path (Bug 007)

The stdlib has correct, capability-annotated `print`/`println` in `std/src/io.con:57-71`. But standalone `.con` files compiled without a `Concrete.toml` project cannot `import std.io` — the module is unresolvable.

The usable path lives in stdlib/project setup rather than in an always-available surface. This blocks Phase H examples from producing output without handwritten `trusted extern fn putchar` boilerplate.

**What exists:** `std.io.{print, println, eprint, eprintln}` with `Console` capability.
**What doesn't exist:** A way for standalone files to reach them, or a compiler builtin equivalent.

### 3. No string formatting or interpolation

Building `"[ALLOW] admin read source_code"` requires 7 chained `string_concat` calls. No `format(pattern, ...)` or string interpolation exists.

**Effect:** String-heavy code is verbose and error-prone. Every intermediate string is a potential leak if cleanup is missed.

### 4. No substring extraction path (Bug 010)

MAL exposed a real parser/reader gap: there is no normal way to extract a substring from a source string. Reader code naturally wants to slice tokens out of the input, but Concrete currently has only low-level inspection helpers (`string_length`, `string_char_at`) and concatenation.

**Effect:** Parsers must fall back to direct `(start, end)` indexing logic, hash computation over source slices, or other workarounds instead of ordinary substring-oriented code.

## Real Ergonomic Pain (Not Blockers)

### ~~5. If-else is a statement, not an expression (Bug 008)~~ — FIXED

**Status:** Fixed. If-else expressions now work:

```con
let label: String = if v == 1 { "ALLOW" } else { "DENY" };
```

Added `ifExpr` to `AST.Expr`, `Core.CExpr`, parser (`parseExprBlock`), elaboration, and lowering (alloca+condBr+store+load pattern with proper type casts).

### 6. Linear string building is awkward inside loops (Bug 011)

The obvious `string_concat` + `drop_string` + reassign pattern becomes awkward for loop-carried string state. MAL's reader avoided substring construction partly because building strings incrementally is not ergonomic enough today.

**Effect:** Parser and pretty-printing code fight linearity more than they should. A loop-friendly `push_char` / `append` path would help a lot.

### 7. No qualified name access across modules

When two modules export functions with the same name (e.g., `from_tag`), there's no way to disambiguate except renaming one. `Module.function()` syntax does not exist. Confirmed: call expressions take a plain `String` name, not a qualified path.

### ~~8. Const declarations are parsed but broken at SSA lowering (Bug 009)~~ — FIXED

**Status:** Fixed. Constants now inline correctly during lowering. Added `constants` field to `LowerState` and constant lookup in the `.ident` case of `lowerExpr`.

### 9. No destructuring let

`let (a, b) = ...;` is not supported. `parseLet` only expects a single identifier.

### 10. Interpreter/runtime data-structure ergonomics are still thin

MAL exposed an important distinction:

- the first environment design was an interpreter implementation problem (a flat global binding pool with backwards scans over the full history)
- but Concrete still lacks some of the runtime-oriented collection ergonomics that would make the better design more natural

The right MAL fix is a frame-bounded environment design, not a language workaround. But the language/stdlib still makes this class of runtime somewhat harder than it should be:

- no hashmap/dictionary yet
- no obvious nested collection patterns for runtime structures
- string-heavy runtime code is already under pressure from Bugs 010 and 011

**Effect:** Concrete can support better interpreter designs than the first MAL attempt, but the supporting runtime/data-structure toolbox is still thinner than ideal for this workload class.

### 11. Standalone benchmark programs lack an easy timing path (Bug 012)

Concrete already has `std.time`, but standalone `.con` files cannot easily import it without project/package setup. That means real benchmark programs currently need to be timed externally rather than measuring themselves through a normal in-language path.

**Effect:** Phase H comparative programs can benchmark correctly, but the easiest workflow is still shell/harness timing instead of an obvious in-language timing surface.

## Not Actually Missing (Previously Claimed Incorrectly)

- **print/println** — Exists in stdlib (`std.io`). The gap is standalone access, not absence.
- **Constants** — `const` is in the parser and grammar. The gap is a lowering bug (009), not a missing feature.
- **`&&` / `||`** — Work correctly. Used throughout tests (e.g., `lean_tests/integration_text_processing.con:31`).
- **Enums as values** — Work generally. The gap is specifically enum fields inside structs (Bug 005).
- **MAL's first slow environment design** — primarily an interpreter design problem, not proof that Concrete cannot support a better environment model.
- **No clock/timing support at all** — false. `std.time` exists; the gap is standalone accessibility, not absence.

## Summary

### Fixed (since initial discovery)
- **Bug 005** — Enum-in-struct layout: fixed
- **Bug 008** — If-expression: fixed (was statement-only, now works as expression)
- **Bug 009** — Const lowering: fixed (constants inline during lowering)

### Remaining top findings:
1. **Provide a print path for standalone programs (Bug 007)** — unblocks real examples producing output
2. **Add substring extraction or an equivalent string-slicing path (Bug 010)** — unblocks normal parser/reader structure
3. **Add loop-friendly string building (`push_char` / `append`) (Bug 011)** — makes parser/runtime workloads much less contorted
4. **Provide a standalone-friendly timing path (Bug 012)** — makes comparative benchmark programs easier to run and report
5. **Add string formatting** — cuts string-building verbosity by 5-7x
