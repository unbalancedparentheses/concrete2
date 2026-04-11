import Concrete.Core
import Concrete.Pipeline
import Concrete.Proof
import Concrete.Intrinsic

namespace Concrete

/-! ## ProofCore — the proof-oriented compiler pass

ProofCore is an explicit pipeline phase that runs after Core elaboration
and CoreCheck.  It produces a single artifact that every downstream
proof consumer reads from:

  1. Eligibility assessment (source + profile gates)
  2. Core→PExpr extraction (for functions that pass eligibility)
  3. Body fingerprinting (for proof identity)
  4. Call-graph / recursion / loop analysis (computed once, shared)

No downstream code should touch `CModule` directly for proof-related
questions.  ProofCore is the artifact boundary between Core and the
proof pipeline.

ProofCore does NOT define its own semantics.  It is a filter and
extractor, not a rival IR.  The semantic authority remains CoreCheck;
ProofCore identifies the subset of validated Core that the Lean proof
infrastructure can reason about today.
-/

-- ============================================================
-- Shared analysis helpers (used by eligibility + reports)
-- ============================================================

-- Call collection

mutual
partial def collectCallsExpr (e : CExpr) : List String :=
  match e with
  | .call fn _ args _ => [fn] ++ args.foldl (fun acc a => acc ++ collectCallsExpr a) []
  | .binOp _ l r _ => collectCallsExpr l ++ collectCallsExpr r
  | .unaryOp _ e _ => collectCallsExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectCallsExpr v) []
  | .fieldAccess obj _ _ => collectCallsExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectCallsExpr v) []
  | .match_ scrut arms _ => collectCallsExpr scrut ++ arms.foldl (fun acc a => acc ++ collectCallsArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectCallsExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectCallsExpr e) []
  | .arrayIndex arr idx _ => collectCallsExpr arr ++ collectCallsExpr idx
  | .cast inner _ | .try_ inner _ => collectCallsExpr inner
  | .allocCall inner alloc _ => collectCallsExpr inner ++ collectCallsExpr alloc
  | .whileExpr cond body elseBody _ =>
    collectCallsExpr cond ++ collectCallsStmts body ++ collectCallsStmts elseBody
  | .ifExpr cond th el _ =>
    collectCallsExpr cond ++ collectCallsStmts th ++ collectCallsStmts el
  | _ => []

partial def collectCallsArm (arm : CMatchArm) : List String :=
  match arm with
  | .enumArm _ _ _ body => collectCallsStmts body
  | .litArm v body => collectCallsExpr v ++ collectCallsStmts body
  | .varArm _ _ body => collectCallsStmts body

partial def collectCallsStmt (s : CStmt) : List String :=
  match s with
  | .letDecl _ _ _ v => collectCallsExpr v
  | .assign _ v => collectCallsExpr v
  | .return_ (some v) _ => collectCallsExpr v
  | .return_ none _ => []
  | .expr e => collectCallsExpr e
  | .ifElse c t el =>
    collectCallsExpr c ++ collectCallsStmts t ++
    match el with | some stmts => collectCallsStmts stmts | none => []
  | .while_ c body _ step =>
    collectCallsExpr c ++ collectCallsStmts body ++ collectCallsStmts step
  | .fieldAssign obj _ v => collectCallsExpr obj ++ collectCallsExpr v
  | .derefAssign t v => collectCallsExpr t ++ collectCallsExpr v
  | .arrayIndexAssign arr idx v =>
    collectCallsExpr arr ++ collectCallsExpr idx ++ collectCallsExpr v
  | .break_ (some v) _ => collectCallsExpr v
  | .break_ none _ | .continue_ _ => []
  | .defer body => collectCallsExpr body
  | .borrowIn _ _ _ _ _ body => collectCallsStmts body

partial def collectCallsStmts (ss : List CStmt) : List String :=
  ss.foldl (fun acc s => acc ++ collectCallsStmt s) []
end

-- Defer collection

mutual
partial def collectDefersExpr (e : CExpr) : List String :=
  match e with
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ collectDefersExpr a) []
  | .binOp _ l r _ => collectDefersExpr l ++ collectDefersExpr r
  | .unaryOp _ e _ => collectDefersExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectDefersExpr v) []
  | .fieldAccess obj _ _ => collectDefersExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectDefersExpr v) []
  | .match_ scrut arms _ =>
    collectDefersExpr scrut ++ arms.foldl (fun acc a => acc ++ collectDefersArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectDefersExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectDefersExpr e) []
  | .arrayIndex arr idx _ => collectDefersExpr arr ++ collectDefersExpr idx
  | .cast inner _ | .try_ inner _ => collectDefersExpr inner
  | .allocCall inner alloc _ => collectDefersExpr inner ++ collectDefersExpr alloc
  | .whileExpr cond body elseBody _ =>
    collectDefersExpr cond ++ collectDefersStmts body ++ collectDefersStmts elseBody
  | _ => []

