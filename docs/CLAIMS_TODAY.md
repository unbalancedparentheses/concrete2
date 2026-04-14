# Claims Today

Status: public reference

This page states what Concrete claims today, what it does not claim yet, and what still depends on trusted or backend assumptions.

It is intentionally short.

## Concrete Claims Today

### 1. Checked safe-code surface

Concrete already has a real checked language surface with:

- ownership and linearity enforcement
- explicit cleanup and `defer`
- explicit capability boundaries
- explicit `trusted` and `with(Unsafe)` boundaries
- a documented safe-memory guarantee boundary for the checked safe subset

References:

- [MEMORY_GUARANTEES.md](MEMORY_GUARANTEES.md)
- [GUARANTEE_STATEMENT.md](GUARANTEE_STATEMENT.md)

### 2. Real proof/evidence workflow

Concrete already has a real proof/evidence pipeline with:

- explicit `Core -> ProofCore`
- proof eligibility and exclusion reasons
- proof obligations
- proof attachments and stale detection
- machine-readable evidence artifacts
- consistency checks and CI trust gates

References:

- [PROOF_CONTRACT.md](PROOF_CONTRACT.md)
- [CLAIM_TAXONOMY.md](CLAIM_TAXONOMY.md)

### 3. Predictable-execution direction is real

Concrete already has meaningful predictable-execution checking and reporting.
That does not mean the full long-term predictable or high-integrity profile is complete.

It does mean the project is already enforcing and reporting pieces of the bounded/predictable story rather than leaving them as rhetoric.

### 4. Trust boundaries are explicit

Concrete is serious about making these visible:

- capabilities
- `trusted`
- `with(Unsafe)`
- FFI
- backend/target assumptions

That is a core project value, not optional polish.

## Concrete Does Not Claim Yet

Concrete does not currently claim:

- whole-compiler correctness
- verified code generation
- verified backend/toolchain behavior
- a complete proof of the full runtime/binary behavior of compiled programs
- a finished high-integrity profile
- a fully stabilized first public release surface

## What Still Depends On Trusted Or External Assumptions

The strongest current claims still depend on:

- the Concrete checker and compiler implementation
- the Lean kernel for proof checking
- proof attachment/registry integrity
- LLVM/clang/backend behavior
- target/runtime/OS behavior

For the explicit list, see [TRUSTED_COMPUTING_BASE.md](TRUSTED_COMPUTING_BASE.md).

## How To Read Concrete Claims

Use these words precisely:

- `enforced` means checker/compiler-enforced
- `proved` means Lean-backed over the documented proof model
- `reported` means compiler-observed and surfaced as facts/reports
- `trusted assumption` means outside the proved/enforced closure

Reference:

- [CLAIM_TAXONOMY.md](CLAIM_TAXONOMY.md)

## Profile Status Today

- `safe`: real checked surface today
- `predictable`: partially real today, still being tightened
- `provable`: real for the current proof subset
- `high-integrity`: explicit direction, not a completed profile

Reference:

- [PROFILES.md](PROFILES.md)
