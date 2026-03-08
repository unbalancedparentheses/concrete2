import Concrete.Core
import Concrete.SSA

namespace Concrete

/-! ## Lowering: Core IR → SSA IR

Converts structured Core IR into SSA form with basic blocks,
conditional branches, and phi nodes.
-/

-- ============================================================
-- Helpers
-- ============================================================

private def enumerate {α : Type} (l : List α) : List (Nat × α) :=
  let rec go (i : Nat) : List α → List (Nat × α)
    | [] => []
    | a :: rest => (i, a) :: go (i + 1) rest
  go 0 l

-- ============================================================
-- Lowering state
-- ============================================================

structure LowerState where
  blocks : List SBlock
  currentLabel : String
  currentInsts : List SInst
  labelCounter : Nat
  regCounter : Nat
  vars : List (String × SVal)
  stringLits : List (String × String)

abbrev LowerM := ExceptT String (StateM LowerState)

private def getState : LowerM LowerState := get
private def setState (s : LowerState) : LowerM Unit := set s

private def freshReg (pfx : String := "t") : LowerM String := do
  let s ← getState
  let name := s!"{pfx}{s.regCounter}"
  setState { s with regCounter := s.regCounter + 1 }
  return name

private def freshLabel (pfx : String := "bb") : LowerM String := do
  let s ← getState
  let name := s!"{pfx}{s.labelCounter}"
  setState { s with labelCounter := s.labelCounter + 1 }
  return name

private def emit (inst : SInst) : LowerM Unit := do
  let s ← getState
  setState { s with currentInsts := s.currentInsts ++ [inst] }

private def terminateBlock (term : STerm) : LowerM Unit := do
  let s ← getState
  let block : SBlock := { label := s.currentLabel, insts := s.currentInsts, term := term }
  setState { s with blocks := s.blocks ++ [block], currentInsts := [] }

private def startBlock (label : String) : LowerM Unit := do
  let s ← getState
  setState { s with currentLabel := label }

