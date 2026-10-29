import Std.Data.HashSet
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
import Concrete.Report.TermTranslate
import Concrete.Semantics.Capabilities
-- Obligation collectors need only the contract/VC helper cluster, not the
-- capability/arith/unsafe/layout report renderers (pipeline #34).
import Concrete.Report.ReportVC

/-! Runtime-safety obligations: array bounds, loop-invariant scope, division, shifts and (opt-in) overflow, with the nonlinear interval discharge. Split out of ReportObligations.lean;
    `Concrete.Report.ReportObligations` imports all three. -/

namespace Concrete
namespace Report


/-- The NAME an array access is rooted at, peeling `(…)`.

    `a[i]` and `(a)[i]` denote the same access, but bounds discovery matched a BARE `.ident`
    and so generated an obligation only for the first — no VC, no `unproven` marker, nothing
    in the report. Found by `collectIndexUsesE_complete`: writing the completeness predicate
    forced the question "which array expressions are actually recorded?", and the honest
    answer was narrower than anyone had assumed.

    Only `.paren` is peeled. It is meaning- AND type-preserving, so the enclosing
    length lookup (`ScopeDecls.sizes`, keyed by name) stays correct. `.deref`/`.fieldAccess` are NOT
    peeled: they change the type at which the length must be read, so treating them as the
    same name would trade a missing obligation for a WRONG one. -/
def arrayRootName : Expr → Option String
  | .ident _ n => some n
  | .paren _ x => arrayRootName x
  | _ => none

/-- Termination helper for the discovery walkers (R-0455).

    An `else` branch is `Option (List Stmt)`, and the walkers recurse into `el.getD []`. The
    membership fact `attach` supplies is about the DEFAULTED list, so the size bound has to
    climb back out to the `Option` itself; `List.sizeOf_lt_of_mem` alone does not reach. -/
theorem sizeOf_mem_getD {α} [SizeOf α] {o : Option (List α)} {x : α}
    (h : x ∈ o.getD []) : sizeOf x < sizeOf o := by
  cases o with
  | none => simp at h
  | some l =>
    simp only [Option.getD_some] at h
    have := List.sizeOf_lt_of_mem h
    simp +arith
    omega


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
def collectIndexUsesE : Expr → List (Expr × Expr)
  -- EVERY indexed access is recorded, as the array EXPRESSION rather than a name. Requiring
  -- a bare `.ident` here is what made `b.data[i]` invisible to bounds discovery: not an
  -- unproven VC, absent entirely. Whether a length can be resolved is a separate question,
  -- answered by `arrayAccessOf` and reported when the answer is no.
  | .arrayIndex _ a idx => (a, idx) :: (collectIndexUsesE a ++ collectIndexUsesE idx)
  | .binOp _ _ l r => collectIndexUsesE l ++ collectIndexUsesE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .cast _ x _ | .fieldAccess _ x _ => collectIndexUsesE x
  | .arrayLit _ es => es.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesE e)
  | .call _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesE e)
  | .methodCall _ o _ _ args => collectIndexUsesE o ++ args.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesE e)
  | .staticMethodCall _ _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesE e)
  | .structLit _ _ _ fs base => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectIndexUsesE fe) ++ (base.attach.map (fun ⟨e, _⟩ => collectIndexUsesE e)).getD []
  | .enumLit _ _ _ _ fs => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectIndexUsesE fe)
  | .allocCall _ x a => collectIndexUsesE x ++ collectIndexUsesE a
  | .ifExpr _ c t el =>
      collectIndexUsesE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e) ++ el.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e)
  | .match_ _ s _ => collectIndexUsesE s
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
def collectIndexUsesS : Stmt → List (Expr × Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectIndexUsesE v
  | .return_ _ (some v) => collectIndexUsesE v
  | .ifElse _ c t el => collectIndexUsesE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e) ++ (el.getD []).attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e)
  | .while_ _ c b _ => collectIndexUsesE c ++ b.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e)
  | .forLoop _ init c step b _ =>
      (init.attach.map (fun ⟨e, _⟩ => collectIndexUsesS e)).getD [] ++ collectIndexUsesE c
        ++ (step.attach.map (fun ⟨e, _⟩ => collectIndexUsesS e)).getD [] ++ b.attach.flatMap (fun ⟨e, _⟩ => collectIndexUsesS e)
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectIndexUsesE o ++ collectIndexUsesE v
  | .arrayIndexAssign _ a idx v =>
      (a, idx) :: (collectIndexUsesE a ++ collectIndexUsesE idx ++ collectIndexUsesE v)
  -- Missing until 2026-08-06, as in the three sibling statement walkers: `assert_`/`assume_`
  -- carry a condition, `borrowIn` a body, and both destructuring forms a scrutinee, so each is a
  -- place an indexed access can hide.
  | .assert_ _ c | .assume_ _ c => collectIndexUsesE c
  | .borrowIn _ _ _ _ _ b => b.attach.flatMap (fun ⟨x, _⟩ => collectIndexUsesS x)
  | .letDestructure _ _ _ _ v _ => collectIndexUsesE v
  | .letStructDestructure _ _ _ v => collectIndexUsesE v
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
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

/-- Accumulator form of `assignedScalarsS`, newest first. The old
    `t.flatMap … ++ …` copied each level's whole result into its parent's, so a
    statement nested `k` deep cost O(k²) — and the scoped walk asks once per
    level, O(n³) for an n-deep nest of `if`s on the ordinary compile path
    (bug 178). Same names, same order. -/
partial def assignedScalarsGo (acc : List String) : Stmt → List String
  | .assign _ n _ => n :: acc
  | .letDecl _ n _ _ _ _ => n :: acc
  | .ifElse _ _ t el => (el.getD []).foldl assignedScalarsGo (t.foldl assignedScalarsGo acc)
  | .while_ _ _ b _ => b.foldl assignedScalarsGo acc
  | .forLoop _ init _ step b _ =>
      let acc := (init.map (assignedScalarsGo acc)).getD acc
      let acc := (step.map (assignedScalarsGo acc)).getD acc
      b.foldl assignedScalarsGo acc
  | _ => acc

/-- Scalar variables a statement assigns to. Mutating one invalidates any
    in-scope hypothesis that mentions it. Array-element / field / deref stores
    assign no integer counter (the domain our invariants range over), so they
    return `[]`; a nested loop invalidates whatever its body assigns. -/
def assignedScalarsS (s : Stmt) : List String :=
  (assignedScalarsGo [] s).reverse

