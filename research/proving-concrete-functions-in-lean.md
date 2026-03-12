# Proving Concrete Functions In Lean

Status: Open

This note sketches how Concrete programs could eventually be proved in Lean, and what architecture choices make that realistic or unrealistic.

## Short Answer

Yes, Concrete functions should be provable in Lean, but the realistic path is not "prove arbitrary surface syntax directly".

The realistic path is:

1. formalize a small Core language in Lean
2. give that Core language an executable or relational semantics
3. elaborate Concrete source into Core
4. connect selected Concrete functions to their Core meaning
5. prove properties about that Core meaning in Lean

That makes function proofs a downstream consequence of the compiler architecture instead of a separate ad-hoc feature.

## Why This Fits Concrete

Concrete is already being shaped around:

- explicit Core semantics
- explicit pass boundaries
- SSA as a backend boundary
- a small semantic surface
- explicit trust/capability/resource boundaries

Those choices are exactly what make a Lean proof story plausible.

## Why This Is Useful

This matters because it lets Concrete justify a stronger claim than "the compiler seems well-designed".

It would mean:

- not only can you reason about the language in Lean
- you can reason about actual Concrete programs in Lean

That is useful for several reasons.

### 1. It Validates The Language Design

If small real functions can be proved against formal Core semantics, that is strong evidence the language is actually as explicit and proof-friendly as intended.

### 2. It Tests Whether The Compiler Architecture Choice Was Correct

If Core really works as a proof boundary, then the effort around:

- explicit Core semantics
- semantic cleanup
- small language surface
- explicit trust/effect boundaries

was not only aesthetically good; it was functionally correct for the project's proof goals.

### 3. It Is A Real Differentiator

Many languages can talk about safety or correctness.

Far fewer can realistically say:

- here is a source function
- here is its formal Core meaning
- here is a Lean proof of a property about it

That is a strong identity marker for Concrete.

### 4. It Helps Define What Should Remain Simple

Once the project cares about proving actual functions, it becomes easier to reject language features that would damage that property or make the proof boundary less explicit.

### 5. It Creates A Path From Language Trust To Program Trust

Compiler proofs and program proofs are different:

- compiler proofs say "the compiler preserves semantics"
- program proofs say "this program satisfies its spec"

Concrete is unusually well-positioned to care about both.

### 6. It Is Especially Valuable For Security / Audit-Sensitive Code

If Concrete is used for low-level code where authority, resources, and trust boundaries matter, then proving selected critical functions is much more valuable than generic language marketing.

## Why This Could Be Distinctive

Program verification is not new, and some other systems-oriented languages or verification ecosystems already support related work.

What would still be relatively unusual here is the combination of:

- a low-level language
- explicit trust/capability/resource boundaries
- compiler architecture intentionally aligned with a formal Core semantics
- and a realistic path to proving selected user programs in Lean

That is not the same thing as "verification exists somewhere". It would make this proof story part of Concrete's architectural identity rather than an external afterthought.

## Levels Of Proof

There are several different goals that can all be called "proving Concrete functions":

### 1. Compiler / Language Soundness

Examples:

- progress and preservation
- ownership / linearity soundness
- capability / trust honesty
- Core -> SSA preservation

This proves that the language and compiler behave coherently.

### 2. Program Property Proofs Over Core

Examples:

- a pure function returns sorted output
- a parser/formatter pair round-trips
- a transformation preserves a structural invariant

This is the most realistic early form of proving Concrete programs.

### 3. Program Refinement Against Specifications

Examples:

- a Concrete function refines a mathematical spec
- an effectful function respects a capability-aware contract
- a data-structure operation preserves representation invariants

This is possible, but depends on stronger semantic/spec infrastructure.

## Likely Technical Approach

### Deep Embedding First

The most realistic initial model is a deep embedding:

- represent Core syntax as Lean data
- define evaluation / typing / effect rules in Lean
- prove properties over that representation

This is the right place to start because it aligns with compiler formalization work already on the roadmap.

### Surface Syntax Is Not The First Target

Trying to prove arbitrary surface Concrete code directly is the wrong first move.

Surface syntax includes:

- parser details
- elaboration details
- naming and sugar
- diagnostics-facing structure

Those are valuable, but they are not the cleanest proof interface.

Core is the right proof boundary because it is:

- smaller
- more explicit
- semantically authoritative

## What Should Be Provable First

The first realistic target subset is:

- pure functions
- no FFI
- no `Unsafe`
- no `trusted`
- no environment interaction
- simple recursion / structured control flow
- algebraic data types and pattern matching

Examples of good first proofs:

- arithmetic helpers
- structural recursive functions
- formatter/parser properties on limited domains
- collection operations over abstract specs

## What Gets Harder

These cases need stronger models or proof boundaries:

- FFI
- `Unsafe`
- `trusted`
- mutable heap/stateful code
- capabilities tied to the host environment
- concurrency/runtime-dependent behavior

That does not make them impossible. It means they likely need:

- relational specs
- effect models
- trusted assumptions at boundaries
- explicit proof scopes instead of fully total-function reasoning

## Compiler Support Needed

To make function proofs practical, Concrete should eventually be able to:

1. expose a stable Lean-side representation of Core terms for selected functions
2. preserve source-to-Core traceability well enough that proofs remain understandable
3. identify trusted/unsafe/FFI boundaries explicitly in the proof story
4. keep language-item identity explicit so proofs do not depend on ad-hoc names

This means the formalization roadmap and the semantic-cleanup roadmap directly support function proving.

## Good First Milestones

1. Formalize a small pure Core fragment in Lean.
2. Prove basic typing and evaluation properties for that fragment.
3. Select a few representative Concrete functions and connect them to their elaborated Core form.
4. Prove simple correctness properties about those functions in Lean.
5. Later, extend the proof boundary toward effects, resources, and capabilities.

## What Not To Do First

- do not start by trying to prove arbitrary source programs end to end
- do not start with FFI-heavy or `Unsafe`-heavy examples
- do not make proof tooling depend on unstable surface syntax details
- do not bolt on a separate "verification language" before the Core semantics are strong

## Roadmap Connection

This topic belongs downstream of:

- semantic cleanup
- stronger Core semantics/formalization work
- explicit trust/capability boundaries
- stable artifact boundaries

It is best treated as a later formalization/proof track, not as an early-language feature.
