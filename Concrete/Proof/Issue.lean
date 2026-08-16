import Concrete.Proof.ProofCore
import Concrete.Proof.Receipt
import Concrete.Proof.Replay
import Concrete.Proof.ClassificationTable
import Concrete.Proof.DependencyRoot

/-!
# Production receipt issuance (R-0004 package 3)

Receipts existed and nothing minted them. The envelope was closed, the minting authority was closed,
and the production pipeline still had no path from "the kernel accepted this" to a stored fact — so
`ProofEvidenceReceipt` was, honestly described, a well-tested helper type. This module is the path.

WHY THE COMPILER CAN DO THIS AT ALL. Edge classification reads a theorem's ELABORATED type, which
exists only while Lean is elaborating with the proof modules imported, and the compiler imports
neither (`Examples` imports `Concrete`, so importing the proofs from `Concrete` would be a cycle).
The answer is therefore computed at generation time and checked in as `ClassificationTable`, whose
freshness two gates re-derive from the live environment. Issuance reads it through `validatedRowOf`,
so a row that failed structural validation cannot classify anything.

WHAT ISSUANCE IS NOT ALLOWED TO DO is invent any of the four inputs. Each comes from exactly one
producer already used elsewhere, and each refuses on its own terms:

| input | producer | refuses when |
|---|---|---|
| the kernel accepted it | `SuccessfulReplay.of?` | not accepted, unbound, interrupted, unreplayed, fallback workspace |
| what the theorem depends on | `validatedRowOf` | absent, ambiguous, or malformed row |
| what was proved | `ProofCoreEntry.subjectDigest` | facts absent or incomplete |
| what the claim rests on | `dependencyRootMaterial` | any incomplete or unclassified closure |

Every one of those refusals is REPORTED, not skipped. A claim that cannot receive a receipt must say
which of the four inputs was missing, because "no receipt" and "receipt withheld for this reason" are
different facts and only the second is actionable.
-/

namespace Concrete.Proof

open Lean

/-- The environment identities issuance cannot derive for itself.

    These come from the project, not from the replay: the workspace identity is over the package's
    declared name and module set, and the import closure is over module digests. The replay knows
    which Lake workspace it ran in and which modules it imported by NAME, which is not the same
    thing — so they are supplied, and the toolchain half is NOT, because that one the replay does
    know and a caller must not be able to disagree with it. -/
structure IssueEnvironment where
  compilerVersion : String
  workspaceId     : String
  importsId       : String
  deriving Repr

/-- Why one claim did not receive a receipt.

    Each case names WHICH of the four inputs was unavailable. A single "could not issue" would be
    the same shape as the diagnostics this project keeps replacing: true, unactionable, and equally
    consistent with every cause. -/
inductive IssueRefusal where
  /-- The kernel's answer does not witness this claim. -/
  | replay (theoremName : String) (why : ReplayEvidenceRefusal)
  /-- The theorem has no usable classification, so what it depends on is unknown. -/
  | classification (theoremName : String) (why : ClassificationRefusal)
  /-- The claim has no proof link, so there is no artifact to bind. -/
  | noProofLink (subject : String)
  /-- The subject digest is absent or incomplete. An incomplete subject must not be representable
      as a digest string, or it becomes comparable as though it were complete. -/
  | noSubjectDigest (subject : String)
  /-- The subject has no scoped identity, so its closure was never examined. -/
  | noScopedIdentity (subject : String) (why : String)
  /-- The dependency closure refused to root. -/
  | rootRefused (subject : String) (why : String)
  /-- The claim's own status is not `proved`. Caught on the drift fixture the day issuance landed:
      `elf_header_drifted` is a DIFFERENT program sharing every declaration name with `elf_header`,
      and issuance minted four receipts for it — two of them for `stale` claims, whose bodies had
      changed since the proof was linked. The token says the kernel accepted a THEOREM; it says
      nothing about whether that theorem still proves THIS body. Binding the current subject digest
      to a theorem that proved the previous one is precisely the forgery a receipt exists to
      prevent, so the composed authority verdict gates issuance. -/
  | notProved (subject : String) (status : String)
  /-- Every input was present and the material was still rejected — a table named but unbound,
      digests that do not correspond to their tables, an empty environment identity, or a trust
      claim inconsistent with its boundaries. -/
  | materialRefused (subject : String)
  deriving Repr

def IssueRefusal.canonical : IssueRefusal → String
  | .replay ..          => "replay_does_not_witness"
  | .classification ..  => "no_usable_classification"
  | .noProofLink _      => "no_proof_link"
  | .noSubjectDigest _  => "no_subject_digest"
  | .noScopedIdentity ..=> "no_scoped_identity"
  | .rootRefused ..     => "dependency_root_refused"
  | .notProved ..       => "claim_not_proved"
  | .materialRefused _  => "receipt_material_refused"

def IssueRefusal.explain : IssueRefusal → String
  | .replay t why        => s!"'{t}': {why.explain}"
  | .classification t why => s!"'{t}' has no usable classification: {why.explain}"
  | .noProofLink s        => s!"'{s}' carries no proof link, so there is no theorem artifact to bind"
  | .noSubjectDigest s    => s!"'{s}' has no complete subject digest to establish evidence against"
  | .noScopedIdentity s w => s!"'{s}' has no scoped identity: {w}"
  | .rootRefused s w      => s!"'{s}' has no computable dependency root: {w}"
  | .notProved s st       => s!"'{s}' is '{st}', not 'proved' — the kernel accepted a theorem, which says nothing about whether it still proves this body"
  | .materialRefused s    => s!"'{s}' assembled material that the receipt envelope refused"

/-- One claim's issuance outcome, keyed by the subject it is about. -/
structure IssueOutcome where
  subject : String
  result  : Except IssueRefusal ProofEvidenceReceipt
  deriving Repr

