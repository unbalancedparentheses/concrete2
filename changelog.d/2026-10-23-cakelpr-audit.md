### Bounded cake_lpr certificate audit

Add an opt-in pinned CakeML checker build and an audit of original CNF/binary-LRAT pairs retained
from Lean's SAT solver. The audit retains hashes and logs, refuses stale output directories,
requires genuine nontrivial sample coverage, and distinguishes checker refusal from execution
failure. It exercises corrupted proofs and mismatched formulas and reports timeout as incomplete.
Lean's environment supplies owner-module locations rather than guessing from theorem namespaces.

The ARM64 experiment checked two sample formulas and six project formulas; only one sample
required nontrivial certificate reasoning. H20 remains open: the project formulas are already
trivially contradictory, and independent SAT checking does not validate compiled Lean-to-CNF
translation. Clarify that boundary in AXIOMS.md, KNOWN_HOLES.md and the existing roadmap entry.
