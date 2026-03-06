import Concrete.AST

namespace Concrete

/-! ## Type Checker with Linear Variable Tracking

Pipeline: Source → Lexer → Parser → AST → **Check** → Codegen → LLVM IR → clang

Linearity rules (matching Concrete/Rust design):
- Primitives (Int, Bool, Uint, Float64) are implicitly Copy.
- Struct-typed variables are linear by default.
- A linear variable must be consumed exactly once before scope exit.
- Consuming = passing as a function argument (by value).
- Field access does NOT consume the struct.
- Double-consume (use after move) is an error.
- Unconsumed linear variable at scope exit is an error.
- In if/else: both branches must agree on consumption state.
- Cannot consume a linear variable declared outside a loop from inside a loop.
-/

-- ============================================================
-- Types and Environment
-- ============================================================

inductive VarState where
  | unconsumed
  | consumed
  deriving Repr, BEq

structure FnSig where
  params : List (String × Ty)
  retTy : Ty
  deriving Repr

structure VarInfo where
  ty : Ty
  state : VarState
  isCopy : Bool
  loopDepth : Nat
  deriving Repr

structure TypeEnv where
  vars : List (String × VarInfo)
  structs : List StructDef
  functions : List FnSig
  fnNames : List (String × Nat)
  loopDepth : Nat
  deriving Repr

abbrev CheckM := ExceptT String (StateM TypeEnv)

-- ============================================================
-- Helpers
-- ============================================================

private def enumerateList (l : List α) (idx : Nat := 0) : List (Nat × α) :=
  match l with
  | [] => []
  | a :: rest => (idx, a) :: enumerateList rest (idx + 1)

private def listGetIdx (l : List α) (idx : Nat) : Option α :=
  match l, idx with
  | [], _ => none
  | a :: _, 0 => some a
  | _ :: rest, n + 1 => listGetIdx rest n

private def tyToString : Ty → String
  | .int => "Int"
  | .uint => "Uint"
  | .bool => "Bool"
  | .float64 => "Float64"
  | .unit => "()"
  | .named n => n

def getEnv : CheckM TypeEnv := get
def setEnv (env : TypeEnv) : CheckM Unit := set env

/-- Is this type Copy (non-linear)? Primitives are Copy; structs are linear. -/
def isCopyType (ty : Ty) : CheckM Bool := do
  match ty with
  | .int | .uint | .bool | .float64 | .unit => return true
  | .named _ => return false

def lookupVarInfo (name : String) : CheckM (Option VarInfo) := do
  let env ← getEnv
  return env.vars.lookup name

def lookupVarTy (name : String) : CheckM (Option Ty) := do
  match ← lookupVarInfo name with
  | some info => return some info.ty
  | none => return none

def addVar (name : String) (ty : Ty) : CheckM Unit := do
  let env ← getEnv
  let copy ← isCopyType ty
  let info : VarInfo := { ty, state := .unconsumed, isCopy := copy, loopDepth := env.loopDepth }
  setEnv { env with vars := (name, info) :: env.vars }

def lookupStruct (name : String) : CheckM (Option StructDef) := do
  let env ← getEnv
  return env.structs.find? fun sd => sd.name == name

def lookupStructField (structName : String) (fieldName : String) : CheckM (Option Ty) := do
  match ← lookupStruct structName with
  | some sd =>
    match sd.fields.find? fun f => f.name == fieldName with
    | some f => return some f.ty
    | none => return none
  | none => return none

def lookupFn (name : String) : CheckM (Option FnSig) := do
  let env ← getEnv
  match env.fnNames.lookup name with
  | some idx => return listGetIdx env.functions idx
  | none => return none

def expectTy (expected actual : Ty) (ctx : String) : CheckM Unit := do
  if expected == actual then return ()
  else throw s!"type mismatch in {ctx}: expected {tyToString expected}, got {tyToString actual}"

-- ============================================================
-- Linearity: consume and check
-- ============================================================

/-- Consume a linear variable (mark it as consumed).
    Errors on use-after-move, or consuming an outer var inside a loop. -/