partial def collectDefersArm (arm : CMatchArm) : List String :=
  match arm with
  | .enumArm _ _ _ body => collectDefersStmts body
  | .litArm v body => collectDefersExpr v ++ collectDefersStmts body
  | .varArm _ _ body => collectDefersStmts body

partial def collectDefersStmt (s : CStmt) : List String :=
  match s with
  | .defer body =>
    let desc := match body with
      | .call fn _ _ _ => s!"defer {fn}(...)"
      | _ => "defer <expr>"
    [desc] ++ collectDefersExpr body
  | .letDecl _ _ _ v => collectDefersExpr v
  | .assign _ v => collectDefersExpr v
  | .return_ (some v) _ => collectDefersExpr v
  | .return_ none _ => []
  | .expr e => collectDefersExpr e
  | .ifElse c t el =>
    collectDefersExpr c ++ collectDefersStmts t ++
    match el with | some stmts => collectDefersStmts stmts | none => []
  | .while_ c body _ step =>
    collectDefersExpr c ++ collectDefersStmts body ++ collectDefersStmts step
  | .fieldAssign obj _ v => collectDefersExpr obj ++ collectDefersExpr v
  | .derefAssign t v => collectDefersExpr t ++ collectDefersExpr v
  | .arrayIndexAssign arr idx v =>
    collectDefersExpr arr ++ collectDefersExpr idx ++ collectDefersExpr v
  | .break_ (some v) _ => collectDefersExpr v
  | .break_ none _ | .continue_ _ => []
  | .borrowIn _ _ _ _ _ body => collectDefersStmts body

partial def collectDefersStmts (ss : List CStmt) : List String :=
  ss.foldl (fun acc s => acc ++ collectDefersStmt s) []
end

-- Raw pointer operation detection

mutual
partial def hasRawPtrOpsExpr (e : CExpr) : Bool :=
  match e with
  | .deref inner ty =>
    match ty with
    | .ptrMut _ | .ptrConst _ => true
    | _ => hasRawPtrOpsExpr inner
  | .call _ _ args _ => args.any hasRawPtrOpsExpr
  | .binOp _ l r _ => hasRawPtrOpsExpr l || hasRawPtrOpsExpr r
  | .unaryOp _ e _ => hasRawPtrOpsExpr e
  | .structLit _ _ fields _ => fields.any (fun (_, v) => hasRawPtrOpsExpr v)
  | .fieldAccess obj _ _ => hasRawPtrOpsExpr obj
  | .enumLit _ _ _ fields _ => fields.any (fun (_, v) => hasRawPtrOpsExpr v)
  | .match_ scrut arms _ =>
    hasRawPtrOpsExpr scrut || arms.any hasRawPtrOpsArm
  | .borrow inner _ | .borrowMut inner _ => hasRawPtrOpsExpr inner
  | .arrayLit elems _ => elems.any hasRawPtrOpsExpr
  | .arrayIndex arr idx _ => hasRawPtrOpsExpr arr || hasRawPtrOpsExpr idx
  | .cast inner _ | .try_ inner _ => hasRawPtrOpsExpr inner
  | .allocCall inner alloc _ => hasRawPtrOpsExpr inner || hasRawPtrOpsExpr alloc
  | .whileExpr cond body elseBody _ =>
    hasRawPtrOpsExpr cond || hasRawPtrOpsStmts body || hasRawPtrOpsStmts elseBody
  | _ => false

partial def hasRawPtrOpsArm (arm : CMatchArm) : Bool :=
  match arm with
  | .enumArm _ _ _ body => hasRawPtrOpsStmts body
  | .litArm v body => hasRawPtrOpsExpr v || hasRawPtrOpsStmts body
  | .varArm _ _ body => hasRawPtrOpsStmts body

partial def hasRawPtrOpsStmt (s : CStmt) : Bool :=
  match s with
  | .derefAssign _ _ => true
  | .letDecl _ _ _ v => hasRawPtrOpsExpr v
  | .assign _ v => hasRawPtrOpsExpr v
  | .return_ (some v) _ => hasRawPtrOpsExpr v
  | .return_ none _ => false
  | .expr e => hasRawPtrOpsExpr e
  | .ifElse c t el =>
    hasRawPtrOpsExpr c || hasRawPtrOpsStmts t ||
    match el with | some stmts => hasRawPtrOpsStmts stmts | none => false
  | .while_ c body _ step =>
    hasRawPtrOpsExpr c || hasRawPtrOpsStmts body || hasRawPtrOpsStmts step
  | .fieldAssign obj _ v => hasRawPtrOpsExpr obj || hasRawPtrOpsExpr v
  | .arrayIndexAssign arr idx v =>
    hasRawPtrOpsExpr arr || hasRawPtrOpsExpr idx || hasRawPtrOpsExpr v
  | .break_ (some v) _ => hasRawPtrOpsExpr v
  | .break_ none _ | .continue_ _ => false
  | .defer body => hasRawPtrOpsExpr body
  | .borrowIn _ _ _ _ _ body => hasRawPtrOpsStmts body