/-- Drop every in-scope hypothesis that mentions a just-assigned variable.
    `assigned` becomes a HashSet once (bug 178): the statement holding the rest of an
    n-deep nest assigns O(n) names, so list membership per identifier per hypothesis
    made each call O(scope × idents × n). -/
def dropStaleHyps (scope : List Expr) (assigned : List String) : List Expr :=
  if scope.isEmpty then [] else
  let assignedSet : Std.HashSet String := assigned.foldl (·.insert ·) ∅
  scope.filter fun h => (collectIdents h).all (fun v => !assignedSet.contains v)

/-- `{fnQual}@{line}#{obl}`: the stable identity of one loop obligation, shared by the goal
    collector, the renderer and discovery, so discharge results map back to the right line.
    (There used to be a forward copy, `loopVCKeyFwd`, because the first use came before the
    definition in one file.) -/
def loopVCKey (fnQual : String) (line : Nat) (obl : String) : String :=
  s!"{fnQual}@{line}#{obl}"

/-- The loop VCs an obligation's hypotheses OWE — R-0461, closing H23.

    `loopHypsAt` puts a loop's `#[invariant]` expressions verbatim into scope, so an
    obligation discharged inside that loop was proved ASSUMING them. Whether they hold is a
    separate question answered by that loop's O1 (init) and O2 (preservation), and until
    2026-08-03 nothing related the two: a bounds obligation could read
    `proved_by_multi_kernel` while the invariant it rested on read `unproven` in the same
    report, and the compiled program aborted. See `examples/unsound_hypothesis/`.

    Recovered by MATCHING rather than by threading a second value through `scopedWalk`. The
    walker inserts the invariant `Expr` unchanged, so an obligation owes a loop exactly when
    its hypotheses still contain one of that loop's invariants — and `dropStaleHyps` having
    removed it means the obligation no longer assumes it and correctly owes nothing.

    Compared on `fmtExpr` because `Expr` derives only `Repr`: it carries spans, so structural
    equality would distinguish two occurrences of the same invariant. Over-matching is the
    safe direction here (extra debt is conservative); under-matching would be unsound, which
    is why the comparison is on the normalised form rather than on span-bearing terms.

    Only O1 and O2 are owed. O3 (exit implies post) is about the function's `#[ensures]`, and
    O4/O5 are the variant's termination argument — neither is what makes an in-loop
    hypothesis true at the point the obligation is discharged. -/
def loopInvariantDebt (f : FnDef) (fq : String) (hyps : List Expr) : List String :=
  let hypForms := hyps.map Concrete.fmtExpr
  f.loopContracts.flatMap fun lc =>
    if lc.invariants.any (fun inv => hypForms.contains (Concrete.fmtExpr inv))
    then [loopVCKey fq lc.line "O1", loopVCKey fq lc.line "O2"]
    else []

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
/-- Collect every struct in a module tree, submodules included. -/
def allStructsOf (m : Module) : List StructDef :=
  m.structs ++ m.submodules.attach.flatMap (fun ⟨sub, _⟩ => allStructsOf sub)
termination_by sizeOf m
decreasing_by
  all_goals simp_wf
  all_goals
    (rename_i h
     have := List.sizeOf_lt_of_mem h
     cases m
     simp +arith at this ⊢
     omega)

/-- Struct name → its field types. Global, not scoped, so it is passed alongside `ScopeDecls`
    rather than inside it. -/
abbrev StructFieldEnv := List (String × List (String × Ty))

/-- Struct field types for a whole program, keyed by struct name. -/
def structFieldEnv (modules : List Module) : StructFieldEnv :=
  (modules.flatMap allStructsOf).map fun sd =>
    (sd.name, sd.fields.map (fun f => (f.name, f.ty)))

/-- Peel references/pointers to reach a named struct. -/
def namedStructOf : Ty → Option String
  | .named n => some n
  -- A struct whose only arguments are CAPABILITIES has the same fields for every
  -- instantiation, so field paths through it resolve exactly as through `.named n`.
  -- Without this arm, giving a struct a capability parameter would silently remove it
  -- from bounds discovery. (Structs with TYPE arguments stay excluded, as before: their
  -- field types would need substituting.)
  | .generic n [] _ => some n
  | .ref t | .refMut t | .ptrMut t | .ptrConst t | .heap t => namedStructOf t
  | _ => none

/-- Type of a PLACE expression, following field paths through struct definitions.

    `exprIntTy` deliberately stops at integer-typed leaves; this one exists to answer "what
    array is `b.data`?", which is what bounds discovery could not previously ask. -/
def placeTy (structs : StructFieldEnv) (tys : List (String × Ty)) : Expr → Option Ty
  | .ident _ n => tys.lookup n
  | .paren _ e | .borrow _ e | .borrowMut _ e | .deref _ e => placeTy structs tys e
  | .fieldAccess _ o f => do
      let ot ← placeTy structs tys o
      let sname ← namedStructOf ot
      let fields ← structs.lookup sname
      fields.lookup f
  | _ => none

/-- Declarations in scope at a program point: variable types and fixed array lengths.

    Both were previously flat per-function maps (`varTyMap`, `arraySizeMap`) resolved by NAME,
    which meant a shadowed variable was resolved from the wrong binding. For array sizes that
    produced a bound about the wrong array; for types it produced a shift-width obligation
    about the wrong width — `x << 40` on an `i8` was reported PROVED because an earlier
    `x : i64` supplied the width. Threading them per scope is what makes the answer correspond
    to the code.

    Kept as one record rather than two threaded parameters so a future declaration kind cannot
    be added to one and forgotten in the other. -/
structure ScopeDecls where
  /-- Variable → declared type: parameters and ANNOTATED lets. Unannotated lets are absent
      deliberately — inferring a type here risks disagreeing with the checker, and a wrong
      type is exactly the defect being fixed. Their obligations are dropped and named. -/
  tys   : List (String × Ty) := []
  /-- Variable → fixed array length. Includes lengths inferred from an array-literal
      initialiser, which needs no type inference to be certain of. -/
  sizes : List (String × Nat) := []
  deriving Inhabited

/-- Declarations introduced by THIS statement — deliberately not recursive; scoping is the
    walker's job. -/
def declsOwn : Stmt → ScopeDecls
  | .letDecl _ nm _ (some t) _ _ =>
      { tys := [(nm, t)]
      , sizes := match t with | .array _ n => [(nm, n)] | _ => [] }
  | .letDecl _ nm _ none (.arrayLit _ es) _ => { sizes := [(nm, es.length)] }
  | _ => {}

/-- Inner declarations shadow outer ones: prepended, and every lookup takes the first match. -/
def ScopeDecls.extend (inner outer : ScopeDecls) : ScopeDecls :=
  { tys := inner.tys ++ outer.tys, sizes := inner.sizes ++ outer.sizes }

