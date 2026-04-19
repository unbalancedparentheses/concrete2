# Phase Exit Checklists

Status: canonical reference

Each phase has a "phase closes when..." list tied to concrete outputs. A phase is not done until every exit criterion has a verifiable artifact. This prevents roadmap drift into never-finished thematic work.

## Phase 1: Predictable Core

**Closes when all of the following are true:**

- [ ] 5+ canonical examples are trust-gate tested with `--check predictable` passing
  - `fixed_capacity` (12 tests), `parse_validate` (10 tests), `service_errors` (10 tests), `thesis_demo` (8+ tests), `packet` (4 tests)
- [ ] Predictable boundaries explicitly documented
  - `docs/PREDICTABLE_BOUNDARIES.md` (host calls, cleanup, determinism, failure, memory)
  - `docs/PREDICTABLE_FAILURE_DISCIPLINE.md` (allowed/excluded failure modes)
  - `docs/FAILURE_STRATEGY.md` (abort-only, defer, no-leak)
- [ ] Stack-depth reporting works end-to-end
  - `--report stack-depth` shows per-function frame size, max call depth, worst-case bound
  - 25 trust-gate stack-depth tests pass
- [ ] Bounded-capacity types are practical
  - Copy structs with fixed arrays compile and pass predictable
  - `fixed_capacity` example proves the pattern works
- [ ] Error propagation patterns documented with examples
  - `parse_validate` (single-stage, 6 error categories)
  - `service_errors` (multi-stage, 3 error enums + unified error)
- [ ] Example governance in place
  - `docs/EXAMPLE_INVENTORY.md` (all 20 examples catalogued)
  - `docs/EXAMPLE_LIFECYCLE.md` (promotion levels defined)
  - `docs/EXAMPLE_NO_DUPLICATES.md` (reuse rule)
- [ ] Diagnostic UX design documented
  - `docs/DIAGNOSTIC_UX.md` (quality tiers, target format, priority categories)
- [ ] Trusted boundary guide written
  - `docs/TRUSTED_BOUNDARY_GUIDE.md` (4 wrapper patterns, audit checklist)
- [ ] No-std / freestanding split defined
  - Items 34-36 complete (no-std split, standalone UX, project bootstrap)
- [ ] Source-level interpreter exists for semantic oracle
  - Item 31 complete (interpreter covers `fixed_capacity` and `parse_validate`)

**Verification command**: `./scripts/tests/run_tests.sh --trust-gate` passes with 0 failures.

**Current status**: 14/18 items done. Remaining: items 31 (interpreter), 34 (no-std), 35 (standalone UX), 36 (project bootstrap).

## Phase 2: Pre-Stdlib Pressure Workloads

**Closes when all of the following are true:**

- [ ] Parser/decoder pressure set exists (JSON subset, DNS, HTTP, binary)
  - At least 2 parsers compile and run, revealing specific stdlib gaps
- [ ] Ownership-heavy structures tested (tree, arena graph, intrusive list)
  - At least 2 ownership pressure programs compile, documenting borrow/move gaps
- [ ] Borrow/aliasing patterns documented
  - Sequential `&mut`, iterator-like adapters tested
- [ ] Trusted-wrapper / FFI pressure tested
  - libc wrapper, checksum, OS facade — each compiles and reports effects
- [ ] Fixed-capacity / no-alloc pressure extended
  - Beyond `fixed_capacity`: ring buffer, bounded queue, state machine
- [ ] Cleanup/leak boundary tested
  - Nested defer, alloc/free facades, FFI cleanup
- [ ] All gap findings documented in a "stdlib requirements" list
  - Each pressure example documents: what worked, what is missing, what needs stdlib support

**Verification**: each pressure example either compiles and runs, or documents the specific gap that prevents it.

**Current status**: 0/6 items done.

## Phase 3: Stdlib and Syntax Freeze

**Closes when all of the following are true:**

- [ ] String/text contract defined (UTF-8, owned vs borrowed, no implicit conversions)
- [ ] Core stdlib modules implemented: bytes, option/result, slices, basic collections
- [ ] Error ergonomics settled (`?` operator, Result methods, conversion traits)
- [ ] LL(1) syntax finalized and documented
- [ ] Visibility rules stable (pub/non-pub at module and struct level)
- [ ] Endian byte APIs exist (read_u16_be, write_u32_le, etc.)
- [ ] Module hygiene proven (no accidental namespace pollution)
- [ ] Syntax and stdlib surface frozen — changes require explicit unfreezing

**Verification**: `examples/parse_validate/` and `examples/service_errors/` work with stdlib types (not custom Copy enums), and `examples/grep/` uses stdlib string APIs.

**Current status**: 0/19 items done.

## Phase 4: Tooling, Tests, Wrong-Code Corpus

**Closes when all of the following are true:**

- [ ] Formatter exists (`concrete fmt`)
- [ ] Fuzzer exists and has found/fixed at least 5 bugs
- [ ] Wrong-code corpus has 10+ cases with expected vs actual behavior
- [ ] Test reducer/minimizer is functional
- [ ] Test coverage report exists

**Current status**: 0/12 items done.

## Phase 5: Performance, Artifacts, Contract

**Closes when all of the following are true:**

- [ ] Compile-time benchmarks exist with tracking
- [ ] Runtime benchmark suite exists (at least 5 programs)
- [ ] Artifact design documented (binary format, debug info, symbol tables)
- [ ] Backend contract explicit (what SSA guarantees, what optimizations are allowed)

**Current status**: 0/13 items done.

## Phase 6: Release Credibility, Showcase

**Closes when all of the following are true:**

- [ ] Public showcase corpus has 5+ compelling examples
- [ ] Website or landing page exists with honest claims
- [ ] At least one outsider has tried the language and provided feedback
- [ ] All public documentation reviewed for accuracy

**Current status**: 0/23 items done.

## Phase 7: Proof Expansion, Provable Subset

**Closes when all of the following are true:**

- [ ] ProofCore covers structs, pattern matching, and arrays
- [ ] At least 3 functions have Lean-verified proofs that the kernel accepts
- [ ] Proof workflow documented end-to-end (extract → prove → attach → verify)
- [ ] Proof boundary explicitly defined (what can and cannot be proved)

**Current status**: Phase 2 item 1 (proof workflow) done. Remaining items in Phase 7 not started.

## Later phases (8-14)

Exit checklists for phases 8-14 will be defined when earlier phases approach completion. Premature exit criteria for distant phases would drift as the language evolves.

## Updating this document

When a phase exit criterion is met, check the box and add the commit hash or document reference. When all boxes are checked, the phase is closed. Add a closing date and final trust-gate count.