/-- Which claims to ask the kernel about.

    ONE PRODUCER, because there are now two consumers — `--report check-proofs` and receipt issuance
    — and a second copy of this rule would eventually replay a different set than it issued for,
    which is the quietest possible way to withhold a receipt.

    `unbound` is included and must be: kernel replay is how a link WITHOUT a stored subject earns
    one, so excluding it would leave no path from unbound to bound. It still cannot mint — the
    minting token refuses an `acceptedUnbound` verdict — which is exactly the intended split between
    "worth asking the kernel about" and "may become evidence". -/
def replayTargetsOf (pc : ProofCore) : List ReplayTarget :=
  pc.obligations.filterMap fun o =>
    match o.spec with
    | some s =>
      if o.status == .proved || o.status == .stale || o.status == .unbound then
        some { subject := o.functionId.qualName, theoremName := s.proofName
             , kind := .refinement
             , origin := if s.source == .registry then .sourceLinked else .hardcoded
             , binding := if o.status == .unbound then .unbound else .bound }
      else none
    | none => none

/-- The dependency evidence a validated classification row describes.

    Built here rather than by the caller so the row's tables and its digests cannot drift apart:
    `EdgeEvidence` carries them as two lists, and `ReceiptMaterial.of?` refuses if they fail to
    correspond — a refusal that should never be reachable from a validated row, and is kept
    reachable because "should never" is not a guarantee. -/
def edgeEvidenceOfRow (row : ValidatedRow) : EdgeEvidence :=
  { edge := row.edge
  , tables := row.tables.map fun (n, _) => Name.mkSimple n
  , tableDigests := row.tables.map fun (n, d) => (Name.mkSimple n, some d)
  , quantifiesOverTable := row.quantifies }

/-- Issue a receipt for one claim, or say precisely which input was missing.

    The token is taken FIRST. Every other input is a fact about the program that is worth computing
    anyway; the token is the one that says a kernel ran, and checking it last would mean assembling
    a complete receipt body for a claim nobody had replayed and then discarding it — which is the
    shape that eventually gets returned by mistake. -/
def issueFor (pc : ProofCore) (res : ReplayResult) (env : IssueEnvironment)
    (trustedDepsOf : String → List String)
    (e : ProofCoreEntry) : Except IssueRefusal ProofEvidenceReceipt := do
  let subject := e.qualName
  let some spec := e.spec | throw (.noProofLink subject)
  let thm := spec.proofName
  -- THE COMPOSED AUTHORITY VERDICT GATES ISSUANCE, before anything else is assembled. `proved` here
  -- is the status AFTER `applyCorrespondenceAuthority`, so a claim whose dependency closure has no
  -- validated per-edge justification, or whose body drifted from what the proof was linked against,
  -- is already excluded. Replay answers "did the kernel accept this theorem"; it cannot answer
  -- "does that theorem still prove this subject", and only one of those questions is about a body.
  let some obl := pc.obligations.find? (fun o => o.functionId.qualName == subject)
    | throw (.noProofLink subject)
  if obl.status != .proved then throw (.notProved subject obl.status.canonical)
  let sr ← (SuccessfulReplay.of? res thm).mapError (IssueRefusal.replay thm)
  let row ← (validatedRowOf thm).mapError (IssueRefusal.classification thm)
  let some subjDigest := e.subjectDigest | throw (.noSubjectDigest subject)
  let sid ← match e.definitionIdentity with
    | .error w => throw (.noScopedIdentity subject w.explain)
    | .ok i => pure i
  let nodes := dependencyNodesOf pc pc.callGraph
  let rootMat ← match dependencyRootMaterial nodes sid with
    | .error w => throw (.rootRefused subject w.explain)
    | .ok m => pure m
  -- TRUST TRAVELS WITH THE CLAIM, from the same producer the status report reads. Recomputing it
  -- here would be a second answer to "which boundaries does this rest on", and the two would
  -- eventually disagree — with the receipt being the one nobody re-checks.
  let boundaries := trustedDepsOf subject
  -- The root's own trust verdict and the named boundaries must AGREE. They are derived
  -- independently — one from traversing the closure, one from the status entry — so a
  -- disagreement means one of them is wrong, and minting either reading would record a trust
  -- claim that half the system does not share.
  if rootMat.carriesTrust != !boundaries.isEmpty then
    throw (.materialRefused subject)
  let some material := ReceiptMaterial.of? (some subjDigest) (edgeEvidenceOfRow row)
      rootMat.preimage rootMat.carriesTrust boundaries
      env.compilerVersion env.workspaceId env.importsId
    | throw (.materialRefused subject)
  return ProofEvidenceReceipt.mint sr material

/-- Issue over every claim the replay covered, reporting each outcome.

    Returns one entry per claim WITH A PROOF LINK, refusals included. A caller that wants only the
    receipts filters; a caller that wants to know what was withheld and why has it without a second
    traversal, which is what keeps "no receipt" from being reported as "nothing to report". -/
def issueAll (pc : ProofCore) (res : ReplayResult) (env : IssueEnvironment)
    (trustedDepsOf : String → List String) : List IssueOutcome :=
  pc.entries.filterMap fun e =>
    if e.spec.isNone then none
    else some { subject := e.qualName
              , result := issueFor pc res env trustedDepsOf e }

namespace IssueOutcome

def issued (os : List IssueOutcome) : List IssueOutcome :=
  os.filter fun o => match o.result with | .ok _ => true | .error _ => false

def withheld (os : List IssueOutcome) : List IssueOutcome :=
  os.filter fun o => match o.result with | .ok _ => false | .error _ => true

end IssueOutcome

end Concrete.Proof
