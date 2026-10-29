import Concrete.Report.VCSchema

/-! Source/Core/SSA/LLVM traceability and the machine-readable facts (--report traceability, diagnostics-json). Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report

-- ============================================================
-- Source/Core/SSA/LLVM traceability (--report traceability)
-- ============================================================

/-- A traceability entry for one function through the pipeline. -/
structure TraceEntry where
  sourceFunction : String       -- qualified source name
  fingerprint    : String       -- body fingerprint at Core
  extractionStatus : String     -- extracted | eligible_not_extractable | excluded
  proofCoreForm  : String       -- readable PExpr if extracted, else ""
  evidenceLevel  : String       -- proved | enforced | reported | trusted-assumption
  specName       : String       -- spec name (from registry or derived)
  proofName      : String       -- proof name (from registry or derived)
  coreNames      : List String  -- Core function names (pre-mono)
  monoNames      : List String  -- monomorphized specialization names
  ssaNames       : List String  -- SSA function names
  llvmNames      : List String  -- LLVM symbol names
  claimBoundary  : String       -- where the claim stops being guaranteed
  loc            : Option SourceLoc

/-- Collect all function names from SSA modules. -/
private partial def collectSSANames (sm : SModule) (pfx : String := "") : List (String × String) :=
  let modPfx := if pfx.isEmpty then sm.name else pfx ++ "." ++ sm.name
  let fns := sm.functions.map fun f => (f.name, modPfx)
  fns

/-- Collect all function names from monomorphized Core modules. -/
private partial def collectMonoFnNames (m : CModule) (pfx : String := "") : List String :=
  let modPfx := if pfx.isEmpty then m.name else pfx ++ "." ++ m.name
  let fns := m.functions.map fun f => modPfx ++ "." ++ f.name
  fns ++ m.submodules.foldl (fun acc sub => acc ++ collectMonoFnNames sub modPfx) []

/-- The link symbol the backend emits a function under (FFI.md "Symbol Names"): its
    `#[export_name]`, else the mangled `_C.<module path>.<name>` — the entry `main` included. -/
private def llvmSymbol (f : SFnDef) (moduleName : String) : String :=
  match f.exportName with
  | some e => e
  | none => Symbols.concreteFn (if f.modulePath.isEmpty then moduleName else f.modulePath) f.name

/-- Determine the claim boundary for a function. -/
private def claimBoundaryFor (evidence : String) (extracted : Bool) : String :=
  match evidence with
  | "proved" =>
    if extracted then "ProofCore (source-level proof, not preserved past Core)"
    else "source (proof not extractable to ProofCore)"
  | "enforced" => "source (passes predictable profile, no proof)"
  | "trusted-assumption" => "source (trusted, no verification)"
  | "reported" => "source (fails predictable profile)"
  | _ => "source"

/-- Build traceability entries by walking Core functions and looking up
    their counterparts in mono/SSA stages. -/
private def collectTraceEntries
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : List TraceEntry :=
  -- Build extraction entries from ProofCore
  let extractionEntries := extractionEntriesFromPC pc registry
  -- Build proof status entries
  let proofEntries := coreModules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  -- Collect mono names
  let allMonoNames := monoModules.foldl (fun acc m => acc ++ collectMonoFnNames m) []
  -- Collect SSA names
  let allSSAFns := ssaModules.foldl (fun acc sm =>
    acc ++ sm.functions.map fun f => (f.name, llvmSymbol f sm.name)) []
  -- Build entries
  extractionEntries.map fun ext =>
    let bareName := match ext.qualName.splitOn "." with
      | parts => parts.getLast!
    -- Find proof status
    let proofEntry := proofEntries.find? fun e => e.qualName == ext.qualName
    let evidence := match proofEntry with
      | some e => match e.state with
        | .proved => "proved"
        | .stale => "stale"
        | .unbound => "unbound"
        | .needsRecheck => "needs_recheck"
        -- Not "proved": that is the entire point of the status. Traceability
        -- must not launder a contained claim into evidence.
        | .depsNotCurrent => "deps_not_current"
        -- Not "proved" either, and for a strictly stronger reason: the closure's justification was
        -- never established, so traceability must not present it as evidence.
        | .correspondenceUnjustified => "correspondence_unjustified"
        -- Nor a claim never shown to be about this body (bug 079).
        | .specUnbound => "spec_unbound"
        | .notProved => "enforced"
        | .blocked => "blocked"
        | .notEligible => "reported"
        | .trusted => "trusted-assumption"
      | none => "missing"
    let extStatus := if ext.eligible then
      (if ext.extracted.isSome then "extracted" else "eligible_not_extractable")
    else "excluded"
    let pcForm := match ext.extracted with
      | some pexpr => renderPExpr pexpr
      | none => ""
    -- Mono names: find specializations that start with the bare name
    let specPrefix := bareName ++ "_for_"
    let matchesMono (mn : String) : Bool :=
      if mn.endsWith ("." ++ bareName) then true
      else
        let parts := mn.splitOn specPrefix
        parts.length != 1
    let monoMatches := allMonoNames.filter matchesMono
    -- SSA names: find matching functions
    let ssaMatches := allSSAFns.filter fun (sn, _) =>
      sn == bareName || sn.startsWith (bareName ++ "_for_")
    let ssaNames := ssaMatches.map (·.1)
    let llvmNames := ssaMatches.map (·.2)
    let boundary := claimBoundaryFor evidence ext.extracted.isSome
    { sourceFunction := ext.qualName
    , fingerprint := ext.fingerprint
    , extractionStatus := extStatus
    , proofCoreForm := pcForm
    , evidenceLevel := evidence
    , coreNames := [ext.qualName]
    , monoNames := monoMatches
    , ssaNames := ssaNames
    , llvmNames := llvmNames
    , specName := ext.specName
    , proofName := ext.proofName
    , claimBoundary := boundary
    , loc := ext.loc }

