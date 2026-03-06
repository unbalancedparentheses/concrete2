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
    match env.typeAliases.lookup name with
    | some resolved => return resolved
    | none => return ty
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
  | .named _ => return false
  | .generic _ _ => return false  -- Generic instantiations are linear
  | .typeVar _ => return false
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
  let copy ← isCopyType ty
  let info : VarInfo := { ty, state := .unconsumed, isCopy := copy, loopDepth := env.loopDepth, mutable }
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
  | .floatLit _ => return .float64
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
      return info.ty
    | none => throw s!"use of undeclared variable '{name}'"
  | .binOp op lhs rhs =>
    let lTy ← checkExpr lhs
    let rTy ← checkExpr rhs
    match op with
    | .add | .sub | .mul | .div | .mod =>
      -- Allow arithmetic on any matching integer, float, or char type
      if isIntegerType lTy && lTy == rTy then return lTy
      else if isFloatType lTy && lTy == rTy then return lTy
      else if lTy == .char && rTy == .char then return .char
      -- Allow pointer + integer (pointer arithmetic)
      else if isPointerType lTy && isIntegerType rTy then return lTy
      else do
        expectTy lTy rTy "arithmetic operand types"
        return lTy
    | .eq | .neq | .lt | .gt | .leq | .geq =>
      -- Allow comparison on matching types
      if lTy == rTy then return .bool
      else if isIntegerType lTy && isIntegerType rTy then return .bool
      else do
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
      if isIntegerType ty || isFloatType ty then return ty
      else do
        expectTy .int ty "negation operand"
        return .int
    | .not_ =>
      expectTy .bool ty "not operand"
      return .bool
  | .call fnName _typeArgs args =>
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
  | .structLit name _typeArgs fields =>
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
    -- Auto-deref through references
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    match innerTy with
    | .named structName =>
      -- Field access does NOT consume the struct
      match ← lookupStructField structName field with
      | some ty => return ty
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | _ => throw s!"field access on non-struct type"
  | .enumLit enumName variant _typeArgs fields =>
    match ← lookupEnum enumName with
    | some ed =>
      match ed.variants.find? fun v => v.name == variant with
      | some ev =>
        for sf in ev.fields do
          match fields.find? fun (fn, _) => fn == sf.name with
          | some (_, expr) =>
            let exprTy ← checkExpr expr
            expectTy sf.ty exprTy s!"field '{sf.name}' of {enumName}#{variant}"
          | none => throw s!"missing field '{sf.name}' in {enumName}#{variant}"
        for (fn, _) in fields do
          match ev.fields.find? fun sf => sf.name == fn with
          | some _ => pure ()
          | none => throw s!"unknown field '{fn}' in {enumName}#{variant}"
        return .named enumName
      | none => throw s!"unknown variant '{variant}' in enum '{enumName}'"
    | none => throw s!"unknown enum type '{enumName}'"
  | .match_ scrutinee arms =>
    let scrTy ← checkExpr scrutinee
    match scrTy with
    | .named enumName =>
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
          | .mk armEnum armVariant bindings body =>
            if armEnum != enumName then
              throw s!"match arm has enum '{armEnum}' but scrutinee is '{enumName}'"
            match ed.variants.find? fun v => v.name == armVariant with
            | some ev =>
              if seenVariants.contains armVariant then
                throw s!"duplicate match arm for variant '{armVariant}'"
              seenVariants := seenVariants ++ [armVariant]
              if bindings.length != ev.fields.length then
                throw s!"variant '{armVariant}' has {ev.fields.length} fields but arm binds {bindings.length}"
            | none => throw s!"unknown variant '{armVariant}' in enum '{enumName}'"
        -- Check all variants covered
        for v in ed.variants do
          if !seenVariants.contains v.name then
            throw s!"non-exhaustive match: missing variant '{v.name}'"
        -- Linearity across arms: snapshot env, check each arm, ensure all agree
        let envBefore ← getEnv
        let mut firstArmVars : Option (List (String × VarInfo)) := none
        for arm in arms do
          match arm with
          | .mk _armEnum armVariant bindings body =>
            setEnv envBefore
            -- Bind variant fields in scope
            let ev := (ed.variants.find? fun v => v.name == armVariant).get!
            for (binding, sf) in bindings.zip ev.fields do
              addVar binding sf.ty
            let curEnv ← getEnv
            checkStmts body curEnv.currentRetTy
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
                if state1 != state2 then
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
    | _ => throw s!"match scrutinee must be an enum type"
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
      let firstTy ← checkExpr first
      for e in rest do
        let eTy ← checkExpr e
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
  | .methodCall obj methodName _typeArgs args =>
    let objTy ← checkExpr obj
    -- Auto-deref through references
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | _ => ""
    if typeName == "" then throw s!"method call on non-named type"
    -- Look up method in function table (mangled name: TypeName_method)
    let mangledName := typeName ++ "_" ++ methodName
    match ← lookupFn mangledName with
    | some sig =>
      -- First param is self; check remaining args
      let methodParams := sig.params.drop 1
      if args.length != methodParams.length then
        throw s!"method '{methodName}' expects {methodParams.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip methodParams do
        let argTy ← checkExpr arg
        expectTy pTy argTy s!"argument '{pName}' of '{methodName}'"
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return sig.retTy
    | none => throw s!"no method '{methodName}' on type '{typeName}'"
  | .staticMethodCall typeName methodName _typeArgs args =>
    let mangledName := typeName ++ "_" ++ methodName
    match ← lookupFn mangledName with
    | some sig =>
      if args.length != sig.params.length then
        throw s!"static method '{methodName}' expects {sig.params.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip sig.params do
        let argTy ← checkExpr arg
        expectTy pTy argTy s!"argument '{pName}' of '{typeName}::{methodName}'"
        match arg with
        | .ident varName => consumeVar varName
        | _ => pure ()
      return sig.retTy
    | none => throw s!"no method '{methodName}' on type '{typeName}'"

