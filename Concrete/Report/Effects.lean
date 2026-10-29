import Concrete.Elab.Core
import Concrete.Check.Layout
import Concrete.Resolve.FileSummary
import Concrete.Frontend.AST
import Concrete.Resolve.Intrinsic
import Concrete.Proof.IdentityUseBytes
import Concrete.Proof.Proof
import Concrete.Proof.ProofCore
import Concrete.IR.SSA
import Concrete.Backend.Symbols
import Concrete.Report.Diagnostic
import Concrete.Frontend.Format
import Concrete.Report.Json
import Concrete.Report.ReportBase
import Concrete.Report.ReportInterface
import Concrete.Report.ReportObligations
import Concrete.Report.Evidence

/-! Capability, allocation, stack-depth and predictable-profile reports (--report alloc, authority, proof, effects, stack-depth; --check predictable). Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report


-- Report 5: Monomorphization Report (--report mono)
-- ============================================================

private partial def collectSubFnNames (m : CModule) : List String :=
  m.submodules.foldl (fun acc sub =>
    acc ++ sub.functions.map (·.name) ++ collectSubFnNames sub) []

private def collectFnNames (modules : List CModule) : List String :=
  modules.foldl (fun acc m =>
    acc ++ m.functions.map (·.name) ++ collectSubFnNames m) []

/-- The first module named `n`, and the list without it. -/
def takeNamesake (n : String) : List CModule → Option (CModule × List CModule)
  | [] => none
  | m :: ms => if m.name == n then some (m, ms)
    else (takeNamesake n ms).map fun (t, rest) => (t, m :: rest)

/-- The part of a monomorphized program that corresponds to a listing scope: for each scope module,
    its namesake in `mono` at the same level, keeping that module's functions (originals and the
    specializations Mono placed there) only when the scope module itself lists functions, and
    descending into the scope's submodules alone. A scope wrapper (`scopeUserModulesToFile`'s empty
    parent) therefore contributes only its matched children. With the whole program as scope this
    is `mono` itself, up to module order (bug 180: the mono report runs Mono on the validated whole
    program and restricts the listing, instead of running Mono on the scope). -/
