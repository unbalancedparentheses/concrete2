import Concrete.Report.Facts

/-! Semantic queries (why-capability) and the fact artifact snapshot. Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report

-- ============================================================
-- Semantic query: why-capability trace
-- ============================================================

/-- Build a flat lookup of bare function names to CFnDef across module tree. -/
private partial def buildFnLookupModule (m : CModule) : List (String × CFnDef) :=
  let fns := m.functions.map fun f => (f.name, f)
  fns ++ m.submodules.foldl (fun acc sub => acc ++ buildFnLookupModule sub) []

private def buildFnLookup (modules : List CModule) : List (String × CFnDef) :=
  modules.foldl (fun acc m => acc ++ buildFnLookupModule m) []

/-- Build a flat extern name → trusted lookup. -/
private partial def buildExternLookupModule (m : CModule) : List (String × Bool) :=
  let exts := m.externFns.map fun (n, _, _, t) => (n, t)
  exts ++ m.submodules.foldl (fun acc sub => acc ++ buildExternLookupModule sub) []

private def buildExternLookup (modules : List CModule) : List (String × Bool) :=
  modules.foldl (fun acc m => acc ++ buildExternLookupModule m) []

open Json in
/-- Trace why a function requires a specific capability.
    Returns a list of trace steps from the queried function down to the origin.
    Stops at: declared (with clause), extern, intrinsic, or depth limit.
    visited prevents cycles. -/
private partial def traceCapability
    (fnLookup : List (String × CFnDef))
    (externLookup : List (String × Bool))
    (capLookup : CapLookup)
    (locMap : FnLocMap)
    (fnName : String) (cap : String)
    (visited : List String := []) (depth : Nat := 0)
    (deps : Std.HashMap String (Array (String × CapSet)) := {})
    (aliases : List (String × String) := []) : List Val :=
  if depth > 20 then [.obj [("function", .str fnName), ("error", .str "depth limit")]]
  else if visited.contains fnName then [.obj [("function", .str fnName), ("error", .str "cycle")]]
  else
    -- Is it an intrinsic?
    match resolveIntrinsic fnName with
    | some iid =>
      match iid.capability with
      | some icap =>
        if icap == cap then [.obj [("function", .str fnName), ("origin", .str "intrinsic")]]
        else []
      | none => []
    | none =>
    -- Is it an extern?
    match externLookup.find? (fun (n, _) => n == fnName) with
    | some (_, trusted) =>
      if !trusted then
        -- Untrusted externs have Unsafe capability
        if cap == unsafeCapName then
          [.obj [("function", .str fnName), ("origin", .str "extern")]]
        else []
      else []  -- trusted externs have no capabilities
    | none =>
    -- Is it a user function?
    match fnLookup.find? (fun (n, _) => n == fnName) with
    | none => []
    | some (_, f) =>
      let (concreteCaps, _) := f.capSet.normalize
      -- Check if this function even has the cap
      if !concreteCaps.contains cap then []
      else
        let visited' := fnName :: visited
        -- The callees that supply this cap, resolved by the one producer (program definition,
        -- then DEPENDENCY definition, then intrinsic — R-0484 R10).
        let suppliers := capSuppliers capLookup deps f cap aliases
        let contributors := suppliers.filter (·.kind != "dependency") |>.map (·.callee)
        let depSteps : List Val := (suppliers.filter (·.kind == "dependency")).foldl (fun acc x =>
          acc ++ [Val.obj [("function", .str fnName), ("edge", .str "calls"), ("callee", .str x.callee)]]
            ++ x.targets.map fun q =>
              -- The dependency's own header declares the capability; its summary is not re-walked.
              Val.obj [("function", .str q), ("origin", .str "declared"), ("dependency", .bool true)]) []
        if contributors.isEmpty && depSteps.isEmpty then
          -- No callee contributes it → declared via with(...)
          let loc := locMap.find? (fun e => e.qualName.endsWith ("." ++ fnName) || e.qualName == fnName)
          let locVal := match loc with
            | some e => locToJson (some (e.file, e.fnSpan.line))
            | none => Val.null
          [.obj [("function", .str fnName), ("origin", .str "declared"), ("loc", locVal)]]
        else
          -- Trace through each program contributor; dependency suppliers end at their header.
          contributors.foldl (fun acc callee =>
            let subTrace := traceCapability fnLookup externLookup capLookup locMap
              callee cap visited' (depth + 1) deps aliases
            if subTrace.isEmpty then acc
            else
              let step := Val.obj [("function", .str fnName), ("edge", .str "calls"), ("callee", .str callee)]
              acc ++ [step] ++ subTrace
          ) [] ++ depSteps

open Json in
/-- Handle a why-capability query. Returns answer-shaped JSON. -/
def whyCapabilityQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (cap : String) (assumptions : Assumptions.Table := {}) : String :=
  let fnLookup := buildFnLookup modules
  let externLookup := buildExternLookup modules
  let capLookup := buildCapLookup modules
  let trace := traceCapability fnLookup externLookup capLookup locMap fnName cap [] 0 assumptions.depCallees (modules.foldl (fun acc m => acc ++ allLinkerAliases m) [])
  -- R-0479 REPAIRED 2026-08-16. `transitive` is stated explicitly so the catch-all stops doing
  -- double duty — it used to be both the real fourth origin and the fallback for an unreadable one,
  -- turning "the origin key is absent" into a positive claim that the capability arrived
  -- transitively. But the repair sent the MULTI-STEP case to `origin_unavailable` as well, and a
  -- multi-step trace is exactly what transitive MEANS. Four assertions failed on traces that were
  -- entirely correct: `main → uses_alloc → vec_new (intrinsic)` reported "origin unavailable" while
  -- carrying the intrinsic origin it had just resolved.
  --
  -- So the two facts are separated properly. A trace of ONE step reports that step's own origin. A
  -- trace of SEVERAL steps is transitive IF some step carries a readable origin, and unavailable
  -- only when none does — which is the case the repair was actually about.
  let readableOrigin : Val → Bool := fun v =>
    match v with
    | .obj kvs =>
      match kvs.find? (fun (k, _) => k == "origin") with
      | some (_, .str "declared") | some (_, .str "intrinsic")
      | some (_, .str "extern") | some (_, .str "transitive") => true
      | _ => false
    | _ => false
  let answer :=
    if trace.isEmpty then "not_required"
    else
      match trace with
      | [.obj kvs] =>
        match kvs.find? (fun (k, _) => k == "origin") with
        | some (_, .str "declared") => "declared"
        | some (_, .str "intrinsic") => "intrinsic"
        | some (_, .str "extern") => "extern"
        | some (_, .str "transitive") => "transitive"
        | _ => Concrete.originUnavailable
      | steps =>
        if steps.any readableOrigin then "transitive" else Concrete.originUnavailable
  let result := Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("kind", .str "query_answer"),
    ("query", .str s!"why-capability:{fnName}:{cap}"),
    ("function", .str fnName),
    ("capability", .str cap),
    ("answer", .str answer),
    ("trace", .arr trace)
  ]
  result.render

