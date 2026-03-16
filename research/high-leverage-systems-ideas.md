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

## Why These Six Matter

These ideas are worth tracking because they improve Concrete where it most wants to be unusually strong:

- **allocation budgets** make allocation behavior explicit enough to audit and eventually restrict
- **arena allocation** formalizes a real pattern already visible in parser/interpreter-style code
- **execution cost reports** make boundedness visible without requiring full WCET machinery
- **layout reports** turn existing layout authority into a first-class artifact
- **typestate** is a possible extension of linear ownership if real programs justify it
- **authority budgets** scale capabilities from local facts into subsystem/package policy

## Report-First Wins

The fastest additions from this set are report-oriented, not language-oriented:

1. `--report alloc` classification (`NoAlloc`, direct alloc, transitive alloc, structurally unbounded/unknown)
2. `--report layout` padding visualization and stronger enum/layout detail
3. `--report boundedness` or equivalent structural execution-cost classification

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

## Roadmap Relation

These ideas fall into three categories:

- **Committed direction**: allocation profiles / `NoAlloc` / stronger alloc reports (Phase N)
- **Strong research candidates**: arena allocation, layout reports, execution boundedness reports
- **Evidence-gated later ideas**: typestate and package-level authority budgets

The roadmap should mention them so they remain visible, but not all of them should become phases immediately.
