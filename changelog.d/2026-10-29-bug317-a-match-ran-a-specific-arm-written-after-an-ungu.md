### Bug 317: A match ran a specific arm written after an unguarded catch-all arm instead of refusing it (2026-10-29)

A `match` arm that earlier unguarded arms already cover (an arm after `_` or a binding, a repeated literal, a range inside earlier ranges, `_` after every variant or both `bool` values) is refused at check (E0325, PAT-9, OD18) instead of running in place of the catch-all; match arms keep source order. Pinned by run_tests.sh and the PAT-9 spec examples; structural owner R-0500
([bug 317](docs/bugs/317_a_match_ran_a_specific_arm_written_after_an_ungu.md)).