partial def hasRawPtrOpsStmts (ss : List CStmt) : Bool :=
  ss.any hasRawPtrOpsStmt
end

-- Extern name collection

partial def collectExternNames (m : CModule) : List String :=
  m.externFns.map (fun (n, _, _, _) => n) ++
  m.submodules.foldl (fun acc sub => acc ++ collectExternNames sub) []

-- Alloc intrinsic classification

private def allocIntrinsics : List String :=
  ["alloc", "vec_new", "Vec_new"]

private def freeIntrinsics : List String :=
  ["free", "destroy", "vec_free", "Vec_free", "drop_string", "String_drop"]

def isAllocCall (name : String) : Bool :=
  allocIntrinsics.contains name ||
  match resolveIntrinsic name with
  | some .alloc | some .vecNew => true
  | _ => false

def isFreeCall (name : String) : Bool :=
  freeIntrinsics.contains name ||
  name.endsWith "_destroy" ||
  match resolveIntrinsic name with
  | some .free | some .destroy | some .vecFree | some .dropString => true
  | _ => false

def returnsAllocation : Ty → Bool
  | .heap _ | .heapArray _ => true
  | .generic "Vec" _ => true
  | _ => false

-- ============================================================
-- Call graph and recursion analysis
-- ============================================================

abbrev CallGraph := List (String × List String)

private partial def buildCallGraphModule (m : CModule) : CallGraph :=
  let fnEntries := m.functions.map fun f =>
    (f.name, collectCallsStmts f.body |>.eraseDups)
  fnEntries ++ m.submodules.foldl (fun acc sub => acc ++ buildCallGraphModule sub) []

def buildCallGraph (modules : List CModule) : CallGraph :=
  modules.foldl (fun acc m => acc ++ buildCallGraphModule m) []

-- Tarjan's SCC

private structure TarjanState where
  index    : Nat
  stack    : List String
  onStack  : List String
  indices  : List (String × Nat)
  lowlinks : List (String × Nat)
  sccs     : List (List String)

private def TarjanState.empty : TarjanState :=
  { index := 0, stack := [], onStack := [], indices := [], lowlinks := [], sccs := [] }

private def lookupNat (assoc : List (String × Nat)) (key : String) : Nat :=
  match assoc.find? (fun (k, _) => k == key) with
  | some (_, v) => v
  | none => 0

private def setNat (assoc : List (String × Nat)) (key : String) (val : Nat) : List (String × Nat) :=
  match assoc.findIdx? (fun (k, _) => k == key) with
  | some idx => assoc.set idx (key, val)
  | none => assoc ++ [(key, val)]

