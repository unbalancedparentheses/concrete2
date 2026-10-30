### Bug 336: a destructuring let without mut binds assignable names (2026-10-30)

A destructuring `let` without `mut` let its binders be assigned (`let P { a, b } = p; a = a + 1;` was accepted),
against OWN-10, and `let mut` over a pattern was read and dropped. Filed, not fixed; the reproducer is pinned by
the open-bug reproducers leg of check_example_outputs.sh. Structural owner: R-0499, with the binder's mutability
carried in the AST pattern ([bug 336](docs/bugs/336_a_destructuring_let_without_mut_binds_assignable.md)).