/-- Render the traceability report. -/
def traceabilityReport
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let entries := collectTraceEntries coreModules monoModules ssaModules locMap registry pc
  let header := "=== Source/Core/SSA/LLVM Traceability ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let monoStr := if e.monoNames.isEmpty then "(not monomorphized)"
      else ", ".intercalate e.monoNames
    let ssaStr := if e.ssaNames.isEmpty then "(not lowered)"
      else ", ".intercalate e.ssaNames
    let llvmStr := if e.llvmNames.isEmpty then "(not emitted)"
      else ", ".intercalate e.llvmNames
    let pcStr := if e.proofCoreForm.isEmpty then ""
      else s!"\n    proof_core:   {e.proofCoreForm}"
    let specStr := if e.specName.isEmpty then "" else s!"\n    spec:         {e.specName}"
    let proofStr := if e.proofName.isEmpty then "" else s!"\n    proof:        {e.proofName}"
    s!"  {e.sourceFunction}\n    evidence:     {e.evidenceLevel}\n    extraction:   {e.extractionStatus}{pcStr}{specStr}{proofStr}\n    core:         {", ".intercalate e.coreNames}\n    mono:         {monoStr}\n    ssa:          {ssaStr}\n    llvm:         {llvmStr}\n    boundary:     {e.claimBoundary}\n    fingerprint:  {e.fingerprint}\n    loc:          {locStr}"
  let evidenceCounts := entries.foldl (fun acc e =>
    match e.evidenceLevel with
    | "proved" => { acc with fst := acc.fst + 1 }
    | "enforced" => { acc with snd := { acc.snd with fst := acc.snd.fst + 1 } }
    | "reported" => { acc with snd := { acc.snd with snd := { acc.snd.snd with fst := acc.snd.snd.fst + 1 } } }
    | _ => { acc with snd := { acc.snd with snd := { acc.snd.snd with snd := acc.snd.snd.snd + 1 } } }
    ) (0, (0, (0, 0)))
  let (proved, (enforced, (reported, other))) := evidenceCounts
  let summary := s!"Totals: {entries.length} functions — {proved} proved, {enforced} enforced, {reported} reported, {other} other"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Machine-readable facts (--report diagnostics-json)
-- ============================================================
-- Structured diagnostic records for predictable violations and
-- proof-status entries. JSON output, no external dependencies.


/-- Schema version for the machine-readable JSON API — the single definition in `Json.lean`.
    Bump this when adding required fields or removing fields.
    Adding optional fields is backwards-compatible and does not bump the version. -/
def schemaVersion : Nat := apiSchemaVersion

/-- Known fact kinds that the compiler produces. -/
def knownFactKinds : List String :=
  ["proof_diagnostic", "predictable_violation", "proof_status", "eligibility",
   "obligation", "extraction", "traceability", "effects", "capability", "unsafe", "alloc",
   "contract"]

/-- Known semantic query prefixes. -/
def knownQueryKinds : List String :=
  ["predictable", "proof", "evidence", "audit", "fn", "why-capability", "traceability"]

open Json in
/-- Wrap a list of facts in a versioned envelope. -/
def factsEnvelope (facts : List Val) : Val :=
  .obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("schema_kind", .str "facts"),
    ("fact_kinds", .arr (knownFactKinds.map .str)),
    ("fact_count", .num (Int.ofNat facts.length)),
    ("facts", .arr facts)
  ]

open Json in
/-- Convert a SourceLoc to a JSON object. -/
def locToJson : Option SourceLoc → Val
  | some (file, line) => .obj [("file", .str file), ("line", .num line)]
  | none => .null

open Json in
/-- Convert a proof diagnostic to a JSON fact. -/
private def proofDiagnosticToFact (d : Concrete.ProofDiagnostic) : Val :=
  .obj ([
    ("kind", .str "proof_diagnostic"),
    ("code", .str d.kind.code),
    ("diagnostic_kind", .str (diagnosticKindLabel d.kind)),
    ("severity", .str (diagnosticSeverityLabel d.severity)),
    ("failure_class", .str d.failureClass),
    ("repair_class", .str d.repairClass),
    ("function", .str d.function),
    ("message", .str d.message),
    ("loc", locToJson d.loc)
  ] ++ (if d.hint.isEmpty then [] else [("hint", .str d.hint)])
    ++ (if d.details.isEmpty then [] else [("details", .arr (d.details.map .str))])
    ++ (if d.fingerprint.isEmpty then [] else [("fingerprint", .str d.fingerprint)])
    ++ (if d.expectedFp.isEmpty then [] else [("expected_fingerprint", .str d.expectedFp)]))