/-- The declarations a function body starts from. -/
def paramDecls (f : FnDef) : ScopeDecls :=
  { tys := f.params.map (fun p => (p.name, p.ty))
  , sizes := f.params.filterMap fun p =>
      match p.ty with | .array _ n => some (p.name, n) | _ => none }

/-- Bug 293: the hypotheses in scope at a program point, as the scoped walker threads them.
    `rev` holds them newest first, so entering a branch or a loop body is a cons (the list
    `scope ++ [c]` copied the whole scope at every nesting level, n² for an n-deep nest), and
    `toList` restores the order the leaves and every obligation see. `idents` holds every
    identifier some hypothesis names, so the invalidation after a statement filters the scope only
    when the statement assigns one of them; it may name more than the current hypotheses (it grows
    with each push and is recomputed after a drop that filters), never fewer. -/
structure ScopeHyps where
  rev    : List Expr := []
  idents : Std.HashSet String := {}

def ScopeHyps.push (sc : ScopeHyps) (h : Expr) : ScopeHyps :=
  { rev := h :: sc.rev, idents := (collectIdents h).foldl (·.insert ·) sc.idents }

/-- `sc` followed by `hs`, in order: the hand-threaded `scope ++ hs`. -/
def ScopeHyps.pushAll (sc : ScopeHyps) (hs : List Expr) : ScopeHyps := hs.foldl ScopeHyps.push sc

def ScopeHyps.ofList (hs : List Expr) : ScopeHyps := ScopeHyps.pushAll {} hs

def ScopeHyps.toList (sc : ScopeHyps) : List Expr := sc.rev.reverse

/-- `dropStaleHyps` on the threaded scope: the hypotheses that name no assigned variable, in
    order. When no identifier the scope names is assigned, the filter would keep every hypothesis
    and the scope is returned unchanged; the test walks the smaller of the two sets. -/
def ScopeHyps.drop (sc : ScopeHyps) (assigned : Std.HashSet String) : ScopeHyps :=
  if sc.rev.isEmpty then {} else
  let hit := if sc.idents.size ≤ assigned.size
    then sc.idents.fold (fun b v => b || assigned.contains v) false
    else assigned.fold (fun b v => b || sc.idents.contains v) false
  if !hit then sc else
  let kept := sc.rev.filter fun h => (collectIdents h).all (fun v => !assigned.contains v)
  { rev := kept, idents := kept.foldl (fun acc h => (collectIdents h).foldl (·.insert ·) acc) {} }

/-- The union of two assigned-name sets, inserting the smaller into the larger. -/
def unionAssigned (a b : Std.HashSet String) : Std.HashSet String :=
  if a.size ≤ b.size then a.fold (·.insert ·) b else b.fold (·.insert ·) a

mutual
/-- The walk of one statement: its obligations, and the scalars it assigns (`assignedScalarsS`,
    as a set). Bug 293: the scalars come back from the walk, which visits every sub-statement
    anyway; the block walker used to ask `assignedScalarsS`, a walk of the statement's whole
    subtree, for every statement, so a nested `if` was walked again at each level above it. The
    set follows `assignedScalarsGo` case by case: a `borrow … in` block, and every other statement
    but `let` and `=`, assigns nothing. -/