open Json in
/-- Handle a predictable query for a single function. Returns answer-shaped JSON. -/
def predictableQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (pc : Concrete.ProofCore) : String :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap recUncertain externNames locMap m) []
  let fnViolations := violations.filter fun v =>
    v.fnName == fnName
  let answer := if fnViolations.isEmpty then "pass" else "fail"
  let gates := fnViolations.map fun v =>
    .obj ([
      ("gate", .str v.reason),
      ("hint", .str v.hint)
    ] ++ match v.loc with
      | some l => [("loc", locToJson (some l))]
      | none => []
    ++ match v.violationLoc with
      | some l => [("violation_loc", locToJson (some l))]
      | none => [])
  let result := Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("kind", .str "query_answer"),
    ("query", .str s!"predictable:{fnName}"),
    ("function", .str fnName),
    ("answer", .str answer),
    ("gates_failed", .num (Int.ofNat fnViolations.length)),
    ("violations", .arr gates)
  ]
  result.render

open Json in
/-- Handle a proof query for a single function. Returns answer-shaped JSON. -/
def proofQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  let fnEntry := entries.find? fun e =>
    e.bareName == fnName || e.qualName == fnName || e.qualName.endsWith ("." ++ fnName)
  match fnEntry with
  | none =>
    (Val.obj [
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"proof:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some e =>
    let stateStr := e.state.canonical
    let hintStr := match e.state with
      | .stale => "Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
      | .notProved => "Add a Lean proof for this function in Concrete/Proof.lean with the current fingerprint."
      | .blocked => "Remove unsupported constructs to enable proof extraction."
      | .notEligible => s!"Remove {", ".intercalate e.eligibilityReasons} to make this function eligible for proof."
      | _ => ""
    (Val.obj ([
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"proof:{fnName}"),
      ("function", .str e.qualName),
      ("answer", .str stateStr),
      ("current_fingerprint", .str e.currentFp)
    ] ++ (if e.expectedFp.isEmpty then [] else [("expected_fingerprint", .str e.expectedFp)])
      ++ (if e.eligibilityReasons.isEmpty then [] else [("profile_gates", .arr (e.eligibilityReasons.map .str))])
      ++ (if hintStr.isEmpty then [] else [("hint", .str hintStr)])
      ++ [("loc", locToJson e.loc)])).render

open Json in
/-- Handle an evidence query for a single function. Returns answer-shaped JSON
    combining predictable profile, proof status, and trust into one answer. -/
def evidenceQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) : String :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  -- R-0484: purity is a claim, computed, not inferred from an empty capability set.
  let opaqueSet := effectOpaqueSet modules pc.callGraph
  -- Get effects for evidence level
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule opaqueSet externNames recUncertain recMap locMap pc m) []
  let matchFn (e : FnEffects) := e.name == fnName || e.qualName == fnName || e.qualName.endsWith ("." ++ fnName)
  let fnEffects := allEffects.find? matchFn
  -- Get violations
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap recUncertain externNames locMap m) []
  let fnViolations := violations.filter fun v => v.fnName == fnName || v.qualName == fnName || v.qualName.endsWith ("." ++ fnName)
  -- Get proof status
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus pc locMap m "" registry) []
  let fnProof := entries.find? fun e =>
    e.bareName == fnName || e.qualName == fnName || e.qualName.endsWith ("." ++ fnName)
  match fnEffects with
  | none =>
    (Val.obj [
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"evidence:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some eff =>
    let proofState := match fnProof with
      | some e => e.state.canonical
      | none => "missing"
    let gatesFailed := fnViolations.map fun v => Val.str v.reason
    (Val.obj [
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"evidence:{fnName}"),
      ("function", .str eff.qualName),
      ("answer", .str eff.evidence),
      ("is_trusted", .bool eff.isTrusted),
      ("passes_predictable", .bool fnViolations.isEmpty),
      ("proof_state", .str proofState),
      ("gates_failed", .arr gatesFailed),
      ("loc", locToJson eff.loc)
    ]).render

open Json in
/-- Handle an audit query for a single function. Bundles authority, predictable
    profile, proof status, evidence, trust, and allocation into one answer. -/
def auditQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) (assumptions : Assumptions.Table := {}) : String :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  -- R-0484: purity is a claim, computed, not inferred from an empty capability set.
  let opaqueSet := effectOpaqueSet modules pc.callGraph
  let capLookup := buildCapLookup modules
  let fnLookup := buildFnLookup modules
  let externLookup := buildExternLookup modules
  -- Effects
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule opaqueSet externNames recUncertain recMap locMap pc m) []
  let fnEffects := allEffects.find? fun e => e.name == fnName || e.qualName == fnName || e.qualName.endsWith ("." ++ fnName)
  match fnEffects with
  | none =>
    (Val.obj [
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"audit:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some eff =>
    -- Capabilities with why traces
    let (concreteCaps, _) := eff.capSet.normalize
    let capTraces := concreteCaps.map fun cap =>
      let trace := traceCapability fnLookup externLookup capLookup locMap fnName cap [] 0 assumptions.depCallees (modules.foldl (fun acc m => acc ++ allLinkerAliases m) [])
      let origin :=
        if trace.isEmpty then "not_required"
        else match trace with
          | [.obj kvs] =>
            match kvs.find? (fun (k, _) => k == "origin") with
            | some (_, .str o) => o
            -- R-0479: an absent origin key or a non-object trace is not evidence of transitivity.
            | _ => Concrete.originUnavailable
          -- ...and a MULTI-STEP trace is transitive when some step resolves an origin. Same repair
          -- as the query path above: "several steps" and "no readable origin" are different facts.
          | steps =>
            let readable := steps.any (fun v =>
              match v with
              | .obj kvs =>
                match kvs.find? (fun (k, _) => k == "origin") with
                | some (_, .str "declared") | some (_, .str "intrinsic")
                | some (_, .str "extern") | some (_, .str "transitive") => true
                | _ => false
              | _ => false)
            if readable then "transitive" else Concrete.originUnavailable
      .obj [("capability", .str cap), ("origin", .str origin), ("trace", .arr trace)]
    -- Predictable
    let violations := modules.foldl (fun acc m =>
      acc ++ checkPredictableModule recMap recUncertain externNames locMap m) []
    let fnViolations := violations.filter fun v => v.fnName == fnName || v.qualName == fnName || v.qualName.endsWith ("." ++ fnName)
    let violationFacts := fnViolations.map fun v =>
      .obj ([("gate", .str v.reason), ("hint", .str v.hint)]
        ++ match v.violationLoc with
          | some l => [("violation_loc", locToJson (some l))]
          | none => [])
    -- Proof
    let entries := modules.foldl (fun acc m =>
      acc ++ collectProofStatus pc locMap m "" registry) []
    let fnProof := entries.find? fun e =>
      e.bareName == fnName || e.qualName.endsWith ("." ++ fnName)
    let proofState := match fnProof with
      | some e => e.state.canonical
      | none => "missing"
    let fingerprint := match fnProof with
      | some e => e.currentFp | none => "<missing>"
    -- Allocation
    let fnDef := fnLookup.find? (fun (n, _) => n == fnName)
    let allocInfo := match fnDef with
      | some (_, f) =>
        let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
        let allocs := callees.filter isAllocCall
        let frees := cleanupCallsStmts f.body
        let defers := collectDefersStmts f.body
        .obj [
          ("allocates", .arr (allocs.map .str)),
          ("frees", .arr (frees.map .str)),
          ("defers", .arr (defers.map .str)),
          ("returns_allocation", .bool (returnsAllocation f.retTy))
        ]
      | none => .obj [("allocates", .arr []), ("frees", .arr []), ("defers", .arr []),
                       ("returns_allocation", .bool false)]
    (Val.obj [
      ("schema_version", .num (Int.ofNat schemaVersion)),
      ("kind", .str "query_answer"),
      ("query", .str s!"audit:{fnName}"),
      ("function", .str eff.qualName),
      ("loc", locToJson eff.loc),
      ("evidence", .str eff.evidence),
      ("is_public", .bool eff.isPublic),
      ("is_trusted", .bool eff.isTrusted),
      ("authority", .obj [
        ("capabilities", .arr (concreteCaps.map .str)),
        ("no_declared_capability", .bool concreteCaps.isEmpty),
        ("traces", .arr capTraces)
      ]),
      ("predictable", .obj [
        ("passes", .bool fnViolations.isEmpty),
        ("violations", .arr violationFacts)
      ]),
      ("proof", .obj ([
        ("state", .str proofState),
        ("fingerprint", .str fingerprint)
      ] ++ match fnProof with
        | some e => if e.eligibilityReasons.isEmpty then []
          else [("profile_gates", .arr (e.eligibilityReasons.map .str))]
        | none => [])),
      ("allocation", allocInfo)
    ]).render

open Json in
/-- Query compiler facts by kind and optional function name.
    Query formats:
    - "KIND"                  — filter all facts by kind
    - "KIND:FUNCTION"         — filter by kind + function
    - "fn:FUNCTION"           — all facts for one function
    - "why-capability:FN:CAP" — trace why a function requires a capability
    - "predictable:FN"        — predictable profile answer for one function
    - "proof:FN"              — proof status answer for one function
    - "evidence:FN"           — combined evidence answer for one function
    Returns Except.error for malformed/unknown queries, Except.ok for valid results. -/
def queryFacts (modules : List CModule) (locMap : FnLocMap := [])
    (query : String) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) (assumptions : Assumptions.Table := {}) : Except String String :=
  let parts := query.splitOn ":"
  let allKindsStr := s!"{", ".intercalate knownQueryKinds} (semantic), {", ".intercalate knownFactKinds} (fact filter)"
  -- Reject empty query
  if query.isEmpty then
    .error s!"empty query string. Use --query KIND, --query KIND:FUNCTION, or --query predictable:FUNCTION. Known kinds: {allKindsStr}"
  else
  -- Reject queries with empty segments (leading/trailing/double colons)
  if parts.any (·.isEmpty) then
    .error s!"malformed query '{query}': contains empty segment. Use --query KIND:FUNCTION, not ':FUNCTION' or 'KIND:'"
  else
  -- Semantic queries: three-part (why-capability:fn:cap)
  if parts.length == 3 then
    match parts with
    | ["why-capability", fnName, cap] => .ok (whyCapabilityQuery modules locMap fnName cap assumptions)
    | [kind, _, _] =>
      .error s!"unknown three-part query kind '{kind}'. Only 'why-capability:FN:CAP' uses three parts"
    | _ => .error s!"malformed three-part query '{query}'"
  else
  -- Semantic queries: two-part (predictable:fn, proof:fn, evidence:fn)
  if parts.length == 2 then
    match parts with
    | ["predictable", fnName] => .ok (predictableQuery modules locMap fnName pc)
    | ["proof", fnName] => .ok (proofQuery modules locMap fnName registry pc)
    | ["evidence", fnName] => .ok (evidenceQuery modules locMap fnName registry pc)
    | ["audit", fnName] => .ok (auditQuery modules locMap fnName registry pc assumptions)
    | ["fn", fnName] =>
      let allFacts := collectCoreFacts modules locMap registry pc assumptions
      let filtered := allFacts.filter fun v =>
        match jsonGetStr v "function" with
        | some f => f == fnName || f.endsWith ("." ++ fnName)
        | none => false
      .ok (factsEnvelope filtered).render
    | [filterKind, filterFn] =>
      -- kind:function filter — validate the kind is known
      if knownFactKinds.contains filterKind then
        let allFacts := collectCoreFacts modules locMap registry pc assumptions
        let byKind := allFacts.filter fun v =>
          jsonGetStr v "kind" == some filterKind
        let filtered := byKind.filter fun v =>
          match jsonGetStr v "function" with
          | some f => f == filterFn || f.endsWith ("." ++ filterFn)
          | none => false
        .ok (factsEnvelope filtered).render
      else
        .error s!"unknown query kind '{filterKind}'. Known kinds: {allKindsStr}"
    | _ => .error s!"malformed two-part query '{query}'"
  else if parts.length == 1 then
    -- Single-word filter: all facts of this kind — validate kind is known
    if knownFactKinds.contains query then
      let allFacts := collectCoreFacts modules locMap registry pc assumptions
      let filtered := allFacts.filter fun v =>
        jsonGetStr v "kind" == some query
      .ok (factsEnvelope filtered).render
    else
      .error s!"unknown query kind '{query}'. Known kinds: {allKindsStr}"
  else
    .error s!"malformed query '{query}': too many ':' separators (max 2, for why-capability:FN:CAP)"


-- ============================================================
-- Fact artifact snapshot
-- ============================================================

open Json in
/-- Build a summary object from a list of facts. -/
private def buildSummaryFact (facts : List Val) : Val :=
  let count (kind : String) := facts.filter (fun v => jsonGetStr v "kind" == some kind) |>.length
  let proofFacts := facts.filter fun v => jsonGetStr v "kind" == some "proof_status"
  let proofState (s : String) := proofFacts.filter (fun v => jsonGetStr v "state" == some s) |>.length
  let obFacts := facts.filter fun v => jsonGetStr v "kind" == some "obligation"
  let obStatus (s : String) := obFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  let extFacts := facts.filter fun v => jsonGetStr v "kind" == some "extraction"
  let extStatus (s : String) := extFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  let eligFacts := facts.filter fun v => jsonGetStr v "kind" == some "eligibility"
  let eligStatus (s : String) := eligFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  .obj [
    ("total_functions", .num (proofFacts.length)),
    ("proved", .num (proofState "proved")),
    ("stale", .num (proofState "stale")),
    ("missing", .num (proofState "missing")),
    ("ineligible", .num (proofState "ineligible")),
    ("trusted", .num (proofState "trusted")),
    -- These three completed the census. `total_functions` never added up:
    -- `unbound` and `blocked` had been missing since those states existed, so a
    -- function in either was invisible to any consumer summing this object, and
    -- `deps_not_current` would have joined them. A summary that silently drops
    -- states is worse than one that omits the field, because it reads complete.
    ("unbound", .num (proofState "unbound")),
    ("blocked", .num (proofState "blocked")),
    ("deps_not_current", .num (proofState "deps_not_current")),
    -- The same omission, one status later. `correspondence_unjustified` and `needs_recheck` were
    -- both absent, so a downgraded function was invisible to any consumer summing this object —
    -- which is how a crypto_verify snapshot reported 2 proved of 5 total with nothing accounting
    -- for the other two.
    ("correspondence_unjustified", .num (proofState "correspondence_unjustified")),
    ("needs_recheck", .num (proofState "needs_recheck")),
    ("eligibility_eligible", .num (eligStatus "eligible")),
    ("eligibility_excluded", .num (eligStatus "excluded")),
    ("eligibility_trusted", .num (eligStatus "trusted")),
    ("predictable_violations", .num (count "predictable_violation")),
    ("obligations_proved", .num (obStatus "proved")),
    ("obligations_missing", .num (obStatus "missing")),
    ("obligations_blocked", .num (obStatus "blocked")),
    ("obligations_stale", .num (obStatus "stale")),
    ("extracted", .num (extStatus "extracted")),
    ("excluded", .num (extStatus "excluded")),
    ("effects_facts", .num (count "effects")),
    ("capability_facts", .num (count "capability")),
    ("unsafe_facts", .num (count "unsafe")),
    ("alloc_facts", .num (count "alloc")),
    ("traceability_facts", .num (count "traceability"))
  ]

open Json in
/-- Build the full snapshot JSON object with metadata, facts, and summary. -/
def snapshotJson
    (sourcePath : String)
    (timestamp : String)
    (coreFacts : List Val)
    (traceFacts : List Val := []) : String :=
  let allFacts := coreFacts ++ traceFacts
  let summary := buildSummaryFact allFacts
  let snapshot := Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("version", .num 1),
    ("source", .str sourcePath),
    ("timestamp", .str timestamp),
    ("fact_count", .num allFacts.length),
    ("summary", summary),
    ("facts", .arr allFacts)
  ]
  snapshot.render

