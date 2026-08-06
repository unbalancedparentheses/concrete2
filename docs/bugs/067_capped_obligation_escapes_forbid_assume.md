# Bug 067 — a capped obligation escapes `forbid-assume` when more kernels attest

**Status:** OPEN — main is RED on this
**Found:** 2026-08-05, by CI on the multi-prover merge (`04fa2426`). Not reproducible
locally without Rocq/Isabelle installed, which is why local runs were green.
**Severity:** authority leak. An obligation resting on an UNSOUND HYPOTHESIS passes the
release gate.

## Witness

`examples/unsound_hypothesis/src/main.con`, with `forbid-assume = true`.

| environment | multi-kernel verdict | `concrete check` |
|---|---|---|
| no external provers (local) | `=> assumed` (rocq: off, isabelle: off) | **E0617 — rejected** |
| Rocq + Isabelle present (CI) | graduates out of `assumed` | **passes** |

`scripts/tests/check_known_wrong_corpus.sh` asserts the rejection and fails in CI:

    FAIL forbid-assume does NOT reject a capped obligation — the cap is display-only

## Why it matters

The cap exists because the obligation rests on a hypothesis known to be unsound. Adding
independent kernels does not make the hypothesis sound — each kernel closes ITS LOWERING of
the same unsound premise. So more attestation removes the cap that was protecting against
exactly this.

This contradicts the spike's own stated invariant in `ObligationCore.lean`: these classes
"never launder past a `trusted` boundary". Here the cap is lost, and the release gate that
should stop it does not fire.

It is also the concrete instance of the gap the spike documents: *"nothing verifying they
spell the SAME proposition — there is no subject-digest cross-check"*. Without that check,
N kernels accepting N lowerings is being treated as stronger evidence than one, when the
premise is unsound in all N.

## Resolution options

1. **Cap dominates attestation.** A capped obligation stays capped regardless of how many
   kernels attest; `forbid-assume` fires on the cap, not on the badge. Preferred — the cap
   is a statement about the PREMISE, which kernel count cannot affect.
2. **Revert the merge** until 1 is implemented, keeping R-0004 on main.

## Gate

`check_known_wrong_corpus.sh` already asserts the property and already fails. It must NOT be
weakened; it is doing exactly its job, and it caught this only because CI has the provers.
