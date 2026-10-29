import Concrete.Report.Effects

/-! Proof eligibility, proof status, obligations, proof dependencies, proof diagnostics and extraction reports. Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report

-- ============================================================
-- Proof Eligibility Assessment (first-class, shared by all
-- proof pipeline consumers: proof-status, extraction,
-- obligations, traceability, effects evidence)
-- ============================================================
-- This is the single authoritative source for "is this function
-- in the provable subset?" It runs BEFORE extraction or proof
-- matching, and every downstream consumer reads it.

/-- Render the eligibility report (--report eligibility). -/
def eligibilityReport (pc : Concrete.ProofCore) : String :=
  let entries := pc.allEligibility
  let header := "=== Proof Eligibility Assessment ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    if e.isTrusted then
      s!"  trusted    `{e.qualName}`  @ {locStr}\n             proof bypassed (trusted assumption)"
    else if e.eligible then
      s!"  eligible   `{e.qualName}`  @ {locStr}\n             in provable subset: pure, bounded, no FFI"
    else
      -- Float arithmetic gets a dedicated, honest framing: it is not a generic
      -- profile miss but an absent proof profile. Says the useful thing.
      let floatReason := "floating-point arithmetic has no active proof profile"
      let floatStr := if e.profileReasons.contains floatReason then
        s!"\n             float semantics: unprofiled\n             proof eligibility: excluded\n             reason: {floatReason}"
        else ""
      let otherProfile := e.profileReasons.filter (· != floatReason)
      let srcStr := if e.sourceReasons.isEmpty then "" else
        s!"\n             source: {", ".intercalate e.sourceReasons}"
      let profStr := if otherProfile.isEmpty then "" else
        s!"\n             profile: {", ".intercalate otherProfile}"
      s!"  excluded   `{e.qualName}`  @ {locStr}{srcStr}{profStr}{floatStr}"
  -- Summary
  let eligible := (entries.filter (·.eligible)).length
  let excluded := (entries.filter fun e => !e.eligible && !e.isTrusted).length
  let trusted := (entries.filter (·.isTrusted)).length
  let sourceOnly := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && !e.sourceReasons.isEmpty && e.profileReasons.isEmpty).length
  let profileOnly := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && e.sourceReasons.isEmpty && !e.profileReasons.isEmpty).length
  let bothReasons := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && !e.sourceReasons.isEmpty && !e.profileReasons.isEmpty).length
  let summary := s!"Totals: {entries.length} functions — {eligible} eligible, {excluded} excluded ({sourceOnly} source, {profileOnly} profile, {bothReasons} both), {trusted} trusted"
  s!"{header}\n\n{"\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Report: Proof Status (--report proof-status)
-- ============================================================
-- Per-function proof evidence with Elm-clear diagnostics for
-- stale, missing, and ineligible states.

/-- Proof status for a single function. -/
inductive ProofState where
  | proved          -- name + fingerprint match, extraction succeeded
  | stale           -- name matches but fingerprint changed
  | notProved       -- passes profile, extractable, no registered proof
  | blocked         -- eligible but extraction failed (unsupported constructs)
  | notEligible     -- fails profile gates (recursion, alloc, etc.)
  | trusted         -- marked trusted (bypasses proof)
  /-- Link present, no stored proof-subject digest — nothing to be fresh
      against. Distinct from `stale`, which asserts a body change. -/
  | unbound
  /-- Link present with a digest stored under an EARLIER SCHEMA. Kept distinct
      from `unbound` rather than folded into it: `unbound` means no subject was
      ever recorded, this means one was and it answers a weaker question. The
      repair differs — re-verify and re-record, versus pin for the first time —
      and collapsing the two would hide which of those the author owes. -/
  | needsRecheck
  /-- This function's own subject is fresh, but something it reaches is not
      current, so the claim contributes no proved evidence. Distinct from `stale`
      and `unbound`, which are both statements about THIS body. -/
  | depsNotCurrent
  /-- Subject fresh, dependencies current, and the dependency closure has no validated per-edge
      JUSTIFICATION: some edge lacks a witness naming that exact implementation, or a table the
      linked theorem names could not be read. A statement about the evidence, not about this body
      or any callee's freshness. -/
  | correspondenceUnjustified
  /-- The body is not shown to be the specification the linked theorem evaluates (bug 079). -/
  | specUnbound

/-- Canonical string for a ProofState. Uses the same terminology as
    ObligationStatus.canonical to prevent cross-surface drift. -/
def ProofState.canonical : ProofState → String
  | .unbound        => "unbound"
  | .needsRecheck   => "needs_recheck"
  | .depsNotCurrent => "deps_not_current"
  | .correspondenceUnjustified => "correspondence_unjustified"
  | .specUnbound => "spec_unbound"
  | .proved     => "proved"
  | .stale      => "stale"
  | .notProved  => "missing"
  | .blocked    => "blocked"
  | .notEligible => "ineligible"
  | .trusted    => "trusted"

/-- Per-function proof status record. -/
structure ProofStatusEntry where
  qualName      : String
  bareName      : String
  state         : ProofState
  currentFp     : String       -- current body fingerprint
  expectedFp    : String       -- registered fingerprint (empty if no proof)
  eligibilityReasons  : List String  -- reasons the function is not eligible for proof
  /-- ADMISSION, reported separately from `state`. `state` is extraction-driven, so a
      claim whose admission is refused stays visible, replayable and drift-monitored;
      it simply stops counting toward admitted proof coverage. A report may therefore
      say the theorem replays AND that it is not admitted, which is not a contradiction:
      the artifact is logically valid while it cannot justify the program-level claim.
      Rendering this is not optional — an unreported refusal is worse than an inert
      rule, because the verdict changes with nothing saying why. -/
  admissible    : Bool
  admissionReasons : List String := []
  unsupported   : List String  -- unsupported constructs (empty unless blocked)
  specName      : String       -- spec name (from registry or derived)
  proofName     : String       -- proof/theorem name (from registry or derived)
  proofSource   : String       -- "registry" | "hardcoded" | "none"
  origin        : String       -- "source_linked" | "json_backed" | "hardcoded" | "" (link provenance)
  coverage      : String       -- proof coverage kind: point|one_direction|iff|invariant|runtime_error|full_contract|""
  /-- The subject binding's verdict, rendered (bug 079): what the claim's body was compared with,
      or why the comparison could not be made. Empty when the function makes no proof claim. -/
  specBinding : String := ""
  /-- Reachable dependencies that are not current, when `state` is
      `depsNotCurrent`. Carried so the report can NAME them: "a dependency is
      not current" without saying which one is not actionable, and the whole
      point of this status is that the repair is somewhere else. -/
  notCurrentDeps : List String := []
  /-- Reachable trusted boundaries. Qualifies a `proved` claim rather than
      blocking it: the proof is real, and it rests on an unproven boundary. -/
  trustedDeps : List String := []
  loc           : Option SourceLoc
  fnSpan        : Option Span

