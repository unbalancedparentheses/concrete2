import Concrete.AST

namespace Concrete

/-! ## Type Checker with Linear Variable Tracking

Pipeline: Source → Lexer → Parser → AST → **Check** → Codegen → LLVM IR → clang

Linearity rules (matching Concrete/Rust design):
- Primitives (Int, Bool, Uint, Float64, i32, etc.) are implicitly Copy.
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
  | unconsumed  -- never touched
  | used        -- read/borrowed but not moved
  | consumed    -- moved by value
  deriving Repr, BEq

structure FnSig where
  params : List (String × Ty)
  retTy : Ty
  typeParams : List String := []
  capParams : List String := []    -- capability variables
  capSet : CapSet := .empty        -- declared capabilities
  deriving Repr

structure VarInfo where
  ty : Ty
  state : VarState
  isCopy : Bool
  loopDepth : Nat
  borrowCount : Nat := 0
  mutBorrowed : Bool := false
  mutable : Bool := true  -- whether the variable was declared with mut
  deriving Repr

structure TypeEnv where
  vars : List (String × VarInfo)
  structs : List StructDef
  enums : List EnumDef
  functions : List FnSig
  fnNames : List (String × Nat)
  loopDepth : Nat
  currentRetTy : Ty := .unit
  typeAliases : List (String × Ty) := []
  constants : List (String × Ty) := []
  currentTypeParams : List String := []  -- active function's type params
  currentCapSet : CapSet := .empty       -- current function's capability set
  currentFnName : String := ""           -- current function name (for error messages)
  lastExprIsLinearClosure : Bool := false  -- set by closure checking, read by letDecl
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
  | .int => "i64"
  | .uint => "u64"
  | .i8 => "i8"
  | .i16 => "i16"
  | .i32 => "i32"
  | .u8 => "u8"
  | .u16 => "u16"
  | .u32 => "u32"
  | .bool => "bool"
  | .float64 => "f64"
  | .float32 => "f32"
  | .char => "char"
  | .unit => "()"
  | .string => "String"
  | .named n => n
  | .ref inner => "&" ++ tyToString inner
  | .refMut inner => "&mut " ++ tyToString inner
  | .generic name args => name ++ "<" ++ ", ".intercalate (args.map tyToString) ++ ">"
  | .typeVar name => name
  | .array elem size => "[" ++ tyToString elem ++ "; " ++ toString size ++ "]"
  | .ptrMut inner => "*mut " ++ tyToString inner
  | .ptrConst inner => "*const " ++ tyToString inner
  | .fn_ params capSet retTy =>
    let paramStr := ", ".intercalate (params.map tyToString)
    let capStr := match capSet with
      | .empty => ""
      | .concrete caps => " with(" ++ ", ".intercalate caps ++ ")"
      | .var name => " with(" ++ name ++ ")"
      | _ => " with(...)"
    "fn(" ++ paramStr ++ ")" ++ capStr ++ " -> " ++ tyToString retTy
  | .unknown => "<unknown>"

/-- Is this an integer type (any size)? -/
def isIntegerType : Ty → Bool
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
  | _ => false

/-- Is this a signed integer type? -/
def isSignedInt : Ty → Bool
  | .int | .i8 | .i16 | .i32 => true
  | _ => false

/-- Is this a float type? -/
def isFloatType : Ty → Bool
  | .float32 | .float64 => true
  | _ => false

/-- Is this a numeric type (int or float)? -/
def isNumericType : Ty → Bool
  | ty => isIntegerType ty || isFloatType ty

/-- Is this a pointer type? -/
def isPointerType : Ty → Bool
  | .ptrMut _ | .ptrConst _ => true
  | _ => false

def getEnv : CheckM TypeEnv := get
def setEnv (env : TypeEnv) : CheckM Unit := set env

/-- Resolve type aliases. -/
def resolveType (ty : Ty) : CheckM Ty := do
  match ty with
  | .named name =>
    let env ← getEnv
    -- Check if it's a type parameter first
    if env.currentTypeParams.contains name then return .typeVar name
    else
      match env.typeAliases.lookup name with
      | some resolved => return resolved
      | none => return ty
  | .ref inner =>
    let inner' ← resolveType inner
    return .ref inner'
  | .refMut inner =>
    let inner' ← resolveType inner
    return .refMut inner'
  | .ptrMut inner =>
    let inner' ← resolveType inner
    return .ptrMut inner'
  | .ptrConst inner =>
    let inner' ← resolveType inner
    return .ptrConst inner'
  | .array elem n =>
    let elem' ← resolveType elem
    return .array elem' n
  | .generic name args =>
    let args' ← args.mapM resolveType
    return .generic name args'
  | .fn_ params capSet retTy =>
    let params' ← params.mapM resolveType
    let retTy' ← resolveType retTy
    return .fn_ params' capSet retTy'
  | _ => return ty

/-- Is this type Copy (non-linear)? Primitives are Copy; structs are linear. -/
def isCopyType (ty : Ty) : CheckM Bool := do
  match ty with
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => return true
  | .bool | .float64 | .float32 | .char | .unit => return true
  | .string => return false    -- String is linear
  | .ref _ => return true      -- References are Copy
  | .refMut _ => return false  -- Mutable refs are not Copy (exclusive)
  | .ptrMut _ | .ptrConst _ => return true  -- Raw pointers are Copy
  | .fn_ _ _ _ => return true  -- Function types: Copy by default, linear closures tracked separately
  | .unknown => return true
  | .named _ => return false
  | .generic _ _ => return false  -- Generic instantiations are linear
  | .typeVar _ => return true  -- Type variables are treated as Copy in generic context
  | .array t _ => isCopyType t  -- Array of copy types is copy

def lookupVarInfo (name : String) : CheckM (Option VarInfo) := do
  let env ← getEnv
  return env.vars.lookup name

def lookupVarTy (name : String) : CheckM (Option Ty) := do
  match ← lookupVarInfo name with
  | some info => return some info.ty
  | none => return none