open Json in
/-- Collect proof diagnostic facts from ProofCore. -/
def collectProofDiagnosticFacts (pc : Concrete.ProofCore) : List Val :=
  pc.diagnostics.map proofDiagnosticToFact

open Json in
/-- Convert a ProfileViolation to a JSON fact. -/
private def violationToFact (v : ProfileViolation) : Val :=
  .obj [
    ("kind", .str "predictable_violation"),
    ("function", .str v.qualName),
    ("state", .str "failed"),
    ("reason", .str v.reason),
    ("hint", .str v.hint),
    ("loc", locToJson v.loc),
    ("violation_loc", locToJson v.violationLoc)
  ]

open Json in
/-- Convert a ProofStatusEntry to a JSON fact. -/
private def proofStatusToFact (e : ProofStatusEntry) : Val :=
  let stateStr := e.state.canonical
  let hintStr := match e.state with
    | .stale => "Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
    | .notProved => "Add a Lean proof for this function in Concrete/Proof.lean with the current fingerprint."
    | .blocked =>
      let unsupStr := if e.unsupported.isEmpty then "unsupported constructs"
          else ", ".intercalate e.unsupported
      s!"Remove {unsupStr} to enable proof extraction."
    | .notEligible => "Address these constraints to make this function eligible for proof."
    | _ => ""
  .obj ([
    ("kind", .str "proof_status"),
    ("function", .str e.qualName),
    ("state", .str stateStr),
    ("loc", locToJson e.loc),
    ("current_fingerprint", .str e.currentFp)
  ] ++ (if e.expectedFp.isEmpty then [] else [("expected_fingerprint", .str e.expectedFp)])
    ++ (if e.specName.isEmpty then [] else [("spec", .str e.specName)])
    ++ (if e.proofName.isEmpty then [] else [("proof", .str e.proofName)])
    ++ (if e.proofSource == "none" then [] else [("source", .str e.proofSource)])
    ++ (if e.eligibilityReasons.isEmpty then [] else [("profile_gates", .arr (e.eligibilityReasons.map .str))])
    ++ (if e.unsupported.isEmpty then [] else [("unsupported", .arr (e.unsupported.map .str))])
    ++ (if hintStr.isEmpty then [] else [("hint", .str hintStr)]))

open Json in
/-- Collect predictable violations as structured facts. -/
def collectPredictableFacts (modules : List CModule) (locMap : FnLocMap := [])
    (pc : Concrete.ProofCore) : List Val :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap recUncertain externNames locMap m) []
  violations.map violationToFact

open Json in
/-- Convert an eligibility entry to a JSON fact. -/
private def eligibilityToFact (e : EligibilityEntry) : Val :=
  let statusStr := if e.isTrusted then "trusted"
    else if e.eligible then "eligible"
    else "excluded"
  let exclusionStr := match e.exclusionKind with
    | some .source => "source"
    | some .profile => "profile"
    | some .both => "both"
    | none => "none"
  .obj ([
    ("kind", .str "eligibility"),
    ("function", .str e.qualName),
    ("status", .str statusStr),
    ("exclusion_kind", .str exclusionStr),
    ("source_reasons", .arr (e.sourceReasons.map .str)),
    ("profile_reasons", .arr (e.profileReasons.map .str)),
    -- ADMISSION is a separate judgment from eligibility (see `EligibilityEntry.admissible`):
    -- an eligible function can still be refused admission as effect-free.
    ("admissible", .bool e.admissible),
    ("admission_reasons", .arr (e.admissionReasons.map .str)),
    ("loc", locToJson e.loc)
  ])

open Json in
/-- Collect eligibility facts for all functions. -/
def collectEligibilityFacts (pc : Concrete.ProofCore) : List Val :=
  let entries := pc.allEligibility
  entries.map eligibilityToFact

open Json in
/-- Collect proof-status entries as structured facts. -/
def collectProofStatusFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) (pc : Concrete.ProofCore) : List Val :=
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  entries.map proofStatusToFact

open Json in
/-- Convert an obligation entry to a JSON fact. -/
private def obligationToFact (e : ObligationEntry) : Val :=
  .obj ([
    ("kind", .str "obligation"),
    ("function", .str e.function),
    ("status", .str e.status),
    ("spec", .str e.spec),
    ("proof", .str e.proof),
    ("source", .str e.source),
    ("fingerprint", .str e.fingerprint),
    ("dependencies", .arr (e.dependencies.map .str)),
    ("stale_deps", .arr (e.notCurrentDeps.map .str)),
    ("loc", locToJson e.loc)
  ])