partial def scopedWalkGoS {α}
    (leaf : Thunk (List Expr) → ScopeDecls → Stmt → List α)
    (lcs : List LoopContract) (scope : ScopeHyps) (decls : ScopeDecls) :
    Stmt → List α × Std.HashSet String
  | s@(.ifElse _ c t el) =>
      let (oThen, aThen) := scopedWalkGoB leaf lcs (scope.push c) decls t
      let (oElse, aElse) := scopedWalkGoB leaf lcs (scope.pushAll (negateGuard c).toList) decls (el.getD [])
      (leaf (Thunk.mk fun _ => scope.toList) decls s ++ oThen ++ oElse, unionAssigned aThen aElse)
  | s@(.while_ sp _ b _) =>
      let (oBody, aBody) := scopedWalkGoB leaf lcs (scope.pushAll (loopHypsAt lcs sp.line)) decls b
      (leaf (Thunk.mk fun _ => scope.toList) decls s ++ oBody, aBody)
  | s@(.forLoop sp init _ step b _) =>
      -- init, then this statement's own leaves (the loop condition), then step,
      -- then body — the traversal ORDER every family's old walker used, so the
      -- positional `#idx`/`#pre`/… keys are preserved across the migration.
      -- Anything `init` declares is visible to the condition, step and body.
      let decls' := ((init.map declsOwn).getD {}).extend decls
      let (oInit, aInit) := (init.map (scopedWalkGoS leaf lcs scope decls)).getD ([], {})
      let (oStep, aStep) := (step.map (scopedWalkGoS leaf lcs scope decls')).getD ([], {})
      let (oBody, aBody) := scopedWalkGoB leaf lcs (scope.pushAll (loopHypsAt lcs sp.line)) decls' b
      (oInit ++ leaf (Thunk.mk fun _ => scope.toList) decls' s ++ oStep ++ oBody,
       unionAssigned (unionAssigned aInit aStep) aBody)
  | s@(.borrowIn _ _ _ _ _ b) =>
      (leaf (Thunk.mk fun _ => scope.toList) decls s ++ (scopedWalkGoB leaf lcs scope decls b).1, {})
  | s@(.assign _ n _) =>
      (leaf (Thunk.mk fun _ => scope.toList) decls s, ({} : Std.HashSet String).insert n)
  | s@(.letDecl _ n _ _ _ _) =>
      (leaf (Thunk.mk fun _ => scope.toList) decls s, ({} : Std.HashSet String).insert n)
  | s => (leaf (Thunk.mk fun _ => scope.toList) decls s, {})
/-- The walk of a block: its obligations in order, and the scalars its statements assign. -/
partial def scopedWalkGoB {α}
    (leaf : Thunk (List Expr) → ScopeDecls → Stmt → List α)
    (lcs : List LoopContract) (scope : ScopeHyps) (decls : ScopeDecls) :
    List Stmt → List α × Std.HashSet String
  | [] => ([], {})
  | s :: rest =>
      let (oHere, aHere) := scopedWalkGoS leaf lcs scope decls s
      let restScope := match s with
        -- An empty scope has nothing to invalidate (bug 178). The catch-all arm is the
        -- fact-invalidation mutation's anchor.
        | .ifElse _ c t none => if blockTerminates t then scope.pushAll (negateGuard c).toList
                                else if scope.rev.isEmpty then {} else scope.drop aHere
        | _ => scope.drop aHere
      -- A declaration is visible to what FOLLOWS it, and shadows an outer binding of the
      -- same name because it is prepended and lookups take the first match. Bindings made
      -- inside `s` (a block) do not reach `rest`: only `s`'s own declaration does.
      let restDecls := (declsOwn s).extend decls
      let (oRest, aRest) := scopedWalkGoB leaf lcs restScope restDecls rest
      (oHere ++ oRest, unionAssigned aHere aRest)
end

/-- The ONE scoped walk of a statement: the obligations `leaf` finds in it, each with the
    hypotheses in scope at its statement. They reach the leaf as a `Thunk`, forced only by a leaf
    that emits an obligation, so a statement with none costs nothing however deep its scope
    (bug 293). -/
def scopedWalkSizedS {α}
    (leaf : Thunk (List Expr) → ScopeDecls → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) (decls : ScopeDecls) (st : Stmt) : List α :=
  (scopedWalkGoS leaf lcs (ScopeHyps.ofList scope) decls st).1

/-- See `scopedWalkSizedS`. -/
def scopedWalkSizedB {α}
    (leaf : Thunk (List Expr) → ScopeDecls → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) (decls : ScopeDecls) (body : List Stmt) :
    List α :=
  (scopedWalkGoB leaf lcs (ScopeHyps.ofList scope) decls body).1

/-- Declaration-agnostic walk, for the families that resolve nothing by name. Identical
    traversal, so positional keys are shared. -/
def scopedWalkS {α} (leaf : Thunk (List Expr) → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) (st : Stmt) : List α :=
  scopedWalkSizedS (fun sc _ s => leaf sc s) lcs scope {} st

/-- See `scopedWalkS`. -/
def scopedWalkB {α} (leaf : Thunk (List Expr) → Stmt → List α)
    (lcs : List LoopContract) (scope : List Expr) (body : List Stmt) : List α :=
  scopedWalkSizedB (fun sc _ s => leaf sc s) lcs scope {} body

/-- The array an access refers to: a display name and its fixed length.

    Two routes, and both are needed:

    * the scoped size map, keyed by the root NAME — this is the only route that knows a length
      inferred from an array-literal initialiser (`let a = [0; 16]`, no annotation);
    * `placeTy`, which follows field paths — the only route that can answer `b.data[i]`, which
      previously produced no obligation at all because discovery required a bare `.ident`.

    The name is display-only (`BoundsObl.arrName` is interpolated into messages, never
    resolved), so a field path can carry `b.data` without anything downstream needing to
    parse it. -/
def arrayAccessOf (structs : StructFieldEnv) (decls : ScopeDecls) (a : Expr) :
    Option (String × Nat) :=
  match arrayRootName a with
  | some nm =>
      match decls.sizes.find? (·.1 == nm) with
      | some (_, sz) => some (nm, sz)
      | none => match placeTy structs decls.tys a with
        | some (.array _ n) => some (nm, n)
        | _ => none
  | none =>
      match placeTy structs decls.tys a with
      | some (.array _ n) => some (Concrete.fmtExpr a, n)
      | _ => none

/-- Array-index leaf: the index uses in a statement's OWN expression positions
    (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's index uses).
    A store `a[idx] = v` carries its target bound `(a, idx)` FIRST, matching the
    old walker's ordering exactly. -/
def boundsLeaf (structs : StructFieldEnv) (scope : Thunk (List Expr)) (decls : ScopeDecls) :
    Stmt → List (String × Expr × List Expr × Option Nat) :=
  let mk : (Expr × Expr) → (String × Expr × List Expr × Option Nat) :=
    fun (a, i) => match arrayAccessOf structs decls a with
      | some (nm, sz) => (nm, i, scope.get, some sz)
      | none => (Concrete.fmtExpr a, i, scope.get, none)
  fun
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectIndexUsesE v).map mk
  | .return_ _ (some v) => (collectIndexUsesE v).map mk
  | .ifElse _ c _ _ => (collectIndexUsesE c).map mk
  | .while_ _ c _ _ => (collectIndexUsesE c).map mk
  | .forLoop _ _ c _ _ _ => (collectIndexUsesE c).map mk
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectIndexUsesE o ++ collectIndexUsesE v).map mk
  | .arrayIndexAssign _ a idx v =>
      mk (a, idx) :: (collectIndexUsesE a ++ collectIndexUsesE idx ++ collectIndexUsesE v).map mk
  -- as in the other three leaves: the condition of an `assert_`/`assume_` was never examined.
  | .assert_ _ c | .assume_ _ c => (collectIndexUsesE c).map mk
  | _ => []

/-- Index uses paired with the hypotheses in scope at the access (Phase 3 #5 —
    migrated onto the unified `scopedWalk`). Like the call-site migration, the
    collector now threads enclosing `if`-guards (then assumes `c`, else assumes
    `¬c`), early-return fall-through, and loop invariants/guards — strictly more
    sound context than the old bounds walker, so a bounds obligation can only move
    `unproven → proved_by_kernel_decision` (e.g. `if 0 ≤ i && i < n { a[i] }`),
    never the reverse, and a reassigned index still drops its stale guard. -/
def scopedBoundsB (structs : StructFieldEnv) (lcs : List LoopContract) (scope : List Expr)
    (decls : ScopeDecls) (body : List Stmt) :
    List (String × Expr × List Expr × Option Nat) :=
  scopedWalkSizedB (boundsLeaf structs) lcs scope decls body

/-- Call-site leaf: the calls in a statement's OWN expression positions (the
    walker owns recursion into branches, loop bodies, and for-loop init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's calls). -/
def callLeaf (scope : Thunk (List Expr)) : Stmt → List (String × List Expr × List Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectCallsE v).map fun (_, fn, args) => (fn, args, scope.get)
  | .return_ _ (some v) => (collectCallsE v).map fun (_, fn, args) => (fn, args, scope.get)
  | .ifElse _ c _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope.get)
  | .while_ _ c _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope.get)
  | .forLoop _ _ c _ _ _ => (collectCallsE c).map fun (_, fn, args) => (fn, args, scope.get)
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectCallsE o ++ collectCallsE v).map fun (_, fn, args) => (fn, args, scope.get)
  | .arrayIndexAssign _ a i v =>
      (collectCallsE a ++ collectCallsE i ++ collectCallsE v).map fun (_, fn, args) => (fn, args, scope.get)
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
def assertLeaf (scope : Thunk (List Expr)) : Stmt → List (Bool × Expr × List Expr)
  | .assert_ _ c => [(false, c, scope.get)]
  | .assume_ _ c => [(true, c, scope.get)]
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
-- spec: CON-2 (docs/spec/contracts.md; this declaration enforces the rule)
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
  -- Loop VCs these hypotheses owe (R-0461). Non-empty means the obligation was discharged
  -- under an invariant whose own O1/O2 must hold; the ledger caps the status accordingly.
  hypDebt       : List String := []