def tarjanSCC (graph : CallGraph) : List (List String) :=
  let allNodes := graph.foldl (fun acc (fn, callees) =>
    let acc := if acc.contains fn then acc else acc ++ [fn]
    callees.foldl (fun a c => if a.contains c then a else a ++ [c]) acc) []
  let rec processStack
    (work : List (String × List String × Nat))
    (st : TarjanState)
    (fuel : Nat) : TarjanState :=
    match fuel with
    | 0 => st
    | fuel + 1 =>
      match work with
      | [] => st
      | (v, [], _vLow) :: rest =>
        let vLow := lookupNat st.lowlinks v
        let vIdx := lookupNat st.indices v
        let st := if vLow == vIdx then
          let rec popScc (stk : List String) (scc : List String) :=
            match stk with
            | [] => (scc, [])
            | w :: stk' =>
              let scc := scc ++ [w]
              if w == v then (scc, stk')
              else popScc stk' scc
          let (scc, newStack) := popScc st.stack []
          let newOnStack := st.onStack.filter (fun n => !scc.contains n)
          { st with stack := newStack, onStack := newOnStack, sccs := st.sccs ++ [scc] }
        else st
        match rest with
        | [] => processStack [] st fuel
        | (pv, pRemain, _pLow) :: grandRest =>
          let pLow := lookupNat st.lowlinks pv
          let newPLow := if vLow < pLow then vLow else pLow
          let st := { st with lowlinks := setNat st.lowlinks pv newPLow }
          processStack ((pv, pRemain, newPLow) :: grandRest) st fuel
      | (v, w :: ws, _vLow) :: rest =>
        if (st.indices.find? (fun (k, _) => k == w)).isNone then
          let wIdx := st.index
          let st := { st with
            index := st.index + 1
            indices := st.indices ++ [(w, wIdx)]
            lowlinks := st.lowlinks ++ [(w, wIdx)]
            stack := [w] ++ st.stack
            onStack := [w] ++ st.onStack }
          let wCallees := match graph.find? (fun (n, _) => n == w) with
            | some (_, cs) => cs
            | none => []
          processStack ((w, wCallees, wIdx) :: (v, ws, lookupNat st.lowlinks v) :: rest) st fuel
        else if st.onStack.contains w then
          let vLow := lookupNat st.lowlinks v
          let wIdx := lookupNat st.indices w
          let newLow := if wIdx < vLow then wIdx else vLow
          let st := { st with lowlinks := setNat st.lowlinks v newLow }
          processStack ((v, ws, newLow) :: rest) st fuel
        else
          processStack ((v, ws, lookupNat st.lowlinks v) :: rest) st fuel
  let st := allNodes.foldl (fun st v =>
    if (st.indices.find? (fun (k, _) => k == v)).isSome then st
    else
      let vIdx := st.index
      let st := { st with
        index := st.index + 1
        indices := st.indices ++ [(v, vIdx)]
        lowlinks := st.lowlinks ++ [(v, vIdx)]
        stack := [v] ++ st.stack
        onStack := [v] ++ st.onStack }
      let vCallees := match graph.find? (fun (n, _) => n == v) with
        | some (_, cs) => cs
        | none => []
      processStack [(v, vCallees, vIdx)] st (allNodes.length * allNodes.length + allNodes.length)
  ) TarjanState.empty
  st.sccs

inductive RecursionKind where
  | none
  | direct
  | mutual
  deriving BEq

def classifyRecursion (graph : CallGraph) (sccs : List (List String))
    : List (String × RecursionKind × List String) :=
  sccs.foldl (fun acc scc =>
    match scc with
    | [single] =>
      let callees := match graph.find? (fun (n, _) => n == single) with
        | some (_, cs) => cs
        | none => []
      if callees.contains single then
        acc ++ [(single, .direct, [single])]
      else
        acc ++ [(single, .none, [])]
    | members =>
      let entries := members.map fun m => (m, RecursionKind.mutual, members)
      acc ++ entries
  ) []

-- ============================================================
-- Loop-boundedness classification
-- ============================================================

private def isBoundedCond (cond : CExpr) : Bool :=
  match cond with
  | .binOp op _ _ _ =>
    op == .lt || op == .gt || op == .leq || op == .geq || op == .neq
  | _ => false

inductive LoopBound where
  | bounded
  | unbounded
  deriving BEq

mutual
partial def collectLoopBoundsExpr (e : CExpr) : List LoopBound :=
  match e with
  | .whileExpr cond body elseBody _ =>
    let thisBound := if isBoundedCond cond then .bounded else .unbounded
    [thisBound] ++ collectLoopBoundsStmts body ++ collectLoopBoundsStmts elseBody
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ collectLoopBoundsExpr a) []
  | .binOp _ l r _ => collectLoopBoundsExpr l ++ collectLoopBoundsExpr r
  | .unaryOp _ e _ => collectLoopBoundsExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectLoopBoundsExpr v) []
  | .fieldAccess obj _ _ => collectLoopBoundsExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectLoopBoundsExpr v) []
  | .match_ scrut arms _ =>
    collectLoopBoundsExpr scrut ++ arms.foldl (fun acc a => acc ++ collectLoopBoundsArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectLoopBoundsExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectLoopBoundsExpr e) []
  | .arrayIndex arr idx _ => collectLoopBoundsExpr arr ++ collectLoopBoundsExpr idx
  | .cast inner _ | .try_ inner _ => collectLoopBoundsExpr inner
  | .allocCall inner alloc _ => collectLoopBoundsExpr inner ++ collectLoopBoundsExpr alloc
  | .ifExpr c t e _ => collectLoopBoundsExpr c ++ collectLoopBoundsStmts t ++ collectLoopBoundsStmts e
  | _ => []

partial def collectLoopBoundsArm (arm : CMatchArm) : List LoopBound :=
  match arm with
  | .enumArm _ _ _ body => collectLoopBoundsStmts body
  | .litArm v body => collectLoopBoundsExpr v ++ collectLoopBoundsStmts body
  | .varArm _ _ body => collectLoopBoundsStmts body

partial def collectLoopBoundsStmt (s : CStmt) : List LoopBound :=
  match s with
  | .while_ cond body _ step =>
    let hasStep := !step.isEmpty
    let thisBound := if isBoundedCond cond && hasStep then .bounded else .unbounded
    [thisBound] ++ collectLoopBoundsStmts body
  | .letDecl _ _ _ v => collectLoopBoundsExpr v
  | .assign _ v => collectLoopBoundsExpr v
  | .return_ (some v) _ => collectLoopBoundsExpr v
  | .return_ none _ => []
  | .expr e => collectLoopBoundsExpr e
  | .ifElse c t el =>
    collectLoopBoundsExpr c ++ collectLoopBoundsStmts t ++
    match el with | some stmts => collectLoopBoundsStmts stmts | none => []
  | .fieldAssign obj _ v => collectLoopBoundsExpr obj ++ collectLoopBoundsExpr v
  | .derefAssign t v => collectLoopBoundsExpr t ++ collectLoopBoundsExpr v
  | .arrayIndexAssign arr idx v =>
    collectLoopBoundsExpr arr ++ collectLoopBoundsExpr idx ++ collectLoopBoundsExpr v
  | .break_ (some v) _ => collectLoopBoundsExpr v
  | .break_ none _ | .continue_ _ => []
  | .defer body => collectLoopBoundsExpr body
  | .borrowIn _ _ _ _ _ body => collectLoopBoundsStmts body

