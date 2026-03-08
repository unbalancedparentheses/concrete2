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
  | reserved    -- reserved by defer (cannot be moved, can be read)
  | frozen      -- frozen by borrow block (cannot be used at all)
  deriving Repr, BEq

structure FnSig where
  params : List (String × Ty)
  retTy : Ty
  typeParams : List String := []
  typeBounds : List (String × List String) := []  -- type param bounds
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
  borrowedFrom : Option String := none
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
  allFnSigs : List (String × FnSig) := []  -- all function signatures for fnRef resolution
  borrowRefs : List String := []          -- names of refs created by borrow blocks (for escape analysis)
  loopBreakTy : Option Ty := none         -- collects type from break-with-value in while-as-expression
  inDeferBody : Bool := false             -- true when checking inside a defer body
  currentImplType : Option Ty := none     -- the Self type when inside an impl block
  loopLabels : List String := []          -- stack of active loop labels
  traitImpls : List (String × String) := []  -- (typeName, traitName) pairs for bound checking
  traits : List TraitDef := []             -- all trait definitions (for method lookup on type vars)
  currentTypeBounds : List (String × List String) := []  -- current function's type param bounds
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
  | .never => "!"
  | .heap inner => "Heap<" ++ tyToString inner ++ ">"
  | .heapArray inner => "HeapArray<" ++ tyToString inner ++ ">"
  | .placeholder => "<unknown>"

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
    -- Resolve Self to the current impl type
    if name == "Self" then
      match env.currentImplType with
      | some t => return t
      | none => throw "Self can only be used inside impl blocks"
    -- Check if it's a type parameter first
    else if env.currentTypeParams.contains name then return .typeVar name
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
  | .generic "Heap" [inner] =>
    let inner' ← resolveType inner
    return .heap inner'
  | .generic "HeapArray" [inner] =>
    let inner' ← resolveType inner
    return .heapArray inner'
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
  | .fn_ _ _ _ => return true  -- Function pointers are Copy (no captures, just a code address)
  | .placeholder => return true
  | .never => return true      -- Never type is compatible with anything
  | .heap _ => return false    -- Heap pointers are linear
  | .heapArray _ => return false
  | .named name =>
    -- Check if the struct/enum has isCopy = true
    let env ← getEnv
    match env.structs.find? fun sd => sd.name == name with
    | some sd => return sd.isCopy
    | none =>
      match env.enums.find? fun ed => ed.name == name with
      | some ed => return ed.isCopy
      | none => return false
  | .generic _ _ => return false  -- Generic instantiations are linear
  | .typeVar _ => return false  -- Generic values remain linear unless proven Copy
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
  let env ← getEnv
  setEnv { env with vars := (name, info) :: env.vars }

private def activeBorrowRefs (env : TypeEnv) (varName : String) : List VarInfo :=
  env.vars.foldl (fun acc (_, info) =>
    match info.borrowedFrom with
    | some sourceName =>
      if sourceName == varName && info.state != .consumed then info :: acc else acc
    | none => acc) []

private partial def tyContainsTypeVar : Ty → Bool
  | .typeVar _ => true
  | .ref inner | .refMut inner | .ptrMut inner | .ptrConst inner | .heap inner | .heapArray inner =>
    tyContainsTypeVar inner
  | .array elem _ => tyContainsTypeVar elem
  | .generic _ args => args.any tyContainsTypeVar
  | .fn_ params _ retTy => params.any tyContainsTypeVar || tyContainsTypeVar retTy
  | _ => false

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

/-- Normalize a type for comparison (normalize empty capsets in fn types). -/
private def normalizeTyForCmp : Ty → Ty
  | .fn_ params capSet retTy =>
    let normCap := match capSet with
      | .concrete [] => .empty
      | .empty => .empty
      | cs => cs
    .fn_ (params.map normalizeTyForCmp) normCap (normalizeTyForCmp retTy)
  | .ref t => .ref (normalizeTyForCmp t)
  | .refMut t => .refMut (normalizeTyForCmp t)
  | .heap t => .heap (normalizeTyForCmp t)
  | .heapArray t => .heapArray (normalizeTyForCmp t)
  | .generic n args => .generic n (args.map normalizeTyForCmp)
  | .array t n => .array (normalizeTyForCmp t) n
  | t => t