def consumeVar (name : String) : CheckM Unit := do
  let env ← getEnv
  match env.vars.lookup name with
  | none => throw s!"use of undeclared variable '{name}'"
  | some info =>
    if info.isCopy then return ()  -- Copy types are never consumed
    match info.state with
    | .consumed =>
      throw s!"linear variable '{name}' used after move"
    | .unconsumed =>
      -- Loop depth check
      if info.loopDepth < env.loopDepth then
        throw s!"cannot consume linear variable '{name}' inside a loop (declared outside the loop)"
      -- Mark consumed
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := .consumed })
        else (n, vi)
      setEnv { env with vars := vars' }

/-- Check that all linear variables in the given name list are consumed.
    Called at function scope exit. -/
def checkScopeExit (varNames : List String) : CheckM Unit := do
  let env ← getEnv
  for name in varNames do
    match env.vars.lookup name with
    | some info =>
      if !info.isCopy && info.state == .unconsumed then
        throw s!"linear variable '{name}' was never consumed"
    | none => pure ()

-- ============================================================
-- Type checking expressions and statements
-- ============================================================

mutual

partial def checkExpr (e : Expr) : CheckM Ty := do
  match e with
  | .intLit _ => return .int
  | .boolLit _ => return .bool
  | .ident name =>
    match ← lookupVarInfo name with
    | some info =>
      -- Reading a variable (not consuming). Check it's not already consumed.
      if !info.isCopy && info.state == .consumed then
        throw s!"linear variable '{name}' used after move"
      return info.ty
    | none => throw s!"use of undeclared variable '{name}'"
  | .binOp op lhs rhs =>
    let lTy ← checkExpr lhs
    let rTy ← checkExpr rhs
    match op with
    | .add | .sub | .mul | .div | .mod =>
      expectTy .int lTy "left operand of arithmetic"
      expectTy .int rTy "right operand of arithmetic"
      return .int
    | .eq | .neq | .lt | .gt | .leq | .geq =>
      expectTy lTy rTy "comparison operands"
      return .bool
    | .and_ | .or_ =>
      expectTy .bool lTy "left operand of logical op"
      expectTy .bool rTy "right operand of logical op"
      return .bool
  | .unaryOp op operand =>
    let ty ← checkExpr operand
    match op with
    | .neg =>
      expectTy .int ty "negation operand"
      return .int
    | .not_ =>
      expectTy .bool ty "not operand"
      return .bool
  | .call fnName args =>
    match ← lookupFn fnName with
    | some sig =>
      if args.length != sig.params.length then
        throw s!"function '{fnName}' expects {sig.params.length} arguments, got {args.length}"
      -- Check each argument. Passing a linear variable by value consumes it.
      for (arg, (pName, pTy)) in args.zip sig.params do
        let argTy ← checkExpr arg
        expectTy pTy argTy s!"argument '{pName}' of '{fnName}'"
        -- If arg is a bare identifier of a linear type, consume it
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return sig.retTy
    | none => throw s!"call to undeclared function '{fnName}'"
  | .paren inner => checkExpr inner
  | .structLit name fields =>
    match ← lookupStruct name with
    | some sd =>
      for sf in sd.fields do
        match fields.find? fun (fn, _) => fn == sf.name with
        | some (_, expr) =>
          let exprTy ← checkExpr expr
          expectTy sf.ty exprTy s!"field '{sf.name}' of struct '{name}'"
        | none => throw s!"missing field '{sf.name}' in struct literal '{name}'"
      for (fn, _) in fields do
        match sd.fields.find? fun sf => sf.name == fn with
        | some _ => pure ()
        | none => throw s!"unknown field '{fn}' in struct literal '{name}'"
      return .named name
    | none => throw s!"unknown struct type '{name}'"
  | .fieldAccess obj field =>
    let objTy ← checkExpr obj
    match objTy with
    | .named structName =>
      -- Field access does NOT consume the struct (Phase 1 simplification)
      match ← lookupStructField structName field with
      | some ty => return ty
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | _ => throw s!"field access on non-struct type"

partial def checkStmt (stmt : Stmt) (retTy : Ty) : CheckM Unit := do
  match stmt with
  | .letDecl name _mutable ty value =>
    let valTy ← checkExpr value
    match ty with
    | some declTy => expectTy declTy valTy s!"let binding '{name}'"
    | none => pure ()
    let finalTy := match ty with | some t => t | none => valTy
    addVar name finalTy
  | .assign name value =>
    match ← lookupVarTy name with
    | some varTy =>
      let valTy ← checkExpr value
      expectTy varTy valTy s!"assignment to '{name}'"
    | none => throw s!"assignment to undeclared variable '{name}'"
  | .return_ (some value) =>
    let valTy ← checkExpr value
    expectTy retTy valTy "return value"
    -- Returning a linear variable consumes it
    match value with
    | .ident varName => consumeVar varName
    | _ => pure ()
  | .return_ none =>
    expectTy .unit retTy "return (void)"
  | .expr e =>
    let _ ← checkExpr e
    pure ()
  | .ifElse cond thenBody elseBody =>
    let condTy ← checkExpr cond
    expectTy .bool condTy "if condition"
    -- Snapshot variable states before branches
    let envBefore ← getEnv
    -- Check then branch
    checkStmts thenBody retTy
    let envAfterThen ← getEnv
    -- Restore env and check else branch
    setEnv envBefore
    match elseBody with
    | some stmts =>
      checkStmts stmts retTy
      let envAfterElse ← getEnv
      -- Merge: both branches must agree on consumption state of linear vars
      mergeVarStates envBefore.vars envAfterThen.vars envAfterElse.vars
    | none =>
      -- No else branch: then branch must not consume any linear var
      -- (because the implicit else branch leaves them unconsumed)
      checkNoBranchConsumption envBefore.vars envAfterThen.vars "if-without-else"
  | .while_ cond body =>
    let condTy ← checkExpr cond
    expectTy .bool condTy "while condition"
    -- Increment loop depth for the body
    let env ← getEnv
    setEnv { env with loopDepth := env.loopDepth + 1 }
    checkStmts body retTy
    -- Restore loop depth
    let env' ← getEnv
    setEnv { env' with loopDepth := env.loopDepth }
  | .fieldAssign obj field value =>
    let objTy ← checkExpr obj
    match objTy with
    | .named structName =>
      match ← lookupStructField structName field with
      | some fieldTy =>
        let valTy ← checkExpr value
        expectTy fieldTy valTy s!"field assignment '{structName}.{field}'"
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | _ => throw s!"field assignment on non-struct type"

partial def checkStmts (stmts : List Stmt) (retTy : Ty) : CheckM Unit := do
  for stmt in stmts do
    checkStmt stmt retTy

/-- After if/else, check both branches agree on linear var consumption.
    Both must have consumed the same set of linear variables. -/
partial def mergeVarStates
    (before : List (String × VarInfo))
    (afterThen : List (String × VarInfo))
    (afterElse : List (String × VarInfo)) : CheckM Unit := do
  for (name, infoBefore) in before do
    if infoBefore.isCopy then continue
    let thenState := match afterThen.lookup name with
      | some info => info.state
      | none => infoBefore.state
    let elseState := match afterElse.lookup name with
      | some info => info.state
      | none => infoBefore.state
    if thenState != elseState then
      throw s!"linear variable '{name}' consumed in one branch of if/else but not the other"
    -- Apply the agreed-upon state
    if thenState != infoBefore.state then
      let env ← getEnv
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := thenState })
        else (n, vi)
      setEnv { env with vars := vars' }

/-- For if-without-else: the then branch must not consume any linear var
    that existed before the if. -/
partial def checkNoBranchConsumption
    (before : List (String × VarInfo))
    (afterThen : List (String × VarInfo))
    (ctx : String) : CheckM Unit := do
  for (name, infoBefore) in before do
    if infoBefore.isCopy then continue
    if infoBefore.state != .unconsumed then continue
    let thenState := match afterThen.lookup name with
      | some info => info.state
      | none => infoBefore.state
    if thenState == .consumed then
      throw s!"linear variable '{name}' consumed in {ctx} then-branch (no else branch to match)"

end

def checkFn (f : FnDef) : CheckM Unit := do
  -- Save env state (vars from previous functions shouldn't leak)
  let envBefore ← getEnv
  -- Add params to env. Linear params are "consumed" by being received —
  -- the caller consumed them by passing them, so the function body
  -- doesn't need to further consume them.
  let mut paramNames : List String := []
  for p in f.params do
    addVar p.name p.ty
    paramNames := paramNames ++ [p.name]
  -- Check body
  checkStmts f.body f.retTy
  -- Check linearity: only LOCAL let-bindings of linear type must be consumed.
  -- Function parameters are already consumed by being received (ownership transfer).
  let envAfter ← getEnv
  let localVars := envAfter.vars.filter fun (name, _) =>
    !paramNames.contains name && (envBefore.vars.lookup name).isNone
  let localNames := localVars.map fun (name, _) => name
  checkScopeExit localNames
  -- Restore env (remove this function's locals)
  setEnv envBefore

def checkModule (m : Module) : Except String Unit :=
  let fnSigs : List FnSig := m.functions.map fun f =>
    { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy }
  let fnNames : List (String × Nat) := enumerateList m.functions |>.map fun (idx, f) => (f.name, idx)
  let initEnv : TypeEnv :=
    { vars := [], structs := m.structs, functions := fnSigs, fnNames := fnNames, loopDepth := 0 }
  let result := m.functions.foldlM (fun () f => checkFn f) () |>.run initEnv |>.run
  match result with
  | (.ok (), _) => .ok ()
  | (.error e, _) => .error e

end Concrete