/-- Convert ProofCore ObligationStatus to Report-side ProofState. -/
private def obligationStatusToProofState : Concrete.ObligationStatus → ProofState
  | .unbound => .unbound
  | .needsRecheck => .needsRecheck
  | .depsNotCurrent => .depsNotCurrent
  | .correspondenceUnjustified => .correspondenceUnjustified
  | .specUnbound => .specUnbound
  | .proved => .proved
  | .stale => .stale
  | .missing => .notProved
  | .blocked => .blocked
  | .ineligible => .notEligible
  | .trusted => .trusted

partial def collectProofStatus
    (pc : Concrete.ProofCore)
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "")
    (registry : ProofRegistry := []) : List ProofStatusEntry :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let entries := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.sourceName
    let entry := lookupBody locMap qualName
    let fnLoc := lookupLoc locMap qualName
    let fnSp := entry.map (·.fnSpan)
    -- Look up pre-computed obligation from ProofCore
    let obl := pc.obligations.find? fun o => o.functionId.qualName == qualName
    let state := match obl with
      | some o => obligationStatusToProofState o.status
      | none => .notEligible
    let fp := match obl with
      | some o => o.functionId.fingerprint
      | none => bodyFingerprint f.body
    let gates := match obl with
      | some o => o.eligibilityReasons
      | none => []
    let expectedFp := match obl with
      | some o => o.expectedFp
      | none => ""
    let (sName, pName, pSrc) := match obl with
      | some o => match o.spec with
        | some a => (a.specId.name, a.proofName,
            match a.source with | .registry => "registry" | .hardcoded => "hardcoded")
        | none => ("", "", "none")
      | none => ("", "", "none")
    -- Look up unsupported constructs from ProofCore entry (for blocked functions)
    let unsup := match pc.entries.find? fun e => e.qualName == qualName with
      | some e => e.unsupported
      | none => []
    -- Look up coverage classification + link provenance from the registry entry.
    let regEntry := registry.find? fun re => re.function == qualName
    let coverage := match regEntry with | some re => re.coverage | none => ""
    -- Registry entries are always synthesized from in-source links now (JSON
    -- registries were removed). No other origin exists since bug 083 deleted the
    -- name-keyed Proof.provedFunctions fallback; the `hardcoded` arm is unreachable.
    let origin := match regEntry with
      | some _ => "source_linked"
      | none => if pSrc == "hardcoded" then "hardcoded" else ""
    { qualName, bareName := f.name, state, currentFp := fp, expectedFp
    , eligibilityReasons := gates, unsupported := unsup, specName := sName, proofName := pName
    -- No obligation means no admission verdict was formed, which is not an admission.
    , admissible := match obl with | some o => o.admissible | none => false
    , admissionReasons := match obl with
        | some o => o.admissionReasons
        | none => ["no proof obligation was formed for this function, so no admission verdict exists"]
    , proofSource := pSrc, origin, coverage
    , specBinding := match (pc.findEntry qualName).bind (·.binding?) with
        | some (.ok b) => s!"bound to {b.spec}, the specification {b.theoremName} evaluates (body {b.valueDigest}, parameters [{", ".intercalate b.params}])"
        | some (.error w) => s!"NOT bound — {w.explain}"
        | none => ""
    -- An unjustified closure names what is unjustified. A call whose key denotes another callee
    -- (bug 081) is named by the correspondence input the verdict read, not re-derived here.
    , notCurrentDeps := match obl with
        | some o =>
          if o.status == .correspondenceUnjustified
          then o.notCurrentDeps ++ (match pc.entries.find? (·.qualName == qualName) with
            | some e => Concrete.calleeKeyRefusalsOf pc pc.callGraph e.callableId
            | none => [])
          else o.notCurrentDeps
        | none => []
    , trustedDeps := match obl with | some o => o.trustedDeps | none => []
    , loc := fnLoc, fnSpan := fnSp }
  entries ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectProofStatus pc locMap sub qualPrefix registry) []

/-- The trusted boundaries a claim's closure crosses, rendered for EVERY status that has any.

    It used to appear only under `proved`, and that hid a fact from the readers most likely to act on
    it. A trusted boundary is a property of the dependency CLOSURE, not of the verdict: a `stale` or
    `unbound` claim reaching one is resting on the same unproved assumption, and disclosing it only
    once the claim turns green means an author fixes a fingerprint and DISCOVERS an assumption that
    was there all along. Monotone propagation is only observable if it is reported wherever it holds.

    Empty for most entries, so it costs nothing where there is no boundary to name. -/
private def trustedBoundaryLine (e : ProofStatusEntry) : String :=
  if e.trustedDeps.isEmpty then ""
  else s!"\n\n  ASSUMES trusted boundaries (not proved): {", ".intercalate e.trustedDeps}"