/-- Array accesses that reach NO bounds obligation, named so coverage cannot be over-read.

    `N VCs, all proved` must not be readable as `every array access is checked`. This is the
    same discipline `--report core-semantics-diff` applies to functions outside the extractable
    fragment, applied to the layer that was quietly exempt from it.

    Two causes reach here, both real gaps rather than errors:

    * **no statically known size** — nothing in scope at the access fixes a length for that
      name (e.g. an array returned from a call, or a `let` with a non-literal initialiser).

    Shadowing is no longer a cause: sizes are resolved per SCOPE, so a redeclared array is
    sized from the binding actually in effect. That replaced a conservative refusal, which had
    in turn replaced a wrong answer.

    A third cause does not reach here and is listed in `DiscoveryComplete.lean`: an array
    reached through a field (`b.data[i]`) is never RECORDED, so there is no name to report.
    Closing that needs type resolution for arbitrary array expressions. -/
def unresolvedBoundsAccesses (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    for (arr, _, _, msize) in scopedBoundsB (structFieldEnv modules) f.loopContracts [] (paramDecls f) f.body do
      if msize.isNone then
        out := out ++ [(fq, arr)]
  return out.eraseDups

/-- Generate array-bounds obligations for every indexed access into a known
    fixed-size array. -/
def boundsObligations (modules : List Module) : List BoundsObl := Id.run do
  let mut out : List BoundsObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (arr, idx, scope, msize) in scopedBoundsB (structFieldEnv modules) f.loopContracts [] (paramDecls f) f.body do
      match msize with
      | none => pure ()   -- named by `unresolvedBoundsAccesses`, which walks identically
      | some n =>
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
                        , closedVerdict := cv.1, leanGoal := cv.2, hyps := obHyps
                        , hypDebt := loopInvariantDebt f fq obHyps }]
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
def collectDivisorsE : Expr → List (Bool × Expr × Expr)
  -- R-0464: the DIVIDEND travels with the divisor now. `divisor ≠ 0` needs only `r`, which
  -- is why `l` was dropped — and dropping it is what made the signed `MIN / -1` quotient
  -- overflow inexpressible at this layer rather than merely unstated.
  | .binOp _ .div l r => (false, l, r) :: (collectDivisorsE l ++ collectDivisorsE r)
  | .binOp _ .mod l r => (true, l, r) :: (collectDivisorsE l ++ collectDivisorsE r)
  | .binOp _ _ l r => collectDivisorsE l ++ collectDivisorsE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .cast _ x _ | .fieldAccess _ x _ => collectDivisorsE x
  | .arrayLit _ es => es.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsE e)
  | .arrayIndex _ a i => collectDivisorsE a ++ collectDivisorsE i
  | .call _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsE e)
  | .methodCall _ o _ _ args => collectDivisorsE o ++ args.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsE e)
  | .staticMethodCall _ _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsE e)
  | .structLit _ _ _ fs base => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectDivisorsE fe) ++ (base.attach.map (fun ⟨e, _⟩ => collectDivisorsE e)).getD []
  | .enumLit _ _ _ _ fs => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectDivisorsE fe)
  | .allocCall _ x a => collectDivisorsE x ++ collectDivisorsE a
  | .ifExpr _ c t el =>
      collectDivisorsE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e) ++ el.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e)
  | .match_ _ s _ => collectDivisorsE s
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
def collectDivisorsS : Stmt → List (Bool × Expr × Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectDivisorsE v
  | .return_ _ (some v) => collectDivisorsE v
  | .ifElse _ c t el => collectDivisorsE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e) ++ (el.getD []).attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e)
  | .while_ _ c b _ => collectDivisorsE c ++ b.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e)
  | .forLoop _ init c step b _ =>
      (init.attach.map (fun ⟨e, _⟩ => collectDivisorsS e)).getD [] ++ collectDivisorsE c
        ++ (step.attach.map (fun ⟨e, _⟩ => collectDivisorsS e)).getD [] ++ b.attach.flatMap (fun ⟨e, _⟩ => collectDivisorsS e)
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectDivisorsE o ++ collectDivisorsE v
  | .arrayIndexAssign _ a i v => collectDivisorsE a ++ collectDivisorsE i ++ collectDivisorsE v
  -- These five were MISSING from all four statement walkers until 2026-08-06. An obligation
  -- inside `assert(a / b > 0)` was lost entirely -- verified: zero div-by-zero obligations for
  -- exactly that program. `assert_`/`assume_` carry a condition, `borrowIn` a body, and both
  -- destructuring forms a scrutinee, so each is a place obligations can hide.
  | .assert_ _ c | .assume_ _ c => collectDivisorsE c
  | .borrowIn _ _ _ _ _ b => b.attach.flatMap (fun ⟨x, _⟩ => collectDivisorsS x)
  | .letDestructure _ _ _ _ v _ => collectDivisorsE v
  | .letStructDestructure _ _ _ v => collectDivisorsE v
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
end

/-- Inclusive value range of a *fixed-width* integer type (none = arbitrary/
    `Int`). The range values come from the arithmetic reference
    (`IntArith.intRange`); this deliberately keeps `Int`/`Uint` as `none` (an
    audit choice — their overflow is profile-dependent, per the note above), so
    it is not a blind alias of `IntArith.intRange`, which does give them ranges. -/
def intRange : Ty → Option (Int × Int)
  | .int | .uint => none
  | ty => IntArith.intRange ty

/-- Best-effort fixed-width int type of an expression, from a var→type map. -/
def exprIntTy (vt : List (String × Ty)) : Expr → Option Ty
  | .ident _ n => vt.lookup n
  | .paren _ e => exprIntTy vt e
  | .unaryOp _ _ e => exprIntTy vt e
  | .cast _ _ t => some t
  | .binOp _ _ l r => match exprIntTy vt l with | some t => some t | none => exprIntTy vt r
  | _ => none

