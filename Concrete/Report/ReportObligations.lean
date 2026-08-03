import Concrete.Elab.Core
import Concrete.Check.Layout
import Concrete.Resolve.FileSummary
import Concrete.Frontend.AST
import Concrete.Resolve.Intrinsic
import Concrete.Proof.Proof
import Concrete.Proof.ProofCore
import Concrete.IR.SSA
import Concrete.Report.Diagnostic
import Concrete.Frontend.Format
import Concrete.Report.ReportBase
import Concrete.Semantics.IntArith
import Concrete.Semantics.Capabilities
-- Obligation collectors need only the contract/VC helper cluster, not the
-- capability/arith/unsafe/layout report renderers (pipeline #34).
import Concrete.Report.ReportVC

namespace Concrete
namespace Report

-- Runtime-safety obligations: array bounds
-- ============================================================
-- A runtime-error class. Every `arr[idx]` into a fixed-size array generates the
-- obligation `0 ≤ idx < N`. Constant indices are evaluated (in-bounds / VIOLATION);
-- variable indices are discharged by `omega` under the function's #[requires]
-- (a kernel decision procedure — statically in bounds, no runtime check needed),
-- or left `unproven` (needs a precondition or a runtime check). This is the
-- runtime_checked evidence class.

mutual
/-- `(arrayName, indexExpr)` for every `arr[idx]` with an identifier base. -/
partial def collectIndexUsesE : Expr → List (String × Expr)
  | .arrayIndex _ (.ident _ arr) idx => (arr, idx) :: collectIndexUsesE idx
  | .arrayIndex _ a idx => collectIndexUsesE a ++ collectIndexUsesE idx
  | .binOp _ _ l r => collectIndexUsesE l ++ collectIndexUsesE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .try_ _ x | .cast _ x _ | .fieldAccess _ x _ => collectIndexUsesE x
  | .arrayLit _ es => es.flatMap collectIndexUsesE
  | .call _ _ _ args => args.flatMap collectIndexUsesE
  | .methodCall _ o _ _ args => collectIndexUsesE o ++ args.flatMap collectIndexUsesE
  | .staticMethodCall _ _ _ _ args => args.flatMap collectIndexUsesE
  | .structLit _ _ _ fs base => fs.flatMap (fun (_, fe) => collectIndexUsesE fe) ++ (base.map collectIndexUsesE).getD []
  | .enumLit _ _ _ _ fs => fs.flatMap (fun (_, fe) => collectIndexUsesE fe)
  | .allocCall _ x a => collectIndexUsesE x ++ collectIndexUsesE a
  | .ifExpr _ c t el =>
      collectIndexUsesE c ++ t.flatMap collectIndexUsesS ++ el.flatMap collectIndexUsesS
  | .match_ _ s _ => collectIndexUsesE s
  | _ => []
partial def collectIndexUsesS : Stmt → List (String × Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectIndexUsesE v
  | .return_ _ (some v) => collectIndexUsesE v
  | .ifElse _ c t el => collectIndexUsesE c ++ t.flatMap collectIndexUsesS ++ (el.getD []).flatMap collectIndexUsesS
  | .while_ _ c b _ => collectIndexUsesE c ++ b.flatMap collectIndexUsesS
  | .forLoop _ init c step b _ =>
      (init.map collectIndexUsesS).getD [] ++ collectIndexUsesE c
        ++ (step.map collectIndexUsesS).getD [] ++ b.flatMap collectIndexUsesS
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectIndexUsesE o ++ collectIndexUsesE v
  | .arrayIndexAssign _ (.ident _ arr) idx v => (arr, idx) :: (collectIndexUsesE idx ++ collectIndexUsesE v)
  | .arrayIndexAssign _ a i v => collectIndexUsesE a ++ collectIndexUsesE i ++ collectIndexUsesE v
  | _ => []
end

-- ============================================================
-- Loop-invariant scope for runtime-safety obligations
-- ============================================================
-- A runtime-safety obligation that occurs inside a loop body may ASSUME the
-- loop's invariant and guard: at the top of the body the invariant holds and
-- the guard was just taken. Feeding those facts to omega lets a body access
-- like `a[i]` discharge from `#[invariant(0 <= i && i <= N)]` + guard `i < N`,
-- instead of demanding a `#[requires]`. SOUNDNESS: the invariant only provably
-- holds until the body mutates a variable it mentions, so the ordered walk
-- below DROPS a hypothesis as soon as a statement assigns to one of its
-- variables (array-element / field / deref stores touch no integer counter, so
-- they invalidate nothing; the canonical `a[i] = …; i = i + 1` therefore keeps
-- the bound at the access and loses it only for statements after the `i = …`).

/-- Loop invariants + guard for the loop whose statement begins on `line`
    (matched against `FnDef.loopContracts` by source line). The facts assumable
    for an obligation in that loop's body. -/
def loopHypsAt (lcs : List LoopContract) (line : Nat) : List Expr :=
  match lcs.find? (·.line == line) with
  | some lc => lc.invariants ++ lc.guard.toList
  | none    => []

/-- Scalar variables a statement assigns to. Mutating one invalidates any
    in-scope hypothesis that mentions it. Array-element / field / deref stores
    assign no integer counter (the domain our invariants range over), so they
    return `[]`; a nested loop invalidates whatever its body assigns. -/
partial def assignedScalarsS : Stmt → List String
  | .assign _ n _ => [n]
  | .letDecl _ n _ _ _ _ => [n]
  | .ifElse _ _ t el => t.flatMap assignedScalarsS ++ (el.getD []).flatMap assignedScalarsS
  | .while_ _ _ b _ => b.flatMap assignedScalarsS
  | .forLoop _ init _ step b _ =>
      (init.map assignedScalarsS).getD [] ++ (step.map assignedScalarsS).getD []
        ++ b.flatMap assignedScalarsS
  | _ => []

/-- Drop every in-scope hypothesis that mentions a just-assigned variable. -/
def dropStaleHyps (scope : List Expr) (assigned : List String) : List Expr :=
  scope.filter fun h => (collectIdents h).all (fun v => !assigned.contains v)

-- ────────────────────────────────────────────────────────────────────────────
-- The ONE scoped context collector (ROADMAP Phase 3 #3).
--
-- Shared engine for every scoped obligation family (call-site preconditions,
-- array bounds, div/mod, overflow, asserts, …). Migrated families walk the body
-- once with the SAME scope-threading discipline, parameterised only by a
-- per-statement `leaf` extractor. The walker threads the full fact set the
-- roadmap requires:
--   • enclosing `if`-guards          → the then-branch assumes `c`,
--   • negated guards                 → the else-branch assumes `¬c`,
--   • early-return fall-through       → after `if c { …return… }`, assume `¬c`,
--   • loop invariants + guards        → the body assumes `loopHypsAt`,
--   • one shared invalidation rule    → `dropStaleHyps` after each assignment.
-- `leaf scope s` sees the hypotheses in scope at `s` and returns this statement's
-- own (non-recursive) obligations; the walker owns ALL recursion into branches,
-- loop bodies, and for-loop init/step, so no family can drift in how it threads
-- scope. Migrated families instantiate this with their own leaf (Phase 3 #4-9).
mutual
partial def scopedWalkS {α} (leaf : List Expr → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) : Stmt → List α
  | s@(.ifElse _ c t el) =>
      leaf scope s
        ++ scopedWalkB leaf lcs (scope ++ [c]) t
        ++ scopedWalkB leaf lcs (scope ++ (negateGuard c).toList) (el.getD [])
  | s@(.while_ sp _ b _) =>
      leaf scope s ++ scopedWalkB leaf lcs (scope ++ loopHypsAt lcs sp.line) b
  | s@(.forLoop sp init _ step b _) =>
      -- init, then this statement's own leaves (the loop condition), then step,
      -- then body — the traversal ORDER every family's old walker used, so the
      -- positional `#idx`/`#pre`/… keys are preserved across the migration.
      ((init.map (scopedWalkS leaf lcs scope)).getD [])
        ++ leaf scope s
        ++ ((step.map (scopedWalkS leaf lcs scope)).getD [])
        ++ scopedWalkB leaf lcs (scope ++ loopHypsAt lcs sp.line) b
  | s@(.borrowIn _ _ _ _ _ b) => leaf scope s ++ scopedWalkB leaf lcs scope b
  | s => leaf scope s
partial def scopedWalkB {α} (leaf : List Expr → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) : List Stmt → List α
  | [] => []
  | s :: rest =>
      let restScope := match s with
        | .ifElse _ c t none => if blockTerminates t then scope ++ (negateGuard c).toList
                                else dropStaleHyps scope (assignedScalarsS s)
        | _ => dropStaleHyps scope (assignedScalarsS s)
      scopedWalkS leaf lcs scope s ++ scopedWalkB leaf lcs restScope rest
end

/-- Array-index leaf: the index uses in a statement's OWN expression positions
    (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's index uses).
    A store `a[idx] = v` carries its target bound `(a, idx)` FIRST, matching the
    old walker's ordering exactly. -/
def boundsLeaf (scope : List Expr) : Stmt → List (String × Expr × List Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectIndexUsesE v).map fun (a, i) => (a, i, scope)
  | .return_ _ (some v) => (collectIndexUsesE v).map fun (a, i) => (a, i, scope)
  | .ifElse _ c _ _ => (collectIndexUsesE c).map fun (a, i) => (a, i, scope)
  | .while_ _ c _ _ => (collectIndexUsesE c).map fun (a, i) => (a, i, scope)
  | .forLoop _ _ c _ _ _ => (collectIndexUsesE c).map fun (a, i) => (a, i, scope)
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectIndexUsesE o ++ collectIndexUsesE v).map fun (a, i) => (a, i, scope)
  | .arrayIndexAssign _ (.ident _ arr) idx v =>
      (arr, idx, scope) :: (collectIndexUsesE idx ++ collectIndexUsesE v).map fun (a, i) => (a, i, scope)
  | .arrayIndexAssign _ a i v =>
      (collectIndexUsesE a ++ collectIndexUsesE i ++ collectIndexUsesE v).map fun (x, j) => (x, j, scope)
  | _ => []

/-- Index uses paired with the hypotheses in scope at the access (Phase 3 #5 —
    migrated onto the unified `scopedWalk`). Like the call-site migration, the
    collector now threads enclosing `if`-guards (then assumes `c`, else assumes
    `¬c`), early-return fall-through, and loop invariants/guards — strictly more
    sound context than the old bounds walker, so a bounds obligation can only move
    `unproven → proved_by_kernel_decision` (e.g. `if 0 ≤ i && i < n { a[i] }`),
    never the reverse, and a reassigned index still drops its stale guard. -/
def scopedBoundsB (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) :
    List (String × Expr × List Expr) :=
  scopedWalkB boundsLeaf lcs scope body

/-- Call-site leaf: the calls in a statement's OWN expression positions (the
    walker owns recursion into branches, loop bodies, and for-loop init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's calls). -/
def callLeaf (scope : List Expr) : Stmt → List (String × List Expr × List Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectCallsE v).map fun (_, fn, args) => (fn, args, scope)
  | .return_ _ (some v) => (collectCallsE v).map fun (_, fn, args) => (fn, args, scope)
  | .ifElse _ c _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope)
  | .while_ _ c _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope)
  | .forLoop _ _ c _ _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope)
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectCallsE o ++ collectCallsE v).map fun (_, fn, args) => (fn, args, scope)
  | .arrayIndexAssign _ a i v =>
      (collectCallsE a ++ collectCallsE i ++ collectCallsE v).map fun (_, fn, args) => (fn, args, scope)
  | _ => []