/-- Render a single proof status entry with Elm-clear formatting. -/
private def renderProofStatusBody (e : ProofStatusEntry) (sourceMap : SourceMap) : String :=
  let locStr := fmtLoc e.loc
  let fileStr := match e.loc with | some (f, _) => f | none => ""
  let source := sourceMap.lookup fileStr
  -- Source snippet
  let snippet := match e.fnSpan, source with
    | some sp, some src =>
      let line := getSourceLine src sp.line
      if line.isEmpty then ""
      else
        let lineNumStr := toString sp.line
        let pad := lineNumStr.length
        let gutter := String.ofList (List.replicate pad ' ')
        let caretLen := line.length
        let carets := String.ofList (List.replicate caretLen '^')
        s!"\n\n {lineNumStr} | {line}\n {gutter} | {carets}"
    | _, _ => ""
  match e.state with
  | .proved =>
    let coverageTag := if e.coverage.isEmpty then "" else s!" [{e.coverage}]"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    -- Honesty line (audit 2026-07-16): this REPORT verifies link presence +
    -- fingerprint freshness only; it does not run the Lean kernel. The
    -- kernel replay is `--report check-proofs` (gated in CI for std).
    -- The claim is CONDITIONAL when its closure crosses a boundary, and must say so where it is
    -- read: a reader seeing only "proved" cannot tell that part of the chain is an unproven, audited
    -- boundary. ONE producer for that line — `trustedBoundaryLine` — so the other statuses report it
    -- identically rather than each spelling it out.
    let trustLine :=
      "\n\n  trust: linked + fingerprint-fresh — kernel replay via `--report check-proofs`"
        ++ trustedBoundaryLine e
    let specLine := if e.specBinding.isEmpty then "" else s!"\n\n  spec: {e.specBinding}"
    s!"-- proved{coverageTag} {String.ofList (List.replicate 48 '-')} {locStr}\n\n  ✓ `{e.qualName}` — proof matches current body.{snippet}\n\n  coverage: {if e.coverage.isEmpty then "unclassified" else e.coverage}{trustLine}{specLine}{originLine}"
  | .stale =>
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    -- STALE BY THE BINDING, not by a body edit (bug 079): the specification the theorem evaluates is
    -- a different body. "The body changed" would be false — it may never have matched — so say what
    -- was found instead of showing two identical fingerprints under a claim of change.
    if e.specBinding.startsWith "NOT bound" then
      -- BOTH findings when both hold: a body can also have changed since it was pinned, and that diff
      -- is the first thing a reader repairing it needs.
      let fpLines := if e.expectedFp.isEmpty || e.expectedFp == e.currentFp then ""
        else s!"\n\n  expected fingerprint:\n    {e.expectedFp}\n\n  current fingerprint:\n    {e.currentFp}"
      s!"-- proof stale {String.ofList (List.replicate 44 '-')} {locStr}\n\n  `{e.qualName}`: the linked theorem is about a different body.{snippet}\n\n  spec: {e.specBinding}{fpLines}{originLine}\n\n  hint: Link the theorem whose specification is this body, or restore the body the theorem is about."
    else
    s!"-- proof stale {String.ofList (List.replicate 44 '-')} {locStr}\n\n  Function `{e.qualName}` has a registered proof, but the body changed.{snippet}\n\n  expected fingerprint:\n    {e.expectedFp}\n\n  current fingerprint:\n    {e.currentFp}{originLine}\n\n  hint: Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
  | .unbound =>
    -- Carry the drift line here too. `unbound` supersedes the status a drifted
    -- spec would otherwise produce, so without this the spec-drift signal would
    -- vanish from the report for exactly the links that are least verified.
    let specLine := if e.specBinding.isEmpty then "" else s!"\n\n  spec: {e.specBinding}"
    -- Coverage and origin are still KNOWN facts about the link — what is unknown
    -- is its freshness. Dropping them (as the first version of this block did)
    -- traded away information the proved block shows, for no reason: snapshot
    -- review caught 12 links silently losing both.
    let coverageTag := if e.coverage.isEmpty then "" else s!"\n\n  coverage: {e.coverage}"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    s!"-- proof link unbound {String.ofList (List.replicate 37 '-')} {locStr}\n\n  proof link unbound: no stored proof-subject digest for `{e.qualName}`.{snippet}\n\n  current fingerprint:\n    {e.currentFp}\n\n  Not proved, and not stale: the body has not been shown to change, it has\n  never been pinned. With no stored subject the freshness check would compare\n  this body against itself.{coverageTag}{originLine}{specLine}\n\n  hint: Re-verify the proof against the current body, then record the result as #[proof_fingerprint(\"...\")]."
  | .needsRecheck =>
    -- Says what the stored value CANNOT decide, rather than asserting a change.
    -- The v1 digest hashed Core statements; v2 covers identity, typed signature,
    -- generics, capabilities and contracts. A v1 value answers a strictly weaker
    -- question, so no comparison against it establishes v2 freshness — and
    -- rendering that as "the body changed" would invent a fact.
    let specLine := if e.specBinding.isEmpty then "" else s!"\n\n  spec: {e.specBinding}"
    let coverageTag := if e.coverage.isEmpty then "" else s!"\n\n  coverage: {e.coverage}"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    s!"-- proof needs re-check {String.ofList (List.replicate 36 '-')} {locStr}\n\n  `{e.qualName}` has a stored proof-subject digest from an EARLIER SCHEMA.{snippet}\n\n  current subject digest:\n    {e.currentFp}\n\n  Not proved, and not stale. The stored value is a v1 (body-only) digest: it\n  covers no signature, capability or contract, so it cannot answer whether the\n  v2 subject is unchanged. The format changed; the program may not have.{coverageTag}{originLine}{specLine}\n\n  hint: Re-verify against the current subject and record the new v2 value as #[proof_fingerprint(\"v2:...\")]."
  | .depsNotCurrent =>
    -- Name the dependencies. "A dependency is not current" without saying which
    -- is unactionable, and the defining feature of this status is that the fix is
    -- in another function.
    let depLines := String.intercalate "\n" (e.notCurrentDeps.map fun d => s!"    - {d}")
    let coverageTag := if e.coverage.isEmpty then "" else s!"\n\n  coverage: {e.coverage}"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    s!"-- dependency not current {String.ofList (List.replicate 34 '-')} {locStr}\n\n  `{e.qualName}` cannot contribute proved evidence: it reaches a dependency that is not current.{snippet}\n\n  not current:\n{depLines}\n\n  This function's own subject is FRESH — the problem is downstream. Make the\n  listed dependencies current and this claim recovers on its own.{coverageTag}{originLine}\n\n  hint: Re-verify and update those fingerprints, attach their missing proofs, or mark a boundary trusted."
  | .specUnbound =>
    let coverageTag := if e.coverage.isEmpty then "" else s!"\n\n  coverage: {e.coverage}"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    s!"-- spec not bound to body {String.ofList (List.replicate 33 '-')} {locStr}\n\n  `{e.qualName}` is not shown to be what its theorem is about.{snippet}\n\n  spec: {e.specBinding}\n\n  A theorem is about the specification VALUES its statement evaluates. A current\n  fingerprint says the body did not change since it was linked; it does not say\n  the linked theorem is about this body.{coverageTag}{originLine}\n\n  hint: Link a theorem whose specification is this body, name in #[spec] the specification it evaluates, or declare that specification's parameters with a PFnDef whose body it is."
  | .correspondenceUnjustified =>
    -- NAME THE EDGES, for the same reason `depsNotCurrent` names the dependencies: "the closure is
    -- unjustified" without saying which edge is unactionable, and the fix is in the EVIDENCE rather
    -- than in this body or in a callee.
    let edgeLines := String.intercalate "\n" (e.notCurrentDeps.map fun d => s!"    - {d}")
    let coverageTag := if e.coverage.isEmpty then "" else s!"\n\n  coverage: {e.coverage}"
    let originLine := if e.origin.isEmpty then "" else s!"\n\n  origin: {e.origin}"
    s!"-- dependency closure unjustified {String.ofList (List.replicate 26 '-')} {locStr}\n\n  `{e.qualName}` cannot contribute proved evidence: its dependency closure has no validated per-edge justification.{snippet}\n\n  unjustified:\n{edgeLines}\n\n  This function's own subject is FRESH and its dependencies ARE current. What is\n  missing is the justification: every edge must be witnessed by exactly one entry\n  naming that exact implementation — package, module, declaration and body — in a\n  table the linked theorem names.{coverageTag}{originLine}\n\n  hint: Attest the table's entries, or repair a proof link naming a table that describes a different program's function."
  | .notProved =>
    s!"-- no proof {String.ofList (List.replicate 47 '-')} {locStr}\n\n  `{e.qualName}`\n  obligation: extractable\n  registered proof: none{snippet}\n\n  current fingerprint:\n    {e.currentFp}\n\n  hint: Add a Lean proof for this function in Concrete/Proof.lean with the fingerprint above."
  | .blocked =>
    let unsupStr := if e.unsupported.isEmpty then "unsupported constructs"
        else ", ".intercalate e.unsupported
    s!"-- blocked {String.ofList (List.replicate 48 '-')} {locStr}\n\n  obligation: NOT extractable — `{e.qualName}` uses unsupported constructs.{snippet}\n\n  unsupported: {unsupStr}\n\n  hint: Remove {unsupStr} to enable proof extraction."
  | .notEligible =>
    let gateStr := ", ".intercalate e.eligibilityReasons
    s!"-- not eligible {String.ofList (List.replicate 43 '-')} {locStr}\n\n  `{e.qualName}` cannot be proved: fails the proof-eligibility gates ({gateStr}).{snippet}\n\n  reasons: {gateStr}\n\n  hint: Address these constraints to make this function eligible for proof."
  | .trusted =>
    s!"-- trusted {String.ofList (List.replicate 48 '-')} {locStr}\n\n  `{e.qualName}` is marked trusted — proof is bypassed (trusted assumption).{snippet}"