/-- Divisor leaf: the `/`/`%` divisors in a statement's OWN expression positions
    (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's divisors).
    Each item is `(isMod, divisorExpr, scope)`. -/
def divLeaf (scope : Thunk (List Expr)) (decls : ScopeDecls) :
    Stmt → List (Bool × Expr × Expr × List Expr × Option Ty) :=
  let mk : (Bool × Expr × Expr) → (Bool × Expr × Expr × List Expr × Option Ty) :=
    fun (m, n, e) => (m, n, e, scope.get, exprIntTy decls.tys n)
  fun
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectDivisorsE v).map mk
  | .return_ _ (some v) => (collectDivisorsE v).map mk
  | .ifElse _ c _ _ => (collectDivisorsE c).map mk
  | .while_ _ c _ _ => (collectDivisorsE c).map mk
  | .forLoop _ _ c _ _ _ => (collectDivisorsE c).map mk
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectDivisorsE o ++ collectDivisorsE v).map mk
  | .arrayIndexAssign _ a i v =>
      (collectDivisorsE a ++ collectDivisorsE i ++ collectDivisorsE v).map mk
  -- `assert_`/`assume_` carry a CONDITION, and no leaf examined it until 2026-08-06: a division
  -- in `assert(a / b > 0)` produced no obligation at all. The statement traversal calls these
  -- leaves, so a gap here loses the obligation even when the `…S` walker handles the case.
  | .assert_ _ c | .assume_ _ c => (collectDivisorsE c).map mk
  | _ => []

/-- Divisor uses paired with the hypotheses in scope at the `/`/`%` (Phase 3 #6 —
    migrated onto the unified `scopedWalk`). The collector threads enclosing
    guards / negated guards / fall-through / loop invariants, so a `divisor ≠ 0`
    obligation can only move `unproven → proved` (e.g. `if d != 0 { n / d }`),
    never the reverse. The SOUND division/modulo lowering is unchanged: it still
    flows through `divSound`/`toLeanPropSound`, which lower `/`/`%` to Lean
    E-division ONLY when the dividend is provably non-negative — keeping Concrete's
    truncating semantics from being confused with Lean's floor division. -/
def scopedDivB (lcs : List LoopContract) (scope : List Expr) (decls : ScopeDecls)
    (body : List Stmt) : List (Bool × Expr × Expr × List Expr × Option Ty) :=
  scopedWalkSizedB divLeaf lcs scope decls body

mutual
/-- Every `+`/`-`/`*` binop node in an expression (the whole `a op b`). -/
def collectArithE : Expr → List Expr
  | e@(.binOp _ op l r) =>
    let here := match op with | .add | .sub | .mul => [e] | _ => []
    here ++ collectArithE l ++ collectArithE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .cast _ x _ | .fieldAccess _ x _ => collectArithE x
  | .arrayLit _ es => es.attach.flatMap (fun ⟨e, _⟩ => collectArithE e)
  | .arrayIndex _ a i => collectArithE a ++ collectArithE i
  | .call _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectArithE e)
  | .methodCall _ o _ _ args => collectArithE o ++ args.attach.flatMap (fun ⟨e, _⟩ => collectArithE e)
  | .staticMethodCall _ _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectArithE e)
  | .structLit _ _ _ fs base => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectArithE fe) ++ (base.attach.map (fun ⟨e, _⟩ => collectArithE e)).getD []
  | .enumLit _ _ _ _ fs => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectArithE fe)
  | .allocCall _ x a => collectArithE x ++ collectArithE a
  | .ifExpr _ c t el =>
      collectArithE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectArithS e) ++ el.attach.flatMap (fun ⟨e, _⟩ => collectArithS e)
  | .match_ _ s _ => collectArithE s
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
def collectArithS : Stmt → List Expr
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectArithE v
  | .return_ _ (some v) => collectArithE v
  | .ifElse _ c t el => collectArithE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectArithS e) ++ (el.getD []).attach.flatMap (fun ⟨e, _⟩ => collectArithS e)
  | .while_ _ c b _ => collectArithE c ++ b.attach.flatMap (fun ⟨e, _⟩ => collectArithS e)
  | .forLoop _ init c step b _ =>
      (init.attach.map (fun ⟨e, _⟩ => collectArithS e)).getD [] ++ collectArithE c
        ++ (step.attach.map (fun ⟨e, _⟩ => collectArithS e)).getD [] ++ b.attach.flatMap (fun ⟨e, _⟩ => collectArithS e)
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectArithE o ++ collectArithE v
  | .arrayIndexAssign _ a i v => collectArithE a ++ collectArithE i ++ collectArithE v
  -- These five were MISSING from all four statement walkers until 2026-08-06. An obligation
  -- inside `assert(a / b > 0)` was lost entirely -- verified: zero div-by-zero obligations for
  -- exactly that program. `assert_`/`assume_` carry a condition, `borrowIn` a body, and both
  -- destructuring forms a scrutinee, so each is a place obligations can hide.
  | .assert_ _ c | .assume_ _ c => collectArithE c
  | .borrowIn _ _ _ _ _ b => b.attach.flatMap (fun ⟨x, _⟩ => collectArithS x)
  | .letDestructure _ _ _ _ v _ => collectArithE v
  | .letStructDestructure _ _ _ v => collectArithE v
  | _ => []
termination_by x => sizeOf x
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
end

/-- Arithmetic-op leaf: the `+`/`-`/`*` op nodes in a statement's OWN expression
    positions (the walker owns recursion into branches/loops/init/step, so
    `.ifElse`/`.while_`/`.forLoop` contribute only their condition's op nodes). -/
def arithLeaf (scope : Thunk (List Expr)) (decls : ScopeDecls) :
    Stmt → List (Expr × List Expr × Option Ty) :=
  let mk : Expr → (Expr × List Expr × Option Ty) :=
    fun e => (e, scope.get, exprIntTy decls.tys e)
  fun
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectArithE v).map mk
  | .return_ _ (some v) => (collectArithE v).map mk
  | .ifElse _ c _ _ => (collectArithE c).map mk
  | .while_ _ c _ _ => (collectArithE c).map mk
  | .forLoop _ _ c _ _ _ => (collectArithE c).map mk
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectArithE o ++ collectArithE v).map mk
  | .arrayIndexAssign _ a i v =>
      (collectArithE a ++ collectArithE i ++ collectArithE v).map mk
  -- `assert_`/`assume_` carry a CONDITION, and no leaf examined it until 2026-08-06: a division
  -- in `assert(a / b > 0)` produced no obligation at all. The statement traversal calls these
  -- leaves, so a gap here loses the obligation even when the `…S` walker handles the case.
  | .assert_ _ c | .assume_ _ c => (collectArithE c).map mk
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
def scopedArithB (lcs : List LoopContract) (scope : List Expr) (decls : ScopeDecls)
    (body : List Stmt) : List (Expr × List Expr × Option Ty) :=
  scopedWalkSizedB arithLeaf lcs scope decls body

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
  -- Loop VCs these hypotheses owe (R-0461). Non-empty means the obligation was discharged
  -- under an invariant whose own O1/O2 must hold; the ledger caps the status accordingly.
  hypDebt       : List String := []

