### The Test Suite Is Data (cleanup items 12 and 13, 2026-10-30)

`scripts/tests/run_tests.sh` went from 15,000 lines to 1,200. Its tests are rows of
`tests/cases/<block>.tsv`, one per test in run order (id, kind, section, helper, arguments), which
`run_cases` dispatches to the unchanged helpers; code that is not one helper call moved verbatim into
`scripts/tests/suite/<block>.sh` as one function per unit. The kind column is the taxonomy by what a
test asserts (run-value, reject-diagnostic, trap, report, profile, test-flag, gate-fixture, script);
files did not move. `run_tests.sh --list` prints every test a mode runs, and `RUN_TESTS_TRACE=FILE`
records each call of the shared assertion helpers. The move changed nothing that runs: in every mode
(fast, full, trust-gate, stdlib, O2, codegen, report) the `--list` output, the pass/fail/skip totals,
the helper-call trace and the result lines (timings aside) were identical before and after on OVH. The gate-smoke
section is gone: its 21 gates are each their own CI step (fast and full lose the ids
`script:gatesmoke.1`..`12` and exactly 24 passes). The unused diff-to-gate selector
(`gates_for_diff.sh` and its test) is retired; `lib/gates_for_diff.py` keeps only the tables the
impact selector reads. The text consumers of the suite (`test_ssa.sh`, `audit_bug_corpus.sh`,
`check_generic_enum_inventory.sh`, the impact selector, the registration walk and the hygiene
scans) read the case tables and code units.
