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

structure LoopInfo where
  headerLabel : String
  exitLabel : String
  /-- Phi registers created at header: (varName, phiReg, preLoopVal, ty) -/
  headerPhis : List (String × String × SVal × Ty) := []
  /-- Var snapshots at each break: (varsSnapshot, sourceLabel) -/
  breakEdges : List (List (String × SVal) × String) := []
  /-- Alloca slot for while-as-expression result (break stores value here). -/
  resultSlot : Option String := none
  /-- Type for the result slot. -/
  resultTy : Ty := .unit
  /-- Var snapshots at each continue: (varsSnapshot, sourceLabel) -/
  continueEdges : List (List (String × SVal) × String) := []
  /-- Target label for continue (step block for for-loops, header for while-loops). -/
  continueTarget : String := ""
  /-- Optional loop label for labeled break/continue. -/
  loopLabel : Option String := none

structure LowerState where
  blocks : List SBlock
  currentLabel : String
  currentInsts : List SInst
  labelCounter : Nat
  regCounter : Nat
  vars : List (String × SVal)
  stringLits : List (String × String)
  structDefs : List CStructDef
  enumDefs : List CEnumDef
  loopStack : List LoopInfo

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
  match s.blocks.getLast? with
  | some b => return b.label == s.currentLabel && s.currentInsts.isEmpty
  | none => return false

/-- Get the current block label (may differ from startBlock label after lowering body). -/
private def getCurrentLabel : LowerM String := do
  let s ← getState
  -- If the current block was terminated, the last block's label is where we ended up
  -- Otherwise, we're still building the current label
  return s.currentLabel

-- ============================================================
-- Struct/enum definition lookup helpers
-- ============================================================

/-- Look up a struct definition's fields by type name. -/
private def lookupStructFields (tyName : String) : LowerM (List (String × Ty)) := do
  let s ← getState
  match s.structDefs.find? fun sd => sd.name == tyName with
  | some sd => return sd.fields
  | none => return []

/-- Get field index within a struct definition. Returns 0 if not found. -/
private def fieldIndex (tyName : String) (fieldName : String) : LowerM Nat := do
  let fields ← lookupStructFields tyName
  match (enumerate fields).find? fun (_, (n, _)) => n == fieldName with
  | some (idx, _) => return idx
  | none => return 0

/-- Get variant index within an enum definition. Returns 0 if not found. -/
private def variantIndex (enumName : String) (variantName : String) : LowerM Nat := do
  let s ← getState
  match s.enumDefs.find? fun ed => ed.name == enumName with
  | some ed =>
    match (enumerate ed.variants).find? fun (_, (vn, _)) => vn == variantName with
    | some (idx, _) => return idx
    | none => return 0
  | none => return 0

/-- Get variant fields within an enum definition. -/
private def variantFields (enumName : String) (variantName : String) : LowerM (List (String × Ty)) := do
  let s ← getState
  match s.enumDefs.find? fun ed => ed.name == enumName with
  | some ed =>
    match ed.variants.find? fun (vn, _) => vn == variantName with
    | some (_, fields) => return fields
    | none => return []
  | none => return []

/-- Extract struct type name from a Ty, unwrapping references/pointers. -/
private def structNameFromTy (ty : Ty) : String :=
  match ty with
  | .named n => n
  | .generic n _ => n
  | .ref inner | .refMut inner | .ptrMut inner | .ptrConst inner => structNameFromTy inner
  | _ => ""

/-- Compute byte size of a type (for malloc). -/
private partial def computeTySize (ty : Ty) : LowerM Nat := do
  match ty with
  | .int | .uint | .float64 => return 8
  | .i32 | .u32 | .float32 => return 4
  | .i16 | .u16 => return 2
  | .i8 | .u8 | .char | .bool => return 1
  | .unit => return 0
  | .string => return 16  -- ptr + i64
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => return 8
  | .fn_ _ _ _ | .heap _ | .heapArray _ => return 8
  | .generic "Heap" _ | .generic "HeapArray" _ => return 8
  | .generic "Vec" _ => return 24
  | .generic "HashMap" _ => return 40
  | .named name | .generic name _ =>
    let fields ← lookupStructFields name
    if !fields.isEmpty then
      let mut total := 0
      for (_, ft) in fields do
        total := total + (← computeTySize ft)
      return total
    else
      let s ← getState
      match s.enumDefs.find? fun ed => ed.name == name with
      | some ed =>
        let mut maxPayload := 0
        for (_, vfields) in ed.variants do
          let mut sz := 0
          for (_, ft) in vfields do
            sz := sz + (← computeTySize ft)
          maxPayload := Nat.max maxPayload sz
        return 4 + maxPayload  -- i32 tag + payload
      | none => return 8
  | .array elem n => do
    let elemSz ← computeTySize elem
    return elemSz * n
  | _ => return 8

/-- Push loop info onto the loop stack. -/
private def pushLoop (info : LoopInfo) : LowerM Unit := do
  let s ← getState
  setState { s with loopStack := info :: s.loopStack }

