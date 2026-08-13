# Verification IR

Status: normative design direction — VIR v1 is not yet a shipped compatibility promise

The Verification IR (VIR) is the small, typed language that defines what
Concrete proof artifacts and standalone certificate checkers mean. It is not a
serialization of whichever prover syntax the compiler happens to emit.

See [EVIDENCE_ARCHITECTURE.md](EVIDENCE_ARCHITECTURE.md) for the surrounding
evidence model and [CLAIMS_TODAY.md](CLAIMS_TODAY.md) for current support.

## Purpose

VIR provides one canonical proposition between producer and consumers:

```text
Concrete source
      |
   typed Core
      |  separately reported source correspondence
      v
canonical VIR proposition
      |  certificate or proof-object checking
      v
logical-validity evidence
```

The proposition, certificate, checker result, and source-correspondence result
are separate artifacts. Proving VIR does not prove that VC generation was
faithful.

## VIR v1 boundary

The initial intended fragment contains:

- booleans and propositions;
- linear mathematical-integer arithmetic;
- explicitly selected fixed-width bit-vector operations;
- records with statically identified fields;
- arrays modeled as total functions with explicit length/bounds facts;
- conditionals and let bindings with stable lexical identities; and
- versioned defined or uninterpreted specification functions.

Every operation defines exact typing, evaluation, failure, overflow, and
partiality behavior. Source constructs outside the fragment produce a named
unsupported result; no backend may silently approximate them into a stronger
claim.

## Permanent simplicity constraints

Canonical VIR meaning never depends on:

- source or checkout paths;
- declaration, import, allocation, hash-table, or traversal order;
- process-global binder counters;
- unresolved source names;
- ambient plugins or metaprograms;
- hidden coercions or inferred dependencies;
- prover-specific pretty printing; or
- unspecified host arithmetic.

VIR v1 does not contain arbitrary inductive declarations, general
definitional equality, or prover-kernel projection machinery. A rich prover
backend may use its own internal language, but that additional surface remains
part of that backend's versioned trust and is not imported into the portable
VIR semantics.

## Identities

Parameters use signature position. Locals and binders use function-local
structured lexical paths. Functions, contracts, fields, and specification
symbols use stable qualified semantic identities. Unresolved identity is a
refusal, never a fallback to spelling, source position, or allocation id.

Alpha-renaming and unrelated declaration/import reordering leave canonical VIR
bytes unchanged. A semantic change to type, operation, contract, claim scope,
or referenced definition changes the relevant canonical identity.

## Canonical encoding

The normative representation is a versioned canonical binary codec. Display
text and JSON are diagnostics only. Decoding rejects duplicate fields,
non-canonical integer encodings, alternate orderings, unknown critical fields,
trailing bytes, excessive nesting, cycles where forbidden, and resources over
declared limits.

Every hashed domain has a distinct prefix and schema identity. A schema label
cannot be silently redefined after acceptance; failed pre-release acceptance
is explicitly revoked, while an authoritative change receives a new version.

## Semantics and executable reference

VIR ships with an executable reference evaluator/checker for its declared
fragment. The semantics specify:

- mathematical integers versus fixed-width words;
- signed division and modulo corner cases;
- shift domains;
- array indexing and update;
- record construction/projection;
- assumptions and quantifier domains;
- stuck/unsupported outcomes; and
- evaluation resource limits.

The reference evaluator is not automatically a proof that Core-to-VIR
lowering is faithful. It is the common meaning against which differential,
exhaustive, certificate, and future formal correspondence evidence is stated.

## Certificate-profile relation

A certificate profile maps a declared VIR subset to exact checker input. For
example:

```text
VIR proposition
-> canonical CNF bytes and digest
-> retained DRAT/LRAT certificate
-> versioned checker result
```

The mapping itself is an evidence-bearing translation. Regenerating another
certificate by re-solving the CNF is corroboration, not replay of the retained
artifact.

## Extension admission

Every VIR extension requires:

1. grammar and typing changes;
2. executable semantic changes;
3. canonical-codec version analysis;
4. source/Core correspondence behavior;
5. backend and certificate-profile behavior;
6. unsupported and malformed controls;
7. semantic-change and invariance controls;
8. wrong-goal/correct-certificate swap controls;
9. resource-exhaustion controls; and
10. an explicit statement of remaining trust.

No extension graduates solely because every current backend accepts its
rendering.

