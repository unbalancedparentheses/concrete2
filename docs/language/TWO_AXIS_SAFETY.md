# The two safety axes, and what the migration experiment measured

Status: design note + experiment record.
Date: 2026-09-25. Gated by `scripts/tests/check_trusted_method.sh`.

## The three facts `Unsafe` was conflating

| fact | declared as | means |
|---|---|---|
| operational authority | `with(File, Alloc, …)` | ambient authority the caller must supply |
| caller safety obligation | `with(Unsafe)` | the caller must uphold an invariant the language cannot establish |
| trust provenance | *(derived)* | the implementation depends on raw operations, FFI, or an audited assertion |

An API may be **safe to call while raw inside** — `Vec::push` — which is why
provenance must never propagate as a caller requirement.

| caller interface | implementation | example |
|---|---|---|
| safe | checked | ordinary pure function |
| safe | trusted/raw internally | `Vec::push`, `String::clone` |
| caller owes an obligation | checked under that assumption | bounds-dependent raw access |
| caller owes an obligation | trusted | raw deallocation, FFI escape hatch |

## Why the measurement came first

`Unsafe` signatures are **already not a provenance system**: 292 public `std`
functions reach a raw root while 154 declare `Unsafe` — off by 138. Separating
the facts is necessary even if no signature ever changes.

The boundary is also neither small nor deep. Of 888 `std` functions there are
**257 distinct raw roots**; 172 of them *are* public APIs, and the maximum
shortest-path depth to a root is **2**. There is almost no safe wrapper layer to
"terminate" anything at — which refuted the first hypothesis (that a handful of
private helpers were the cascade's source) before any code changed.

## The language gap the experiment found by failing

The first migration attempt produced unparseable `std`. `trusted` was only a
**whole-impl** modifier, so *safe interface + audited implementation* was not
expressible for a method: licensing `Vec::push`'s raw work meant vouching for
every method in `impl Vec`. Since 67 of the 154 public `Unsafe` declarations do
raw work in their own body, that shape was most of the library.

Per-method `trusted` closes it. The axes stay independent — `pub trusted fn
read_unchecked(..) with(Unsafe)` means audited body *and* caller owes — and trust
never erases `File`/`Console`/`Network`/`Alloc`.

## Results (isolated worktree, full cross-package `Unsafe` enforcement)

| measure | before | after |
|---|---|---|
| public `Unsafe` declarations | 154 | **21** |
| public `trusted` functions | 50 | 88 |
| all `trusted` functions | 96 | 156 |
| operational capability sets changed | — | **0 of 418** |
| corpus regressions vs baseline | — | **0** |
| cross-package `Unsafe` exception | required | **removed** |

The 21 survivors are exactly the obligation-bearing APIs: every one takes or
returns a raw pointer, or is a `RawCursor` unchecked read. No `Vec`, `String`,
`Bytes`, `map`, `set`, `fmt`, `hex` or `base64` entry point remains.

**`alloc::heap_new`/`grow`/`dealloc` dropped `Unsafe` and kept `Alloc`.** The
obligation is real but already enforced by the *argument type*: they take and
return `*mut T`, and no caller can obtain or use such a pointer without being
`trusted` or holding `Unsafe`, because E0521 gates every dereference
independently. The capability was redundant with the pointer type while costing
every allocating API in the library.

## The refinement this forced, and its scope

23 diagnostics survived the first pass, all the same shape: a **trusted** function
that satisfies a callee's precondition internally still had to declare the
obligation upward. Vouching that it discharges a callee's precondition is what
"audited" means, so a trusted body discharges an `Unsafe` **obligation** at a
call. Scoped three ways so it stays a discharge and not an erasure:

- **only `Unsafe`** — operational capabilities are untouched, so trust never
  confers authority to reach a sink;
- **only a non-`extern` callee** — an `extern` still demands it, which is what
  `error_trusted_extern_needs_unsafe.con` holds; the audited-leaf escape remains
  `trusted extern fn`. Both negative fixtures still refuse under the change;
- **only the call** — the raw-operation gate (E0521) is untouched.

## Harness

The previous round's result was lost to a sweep that grepped for capability
diagnostics: a `std` that failed to **parse** produced no `E0520` and scored as
clean. Every package now lands in exactly one bucket — success (`build` exits 0),
expected refusal (the specific diagnostic, and *not* a parse/resolve failure), or
unexpected — and an injected parse error is required to surface as unexpected.
It does: the control reports 114 unexpected rather than 114 passes.

`concrete check`'s exit code is **not** a compile signal — it returns 1 when a
function is proof-eligible with no registered proof. `build` is.

## Not landed

The `std` migration stays in the worktree. Removing `Unsafe` from a safe wrapper
deletes the only current signal that it depends on trusted code, and
`--report trust-edges` does not yet cross a package boundary — the same gap as
R-0484's cross-package opacity. Until per-function trust edges travel in package
summaries, the migration would erase information from consumers.