open Json in
/-- Collect obligation facts for all functions. -/
def collectObligationFacts (_modules : List CModule) (_locMap : FnLocMap := [])
    (_registry : ProofRegistry := []) (pc : Concrete.ProofCore) : List Val :=
  let entries := pc.obligations.map obligationToEntry
  entries.map obligationToFact

open Json in
/-- Convert an extraction entry to a JSON fact. -/
private def extractionToFact (e : ExtractionEntry) : Val :=
  let statusStr := if e.eligible then
    match e.extracted with
    | some _ => "extracted"
    | none => "eligible_not_extractable"
  else "excluded"
  let proofCoreStr := match e.extracted with
    | some pexpr => renderPExpr pexpr
    | none => ""
  .obj ([
    ("kind", .str "extraction"),
    ("function", .str e.qualName),
    ("status", .str statusStr),
    ("eligible", .bool e.eligible),
    ("fingerprint", .str e.fingerprint),
    ("params", .arr (e.params.map .str)),
    ("loc", locToJson e.loc)
  ] ++ (if proofCoreStr.isEmpty then [] else [("proof_core", .str proofCoreStr)])
    ++ (if e.specName.isEmpty then [] else [("spec", .str e.specName)])
    ++ (if e.proofName.isEmpty then [] else [("proof", .str e.proofName)])
    ++ (if e.excluded.isEmpty then [] else [("excluded_reasons", .arr (e.excluded.map .str))])
    ++ (if e.unsupported.isEmpty then [] else [("unsupported", .arr (e.unsupported.map .str))]))