partial def collectLoopBoundsStmts (ss : List CStmt) : List LoopBound :=
  ss.foldl (fun acc s => acc ++ collectLoopBoundsStmt s) []
end

def classifyLoops (body : List CStmt) : String :=
  let bounds := collectLoopBoundsStmts body
  if bounds.isEmpty then "no loops"
  else if bounds.all (· == .bounded) then "bounded"
  else if bounds.all (· == .unbounded) then "unbounded"
  else "mixed"

-- ============================================================
-- Body fingerprinting
-- ============================================================

private partial def fingerprintExpr : CExpr → String
  | .intLit v _ => s!"(int {v})"
  | .floatLit v _ => s!"(float {v})"
  | .boolLit v => s!"(bool {v})"
  | .strLit v => s!"(str {repr v})"
  | .charLit v => s!"(char {repr v})"
  | .ident name _ => s!"(var {name})"
  | .binOp op lhs rhs _ => s!"(binop {repr op} {fingerprintExpr lhs} {fingerprintExpr rhs})"
  | .unaryOp op inner _ => s!"(unary {repr op} {fingerprintExpr inner})"
  | .call fn _ args _ => s!"(call {fn} {fingerprintExprs args})"
  | .structLit name _ fields _ =>
    let fs := fields.map fun (n, e) => s!"{n}={fingerprintExpr e}"
    s!"(struct {name} {" ".intercalate fs})"
  | .fieldAccess obj field _ => s!"(field {fingerprintExpr obj} {field})"
  | .enumLit en v _ fields _ =>
    let fs := fields.map fun (n, e) => s!"{n}={fingerprintExpr e}"
    s!"(enum {en}::{v} {" ".intercalate fs})"
  | .match_ scr arms _ =>
    let as_ := arms.map fingerprintArm
    s!"(match {fingerprintExpr scr} {" ".intercalate as_})"
  | .borrow inner _ => s!"(borrow {fingerprintExpr inner})"
  | .borrowMut inner _ => s!"(borrowmut {fingerprintExpr inner})"
  | .deref inner _ => s!"(deref {fingerprintExpr inner})"
  | .arrayLit elems _ => s!"(array {fingerprintExprs elems})"
  | .arrayIndex arr idx _ => s!"(index {fingerprintExpr arr} {fingerprintExpr idx})"
  | .cast inner ty => s!"(cast {fingerprintExpr inner} {repr ty})"
  | .fnRef name _ => s!"(fnref {name})"
  | .try_ inner _ => s!"(try {fingerprintExpr inner})"
  | .allocCall inner alloc _ => s!"(alloc {fingerprintExpr inner} {fingerprintExpr alloc})"
  | .whileExpr cond body els _ => s!"(while {fingerprintExpr cond} {fingerprintStmts body} {fingerprintStmts els})"
  | .ifExpr cond th el _ => s!"(if {fingerprintExpr cond} {fingerprintStmts th} {fingerprintStmts el})"
where
  fingerprintExprs (es : List CExpr) : String :=
    " ".intercalate (es.map fingerprintExpr)
  fingerprintArm : CMatchArm → String
    | .enumArm en v binds body => s!"(arm {en}::{v} [{" ".intercalate (binds.map Prod.fst)}] {fingerprintStmts body})"
    | .litArm val body => s!"(lit {fingerprintExpr val} {fingerprintStmts body})"
    | .varArm b _ body => s!"(var {b} {fingerprintStmts body})"
  fingerprintStmt : CStmt → String
    | .letDecl name _ _ val => s!"(let {name} {fingerprintExpr val})"
    | .assign name val => s!"(set {name} {fingerprintExpr val})"
    | .return_ (some val) _ => s!"(ret {fingerprintExpr val})"
    | .return_ none _ => "(ret)"
    | .expr e => fingerprintExpr e
    | .ifElse cond th (some el) => s!"(if {fingerprintExpr cond} {fingerprintStmts th} {fingerprintStmts el})"
    | .ifElse cond th none => s!"(if {fingerprintExpr cond} {fingerprintStmts th})"
    | .while_ cond body _ step => s!"(while {fingerprintExpr cond} {fingerprintStmts body} {fingerprintStmts step})"
    | .fieldAssign obj f val => s!"(setfield {fingerprintExpr obj} {f} {fingerprintExpr val})"
    | .derefAssign tgt val => s!"(setderef {fingerprintExpr tgt} {fingerprintExpr val})"
    | .arrayIndexAssign arr idx val => s!"(setindex {fingerprintExpr arr} {fingerprintExpr idx} {fingerprintExpr val})"
    | .break_ _ lbl => s!"(break {lbl})"
    | .continue_ lbl => s!"(continue {lbl})"
    | .defer body => s!"(defer {fingerprintExpr body})"
    | .borrowIn v r rg m _ body => s!"(borrowin {v} {r} {rg} {m} {fingerprintStmts body})"
  fingerprintStmts (ss : List CStmt) : String :=
    "[" ++ " ".intercalate (ss.map fingerprintStmt) ++ "]"

