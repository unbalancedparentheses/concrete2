### One Gate Manifest (cleanup 5, slice 1, 2026-10-29)

`scripts/tests/gates.tsv` is now the one list of gates: a row per way the repository runs a gate
script, with its workflow job and step, how CI reaches it (`via`: a step, an aggregator, a tool, or a
skip with its reason), area, owner, claim, tier, spec keys, make target, devshell, and whether it
needs a build or checks a generated view. Its header documents every column and why the test
taxonomy will be a `kind` column rather than a directory move. `scripts/gen/gates.py` generates
`scripts/tests/ci_gate_inventory.txt` from it (byte-identical to the hand-kept file it replaces) and
runs from `scripts/gen/refresh_generated.sh`. `check_gate_registration.sh` now runs `gates.py
--check` (valid vocabularies, unique ids and make targets, live spec keys, step rows matching the
workflow, fresh views), fails on any check/test/run script without a row, takes its skip list from
the manifest, and cross-checks each row's `via` against its reachability walk; negative controls on
a planted copy cover the unlisted script, a stale view, duplicate ids and make targets, values
outside the vocabularies, a dead spec key, a missing or comment-only workflow step, a conditional
pre-push line, and stale or wrong `via` routes. The seeding found three scripts no CI step reaches: `test_bundle_smoke.sh`,
`test_parser_fuzz.sh` and `test_verify_gates.sh` (make targets only); they are recorded as
`skip` rows with tier `manual`.

### Gate Make Targets Generated From the Manifest (cleanup 5, slice 2, 2026-10-29)

The 185 Makefile targets that each run one gate command are now generated into `mk/gates.mk` from
the manifest's `make` cells and included from the Makefile. Targets whose recipe is not one plain
`bash`/`python3` gate command (run_tests.sh under `sh`, the oracles, the docs-drift and example
pairs, the fuzz smoke) stay hand-written, as do `test-proof-gate` and `check-grammar` for now. Each generated target line and recipe is byte-identical to the
hand-written one it replaces (18 recipes were first respelled `bash ./scripts/tests/...` like the
other 167), and `make -pRrq`'s rule database is unchanged for every target apart from the new
include node, `make test-mutation` (the mutation harness, under `$(NIX_DEVELOP)`), and 59 gate
targets that are now `.PHONY` like the rest. `check_gate_hygiene.sh` lints the generated recipes
too, and the registration gate refuses a stale `mk/gates.mk`, a generated target also written by
hand, and a Makefile that does not include it.

### Generated CI Steps (cleanup 5, slice 3, 2026-10-29)

`scripts/gen/gates.py` now writes the workflow's single-gate steps: 214 of them, in 44 blocks across
14 jobs, each between `# BEGIN GENERATED: gates <job> from <row id>` and `# END GENERATED: gates
<job>` markers, from the manifest's `gen=y` rows (whose order is now the workflow's). Steps with
`if:`, `env:`, several commands, or a name GitHub cuts short at ` #` stay hand-written, as do the
comments between steps; `--check` refuses a hand edit inside a block and a `gen=y` row no block
reaches. The parsed workflow is identical to the one before, job by job (same steps, names, `run`
strings and order); the text changed only by the marker lines and by 106 step names written without
their redundant quotes. The `gen` column now means "this row's workflow step is generated".