open Json in
/-- Collect extraction facts for all functions. -/
def collectExtractionFacts (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : List Val :=
  let entries := extractionEntriesFromPC pc registry
  entries.map extractionToFact

open Json in
/-- Convert a traceability entry to a JSON fact. -/
private def traceToFact (e : TraceEntry) : Val :=
  .obj ([
    ("kind", .str "traceability"),
    ("function", .str e.sourceFunction),
    ("evidence", .str e.evidenceLevel),
    ("extraction", .str e.extractionStatus),
    ("core", .arr (e.coreNames.map .str)),
    ("mono", .arr (e.monoNames.map .str)),
    ("ssa", .arr (e.ssaNames.map .str)),
    ("llvm", .arr (e.llvmNames.map .str)),
    ("boundary", .str e.claimBoundary),
    ("fingerprint", .str e.fingerprint),
    ("spec", .str e.specName),
    ("proof", .str e.proofName),
    ("loc", locToJson e.loc)
  ] ++ (if e.proofCoreForm.isEmpty then [] else [("proof_core", .str e.proofCoreForm)]))

open Json in
/-- Collect traceability facts for all functions. -/
def collectTraceabilityFacts
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : List Val :=
  let entries := collectTraceEntries coreModules monoModules ssaModules locMap registry pc
  entries.map traceToFact

open Json in
/-- Query traceability facts, optionally filtered by function name. -/
def queryTraceability
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (fnFilter : Option String := none)
    (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let allFacts := collectTraceabilityFacts coreModules monoModules ssaModules locMap registry pc
  let getStr (v : Val) (key : String) : Option String :=
    match v with
    | .obj kvs =>
      match kvs.find? (fun (k, _) => k == key) with
      | some (_, .str s) => some s
      | _ => none
    | _ => none
  let filtered := match fnFilter with
    | none => allFacts
    | some fnName => allFacts.filter fun v =>
      match getStr v "function" with
      | some f => f == fnName || f.endsWith ("." ++ fnName)
      | none => false
  (factsEnvelope filtered).render

open Json in
/-- The assumption facts for one function, as JSON — the SAME `Assumptions.Table` the text
    reports render, so JSON and text cannot disagree (R-0484 R10). -/
def assumptionsVal (assumptions : Assumptions.Table) (idx : Std.HashMap String String)
    (qualName : String) : List (String × Val) :=
  if assumptions.fns.isEmpty then [("assumptions_computed", .bool false)]
  else match idx.get? qualName >>= assumptions.fns.get? with
    | none => [("assumptions_computed", .bool false)]
    | some s =>
      let foreign := (assumptions.foreignFacts s).toList.map fun f =>
        .obj [("declaration", .str f.id.qualified), ("package_name", .str f.id.packageName),
              ("effects", .arr ((f.effects.normalize.1 ++ f.effects.normalize.2).map .str)),
              ("trusted_extern", .bool f.trustedExtern),
              -- R5: descriptor classification is not compiler-checked; this names the audit.
              ("descriptor_audit", .str f.descriptorAuditTag)]
      [ ("assumptions_computed", .bool true),
        ("dependencies_analysed", .bool assumptions.dependenciesAnalysed),
        ("coverage_complete", .bool s.complete),
        ("unresolved_indirect_calls", .arr (s.gaps.toList.map fun g =>
          -- The field name predates the other gap kinds; `kind` says which one this is.
          .obj [("site", .str g.site), ("binding", .str g.binding), ("kind", .str g.kind)])),
        ("assumed_foreign_bindings", .arr foreign),
        ("trusted_boundaries_reached", .num (Int.ofNat s.trustedBoundaries.size)),
        -- Named, with the obligation each absorbs (null: not determined or not computed).
        ("trusted_boundaries", .arr (s.trustedBoundaries.toList.map fun k =>
          let f? := assumptions.facts.get? k
          .obj [("declaration", .str ((f?.map (·.id.qualified)).getD k)),
                ("package_name", .str ((f?.map (·.id.packageName)).getD "")),
                ("absorbs", if !assumptions.absorbedComputed then .null else
                   match assumptions.absorbed.get? k with
                   | some (some xs) => .arr (xs.toList.map .str)
                   | _ => .null)])) ]

open Json in
/-- Convert an FnEffects record to a JSON fact. -/
private def effectsToFact (assumptions : Assumptions.Table) (idx : Std.HashMap String String)
    (e : FnEffects) : Val :=
  let (concreteCaps, _) := e.capSet.normalize
  -- "pure" is a CLAIM: no declared capability, complete coverage, and no foreign binding whose
  -- honesty it would rest on. An empty capability set alone does not earn it (R-0484).
  let noAuthority := match idx.get? e.qualName >>= assumptions.fns.get? with
    | some s => assumptions.noExternalAuthority s e.capSet
    | none => e.capSet == .empty && !e.effectOpaque
  .obj ([
    ("kind", .str "effects"),
    ("function", .str e.qualName),
    ("capabilities", .arr (concreteCaps.map .str)),
    ("no_external_authority", .bool noAuthority),
    ("allocates", .bool e.allocates),
    ("frees", .bool e.frees),
    ("defers", .bool e.defers),
    ("recursion", .str e.recursion),
    ("loops", .str e.loops),
    ("crosses_ffi", .bool e.crossesFfi),
    ("is_trusted", .bool e.isTrusted),
    ("is_public", .bool e.isPublic),
    ("evidence", .str e.evidence),
    ("loc", locToJson e.loc)
  ] ++ assumptionsVal assumptions idx e.qualName)

open Json in
/-- Collect effects facts for all functions. -/
def collectEffectsFacts (modules : List CModule) (locMap : FnLocMap := [])
    (pc : Concrete.ProofCore) (assumptions : Assumptions.Table := {}) : List Val :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  -- R-0484: purity is a claim, computed, not inferred from an empty capability set.
  let opaqueSet := effectOpaqueSet modules pc.callGraph
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule opaqueSet externNames recUncertain recMap locMap pc m) []
  let idx := assumptions.programIndex (modules.map (·.name))
  allEffects.map (effectsToFact assumptions idx)

open Json in
/-- Convert a per-function capability entry with why-traces to a JSON fact. -/
private def capToFact (lookup : CapLookup) (assumptions : Assumptions.Table)
    (idx : Std.HashMap String String) (qualName : String) (f : CFnDef)
    (aliases : List (String × String) := []) : Val :=
  let (concreteCaps, _) := f.capSet.normalize
  let traces := concreteCaps.map fun cap =>
    let sup := capSuppliers lookup assumptions.depCallees f cap aliases
    .obj [
      ("capability", .str cap),
      ("source", .str (if sup.isEmpty then "declared" else ", ".intercalate (sup.map (·.callee)))),
      -- How each supplier resolved: a program function, a DEPENDENCY definition (named), or an
      -- intrinsic. The same producer renders the caps and authority text.
      ("suppliers", .arr (sup.map fun x => .obj [("callee", .str x.callee), ("kind", .str x.kind),
          ("targets", .arr (x.targets.map .str))]))
    ]
  .obj ([
    ("kind", .str "capability"),
    ("function", .str qualName),
    ("capabilities", .arr (concreteCaps.map .str)),
    ("no_external_authority", .bool (match idx.get? qualName >>= assumptions.fns.get? with
      | some s => assumptions.noExternalAuthority s f.capSet
      | none => concreteCaps.isEmpty)),
    ("is_public", .bool f.isPublic),
    ("why", .arr traces)
  ] ++ assumptionsVal assumptions idx qualName)

open Json in
/-- Collect capability facts with why-traces for all functions. -/
private partial def collectCapFactsModule (lookup : CapLookup) (assumptions : Assumptions.Table)
    (idx : Std.HashMap String String) (m : CModule) (modulePath : String := "") : List Val :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fnFacts := m.functions.map fun f => capToFact lookup assumptions idx (qualPrefix ++ "." ++ f.sourceName) f m.linkerAliases
  let externFacts := m.externFns.map fun (n, _, _, trusted) =>
    -- What CALLING the binding requires: its declared effects, plus Unsafe unless trusted. The
    -- declared effects are an assumption about C (R-0484 R10), never a checked fact.
    let required := Capabilities.externFnRequiredCaps trusted ((m.externFnCaps.lookup n).getD .empty)
    let (rc, rv) := required.normalize
    .obj [
      ("kind", .str "capability"),
      ("function", .str (qualPrefix ++ "." ++ n)),
      ("capabilities", .arr ((rc ++ rv).map Val.str)),
      ("no_external_authority", .bool false),
      ("is_extern", .bool true),
      ("is_trusted", .bool trusted),
      ("declared_effects_assumed", .bool true),
      ("why", .arr [])
    ]
  fnFacts ++ externFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectCapFactsModule lookup assumptions idx sub qualPrefix) []