/-- The admission line for a report block, or "" when admitted.

    Rendered for EVERY state, because admission is orthogonal to `state`: a claim can
    replay cleanly and still be refused admission, and that pair is the whole point of
    the separation. Printing it only under `not eligible` would hide exactly the case it
    exists to express. -/
private def admissionLine (e : ProofStatusEntry) : String :=
  if e.admissible then ""
  -- A function that is not extractable, or is trusted, is not admitted either, and its state
  -- line already says why. Repeating it as an admission refusal with no reason of its own
  -- would present the same fact twice, the second time as unexplained.
  else if e.admissionReasons.isEmpty && (match e.state with | .notEligible | .trusted => true | _ => false) then ""
  else
    let why := if e.admissionReasons.isEmpty then "no reason recorded"
               else ", ".intercalate e.admissionReasons
    -- The consequence differs by whether an artifact EXISTS. Telling a reader that "the
    -- artifact stays replayable" when none was ever registered asserts something that is
    -- not there, which is the defect class this area exists to prevent.
    let consequence :=
      if e.proofSource == "none" && e.proofName.isEmpty then
        "no registered artifact to replay; future evidence cannot count until admission succeeds"
      else
        "artifact remains replayable and drift-monitored but does not count as admitted proof"
    s!"\n\n  admission: REFUSED — {why}\n  ({consequence})"

/-- One rendered block: the state-specific body, plus the admission fact.

    APPENDED ONCE HERE rather than inside each arm of `renderProofStatusBody`. Appending
    per-arm was the first attempt and it silently skipped `proved` — the one state where
    an unreported refusal does real damage, because that block reads as a program-level
    guarantee. -/
private def renderProofStatusEntry (e : ProofStatusEntry) (sourceMap : SourceMap) : String :=
  renderProofStatusBody e sourceMap ++ admissionLine e

