# Stdlib Freeze Gap Ledger

Status: evidence log (pre-freeze)

This document is the working ledger for ROADMAP item 67:

> require workload-backed stdlib freeze evidence beyond the tiny canon: at least one string-heavy medium workload and one interpreter/runtime-heavy medium workload should run against the intended stdlib surface, with explicit gap notes showing whether the remaining pain is missing APIs, bad ergonomics, missing patterns, or a deliberate deferral.

For the intended stdlib surface, see [STDLIB.md](STDLIB.md), [FORMATTING_OUTPUT.md](FORMATTING_OUTPUT.md), [RUNTIME_COLLECTIONS.md](RUNTIME_COLLECTIONS.md), [VALIDATED_WRAPPERS.md](VALIDATED_WRAPPERS.md), [LAYOUT_CONTRACT.md](LAYOUT_CONTRACT.md).

Each finding is classified as:
- **Missing API** — a needed function/type does not yet exist.
- **Bad ergonomics** — an API exists, but using it correctly is verbose or error-prone.
- **Missing pattern** — the convention is not established; examples roll their own.
- **Deferred** — deliberately out of scope for the first freeze.
- **Compiler gap** — the design is settled but the implementation has a bug or limitation.

---

## 1. String-Heavy Workload: `examples/grep`

- Size: 207 lines (`examples/grep/src/main.con`).
- Status: compiles, runs, matches literal strings across input lines, emits formatted match reports.
- Stdlib surfaces exercised: `std.string`, `std.fs`, `std.args`, `std.vec`, `print`/`println` variadic.

### Findings

| Tag | Classification | Finding | Resolution path |
|---|---|---|---|
| G-1 | Bad ergonomics | Every log line builds a `String` via 5–7 chained `out.append(&x); out.append_int(n); ...` calls. 11 call sites total (grepped `.append*(`/`println(`). | **Resolved** (2026-04-20): variadic `append(&mut buf, ...)` desugar implemented in Elab, with Check intercept and `IntrinsicId.append` wired. Test: `tests/programs/variadic_append.con`. grep migration remains as a follow-up cleanup (not freeze-blocking). |
| G-2 | Deferred | No format specifiers (padding, width, hex, leading-zero line numbers). grep does not need them today, but a reviewer would expect them for `ls`-style output. | Reconsideration trigger per [FORMATTING_OUTPUT.md](FORMATTING_OUTPUT.md) §6. Not blocking. |
| G-3 | Compiler gap | `String::append` returns `()` — no chaining possible without borrow-checker work. Doc [FORMATTING_OUTPUT.md §4](FORMATTING_OUTPUT.md) records the decision to not pursue chaining now. | Not a bug; a deliberate deferral documented. |
| G-4 | Missing pattern | grep has no local `format_error(msg: &mut String, ...)` helper; error reporting is inlined. [FORMATTING_OUTPUT.md §5](FORMATTING_OUTPUT.md) commits to the buffer-oriented shape, but no canonical example yet demonstrates it. | Add one when parser error reporting is next touched; do not backport as churn. |

### Verdict
String-heavy workload runs end-to-end on today's surface. The frozen direction ([FORMATTING_OUTPUT.md](FORMATTING_OUTPUT.md)) resolves the main ergonomic gap (G-1) at the design-decision level. Implementation of the variadic `append` desugar is the one remaining blocker for the freeze checklist in that document.

---

## 2. Interpreter/Runtime-Heavy Workload: `examples/lox`

- Size: 1 183 lines (`examples/lox/src/main.con`), 48 `fn` declarations.
- Status: compiles, runs, executes `test_comprehensive.lox` producing expected output (numbers, booleans, strings, nil).
- Stdlib surfaces exercised: `std.vec`, `std.string`, `std.fs`, `std.args`, manual binding tables.

### Findings