open Json in
def collectCapFacts (modules : List CModule) (assumptions : Assumptions.Table := {}) : List Val :=
  let lookup := buildCapLookup modules
  let idx := assumptions.programIndex (modules.map (·.name))
  modules.foldl (fun acc m => acc ++ collectCapFactsModule lookup assumptions idx m) []

open Json in
/-- Convert a function's unsafe/trust boundary info to a JSON fact. -/
private partial def collectUnsafeFactsModule (externNames : List String) (m : CModule) (modulePath : String := "") : List Val :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fnFacts := m.functions.filterMap fun f =>
    let qualName := qualPrefix ++ "." ++ f.sourceName
    let hasUnsafe := hasUnsafeCap f.capSet
    let hasRawPtrs := fnUsesRawPtrs f
    let trusted := f.isTrusted
    if !hasUnsafe && !hasRawPtrs && !trusted then none
    else
      let boundary := if trusted then trustBoundaryAnalysis externNames f else []
      some (.obj [
        ("kind", .str "unsafe"),
        ("function", .str qualName),
        ("has_unsafe_cap", .bool hasUnsafe),
        ("has_raw_pointers", .bool hasRawPtrs),
        ("is_trusted", .bool trusted),
        ("trust_boundary", .arr (boundary.map .str))
      ])
  let externFacts := m.externFns.map fun (n, _, _, trusted) =>
    .obj [
      ("kind", .str "unsafe"),
      ("function", .str (qualPrefix ++ "." ++ n)),
      ("is_extern", .bool true),
      ("is_trusted", .bool trusted)
    ]
  fnFacts ++ externFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectUnsafeFactsModule externNames sub qualPrefix) []

open Json in
def collectUnsafeFacts (modules : List CModule) : List Val :=
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  modules.foldl (fun acc m => acc ++ collectUnsafeFactsModule externNames m) []

open Json in
/-- Convert a function's allocation info to a JSON fact. -/
private def allocToFact (qualName : String) (f : CFnDef) : Option Val :=
  let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
  let allocs := callees.filter isAllocCall
  let frees := cleanupCallsStmts f.body
  let defers := collectDefersStmts f.body
  if allocs.isEmpty && frees.isEmpty && defers.isEmpty then none
  else
    let returnsAlloc := returnsAllocation f.retTy
    let leaks := !allocs.isEmpty && frees.isEmpty && defers.isEmpty && !returnsAlloc
    some (.obj [
      ("kind", .str "alloc"),
      ("function", .str qualName),
      ("allocates", .arr (allocs.map .str)),
      ("frees", .arr (frees.map .str)),
      ("defers", .arr (defers.map .str)),
      ("returns_allocation", .bool returnsAlloc),
      ("potential_leak", .bool leaks)
    ])

open Json in
private partial def collectAllocFactsModule (m : CModule) (modulePath : String := "") : List Val :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fnFacts := m.functions.filterMap fun f => allocToFact (qualPrefix ++ "." ++ f.sourceName) f
  fnFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectAllocFactsModule sub qualPrefix) []

open Json in
def collectAllocFacts (modules : List CModule) : List Val :=
  modules.foldl (fun acc m => acc ++ collectAllocFactsModule m) []

open Json in
/-- Collect per-function source-contract facts from the AST (not Core — contracts
    are AST metadata, erased before Core). One fact per function that declares any
    `#[requires]` / `#[ensures]` / loop `#[invariant]`. The clause sets are joined
    with `∧` and diffed at the clause level (see `isWeakening "contract"`), so the
    semantic-diff surface can classify a contract change as a breaking precondition
    strengthening, a breaking postcondition weakening, or a flagged invariant
    change. Emitted by `concrete snapshot`; consumed by `concrete diff`. -/
def collectContractFacts (modules : List Module) : List Val :=
  (modules.flatMap allFunctions).filterMap fun (pfx, f) =>
    let invs := f.loopContracts.flatMap (·.invariants)
    if f.requires.isEmpty && f.ensures.isEmpty && invs.isEmpty then none
    else
      let canon (es : List Expr) := " ∧ ".intercalate ((es.map Concrete.fmtExpr).eraseDups)
      some (.obj [
        ("kind", .str "contract"),
        ("function", .str (pfx ++ f.name)),
        ("requires", .str (canon f.requires)),
        ("ensures", .str (canon f.ensures)),
        ("invariants", .str (canon invs)) ])