def addVar (name : String) (ty : Ty) (mutable : Bool := true) : CheckM Unit := do
  let env ← getEnv
  let mut copy ← isCopyType ty
  -- If the last expression was a linear closure, override copy to false
  if env.lastExprIsLinearClosure then
    copy := false
    modify fun env => { env with lastExprIsLinearClosure := false }
  let info : VarInfo := { ty, state := .unconsumed, isCopy := copy, loopDepth := env.loopDepth, mutable }
  let env ← getEnv
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

def lookupEnum (name : String) : CheckM (Option EnumDef) := do
  let env ← getEnv
  return env.enums.find? fun ed => ed.name == name

def lookupEnumVariant (enumName : String) (variantName : String) : CheckM (Option EnumVariant) := do
  match ← lookupEnum enumName with
  | some ed => return ed.variants.find? fun v => v.name == variantName
  | none => return none

def lookupFn (name : String) : CheckM (Option FnSig) := do
  let env ← getEnv
  match env.fnNames.lookup name with
  | some idx => return listGetIdx env.functions idx
  | none => return none

def expectTy (expected actual : Ty) (ctx : String) : CheckM Unit := do
  if expected == actual then return ()
  -- Resolve type aliases and try again
  let expectedR ← resolveType expected
  let actualR ← resolveType actual
  if expectedR == actualR then return ()
  -- .string is compatible with .named "String"
  else if (expectedR == .string && actualR == .named "String")
       || (expectedR == .named "String" && actualR == .string) then return ()
  else throw s!"type mismatch in {ctx}: expected {tyToString expected}, got {tyToString actual}"

-- ============================================================
-- Capability checking
-- ============================================================

/-- Check that caller's capabilities are a superset of callee's capabilities.
    This is the core of the effect system: if f calls g, f must have g's caps. -/
def checkCapabilities (calleeName : String) (calleeCapSet : CapSet) : CheckM Unit := do
  let env ← getEnv
  let callerCapSet := env.currentCapSet
  -- Get concrete caps from callee
  let (calleeCaps, _calleeVars) := calleeCapSet.normalize
  -- Get concrete caps from caller
  let (callerCaps, _callerVars) := callerCapSet.normalize
  -- Check each callee cap exists in caller
  for cap in calleeCaps do
    unless callerCaps.contains cap do
      throw s!"function '{calleeName}' requires capability '{cap}' but '{env.currentFnName}' does not declare it"

-- ============================================================
-- Linearity: consume and check
-- ============================================================

