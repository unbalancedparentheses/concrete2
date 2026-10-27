### Bug 307: a call argument &mut x passed a temporary copy of x and wrote it back after the call, so a raw pointer derived from it did not alias x (2026-10-27)

A call argument `&mut x` is now `x`'s own storage, as `&mut x` is everywhere else, instead of a
temporary copy written back after the call: a raw pointer a trusted callee derives from it aliases
`x` after the call. Regression leg: `regress_307_call_arg_mut_borrow_aliases.con` in
`run_tests.sh`. Structural owner: R-0501
([bug 307](docs/bugs/307_a_call_argument_mut_x_passed_a_temporary_copy_of.md)).
