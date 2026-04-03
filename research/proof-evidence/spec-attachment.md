# Specification Attachment

**Status:** Open

This note defines how specifications should attach to Concrete functions in a Lean-backed proof workflow.

## Why This Matters

Proofs are only useful if it is clear:

1. what function the proof is about
2. what property is claimed
3. what preconditions are assumed
4. where that specification lives

If the spec model is unclear, proof-backed evidence will remain niche and fragile.

## The Design Space

Likely options include:

1. specs live entirely in Lean, keyed to extracted function artifacts
2. Concrete eventually gains lightweight source-level markers that point to external Lean specs
3. reports carry spec/proof links without changing ordinary function syntax

Concrete should start with the lightest option that still gives clear traceability.

## What This Note Should Decide

1. whether specifications are source-visible, artifact-visible, or Lean-only
2. how preconditions and postconditions are named
3. how one theorem is tied to one Concrete function revision
4. whether profile compliance and proof obligations can share artifact structure
