### The dead-code ratchet: the compiler cannot grow unreachable declarations (2026-10-29)

`scripts/tests/check_dead_code_ratchet.sh` computes which compiler declarations are reachable in
the elaborated Lean environment (`scripts/tools/dead_code_inventory.lean`), not in the source
text. The roots are the executables' `main`, every user theorem, everything the proof libraries
`Examples` and `DesignExamples` declare, `@[export]`/`@[extern]`/`initialize`/simp/syntax
declarations, the generated data modules, the identifiers of `#guard`/`#eval`/`example` commands
and of the Lean files outside the libraries, and the declarations gates name only as text
(`docs/compiler/dead_code_allowlist.tsv`, 38 rows, each with the file that names it). Auxiliary
declarations (match, equation, `_unsafe_rec`, constructor, projection, derived-instance helpers)
count toward the declaration they belong to, and an instance is live only while its types are.
The gate fails on an unreachable declaration missing from `docs/compiler/dead_code_baseline.tsv`,
on a baseline row that is reachable or gone, and on a baseline that grows relative to the base
revision. The baseline starts at 79 of 4397 declarations. CI runs the gate.
