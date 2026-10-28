### Bug 312: a destructuring let binds a name with the compiler's __destr_ prefix (SYN-3 checked only on a plain let) (2026-10-28)

A destructuring `let` (struct or enum) may no longer bind a name beginning with `__destr_` (E0283, SYN-3), as a plain `let` could not; pinned by run_tests.sh and the spec example `SYN-3/destructuring-binder`; structural owner R-0499 (with R-0492)
([bug 312](docs/bugs/312_a_destructuring_let_binds_a_name_with_the_compil.md)).
