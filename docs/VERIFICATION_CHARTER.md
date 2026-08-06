# Verification Charter

Status: product direction — not a statement of shipped guarantees

Concrete's verification goal is:

> Important behavior is specified at boundaries, composed across calls and
> packages, carried in independently re-checkable artifacts, and assigned
> explicit evidence. Anything outside the supported verification surface is
> named rather than silently omitted.

The product is not a green `verified` badge. It is a transferable account of
what was claimed, what artifact the claim describes, how it was checked, which
translation and assumptions it depends on, and whether a downstream consumer
can replay it with a kernel they choose.

This is direction, not a claim of automatic completeness. For the guarantees
that ship today, see [CLAIMS_TODAY.md](CLAIMS_TODAY.md).

## The intended contract

Every well-formed property in a declared supported logic is assigned one
explicit disposition:

1. proved;
2. enforced statically;
3. checked at runtime;
4. tested or solver-supported, with its trust class identified;
5. accepted as an explicit assumption; or
6. rejected with a precise unsupported-fragment reason.

No property becomes proved merely because several tools agree. A result also
records its source and specification binding, dependency closure, translation
assurance, checker assumptions, freshness, and replay instructions.

## Target user experience

A public function can eventually describe:

- preconditions, postconditions, and functional refinement;
- mutation through old-state expressions and frame conditions;
- termination through a well-founded variant;
- authority, effects, allocation, stack, and runtime-failure behavior;
- relational properties through an explicitly separate relational contract.

A caller establishes the callee's preconditions and may rely on its exported
postconditions without inspecting or inlining its body. A package publishes
machine-checkable interface contracts plus evidence artifacts. A consumer can
reject an upgrade that weakens a required contract, widens authority, introduces
trust, exceeds a resource budget, or loses required proof coverage.

Concrete already has substantial pieces of this surface: `#[requires]`,
`#[ensures]`, call-site obligations, loop invariant and variant obligations,
ghost code, proof attachment, evidence classes, and named coverage gaps. The
work is to make these pieces compositional, complete over declared fragments,
portable across package boundaries, and independently replayable—not to replace
them with a second contract system.

## Product invariants

1. **No silent coverage loss.** Every relevant construct is lowered,
   conservatively abstracted, or reported as unsupported.
2. **No evidence without binding.** Evidence identifies the source, contract,
   dependencies, semantics, and tool versions it attests to.
3. **No trust laundering.** Enforcement, runtime checks, tests, solvers,
   assumptions, and kernel proofs remain distinct.
4. **Composition cannot strengthen a claim.** A caller or importing package may
   rely on no more than a callee or dependency actually exports.
5. **Faithfulness is load-bearing.** More kernels do not repair a shared
   mistranslation; lowering assurance accompanies every evidence claim.
6. **Independent replay is a product surface.** Each graduated contract family
   defines a versioned artifact and standalone replay path as it ships.
7. **Policy is graduated, not performative.** Projects set requirements by
   module, boundary, property family, and explicit hole budget. Strict profiles
   may deny all holes; adoption profiles may permit named debt. Neither may hide
   or relabel it.

## Evidence is a vector, not a ladder

Evidence must retain at least these independent dimensions:

| Dimension | Examples |
|---|---|
| semantic coverage | one execution; bounded domain; all modeled executions |
| disposition | proved; enforced; runtime-checked; tested; assumed; missing |
| checker trust | compiler; external solver; proof kernel |
| translation assurance | unchecked; sampled; exhaustive; formally justified |
| independence | shared bridge; independent renderer; independent kernel |
| composition | local; call-closed; package-closed |
| freshness | unbound; source-bound; dependency-bound |

Multi-kernel evidence is a differentiator because it makes claims portable
across trust foundations. It is valuable only when the artifact and its lowering
assurance are portable too. Kernel breadth therefore tracks contract reach:
each new compositional property family ships with its artifact representation,
honest bridge status, and replay story rather than waiting for a final prover
phase.

## Practical limits

Termination and other non-trivial semantic properties are undecidable for
arbitrary programs, although useful fragments admit inference. Concrete may
infer specifications or measures when the result is sound and explainable, but
author-supplied contracts remain necessary. Zero-annotation proof is an
ergonomic goal for routine safety obligations, not a completeness promise.

The current differential checks provide useful lowering evidence now:
exhaustive on suitable finite fragments and sampled elsewhere. Formal semantics
and verified translations can strengthen that evidence incrementally; they are
not a prerequisite that freezes delivery of every contract feature.

General temporal liveness is not the same as termination. Decreasing variants
support termination and total correctness; loop invariants support safety and
functional correctness. Relational properties such as constant-time behavior
need paired-execution semantics rather than being forced into ordinary per-site
obligations.

