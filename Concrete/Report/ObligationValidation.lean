import Concrete.Report.ObligationDischarge

/-! Certificate replay, SMT rendering validation and the `#[ensures]` discharge decision. Split out of ReportObligations.lean;
    `Concrete.Report.ReportObligations` imports all three. -/

namespace Concrete
namespace Report

/-! ### Certificate REPLAY (as opposed to kernel corroboration)

`solver_checked` means an independent decision procedure (Rocq `nia`) reached the
same verdict as the SMT solver. That removes the solver from the trusted base, but
it is corroboration: nothing checked the solver's own reasoning.

Replay is strictly stronger. Isabelle's `smt` method, with `smt_oracle = false`,
asks a proof-producing solver for its proof and RECONSTRUCTS every inference in the
HOL kernel — the solver's argument itself is checked, not merely its answer. Two
things make that claim auditable rather than aspirational:

  * `smt_oracle = false` is declared explicitly. Under `smt_oracle = true` the
    method stamps the goal instead of checking it, which is precisely the trust leak
    replay exists to close.
  * the emitted theory ASSERTS the resulting theorem carries no oracle
    (`Thm_Deps.all_oracles`), so a stamped proof fails the build rather than passing
    as a replayed one. Verified in both directions: the assertion passes under
    `smt_oracle = false` and fires under `smt_oracle = true`.

Measured limitation, and the reason this does not simply replace `solver_checked`:
reconstruction handles LINEAR integer arithmetic but not nonlinear. Checked against
all three proof-producing solvers reachable here — z3 4.4.0pre (bundled with
Isabelle for exactly this purpose), cvc5, and veriT 2021.06.2 — every one
reconstructs a linear goal and every one fails on `0 ≤ a ⟹ 0 ≤ a * a`, at a 120s
timeout. Since the SMT path exists precisely for the nonlinear VCs the kernel tiers
cannot close, replay currently cannot upgrade them, and `solver_checked` remains
the ceiling for that family. The machinery is wired anyway: it reports the honest
status per goal today, and any goal that becomes replayable graduates on its own. -/

/-- Isabelle driver that REPLAYS a proof-producing solver's proof through the HOL
    kernel, rather than re-deciding the goal with another decision procedure. -/
def isabelleSmtReplayLowering : ProverLowering where
  name := "isabelle-smt-verit"
  binop := isabelleBinOp
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "
    let arrows := String.join (hyps.map (fun h => s!"({h}) --> "))
    "\n".intercalate
      [ "theory VC imports Main begin",
        "(* certificate REPLAY: the solver's proof is reconstructed in the HOL kernel. *)",
        "declare [[smt_oracle = false, smt_timeout = 60]]",
        s!"lemma replayed: \"{binder}{arrows}{concl}\"",
        "  by (smt (verit))",
        "(* A replayed proof must carry NO oracle. Under smt_oracle = true the method",
        "   stamps the result instead of checking it; that must fail, not pass. *)",
        "ML \\<open>",
        "  val n = length (Thm_Deps.all_oracles [@{thm replayed}]);",
        "  val _ = if n = 0 then writeln \"REPLAY-VERIFIED: no oracle\"",
        "          else error \"ORACLE PRESENT - proof was stamped, not checked\";",
        "\\<close>",
        "end" ]
  arrow := "-->"
  binder := fun vars =>
    if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "

/-- `(vcKey, isabelleTheorySource)` replaying each SMT-eligible NONLINEAR overflow
    obligation through the HOL kernel. Same selection as `rocqNiaGoals`, so the
    `solver-cert` report can show corroboration and replay side by side on one goal. -/
def isabelleSmtReplayGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in smtEligibleOverflow modules do
    let concl : Option String := do
      let e ← exprToProver isabelleBinOp o.opExpr
      let lo ← isabelleBinOp .leq (toString o.lo) e
      let hi ← isabelleBinOp .leq e (toString o.hi)
      isabelleBinOp .and_ lo hi
    match concl, o.hyps.mapM (exprToProver isabelleBinOp) with
    | some c, some hyps =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      out := out ++ [(o.key, isabelleSmtReplayLowering.render vars hyps c)]
    | _, _ => pure ()
  return out

