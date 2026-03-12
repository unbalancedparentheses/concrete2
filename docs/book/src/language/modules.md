# Modules

A module groups functions, structs, enums, impls, and nested modules.

Basic shape:

```rust
mod modulename {
    // ..
}
```

## What Lives In A Module

Modules are the basic namespace boundary for:

- functions
- types
- impl blocks
- submodules
- imports

## Current Notes

- The module system is still evolving as the package/dependency model matures.
- Concrete's compiler already has explicit multi-file/module handling, but the final project/package UX is still a later roadmap phase.
- `Self` resolution and interface/summary handling are important parts of the compiler architecture behind the surface module syntax.

## Why Modules Matter

Modules are not only a syntax feature. They are also important to:

- visibility
- name resolution
- project/package structure
- future package/dependency semantics