private def setVar (name : String) (val : SVal) : LowerM Unit := do
  let s ← getState
  let vars' := if s.vars.any fun (n, _) => n == name then
    s.vars.map fun (n, v) => if n == name then (n, val) else (n, v)
  else
    s.vars ++ [(name, val)]
  setState { s with vars := vars' }

private def lookupVar (name : String) : LowerM (Option SVal) := do
  let s ← getState
  return s.vars.lookup name

private def internString (val : String) : LowerM String := do
  let s ← getState
  match s.stringLits.find? fun (_, v) => v == val with
  | some (name, _) => return name
  | none =>
    let name := s!"str.{s.stringLits.length}"
    setState { s with stringLits := s.stringLits ++ [(name, val)] }
    return name

/-- Check if current block already has a terminator in the blocks list. -/
private def currentBlockTerminated : LowerM Bool := do
  let s ← getState
  -- If the current label matches the last completed block's label, it was terminated
  match s.blocks.getLast? with
  | some b => return b.label == s.currentLabel && s.currentInsts.isEmpty
  | none => return false

-- ============================================================
-- Expression and statement lowering
-- ============================================================

mutual

partial def lowerExpr (e : CExpr) : LowerM SVal := do
  match e with
  | .intLit v ty => return .intConst v ty
  | .floatLit v ty => return .floatConst v ty
  | .boolLit b => return .boolConst b
  | .strLit s =>
    let name ← internString s
    return .strConst name
  | .charLit c =>
    return .intConst (Int.ofNat c.toNat) .char

  | .ident name ty =>
    match ← lookupVar name with
    | some val => return val
    | none => return .reg name ty

  | .binOp op lhs rhs ty =>
    let lVal ← lowerExpr lhs
    let rVal ← lowerExpr rhs
    let dst ← freshReg
    emit (.binOp dst op lVal rVal ty)
    return .reg dst ty

  | .unaryOp op operand ty =>
    let oVal ← lowerExpr operand
    let dst ← freshReg
    emit (.unaryOp dst op oVal ty)
    return .reg dst ty

  | .call fn _typeArgs args ty =>
    let mut aVals : List SVal := []
    for arg in args do
      let v ← lowerExpr arg
      aVals := aVals ++ [v]
    if ty == .unit || ty == .never then
      emit (.call none fn aVals ty)
      return .unit
    else
      let dst ← freshReg
      emit (.call (some dst) fn aVals ty)
      return .reg dst ty

  | .structLit _name _typeArgs fields ty =>
    let dst ← freshReg
    emit (.alloca dst ty)
    let baseVal := SVal.reg dst ty
    for (idx, (_, fieldExpr)) in enumerate fields do
      let fVal ← lowerExpr fieldExpr
      let gepDst ← freshReg
      emit (.gep gepDst baseVal [.intConst (Int.ofNat idx) .int] fieldExpr.ty)
      emit (.store fVal (.reg gepDst fieldExpr.ty))
    let loadDst ← freshReg
    emit (.load loadDst baseVal ty)
    return .reg loadDst ty

  | .fieldAccess obj _field ty =>
    let oVal ← lowerExpr obj
    let dst ← freshReg
    emit (.gep dst oVal [.intConst 0 .int] ty)
    let loadDst ← freshReg
    emit (.load loadDst (.reg dst ty) ty)
    return .reg loadDst ty

  | .enumLit _enumName _variant _typeArgs fields ty =>
    let dst ← freshReg
    emit (.alloca dst ty)
    let baseVal := SVal.reg dst ty
    for (idx, (_, fieldExpr)) in enumerate fields do
      let fVal ← lowerExpr fieldExpr
      let gepDst ← freshReg
      emit (.gep gepDst baseVal [.intConst (Int.ofNat idx) .int] fieldExpr.ty)
      emit (.store fVal (.reg gepDst fieldExpr.ty))
    let loadDst ← freshReg
    emit (.load loadDst baseVal ty)
    return .reg loadDst ty

  | .match_ scrutinee arms ty =>
    let scrVal ← lowerExpr scrutinee
    let mergeLabel ← freshLabel "merge"
    let mergeDst ← freshReg
    let mut phiIncoming : List (SVal × String) := []
    -- Chain arms sequentially (simplified v1)
    for (idx, arm) in enumerate arms do
      let armLabel ← freshLabel s!"arm{idx}"
      let terminated ← currentBlockTerminated
      if !terminated then
        terminateBlock (.br armLabel)
      startBlock armLabel
      match arm with
      | .enumArm _ _ bindings body =>
        for (bidx, (bname, bty)) in enumerate bindings do
          let gepDst ← freshReg
          emit (.gep gepDst scrVal [.intConst (Int.ofNat bidx) .int] bty)
          let loadDst ← freshReg
          emit (.load loadDst (.reg gepDst bty) bty)
          setVar bname (.reg loadDst bty)
        lowerStmts body
        let curLabel := armLabel
        phiIncoming := phiIncoming ++ [(.unit, curLabel)]
        let term ← currentBlockTerminated
        if !term then
          terminateBlock (.br mergeLabel)
      | .litArm _val body =>
        lowerStmts body
        phiIncoming := phiIncoming ++ [(.unit, armLabel)]
        let term ← currentBlockTerminated
        if !term then
          terminateBlock (.br mergeLabel)
      | .varArm binding _bindTy body =>
        setVar binding scrVal
        lowerStmts body
        phiIncoming := phiIncoming ++ [(.unit, armLabel)]
        let term ← currentBlockTerminated
        if !term then
          terminateBlock (.br mergeLabel)
    startBlock mergeLabel
    if phiIncoming.length > 1 then
      emit (.phi mergeDst phiIncoming ty)
      return .reg mergeDst ty
    else
      return .unit

  | .borrow inner ty =>
    let iVal ← lowerExpr inner
    let dst ← freshReg
    emit (.cast dst iVal ty)
    return .reg dst ty

  | .borrowMut inner ty =>
    let iVal ← lowerExpr inner
    let dst ← freshReg
    emit (.cast dst iVal ty)
    return .reg dst ty

  | .deref inner ty =>
    let iVal ← lowerExpr inner
    let dst ← freshReg
    emit (.load dst iVal ty)
    return .reg dst ty

  | .arrayLit elems ty =>
    let dst ← freshReg
    emit (.alloca dst ty)
    let baseVal := SVal.reg dst ty
    let elemTy := match ty with | .array t _ => t | _ => .placeholder
    for (idx, elem) in enumerate elems do
      let eVal ← lowerExpr elem
      let gepDst ← freshReg
      emit (.gep gepDst baseVal [.intConst (Int.ofNat idx) .int] elemTy)
      emit (.store eVal (.reg gepDst elemTy))
    let loadDst ← freshReg
    emit (.load loadDst baseVal ty)
    return .reg loadDst ty

  | .arrayIndex arr index ty =>
    let aVal ← lowerExpr arr
    let iVal ← lowerExpr index
    let gepDst ← freshReg
    emit (.gep gepDst aVal [iVal] ty)
    let loadDst ← freshReg
    emit (.load loadDst (.reg gepDst ty) ty)
    return .reg loadDst ty

  | .cast inner targetTy =>
    let iVal ← lowerExpr inner
    let dst ← freshReg
    emit (.cast dst iVal targetTy)
    return .reg dst targetTy

  | .fnRef name ty =>
    return .reg name ty

  | .try_ inner ty =>
    let iVal ← lowerExpr inner
    let dst ← freshReg
    emit (.cast dst iVal ty)
    return .reg dst ty

  | .allocCall inner _allocExpr _ty =>
    lowerExpr inner

  | .whileExpr cond body _elseBody _ty =>
    let headerLabel ← freshLabel "while.hdr"
    let bodyLabel ← freshLabel "while.body"
    let exitLabel ← freshLabel "while.exit"
    terminateBlock (.br headerLabel)
    startBlock headerLabel
    let condVal ← lowerExpr cond
    terminateBlock (.condBr condVal bodyLabel exitLabel)
    startBlock bodyLabel
    lowerStmts body
    let term ← currentBlockTerminated
    if !term then
      terminateBlock (.br headerLabel)
    startBlock exitLabel
    return .unit

partial def lowerStmt (stmt : CStmt) : LowerM Unit := do
  match stmt with
  | .letDecl name _mutable _ty value =>
    let val ← lowerExpr value
    setVar name val

  | .assign name value =>
    let val ← lowerExpr value
    setVar name val

  | .return_ (some value) _retTy =>
    let val ← lowerExpr value
    terminateBlock (.ret (some val))

  | .return_ none _retTy =>
    terminateBlock (.ret none)

  | .expr e =>
    let _ ← lowerExpr e

  | .ifElse cond then_ else_ =>
    let condVal ← lowerExpr cond
    let thenLabel ← freshLabel "then"
    let elseLabel ← freshLabel "else"
    let mergeLabel ← freshLabel "merge"
    terminateBlock (.condBr condVal thenLabel elseLabel)
    -- Then block
    startBlock thenLabel
    lowerStmts then_
    let term1 ← currentBlockTerminated
    if !term1 then
      terminateBlock (.br mergeLabel)
    -- Else block
    startBlock elseLabel
    match else_ with
    | some stmts => lowerStmts stmts
    | none => pure ()
    let term2 ← currentBlockTerminated
    if !term2 then
      terminateBlock (.br mergeLabel)
    -- Merge
    startBlock mergeLabel

  | .while_ cond body _label =>
    let headerLabel ← freshLabel "while.hdr"
    let bodyLabel ← freshLabel "while.body"
    let exitLabel ← freshLabel "while.exit"
    terminateBlock (.br headerLabel)
    startBlock headerLabel
    let condVal ← lowerExpr cond
    terminateBlock (.condBr condVal bodyLabel exitLabel)
    startBlock bodyLabel
    lowerStmts body
    let term ← currentBlockTerminated
    if !term then
      terminateBlock (.br headerLabel)
    startBlock exitLabel

  | .fieldAssign obj _field value =>
    let oVal ← lowerExpr obj
    let fVal ← lowerExpr value
    let gepDst ← freshReg
    emit (.gep gepDst oVal [.intConst 0 .int] value.ty)
    emit (.store fVal (.reg gepDst value.ty))

  | .derefAssign target value =>
    let tVal ← lowerExpr target
    let vVal ← lowerExpr value
    emit (.store vVal tVal)

  | .arrayIndexAssign arr index value =>
    let aVal ← lowerExpr arr
    let iVal ← lowerExpr index
    let vVal ← lowerExpr value
    let gepDst ← freshReg
    emit (.gep gepDst aVal [iVal] value.ty)
    emit (.store vVal (.reg gepDst value.ty))

  | .break_ _value _label =>
    pure ()  -- simplified for v1

  | .continue_ _label =>
    pure ()  -- simplified for v1

  | .defer body =>
    let _ ← lowerExpr body

  | .borrowIn _var _ref _region _isMut _refTy body =>
    lowerStmts body

partial def lowerStmts (stmts : List CStmt) : LowerM Unit := do
  for s in stmts do
    let term ← currentBlockTerminated
    if term then
      return  -- Don't lower statements after a terminator
    lowerStmt s

end

-- ============================================================
-- Function and module lowering
-- ============================================================

def lowerFn (f : CFnDef) : Except String SFnDef :=
  let initState : LowerState := {
    blocks := []
    currentLabel := "entry"
    currentInsts := []
    labelCounter := 0
    regCounter := 0
    vars := f.params.map fun (n, ty) => (n, SVal.reg n ty)
    stringLits := []
  }
  let result := (do
    lowerStmts f.body
    -- If the function hasn't terminated, add implicit return
    let term ← currentBlockTerminated
    if !term then
      if f.retTy == Ty.unit then
        terminateBlock (.ret none)
      else
        terminateBlock (.ret (some SVal.unit))
  ).run initState |>.run
  match result with
  | ((.ok ()), finalState) =>
    .ok {
      name := f.name
      params := f.params
      retTy := f.retTy
      blocks := finalState.blocks
    }
  | ((.error e), _) => .error e

def lowerModule (m : CModule) : SModule :=
  let fns := m.functions.filterMap fun f =>
    match lowerFn f with
    | .ok sfn => some sfn
    | .error _ => none
  -- Collect string literals
  let globals := m.functions.foldl (fun acc f =>
    let initState : LowerState := {
      blocks := [], currentLabel := "entry", currentInsts := []
      labelCounter := 0, regCounter := 0
      vars := f.params.map fun (n, ty) => (n, SVal.reg n ty)
      stringLits := []
    }
    let result := (do
      lowerStmts f.body
      let term ← currentBlockTerminated
      if !term then terminateBlock (.ret none)
    ).run initState |>.run
    match result with
    | ((.ok ()), finalState) => acc ++ finalState.stringLits
    | _ => acc
  ) ([] : List (String × String))
  { name := m.name
    structs := m.structs
    enums := m.enums
    functions := fns
    externFns := m.externFns
    globals := globals }

end Concrete