/-- Calls paired with the hypotheses in scope at the call (Phase 3 #4 — migrated
    onto the unified `scopedWalk`). The collector threads the FULL fact set:
    enclosing `if`-guards (then assumes `c`, else assumes `¬c`), early-return
    fall-through (`¬c` after `if c { …return… }`), loop invariants/guards, and one
    shared stale-hypothesis rule. This is strictly more (sound) context than the
    old call walker threaded, so a call precondition can only move `unproven →
    proved`, never the reverse; it also closes the old gap of skipping calls
    inside `borrow … in { }` bodies. -/
def scopedCallsB (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) :
    List (String × List Expr × List Expr) :=
  scopedWalkB callLeaf lcs scope body

/-- `assert`/`assume` leaf: the only own-obligation statements are `assert`/
    `assume` themselves; everything else is pure recursion the walker owns. -/
def assertLeaf (scope : List Expr) : Stmt → List (Bool × Expr × List Expr)
  | .assert_ _ c => [(false, c, scope)]
  | .assume_ _ c => [(true, c, scope)]
  | _ => []

/-- `assert`/`assume` with the path conditions in scope at each one (the first
    family on the unified collector — Phase 3 #3). Enclosing `if`-guards (the
    guard on the then-branch, its negation on the else-branch), loop invariants in
    the body, and `¬c` for the fall-through of an early-return `if c { …return… }`.
    Mirrors `collectAssertAssumeS`'s traversal ORDER exactly, so the `i`-th item
    keeps the same `#aa<i>` key the renderer uses. -/
def scopedAssertsB (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) :
    List (Bool × Expr × List Expr) :=
  scopedWalkB assertLeaf lcs scope body

/-- Omega goals for `assert(e)` obligations: `∀ vars, (path conditions) → (e)`.
    The hypotheses are the function's `#[requires]` PLUS the path conditions in
    scope at the assert (if-guards, negated guards, loop invariants) — threaded
    like the call-site/bounds/div VCs. Discharged by the same omega backend; a
    success means the assert holds. `assume` produces no goal (trusted, not
    proved). Keyed `<fq>#aa<i>` by position in the assert/assume stream, matching
    `renderAssertAssume`. -/
def assertGoals (modules : List Module) : List (String × String) := Id.run do
  let mut goals : List (String × String) := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (isAssume, cond, scope) in scopedAssertsB f.loopContracts [] f.body do
      if !isAssume then
        let hyps := f.requires ++ scope
        let nn := nonNegFromHyps hyps
        match toLeanPropSound nn cond with
        | some p =>
          let hypProps := hyps.filterMap (toLeanPropSound nn)
          let vars := (collectIdents cond ++ hyps.flatMap collectIdents).eraseDups
          let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
          let hyp := if hypProps.isEmpty then "" else s!"({" ∧ ".intercalate (hypProps.map (fun q => s!"({q})"))}) → "
          goals := goals ++ [(s!"{fq}#aa{i}", s!"{binder}{hyp}({p})")]
        | none => pure ()
      i := i + 1
  return goals

