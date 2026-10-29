import Concrete.Report.LeanStubs

/-! The verification-condition schema, backend discharge adapters and the evidence-class firewall. Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report

/-! ## Verification-condition schema v1 (Phase 2 foundation)

A single, project-wide, machine-readable view over every obligation the compiler
generates. Each VC carries the schema-v1 fields: a stable `id`, source `loc`
(span), `kind`, separated `hypotheses` + `conclusion`, the `origin` function,
`dependencies` (proof links it leans on), an `arith_profile`, and the
`expected_discharge` mode. This is deliberately a DESCRIPTION of the obligation
and which backend *should* own it — it does not itself run any solver. Discharge
status stays in the existing per-kind reports; keeping the schema separate is
what stops a solver from silently becoming a "proved" path. -/

def vcSchemaVersion : Nat := 1

/-- What ONE kernel reported about ONE obligation: the auditable unit the
    multi-kernel classes are composed from.

    `verdict` is the kernel's own cell (`closed` / `refused` / `error` /
    `not-asked`); `loweringAgreed` records whether the goal that kernel was handed
    was verified to denote the obligation. BOTH are required for the receipt to count
    as evidence — a kernel that closed a goal denoting something else proved a
    different proposition. `replay` is the command an outsider runs to re-derive this
    receipt, which is what makes the evidence portable rather than merely asserted. -/
structure KernelReceipt where
  kernel         : String        -- "lean" | "rocq" | "isabelle"
  version        : String        -- exact tool identity, e.g. "coqc 9.0.1"
  verdict        : String        -- "closed" | "refused" | "error" | "not-asked"
  loweringAgreed : Bool          -- did its rendering denote the obligation?
  replay         : String := ""  -- how to re-check this receipt independently
  deriving Inhabited, BEq

/-- Does this receipt count toward the multi-kernel class? -/
def KernelReceipt.attests (r : KernelReceipt) : Bool :=
  r.verdict == "closed" && r.loweringAgreed

/-- The independence axes a multi-kernel claim spans, stated structurally so a stale
    claim fails a gate instead of merely reading oddly in a comment.

    `bridge` is the honest "no": every kernel checks a lowering produced by ONE
    Core→obligation bridge, so agreement says nothing about that bridge's
    faithfulness until realization proofs or a discharged bridge register exist. -/
structure IndependenceFacts where
  specFormalization    : String  -- "no" — one spec, one formalization
  kernelImplementation : String  -- "yes" once an external kernel attests
  kernelFoundations    : String  -- "no" | "partial (CIC×CIC)" | "yes (CIC×HOL)"
  bridge               : String  -- "no (single shared Core→obligation bridge)"
  deriving Inhabited, BEq

/-- Derive the independence axes from the set of attesting kernels.

    R-0458: `kernelFoundations` now comes from `Evidence.foundationSummary` rather than from
    a local `contains "isabelle"` / `contains "rocq"` chain. The old chain was a SECOND copy
    of which kernel belongs to which foundation, sitting in a different module from the badge
    that reports it — so adding a fourth kernel meant remembering to edit both, and the two
    could disagree about the same attester set. One definition, two consumers. -/
def independenceOf (attest : List String) : IndependenceFacts :=
  let (n, names) := foundationSummary attest
  { specFormalization := "no (one spec, one formalization)"
    kernelImplementation :=
      if attest.any (fun k => k != "lean") then "yes" else "no (lean only)"
    kernelFoundations :=
      if n ≥ 2 then s!"yes ({names})"
      else if attest.length ≥ 2 then s!"partial ({names}×{names} — {attest.length} kernels, one foundation)"
      else "no (single foundation)"
    bridge := "no (single shared Core→obligation bridge; see --report core-semantics-diff)" }