partial def restrictMonoToScope (scope mono : List CModule) : List CModule :=
  -- Match by OCCURRENCE, in order: a scope module takes the first not-yet-taken namesake, so two
  -- sibling modules of one name map to their own counterparts (Mono keeps module order).
  let step (acc : List CModule × List CModule) (sm : CModule) : List CModule × List CModule :=
    let (out, rest) := acc
    match takeNamesake sm.name rest with
    | none => (out, rest)
    | some (tm, rest') =>
      let kept := { tm with functions := if sm.functions.isEmpty then [] else tm.functions,
                            submodules := restrictMonoToScope sm.submodules tm.submodules }
      (out ++ [kept], rest')
  (scope.foldl step ([], mono)).1

/-- Count generic functions across all modules including submodules. -/
private partial def countGenericFns (m : CModule) : Nat :=
  let local_ := (m.functions.filter fun f => !f.typeParams.isEmpty).length
  local_ + m.submodules.foldl (fun acc sub => acc + countGenericFns sub) 0

/-- Count all functions across module tree. -/
private partial def countAllFns (m : CModule) : Nat :=
  m.functions.length + m.submodules.foldl (fun acc sub => acc + countAllFns sub) 0

def monoReport (preMono postMono : List CModule) : String :=
  let header := "=== Monomorphization Report ==="
  let preNames := collectFnNames preMono
  let postNames := collectFnNames postMono
  let specializations := postNames.filter fun n =>
    (n.splitOn "_for_").length > 1 && !preNames.contains n
  let genericCount := preMono.foldl (fun acc m => acc + countGenericFns m) 0
  let preFnCount := preMono.foldl (fun acc m => acc + countAllFns m) 0
  let postFnCount := postMono.foldl (fun acc m => acc + countAllFns m) 0
  let statsLines := [
    s!"Functions before mono: {preFnCount}",
    s!"Functions after mono:  {postFnCount}",
    s!"Generic functions:     {genericCount}",
    s!"Specializations:       {specializations.length}"
  ]
  let specLines := if specializations.isEmpty then []
    else ["", "Specializations:"] ++ specializations.map fun n =>
      let parts := n.splitOn "_for_"
      match parts with
      | [base, suffix] =>
        let typeArgs := suffix.splitOn "_"
        s!"  {base}<{", ".intercalate typeArgs}> -> {n}"
      | _ => s!"  {n}"
  let body := statsLines ++ specLines
  s!"{header}\n\n{"\n".intercalate body}\n"

-- ============================================================
-- Report 6: Allocation/Cleanup Summary (--report alloc)
-- ============================================================


/-- Analyze allocation patterns in a single function. -/
private def analyzeFnAlloc (f : CFnDef) : Option String :=
  let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
  let allocs := callees.filter isAllocCall
  let frees := cleanupCallsStmts f.body
  let defers := collectDefersStmts f.body
  -- Skip functions with no allocation activity
  if allocs.isEmpty && frees.isEmpty && defers.isEmpty then none
  else
    let lines : List String := [s!"  fn {f.name}:"]
    let lines := if allocs.isEmpty then lines
      else lines ++ [s!"    allocates: {", ".intercalate allocs}"]
    let lines := if frees.isEmpty then lines
      else lines ++ [s!"    frees: {", ".intercalate frees}"]
    let lines := if defers.isEmpty then lines
      else lines ++ defers.map fun d => s!"    cleanup: {d}"
    -- Warn if allocates but no free or defer
    let lines := if !allocs.isEmpty && frees.isEmpty && defers.isEmpty then
      if returnsAllocation f.retTy then
        lines ++ [s!"    note: allocates and returns — caller responsible for cleanup"]
      else
        lines ++ [s!"    WARNING: allocates but has no matching free/defer"]
    else lines
    some ("\n".intercalate lines)

private partial def allocReportModule (m : CModule) (indent : String) : Option String :=
  let fnReports := m.functions.filterMap analyzeFnAlloc
  let subReports := m.submodules.filterMap (allocReportModule · (indent ++ "  "))
  if fnReports.isEmpty && subReports.isEmpty then none
  else
    let header := s!"{indent}module {m.name}:"
    let body := fnReports ++ subReports
    some (s!"{header}\n{"\n".intercalate body}")

/-- Count allocation-related functions across module tree. -/
private partial def allocCounts (m : CModule) : Nat × Nat × Nat :=
  let fnResults := m.functions.map fun f =>
    let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
    let allocs := callees.filter isAllocCall
    let frees := cleanupCallsStmts f.body
    let defers := collectDefersStmts f.body
    (allocs.isEmpty, frees.isEmpty, defers.isEmpty)
  let allocating := (fnResults.filter fun (a, _, _) => !a).length
  let freeing := (fnResults.filter fun (_, f, _) => !f).length
  let deferring := (fnResults.filter fun (_, _, d) => !d).length
  m.submodules.foldl (fun (a, f, d) sub =>
    let (a', f', d') := allocCounts sub
    (a + a', f + f', d + d')) (allocating, freeing, deferring)

def allocReport (modules : List CModule) : String :=
  let header := "=== Allocation/Cleanup Summary ==="
  let body := modules.filterMap (allocReportModule · "")
  let (allocCount, freeCount, deferCount) :=
    modules.foldl (fun (a, f, d) m =>
      let (a', f', d') := allocCounts m
      (a + a', f + f', d + d')) (0, 0, 0)
  if body.isEmpty then s!"{header}\n\nNo allocation activity found.\n"
  else
    let summary := s!"\nTotals: {allocCount} functions allocate, {freeCount} free, {deferCount} use defer"
    s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 7: Authority Budget (--report authority)
-- ============================================================
-- For each capability, show which functions require it and
-- compute the transitive call chain that introduces it.


/-- All function defs across modules (flat). -/
private partial def collectAllFnDefs (m : CModule) : List CFnDef :=
  m.functions ++ m.submodules.foldl (fun acc sub => acc ++ collectAllFnDefs sub) []

/-- Find one call chain from `fn` to any function that directly declares `cap`.
    Returns the chain as a list of function names, or empty if no chain found.
    Uses BFS with visited set to avoid cycles. -/
private def findCapChain (callGraph : CallGraph) (lookup : CapLookup)
    (fnName : String) (cap : String) (maxDepth : Nat := 20) : List String :=
  let rec bfs (queue : List (String × List String)) (visited : List String)
      (fuel : Nat) : List String :=
    match fuel, queue with
    | 0, _ => []
    | _, [] => []
    | fuel + 1, (current, path) :: rest =>
      -- Check if current function directly has this cap
      let directCaps := match lookup.find? (fun (n, _) => n == current) with
        | some (_, cs) => cs.concreteCaps
        | none =>
          match resolveIntrinsic current with
          | some iid => match iid.capability with
            | some c => [c]
            | none => []
          | none => []
      if directCaps.contains cap && path.length > 0 then
        path ++ [current]
      else
        let callees := match callGraph.find? (fun (n, _) => n == current) with
          | some (_, cs) => cs
          | none => []
        let newVisited := visited ++ [current]
        let newEntries := callees.filter (fun c => !visited.contains c) |>.map fun c =>
          (c, path ++ [current])
        bfs (rest ++ newEntries) newVisited fuel
  bfs [(fnName, [])] [] maxDepth

/-- Group functions by capability for the authority report. -/
private partial def collectFnsWithCap (m : CModule) (cap : String) : List CFnDef :=
  let matching := m.functions.filter fun f =>
    let (caps, _) := f.capSet.normalize
    caps.contains cap
  matching ++ m.submodules.foldl (fun acc sub => acc ++ collectFnsWithCap sub cap) []

def authorityReport (modules : List CModule) (assumptions : Assumptions.Table := {}) : String :=
  let header := "=== Authority Report ==="
  let idx := assumptions.programIndex (modules.map (·.name))
  let qualLookup := buildQualCapLookup modules
  let callGraph := buildCallGraph modules
  let bareToQual := modules.foldl (fun acc m => acc ++ buildBareToQualMap m) []
  let allCaps := validCaps  -- all 9 capabilities
  let sections := allCaps.filterMap fun cap =>
    let fns := modules.foldl (fun acc m => acc ++ collectFnsWithCap m cap) []
    if fns.isEmpty then none
    else
      let capHeader := s!"capability {cap} ({fns.length} functions):"
      let fnLines := fns.map fun f =>
        let pubStr := if f.isPublic then "pub " else "    "
        let qualName := match bareToQual.find? (fun (b, _) => b == f.name) with
          | some (_, q) => q | none => f.name
        let chain := findCapChain callGraph qualLookup qualName cap
        -- Display bare names in chain output for readability
        let bareChain := chain.map fun n =>
          match n.splitOn "." |>.getLast? with | some b => b | none => n
        -- No program chain supplies `cap`: name the DEPENDENCY callee that does, from the one
        -- supplier producer, before falling back to "declared" (R-0484 R10).
        let depSupply := if bareChain.length > 1 then [] else
          (capSuppliers (buildCapLookup modules) assumptions.depCallees f cap
            (modules.foldl (fun acc m => acc ++ allLinkerAliases m) [])).filter (·.kind == "dependency")
        let chainStr := if bareChain.length > 1 then s!"  <- {" -> ".intercalate bareChain}"
          else if depSupply.isEmpty then "  <- declared"
          else s!"  <- calls {", ".intercalate (depSupply.map (·.render))}"
        -- R10: the conclusion "this function exercises `cap`" rests on the foreign bindings that
        -- provide it, and on coverage; both are stated with it.
        let qual := match idx.get? qualName >>= assumptions.fns.get? with
          | some sm => s!"\n        {assumptions.qualifyCap sm cap}; {sm.coveragePhrase}"
          | none => if assumptions.fns.isEmpty then "\n        assumptions: not computed for this output" else ""
        s!"  {pubStr}{f.name}{chainStr}{qual}"
      some (s!"{capHeader}\n{"\n".intercalate fnLines}")
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let pureFns := (allFns.filter fun f => f.capSet.isEmpty).length
  let totalFns := allFns.length
  let externCount := modules.foldl (fun acc m => acc + countModuleExterns m) 0
  let summary := s!"\nTotals: {totalFns} functions ({pureFns} with no declared capability, {totalFns - pureFns} with capabilities), {externCount} externs"
  if sections.isEmpty then s!"{header}\n\nAll functions are pure — no capabilities required.\n"
  else s!"{header}\n\n{"\n\n".intercalate sections}\n{summary}\n"

-- ============================================================
-- Report 8: Proof Eligibility (--report proof)
-- ============================================================
-- Determines which functions could be extracted for ProofCore
-- (pure, no trusted, no extern calls, no raw pointer ops).

/-- Close a set of function names BACKWARDS over the call graph: every caller that can reach a
    member is added, to a fixpoint.

    Used for the two profile properties that are not backed by a capability. Alloc and the
    blocking caps are transitive for free — the compiler already refuses `E0520: requires Alloc
    but caller has (none)`, so a caller must declare the capability and the effects report sees
    it. FFI has no capability behind it, only a direct-callee check, so `f` calling `g` calling
    an extern reported `ffi: no` and `evidence: enforced` while transitively crossing FFI. This
    makes FFI agree with the two gates that were already transitive. -/
private partial def closeBackward (callGraph : CallGraph) (seed : List String) (fuel : Nat) :
    List String :=
  match fuel with
  | 0 => seed
  | fuel + 1 =>
    let more := callGraph.filterMap fun (n, cs) =>
      if !seed.contains n && cs.any (fun c => seed.contains c) then some n else none
    if more.isEmpty then seed else
      -- Both the qualified node name AND its final component. The call graph resolves callees
      -- to qualified names, but the effects report compares against RAW callee names, so a
      -- qualified-only set never matches there. Carrying the bare form can over-flag a
      -- same-named function in another module; that direction refuses a function rather than
      -- admitting one, which is the side to err on for a profile.
      let bare := more.map fun n => (n.splitOn ".").getLast!
      closeBackward callGraph (seed ++ (more ++ bare).eraseDups) fuel

/-- Functions that cannot be certified acyclic, closed over callers.

    "Predictable execution" is a property of RUNNING a function: if `f` calls `g`, running `f`
    runs `g`, so `f` can only be predictable if `g` is. The label was computed from `f`'s own
    body alone, so this was `enforced`:

        fn recurses(x: i32) -> i32 { if x <= 0 { return 0; } return recurses(x - 1); }
        fn caller(x: i32)   -> i32 { return recurses(x); }        -- enforced

    `caller` contains no recursion textually and unbounded recursion in practice.

    The other gates never had this problem, and not by design: alloc and the blocking caps are
    transitive because the COMPILER forces it (`E0520: requires Alloc but caller has (none)`), and
    FFI was closed over the call graph earlier. Recursion was the last gate detected by a graph
    walk rather than by types, and the only one still asking "is it written in your body?"
    instead of "can you reach it?".

    The seed includes bodies containing an INDIRECT call: with no edge for `f(x)` the callee set
    is unknown, so acyclicity is not established there either. -/
private def recursionUncertain (callGraph : CallGraph)
    (recMap : List (String × RecursionKind × List String))
    (indirectFns : List String) : List String :=
  let seed := (recMap.filterMap fun (n, k, _) =>
    match k with | .none => none | _ => some n) ++ indirectFns
  closeBackward callGraph seed.eraseDups (callGraph.length + 1)

/-- Qualified names of functions whose body contains an indirect call. -/
private partial def indirectCallFns (m : CModule) (pfx : String := "") : List String :=
  let qualPrefix := if pfx == "" then m.name else pfx ++ "." ++ m.name
  (m.functions.filterMap fun f =>
      if hasIndirectCallStmts f.body then some (qualPrefix ++ "." ++ f.sourceName) else none)
    ++ m.submodules.foldl (fun acc sub => acc ++ indirectCallFns sub qualPrefix) []

/-- The two transitively-closed sets every profile consumer needs, from one place.

    Returned together deliberately. When FFI was closed over the call graph, three of the six
    consumers kept passing the UNCLOSED set and stayed non-transitive — the same
    "one path updated, the rest silently not" defect this session keeps turning up, introduced
    by the fix for it. Computing both here means a consumer cannot obtain one without the
    other. -/
def profileClosures (modules : List CModule) (pc : Concrete.ProofCore) :
    List String × List String :=
  let indirect := modules.foldl (fun acc m => acc ++ indirectCallFns m) []
  ( closeBackward pc.callGraph pc.externNames (pc.callGraph.length + 1)
  , recursionUncertain pc.callGraph pc.recMap indirect )

/-- Reasons a function is excluded from ProofCore. -/
private def proofExclusionReasons (externNames : List String) (f : CFnDef) : List String :=
  let reasons : List String := []
  -- 1. Has capabilities
  let reasons := if !f.capSet.isEmpty then
    let (caps, _) := f.capSet.normalize
    reasons ++ [s!"requires capabilities: {", ".intercalate caps}"]
  else reasons
  -- 2. Is trusted
  let reasons := if f.isTrusted then reasons ++ ["trusted boundary"] else reasons
  -- 3. Calls extern functions
  -- Only a free call can reach a foreign binding (bugs 238 – 239).
  let externCalls := externCallsIn externNames f
  let reasons := if !externCalls.isEmpty then
    reasons ++ [s!"calls extern: {", ".intercalate externCalls}"]
  else reasons
  -- 4. Raw pointer operations
  let reasons := if hasRawPtrOpsStmts f.body then
    reasons ++ ["raw pointer operations"]
  else reasons
  reasons

private partial def proofReportModule (externNames : List String) (m : CModule) (indent : String)
    : String :=
  let header := s!"{indent}module {m.name}:"
  let fnLines := m.functions.map fun f =>
    let reasons := proofExclusionReasons externNames f
    if reasons.isEmpty then
      s!"{indent}  ✓ {f.name}"
    else
      let reasonStr := ", ".intercalate reasons
      s!"{indent}  ✗ {f.name}  ({reasonStr})"
  let subLines := m.submodules.map (proofReportModule externNames · (indent ++ "  "))
  let body := fnLines ++ subLines
  s!"{header}\n{"\n".intercalate body}"

def proofReport (modules : List CModule) (pc : Concrete.ProofCore) : String :=
  let header := "=== Proof Eligibility Report ==="
  let externNames := pc.externNames
  let body := modules.map (proofReportModule externNames · "")
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let eligible := allFns.filter fun f =>
    (proofExclusionReasons externNames f).isEmpty
  let excluded := allFns.length - eligible.length
  let summary := s!"\nTotals: {allFns.length} functions, {eligible.length} eligible for ProofCore, {excluded} excluded"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"


-- ============================================================
-- Report 10: Combined Effects Summary (--report effects)
-- ============================================================
-- Per-function view unifying: capabilities, allocation class,
-- recursion/cycle status, loop boundedness, crosses FFI, uses trusted.

/-- Per-function effects summary record. -/
structure FnEffects where
  name       : String         -- bare name for display
  qualName   : String         -- qualified name for facts (e.g. "main.parse_byte")
  capSet     : CapSet
  allocates  : Bool
  frees      : Bool
  defers     : Bool
  recursion  : String       -- "none", "direct", or "mutual: a, b, c"
  loops      : String       -- "no loops", "bounded", "unbounded", or "mixed"
  crossesFfi : Bool         -- calls any extern function
  isTrusted  : Bool
  isPublic   : Bool
  evidence   : String       -- "enforced", "reported", or "trusted-assumption"
  -- R-0484: can reach an indirect call, so an empty capability set is "nothing
  -- declared" rather than "nothing happens". Proof admission already refuses these;
  -- printing `(pure)` here would leave report and admission disagreeing.
  effectOpaque : Bool
  /-- From the assumption summary: no declared capability, complete coverage, no assumed binding. -/
  noExternalAuthority : Bool := false
  loc        : Option SourceLoc  -- structured (file, line), not pre-formatted

private def fmtEffectsRow (e : FnEffects) : String :=
  let pub := if e.isPublic then "pub " else "    "
  let caps := ppAuthority e.capSet e.effectOpaque e.noExternalAuthority
  let allocClass :=
    if e.allocates && e.defers then "alloc+defer"
    else if e.allocates && e.frees then "alloc+free"
    else if e.allocates then "alloc"
    else if e.frees then "free-only"
    else if e.defers then "defer-only"
    else "none"
  let trusted := if e.isTrusted then "yes" else "no"
  let ffi := if e.crossesFfi then "yes" else "no"
  let locSuffix := match e.loc with | some l => s!"  @ {fmtLoc (some l)}" | none => ""
  s!"  {pub}{e.name}\n    caps: {caps}  alloc: {allocClass}  recursion: {e.recursion}  loops: {e.loops}  ffi: {ffi}  trusted: {trusted}  evidence: {e.evidence}{locSuffix}"

partial def effectsForModule
    (opaqueSet : List String)
    (externNames : List String)
    (recUncertain : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : FnLocMap)
    (pc : Concrete.ProofCore)
    (m : CModule) (modulePath : String := "") : List FnEffects :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fns := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.sourceName
    let isEffectOpaque := opaqueSet.contains qualName
    let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
    let allocs := callees.filter isAllocCall
    let frees := cleanupCallsStmts f.body
    let defs := collectDefersStmts f.body
    let rec_ := match recMap.find? (fun (n, _, _) => n == qualName) with
      | some (_, .direct, _) => "direct"
      | some (_, .mutual, members) =>
        let others := members.filter (· != qualName)
        s!"mutual: {", ".intercalate others}"
      | _ => "none"
    -- Only a free call can reach a foreign binding directly (bugs 238 – 239); any call, a method
    -- call included, reaches one transitively, which the closure records for this function's
    -- qualified name over the namespace-aware call graph (Codex review r9).
    let crossesFfi := externNames.contains qualName
      || !(externCallsIn externNames f).isEmpty
    let loopClass := classifyLoops f.body
    -- Evidence level: enforced if passes all 5 predictable gates
    let (concreteCaps, _) := f.capSet.normalize
    -- An indirect call means the callee set is not statically known, so this function cannot
    -- be shown acyclic. Treated as recursion for admission purposes: the profile's claim is
    -- "no recursion", and "we could not tell" does not support it.
    let hasIndirect := hasIndirectCallStmts f.body
    -- Transitive: reaching a function that cannot be certified acyclic is enough.
    let hasRecursion := rec_ != "none" || hasIndirect || recUncertain.contains qualName
    let hasUnboundedLoops := loopClass == "unbounded" || loopClass == "mixed"
    let hasAllocEvidence := !allocs.isEmpty || concreteCaps.any (· == "Alloc")
    let hasFfi := crossesFfi
    let hasBlocking := concreteCaps.any fun c =>
      c == "File" || c == "Network" || c == "Process"
    let passesProfile := !hasRecursion && !hasUnboundedLoops && !hasAllocEvidence && !hasFfi && !hasBlocking
    let obl := pc.obligations.find? fun o => o.functionId.qualName == qualName
    let evidenceLevel :=
      if f.isTrusted then "trusted-assumption"
      else match obl with
      | some o => match o.status with
        | .proved => if passesProfile then "proved" else "reported"
        | .stale => if passesProfile then "enforced (proof stale: body changed)" else "reported"
        | .unbound => if passesProfile then "enforced (proof link unbound: no stored subject)" else "reported"
        | .trusted => "trusted-assumption"
        | _ => if passesProfile then "enforced" else "reported"
      | none => if passesProfile then "enforced" else "reported"
    { name := f.name
      qualName := qualName
      capSet := f.capSet
      effectOpaque := isEffectOpaque
      allocates := !allocs.isEmpty
      frees := !frees.isEmpty
      defers := !defs.isEmpty
      recursion := rec_
      loops := loopClass
      crossesFfi := crossesFfi
      isTrusted := f.isTrusted
      isPublic := f.isPublic
      evidence := evidenceLevel
      loc := lookupLoc locMap qualName }
  fns ++ m.submodules.foldl (fun acc sub =>
    acc ++ effectsForModule opaqueSet externNames recUncertain recMap locMap pc sub qualPrefix) []

def effectsReport (modules : List CModule) (locMap : FnLocMap := [])
    (pc : Concrete.ProofCore) (assumptions : Assumptions.Table := {}) : String :=
  let header := "=== Combined Effects Report ==="
  -- Use shared analysis results from ProofCore
  let recMap := pc.recMap
  -- Transitively closed: reaching an extern through another function still crosses FFI.
  let (externNames, recUncertain) := profileClosures modules pc
  -- R-0484: purity is a claim, computed, not inferred from an empty capability set.
  let opaqueSet := effectOpaqueSet modules pc.callGraph
  -- Collect per-function effects
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule opaqueSet externNames recUncertain recMap locMap pc m) []
  -- Format per-module
  let body := modules.map fun m =>
    let idx := assumptions.programIndex (modules.map (·.name))
    -- Opacity follows the shared summary too, so the row cannot claim `(pure)` past a gap.
    let modEffects := (effectsForModule opaqueSet externNames recUncertain recMap locMap pc m).map fun e =>
      match idx.get? e.qualName >>= assumptions.fns.get? with
      | some sm => { e with effectOpaque := e.effectOpaque || !sm.complete
                            noExternalAuthority := assumptions.noExternalAuthority sm e.capSet }
      | none => e
    let fnLines := modEffects.map fun e =>
      "\n".intercalate (fmtEffectsRow e :: assumesLine assumptions idx e.qualName e.capSet "    ")
    s!"module {m.name}:\n{"\n".intercalate fnLines}"
  -- Summary counts
  let total := allEffects.length
  let idxT := assumptions.programIndex (modules.map (·.name))
  let pure := if assumptions.fns.isEmpty then (allEffects.filter fun e => e.capSet == .empty && !e.effectOpaque).length
    else (allEffects.filter fun e => match idxT.get? e.qualName >>= assumptions.fns.get? with
      | some sm => assumptions.noExternalAuthority sm e.capSet && !e.effectOpaque
      | none => false).length
  let allocating := (allEffects.filter (·.allocates)).length
  let recursive := (allEffects.filter fun e => e.recursion != "none").length
  let unboundedLoops := (allEffects.filter fun e => e.loops == "unbounded" || e.loops == "mixed").length
  let ffi := (allEffects.filter (·.crossesFfi)).length
  let trusted := (allEffects.filter (·.isTrusted)).length
  let proved := (allEffects.filter fun e => e.evidence == "proved").length
  let enforced := (allEffects.filter fun e => e.evidence.startsWith "enforced").length
  let trustedAssumption := (allEffects.filter fun e => e.evidence == "trusted-assumption").length
  let reported := (allEffects.filter fun e => e.evidence == "reported").length
  let summary := s!"\nTotals: {total} functions, {pure} with no external authority, {allocating} allocating, {recursive} recursive, {unboundedLoops} unbounded loops, {ffi} cross FFI, {trusted} trusted\nEvidence: {proved} proved, {enforced} enforced, {trustedAssumption} trusted-assumption, {reported} reported"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

/-- Format the recursion report. -/
def recursionReport (pc : Concrete.ProofCore) : String :=
  let header := "=== Recursion / Call-Cycle Report ==="
  let graph := pc.callGraph
  let sccs := tarjanSCC graph
  let classifications := pc.recMap
  -- Separate into categories
  let directRec := classifications.filter fun (_, k, _) => k == .direct
  let mutualRec := classifications.filter fun (_, k, _) => k == .mutual
  let nonRec := classifications.filter fun (_, k, _) => k == .none
  -- Group mutual recursion by cycle (deduplicate SCC listings)
  let mutualCycles := sccs.filter (fun scc => scc.length > 1)
  -- Build output
  let directSection :=
    if directRec.isEmpty then []
    else
      [s!"Direct recursion ({directRec.length} functions):"] ++
      directRec.map (fun (fn, _, _) => s!"  {fn} -> {fn}") ++ [""]
  let mutualSection :=
    if mutualCycles.isEmpty then []
    else
      [s!"Mutual recursion ({mutualCycles.length} cycles):"] ++
      mutualCycles.map (fun cycle =>
        let cycleStr := " -> ".intercalate cycle
        match cycle.head? with
        | some h => s!"  cycle: {cycleStr} -> {h}"
        | none => s!"  cycle: {cycleStr}") ++ [""]
  let totalFns := classifications.length
  let recursiveFns := directRec.length + mutualRec.length
  let summaryLine := s!"Totals: {totalFns} functions, {nonRec.length} non-recursive, {directRec.length} direct recursion, {mutualRec.length} in mutual cycles"
  let acyclicNote :=
    if recursiveFns == 0 then ["", "No recursion detected — all call paths are acyclic."]
    else []
  let allLines := [header, ""] ++ directSection ++ mutualSection ++ [summaryLine] ++ acyclicNote
  "\n".intercalate allLines ++ "\n"

-- ============================================================
-- Report 11: Stack-Depth Report (--report stack-depth)
-- ============================================================
-- For functions that pass the no-recursion profile (recursion: none),
-- reports:
--   1. Frame size (bytes): sum of parameter and local variable sizes
--   2. Max call depth: longest path in the acyclic call graph
--   3. Worst-case stack bound (bytes): sum of frame sizes along deepest chain
--
-- Recursive functions are listed separately with "unbounded" stack depth.

/-- Per-function stack-depth record. -/
private structure FnStackInfo where
  qualName   : String
  name       : String
  frameBytes : Nat
  callDepth  : Nat           -- 0 = leaf
  stackBound : Nat           -- worst-case bytes through this call chain
  isRecursive : Bool
  loc        : Option SourceLoc

/-- Collect all local variable types from a function body (recursive into nested scopes). -/
private partial def collectLocalTys : List CStmt → List Ty
  | [] => []
  | s :: rest =>
    let here := match s with
    | .letDecl _ _ ty _ => [ty]
    | .ifElse _ then_ (some else_) => collectLocalTys then_ ++ collectLocalTys else_
    | .ifElse _ then_ none => collectLocalTys then_
    | .while_ _ body _ step => collectLocalTys body ++ collectLocalTys step
    | .borrowIn _ _ _ _ refTy body => [refTy] ++ collectLocalTys body
    | _ => []
    here ++ collectLocalTys rest

/-- Compute frame size in bytes for a function: parameters + locals. -/
private def computeFrameBytes (ctx : Layout.Ctx) (f : CFnDef) : Nat :=
  let paramBytes := f.params.foldl (fun acc (_, ty) => acc + Layout.tySize ctx ty) 0
  let localTys := collectLocalTys f.body
  let localBytes := localTys.foldl (fun acc ty => acc + Layout.tySize ctx ty) 0
  -- Return address (8 bytes on 64-bit)
  8 + paramBytes + localBytes

/-- Compute max call depth and worst-case stack bound for each non-recursive function.
    Uses memoized DFS on the acyclic call graph. -/
private partial def computeCallDepths
    (frameSizes : List (String × Nat))
    (callGraph : CallGraph)
    (recMap : List (String × RecursionKind × List String))
    : List (String × Nat × Nat) :=  -- (qualName, maxDepth, stackBound)
  let isRecursive (fn : String) : Bool :=
    match recMap.find? (fun (n, _, _) => n == fn) with
    | some (_, .none, _) => false
    | some _ => true
    | none => false
  let getFrame (fn : String) : Nat :=
    match frameSizes.find? (fun (n, _) => n == fn) with
    | some (_, sz) => sz
    | none => 0
  let getCallees (fn : String) : List String :=
    match callGraph.find? (fun (n, _) => n == fn) with
    | some (_, cs) => cs
    | none => []
  -- Memoized DFS: returns (depth, stackBound) for a function
  let rec dfs (fn : String) (visited : List String)
      (memo : List (String × Nat × Nat)) (fuel : Nat)
      : (Nat × Nat) × List (String × Nat × Nat) :=
    match fuel with
    | 0 => ((0, getFrame fn), memo)
    | fuel + 1 =>
      match memo.find? (fun (n, _, _) => n == fn) with
      | some (_, d, s) => ((d, s), memo)
      | none =>
        if isRecursive fn || visited.contains fn then
          ((0, getFrame fn), memo)
        else
          let callees := getCallees fn |>.filter (fun c =>
            !isRecursive c && frameSizes.any (fun (n, _) => n == c))
          let (maxD, maxS, memo) := callees.foldl (fun (bestD, bestS, m) c =>
            let ((cd, cs), m) := dfs c (fn :: visited) m fuel
            let d := cd + 1
            let s := cs + getFrame fn
            if s > bestS then (d, s, m) else (bestD, bestS, m)
          ) (0, getFrame fn, memo)
          let memo := memo ++ [(fn, maxD, maxS)]
          ((maxD, maxS), memo)
  -- Process all non-recursive functions
  let allFns := frameSizes.filter (fun (n, _) => !isRecursive n)
  let fuel := frameSizes.length * frameSizes.length + frameSizes.length
  let memo := allFns.foldl (fun (memo : List (String × Nat × Nat)) (fn, _) =>
    let (_, memo) := dfs fn [] memo fuel
    memo
  ) []
  memo

private def fmtStackRow (info : FnStackInfo) : String :=
  let locSuffix := match info.loc with | some l => s!"  @ {fmtLoc (some l)}" | none => ""
  if info.isRecursive then
    s!"  {info.name}\n    frame: {info.frameBytes} bytes  depth: unbounded (recursive)  stack: unbounded{locSuffix}"
  else
    s!"  {info.name}\n    frame: {info.frameBytes} bytes  depth: {info.callDepth}  stack: {info.stackBound} bytes{locSuffix}"

private partial def collectStackFns
    (ctx : Layout.Ctx)
    (recMap : List (String × RecursionKind × List String))
    (locMap : FnLocMap)
    (m : CModule) (pfx : String := "")
    : List (String × String × Nat × Bool × Option SourceLoc) :=
  let qualPrefix := if pfx == "" then m.name else pfx ++ "." ++ m.name
  let fns := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.sourceName
    let frame := computeFrameBytes ctx f
    -- An indirect call contributes no call-graph edge, so the deepest chain through this body
    -- looks like one frame and the report would state a specific byte bound for a function that
    -- may recurse arbitrarily deep. A false NUMBER is worse than a missing one: it is quotable.
    -- Grouped with the recursive functions, which is where "no bound established" already lives.
    let isRec := if hasIndirectCallStmts f.body then true else
      match recMap.find? (fun (n, _, _) => n == qualName) with
      | some (_, .none, _) => false
      | some _ => true
      | none => false
    (qualName, f.name, frame, isRec, lookupLoc locMap qualName)
  fns ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectStackFns ctx recMap locMap sub qualPrefix) []

/-- Close a set of "no bound established" functions backwards over the call graph.

    `computeCallDepths` FILTERED recursive callees out of each chain, so a function calling an
    unbounded one still received a finite byte bound: `ping` calling `apply` (unbounded) was
    reported as `depth: 1, stack: 32 bytes`, and that number became the program's
    `Max stack bound`. Dropping the edge understates the answer instead of declining to give
    one. Unboundedness has to propagate to callers, which is what this does. -/
private def closeUnbounded (callGraph : CallGraph) (seed : List String) (fuel : Nat) :
    List String :=
  closeBackward callGraph seed fuel

/-- The `Max stack bound:` line -- the ONE producer of the program-level stack figure.

    Bug 065: this maximised over the BOUNDED subset only, so a program with any unbounded
    function still printed a finite number (`48 bytes (leaf)` while `main` recursed; `0 bytes
    ((none))` when nothing was bounded). That number is what `[policy] max_stack_bytes`,
    `[allocation] stack_max_bytes` and the release bundle's `evidence.max_stack_bytes` read, so a
    budget PASSED a program with unbounded stack. The line covers every function the report
    lists (the report has no entry-point notion), so it is `unbounded` if ANY of them is: a
    maximum over a set with an unbounded member is unbounded. Shell consumers parse this line
    only through `scripts/tests/lib/stack_bound.sh`; the word `unbounded` is the contract. -/
private def stackSummaryLine (infos : List FnStackInfo) : String :=
  let unboundedFns := infos.filter (·.isRecursive)
  if !unboundedFns.isEmpty then
    let shown := (unboundedFns.take 3).map (·.qualName)
    let more := if unboundedFns.length > 3 then s!", ... (+{unboundedFns.length - 3})" else ""
    s!"Max stack bound: unbounded ({unboundedFns.length} of {infos.length} functions have no bound: {", ".intercalate shown}{more})"
  else
    match infos.foldl (fun best i =>
      match best with
      | none => some i
      | some b => if i.stackBound > b.stackBound then some i else best) none with
    | some i => s!"Max stack bound: {i.stackBound} bytes ({i.name})"
    | none => "Max stack bound: 0 bytes (no functions)"

/-- Every declared extern name in a module tree, and those declared AS an intrinsic. -/
private partial def stackExternNames (ms : List CModule) : List String × List String :=
  ms.foldl (fun (ex, intr) m =>
    let (subEx, subIntr) := stackExternNames m.submodules
    (ex ++ m.externFns.map (·.1) ++ subEx, intr ++ m.intrinsicDecls.map (·.1) ++ subIntr)) ([], [])

/-- Stack-depth report for functions passing the no-recursion profile. -/
def stackDepthReport (modules : List CModule) (locMap : FnLocMap := [])
    (pc : Concrete.ProofCore) : String :=
  let ctx := buildLayoutCtx modules
  let recMap := pc.recMap
  let callGraph := pc.callGraph
  let allFns := modules.foldl (fun acc m =>
    acc ++ collectStackFns ctx recMap locMap m) []
  let frameSizes := allFns.map fun (qn, _, frame, _, _) => (qn, frame)
  -- Compute call depths
  let depths := computeCallDepths frameSizes callGraph recMap
  -- A DIRECT EDGE WHOSE TARGET HAS NO FRAME IN THIS REPORT IS NOT A LEAF. An extern, or a callee
  -- the call graph left bare because it resolved to no unique definition (unknown or ambiguous
  -- spelling), has no stack figure here: `computeCallDepths` drops such edges, so a function
  -- calling an externally implemented recursive routine published a finite bound that every
  -- budget consumer accepted (bug 065 follow-up). No stack bound is ever validated for those
  -- targets, so their callers are seeded as "no bound established". Compiler intrinsics are the
  -- one exception: the compiler lowers them itself and they never call back into program code.
  --
  -- The exemption is for a RESOLVED intrinsic identity, never a spelling: an explicitly
  -- declared extern named `wrapping_add` is externally implemented with no validated bound,
  -- and Elab already calls IT rather than the intrinsic (a user/extern signature wins), so it
  -- stays opaque here too (Codex round 2). An extern DECLARED as an intrinsic
  -- (`intrinsicDecls`) is the compiler's own lowering and stays exempt.
  let framed := frameSizes.map (·.1)
  let (externNames, intrinsicExterns) := stackExternNames modules
  let isResolvedIntrinsic := fun (c : String) =>
    (resolveIntrinsic c).isSome && (!externNames.contains c || intrinsicExterns.contains c)
  let opaqueCallers := callGraph.filterMap fun (n, cs) =>
    if cs.any (fun c => !framed.contains c && !isResolvedIntrinsic c) then some n else none
  -- Anything that can REACH a function with no bound has no bound either.
  let seed := (allFns.filter (fun (_, _, _, isRec, _) => isRec)).map (fun (qn, _, _, _, _) => qn)
    ++ opaqueCallers
  let unbounded := closeUnbounded callGraph seed (frameSizes.length + 1)
  -- Build FnStackInfo records
  let infos := allFns.map fun (qn, name, frame, isRec, loc) =>
    if isRec || unbounded.contains qn then
      { qualName := qn, name := name, frameBytes := frame,
        callDepth := 0, stackBound := 0, isRecursive := true, loc := loc : FnStackInfo }
    else
      match depths.find? (fun (n, _, _) => n == qn) with
      | some (_, d, s) =>
        { qualName := qn, name := name, frameBytes := frame,
          callDepth := d, stackBound := s, isRecursive := false, loc := loc : FnStackInfo }
      | none =>
        { qualName := qn, name := name, frameBytes := frame,
          callDepth := 0, stackBound := frame, isRecursive := false, loc := loc : FnStackInfo }
  -- Format
  let header := "=== Stack-Depth Report ==="
  let body := modules.map fun m =>
    let qualPrefix := m.name
    let modInfos := infos.filter fun i => i.qualName.startsWith (qualPrefix ++ ".")
    let fnLines := modInfos.map fmtStackRow
    s!"module {m.name}:\n{"\n".intercalate fnLines}"
  -- Summary
  let bounded := infos.filter (!·.isRecursive)
  let recursive := infos.filter (·.isRecursive)
  let summary := s!"\nTotals: {infos.length} functions, {bounded.length} bounded, {recursive.length} recursive (unbounded)\n{stackSummaryLine infos}"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Profile checks (--check predictable)
-- ============================================================
-- Enforces the predictable-execution profile gate:
--   1. No recursion / call cycles
--   2. No unbounded or mixed loop classifications
--   3. No allocation (alloc/vec_new intrinsic calls)
--   4. No FFI (extern function calls)
--   5. No blocking (File/Network/Process capabilities)
-- Returns a list of violation strings (empty = pass).

/-- Capabilities that imply potentially blocking I/O. -/
private def blockingCaps : List String :=
  ["File", "Network", "Process"]

/-- A single profile violation. -/
structure ProfileViolation where
  fnName        : String         -- bare name for display
  qualName      : String         -- qualified name for facts (e.g. "main.parse_byte")
  reason        : String
  hint          : String := ""                -- suggested fix
  loc           : Option SourceLoc := none    -- function definition
  violationLoc  : Option SourceLoc := none    -- offending construct (loop, call, etc.)
  violationSpan : Option Span := none         -- full span for caret rendering

partial def checkPredictableModule
    (recMap : List (String × RecursionKind × List String))
    (recUncertain : List String)
    (externNames : List String)
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "") : List ProfileViolation :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fnViolations := m.functions.foldl (fun acc f =>
    let qualName := qualPrefix ++ "." ++ f.sourceName
    let fnLoc := lookupLoc locMap qualName
    let entry := lookupBody locMap qualName
    let astBody := match entry with | some e => e.body | none => []
    let fileStr := match entry with | some e => e.file | none => ""
    let mkViolLoc (sp : Option Span) : Option SourceLoc :=
      sp.bind fun s => if fileStr == "" then none else some (fileStr, s.line)
    -- 1. Recursion (function-level only for now)
    let recViolations := match recMap.find? (fun (n, _, _) => n == qualName) with
      | some (_, .direct, _) =>
        [{ fnName := f.name, qualName := qualName, reason := "direct recursion"
         , hint := "Use a loop or iterative approach instead of self-calls."
         , loc := fnLoc }]
      | some (_, .mutual, members) =>
        let others := members.filter (· != qualName)
        [{ fnName := f.name, qualName := qualName, reason := s!"mutual recursion with {", ".intercalate others}"
         , hint := "Break the cycle by restructuring into a loop or state machine."
         , loc := fnLoc }]
      | _ => []
    -- 1b. Indirect calls. The call graph records only DIRECT callees, so a cycle that passes
    -- through a function pointer produces no edge and SCC finds nothing: `ping` calling
    -- `apply(ping, …)` reported `recursion: none` and passed this gate, and `--report
    -- stack-depth` stated a specific byte bound for it. The callee set is not statically known,
    -- so acyclicity cannot be established -- and "could not tell" does not support a
    -- `no recursion` claim.
    -- 1c. TRANSITIVE recursion. "Predictable execution" is a property of RUNNING the function:
    -- if it calls something that cannot be certified acyclic, its own execution inherits that.
    -- `caller` calling a directly recursive `recurses` was `enforced` because the label was
    -- computed from its own body alone. Alloc and the blocking caps never had this problem --
    -- the compiler forces a caller to declare the capability -- and FFI was closed earlier, so
    -- recursion was the last gate asking "is it written here?" instead of "can you reach it?".
    let transRecViolations :=
      if recUncertain.contains qualName && (recMap.find? (fun (n, k, _) => n == qualName && k != .none)).isNone
         && !hasIndirectCallStmts f.body then
        [{ fnName := f.name, qualName := qualName
         , reason := "reaches a function whose recursion cannot be ruled out"
         , hint := "Predictable execution is transitive: the callee must itself pass the profile."
         , loc := fnLoc }]
      else []
    let indirectViolations :=
      if hasIndirectCallStmts f.body then
        [{ fnName := f.name, qualName := qualName
         , reason := "indirect call (callee not statically known, so recursion cannot be ruled out)"
         , hint := "Call a named function directly, or keep this function out of the predictable profile."
         , loc := fnLoc }]
      else []
    -- 2. Loop boundedness — point at the offending loop
    let loopClass := classifyLoops f.body
    let loopSpan := findLoopSpan astBody
    let loopViolLoc := mkViolLoc loopSpan
    let loopViolations :=
      if loopClass == "unbounded" then
        [{ fnName := f.name, qualName := qualName, reason := "unbounded loops"
         , hint := "Use a for loop with an explicit bound: for (let mut i = 0; i < n; i = i + 1)"
         , loc := fnLoc, violationLoc := loopViolLoc, violationSpan := loopSpan }]
      else if loopClass == "mixed" then
        [{ fnName := f.name, qualName := qualName, reason := "mixed loop boundedness (some loops are unbounded)"
         , hint := "Replace while(true) or while(flag) with a bounded for loop."
         , loc := fnLoc, violationLoc := loopViolLoc, violationSpan := loopSpan }]
      else []
    -- 3. Allocation — point at the allocating call
    let callees := collectFreeCallsStmts f.body |>.eraseDups  -- free calls: a method is no allocation intrinsic (bugs 238 – 239)
    let allocs := callees.filter isAllocCall
    let (fnCaps, _) := f.capSet.normalize
    let hasAllocCap := fnCaps.any (· == "Alloc")
    let allocSpan := findCallSpan allocs astBody
    let allocViolLoc := mkViolLoc allocSpan
    let allocViolations :=
      if !allocs.isEmpty then
        [{ fnName := f.name, qualName := qualName, reason := s!"allocates ({", ".intercalate allocs})"
         , hint := "Use a fixed-size array or stack buffer instead of heap allocation."
         , loc := fnLoc, violationLoc := allocViolLoc, violationSpan := allocSpan }]
      else if hasAllocCap then
        [{ fnName := f.name, qualName := qualName, reason := "has Alloc capability"
         , hint := "Remove Alloc from the with(...) clause if this function does not need heap allocation."
         , loc := fnLoc, violationSpan := match entry with | some e => some e.fnSpan | none => none }]
      else []
    -- 4. FFI — point at the extern call
    -- Only a free call can reach a foreign binding (bugs 238 – 239).
    let directExtern := externCallsIn externNames f
    -- Transitively through any call, free or method (Codex reviews r9, r22): the closure over the
    -- namespace-aware call graph holds this function; the callees named in the closure are cited.
    let directCalls := collectCallsStmts f.body |>.eraseDups
    let externCalls := if !directExtern.isEmpty then directExtern
      else if externNames.contains qualName then
        (let named := directCalls.filter externNames.contains
         if named.isEmpty then directCalls else named)
      else []
    let ffiSpan := findCallSpan externCalls astBody
    let ffiViolLoc := mkViolLoc ffiSpan
    let ffiViolations := if externCalls.isEmpty then []
      else [{ fnName := f.name, qualName := qualName, reason := s!"calls extern ({", ".intercalate externCalls})"
            , hint := "Move the extern call to a non-predictable wrapper and call that instead."
            , loc := fnLoc, violationLoc := ffiViolLoc, violationSpan := ffiSpan }]
    -- 5. Blocking — points at function signature (with-clause has no separate span)
    let (concreteCaps, _) := f.capSet.normalize
    let blockingUsed := concreteCaps.filter fun c => blockingCaps.contains c
    let blockViolations := if blockingUsed.isEmpty then []
      else [{ fnName := f.name, qualName := qualName, reason := s!"may block ({", ".intercalate blockingUsed})"
            , hint := s!"Remove {", ".intercalate blockingUsed} from with(...) or move I/O to a non-predictable caller."
            , loc := fnLoc, violationSpan := match entry with | some e => some e.fnSpan | none => none }]
    acc ++ recViolations ++ transRecViolations ++ indirectViolations ++ loopViolations ++ allocViolations ++ ffiViolations ++ blockViolations) []
  fnViolations ++ m.submodules.foldl (fun acc sub =>
    acc ++ checkPredictableModule recMap recUncertain externNames locMap sub qualPrefix) []

/-- Extract a 1-indexed line from source text. Returns "" if out of bounds. -/
def getSourceLine (source : String) (lineNum : Nat) : String :=
  let lines := source.splitOn "\n"
  if lineNum == 0 then ""
  else match lines[lineNum - 1]? with
    | some l => l
    | none => ""

/-- Render a violation with Elm-style snippet formatting. -/
private def renderViolation (v : ProfileViolation) (sourceMap : SourceMap) : String :=
  -- Header: location + label
  let locStr := match v.loc with | some l => s!"{fmtLoc (some l)}: " | none => ""
  let header := s!"-- {locStr}{v.fnName} — {v.reason}"
  -- Source snippet at the violation point (or function if no violation span)
  let snippetSpan := v.violationSpan.orElse fun _ =>
    match v.loc with | some (_, line) => some { line, col := 1 } | none => none
  let snippetFile := match v.violationLoc with
    | some (f, _) => f
    | none => match v.loc with | some (f, _) => f | none => ""
  let source := sourceMap.lookup snippetFile
  let snippet := match snippetSpan, source with
    | some sp, some src =>
      let line := getSourceLine src sp.line
      if line.isEmpty then ""
      else
        let lineNumStr := toString sp.line
        let pad := lineNumStr.length
        let gutter := String.ofList (List.replicate pad ' ')
        let caretStart := if sp.col > 1 then sp.col - 1 else 0
        let caretLen := if sp.endCol > sp.col then sp.endCol - sp.col else line.length - caretStart
        let spaces := String.ofList (List.replicate caretStart ' ')
        let carets := String.ofList (List.replicate caretLen '^')
        s!"\n\n {lineNumStr} | {line}\n {gutter} | {spaces}{carets}"
    | _, _ => ""
  -- Hint
  let hintStr := if v.hint.isEmpty then "" else s!"\n\n  hint: {v.hint}"
  s!"{header}{snippet}{hintStr}"

/-- Check the predictable-execution profile. Returns (pass, report string). -/
def checkPredictable (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) (pc : Concrete.ProofCore) : Bool × String :=
  let recMap := pc.recMap
  let (externNames, recUncertain) := profileClosures modules pc
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap recUncertain externNames locMap m) []
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let violatingFns := (violations.map (·.fnName)).eraseDups
  let passingFns := allFns.length - violatingFns.length
  if violations.isEmpty then
    (true, s!"predictable profile: pass ({allFns.length} functions checked)\n")
  else
    let header := "predictable profile: FAIL"
    let lines := violations.map fun v => renderViolation v sourceMap
    let summary := s!"{violatingFns.length} function(s) failed, {passingFns} passed"
    (false, s!"{header}\n\n{"\n\n".intercalate lines}\n\n{summary}\n")


end Report
end Concrete