/-- Single-command audit composing the surfaces a reviewer needs to answer
    "what does this program claim, and where do the trust boundaries sit?".
    The audit is the per-program rendering of the proof-story matrix
    (`docs/verification/PROOF_STORY_MATRIX.md`): authority, trust, allocation, proof
    evidence with coverage, obligations.  Each section is the existing
    aspect-specific report under a labeled banner; later versions can
    add machine-readable JSON output and a ProvableV1 conformance check. -/
def auditReport (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) (registry : ProofRegistry := [])
    (pc : Concrete.ProofCore) (vcSummary : String := "")
    (assumptions : Assumptions.Table := {}) (depsLoaded : Bool := false) : String :=
  let banner := String.intercalate "\n"
    [ "=== Concrete Audit Report ==="
    , ""
    , "Governing frame: every construct is one of"
    , "  proved / enforced / reported / assumed / trusted."
    , "See docs/verification/PROVABLE_V1.md and docs/verification/PROOF_STORY_MATRIX.md for context."
    ]
  let sectionHeader (name : String) : String :=
    s!"\n\n--- {name} ---\n"
  String.intercalate "" [
    banner,
    sectionHeader "Authority",
    capabilityReport modules assumptions,
    sectionHeader "Allocation",
    allocReport modules,
    sectionHeader "Unsafe / Trust",
    unsafeReport modules pc assumptions depsLoaded,
    sectionHeader "Effects",
    effectsReport modules locMap pc assumptions,
    sectionHeader "Eligibility",
    eligibilityReport pc,
    sectionHeader "Proof Status",
    proofStatusReport modules locMap sourceMap (registry := registry) (pc := pc),
    sectionHeader "ProvableV1 Conformance",
    provableV1ConformanceReport modules locMap (registry := registry) (pc := pc),
    sectionHeader "Obligations",
    obligationsReport modules locMap registry pc,
    sectionHeader "Verification Conditions",
    (if vcSummary.isEmpty then "(no verification conditions)" else vcSummary)
  ]