/-- The raw per-function proof-link freshness entries (Phase 3 #11): the same
    records `proofStatusReport` renders, exposed so the ObligationCore ledger can
    project proof links / fingerprint drift / missing / blocked / ineligible /
    trusted facts into the one ledger instead of a separate proof-status model. -/
def proofStatusEntries (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) (pc : Concrete.ProofCore) : List ProofStatusEntry :=
  modules.foldl (fun acc m => acc ++ collectProofStatus pc locMap m "" registry) []

/-- Proof status report with Elm-clear diagnostics. -/
def proofStatusReport (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let header := "=== Proof Status Report ==="
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  -- THE BOUNDARY LINE IS APPENDED FOR EVERY STATUS, once, here. The `proved` branch already
  -- includes it inline (beside its own trust line, where a reader expects it); every other status
  -- gets it from this append, so a `stale` or `unbound` claim resting on an unproved boundary
  -- discloses that fact instead of waiting until it turns green.
  let body := entries.map fun e =>
    let rendered := renderProofStatusEntry e sourceMap
    if e.state matches .proved then rendered
    else rendered ++ trustedBoundaryLine e
  -- Summary
  let proved := (entries.filter fun e => e.state matches .proved).length
  let stale := (entries.filter fun e => e.state matches .stale).length
  let unboundCnt := (entries.filter fun e => e.state matches .unbound).length
  let notProved := (entries.filter fun e => e.state matches .notProved).length
  let blockedCnt := (entries.filter fun e => e.state matches .blocked).length
  let notEligible := (entries.filter fun e => e.state matches .notEligible).length
  let trusted := (entries.filter fun e => e.state matches .trusted).length
  -- Every status must appear here. `depsNotCurrent` was missing at first and the
  -- line silently added up to 4 of 5 functions — a totals row that does not
  -- total is worse than no row, because it reads as a complete census.
  let depsNC := (entries.filter fun e =>
    match e.state with | .depsNotCurrent => true | _ => false).length
  -- ...and `correspondenceUnjustified` was missing in exactly the same way, one status later: the
  -- eight-function elf_header report added up to seven. The comment above was already the warning.
  let unjust := (entries.filter fun e =>
    match e.state with | .correspondenceUnjustified => true | _ => false).length
  let needsRe := (entries.filter fun e =>
    match e.state with | .needsRecheck => true | _ => false).length
  -- And `specUnbound` (bug 079), added with this line in mind.
  let specUnb := (entries.filter fun e =>
    match e.state with | .specUnbound => true | _ => false).length
  let summary := s!"Totals: {entries.length} functions — {proved} proved, {stale} stale, {unboundCnt} unbound, {needsRe} needs-recheck, {depsNC} dependency-not-current, {unjust} closure-unjustified, {specUnb} spec-unbound, {notProved} unproved, {blockedCnt} blocked, {notEligible} ineligible, {trusted} trusted"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

/-- Program-level conformance check against `docs/verification/PROVABLE_V1.md`.
    Classifies each function as:
    - in:        proof-eligible AND extraction succeeds (fits ProvableV1)
    - blocked:   proof-eligible BUT extraction failed on unsupported constructs
                 (the only case that counts against conformance)
    - excluded:  ineligible or trusted — outside ProvableV1 by profile design,
                 not counted against conformance
    Status is `full` iff there are no blocked functions. -/
def provableV1ConformanceReport (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) (pc : Concrete.ProofCore) : String :=
  let header := "=== ProvableV1 Conformance ==="
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  let inEntries := entries.filter fun e =>
    e.state matches .proved || e.state matches .stale ||
    e.state matches .notProved
  let blockedEntries := entries.filter fun e => e.state matches .blocked
  let excludedEntries := entries.filter fun e =>
    e.state matches .notEligible || e.state matches .trusted
  let conformance := if blockedEntries.isEmpty then "full" else "partial"
  let inLines := inEntries.map fun e => s!"  in        `{e.qualName}`"
  let blockedLines := blockedEntries.map fun e =>
    let reason := if e.unsupported.isEmpty then "blocked"
                  else ", ".intercalate e.unsupported
    s!"  blocked   `{e.qualName}` — {reason}"
  let excludedLines := excludedEntries.map fun e =>
    let reason :=
      if e.state matches .trusted then "trusted"
      else if e.eligibilityReasons.isEmpty then "by profile"
      else ", ".intercalate e.eligibilityReasons
    s!"  excluded  `{e.qualName}` — by design ({reason})"
  let chunks :=
    (if inLines.isEmpty then []
     else [s!"Inside ProvableV1 ({inEntries.length}):"] ++ inLines) ++
    (if blockedLines.isEmpty then []
     else [""] ++ [s!"Outside ProvableV1 — construct violations ({blockedEntries.length}):"]
            ++ blockedLines) ++
    (if excludedLines.isEmpty then []
     else [""] ++ [s!"Outside ProvableV1 — by profile design ({excludedEntries.length}):"]
            ++ excludedLines)
  let footer :=
    if blockedEntries.isEmpty then
      "Every proof-eligible function fits the ProvableV1 supported surface.\nExcluded functions are excluded by the profile itself (entry points,\ntrusted functions and methods, capability use), not counted against conformance."
    else
      s!"{blockedEntries.length} function(s) are proof-eligible but use constructs\noutside the current ProvableV1 supported surface (see docs/verification/PROVABLE_V1.md)."
  s!"{header}\n\n{"\n".intercalate chunks}\n\nStatus: {conformance}\n{footer}\n"

/-- Compact one-line proof summary suitable for build output. -/
def proofSummaryLine (pc : Concrete.ProofCore) : String :=
  let obls := pc.obligations
  let proved := (obls.filter fun o => o.status == .proved).length
  let stale := (obls.filter fun o => o.status == .stale).length
  let missing := (obls.filter fun o => o.status == .missing).length
  let blocked := (obls.filter fun o => o.status == .blocked).length
  let ineligible := (obls.filter fun o => o.status == .ineligible).length
  let trusted := (obls.filter fun o => o.status == .trusted).length
  -- EVERY NON-PROVED ELIGIBLE STATUS COUNTS TOWARD THE DENOMINATOR. `eligible` was
  -- `proved + stale + missing + blocked`, so a downgraded claim left the denominator entirely and
  -- the line read `4/4 proved` for a package holding an unjustified closure — a build summary
  -- reporting completeness it did not have.
  let unbound := (obls.filter fun o => o.status == .unbound).length
  let needsRecheck := (obls.filter fun o => o.status == .needsRecheck).length
  let depsNC := (obls.filter fun o => o.status == .depsNotCurrent).length
  let unjust := (obls.filter fun o => o.status == .correspondenceUnjustified).length
  let eligible := proved + stale + missing + blocked + unbound + needsRecheck + depsNC + unjust
  if eligible == 0 && ineligible == 0 && trusted == 0 then
    "Proofs: no eligible functions"
  else if eligible == 0 then
    s!"Proofs: no eligible functions ({ineligible} ineligible, {trusted} trusted)"
  else if proved == eligible then
    s!"Proofs: {proved}/{eligible} proved"
  else
    let parts : List String :=
      (if proved != 0 then [s!"{proved} proved"] else []) ++
      (if stale != 0 then [s!"{stale} stale"] else []) ++
      (if missing != 0 then [s!"{missing} missing"] else []) ++
      (if blocked != 0 then [s!"{blocked} blocked"] else []) ++
      (if unbound != 0 then [s!"{unbound} unbound"] else []) ++
      (if needsRecheck != 0 then [s!"{needsRecheck} needs-recheck"] else []) ++
      (if depsNC != 0 then [s!"{depsNC} dependency-not-current"] else []) ++
      (if unjust != 0 then [s!"{unjust} closure-unjustified"] else [])
    s!"Proofs: {", ".intercalate parts}"

/-- Actionable "next steps" for the proof workflow — at most 3 items,
    prioritized: stale first, then missing, then blocked. -/
def proofNextSteps (pc : Concrete.ProofCore) : String :=
  let stales := pc.obligations.filter fun o => o.status == .stale
  let missing := pc.obligations.filter fun o => o.status == .missing
  let staleItems := stales.map fun o =>
    s!"  - fix stale proof for {o.functionId.qualName} (body changed, update fingerprint)"
  let missingItems := missing.map fun o =>
    s!"  - add proof for {o.functionId.qualName} (eligible, extractable, no registry entry)"
  let blockedItems := (pc.entries.filter fun e => e.extracted.isNone && !e.unsupported.isEmpty).map fun e =>
    s!"  - unblock {e.qualName} (uses {", ".intercalate e.unsupported})"
  let allItems := staleItems ++ missingItems ++ blockedItems
  if allItems.isEmpty then ""
  else
    let shown := allItems.take 3
    let more := if allItems.length != shown.length
        then s!"\n  ... and {allItems.length - shown.length} more"
        else ""
    s!"Next steps:\n{"\n".intercalate shown}{more}"

-- ============================================================
-- Proof obligations report (--report obligations)
-- ============================================================

/-- A single proof obligation entry (presentation layer). -/
structure ObligationEntry where
  function     : String       -- qualified name
  spec         : String       -- spec name (from registry, or empty)
  proof        : String       -- proof name (from registry/hardcoded, or empty)
  status       : String       -- proved | stale | missing | blocked | ineligible | trusted
  dependencies : List String  -- qualified names of proved helpers this function calls
  notCurrentDeps    : List String  -- proved callees whose proof has gone stale
  fingerprint  : String       -- current body fingerprint
  source       : String       -- "registry" | "hardcoded" | "none"
  loc          : Option SourceLoc

/-- Convert a ProofCore obligation to a Report-side ObligationEntry. -/
def obligationToEntry (o : Concrete.Obligation) : ObligationEntry :=
  let statusStr := o.status.canonical
  let (sName, pName, src) := match o.spec with
    | some a => (a.specId.name, a.proofName,
        match a.source with | .registry => "registry" | .hardcoded => "hardcoded")
    | none => ("", "", "none")
  { function := o.functionId.qualName, spec := sName, proof := pName
  , status := statusStr, dependencies := o.dependencies, notCurrentDeps := o.notCurrentDeps
  , fingerprint := o.functionId.fingerprint, source := src, loc := o.loc }

/-- Render the obligations report as human-readable output. -/
def obligationsReport (_modules : List CModule) (_locMap : FnLocMap := [])
    (_registry : ProofRegistry := []) (pc : Concrete.ProofCore) : String :=
  let entries := pc.obligations.map obligationToEntry
  let header := "=== Proof Obligations ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let depsStr := if e.dependencies.isEmpty then "none"
      else ", ".intercalate e.dependencies
    let notCurrentDepsStr := if e.notCurrentDeps.isEmpty then ""
      -- "not current", not "stale": since slice 3 this list is the reachable
      -- closure of anything that blocks proved evidence, and most entries are
      -- `missing` rather than stale. The old label described a subset.
      else s!"\n    not current:  {", ".intercalate e.notCurrentDeps}"
    let specStr := if e.spec.isEmpty then "(none)" else e.spec
    let proofStr := if e.proof.isEmpty then "(none)" else e.proof
    s!"  {e.function}\n    status:       {e.status}\n    spec:         {specStr}\n    proof:        {proofStr}\n    source:       {e.source}\n    fingerprint:  {e.fingerprint}\n    dependencies: {depsStr}{notCurrentDepsStr}\n    loc:          {locStr}"
  let proved := (entries.filter fun e => e.status == "proved").length
  let stale := (entries.filter fun e => e.status == "stale").length
  let missing := (entries.filter fun e => e.status == "missing").length
  let blockedCnt := (entries.filter fun e => e.status == "blocked").length
  let inelig := (entries.filter fun e => e.status == "ineligible").length
  let trusted := (entries.filter fun e => e.status == "trusted").length
  let summary := s!"Totals: {entries.length} obligations — {proved} proved, {stale} stale, {missing} missing, {blockedCnt} blocked, {inelig} ineligible, {trusted} trusted"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Proof dependency graph report (--report proof-deps)
-- ============================================================

/-- Render the proof dependency graph as a human-readable report.
    Shows proved functions and their proved/stale helper dependencies. -/
def proofDepsReport (pc : Concrete.ProofCore) : String :=
  let header := "=== Proof Dependency Graph ==="
  -- Show only obligations that have dependencies or stale deps
  let withDeps := pc.obligations.filter fun o =>
    !o.dependencies.isEmpty || !o.notCurrentDeps.isEmpty
  let noDeps := pc.obligations.filter fun o =>
    o.status == .proved && o.dependencies.isEmpty && o.notCurrentDeps.isEmpty
  let body := withDeps.map fun o =>
    let statusTag := o.status.canonical
    -- Label each edge with the callee's FINAL status. Hardcoding "(proved)" here
    -- misreported a callee that slice 3 had just downgraded: `verify_message`
    -- listed `verify_tag (proved)` while verify_tag itself read
    -- `deps_not_current`. The status is a fact about the callee, so read it from
    -- the callee rather than restating it at the edge.
    let labelOf : String → String := fun d =>
      match pc.obligations.find? (fun x => x.functionId.qualName == d) with
      | some c => c.status.canonical
      | none   => "unknown"
    let depLines := o.dependencies.map fun d => s!"    → {d} ({labelOf d})"
    let staleLines := o.notCurrentDeps.map fun d => s!"    → {d} ({labelOf d})"
    -- notCurrentDeps is the CLOSURE, so a direct callee can appear in both lists.
    let allLines := (depLines ++ staleLines).eraseDups
    s!"  {o.functionId.qualName} [{statusTag}]\n{"\n".intercalate allLines}"
  let isolatedNames := noDeps.map fun o => s!"  {o.functionId.qualName} [proved, no dependencies]"
  let provedCount := (pc.obligations.filter fun o => o.status == .proved).length
  let withStaleCount := (withDeps.filter fun o => !o.notCurrentDeps.isEmpty).length
  let containedCount := (pc.obligations.filter fun o => o.status == .depsNotCurrent).length
  let summary := s!"Summary: {provedCount} proved functions, {withDeps.length} with dependencies, {withStaleCount} reaching a non-current dependency, {containedCount} contained by one"
  let sections := if body.isEmpty && isolatedNames.isEmpty then ["  (no proof dependencies)"]
    else body ++ (if isolatedNames.isEmpty then [] else [""] ++ isolatedNames)
  s!"{header}\n\n{"\n\n".intercalate sections}\n\n{summary}\n"

-- ============================================================
-- Proof diagnostics report (--report proof-diagnostics)
-- ============================================================

/-- Render a proof diagnostic kind as a short label. -/
def diagnosticKindLabel : Concrete.ProofDiagnosticKind → String
  | .staleProof => "stale_proof"
  | .missingProof => "missing_proof"
  | .ineligible => "ineligible"
  | .unsupportedConstruct => "unsupported_construct"
  | .trusted => "trusted"
  | .attachmentIntegrity => "attachment_integrity"
  | .theoremLookup => "theorem_lookup"
  | .leanCheckFailure => "lean_check_failure"
  | .unboundProofLink => "unbound_proof_link"
  | .dependencyNotCurrent => "dependency_not_current"
  | .dependencyClosureUnjustified => "dependency_closure_unjustified"
  | .specNotBound => "spec_not_bound"

/-- Render a proof diagnostic severity as a string. -/
def diagnosticSeverityLabel : Concrete.ProofDiagnosticSeverity → String
  | .error => "error"
  | .warning => "warning"
  | .info => "info"

/-- Render a single proof diagnostic in Elm-clear format. -/
private def renderProofDiagnostic (d : Concrete.ProofDiagnostic) : String :=
  let locStr := fmtLoc d.loc
  let sevStr := diagnosticSeverityLabel d.severity
  let kindStr := diagnosticKindLabel d.kind
  let header := s!"-- {kindStr} [{sevStr}] {String.ofList (List.replicate (40 - kindStr.length) '-')} {locStr}"
  let body := s!"  {d.message}"
  let classStr := s!"\n  failure:     {d.failureClass}\n  repair:      {d.repairClass}"
  let detailStr := if d.details.isEmpty then ""
    else s!"\n  details: {", ".intercalate d.details}"
  let fpStr := if d.fingerprint.isEmpty then ""
    else s!"\n  fingerprint: {d.fingerprint}"
  let expStr := if d.expectedFp.isEmpty then ""
    else s!"\n  expected:    {d.expectedFp}"
  let hintStr := if d.hint.isEmpty then ""
    else s!"\n  hint: {d.hint}"
  s!"{header}\n\n{body}{classStr}{detailStr}{fpStr}{expStr}{hintStr}"

/-- Human-readable proof diagnostics report. -/
def proofDiagnosticsReport (pc : Concrete.ProofCore) : String :=
  let header := "=== Proof Diagnostics ==="
  let diags := pc.diagnostics
  if diags.isEmpty then
    s!"{header}\n\nNo proof diagnostics.\n"
  else
    let body := diags.map renderProofDiagnostic
    let errors := (diags.filter fun d => d.severity == .error).length
    let warnings := (diags.filter fun d => d.severity == .warning).length
    let infos := (diags.filter fun d => d.severity == .info).length
    let summary := s!"Totals: {diags.length} diagnostics — {errors} errors, {warnings} warnings, {infos} info"
    s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- proofDiagnosticToFact and collectProofDiagnosticFacts are defined after locToJson

-- ============================================================
-- Source-to-ProofCore extraction report (--report extraction)
-- ============================================================

/-- Pretty-print a PExpr as a readable S-expression. -/
partial def renderPExpr : Proof.PExpr → String
  | .lit (.int n) => toString n
  | .lit (.bool b) => toString b
  | .lit (.struct_ name _) => s!"<struct {name}>"
  | .lit (.enum_ enumName variant _) => s!"<{enumName}::{variant}>"
  | .lit (.array_ elems) => s!"<array (size {elems.length})>"
  | .var name => name
  | .binOp op lhs rhs =>
    let opStr := match op with
      | .add => "+" | .sub => "-" | .mul => "*"
      | .addw _ _ => "+w"     -- wrapping add at width (mod 2^w)
      | .mod _ true => "%"    -- signed mod (i32 srem semantics)
      | .mod _ false => "%u"  -- unsigned mod (urem semantics)
      | .div _ true => "/"    -- signed div (i32 sdiv semantics)
      | .div _ false => "/u"  -- unsigned div (udiv semantics)
      | .bitxor _ true => "^"
      | .bitxor _ false => "^u"
      | .bitor _ true => "|"
      | .bitor _ false => "|u"
      | .bitand _ true => "&"
      | .bitand _ false => "&u"
      | .shr _ _ => ">>"
      | .shl _ _ => "<<"
      | .addsat _ _ => "+sat"
      | .subsat _ _ => "-sat"
      | .eq => "==" | .ne => "!=" | .lt => "<"
      | .le => "<=" | .gt => ">" | .ge => ">="
    s!"({renderPExpr lhs} {opStr} {renderPExpr rhs})"
  | .letIn name val body =>
    s!"let {name} = {renderPExpr val}; {renderPExpr body}"
  | .ifThenElse cond t e =>
    s!"if {renderPExpr cond} then {renderPExpr t} else {renderPExpr e}"
  | .call fn args =>
    let argsStr := ", ".intercalate (args.map renderPExpr)
    s!"{fn}({argsStr})"
  -- Rendered distinctly from `.call`: a report that spelled a parameter
  -- application the same way as a definition call would let a reader upgrade a
  -- representative-callback theorem to a universal one by eye. The `&` marks
  -- the callee as a bound value, not a name in the program.
  | .applyVar binding args =>
    let argsStr := ", ".intercalate (args.map renderPExpr)
    s!"&{binding}({argsStr})"
  | .structLit name fields =>
    let fieldsStr := ", ".intercalate (fields.map fun (fname, fexpr) =>
      s!"{fname}: {renderPExpr fexpr}")
    s!"{name} \{ {fieldsStr} }"
  | .enumLit enumName variant fields =>
    let fieldsStr := ", ".intercalate (fields.map fun (fname, fexpr) =>
      s!"{fname}: {renderPExpr fexpr}")
    if fields.isEmpty then s!"{enumName}::{variant}"
    else s!"{enumName}::{variant} \{ {fieldsStr} }"
  | .fieldAccess obj field =>
    s!"{renderPExpr obj}.{field}"
  | .arrayIndex arr idx =>
    s!"{renderPExpr arr}[{renderPExpr idx}]"
  | .match_ scrutinee arms =>
    let armStrs := arms.map fun (pat, body) =>
      let patStr := match pat with
        | .enumPat eName variant [] => s!"{eName}::{variant}"
        | .enumPat eName variant bindings =>
          s!"{eName}::{variant} \{ {", ".intercalate bindings} }"
        | .litPat (.int n) => toString n
        | .litPat (.bool b) => toString b
        | .litPat _ => "<lit>"
        | .varPat name => name
      s!"{patStr} => {renderPExpr body}"
    s!"match {renderPExpr scrutinee} \{ {"; ".intercalate armStrs} }"
  | .cast inner => s!"({renderPExpr inner} as _)"
  | .wrapCast w sg inner => s!"({renderPExpr inner} as {if sg then "i" else "u"}{w})"
  | .arrayLit elems => s!"[{", ".intercalate (elems.map renderPExpr)}]"
  | .arraySet arr idx val =>
    s!"{renderPExpr arr}.set({renderPExpr idx}, {renderPExpr val})"
  | .while_ cond assigns cont =>
    let assignStrs := assigns.map fun (n, e) => s!"{n} = {renderPExpr e}"
    s!"while {renderPExpr cond} \{ {"; ".intercalate assignStrs} }; {renderPExpr cont}"
  | .while_step cond carried step cont =>
    s!"while_step {renderPExpr cond} carried=[{", ".intercalate carried}] \{ {renderPExpr step} }; {renderPExpr cont}"

/-- Extraction entry for one function. -/
structure ExtractionEntry where
  qualName    : String
  /-- Semantic identity, CARRIED from ProofCore where it was minted from resolved
      compiler facts. The generator reads this; it does not split `qualName`.
      Optional only because excluded entries have no ProofCore identity yet. -/
  callableId  : Option CallableId := none
  eligible    : Bool
  extracted   : Option Proof.PExpr
  excluded    : List String  -- reasons if not eligible
  unsupported : List String  -- constructs that blocked extraction
  fingerprint : String
  params      : List String
  specName    : String       -- spec name (from registry or derived)
  proofName   : String       -- proof name (from registry or derived)
  loc         : Option SourceLoc

/-- Extract spec/proof names from a SpecAttachment, or empty strings if none. -/
private def specNames (att : Option SpecAttachment) : String × String :=
  match att with
  | some a => (a.specId.name, a.proofName)
  | none => ("", "")

/-- Build extraction entries from ProofCore — the single source of truth
    for eligibility, extraction, and fingerprinting. -/
def extractionEntriesFromPC (pc : Concrete.ProofCore)
    (_registry : ProofRegistry := []) : List ExtractionEntry :=
  let eligible := pc.entries.map fun e =>
    let (sName, pName) := specNames e.spec
    { qualName := e.qualName, callableId := some e.callableId
    , eligible := true, extracted := e.extracted
    , excluded := [], unsupported := e.unsupported, fingerprint := e.fingerprint
    , params := e.params, specName := sName, proofName := pName, loc := e.loc }
  let excludedEntries := pc.excluded.map fun e =>
    let (sName, pName) := specNames e.spec
    let reasons := e.eligibility.sourceReasons ++ e.eligibility.profileReasons
    { qualName := e.qualName, eligible := false, extracted := none
    , excluded := reasons, unsupported := [], fingerprint := e.fingerprint
    , params := e.fn.params.map (·.1), specName := sName, proofName := pName, loc := e.loc }
  eligible ++ excludedEntries

/-- Render the source-to-ProofCore extraction report. -/
def extractionReport (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let entries := extractionEntriesFromPC pc registry
  let header := "=== Source-to-ProofCore Extraction ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let statusStr := if e.eligible then
      match e.extracted with
      | some pexpr => s!"extracted\n    ProofCore: {renderPExpr pexpr}"
      | none => s!"eligible (extraction failed)\n    unsupported: {", ".intercalate e.unsupported}"
    else
      s!"excluded\n    reasons: {", ".intercalate e.excluded}"
    let paramStr := if e.params.isEmpty then "()" else "(" ++ ", ".intercalate e.params ++ ")"
    let specStr := if e.specName.isEmpty then "" else s!"\n    spec: {e.specName}"
    let proofStr := if e.proofName.isEmpty then "" else s!"\n    proof: {e.proofName}"
    s!"  {e.qualName}{paramStr}\n    status: {statusStr}{specStr}{proofStr}\n    fingerprint: {e.fingerprint}\n    loc: {locStr}"
  let extracted := (entries.filter fun e => e.eligible && e.extracted.isSome).length
  let eligFailed := (entries.filter fun e => e.eligible && e.extracted.isNone).length
  let excluded := (entries.filter fun e => !e.eligible).length
  let summary := s!"Totals: {entries.length} functions — {extracted} extracted, {eligFailed} eligible but not extractable, {excluded} excluded"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"


end Report
end Concrete
