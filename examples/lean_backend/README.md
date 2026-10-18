# Experimental Lean backend example

This returns 42 using explicit wrapping arithmetic and a branch. It exercises
Concrete's normal checked SSA pipeline, the experimental QBE adapter and the
separate general-purpose Lean Compiler Backend.

See [the integration note](../../research/compiler/lean-backend-integration.md)
for Nix build commands, test evidence and the exact supported domain. This is an
isolated experiment; ordinary checked arithmetic, calls and memory operations
are not yet supported by the adapter.