/-- `assume(e)` facts with the path conditions in scope (Phase 3 #8). An `assume`
    is NOT an obligation to discharge — it is a trusted assumption fact that the
    audit ledger must surface loudly: it carries status `assumed` (never a proof),
    is a policy input (`forbid-assume`, E0614), and crucially produces no goal, so
    it can never launder trust into kernel evidence for a later assert. Keyed
    `<fq>#aa<i>` by the SAME position scheme as `assertGoals` (assume and assert
    occupy disjoint positions in the shared stream). -/
def assumeFacts (modules : List Module) : List (String × String × List String) := Id.run do
  let mut facts : List (String × String × List String) := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (isAssume, cond, scope) in scopedAssertsB f.loopContracts [] f.body do
      if isAssume then
        let hyps := f.requires ++ scope
        let nn := nonNegFromHyps hyps
        let concl := (toLeanPropSound nn cond).getD (Concrete.fmtExpr cond)
        facts := facts ++ [(s!"{fq}#aa{i}", concl, hyps.filterMap (toLeanPropSound nn))]
      i := i + 1
  return facts

/-- Build the ordered list of call-site obligations across all callers. The fast
    constant folder classifies the literal/arithmetic cases; an obligation that
    stays non-constant carries a `bv_decide` `leanGoal` (when closed after
    let-const subst) and the `hyps` in scope at the call so `callPrecondGoals`
    can try to discharge it with `omega` from the caller's `#[requires]` /
    enclosing guards / loop invariants. -/
def callSiteObligations (modules : List Module) : List CallObligation := Id.run do
  let fns := modules.flatMap allFunctions
  let reqMap : List (String × (List Param × List Expr)) :=
    fns.filterMap (fun (_, f) => if f.requires.isEmpty then none else some (f.name, (f.params, f.requires)))
  if reqMap.isEmpty then return []
  let mut obs : List CallObligation := []
  let mut gi := 0
  for (pfx, f) in fns do
    let lets := letConstMap f.body
    for (fn, args, scope) in scopedCallsB f.loopContracts [] f.body do
      match reqMap.find? (·.1 == fn) with
      | none => pure ()
      | some (_, (params, reqs)) =>
        let argSubst := (params.zip args).map (fun (p, a) => (p.name, a))
        let callStr := s!"{fn}({", ".intercalate (args.map Concrete.fmtExpr)})"
        for r in reqs do
          let spec := substContract argSubst r
          let (baseStatus, leanGoal) := match cEvalBool spec with
            | some true  => ("proved_at_callsite", none)
            | some false => ("failed_at_callsite", none)
            | none =>
              let spec2 := substContract lets spec
              match cEvalBool spec2 with
              | some false => ("failed_at_callsite", none)
              | _ => if isClosed spec2 then ("unproven", toLeanBV spec2)
                     else ("unproven", none)
          obs := obs ++ [{ caller := pfx ++ f.name, callStr, specExpr := spec, baseStatus, leanGoal
                         , key := s!"{pfx ++ f.name}#pre{gi}", hyps := f.requires ++ scope }]
          gi := gi + 1
  return obs

/-- Omega goals for call-site preconditions that are not constant-decidable:
    `∀ (vars : Int), (caller hyps) → precondition`. Discharged by the same
    `omega` backend as the bounds/div goals; a success means the caller's
    `#[requires]` / guards / loop invariants establish the callee's precondition. -/
def callPrecondGoals (modules : List Module) : List (String × String) :=
  (callSiteObligations modules).filterMap fun o =>
    if o.baseStatus != "unproven" then none
    else match toLeanProp o.specExpr with
      | none => none
      | some specStr =>
        let vars := (collectIdents o.specExpr ++ o.hyps.flatMap collectIdents).eraseDups
        let reqs := o.hyps.filterMap toLeanProp
        let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
        let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
        some (o.key, s!"{binder}{hyp}({specStr})")

/-- One array-bounds obligation. `closedVerdict` is set when the index is a
    compile-time constant; otherwise `leanGoal` is the omega goal (if lowerable). -/
structure BoundsObl where
  fnQual        : String
  key           : String
  arrName       : String
  idxExpr       : Expr
  size          : Nat
  closedVerdict : Option Bool
  leanGoal      : Option String
  hyps          : List Expr := []   -- in-scope #[requires]/guards (for prover-neutral lowering)

/-- Identifier → fixed-array size, from array-typed params and annotated lets. -/
def arraySizeMap (f : FnDef) : List (String × Nat) :=
  let ps := f.params.filterMap fun p => match p.ty with | .array _ n => some (p.name, n) | _ => none
  let ls := f.body.filterMap fun s => match s with
    | .letDecl _ nm _ (some (.array _ n)) _ _ => some (nm, n) | _ => none
  ps ++ ls

/-- Generate array-bounds obligations for every indexed access into a known
    fixed-size array. -/
def boundsObligations (modules : List Module) : List BoundsObl := Id.run do
  let mut out : List BoundsObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let sizes := arraySizeMap f
    let mut i := 0
    for (arr, idx, scope) in scopedBoundsB f.loopContracts [] f.body do
      match sizes.find? (·.1 == arr) with
      | none => pure ()
      | some (_, n) =>
        let key := s!"{fq}#bounds{i}"
        let obHyps := f.requires ++ scope
        let cv : Option Bool × Option String := match cEvalInt idx with
          | some k => (some (decide (0 ≤ k) && decide (k < (Int.ofNat n))), none)
          | none => match toLeanProp idx with
            | none => (none, none)
            | some idxStr =>
              let vars := (collectIdents idx ++ obHyps.flatMap collectIdents).eraseDups
              let reqs := obHyps.filterMap toLeanProp
              let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
              let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
              (none, some s!"{binder}{hyp}(0 ≤ {idxStr} ∧ {idxStr} < {n})")
        out := out ++ [{ fnQual := fq, key, arrName := arr, idxExpr := idx, size := n
                        , closedVerdict := cv.1, leanGoal := cv.2, hyps := obHyps }]
        i := i + 1
  return out

/-- Lean goals for the non-constant bounds obligations, for omega discharge. -/
def boundsGoals (modules : List Module) : List (String × String) :=
  (boundsObligations modules).filterMap fun o => o.leanGoal.map (fun g => (o.key, g))

/-- Render the array-bounds section. `provedKeys` are the omega-discharged keys. -/
def renderBounds (obls : List BoundsObl) (provedKeys : List String) : String := Id.run do
  if obls.isEmpty then return ""
  let mut out := "\n\n=== Runtime-safety obligations (array bounds) ==="
  let mut cur := ""
  for o in obls do
    if o.fnQual != cur then out := out ++ s!"\n\n{o.fnQual}"; cur := o.fnQual
    let status := match o.closedVerdict with
      | some true  => "checked: in bounds (constant index)"
      | some false => "VIOLATION: index out of bounds (constant index)"
      | none => match o.leanGoal with
        | some _ =>
          if provedKeys.contains o.key
          then "proved_by_kernel_decision (omega) — statically in bounds, no runtime check needed"
          else "unproven — bound the index with a #[requires], or insert a runtime check"
        | none => "unproven — index not statically analyzable; needs a runtime check"
    out := out ++ s!"\n  {o.arrName}[{Concrete.fmtExpr o.idxExpr}]  (array size {o.size})\n    status: {status}"
  return out ++ "\n"

-- ============================================================
-- Runtime-safety obligations: division by zero
-- ============================================================
-- Every `/` and `%` generates the obligation `divisor ≠ 0`. Same shape as array
-- bounds: constant divisors are evaluated; variable divisors discharge by omega
-- under the function's #[requires] (statically nonzero), or stay `unproven`.

mutual
/-- `(isMod, divisorExpr)` for every `/` and `%` in an expression. -/
partial def collectDivisorsE : Expr → List (Bool × Expr)
  | .binOp _ .div l r => (false, r) :: (collectDivisorsE l ++ collectDivisorsE r)
  | .binOp _ .mod l r => (true, r) :: (collectDivisorsE l ++ collectDivisorsE r)
  | .binOp _ _ l r => collectDivisorsE l ++ collectDivisorsE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .try_ _ x | .cast _ x _ | .fieldAccess _ x _ => collectDivisorsE x
  | .arrayLit _ es => es.flatMap collectDivisorsE
  | .arrayIndex _ a i => collectDivisorsE a ++ collectDivisorsE i
  | .call _ _ _ args => args.flatMap collectDivisorsE
  | .methodCall _ o _ _ args => collectDivisorsE o ++ args.flatMap collectDivisorsE
  | .staticMethodCall _ _ _ _ args => args.flatMap collectDivisorsE
  | .structLit _ _ _ fs base => fs.flatMap (fun (_, fe) => collectDivisorsE fe) ++ (base.map collectDivisorsE).getD []
  | .enumLit _ _ _ _ fs => fs.flatMap (fun (_, fe) => collectDivisorsE fe)
  | .allocCall _ x a => collectDivisorsE x ++ collectDivisorsE a
  | .ifExpr _ c t el =>
      collectDivisorsE c ++ t.flatMap collectDivisorsS ++ el.flatMap collectDivisorsS
  | .match_ _ s _ => collectDivisorsE s
  | _ => []
partial def collectDivisorsS : Stmt → List (Bool × Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectDivisorsE v
  | .return_ _ (some v) => collectDivisorsE v
  | .ifElse _ c t el => collectDivisorsE c ++ t.flatMap collectDivisorsS ++ (el.getD []).flatMap collectDivisorsS
  | .while_ _ c b _ => collectDivisorsE c ++ b.flatMap collectDivisorsS
  | .forLoop _ init c step b _ =>
      (init.map collectDivisorsS).getD [] ++ collectDivisorsE c
        ++ (step.map collectDivisorsS).getD [] ++ b.flatMap collectDivisorsS
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectDivisorsE o ++ collectDivisorsE v
  | .arrayIndexAssign _ a i v => collectDivisorsE a ++ collectDivisorsE i ++ collectDivisorsE v
  | _ => []
end

/-- Divisor leaf: the `/`/`%` divisors in a statement's OWN expression positions
    (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's divisors).
    Each item is `(isMod, divisorExpr, scope)`. -/
def divLeaf (scope : List Expr) : Stmt → List (Bool × Expr × List Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectDivisorsE v).map fun (m, e) => (m, e, scope)
  | .return_ _ (some v) => (collectDivisorsE v).map fun (m, e) => (m, e, scope)
  | .ifElse _ c _ _ => (collectDivisorsE c).map fun (m, e) => (m, e, scope)
  | .while_ _ c _ _ => (collectDivisorsE c).map fun (m, e) => (m, e, scope)
  | .forLoop _ _ c _ _ _ => (collectDivisorsE c).map fun (m, e) => (m, e, scope)
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectDivisorsE o ++ collectDivisorsE v).map fun (m, e) => (m, e, scope)
  | .arrayIndexAssign _ a i v =>
      (collectDivisorsE a ++ collectDivisorsE i ++ collectDivisorsE v).map fun (m, e) => (m, e, scope)
  | _ => []

/-- Divisor uses paired with the hypotheses in scope at the `/`/`%` (Phase 3 #6 —
    migrated onto the unified `scopedWalk`). The collector threads enclosing
    guards / negated guards / fall-through / loop invariants, so a `divisor ≠ 0`
    obligation can only move `unproven → proved` (e.g. `if d != 0 { n / d }`),
    never the reverse. The SOUND division/modulo lowering is unchanged: it still
    flows through `divSound`/`toLeanPropSound`, which lower `/`/`%` to Lean
    E-division ONLY when the dividend is provably non-negative — keeping Concrete's
    truncating semantics from being confused with Lean's floor division. -/
def scopedDivB (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) :
    List (Bool × Expr × List Expr) :=
  scopedWalkB divLeaf lcs scope body

/-- One division-by-zero obligation. -/
structure DivObl where
  fnQual        : String
  key           : String
  divExpr       : Expr
  isMod         : Bool
  closedVerdict : Option Bool
  leanGoal      : Option String
  hyps          : List Expr := []   -- in-scope #[requires]/guards (for prover-neutral lowering)

/-- Generate `divisor ≠ 0` obligations for every `/` and `%`. -/
def divObligations (modules : List Module) : List DivObl := Id.run do
  let mut out : List DivObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (isMod, dv, scope) in scopedDivB f.loopContracts [] f.body do
      let key := s!"{fq}#div{i}"
      let obHyps := f.requires ++ scope
      let cv : Option Bool × Option String := match cEvalInt dv with
        | some k => (some (decide (k ≠ 0)), none)
        | none => match toLeanProp dv with
          | none => (none, none)
          | some dStr =>
            let vars := (collectIdents dv ++ obHyps.flatMap collectIdents).eraseDups
            let reqs := obHyps.filterMap toLeanProp
            let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
            let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
            (none, some s!"{binder}{hyp}({dStr} ≠ 0)")
      out := out ++ [{ fnQual := fq, key, divExpr := dv, isMod, closedVerdict := cv.1, leanGoal := cv.2, hyps := obHyps }]
      i := i + 1
  return out

/-- Lean goals for the non-constant divisor obligations, for omega discharge. -/
def divGoals (modules : List Module) : List (String × String) :=
  (divObligations modules).filterMap fun o => o.leanGoal.map (fun g => (o.key, g))

/-- Render the division-by-zero section. -/
def renderDiv (obls : List DivObl) (provedKeys : List String) : String := Id.run do
  if obls.isEmpty then return ""
  let mut out := "\n\n=== Runtime-safety obligations (division: non-zero divisor) ==="
  let mut cur := ""
  for o in obls do
    if o.fnQual != cur then out := out ++ s!"\n\n{o.fnQual}"; cur := o.fnQual
    let opname := if o.isMod then "%" else "/"
    let status := match o.closedVerdict with
      | some true  => "checked: divisor is a nonzero constant"
      | some false => "VIOLATION: division by zero (constant divisor)"
      | none => match o.leanGoal with
        | some _ =>
          if provedKeys.contains o.key
          then "proved_by_kernel_decision (omega) — divisor nonzero, no runtime check needed"
          else "unproven — require the divisor nonzero (#[requires]), or insert a runtime check"
        | none => "unproven — divisor not statically analyzable; needs a runtime check"
    out := out ++ s!"\n  {opname} divisor {Concrete.fmtExpr o.divExpr}\n    status: {status}"
  return out ++ "\n"

-- ============================================================
-- Runtime-safety obligations: integer overflow (opt-in)
-- ============================================================
-- Under `#[overflow_checked]`, each fixed-width `+`/`-`/`*` generates
-- `MIN ≤ result ≤ MAX` for that width. Opt-in, because Concrete's default
-- integer overflow semantics are profile-dependent and emitting this for every
-- arithmetic op would flood the audit. Same disposition shape as bounds/div.

/-- Inclusive value range of a *fixed-width* integer type (none = arbitrary/
    `Int`). The range values come from the arithmetic reference
    (`IntArith.intRange`); this deliberately keeps `Int`/`Uint` as `none` (an
    audit choice — their overflow is profile-dependent, per the note above), so
    it is not a blind alias of `IntArith.intRange`, which does give them ranges. -/
def intRange : Ty → Option (Int × Int)
  | .int | .uint => none
  | ty => IntArith.intRange ty

/-- Best-effort fixed-width int type of an expression, from a var→type map. -/
partial def exprIntTy (vt : List (String × Ty)) : Expr → Option Ty
  | .ident _ n => vt.lookup n
  | .paren _ e => exprIntTy vt e
  | .unaryOp _ _ e => exprIntTy vt e
  | .cast _ _ t => some t
  | .binOp _ _ l r => match exprIntTy vt l with | some t => some t | none => exprIntTy vt r
  | _ => none

mutual
/-- Every `+`/`-`/`*` binop node in an expression (the whole `a op b`). -/
partial def collectArithE : Expr → List Expr
  | e@(.binOp _ op l r) =>
    let here := match op with | .add | .sub | .mul => [e] | _ => []
    here ++ collectArithE l ++ collectArithE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .try_ _ x | .cast _ x _ | .fieldAccess _ x _ => collectArithE x
  | .arrayLit _ es => es.flatMap collectArithE
  | .arrayIndex _ a i => collectArithE a ++ collectArithE i
  | .call _ _ _ args => args.flatMap collectArithE
  | .methodCall _ o _ _ args => collectArithE o ++ args.flatMap collectArithE
  | .staticMethodCall _ _ _ _ args => args.flatMap collectArithE
  | .structLit _ _ _ fs base => fs.flatMap (fun (_, fe) => collectArithE fe) ++ (base.map collectArithE).getD []
  | .enumLit _ _ _ _ fs => fs.flatMap (fun (_, fe) => collectArithE fe)
  | .allocCall _ x a => collectArithE x ++ collectArithE a
  | .ifExpr _ c t el =>
      collectArithE c ++ t.flatMap collectArithS ++ el.flatMap collectArithS
  | .match_ _ s _ => collectArithE s
  | _ => []
partial def collectArithS : Stmt → List Expr
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectArithE v
  | .return_ _ (some v) => collectArithE v
  | .ifElse _ c t el => collectArithE c ++ t.flatMap collectArithS ++ (el.getD []).flatMap collectArithS
  | .while_ _ c b _ => collectArithE c ++ b.flatMap collectArithS
  | .forLoop _ init c step b _ =>
      (init.map collectArithS).getD [] ++ collectArithE c
        ++ (step.map collectArithS).getD [] ++ b.flatMap collectArithS
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectArithE o ++ collectArithE v
  | .arrayIndexAssign _ a i v => collectArithE a ++ collectArithE i ++ collectArithE v
  | _ => []
end

/-- Arithmetic-op leaf: the `+`/`-`/`*` op nodes in a statement's OWN expression
    positions (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's op nodes). -/
def arithLeaf (scope : List Expr) : Stmt → List (Expr × List Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectArithE v).map fun e => (e, scope)
  | .return_ _ (some v) => (collectArithE v).map fun e => (e, scope)
  | .ifElse _ c _ _ => (collectArithE c).map fun e => (e, scope)
  | .while_ _ c _ _ => (collectArithE c).map fun e => (e, scope)
  | .forLoop _ _ c _ _ _ => (collectArithE c).map fun e => (e, scope)
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectArithE o ++ collectArithE v).map fun e => (e, scope)
  | .arrayIndexAssign _ a i v =>
      (collectArithE a ++ collectArithE i ++ collectArithE v).map fun e => (e, scope)
  | _ => []

/-- Arithmetic-op nodes paired with the hypotheses in scope (Phase 3 #7 —
    migrated onto the unified `scopedWalk`). The collector now threads enclosing
    guards / negated guards / fall-through / loop invariants into the in-scope
    facts, so an overflow obligation's interval/`bv_decide`/SMT discharge sees
    strictly MORE sound bounds — proofs can only get stronger
    (`unproven → proved`), never weaker. The three-route discharge downstream is
    unchanged: omega/interval/`bv_decide` are kernel-owned, external SMT remains
    opt-in (`--smt`) and may only touch obligations the kernel tiers left
    unproved; stale bounds are still dropped by the shared invalidation rule. -/
def scopedArithB (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) :
    List (Expr × List Expr) :=
  scopedWalkB arithLeaf lcs scope body

/-- One integer-overflow obligation. -/
structure OverflowObl where
  fnQual        : String
  key           : String
  opExpr        : Expr
  lo            : Int
  hi            : Int
  closedVerdict : Option Bool
  leanGoal      : Option String           -- omega goal (linear)
  bvGoal        : Option String := none    -- widened bv_decide goal (nonlinear, interval-gated)
  hyps          : List Expr := []          -- the in-scope #[requires]/guards (for the SMT query)

/-- All annotated `let` bindings in a statement tree, including those declared
    inside loop inits/steps/bodies (so a loop counter `i` from a `for`-init is
    typed for the overflow check). -/
partial def collectLetTys : Stmt → List (String × Ty)
  | .letDecl _ n _ (some t) _ _ => [(n, t)]
  | .ifElse _ _ t el => t.flatMap collectLetTys ++ (el.getD []).flatMap collectLetTys
  | .while_ _ _ b _ => b.flatMap collectLetTys
  | .forLoop _ init _ step b _ =>
      (init.map collectLetTys).getD [] ++ (step.map collectLetTys).getD [] ++ b.flatMap collectLetTys
  | _ => []

/-- Var→type map from params and annotated lets (recursively, see
    `collectLetTys`). -/
def varTyMap (f : FnDef) : List (String × Ty) :=
  f.params.map (fun p => (p.name, p.ty)) ++ f.body.flatMap collectLetTys

-- ============================================================
-- Nonlinear overflow discharge: interval analysis + bv_decide
-- ============================================================
-- omega is LINEAR, so a product of two variables (`sample * gain`) is left
-- `unproven` by the omega path. When every operand has a non-negative, bounded
-- range (from #[requires] / loop invariants), interval analysis computes the
-- result range; if it fits the type, we emit a WIDENED unsigned `bv_decide`
-- goal so the no-overflow fact is KERNEL-checked (not merely computed here).
-- Restricted to +/* of non-negative bounded operands so the unsigned model is
-- sound (no underflow); anything else stays honestly `unproven`.

/-- Flatten an `&&`-conjunction into its conjuncts. -/
partial def conjuncts : Expr → List Expr
  | .binOp _ .and_ l r => conjuncts l ++ conjuncts r
  | .paren _ e => conjuncts e
  | e => [e]

/-- Per-variable integer bounds `[lo,hi]` from hypothesis conjuncts of the form
    `k <= v`, `v <= k`, `k < v`, `v < k` (and ≥/> mirrors), merged to the
    tightest known bound. Only variables with BOTH a lower and upper bound. -/
def varBoundsFromHyps (hyps : List Expr) : List (String × (Int × Int)) := Id.run do
  let mut los : List (String × Int) := []
  let mut his : List (String × Int) := []
  let upd := fun (l : List (String × Int)) (v : String) (k : Int) (f : Int → Int → Int) =>
    match l.lookup v with
    | some old => (l.filter (·.1 != v)) ++ [(v, f old k)]
    | none => l ++ [(v, k)]
  for c in hyps.flatMap conjuncts do
    match c with
    | .binOp _ .leq (.intLit _ k) (.ident _ v) => los := upd los v k max
    | .binOp _ .leq (.ident _ v) (.intLit _ k) => his := upd his v k min
    | .binOp _ .lt  (.intLit _ k) (.ident _ v) => los := upd los v (k+1) max
    | .binOp _ .lt  (.ident _ v) (.intLit _ k) => his := upd his v (k-1) min
    | .binOp _ .geq (.ident _ v) (.intLit _ k) => los := upd los v k max
    | .binOp _ .geq (.intLit _ k) (.ident _ v) => his := upd his v k min
    | .binOp _ .gt  (.ident _ v) (.intLit _ k) => los := upd los v (k+1) max
    | .binOp _ .gt  (.intLit _ k) (.ident _ v) => his := upd his v (k-1) min
    | _ => pure ()
  return los.filterMap fun (v, l) => (his.lookup v).map fun h => (v, (l, h))

/-- Conservative interval `(lo, hi)` of an arithmetic expr plus the maximum
    magnitude seen across the whole subtree (to choose a wrap-free bit width).
    `none` if any operand is unbounded or the op is outside `+`/`-`/`*`. -/
partial def exprIntervalMax (bounds : List (String × (Int × Int))) : Expr → Option (Int × Int × Nat)
  | .intLit _ k => some (k, k, k.natAbs)
  | .paren _ e => exprIntervalMax bounds e
  | .ident _ v => (bounds.lookup v).map fun (l, h) => (l, h, max l.natAbs h.natAbs)
  | .binOp _ op l r => do
    let (la, lb, lm) ← exprIntervalMax bounds l
    let (ra, rb, rm) ← exprIntervalMax bounds r
    let sub := max lm rm
    let mk := fun (a b : Int) => some (a, b, max sub (max a.natAbs b.natAbs))
    match op with
    | .add => mk (la + ra) (lb + rb)
    | .sub => mk (la - rb) (lb - ra)
    | .mul =>
      let ps := [la*ra, la*rb, lb*ra, lb*rb]
      mk (ps.foldl min (la*ra)) (ps.foldl max (la*ra))
    | _ => none
  | _ => none

/-- Lower an arithmetic expr to a `BitVec w` term (`+`/`*` of vars and
    non-negative literals only; `-` is excluded so the unsigned model can't
    underflow). -/
partial def arithToBVW (w : Nat) : Expr → Option String
  | .intLit _ k => if k < 0 then none else some s!"({k}#{w})"
  | .paren _ e => arithToBVW w e
  | .ident _ v => some v
  | .binOp _ op l r => do
    let L ← arithToBVW w l
    let R ← arithToBVW w r
    match op with
    | .add => some s!"({L} + {R})"
    | .mul => some s!"({L} * {R})"
    | _ => none
  | _ => none

/-- A widened unsigned `bv_decide` goal proving `e` cannot overflow `[lo,hi]`,
    when interval analysis shows the result is non-negative and in range and the
    operands are `+`/`*` of non-negative bounded vars. `none` otherwise (→ the
    obligation stays `unproven`). -/
def overflowBVGoal (e : Expr) (lo hi : Int) (hyps : List Expr) : Option String := do
  let bounds := varBoundsFromHyps hyps
  let (elo, ehi, maxMag) ← exprIntervalMax bounds e
  guard (lo ≤ elo)          -- lower bound holds by interval
  guard (ehi ≤ hi)          -- upper bound holds by interval
  guard (0 ≤ elo)           -- non-negative result → unsigned model is sound
  let w ← if maxMag < 2147483648 then some 32
          else if maxMag < 9223372036854775808 then some 64 else none
  let eBV ← arithToBVW w e
  let vars := (collectIdents e).eraseDups
  guard (!vars.isEmpty)
  -- every operand needs a non-negative upper bound to model it as unsigned BitVec
  let varHyps ← vars.mapM fun v => (bounds.lookup v).bind fun (vl, vh) =>
    if vl < 0 then none else some s!"BitVec.ule {v} ({vh}#{w})"
  some s!"∀ ({" ".intercalate vars} : BitVec {w}), {" → ".intercalate varHyps} → BitVec.ule {eBV} ({hi}#{w})"

/-- Generate no-overflow obligations for `#[overflow_checked]` functions. -/
def overflowObligations (modules : List Module) : List OverflowObl := Id.run do
  let mut out : List OverflowObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    if !f.overflowChecked then continue
    let fq := pfx ++ f.name
    let vt := varTyMap f
    let mut i := 0
    for (e, scope) in scopedArithB f.loopContracts [] f.body do
      match (exprIntTy vt e).bind intRange, toLeanProp e with
      | some (lo, hi), some eStr =>
        let key := s!"{fq}#ovf{i}"
        let hyps := f.requires ++ scope
        let cv : Option Bool × Option String := match cEvalInt e with
          | some k => (some (decide (lo ≤ k ∧ k ≤ hi)), none)
          | none =>
            let vars := (collectIdents e ++ hyps.flatMap collectIdents).eraseDups
            let reqs := hyps.filterMap toLeanProp
            let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
            let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
            (none, some s!"{binder}{hyp}({lo} ≤ {eStr} ∧ {eStr} ≤ {hi})")
        -- nonlinear/bv fallback: interval-gated widened unsigned goal (only when
        -- omega's linear goal won't close it — i.e. the constant case is skipped).
        let bvGoal := if cv.1.isSome then none else overflowBVGoal e lo hi hyps
        out := out ++ [{ fnQual := fq, key, opExpr := e, lo, hi
                       , closedVerdict := cv.1, leanGoal := cv.2, bvGoal, hyps }]
        i := i + 1
      | _, _ => pure ()
  return out

/-- Lean goals for the non-constant overflow obligations, for omega discharge. -/
def overflowGoals (modules : List Module) : List (String × String) :=
  (overflowObligations modules).filterMap fun o => o.leanGoal.map (fun g => (o.key, g))

/-- Widened unsigned `bv_decide` goals for nonlinear overflow obligations (the
    interval-gated `var * var` cases omega cannot close). Run by Main after omega,
    only for obligations omega left unproven. -/
def overflowBVGoals (modules : List Module) : List (String × String) :=
  (overflowObligations modules).filterMap fun o => o.bvGoal.map (fun g => (o.key, g))

/-! ## External-SMT path (Phase 2 #8) — narrow first slice

The kernel-checked tiers (constant fold → omega → `bv_decide`) are exhausted
first. What genuinely remains outside them is *nonlinear* integer arithmetic —
a product of two program variables that interval analysis cannot bound. For that
one narrow VC class we can emit a standard SMT-LIB query and hand it to an
external solver. The result is NEVER a kernel-checked class: it is
`solver_trusted` / `proved_by_smt` (the solver enters the TCB), kept distinct
from `proved_by_kernel_decision`, and only ever produced behind an explicit flag.
The translation targets structured `Expr`s (not the Lean-syntax strings), so the
emitted SMT-LIB is well-formed by construction. -/

/-- Lower a contract `Expr` to an SMT-LIB (QF_NIA) s-expression. Same fragment as
    `toLeanProp`: integer literals/vars, add/sub/mul, comparisons, and/or/not. -/
partial def exprToSmt : Expr → Option String
  | .intLit _ v => some (if v < 0 then s!"(- {-v})" else s!"{v}")
  | .ident _ n => some n
  | .paren _ e => exprToSmt e
  | .unaryOp _ op e => do
    let E ← exprToSmt e
    match op with
    | .neg  => some s!"(- {E})"
    | .not_ => some s!"(not {E})"
    | _     => none
  | .binOp _ op l r => do
    let L ← exprToSmt l
    let R ← exprToSmt r
    match op with
    | .neq => some s!"(not (= {L} {R}))"
    | _ => (obBinOpSmt op).map fun s => s!"({s} {L} {R})"
  | _ => none

/-- True when `e` contains a multiplication of two non-constant operands — the
    genuinely nonlinear shape `omega` cannot own and interval `bv_decide` may miss. -/
partial def exprHasNonlinMul : Expr → Bool
  | .binOp _ .mul l r => (cEvalInt l).isNone && (cEvalInt r).isNone
      || exprHasNonlinMul l || exprHasNonlinMul r
  | .binOp _ _ l r => exprHasNonlinMul l || exprHasNonlinMul r
  | .paren _ e => exprHasNonlinMul e
  | _ => false

/-- The SMT-eligible VC class (v1): `#[overflow_checked]` obligations whose operand
    is genuinely nonlinear (a product of variables), not constant, and not already
    closed by the interval `bv_decide` path. Returns `(vcKey, smtlibScript)`. The
    script asserts the in-scope hypotheses and the NEGATION of the range goal:
    `unsat` ⇒ no overflow (solver-proved); `sat` ⇒ a counterexample exists. -/
def overflowSmtGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in overflowObligations modules do
    if o.closedVerdict.isSome then continue          -- constant tier owns it
    if o.bvGoal.isSome then continue                 -- interval bv_decide owns it
    if !exprHasNonlinMul o.opExpr then continue      -- omega owns the linear case
    -- soundness: require the operand AND every hypothesis to lower. If any
    -- #[requires]/guard falls outside the SMT fragment, DROP the whole query
    -- rather than emit one missing a constraint (which could read as a spurious
    -- counterexample). Never emit an unsound query.
    match exprToSmt o.opExpr, o.hyps.mapM exprToSmt with
    | some eSmt, some hypSmts =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      let decls := vars.map (fun v => s!"(declare-const {v} Int)")
      let hypAsserts := hypSmts.map (fun s => s!"(assert {s})")
      let neg := s!"(assert (not (and (<= {o.lo} {eSmt}) (<= {eSmt} {o.hi}))))"
      let script := "\n".intercalate
        (["; VC " ++ o.key, "; no-overflow of an operand in [" ++ toString o.lo ++ ", " ++ toString o.hi ++ "]",
          "(set-logic QF_NIA)"] ++ decls ++ hypAsserts ++ [neg, "(check-sat)", "(get-model)"])
      out := out ++ [(o.key, script)]
    | _, _ => pure ()
  return out

/-! ## Lean replay artifact (Phase 2 #12)

For each SMT VC we also emit a standalone Lean theorem that states the SAME
obligation — hypotheses as binders, the range goal as the conclusion — with an
in-toolchain proof attempt (`by omega`). If a kernel-checked tactic closes it, the
claim no longer depends on the external solver and graduates `solver_trusted` →
`proved_by_lean_replay` (a Lean/kernel class, no solver in the TCB). The bounded
*nonlinear* fragment we route to SMT is, by construction, outside `omega`'s reach
(and `nlinarith` is Mathlib, which is deliberately NOT a dependency), so today the
attempt does not close and the VC honestly stays `solver_trusted`. The artifact is
still emitted so a reviewer — or a Mathlib-enabled build that swaps `omega` for
`nlinarith` — can check it and graduate the evidence. -/

/-- Lower a contract `Expr` to Lean `Prop`/`Int` syntax for the replay theorem.
    Same fragment as `toLeanProp` but ALSO handles unary negation (`-30000`) — the
    signed bounds that make a VC SMT-eligible in the first place. Kept local to the
    replay path so `toLeanProp`'s callers are unaffected. -/
partial def exprToLeanProp : Expr → Option String
  | .intLit _ v => some s!"{v}"
  | .ident _ n => some n
  | .paren _ e => exprToLeanProp e
  | .unaryOp _ op e => do
    let E ← exprToLeanProp e
    match op with | .neg => some s!"(-{E})" | .not_ => some s!"(¬ {E})" | _ => none
  | .binOp _ op l r => do
    let L ← exprToLeanProp l; let R ← exprToLeanProp r
    match op with
    | .div | .mod => none
    | _ => leanBinOp op L R
  | _ => none

/-! ## Prover-neutral multi-kernel path — the `proved_by_two_kernels` beachhead

The evidence thesis says independence is the trust value: an obligation a
Lean-hosted compiler discharges with `omega` should ALSO be dischargeable by
OTHER, independently-implemented kernels. We lower the SAME structured obligation
`Expr` through a prover-neutral DRIVER (`ProverLowering`) and hand the script to
that kernel's linear-arithmetic decision procedure:

  * Rocq / `coqc`  — `lia`        (CIC kernel; certification lineage)
  * Isabelle / HOL — `presburger` (HOL kernel; FOUNDATIONAL independence from CIC)

A VC that Lean's `omega` AND ≥1 external kernel independently close on the same
subject graduates `proved_by_kernel_decision` → `proved_by_two_kernels` (or, with
≥2 externals, `proved_by_multi_kernel`). If a kernel is absent, the honest verdict
is "it did not run" — the VC keeps its class, never a fabricated upgrade. Adding a
new prover ("any useful cool language") is a new `ProverLowering` value plus its
binop column in `ReportVC`, not new plumbing. -/

/-- A prover-neutral lowering DRIVER (the Why3 "driver" idea): everything needed to
    turn a structured obligation into a self-contained proof script for one external
    kernel. `binop` is the prover's row of the shared lowering table; `render vars
    hyps concl` wraps the lowered pieces in that prover's goal/quantifier/proof
    syntax. Adding a prover is a new value of this record, not new code paths. -/
structure ProverLowering where
  name  : String
  binop : BinOp → String → String → Option String
  /-- `render quantifiedVars loweredHyps loweredConclusion → full source file`. -/
  render : List String → List String → String → String
  /-- This prover's implication arrow (Rocq `->`, Isabelle `-->`). Needed to build a
      GROUND implication for the lowering-agreement check, which cannot reuse
      `render`'s hypothesis handling because it must also negate the whole thing. -/
  arrow : String := "->"
  /-- This prover's typed quantifier prefix for `vars` (Rocq `forall (a b : Z), `,
      Isabelle `ALL a b::int. `). The agreement check MUST keep this even though its
      instances are ground: Isabelle infers a fresh free type variable per numeral in
      an unquantified proposition (`0 ≤ (100::'b)`), so the lemma stops being about
      integers and `presburger` cannot prove it. Variables are therefore pinned by
      equality hypotheses rather than substituted away. -/
  binder : List String → String := fun _ => ""
  /-- Wrap a proposition in this prover's negation. Both Rocq and Isabelle spell it
      `~`, matching `exprToProver`'s `.not_` case. -/
  negate : String → String := fun p => s!"~ ({p})"
  /-- `batchRender closedPropositions → one source file asserting ALL of them`.
      Batching matters: the agreement check emits one lemma per grid assignment, and
      a fresh Isabelle session build per lemma would cost ~30s each. -/
  batchRender : List String → String := fun _ => ""

/-- Lower a contract `Expr` through an arbitrary prover's binop column. Same linear
    fragment as `exprToLeanProp` (int literals/vars, `+`/`-`/`*`, comparisons,
    connectives, unary `-`/`~`); `div`/`mod` dropped as in `toLeanProp`. Structured
    (not a string rewrite), so the emitted script is well-formed by construction.
    Coq and Isabelle share this: both spell unary neg `(- e)`, `not` `~`, and a
    negative literal `(-k)`; only the binary-op column and wrapper differ. -/
partial def exprToProver (binop : BinOp → String → String → Option String) : Expr → Option String
  | .intLit _ v => some (if v < 0 then s!"({v})" else s!"{v}")
  | .ident _ n => some n
  | .paren _ e => exprToProver binop e
  | .unaryOp _ op e => do
    let E ← exprToProver binop e
    match op with | .neg => some s!"(- {E})" | .not_ => some s!"(~ {E})" | _ => none
  | .binOp _ op l r => do
    let L ← exprToProver binop l; let R ← exprToProver binop r
    match op with
    | .div | .mod => none
    | _ => binop op L R
  | _ => none

/-! ### Bridge differential-check (feature #1)

An INDEPENDENT concrete evaluator for the contract fragment, used to fuzz proved
obligations: sample variable assignments, and check that no hypothesis-satisfying
assignment refutes the obligation's safety conclusion. A counterexample under a
*proved* obligation would mean the Core→VC bridge (or the discharge) claimed
something concretely false — the one thing "proved" must never do. Independent of
`exprToProver`/omega: it evaluates the arithmetic directly (truncating `/`,`%`,
matching Concrete's `IntArith`), so agreement is a real cross-check, not a tautology. -/

/-- Evaluate a contract `Expr` to an unbounded `Int` under a variable environment.
    `none` if outside the fragment or a `/`/`%` by zero. Truncating division. -/
partial def evalIntEnv (env : List (String × Int)) : Expr → Option Int
  | .intLit _ v => some v
  | .ident _ n => env.lookup n
  | .paren _ e => evalIntEnv env e
  | .unaryOp _ .neg e => (evalIntEnv env e).map (- ·)
  | .binOp _ op l r => do
    let a ← evalIntEnv env l; let b ← evalIntEnv env r
    match op with
    | .add => some (a + b) | .sub => some (a - b) | .mul => some (a * b)
    | .div => if b == 0 then none else some (a.tdiv b)
    | .mod => if b == 0 then none else some (a.tmod b)
    | _ => none
  | _ => none

/-- Evaluate a contract `Expr` to a `Bool` under an environment (hypotheses and
    safety conclusions). `none` if outside the fragment. -/
partial def evalBoolEnv (env : List (String × Int)) : Expr → Option Bool
  | .paren _ e => evalBoolEnv env e
  | .unaryOp _ .not_ e => (evalBoolEnv env e).map (! ·)
  | .binOp _ .and_ l r => do let a ← evalBoolEnv env l; let b ← evalBoolEnv env r; some (a && b)
  | .binOp _ .or_  l r => do let a ← evalBoolEnv env l; let b ← evalBoolEnv env r; some (a || b)
  | .binOp _ op l r => do
    let a ← evalIntEnv env l; let b ← evalIntEnv env r
    match op with
    | .leq => some (a ≤ b) | .lt => some (a < b) | .geq => some (a ≥ b)
    | .gt => some (a > b)  | .eq => some (a == b) | .neq => some (a != b)
    | _ => none
  | _ => none

/-- A family-neutral view of one linear obligation, so every runtime-safety family
    (overflow / array-bounds / div-nonzero, and any future family) flows through the
    SAME prover-neutral lowering instead of each re-implementing it. `mainExpr` is the
    operand/index/divisor to lower; `mkConcl` builds the obligation's conclusion from
    the driver's binop column and the lowered `mainExpr` — so each family states its
    own shape (`lo<=e<=hi`, `0<=i<n`, `d<>0`) in the prover's syntax. `desc` is the
    human display; `hyps` are the in-scope assumptions. Selection is the omega domain:
    non-constant obligations carrying a linear `leanGoal`, matched to omega by `key`. -/
structure MultiKernelObl where
  key      : String
  desc     : String
  hyps     : List Expr
  mainExpr : Expr
  mkConcl  : (BinOp → String → String → Option String) → String → Option String
  -- concrete safety check for the bridge fuzzer (feature #1): does the obligation's
  -- conclusion hold under this environment? `none` if it can't be evaluated.
  safeOn   : List (String × Int) → Option Bool
  -- The obligation's OWN boundary values — the type range for overflow, `0` and the
  -- length for bounds, `0` for a divisor. These are where a comparison-operator error
  -- lives: `<=` rendered as `<` differs from the reference ONLY at a boundary, and
  -- nowhere else. They were previously captured inside `mkConcl`/`safeOn` and invisible
  -- to the grid, so whether the mutation was detected depended on the boundary happening
  -- to appear as a literal in the hypotheses. Measured: `fuzzGrid` contains 3 and 100 but
  -- not 4, so a `[i32; 4]` bounds obligation caught it only incidentally.
  boundaryVals : List Int := []

/-- Collect the linear runtime-safety obligations of every family into the neutral
    view. Adding a family is a new block here, not a new lowering. -/
def multiKernelObligations (modules : List Module) (requireLeanGoal : Bool := true)
    : List MultiKernelObl := Id.run do
  let mut out : List MultiKernelObl := []
  for o in overflowObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => do let lo ← bop .leq (toString o.lo) e; let hi ← bop .leq e (toString o.hi); bop .and_ lo hi
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.opExpr).map (fun v => o.lo ≤ v && v ≤ o.hi)
      out := out ++ [{ boundaryVals := [o.lo, o.hi], key := o.key, desc := s!"{Concrete.fmtExpr o.opExpr} ∈ [{o.lo}, {o.hi}]", hyps := o.hyps, mainExpr := o.opExpr, mkConcl := mk, safeOn := safe }]
  for o in boundsObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => do let lo ← bop .leq "0" e; let hi ← bop .lt e (toString o.size); bop .and_ lo hi
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.idxExpr).map (fun v => 0 ≤ v && v < (Int.ofNat o.size))
      out := out ++ [{ boundaryVals := [0, Int.ofNat o.size], key := o.key, desc := s!"0 ≤ {Concrete.fmtExpr o.idxExpr} < {o.size} (bounds of {o.arrName})", hyps := o.hyps, mainExpr := o.idxExpr, mkConcl := mk, safeOn := safe }]
  for o in divObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => bop .neq e "0"
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.divExpr).map (fun v => v != 0)
      out := out ++ [{ boundaryVals := [0], key := o.key, desc := s!"{Concrete.fmtExpr o.divExpr} ≠ 0 (divisor)", hyps := o.hyps, mainExpr := o.divExpr, mkConcl := mk, safeOn := safe }]
  return out

/-- Result of fuzzing one obligation against the concrete evaluator (feature #1). -/
structure BridgeFuzzResult where
  key            : String
  desc           : String
  hypSat         : Nat                              -- assignments satisfying every hypothesis
  counterexample : Option (List (String × Int))     -- a hyp-satisfying assignment that REFUTES safety

/-- Integer probes, including i32 extremes and 46341 (≈√(2^31), where `a*a`
    overflows i32) so the fuzzer actually finds real violations. -/
def fuzzGrid : List Int := [-2147483648, -100, -3, -1, 0, 1, 3, 100, 46341, 2147483647]

/-- Cartesian product of `vals` over `vars` (all assignments). Callers bound `vars`
    and shrink `vals` to keep this finite. -/
partial def cartesianEnvs (vars : List String) (vals : List Int) : List (List (String × Int)) :=
  match vars with
  | [] => [[]]
  | v :: rest =>
    let restEnvs := cartesianEnvs rest vals
    vals.flatMap (fun x => restEnvs.map (fun e => (v, x) :: e))

/-- Fuzz every linear obligation against the INDEPENDENT concrete evaluator: over a
    grid of assignments, keep those satisfying all hypotheses, and look for one that
    refutes the safety conclusion. A counterexample under a *proved* obligation is a
    bridge/discharge unsoundness; a counterexample under an *unproved* one validates
    that the fuzzer has teeth. Assignments where a hypothesis can't be evaluated are
    conservatively excluded (never tested against). -/
def bridgeFuzz (modules : List Module) : List BridgeFuzzResult := Id.run do
  let mut out : List BridgeFuzzResult := []
  for o in multiKernelObligations modules do
    let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
    -- keep the grid finite: shrink to extremes when there are many variables.
    let grid := if vars.length ≥ 4 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647] else fuzzGrid
    let mut hypSat := 0
    let mut cex : Option (List (String × Int)) := none
    for env in cartesianEnvs vars grid do
      if o.hyps.all (fun h => evalBoolEnv env h == some true) then
        hypSat := hypSat + 1
        if o.safeOn env == some false && cex.isNone then cex := some env
    out := out ++ [{ key := o.key, desc := o.desc, hypSat, counterexample := cex }]
  return out

/-! ### Lowering-agreement check — closing the "same proposition?" hole

`proved_by_two_kernels` matches kernels on the obligation KEY, and each driver
re-spells the obligation in its own syntax. Nothing so far checks that those
spellings mean the SAME thing, which the multi-kernel report states outright as a
non-attestation. So two kernels could each close a DIFFERENT (possibly weaker)
proposition and the report would still read `proved_by_two_kernels` — the badge
would be measuring agreement it never established.

This closes that hole without writing a parser per prover syntax: use each prover
as the evaluator of its OWN output. We take the driver's rendering of the obligation
verbatim — the same string the multi-kernel path sends the kernel — and PIN its
variables to one grid assignment with equality hypotheses, giving a proposition
whose truth value is decided (`lia`/`presburger` both decide ground linear
arithmetic either way). We compare that against the reference truth value from
`evalBoolEnv`, the independent concrete evaluator already used by the bridge fuzzer:

  * reference TRUE  → the prover must prove the ground implication
  * reference FALSE → the prover must prove its NEGATION

If every instance checks, the driver's rendering has the same truth table as the
reference on the grid — so precedence bugs, a wrong operator column (`~=` vs `<>`),
and mangled hypotheses all surface. Mapping onto `KernelVerdict` is exact: a
malformed rendering is a syntax `error`, while a well-formed rendering that means
something else is a `refused` — a real DISAGREEMENT.

Honest limits. This is a differential test, not a proof of equivalence: it certifies
agreement on the SAMPLED assignments only. A rendering that differs only at values
the hypotheses make unreachable will (correctly) read as agreeing, and one that
differs only outside the grid will be missed — hence `agreementGrid` seeds the
literals appearing in the obligation and their ±1 neighbours, which is where
comparison-operator errors live. -/

/-- How many ground instances to check per obligation. Bounded because each instance
    is a lemma in the emitted script; hypothesis-satisfying assignments are taken
    first since they are the informative ones (a vacuous instance is trivially true
    for the prover, though it still catches a hypothesis rendered too weakly). -/
def agreementInstanceCap : Nat := 24

/-- Every integer literal occurring in an expression. Used to derive BOUNDARY probe
    values, because an off-by-one operator bug (`<=` rendered as `<`) only shows up
    at a value where the two differ — a fixed grid can miss it entirely. -/
partial def collectIntLits : Expr → List Int
  | .intLit _ v => [v]
  | .paren _ e => collectIntLits e
  | .unaryOp _ _ e => collectIntLits e
  | .binOp _ _ l r => collectIntLits l ++ collectIntLits r
  | _ => []

/-- Probe values for one obligation: the shared grid plus each literal appearing in
    the obligation or its hypotheses, and each literal ±1. Those neighbours are what
    make a comparison-operator error observable. -/
def agreementGrid (o : MultiKernelObl) (base : List Int) : List Int :=
  -- Seed from the literals appearing in the obligation AND from the obligation's own
  -- boundary values, each with its ±1 neighbours. The boundaries are the load-bearing
  -- addition: a comparison-operator error differs from the reference only there, so a grid
  -- that does not reach them cannot detect one. Relying on the boundary appearing as a
  -- literal made detection incidental.
  let lits := (o.hyps.flatMap collectIntLits ++ collectIntLits o.mainExpr ++ o.boundaryVals)
  let withNeighbours := lits.flatMap (fun v => [v - 1, v, v + 1])
  (base ++ withNeighbours).eraseDups

/-- One `(vcKey, proofScript)` per obligation: a single batched script whose lemmas
    are the ground instances described above. A `refused` verdict on that script
    means this obligation's lowering DISAGREES with the reference evaluator.
    Obligations whose lowering is outside the fragment are skipped (never asked). -/
def loweringAgreementScripts (pl : ProverLowering) (modules : List Module)
    : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in multiKernelObligations modules do
    let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
    -- Boundary-aware grid. With ≥3 variables the cartesian product explodes, so use
    -- the bare extremes there and reserve the literal-derived neighbours (which is
    -- what catches an off-by-one operator column) for the small-arity cases.
    let base := if vars.length ≥ 4 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647]
                else fuzzGrid
    let grid := if vars.length ≥ 3 then base else agreementGrid o base
    -- partition the grid by whether the hypotheses hold, preferring the informative
    -- (hypothesis-satisfying) assignments up to the cap.
    let envs := cartesianEnvs vars grid
    let sat := envs.filter (fun e => o.hyps.all (fun h => evalBoolEnv e h == some true))
    let unsat := envs.filter (fun e => !(o.hyps.all (fun h => evalBoolEnv e h == some true)))
    -- Implication instances want hypothesis-SATISFYING assignments: those are where
    -- the implication is not vacuous.
    let implEnvs := (sat.take agreementInstanceCap)
                    ++ (unsat.take (agreementInstanceCap - min agreementInstanceCap sat.length))
    -- Conclusion-only instances must span the WHOLE grid, hypotheses or not. Taking
    -- only hypothesis-satisfying points here would defeat the purpose: a weakened
    -- conclusion is invisible on the domain the hypotheses carve out (see below), so
    -- half the budget is spent on assignments the hypotheses reject.
    let half := agreementInstanceCap / 2
    let conclEnvs := (sat.take half) ++ (unsat.take half)
    -- The driver's rendering of the obligation itself, rendered ONCE: this is the
    -- very string the multi-kernel path sends the kernel, so we are checking the
    -- production lowering, not a special variant of it.
    let concl := (exprToProver pl.binop o.mainExpr).bind (o.mkConcl pl.binop)
    let loweredHyps := o.hyps.mapM (exprToProver pl.binop)
    match concl, loweredHyps with
    | some c, some hs =>
      let body := String.join (hs.map (fun h => s!"({h}) {pl.arrow} ")) ++ c
      -- Pin each variable to an assignment with an equality hypothesis instead of
      -- substituting a literal, so the prover's TYPED binder is retained. Returns
      -- `none` if some variable has no value in this environment.
      let pinnedClaim := fun (env : List (String × Int)) (claim : String) (truth : Bool) =>
        let pins := vars.filterMap (fun v => do
          let value ← env.lookup v
          let lit := if value < 0 then s!"({value})" else s!"{value}"
          pl.binop .eq v lit)
        if pins.length != vars.length then none
        else
          let pinArrows := String.join (pins.map (fun p => s!"({p}) {pl.arrow} "))
          some s!"{pl.binder vars}{pinArrows}{if truth then claim else pl.negate claim}"
      let mut props : List String := []
      -- (a) the WHOLE implication, which exercises the hypothesis rendering.
      for env in implEnvs do
        match o.safeOn env with
        | none => pure ()   -- no reference obtainable; never guess
        | some cv =>
          let hypsHold := o.hyps.all (fun h => evalBoolEnv env h == some true)
          match pinnedClaim env body (!hypsHold || cv) with
          | some p => props := props ++ [p]
          | none => pure ()
      -- (b) the CONCLUSION alone, over a spread of the grid and ignoring whether the
      -- hypotheses hold. This is what catches a WEAKENED conclusion: rendering
      -- `A ∧ B` as `A ∨ B` has the same truth value everywhere the hypotheses hold
      -- (both conjuncts are true there), so (a) alone provably cannot see it. The two
      -- differ only where exactly one side holds — assignments the hypotheses reject,
      -- but still perfectly good tests of the RENDERING itself.
      for env in conclEnvs do
        match o.safeOn env with
        | none => pure ()
        | some cv =>
          match pinnedClaim env c cv with
          | some p => props := props ++ [p]
          | none => pure ()
      if !props.isEmpty then
        out := out ++ [(o.key, pl.batchRender props)]
    | _, _ => pure ()   -- outside the fragment: never asked
  return out

/-- `(vcKey, proofScript)` for each linear obligation (ALL families), lowered through
    the given driver. The conclusion is built via the driver's binop column, so `<=` /
    `<` / `<>` / conjunction are spelled the prover's way. Soundness: if the main expr,
    ANY hypothesis, or the conclusion falls outside the fragment we DROP the whole goal
    (never emit a partial one — a dropped goal reads `not-asked`, never a false verdict). -/
def proverReplayGoals (pl : ProverLowering) (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in multiKernelObligations modules do
    let concl : Option String := (exprToProver pl.binop o.mainExpr).bind (o.mkConcl pl.binop)
    match concl, o.hyps.mapM (exprToProver pl.binop) with
    | some c, some hyps =>
      let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
      out := out ++ [(o.key, pl.render vars hyps c)]
    | _, _ => pure ()
  return out

/-- Rocq/`coqc` driver: `Goal forall (vars : Z), h1 -> ... -> concl. Proof. lia. Qed.`
    `lia` is Coq's linear-integer-arithmetic decision procedure (CIC kernel). -/
def rocqLowering : ProverLowering where
  name := "rocq"
  binop := rocqBinOp
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"forall ({" ".intercalate vars} : Z), "
    let arrows := String.join (hyps.map (fun h => s!"({h}) -> "))
    "\n".intercalate
      [ "(* second-kernel (Rocq/lia) check of a linear runtime-safety obligation *)",
        "From Stdlib Require Import ZArith.", "From Stdlib Require Import Lia.",
        "Open Scope Z_scope.", s!"Lemma vc : {binder}{arrows}{concl}.", "Proof. lia. Qed.",
        -- ATTEST: `coqc` exits 0 on `Admitted.` too, so the exit code cannot tell a
        -- closed proof from a stated one. `Print Assumptions` can: a Qed-closed proof
        -- prints "Closed under the global context", an admitted one lists it under
        -- "Axioms:". The script therefore asserts its own integrity.
        "Print Assumptions vc." ]
  arrow := "->"
  binder := fun vars =>
    if vars.isEmpty then "" else s!"forall ({" ".intercalate vars} : Z), "
  batchRender := fun props =>
    "\n".intercalate
      ([ "(* lowering-agreement check: pinned instances of ONE obligation *)",
         "From Stdlib Require Import ZArith.", "From Stdlib Require Import Lia.",
         "Open Scope Z_scope." ]
       ++ props.zipIdx.map (fun (p, i) =>
            s!"Lemma agree{i} : {p}.\nProof. lia. Qed.\nPrint Assumptions agree{i}."))

/-- Isabelle/HOL driver: `lemma "ALL vars::int. h1 --> ... --> concl" by presburger`.
    `presburger` decides linear integer arithmetic in a HOL kernel — independent of
    CIC, so agreement with Lean/Rocq is FOUNDATIONAL cross-logic independence. -/
def isabelleLowering : ProverLowering where
  name := "isabelle"
  binop := isabelleBinOp
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "
    let arrows := String.join (hyps.map (fun h => s!"({h}) --> "))
    "\n".intercalate
      [ "theory VC imports Main begin",
        s!"lemma \"{binder}{arrows}{concl}\"", "  by presburger", "end" ]
  arrow := "-->"
  binder := fun vars =>
    if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "
  batchRender := fun props =>
    -- each lemma needs a distinct name, hence the index
    "\n".intercalate
      ([ "theory VC imports Main begin" ]
       ++ (props.zipIdx.map (fun (p, i) => s!"lemma agree{i}: \"{p}\"\n  by presburger"))
       ++ [ "end" ])

/-- Rocq driver using `nia` (nonlinear integer arithmetic) instead of `lia`. Used to
    CERTIFICATE-CHECK the solver: a nonlinear VC an external SMT solver reports `unsat`
    (`solver_trusted`, solver in the TCB) that Rocq's `nia` ALSO closes graduates to
    `solver_checked` — an independent kernel corroborated the solver, so the solver
    drops out of the trusted base. `nia` ships with `Require Import Lia` (micromega). -/
def rocqNiaLowering : ProverLowering where
  name := "rocq-nia"
  binop := rocqBinOp
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"forall ({" ".intercalate vars} : Z), "
    let arrows := String.join (hyps.map (fun h => s!"({h}) -> "))
    "\n".intercalate
      [ "(* certificate-check (Rocq/nia) of a solver-trusted nonlinear obligation *)",
        "From Stdlib Require Import ZArith.", "From Stdlib Require Import Lia.",
        "Open Scope Z_scope.", s!"Lemma vc : {binder}{arrows}{concl}.", "Proof. nia. Qed.",
        "Print Assumptions vc." ]

/-- SMT-eligible overflow obligations (the genuinely NONLINEAR ones the kernel tiers
    left open — same selection as `overflowSmtGoals`), as structured obligations so
    they can be lowered to Rocq `nia` for certificate-checking. -/
def smtEligibleOverflow (modules : List Module) : List OverflowObl :=
  (overflowObligations modules).filter fun o =>
    o.closedVerdict.isNone && o.bvGoal.isNone && exprHasNonlinMul o.opExpr

/-- `(vcKey, coqSource)` lowering each SMT-eligible nonlinear overflow obligation to a
    Rocq `nia` goal — the certificate-check of the solver's `unsat` verdict. -/
def rocqNiaGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in smtEligibleOverflow modules do
    let concl : Option String := do
      let e ← exprToProver rocqBinOp o.opExpr
      let lo ← rocqBinOp .leq (toString o.lo) e
      let hi ← rocqBinOp .leq e (toString o.hi)
      rocqBinOp .and_ lo hi
    match concl, o.hyps.mapM (exprToProver rocqBinOp) with
    | some c, some hyps =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      out := out ++ [(o.key, rocqNiaLowering.render vars hyps c)]
    | _, _ => pure ()
  return out

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

/-- Stable identity for one loop obligation, shared by the goal collector and
    the renderer so discharge results map back to the right line. -/
def loopVCKey (fnQual : String) (line : Nat) (obl : String) : String :=
  s!"{fnQual}@{line}#{obl}"

/-- Collect the loop VCs that a kernel decision procedure can discharge:
    `invariant_init` (O1), `variant_nonnegative` (O4), `variant_decreases` (O5).
    Each is `(key, leanGoal)` where the goal is the same string the report
    shows — it is already valid Lean (`∀ (i : Int), … `) provable by
    `intros; omega`. Preservation (O2) stays hand-linked; exit-link (O3) needs a
    postcondition. -/
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
def loopContractSection (modules : List Module) (registry : ProofRegistry)
    (provedVCs : List String := []) (provedVacuous : List String := []) : String := Id.run do
  let withLoops := (modules.flatMap allFunctions).filter (fun (_, f) => !f.loopContracts.isEmpty)
  if withLoops.isEmpty then return ""
  let callables := callableContractNames modules
  let consts := contractConstNames modules
  let impures := impureFnNames modules
  let mut out := "\n\n=== Loop contracts ==="
  for (pfx, f) in withLoops do
    -- a registered `coverage: invariant` proof discharges invariant_preservation
    let preserveProof : Option String :=
      match registry.find? (fun e => e.function == pfx ++ f.name) with
      | some e => if e.coverage == "invariant" && !e.proof.isEmpty then some e.proof else none
      | none => none
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

partial def contractsReport (modules : List Module) (registry : ProofRegistry)
    (provedVCs : List String := []) (provedVacuous : List String := []) : String := Id.run do
  let callables := callableContractNames modules
  let consts := contractConstNames modules
  let impures := impureFnNames modules
  -- Discharge status for an `#[ensures]` on `qual`. Tiers, honest about partial
  -- coverage: a registered `ensures_proof` → fully proved_by_lean. Otherwise, a
  -- registered `proof` with directional coverage (`one_direction`) discharges
  -- ONE direction of the postcondition — shown as partial, with the converse
  -- still outstanding — rather than collapsing to a bare "missing".
  let discharge (qual : String) : String :=
    match registry.find? (fun e => e.function == qual) with
    | some e => match e.ensuresProof with
      | some thm =>
        -- `iff` coverage with both a `proof` and an `ensures_proof` means the
        -- two directions of an iff postcondition are each kernel-checked.
        if e.coverage == "iff" && !e.proof.isEmpty then
          s!"\n     status:  proved_by_lean (full iff)\n     forward direction:  {e.proof}\n     converse direction: {thm}"
        else s!"\n     status:  proved_by_lean\n     theorem: {thm}"
      | none =>
        if !e.proof.isEmpty && e.coverage == "one_direction" then
          s!"\n     status:  partial — one direction proved_by_lean, converse outstanding\n     theorem: {e.proof}  (coverage: one_direction)\n     note:    full postcondition not yet discharged; the converse is the next obligation"
        else "\n     status:  missing (registry entry has no ensures_proof)"
    | none => "\n     status:  missing (no in-source proof link for this function)"
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
        -- discharged by a registered ensures_proof, or missing.
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
