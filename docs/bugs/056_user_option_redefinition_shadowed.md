# Bug 056: a user module redefining `enum Option`/`Result` is silently shadowed by the builtin

**Status:** open_with_reproducer (2026-07-19, surfaced during R-0001 root-fix review)

## Symptom

A user module may declare its own `enum Option<T>` (or `Result`). If its
variants/payloads **diverge** from the builtin, the divergence is silently
ignored: the compiler resolves `Option::Some` against the *builtin* definition,
so a user-added field is reported as unknown.

```con
mod m {
    enum Option<T> { Some { value: T, extra: i64 }, None }
    pub fn main() -> i64 {
        let a: Option<i64> = Option::<i64>::Some { value: 7, extra: 100 };
        match a { Option::Some { value, extra } => { return value + extra; }, Option::None => { return 0; } }
    }
}
```

**Exact current observation (the reproducer's expectation):**

```
error[check]: (E0253) unknown field 'extra' in Option::Some
```

That message is *confusing but stable*: the user declared `extra`, yet is told
it is unknown — because their `Option` declaration never took effect.

## Root cause

Name-as-identity. `Option`/`Result` are resolved (and given EmitSSA's canonical
union layout) **by the bare string name**, not by definition/origin. A user
`enum Option<T>` therefore both (a) is shadowed by the builtin for resolution
and (b) still exists in `m.enums` (which is why R-0001's enum monomorphization
had to exclude the name to avoid monomorphizing it and breaking Vec/Option —
see bug 051). Same substrate as 050/051/054/055: instantiation/type identity
spelled as a name, resolved by name lookup.

## Fix trajectory (owned residual)

1. **Now (this record):** preserved as `open_with_reproducer`; the reproducer
   asserts the exact `E0253` observation so the behavior can't drift silently.
   R-0001 keeps the bare-name Option/Result exclusion as *recorded temporary
   containment*, not a silent skip.
2. **Containment slice (R-0001 step 5):** replace the bare-name exclusion with
   resolved builtin *origin*, and reject an indistinguishable user
   redefinition with a **purpose-built diagnostic** ("cannot redefine builtin
   Option/Result"); this record's expectation changes from `E0253` to that
   new diagnostic.
3. **Phase 8 (canonical identity):** with `(GenericDefId, type-args)` identity
   and origin-qualified resolution, `module_x.Option` may legitimately coexist
   with the builtin; the expectation changes to valid coexistence.

Retirement owner: Phase 8 structured-identity migration.