| Tag | Classification | Finding | Resolution path |
|---|---|---|---|
| L-1 | Missing pattern | lox rolls its own `Vec<NumEntry>` / `Vec<Binding>` / tag-indexed object store instead of `HashMap<String, Value>` + `Vec<Frame>`. [RUNTIME_COLLECTIONS.md §3.1](RUNTIME_COLLECTIONS.md) commits to the HashMap+frame shape as the canonical idiom. | lox predates the frozen direction. Rewriting it onto the canonical shape is the definitive evidence for item 67 section 6 freeze checklist. Not required before freeze, but scheduled for the freeze checklist close-out. |
| L-2 | Missing API | `HashMap::get_mut(&mut self, key: &K) -> Option<&mut V>` does not exist in `std.map`. It is required for in-place value mutation ([RUNTIME_COLLECTIONS.md §4](RUNTIME_COLLECTIONS.md) "Mutating lookup" row). | Add before freeze. Small addition in `std/src/map.con` mirroring `get`. |
| L-3 | Missing API | `HashMap::insert` currently does not return the displaced value (ownership of the prior entry is lost / the implementation is silent on the return). Freeze checklist requires `Option<V>` return. | Verify and patch in `std/src/map.con`. Small, localized. |
| L-4 | Deferred | No priority queue / heap type in stdlib. lox does not need one; no scheduler example forces it yet. | Deferred per [RUNTIME_COLLECTIONS.md §2](RUNTIME_COLLECTIONS.md) "Not in the stable surface". |
| L-5 | Missing pattern | lox has no `Env` / `Frame` struct factored out; scope handling is threaded through free functions (`lox_env_get`, etc.). | Example-shape, not stdlib. Promote to stdlib only if two unrelated examples arrive at the same shape ([RUNTIME_COLLECTIONS.md §6](RUNTIME_COLLECTIONS.md) promotion rules). |
| L-6 | Compiler gap | Large monolithic file (1 183 lines) suggests module boundaries are not ergonomic for runtime-heavy programs. Not a stdlib gap; a module-hygiene gap. | Tracked separately under [VISIBILITY_AND_MODULE_HYGIENE.md](VISIBILITY_AND_MODULE_HYGIENE.md). |

### Verdict
Interpreter workload runs end-to-end. The frozen direction ([RUNTIME_COLLECTIONS.md](RUNTIME_COLLECTIONS.md)) matches the shape a canonical lox *would* have. Before the stdlib freeze, `std.map` must close L-2 and L-3 (small, mechanical), and the project must decide whether to rewrite lox onto the canonical shape (L-1) as freeze evidence or accept the pattern-as-documented without a reference implementation.

---

## 3. Summary Against the Freeze Checklist

| Domain | Design frozen | Implementation complete | Workload evidence |
|---|---|---|---|
| Formatting / print / append | Yes ([FORMATTING_OUTPUT.md](FORMATTING_OUTPUT.md)) | Complete — `print`/`println` and variadic `append` all wired | `grep` exercises existing surface; `tests/programs/variadic_append.con` covers the new desugar |
| Runtime collections | Yes ([RUNTIME_COLLECTIONS.md](RUNTIME_COLLECTIONS.md)) | Partial — `HashMap::get_mut`, `insert` return value missing | `lox` runs but does not use canonical HashMap shape yet |
| Validated wrappers | Yes ([VALIDATED_WRAPPERS.md](VALIDATED_WRAPPERS.md)) | Complete on the layout/codegen path — native/SSA layout resolves enum-payload newtypes; canonical stdlib wrappers landed (`std.numeric.NonZeroU32`/`NonZeroU64`/`Port`, `std.text.AsciiText`). Instance-method dispatch on newtypes still resolves to inner-type methods (doc §8 remaining gap); static-only API is the convention until that closes | `tests/programs/newtype_validated.con` plus `AsciiText` stdlib tests exercise convention |
| Layout / ABI contract | Yes ([LAYOUT_CONTRACT.md](LAYOUT_CONTRACT.md)) | Implementation already accepts the four stable forms; freeze checklist items around report fact set and `#[repr(transparent)]` rejection remain | `pressure_ffi_*` programs exercise existing surface |

No design decision is blocked by a missing workload. One small implementation task remains between the current state and the freeze checklist being green: `HashMap::get_mut` + `insert` return value. Newtype layout lookup in SSA codegen landed 2026-04-24 (`Layout.Ctx` now carries a newtypes list and resolves through `resolveNewtype` at the layout boundary), paired with canonical stdlib wrappers (`NonZeroU32`, `NonZeroU64`, `Port`, `AsciiText`) and `OrderedMap::get_mut`. Variadic `append` (G-1) landed 2026-04-20.

---

## 4. Process

- New workload findings are added as numbered rows under the relevant example.
- When a finding is resolved, mark it resolved in place; do not delete it. The ledger is a historical record.
- When a new medium workload enters the pressure set, it gets its own section with the same `classification / finding / resolution` format.
- Each finding that triggers a design revision references back to the design doc being revised, so the revision can be audited.
