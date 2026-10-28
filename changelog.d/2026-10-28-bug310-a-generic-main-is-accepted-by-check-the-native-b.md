### Bug 310: a generic main is accepted by Check: the native build loses its entry point and --interp runs it (2026-10-28)

A `main` with a type parameter is refused at check (E0310, STMT-7) instead of failing at link natively and running under `--interp`; pinned by run_tests.sh and the spec example `STMT-7/generic-main`; structural owner R-0499
([bug 310](docs/bugs/310_a_generic_main_is_accepted_by_check_the_native_b.md)).