/-- Mark a linear variable as used (read/borrowed but not moved). -/
def useVar (name : String) : CheckM Unit := do
  let env ← getEnv
  match env.vars.lookup name with
  | none => pure ()  -- not found (might be a constant or function)
  | some info =>
    if info.isCopy then return ()
    if info.state == .unconsumed then
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := .used })
        else (n, vi)
      setEnv { env with vars := vars' }

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
    | .unconsumed | .used =>
      -- Loop depth check
      if info.loopDepth < env.loopDepth then
        throw s!"cannot consume linear variable '{name}' inside a loop (declared outside the loop)"
      -- Mark consumed
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := .consumed })
        else (n, vi)
      setEnv { env with vars := vars' }

/-- Check that all linear variables in the given name list are consumed or used.
    Only errors on variables that were never touched at all.
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
-- Type substitution for generics
-- ============================================================

/-- Substitute type variables using a mapping. -/
private def substTy (mapping : List (String × Ty)) : Ty → Ty
  | .named name => match mapping.lookup name with | some t => t | none => .named name
  | .typeVar name => match mapping.lookup name with | some t => t | none => .typeVar name
  | .ref inner => .ref (substTy mapping inner)
  | .refMut inner => .refMut (substTy mapping inner)
  | .ptrMut inner => .ptrMut (substTy mapping inner)
  | .ptrConst inner => .ptrConst (substTy mapping inner)
  | .array elem n => .array (substTy mapping elem) n
  | .generic name args => .generic name (args.map (substTy mapping))
  | ty => ty

-- ============================================================
-- Type checking expressions and statements
-- ============================================================

mutual

partial def checkExpr (e : Expr) (hint : Option Ty := none) : CheckM Ty := do
  match e with
  | .intLit _ =>
    -- Use hint to infer integer literal type (resolve aliases first)
    match hint with
    | some ty =>
      let tyR ← resolveType ty
      if isIntegerType tyR || tyR == .char then return tyR
      else
        match tyR with
        | .typeVar _ => return tyR  -- Type variables accept integer literals
        | _ => return .int
    | none => return .int
  | .floatLit _ =>
    match hint with
    | some ty =>
      let tyR ← resolveType ty
      if isFloatType tyR then return tyR else return .float64
    | none => return .float64
  | .boolLit _ => return .bool
  | .strLit _ => return .string
  | .charLit _ => return .char
  | .ident name =>
    -- First check if it's a constant
    let env ← getEnv
    match env.constants.lookup name with
    | some ty => return ty
    | none =>
    match ← lookupVarInfo name with
    | some info =>
      -- Reading a variable (not consuming). Check it's not already consumed.
      if !info.isCopy && info.state == .consumed then
        throw s!"linear variable '{name}' used after move"
      useVar name
      return info.ty
    | none => throw s!"use of undeclared variable '{name}'"
  | .binOp op lhs rhs =>
    -- Check lhs first (with hint), then use its type as hint for rhs
    let lTy ← checkExpr lhs hint
    let lTyR ← resolveType lTy
    let rTy ← checkExpr rhs (some lTyR)
    let rTyR ← resolveType rTy
    let isTypeVarL := match lTyR with | .typeVar _ => true | _ => false
    let isTypeVarR := match rTyR with | .typeVar _ => true | _ => false
    match op with
    | .add | .sub | .mul | .div | .mod =>
      if isIntegerType lTyR && lTyR == rTyR then return lTy
      else if isFloatType lTyR && lTyR == rTyR then return lTy
      else if lTyR == .char && rTyR == .char then return .char
      else if isPointerType lTyR && isIntegerType rTyR then return lTy
      else if isTypeVarL || isTypeVarR then return lTy
      else do
        expectTy lTyR rTyR "arithmetic operand types"
        return lTy
    | .eq | .neq | .lt | .gt | .leq | .geq =>
      if lTyR == rTyR then return .bool
      else if isIntegerType lTyR && isIntegerType rTyR then return .bool
      else if isTypeVarL || isTypeVarR then return .bool
      else do
        expectTy lTyR rTyR "comparison operands"
        return .bool
    | .and_ | .or_ =>
      expectTy .bool lTyR "left operand of logical op"
      expectTy .bool rTyR "right operand of logical op"
      return .bool
  | .unaryOp op operand =>
    let ty ← checkExpr operand hint
    match op with
    | .neg =>
      if isIntegerType ty || isFloatType ty then return ty
      else do
        expectTy .int ty "negation operand"
        return .int
    | .not_ =>
      expectTy .bool ty "not operand"
      return .bool
  | .call fnName typeArgs args =>
    -- Check if this is a closure call (variable with fn_ type)
    let closureVarTy ← lookupVarTy fnName
    match closureVarTy with
    | some (.fn_ paramTys closureCapSet closureRetTy) =>
      -- Closure call: check capabilities
      checkCapabilities fnName closureCapSet
      -- Check argument count
      if args.length != paramTys.length then
        throw s!"closure '{fnName}' expects {paramTys.length} arguments, got {args.length}"
      -- Check each argument type
      for (arg, pTy) in args.zip paramTys do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument of closure call '{fnName}'"
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      -- Calling a closure consumes it (if linear)
      consumeVar fnName
      return closureRetTy
    | _ =>
    match ← lookupFn fnName with
    | some sig =>
      -- Check capabilities: caller must have callee's caps
      checkCapabilities fnName sig.capSet
      -- Build type substitution from typeArgs + sig.typeParams
      let mapping := sig.typeParams.zip typeArgs
      let paramTypes := sig.params.map fun (n, t) => (n, substTy mapping t)
      let retTy := substTy mapping sig.retTy
      if args.length != paramTypes.length then
        throw s!"function '{fnName}' expects {paramTypes.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip paramTypes do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{fnName}'"
        -- If arg is a bare identifier of a linear type, consume it
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return retTy
    | none =>
      -- sizeof intrinsic
      if fnName == "sizeof" || fnName.endsWith "_sizeof" then return .uint
      else throw s!"call to undeclared function '{fnName}'"
  | .paren inner => checkExpr inner hint
  | .structLit name typeArgs fields =>
    match ← lookupStruct name with
    | some sd =>
      -- Build type substitution from struct type params + provided type args
      let mapping := sd.typeParams.zip typeArgs
      for sf in sd.fields do
        let fieldTy := substTy mapping sf.ty
        match fields.find? fun (fn, _) => fn == sf.name with
        | some (_, expr) =>
          let exprTy ← checkExpr expr (some fieldTy)
          expectTy fieldTy exprTy s!"field '{sf.name}' of struct '{name}'"
        | none =>
          -- Unions allow partial initialization (only one field set)
          if !sd.isUnion then
            throw s!"missing field '{sf.name}' in struct literal '{name}'"
      for (fn, _) in fields do
        match sd.fields.find? fun sf => sf.name == fn with
        | some _ => pure ()
        | none => throw s!"unknown field '{fn}' in struct literal '{name}'"
      if typeArgs.isEmpty then return .named name
      else return .generic name typeArgs
    | none => throw s!"unknown struct type '{name}'"
  | .fieldAccess obj field =>
    let objTy ← checkExpr obj
    -- Auto-deref through references
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    -- Extract struct name and type args for generic type substitution
    let (structName, typeArgs) := match innerTy with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | .string => ("String", [])
      | _ => ("", [])
    if structName == "" then throw s!"field access on non-struct type"
    else
      match ← lookupStruct structName with
      | some sd =>
        match sd.fields.find? fun f => f.name == field with
        | some f =>
          let mapping := sd.typeParams.zip typeArgs
          return substTy mapping f.ty
        | none => throw s!"struct '{structName}' has no field '{field}'"
      | none => throw s!"field access on non-struct type"
  | .enumLit enumName variant typeArgs fields =>
    match ← lookupEnum enumName with
    | some ed =>
      let mapping := ed.typeParams.zip typeArgs
      match ed.variants.find? fun v => v.name == variant with
      | some ev =>
        for sf in ev.fields do
          let fieldTy := substTy mapping sf.ty
          match fields.find? fun (fn, _) => fn == sf.name with
          | some (_, expr) =>
            let exprTy ← checkExpr expr (some fieldTy)
            expectTy fieldTy exprTy s!"field '{sf.name}' of {enumName}#{variant}"
          | none => throw s!"missing field '{sf.name}' in {enumName}#{variant}"
        for (fn, _) in fields do
          match ev.fields.find? fun sf => sf.name == fn with
          | some _ => pure ()
          | none => throw s!"unknown field '{fn}' in {enumName}#{variant}"
        if typeArgs.isEmpty then return .named enumName
        else return .generic enumName typeArgs
      | none => throw s!"unknown variant '{variant}' in enum '{enumName}'"
    | none => throw s!"unknown enum type '{enumName}'"
  | .match_ scrutinee arms =>
    let scrTy ← checkExpr scrutinee
    -- Auto-deref through references for match
    let innerTy := match scrTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let innerTyR ← resolveType innerTy
    let (enumName, _enumTypeArgs) := match innerTyR with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | _ => ("", [])
    if enumName != "" then
      match ← lookupEnum enumName with
      | some ed =>
        -- Consume scrutinee if it's a linear ident
        match scrutinee with
        | .ident varName => consumeVar varName
        | _ => pure ()
        -- Check exhaustiveness: every variant must appear, no duplicates
        let mut seenVariants : List String := []
        for arm in arms do
          match arm with
          | .mk armEnum armVariant bindings _body =>
            if armEnum != enumName then
              throw s!"match arm has enum '{armEnum}' but scrutinee is '{enumName}'"
            match ed.variants.find? fun v => v.name == armVariant with
            | some ev =>
              if seenVariants.contains armVariant then
                throw s!"duplicate match arm for variant '{armVariant}'"
              seenVariants := seenVariants ++ [armVariant]
              -- Allow 0 bindings (ignore payload) or exact match
              if bindings.length != 0 && bindings.length != ev.fields.length then
                throw s!"variant '{armVariant}' has {ev.fields.length} fields but arm binds {bindings.length}"
            | none => throw s!"unknown variant '{armVariant}' in enum '{enumName}'"
          | .litArm _ _ => pure ()
          | .varArm _ _ => pure ()
        -- Check all variants covered
        for v in ed.variants do
          if !seenVariants.contains v.name then
            throw s!"non-exhaustive match: missing variant '{v.name}'"
        -- Linearity across arms: snapshot env, check each arm, ensure all agree
        let envBefore ← getEnv
        let mut firstArmVars : Option (List (String × VarInfo)) := none
        for arm in arms do
          setEnv envBefore
          match arm with
          | .mk _armEnum armVariant bindings body =>
            -- Bind variant fields in scope
            let ev := (ed.variants.find? fun v => v.name == armVariant).get!
            for (binding, sf) in bindings.zip ev.fields do
              addVar binding sf.ty
            let curEnv ← getEnv
            checkStmts body curEnv.currentRetTy
          | .litArm _val body =>
            checkStmts body envBefore.currentRetTy
          | .varArm binding body =>
            addVar binding innerTyR
            checkStmts body envBefore.currentRetTy
          let envAfterArm ← getEnv
          match firstArmVars with
          | none => firstArmVars := some envAfterArm.vars
          | some firstVars =>
            -- Check agreement on pre-existing variables
            for (name, infoBefore) in envBefore.vars do
              if infoBefore.isCopy then continue
              let state1 := match firstVars.lookup name with
                | some info => info.state
                | none => infoBefore.state
              let state2 := match envAfterArm.vars.lookup name with
                | some info => info.state
                | none => infoBefore.state
              let consumed1 := state1 == .consumed
              let consumed2 := state2 == .consumed
              if consumed1 != consumed2 then
                throw s!"match arms disagree on consumption of '{name}'"
        -- Apply the final state from first arm (they all agree)
        match firstArmVars with
        | some vars =>
          let env ← getEnv
          let vars' := env.vars.map fun (n, vi) =>
            match vars.lookup n with
            | some info => (n, { vi with state := info.state })
            | none => (n, vi)
          setEnv { envBefore with vars := vars' }
        | none => setEnv envBefore
        return .named enumName
      | none => throw s!"unknown enum type '{enumName}'"
    else
      -- Value-pattern match (integer/bool literals, variable bindings)
      match scrutinee with
      | .ident varName => useVar varName
      | _ => pure ()
      let envBefore ← getEnv
      let mut resultTy := scrTy
      for arm in arms do
        setEnv envBefore
        match arm with
        | .litArm _val body =>
          checkStmts body envBefore.currentRetTy
        | .varArm binding body =>
          addVar binding scrTy
          checkStmts body envBefore.currentRetTy
        | .mk _ _ _ body =>
          checkStmts body envBefore.currentRetTy
      setEnv envBefore
      return resultTy
  | .borrow inner =>
    let innerTy ← checkExpr inner
    -- Check the variable is not moved or already mutably borrowed
    match inner with
    | .ident varName =>
      match ← lookupVarInfo varName with
      | some info =>
        if !info.isCopy && info.state == .consumed then
          throw s!"cannot borrow '{varName}': already moved"
        if info.mutBorrowed then
          throw s!"cannot borrow '{varName}': already mutably borrowed"
        -- Increment borrow count
        let env ← getEnv
        let vars' := env.vars.map fun (n, vi) =>
          if n == varName then (n, { vi with borrowCount := vi.borrowCount + 1 })
          else (n, vi)
        setEnv { env with vars := vars' }
      | none => throw s!"use of undeclared variable '{varName}'"
    | _ => pure ()
    return .ref innerTy
  | .borrowMut inner =>
    let innerTy ← checkExpr inner
    match inner with
    | .ident varName =>
      match ← lookupVarInfo varName with
      | some info =>
        if !info.isCopy && info.state == .consumed then
          throw s!"cannot borrow '{varName}': already moved"
        if info.borrowCount > 0 then
          throw s!"cannot mutably borrow '{varName}': already borrowed"
        if info.mutBorrowed then
          throw s!"cannot mutably borrow '{varName}': already mutably borrowed"
        if !info.mutable then
          throw s!"cannot take mutable borrow of immutable variable '{varName}'"
        let env ← getEnv
        let vars' := env.vars.map fun (n, vi) =>
          if n == varName then (n, { vi with mutBorrowed := true })
          else (n, vi)
        setEnv { env with vars := vars' }
      | none => throw s!"use of undeclared variable '{varName}'"
    | _ => pure ()
    return .refMut innerTy
  | .deref inner =>
    let innerTy ← checkExpr inner
    match innerTy with
    | .ref t => return t
    | .refMut t => return t
    | .ptrMut t => return t
    | .ptrConst t => return t
    | _ => throw s!"cannot dereference non-reference type"
  | .try_ inner =>
    let innerTy ← checkExpr inner
    -- Consume the inner expression if it's a variable
    match inner with
    | .ident name => consumeVar name
    | _ => pure ()
    match innerTy with
    | .named enumName =>
      match ← lookupEnum enumName with
      | some ed =>
        let okVariant := ed.variants.find? fun v => v.name == "Ok"
        let errVariant := ed.variants.find? fun v => v.name == "Err"
        match okVariant, errVariant with
        | some ok, some _ =>
          -- Function must return the same Result type
          let env ← getEnv
          expectTy innerTy env.currentRetTy "try (?) operator: function must return same Result type"
          -- Return the type of the first field in Ok variant
          match ok.fields.head? with
          | some f => return f.ty
          | none => throw s!"Ok variant of '{enumName}' has no value field"
        | _, _ => throw s!"? operator requires an enum with Ok and Err variants"
      | none => throw s!"unknown enum type '{enumName}'"
    | _ => throw "? operator requires a Result enum type"
  | .arrayLit elems =>
    match elems with
    | [] => throw "array literal cannot be empty"
    | first :: rest =>
      -- Use hint to determine element type (e.g. [i32; N] → elements are i32)
      let elemHint := match hint with
        | some (.array t _) => some t
        | _ => none
      let firstTy ← checkExpr first elemHint
      for e in rest do
        let eTy ← checkExpr e (some firstTy)
        expectTy firstTy eTy "array element"
      return .array firstTy elems.length
  | .arrayIndex arr index =>
    let arrTy ← checkExpr arr
    let idxTy ← checkExpr index
    if !isIntegerType idxTy then
      throw s!"type mismatch: array index must be an integer type, got {tyToString idxTy}"
    match arrTy with
    | .array elemTy _ => return elemTy
    | _ => throw s!"type mismatch: indexing into non-array type {tyToString arrTy}"
  | .cast inner targetTy =>
    let innerTy ← checkExpr inner
    -- Allow casts between: integers (any size), bool, floats, pointers, char
    let valid :=
      (isIntegerType innerTy && isIntegerType targetTy) ||
      (isIntegerType innerTy && targetTy == .bool) ||
      (innerTy == .bool && isIntegerType targetTy) ||
      (isIntegerType innerTy && isFloatType targetTy) ||
      (isFloatType innerTy && isIntegerType targetTy) ||
      (isFloatType innerTy && isFloatType targetTy) ||
      (isIntegerType innerTy && targetTy == .char) ||
      (innerTy == .char && isIntegerType targetTy) ||
      (isPointerType innerTy && isPointerType targetTy) ||
      (isPointerType innerTy && isIntegerType targetTy) ||
      (isIntegerType innerTy && isPointerType targetTy) ||
      -- Allow array to pointer cast
      (match innerTy with | .array _ _ => isPointerType targetTy | _ => false) ||
      -- Allow pointer to reference cast
      (isPointerType innerTy && match targetTy with | .ref _ | .refMut _ => true | _ => false) ||
      -- Allow reference to pointer cast
      (match innerTy with | .ref _ | .refMut _ => isPointerType targetTy | _ => false) ||
      (innerTy == targetTy)
    if !valid then throw s!"cannot cast {tyToString innerTy} to {tyToString targetTy}"
    return targetTy
  | .methodCall obj methodName typeArgs args =>
    let objTy ← checkExpr obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    if typeName == "" then throw s!"method call on non-named type"
    let mangledName := typeName ++ "_" ++ methodName
    match ← lookupFn mangledName with
    | some sig =>
      -- Check capabilities
      checkCapabilities (typeName ++ "." ++ methodName) sig.capSet
      -- Build type mapping from object's generic type args + explicit call typeArgs
      let objTypeArgs := match innerTy with
        | .generic _ args => args
        | _ => []
      let implTypeParams := sig.typeParams.take objTypeArgs.length
      let methodTypeParams := sig.typeParams.drop objTypeArgs.length
      let mapping := implTypeParams.zip objTypeArgs ++ methodTypeParams.zip typeArgs
      let methodParams := (sig.params.drop 1).map fun (n, t) => (n, substTy mapping t)
      let retTy := substTy mapping sig.retTy
      if args.length != methodParams.length then
        throw s!"method '{methodName}' expects {methodParams.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip methodParams do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{methodName}'"
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return retTy
    | none => throw s!"no method '{methodName}' on type '{typeName}'"
  | .staticMethodCall typeName methodName typeArgs args =>
    let mangledName := typeName ++ "_" ++ methodName
    match ← lookupFn mangledName with
    | some sig =>
      -- Check capabilities
      checkCapabilities (typeName ++ "::" ++ methodName) sig.capSet
      let mapping := sig.typeParams.zip typeArgs
      let paramTypes := sig.params.map fun (n, t) => (n, substTy mapping t)
      let retTy := substTy mapping sig.retTy
      if args.length != paramTypes.length then
        throw s!"static method '{methodName}' expects {paramTypes.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip paramTypes do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{typeName}::{methodName}'"
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return retTy
    | none => throw s!"no method '{methodName}' on type '{typeName}'"
  | .closure params capSet retTy body _captures _isLinear =>
    let env ← getEnv
    -- Determine expected types from hint (bidirectional inference)
    let expectedParamTys : List Ty := match hint with
      | some (.fn_ eTys _ _) => eTys
      | _ => []
    let expectedCapSet : Option CapSet := match hint with
      | some (.fn_ _ eCapSet _) => some eCapSet
      | _ => none
    let expectedRetTy : Option Ty := match hint with
      | some (.fn_ _ _ eRetTy) => some eRetTy
      | _ => none
    -- Resolve params: use explicit types or infer from hint
    let mut resolvedParams : List Param := []
    for (idx, p) in enumerateList params do
      if p.ty == .unknown then
        match listGetIdx expectedParamTys idx with
        | some eTy => resolvedParams := resolvedParams ++ [{ name := p.name, ty := eTy }]
        | none => throw s!"cannot infer type of closure parameter '{p.name}' without type context"
      else
        resolvedParams := resolvedParams ++ [{ name := p.name, ty := p.ty }]
    -- Determine the return type
    let closureRetTy := match retTy with
      | some t => t
      | none => match expectedRetTy with
        | some t => t
        | none => .unit
    -- Determine capabilities
    let closureCapSet := if capSet != .empty then capSet
      else match expectedCapSet with
        | some cs => cs
        | none => .empty
    -- Analyze captures: find free variables in the body
    let paramNames := resolvedParams.map (fun p => p.name)
    let freeVars := collectFreeVars body paramNames
    let mut captureList : List (String × CaptureMode) := []
    let mut closureIsLinear := false
    for varName in freeVars do
      match env.vars.lookup varName with
      | some info =>
        if info.isCopy then
          captureList := captureList ++ [(varName, .copy)]
        else
          captureList := captureList ++ [(varName, .move)]
          closureIsLinear := true
          -- Mark the original variable as consumed
          consumeVar varName
      | none => pure ()  -- Must be a global function, ignore
    -- Create a fresh scope for the closure body
    let savedEnv ← getEnv
    -- Add closure params as variables
    for p in resolvedParams do
      addVar p.name p.ty true
    -- Add captures as variables in the closure scope
    for (capName, capMode) in captureList do
      match savedEnv.vars.lookup capName with
      | some info =>
        let isCopy := capMode == .copy
        let varInfo : VarInfo := {
          ty := info.ty, state := .unconsumed, isCopy := isCopy,
          loopDepth := 0, mutable := false
        }
        modify fun env => { env with vars := (capName, varInfo) :: env.vars }
      | none => pure ()
    -- Set capability context for the closure body
    let bodyEnv ← getEnv
    let env1 := { bodyEnv with currentCapSet := closureCapSet }
    modify fun _ => { env1 with currentFnName := "<closure>", currentRetTy := closureRetTy }
    -- Check the body
    checkStmts body closureRetTy
    -- Check unconsumed linear captures
    let envAfter ← getEnv
    for (capName, capMode) in captureList do
      if capMode == .move then
        match envAfter.vars.lookup capName with
        | some info =>
          if info.state != .consumed then
            throw s!"linear capture '{capName}' was never consumed in closure"
        | none => pure ()
    -- Restore the environment (but keep consumed state for move-captures)
    modify fun _ => savedEnv
    -- Signal to letDecl that this closure is linear
    if closureIsLinear then
      modify fun env => { env with lastExprIsLinearClosure := true }
    -- Build the function type
    let paramTys := resolvedParams.map (fun p => p.ty)
    return .fn_ paramTys closureCapSet closureRetTy

partial def checkStmt (stmt : Stmt) (retTy : Ty) : CheckM Unit := do
  match stmt with
  | .letDecl name mutable ty value =>
    let valTy ← checkExpr value ty
    match ty with
    | some declTy => expectTy declTy valTy s!"let binding '{name}'"
    | none => pure ()
    let finalTy := match ty with | some t => t | none => valTy
    addVar name finalTy mutable
  | .assign name value =>
    match ← lookupVarInfo name with
    | some info =>
      if !info.mutable then
        throw s!"cannot assign to immutable variable '{name}'"
      let valTy ← checkExpr value (some info.ty)
      expectTy info.ty valTy s!"assignment to '{name}'"
    | none => throw s!"assignment to undeclared variable '{name}'"
  | .return_ (some value) =>
    let valTy ← checkExpr value (some retTy)
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
    -- Allow bool or integer types as conditions
    if condTy != .bool && !isIntegerType condTy then
      throw s!"if condition must be bool, got {tyToString condTy}"
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
      checkNoBranchConsumption envBefore.vars envAfterThen.vars "if-without-else"
  | .while_ cond body =>
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throw s!"while condition must be bool, got {tyToString condTy}"
    -- Increment loop depth for the body
    let env ← getEnv
    setEnv { env with loopDepth := env.loopDepth + 1 }
    checkStmts body retTy
    -- Restore loop depth
    let env' ← getEnv
    setEnv { env' with loopDepth := env.loopDepth }
  | .forLoop init cond step body =>
    -- Init
    match init with
    | some initStmt => checkStmt initStmt retTy
    | none => pure ()
    -- Condition
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throw s!"for condition must be bool, got {tyToString condTy}"
    -- Body + step in loop scope
    let env ← getEnv
    setEnv { env with loopDepth := env.loopDepth + 1 }
    checkStmts body retTy
    match step with
    | some stepStmt => checkStmt stepStmt retTy
    | none => pure ()
    let env' ← getEnv
    setEnv { env' with loopDepth := env.loopDepth }
  | .fieldAssign obj field value =>
    let objTy ← checkExpr obj
    -- Auto-deref through references
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    match innerTy with
    | .named structName =>
      match ← lookupStructField structName field with
      | some fieldTy =>
        let valTy ← checkExpr value (some fieldTy)
        expectTy fieldTy valTy s!"field assignment '{structName}.{field}'"
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | _ => throw s!"field assignment on non-struct type"
  | .derefAssign target value =>
    let targetTy ← checkExpr target
    match targetTy with
    | .refMut inner =>
      let valTy ← checkExpr value (some inner)
      expectTy inner valTy "deref assignment"
    | .ptrMut inner =>
      let valTy ← checkExpr value (some inner)
      expectTy inner valTy "deref assignment"
    | _ => throw s!"cannot assign through non-mutable reference"
  | .arrayIndexAssign arr index value =>
    let arrTy ← checkExpr arr
    let idxTy ← checkExpr index
    if !isIntegerType idxTy then
      throw s!"type mismatch: array index must be an integer type"
    match arrTy with
    | .array elemTy _ =>
      let valTy ← checkExpr value (some elemTy)
      expectTy elemTy valTy "array element assignment"
    | _ => throw s!"type mismatch: indexing into non-array type"
  | .break_ _value =>
    let env ← getEnv
    if env.loopDepth == 0 then
      throw "break outside of loop"
    -- Check all linear variables declared in the loop body are consumed
    for (name, info) in env.vars do
      if !info.isCopy && info.state != .consumed && info.loopDepth >= env.loopDepth then
        throw s!"break would skip unconsumed linear variable '{name}'"
  | .continue_ =>
    let env ← getEnv
    if env.loopDepth == 0 then
      throw "continue outside of loop"
    -- Check all linear variables declared in the loop body are consumed
    for (name, info) in env.vars do
      if !info.isCopy && info.state != .consumed && info.loopDepth >= env.loopDepth then
        throw s!"continue would skip unconsumed linear variable '{name}'"

partial def checkStmts (stmts : List Stmt) (retTy : Ty) : CheckM Unit := do
  for stmt in stmts do
    checkStmt stmt retTy

/-- After if/else, check both branches agree on linear var consumption. -/
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
    -- Both consumed or both not-consumed (used/unconsumed are equivalent here)
    let thenConsumed := thenState == .consumed
    let elseConsumed := elseState == .consumed
    if thenConsumed != elseConsumed then
      throw s!"linear variable '{name}' consumed in one branch of if/else but not the other"
    -- Apply the most progressed state (consumed > used > unconsumed)
    let mergedState := if thenState == .consumed then .consumed
      else if thenState == .used || elseState == .used then .used
      else infoBefore.state
    if mergedState != infoBefore.state then
      let env ← getEnv
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := mergedState })
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
    if infoBefore.state == .consumed then continue
    let thenState := match afterThen.lookup name with
      | some info => info.state
      | none => infoBefore.state
    if thenState == .consumed then
      throw s!"linear variable '{name}' consumed in {ctx} then-branch (no else branch to match)"

end

private def resolveTypeParams (ty : Ty) (typeParams : List String) : Ty :=
  match ty with
  | .named n => if typeParams.contains n then .typeVar n else ty
  | .ref t => .ref (resolveTypeParams t typeParams)
  | .refMut t => .refMut (resolveTypeParams t typeParams)
  | .ptrMut t => .ptrMut (resolveTypeParams t typeParams)
  | .ptrConst t => .ptrConst (resolveTypeParams t typeParams)
  | .array t n => .array (resolveTypeParams t typeParams) n
  | .generic name args => .generic name (args.map fun a => resolveTypeParams a typeParams)
  | _ => ty

def checkFn (f : FnDef) : CheckM Unit := do
  -- Save env state (vars from previous functions shouldn't leak)
  let envBefore ← getEnv
  -- Resolve type parameter names: .named "T" -> .typeVar "T"
  let retTy := resolveTypeParams f.retTy f.typeParams
  -- Set current return type, type params, and capability context
  let env1 := { envBefore with currentRetTy := retTy, currentTypeParams := f.typeParams }
  let env2 := { env1 with currentCapSet := f.capSet }
  setEnv { env2 with currentFnName := f.name }
  -- Add params to env. Linear params are "consumed" by being received.
  let mut paramNames : List String := []
  for p in f.params do
    let paramTy := resolveTypeParams p.ty f.typeParams
    addVar p.name paramTy true  -- params are always mutable for now
    paramNames := paramNames ++ [p.name]
  -- Check body
  checkStmts f.body retTy
  -- Check linearity: only LOCAL let-bindings of linear type must be consumed.
  let envAfter ← getEnv
  let localVars := envAfter.vars.filter fun (name, _) =>
    !paramNames.contains name && (envBefore.vars.lookup name).isNone
  let localNames := localVars.map fun (name, _) => name
  checkScopeExit localNames
  -- Restore env (remove this function's locals)
  setEnv envBefore

def checkModule (m : Module) (importedFnSigs : List (String × FnSig) := [])
    (importedStructs : List StructDef := []) (importedEnums : List EnumDef := [])
    (importedImplBlocks : List ImplBlock := []) (importedTraitImpls : List ImplTraitBlock := [])
    : Except String Unit :=
  let fnSigs : List FnSig := m.functions.map fun f =>
    { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy, typeParams := f.typeParams,
      capParams := f.capParams, capSet := f.capSet }
  -- Add extern fn signatures
  let externSigs : List FnSig := m.externFns.map fun ef =>
    { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy }
  let importedSigList := importedFnSigs.map Prod.snd
  let baseOffset := importedSigList.length
  -- Built-in functions for strings
  let builtinSigs : List FnSig := [
    { params := [("s", .ref .string)], retTy := .int },
    { params := [("a", .string), ("b", .string)], retTy := .string },
    { params := [("s", .ref .string)], retTy := .unit },
    { params := [("s", .string)], retTy := .unit }
  ]
  let builtinOffset := baseOffset + fnSigs.length
  let builtinNames : List (String × Nat) := [
    ("string_length", builtinOffset),
    ("string_concat", builtinOffset + 1),
    ("print_string", builtinOffset + 2),
    ("drop_string", builtinOffset + 3)
  ]
  -- Add submodule functions/extern fns with qualified names (mod_fn)
  let submoduleSigs : List FnSig := m.submodules.foldl (fun acc (sub : Module) =>
    acc ++ (sub.functions.map fun f =>
      { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy, typeParams := f.typeParams,
        capParams := f.capParams, capSet := f.capSet : FnSig })
    ++ (sub.externFns.map fun ef =>
      { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy : FnSig })
  ) []
  let submoduleNames : List (String × Nat) := m.submodules.foldl (fun (acc : List (String × Nat)) (sub : Module) =>
    let baseIdx := baseOffset + fnSigs.length + builtinSigs.length + externSigs.length + acc.length
    let fnNames' : List (String × Nat) := (enumerateList sub.functions).map fun (idx, f) =>
      (sub.name ++ "_" ++ f.name, baseIdx + idx)
    let efNames : List (String × Nat) := (enumerateList sub.externFns).map fun (idx, ef) =>
      (sub.name ++ "_" ++ ef.name, baseIdx + sub.functions.length + idx)
    acc ++ fnNames' ++ efNames
  ) []
  let externOffset := builtinOffset + builtinSigs.length
  let externNames : List (String × Nat) :=
    (enumerateList m.externFns).map fun (idx, ef) => (ef.name, externOffset + idx)
  -- Collect all impl block methods
  let allImplBlocks := importedImplBlocks ++ m.implBlocks
  let allTraitImpls := importedTraitImpls ++ m.traitImpls
  let implMethodSigs : List (String × FnSig) := allImplBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f =>
      let mangledName := ib.typeName ++ "_" ++ f.name
      let allTypeParams := ib.typeParams ++ f.typeParams
      let sig : FnSig := { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy,
                            typeParams := allTypeParams, capParams := f.capParams, capSet := f.capSet }
      (mangledName, sig)
  ) []
  let traitImplMethodSigs : List (String × FnSig) := allTraitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f =>
      let mangledName := tb.typeName ++ "_" ++ f.name
      let allTypeParams := tb.typeParams ++ f.typeParams
      let sig : FnSig := { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy,
                            typeParams := allTypeParams, capParams := f.capParams, capSet := f.capSet }
      (mangledName, sig)
  ) []
  let implSigList := (implMethodSigs ++ traitImplMethodSigs).map Prod.snd
  let implOffset := externOffset + externSigs.length
  let implNames : List (String × Nat) :=
    (enumerateList (implMethodSigs ++ traitImplMethodSigs)).map fun (idx, (name, _)) => (name, implOffset + idx)
  let allSigs := importedSigList ++ fnSigs ++ builtinSigs ++ externSigs ++ submoduleSigs ++ implSigList
  let importedNames : List (String × Nat) :=
    (enumerateList importedFnSigs).map fun (idx, (name, _)) => (name, idx)
  let fnNames : List (String × Nat) :=
    (enumerateList m.functions).map fun (idx, f) => (f.name, baseOffset + idx)
  let allNames := importedNames ++ fnNames ++ builtinNames ++ externNames ++ submoduleNames ++ implNames
  let allStructs := importedStructs ++ m.structs
  let allEnums := importedEnums ++ m.enums
  -- Build type aliases map
  let typeAliasMap : List (String × Ty) := m.typeAliases.map fun ta => (ta.name, ta.targetTy)
  -- Build constants map
  let constantsMap : List (String × Ty) := m.constants.map fun c => (c.name, c.ty)
  let initEnv : TypeEnv :=
    { vars := [], structs := allStructs, enums := allEnums, functions := allSigs,
      fnNames := allNames, loopDepth := 0, typeAliases := typeAliasMap, constants := constantsMap }
  -- Validate trait impls
  let traitCheck := m.traitImpls.foldlM (init := ()) fun () tb => do
    match m.traits.find? fun (td : TraitDef) => td.name == tb.traitName with
    | none => Except.error s!"unknown trait '{tb.traitName}'"
    | some td =>
      td.methods.foldlM (init := ()) fun () (sig : FnSigDef) =>
        match tb.methods.find? fun (f : FnDef) => f.name == sig.name with
        | none => Except.error s!"trait impl for '{tb.typeName}' is missing method '{sig.name}'"
        | some f =>
          if sig.retTy != f.retTy then
            Except.error s!"method '{sig.name}' signature does not match trait definition: expected return type {tyToString sig.retTy}, got {tyToString f.retTy}"
          else Except.ok ()
  match traitCheck with
  | .error e => .error e
  | .ok () =>
  -- Merge impl block type params into each method's typeParams
  let allImplMethods := allImplBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f =>
      { f with typeParams := ib.typeParams ++ f.typeParams }
  ) []
  let allTraitImplMethods := allTraitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f =>
      { f with typeParams := tb.typeParams ++ f.typeParams }
  ) []
  let allMethodDefs := allImplMethods ++ allTraitImplMethods
  let result := (m.functions ++ allMethodDefs).foldlM (fun () f => checkFn f) () |>.run initEnv |>.run
  match result with
  | (.ok (), _) => .ok ()
  | (.error e, _) => .error e

abbrev ExportEntry := List (String × FnSig) × List StructDef × List EnumDef × List ImplBlock × List ImplTraitBlock

/-- Resolve imports for a module: find requested symbols in export tables. -/
private def resolveImports (m : Module)
    (exportTable : List (String × ExportEntry))
    : Except String (List (String × FnSig) × List StructDef × List EnumDef × List ImplBlock × List ImplTraitBlock) :=
  m.imports.foldlM (init := ([], [], [], [], [])) fun (fns, structs, enums, impls, trImpls) imp =>
    match exportTable.lookup imp.moduleName with
    | none => .error s!"unknown module '{imp.moduleName}'"
    | some (pubFns, pubStructs, pubEnums, pubImpls, pubTraitImpls) =>
      imp.symbols.foldlM (init := (fns, structs, enums, impls, trImpls)) fun (fns, structs, enums, impls, trImpls) sym =>
        match pubFns.find? fun (n, _) => n == sym with
        | some pair => .ok (fns ++ [pair], structs, enums, impls, trImpls)
        | none =>
          match pubStructs.find? fun sd => sd.name == sym with
          | some sd =>
            let structImpls := pubImpls.filter fun ib => ib.typeName == sym
            let structTraitImpls := pubTraitImpls.filter fun tb => tb.typeName == sym
            .ok (fns, structs ++ [sd], enums, impls ++ structImpls, trImpls ++ structTraitImpls)
          | none =>
            match pubEnums.find? fun ed => ed.name == sym with
            | some ed => .ok (fns, structs, enums ++ [ed], impls, trImpls)
            | none => .error s!"'{sym}' is not public in module '{imp.moduleName}'"

/-- Check a multi-module program. Processes modules in order, building export tables. -/
def checkProgram (modules : List Module) : Except String Unit :=
  -- First pass: build export table from all modules (allows forward references)
  let exportTable : List (String × ExportEntry) := modules.foldl (fun acc m =>
    let pubFns := m.functions.map fun (f : FnDef) =>
      (f.name, { params := f.params.map fun (p : Param) => (p.name, p.ty), retTy := f.retTy,
                  capParams := f.capParams, capSet := f.capSet : FnSig })
    let subExports : List (String × ExportEntry) := m.submodules.map fun (sub : Module) =>
      let subFns : List (String × FnSig) := sub.functions.map fun (f : FnDef) =>
        (f.name, { params := f.params.map fun (p : Param) => (p.name, p.ty), retTy := f.retTy,
                    capParams := f.capParams, capSet := f.capSet : FnSig })
      let entry : ExportEntry := (subFns, sub.structs, sub.enums, sub.implBlocks, sub.traitImpls)
      (m.name ++ "." ++ sub.name, entry)
    acc ++ [(m.name, (pubFns, m.structs, m.enums, m.implBlocks, m.traitImpls))] ++ subExports
  ) []
  -- Second pass: resolve imports and type-check each module
  let go := modules.foldlM (init := ()) fun () m => do
    let (impFns, impStructs, impEnums, impImpls, impTraitImpls) ← resolveImports m exportTable
    checkModule m impFns impStructs impEnums impImpls impTraitImpls
  go

end Concrete
