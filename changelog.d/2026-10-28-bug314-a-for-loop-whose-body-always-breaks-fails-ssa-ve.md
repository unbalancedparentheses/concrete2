### Bug 314: a for loop whose body always breaks fails SSA verification natively (E0703) while --interp runs it (2026-10-28)

A `for` loop whose body always ends in `break` builds natively instead of failing SSA verification (E0703); pinned by run_tests.sh (`regress_314_for_body_always_breaks.con` and the reproducer); structural owner ROADMAP #5 (the structured Lower/SSA builder)
([bug 314](docs/bugs/314_a_for_loop_whose_body_always_breaks_fails_ssa_ve.md)).