def bodyFingerprint (body : List CStmt) : String :=
  fingerprintExpr.fingerprintStmts body

-- ============================================================
-- Core → PExpr extraction
-- ============================================================

private def binOpToPBinOp : BinOp → Option Proof.PBinOp
  | .add => some .add
  | .sub => some .sub
  | .mul => some .mul
  | .eq  => some .eq
  | .neq => some .ne
  | .lt  => some .lt
  | .leq => some .le
  | .gt  => some .gt
  | .geq => some .ge
  | _    => none

mutual
partial def cExprToPExpr : CExpr → Option Proof.PExpr
  | .intLit n _ => some (.lit (.int n))
  | .boolLit b => some (.lit (.bool b))
  | .ident name _ => some (.var name)
  | .binOp op lhs rhs _ => do
    let pop ← binOpToPBinOp op
    let pl ← cExprToPExpr lhs
    let pr ← cExprToPExpr rhs
    some (.binOp pop pl pr)
  | .call fn _ args _ => do
    let pargs ← args.mapM cExprToPExpr
    some (.call fn pargs)
  | .ifExpr cond thenBranch elseBranch _ => do
    let pc ← cExprToPExpr cond
    let pt ← cStmtsToPExpr thenBranch
    let pe ← cStmtsToPExpr elseBranch
    some (.ifThenElse pc pt pe)
  | _ => none

partial def cStmtsToPExpr : List CStmt → Option Proof.PExpr
  | [] => none
  | [.return_ (some e) _] => cExprToPExpr e
  | [.expr e] => cExprToPExpr e
  | (.letDecl name _ _ val) :: rest => do
    let pv ← cExprToPExpr val
    let pb ← cStmtsToPExpr rest
    some (.letIn name pv pb)
  | [.ifElse cond thenBranch (some elseBranch)] => do
    let pc ← cExprToPExpr cond
    let pt ← cStmtsToPExpr thenBranch
    let pe ← cStmtsToPExpr elseBranch
    some (.ifThenElse pc pt pe)
  | _ => none
end

-- Unsupported construct identification

private partial def identifyUnsupportedExpr : CExpr → List String
  | .floatLit .. => ["float literal"]
  | .strLit .. => ["string literal"]
  | .charLit .. => ["char literal"]
  | .structLit .. => ["struct literal"]
  | .fieldAccess .. => ["field access"]
  | .enumLit .. => ["enum literal"]
  | .match_ .. => ["match expression"]
  | .borrow .. => ["borrow"]
  | .borrowMut .. => ["mutable borrow"]
  | .deref .. => ["deref"]
  | .arrayLit .. => ["array literal"]
  | .arrayIndex .. => ["array index"]
  | .cast .. => ["cast"]
  | .fnRef .. => ["function reference"]
  | .try_ .. => ["try expression"]
  | .allocCall .. => ["alloc call"]
  | .whileExpr .. => ["while expression"]
  | .unaryOp .. => ["unary operator"]
  | .binOp op _ _ _ => match binOpToPBinOp op with
    | none => [s!"unsupported operator: {repr op}"]
    | some _ => []
  | _ => []

private partial def identifyUnsupportedStmt : CStmt → List String
  | .letDecl _ _ _ val => identifyUnsupportedExpr val
  | .return_ (some e) _ => identifyUnsupportedExpr e
  | .expr e => identifyUnsupportedExpr e
  | .ifElse cond thenBr elseBr =>
    identifyUnsupportedExpr cond ++
    thenBr.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) [] ++
    match elseBr with
    | some stmts => stmts.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) []
    | none => ["if without else"]
  | _ => []

def identifyUnsupported (body : List CStmt) : List String :=
  let stmtKinds := body.filterMap fun s => match s with
    | .while_ .. => some "while loop"
    | .fieldAssign .. => some "field assignment"
    | .derefAssign .. => some "deref assignment"
    | .arrayIndexAssign .. => some "array index assignment"
    | .break_ .. => some "break"
    | .continue_ .. => some "continue"
    | .defer .. => some "defer"
    | .borrowIn .. => some "borrow region"
    | .assign .. => some "mutable assignment"
    | _ => none
  let exprKinds := body.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) []
  (stmtKinds ++ exprKinds).eraseDups

