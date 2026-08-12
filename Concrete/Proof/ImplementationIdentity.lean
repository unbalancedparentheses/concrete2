import Concrete.Proof.IdentityUseBytes
import Concrete.Proof.Digest

/-!
# Implementation identity

What a callable IS — signature, generics, capabilities, contracts and structural body — with no
proof-link metadata. Separate from the proof SUBJECT, which additionally binds the selected
specification and claim scope.

**Placement below `DependencyEdge` is load-bearing.** The manifest that a `body` dependency edge
binds against must compute its own digests rather than accept them from a caller: a public entry
point taking `(CallableId x String x String)` cannot tell a computed digest from a well-formed
invented one. Computing them inside the manifest constructor requires this module to be reachable
from `DependencyEdge`, and it is: `SubjectFacts`, `EvidenceTree` and `IdentityUseBytes` mention
`DependencyEdge` nowhere, and `shortHash` lives in `Digest`.

Moved verbatim from `ProofCore`. The V2 preimage bytes are frozen and this move does not touch
them — `implementationPreimage` is shared with `proofSubjectDigestV2`, which is why the
domain-separating prefix is applied to the HASH rather than to the preimage.
-/

namespace Concrete

/-- The IMPLEMENTATION preimage: what a callable IS, with no proof-link metadata.

    Identity, typed signature, generics, capabilities and contracts (via `facts.canonical`) plus
    the structural body. Deliberately excludes the selected specification and claim scope: those
    say what a particular proof CLAIMS about this implementation, and an implementation does not
    change when a different proof is pointed at it.

    Exposed as the preimage rather than only as a digest so `proofSubjectDigestV2` can extend it
    without nesting a hash — which would change V2's bytes and break its freeze for a refactor
    that adds no information. -/
def implementationPreimage (facts : Proof.CheckedDeclFacts)
    (body : Proof.CompleteEvidenceBodyV2) : String :=
  "subjectV2:" ++ facts.canonical ++ "|body:" ++ shortHash (Proof.bodyBytesV2 body)

/-- The implementation digest — the identity a `body` dependency edge should bind.

    Distinct from the proof-subject digest, and the distinction is the point: a table entry
    describes an implementation, so binding the full subject there would couple table membership
    to which specification a proof link happened to select. -/
def implementationDigest (facts : Proof.CheckedDeclFacts)
    (body : Proof.CompleteEvidenceBodyV2) : String :=
  -- DOMAIN-SEPARATED. The preimage begins `subjectV2:` because it is shared with
  -- `proofSubjectDigestV2`, whose bytes are frozen. Hashing it unprefixed would give the
  -- implementation identity the same domain as a proof subject over the same inputs — two
  -- different identities whose values could not be told apart by their construction. The prefix
  -- is on the HASH, not the preimage, so V2 values stay byte-identical.
  shortHash ("implementationV1:" ++ implementationPreimage facts body)

end Concrete