def expectTy (expected actual : Ty) (ctx : String) : CheckM Unit := do
  if expected == actual then return ()
  -- Never type is compatible with anything (bottom type)
  if actual == .never then return ()
  -- Resolve type aliases and try again
  let expectedR ← resolveType expected
  let actualR ← resolveType actual
  if expectedR == actualR then return ()
  -- Normalize fn types (empty capsets) and try again
  let expectedN := normalizeTyForCmp expectedR
  let actualN := normalizeTyForCmp actualR
  if expectedN == actualN then return ()
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
    if info.state == .frozen then
      throw s!"variable '{name}' is frozen by borrow block"
    if info.isCopy then return ()
    if info.state == .unconsumed || info.state == .reserved then
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := if info.state == .reserved then .reserved else .used })
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
    let activeRefs := activeBorrowRefs env name
    if activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
      throw s!"cannot move linear variable '{name}': variable is borrowed"
    match info.state with
    | .consumed =>
      throw s!"linear variable '{name}' used after move"
    | .reserved =>
      throw s!"variable '{name}' is reserved by defer"
    | .frozen =>
      throw s!"variable '{name}' is frozen by borrow block"
    | .unconsumed | .used =>
      -- Loop depth check
      if info.loopDepth < env.loopDepth then
        throw s!"cannot consume linear variable '{name}' inside a loop (declared outside the loop)"
      -- Mark consumed
      let vars' := env.vars.map fun (n, vi) =>
        if n == name then (n, { vi with state := .consumed })
        else (n, vi)
      setEnv { env with vars := vars' }

/-- Consume a variable if it exists. Skips function names (not in var scope). -/
def consumeVarIfExists (name : String) : CheckM Unit := do
  match ← lookupVarInfo name with
  | some _ => consumeVar name
  | none => pure ()  -- function reference, not a variable

/-- Check that all tracked linear variables in the given name list are consumed.
    `reserved` is allowed because the deferred destroy will run at scope exit. -/
def checkScopeExit (varNames : List String) : CheckM Unit := do
  let env ← getEnv
  for name in varNames do
    match env.vars.lookup name with
    | some info =>
      if !info.isCopy && info.state != .consumed && info.state != .reserved then
        throw s!"linear variable '{name}' was never consumed"
    | none => pure ()

-- ============================================================
-- Type substitution for generics
-- ============================================================

/-- Peek at an expression's type without consuming any linear variables. -/
def peekExprType (e : Expr) : CheckM Ty := do
  match e with
  | .intLit _ => return .int
  | .floatLit _ => return .float64
  | .boolLit _ => return .bool
  | .strLit _ => return .string
  | .charLit _ => return .char
  | .ident name =>
    let env ← getEnv
    match env.constants.lookup name with
    | some ty => return ty
    | none =>
    match env.vars.lookup name with
    | some info => return info.ty
    | none =>
      match ← lookupFn name with
      | some sig =>
        let paramTys := sig.params.map fun (_, t) => t
        return .fn_ paramTys sig.capSet sig.retTy
      | none => return .placeholder
  | .structLit name typeArgs _ =>
    if typeArgs.isEmpty then return .named name
    else return .generic name typeArgs
  | .enumLit enumName _ typeArgs _ =>
    if typeArgs.isEmpty then return .named enumName
    else return .generic enumName typeArgs
  | .fnRef name =>
    let env ← getEnv
    match env.allFnSigs.lookup name with
    | some sig =>
      let paramTys := sig.params.map Prod.snd
      return .fn_ paramTys sig.capSet sig.retTy
    | none => return .placeholder
  | .paren inner => peekExprType inner
  | _ => return .placeholder

/-- Unify a pattern type with an actual type to discover type variable bindings. -/
private partial def unifyTypes (pattern actual : Ty) (typeParams : List String) : List (String × Ty) :=
  match pattern with
  | .named name =>
    if typeParams.contains name then [(name, actual)]
    else []
  | .typeVar name =>
    if typeParams.contains name then [(name, actual)]
    else []
  | .ref inner =>
    match actual with
    | .ref aInner => unifyTypes inner aInner typeParams
    | _ => []
  | .refMut inner =>
    match actual with
    | .refMut aInner => unifyTypes inner aInner typeParams
    | _ => []
  | .fn_ pParams pCapSet pRet =>
    match actual with
    | .fn_ aParams _aCapSet aRet =>
      let paramBindings := (pParams.zip aParams).foldl (fun acc (pp, ap) =>
        acc ++ unifyTypes pp ap typeParams) []
      let retBindings := unifyTypes pRet aRet typeParams
      -- Also try to unify cap set names
      let capBindings := match pCapSet with
        | .concrete _ => []  -- concrete caps don't bind type vars
        | _ => []
      paramBindings ++ retBindings ++ capBindings
    | _ => []
  | .generic _name pArgs =>
    match actual with
    | .generic _aName aArgs =>
      (pArgs.zip aArgs).foldl (fun acc (pp, ap) =>
        acc ++ unifyTypes pp ap typeParams) []
    | _ => []
  | .heap inner =>
    match actual with
    | .heap aInner => unifyTypes inner aInner typeParams
    | _ => []
  | .array elem _ =>
    match actual with
    | .array aElem _ => unifyTypes elem aElem typeParams
    | _ => []
  | _ => []

private def substCapSet (mapping : List (String × Ty)) : CapSet → CapSet
  | .concrete caps =>
    -- Cap variable names that map to types are not relevant here, keep as-is
    .concrete caps
  | .var name => .var name
  | .union a b => .union (substCapSet mapping a) (substCapSet mapping b)
  | .empty => .empty

private def substTy (mapping : List (String × Ty)) : Ty → Ty
  | .named name => match mapping.lookup name with | some t => t | none => .named name
  | .typeVar name => match mapping.lookup name with | some t => t | none => .typeVar name
  | .ref inner => .ref (substTy mapping inner)
  | .refMut inner => .refMut (substTy mapping inner)
  | .ptrMut inner => .ptrMut (substTy mapping inner)
  | .ptrConst inner => .ptrConst (substTy mapping inner)
  | .array elem n => .array (substTy mapping elem) n
  | .generic name args => .generic name (args.map (substTy mapping))
  | .fn_ params capSet retTy =>
    .fn_ (params.map (substTy mapping)) (substCapSet mapping capSet) (substTy mapping retTy)
  | .heap inner => .heap (substTy mapping inner)
  | .heapArray inner => .heapArray (substTy mapping inner)
  | ty => ty

/-- Check trait bounds: for each type param with bounds, verify the concrete type implements the required traits. -/
private def checkTraitBounds (bounds : List (String × List String)) (mapping : List (String × Ty))
    (context : String) : CheckM Unit := do
  let env ← getEnv
  for (paramName, requiredTraits) in bounds do
    match mapping.lookup paramName with
    | some concreteType =>
      let typeName := match concreteType with
        | .named n => some n
        | .generic n _ => some n
        | _ => none
      match typeName with
      | some tn =>
        for traitName in requiredTraits do
          if !(env.traitImpls.any fun (t, tr) => t == tn && tr == traitName) then
            throw s!"type '{tn}' does not implement trait '{traitName}' required by {context}"
      | none => pure ()  -- primitive types, skip bound checking
    | none => pure ()

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
    | none =>
      -- Check if it's a function name (first-class function reference)
      match ← lookupFn name with
      | some sig =>
        let paramTys := sig.params.map fun (_, t) => t
        return .fn_ paramTys sig.capSet sig.retTy
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
    | .bitand | .bitor | .bitxor | .shl | .shr =>
      if isIntegerType lTyR && lTyR == rTyR then return lTy
      else if isTypeVarL || isTypeVarR then return lTy
      else do
        if !isIntegerType lTyR then
          throw s!"type mismatch in bitwise op: expected integer type, got {tyToString lTyR}"
        expectTy lTyR rTyR "bitwise operand types"
        return lTy
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
    | .bitnot =>
      if isIntegerType ty then return ty
      else do
        throw s!"type mismatch in bitwise not: expected integer type, got {tyToString ty}"
  | .arrowAccess obj field =>
    let objTy ← checkExpr obj
    -- obj must be Heap<T> or HeapArray<T>
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | .ref (.heap t) => t
      | .refMut (.heap t) => t
      | _ => .placeholder
    if innerTy == .placeholder then
      throw s!"arrow access '->' requires Heap<T> or HeapArray<T> type, got {tyToString objTy}"
    -- Look up field on the inner type
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    if structName == "" then throw s!"arrow access '->' on non-struct inner type"
    match ← lookupStruct structName with
    | some sd =>
      match sd.fields.find? fun f => f.name == field with
      | some f => resolveType f.ty
      | none => throw s!"struct '{structName}' has no field '{field}'"
    | none => throw s!"unknown struct type '{structName}'"
  | .allocCall inner allocExpr =>
    -- Check that caller has Alloc capability (needed to forward)
    checkCapabilities "with(Alloc)" (.concrete ["Alloc"])
    -- Check the allocator expression is valid
    let _allocTy ← checkExpr allocExpr
    -- Check the inner call expression
    checkExpr inner hint
  | .whileExpr cond body elseBody =>
    -- while-as-expression: while cond { body } else { elseBody }
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throw s!"while condition must be bool, got {tyToString condTy}"
    -- Save and set up loop context
    let env ← getEnv
    let savedLoopDepth := env.loopDepth
    let savedBreakTy := env.loopBreakTy
    setEnv { env with loopDepth := env.loopDepth + 1, loopBreakTy := none }
    -- Check body
    checkStmts body env.currentRetTy
    -- Get break type if any
    let envAfterBody ← getEnv
    let breakTy := envAfterBody.loopBreakTy
    -- Restore loop depth and break ty
    setEnv { envAfterBody with loopDepth := savedLoopDepth, loopBreakTy := savedBreakTy }
    -- Check else body: all stmts except the last, then check last for its type
    let elseInit := elseBody.dropLast
    checkStmts elseInit env.currentRetTy
    let elseTy ← match elseBody.getLast? with
      | some (.expr e) => checkExpr e hint
      | some (.return_ v) =>
        match v with
        | some rv => let _ ← checkExpr rv; pure Ty.never
        | none => pure Ty.never
      | some other =>
        checkStmt other env.currentRetTy
        pure Ty.unit
      | none => pure Ty.unit
    -- The result type: if break had a value, verify it matches else type
    match breakTy with
    | some bTy =>
      if bTy != elseTy && elseTy != .never && bTy != .never then
        throw s!"while-expression break type '{tyToString bTy}' does not match else type '{tyToString elseTy}'"
      return elseTy
    | none => return elseTy
  | .call fnName typeArgs args =>
    -- Intercept abort() calls
    if fnName == "abort" then
      if args.length != 0 then throw "abort() takes no arguments"
      return .never
    -- Intercept destroy() calls
    if fnName == "destroy" then
      if args.length != 1 then throw "destroy() takes exactly 1 argument"
      let arg := match args with | a :: _ => a | [] => Expr.intLit 0
      let argTy ← checkExpr arg
      -- Look up impl Destroy for the type
      let typeName := match argTy with
        | .named n => n
        | .generic n _ => n
        | _ => ""
      if typeName == "" then throw s!"destroy() requires a named type, got {tyToString argTy}"
      -- Search function signatures for TypeName_destroy
      let destroyFn ← lookupFn (typeName ++ "_destroy")
      match destroyFn with
      | some _ =>
        -- Consume the argument
        match arg with
        | .ident varName => consumeVarIfExists varName
        | _ => pure ()
        return .unit
      | none => throw s!"type '{typeName}' does not implement Destroy"
    -- Intercept alloc(val) calls
    if fnName == "alloc" then
      if args.length != 1 then throw "alloc() takes exactly 1 argument"
      -- Require Alloc capability
      checkCapabilities "alloc" (.concrete ["Alloc"])
      let arg := match args with | a :: _ => a | [] => Expr.intLit 0
      let argTy ← checkExpr arg
      -- Consume linear variables passed to alloc (ownership moves to heap)
      match arg with
      | .ident varName => consumeVarIfExists varName
      | _ => pure ()
      return .heap argTy
    -- Intercept free(ptr) calls
    if fnName == "free" then
      if args.length != 1 then throw "free() takes exactly 1 argument"
      -- Require Alloc capability
      checkCapabilities "free" (.concrete ["Alloc"])
      let arg := match args with | a :: _ => a | [] => Expr.intLit 0
      let argTy ← checkExpr arg
      match argTy with
      | .heap innerTy =>
        -- Consume the argument (Heap<T> is linear)
        match arg with
        | .ident varName => consumeVarIfExists varName
        | _ => pure ()
        return innerTy
      | _ => throw s!"free() requires Heap<T> type, got {tyToString argTy}"
    -- Check if this is a function pointer call (variable with fn_ type)
    let fnPtrVarTy ← lookupVarTy fnName
    match fnPtrVarTy with
    | some (.fn_ paramTys fnPtrCapSet fnPtrRetTy) =>
      -- Function pointer call: check capabilities
      checkCapabilities fnName fnPtrCapSet
      -- Check argument count
      if args.length != paramTys.length then
        throw s!"function pointer '{fnName}' expects {paramTys.length} arguments, got {args.length}"
      -- Check each argument type
      for (arg, pTy) in args.zip paramTys do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument of function pointer call '{fnName}'"
        match arg with
        | .ident varName => consumeVarIfExists varName
        | _ => pure ()
      -- Function pointers are Copy, no need to consume
      useVar fnName
      return fnPtrRetTy
    | _ =>
    match ← lookupFn fnName with
    | some sig =>
      -- Infer type arguments if not explicitly provided
      let inferredTypeArgs ← do
        if !typeArgs.isEmpty || sig.typeParams.isEmpty then
          pure typeArgs
        else
          -- Infer types from argument types (without consuming)
          let mut inferred : List (String × Ty) := []
          for (arg, (_, pTy)) in args.zip sig.params do
            let argTy ← peekExprType arg
            -- Try to unify pTy with argTy to learn type variables
            let bindings := unifyTypes pTy argTy sig.typeParams
            for (name, ty) in bindings do
              if !(inferred.any fun (n, _) => n == name) then
                inferred := inferred ++ [(name, ty)]
          -- Build ordered type args from inferred mapping
          pure (sig.typeParams.map fun tp =>
            match inferred.lookup tp with
            | some ty => ty
            | none => .typeVar tp)
      -- Build type substitution
      let mapping := sig.typeParams.zip inferredTypeArgs
      -- Check trait bounds
      if !sig.typeBounds.isEmpty then
        checkTraitBounds sig.typeBounds mapping s!"generic function '{fnName}'"
      let paramTypes := sig.params.map fun (n, t) => (n, substTy mapping t)
      let retTy := substTy mapping sig.retTy
      -- Resolve capability variables from argument types
      let resolvedCapSet ← do
        if sig.capParams.isEmpty then
          pure sig.capSet
        else
          let mut capBindings : List (String × List String) := []
          -- Infer cap variable bindings from fn-typed arguments
          for (arg, (_, pTy)) in args.zip paramTypes do
            match pTy with
            | .fn_ _ (.concrete caps) _ =>
              for cap in caps do
                if sig.capParams.contains cap then
                  -- Get actual argument's cap set
                  let argCapSet ← do
                    let argTy ← peekExprType arg
                    match argTy with
                    | .fn_ _ cs _ => pure cs
                    | _ =>
                      match arg with
                      | .ident varName =>
                        match ← lookupFn varName with
                        | some argSig => pure argSig.capSet
                        | none => pure CapSet.empty
                      | _ => pure CapSet.empty
                  let (argCaps, _) := argCapSet.normalize
                  capBindings := capBindings ++ [(cap, argCaps)]
            | _ => pure ()
          -- Build resolved capSet
          let (concreteCaps, _) := sig.capSet.normalize
          let mut resolvedCaps : List String := []
          for cap in concreteCaps do
            if sig.capParams.contains cap then
              match capBindings.find? fun (name, _) => name == cap with
              | some (_, caps) => resolvedCaps := resolvedCaps ++ caps
              | none => throw s!"cannot infer capability variable '{cap}' for call to '{fnName}'"
            else
              resolvedCaps := resolvedCaps ++ [cap]
          pure (CapSet.concrete resolvedCaps)
      -- Resolve cap variables in parameter types for type comparison
      let capBindings' := if sig.capParams.isEmpty then [] else
        sig.capParams.map fun cp =>
          match resolvedCapSet with
          | .concrete caps => (cp, caps.filter fun c => !sig.capParams.contains c)
          | _ => (cp, ([] : List String))
      let resolveCapInTy : Ty → Ty := fun ty =>
        match ty with
        | .fn_ params (.concrete caps) ret =>
          let newCaps := caps.foldl (fun acc cap =>
            if sig.capParams.contains cap then
              match capBindings'.find? fun (n, _) => n == cap with
              | some (_, resolved) => acc ++ resolved
              | none => acc
            else acc ++ [cap]) []
          .fn_ params (.concrete newCaps) ret
        | t => t
      let paramTypes := paramTypes.map fun (n, t) => (n, resolveCapInTy t)
      -- Check capabilities with resolved set
      checkCapabilities fnName resolvedCapSet
      if args.length != paramTypes.length then
        throw s!"function '{fnName}' expects {paramTypes.length} arguments, got {args.length}"
      for (arg, (pName, pTy)) in args.zip paramTypes do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{fnName}'"
        -- If arg is a bare identifier of a linear type, consume it
        match arg with
        | .ident varName => consumeVarIfExists varName
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
        let fieldTy ← resolveType (substTy mapping sf.ty)
        match fields.find? fun (fn, _) => fn == sf.name with
        | some (_, expr) =>
          let exprTy ← checkExpr expr (some fieldTy)
          expectTy fieldTy exprTy s!"field '{sf.name}' of struct '{name}'"
          -- Consume linear variables used as struct fields
          match expr with
          | .ident varName => consumeVarIfExists varName
          | _ => pure ()
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
    -- Prevent direct field access on Heap<T> — must use ->
    match objTy with
    | .heap _ => throw s!"cannot access field '{field}' on {tyToString objTy} with '.'; use '->' for heap access"
    | .heapArray _ => throw s!"cannot access field '{field}' on {tyToString objTy} with '.'; use '->' for heap access"
    | _ => pure ()
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
          resolveType (substTy mapping f.ty)
        | none => throw s!"struct '{structName}' has no field '{field}'"
      | none => throw s!"field access on non-struct type"
  | .enumLit enumName variant typeArgs fields =>
    match ← lookupEnum enumName with
    | some ed =>
      -- Infer type args from hint if not explicitly provided
      let effectiveTypeArgs := if typeArgs.isEmpty && !ed.typeParams.isEmpty then
        match hint with
        | some (.generic n args) => if n == enumName then args else []
        | _ => []
      else typeArgs
      let mapping := ed.typeParams.zip effectiveTypeArgs
      match ed.variants.find? fun v => v.name == variant with
      | some ev =>
        for sf in ev.fields do
          let fieldTy := substTy mapping sf.ty
          match fields.find? fun (fn, _) => fn == sf.name with
          | some (_, expr) =>
            let exprTy ← checkExpr expr (some fieldTy)
            expectTy fieldTy exprTy s!"field '{sf.name}' of {enumName}#{variant}"
            -- Consume linear variables used as enum fields
            match expr with
            | .ident varName => consumeVarIfExists varName
            | _ => pure ()
          | none => throw s!"missing field '{sf.name}' in {enumName}#{variant}"
        for (fn, _) in fields do
          match ev.fields.find? fun sf => sf.name == fn with
          | some _ => pure ()
          | none => throw s!"unknown field '{fn}' in {enumName}#{variant}"
        if effectiveTypeArgs.isEmpty then return .named enumName
        else return .generic enumName effectiveTypeArgs
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
    let (enumName, enumTypeArgs) := match innerTyR with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | _ => ("", [])
    if enumName != "" then
      match ← lookupEnum enumName with
      | some ed =>
        -- Consume scrutinee if it's a linear ident
        match scrutinee with
        | .ident varName => consumeVarIfExists varName
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
            -- Bind variant fields in scope (substitute generic type args)
            let ev := (ed.variants.find? fun v => v.name == armVariant).get!
            let typeMapping := ed.typeParams.zip enumTypeArgs
            for (binding, sf) in bindings.zip ev.fields do
              addVar binding (substTy typeMapping sf.ty)
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
        let env ← getEnv
        let activeRefs := activeBorrowRefs env varName
        if info.mutBorrowed || activeRefs.any (fun refInfo => match refInfo.ty with | .refMut _ => true | _ => false) then
          throw s!"cannot borrow '{varName}': already mutably borrowed"
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
        let env ← getEnv
        let activeRefs := activeBorrowRefs env varName
        if info.borrowCount > 0 || activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
          throw s!"cannot mutably borrow '{varName}': already borrowed"
        if info.mutBorrowed then
          throw s!"cannot mutably borrow '{varName}': already mutably borrowed"
        if !info.mutable then
          throw s!"cannot take mutable borrow of immutable variable '{varName}'"
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
    | .heap t =>
      -- *heap_ptr: loads value from heap, frees memory, consumes the Heap<T>
      -- Requires Alloc capability (heap deallocation)
      checkCapabilities "*heap_ptr" (.concrete ["Alloc"])
      match inner with
      | .ident varName => consumeVar varName
      | _ => pure ()
      return t
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
    if typeName == "" then
      -- Check if this is a type variable with trait bounds
      match innerTy with
      | .typeVar n =>
        let env ← getEnv
        let bounds := (env.currentTypeBounds.find? fun (name, _) => name == n).map Prod.snd |>.getD []
        -- Find the method in one of the bound traits
        let mut foundSig : Option FnSigDef := none
        for traitName in bounds do
          match env.traits.find? fun td => td.name == traitName with
          | some td =>
            match td.methods.find? fun ms => ms.name == methodName with
            | some ms => foundSig := some ms; break
            | none => pure ()
          | none => pure ()
        match foundSig with
        | none => throw s!"no method '{methodName}' for type variable '{n}'"
        | some sig =>
          -- Check capabilities from trait method
          checkCapabilities (n ++ "." ++ methodName) sig.capSet
          -- Type check arguments (params in FnSigDef excludes self)
          if args.length != sig.params.length then
            throw s!"method '{methodName}' expects {sig.params.length} arguments, got {args.length}"
          for (arg, p) in args.zip sig.params do
            let argTy ← checkExpr arg (some p.ty)
            expectTy p.ty argTy s!"argument '{p.name}' of '{methodName}'"
            match arg with
            | .ident varName => consumeVarIfExists varName
            | _ => pure ()
          return sig.retTy
      | _ => throw s!"method call on non-named type"
    else
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
        | .ident varName => consumeVarIfExists varName
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
        | .ident varName => consumeVarIfExists varName
        | _ => pure ()
      return retTy
    | none => throw s!"no method '{methodName}' on type '{typeName}'"
  | .fnRef fnName =>
    -- Look up the function signature to build the fn pointer type
    let env ← getEnv
    match env.allFnSigs.lookup fnName with
    | some sig =>
      let paramTys := sig.params.map Prod.snd
      return .fn_ paramTys sig.capSet sig.retTy
    | none => throw s!"unknown function '{fnName}' in function reference"

partial def checkStmt (stmt : Stmt) (retTy : Ty) : CheckM Unit := do
  match stmt with
  | .letDecl name mutable ty value =>
    -- Escape analysis: prevent storing a borrow ref into a new binding
    let env ← getEnv
    match value with
    | .ident vn =>
      if env.borrowRefs.contains vn then
        throw s!"reference '{vn}' cannot escape its borrow block"
    | _ => pure ()
    let valTy ← checkExpr value ty
    match ty with
    | some declTy => expectTy declTy valTy s!"let binding '{name}'"
    | none => pure ()
    let finalTy ← match ty with
      | some t => resolveType t
      | none => pure valTy
    addVar name finalTy mutable
    match value with
    | .borrow (.ident sourceName) =>
      modify fun env =>
        { env with vars := env.vars.map fun (n, info) =>
            if n == name then (n, { info with borrowedFrom := some sourceName }) else (n, info) }
    | .borrowMut (.ident sourceName) =>
      modify fun env =>
        { env with vars := env.vars.map fun (n, info) =>
            if n == name then (n, { info with borrowedFrom := some sourceName }) else (n, info) }
    | _ => pure ()
  | .assign name value =>
    -- Escape analysis: prevent storing a borrow ref into an outer variable
    let env ← getEnv
    match value with
    | .ident vn =>
      if env.borrowRefs.contains vn then
        throw s!"reference '{vn}' cannot escape its borrow block"
    | _ => pure ()
    match ← lookupVarInfo name with
    | some info =>
      if !info.mutable then
        throw s!"cannot assign to immutable variable '{name}'"
      if info.state == .frozen then
        throw s!"cannot assign to '{name}': variable is frozen by borrow block"
      let env ← getEnv
      let activeRefs := activeBorrowRefs env name
      if activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
        throw s!"cannot assign to '{name}': variable is borrowed"
      let valTy ← checkExpr value (some info.ty)
      expectTy info.ty valTy s!"assignment to '{name}'"
    | none => throw s!"assignment to undeclared variable '{name}'"
  | .return_ (some value) =>
    -- Escape analysis: prevent returning a borrow ref
    let env ← getEnv
    match value with
    | .ident vn =>
      if env.borrowRefs.contains vn then
        throw s!"reference '{vn}' cannot escape its borrow block"
    | _ => pure ()
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
  | .while_ cond body lbl =>
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throw s!"while condition must be bool, got {tyToString condTy}"
    -- Increment loop depth for the body, push label if present
    let env ← getEnv
    let labels := match lbl with
      | some l => l :: env.loopLabels
      | none => env.loopLabels
    setEnv { env with loopDepth := env.loopDepth + 1, loopLabels := labels }
    checkStmts body retTy
    -- Restore loop depth and labels
    let env' ← getEnv
    setEnv { env' with loopDepth := env.loopDepth, loopLabels := env.loopLabels }
  | .forLoop init cond step body lbl =>
    -- Init
    match init with
    | some initStmt => checkStmt initStmt retTy
    | none => pure ()
    -- Condition
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throw s!"for condition must be bool, got {tyToString condTy}"
    -- Body + step in loop scope, push label if present
    let env ← getEnv
    let labels := match lbl with
      | some l => l :: env.loopLabels
      | none => env.loopLabels
    setEnv { env with loopDepth := env.loopDepth + 1, loopLabels := labels }
    checkStmts body retTy
    match step with
    | some stepStmt => checkStmt stepStmt retTy
    | none => pure ()
    let env' ← getEnv
    setEnv { env' with loopDepth := env.loopDepth, loopLabels := env.loopLabels }
  | .fieldAssign obj field value =>
    -- Escape analysis: prevent storing a borrow ref into a struct field
    let env ← getEnv
    match value with
    | .ident vn =>
      if env.borrowRefs.contains vn then
        throw s!"reference '{vn}' cannot escape its borrow block"
    | _ => pure ()
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
  | .defer body =>
    -- Verify body is a call expression
    match body with
    | .call _ _ _ => pure ()
    | _ => throw "defer body must be a function call"
    let _ ← checkExpr body
    -- If it's destroy(varName), mark varName as reserved
    match body with
    | .call "destroy" _ args =>
      match args.head? with
      | some (.ident varName) =>
        let env ← getEnv
        let vars' := env.vars.map fun (n, vi) =>
          if n == varName then (n, { vi with state := .reserved })
          else (n, vi)
        setEnv { env with vars := vars' }
      | _ => pure ()
    | _ => pure ()
  | .borrowIn var ref region isMut body =>
    -- Check that var exists
    match ← lookupVarInfo var with
    | none => throw s!"use of undeclared variable '{var}'"
    | some varInfo =>
      -- Check no shadowing of ref and region names
      let env ← getEnv
      if (env.vars.lookup ref).isSome then
        throw s!"borrow ref '{ref}' shadows existing name"
      if (env.vars.lookup region).isSome then
        throw s!"borrow region '{region}' shadows existing name"
      -- Check if variable is frozen (already inside another borrow block)
      if varInfo.state == .frozen then
        throw s!"variable '{var}' is frozen by borrow block"
      -- Check for mutable borrow conflict: if var is already mutably borrowed, error
      if isMut && varInfo.mutBorrowed then
        throw s!"variable '{var}' is already mutably borrowed"
      if isMut && varInfo.borrowCount > 0 then
        throw s!"cannot mutably borrow '{var}': already immutably borrowed"
      if !isMut && varInfo.mutBorrowed then
        throw s!"cannot immutably borrow '{var}': already mutably borrowed"
      -- Save state and freeze the original variable
      let savedState := varInfo.state
      let vars' := env.vars.map fun (n, vi) =>
        if n == var then (n, { vi with state := .frozen })
        else (n, vi)
      setEnv { env with vars := vars' }
      -- Add reference binding and track for escape analysis
      let refTy := if isMut then Ty.refMut varInfo.ty else Ty.ref varInfo.ty
      addVar ref refTy true
      let envWithRef ← getEnv
      setEnv { envWithRef with borrowRefs := ref :: envWithRef.borrowRefs }
      -- Check body
      checkStmts body env.currentRetTy
      -- Clean up: remove ref from borrowRefs and unfreeze original variable
      let env' ← getEnv
      let vars'' := (env'.vars.map fun (n, vi) =>
        if n == var then (n, { vi with state := savedState })
        else (n, vi)).filter fun (n, _) => n != ref
      let cleanedRefs := env'.borrowRefs.filter (· != ref)
      setEnv { env' with vars := vars'', borrowRefs := cleanedRefs }
  | .arrowAssign obj field value =>
    let objTy ← checkExpr obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | .ref (.heap t) | .refMut (.heap t) => t
      | _ => .placeholder
    if innerTy == .placeholder then
      throw s!"arrow assign '->' requires Heap<T> type, got {tyToString objTy}"
    let structName := match innerTy with
      | .named n => n
      | _ => ""
    if structName == "" then throw s!"arrow assign on non-struct inner type"
    match ← lookupStructField structName field with
    | some fieldTy =>
      let valTy ← checkExpr value (some fieldTy)
      expectTy fieldTy valTy s!"arrow field assignment '{structName}->{field}'"
    | none => throw s!"struct '{structName}' has no field '{field}'"
  | .break_ value lbl =>
    let env ← getEnv
    if env.inDeferBody then
      throw "break is not allowed inside defer"
    if env.loopDepth == 0 then
      throw "break outside of loop"
    -- Validate label if present
    match lbl with
    | some l =>
      if !env.loopLabels.contains l then
        throw s!"unknown loop label '{l}'"
    | none => pure ()
    -- Check all linear variables declared in the loop body are consumed
    for (name, info) in env.vars do
      if !info.isCopy && info.state != .consumed && info.loopDepth >= env.loopDepth then
        throw s!"break would skip unconsumed linear variable '{name}'"
    -- Check break value if present (for while-as-expression)
    match value with
    | some expr =>
      let valTy ← checkExpr expr
      let env2 ← getEnv
      match env2.loopBreakTy with
      | none => setEnv { env2 with loopBreakTy := some valTy }
      | some prevTy =>
        if prevTy != valTy then
          throw s!"break value type '{tyToString valTy}' does not match previous break type '{tyToString prevTy}'"
    | none => pure ()
  | .continue_ lbl =>
    let env ← getEnv
    if env.inDeferBody then
      throw "continue is not allowed inside defer"
    if env.loopDepth == 0 then
      throw "continue outside of loop"
    -- Validate label if present
    match lbl with
    | some l =>
      if !env.loopLabels.contains l then
        throw s!"unknown loop label '{l}'"
    | none => pure ()
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
  let retTyRaw := resolveTypeParams f.retTy f.typeParams
  -- Set current return type, type params, capability context, and type bounds
  let env1 := { envBefore with currentRetTy := retTyRaw, currentTypeParams := f.typeParams }
  let env2 := { env1 with currentCapSet := f.capSet }
  let env3 := { env2 with currentTypeBounds := f.typeBounds }
  setEnv { env3 with currentFnName := f.name }
  -- Resolve Self in return type (needs currentImplType from env)
  let retTy ← resolveType retTyRaw
  modify fun env => { env with currentRetTy := retTy }
  -- Add params to env. Linear params are "consumed" by being received.
  let mut paramNames : List String := []
  for p in f.params do
    let paramTyRaw := resolveTypeParams p.ty f.typeParams
    let paramTy ← resolveType paramTyRaw
    addVar p.name paramTy true  -- params are always mutable for now
    paramNames := paramNames ++ [p.name]
  -- Check body
  checkStmts f.body retTy
  -- Check local bindings, plus generic by-value params whose linearity is otherwise erased.
  let envAfter ← getEnv
  let localVars := envAfter.vars.filter fun (name, _) =>
    match envBefore.vars.lookup name with
    | some _ => false
    | none =>
      if paramNames.contains name then
        -- For params with generic types, only flag if completely untouched (.unconsumed).
        -- .used is acceptable — the function used the parameter (borrowed, field-accessed, etc).
        match envAfter.vars.lookup name with
        | some info => tyContainsTypeVar info.ty && info.state == .unconsumed
        | none => false
      else true
  let localNames := localVars.map fun (name, _) => name
  checkScopeExit localNames
  -- Restore env (remove this function's locals)
  setEnv envBefore

/-- Resolve Self to the concrete impl type in a Ty (pure, for signature building). -/
private def resolveSelf (ty : Ty) (implTy : Ty) : Ty :=
  match ty with
  | .named "Self" => implTy
  | .ref inner => .ref (resolveSelf inner implTy)
  | .refMut inner => .refMut (resolveSelf inner implTy)
  | .generic name args => .generic name (args.map fun a => resolveSelf a implTy)
  | .array elem n => .array (resolveSelf elem implTy) n
  | .heap inner => .heap (resolveSelf inner implTy)
  | .heapArray inner => .heapArray (resolveSelf inner implTy)
  | other => other

def checkModule (m : Module) (importedFnSigs : List (String × FnSig) := [])
    (importedStructs : List StructDef := []) (importedEnums : List EnumDef := [])
    (importedImplBlocks : List ImplBlock := []) (importedTraitImpls : List ImplTraitBlock := [])
    : Except String Unit :=
  let fnSigs : List FnSig := m.functions.map fun f =>
    { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy, typeParams := f.typeParams,
      typeBounds := f.typeBounds, capParams := f.capParams, capSet := f.capSet }
  -- Add extern fn signatures
  let externSigs : List FnSig := m.externFns.map fun ef =>
    { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy }
  let importedSigList := importedFnSigs.map Prod.snd
  let baseOffset := importedSigList.length
  -- Built-in functions for strings and I/O
  let builtinSigs : List FnSig := [
    -- 0: string_length
    { params := [("s", .ref .string)], retTy := .int },
    -- 1: string_concat
    { params := [("a", .string), ("b", .string)], retTy := .string },
    -- 2: print_string
    { params := [("s", .ref .string)], retTy := .unit, capSet := .concrete ["Console"] },
    -- 3: drop_string
    { params := [("s", .string)], retTy := .unit },
    -- 4: print_int
    { params := [("x", .int)], retTy := .unit, capSet := .concrete ["Console"] },
    -- 5: print_bool
    { params := [("x", .bool)], retTy := .unit, capSet := .concrete ["Console"] },
    -- 6: read_file
    { params := [("path", .ref .string)], retTy := .string, capSet := .concrete ["File"] },
    -- 7: write_file
    { params := [("path", .ref .string), ("data", .ref .string)], retTy := .int, capSet := .concrete ["File"] },
    -- 8: string_slice
    { params := [("s", .ref .string), ("start", .int), ("end_", .int)], retTy := .string },
    -- 9: string_char_at
    { params := [("s", .ref .string), ("index", .int)], retTy := .int },
    -- 10: string_contains
    { params := [("haystack", .ref .string), ("needle", .ref .string)], retTy := .bool },
    -- 11: string_eq
    { params := [("a", .ref .string), ("b", .ref .string)], retTy := .bool },
    -- 12: int_to_string
    { params := [("n", .int)], retTy := .string },
    -- 13: string_to_int
    { params := [("s", .ref .string)], retTy := .generic "Result" [.int, .int] },
    -- 14: bool_to_string
    { params := [("b", .bool)], retTy := .string },
    -- 15: float_to_string
    { params := [("f", .float64)], retTy := .string },
    -- 16: read_line
    { params := [], retTy := .string, capSet := .concrete ["Console"] },
    -- 17: print_char
    { params := [("c", .int)], retTy := .unit, capSet := .concrete ["Console"] },
    -- 18: eprint_string
    { params := [("s", .ref .string)], retTy := .unit, capSet := .concrete ["Console"] },
    -- 19: get_env
    { params := [("name", .ref .string)], retTy := .generic "Option" [.string], capSet := .concrete ["Env"] },
    -- 20: get_args
    { params := [], retTy := .heapArray .string, capSet := .concrete ["Process"] },
    -- 21: exit_process
    { params := [("code", .int)], retTy := .unit, capSet := .concrete ["Process"] },
    -- 22: string_trim
    { params := [("s", .ref .string)], retTy := .string }
  ]
  let builtinOffset := baseOffset + fnSigs.length
  let builtinNames : List (String × Nat) := [
    ("string_length", builtinOffset),
    ("string_concat", builtinOffset + 1),
    ("print_string", builtinOffset + 2),
    ("drop_string", builtinOffset + 3),
    ("print_int", builtinOffset + 4),
    ("print_bool", builtinOffset + 5),
    ("read_file", builtinOffset + 6),
    ("write_file", builtinOffset + 7),
    ("string_slice", builtinOffset + 8),
    ("string_char_at", builtinOffset + 9),
    ("string_contains", builtinOffset + 10),
    ("string_eq", builtinOffset + 11),
    ("int_to_string", builtinOffset + 12),
    ("string_to_int", builtinOffset + 13),
    ("bool_to_string", builtinOffset + 14),
    ("float_to_string", builtinOffset + 15),
    ("read_line", builtinOffset + 16),
    ("print_char", builtinOffset + 17),
    ("eprint_string", builtinOffset + 18),
    ("get_env", builtinOffset + 19),
    ("get_args", builtinOffset + 20),
    ("exit_process", builtinOffset + 21),
    ("string_trim", builtinOffset + 22)
  ]
  -- Add submodule functions/extern fns with qualified names (mod_fn)
  let submoduleSigs : List FnSig := m.submodules.foldl (fun acc (sub : Module) =>
    acc ++ (sub.functions.map fun f =>
      { params := f.params.map fun p => (p.name, p.ty), retTy := f.retTy, typeParams := f.typeParams,
        typeBounds := f.typeBounds, capParams := f.capParams, capSet := f.capSet : FnSig })
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
    let implTy := if ib.typeParams.isEmpty then Ty.named ib.typeName
                  else Ty.generic ib.typeName (ib.typeParams.map Ty.typeVar)
    acc ++ ib.methods.map fun f =>
      let mangledName := ib.typeName ++ "_" ++ f.name
      let allTypeParams := ib.typeParams ++ f.typeParams
      let sig : FnSig := { params := f.params.map fun p => (p.name, resolveSelf p.ty implTy),
                            retTy := resolveSelf f.retTy implTy,
                            typeParams := allTypeParams, capParams := f.capParams, capSet := f.capSet }
      (mangledName, sig)
  ) []
  let traitImplMethodSigs : List (String × FnSig) := allTraitImpls.foldl (fun acc tb =>
    let implTy := if tb.typeParams.isEmpty then Ty.named tb.typeName
                  else Ty.generic tb.typeName (tb.typeParams.map Ty.typeVar)
    acc ++ tb.methods.map fun f =>
      let mangledName := tb.typeName ++ "_" ++ f.name
      let allTypeParams := tb.typeParams ++ f.typeParams
      let sig : FnSig := { params := f.params.map fun p => (p.name, resolveSelf p.ty implTy),
                            retTy := resolveSelf f.retTy implTy,
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
  -- Build named function signature map for fnRef resolution
  let fnSigPairs : List (String × FnSig) :=
    (m.functions.map fun f => (f.name, { params := f.params.map fun p => (p.name, p.ty),
                                          retTy := f.retTy, typeParams := f.typeParams,
                                          capParams := f.capParams, capSet := f.capSet })) ++
    (implMethodSigs ++ traitImplMethodSigs)
  let allStructs := importedStructs ++ m.structs
  -- Built-in Option<T> enum (Some { value: T }, None {})
  let builtinOptionEnum : EnumDef := {
    name := "Option"
    typeParams := ["T"]
    variants := [
      { name := "Some", fields := [{ name := "value", ty := .typeVar "T" }] },
      { name := "None", fields := [] }
    ]
    isCopy := false
  }
  let builtinResultEnum : EnumDef := {
    name := "Result"
    typeParams := ["T", "E"]
    variants := [
      { name := "Ok", fields := [{ name := "value", ty := .typeVar "T" }] },
      { name := "Err", fields := [{ name := "value", ty := .typeVar "E" }] }
    ]
    isCopy := false
  }
  let hasUserResult := m.enums.any fun ed => ed.name == "Result"
  let builtinEnumList := [builtinOptionEnum] ++ (if hasUserResult then [] else [builtinResultEnum])
  let allEnums := builtinEnumList ++ importedEnums ++ m.enums
  -- Build type aliases map
  let typeAliasMap : List (String × Ty) := m.typeAliases.map fun ta => (ta.name, ta.targetTy)
  -- Build constants map
  let constantsMap : List (String × Ty) := m.constants.map fun c => (c.name, c.ty)
  -- Build trait impl pairs for bound checking
  let traitImplPairs : List (String × String) := allTraitImpls.map fun tb => (tb.typeName, tb.traitName)
  let initEnv : TypeEnv :=
    { vars := [], structs := allStructs, enums := allEnums, functions := allSigs,
      fnNames := allNames, loopDepth := 0, typeAliases := typeAliasMap, constants := constantsMap,
      traitImpls := traitImplPairs, allFnSigs := fnSigPairs }
  -- Helper: check if a type is copy (pure context, uses struct/enum defs)
  let isCopyTyPure : Ty → Bool := fun ty =>
    match ty with
    | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
    | .bool | .float64 | .float32 | .char | .unit => true
    | .ref _ => true
    | .ptrMut _ | .ptrConst _ => true
    | .never => true
    | .named name =>
      match m.structs.find? fun sd => sd.name == name with
      | some sd => sd.isCopy
      | none => match m.enums.find? fun ed => ed.name == name with
        | some ed => ed.isCopy
        | none => false
    | _ => false
  -- Validate Copy structs/enums don't implement Destroy, and all fields are copy
  let copyStructCheck := m.structs.foldl (init := (Except.ok () : Except String Unit)) fun acc sd =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if sd.isCopy then
        if m.traitImpls.any fun tb => tb.traitName == "Destroy" && tb.typeName == sd.name then
          .error s!"type '{sd.name}' implements Destroy and cannot be Copy"
        else
          -- Check all fields are copy types
          match sd.fields.find? fun f => !isCopyTyPure f.ty with
          | some f => .error s!"Copy struct '{sd.name}' contains non-copy field '{f.name}'"
          | none => .ok ()
      else .ok ()
  match copyStructCheck with
  | .error e => .error e
  | .ok () =>
  let copyEnumCheck := m.enums.foldl (init := (Except.ok () : Except String Unit)) fun acc ed =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if ed.isCopy && (m.traitImpls.any fun tb => tb.traitName == "Destroy" && tb.typeName == ed.name) then
        .error s!"type '{ed.name}' implements Destroy and cannot be Copy"
      else .ok ()
  match copyEnumCheck with
  | .error e => .error e
  | .ok () =>
  -- Check user doesn't declare trait Destroy
  let destroyTraitCheck := m.traits.foldl (init := (Except.ok () : Except String Unit)) fun acc td =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if td.name == "Destroy" then .error "'Destroy' is a built-in trait"
      else .ok ()
  match destroyTraitCheck with
  | .error e => .error e
  | .ok () =>
  -- Reserved top-level function names
  let reservedNameCheck := m.functions.foldl (init := (Except.ok () : Except String Unit)) fun acc f =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if f.name == "destroy" || f.name == "abort" || f.name == "alloc" || f.name == "free"
         || f.name == "alloc_array" || f.name == "free_array" || f.name == "realloc_array" then
        .error s!"'{f.name}' is a reserved identifier"
      else .ok ()
  match reservedNameCheck with
  | .error e => .error e
  | .ok () =>
  -- Built-in Destroy trait (users don't declare it, just impl it)
  let builtinDestroyTrait : TraitDef := {
    name := "Destroy"
    methods := [{ name := "destroy", params := [], retTy := .unit, selfKind := some .ref }]
  }
  let allTraits := builtinDestroyTrait :: m.traits
  -- Validate trait impls
  let traitCheck := m.traitImpls.foldlM (init := ()) fun () tb => do
    match allTraits.find? fun (td : TraitDef) => td.name == tb.traitName with
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
  -- Merge impl block type params into each method's typeParams, track impl type for Self
  let regularFns : List (FnDef × Option Ty) := m.functions.map fun f => (f, none)
  let implMethodPairs : List (FnDef × Option Ty) := allImplBlocks.foldl (fun acc ib =>
    let implTy := if ib.typeParams.isEmpty then Ty.named ib.typeName
                  else Ty.generic ib.typeName (ib.typeParams.map Ty.typeVar)
    acc ++ ib.methods.map fun f =>
      ({ f with typeParams := ib.typeParams ++ f.typeParams }, some implTy)
  ) []
  let traitImplMethodPairs : List (FnDef × Option Ty) := allTraitImpls.foldl (fun acc tb =>
    let implTy := if tb.typeParams.isEmpty then Ty.named tb.typeName
                  else Ty.generic tb.typeName (tb.typeParams.map Ty.typeVar)
    acc ++ tb.methods.map fun f =>
      ({ f with typeParams := tb.typeParams ++ f.typeParams }, some implTy)
  ) []
  let allFnPairs := regularFns ++ implMethodPairs ++ traitImplMethodPairs
  let result := allFnPairs.foldlM (fun () (f, implTy) => do
    let env ← getEnv
    setEnv { env with currentImplType := implTy, traits := allTraits }
    checkFn f
  ) () |>.run initEnv |>.run
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
                  typeBounds := f.typeBounds, capParams := f.capParams, capSet := f.capSet : FnSig })
    let subExports : List (String × ExportEntry) := m.submodules.foldl (fun acc2 (sub : Module) =>
      let subFns : List (String × FnSig) := sub.functions.map fun (f : FnDef) =>
        (f.name, { params := f.params.map fun (p : Param) => (p.name, p.ty), retTy := f.retTy,
                    typeBounds := f.typeBounds, capParams := f.capParams, capSet := f.capSet : FnSig })
      let entry : ExportEntry := (subFns, sub.structs, sub.enums, sub.implBlocks, sub.traitImpls)
      -- Register under both qualified (parent.sub) and unqualified (sub) names
      acc2 ++ [(m.name ++ "." ++ sub.name, entry), (sub.name, entry)]
    ) ([] : List (String × ExportEntry))
    acc ++ [(m.name, (pubFns, m.structs, m.enums, m.implBlocks, m.traitImpls))] ++ subExports
  ) []
  -- Second pass: resolve imports and type-check each module
  let go := modules.foldlM (init := ()) fun () m => do
    let (impFns, impStructs, impEnums, impImpls, impTraitImpls) ← resolveImports m exportTable
    checkModule m impFns impStructs impEnums impImpls impTraitImpls
  go

end Concrete
