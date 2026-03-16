# High-Leverage Systems Ideas

Status: research

This note consolidates a small set of Concrete-specific ideas that repeatedly come up because they strengthen the project's core identity:

- auditability
- explicit authority and trust boundaries
- high-integrity execution profiles
- reportable low-level facts
- proof-friendly compiler structure

The purpose of this file is not to force adoption.
It exists so these ideas stay visible, comparable, and cross-linked even when they are not yet roadmap-committed.

## Summary Table

| Idea | Quick win | Full version | Current status | Primary note |
|------|-----------|--------------|----------------|--------------|
| Allocation budgets | 1-2 days (`--report alloc` classification) | 1-2 weeks for enforceable `NoAlloc`; longer for restricted `BoundedAlloc(N)` | Roadmap-committed in Phase N | [allocation-budgets.md](allocation-budgets.md) |
| Arena allocation | ~1 week | ~1 week — feature is small if adopted | Research only | [arena-allocation.md](arena-allocation.md) |
| Execution cost / boundedness | 1-2 days (structural boundedness report) | 2-3 weeks (abstract cost counting) | Research only | [execution-cost.md](execution-cost.md) |
| Layout reports | 1 day for padding, 3-4 days for strong report pass | 3-4 days total for the near-term report set | Research only | [layout-reports.md](layout-reports.md) |
| Typestate | 0 for ownership-based irreversible transitions | 2-3 weeks for phantom-type typestate | Research only; wait for evidence | [typestate.md](typestate.md) |
| Authority budgets | ~1 week for module-level budgets | package-level enforcement depends on package model | Research only; blocked on package maturity | [authority-budgets.md](authority-budgets.md) |
| Semantic query/search tooling | 2-4 days for per-function report slices and simple fact queries | 1-2 weeks for maintained query/search surface over machine-readable artifacts | Research only; strong operational fit | [semantic-diff-and-trust-drift.md](semantic-diff-and-trust-drift.md) |
| Type-aware fuzzing/tool-generated invariants | 1-2 days for parser/container/property expansions | 1-2 weeks for maintained generator/fuzz tooling over types and bounds | Research only; prefer tooling over syntax | [testing-strategy.md](testing-strategy.md) |
| Binary format DSL / derived parsers | none without real workload pressure | several weeks if promoted to surface syntax and proof-backed derivation | Research only; evidence-gated | [binary-format-dsl.md](binary-format-dsl.md) |

## Why These Ideas Matter

These ideas are worth tracking because they improve Concrete where it most wants to be unusually strong:

- **allocation budgets** make allocation behavior explicit enough to audit and eventually restrict
- **arena allocation** formalizes a real pattern already visible in parser/interpreter-style code
- **execution cost reports** make boundedness visible without requiring full WCET machinery
- **layout reports** turn existing layout authority into a first-class artifact
- **typestate** is a possible extension of linear ownership if real programs justify it
- **authority budgets** scale capabilities from local facts into subsystem/package policy
- **semantic query/search tooling** lets users ask review questions directly over compiler facts instead of manually stitching reports together
- **type-aware fuzzing/tool-generated invariants** improves confidence in stdlib/runtime behavior without growing the core language
- **binary format DSLs** may eventually help protocol/config-heavy workloads, but only if they outperform ordinary library/tool/report approaches enough to justify new syntax

## Report-First Wins

The fastest additions from this set are report-oriented, not language-oriented:

1. `--report alloc` classification (`NoAlloc`, direct alloc, transitive alloc, structurally unbounded/unknown)
2. `--report layout` padding visualization and stronger enum/layout detail
3. `--report boundedness` or equivalent structural execution-cost classification
4. per-function inspection and semantic query/search over maintained report subjects

These are high leverage because they:

- add audit value immediately
- reuse infrastructure that already exists
- avoid grammar growth
- avoid proof-model churn
- create evidence for whether stricter enforcement is worth it later

## Recommended Stance Per Idea

### 1. Allocation budgets

Adopt `NoAlloc` and stronger reports first.
Treat restricted `BoundedAlloc(N)` as a later high-integrity feature, not a general-purpose effect system.

### 2. Arena allocation

Keep it as a serious candidate because it formalizes an existing pattern cleanly.
It should compete on evidence against better `Vec`/pool ergonomics, not on novelty.

### 3. Execution cost / boundedness

Prefer structural boundedness reporting first.
Do not build cycle-accurate WCET tooling inside Concrete.

### 4. Layout reports

This is the clearest report-only win in the set.
It is mostly productization of an existing subsystem, not a risky language change.

### 5. Typestate

Do not rush phantom types into the language.
Ownership-based irreversible transitions already cover the most important case.

### 6. Authority budgets

Keep the idea alive because it is one of the best long-term supply-chain differentiators.
Prefer module-level experiments before package-level enforcement.

### 7. Semantic query/search tooling

Adopt this only as operational tooling over maintained compiler facts.
Do not let it drag Concrete into a query-first compiler architecture or daemon-heavy semantic model.

### 8. Type-aware fuzzing/tool-generated invariants

Keep this as tooling first.
The strongest early wins are parser fuzzing, collection operation-trace testing, and round-trip/property generators for existing stdlib APIs.

### 9. Binary format DSL / derived parsers

Treat this as evidence-gated.
If real workloads keep wanting binary/protocol schemas, derived parse/serialize pairs, and round-trip evidence, it may earn a place later.
Until then, prefer library patterns, layout/protocol reports, and proof/tool consumers over new core syntax.

## Roadmap Relation

These ideas fall into three categories:

- **Committed direction**: allocation profiles / `NoAlloc` / stronger alloc reports (Phase N)
- **Strong research candidates**: arena allocation, layout reports, execution boundedness reports, semantic query/search tooling
- **Evidence-gated later ideas**: typestate, package-level authority budgets, binary format DSLs, and any derive-heavy fuzzing surface

The roadmap should mention them so they remain visible, but not all of them should become phases immediately.

## Current Phase Mapping

This is the current best-fit phase mapping for the concrete sequencing discussed so far:

1. **`defer`**
   - **Phase H**
   - rationale: highest-leverage real-program ergonomics improvement; best evaluated under sustained-use pressure

2. **Cheap reports**
   - allocation classification (`NoAlloc`, direct alloc, transitive alloc, structurally unbounded/unknown)
     - **Phase N**
   - layout padding/details
     - **Phase H**
   - structural boundedness / execution-boundedness report
     - **Phase N**

3. **Arena allocation**
   - **Phase H**
   - rationale: only adopt if real programs show that the current `Vec`-pool pattern materially hurts clarity, performance, or boundedness

4. **Authority budgets**
   - module-level experiments
     - **Phase O** if explored before the package model is mature
   - package/subsystem enforcement
     - **Phase J**

5. **Typestate**
   - **Phase O**
   - rationale: evidence-gated; do not add phantom-type typestate without stronger real-program demand

6. **Semantic query/search tooling**
   - **Phase L**
   - rationale: strongest fit is maintained operational tooling over machine-readable reports, per-function inspection, and trust-drift workflows

7. **Type-aware fuzzing/tool-generated invariants**
   - early tooling and testing growth
     - **Phase L**
   - if any language-surface version is proposed later
     - **Phase O**

8. **Binary format DSL / derived parsers**
   - evidence-gated exploration
     - **Phase O**
   - only move earlier if a serious protocol-heavy workload proves that ordinary library/report/proof tooling is not enough
