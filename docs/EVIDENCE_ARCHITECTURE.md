# Evidence Architecture

Status: normative design direction — not a statement of shipped guarantees

This document defines the target data model for Concrete evidence. The
[verification charter](VERIFICATION_CHARTER.md) states the product promise;
this document states the architectural boundaries needed to keep that promise.
Current support remains documented in [CLAIMS_TODAY.md](CLAIMS_TODAY.md).

## Governing rule

> Concrete represents every claim at least as precisely as it describes that
> claim. Source correspondence, logical validity, dependency closure, replay
> history, and current policy acceptance remain separate, typed, independently
> degradable facts.

No report, renderer, package writer, or policy evaluator may reconstruct an
authoritative fact from display strings. Authority moves only through checked
constructors whose acceptance conditions are executable and negatively
controlled.

## Five objects, not one status

### Source correspondence

`SourceCorrespondence` answers whether the canonical verification proposition
describes the relevant source and typed-Core behavior. Its assurance is
reported independently:

```text
missing
producer_validated
sampled
differentially_checked
exhaustive_for_finite_fragment
certificate_checked
formally_justified
```

A certificate proving a VIR proposition does not strengthen this relation.
Concrete may later check narrow translation certificates or verified
lowerings, but it must not infer source faithfulness from solver or kernel
success.

### Logical validity

`LogicalValidity` answers whether the exact canonical proposition is
established by the retained evidence. Evidence families remain distinct:

```text
certificate_replayed
same_kernel_replayed
independent_reimplementation_replayed
different_family_replayed
kernel_checked
solver_trusted
runtime_checked
tested
assumed
missing
```

Re-running a derivation is not replay of the original evidence. A solver that
re-solves a query provides corroboration; it does not validate the certificate
or proof object that originally supported the claim.

### Dependency closure

`DependencyClosure` answers whether every compiler edge, theorem witness,
contract hypothesis, table entry, implementation, assumption, and trusted
boundary needed by the claim is present, unique, current, and consumed exactly
once where required. Missing, surplus, duplicate, ambiguous, unclassified, and
mismatched sets are named refusals. They are never discarded by `filterMap`, a
first-match lookup, or an advisory-only warning.

### Replay receipt

`ReplayReceipt` is an immutable historical statement that exact retained
material was checked. It binds at least:

- subject and claim scope;
- canonical proposition and artifact/certificate identities;
- checker implementation, version/commit, rule-set, and exporter identities;
- dependency root and table material;
- toolchain, workspace, imports, schema, and canonical-codec identities;
- trust and assumptions present during replay; and
- the replay result and profile.

A receipt does **not** contain the currently effective vulnerability or
revocation disposition. An advisory discovered after minting does not make the
historical replay fictitious.

### Policy decision

`PolicyDecision` is time-relative:

```text
ReplayReceipt
+ current AdvisoryRegistry
+ accepted expected root or signing key
+ consumer Policy
-> PolicyDecision
```

If policy decisions are themselves retained or signed, they bind the exact
policy and advisory-registry identities used. Updating an advisory registry
can invalidate a decision without changing or reminting its receipt.

## Typed identities and authority states

Interchangeable `String` digests are forbidden at authoritative module
boundaries. Use distinct domain-separated types such as:

```text
SubjectDigest            ImplementationDigest
ContractDigest           ClaimDigest
PropositionDigest        TheoremArtifactDigest
CertificateDigest        DependencyRoot
ReceiptDigest            CheckerIdentity
RuleSetIdentity          ToolchainIdentity
PolicyIdentity           AdvisoryRegistryIdentity
```

Each type defines canonical bytes, domain separation, strict parsing, schema
identity, and a private or validating constructor. A value of one digest family
cannot be supplied where another is required.

Authority stages are also types, not comments:

```text
DeclaredEvidence
StructurallyValidatedEvidence
DependencyClosedEvidence
ReplayBoundEvidence
PolicyAcceptedEvidence
```

Do not replace flat statuses with one giant record of optional fields. Use a
shared envelope plus typed variants for evidence families so invalid
combinations remain unrepresentable.

## Authorship modes

The target proof-attachment surface makes the evidence mode explicit where it
enters the program:

```text
#[certificate_by(...)]
#[proof_object_by(...)]
#[trusted_proof_by(...)]
#[assume(...)]
```

`certificate_by` selects a versioned certificate profile. `proof_object_by`
retains exact replay material. `trusted_proof_by` visibly widens the trusted
base. `assume` remains an assumption. Existing `#[proof_by]` cannot silently
inherit the strongest class during migration; it maps conservatively until its
mode is explicit.

## Certificate profiles

Every certificate profile fixes:

- the supported VIR fragment;
- canonical proposition encoding;
- certificate encoding;
- checker algorithm, implementation, version, and rule-set digest;
- deterministic checking relation and failure taxonomy;
- resource/depth limits;
- exact retained artifacts; and
- resulting evidence class.

Initial candidates are linear-arithmetic witnesses, exact CNF plus retained
DRAT/LRAT, and exhaustive finite-domain witnesses. These remain probes until
stable export, semantic agreement, eligible coverage, and checker cost are
measured. Nonlinear solver success remains `solver_trusted` until a checkable
proof object exists.

## Independence

Different executable names do not establish independence. Record these axes
separately:

- implementation and code lineage;
- algorithm;
- logical/proof-system foundation;
- artifact parser;
- exporter and canonicalizer;
- shared libraries;
- shared specification; and
- shared retained artifact.

Policy can then require two executions, two implementations, two design
families, or a certificate plus a kernel. Those are different claims.

## Advisory and revocation boundary

Checker advisories are validation-time inputs. The machine-readable registry
keys entries by exact implementation/version/rule set and upstream
advisory/reproducer identity, and records `accepted`, `affected`, `revoked`, or
`unknown` plus remediation and affected claim indexes.

An affected checker version is downgraded wholesale by default. Fragment-
scoped narrowing is permitted only when an independently checked
`CheckerFeatureFootprint` establishes that the vulnerable mechanism was absent
from the retained environment. A footprint self-reported only by the affected
checker is not sufficient.

Revocation preserves unaffected dimensions. A claim can remain source-bound
and dependency-closed while its logical-validity evidence is rejected pending
replay.

## Standalone consumer

The independent verifier has three layers:

1. **Envelope/accounting:** strict decoding, digest and root recomputation,
   identity uniqueness, dependency closure, receipts, advisories, trust,
   assumptions, authentication, and policy.
2. **Certificate checking:** check exact retained certificates against exact
   retained canonical propositions without invoking their generators.
3. **Translation assurance:** check narrow correspondence evidence where it
   exists and otherwise report the producer-side assurance without upgrading
   it.

Internal consistency is not authenticity. Verification requires an externally
pinned expected root or a signature rooted in a consumer-accepted key.

## Authority transitions

Every new path progresses explicitly:

```text
designed
-> prototype
-> negatively controlled
-> mutation-killed
-> shadow-compared
-> independently reproduced
-> authoritative
-> adversarially closed
```

No stage is inferred from code existing or a gate being green. A mutation must
exercise the production consumer, not only a helper. Gate results distinguish
registered, executed, killed, survived, inconclusive, and vacuous.

## Required degradation shape

Concrete never collapses an incident into one badge. A policy report may say:

```text
subject_binding: current
source_correspondence: differentially_checked
dependencies: complete
drat_certificate: valid
lean_replay: revoked_checker
authentication: valid
policy: rejected
required_action: replay Lean artifact with an accepted checker
```

That separability is the purpose of the architecture, not merely a reporting
convenience.