open Json in
/-- Collect all core facts (everything except traceability) into a flat list. -/
def collectCoreFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) (pc : Concrete.ProofCore)
    (assumptions : Assumptions.Table := {}) : List Val :=
  let eligibility := collectEligibilityFacts pc
  let predictable := collectPredictableFacts modules locMap pc
  let proofStatus := collectProofStatusFacts modules locMap registry pc
  let obligations := collectObligationFacts modules locMap registry pc
  let extraction := collectExtractionFacts (registry := registry) (pc := pc)
  let effects := collectEffectsFacts modules locMap pc assumptions
  let caps := collectCapFacts modules assumptions
  let unsafeFacts := collectUnsafeFacts modules
  let alloc := collectAllocFacts modules
  let proofDiags := collectProofDiagnosticFacts pc
  let base := eligibility ++ predictable ++ proofStatus ++ obligations ++ extraction
  base ++ proofDiags ++ effects ++ caps ++ unsafeFacts ++ alloc

open Json in
/-- Produce JSON diagnostics combining all fact types in a versioned envelope. -/
def diagnosticsJson (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) (pc : Concrete.ProofCore)
    (assumptions : Assumptions.Table := {}) : String :=
  (factsEnvelope (collectCoreFacts modules locMap registry pc assumptions)).render

open Json in
/-- One VC as a JSON object (schema v1). -/
def vcToJson (v : VC) : Val :=
  .obj [
    ("id", .str v.id),
    ("kind", .str v.kind),
    ("function", .str v.fn),
    ("loc", .obj [("file", .str v.file), ("line", .num (Int.ofNat v.line))]),
    ("hypotheses", .arr (v.hypotheses.map (.str ·))),
    ("conclusion", .str v.conclusion),
    ("origin", .str v.origin),
    ("dependencies", .arr (v.dependencies.map (.str ·))),
    ("arith_profile", .str v.arithProfile),
    ("expected_discharge", .str v.dischargeMode),
    ("status", .str v.status),
    ("engine", .str v.engine),
    -- Multi-kernel provenance. `null` unless an external kernel actually attested,
    -- so the default artifact is unchanged. Present WITH versions, because a stored
    -- `proved_by_two_kernels` is otherwise un-auditable — the reader could not tell
    -- which prover builds agreed, nor invalidate the claim if one is later found
    -- buggy. This is the same (tool, version) tuple the verdict cache keys on.
    ("multi_kernel", if v.attestingKernels.isEmpty then Json.Val.null else .obj [
      ("attesting_kernels", .arr (v.attestingKernels.map (.str ·))),
      ("attesting_kernel_versions", .arr (v.attestingKernelVersions.map (.str ·))),
      -- One receipt per kernel consulted. The class above is COMPOSED from these, so
      -- a reader can recompute it rather than trust it, and each receipt carries the
      -- command to re-derive it independently.
      ("receipts", .arr (v.kernelReceipts.map (fun r => Json.Val.obj [
        ("kernel", .str r.kernel), ("version", .str r.version),
        ("verdict", .str r.verdict),
        ("lowering_agreed", .str (if r.loweringAgreed then "yes" else "no")),
        ("attests", .str (if r.attests then "yes" else "no")),
        ("replay", .str r.replay)]))),
      -- STRUCTURED independence, not a prose sentence: a stale field can be gated, a
      -- stale comment cannot. `bridge: no` is the standing honest disclaimer.
      ("independent_of", match v.independence with
        | none => Json.Val.null
        | some i => .obj [
            ("spec_formalization", .str i.specFormalization),
            ("kernel_implementation", .str i.kernelImplementation),
            ("kernel_foundations", .str i.kernelFoundations),
            ("bridge", .str i.bridge)])]),
    ("counterexample", .obj (v.counterexample.map (fun (n, x) => (n, Json.Val.str x)))),
    -- SMT provenance (determinism / replay). Present only for SMT-routed VCs;
    -- `null` otherwise, so the default report carries no solver data.
    ("smt", if v.smtHash.isEmpty then Json.Val.null else .obj [
      ("logic", .str "QF_NIA"),
      ("timeout_sec", .num 5),
      ("smtlib_sha", .str v.smtHash),
      ("solver", .str (if v.solver.isEmpty then "(not run)" else v.solver)),
      ("query", .str v.smtQuery),
      ("replay", .str s!"save `query` to vc.smt2 and run: z3 -T:5 vc.smt2"),
      -- Lean replay artifact: the SAME obligation as a kernel-checkable theorem.
      ("lean_replay", if v.leanReplay.isEmpty then Json.Val.null else .obj [
        ("theorem", .str v.leanReplay),
        ("proof_attempt", .str "by omega (in-toolchain; a Mathlib build can swap in nlinarith)"),
        ("check_command", .str "save to vc_replay.lean and run: lake env lean vc_replay.lean"),
        ("note", .str "if Lean closes it, the VC graduates solver_trusted → proved_by_lean_replay and no longer depends on the solver")])
    ])
  ]

open Json in
/-- Versioned JSON envelope of a (post-discharge) VC schedule (schema v1). -/
def vcsJson (vcs : List VC) (schemaVer : Nat) : String :=
  (Val.obj [
    ("schema_version", .num (Int.ofNat schemaVer)),
    ("schema_kind", .str "vcs"),
    ("vc_schema_version", .num (Int.ofNat vcSchemaVersion)),
    ("count", .num (Int.ofNat vcs.length)),
    ("vcs", .arr (vcs.map vcToJson))
  ]).render

