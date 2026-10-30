### Bug 337: a name in with(...) that is no capability, alias or capability variable is accepted (2026-10-30)

A name in `with(...)` that is no capability, alias or capability variable (`with(Foo)`) was accepted, against
MOD-1. Filed, not fixed; the reproducer is pinned by the open-bug reproducers leg of check_example_outputs.sh.
Structural owner: Resolve, which resolves capability names like every other name
([bug 337](docs/bugs/337_a_name_in_with_that_is_no_capability_alias_or_ca.md)).
