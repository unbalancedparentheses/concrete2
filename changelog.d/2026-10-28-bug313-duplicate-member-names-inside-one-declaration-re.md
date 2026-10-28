### Bug 313: duplicate member names inside one declaration reach llvm-as or are accepted (no rule or site checks fields, variants, methods or parameters) (2026-10-28)

An enum that declares a variant twice, or an impl that declares a method twice, is refused at check (E0324, the new MOD-5) instead of reaching `llvm-as`; pinned by run_tests.sh and the MOD-5 spec examples; structural owner R-0499
([bug 313](docs/bugs/313_duplicate_member_names_inside_one_declaration_re.md)).