/-- Pop loop info from the loop stack, returning it. -/
private def popLoop : LowerM (Option LoopInfo) := do
  let s ← getState
  match s.loopStack with
  | info :: rest =>
    setState { s with loopStack := rest }
    return some info
  | [] => return none

/-- Get the innermost loop info. -/
private def currentLoop : LowerM (Option LoopInfo) := do
  let s ← getState
  return s.loopStack.head?

/-- Find a loop by label, returning it and its index in the stack. -/
private def findLoopByLabel (label : Option String) : LowerM (Option LoopInfo) := do
  match label with
  | none => currentLoop
  | some lbl =>
    let s ← getState
    match s.loopStack.find? fun info => info.loopLabel == some lbl with
    | some info => return some info
    | none => currentLoop

/-- Record a break edge on a specific loop (identified by exitLabel). -/
private def addBreakEdgeToLoop (vars : List (String × SVal)) (srcLabel : String) (targetExitLabel : String) : LowerM Unit := do
  let s ← getState
  let newStack := s.loopStack.map fun info =>
    if info.exitLabel == targetExitLabel then
      { info with breakEdges := info.breakEdges ++ [(vars, srcLabel)] }
    else info
  setState { s with loopStack := newStack }

/-- Record a break edge on the innermost loop. -/
private def addBreakEdge (vars : List (String × SVal)) (label : String) : LowerM Unit := do
  let s ← getState
  match s.loopStack with
  | info :: rest =>
    let info' := { info with breakEdges := info.breakEdges ++ [(vars, label)] }
    setState { s with loopStack := info' :: rest }
  | [] => pure ()

/-- Record a continue edge on the innermost loop. -/
private def addContinueEdge (vars : List (String × SVal)) (label : String) : LowerM Unit := do
  let s ← getState
  match s.loopStack with
  | info :: rest =>
    let info' := { info with continueEdges := info.continueEdges ++ [(vars, label)] }
    setState { s with loopStack := info' :: rest }
  | [] => pure ()

/-- Peek at the continue edges of the innermost loop without popping. -/
private def peekContinueEdges : LowerM (List (List (String × SVal) × String)) := do
  let s ← getState
  match s.loopStack with
  | info :: _ => return info.continueEdges
  | [] => return []

/-- Prepend instructions to an already-finalized block. -/
private def prependInstsToBlock (label : String) (newInsts : List SInst) : LowerM Unit := do
  let s ← getState
  let blocks' := s.blocks.map fun b =>
    if b.label == label then { b with insts := newInsts ++ b.insts }
    else b
  setState { s with blocks := blocks' }

/-- Get current var map snapshot. -/
private def snapshotVars : LowerM (List (String × SVal)) := do
  let s ← getState
  return s.vars

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
    | none =>
      -- If it's a function type and not a local var, treat as global function reference
      match ty with
      | .fn_ _ _ _ => return .reg ("@fnref." ++ name) ty
      | _ => return .reg name ty

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
    -- Handle alloc(val) → malloc + store
    if fn == "alloc" then
      match args.head? with
      | some arg =>
        let aVal ← lowerExpr arg
        let innerTy := arg.ty
        let szDst ← freshReg
        let sz ← computeTySize innerTy
        emit (.call (some szDst) "malloc" [.intConst (Int.ofNat sz) .int] (.ptrMut innerTy))
        let ptrVal := SVal.reg szDst (.ptrMut innerTy)
        emit (.store aVal ptrVal)
        return ptrVal
      | none => return .unit
    -- Handle free(ptr) → free the pointer, return loaded value
    else if fn == "free" then
      match args.head? with
      | some arg =>
        let ptrVal ← lowerExpr arg
        let innerTy := match arg.ty with
          | .heap t => t
          | .generic "Heap" [t] => t
          | t => t
        if ty == .unit || ty == .never then
          emit (.call none "free" [ptrVal] .unit)
          return .unit
        else
          -- Load value before freeing
          let loadDst ← freshReg
          emit (.load loadDst ptrVal innerTy)
          emit (.call none "free" [ptrVal] .unit)
          return .reg loadDst innerTy
      | none => return .unit
    else
    -- Track borrowMut args that need write-back after the call
    let mut aVals : List SVal := []
    let mut mutBorrows : List (String × String × Ty) := []  -- (varName, allocaReg, innerTy)
    for arg in args do
      match arg with
      | .borrowMut (.ident varName innerTy) _ =>
        -- For &mut borrows of variables: alloca, store current value, pass ptr
        -- After the call we'll load back to propagate mutations
        let curVal ← lowerExpr (.ident varName innerTy)
        let slot ← freshReg "mutref."
        emit (.alloca slot innerTy)
        emit (.store curVal (.reg slot innerTy))
        aVals := aVals ++ [.reg slot (.refMut innerTy)]
        mutBorrows := mutBorrows ++ [(varName, slot, innerTy)]
      | _ =>
        let v ← lowerExpr arg
        aVals := aVals ++ [v]
    if ty == .unit || ty == .never then
      emit (.call none fn aVals ty)
      -- Write back mutably borrowed variables
      for (varName, slot, innerTy) in mutBorrows do
        let loadBack ← freshReg "wb."
        emit (.load loadBack (.reg slot innerTy) innerTy)
        setVar varName (.reg loadBack innerTy)
      return .unit
    else
      let dst ← freshReg
      emit (.call (some dst) fn aVals ty)
      -- Write back mutably borrowed variables
      for (varName, slot, innerTy) in mutBorrows do
        let loadBack ← freshReg "wb."
        emit (.load loadBack (.reg slot innerTy) innerTy)
        setVar varName (.reg loadBack innerTy)
      return .reg dst ty

  | .structLit name _typeArgs fields ty =>
    -- Bug #7 fix: reorder fields to match struct definition's canonical order
    let defFields ← lookupStructFields name
    let orderedFields := if defFields.isEmpty then fields
      else defFields.filterMap fun (defName, _) =>
        fields.find? fun (fname, _) => fname == defName
    let actualFields := if orderedFields.length == fields.length then orderedFields else fields
    let dst ← freshReg
    emit (.alloca dst ty)
    let baseVal := SVal.reg dst ty
    for (idx, (_, fieldExpr)) in enumerate actualFields do
      let fVal ← lowerExpr fieldExpr
      let gepDst ← freshReg
      emit (.gep gepDst baseVal [.intConst (Int.ofNat idx) .int] fieldExpr.ty)
      emit (.store fVal (.reg gepDst fieldExpr.ty))
    let loadDst ← freshReg
    emit (.load loadDst baseVal ty)
    return .reg loadDst ty

  | .fieldAccess obj field ty =>
    -- Bug #1 fix: look up actual field index instead of hardcoded 0
    let oVal ← lowerExpr obj
    let tyName := structNameFromTy obj.ty
    let idx ← fieldIndex tyName field
    let dst ← freshReg
    emit (.gep dst oVal [.intConst (Int.ofNat idx) .int] ty)
    let loadDst ← freshReg
    emit (.load loadDst (.reg dst ty) ty)
    return .reg loadDst ty

  | .enumLit enumName variant _typeArgs fields ty =>
    -- Bug #5 fix: store discriminant tag at index 0, fields starting at index 1
    let vidx ← variantIndex enumName variant
    let dst ← freshReg
    emit (.alloca dst ty)
    let baseVal := SVal.reg dst ty
    -- Store tag as i32 at offset 0
    emit (.store (.intConst (Int.ofNat vidx) .i32) baseVal)
    -- Store fields starting at byte offset 4 (after i32 tag)
    -- First GEP past the tag: gep i32, ptr, 1 → offset 4
    let payloadPtr ← freshReg
    emit (.gep payloadPtr baseVal [.intConst 1 .int] .i32)
    let mut fieldOffset : Int := 0
    for (_, (_, fieldExpr)) in enumerate fields do
      let fVal ← lowerExpr fieldExpr
      let gepDst ← freshReg
      if fieldOffset == 0 then
        -- First field is right at the payload pointer
        emit (.gep gepDst (.reg payloadPtr .i32) [.intConst 0 .int] .i8)
      else
        emit (.gep gepDst (.reg payloadPtr .i32) [.intConst fieldOffset .int] .i8)
      emit (.store fVal (.reg gepDst fieldExpr.ty))
      fieldOffset := fieldOffset + Int.ofNat (← computeTySize fieldExpr.ty)
    let loadDst ← freshReg
    emit (.load loadDst baseVal ty)
    return .reg loadDst ty

  | .match_ scrutinee arms ty =>
    -- Bug #3 fix: actual pattern comparison dispatch
    -- Bug #4 fix: capture real result values for phi nodes
    let scrVal ← lowerExpr scrutinee
    let mergeLabel ← freshLabel "merge"
    let mergeDst ← freshReg
    let mut phiIncoming : List (SVal × String) := []
    let mut allArmsTerminated := true

    -- Determine if this is an enum match (check first arm)
    let isEnumMatch := arms.any fun arm => match arm with
      | .enumArm .. => true
      | _ => false

    if isEnumMatch then
      -- Load tag as i32 from offset 0, then extend to i64 for comparison
      let tagRaw ← freshReg
      emit (.load tagRaw scrVal .i32)
      let tagVal ← freshReg
      emit (.cast tagVal (.reg tagRaw .i32) .int)

      -- Generate comparison chain
      for (idx, arm) in enumerate arms do
        let armLabel ← freshLabel s!"arm{idx}"
        let nextCheck ← freshLabel s!"check{idx + 1}"
        match arm with
        | .enumArm enumName variant bindings body =>
          let vidx ← variantIndex enumName variant
          let cmpDst ← freshReg
          emit (.binOp cmpDst .eq (.reg tagVal .int) (.intConst (Int.ofNat vidx) .int) .bool)
          terminateBlock (.condBr (.reg cmpDst .bool) armLabel nextCheck)
          startBlock armLabel
          -- GEP past i32 tag to reach payload
          let payloadGep ← freshReg
          emit (.gep payloadGep scrVal [.intConst 1 .int] .i32)
          let mut fieldOffset : Int := 0
          for (_, (bname, bty)) in enumerate bindings do
            let gepDst ← freshReg
            if fieldOffset == 0 then
              emit (.gep gepDst (.reg payloadGep .i32) [.intConst 0 .int] .i8)
            else
              emit (.gep gepDst (.reg payloadGep .i32) [.intConst fieldOffset .int] .i8)
            let loadDst ← freshReg
            emit (.load loadDst (.reg gepDst bty) bty)
            setVar bname (.reg loadDst bty)
            fieldOffset := fieldOffset + Int.ofNat (← computeTySize bty)
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
        | .varArm binding _bindTy body =>
          terminateBlock (.br armLabel)
          startBlock armLabel
          setVar binding scrVal
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
        | .litArm litVal body =>
          let litSVal ← lowerExpr litVal
          let cmpDst ← freshReg
          emit (.binOp cmpDst .eq scrVal litSVal .bool)
          terminateBlock (.condBr (.reg cmpDst .bool) armLabel nextCheck)
          startBlock armLabel
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
      -- After all checks: if all arms terminated, fallthrough is unreachable
      let term ← currentBlockTerminated
      if !term then
        if allArmsTerminated then
          terminateBlock .unreachable
        else
          let curLabel ← getCurrentLabel
          phiIncoming := phiIncoming ++ [(.unit, curLabel)]
          terminateBlock (.br mergeLabel)
    else
      -- Non-enum match (literal/variable patterns)
      for (idx, arm) in enumerate arms do
        let armLabel ← freshLabel s!"arm{idx}"
        let nextCheck ← freshLabel s!"check{idx + 1}"
        match arm with
        | .litArm litVal body =>
          let litSVal ← lowerExpr litVal
          let cmpDst ← freshReg
          emit (.binOp cmpDst .eq scrVal litSVal .bool)
          terminateBlock (.condBr (.reg cmpDst .bool) armLabel nextCheck)
          startBlock armLabel
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
        | .varArm binding _bindTy body =>
          terminateBlock (.br armLabel)
          startBlock armLabel
          setVar binding scrVal
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
        | .enumArm _ _ _ body =>
          terminateBlock (.br armLabel)
          startBlock armLabel
          lowerStmts body
          let bodyVal ← lastExprVal body ty
          let term ← currentBlockTerminated
          if !term then
            allArmsTerminated := false
            let curLabel ← getCurrentLabel
            phiIncoming := phiIncoming ++ [(bodyVal, curLabel)]
            terminateBlock (.br mergeLabel)
          startBlock nextCheck
      let term ← currentBlockTerminated
      if !term then
        if allArmsTerminated then
          terminateBlock .unreachable
        else
          let curLabel ← getCurrentLabel
          phiIncoming := phiIncoming ++ [(.unit, curLabel)]
          terminateBlock (.br mergeLabel)

    startBlock mergeLabel
    if phiIncoming.length > 1 then
      emit (.phi mergeDst phiIncoming ty)
      return .reg mergeDst ty
    else if phiIncoming.length == 1 then
      match phiIncoming with
      | [(val, _)] => return val
      | _ => return .unit
    else
      -- All arms terminated (e.g. all return) — merge is unreachable
      terminateBlock .unreachable
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
    -- Return alloca pointer directly (don't load) so mutations work
    return baseVal

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
    return .reg ("@fnref." ++ name) ty

  | .try_ inner ty =>
    -- Try operator: unwrap Ok value or early-return Err
    let iVal ← lowerExpr inner
    -- Load tag as i32 from offset 0
    let tagRaw ← freshReg
    emit (.load tagRaw iVal .i32)
    let tagVal ← freshReg
    emit (.cast tagVal (.reg tagRaw .i32) .int)
    -- Compare tag == 0 (Ok variant)
    let cmpDst ← freshReg
    emit (.binOp cmpDst .eq (.reg tagVal .int) (.intConst 0 .int) .bool)
    let okLabel ← freshLabel "try.ok"
    let errLabel ← freshLabel "try.err"
    terminateBlock (.condBr (.reg cmpDst .bool) okLabel errLabel)
    -- Err path: return the whole enum
    startBlock errLabel
    terminateBlock (.ret (some iVal))
    -- Ok path: extract the Ok value from payload
    startBlock okLabel
    let payloadGep ← freshReg
    emit (.gep payloadGep iVal [.intConst 1 .int] .i32)
    let valueGep ← freshReg
    emit (.gep valueGep (.reg payloadGep .i32) [.intConst 0 .int] .i8)
    let loadDst ← freshReg
    emit (.load loadDst (.reg valueGep ty) ty)
    return .reg loadDst ty

  | .allocCall inner _allocExpr _ty =>
    lowerExpr inner

  | .whileExpr cond body _elseBody _ty =>
    let headerLabel ← freshLabel "while.hdr"
    let bodyLabel ← freshLabel "while.body"
    let exitLabel ← freshLabel "while.exit"
    -- Create result slot for while-as-expression
    let resultSlot ← freshReg "wslot."
    emit (.alloca resultSlot _ty)
    let preLoopVars ← snapshotVars
    let preLoopLabel ← getCurrentLabel
    let mut headerPhis : List (String × String × SVal × Ty) := []
    terminateBlock (.br headerLabel)
    startBlock headerLabel
    for (name, val) in preLoopVars do
      let ty := val.ty
      let phiReg ← freshReg "phi."
      setVar name (.reg phiReg ty)
      headerPhis := headerPhis ++ [(name, phiReg, val, ty)]
    let loopInfo : LoopInfo := {
      headerLabel := headerLabel
      exitLabel := exitLabel
      headerPhis := headerPhis
      resultSlot := some resultSlot
      resultTy := _ty
    }
    pushLoop loopInfo
    let condVal ← lowerExpr cond
    terminateBlock (.condBr condVal bodyLabel exitLabel)
    startBlock bodyLabel
    lowerStmts body
    let bodyEndVars ← snapshotVars
    let bodyEndLabel ← getCurrentLabel
    let term ← currentBlockTerminated
    if !term then
      terminateBlock (.br headerLabel)
    let loopInfoFinal ← popLoop
    let mut headerPhiInsts : List SInst := []
    for (name, phiReg, preVal, ty) in headerPhis do
      let mut incoming : List (SVal × String) := [(preVal, preLoopLabel)]
      if !term then
        let backVal := (bodyEndVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
        incoming := incoming ++ [(backVal, bodyEndLabel)]
      match loopInfoFinal with
      | some info =>
        for (contVars, contLabel) in info.continueEdges do
          let contVal := (contVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
          incoming := incoming ++ [(contVal, contLabel)]
      | none => pure ()
      headerPhiInsts := headerPhiInsts ++ [.phi phiReg incoming ty]
    prependInstsToBlock headerLabel headerPhiInsts
    -- For while-as-expression: route normal exit through else block, break goes to final
    let hasBreaks := match loopInfoFinal with
      | some info => !info.breakEdges.isEmpty
      | none => false
    let breakEdges := match loopInfoFinal with
      | some info => info.breakEdges
      | none => []
    if hasBreaks then
      -- Normal exit from header → else block → store else value → final
      -- Break exit → already stored break value → final
      let elseBlockLabel ← freshLabel "while.else"
      let finalLabel ← freshLabel "while.final"
      -- Rewrite: exitLabel becomes the "else" path (from header only)
      -- Break edges already branch to exitLabel, so we need a different approach:
      -- exitLabel receives both paths. Use the resultSlot to distinguish.
      startBlock exitLabel
      for (name, phiReg, _, ty) in headerPhis do
        setVar name (.reg phiReg ty)
      if !breakEdges.isEmpty then
        for (name, phiReg, _, ty) in headerPhis do
          let headerVal := SVal.reg phiReg ty
          let mut exitIncoming : List (SVal × String) := [(headerVal, headerLabel)]
          for (breakVars, breakLabel) in breakEdges do
            let breakVal := (breakVars.find? fun (n, _) => n == name).map (·.2) |>.getD headerVal
            exitIncoming := exitIncoming ++ [(breakVal, breakLabel)]
          let allSame := exitIncoming.all fun (v, _) => match v, headerVal with
            | .reg n1 _, .reg n2 _ => n1 == n2
            | _, _ => false
          if !allSame then
            let exitPhiReg ← freshReg "exit."
            emit (.phi exitPhiReg exitIncoming ty)
            setVar name (.reg exitPhiReg ty)
      -- Use a flag phi: 0 from header (normal), 1 from break
      let flagReg ← freshReg "bflag."
      let mut flagIncoming : List (SVal × String) := [(.intConst 0 .int, headerLabel)]
      for (_, breakLabel) in breakEdges do
        flagIncoming := flagIncoming ++ [(.intConst 1 .int, breakLabel)]
      emit (.phi flagReg flagIncoming .int)
      let flagCmp ← freshReg "bfcmp."
      emit (.binOp flagCmp .eq (.reg flagReg .int) (.intConst 1 .int) .bool)
      terminateBlock (.condBr (.reg flagCmp .bool) finalLabel elseBlockLabel)
      -- Else block: store else value
      startBlock elseBlockLabel
      if !_elseBody.isEmpty then
        lowerStmts _elseBody
        let elseVal ← lastExprVal _elseBody _ty
        emit (.store elseVal (.reg resultSlot _ty))
      terminateBlock (.br finalLabel)
      -- Final block: load result
      startBlock finalLabel
      let loadDst ← freshReg "wload."
      emit (.load loadDst (.reg resultSlot _ty) _ty)
      return .reg loadDst _ty
    else
      -- No breaks: simple exit
      startBlock exitLabel
      for (name, phiReg, _, ty) in headerPhis do
        setVar name (.reg phiReg ty)
      -- Store else value into result slot (loop ended without break)
      if !_elseBody.isEmpty then
        lowerStmts _elseBody
        let elseVal ← lastExprVal _elseBody _ty
        emit (.store elseVal (.reg resultSlot _ty))
      -- Load result from slot
      let loadDst ← freshReg "wload."
      emit (.load loadDst (.reg resultSlot _ty) _ty)
      return .reg loadDst _ty

/-- Extract a value from the last statement of a body, for phi nodes.
    Uses the __last_expr var that lowerStmt(.expr) sets. -/
partial def lastExprVal (body : List CStmt) (ty : Ty) : LowerM SVal := do
  match body.getLast? with
  | some (.expr _) =>
    match ← lookupVar "__last_expr" with
    | some val => pure val
    | none => pure .unit
  | some (.return_ (some _) _) => pure .unit  -- arm returned, won't reach phi
  | some (.letDecl name _ _ _) =>
    match ← lookupVar name with
    | some val => pure val
    | none => pure .unit
  | _ => pure .unit

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
    let v ← lowerExpr e
    setVar "__last_expr" v

  | .ifElse cond then_ else_ =>
    let condVal ← lowerExpr cond
    let thenLabel ← freshLabel "then"
    let elseLabel ← freshLabel "else"
    let mergeLabel ← freshLabel "merge"
    let preIfVars ← snapshotVars
    terminateBlock (.condBr condVal thenLabel elseLabel)
    -- Then block
    startBlock thenLabel
    lowerStmts then_
    let thenEndVars ← snapshotVars
    let thenEndLabel ← getCurrentLabel
    let term1 ← currentBlockTerminated
    if !term1 then
      terminateBlock (.br mergeLabel)
    -- Else block
    -- Restore pre-if vars so else branch starts from same state
    for (name, val) in preIfVars do
      setVar name val
    startBlock elseLabel
    match else_ with
    | some stmts => lowerStmts stmts
    | none => pure ()
    let elseEndVars ← snapshotVars
    let elseEndLabel ← getCurrentLabel
    let term2 ← currentBlockTerminated
    if !term2 then
      terminateBlock (.br mergeLabel)
    -- Merge with phi nodes for variables that differ between branches
    startBlock mergeLabel
    if !term1 || !term2 then
      for (name, preVal) in preIfVars do
        let thenVal := if term1 then none
          else (thenEndVars.find? fun (n, _) => n == name).map (·.2)
        let elseVal := if term2 then none
          else (elseEndVars.find? fun (n, _) => n == name).map (·.2)
        let ty := preVal.ty
        -- Check if any branch modified this variable
        let thenChanged := match thenVal with
          | some v => match v, preVal with
            | .reg n1 _, .reg n2 _ => n1 != n2
            | _, _ => true
          | none => false
        let elseChanged := match elseVal with
          | some v => match v, preVal with
            | .reg n1 _, .reg n2 _ => n1 != n2
            | _, _ => true
          | none => false
        if thenChanged || elseChanged then
          let mut incoming : List (SVal × String) := []
          match thenVal with
          | some v => incoming := incoming ++ [(v, thenEndLabel)]
          | none => pure ()
          match elseVal with
          | some v => incoming := incoming ++ [(v, elseEndLabel)]
          | none => pure ()
          if incoming.length >= 2 then
            let phiReg ← freshReg "if.phi."
            emit (.phi phiReg incoming ty)
            setVar name (.reg phiReg ty)
          else if incoming.length == 1 then
            match incoming.head? with
            | some (v, _) => setVar name v
            | none => pure ()

  | .while_ cond body whileLabel step =>
    let headerLabel ← freshLabel "while.hdr"
    let bodyLabel ← freshLabel "while.body"
    let exitLabel ← freshLabel "while.exit"
    -- For for-loops with a step, create a step block that continue targets
    let hasStep := !step.isEmpty
    let stepLabel ← if hasStep then freshLabel "for.step" else pure headerLabel
    -- Snapshot pre-loop state
    let preLoopVars ← snapshotVars
    let preLoopLabel ← getCurrentLabel
    -- Create header phis for all live variables
    let mut headerPhis : List (String × String × SVal × Ty) := []
    terminateBlock (.br headerLabel)
    startBlock headerLabel
    for (name, val) in preLoopVars do
      let ty := val.ty
      let phiReg ← freshReg "phi."
      setVar name (.reg phiReg ty)
      headerPhis := headerPhis ++ [(name, phiReg, val, ty)]
    let loopInfo : LoopInfo := {
      headerLabel := headerLabel
      exitLabel := exitLabel
      headerPhis := headerPhis
      continueTarget := stepLabel
      loopLabel := whileLabel
    }
    pushLoop loopInfo
    -- Lower condition (uses phi values)
    let condVal ← lowerExpr cond
    terminateBlock (.condBr condVal bodyLabel exitLabel)
    -- Lower body (without step, since step is separate for for-loops)
    startBlock bodyLabel
    if hasStep then
      -- Lower only non-step body
      let bodyWithoutStep := body.take (body.length - step.length)
      lowerStmts bodyWithoutStep
    else
      lowerStmts body
    let bodyEndVars ← snapshotVars
    let bodyEndLabel ← getCurrentLabel
    let term ← currentBlockTerminated
    if !term then
      if hasStep then
        terminateBlock (.br stepLabel)
      else
        terminateBlock (.br headerLabel)
    -- If for-loop has step, create the step block with phi nodes
    if hasStep then
      startBlock stepLabel
      -- Build phi nodes at step block for continue edges
      let continueEdges ← peekContinueEdges
      if !continueEdges.isEmpty then
        for (name, phiReg, _, ty) in headerPhis do
          let bodyVal := (bodyEndVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
          let mut incoming : List (SVal × String) := []
          if !term then
            incoming := incoming ++ [(bodyVal, bodyEndLabel)]
          for (contVars, contLabel) in continueEdges do
            let contVal := (contVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
            incoming := incoming ++ [(contVal, contLabel)]
          if incoming.length >= 2 then
            let stepPhiReg ← freshReg "step.phi."
            emit (.phi stepPhiReg incoming ty)
            setVar name (.reg stepPhiReg ty)
          else if incoming.length == 1 then
            match incoming.head? with
            | some (val, _) => setVar name val
            | none => pure ()
      lowerStmts step
      let stepEndVars ← snapshotVars
      let stepEndLabel ← getCurrentLabel
      let stepTerm ← currentBlockTerminated
      if !stepTerm then
        terminateBlock (.br headerLabel)
      -- Pop loop to get break/continue edges
      let loopInfoFinal ← popLoop
      -- Build header phi instructions (step block is the back-edge source)
      let mut headerPhiInsts : List SInst := []
      for (name, phiReg, preVal, ty) in headerPhis do
        let mut incoming : List (SVal × String) := [(preVal, preLoopLabel)]
        if !stepTerm then
          let stepVal := (stepEndVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
          incoming := incoming ++ [(stepVal, stepEndLabel)]
        headerPhiInsts := headerPhiInsts ++ [.phi phiReg incoming ty]
      prependInstsToBlock headerLabel headerPhiInsts
      -- Build exit block
      startBlock exitLabel
      let breakEdges := match loopInfoFinal with
        | some info => info.breakEdges
        | none => []
      for (name, phiReg, _, ty) in headerPhis do
        setVar name (.reg phiReg ty)
      if !breakEdges.isEmpty then
        for (name, phiReg, _, ty) in headerPhis do
          let headerVal := SVal.reg phiReg ty
          let mut exitIncoming : List (SVal × String) := [(headerVal, headerLabel)]
          for (breakVars, breakLabel) in breakEdges do
            let breakVal := (breakVars.find? fun (n, _) => n == name).map (·.2) |>.getD headerVal
            exitIncoming := exitIncoming ++ [(breakVal, breakLabel)]
          let allSame := exitIncoming.all fun (v, _) => match v, headerVal with
            | .reg n1 _, .reg n2 _ => n1 == n2
            | _, _ => false
          if !allSame then
            let exitPhiReg ← freshReg "exit."
            emit (.phi exitPhiReg exitIncoming ty)
            setVar name (.reg exitPhiReg ty)
    else do
    -- Pop loop to get break/continue edges
    let loopInfoFinal ← popLoop
    -- Build header phi instructions
    -- Incoming edges: (preLoopLabel, preLoopVars) + (bodyEndLabel, bodyEndVars) + continue edges
    let mut headerPhiInsts : List SInst := []
    for (name, phiReg, preVal, ty) in headerPhis do
      let mut incoming : List (SVal × String) := [(preVal, preLoopLabel)]
      -- Back-edge from body end (only if body didn't fully terminate)
      if !term then
        let backVal := (bodyEndVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
        incoming := incoming ++ [(backVal, bodyEndLabel)]
      -- Continue edges
      match loopInfoFinal with
      | some info =>
        for (contVars, contLabel) in info.continueEdges do
          let contVal := (contVars.find? fun (n, _) => n == name).map (·.2) |>.getD (.reg phiReg ty)
          incoming := incoming ++ [(contVal, contLabel)]
      | none => pure ()
      headerPhiInsts := headerPhiInsts ++ [.phi phiReg incoming ty]
    prependInstsToBlock headerLabel headerPhiInsts
    -- Build exit phis if there are break edges
    startBlock exitLabel
    let breakEdges := match loopInfoFinal with
      | some info => info.breakEdges
      | none => []
    -- Restore vars to header phi values (which dominate exit)
    for (name, phiReg, _, ty) in headerPhis do
      setVar name (.reg phiReg ty)
    -- If break edges exist, insert exit phis
    if !breakEdges.isEmpty then
      for (name, phiReg, _, ty) in headerPhis do
        let headerVal := SVal.reg phiReg ty
        let mut exitIncoming : List (SVal × String) := [(headerVal, headerLabel)]
        for (breakVars, breakLabel) in breakEdges do
          let breakVal := (breakVars.find? fun (n, _) => n == name).map (·.2) |>.getD headerVal
          exitIncoming := exitIncoming ++ [(breakVal, breakLabel)]
        -- Only emit phi if values actually differ
        let allSame := exitIncoming.all fun (v, _) => match v, headerVal with
          | .reg n1 _, .reg n2 _ => n1 == n2
          | _, _ => false
        if !allSame then
          let exitPhiReg ← freshReg "exit."
          emit (.phi exitPhiReg exitIncoming ty)
          setVar name (.reg exitPhiReg ty)

  | .fieldAssign obj field value =>
    let fVal ← lowerExpr value
    let tyName := structNameFromTy obj.ty
    let idx ← fieldIndex tyName field
    -- Check if obj is a deref expression (e.g., *p.field = val → GEP into p directly)
    match obj with
    | .deref inner _ =>
      let ptrVal ← lowerExpr inner
      let gepDst ← freshReg
      emit (.gep gepDst ptrVal [.intConst (Int.ofNat idx) .int] value.ty)
      emit (.store fVal (.reg gepDst value.ty))
    | _ =>
    let oVal ← lowerExpr obj
    -- Check if the object is a reference/pointer type (e.g. &mut self)
    let isRefTy := match obj.ty with
      | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => true
      | _ => false
    if isRefTy then
      -- oVal is already a pointer to the struct; GEP + store directly
      let gepDst ← freshReg
      emit (.gep gepDst oVal [.intConst (Int.ofNat idx) .int] value.ty)
      emit (.store fVal (.reg gepDst value.ty))
    else
      -- Struct value: alloca a temporary, mutate the field, load back,
      -- and update the variable map with the new struct value.
      let structTy := obj.ty
      let tmpSlot ← freshReg
      emit (.alloca tmpSlot structTy)
      emit (.store oVal (.reg tmpSlot structTy))
      let gepDst ← freshReg
      emit (.gep gepDst (.reg tmpSlot structTy) [.intConst (Int.ofNat idx) .int] value.ty)
      emit (.store fVal (.reg gepDst value.ty))
      let newVal ← freshReg
      emit (.load newVal (.reg tmpSlot structTy) structTy)
      match obj with
      | .ident name _ => setVar name (.reg newVal structTy)
      | _ => pure ()

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

  | .break_ value breakLabel =>
    match ← findLoopByLabel breakLabel with
    | some info =>
      -- Store break value into result slot (for while-as-expression)
      match value, info.resultSlot with
      | some valExpr, some slot =>
        let bVal ← lowerExpr valExpr
        emit (.store bVal (.reg slot info.resultTy))
      | _, _ => pure ()
      let vars ← snapshotVars
      let label ← getCurrentLabel
      addBreakEdgeToLoop vars label info.exitLabel
      terminateBlock (.br info.exitLabel)
    | none => pure ()

  | .continue_ contLabel =>
    match ← findLoopByLabel contLabel with
    | some info =>
      let target := if info.continueTarget != "" then info.continueTarget else info.headerLabel
      let vars ← snapshotVars
      let label ← getCurrentLabel
      addContinueEdge vars label
      terminateBlock (.br target)
    | none => pure ()

  | .defer body =>
    let _ ← lowerExpr body

  | .borrowIn var ref _region isMut refTy body =>
    -- Create a memory slot for the borrowed variable, set ref to point to it
    let curVal ← lookupVar var
    let innerTy := match refTy with
      | .ref t | .refMut t | .ptrMut t | .ptrConst t => t
      | _ => refTy
    let slot ← freshReg "borrow."
    emit (.alloca slot innerTy)
    match curVal with
    | some cv => emit (.store cv (.reg slot innerTy))
    | none => pure ()
    setVar ref (.reg slot innerTy)
    lowerStmts body
    -- For mutable borrows, load back the value and update the original variable
    if isMut then
      let loadBack ← freshReg "wb."
      emit (.load loadBack (.reg slot innerTy) innerTy)
      setVar var (.reg loadBack innerTy)

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

def lowerFn (f : CFnDef) (structDefs : List CStructDef) (enumDefs : List CEnumDef) : Except String SFnDef :=
  let initState : LowerState := {
    blocks := []
    currentLabel := "entry"
    currentInsts := []
    labelCounter := 0
    regCounter := 0
    vars := f.params.map fun (n, ty) => (n, SVal.reg n ty)
    stringLits := []
    structDefs := structDefs
    enumDefs := enumDefs
    loopStack := []
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
  -- Skip generic functions (non-empty typeParams); only their monomorphized
  -- specializations should be lowered.
  let concreteFns := m.functions.filter fun f => f.typeParams.isEmpty
  let fns := concreteFns.filterMap fun f =>
    match lowerFn f m.structs m.enums with
    | .ok sfn => some sfn
    | .error _ => none
  -- Collect string literals from lowered functions
  let globals := concreteFns.foldl (fun acc f =>
    let initState : LowerState := {
      blocks := [], currentLabel := "entry", currentInsts := []
      labelCounter := 0, regCounter := 0
      vars := f.params.map fun (n, ty) => (n, SVal.reg n ty)
      stringLits := []
      structDefs := m.structs
      enumDefs := m.enums
      loopStack := []
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