/-- One division-by-zero obligation. -/
structure DivObl where
  fnQual        : String
  key           : String
  divExpr       : Expr              -- the DIVISOR (meaning unchanged; 6 consumers rely on it)
  numExpr       : Expr              -- the DIVIDEND (R-0464: needed to state MIN / -1)
  isMod         : Bool
  closedVerdict : Option Bool
  leanGoal      : Option String
  -- R-0464 / H24: the `quotientInRange` half of what `IntArith.trapConditions` says `/` and
  -- `%` owe. `leanGoal` above is the `divisorNonZero` half, and shipping only that half is
  -- why `examples/trap_semantics_gap/` reported `proved_by_kernel_decision` for a division
  -- that aborts. `none` when the operand type is not a known-width integer, in which case
  -- there is no MIN to state and the condition is vacuous.
  quotGoal      : Option String := none
  -- The signed minimum this obligation excludes, for the report. `none` for unsigned and
  -- unknown-width types, which cannot hit the quotient overflow at all.
  quotMin       : Option Int := none
  hyps          : List Expr := []   -- in-scope #[requires]/guards (for prover-neutral lowering)
  -- Loop VCs these hypotheses owe (R-0461). Non-empty means the obligation was discharged
  -- under an invariant whose own O1/O2 must hold; the ledger caps the status accordingly.
  hypDebt       : List String := []

/-- Generate `divisor ≠ 0` obligations for every `/` and `%`. -/
def divObligations (modules : List Module) : List DivObl := Id.run do
  let mut out : List DivObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (isMod, nv, dv, scope, nvTy) in scopedDivB f.loopContracts [] (paramDecls f) f.body do
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
      -- R-0464: the SECOND condition `IntArith.trapConditions` lists for `/` and `%`.
      -- Signed only, and type-relative: the bound is THIS type's minimum, which is exactly
      -- what a hand-written rule gets wrong at one width or another.
      let quot : Option String × Option Int :=
        match nvTy.bind intRange with
        | some (lo, _) =>
          if !(IntArith.isSignedInt (nvTy.getD .i32)) then (none, none)
          else match toLeanProp nv, toLeanProp dv with
            | some nStr, some dStr =>
              let vars := (collectIdents nv ++ collectIdents dv
                           ++ obHyps.flatMap collectIdents).eraseDups
              let reqs := obHyps.filterMap toLeanProp
              let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
              let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
              (some s!"{binder}{hyp}(¬({nStr} = {lo} ∧ {dStr} = -1))", some lo)
            | _, _ => (none, some lo)
        | none => (none, none)
      out := out ++ [{ fnQual := fq, key, divExpr := dv, numExpr := nv, isMod
                     , closedVerdict := cv.1
                     , leanGoal := cv.2, hyps := obHyps
                     , quotGoal := quot.1, quotMin := quot.2
                     , hypDebt := loopInvariantDebt f fq obHyps }]
      i := i + 1
  return out

/-! ### Shift-amount obligations (R-0464 / H24)

The third condition `IntArith.trapConditions` lists, and the one no family generated. This
was not a weak rule but an ABSENT one: `collectArithE` matches `.add | .sub | .mul`, so `<<`
and `>>` were collected by nothing, `--report vcs` was empty for them, and
`examples/trap_semantics_gap/`'s `1 << 40` aborted with no obligation having been stated.

Worth recording why the gate suite could not see it: `check_vc_bridge_register.sh` asserts
every family GENERATOR has a register row. A missing family has no generator, so there is
nothing for it to notice — the same blind spot mutation coverage has, one level up. What
closes it is the totality lock against `allTrapConditions`, which fails when a condition in
`IntArith` is claimed by no family. -/

mutual
def collectShiftsE : Expr → List (Expr × Expr)
  | .binOp _ .shl l r => (l, r) :: (collectShiftsE l ++ collectShiftsE r)
  | .binOp _ .shr l r => (l, r) :: (collectShiftsE l ++ collectShiftsE r)
  | .binOp _ _ l r => collectShiftsE l ++ collectShiftsE r
  | .unaryOp _ _ x | .paren _ x | .borrow _ x | .borrowMut _ x | .deref _ x
  | .cast _ x _ | .fieldAccess _ x _ => collectShiftsE x
  | .arrayLit _ es => es.attach.flatMap (fun ⟨e, _⟩ => collectShiftsE e)
  | .arrayIndex _ a i => collectShiftsE a ++ collectShiftsE i
  | .call _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectShiftsE e)
  | .methodCall _ o _ _ args =>
      collectShiftsE o ++ args.attach.flatMap (fun ⟨e, _⟩ => collectShiftsE e)
  | .staticMethodCall _ _ _ _ args => args.attach.flatMap (fun ⟨e, _⟩ => collectShiftsE e)
  | .structLit _ _ _ fs base =>
      fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectShiftsE fe)
        ++ (base.attach.map (fun ⟨e, _⟩ => collectShiftsE e)).getD []
  | .enumLit _ _ _ _ fs => fs.attach.flatMap (fun ⟨(_, fe), _⟩ => collectShiftsE fe)
  | .allocCall _ x a => collectShiftsE x ++ collectShiftsE a
  -- `.ifExpr` was MISSING until 2026-08-06: a shift inside an if-EXPRESSION produced no
  -- shift-amount obligation at all. Found by per-walker constructor coverage, not by a test --
  -- all three sibling walkers had this case, which is why a file-granular check could not see it.
  | .ifExpr _ c t el =>
      collectShiftsE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e)
        ++ el.attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e)
  | .match_ _ sc _ => collectShiftsE sc
  | _ => []