open Json in
/-- Produce the JSON API schema definition. Documents all fact kinds, their fields,
    query response shapes, location encoding, and compatibility rules. -/
def schemaReport : String :=
  let loc := Val.obj [
    ("type", .str "object|null"),
    ("fields", .obj [("file", .str "string"), ("line", .str "number")]),
    ("note", .str "null when source location is unavailable")
  ]
  let fieldSpec (required optional : List (String × String)) : Val :=
    .obj [
      ("required", .arr (required.map fun (k, v) => .obj [("name", .str k), ("type", .str v)])),
      ("optional", .arr (optional.map fun (k, v) => .obj [("name", .str k), ("type", .str v)]))
    ]
  let factSchemas := Val.obj [
    ("proof_diagnostic", fieldSpec
      [("kind", "string"), ("code", "string"), ("diagnostic_kind", "string"), ("severity", "string"),
       ("function", "string"), ("message", "string"), ("loc", "location"),
       ("failure_class", "string"), ("repair_class", "string")]
      [("hint", "string"), ("details", "string[]"), ("fingerprint", "string"),
       ("expected_fingerprint", "string")]),
    ("predictable_violation", fieldSpec
      [("kind", "string"), ("function", "string"), ("state", "string"),
       ("reason", "string"), ("hint", "string"), ("loc", "location"),
       ("violation_loc", "location")]
      []),
    ("proof_status", fieldSpec
      [("kind", "string"), ("function", "string"), ("state", "string"),
       ("loc", "location"), ("current_fingerprint", "string")]
      [("expected_fingerprint", "string"), ("spec", "string"), ("proof", "string"),
       ("source", "string"), ("profile_gates", "string[]"), ("hint", "string")]),
    ("eligibility", fieldSpec
      [("kind", "string"), ("function", "string"), ("status", "string"),
       ("exclusion_kind", "string"), ("source_reasons", "string[]"),
       ("profile_reasons", "string[]"), ("loc", "location")]
      []),
    ("obligation", fieldSpec
      [("kind", "string"), ("function", "string"), ("status", "string"),
       ("spec", "string"), ("proof", "string"), ("source", "string"),
       ("fingerprint", "string"), ("dependencies", "string[]"),
       ("stale_deps", "string[]"), ("loc", "location")]
      []),
    ("extraction", fieldSpec
      [("kind", "string"), ("function", "string"), ("status", "string"),
       ("eligible", "boolean"), ("fingerprint", "string"), ("params", "string[]"),
       ("loc", "location")]
      [("proof_core", "string"), ("spec", "string"), ("proof", "string"),
       ("excluded_reasons", "string[]"), ("unsupported", "string[]")]),
    ("traceability", fieldSpec
      [("kind", "string"), ("function", "string"), ("evidence", "string"),
       ("extraction", "string"), ("core", "string[]"), ("mono", "string[]"),
       ("ssa", "string[]"), ("llvm", "string[]"), ("boundary", "string"),
       ("fingerprint", "string"), ("spec", "string"), ("proof", "string"),
       ("loc", "location")]
      [("proof_core", "string")]),
    ("effects", fieldSpec
      [("kind", "string"), ("function", "string"), ("capabilities", "string[]"),
       ("no_external_authority", "boolean"), ("allocates", "boolean"), ("frees", "boolean"),
       ("defers", "boolean"), ("recursion", "string"), ("loops", "string"),
       ("crosses_ffi", "boolean"), ("is_trusted", "boolean"), ("is_public", "boolean"),
       ("evidence", "string"), ("loc", "location")]
      []),
    ("capability", fieldSpec
      [("kind", "string"), ("function", "string"), ("capabilities", "string[]"),
       ("no_external_authority", "boolean"), ("why", "object[]")]
      [("is_public", "boolean"), ("is_extern", "boolean"), ("is_trusted", "boolean")]),
    ("unsafe", fieldSpec
      [("kind", "string"), ("function", "string")]
      [("has_unsafe_cap", "boolean"), ("has_raw_pointers", "boolean"),
       ("is_trusted", "boolean"), ("trust_boundary", "string[]"),
       ("is_extern", "boolean")]),
    ("alloc", fieldSpec
      [("kind", "string"), ("function", "string"), ("allocates", "string[]"),
       ("frees", "string[]"), ("defers", "string[]"), ("returns_allocation", "boolean"),
       ("potential_leak", "boolean")]
      []),
    ("contract", fieldSpec
      [("kind", "string"), ("function", "string"),
       ("requires", "string — ∧-joined precondition clauses"),
       ("ensures", "string — ∧-joined postcondition clauses"),
       ("invariants", "string — ∧-joined loop-invariant clauses")]
      [])
  ]
  let querySchemas := Val.obj [
    ("why-capability", .obj [
      ("format", .str "why-capability:FUNCTION:CAPABILITY"),
      ("response", .str "query_answer with answer, trace")]),
    ("predictable", .obj [
      ("format", .str "predictable:FUNCTION"),
      ("response", .str "query_answer with answer, gates_failed, violations")]),
    ("proof", .obj [
      ("format", .str "proof:FUNCTION"),
      ("response", .str "query_answer with answer, current_fingerprint")]),
    ("evidence", .obj [
      ("format", .str "evidence:FUNCTION"),
      ("response", .str "query_answer with answer, is_trusted, passes_predictable, proof_state")]),
    ("audit", .obj [
      ("format", .str "audit:FUNCTION"),
      ("response", .str "query_answer with authority, predictable, proof, allocation")]),
    ("fn", .obj [
      ("format", .str "fn:FUNCTION"),
      ("response", .str "facts envelope — all facts for one function")]),
    ("traceability", .obj [
      ("format", .str "traceability[:FUNCTION]"),
      ("response", .str "facts envelope — traceability facts, optionally filtered")])
  ]
  let schema := Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("fact_kinds", .arr (knownFactKinds.map .str)),
    ("query_kinds", .arr (knownQueryKinds.map .str)),
    ("location_encoding", loc),
    ("fact_schemas", factSchemas),
    ("query_schemas", querySchemas),
    ("envelopes", .obj [
      ("facts", .obj [
        ("description", .str "Wraps fact arrays from diagnostics-json and fact-filter queries"),
        ("fields", .obj [
          ("schema_version", .str "number"),
          ("schema_kind", .str "\"facts\""),
          ("fact_kinds", .str "string[] — canonical list of known fact kinds"),
          ("fact_count", .str "number"),
          ("facts", .str "object[] — the fact objects")])]),
      ("query_answer", .obj [
        ("description", .str "Wraps semantic query responses"),
        ("fields", .obj [
          ("schema_version", .str "number"),
          ("kind", .str "\"query_answer\""),
          ("query", .str "string — the original query string"),
          ("function", .str "string — qualified function name"),
          ("answer", .str "string — query-specific answer value")])]),
      ("snapshot", .obj [
        ("description", .str "Full snapshot with metadata, summary, and facts"),
        ("fields", .obj [
          ("schema_version", .str "number"),
          ("version", .str "number — snapshot format version"),
          ("source", .str "string"),
          ("timestamp", .str "string"),
          ("fact_count", .str "number"),
          ("summary", .str "object"),
          ("facts", .str "object[]")])]),
      ("vcs", .obj [
        ("description", .str "Verification-condition schedule from --report vcs --json (schema v1). A VC describes an obligation and the backend that SHOULD discharge it; it does not itself run a solver."),
        ("fields", .obj [
          ("schema_version", .str "number"),
          ("schema_kind", .str "\"vcs\""),
          ("vc_schema_version", .str "number — VC schema version (currently 1)"),
          ("count", .str "number"),
          ("vcs", .str "object[] — each: id, kind, function, loc{file,line}, hypotheses[], conclusion, origin, dependencies[], arith_profile, expected_discharge, status, engine, counterexample{var:value}. status ∈ {planned, proved_by_kernel_decision, proved_by_lean, arithmetic_proved, counterexample, unproven, missing} plus the OPT-IN external-solver classes {solver_trusted, unknown, timeout, solver_error} and the replay class proved_by_lean_replay (a Lean/kernel class — set only when a kernel tactic independently closes the replay theorem, dropping the solver from the claim); engine ∈ {constant_fold, omega, bv_decide, lean, lean:omega, smt:<solver>, \"\"}. counterexample maps SOURCE variable names to concrete values, populated only on a `sat` solver result. smt (null unless the VC was SMT-routed) carries determinism/replay provenance: {logic, timeout_sec, smtlib_sha (stable digest of the exact query), solver (name+version), query (the SMT-LIB script), replay, lean_replay{theorem, proof_attempt, check_command, note}}. A decision procedure can only yield proved_by_kernel_decision; an external solver (behind --smt) yields solver_trusted/counterexample/unknown/timeout/solver_error and only ever on a VC the kernel tiers left unproven — the classes never merge.")])])
    ]),
    ("policies", .obj [
      ("empty_result", .str "A query that matches zero facts returns a facts envelope with an empty facts array and fact_count 0. Semantic queries for unknown functions return a query_answer with answer \"not_found\". Neither case is an error."),
      ("error_result", .str "Malformed or unknown queries return an error string on stderr and exit code 1. Errors are never encoded in JSON — they use plain text on stderr."),
      ("function_names", .str "All function fields use qualified names (e.g. \"main.parse_byte\"). Queries accept either bare or qualified names."),
      ("compatibility", .str "Adding new optional fields or new fact kinds is backwards-compatible and does not bump schema_version. Removing fields, changing field types, renaming fields, or changing required/optional status bumps schema_version. Consumers should ignore unknown fields and unknown fact kinds for forward-compatibility.")
    ])
  ]
  schema.render