open Json in
/-- Build proof-specific summary from proof-related facts. -/
private def buildProofSummary (pc : Concrete.ProofCore) : Val :=
  let obCount (s : Concrete.ObligationStatus) := (pc.obligations.filter fun o => o.status == s).length
  let diagCount (k : Concrete.ProofDiagnosticKind) := (pc.diagnostics.filter fun d => d.kind == k).length
  let extractedCount := (pc.entries.filter fun e => e.extracted.isSome).length
  let blockedCount := (pc.entries.filter fun e => e.extracted.isNone && !e.unsupported.isEmpty).length
  let excludedCount := pc.excluded.length
  let depsCount := (pc.obligations.filter fun o => !o.dependencies.isEmpty).length
  let notCurrentDepsCount := (pc.obligations.filter fun o => !o.notCurrentDeps.isEmpty).length
  .obj [
    ("total_functions", .num (pc.obligations.length)),
    ("proved", .num (obCount .proved)),
    ("stale", .num (obCount .stale)),
    ("missing", .num (obCount .missing)),
    ("blocked", .num (obCount .blocked)),
    ("ineligible", .num (obCount .ineligible)),
    ("trusted", .num (obCount .trusted)),
    ("extracted", .num extractedCount),
    ("extraction_blocked", .num blockedCount),
    ("excluded", .num excludedCount),
    ("diagnostics_errors", .num ((pc.diagnostics.filter fun d => d.severity == .error).length)),
    ("diagnostics_warnings", .num ((pc.diagnostics.filter fun d => d.severity == .warning).length)),
    ("diagnostics_info", .num ((pc.diagnostics.filter fun d => d.severity == .info).length)),
    ("stale_proof_count", .num (diagCount .staleProof)),
    ("missing_proof_count", .num (diagCount .missingProof)),
    ("attachment_integrity_count", .num (diagCount .attachmentIntegrity)),
    ("functions_with_dependencies", .num depsCount),
    ("functions_with_stale_deps", .num notCurrentDepsCount)
  ]

open Json in
/-- Convert a registry entry to a JSON value. -/
private def registryEntryToJson (e : Concrete.ProofRegistryEntry) : Val :=
  .obj [
    ("function", .str e.function),
    ("body_fingerprint", .str e.bodyFingerprint),
    ("proof", .str e.proof),
    ("spec", .str e.spec)
  ]

open Json in
/-- Convert a dependency edge to a JSON value. -/
private def depEdgeToJson (o : Concrete.Obligation) : Val :=
  .obj [
    ("function", .str o.functionId.qualName),
    ("status", .str o.status.canonical),
    ("proved_deps", .arr (o.dependencies.map .str)),
    ("stale_deps", .arr (o.notCurrentDeps.map .str))
  ]

open Json in
/-- Produce a proof-workflow evidence bundle combining all proof-related data. -/
def proofBundleJson
    (sourcePath : String)
    (timestamp : String)
    (compilerIdent : String)
    (modules : List CModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  -- Proof-related facts
  let proofStatusFacts := collectProofStatusFacts modules locMap registry pc
  let obligationFacts := collectObligationFacts modules locMap registry pc
  let extractionFacts := collectExtractionFacts (registry := registry) (pc := pc)
  let diagnosticFacts := collectProofDiagnosticFacts pc
  let eligibilityFacts := collectEligibilityFacts pc
  let allFacts := proofStatusFacts ++ obligationFacts ++ extractionFacts ++ diagnosticFacts ++ eligibilityFacts
  -- Registry entries
  let registryJson := registry.map registryEntryToJson
  -- Dependency edges (only functions that have deps or stale deps)
  let depEdges := (pc.obligations.filter fun o =>
    !o.dependencies.isEmpty || !o.notCurrentDeps.isEmpty).map depEdgeToJson
  -- Assumptions
  let assumptions := Val.obj [
    ("proof_model", .str "PExpr with Lean unbounded Int, pure functional semantics"),
    ("compilation_chain", .str "Core IR → SSA → LLVM IR → binary: unverified"),
    ("integer_model", .str "PExpr uses unbounded Int; binary uses 64-bit fixed-width"),
    ("composition", .str "per-function proofs; cross-function composition not verified"),
    ("checker_soundness", .str "Concrete checker (Check.lean) correctness is assumed, not proved"),
    ("fingerprint_stability", .str "stable within compiler version; may change across versions")
  ]
  let bundle := Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("schema_kind", .str "proof_bundle"),
    ("source", .str sourcePath),
    ("timestamp", .str timestamp),
    ("compiler", .str compilerIdent),
    ("summary", buildProofSummary pc),
    ("assumptions", assumptions),
    ("registry", .arr registryJson),
    ("dependency_graph", .arr depEdges),
    ("fact_count", .num allFacts.length),
    ("facts", .arr allFacts)
  ]
  bundle.render



end Report
end Concrete