termination_by e => sizeOf e
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
def collectShiftsS : Stmt → List (Expr × Expr)
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v => collectShiftsE v
  | .return_ _ (some v) => collectShiftsE v
  | .ifElse _ c t el => collectShiftsE c ++ t.attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e) ++ (el.getD []).attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e)
  | .while_ _ c b _ => collectShiftsE c ++ b.attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e)
  | .forLoop _ init c step b _ =>
      (init.attach.map (fun ⟨e, _⟩ => collectShiftsS e)).getD [] ++ collectShiftsE c
        ++ (step.attach.map (fun ⟨e, _⟩ => collectShiftsS e)).getD [] ++ b.attach.flatMap (fun ⟨e, _⟩ => collectShiftsS e)
  | .fieldAssign _ o _ v | .derefAssign _ o v => collectShiftsE o ++ collectShiftsE v
  | .arrayIndexAssign _ a i v => collectShiftsE a ++ collectShiftsE i ++ collectShiftsE v
  -- These five were MISSING from all four statement walkers until 2026-08-06. An obligation
  -- inside `assert(a / b > 0)` was lost entirely -- verified: zero div-by-zero obligations for
  -- exactly that program. `assert_`/`assume_` carry a condition, `borrowIn` a body, and both
  -- destructuring forms a scrutinee, so each is a place obligations can hide.
  | .assert_ _ c | .assume_ _ c => collectShiftsE c
  | .borrowIn _ _ _ _ _ b => b.attach.flatMap (fun ⟨x, _⟩ => collectShiftsS x)
  | .letDestructure _ _ _ _ v _ => collectShiftsE v
  | .letStructDestructure _ _ _ v => collectShiftsE v
  | _ => []
termination_by e => sizeOf e
decreasing_by
  all_goals simp_wf
  all_goals
    first
      | omega
      | (rename_i h; have := List.sizeOf_lt_of_mem h; simp +arith at this ⊢; omega)
      | (rename_i h; have := sizeOf_mem_getD h; simp +arith at this ⊢; omega)
      | (rename_i h; subst h; simp +arith; omega)
      | (rename_i h; subst h; simp +arith)
end

def shiftLeaf (scope : Thunk (List Expr)) (decls : ScopeDecls) :
    Stmt → List (Expr × Expr × List Expr × Option Ty) :=
  let mk : (Expr × Expr) → (Expr × Expr × List Expr × Option Ty) :=
    fun (l, r) => (l, r, scope.get, exprIntTy decls.tys l)
  fun
  | .letDecl _ _ _ _ v _ | .assign _ _ v | .expr _ v _ | .defer _ v =>
      (collectShiftsE v).map mk
  | .return_ _ (some v) => (collectShiftsE v).map mk
  | .ifElse _ c _ _ => (collectShiftsE c).map mk
  | .while_ _ c _ _ => (collectShiftsE c).map mk
  | .forLoop _ _ c _ _ _ => (collectShiftsE c).map mk
  | .fieldAssign _ o _ v | .derefAssign _ o v =>
      (collectShiftsE o ++ collectShiftsE v).map mk
  | .arrayIndexAssign _ a i v =>
      (collectShiftsE a ++ collectShiftsE i ++ collectShiftsE v).map mk
  -- `assert_`/`assume_` carry a CONDITION, and no leaf examined it until 2026-08-06: a division
  -- in `assert(a / b > 0)` produced no obligation at all. The statement traversal calls these
  -- leaves, so a gap here loses the obligation even when the `…S` walker handles the case.
  | .assert_ _ c | .assume_ _ c => (collectShiftsE c).map mk
  | _ => []

/-- One shift-amount obligation: `0 ≤ amount < bitWidth(ty)`. -/
structure ShiftObl where
  fnQual        : String
  key           : String
  shiftedExpr   : Expr
  amountExpr    : Expr
  width         : Nat
  closedVerdict : Option Bool
  leanGoal      : Option String
  hyps          : List Expr := []
  hypDebt       : List String := []

/-- Generate `0 ≤ amount < width` obligations for every `<<` and `>>`.

    The width comes from the SHIFTED operand's type, matching
    `IntArith.shiftAmountInRange`, which takes the value's type — not the amount's. Getting
    that backwards would state a condition about the wrong width and pass. -/
def shiftObligations (modules : List Module) : List ShiftObl := Id.run do
  let mut out : List ShiftObl := []
  for (pfx, f) in modules.flatMap allFunctions do
    let fq := pfx ++ f.name
    let mut i := 0
    for (sv, amt, scope, svTy) in
        scopedWalkSizedB shiftLeaf f.loopContracts [] (paramDecls f) f.body do
      match svTy.bind IntArith.intBitWidth with
      | some (w, _) =>
        let key := s!"{fq}#shift{i}"
        let obHyps := f.requires ++ scope
        let cv : Option Bool × Option String := match cEvalInt amt with
          | some k => (some (decide (0 ≤ k ∧ k < Int.ofNat w)), none)
          | none => match toLeanProp amt with
            | none => (none, none)
            | some aStr =>
              let vars := (collectIdents amt ++ obHyps.flatMap collectIdents).eraseDups
              let reqs := obHyps.filterMap toLeanProp
              let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
              let hyp := if reqs.isEmpty then "" else s!"({" ∧ ".intercalate reqs}) → "
              (none, some s!"{binder}{hyp}(0 ≤ {aStr} ∧ {aStr} < {w})")
        out := out ++ [{ fnQual := fq, key, shiftedExpr := sv, amountExpr := amt, width := w
                       , closedVerdict := cv.1, leanGoal := cv.2, hyps := obHyps
                       , hypDebt := loopInvariantDebt f fq obHyps }]
        i := i + 1
      | none => pure ()
  return out

/-- Lean goals for the non-constant shift-amount obligations, for omega discharge. -/
def shiftGoals (modules : List Module) : List (String × String) :=
  (shiftObligations modules).filterMap fun o => o.leanGoal.map (fun g => (o.key, g))

/-- Lean goals for the non-constant divisor obligations, for omega discharge. -/
def divGoals (modules : List Module) : List (String × String) :=
  (divObligations modules).filterMap fun o => o.leanGoal.map (fun g => (o.key, g))

/-- **R-0464: the quotient-overflow goals, keyed separately from `divGoals`.**

    A distinct key (`…#divq{n}` rather than `…#div{n}`) because it is a distinct obligation:
    a division can discharge `divisor ≠ 0` and fail `quotientInRange`, which is exactly the
    case `examples/trap_semantics_gap/` reproduces. Sharing one key would let the stronger
    condition's failure be masked by the weaker one's success — the same collapsing of two
    facts into one status that H23 was. -/
def divQuotGoals (modules : List Module) : List (String × String) :=
  (divObligations modules).filterMap fun o => o.quotGoal.map (fun g => (o.key ++ "q", g))

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
def conjuncts : Expr → List Expr
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
def exprIntervalMax (bounds : List (String × (Int × Int))) : Expr → Option (Int × Int × Nat)
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
def arithToBVW (w : Nat) : Expr → Option String
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
    let mut i := 0
    for (e, scope, eTy) in scopedArithB f.loopContracts [] (paramDecls f) f.body do
      match eTy.bind intRange, toLeanProp e with
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
                       , closedVerdict := cv.1, leanGoal := cv.2, bvGoal, hyps
                       , hypDebt := loopInvariantDebt f fq hyps }]
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


end Report
end Concrete