open Json in
/-- Produce a machine-readable listing of all stable diagnostic error codes. -/
def diagnosticCodesReport : String :=
  -- A code with a whole-code rule (`codeRuleTag`, docs/spec) names it, like `entryR` below.
  let entry (code pass severity description : String) : Val :=
    let rules := match codeRuleTag code with
      | some r => r
      | none => ", ".intercalate (codeSharedRules code)
    if rules.isEmpty then
      .obj [("code", .str code), ("pass", .str pass), ("severity", .str severity), ("description", .str description)]
    else
      .obj [("code", .str code), ("pass", .str pass), ("severity", .str severity),
            ("description", .str description), ("rules", .str rules)]
  -- A code that enforces exit 2i rules names them with their versions (MEMORY_SEMANTICS §15.5
  -- item 1); `scripts/tests/check_rules_2i.sh` checks every manifest row's tag against this.
  let entryR (code pass severity description rules : String) : Val :=
    .obj [("code", .str code), ("pass", .str pass), ("severity", .str severity), ("description", .str description),
          ("rules", .str rules)]
  let codes : List Val := [
    -- Parse (E0001)
    entry "E0001" "parse" "error" "syntax error",
    -- Resolve (E0100–E0111)
    entry "E0100" "resolve" "error" "undeclared variable",
    entry "E0101" "resolve" "error" "unknown function",
    entry "E0102" "resolve" "error" "unknown struct type",
    entry "E0103" "resolve" "error" "unknown enum variant",
    entry "E0104" "resolve" "error" "not an enum",
    entry "E0105" "resolve" "error" "unknown enum",
    entry "E0106" "resolve" "error" "unknown static method",
    entry "E0107" "resolve" "error" "unknown function reference",
    entry "E0108" "resolve" "error" "unknown type",
    entry "E0109" "resolve" "error" "Self outside impl block",
    entry "E0110" "resolve" "error" "unknown module",
    entry "E0111" "resolve" "error" "symbol not public in module",
    entry "E0112" "resolve" "error" "recursive type alias",
    entry "E0113" "resolve" "error" "wrong number of type arguments",
    entry "E0114" "resolve" "error" "capability argument of the wrong kind",
    entry "E0115" "resolve" "error" "wrong number of capability arguments",
    entry "E0116" "resolve" "error" "foreign binding does not declare its effects",
    entry "E0117" "resolve" "error" "known effectful C symbol declared with()",
    entry "E0118" "resolve" "error" "invalid #[link_name]",
    entry "E0119" "resolve" "error" "invalid #[export_name]",
    entry "E0120" "resolve" "error" "import alias names an intrinsic",
    entry "E0121" "resolve" "error" "capability parameter spelled like a capability (bug 188)",
    entry "E0122" "resolve" "error" "a `mod X;` module file not found (bug 206)",
    entry "E0123" "resolve" "error" "a module file loaded twice (a `mod` cycle or two declarations; bug 206)",
    entry "E0124" "resolve" "error" "a module file holds other than one module (bug 206)",
    entry "E0125" "resolve" "error" "unknown trait in a bound (bug 231)",
    entry "E0126" "resolve" "error" "import of a public trait, which no import binds (traits are module-local; bug 233)",
    -- Check: name/variable/linearity (E0200–E0219)
    entry "E0200" "check" "error" "Self outside impl block",
    entry "E0201" "check" "error" "undeclared variable",
    entry "E0202" "check" "error" "assignment to undeclared variable",
    entryR "E0203" "check" "error" "variable frozen by borrow" "REF-8@1",
    entryR "E0204" "check" "error" "cannot move linear variable: borrowed" "REF-8@1",
    entry "E0205" "check" "error" "linear variable used after move",
    entry "E0206" "check" "error" "variable reserved or borrowed by a pending defer",
    entry "E0207" "check" "error" "cannot consume linear variable in loop",
    entry "E0208" "check" "error" "linear variable never consumed",
    entry "E0209" "check" "error" "match arms disagree on consumption",
    entry "E0210" "check" "error" "break skips unconsumed linear variable",
    entry "E0211" "check" "error" "continue skips unconsumed linear variable",
    entry "E0212" "check" "error" "linear consumed in one branch not other",
    entry "E0213" "check" "error" "linear consumed in then-branch (no else)",
    entryR "E0214" "check" "error" "borrow ref shadows existing name (no longer emitted: subsumed by E0301, exit 2i)" "SCOPE-1@1",
    entryR "E0215" "check" "error" "borrow region shadows existing name (no longer emitted: subsumed by E0301, exit 2i)" "SCOPE-1@1",
    entry "E0216" "check" "error" "unknown loop label",
    entry "E0217" "check" "error" "assignment to immutable variable",
    entry "E0218" "check" "error" "assignment to frozen variable",
    entry "E0219" "check" "error" "reassignment of linear variable",
    -- Check: type mismatch (E0220–E0229)
    entry "E0220" "check" "error" "type mismatch",
    entry "E0221" "check" "error" "dereference of non-reference type",
    entry "E0222" "check" "error" "while break/else type mismatch",
    entry "E0223" "check" "error" "condition of if / while / for not Bool",
    entry "E0224" "check" "error" "if branch type mismatch",
    entry "E0225" "check" "error" "match arm type mismatch",
    entry "E0226" "check" "error" "break value type mismatch",
    entry "E0227" "check" "error" "integer literal out of range",
    entry "E0228" "check" "error" "binary operand type mismatch",
    entry "E0229" "check" "error" "comparison not defined on this type (integers, floats, bool, char; raw pointers in Unsafe code; bugs 134/140)",
    -- Check: borrow/escape (E0230–E0235)
    entry "E0230" "check" "error" "cannot borrow: already moved",
    entryR "E0231" "check" "error" "cannot borrow: already mutably borrowed" "REF-8@1",
    entryR "E0232" "check" "error" "cannot mutably borrow: already borrowed" "REF-8@1",
    entry "E0233" "check" "error" "cannot mutably borrow immutable variable",
    entryR "E0234" "check" "error" "reference escapes borrow block" "REF-6@1",
    entry "E0235" "check" "error" "cannot mutably borrow: already immutably borrowed",
    entryR "E0239" "check" "error" "a reference stored in an aggregate (struct/enum field, array, Heap, generic argument; bug 092)" "REF-3@1, REF-4@1",
    entry "E0237" "check" "error" "mutable borrow (explicit or `&mut self` receiver) through a shared reference",
    entryR "E0238" "check" "error" "place or reference source that does not normalize to a traceable place" "REF-4@1, REF-5@1, REF-6@1, REF-7@1, REF-8@1",
    -- Check: capability (E0240–E0242)
    entry "E0240" "check" "error" "missing capability",
    entry "E0241" "check" "error" "trait bound not satisfied",
    entry "E0242" "check" "error" "cannot infer capability variable",
    entry "E0243" "check" "error" "proof-only statement (assert, assume, ghost let) moves a runtime value (bug 147)",
    entry "E0244" "check" "error" "right operand of && or || moves a value it may never run to move (bug 148)",
    entry "E0245" "check" "error" "break or continue in a for step targets that loop (bug 330)",
    -- Check: struct/enum/function (E0250–E0277)
    entry "E0250" "check" "error" "unknown struct type",
    entry "E0251" "check" "error" "struct has no field",
    entry "E0252" "check" "error" "missing field in literal",
    entry "E0253" "check" "error" "unknown field in literal",
    entry "E0254" "check" "error" "field access on non-struct",
    entry "E0255" "check" "error" "heap access required",
    entry "E0256" "check" "error" "arrow access on non-heap type",
    entry "E0257" "check" "error" "arrow access on non-struct inner type",
    entry "E0258" "check" "error" "arrow assign on non-heap type",
    entry "E0259" "check" "error" "arrow assign on non-struct",
    entry "E0260" "check" "error" "unknown variant",
    entry "E0261" "check" "error" "unknown enum type",
    entry "E0262" "check" "error" "wrong argument count",
    entry "E0263" "check" "error" "undeclared function",
    entry "E0264" "check" "error" "no method on type",
    entry "E0265" "check" "error" "no method on type variable",
    entry "E0266" "check" "error" "method call on non-named type",
    entry "E0267" "check" "error" "unknown function reference",
    entry "E0268" "check" "error" "builtin wrong argument count",
    entry "E0269" "check" "error" "builtin wrong type argument count",
    entry "E0270" "check" "error" "builtin wrong first argument type",
    entry "E0271" "check" "error" "builtin bad key type",
    entry "E0272" "check" "error" "destroy requires named type",
    entry "E0273" "check" "error" "type does not implement Destroy",
    entry "E0274" "check" "error" "free requires Heap type",
    -- Retired with postfix `?`; codes stay reserved and are never reassigned.
    entry "E0275" "retired" "error" "former ? operator required Result type",
    entry "E0276" "retired" "error" "former ? operator required Ok/Err variants",
    entry "E0277" "retired" "error" "former ? operator required an Ok value field",
    entry "E0278" "check" "error" "return/break/continue inside a call argument, literal element or operator operand (bug 142)",
    entry "E0279" "check" "error" "deferred call argument is not a local, a borrow of a local, or a constant (bug 143)",
    -- Check: control flow (E0280–E0285)
    entry "E0280" "check" "error" "break outside loop",
    entry "E0281" "check" "error" "continue outside loop",
    entry "E0282" "check" "error" "defer body must be a function call",
    entry "E0283" "check" "error" "reserved identifier",
    entry "E0284" "check" "error" "unknown module",
    entry "E0285" "check" "error" "symbol not public in module",
    entry "E0323" "check" "error" "import of a public trait, which no import binds (traits are module-local; bug 233)",
    -- Check: discard/linearity one-law (E0286–E0289, Phase 6 #13 + H6)
    entry "E0286" "check" "error" "fallible result discarded (must use)",
    entry "E0287" "check" "error" "non-Copy value discarded without consumption",
    entry "E0288" "check" "error" "wildcard would discard a non-Copy value",
    entry "E0289" "check" "error" "let _ removed (wildcard is not a discard)",
    -- Check: conservation sweep + callable values (E0290–E0293, 2026-07-05/06)
    entry "E0290" "check" "error" "non-Copy sub-place read by value (would duplicate)",
    entry "E0291" "check" "error" "non-Copy overwrite would leak the old value",
    entryR "E0292" "check" "error" "shadowing a still-live non-Copy binding (no longer emitted: subsumed by E0301, R-0492)" "SCOPE-1@1",
    entryR "E0293" "check" "error" "overlapping borrows of one root in a single call" "REF-8@1, REF-11@3",
    entry "E0294" "check" "error" "pure value computed then discarded (dead computation)",
    entry "E0295" "check" "error" "discard() of a non-Copy value (use destroy or consume it)",
    entry "E0296" "check" "error" "newtype constructed outside its defining module (construction rights, 0b)",
    entry "E0297" "check" "error" "struct literal touches a field private to its defining module (0b)",
    entry "E0298" "check" "error" "read/write of a struct field private to its defining module (0b)",
    entry "E0300" "check" "error" "a match guard moves a non-Copy value (guards are read-only; bug 090)",
    entryR "E0301" "check" "error" "a binding reuses the name of a visible local binding (one lexical name, one binding; exit 2i)" "SCOPE-1@1",
    entryR "E0302" "check" "error" "a `let` binding holds a reference (references are scoped; exit 2i)" "REF-6@1",
    entryR "E0303" "check" "error" "a reference binding is assigned (references are never re-pointed; exit 2i)" "REF-6@1",
    entryR "E0305" "check" "error" "a contract expression binds a name (contracts are binder-free propositions; exit 2i)" "SCOPE-1@1",
    entryR "E0236" "check" "error" "a function, function type or instantiation returns a reference (front end and post-mono)" "REF-1@1, REF-2@1, REF-4@1",
    entry "E0304" "check" "error" "a labeled pattern field list does not match the variant or struct (unknown, repeated or missing field; exit 2i G4)",
    entry "E0299" "check" "error" "a module binds one name twice (two declarations, an import vs a local definition, or two imports)",
    entry "E0307" "check" "error" "the end of a function with a result type is reachable without a return (bug 194)",
    entry "E0308" "check" "error" "the else block of a let ... else can fall through (bug 195)",
    entry "E0309" "check" "error" "a match arm's pattern does not fit the scrutinee's type (bug 196)",
    entry "E0306" "check" "error" "a struct or enum literal gives a field more than once (bug 193)",
    entry "E0310" "check" "error" "`main` declares parameters (the entry point is `fn main() -> Int`; arguments come from std.args; bug 111)",
    entry "E0311" "check" "error" "`*p` moves a non-Copy value out of raw memory (use the `read_owned` intrinsic; T-RAWDUP)",
    entry "E0312" "check" "error" "internal: a declaration or binder reached the checker without its local binder table (R-0492; bug 206)",
    entry "E0313" "check" "error" "newtype constructor called with other than one argument or with type arguments (bug 206)",
    entry "E0314" "check" "error" "wrapping_/saturating_ operation on non-integer operands or operands of different types (bug 206)",
    entry "E0315" "check" "error" "builtin called with fewer arguments than its minimum (print, println, append; bug 206)",
    entry "E0316" "check" "error" "newtype field access other than .0 (bug 206)",
    entry "E0317" "check" "error" "trait method without a self receiver called as a method (bug 206)",
    entry "E0318" "check" "error" "enum destructuring let in a for header (bug 206)",
    entry "E0319" "check" "error" "#[test] function with parameters, type parameters or a result other than i32 (bug 206)",
    entry "E0320" "check" "error" "contract clause or spec function body of the wrong sort (bug 206)",
    entry "E0321" "check" "error" "contract or spec function body calls a non-spec or capability-requiring function (bug 206)",
    entry "E0322" "check" "error" "an explicit type-argument list at a call does not match the callee's type parameters (bug 221)",
    -- Elab (E0400–E0419)
    entry "E0400" "elab" "error" "Self outside impl block",
    entry "E0401" "elab" "error" "undeclared variable",
    entry "E0402" "elab" "error" "undeclared function",
    entry "E0403" "elab" "error" "unknown function reference",
    entry "E0404" "elab" "error" "assignment to undeclared variable",
    entry "E0405" "elab" "error" "borrow of undeclared variable",
    entry "E0406" "elab" "error" "unknown struct type",
    entry "E0407" "elab" "error" "arrow access on unknown struct",
    entry "E0408" "elab" "error" "struct has no field",
    entry "E0409" "elab" "error" "field access on non-struct",
    entry "E0410" "elab" "error" "unknown enum type",
    entry "E0411" "elab" "error" "unknown variant",
    entry "E0412" "elab" "error" "missing field in variant",
    entry "E0413" "elab" "error" "no method on type variable",
    entry "E0414" "elab" "error" "no method on type",
    entry "E0415" "elab" "error" "method call on non-named type",
    entry "E0416" "elab" "error" "empty array literal",
    entry "E0417" "elab" "error" "submodule elaboration error",
    entry "E0418" "elab" "error" "unknown module",
    entry "E0419" "elab" "error" "symbol not public in module",
    entry "E0423" "elab" "error" "import of a public trait, which no import binds (traits are module-local; bug 233)",
    entry "E0421" "check" "error" "append() or print() argument of an unsupported type (bug 203; it had no code in Check and E0420 in Elab)",
    entry "E0420" "elab" "error" "ghost value used in runtime code",
    entry "E0422" "elab" "error" "internal: a binding-identity invariant failed at elaboration: a binder or function reached elaboration without its local binder table, or ElabVerify found Core whose binding identities and names disagree (R-0492 steps 2 and 3)",
    -- Core-check: type consistency (E0500–E0509)
    entry "E0500" "core-check" "error" "variable type mismatch",
    entry "E0501" "core-check" "error" "arithmetic on non-numeric type",
    entry "E0502" "core-check" "error" "binary operand type mismatch",
    entry "E0503" "core-check" "error" "comparison operand type mismatch",
    entry "E0504" "core-check" "error" "comparison result not Bool",
    entry "E0505" "core-check" "error" "logical operator on non-Bool",
    entry "E0506" "core-check" "error" "bitwise operator on non-integer",
    entry "E0507" "core-check" "error" "negation on non-numeric type",
    entry "E0508" "core-check" "error" "logical not on non-Bool",
    entry "E0509" "core-check" "error" "bitwise not on non-integer",
    -- Core-check: binder agreement (bug 177)
    entry "E0510" "core-check" "error" "binding type mismatch (let, assignment, argument, field or store)",
    -- Core-check: capability (E0520–E0522)
    entry "E0520" "core-check" "error" "insufficient capabilities",
    entry "E0521" "core-check" "error" "missing capability",
    entry "E0522" "core-check" "error" "argument count mismatch",
    -- Core-check: match coverage (E0530–E0534)
    entry "E0530" "core-check" "error" "non-exhaustive match: missing variant",
    entry "E0531" "core-check" "error" "match arm wrong enum",
    entry "E0532" "core-check" "error" "duplicate match arm",
    entry "E0533" "core-check" "error" "variant field count mismatch",
    entry "E0534" "core-check" "error" "non-enum match without default arm",
    -- Core-check: control flow (E0540–E0543)
    entry "E0540" "core-check" "error" "while condition not Bool",
    entry "E0541" "core-check" "error" "if condition not Bool",
    entry "E0542" "core-check" "error" "break outside loop",
    entry "E0543" "core-check" "error" "continue outside loop",
    -- Core-check: type legality (E0550–E0560)
    entry "E0550" "core-check" "error" "empty array literal",
    entry "E0551" "core-check" "error" "array index not integer",
    entry "E0552" "core-check" "error" "indexing non-array type",
    entry "E0553" "core-check" "error" "cannot cast between types",
    entry "E0554" "core-check" "error" "dereference of non-reference type",
    entry "E0555" "core-check" "error" "assign through a target that is not `&mut T` or `*mut T`",
    entry "E0560" "core-check" "error" "return type mismatch",
    -- Core-check: module validation (E0570–E0582)
    entry "E0570" "core-check" "error" "Copy/Destroy conflict",
    entry "E0571" "core-check" "error" "Copy struct has non-Copy field",
    entry "E0572" "core-check" "error" "repr(C) struct has generics",
    entry "E0573" "core-check" "error" "repr(C) field not FFI-safe",
    entryR "E0574" "core-check" "error" "extern fn parameter not FFI-safe (a type containing a reference is FFI-3)" "FFI-3@1",
    entryR "E0575" "core-check" "error" "extern fn return not FFI-safe (a type containing a reference is FFI-3)" "FFI-3@1",
    entry "E0576" "core-check" "error" "repr(packed) and repr(align) conflict",
    entry "E0577" "core-check" "error" "repr(align) not power of two",
    entry "E0578" "core-check" "error" "reserved function name",
    entry "E0579" "core-check" "error" "builtin trait redeclared",
    entry "E0580" "core-check" "error" "unknown trait",
    entry "E0581" "core-check" "error" "missing trait method",
    entry "E0582" "core-check" "error" "trait method return type mismatch",
    entry "E0583" "core-check" "error" "recursive type has infinite size",
    entry "E0584" "core-check" "error" "Destroy impl requires capabilities beyond Alloc (v1 drop-glue restriction)",
    entry "E0585" "core-check" "error" "repr(align) exceeds natural alignment (over-aligned structs not yet supported in codegen)",
    entry "E0586" "core-check" "error" "trait impl method requires capabilities beyond its trait method's declared set",
    entry "E0587" "core-check" "error" "trait impl method signature (receiver, parameters, generics) does not match its trait method",
    entry "E0588" "elab" "error" "extern fn taken as a value (bug 166)",
    -- Check: trait coherence (bug 186; docs/spec/traits.md TRAIT-1 … TRAIT-6)
    entry "E0590" "check" "error" "duplicate impl: a trait implemented twice for one type (TRAIT-1)",
    entry "E0591" "check" "error" "overlapping impls: two impls of one trait whose targets unify (TRAIT-2)",
    entry "E0592" "check" "error" "orphan impl: the module defines neither the trait nor the type (TRAIT-3)",
    entry "E0593" "check" "error" "impl target is not its type applied to exactly the impl's own parameters (specialized, blanket, alias or arity; TRAIT-4)",
    entry "E0594" "check" "error" "one method name provided by two impls of the same type (TRAIT-5)",
    entry "E0595" "check" "error" "method call through type-parameter bounds is ambiguous: several bound traits declare it (TRAIT-6)",
    -- Verify/lower (E0600–E0602)
    entry "E0600" "verify" "error" "post-elab: placeholder type survived elaboration",
    entry "E0601" "verify" "error" "post-mono: type variable survived monomorphization",
    entry "E0602" "lower" "error" "lowering failure",
    -- Policy (E0610–E0612)
    entry "E0610" "policy" "error" "predictable profile violation",
    entry "E0611" "policy" "error" "denied capability used",
    entry "E0612" "policy" "error" "proof-eligible function unproved",
    -- SSA-verify (E0700–E0715)
    entry "E0700" "ssa-verify" "error" "duplicate register definition",
    entry "E0701" "ssa-verify" "error" "function has no blocks",
    entry "E0702" "ssa-verify" "error" "use before definition",
    entry "E0703" "ssa-verify" "error" "use in non-dominating block",
    entry "E0704" "ssa-verify" "error" "undefined register",
    entry "E0705" "ssa-verify" "error" "branch to unknown label",
    entry "E0706" "ssa-verify" "error" "phi missing predecessor",
    entry "E0707" "ssa-verify" "error" "phi extra predecessor",
    entry "E0708" "ssa-verify" "error" "phi not dominated by source",
    entry "E0709" "ssa-verify" "error" "phi uses undefined register",
    entry "E0710" "ssa-verify" "error" "phi type mismatch",
    entry "E0711" "ssa-verify" "error" "call arity mismatch",
    entry "E0712" "ssa-verify" "error" "ret void in non-void function",
    entry "E0713" "ssa-verify" "error" "ret value in void function",
    entry "E0714" "ssa-verify" "error" "phi on aggregate type",
    entry "E0715" "ssa-verify" "error" "binop operand type mismatch",
    -- Proof diagnostics (E0800–E0807)
    entry "E0800" "proof" "error" "stale proof: fingerprint changed",
    entry "E0801" "proof" "warning" "missing proof: eligible but unproved",
    entry "E0802" "proof" "info" "ineligible: fails profile gates",
    entry "E0803" "proof" "error" "blocked: unsupported construct in extraction",
    entry "E0804" "proof" "info" "trusted: marked trusted",
    entry "E0805" "proof" "error" "attachment integrity: registry entry is invalid",
    entry "E0806" "proof" "warning" "theorem lookup: Lean proof name not found",
    entry "E0807" "proof" "error" "lean check failure: Lean kernel rejected proof",
    entry "E0808" "mono" "error" "user-defined generic enum reached codegen un-monomorphized — would corrupt memory; rejected fail-closed (bug 051)",
    entry "E0809" "mono" "error" "a monomorphized specialization's name is already declared in the program — one name cannot carry two layouts (R-0001)",
    entry "E0810" "proof" "error" "proof link unbound: no stored proof-subject digest, so freshness cannot be checked and the claim is not proved (R-0004, bug 058)"
  ]
  (Val.obj [
    ("schema_version", .num (Int.ofNat schemaVersion)),
    ("code_count", .num (Int.ofNat codes.length)),
    ("codes", .arr codes),
    ("severity_meanings", .obj [
      ("error", .str "blocks compilation or proof pipeline"),
      ("warning", .str "needs attention but allows continuation"),
      ("info", .str "informational, no action required"),
      ("note", .str "additional context for another diagnostic")
    ]),
    ("compatibility", .str "Error codes are stable identifiers. A code will not be reassigned to a different meaning. New codes may be added. Codes may be retired (no longer emitted) but not reused. Consumers should tolerate unknown codes.")
  ]).render


end Report
end Concrete
