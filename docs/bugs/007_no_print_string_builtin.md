# Bug 007: No Print Path for Standalone Programs

**Status:** Open (ergonomic/access gap, not a missing feature)
**Discovered:** 2026-03-15

## Situation

| Layer | print/println available? |
|-------|------------------------|
| Compiler builtin | **No** |
| Stdlib `std.io.{print, println}` | **Yes** — `io.con:57-71`, uses `Console` capability correctly |
| Standalone `.con` files | **No** — `import std.io` fails without `Concrete.toml` project declaring `std` dependency |

## The Real Gap

Printing is blocked in standalone real programs because the usable path lives in stdlib/project setup rather than in an always-available surface. Standalone `.con` files compiled with `concrete file.con` cannot resolve `std.*` imports.

Every standalone example that needs output must declare `trusted extern fn putchar(c: i32) -> i32;` and write a character-by-character print loop — ~8 lines of boilerplate.

## What Is NOT the Problem

- The stdlib has correct `print`/`println`/`eprint`/`eprintln` with `Console` capability
- Project-based programs with `Concrete.toml` can use them
- Concrete does not lack a print facility

## Impact

- Phase H example programs require print boilerplate
- `examples/string_processing.con` calls nonexistent `print_string` — it doesn't compile
- New users trying single-file examples have no obvious print path

## Possible Fixes

- **Option A:** Add `print_string`/`print_char` as compiler builtins (like `string_concat`). Zero setup cost, duplicates stdlib.
- **Option B:** Auto-resolve `std.*` imports in standalone mode by searching a known stdlib path. No new builtins needed.
- **Option C:** Accept standalone limitation, document it clearly, encourage project setup for real programs.
