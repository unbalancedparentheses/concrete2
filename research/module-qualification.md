# Module Qualification

Status: open

Real programs are now large enough that unqualified exported names create avoidable rename pressure.

## Problem

Concrete currently lacks a normal qualified access path like:

```con
Policy.from_tag(...)
Text.parse_int(...)
```

That means multi-module programs tend to solve collisions by renaming functions instead of expressing namespace intent directly.

## Questions

1. Should Concrete support `Module.name` access directly?
2. Should imports support aliasing in addition to qualification?
3. How should qualification interact with submodules and public reexports?
4. How should diagnostics present qualified names?

## Constraints

- keep lookup rules simple
- avoid hidden import magic
- preserve explicit module boundaries
- do not complicate the parser or name-resolution surface unless the win is clear

## Why Now

This is no longer hypothetical. Phase H programs already hit name-collision pressure that should be solved structurally rather than by style conventions alone.