-- ============================================================
-- Eligibility predicates
-- ============================================================

/-- A function is proof-eligible when it is pure, not trusted, and has
    no type parameters (monomorphic or pre-mono with concrete types only). -/
def CFnDef.isProofEligible (f : CFnDef) : Bool :=
  f.capSet.isEmpty &&
  !f.isTrusted &&
  !f.isEntryPoint &&
  f.trustedImplOrigin.isNone

/-- A struct is proof-eligible when it has no FFI annotations. -/
def CStructDef.isProofEligible (s : CStructDef) : Bool :=
  !s.isReprC && !s.isPacked && s.reprAlign.isNone

/-- An enum is proof-eligible when it has no builtin override. -/
def CEnumDef.isProofEligible (e : CEnumDef) : Bool :=
  e.builtinId.isNone

-- ============================================================
-- Eligibility assessment (source + profile gates)
-- ============================================================

/-- Source location: (file, line). -/
abbrev SourceLoc := String × Nat

inductive ExclusionKind where
  | source
  | profile
  | both
  deriving Repr

structure EligibilityEntry where
  qualName       : String
  eligible       : Bool
  sourceReasons  : List String
  profileReasons : List String
  exclusionKind  : Option ExclusionKind
  isTrusted      : Bool
  loc            : Option SourceLoc

-- ============================================================
-- ProofCore artifact
-- ============================================================

/-- A function that passed eligibility and was extracted (or attempted). -/
structure ProofCoreEntry where
  qualName    : String
  bareName    : String
  fn          : CFnDef
  extracted   : Option Proof.PExpr
  unsupported : List String
  fingerprint : String
  params      : List String
  eligibility : EligibilityEntry
  loc         : Option SourceLoc

/-- A function excluded from ProofCore with reasons. -/
structure ProofCoreExcluded where
  qualName    : String
  bareName    : String
  fn          : CFnDef
  fingerprint : String
  eligibility : EligibilityEntry
  loc         : Option SourceLoc

/-- The proof-oriented fragment of validated Core.
    This is the single artifact boundary between Core and the proof pipeline. -/
structure ProofCore where
  /-- Eligible functions with extraction results. -/
  entries     : List ProofCoreEntry
  /-- Excluded functions with reasons. -/
  excluded    : List ProofCoreExcluded
  /-- Proof-eligible structs. -/
  structs     : List CStructDef
  /-- Proof-eligible enums. -/
  enums       : List CEnumDef
  /-- Trait definitions (for context). -/
  traitDefs   : List CTraitDef
  /-- Precomputed call graph. -/
  callGraph   : CallGraph
  /-- Precomputed recursion classification. -/
  recMap      : List (String × RecursionKind × List String)
  /-- Extern function names. -/
  externNames : List String

-- ============================================================
-- Extraction: Core modules → ProofCore
-- ============================================================

/-- Flatten a module tree into a list of all modules (pre-order). -/
private partial def flattenModules (m : CModule) : List CModule :=
  m :: List.flatten (m.submodules.map flattenModules)

/-- Assess eligibility for one function. Combines source-level checks
    (capabilities, trusted, entry point) with profile gates (recursion,
    loops, allocation, FFI, blocking I/O). -/
private def assessEligibility
    (f : CFnDef) (qualName : String)
    (externNames : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : List (String × SourceLoc)) : EligibilityEntry :=
  let fnLoc := match locMap.find? fun (n, _) => n == qualName with
    | some (_, loc) => some loc
    | none => none
  let (concreteCaps, _) := f.capSet.normalize
  let callees := collectCallsStmts f.body |>.eraseDups
  let sourceReasons : List String :=
    (if !f.capSet.isEmpty then
      [s!"has capabilities: {", ".intercalate concreteCaps}"] else []) ++
    (if f.isTrusted then ["marked trusted"] else []) ++
    (if f.isEntryPoint then ["is entry point (main)"] else []) ++
    (if f.trustedImplOrigin.isSome then ["from trusted impl"] else [])
  let allocs := callees.filter isAllocCall
  let rec_ := match recMap.find? (fun (n, _, _) => n == f.name) with
    | some (_, .direct, _) => "direct"
    | some (_, .mutual, _) => "mutual"
    | _ => "none"
  let crossesFfi := callees.any fun c => externNames.contains c
  let loopClass := classifyLoops f.body
  let profileReasons : List String :=
    (if rec_ != "none" then [s!"recursion ({rec_})"] else []) ++
    (if loopClass == "unbounded" || loopClass == "mixed" then ["unbounded loops"] else []) ++
    (if !allocs.isEmpty || concreteCaps.any (· == "Alloc") then ["allocation"] else []) ++
    (if crossesFfi then ["FFI"] else []) ++
    (if concreteCaps.any fun c => c == "File" || c == "Network" || c == "Process"
     then ["blocking I/O"] else [])
  let passesSource := sourceReasons.isEmpty
  let passesProfile := profileReasons.isEmpty
  let eligible := passesSource && passesProfile
  let exclusionKind := if eligible then none
    else if !passesSource && !passesProfile then some .both
    else if !passesSource then some .source
    else some .profile
  { qualName, eligible, sourceReasons, profileReasons, exclusionKind
  , isTrusted := f.isTrusted, loc := fnLoc }