/-- `(vcKey, coqSource)` for each linear overflow obligation (Rocq driver). -/
def rocqReplayGoals (modules : List Module) : List (String × String) :=
  proverReplayGoals rocqLowering modules

/-- `(vcKey, isabelleTheorySource)` for each linear overflow obligation (Isabelle). -/
def isabelleReplayGoals (modules : List Module) : List (String × String) :=
  proverReplayGoals isabelleLowering modules

/-! ### SMT rendering validation — the one-printer-many-tools path, finally checked

`exprToSmt` renders an obligation once and feeds z3, cvc5, veriT and any other SMT-LIB
consumer. That makes it the CHEAPEST diversity in the system — one printer, N tools —
and it was the only lowering with no agreement check at all, while its verdict enters the
TCB as `solver_trusted` with no kernel re-deriving it. R-0450 named the gap; this closes
the rendering half of it.

Same method as the prover drivers, adapted to SMT's shape. Variables are PINNED with
equality assertions rather than substituted away, so `exprToSmt` is exercised verbatim —
the point is to test the printer we actually use, not a variant of it. Each instance is
its own query because `(check-sat)` is per-script: batching would ask one question about a
conjunction and lose which instance disagreed.

Truth-table comparison, not provability: for a ground instance the reference evaluator says
TRUE or FALSE, and the solver must AGREE. Reference true → asserting the negation must be
`unsat`. Reference false → asserting the formula itself must be `unsat`. Either way the
expected answer is `unsat`, so `sat` is a genuine disagreement and `unknown` is our problem
rather than the printer's. -/

/-- SMT-LIB operator column, so the family-neutral `mkConcl` can render a conclusion in
    prefix form exactly as `exprToSmt` would. Deliberately partial: an operator with no
    entry yields `none` and the obligation is skipped rather than rendered approximately.
    A wrong column here would make the check pass against a formula the solver never
    sees, which is the failure this whole mechanism exists to detect. -/
def smtBinOpColumn : BinOp → String → String → Option String
  | .leq,  l, r => some s!"(<= {l} {r})"
  | .lt,   l, r => some s!"(< {l} {r})"
  | .geq,  l, r => some s!"(>= {l} {r})"
  | .gt,   l, r => some s!"(> {l} {r})"
  | .eq,   l, r => some s!"(= {l} {r})"
  | .neq,  l, r => some s!"(not (= {l} {r}))"
  | .and_, l, r => some s!"(and {l} {r})"
  | .or_,  l, r => some s!"(or {l} {r})"
  | _,     _, _ => none

/-- `(instanceKey, smtLibQuery)` validating that `exprToSmt`'s rendering of each obligation
    denotes the obligation. Keys are `{obligationKey}#smtagree{i}` so a disagreement names
    the instance; `validatedKeysOf`-style consumers strip the suffix. -/
def smtAgreementGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  -- `requireLeanGoal := false` is essential, not incidental. The default view is the OMEGA
  -- domain (linear); the SMT VERDICT path is the complement — it takes only obligations with
  -- a nonlinear multiplication, because omega owns the linear case. Validating the default
  -- view would therefore check `exprToSmt` on exactly the obligations SMT never renders for
  -- a verdict, and the two key sets would be disjoint. Measured before this was fixed.
  for o in multiKernelObligations modules (requireLeanGoal := false) do
    let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
    match exprToSmt o.mainExpr, o.hyps.mapM exprToSmt with
    | some eSmt, some hypSmts =>
      match o.mkConcl smtBinOpColumn eSmt with
      | none => pure ()          -- conclusion outside the SMT column: skip, never guess
      | some conclSmt =>
        let base := if vars.length ≥ 4 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647]
                    else fuzzGrid
        let grid := if vars.length ≥ 3 then base else agreementGrid o base
        let mut i := 0
        for env in (cartesianEnvs vars grid).take agreementInstanceCap do
          -- Reference value of the WHOLE obligation under this assignment. Vacuous when
          -- the hypotheses do not hold, which is still a row worth checking: a rendering
          -- that mangles a hypothesis shows up as disagreement exactly there.
          let hypsTrue := o.hyps.all (fun h => evalBoolEnv env h == some true)
          let refVal := if hypsTrue then o.safeOn env else some true
          match refVal with
          | none => pure ()      -- not evaluable: no reference to compare against
          | some rv =>
            let impl := if hypSmts.isEmpty then conclSmt
                        else s!"(=> (and {" ".intercalate hypSmts}) {conclSmt})"
            -- Reference TRUE  => negation must be unsat.
            -- Reference FALSE => the formula itself must be unsat.
            let asserted := if rv then s!"(not {impl})" else impl
            let decls := vars.map (fun v => s!"(declare-const {v} Int)")
            let pins := env.map (fun (v, k) =>
              s!"(assert (= {v} {if k < 0 then s!"(- {-k})" else toString k}))")
            let q := "(set-logic ALL)\n"
              ++ String.intercalate "\n" decls ++ "\n"
              ++ String.intercalate "\n" pins ++ "\n"
              ++ s!"(assert {asserted})\n(check-sat)\n"
            out := out ++ [(s!"{o.key}#smtagree{i}", q)]
            i := i + 1
    | _, _ => pure ()
  return out

/-- `(vcKey, coqSource)` ground-instance agreement scripts for the Rocq driver. -/
def rocqAgreementGoals (modules : List Module) : List (String × String) :=
  loweringAgreementScripts rocqLowering modules

/-- `(vcKey, isabelleTheorySource)` ground-instance agreement scripts (Isabelle). -/
def isabelleAgreementGoals (modules : List Module) : List (String × String) :=
  loweringAgreementScripts isabelleLowering modules

/-- `(vcKey, leanTheoremSource)` for each SMT-eligible VC: a self-contained Lean
    theorem restating the obligation, with a `by omega` proof attempt. Same
    selection as `overflowSmtGoals`. -/
def leanReplayGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in overflowObligations modules do
    if o.closedVerdict.isSome then continue
    if o.bvGoal.isSome then continue
    if !exprHasNonlinMul o.opExpr then continue
    match exprToLeanProp o.opExpr, o.hyps.mapM exprToLeanProp with
    | some eProp, some hypProps =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      let binders := if vars.isEmpty then "" else s!"({" ".intercalate vars} : Int) "
      let hypBinders := " ".intercalate
        ((List.range hypProps.length).zip hypProps |>.map (fun (i, h) => s!"(h{i} : {h})"))
      let concl := s!"({o.lo} ≤ {eProp}) ∧ ({eProp} ≤ {o.hi})"
      -- `by omega` is the in-toolchain attempt; a Mathlib build swaps in `nlinarith`.
      let src := s!"theorem vc_replay {binders}{hypBinders} : {concl} := by omega"
      out := out ++ [(o.key, src)]
    | _, _ => pure ()
  return out

/-- Render the integer-overflow section. `provedKeys` are omega-discharged;
    `bvProvedKeys` are discharged by the widened `bv_decide` (nonlinear) path. -/
def renderOverflow (obls : List OverflowObl) (provedKeys : List String)
    (bvProvedKeys : List String := []) : String := Id.run do
  if obls.isEmpty then return ""
  let mut out := "\n\n=== Runtime-safety obligations (integer overflow, #[overflow_checked]) ==="
  let mut cur := ""
  for o in obls do
    if o.fnQual != cur then out := out ++ s!"\n\n{o.fnQual}"; cur := o.fnQual
    let status := match o.closedVerdict with
      | some true  => "checked: result in range (constant)"
      | some false => "VIOLATION: constant overflows the type"
      | none =>
        if provedKeys.contains o.key then
          "proved_by_kernel_decision (omega) — cannot overflow, no runtime check needed"
        else if bvProvedKeys.contains o.key then
          "proved_by_kernel_decision (bv_decide) — bounded operands cannot overflow (interval + bitvector), no runtime check needed"
        else match o.leanGoal with
          | some _ => "unproven — bound the operands (#[requires]), or use a wrapping/checked profile"
          | none => "unproven — operands not statically analyzable"
    out := out ++ s!"\n  {Concrete.fmtExpr o.opExpr}  (range [{o.lo}, {o.hi}])\n    status: {status}"
  return out ++ "\n"