partial def checkStmt (stmt : Stmt) (retTy : Ty) : CheckM Unit := do
  match stmt with
  | .letDecl name mutable ty value =>
    let valTy ← checkExpr value
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
      let valTy ← checkExpr value
      expectTy info.ty valTy s!"assignment to '{name}'"
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
        let valTy ← checkExpr value
        expectTy fieldTy valTy s!"field assignment '{structName}.{field}'"
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | _ => throw s!"field assignment on non-struct type"
  | .derefAssign target value =>
    let targetTy ← checkExpr target
    match targetTy with
    | .refMut inner =>
      let valTy ← checkExpr value
      expectTy inner valTy "deref assignment"
    | .ptrMut inner =>
      let valTy ← checkExpr value
      expectTy inner valTy "deref assignment"
    | _ => throw s!"cannot assign through non-mutable reference"
  | .arrayIndexAssign arr index value =>
    let arrTy ← checkExpr arr
    let idxTy ← checkExpr index
    if !isIntegerType idxTy then
      throw s!"type mismatch: array index must be an integer type"
    match arrTy with
    | .array elemTy _ =>
      let valTy ← checkExpr value
      expectTy elemTy valTy "array element assignment"
    | _ => throw s!"type mismatch: indexing into non-array type"

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
  -- Set current return type
  setEnv { envBefore with currentRetTy := f.retTy }
  -- Add params to env. Linear params are "consumed" by being received.
  let mut paramNames : List String := []
  for p in f.params do
    addVar p.name p.ty true  -- params are always mutable for now
    paramNames := paramNames ++ [p.name]
  -- Check body
  checkStmts f.body f.retTy
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
    { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy }
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
  let externOffset := builtinOffset + builtinSigs.length
  let externNames : List (String × Nat) :=
    (enumerateList m.externFns).map fun (idx, ef) => (ef.name, externOffset + idx)
  -- Collect all impl block methods
  let allImplBlocks := importedImplBlocks ++ m.implBlocks
  let allTraitImpls := importedTraitImpls ++ m.traitImpls
  let implMethodSigs : List (String × FnSig) := allImplBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f =>
      let mangledName := ib.typeName ++ "_" ++ f.name
      let sig : FnSig := { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy }
      (mangledName, sig)
  ) []
  let traitImplMethodSigs : List (String × FnSig) := allTraitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f =>
      let mangledName := tb.typeName ++ "_" ++ f.name
      let sig : FnSig := { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy }
      (mangledName, sig)
  ) []
  let implSigList := (implMethodSigs ++ traitImplMethodSigs).map Prod.snd
  let implOffset := externOffset + externSigs.length
  let implNames : List (String × Nat) :=
    (enumerateList (implMethodSigs ++ traitImplMethodSigs)).map fun (idx, (name, _)) => (name, implOffset + idx)
  let allSigs := importedSigList ++ fnSigs ++ builtinSigs ++ externSigs ++ implSigList
  let importedNames : List (String × Nat) :=
    (enumerateList importedFnSigs).map fun (idx, (name, _)) => (name, idx)
  let fnNames : List (String × Nat) :=
    (enumerateList m.functions).map fun (idx, f) => (f.name, baseOffset + idx)
  let allNames := importedNames ++ fnNames ++ builtinNames ++ externNames ++ implNames
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
  let allImplMethods := allImplBlocks.foldl (fun acc ib => acc ++ ib.methods) []
  let allTraitImplMethods := allTraitImpls.foldl (fun acc tb => acc ++ tb.methods) []
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
  let go := modules.foldlM
    (init := ([] : List (String × ExportEntry)))
    fun exportTable m => do
      let (impFns, impStructs, impEnums, impImpls, impTraitImpls) ← resolveImports m exportTable
      checkModule m impFns impStructs impEnums impImpls impTraitImpls
      let pubFns := (m.functions.filter fun (f : FnDef) => f.isPublic).map fun (f : FnDef) =>
        (f.name, { params := f.params.map fun (p : Param) => (p.name, p.ty), retTy := f.retTy : FnSig })
      let pubStructs := m.structs.filter fun (s : StructDef) => s.isPublic
      let pubEnums := m.enums.filter fun (e : EnumDef) => e.isPublic
      return exportTable ++ [(m.name, (pubFns, pubStructs, pubEnums, m.implBlocks, m.traitImpls))]
  go.map fun _ => ()

end Concrete