/-- Walk a module tree collecting eligibility + extraction for each function.
    This produces one ProofCoreEntry or ProofCoreExcluded per function. -/
private partial def extractModule
    (externNames : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : List (String × SourceLoc))
    (m : CModule) (modulePath : String := "")
    : List ProofCoreEntry × List ProofCoreExcluded :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let (entries, excluded) := m.functions.foldl (fun (accE, accX) f =>
    let qualName := qualPrefix ++ "." ++ f.name
    let bareName := f.name
    let fp := bodyFingerprint f.body
    let elig := assessEligibility f qualName externNames recMap locMap
    if elig.isTrusted then
      (accE, accX ++ [{ qualName, bareName, fn := f, fingerprint := fp
                       , eligibility := elig, loc := elig.loc : ProofCoreExcluded }])
    else if elig.eligible then
      let extracted := cStmtsToPExpr f.body
      let unsup := if extracted.isNone then identifyUnsupported f.body else []
      (accE ++ [{ qualName, bareName, fn := f, extracted, unsupported := unsup
                 , fingerprint := fp, params := f.params.map Prod.fst
                 , eligibility := elig, loc := elig.loc : ProofCoreEntry }], accX)
    else
      (accE, accX ++ [{ qualName, bareName, fn := f, fingerprint := fp
                       , eligibility := elig, loc := elig.loc : ProofCoreExcluded }])
  ) ([], [])
  -- Recurse into submodules
  let (subEntries, subExcluded) := m.submodules.foldl (fun (accE, accX) sub =>
    let (e, x) := extractModule externNames recMap locMap sub qualPrefix
    (accE ++ e, accX ++ x)) ([], [])
  (entries ++ subEntries, excluded ++ subExcluded)

/-- Extract the proof-oriented fragment from validated Core.
    This is the primary entry point for the proof pipeline. -/
def extractProofCore (vc : ValidatedCore) (locMap : List (String × SourceLoc) := [])
    : ProofCore :=
  let modules := vc.coreModules
  let allModules := List.flatten (modules.map flattenModules)
  -- Precompute shared analysis
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  -- Extract entries and excluded
  let (entries, excluded) := modules.foldl (fun (accE, accX) m =>
    let (e, x) := extractModule externNames recMap locMap m
    (accE ++ e, accX ++ x)) ([], [])
  -- Collect eligible types
  let sts := List.flatten (allModules.map (·.structs)) |>.filter CStructDef.isProofEligible
  let ens := List.flatten (allModules.map (·.enums)) |>.filter CEnumDef.isProofEligible
  let tds := List.flatten (allModules.map (·.traitDefs))
  { entries, excluded, structs := sts, enums := ens, traitDefs := tds
  , callGraph := graph, recMap, externNames }

-- ============================================================
-- Pretty-printing (for --report proofcore)
-- ============================================================

def ProofCore.summary (pc : ProofCore) : String :=
  let eligibleNames := pc.entries.map (·.qualName)
  let excludedNames := pc.excluded.map (·.qualName)
  let extractedCount := (pc.entries.filter (·.extracted.isSome)).length
  s!"ProofCore fragment:\n" ++
  s!"  {pc.entries.length} eligible functions ({extractedCount} extracted to PExpr)\n" ++
  s!"  {pc.excluded.length} excluded functions\n" ++
  s!"  {pc.structs.length} proof-eligible structs\n" ++
  s!"  {pc.enums.length} proof-eligible enums\n" ++
  s!"  eligible:  {eligibleNames}\n" ++
  s!"  excluded:  {excludedNames}"

/-- Get all eligibility entries (both eligible and excluded). -/
def ProofCore.allEligibility (pc : ProofCore) : List EligibilityEntry :=
  pc.entries.map (·.eligibility) ++ pc.excluded.map (·.eligibility)

/-- Find a ProofCoreEntry by qualified name. -/
def ProofCore.findEntry (pc : ProofCore) (qualName : String) : Option ProofCoreEntry :=
  pc.entries.find? fun e => e.qualName == qualName

/-- Find an excluded entry by qualified name. -/
def ProofCore.findExcluded (pc : ProofCore) (qualName : String) : Option ProofCoreExcluded :=
  pc.excluded.find? fun e => e.qualName == qualName

end Concrete