/-- The ONE obligation record (Phase 3 #18d). Formerly two types — `Report.VC`
    and `ObligationCore.Obligation` — now a single struct hosted here (the module
    `collectVCs` lives in; `ObligationCore` imports `Report`, so the canonical
    record must live at or below `Report`). `ObligationCore.Obligation` is an
    `abbrev` of this, and `VC` is kept as a compatibility alias for the existing
    discharge/schema/render call sites. The fields after `leanReplay` are the
    ledger-view fields (formerly ObligationCore-only); they default empty so a
    plain VC literal is unchanged and the VC reports never observe them. -/
structure Obligation where
  id            : String
  kind          : String       -- ∈ kindVocabulary
  fn            : String
  file          : String
  line          : Nat
  hypotheses    : List String
  conclusion    : String
  origin        : String
  dependencies  : List String
  -- Loop VCs this obligation's HYPOTHESES owe (R-0461). Distinct from `dependencies`,
  -- which is the function-level proof-dependency edge: this is the VC-level hypothesis
  -- edge, and H23 was exactly the absence of a composition along it.
  hypDebt       : List String := []
  arithProfile  : String       -- constant | linear | bitvector | nonlinear | refinement | operational | unsupported
  dischargeMode : String       -- constant_fold | omega | bv_decide | lean | smt | none
  -- discharge OUTCOME (filled in by `dischargeVCs` after the backends run):
  status        : String       -- ∈ statusVocabulary
  engine        : String       -- constant_fold | omega | bv_decide | lean | "" (none yet)
  -- concrete source-level counterexample (var → value), when a solver returned `sat`:
  counterexample : List (String × String) := []
  -- external-solver provenance (set only for SMT-routed VCs), for determinism/replay:
  smtHash       : String := ""  -- stable digest of the exact SMT-LIB query
  smtQuery      : String := ""  -- the SMT-LIB script itself (the replay artifact)
  solver        : String := ""  -- solver identity + version, e.g. "z3 4.16.0" (when run)
  leanReplay    : String := ""  -- the standalone Lean replay theorem (the artifact to kernel-check)
  -- ledger-view fields (Phase 3 #18d; formerly ObligationCore.Obligation-only):
  variables      : List String := []   -- typed variables in scope (names)
  allowedEngines : List String := []   -- which backends may discharge it
  replay         : String := ""        -- human replay hint
  policyImpact   : String := ""        -- release-policy consequence of `status`
  -- independent kernels that each accepted a lowering of this obligation (spike
  -- multi-prover-evidence); set by foldMultiKernelResults, e.g. ["lean","rocq"].
  attestingKernels : List String := []
  -- The SAME attesters with their tool versions, e.g.
  -- ["lean 4.28.0", "coqc 9.0.1", "isabelle Isabelle2025-2"]. Recorded because a
  -- STORED `proved_by_two_kernels` claim is otherwise un-auditable: months later the
  -- artifact says two kernels agreed but not which builds, so the claim cannot be
  -- reproduced or invalidated by a known-buggy prover release. Versions are exactly
  -- what the verdict cache keys on, so both come from one source.
  attestingKernelVersions : List String := []
  /-- One RECEIPT per kernel that was consulted. The multi-kernel class is COMPOSED
      from these (count the receipts that both closed and agreed), never decided by a
      coordinator that holds its own opinion about what agreement means. That
      direction matters: a class computed from receipts cannot drift from the receipts,
      whereas a separately-maintained class can — and did, until the badge was
      composed with lowering agreement. -/
  kernelReceipts : List KernelReceipt := []
  /-- Which axes of independence this obligation's evidence actually spans. Structured
      rather than prose, because a prose non-attestation is the drift class this
      project keeps rediscovering: comments do not fail a gate when they go stale. -/
  independence : Option IndependenceFacts := none

/-- Compatibility alias: `VC` is the obligation record, kept for the existing
    discharge/schema/render call sites. -/
abbrev VC := Obligation

/-- Split a compiler-generated goal string `∀ (vars : T), (h1) → h2 → (concl)`
    into (hypotheses, conclusion): drop the binder, split the body on top-level
    ` → `, the conclusion is the final component. The goal strings are
    compiler-generated with a regular shape, so this is exact, not heuristic. -/
def splitVCGoal (g : String) : List String × String :=
  let body :=
    if g.startsWith "∀" then
      match g.splitOn "), " with
      | _ :: rest => "), ".intercalate rest
      | [] => g
    else g
  let parts := body.splitOn " → "
  match parts.reverse with
  | concl :: hypsRev => (hypsRev.reverse, concl)
  | [] => ([], body)

/-- Function qualname embedded in a VC key: strip the `#suffix` and any `@line`. -/
private def vcFnOfKey (key : String) : String :=
  let beforeHash := (key.splitOn "#").head?.getD key
  (beforeHash.splitOn "@").head?.getD beforeHash

/-- Contract-clause diagnostics for the ledger (Phase 3 #10): every `#[requires]`/
    `#[ensures]`/`#[invariant]`/`#[variant]` clause that fails validation surfaces
    as a ledger obligation — `impure_contract_call` when it calls a
    capability-requiring function, else `invalid_contract_expression` (unknown
    name, non-total construct, …). Status is `ineligible`: such a clause is not a
    provable obligation, it is a malformed contract the audit must show loudly.
    Mirrors the checks `contractsReport`/`loopContractSection` already render. -/
def contractClauseDiagnostics (modules : List Module) :
    List (String × String × String × String × List String) := Id.run do
  let callables := callableContractNames modules
  let consts := contractConstNames modules
  let impures := impureFnNames modules
  let mut out : List (String × String × String × String × List String) := []
  let diag := fun (allowed : List String) (e : Expr) =>
    let invalid := validateContractExpr allowed callables e
    let impure := (contractImpureCalls impures e).map (fun fn =>
      s!"impure call '{fn}' — spec/ghost must be pure and total (no capabilities)")
    (invalid, impure)
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let paramVars := f.params.map (·.name)
    let preVars := (paramVars ++ consts).eraseDups
    let postVars := (paramVars ++ ["result"] ++ localNamesB f.body ++ consts).eraseDups
    let loopVars := (paramVars ++ localNamesB f.body ++ consts).eraseDups
    let emit := fun (acc : List (String × String × String × String × List String))
        (key clauseTxt : String) (allowed : List String) (e : Expr) =>
      let (invalid, impure) := diag allowed e
      if !impure.isEmpty then
        acc ++ [(key, "impure_contract_call", fq, clauseTxt, impure)]
      else if !invalid.isEmpty then
        acc ++ [(key, "invalid_contract_expression", fq, clauseTxt, invalid.eraseDups)]
      else acc
    let mut ri := 1
    for r in f.requires do
      out := emit out s!"{fq}#req_diag{ri}" s!"requires {Concrete.fmtExpr r}" preVars r; ri := ri + 1
    let mut oi := 1
    for e in f.ensures do
      out := emit out s!"{fq}#ens_diag{oi}" s!"ensures {Concrete.fmtExpr e}" postVars e; oi := oi + 1
    for lc in f.loopContracts do
      let mut ii := 1
      for inv in lc.invariants do
        out := emit out s!"{fq}@{lc.line}#inv_diag{ii}" s!"invariant {Concrete.fmtExpr inv}" loopVars inv; ii := ii + 1
      match lc.variant with
      | some v => out := emit out s!"{fq}@{lc.line}#var_diag" s!"variant {Concrete.fmtExpr v}" loopVars v
      | none => pure ()
  return out

/-- Collect the project-wide VC schedule. Covers preconditions (call sites),
    postconditions (`#[ensures]`), asserts, vacuity, the runtime-safety
    obligations (array bounds, div/mod nonzero, `#[overflow_checked]`), the
    loop obligations (O1 init, O2 preservation, O3 exit→post, O4/O5 variant),
    and the contract-clause diagnostics (Phase 3 #10). -/
def collectVCs (modules : List Module) (locMap : FnLocMap)
    (registry : ProofRegistry) : List VC := Id.run do
  let loc := fun (fq : String) =>
    match locMap.find? (·.qualName == fq) with
    | some e => (e.file, e.fnSpan.line)
    | none => ("", 0)
  let mkVC := fun (id kind fq file : String) (line : Nat) (hyps : List String)
      (concl origin : String) (deps : List String) (profile mode status engine : String) =>
    ({ id := id, kind := kind, fn := fq, file := file, line := line, hypotheses := hyps,
       conclusion := concl, origin := origin, dependencies := deps,
       arithProfile := profile, dischargeMode := mode, status := status, engine := engine } : VC)
  -- a VC whose discharge cannot be decided without running a backend is "planned";
  -- the constant-fold and lean-link verdicts ARE decidable here and set directly.
  let mkSplit := fun (key kind profile mode : String) (goal : String) (deps : List String) =>
    let (hyps, concl) := splitVCGoal goal
    let fq := vcFnOfKey key
    let (file, line) := loc fq
    mkVC key kind fq file line hyps concl s!"{kind} in {fq}" deps profile mode "planned" ""
  let mut out : List VC := []
  -- preconditions at call sites (structural: includes the constant-decided ones).
  for o in callSiteObligations modules do
    let (file, line) := loc o.caller
    let concl := (toLeanProp o.specExpr).getD (Concrete.fmtExpr o.specExpr)
    let hyps := o.hyps.filterMap toLeanProp
    let (profile, mode, status, engine) := match o.baseStatus with
      | "proved_at_callsite" => ("constant", "constant_fold", "proved_by_kernel_decision", "constant_fold")
      | "failed_at_callsite" => ("constant", "constant_fold", "counterexample", "constant_fold")
      | _ => match o.leanGoal with
             | some _ => ("bitvector", "bv_decide", "planned", "")
             | none   => if (toLeanProp o.specExpr).isSome then ("linear", "omega", "planned", "") else ("unsupported", "none", "unproven", "")
    out := out ++ [mkVC o.key "precondition" o.caller file line hyps concl
      s!"precondition of {o.callStr} in {o.caller}" [] profile mode status engine]
  -- asserts and vacuity (goal-string generators; omega decides at discharge time).
  for (k, g) in assertGoals modules do out := out ++ [mkSplit k "assert" "linear" "omega" g []]
  -- assume facts: trusted assumptions surfaced in the one ledger as `assumed`
  -- (never a proof; no goal, so they cannot launder trust into kernel evidence).
  for (k, concl, hyps) in assumeFacts modules do
    let fq := vcFnOfKey k
    let (file, line) := loc fq
    out := out ++ [mkVC k "assume" fq file line hyps concl s!"assume in {fq}" [] "operational" "none" "assumed" "assumed"]
  for (k, g) in vacuityGoals modules do out := out ++ [mkSplit k "vacuity" "linear" "omega" g []]
  -- constant-false preconditions are vacuous too, but the constant folder (not
  -- omega) decides them — `vacuityGoals` skips them because `false` does not
  -- lower to a Lean prop. Surface them in the ledger as constant-fold vacuity so
  -- the obligation ledger is the complete source of vacuous functions (Phase 3
  -- #14: policy reads vacuity from the ledger, not a side channel).
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    if f.requires.any (fun r => cEvalBool r == some false) then
      let (file, line) := loc fq
      out := out ++ [mkVC s!"{fq}#requires_vac" "vacuity" fq file line []
        "False" s!"vacuity in {fq}" [] "constant" "constant_fold" "proved_by_kernel_decision" "constant_fold"]
  -- a constant runtime-safety verdict → kernel-decided here; else planned/omega/bv.
  let constStatus := fun (cv : Option Bool) =>
    match cv with
    | some true  => ("proved_by_kernel_decision", "constant_fold")
    | some false => ("counterexample", "constant_fold")
    | none       => ("unproven", "")
  -- array bounds.
  for o in boundsObligations modules do
    let (file, line) := loc o.fnQual
    let (hyps, concl, profile, mode, status, engine) := match o.leanGoal with
      | some g => let (h, c) := splitVCGoal g; (h, c, "linear", "omega", "planned", "")
      | none =>
        let c := s!"0 ≤ {Concrete.fmtExpr o.idxExpr} ∧ {Concrete.fmtExpr o.idxExpr} < {o.size}"
        let (st, en) := constStatus o.closedVerdict
        if o.closedVerdict.isSome then ([], c, "constant", "constant_fold", st, en) else ([], c, "unsupported", "none", st, en)
    out := out ++ [{ mkVC o.key "array_bounds" o.fnQual file line hyps concl
      s!"index {o.arrName}[{Concrete.fmtExpr o.idxExpr}] (size {o.size}) in {o.fnQual}" [] profile mode status engine
      with hypDebt := o.hypDebt }]
  -- div/mod nonzero.
  for o in divObligations modules do
    let (file, line) := loc o.fnQual
    let (hyps, concl, profile, mode, status, engine) := match o.leanGoal with
      | some g => let (h, c) := splitVCGoal g; (h, c, "linear", "omega", "planned", "")
      | none =>
        let c := s!"{Concrete.fmtExpr o.divExpr} ≠ 0"
        let (st, en) := constStatus o.closedVerdict
        if o.closedVerdict.isSome then ([], c, "constant", "constant_fold", st, en) else ([], c, "unsupported", "none", st, en)
    out := out ++ [{ mkVC o.key "div_nonzero" o.fnQual file line hyps concl
      s!"{if o.isMod then "%" else "/"} divisor {Concrete.fmtExpr o.divExpr} in {o.fnQual}" [] profile mode status engine
      with hypDebt := o.hypDebt }]
    -- R-0464 / H24: the SECOND condition `IntArith.trapConditions` lists for `/` and `%`.
    -- A separate VC with its own key, because a division can discharge `divisor ≠ 0` and
    -- still trap on signed `MIN / -1` — one status for two conditions is how the weaker one
    -- masked the stronger. Emitted only where the operand type has a signed minimum to
    -- exclude; unsigned and unknown-width operands cannot hit the quotient overflow.
    match o.quotGoal, o.quotMin with
    | some g, some m =>
      let (qh, qc) := splitVCGoal g
      out := out ++ [{ mkVC (o.key ++ "q") "div_quotient_in_range" o.fnQual file line qh qc
        s!"{if o.isMod then "%" else "/"} quotient of {Concrete.fmtExpr o.numExpr} by {Concrete.fmtExpr o.divExpr} in {o.fnQual} (excludes {m} / -1)"
        [] "linear" "omega" "planned" ""
        with hypDebt := o.hypDebt }]
    | _, _ => pure ()
  -- R-0464 / H24: shift amounts. A family that did not exist, so `<<`/`>>` produced no VC
  -- at all and `--report vcs` was silent about an operation that aborts.
  for o in shiftObligations modules do
    let (file, line) := loc o.fnQual
    let (hyps, concl, profile, mode, status, engine) := match o.leanGoal with
      | some g => let (h, c) := splitVCGoal g; (h, c, "linear", "omega", "planned", "")
      | none =>
        let c := s!"0 ≤ {Concrete.fmtExpr o.amountExpr} ∧ {Concrete.fmtExpr o.amountExpr} < {o.width}"
        let (st, en) := constStatus o.closedVerdict
        if o.closedVerdict.isSome then ([], c, "constant", "constant_fold", st, en)
        else ([], c, "unsupported", "none", "ineligible", "")
    out := out ++ [{ mkVC o.key "shift_amount_in_range" o.fnQual file line hyps concl
      s!"shift of {Concrete.fmtExpr o.shiftedExpr} by {Concrete.fmtExpr o.amountExpr} in {o.fnQual} (width {o.width})"
      [] profile mode status engine
      with hypDebt := o.hypDebt }]
  -- overflow (omega tier, then the interval-gated bv_decide fallback, then const).
  for o in overflowObligations modules do
    let (file, line) := loc o.fnQual
    let (hyps, concl, profile, mode, status, engine) := match o.leanGoal, o.bvGoal with
      | some g, _ => let (h, c) := splitVCGoal g; (h, c, "linear", "omega", "planned", "")
      | none, some g => let (h, c) := splitVCGoal g; (h, c, "bitvector", "bv_decide", "planned", "")
      | none, none =>
        let c := s!"{o.lo} ≤ {Concrete.fmtExpr o.opExpr} ∧ {Concrete.fmtExpr o.opExpr} ≤ {o.hi}"
        let (st, en) := constStatus o.closedVerdict
        if o.closedVerdict.isSome then ([], c, "constant", "constant_fold", st, en) else ([], c, "unsupported", "none", st, en)
    out := out ++ [{ mkVC o.key "no_overflow" o.fnQual file line hyps concl
      s!"no-overflow of {Concrete.fmtExpr o.opExpr} in [{o.lo}, {o.hi}] in {o.fnQual}" [] profile mode status engine
      with hypDebt := o.hypDebt }]
  -- loop obligations (reuse loopObInfo for kind/hyps/conclusion). Discharge is
  -- decided by omega (O1/O3/O4/O5) or stays operational/lean (O2) → planned here.
  for (pfx, f) in (modules.flatMap allFunctions).filter (fun (_, f) => !f.loopContracts.isEmpty) do
    let fq := pfx ++ f.name
    let (file, _) := loc fq
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    let _reg := registry.find? (·.function == fq)
    -- No coverage label discharges a loop step (see `proveReportEntry`): there is no loop-step binding.
    let invDep : List String := []
    for lc in f.loopContracts do
      for oid in ["O1", "O2", "O3", "O4", "O5"] do
        match loopObInfo lc oid fq f.ensures extraLets retExpr [] f.requires with
        | some (kind, hyps, concl, _) =>
          let (profile, mode) := if oid == "O2" then ("operational", "lean") else ("linear", "omega")
          let deps := if oid == "O2" then invDep else []
          out := out ++ [mkVC (loopVCKey fq lc.line oid) kind fq file lc.line hyps concl
            s!"{kind} (loop @ line {lc.line}) in {fq}" deps profile mode "planned" ""]
        | none => pure ()
  -- postconditions (#[ensures]) discharged by registered Lean proofs.
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    if f.ensures.isEmpty then continue
    let (file, line) := loc fq
    -- THE ensures verdict (bug 089). The dependency list is what the link OFFERS, so a reader can
    -- follow it; the status is never a proof class until a checked matcher confirms the theorem
    -- concludes this clause. This used to be `proved_by_lean` whenever any theorem was linked and the
    -- coverage label was not `one_direction` — `#[proof_coverage(iff)]` alone discharged it.
    let v := ensuresVerdictOf registry fq
    let mode := if v.theorems.isEmpty then "none" else "lean"
    let mut ei := 0
    for ens in f.ensures do
      out := out ++ [mkVC s!"{fq}#ensures{ei}" "postcondition" fq file line
        (f.requires.map Concrete.fmtExpr) (Concrete.fmtExpr ens) s!"postcondition in {fq}"
        v.theorems "refinement" mode v.status ""]
      ei := ei + 1
  -- contract-clause diagnostics: malformed #[requires]/#[ensures]/#[invariant]/
  -- #[variant] clauses surface as `ineligible` ledger obligations (Phase 3 #10).
  for (key, kind, fq, clauseTxt, issues) in contractClauseDiagnostics modules do
    let (file, line) := loc fq
    out := out ++ [mkVC key kind fq file line [] (", ".intercalate issues)
      s!"{clauseTxt} in {fq}" [] "unsupported" "none" "ineligible" ""]
  return out

/-! ### Backend discharge adapters (Phase 3 #13)

Every backend that can change a VC's status is expressed as ONE adapter type with
a DECLARED set of evidence classes it may produce. `DischargeAdapter.fold` applies
a backend's results only to VCs in the adapter's precondition status AND only when
the resulting class is in the adapter's `allowed` set — so a backend can NEVER emit
a class it does not own (the evidence-class firewall is structural, not a
convention). omega/bv_decide own the kernel classes, external SMT owns only the
solver classes, Lean-replay owns only `proved_by_lean_replay`. -/

/-- **R-0465: how a backend may treat what a claim RESTS ON — the firewall's second axis.**

    `allowed` governs *who may claim what*. Evidence has a second axis, *what the claim
    rests on*, and it had no framework until Register C. H23 lived entirely in the second
    one, which is why a well-built firewall did not catch it: the fold correctly refuses to
    upgrade an `assumed` VC, but a VC proved under an unestablished invariant carries
    `proved_by_kernel_decision` and sailed straight through.

    `union` is the only sound default. A backend that closes a goal has learned something
    about the goal, not about the hypotheses it was handed — so discharging a proof
    obligation must never shrink the assumption set. `reset` exists to be *named and
    unused*: it is what a backend that genuinely discharges assumptions would declare, and
    having the case forces a new adapter to state its choice rather than inherit silence.
    The compile-time example below pins that no adapter selects it today. -/
inductive AssumptionPolicy where
  | union
  | reset
  deriving DecidableEq, Repr

structure DischargeAdapter where
  engine     : String              -- the engine string stamped on a touched VC
  allowed    : List String         -- the ONLY statuses this backend may assign
  actsOn     : String → Bool       -- precondition: which CURRENT status it may act on
  finalize   : String → String → String  -- (vcKind, rawResultClass) → final status
  setsSolver : Bool := false       -- whether to stamp the solver-identity field
  assumptions : AssumptionPolicy := .union  -- R-0465: never `reset` without saying so

/-- The firewall's admission test: may this adapter move a VC in `curStatus` to `cls`?

    Extracted from `fold` so a backend that cannot use `fold` still passes the SAME test.
    `foldMultiKernelResults` is that backend — it computes a rich verdict (receipts,
    attesters, independence axes) rather than a bare class, so it cannot be expressed as a
    `results` list, and it therefore assigned its status by direct record update, outside
    the firewall built to govern exactly that. R-0465 routes it through here instead. -/
def DischargeAdapter.admits (a : DischargeAdapter) (curStatus cls : String) : Bool :=
  a.actsOn curStatus && a.allowed.contains cls

/-- Apply a backend's `(id, rawClass, model)` results through the adapter
    firewall. A result is applied to VC `v` only when `v.id` matches, `actsOn
    v.status` holds, and the finalized class is in `allowed`; otherwise `v` is
    left exactly as is. This is the single choke point through which any
    status-changing backend must pass. -/
def DischargeAdapter.fold (a : DischargeAdapter) (solverId : String)
    (vcs : List VC) (results : List (String × String × List (String × String))) : List VC :=
  vcs.map fun v =>
    match results.find? (·.1 == v.id) with
    | none => v
    | some (_, raw, model) =>
      let cls := a.finalize v.kind raw
      if a.admits v.status cls then
        { v with status := cls, engine := a.engine,
                 counterexample := if cls == "counterexample" then model else v.counterexample,
                 solver := if a.setsSolver then solverId else v.solver,
                 -- EXPLICIT, not incidental. Record-update already preserved `hypDebt`, so
                 -- this line changes no behaviour — and that is the point: the preservation
                 -- was an accident of syntax that any future rewrite of this branch could
                 -- drop without a single gate noticing. Stating it makes the second axis a
                 -- declared property of the choke point.
                 hypDebt := match a.assumptions with
                   | .union => v.hypDebt
                   | .reset => [] }
      else v

/-- omega: a kernel decision procedure. Owns `proved_by_kernel_decision`, plus
    `arithmetic_proved` for loop-invariant preservation (where omega closes only
    the arithmetic half). Acts only on `planned` VCs. -/
def omegaAdapter : DischargeAdapter :=
  { engine := "omega", allowed := ["proved_by_kernel_decision", "arithmetic_proved"],
    actsOn := (· == "planned"),
    finalize := fun kind _ =>
      if kind == "loop_invariant_preservation" then "arithmetic_proved"
      else "proved_by_kernel_decision" }

/-- bv_decide: a kernel bit-vector decision procedure. Owns only
    `proved_by_kernel_decision`. Acts only on `planned` VCs. -/
def bvAdapter : DischargeAdapter :=
  { engine := "bv_decide", allowed := ["proved_by_kernel_decision"],
    actsOn := (· == "planned"), finalize := fun _ _ => "proved_by_kernel_decision" }

/-- External SMT: opt-in, untrusted relative to the kernel. Owns ONLY the solver
    classes — it can never produce a kernel/Lean class. Acts only on VCs the
    kernel tiers left `unproven`, and stamps the solver identity. -/
def smtAdapter : DischargeAdapter :=
  { engine := "smt:z3",
    allowed := ["solver_trusted", "counterexample", "unknown", "timeout", "solver_error"],
    actsOn := (· == "unproven"), finalize := fun _ raw => raw, setsSolver := true }

/-- Lean replay: an independent kernel re-check of a solver_trusted VC. Owns only
    `proved_by_lean_replay`, and acts only on `solver_trusted` VCs. -/
def replayAdapter : DischargeAdapter :=
  { engine := "lean:omega", allowed := ["proved_by_lean_replay"],
    actsOn := (· == "solver_trusted"), finalize := fun _ _ => "proved_by_lean_replay" }

/-- Constant fold: decides literal/arithmetic obligations at collect time. Owns
    `proved_by_kernel_decision` (in range) and `counterexample` (a constant
    violation). Assigned directly in `collectVCs`; declared here so its owned
    classes are part of the one firewall spec. -/
def constantFoldAdapter : DischargeAdapter :=
  { engine := "constant_fold", allowed := ["proved_by_kernel_decision", "counterexample"],
    actsOn := (· == "planned"), finalize := fun _ raw => raw }

/-- Linked Lean theorem: a registered in-source proof. Owns only `proved_by_lean`. -/
def linkedLeanAdapter : DischargeAdapter :=
  { engine := "lean", allowed := ["proved_by_lean", "partial"],
    actsOn := (· == "planned"), finalize := fun _ raw => raw }

/-- Oracle / differential test evidence. Owns only `tested_by_oracle` — never a
    proof class. -/
def oracleAdapter : DischargeAdapter :=
  { engine := "oracle", allowed := ["tested_by_oracle"],
    actsOn := (· == "planned"), finalize := fun _ _ => "tested_by_oracle" }

/-- Runtime enforcement: a runtime check or capability gate. Owns
    `runtime_checked` / `enforced` — NEVER a static proof class. -/
def runtimeAdapter : DischargeAdapter :=
  { engine := "runtime", allowed := ["runtime_checked", "enforced"],
    actsOn := (· == "planned"), finalize := fun _ raw => raw }

/-- Assumption / trust boundary: `assume(...)` and `#[trusted]`. Owns `assumed` /
    `trusted` — a trust escape hatch, NEVER a proof class. -/
def assumptionAdapter : DischargeAdapter :=
  { engine := "assumed", allowed := ["assumed", "trusted"],
    actsOn := fun _ => true, finalize := fun _ raw => raw }

/-- **Multi-kernel attestation (R-0465).** Owns the three classes produced by consulting
    independent kernels on an obligation Lean already closed: the two badges and the
    downgrade. Acts ONLY on a VC that Lean has proved — external attestation is a strengthening
    of an existing Lean proof, never a way to obtain one, so a `planned` or `unproven` VC is
    outside its precondition and stays untouched.

    `kernel_disagreement` is in `allowed` because this adapter is the thing that assigns it;
    it is deliberately NOT in `proofClasses`, being a downgrade rather than a claim.

    These were the newest and strongest classes in the system and the only ones outside the
    firewall — protected by a hand-rolled `actsOn` in `foldMultiKernelResults`, which was
    not unsound but was convention where everything around it was structure. -/
def multiKernelAdapter : DischargeAdapter :=
  { engine := "multi-kernel",
    allowed := ["proved_by_two_kernels", "proved_by_multi_kernel", "kernel_disagreement"],
    actsOn := fun s => s == "proved_by_kernel_decision" || s == "proved_by_lean"
                       || s == "proved_by_lean_replay",
    finalize := fun _ raw => raw }

/-- Every backend adapter, for the firewall properties below and documentation. -/
def dischargeAdapters : List DischargeAdapter :=
  [constantFoldAdapter, omegaAdapter, bvAdapter, linkedLeanAdapter, replayAdapter,
   smtAdapter, oracleAdapter, runtimeAdapter, assumptionAdapter, multiKernelAdapter]

/-- The static-proof evidence classes — the ones an untrusted backend (SMT,
    runtime, oracle, assumption) must NEVER be able to emit. -/
def proofClasses : List String :=
  ["proved_by_kernel_decision", "proved_by_lean", "proved_by_lean_replay", "arithmetic_proved",
   -- R-0465: the multi-kernel badges belong here. Their absence meant the four
   -- "untrusted backends emit no proof class" examples below would have stayed GREEN if an
   -- untrusted adapter had listed `proved_by_multi_kernel` — the strongest claim the system
   -- can make was the one the firewall did not defend.
   "proved_by_two_kernels", "proved_by_multi_kernel"]

/-- Register C companion to `Evidence.c3_caps_to_assumed`, kept here because this is
    where `proofClasses` lives. C3 proves a claim with outstanding assumptions presents
    as exactly `"assumed"`; this proves `"assumed"` is not a proof class. Together:
    **a claim resting on an unestablished hypothesis can never present as proved** — the
    H23 *class*, as a compile-time fact rather than a gate.

    R-0461 (2026-08-03) closed H23 itself: `capOnHypothesisDebt` populates the assumption
    set from loop-invariant provenance, so this example now constrains live verdicts. The
    fixture in `check_known_wrong_corpus.sh` asserts the cap rather than the hole.
    `docs/verification/KNOWN_HOLES.md` is the authority on hole status; this comment is a reference to
    it, and `check_hole_status_consistency.sh` fails if a reference disagrees in EITHER
    direction — the stale-open form that replaced this sentence's stale-closed predecessor
    was found by exactly that check.

    The two halves are deliberately in different modules. Evidence.lean must not import
    the report layer, and putting the list here keeps one definition of what counts as a
    proof class for both the adapter firewall and the assumption cap. -/
example : (!proofClasses.contains "assumed") = true := rfl

/-! ### The evidence-class firewall, proved at compile time (Phase 3 #13)

These `example`s are kernel-checked proofs that no adapter can emit a class it
does not own — the firewall holds by construction, independent of any caller. -/

-- Untrusted backends declare NO static-proof class in their `allowed` set.
example : smtAdapter.allowed.all (fun c => !proofClasses.contains c) = true := rfl
example : runtimeAdapter.allowed.all (fun c => !proofClasses.contains c) = true := rfl
example : assumptionAdapter.allowed.all (fun c => !proofClasses.contains c) = true := rfl
example : oracleAdapter.allowed.all (fun c => !proofClasses.contains c) = true := rfl

private def fwVC (st : String) : VC :=
  { id := "f#x", kind := "no_overflow", fn := "f", file := "", line := 0,
    hypotheses := [], conclusion := "c", origin := "", dependencies := [],
    arithProfile := "nonlinear", dischargeMode := "smt", status := st, engine := "" }

-- external SMT may NOT emit a kernel class onto an unproven VC: rejected.
example : (smtAdapter.fold "z3" [fwVC "unproven"]
    [("f#x", "proved_by_kernel_decision", [])]).map (·.status) = ["unproven"] := rfl
-- external SMT may emit its OWN class.
example : (smtAdapter.fold "z3" [fwVC "unproven"]
    [("f#x", "solver_trusted", [])]).map (·.status) = ["solver_trusted"] := rfl
-- external SMT may NOT overwrite a kernel-proved VC (wrong precondition status).
example : (smtAdapter.fold "z3" [fwVC "proved_by_kernel_decision"]
    [("f#x", "counterexample", [])]).map (·.status) = ["proved_by_kernel_decision"] := rfl
-- omega cannot be coerced into a solver class: it always finalizes to its own.
example : (omegaAdapter.fold "" [fwVC "planned"]
    [("f#x", "solver_trusted", [])]).map (·.status) = ["proved_by_kernel_decision"] := rfl
-- replay acts ONLY on solver_trusted: a planned VC is untouched.
example : (replayAdapter.fold "" [fwVC "planned"]
    [("f#x", "x", [])]).map (·.status) = ["planned"] := rfl

/-! #### R-0465: the multi-kernel classes, and the assumption axis

The badges were the strongest claims in the system and the only ones the firewall did not
govern. These pin both halves of that fix. -/

-- Untrusted backends cannot emit a multi-kernel badge either. This is the check whose
-- ABSENCE was the hole: before `proved_by_two_kernels`/`proved_by_multi_kernel` were added
-- to `proofClasses`, the four examples above passed while saying nothing about them —
-- widening the list is what gave them teeth, and this one states the property directly for
-- EVERY adapter rather than the four that were spelled out by hand.
example : dischargeAdapters.all (fun a =>
  a.engine == "multi-kernel" || a.allowed.all (fun c =>
    c != "proved_by_two_kernels" && c != "proved_by_multi_kernel")) = true := rfl

-- Attestation STRENGTHENS an existing Lean proof; it is never a route to one. A VC the
-- kernels never proved cannot be badged, whatever the external kernels claim.
example : multiKernelAdapter.admits "planned" "proved_by_multi_kernel" = false := rfl
example : multiKernelAdapter.admits "unproven" "proved_by_two_kernels" = false := rfl
example : multiKernelAdapter.admits "assumed" "proved_by_multi_kernel" = false := rfl
example : multiKernelAdapter.admits "solver_trusted" "proved_by_multi_kernel" = false := rfl
-- ...and cannot mint a class it does not own, even from a legitimate precondition.
example : multiKernelAdapter.admits "proved_by_kernel_decision" "proved_by_lean_replay" = false := rfl
example : multiKernelAdapter.admits "proved_by_kernel_decision" "trusted" = false := rfl
-- What it MAY do: strengthen a Lean-proved VC, or downgrade one on disagreement.
example : multiKernelAdapter.admits "proved_by_kernel_decision" "proved_by_multi_kernel" = true := rfl
example : multiKernelAdapter.admits "proved_by_lean" "proved_by_two_kernels" = true := rfl
example : multiKernelAdapter.admits "proved_by_kernel_decision" "kernel_disagreement" = true := rfl
-- The downgrade is not a proof class, so nothing above lets it launder into one.
example : (!proofClasses.contains "kernel_disagreement") = true := rfl

-- The assumption axis. No backend discharges assumptions, so every adapter unions; a new
-- adapter selecting `.reset` is a deliberate, visible act that breaks this line.
example : dischargeAdapters.all (fun a => a.assumptions == .union) = true := rfl

-- One obligation, one verdict per kernel: the shape that replaced parallel closed/refused
-- lists. `find?` cannot report both, so `proved_by_two_kernels` beside a stored refusal is
-- now unrepresentable rather than merely unreachable.
example : (([("k", KernelCell.refused), ("k", KernelCell.closed)].find? (·.1 == "k")).map (·.2))
    = some KernelCell.refused := rfl

private def debtVC (st : String) : VC :=
  { fwVC st with hypDebt := ["g@1#O2"] }

-- Behavioural: discharging a goal does not shrink what the goal RESTS ON. This is the H23
-- axis, and it is the lock that a rewrite of `fold` would otherwise silently drop — the
-- preservation used to be an accident of record-update syntax.
example : (omegaAdapter.fold "" [debtVC "planned"]
    [("f#x", "proved_by_kernel_decision", [])]).map (·.hypDebt) = [["g@1#O2"]] := rfl
example : (smtAdapter.fold "z3" [debtVC "unproven"]
    [("f#x", "solver_trusted", [])]).map (·.hypDebt) = [["g@1#O2"]] := rfl
-- ...and a REFUSED fold leaves the debt alone too, rather than clearing it on the way out.
example : (smtAdapter.fold "z3" [debtVC "unproven"]
    [("f#x", "proved_by_kernel_decision", [])]).map (·.hypDebt) = [["g@1#O2"]] := rfl

def dischargeVCs (vcs : List VC) (omegaProved bvProved : List String) : List VC :=
  -- omega then bv_decide through the adapter firewall; whatever stays `planned`
  -- afterwards was discharged by no kernel tier → `unproven`.
  let idResults := fun (ids : List String) => ids.map (fun k => (k, "proved", ([] : List (String × String))))
  let afterOmega := omegaAdapter.fold "" vcs (idResults omegaProved)
  let afterBv := bvAdapter.fold "" afterOmega (idResults bvProved)
  afterBv.map fun v => if v.status == "planned" then { v with status := "unproven" } else v

/-- Mark the SMT-eligible VCs as routed to the external solver: `arith_profile`
    becomes `nonlinear`, `expected_discharge` becomes `smt`, and the determinism /
    replay provenance is attached — a stable digest of the exact SMT-LIB query
    (`smtHash`) and the query text itself (`smtQuery`, the replay artifact).
    Applied ONLY when the external-SMT path is engaged (an explicit flag) — so by
    default no VC ever advertises `smt`. Does not change `status`. -/
def markSmtEligible (vcs : List VC) (smtGoals : List (String × String))
    (replayGoals : List (String × String) := []) : List VC :=
  vcs.map fun v =>
    match smtGoals.find? (·.1 == v.id) with
    | some (_, script) =>
      { v with arithProfile := "nonlinear", dischargeMode := "smt",
               smtHash := shortHash script, smtQuery := script,
               leanReplay := (replayGoals.find? (·.1 == v.id)).map (·.2) |>.getD "" }
    | none => v

/-- Fold Lean-replay results into the VC schedule. `replayed` lists the VC ids a
    kernel-checked Lean tactic INDEPENDENTLY closed. Such a VC graduates from
    `solver_trusted` to `proved_by_lean_replay` (engine `lean:omega`) — the external
    solver is no longer part of the claim, so it is NOT subject to the solver-evidence
    policy. Applied only to VCs currently `solver_trusted`; everything else is left
    exactly as is, so the class boundary stays crisp. -/
def foldReplayResults (vcs : List VC) (replayed : List String) : List VC :=
  replayAdapter.fold "" vcs (replayed.map (fun k => (k, "replayed", [])))

/-- Fold independent-kernel (Rocq/Isabelle) agreement into the ledger (spike
    multi-prover-evidence). ONLY enriches VCs Lean already kernel-proved
    (`proved_by_kernel_decision` / `proved_by_lean` / `proved_by_lean_replay`): a
    VC an external kernel ALSO closed graduates to `proved_by_two_kernels` (one
    external) or `proved_by_multi_kernel` (≥2), recording the attesters. It never
    upgrades an unproved VC, and — per the honesty boundary — attests only that each
    kernel accepted its OWN lowering (no digest cross-check).

    **It CAN downgrade, and that is deliberate.** An earlier version of this comment said
    "never downgrades"; the dissent path added later makes that false, and an external
    review caught the stale claim. A VC Lean proved that an external kernel then REFUSED
    becomes `kernel_disagreement`: every kernel here is complete for linear integer
    arithmetic, so opposite verdicts on the same rendering mean something is wrong, and
    reporting the Lean proof unqualified would hide it. Downgrading on dissent is the
    only status reduction this fold performs.
    `rocqClosed`/`isaClosed` are VC ids the external kernels independently closed.
    Applied only behind the explicit prover flags, so the default ledger is
    unchanged.

    `leanVer`/`rocqVer`/`isaVer` are the tool identities of the kernels that ran, so
    the stored claim records WHICH builds attested it. Without them the artifact says
    "two kernels agreed" but not which ones, and the claim cannot be reproduced later
    or invalidated when a prover release turns out to be buggy.

    **`rocqValidated`/`isaValidated` carry the validation.** They are the obligation
    ids whose agreement lemma each kernel positively CLOSED, and a witness is minted per
    obligation from them. This fold used to write `loweringAgreed := true` literally,
    trusting the caller to have filtered — which is a claim about a check rather than a
    product of one, and is how an agreement run that ended in `error` still produced a
    badge. Defaulting these to `[]` would restore that hazard silently, so they default to
    `[]` meaning NOTHING is validated: a caller that forgets them gets no attestations
    rather than unchecked ones. Fail closed on the caller's mistake too. -/
def foldMultiKernelResults (vcs : List VC)
    (rocqVerdicts isaVerdicts : List (String × KernelCell))
    (leanVer : String := "lean") (rocqVer : String := "rocq") (isaVer : String := "isabelle")
    (rocqValidated isaValidated : List String := [])
    (leanValidated : Option (List String) := none)
    : List VC :=
  vcs.map fun v =>
    if v.status == "proved_by_kernel_decision" || v.status == "proved_by_lean"
       || v.status == "proved_by_lean_replay" then
      -- One RECEIPT per kernel consulted. `loweringAgreed` is DERIVED from whether a
      -- validation witness could be minted for this kernel and this obligation, never
      -- written as a literal. It used to be `true` at five sites, which was accidentally
      -- correct because the caller had filtered — the same assert-instead-of-derive shape
      -- that let an errored agreement check pass as a passed one. Lean is the exception
      -- and says why — but the REASON on record was wrong, and R-0450's slice (2026-08-03)
      -- corrected it. The claim was "Lean's rendering IS the reference the others are
      -- validated against, so there is nothing to validate it with". The agreement check
      -- actually validates a rendering against the reference EVALUATOR (`safeOn` /
      -- `evalBoolEnv`, which walk the AST), not against Lean. The real obstacle was that
      -- Lean's lowering was not expressible as a driver, so the machinery could not be
      -- pointed at it. That obstacle is now gone (`exprToLeanProp` delegates to
      -- `exprToProverU`); running the agreement scripts through a Lean driver and minting a
      -- witness here is the remaining work, still filed under R-0450. The literal stays
      -- until then — but it is a TODO, not a fundamental asymmetry.
      let rocqW := LoweringValidated.mint "rocq" v.id rocqValidated
      let isaW  := LoweringValidated.mint "isabelle" v.id isaValidated
      -- R-0450: Lean's rendering is validated on the same terms as everyone else's now.
      -- `none` means the check was not run (the caller had no Lean agreement pass), and
      -- gating on a check nobody performed would silently delete every badge. `some ks`
      -- means it RAN, and then absence from `ks` is a real negative.
      let leanW := leanValidated.bind (fun ks => LoweringValidated.mint "lean" v.id ks)
      let leanChecked := leanValidated.isSome
      -- R-0465: ONE lookup per kernel, so an obligation has exactly one verdict from each.
      -- This replaced parallel `closed`/`refused` lists whose type could not say they were
      -- disjoint: given `rocqClosed = ["k"]` and `rocqRefused = ["k"]`, both receipts were
      -- written while the `if closed … else if refused` chain passed only `.closed` to
      -- `multiKernelVerdict`, yielding `proved_by_two_kernels` beside a stored refusal. It
      -- was unreachable — both lists came from one verdict list upstream — but the API could
      -- not express that, and an invariant held only by its producer is one refactor from
      -- being lost. `find?` makes the question unaskable rather than answered.
      let rocqCell := cellFor rocqVerdicts v.id
      let isaCell  := cellFor isaVerdicts v.id
      let receipts : List KernelReceipt :=
        -- DERIVED, not asserted. This was the last `loweringAgreed := true` literal in the
        -- system, kept because Lean's rendering had no agreement check — for a reason that
        -- turned out to be wrong (the check measures a rendering against the reference
        -- EVALUATOR, not against Lean). With `leanAgreementGoals` it has one.
        [{ kernel := "lean", version := leanVer, verdict := "closed"
         , loweringAgreed := if leanChecked then leanW.isSome else true
         , replay := "concrete <file> --report multi-kernel" }]
        ++ (if rocqCell == .closed then
              [{ kernel := "rocq", version := rocqVer, verdict := "closed"
               , loweringAgreed := rocqW.isSome
               , replay := "concrete <file> --report multi-kernel --rocq" }] else [])
        ++ (if isaCell == .closed then
              [{ kernel := "isabelle", version := isaVer, verdict := "closed"
               , loweringAgreed := isaW.isSome
               , replay := "concrete <file> --report multi-kernel --isabelle" }] else [])
      -- A kernel that RENDERED this obligation and said no is a dissenter, not an
      -- absence. It gets a receipt too, with `verdict := "refused"`, so the artifact
      -- records that a kernel was consulted and disagreed — previously the stored
      -- claim was indistinguishable from one where no external kernel ran.
      let dissentReceipts : List KernelReceipt :=
        (if rocqCell == .refused then
           [{ kernel := "rocq", version := rocqVer, verdict := "refused"
            , loweringAgreed := rocqW.isSome
            , replay := "concrete <file> --report multi-kernel --rocq" }] else [])
        ++ (if isaCell == .refused then
              [{ kernel := "isabelle", version := isaVer, verdict := "refused"
               , loweringAgreed := isaW.isSome
               , replay := "concrete <file> --report multi-kernel --isabelle" }] else [])
      let receipts := receipts ++ dissentReceipts
      let attesting := receipts.filter (·.attests)
      let versionOf := fun (n : String) =>
        if n == "rocq" then rocqVer else if n == "isabelle" then isaVer else leanVer
      -- Derived by the SAME function the multi-kernel report uses, so the ledger and
      -- the report cannot disagree about one obligation. `v.status` being a kernel
      -- proof class means Lean closed it, hence `leanClosed := true`.
      -- Witnesses are MINTED per obligation from the validated sets, never asserted. If
      -- the agreement lemma did not close for this kernel and this id, `mint` yields
      -- `none` and multiKernelVerdict excludes the kernel entirely.
      let verdict := multiKernelVerdict v.id true (
        kernelInputOf v.id "rocq" "rocq:lia" rocqCell rocqValidated
        ++ kernelInputOf v.id "isabelle" "isabelle:presburger" isaCell isaValidated)
      if !verdict.dissent.isEmpty then
        -- Dissent CAPS the stored claim exactly as it caps the report, and everything a
        -- kernel said stays in the artifact even when what it said blocks the badge:
        -- receipts (including the dissenter's, with verdict "refused"), the attesters,
        -- their versions, AND the independence axes.
        --
        -- Independence is recorded over the kernels that were CONSULTED, not the ones
        -- that agreed — a disagreement between a CIC kernel and a HOL kernel is a
        -- different and more interesting fact than one within a single family, and
        -- dropping the axes would erase that. An external review found this branch
        -- silently leaving `independence := none` while the comment claimed otherwise.
        -- R-0465: the status passes the SAME admission test as every other backend's.
        -- Everything else the kernels said is recorded regardless — refusing the status
        -- change must not silently discard receipts, which are the audit trail.
        let base :=
          { v with kernelReceipts := receipts,
                   attestingKernels := verdict.attest,
                   independence := some (independenceOf (receipts.map (·.kernel)).eraseDups),
                   attestingKernelVersions := verdict.attest.map versionOf }
        if multiKernelAdapter.admits v.status verdict.evidence.present
        then { base with status := verdict.evidence.present } else base
      else if attesting.length < 2 then v
      else
        let attest := attesting.map (·.kernel)
        let base :=
          { v with attestingKernels := attest,
                   kernelReceipts := receipts,
                   independence := some (independenceOf attest),
                   attestingKernelVersions := attest.map versionOf,
                   -- engine lists the EXTERNAL attesters (lean is already there) — but ONLY
                   -- when their attestation is being honoured. With Lean's rendering
                   -- unvalidated the kernels closed goals derived from a lowering we do not
                   -- trust, so advertising `omega+rocq+isabelle` beside a status that
                   -- deliberately withholds the badge states the opposite of the finding.
                   -- Receipts still record everything; the summary field must not oversell.
                   engine := if leanChecked && leanW.isNone then v.engine
                             else "+".intercalate (v.engine :: attest.filter (· != "lean")) }
        -- If the Lean agreement check RAN and this obligation's Lean rendering did not
        -- agree, no badge. Every kernel here closed a goal that Lean's lowering produced,
        -- so a faulty Lean rendering means they all agreed about the wrong proposition —
        -- the one failure mode kernel multiplicity provably cannot detect. Display without
        -- enforcement was the H23 mistake; this is the enforcement.
        if leanChecked && leanW.isNone then base
        else if multiKernelAdapter.admits v.status verdict.evidence.present
        then { base with status := verdict.evidence.present } else base
    else v

/-- **R-0461 / H23: cap a VC by the weakest thing its hypotheses rest on.**

    An obligation discharged inside a loop may assume that loop's `#[invariant]`. Whether
    the invariant holds is answered by that loop's O1 (init) and O2 (preservation), and until
    this pass existed nothing related the two statuses: a bounds obligation reported
    `proved_by_multi_kernel (3: lean, rocq, isabelle)` while its O2 read `unproven` in the
    same report, and the compiled program aborted on the access. See
    `examples/unsound_hypothesis/`.

    Runs AFTER discharge, necessarily: whether O2 is proved is only known once every VC has
    a final status. That ordering is the reason this is a separate pass rather than a check
    inside the family collectors.

    The capped status is `assumed`, via `Evidence.present` — not a new conditional badge.
    `assumed` is already in `statusVocabulary`, already what `#[assume]` produces, and
    already gate-forbiddable through `ProjectPolicy.forbidAssume` — via `E0617`
    (`enforceNoCappedHypotheses`), which R-0461 had to add because `enforceNoAssume` keys on
    the `assume(...)` construct and a capped obligation has none — so capping makes H23
    catchable by enforcement that already exists. Register C's C3 is what guarantees the
    capped value is never a `proved_*` string, and this is the pass that finally makes C3
    fire on real verdicts rather than sit as proved substrate.

    A VC that is not otherwise proved keeps its own more specific status: replacing
    `unproven` with `assumed` would trade a fact about this obligation for a fact about
    someone else's, which is the same rule R-0004 slice 3 applies to dependencies. -/
def capOnHypothesisDebt (vcs : List VC) : List VC :=
  let provedIds := vcs.filterMap (fun v =>
    if v.status.startsWith "proved" || v.status == "trusted" then some v.id else none)
  -- POST-CONDITION: `hypDebt` holds exactly the OUTSTANDING refs. Before this pass it holds
  -- every invariant the obligation leans on, proved or not. Keeping the raw list here made
  -- `constant_time_tag` print `rests on (unproved): ...@52#O1, ...#O2` for two obligations
  -- whose O1 AND O2 were both proved — the cap correctly declined to fire and the render
  -- said otherwise. Narrowing to `outstanding` on every branch is what keeps the field's
  -- meaning the same as its label, and the same as what the policy gate projects.
  vcs.map fun v =>
    if v.hypDebt.isEmpty then v else
    let outstanding := v.hypDebt.filter (fun r => !provedIds.contains r)
    if outstanding.isEmpty then { v with hypDebt := [] } else
    if !(v.status.startsWith "proved") then { v with hypDebt := outstanding } else
      -- Build the claim's evidence and let Register C decide how it presents.
      let ev := outstanding.foldl (fun (e : Evidence) r => e.assuming r)
                  (Evidence.proved v.status)
      { v with status := ev.present, hypDebt := ev.conditions }

/-- Fold external-solver results into the VC schedule. A result class
    (`solver_trusted` / `counterexample` / `unknown` / `timeout` / `solver_error`)
    is applied ONLY to a VC the kernel-checked tiers left `unproven` — so an
    external solver can NEVER override or be confused with a `proved_by_kernel_decision`
    or `proved_by_lean` result. The engine records the solver; a `counterexample`
    carries the solver's model mapped back to source variable names; `solver`
    records the exact solver identity+version that produced the verdict. -/
def foldSmtResults (vcs : List VC) (results : List (String × String × List (String × String)))
    (solverId : String) : List VC :=
  smtAdapter.fold solverId vcs results

/-- Human-readable VC schedule (post-discharge), grouped by originating function.
    `vcs` is the output of `collectVCs` after `dischargeVCs` has folded in results. -/
def vcsReport (vcs : List VC) (unresolvedBounds : List (String × String) := []) : String := Id.run do
  -- Array accesses that reached no obligation are named HERE rather than nowhere. The empty-VC
  -- branch has to render them too: a function whose only access has an unresolvable size
  -- produces zero VCs, and "(no VCs generated)" alone reads as "nothing to check".
  let unresolvedSection : String :=
    if unresolvedBounds.isEmpty then "" else
      let rows := unresolvedBounds.map fun (fq, arr) => s!"\n  {fq}: {arr}[…]"
      "\n\nARRAY ACCESSES OUTSIDE the bounds fragment — no obligation generated"
        ++ " (no statically known array size at the access):"
        ++ String.join rows
        ++ "\n  (these are NOT covered by the counts above; runtime bounds checks still apply)"
  if vcs.isEmpty then
    return "=== Verification Conditions (schema v1) ===\n\n(no VCs generated)" ++ unresolvedSection
  let mut out := "=== Verification Conditions (schema v1) ==="
  let fns := (vcs.map (·.fn)).eraseDups
  for fq in fns do
    out := out ++ s!"\n\n{fq}"
    for v in vcs.filter (·.fn == fq) do
      let hyps := if v.hypotheses.isEmpty then "(none)" else " ∧ ".intercalate v.hypotheses
      let deps := if v.dependencies.isEmpty then "" else s!"\n      dependencies:  {", ".intercalate v.dependencies}"
      let eng := if v.engine.isEmpty then "" else s!" ({v.engine})"
      let cex := if v.counterexample.isEmpty then ""
        else s!"\n      counterexample:  {", ".intercalate (v.counterexample.map (fun (n, x) => s!"{n} = {x}"))}"
      let prov := if v.smtHash.isEmpty then ""
        else s!"\n      solver:  {if v.solver.isEmpty then "(not run)" else v.solver} | logic QF_NIA | timeout 5s | smtlib-sha {v.smtHash}"
          ++ (if v.leanReplay.isEmpty then "" else "\n      lean-replay:  artifact emitted (check with `--emit-lean-replay`); kernel-checks → proved_by_lean_replay")
      -- R-0461: name what the cap rests on. `assumed` alone tells a reader the obligation
      -- is unproved but not what would prove it; the outstanding refs point at the exact
      -- loop VCs to go fix, which is the difference between a verdict and an action.
      let rests := if v.hypDebt.isEmpty then ""
        else s!"\n      rests on (unproved):  {", ".intercalate v.hypDebt}"
      out := out ++ s!"\n  [{v.id}]  {v.kind}"
        ++ s!"\n      status:  {v.status}{eng}{rests}"
        ++ s!"\n      profile/expected:  {v.arithProfile} / {v.dischargeMode}"
        ++ s!"\n      hypotheses:  {hyps}"
        ++ s!"\n      conclusion:  {v.conclusion}{deps}{cex}{prov}"
  -- summary by status
  let proved := (vcs.filter (·.status == "proved_by_kernel_decision")).length
  let lean := (vcs.filter (·.status == "proved_by_lean")).length
  let arith := (vcs.filter (·.status == "arithmetic_proved")).length
  let cex := (vcs.filter (·.status == "counterexample")).length
  let unproven := (vcs.filter (fun v => v.status == "unproven" || v.status == "missing" || v.status == "planned")).length
  out := out ++ s!"\n\nTotal: {vcs.length} VCs — {proved} proved_by_kernel_decision, {lean} proved_by_lean, {arith} arithmetic_proved, {cex} counterexample, {unproven} outstanding"
  return out ++ unresolvedSection

/-- Compact VC-evidence summary for the audit report (the reviewer artifact):
    counts per evidence class, plus the audit-critical lines — every
    `solver_trusted` VC (solver identity + SMT-LIB hash; NOT kernel evidence) and
    every `counterexample` (source-level model). Empty when there are no VCs. -/
def vcAuditSummary (vcs : List VC) : String := Id.run do
  if vcs.isEmpty then return "(no verification conditions)"
  let count := fun (s : String) => (vcs.filter (·.status == s)).length
  let outstanding := (vcs.filter (fun v => v.status == "unproven" || v.status == "missing" || v.status == "planned")).length
  let mut out := s!"{vcs.length} verification conditions:"
  out := out ++ s!"\n  proved_by_kernel_decision:  {count "proved_by_kernel_decision"}  (omega / bv_decide / constant — kernel-checked)"
  out := out ++ s!"\n  proved_by_lean:             {count "proved_by_lean"}  (registered Lean proof)"
  out := out ++ s!"\n  proved_by_lean_replay:      {count "proved_by_lean_replay"}  (solver result replayed in Lean)"
  out := out ++ s!"\n  arithmetic_proved:          {count "arithmetic_proved"}  (omega closed the arithmetic half; operational step needs Lean)"
  out := out ++ s!"\n  solver_trusted:             {count "solver_trusted"}  (external SMT — solver in the TCB, NOT kernel evidence)"
  out := out ++ s!"\n  counterexample:             {count "counterexample"}  (non-proof)"
  out := out ++ s!"\n  outstanding:                {outstanding}  (unproven / missing)"
  -- audit-critical detail: solver-trusted evidence and counterexamples by name.
  let trusted := vcs.filter (·.status == "solver_trusted")
  if !trusted.isEmpty then
    out := out ++ "\n  external-solver evidence (review: solver in the trusted base):"
    for v in trusted do
      out := out ++ s!"\n    {v.id}  [{if v.solver.isEmpty then "solver" else v.solver}, smtlib-sha {v.smtHash}]"
  let cexs := vcs.filter (·.status == "counterexample")
  if !cexs.isEmpty then
    out := out ++ "\n  counterexamples (non-proofs):"
    for v in cexs do
      let m := if v.counterexample.isEmpty then "" else " — " ++ ", ".intercalate (v.counterexample.map (fun (n, x) => s!"{n} = {x}"))
      out := out ++ s!"\n    {v.id}{m}"
  -- by default the audit does not invoke an external solver; note where SMT lives.
  if (count "solver_trusted") == 0 && (count "counterexample") == 0 then
    out := out ++ "\n  (external-solver evidence is opt-in: see `--report vcs --smt`)"
  return out

/-- `concrete prove <file> <fn> --json`: the primary machine-readable proof
    context. Same data as `proveReport`, structured, with `next_actions`. -/
def proveReportJson (pc : Concrete.ProofCore) (registry : ProofRegistry)
    (modules : List Module) (qualName : String) (provedVCs : List String)
    (inputPath schemaVersion : String) : String := Id.run do
  let esc := fun (s : String) => s.foldl (fun a c => a ++ (match c with
    | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\t' => "\\t" | c => c.toString)) ""
  let q := fun (s : String) => "\"" ++ esc s ++ "\""
  let jarr := fun (xs : List String) => "[" ++ ", ".intercalate xs ++ "]"
  let qarr := fun (xs : List String) => jarr (xs.map q)
  let replay := s!"concrete prove {inputPath} {qualName} --replay"
  -- next_actions object builder
  let action := fun (kind cmd fmt resolves : String) =>
    String.join ["{\"kind\": ", q kind, ", \"command\": ", q cmd,
                 ", \"output_format\": ", q fmt, ", \"resolves\": ", q resolves, "}"]
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
  let head := s!"  \"schema_version\": {q schemaVersion},\n  \"function\": {q qualName},"
  match pc.entries.find? (·.qualName == qualName) with
  | none =>
    match pc.excluded.find? (·.qualName == qualName) with
    | some x =>
      let reasons := x.eligibility.sourceReasons ++ x.eligibility.profileReasons
      return String.join [
        "{\n", head, "\n",
        "  \"eligible\": false,\n",
        s!"  \"exclusion_reason\": {q (", ".intercalate reasons)},\n",
        s!"  \"body_fingerprint\": {q x.fingerprint},\n",
        "  \"proof_link\": null,\n",
        "  \"status\": \"ineligible\",\n",
        "  \"evidence_class\": \"ineligible\",\n",
        "  \"obligations\": [],\n",
        s!"  \"next_actions\": [{action "open_docs" "see docs/platform/PROFILES.md" "text" "ineligible"}]\n",
        "}" ]
    | none =>
      return String.join ["{\n", head, s!"\n  \"error\": {q s!"no function '{qualName}' in ProofCore"},\n  \"next_actions\": []\n", "}"]
  | some e =>
    let regEntry := registry.find? (fun re => re.function == e.qualName)
    -- status + evidence from the obligation
    let obl := pc.obligations.find? (·.functionId.qualName == qualName)
    let status := match obl with | some o => o.status.canonical | none => "missing"
    let origin := match regEntry with
      | some re => if re.sourceLinked then "source_linked" else "hardcoded"
      | none => ""  -- no link, no origin (bug 083: there is no name-keyed fallback to name)
    -- proof_link
    let linkJson := match regEntry with
      | some re => String.join [
          "{\"spec\": ", q re.spec, ", \"proof_by\": ", q re.proof,
          ", \"ensures_proof\": ", (match re.ensuresProof with | some t => q t | none => "null"),
          ", \"coverage\": ", q re.coverage,
          ", \"proof_fingerprint\": ", q (shortHash re.bodyFingerprint),
          ", \"origin\": ", q origin, "}" ]
      | none => "null"
    -- obligations (loop VCs)
    let f := astFn?.getD { name := e.bareName, params := [], retTy := .unit, body := [] }
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    let mut obls : List String := []
    -- stable id: "<qual>@<line>#<Ox>" (same key as --report contracts / --replay).
    let oblObj := fun (id : String) (line : Int) (kind : String) (hyps : List String) (concl st : String) =>
      String.join ["{\"id\": ", q id, ", \"kind\": ", q kind, ", \"status\": ", q st,
        ", \"source_line\": ", toString line,
        ", \"hypotheses\": ", qarr hyps, ", \"conclusion\": ", q concl, "}"]
    for lc in f.loopContracts do
      for oid in ["O1", "O2", "O3", "O4", "O5"] do
        match loopObInfo lc oid e.qualName f.ensures extraLets retExpr provedVCs with
        | some (kind, hyps, concl, st) =>
          obls := obls ++ [oblObj (loopVCKey e.qualName lc.line oid) (Int.ofNat lc.line) kind hyps concl st]
        | none => pure ()
    -- the function postcondition (#[ensures]) as an obligation
    for ens in f.ensures do
      let reqHyps := f.requires.map Concrete.fmtExpr
      -- THE verdict (bug 089), never the refinement claim's status: a proved body is not a
      -- discharged postcondition.
      obls := obls ++ [oblObj s!"{e.qualName}#ensures" (Int.ofNat (f.span.line)) "ensures" reqHyps (Concrete.fmtExpr ens) (ensuresVerdictOf registry e.qualName).status]
    -- proofkit hints
    let feats := (e.fn.body.flatMap proveStmtFeatures).eraseDups
    let mut hints : List String := []
    if feats.contains "loop" || !f.loopContracts.isEmpty then hints := hints ++ ["Concrete.ProofKit.Loops"]
    if feats.contains "array" then hints := hints ++ ["Concrete.ProofKit.Array"]
    if feats.contains "bitvec" then hints := hints ++ ["Concrete.ProofKit.BitVec"]
    if feats.contains "call" then hints := hints ++ ["Concrete.ProofKit.Calls"]
    let leanName := leanIdent (e.qualName.splitOn "." |>.getLast!)
    -- next_actions by status
    let na := match status with
      | "missing" => [
          action "show_obligation" s!"concrete prove {inputPath} {qualName} --show-obligation <id>" "text" "missing",
          action "emit_link" s!"concrete prove {inputPath} {qualName} --emit-link" "text" "missing" ]
      | "stale" => [
          action "emit_link" s!"concrete prove {inputPath} {qualName} --emit-link" "text" "stale",
          action "check_proofs" s!"concrete {inputPath} --report check-proofs" "text" "stale" ]
      | "blocked" => [ action "open_docs" "see docs/verification/PROOF_WORKFLOW.md (extraction gates)" "text" "blocked" ]
      | "proved" => [
          action "check_proofs" s!"concrete {inputPath} --report check-proofs" "text" "proved",
          action "replay" replay "text" "proved",
          action "run_audit" s!"concrete audit {inputPath}" "text" "proved" ]
      | _ => [ action "run_audit" s!"concrete audit {inputPath}" "text" status ]
    return String.join [
      "{\n", head, "\n",
      "  \"eligible\": true,\n",
      "  \"exclusion_reason\": null,\n",
      s!"  \"body_fingerprint\": {q e.fingerprint},\n",
      s!"  \"proof_link\": {linkJson},\n",
      s!"  \"status\": {q status},\n",
      s!"  \"evidence_class\": {q (if status == "proved" then "proved_by_lean" else status)},\n",
      s!"  \"obligations\": {jarr obls},\n",
      s!"  \"replay_command\": {q replay},\n",
      s!"  \"proofkit_imports\": {qarr hints},\n",
      s!"  \"suggested_theorems\": {qarr [leanName ++ "_correct"]},\n",
      s!"  \"next_actions\": {jarr na}\n",
      "}" ]

/-- `concrete prove --emit-link`: print the in-source proof-link attribute block
    for `qual`, from its current registry/source-link data. Missing fields are
    emitted as commented placeholders so the author sees what still needs a name.
    Read-only: the author pastes the block above the function and deletes the
    JSON entry. -/
def emitProofLink (pc : Concrete.ProofCore) (registry : ProofRegistry) (qual : String) : String :=
  match registry.find? (·.function == qual) with
  | none => s!"// no proof link or registry entry for `{qual}` — nothing to emit"
  | some e =>
    let req := fun (key val : String) =>
      if val.isEmpty then s!"// #[{key}(...)]   ← missing, fill in" else s!"#[{key}({val})]"
    let ens := match e.ensuresProof with
      | some t => s!"#[ensures_proof({t})]"
      | none => "// #[ensures_proof(...)]   ← none (omit if the postcondition is single-direction)"
    -- THE V2 SUBJECT DIGEST, the value freshness compares against (`storedFreshness`). This emitted
    -- `shortHash` of the BODY fingerprint — a v1 value, which the v2 authority reads as an earlier
    -- schema: a block pasted as the guide says was `needs_recheck` forever, never `proved`.
    let fp := match (pc.findEntry qual).bind (·.subjectDigest) with
      | some d => s!"#[proof_fingerprint(\"v2:{shortHash d}\")]"
      | none => "// #[proof_fingerprint(...)]   ← the subject digest is not computable (facts incomplete); nothing can be pinned"
    String.join [
      s!"// in-source proof link for `{qual}` — paste this block above the function.\n",
      req "spec" e.spec, "\n",
      req "proof_by" e.proof, "\n",
      ens, "\n",
      req "proof_coverage" e.coverage, "\n",
      fp, "\n" ]

/-- `concrete prove --show-obligation <id>`: print one generated loop obligation
    (O1/O2/O3/O4/O5) in full — source span, hypotheses, conclusion, current
    discharge status, suggested ProofKit imports, and the theorem shape to
    write (or a note that omega already closes it). `provedVCs` are the omega
    discharge results from the caller. -/
def showObligation (modules : List Module) (qualName oblId0 : String)
    (provedVCs : List String) : String := Id.run do
  -- Accept either the short id ("O4") or the stable id ("<qual>@<line>#O4").
  let oblId := (oblId0.splitOn "#").getLast!
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName)
    |>.map Prod.snd
  match astFn? with
  | none => return s!"no function `{qualName}` found."
  | some f =>
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    for lc in f.loopContracts do
      let invs := lc.invariants.filterMap toLeanProp
      let guardStr := (lc.guard.bind toLeanProp).getD "<guard>"
      let variantStr := (lc.variant.bind toLeanProp).getD "<variant>"
      let variantBody := (lc.variant.map (substContract lc.body)).bind toLeanProp |>.getD "<variant'>"
      -- (label, hypotheses, conclusion, theorem-shape-when-not-omega)
      let info : Option (String × List String × String × String) := match oblId with
        | "O1" => some ("invariant_init", ["loop-entry state (counter at its initializer)"],
                        (genInitVC lc extraLets).getD "?", "(none — omega closes it)")
        | "O2" => some ("invariant_preservation",
                        invs ++ [guardStr],
                        " ∧ ".intercalate ((lc.invariants.map (substContract lc.body)).filterMap toLeanProp),
                        (genPreservationShape lc qualName).getD "(operational step needs a Lean eval lemma)")
        | "O3" => some ("loop_exit_post_link", invs ++ [s!"¬({guardStr})"],
                        (genExitVC lc f.ensures retExpr).getD "(no groundable #[ensures] at loop exit)", "(none — omega closes it once grounded)")
        | "O4" => some ("variant_nonnegative", invs ++ [guardStr], s!"0 ≤ {variantStr}", "(none — omega closes it)")
        | "O5" => some ("variant_decreases", invs ++ [guardStr], s!"{variantBody} < {variantStr}", "(none — omega closes it)")
        | _ => none
      match info with
      | none => pure ()
      | some (label, hyps, concl, shape) =>
        let omegaDone := provedVCs.contains (loopVCKey qualName lc.line oblId)
        let leanOp := oblId == "O2"
        let status :=
          if omegaDone && !leanOp then "proved_by_kernel_decision (omega)"
          else if omegaDone && leanOp then "arithmetic step: proved_by_kernel_decision (omega); operational step: needs Lean"
          else "planned"
        let kitHint :=
          if leanOp then "Concrete.ProofKit.Loops (eval_while_count) for the operational step; Concrete.ProofKit.Eval"
          else "Concrete.ProofKit.Loops; the arithmetic leaf closes with omega — no ProofKit lemma needed"
        return String.join [
          s!"=== obligation {oblId} ({label}) for {qualName} ===\n\n",
          s!"source:      {qualName} loop @ line {lc.line}\n",
          s!"status:      {status}\n\n",
          "hypotheses:\n", String.join (hyps.map (s!"  {·}\n")),
          s!"\nconclusion:\n  {concl}\n\n",
          s!"ProofKit:    {kitHint}\n",
          s!"theorem shape:\n  {shape}\n" ]
    return s!"obligation `{oblId}` not found on {qualName} (loops expose O1/O2/O3/O4/O5)."

/-- JSON-escape and quote a string. Shared by the prove JSON emitters. -/
def jsonStr (s : String) : String :=
  "\"" ++ s.foldl (fun a c => a ++ (match c with
    | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\t' => "\\t" | c => c.toString)) "" ++ "\""

/-- `concrete prove --show-obligation <id> --json`: one obligation, structured.
    Carries the same stable id as `--json` / `--report contracts`. Accepts the
    short id ("O4") or the stable id ("<qual>@<line>#O4"). -/
def showObligationJson (modules : List Module) (qualName oblId0 : String)
    (provedVCs : List String) (inputPath : String) : String := Id.run do
  let oblId := (oblId0.splitOn "#").getLast!
  let q := jsonStr
  let qarr := fun (xs : List String) => "[" ++ ", ".intercalate (xs.map q) ++ "]"
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
  match astFn? with
  | none => return s!"\{\"error\": {q s!"no function '{qualName}'"}}"
  | some f =>
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    for lc in f.loopContracts do
      match loopObInfo lc oblId qualName f.ensures extraLets retExpr provedVCs with
      | none => pure ()
      | some (kind, hyps, concl, status) =>
        let shape := if oblId == "O2" then (genPreservationShape lc qualName).getD "" else ""
        let kit := if oblId == "O2" then ["Concrete.ProofKit.Loops", "Concrete.ProofKit.Eval"] else ["Concrete.ProofKit.Loops"]
        let na := if status == "planned" || status == "arithmetic_proved" then
            [String.join ["{\"kind\": \"emit_lean\", \"command\": ", q s!"concrete prove {inputPath} {qualName} --emit-lean", ", \"output_format\": \"text\", \"resolves\": ", q status, "}"]]
          else
            [String.join ["{\"kind\": \"replay\", \"command\": ", q s!"concrete prove {inputPath} {qualName} --replay", ", \"output_format\": \"text\", \"resolves\": \"proved\"}"]]
        return String.join [
          "{\n",
          s!"  \"id\": {q (loopVCKey qualName lc.line oblId)},\n",
          s!"  \"function\": {q qualName},\n",
          s!"  \"kind\": {q kind},\n",
          s!"  \"status\": {q status},\n",
          s!"  \"source_line\": {toString lc.line},\n",
          s!"  \"hypotheses\": {qarr hyps},\n",
          s!"  \"conclusion\": {q concl},\n",
          s!"  \"theorem_shape\": {q shape},\n",
          s!"  \"proofkit_imports\": {qarr kit},\n",
          s!"  \"next_actions\": [{", ".intercalate na}]\n",
          "}" ]
    return s!"\{\"error\": {q s!"obligation '{oblId}' not found on {qualName}"}}"

/-- `concrete prove --emit-link --json`: the link fields + the pasteable block. -/
def emitProofLinkJson (pc : Concrete.ProofCore) (registry : ProofRegistry) (qual inputPath : String) : String :=
  let q := jsonStr
  match registry.find? (·.function == qual) with
  | none => s!"\{\"error\": {q s!"no proof link for '{qual}'"}}"
  | some e =>
    let block := emitProofLink pc registry qual
    String.join [
      "{\n",
      s!"  \"function\": {q qual},\n",
      s!"  \"spec\": {q e.spec},\n",
      s!"  \"proof_by\": {q e.proof},\n",
      s!"  \"ensures_proof\": {match e.ensuresProof with | some t => q t | none => "null"},\n",
      s!"  \"coverage\": {q e.coverage},\n",
      s!"  \"proof_fingerprint\": {q (shortHash e.bodyFingerprint)},\n",
      s!"  \"link_block\": {q block},\n",
      s!"  \"next_actions\": [\{\"kind\": \"paste_link\", \"command\": \"<paste link_block above the function in source>\", \"output_format\": \"none\", \"resolves\": \"missing\"}, \{\"kind\": \"check_proofs\", \"command\": {q s!"concrete {inputPath} --report check-proofs"}, \"output_format\": \"text\", \"resolves\": \"proved\"}]\n",
      "}" ]

/-- Static recipe (tactic, lemmas, note) for an obligation kind — the
    proof-recipe map (linear → omega; preservation → eval_while_count; overflow →
    bv_decide; arrays → ProofKit.Array; etc.). -/
def lemmaRecipeFor (kind : String) : String × List String × String :=
  match kind with
  | "invariant_init" | "variant_nonnegative" | "variant_decreases" | "loop_exit_post_link" =>
      ("omega", [], "linear-integer leaf — omega closes it (no lemma needed)")
  | "invariant_preservation" =>
      ("intros; (omega | eval)", ["Concrete.ProofKit.Loops.eval_while_count", "Concrete.ProofKit.Eval"],
       "arithmetic half closes with omega; operational step uses eval_while_count")
  | "array_bounds" =>
      ("intros; omega", ["Concrete.ProofKit.Array.lookupIndex_set_self", "Concrete.ProofKit.Array.set_in_counter_map"],
       "bound from #[requires]/invariant via omega; array lemmas for body updates")
  | "division_nonzero" => ("intros; omega", [], "divisor ≠ 0 follows from #[requires] via omega")
  | "integer_overflow" =>
      ("intros; bv_decide", [], "interval analysis + widened unsigned bv_decide for var*var; omega for linear")
  | "ensures" =>
      ("(state spec, then refine)", ["Concrete.ProofKit.Refinement"],
       "state the spec; prove `<fn> refines spec`; run --emit-link once proved")
  | _ => ("(unknown)", [], "")

/-- `concrete prove <file> <fn> --nearest-lemmas [<id>] [--json]`: proof-recipe
    hints mapping each obligation kind + detected features to local tactics/
    lemmas. With `oblFilter` set (a stable `<qual>@<line>#<Ox>` id or a short
    `O4`/`ensures`), the recipes are scoped to that one obligation. -/
def nearestLemmas (pc : Concrete.ProofCore) (modules : List Module) (qualName : String)
    (provedVCs : List String) (json : Bool) (oblFilter : Option String := none) : String := Id.run do
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
  let entry? := pc.entries.find? (·.qualName == qualName)
  match astFn?, entry? with
  | some f, some e =>
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    -- collect (id, kind) obligations
    let mut obls : List (String × String) := []
    for lc in f.loopContracts do
      for oid in ["O1", "O2", "O3", "O4", "O5"] do
        match loopObInfo lc oid qualName f.ensures extraLets retExpr provedVCs with
        | some (kind, _, _, _) => obls := obls ++ [(loopVCKey qualName lc.line oid, kind)]
        | none => pure ()
    for _ in f.ensures do obls := obls ++ [(s!"{qualName}#ensures", "ensures")]
    -- scope to a single obligation when an id is given (stable or short form)
    match oblFilter with
    | some want =>
      obls := obls.filter fun (id, _) =>
        id == want || (id.splitOn "#").getLast! == want || id == s!"{qualName}#{want}"
      if obls.isEmpty then
        return if json then s!"\{\"error\": {jsonStr s!"no obligation '{want}' for '{qualName}'"}}"
               else s!"no obligation '{want}' for '{qualName}'."
    | none => pure ()
    -- feature-level lemma families
    let feats := (e.fn.body.flatMap proveStmtFeatures).eraseDups
    let mut featLemmas : List String := []
    if feats.contains "loop" || !f.loopContracts.isEmpty then featLemmas := featLemmas ++ ["Concrete.ProofKit.Loops"]
    if feats.contains "array" then featLemmas := featLemmas ++ ["Concrete.ProofKit.Array"]
    if feats.contains "bitvec" then featLemmas := featLemmas ++ ["Concrete.ProofKit.BitVec", "bv_decide"]
    if feats.contains "call" then featLemmas := featLemmas ++ ["Concrete.ProofKit.Calls"]
    if json then
      let q := jsonStr
      let qarr := fun (xs : List String) => "[" ++ ", ".intercalate (xs.map q) ++ "]"
      let recipes := obls.map fun (id, kind) =>
        let (tac, lemmas, note) := lemmaRecipeFor kind
        String.join ["{\"id\": ", q id, ", \"kind\": ", q kind, ", \"tactic\": ", q tac,
          ", \"lemmas\": ", qarr lemmas, ", \"note\": ", q note, "}"]
      return String.join [
        "{\n",
        s!"  \"function\": {q qualName},\n",
        s!"  \"recipes\": [{", ".intercalate recipes}],\n",
        s!"  \"feature_lemmas\": {qarr featLemmas},\n",
        s!"  \"next_actions\": [\{\"kind\": \"emit_lean\", \"command\": {q s!"concrete prove <file> {qualName} --emit-lean"}, \"output_format\": \"text\", \"resolves\": \"missing\"}]\n",
        "}" ]
    else
      let mut out := s!"=== nearest lemmas / proof recipes: {qualName} ===\n\n"
      for (id, kind) in obls do
        let (tac, lemmas, note) := lemmaRecipeFor kind
        out := out ++ s!"  {id}  ({kind})\n    tactic: {tac}\n"
        if !lemmas.isEmpty then out := out ++ s!"    lemmas: {", ".intercalate lemmas}\n"
        out := out ++ s!"    note:   {note}\n\n"
      out := out ++ s!"feature lemma families: {if featLemmas.isEmpty then "(none)" else ", ".intercalate featLemmas}\n"
      return out
  | _, _ =>
    if json then s!"\{\"error\": {jsonStr s!"no extractable function '{qualName}'"}}"
    else s!"no extractable function '{qualName}' (it may be excluded or blocked)."

/-- `concrete prove <file> <fn> --emit-lean`: a compilable Lean stub for ONE
    function — imports, namespace, the extracted PExpr + PFnDef, a single-entry
    FnTable, an eval helper, obligation TODO blocks (from the loop VCs +
    `#[ensures]`), suggested ProofKit lemmas, and a theorem stub ending in
    `sorry` (no invented proof). -/
def emitLeanStub (pc : Concrete.ProofCore) (registry : ProofRegistry)
    (modules : List Module) (qualName : String) (provedVCs : List String) : String := Id.run do
  let entries := extractionEntriesFromPC pc registry
  match entries.find? (·.qualName == qualName) with
  | none => return s!"-- no function '{qualName}' in ProofCore.\n"
  | some e =>
    if !(e.eligible && e.extracted.isSome) then
      return s!"-- `{qualName}` is not extractable (excluded or blocked); no Lean stub to emit.\n"
    let name := leanSymbol qualName
    let pexpr := match e.extracted with | some p => renderPExprAsLean p | none => "sorry"
    let paramsList := "[" ++ ", ".intercalate (e.params.map (s!"\"{·}\"")) ++ "]"
    -- Same body digest as the lean-stubs generator. BOTH surfaces or neither:
    -- updating one generator and not the other is the drift check_proof_patterns
    -- exists to catch, having already caught exactly that.
    let sbd := match e.extracted with
      | some p => renderSourceBodyDigest p
      | none   => "none"
    let paramSig := " ".intercalate (e.params.map fun p => s!"({p} : Int)")
    let paramBinds := e.params.foldl (fun acc p =>
      s!"({acc}.bind \"{p}\" (.int {p}))") "Env.empty"
    -- obligation TODO blocks (loop VCs + ensures), with recipes
    let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
    let mut oblTodos : List String := []
    let mut featLemmas : List String := []
    match astFn? with
    | some f =>
      let extraLets := letConstMap f.body
      let retExpr := loopExitReturn f.body
      for lc in f.loopContracts do
        for oid in ["O1", "O2", "O3", "O4", "O5"] do
          match loopObInfo lc oid qualName f.ensures extraLets retExpr provedVCs with
          | some (kind, hyps, concl, status) =>
            let (tac, lemmas, _) := lemmaRecipeFor kind
            oblTodos := oblTodos ++ [s!"--   [{loopVCKey qualName lc.line oid}] {kind} ({status})\n--     hyps: {" ∧ ".intercalate hyps}\n--     goal: {concl}\n--     recipe: {tac}{if lemmas.isEmpty then "" else s!" — {", ".intercalate lemmas}"}"]
          | none => pure ()
      for ens in f.ensures do
        oblTodos := oblTodos ++ [s!"--   [{qualName}#ensures] ensures: {Concrete.fmtExpr ens}\n--     recipe: state the spec; prove `{name}_refines_spec`"]
      let feats := match pc.entries.find? (·.qualName == qualName) with
        | some pe => (pe.fn.body.flatMap proveStmtFeatures).eraseDups
        | none => []
      if feats.contains "loop" || !f.loopContracts.isEmpty then featLemmas := featLemmas ++ ["Concrete.ProofKit.Loops"]
      if feats.contains "array" then featLemmas := featLemmas ++ ["Concrete.ProofKit.Array"]
      if feats.contains "bitvec" then featLemmas := featLemmas ++ ["Concrete.ProofKit.BitVec", "bv_decide"]
      if feats.contains "call" then featLemmas := featLemmas ++ ["Concrete.ProofKit.Calls"]
    | none => pure ()
    let oblSection := if oblTodos.isEmpty then "--   (no generated loop/ensures obligations)"
                      else "\n".intercalate oblTodos
    let kitSection := if featLemmas.isEmpty then "Concrete.ProofKit (general)" else ", ".intercalate featLemmas
    -- Split at the last dot: the defining module and declaration name come from
    -- the qualified name, never reconstructed later from a display string.
    -- READ the carried identity. This previously split `qualName` at the last
    -- dot — re-deriving identity from a rendering, and dropping namespace,
    -- schema version and type arguments in the process, so a builtin or a
    -- specialization would have been emitted as a plain user callable.
    -- The OPERATIONAL KEY is the bare SOURCE name, verbatim. Not `leanIdent`-ed:
    -- that is a Lean-identifier transformation, and a generated symbol name must
    -- never double as a semantic key. `PExpr.call` selects by the source name, so
    -- any mangling here produces a key evaluation never asks for.
    let proveKey := qualName.splitOn "." |>.getLast!
    let proveIdLit := match e.callableId with
      | some cid => renderCallableId cid
      | none     => "sorry  -- UNMAPPABLE: no CallableId carried from ProofCore"
    return String.join [
      s!"-- Lean proof stub for `{qualName}` — fill in the spec and replace `sorry`.\n",
      s!"-- Suggested ProofKit lemmas: {kitSection}\n",
      "import Concrete.Proof.Proof\nimport Concrete.ProofKit\n\n",
      s!"namespace Concrete.Proof.Generated.{name}\nopen Concrete.Proof\n\n",
      s!"/-- Extracted from `{qualName}`. -/\ndef {name}Expr : PExpr :=\n    {pexpr}\n\n",
      s!"/-- Semantic identity of `{qualName}`. Generated, not hand-written. -/\n" ++
      s!"def {name}Id : CallableId :=\n  {proveIdLit}\n\n",
      s!"def {name}Fn : PFnDef :=\n  \{ identity := .semantic {name}Id, operationalKey := \"{proveKey}\",\n    sourceBodyDigest := {sbd},\n    displayName := \"{proveKey}\", params := {paramsList}, body := {name}Expr }\n\n",
      -- Dispatch on the OPERATIONAL KEY, not on the Lean symbol. This keyed the
      -- generated symbol (`straight__line_add__three`) while the entry's
      -- operationalKey was the bare name (`add_three`), so `globals` answered
      -- nothing for its own entry: `dispatchResolves` false, no root, and the
      -- table could not bear evidence. The same defect was fixed in the
      -- lean-stubs generator; this second surface still had it, and the typed
      -- check is what surfaced it.
      s!"def fnsGlobals : String → Option PFnDef\n  | \"{proveKey}\" => some {name}Fn\n  | _ => none\n\n",
      s!"/-- Locally bound callables. If this spec applies a fn-typed PARAMETER,\n" ++
      s!"    that is an `.applyVar` node and must be bound HERE, not above: a\n" ++
      s!"    definition of the same name will not answer it (R-0442). -/\n" ++
      s!"def fnsCallables : String → Option PFnDef := fun _ => none\n\n",
      s!"/-- Canonical entries: the evidence-bearing form (R-0004 step 3). -/\n" ++
      s!"def fnsEntries : Array PFnDef := #[{name}Fn]\n\n",
      s!"def fns : FnTable :=\n  \{ entries := fnsEntries, globals := fnsGlobals, callables := fnsCallables }\n\n",
      s!"/-- Integrity, checked by the kernel at build time: every entry\n" ++
      s!"    identified, no duplicate identity, no string key reaching two. -/\n" ++
      s!"example : fns.isEvidenceBearing := by decide\n\n",
      s!"/-- Lookup lemma. An `Array` has no equation lemmas, so a table lookup needs\n" ++
      s!"    this to rewrite; generated with the table so it cannot drift. Tagged\n" ++
      s!"    `proofTable`, NOT `simp`: a generated artifact must not enlarge the\n" ++
      s!"    default simp set for the whole project. Use `simp [proofTable]`. -/\n" ++
      s!"@[proofTable] theorem fns_lookup_{name} :\n    fns.lookupById {name}Id = ({name}Fn).identified? := by\n  rfl\n\n",
      s!"def eval_{name} {paramSig} (fuel : Nat := 20) : Option PVal :=\n  eval fns {paramBinds} fuel {name}Expr\n\n",
      "-- Obligations to discharge:\n", oblSection, "\n\n",
      s!"/-- TODO: replace `sorry` (RHS) with the spec, then prove it. -/\n",
      s!"theorem {name}_refines_spec {paramSig} (fuel : Nat) :\n    eval fns {paramBinds} (fuel + 1) {name}Expr = sorry := by\n  sorry\n\n",
      s!"end Concrete.Proof.Generated.{name}\n" ]

/-- One failed-obligation artifact bundle: a sanitized directory name plus the
    four files written under `.build/prove/<fn>/<dirName>/`. -/
structure ProveArtifact where
  oblId : String
  dirName : String
  context : String      -- context.json
  failedLean : String   -- failed.lean
  command : String      -- command.txt
  readme : String       -- README.txt
  deriving Inhabited

/-- Sanitize an obligation id (`<qual>@<line>#<Ox>`) into a path-safe segment. -/
def artifactDirName (oblId : String) : String :=
  String.ofList (oblId.toList.map fun c =>
    if c.isAlphanum || c == '_' || c == '-' then c else '_')

/-- `concrete prove <file> <fn> --emit-artifacts`: collect every obligation that
    does NOT currently close — loop VCs absent from `provedVCs`, call-site VCs in
    `failingCalls`, and (when the function itself is `missing`/`stale`/`blocked`)
    a function-level refinement artifact. Each becomes a reproducible bundle an
    agent can pick up without loading the whole flagship proof. Returns `[]` for a
    cleanly-proved function. -/
def proveArtifacts (pc : Concrete.ProofCore) (registry : ProofRegistry)
    (modules : List Module) (qualName inputPath : String)
    (provedVCs : List String) (failingCalls : List (Nat × String))
    (proveStatus : String) : List ProveArtifact := Id.run do
  let q := jsonStr
  let qarr := fun (xs : List String) => "[" ++ ", ".intercalate (xs.map q) ++ "]"
  let stub := emitLeanStub pc registry modules qualName provedVCs
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
  -- shared builder for the four files given the obligation facts
  let mk := fun (oblId shortId kind status srcLine : String)
                (hyps : List String) (concl tactic : String) (lemmas : List String) (note : String) =>
    let ctx := String.join [
      "{\n",
      s!"  \"id\": {q oblId},\n",
      s!"  \"function\": {q qualName},\n",
      s!"  \"input_file\": {q inputPath},\n",
      s!"  \"kind\": {q kind},\n",
      s!"  \"status\": {q status},\n",
      s!"  \"source_line\": {srcLine},\n",
      s!"  \"hypotheses\": {qarr hyps},\n",
      s!"  \"conclusion\": {q concl},\n",
      s!"  \"recipe\": \{\"tactic\": {q tactic}, \"lemmas\": {qarr lemmas}, \"note\": {q note}}\n",
      "}\n" ]
    let cmd := String.join [
      "# Failed obligation: ", oblId, " (", kind, ") — ", status, "\n\n",
      "# 1. inspect this obligation in full:\n",
      s!"concrete prove {inputPath} {qualName} --show-obligation {shortId} --json\n\n",
      "# 2. (re)generate the Lean stub for this function:\n",
      s!"concrete prove {inputPath} {qualName} --emit-lean --out failed.lean --force\n\n",
      "# recipe: ", tactic, (if lemmas.isEmpty then "" else "  [" ++ ", ".intercalate lemmas ++ "]"), "\n\n",
      "# 3. write the proof in failed.lean (or Concrete/Proof.lean), then re-check:\n",
      s!"concrete prove {inputPath} {qualName} --replay --json\n",
      s!"concrete {inputPath} --report check-proofs\n" ]
    let readme := String.join [
      "FAILED OBLIGATION ", oblId, "\n",
      "================", String.ofList (List.replicate oblId.length '='), "\n\n",
      "function:   ", qualName, "\n",
      "file:       ", inputPath, "\n",
      "kind:       ", kind, "\n",
      "status:     ", status, "\n",
      (if srcLine == "0" then "" else s!"source line: {srcLine}\n"),
      "\nhypotheses:\n",
      (if hyps.isEmpty then "  (none)\n" else String.join (hyps.map (s!"  - {·}\n"))),
      "\ngoal:\n  ", concl, "\n\n",
      "suggested recipe:\n  tactic: ", tactic, "\n",
      (if lemmas.isEmpty then "" else "  lemmas: " ++ ", ".intercalate lemmas ++ "\n"),
      "  note:   ", note, "\n\n",
      "Files in this directory:\n",
      "  context.json  — machine-readable obligation facts (id matches --json / --replay / --report contracts)\n",
      "  failed.lean   — compilable single-function Lean stub (ends in `sorry`; fill in and prove)\n",
      "  command.txt   — exact commands to inspect, regenerate, and re-check\n",
      "  README.txt    — this file\n\n",
      "This bundle is self-contained: it does not require loading the flagship proof.\n" ]
    let banner := s!"-- FAILED OBLIGATION: {oblId} ({kind}) — {status}\n-- See command.txt / README.txt in this directory.\n\n"
    ({ oblId, dirName := artifactDirName oblId,
       context := ctx, failedLean := banner ++ stub, command := cmd, readme } : ProveArtifact)
  let mut arts : List ProveArtifact := []
  -- failing loop obligations
  match astFn? with
  | some f =>
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    for lc in f.loopContracts do
      for oid in ["O1", "O2", "O3", "O4", "O5"] do
        match loopObInfo lc oid qualName f.ensures extraLets retExpr provedVCs with
        | some (kind, hyps, concl, _) =>
          let key := loopVCKey qualName lc.line oid
          if !provedVCs.contains key then
            let (tac, lemmas, note) := lemmaRecipeFor kind
            arts := arts ++ [mk key oid kind "fails_to_close" (toString lc.line) hyps concl tac lemmas note]
        | none => pure ()
  | none => pure ()
  -- failing call-site obligations
  for (i, goal) in failingCalls do
    let (tac, lemmas, note) := lemmaRecipeFor "integer_overflow"
    arts := arts ++ [mk s!"{qualName}#call{i}" s!"call{i}" "call_site_safety" "fails_to_close" "0" [] goal tac lemmas note]
  -- function-level: no/stale/blocked proof link
  if proveStatus == "missing" || proveStatus == "stale" || proveStatus == "blocked" then
    let (tac, lemmas, note) := lemmaRecipeFor "ensures"
    let concl := match astFn? with
      | some f => match f.ensures with
                  | e :: _ => Concrete.fmtExpr e
                  | [] => s!"{qualName} refines its specification"
      | none => s!"{qualName} refines its specification"
    let kind := match proveStatus with
      | "stale" => "stale_proof_link" | "blocked" => "blocked" | _ => "missing_proof_link"
    arts := arts ++ [mk s!"{qualName}#refines_spec" "refines_spec" kind proveStatus "0" [] concl tac lemmas note]
  return arts

/-- `concrete prove <file> <fn> --workspace DIR`: compose the read-only prove
    surfaces into one self-contained directory (disposable build output, NOT a
    proof registry). Returns `(relativePath, contents)` pairs the caller writes
    under DIR:
      manifest.json          — `--json` proof report (status/fingerprint/link/next_actions)
      context.json           — proof-authoring inputs (spec/proof refs, ProofKit imports, theorems, feature hints)
      <Fn>Proofs.lean        — the `--emit-lean` stub
      link.con.txt           — the `--emit-link` source attributes
      obligations/<id>.json  — per-obligation facts + lemma recipe + replay/check command
      check.sh / replay.sh   — exact local commands
      README.md              — function-specific workflow -/
def workspaceFiles (pc : Concrete.ProofCore) (registry : ProofRegistry)
    (modules : List Module) (qualName inputPath schemaVersion : String)
    (provedVCs : List String) : List (String × String) := Id.run do
  let q := jsonStr
  let qarr := fun (xs : List String) => "[" ++ ", ".intercalate (xs.map q) ++ "]"
  let leanName := leanIdent (qualName.splitOn "." |>.getLast!)
  let capName := match leanName.toList with
    | c :: rest => String.ofList (c.toUpper :: rest)
    | [] => leanName
  let leanFile := s!"{capName}Proofs.lean"
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName) |>.map Prod.snd
  let regEntry := registry.find? (·.function == qualName)
  -- context.json: the proof-authoring inputs (distinct from manifest's status report)
  let mut hints : List String := []
  let mut suggested : List String := [leanName ++ "_refines_spec"]
  match pc.entries.find? (·.qualName == qualName), astFn? with
  | some e, some f =>
    let feats := (e.fn.body.flatMap proveStmtFeatures).eraseDups
    if feats.contains "loop" || !f.loopContracts.isEmpty then hints := hints ++ ["Concrete.ProofKit.Loops"]
    if feats.contains "array" then hints := hints ++ ["Concrete.ProofKit.Array"]
    if feats.contains "bitvec" then hints := hints ++ ["Concrete.ProofKit.BitVec"]
    if feats.contains "call" then hints := hints ++ ["Concrete.ProofKit.Calls"]
  | _, _ => pure ()
  let linkRefs := match regEntry with
    | some re => String.join [
        "  \"spec\": ", q re.spec, ",\n  \"proof_by\": ", q re.proof,
        ",\n  \"ensures_proof\": ", (match re.ensuresProof with | some t => q t | none => "null"),
        ",\n  \"proof_fingerprint\": ", q (shortHash re.bodyFingerprint), ",\n" ]
    | none => "  \"spec\": null,\n  \"proof_by\": null,\n  \"ensures_proof\": null,\n  \"proof_fingerprint\": null,\n"
  let contextJson := String.join [
    "{\n  \"function\": ", q qualName, ",\n  \"schema_version\": ", q schemaVersion, ",\n",
    linkRefs,
    "  \"proofkit_imports\": ", qarr hints, ",\n",
    "  \"suggested_theorems\": ", qarr suggested, ",\n",
    "  \"lean_stub_file\": ", q leanFile, ",\n",
    "  \"link_file\": \"link.con.txt\"\n}\n" ]
  let mut files : List (String × String) := []
  files := files ++ [("manifest.json", proveReportJson pc registry modules qualName provedVCs inputPath schemaVersion ++ "\n")]
  files := files ++ [("context.json", contextJson)]
  files := files ++ [(leanFile, emitLeanStub pc registry modules qualName provedVCs)]
  files := files ++ [("link.con.txt", emitProofLink pc registry qualName ++ "\n")]
  -- obligations/<id>.json — per-obligation facts + recipe + commands
  let oblFile := fun (id kind status srcLine : String) (hyps : List String) (concl : String) =>
    let (tac, lemmas, note) := lemmaRecipeFor kind
    String.join [
      "{\n  \"id\": ", q id, ",\n  \"function\": ", q qualName,
      ",\n  \"kind\": ", q kind, ",\n  \"status\": ", q status,
      ",\n  \"source_line\": ", srcLine,
      ",\n  \"hypotheses\": ", qarr hyps, ",\n  \"conclusion\": ", q concl,
      ",\n  \"recipe\": {\"tactic\": ", q tac, ", \"lemmas\": ", qarr lemmas, ", \"note\": ", q note, "}",
      ",\n  \"replay_command\": ", q s!"concrete prove {inputPath} {qualName} --replay --json",
      ",\n  \"check_command\": ", q s!"concrete prove {inputPath} {qualName} --check --json", "\n}\n" ]
  match astFn? with
  | some f =>
    let extraLets := letConstMap f.body
    let retExpr := loopExitReturn f.body
    for lc in f.loopContracts do
      for oid in ["O1", "O2", "O3", "O4", "O5"] do
        match loopObInfo lc oid qualName f.ensures extraLets retExpr provedVCs with
        | some (kind, hyps, concl, st) =>
          let id := loopVCKey qualName lc.line oid
          files := files ++ [(s!"obligations/{artifactDirName id}.json", oblFile id kind st (toString lc.line) hyps concl)]
        | none => pure ()
    for ens in f.ensures do
      let reqHyps := f.requires.map Concrete.fmtExpr
      -- R-0479: the default must NOT be a valid status. `.getD "missing"` was here, and `missing`
      -- is a real canonical status (`.notProved => "missing"`), so "no obligation record for this
      -- function" rendered identically to "an obligation exists and is missing". A consumer
      -- comparing against the valid status set accepts both, which is the shape that made a stale
      -- edge-kind line produce a false finding rather than an obvious wrong answer.
      -- An ensures obligation's status is THE verdict (bug 089), never the refinement claim's: the
      -- function's obligation record says whether the BODY is proved, not whether this clause is.
      let st := (ensuresVerdictOf registry qualName).status
      files := files ++ [(s!"obligations/{artifactDirName s!"{qualName}#ensures"}.json", oblFile s!"{qualName}#ensures" "ensures" st (toString f.span.line) reqHyps (Concrete.fmtExpr ens))]
  | none => pure ()
  files := files ++ [("check.sh", s!"#!/usr/bin/env bash\n# Kernel-verify this function's linked Lean proof (structured JSON).\nconcrete prove {inputPath} {qualName} --check --json\n")]
  files := files ++ [("replay.sh", s!"#!/usr/bin/env bash\n# Re-run omega / bv_decide discharge for this function (structured JSON).\nconcrete prove {inputPath} {qualName} --replay --json\n")]
  let readme := String.join [
    s!"# Proof workspace — `{qualName}`\n\n",
    s!"Generated by `concrete prove {inputPath} {qualName} --workspace`.\n\n",
    "This is a **disposable build output**, not a proof registry. The source of\n",
    "truth stays the `.con` file plus its in-source proof attributes. Do not\n",
    "commit this directory.\n\n",
    "## Files\n\n",
    "- `manifest.json` — machine-readable status: eligibility, fingerprint, proof link, next actions.\n",
    "- `context.json` — proof-authoring inputs: spec/proof references, ProofKit imports, suggested theorem names.\n",
    s!"- `{leanFile}` — compilable Lean stub (ends in `sorry`; write the proof here or in Concrete/Proof.lean).\n",
    "- `obligations/<id>.json` — one file per obligation: hypotheses, conclusion, status, lemma recipe, replay/check command.\n",
    "- `link.con.txt` — the in-source `#[spec]/#[proof_by]/...` attributes to paste above the function once proved.\n",
    "- `check.sh` / `replay.sh` — exact local verification commands.\n\n",
    "## Workflow\n\n",
    "1. Read `manifest.json` for status + next actions, and the `obligations/` files for what to prove.\n",
    s!"2. Write the proof in `{leanFile}` (see PROOFKIT_GUIDE for the lemmas in `context.json`).\n",
    "3. `bash check.sh` — kernel-verify. Iterate until `\"all_checked\": true`.\n",
    "4. Paste `link.con.txt` above the function in the `.con` source.\n",
    s!"5. `concrete {inputPath} --report check-proofs` and `concrete audit {inputPath}` to confirm.\n" ]
  files := files ++ [("README.md", readme)]
  return files


end Report
end Concrete
