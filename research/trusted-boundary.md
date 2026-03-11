# Trusted Boundary

**Status:** Open

This note describes a possible future design for containing implementation-level unsafety without leaking `Unsafe` into safe public APIs.

The motivating problem is simple:

- some stdlib and runtime-facing code must use raw pointers internally
- callers still need honest semantic effects such as `with(Alloc)`
- forcing `Unsafe` onto every caller of a safe container API would make the language worse

The clean split is:

- **caller-facing semantic effects** stay in function signatures
- **implementation-facing trust boundaries** are marked separately

## Core Distinction

These two things are not the same:

### 1. Semantic effect visible to callers

Example:

- a function may allocate
- a function may perform file I/O
- a function may open a socket

These belong in the ordinary capability signature:

```con
fn push(&mut self, value: T) with(Alloc) { ... }
```

That tells the caller something true about program behavior.

### 2. Implementation trust boundary

Example:

- the function uses raw pointer arithmetic internally
- the function dereferences raw pointers
- the function contains audited low-level code that would normally require `Unsafe`

That is not the same kind of fact. It is not a public semantic effect. It is a statement about *how the implementation is achieved*.

That should be modeled by a separate construct:

```con
trusted impl Vec<T> {
    fn push(&mut self, value: T) with(Alloc) { ... }
}
```

## Why This Is Better

Without a trusted boundary, there are two bad options:

### Bad option 1: silent exemption

The compiler simply does not enforce `Unsafe` rules inside selected stdlib code.

This is bad because:

- the trust boundary is invisible
- the language appears stronger than it is
- auditing becomes harder

### Bad option 2: leak `Unsafe` to callers

The public API becomes:

```con
fn push(&mut self, value: T) with(Alloc, Unsafe) { ... }
```

This is also bad because:

- safe abstractions stop looking safe
- `Unsafe` spreads through large parts of ordinary code
- callers are forced to carry implementation details they should not need to know

The trusted-boundary design avoids both problems:

- `Alloc` stays visible where it matters
- raw-pointer internals are contained
- the trust boundary remains explicit and grep-able

## Preferred Surface Syntax

Preferred forms:

```con
trusted fn helper(...) { ... }
trusted impl Vec<T> { ... }
```

This is better than `#[trusted]` because:

- it is more visible
- it feels like a language-level boundary, not metadata
- it is easier to grep and audit

This is better than `unsafe fn` because:

- `unsafe fn` usually suggests danger for the caller
- here the point is that the *implementation* is trusted, while the public API may remain safe-facing

So the keyword should communicate:

- trusted computing base
- extra scrutiny required
- not automatically caller-visible unsafety

## Examples

### Vec

```con
trusted impl Vec<T> {
    fn new() with(Alloc) -> Vec<T> { ... }

    fn push(&mut self, value: T) with(Alloc) {
        ...
    }

    fn get(&self, at: u64) -> Option<&T> {
        ...
    }
}
```

Meaning:

- `new` and `push` may allocate
- `get` does not allocate
- raw-pointer internals stay inside the trusted impl
- callers do not need `Unsafe`

### HashMap

```con
trusted impl HashMap<K, V> {
    fn new(hash: fn(&K) -> u64, eq: fn(&K, &K) -> bool) with(Alloc) -> HashMap<K, V> {
        ...
    }

    fn insert(&mut self, key: K, value: V) with(Alloc) {
        ...
    }

    fn get(&self, key: &K) -> Option<&V> {
        ...
    }
}
```

Again:

- allocation remains explicit
- implementation unsafety stays contained
- callers do not inherit `Unsafe`

## Rules

If Concrete adds `trusted`, the rules should stay strict.

Recommended initial rules:

1. **stdlib / compiler-internal only at first**
   This avoids turning `trusted` into a casual escape hatch.

2. **Explicit, never inferred**
   A function or impl is trusted only if marked directly.

3. **Not nestable**
   No implicit propagation, no stacking games, no "trusted because it is inside trusted."

4. **Ordinary capability rules still apply**
   `trusted` does not erase `Alloc`, `File`, `Network`, etc.
   It only affects the internal low-level trust boundary.

5. **Must appear in audit outputs**
   `grep trusted` should find the boundary in source, and compiler reports should surface it too.

6. **Should integrate with `Unsafe` reporting**
   Trusted regions should appear in:
   - `--report unsafe`
   - or a later dedicated `--report trusted`

## Relationship To `Unsafe`

This design does **not** replace `with(Unsafe)`.

Instead:

- ordinary user-facing low-level code still uses `with(Unsafe)`
- `trusted` exists to contain carefully-audited implementation internals

So the split becomes:

- **`with(Unsafe)`** = explicit low-level authority in ordinary code
- **`trusted`** = explicit trust boundary for implementation internals

That is a cleaner model than forcing one mechanism to serve both purposes.

## Relationship To Audit Outputs

If this lands, reporting becomes even more important.

Useful future outputs:

- which functions/impls are trusted
- why a trusted boundary exists
- which unsafe operations occur inside it
- whether trusted code also allocates or touches host capabilities

This is one of the reasons `trusted` fits Concrete well: it strengthens the audit story rather than hiding it.

## Recommended Order

If Concrete wants this feature, the right order is:

1. keep `Unsafe` reports improving
2. improve wrapper patterns in stdlib/runtime code
3. decide the exact trusted-boundary rules
4. add `trusted fn` / `trusted impl` in a narrow initial form
5. surface trusted code clearly in audit outputs

## Recommendation

Yes, a trusted boundary is a strong design for Concrete.

It preserves the right distinction:

- **`with(Alloc)`** and other capabilities describe public semantic effects
- **`trusted`** describes internal implementation trust

That is the cleanest way to keep:

- safe APIs honest
- allocation explicit
- unsafe internals contained
- the trust boundary visible and auditable