/-- Runtime-safety obligations that have already been discharged to FALSE.
    These are compile-time proofs that the safe program is wrong, not merely
    `unproven` obligations. Build/check paths use this as a hard-error gate;
    report paths still render the obligations so users can inspect them. -/
def provenViolationDiagnostics (modules : List Module) : Diagnostics := Id.run do
  -- Safe-code only: functions marked `trusted` or holding the `Unsafe`
  -- capability carry audit responsibility and are exempt (ROADMAP Phase 12 #0).
  let unsafeQuals : List String := (modules.flatMap allFunctions).filterMap fun (pfx, f) =>
    if f.isTrusted || Capabilities.capSetHasUnsafe f.capSet then some (pfx ++ f.name) else none
  let mut ds : Diagnostics := []
  for o in boundsObligations modules do
    if o.closedVerdict == some false && !unsafeQuals.contains o.fnQual then
      let d : Diagnostic := {
        severity := .error,
        message := s!"proven runtime-safety violation: {o.arrName}[{Concrete.fmtExpr o.idxExpr}] is always out of bounds for array size {o.size}",
        pass := "runtime-safety",
        span := some o.idxExpr.getSpan,
        hint := some "fix the index, change the array size, or move this behind an explicit trusted/Unsafe boundary",
        code := "E0900",
        evidence := [("obligation", o.key), ("status", "violation"), ("kind", "array_bounds")]
      }
      ds := ds ++ [d]
  for o in divObligations modules do
    if o.closedVerdict == some false && !unsafeQuals.contains o.fnQual then
      let opname := if o.isMod then "%" else "/"
      let d : Diagnostic := {
        severity := .error,
        message := s!"proven runtime-safety violation: {opname} divisor {Concrete.fmtExpr o.divExpr} is always zero",
        pass := "runtime-safety",
        span := some o.divExpr.getSpan,
        hint := some "require/prove a nonzero divisor, use a checked API, or move this behind an explicit trusted/Unsafe boundary",
        code := "E0900",
        evidence := [("obligation", o.key), ("status", "violation"), ("kind", "division_nonzero")]
      }
      ds := ds ++ [d]
  for o in overflowObligations modules do
    if o.closedVerdict == some false && !unsafeQuals.contains o.fnQual then
      let d : Diagnostic := {
        severity := .error,
        message := s!"proven runtime-safety violation: {Concrete.fmtExpr o.opExpr} always overflows range [{o.lo}, {o.hi}]",
        pass := "runtime-safety",
        span := some o.opExpr.getSpan,
        hint := some "widen the type, bound the operands, or use an explicit wrapping/checked arithmetic profile",
        code := "E0900",
        evidence := [("obligation", o.key), ("status", "violation"), ("kind", "integer_overflow")]
      }
      ds := ds ++ [d]
  return ds

/-- Collect the loop VCs that a kernel decision procedure can discharge:
    `invariant_init` (O1), `variant_nonnegative` (O4), `variant_decreases` (O5).
    Each is `(key, leanGoal)` where the goal is the same string the report
    shows — it is already valid Lean (`∀ (i : Int), … `) provable by
    `intros; omega`. Preservation (O2) stays hand-linked; exit-link (O3) needs a
    postcondition. -/
-- spec: CON-2 (docs/spec/contracts.md; this declaration enforces the rule)
def loopVCGoals (modules : List Module) : List (String × String) := Id.run do
  let withLoops := (modules.flatMap allFunctions).filter (fun (_, f) => !f.loopContracts.isEmpty)
  let mut out : List (String × String) := []
  for (pfx, f) in withLoops do
    let extraLets := letConstMap f.body
    let fq := pfx ++ f.name
    let retExpr := loopExitReturn f.body
    -- Phase 3 #9: thread the function's `#[requires]` into every loop obligation
    -- (the unified scoped context). Adding hypotheses is monotonic — it can only
    -- turn an `unproven` loop VC `proved` (e.g. an init `0 ≤ n` from a precondition),
    -- never the reverse.
    let outer := f.requires
    for lc in f.loopContracts do
      if let some g := genInitVC lc extraLets outer then
        out := out ++ [(loopVCKey fq lc.line "O1", g)]
      -- O2 arithmetic half: invariant is inductive (omega); operational half
      -- still needs Lean (genPreservationShape).
      if let some g := genPreservationGoal lc outer then
        out := out ++ [(loopVCKey fq lc.line "O2", g)]
      if let some g := genExitVC lc f.ensures retExpr outer then
        out := out ++ [(loopVCKey fq lc.line "O3", g)]
      if lc.variant.isSome then
        if let some g := genVariantNonneg lc outer then
          out := out ++ [(loopVCKey fq lc.line "O4", g)]
        if let some g := genVariantDecreases lc outer then
          out := out ++ [(loopVCKey fq lc.line "O5", g)]
  return out

/-- The loop-contract section: for each `#[invariant]`/`#[variant]`-annotated
    loop, enumerate the verification obligations it induces. Every obligation now
    carries a compiler-generated VC shape. Discharge: preservation (O2) is
    hand-linked via a `coverage: invariant` registry entry; init/variant
    (O1/O4/O5) are kernel-discharged by `omega` when their key appears in
    `provedVCs`; the rest are `planned`. -/
def loopContractSection (modules : List Module) (_registry : ProofRegistry)
    (provedVCs : List String := []) (provedVacuous : List String := []) : String := Id.run do
  let withLoops := (modules.flatMap allFunctions).filter (fun (_, f) => !f.loopContracts.isEmpty)
  if withLoops.isEmpty then return ""
  let callables := callableContractNames modules
  let consts := contractConstNames modules
  let impures := impureFnNames modules
  let mut out := "\n\n=== Loop contracts ==="
  for (pfx, f) in withLoops do
    -- A COVERAGE LABEL IS NOT EVIDENCE (bug 079 follow-up). This used to discharge the loop's
    -- invariant-preservation step whenever the link said `coverage: invariant` and named a proof —
    -- `loop_invariant.count_up` read `proved_by_lean` here while its claim was `spec_unbound`. A loop
    -- step is discharged by a theorem only once a loop-step binding ties that theorem to this loop;
    -- none exists yet (ROADMAP soundness track), so no label discharges anything.
    let preserveProof : Option String := none
    let extraLets := letConstMap f.body
    let fq := pfx ++ f.name
    let outer := f.requires  -- Phase 3 #9: function preconditions are in scope for loop VCs
    let contractVars := (f.params.map (·.name) ++ localNamesB f.body ++ consts).eraseDups
    for lc in f.loopContracts do
      out := out ++ s!"\n\n{pfx}{f.name}  (loop @ line {lc.line})"
      let mut invIdx := 0
      for inv in lc.invariants do
        let issues := validateContractExpr contractVars callables inv
          ++ (contractImpureCalls impures inv).map (fun fn => s!"impure call '{fn}' — spec/ghost must be pure and total (no capabilities)")
        let vac := cEvalBool inv == some false || provedVacuous.contains s!"{fq}@{lc.line}#inv_vac{invIdx}"
        let st :=
          if !issues.isEmpty then contractIssueStatus issues
          else if vac then "\n     status:  invalid/vacuous (unsatisfiable invariant — the loop obligations below are meaningless)"
          else ""
        out := out ++ s!"\n  invariant {Concrete.fmtExpr inv}{st}"
        invIdx := invIdx + 1
      match lc.variant with
      | some v => out := out ++ s!"\n  variant   {Concrete.fmtExpr v}{contractIssueStatus (validateContractExpr contractVars callables v)}"
      | none => pure ()
      out := out ++ "\n  obligations:"
      let planned := "planned (no discharge backend linked yet)"
      let vc := fun (g : Option String) => match g with | some s => s!"\n       generated VC:  {s}" | none => ""
      -- Kernel-decision status for an obligation: omega-discharged when its key
      -- is in `provedVCs`, else planned. `omega` is a kernel decision procedure
      -- (linear integer arithmetic), no external SMT in the TCB.
      let kstat := fun (obl : String) =>
        if provedVCs.contains (loopVCKey fq lc.line obl)
        then "proved_by_kernel_decision\n                                engine:  omega"
        else planned
      -- O1 invariant_init — generated shape, kernel-discharged
      out := out ++ s!"\n    O1 invariant_init          status:  {kstat "O1"}{vc (genInitVC lc extraLets outer)}"
      -- O2 invariant_preservation — split into the two things it actually
      -- requires: (1) the arithmetic step (invariant is inductive), now
      -- auto-discharged by omega; (2) the operational step (the extracted body
      -- realizes the substitution), which still needs Lean. (1) removes most of
      -- the hand-linking; (2) points to the theorem shape when unproved.
      let arithStep :=
        if provedVCs.contains (loopVCKey fq lc.line "O2")
        then "proved_by_kernel_decision (omega)" else planned
      let opStep := match preserveProof with
        | some thm => s!"proved_by_lean\n                          theorem: {thm}"
        | none => match genPreservationShape lc fq with
          | some shape => s!"planned — needs Lean (operational realization), shape:\n           {shape}"
          | none => planned
      out := out ++ s!"\n    O2 invariant_preservation"
      out := out ++ s!"\n       arithmetic step:   {arithStep}"
      out := out ++ s!"\n       operational step:  {opStep}{vc (genPreservationVC lc)}"
      -- O3 exit_implies_post: bridges loop exit facts (invariant ∧ ¬guard) to
      -- the function #[ensures]. Generated only when there is an ensures and a
      -- clean loop-exit return; kernel-discharged by omega like O1/O4/O5.
      let exitVC := genExitVC lc f.ensures (loopExitReturn f.body) outer
      let o3status :=
        if exitVC.isSome then kstat "O3"
        else if f.ensures.isEmpty then "n/a (no #[ensures] postcondition)"
        else planned
      out := out ++ s!"\n    O3 loop_exit_post_link     status:  {o3status}{vc exitVC}"
      match lc.variant with
      | some _ =>
        out := out ++ s!"\n    O4 variant_nonnegative     status:  {kstat "O4"}{vc (genVariantNonneg lc outer)}"
        out := out ++ s!"\n    O5 variant_decreases       status:  {kstat "O5"}{vc (genVariantDecreases lc outer)}"
      | none => pure ()
  return out ++ "\n"

/-! ### The `#[ensures]` discharge decision (bug 089)

An `#[ensures(P)]` obligation is discharged by a theorem only when THREE things hold:

1. the kernel accepted the theorem (a replay, not a name in source);
2. the theorem is about THIS function's body — its specification value is the extracted body with
   these parameters (the bug-079 subject binding, `subjectBindingOf`);
3. the theorem's CONCLUSION is the clause `P`, under the function's parameters and `result`.

No checked matcher for (3) exists yet: that is ROADMAP "Exact property acceptance". Until it does,
NO link discharges an `#[ensures]`, whatever it names and whatever `#[proof_coverage]` says. Before
this, `contracts`, `vcs`, `obligation-ledger` and `audit` each decided from the registry entry alone
and printed `proved_by_lean` for `#[ensures_proof(No.Such.Theorem)] #[ensures(result == 42)]` on
`return x` — no Lean ran, and the clause is false.

This is the ONE answer. Every surface — the contracts renderer, the VC schedule (and through it the
obligation ledger and audit), `concrete prove`, and the `check-proofs` ensures section — consumes it
instead of re-reading `ensuresProof`/`coverage` from the registry. When the matcher lands, it is
added here and nowhere else. -/
inductive EnsuresVerdict where
  /-- No link offers any theorem for this function's postcondition. -/
  | noLink
  /-- Theorem(s) are linked, but nothing checks that any of them concludes the clause. -/
  | unmatched (theorems : List String)
  deriving BEq, Repr

/-- The canonical obligation status of a verdict. Never a proof class: `unproven` for a link that
    proves nothing checked, `missing` when there is no link at all. -/
def EnsuresVerdict.status : EnsuresVerdict → String
  | .noLink => "missing"
  | .unmatched _ => "unproven"

/-- The theorems a link OFFERS for the postcondition — the dependency edge a reader can follow. -/
def EnsuresVerdict.theorems : EnsuresVerdict → List String
  | .noLink => []
  | .unmatched ts => ts

/-- Why the clause is not discharged, in one sentence. -/
def EnsuresVerdict.reason : EnsuresVerdict → String
  | .noLink => "no #[ensures_proof] links a theorem to this postcondition"
  | .unmatched _ =>
    "no checked matcher confirms a linked theorem's conclusion is this clause (exact property acceptance is not implemented); a link and a #[proof_coverage] label are not evidence"

/-- THE decision (bug 089). Offered theorems: the `#[ensures_proof]` theorem, and the `#[proof_by]`
    theorem when a `#[proof_coverage]` label claims it covers the postcondition (`iff`,
    `one_direction`). Either way the verdict is `unmatched` — see the section comment. -/
def ensuresVerdictOf (registry : ProofRegistry) (qual : String) : EnsuresVerdict :=
  match registry.find? (·.function == qual) with
  | none => .noLink
  | some e =>
    let coverageClaim := (e.coverage == "iff" || e.coverage == "one_direction") && !e.proof.isEmpty
    let offered := e.ensuresProof.toList ++ (if coverageClaim then [e.proof] else [])
    if offered.isEmpty then .noLink else .unmatched offered.eraseDups

-- No verdict is a proof class: the property this whole section exists to hold.
example (v : EnsuresVerdict) : v.status ≠ "proved_by_lean" ∧ v.status ≠ "partial" := by
  cases v <;> simp [EnsuresVerdict.status]

partial def contractsReport (modules : List Module) (registry : ProofRegistry)
    (provedVCs : List String := []) (provedVacuous : List String := []) : String := Id.run do
  let callables := callableContractNames modules
  let consts := contractConstNames modules
  let impures := impureFnNames modules
  -- Discharge status for an `#[ensures]` on `qual`: rendered from THE verdict (bug 089), never
  -- re-derived here from the registry entry.
  let discharge (qual : String) : String :=
    let v := ensuresVerdictOf registry qual
    match v with
    | .noLink =>
      if (registry.find? (·.function == qual)).isSome then "\n     status:  missing (registry entry has no ensures_proof)"
      else "\n     status:  missing (no in-source proof link for this function)"
    | .unmatched _ => s!"\n     status:  unproven — NOT discharged\n     linked:  {", ".intercalate v.theorems}\n     note:    {v.reason}"
  let rec go (m : Module) (acc : String) : String := Id.run do
    let mut out := acc
    let pfx := if m.name.isEmpty then "" else m.name ++ "."
    for sf in m.specFns do
      let ps := ", ".intercalate (sf.params.map (fun p => s!"{p.name}: {Concrete.fmtTy p.ty}"))
      out := out ++ s!"\nspec fn {pfx}{sf.name}({ps}) -> {Concrete.fmtTy sf.retTy}"
    for f in m.functions do
      if !f.ensures.isEmpty || !f.requires.isEmpty then
        out := out ++ s!"\n\n{pfx}{f.name}"
        let paramVars := f.params.map (·.name)
        let postVars := (paramVars ++ ["result"] ++ localNamesB f.body ++ consts).eraseDups
        let preVars := (paramVars ++ consts).eraseDups
        -- vacuity: an unsatisfiable precondition makes every #[ensures] hold
        -- trivially — a misleading green. Caught by the constant folder
        -- (#[requires(false)]) or by omega refuting the conjunction (x>0 && x<0).
        let vacuous := !f.requires.isEmpty
          && (f.requires.any (fun r => cEvalBool r == some false)
              || provedVacuous.contains s!"{pfx ++ f.name}#requires_vac")
        if vacuous then
          out := out ++ "\n  ⚠ VACUOUS — preconditions are unsatisfiable; any #[ensures] holds trivially (NOT a real proof)"
        -- preconditions: assumed on entry here; each call site is checked
        -- separately (see the "Call-site obligations" section).
        let mut ri := 1
        for r in f.requires do
          let issues := validateContractExpr preVars callables r
            ++ (contractImpureCalls impures r).map (fun fn => s!"impure call '{fn}' — spec/ghost must be pure and total (no capabilities)")
          let st :=
            if !issues.isEmpty then contractIssueStatus issues
            else if vacuous then "\n     status:  vacuous (unsatisfiable precondition)"
            else "\n     status:  assumed_at_entry (each call site checked separately)"
          out := out ++ s!"\n  R{ri}  requires {Concrete.fmtExpr r}{st}"
          ri := ri + 1
        -- postconditions: vacuous if the precondition is unsatisfiable, else
        -- decided by `ensuresVerdictOf` (bug 089): no link discharges a clause yet.
        let mut i := 1
        for e in f.ensures do
          let issues := validateContractExpr postVars callables e
            ++ (contractImpureCalls impures e).map (fun fn => s!"impure call '{fn}' — spec/ghost must be pure and total (no capabilities)")
          let st :=
            if !issues.isEmpty then contractIssueStatus issues
            else if vacuous then "\n     status:  vacuous (precondition unsatisfiable — postcondition holds trivially, NOT proved)"
            else discharge (pfx ++ f.name)
          out := out ++ s!"\n  O{i}  ensures {Concrete.fmtExpr e}{st}"
          i := i + 1
    for sub in m.submodules do
      out := go sub out
    return out
  let body := modules.foldl (fun acc m => go m acc) ""
  let body := if body.isEmpty then "\n(no spec fns or #[ensures] contracts found)" else body
  return s!"=== Source Contracts ==={body}\n{loopContractSection modules registry provedVCs provedVacuous}"

/-- Whether any module (or submodule) carries a source contract — a `spec fn`
    or an `#[ensures(...)]`. Used to decide whether `audit` appends the
    contracts section. -/
partial def hasContracts (modules : List Module) : Bool :=
  modules.any fun m =>
    !m.specFns.isEmpty
    || m.functions.any (fun f => !f.ensures.isEmpty || !f.requires.isEmpty || !f.loopContracts.isEmpty
        || !(f.body.flatMap collectAssertAssumeS).isEmpty)
    || hasContracts m.submodules

def interfaceReport (summaryTable : List (String × FileSummary)) : String :=
  let header := "=== Interface Summary ==="
  let body := summaryTable.map fun (name, fs) => interfaceModule name fs
  let totalExports := summaryTable.foldl (fun acc (_, fs) =>
    let pubCount := (fs.functions.filter fun (n, _) => fs.publicNames.contains n).length +
      (fs.externFns.filter (·.isPublic)).length +
      (fs.structs.filter (·.isPublic)).length +
      (fs.enums.filter (·.isPublic)).length +
      (fs.traits.filter (·.isPublic)).length +
      (fs.constants.filter (·.isPublic)).length +
      (fs.typeAliases.filter (·.isPublic)).length +
      (fs.newtypes.filter (·.isPublic)).length
    acc + pubCount) 0
  let summary := s!"\nTotals: {summaryTable.length} modules, {totalExports} public exports"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================


end Report
end Concrete
