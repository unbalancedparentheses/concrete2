import Concrete.AST
import Concrete.FileSummary

namespace Concrete

/-! ## Type Checker with Linear Variable Tracking

Pipeline: Source → Parse → Resolve → **Check** → Elab → CoreCheck → Mono → Lower → SSAVerify → EmitSSA → clang

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
  newtypes : List NewtypeDef := []         -- all newtype definitions
  deriving Repr

abbrev CheckM := ExceptT String (StateM TypeEnv)

inductive CheckError where
  -- Slice 1: Name/variable/linearity
  | selfOutsideImpl
  | undeclaredVariable (name : String)
  | assignToUndeclaredVariable (name : String)
  | variableFrozenByBorrow (name : String)
  | cannotMoveLinearBorrowed (name : String)
  | variableUsedAfterMove (name : String)
  | variableReservedByDefer (name : String)
  | cannotConsumeLinearInLoop (name : String)
  | linearVariableNeverConsumed (name : String)
  | matchConsumptionDisagreement (name : String)
  | breakSkipsUnconsumedLinear (name : String)
  | continueSkipsUnconsumedLinear (name : String)
  | linearConsumedOneBranchNotOther (name : String)
  | linearConsumedNoBranch (name : String) (ctx : String)
  | borrowRefShadows (ref : String)
  | borrowRegionShadows (region : String)
  | unknownLoopLabel (label : String)
  | assignToImmutable (name : String)
  | assignToFrozen (name : String)
  | assignToBorrowed (name : String)
  -- Slice 2: Type mismatch / operator
  | typeMismatch (ctx : String) (expected : String) (actual : String)
  | bitwiseOpNotInteger (ty : String)
  | bitwiseNotNotInteger (ty : String)
  | conditionNotBool (ctx : String) (ty : String)
  | arrayIndexNotInteger (ty : Option String)
  | indexingNonArray (ty : Option String)
  | cannotCast (fromTy : String) (toTy : String)
  | cannotDerefNonRef
  | whileBreakTypeMismatch (breakTy : String) (elseTy : String)
  | breakTypeMismatch (valTy : String) (prevTy : String)
  | cannotAssignThroughNonMutRef
  | arrayLiteralEmpty
  -- Slice 3: Borrow/escape/freeze
  | cannotBorrowMoved (name : String)
  | cannotBorrowMutablyBorrowed (name : String)
  | cannotMutBorrowAlreadyBorrowed (name : String)
  | cannotMutBorrowAlreadyMutBorrowed (name : String)
  | cannotMutBorrowImmutable (name : String)
  | referenceEscapesBorrowBlock (name : String)
  | variableAlreadyMutBorrowed (name : String)
  | cannotMutBorrowImmBorrowed (name : String)
  | cannotImmBorrowMutBorrowed (name : String)
  -- Slice 4: Capability
  | missingCapability (callee : String) (cap : String) (caller : String)
  | traitBoundNotSatisfied (typeName : String) (traitName : String) (context : String)
  | cannotInferCapVariable (cap : String) (fnName : String)
  -- Slice 5: Struct/enum/field + function calls
  | unknownStructType (name : String)
  | structHasNoField (structName : String) (fieldName : String)
  | missingFieldInLiteral (fieldName : String) (containerDesc : String)
  | unknownFieldInLiteral (fieldName : String) (containerDesc : String)
  | fieldAccessNonStruct
  | heapAccessRequired (field : String) (ty : String)
  | arrowAccessNotHeap (ty : String)
  | arrowAccessNonStruct
  | arrowAssignNotHeap (ty : String)
  | arrowAssignNonStruct
  | unknownVariant (variant : String) (enumName : String)
  | unknownEnumType (name : String)
  | matchArmWrongEnum (armEnum : String) (scrutineeEnum : String)
  | duplicateMatchArm (variant : String)
  | variantFieldCountMismatch (variant : String) (expected : Nat) (actual : Nat)
  | nonExhaustiveMatch (missingVariant : String)
  | wrongArgCount (calleeDesc : String) (expected : Nat) (actual : Nat)
  | undeclaredFunction (name : String)
  | noMethodOnType (method : String) (typeName : String)
  | noMethodOnTypeVar (method : String) (typeVar : String)
  | methodCallOnNonNamedType
  | unknownFunctionRef (name : String)
  | builtinWrongArgCount (fnName : String) (expected : Nat)
  | builtinWrongTypeArgCount (fnName : String) (desc : String)
  | builtinWrongFirstArg (fnName : String) (expectedDesc : String) (actualTy : String)
  | builtinBadKeyType (fnName : String) (ty : String)
  | destroyRequiresNamed (ty : String)
  | typeDoesNotImplDestroy (typeName : String)
  | freeRequiresHeap (ty : String)
  | tryRequiresResult
  | tryRequiresOkErrVariants
  | tryOkNoField (enumName : String)
  -- Slice 6: Control flow/defer + module validation
  | breakOutsideLoop
  | breakInDefer
  | continueOutsideLoop
  | continueInDefer
  | deferBodyNotCall
  | copyDestroyConflict (typeName : String)
  | copyFieldNotCopy (structName : String) (fieldName : String)
  | builtinTraitRedeclared
  | reservedName (name : String)
  | unknownTrait (name : String)
  | missingTraitMethod (typeName : String) (methodName : String)
  | traitMethodRetTyMismatch (methodName : String) (expectedRetTy : String) (actualRetTy : String)
  | unknownModule (name : String)
  | notPublicInModule (symbol : String) (moduleName : String)
  -- Slice 7: repr(C) / FFI safety
  | reprCHasGenerics (structName : String)
  | reprCFieldNotFFISafe (structName : String) (fieldName : String) (fieldTy : String)
  | externFnParamNotFFISafe (fnName : String) (paramName : String) (paramTy : String)
  | externFnReturnNotFFISafe (fnName : String) (retTy : String)
  -- Slice 8: Unsafe boundary
  | rawPtrDerefRequiresUnsafe
  | rawPtrAssignRequiresUnsafe
  | unsafeCastRequiresUnsafe (fromTy : String) (toTy : String)
  -- Slice 9: repr(align/packed) validation
  | reprPackedAndAlignConflict (structName : String)
  | reprAlignNotPowerOfTwo (structName : String) (n : Nat)

def CheckError.message : CheckError → String
  -- Slice 1
  | .selfOutsideImpl => "Self can only be used inside impl blocks"
  | .undeclaredVariable name => s!"use of undeclared variable '{name}'"
  | .assignToUndeclaredVariable name => s!"assignment to undeclared variable '{name}'"
  | .variableFrozenByBorrow name => s!"variable '{name}' is frozen by borrow block"
  | .cannotMoveLinearBorrowed name => s!"cannot move linear variable '{name}': variable is borrowed"
  | .variableUsedAfterMove name => s!"linear variable '{name}' used after move"
  | .variableReservedByDefer name => s!"variable '{name}' is reserved by defer"
  | .cannotConsumeLinearInLoop name => s!"cannot consume linear variable '{name}' inside a loop (declared outside the loop)"
  | .linearVariableNeverConsumed name => s!"linear variable '{name}' was never consumed"
  | .matchConsumptionDisagreement name => s!"match arms disagree on consumption of '{name}'"
  | .breakSkipsUnconsumedLinear name => s!"break would skip unconsumed linear variable '{name}'"
  | .continueSkipsUnconsumedLinear name => s!"continue would skip unconsumed linear variable '{name}'"
  | .linearConsumedOneBranchNotOther name => s!"linear variable '{name}' consumed in one branch of if/else but not the other"
  | .linearConsumedNoBranch name ctx => s!"linear variable '{name}' consumed in {ctx} then-branch (no else branch to match)"
  | .borrowRefShadows ref => s!"borrow ref '{ref}' shadows existing name"
  | .borrowRegionShadows region => s!"borrow region '{region}' shadows existing name"
  | .unknownLoopLabel label => s!"unknown loop label '{label}'"
  | .assignToImmutable name => s!"cannot assign to immutable variable '{name}'"
  | .assignToFrozen name => s!"cannot assign to '{name}': variable is frozen by borrow block"
  | .assignToBorrowed name => s!"cannot assign to '{name}': variable is borrowed"
  -- Slice 2
  | .typeMismatch ctx expected actual => s!"type mismatch in {ctx}: expected {expected}, got {actual}"
  | .bitwiseOpNotInteger ty => s!"type mismatch in bitwise op: expected integer type, got {ty}"
  | .bitwiseNotNotInteger ty => s!"type mismatch in bitwise not: expected integer type, got {ty}"
  | .conditionNotBool ctx ty => s!"{ctx} condition must be bool, got {ty}"
  | .arrayIndexNotInteger (some ty) => s!"type mismatch: array index must be an integer type, got {ty}"
  | .arrayIndexNotInteger none => "type mismatch: array index must be an integer type"
  | .indexingNonArray (some ty) => s!"type mismatch: indexing into non-array type {ty}"
  | .indexingNonArray none => "type mismatch: indexing into non-array type"
  | .cannotCast fromTy toTy => s!"cannot cast {fromTy} to {toTy}"
  | .cannotDerefNonRef => "cannot dereference non-reference type"
  | .whileBreakTypeMismatch breakTy elseTy => s!"while-expression break type '{breakTy}' does not match else type '{elseTy}'"
  | .breakTypeMismatch valTy prevTy => s!"break value type '{valTy}' does not match previous break type '{prevTy}'"
  | .cannotAssignThroughNonMutRef => "cannot assign through non-mutable reference"
  | .arrayLiteralEmpty => "array literal cannot be empty"
  -- Slice 3
  | .cannotBorrowMoved name => s!"cannot borrow '{name}': already moved"
  | .cannotBorrowMutablyBorrowed name => s!"cannot borrow '{name}': already mutably borrowed"
  | .cannotMutBorrowAlreadyBorrowed name => s!"cannot mutably borrow '{name}': already borrowed"
  | .cannotMutBorrowAlreadyMutBorrowed name => s!"cannot mutably borrow '{name}': already mutably borrowed"
  | .cannotMutBorrowImmutable name => s!"cannot take mutable borrow of immutable variable '{name}'"
  | .referenceEscapesBorrowBlock name => s!"reference '{name}' cannot escape its borrow block"
  | .variableAlreadyMutBorrowed name => s!"variable '{name}' is already mutably borrowed"
  | .cannotMutBorrowImmBorrowed name => s!"cannot mutably borrow '{name}': already immutably borrowed"
  | .cannotImmBorrowMutBorrowed name => s!"cannot immutably borrow '{name}': already mutably borrowed"
  -- Slice 4
  | .missingCapability callee cap caller => s!"function '{callee}' requires capability '{cap}' but '{caller}' does not declare it"
  | .traitBoundNotSatisfied typeName traitName context => s!"type '{typeName}' does not implement trait '{traitName}' required by {context}"
  | .cannotInferCapVariable cap fnName => s!"cannot infer capability variable '{cap}' for call to '{fnName}'"
  -- Slice 5
  | .unknownStructType name => s!"unknown struct type '{name}'"
  | .structHasNoField structName fieldName => s!"struct '{structName}' has no field '{fieldName}'"
  | .missingFieldInLiteral fieldName containerDesc => s!"missing field '{fieldName}' in {containerDesc}"
  | .unknownFieldInLiteral fieldName containerDesc => s!"unknown field '{fieldName}' in {containerDesc}"
  | .fieldAccessNonStruct => "field access on non-struct type"
  | .heapAccessRequired field ty => s!"cannot access field '{field}' on {ty} with '.'; use '->' for heap access"
  | .arrowAccessNotHeap ty => s!"arrow access '->' requires Heap<T> or HeapArray<T> type, got {ty}"
  | .arrowAccessNonStruct => "arrow access '->' on non-struct inner type"
  | .arrowAssignNotHeap ty => s!"arrow assign '->' requires Heap<T> type, got {ty}"
  | .arrowAssignNonStruct => "arrow assign on non-struct inner type"
  | .unknownVariant variant enumName => s!"unknown variant '{variant}' in enum '{enumName}'"
  | .unknownEnumType name => s!"unknown enum type '{name}'"
  | .matchArmWrongEnum armEnum scrutineeEnum => s!"match arm has enum '{armEnum}' but scrutinee is '{scrutineeEnum}'"
  | .duplicateMatchArm variant => s!"duplicate match arm for variant '{variant}'"
  | .variantFieldCountMismatch variant expected actual => s!"variant '{variant}' has {expected} fields but arm binds {actual}"
  | .nonExhaustiveMatch missingVariant => s!"non-exhaustive match: missing variant '{missingVariant}'"
  | .wrongArgCount calleeDesc expected actual => s!"{calleeDesc} expects {expected} arguments, got {actual}"
  | .undeclaredFunction name => s!"call to undeclared function '{name}'"
  | .noMethodOnType method typeName => s!"no method '{method}' on type '{typeName}'"
  | .noMethodOnTypeVar method typeVar => s!"no method '{method}' for type variable '{typeVar}'"
  | .methodCallOnNonNamedType => "method call on non-named type"
  | .unknownFunctionRef name => s!"unknown function '{name}' in function reference"
  | .builtinWrongArgCount fnName expected =>
    if expected == 0 then s!"{fnName}() takes no arguments"
    else if expected == 1 then s!"{fnName}() takes exactly 1 argument"
    else s!"{fnName}() takes exactly {expected} arguments"
  | .builtinWrongTypeArgCount fnName desc => s!"{fnName} requires exactly {desc}"
  | .builtinWrongFirstArg fnName expectedDesc actualTy => s!"{fnName}() requires {expectedDesc}, got {actualTy}"
  | .builtinBadKeyType fnName ty => s!"{fnName}() key type must be Int or String, got {ty}"
  | .destroyRequiresNamed ty => s!"destroy() requires a named type, got {ty}"
  | .typeDoesNotImplDestroy typeName => s!"type '{typeName}' does not implement Destroy"
  | .freeRequiresHeap ty => s!"free() requires Heap<T> type, got {ty}"
  | .tryRequiresResult => "? operator requires a Result enum type"
  | .tryRequiresOkErrVariants => "? operator requires an enum with Ok and Err variants"
  | .tryOkNoField enumName => s!"Ok variant of '{enumName}' has no value field"
  -- Slice 6
  | .breakOutsideLoop => "break outside of loop"
  | .breakInDefer => "break is not allowed inside defer"
  | .continueOutsideLoop => "continue outside of loop"
  | .continueInDefer => "continue is not allowed inside defer"
  | .deferBodyNotCall => "defer body must be a function call"
  | .copyDestroyConflict typeName => s!"type '{typeName}' implements Destroy and cannot be Copy"
  | .copyFieldNotCopy structName fieldName => s!"Copy struct '{structName}' contains non-copy field '{fieldName}'"
  | .builtinTraitRedeclared => "'Destroy' is a built-in trait"
  | .reservedName name => s!"'{name}' is a reserved identifier"
  | .unknownTrait name => s!"unknown trait '{name}'"
  | .missingTraitMethod typeName methodName => s!"trait impl for '{typeName}' is missing method '{methodName}'"
  | .traitMethodRetTyMismatch methodName expectedRetTy actualRetTy => s!"method '{methodName}' signature does not match trait definition: expected return type {expectedRetTy}, got {actualRetTy}"
  | .unknownModule name => s!"unknown module '{name}'"
  | .notPublicInModule symbol moduleName => s!"'{symbol}' is not public in module '{moduleName}'"
  -- Slice 7
  | .reprCHasGenerics structName => s!"#[repr(C)] struct '{structName}' cannot have type parameters"
  | .reprCFieldNotFFISafe structName fieldName fieldTy => s!"#[repr(C)] struct '{structName}' has non-FFI-safe field '{fieldName}' of type {fieldTy}"
  | .externFnParamNotFFISafe fnName paramName paramTy => s!"extern fn '{fnName}' has non-FFI-safe parameter '{paramName}' of type {paramTy}"
  | .externFnReturnNotFFISafe fnName retTy => s!"extern fn '{fnName}' has non-FFI-safe return type {retTy}"
  -- Slice 8
  | .rawPtrDerefRequiresUnsafe => "dereferencing raw pointer requires Unsafe capability"
  | .rawPtrAssignRequiresUnsafe => "assigning through raw pointer requires Unsafe capability"
  | .unsafeCastRequiresUnsafe fromTy toTy => s!"cast from {fromTy} to {toTy} requires Unsafe capability"
  -- Slice 9
  | .reprPackedAndAlignConflict structName => s!"struct '{structName}' cannot have both #[repr(packed)] and #[repr(align(...))]"
  | .reprAlignNotPowerOfTwo structName n => s!"#[repr(align({n}))] on struct '{structName}' must be a power of two"

def throwCheck (e : CheckError) : CheckM α := throw e.message

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

/-- Is this a reference type? -/
def isReferenceType : Ty → Bool
  | .ref _ | .refMut _ => true
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
      | none => throwCheck .selfOutsideImpl
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
partial def isCopyType (ty : Ty) : CheckM Bool := do
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
    -- Check if the struct/enum has isCopy = true, or newtype wraps a Copy type
    let env ← getEnv
    match env.structs.find? fun sd => sd.name == name with
    | some sd => return sd.isCopy
    | none =>
      match env.enums.find? fun ed => ed.name == name with
      | some ed => return ed.isCopy
      | none =>
        match env.newtypes.find? fun nt => nt.name == name with
        | some nt => isCopyType nt.innerTy
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

def lookupNewtype (name : String) : CheckM (Option NewtypeDef) := do
  let env ← getEnv
  return env.newtypes.find? fun nt => nt.name == name

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
  else throwCheck (.typeMismatch ctx (tyToString expected) (tyToString actual))

-- ============================================================
-- Capability checking
-- ============================================================

/-- Check that caller's capabilities are a superset of callee's capabilities.
    This is the core of the effect system: if f calls g, f must have g's caps. -/
def checkCapabilities (calleeName : String) (calleeCapSet : CapSet) : CheckM Unit := do
  let env ← getEnv
  let callerCapSet := env.currentCapSet
  -- Get concrete caps and cap variables from both sides
  let (calleeCaps, _calleeVars) := calleeCapSet.normalize
  let (callerCaps, callerVars) := callerCapSet.normalize
  -- If callee has cap variables, they are satisfied by matching caller cap variables
  -- If caller has cap variables, they can satisfy any callee cap (polymorphic)
  -- Check each callee concrete cap exists in caller (concrete or variable)
  for cap in calleeCaps do
    unless callerCaps.contains cap || callerVars.contains cap do
      throwCheck (.missingCapability calleeName cap env.currentFnName)

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
      throwCheck (.variableFrozenByBorrow name)
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
  | none => throwCheck (.undeclaredVariable name)
  | some info =>
    if info.isCopy then return ()  -- Copy types are never consumed
    let activeRefs := activeBorrowRefs env name
    if activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
      throwCheck (.cannotMoveLinearBorrowed name)
    match info.state with
    | .consumed =>
      throwCheck (.variableUsedAfterMove name)
    | .reserved =>
      throwCheck (.variableReservedByDefer name)
    | .frozen =>
      throwCheck (.variableFrozenByBorrow name)
    | .unconsumed | .used =>
      -- Loop depth check
      if info.loopDepth < env.loopDepth then
        throwCheck (.cannotConsumeLinearInLoop name)
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
        throwCheck (.linearVariableNeverConsumed name)
    | none => pure ()

-- ============================================================
-- Type substitution for generics
-- ============================================================

/-- Peek at an expression's type without consuming any linear variables. -/
def peekExprType (e : Expr) : CheckM Ty := do
  match e with
  | .intLit _ _ => return .int
  | .floatLit _ _ => return .float64
  | .boolLit _ _ => return .bool
  | .strLit _ _ => return .string
  | .charLit _ _ => return .char
  | .ident _ name =>
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
  | .structLit _ name typeArgs _ =>
    if typeArgs.isEmpty then return .named name
    else return .generic name typeArgs
  | .enumLit _ enumName _ typeArgs _ =>
    if typeArgs.isEmpty then return .named enumName
    else return .generic enumName typeArgs
  | .fnRef _ name =>
    let env ← getEnv
    match env.allFnSigs.lookup name with
    | some sig =>
      let paramTys := sig.params.map Prod.snd
      return .fn_ paramTys sig.capSet sig.retTy
    | none => return .placeholder
  | .paren _ inner => peekExprType inner
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
            throwCheck (.traitBoundNotSatisfied tn traitName context)
      | none => pure ()  -- primitive types, skip bound checking
    | none => pure ()

-- ============================================================
-- Type checking expressions and statements
-- ============================================================

mutual

partial def checkExpr (e : Expr) (hint : Option Ty := none) : CheckM Ty := do
  match e with
  | .intLit _ _ =>
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
  | .floatLit _ _ =>
    match hint with
    | some ty =>
      let tyR ← resolveType ty
      if isFloatType tyR then return tyR else return .float64
    | none => return .float64
  | .boolLit _ _ => return .bool
  | .strLit _ _ => return .string
  | .charLit _ _ => return .char
  | .ident _ name =>
    -- First check if it's a constant
    let env ← getEnv
    match env.constants.lookup name with
    | some ty => return ty
    | none =>
    match ← lookupVarInfo name with
    | some info =>
      -- Reading a variable (not consuming). Check it's not already consumed.
      if !info.isCopy && info.state == .consumed then
        throwCheck (.variableUsedAfterMove name)
      useVar name
      return info.ty
    | none =>
      -- Check if it's a function name (first-class function reference)
      match ← lookupFn name with
      | some sig =>
        let paramTys := sig.params.map fun (_, t) => t
        return .fn_ paramTys sig.capSet sig.retTy
      | none => throwCheck (.undeclaredVariable name)
  | .binOp _ op lhs rhs =>
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
          throwCheck (.bitwiseOpNotInteger (tyToString lTyR))
        expectTy lTyR rTyR "bitwise operand types"
        return lTy
  | .unaryOp _ op operand =>
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
        throwCheck (.bitwiseNotNotInteger (tyToString ty))
  | .arrowAccess _ obj field =>
    let objTy ← checkExpr obj
    -- obj must be Heap<T> or HeapArray<T>
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | .ref (.heap t) => t
      | .refMut (.heap t) => t
      | _ => .placeholder
    if innerTy == .placeholder then
      throwCheck (.arrowAccessNotHeap (tyToString objTy))
    -- Look up field on the inner type
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    if structName == "" then throwCheck .arrowAccessNonStruct
    match ← lookupStruct structName with
    | some sd =>
      match sd.fields.find? fun f => f.name == field with
      | some f => resolveType f.ty
      | none => throwCheck (.structHasNoField structName field)
    | none => throwCheck (.unknownStructType structName)
  | .allocCall _ inner allocExpr =>
    -- Check that caller has Alloc capability (needed to forward)
    checkCapabilities "with(Alloc)" (.concrete ["Alloc"])
    -- Check the allocator expression is valid
    let _allocTy ← checkExpr allocExpr
    -- Check the inner call expression
    checkExpr inner hint
  | .whileExpr _ cond body elseBody =>
    -- while-as-expression: while cond { body } else { elseBody }
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throwCheck (.conditionNotBool "while" (tyToString condTy))
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
      | some (.expr _ e) => checkExpr e hint
      | some (.return_ _ v) =>
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
        throwCheck (.whileBreakTypeMismatch (tyToString bTy) (tyToString elseTy))
      return elseTy
    | none => return elseTy
  | .call _sp fnName typeArgs args =>
    -- Intercept newtype wrapping: NewtypeName(expr)
    match ← lookupNewtype fnName with
    | some nt =>
      if args.length != 1 then throw s!"newtype '{fnName}' constructor takes exactly 1 argument"
      if !typeArgs.isEmpty then throw s!"newtype '{fnName}' constructor does not take type arguments"
      -- For generic newtypes, infer type args from hint
      let inferredTypeArgs := if nt.typeParams.isEmpty then []
        else match hint with
          | some (.generic n hintArgs) => if n == fnName then hintArgs else []
          | _ => []
      let mapping := nt.typeParams.zip inferredTypeArgs
      let resolvedInnerTy := substTy mapping nt.innerTy
      let arg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let argTy ← checkExpr arg (some resolvedInnerTy)
      expectTy resolvedInnerTy argTy s!"newtype '{fnName}' constructor"
      -- Consume linear variables passed to newtype constructor (ownership moves)
      match arg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      if inferredTypeArgs.isEmpty then return .named fnName
      else return .generic fnName inferredTypeArgs
    | none =>
    -- Intercept sizeof::<T>() and alignof::<T>() builtins
    if fnName == "sizeof" || fnName == "alignof" then
      if args.length != 0 then throw s!"{fnName} takes no value arguments"
      if typeArgs.length != 1 then throw s!"{fnName} requires exactly 1 type argument: {fnName}::<T>()"
      return .uint
    -- Intercept unwrap(x) for newtype unwrapping (only if not a user-defined function)
    if fnName == "unwrap" && args.length == 1 then
      -- Check if unwrap is a user-defined function; if so, skip this intercept
      let isUserFn ← lookupFn "unwrap"
      if isUserFn.isNone then
        let arg := match args with | a :: _ => a | [] => Expr.intLit default 0
        let argTy ← checkExpr arg
        let ntName := match argTy with | .named n => n | _ => ""
        if ntName == "" then throw s!"unwrap() requires a newtype argument, got {tyToString argTy}"
        match ← lookupNewtype ntName with
        | some nt =>
          match arg with
          | .ident _ varName => consumeVarIfExists varName
          | _ => pure ()
          return nt.innerTy
        | none => throw s!"unwrap() requires a newtype argument, '{ntName}' is not a newtype"
    -- Intercept abort() calls
    if fnName == "abort" then
      if args.length != 0 then throwCheck (.builtinWrongArgCount "abort" 0)
      return .never
    -- Intercept destroy() calls
    if fnName == "destroy" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "destroy" 1)
      let arg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let argTy ← checkExpr arg
      -- Look up impl Destroy for the type
      let typeName := match argTy with
        | .named n => n
        | .generic n _ => n
        | _ => ""
      if typeName == "" then throwCheck (.destroyRequiresNamed (tyToString argTy))
      -- Search function signatures for TypeName_destroy
      let destroyFn ← lookupFn (typeName ++ "_destroy")
      match destroyFn with
      | some _ =>
        -- Consume the argument
        match arg with
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
        return .unit
      | none => throwCheck (.typeDoesNotImplDestroy typeName)
    -- Intercept alloc(val) calls
    if fnName == "alloc" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "alloc" 1)
      -- Require Alloc capability
      checkCapabilities "alloc" (.concrete ["Alloc"])
      let arg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let argTy ← checkExpr arg
      -- Consume linear variables passed to alloc (ownership moves to heap)
      match arg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .heap argTy
    -- Intercept free(ptr) calls
    if fnName == "free" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "free" 1)
      -- Require Alloc capability
      checkCapabilities "free" (.concrete ["Alloc"])
      let arg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let argTy ← checkExpr arg
      match argTy with
      | .heap innerTy =>
        -- Consume the argument (Heap<T> is linear)
        match arg with
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
        return innerTy
      | _ => throwCheck (.freeRequiresHeap (tyToString argTy))
    -- Intercept vec_new::<T>()
    if fnName == "vec_new" then
      if args.length != 0 then throwCheck (.builtinWrongArgCount "vec_new" 0)
      if typeArgs.length != 1 then throwCheck (.builtinWrongTypeArgCount "vec_new" "1 type argument: vec_new::<T>()")
      checkCapabilities "vec_new" (.concrete ["Alloc"])
      let elemTy := match typeArgs with | t :: _ => t | [] => Ty.int
      return .generic "Vec" [elemTy]
    -- Intercept vec_push(&mut v, val)
    if fnName == "vec_push" then
      if args.length != 2 then throwCheck (.builtinWrongArgCount "vec_push" 2)
      checkCapabilities "vec_push" (.concrete ["Alloc"])
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let valArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let elemTy := match vecTy with
        | .refMut (.generic "Vec" [et]) => et
        | _ => Ty.placeholder
      if elemTy == .placeholder then throwCheck (.builtinWrongFirstArg "vec_push" "&mut Vec<T> as first argument" (tyToString vecTy))
      let valTy ← checkExpr valArg (some elemTy)
      expectTy elemTy valTy "vec_push() element argument"
      match valArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .unit
    -- Intercept vec_get(&v, idx)
    if fnName == "vec_get" then
      if args.length != 2 then throwCheck (.builtinWrongArgCount "vec_get" 2)
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let elemTy := match vecTy with
        | .ref (.generic "Vec" [et]) => et
        | .refMut (.generic "Vec" [et]) => et
        | _ => Ty.placeholder
      if elemTy == .placeholder then throwCheck (.builtinWrongFirstArg "vec_get" "&Vec<T> or &mut Vec<T> as first argument" (tyToString vecTy))
      let idxTy ← checkExpr idxArg (some .int)
      expectTy .int idxTy "vec_get() index argument"
      return elemTy
    -- Intercept vec_set(&mut v, idx, val)
    if fnName == "vec_set" then
      if args.length != 3 then throwCheck (.builtinWrongArgCount "vec_set" 3)
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let elemTy := match vecTy with
        | .refMut (.generic "Vec" [et]) => et
        | _ => Ty.placeholder
      if elemTy == .placeholder then throwCheck (.builtinWrongFirstArg "vec_set" "&mut Vec<T> as first argument" (tyToString vecTy))
      let idxTy ← checkExpr idxArg (some .int)
      expectTy .int idxTy "vec_set() index argument"
      let valTy ← checkExpr valArg (some elemTy)
      expectTy elemTy valTy "vec_set() value argument"
      match valArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .unit
    -- Intercept vec_len(&v)
    if fnName == "vec_len" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "vec_len" 1)
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let ok := match vecTy with
        | .ref (.generic "Vec" _) => true
        | .refMut (.generic "Vec" _) => true
        | _ => false
      if !ok then throwCheck (.builtinWrongFirstArg "vec_len" "&Vec<T> or &mut Vec<T> as argument" (tyToString vecTy))
      return .int
    -- Intercept vec_pop(&mut v)
    if fnName == "vec_pop" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "vec_pop" 1)
      checkCapabilities "vec_pop" (.concrete ["Alloc"])
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let elemTy := match vecTy with
        | .refMut (.generic "Vec" [et]) => et
        | _ => Ty.placeholder
      if elemTy == .placeholder then throwCheck (.builtinWrongFirstArg "vec_pop" "&mut Vec<T> as argument" (tyToString vecTy))
      return .generic "Option" [elemTy]
    -- Intercept vec_free(v)
    if fnName == "vec_free" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "vec_free" 1)
      checkCapabilities "vec_free" (.concrete ["Alloc"])
      let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let vecTy ← checkExpr vecArg
      let ok := match vecTy with
        | .generic "Vec" _ => true
        | _ => false
      if !ok then throwCheck (.builtinWrongFirstArg "vec_free" "Vec<T> as argument" (tyToString vecTy))
      match vecArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .unit
    -- Intercept map_new::<K, V>()
    if fnName == "map_new" then
      if args.length != 0 then throwCheck (.builtinWrongArgCount "map_new" 0)
      if typeArgs.length != 2 then throwCheck (.builtinWrongTypeArgCount "map_new" "2 type arguments: map_new::<K, V>()")
      checkCapabilities "map_new" (.concrete ["Alloc"])
      let kTy := match typeArgs with | t :: _ => t | [] => Ty.int
      let vTy := match typeArgs with | _ :: t :: _ => t | _ => Ty.int
      -- Validate key type is Int or String
      let keyOk := match kTy with | .int => true | .string => true | _ => false
      if !keyOk then throwCheck (.builtinBadKeyType "map_new" (tyToString kTy))
      return .generic "HashMap" [kTy, vTy]
    -- Intercept map_insert(&mut m, key, val)
    if fnName == "map_insert" then
      if args.length != 3 then throwCheck (.builtinWrongArgCount "map_insert" 3)
      checkCapabilities "map_insert" (.concrete ["Alloc"])
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let (kTy, vTy) := match mapTy with
        | .refMut (.generic "HashMap" [k, v]) => (k, v)
        | _ => (Ty.placeholder, Ty.placeholder)
      if kTy == .placeholder then throwCheck (.builtinWrongFirstArg "map_insert" "&mut HashMap<K,V> as first argument" (tyToString mapTy))
      let keyTy ← checkExpr keyArg (some kTy)
      expectTy kTy keyTy "map_insert() key argument"
      match keyArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      let valTy ← checkExpr valArg (some vTy)
      expectTy vTy valTy "map_insert() value argument"
      match valArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .unit
    -- Intercept map_get(&m, key)
    if fnName == "map_get" then
      if args.length != 2 then throwCheck (.builtinWrongArgCount "map_get" 2)
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let (kTy, vTy) := match mapTy with
        | .ref (.generic "HashMap" [k, v]) => (k, v)
        | .refMut (.generic "HashMap" [k, v]) => (k, v)
        | _ => (Ty.placeholder, Ty.placeholder)
      if kTy == .placeholder then throwCheck (.builtinWrongFirstArg "map_get" "&HashMap<K,V> or &mut HashMap<K,V> as first argument" (tyToString mapTy))
      let keyTy ← checkExpr keyArg (some kTy)
      expectTy kTy keyTy "map_get() key argument"
      match keyArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .generic "Option" [vTy]
    -- Intercept map_contains(&m, key)
    if fnName == "map_contains" then
      if args.length != 2 then throwCheck (.builtinWrongArgCount "map_contains" 2)
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let kTy := match mapTy with
        | .ref (.generic "HashMap" [k, _]) => k
        | .refMut (.generic "HashMap" [k, _]) => k
        | _ => Ty.placeholder
      if kTy == .placeholder then throwCheck (.builtinWrongFirstArg "map_contains" "&HashMap<K,V> or &mut HashMap<K,V> as first argument" (tyToString mapTy))
      let keyTy ← checkExpr keyArg (some kTy)
      expectTy kTy keyTy "map_contains() key argument"
      match keyArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .bool
    -- Intercept map_remove(&mut m, key)
    if fnName == "map_remove" then
      if args.length != 2 then throwCheck (.builtinWrongArgCount "map_remove" 2)
      checkCapabilities "map_remove" (.concrete ["Alloc"])
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let (kTy, vTy) := match mapTy with
        | .refMut (.generic "HashMap" [k, v]) => (k, v)
        | _ => (Ty.placeholder, Ty.placeholder)
      if kTy == .placeholder then throwCheck (.builtinWrongFirstArg "map_remove" "&mut HashMap<K,V> as first argument" (tyToString mapTy))
      let keyTy ← checkExpr keyArg (some kTy)
      expectTy kTy keyTy "map_remove() key argument"
      match keyArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .generic "Option" [vTy]
    -- Intercept map_len(&m)
    if fnName == "map_len" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "map_len" 1)
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let ok := match mapTy with
        | .ref (.generic "HashMap" _) => true
        | .refMut (.generic "HashMap" _) => true
        | _ => false
      if !ok then throwCheck (.builtinWrongFirstArg "map_len" "&HashMap<K,V> or &mut HashMap<K,V> as argument" (tyToString mapTy))
      return .int
    -- Intercept map_free(m)
    if fnName == "map_free" then
      if args.length != 1 then throwCheck (.builtinWrongArgCount "map_free" 1)
      checkCapabilities "map_free" (.concrete ["Alloc"])
      let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
      let mapTy ← checkExpr mapArg
      let ok := match mapTy with
        | .generic "HashMap" _ => true
        | _ => false
      if !ok then throwCheck (.builtinWrongFirstArg "map_free" "HashMap<K,V> as argument" (tyToString mapTy))
      match mapArg with
      | .ident _ varName => consumeVarIfExists varName
      | _ => pure ()
      return .unit
    -- Check if this is a function pointer call (variable with fn_ type)
    let fnPtrVarTy ← lookupVarTy fnName
    match fnPtrVarTy with
    | some (.fn_ paramTys fnPtrCapSet fnPtrRetTy) =>
      -- Function pointer call: check capabilities
      checkCapabilities fnName fnPtrCapSet
      -- Check argument count
      if args.length != paramTys.length then
        throwCheck (.wrongArgCount s!"function pointer '{fnName}'" paramTys.length args.length)
      -- Check each argument type
      for (arg, pTy) in args.zip paramTys do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument of function pointer call '{fnName}'"
        match arg with
        | .ident _ varName => consumeVarIfExists varName
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
                      | .ident _ varName =>
                        match ← lookupFn varName with
                        | some argSig => pure argSig.capSet
                        | none => pure CapSet.empty
                      | _ => pure CapSet.empty
                  let (argCaps, _) := argCapSet.normalize
                  capBindings := capBindings ++ [(cap, argCaps)]
            | _ => pure ()
          -- Build resolved capSet
          let (concreteCaps, capVars) := sig.capSet.normalize
          let mut resolvedCaps : List String := []
          for cap in concreteCaps do
            if sig.capParams.contains cap then
              match capBindings.find? fun (name, _) => name == cap with
              | some (_, caps) => resolvedCaps := resolvedCaps ++ caps
              | none => throwCheck (.cannotInferCapVariable cap fnName)
            else
              resolvedCaps := resolvedCaps ++ [cap]
          -- Also resolve cap variables (e.g. .var "C" → bound caps)
          for cv in capVars do
            match capBindings.find? fun (name, _) => name == cv with
            | some (_, caps) => resolvedCaps := resolvedCaps ++ caps
            | none => throwCheck (.cannotInferCapVariable cv fnName)
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
        throwCheck (.wrongArgCount s!"function '{fnName}'" paramTypes.length args.length)
      for (arg, (pName, pTy)) in args.zip paramTypes do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{fnName}'"
        -- If arg is a bare identifier of a linear type, consume it
        match arg with
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
      return retTy
    | none =>
      -- sizeof intrinsic
      if fnName == "sizeof" || fnName.endsWith "_sizeof" then return .uint
      else throwCheck (.undeclaredFunction fnName)
  | .paren _ inner => checkExpr inner hint
  | .structLit _ name typeArgs fields =>
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
          | .ident _ varName => consumeVarIfExists varName
          | _ => pure ()
        | none =>
          -- Unions allow partial initialization (only one field set)
          if !sd.isUnion then
            throwCheck (.missingFieldInLiteral sf.name s!"struct literal '{name}'")
      for (fn, _) in fields do
        match sd.fields.find? fun sf => sf.name == fn with
        | some _ => pure ()
        | none => throwCheck (.unknownFieldInLiteral fn s!"struct literal '{name}'")
      if typeArgs.isEmpty then return .named name
      else return .generic name typeArgs
    | none => throwCheck (.unknownStructType name)
  | .fieldAccess _ obj field =>
    let objTy ← checkExpr obj
    -- Prevent direct field access on Heap<T> — must use ->
    match objTy with
    | .heap _ => throwCheck (.heapAccessRequired field (tyToString objTy))
    | .heapArray _ => throwCheck (.heapAccessRequired field (tyToString objTy))
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
    if structName == "" then throwCheck .fieldAccessNonStruct
    else
      -- Check for newtype .0 unwrap
      match ← lookupNewtype structName with
      | some nt =>
        if field == "0" then
          -- Consume the newtype variable if linear
          match obj with
          | .ident _ varName => consumeVarIfExists varName
          | _ => pure ()
          -- Substitute type params for generic newtypes
          let mapping := nt.typeParams.zip typeArgs
          return substTy mapping nt.innerTy
        else throw s!"newtype '{structName}' only supports .0 field access"
      | none =>
      match ← lookupStruct structName with
      | some sd =>
        match sd.fields.find? fun f => f.name == field with
        | some f =>
          let mapping := sd.typeParams.zip typeArgs
          resolveType (substTy mapping f.ty)
        | none => throwCheck (.structHasNoField structName field)
      | none => throwCheck .fieldAccessNonStruct
  | .enumLit _ enumName variant typeArgs fields =>
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
            | .ident _ varName => consumeVarIfExists varName
            | _ => pure ()
          | none => throwCheck (.missingFieldInLiteral sf.name s!"{enumName}#{variant}")
        for (fn, _) in fields do
          match ev.fields.find? fun sf => sf.name == fn with
          | some _ => pure ()
          | none => throwCheck (.unknownFieldInLiteral fn s!"{enumName}#{variant}")
        if effectiveTypeArgs.isEmpty then return .named enumName
        else return .generic enumName effectiveTypeArgs
      | none => throwCheck (.unknownVariant variant enumName)
    | none => throwCheck (.unknownEnumType enumName)
  | .match_ _ scrutinee arms =>
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
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
        -- Check exhaustiveness: every variant must appear, no duplicates
        let mut seenVariants : List String := []
        for arm in arms do
          match arm with
          | .mk _ armEnum armVariant bindings _body =>
            if armEnum != enumName then
              throwCheck (.matchArmWrongEnum armEnum enumName)
            match ed.variants.find? fun v => v.name == armVariant with
            | some ev =>
              if seenVariants.contains armVariant then
                throwCheck (.duplicateMatchArm armVariant)
              seenVariants := seenVariants ++ [armVariant]
              -- Allow 0 bindings (ignore payload) or exact match
              if bindings.length != 0 && bindings.length != ev.fields.length then
                throwCheck (.variantFieldCountMismatch armVariant ev.fields.length bindings.length)
            | none => throwCheck (.unknownVariant armVariant enumName)
          | .litArm _ _ _ => pure ()
          | .varArm _ _ _ => pure ()
        -- Check all variants covered
        for v in ed.variants do
          if !seenVariants.contains v.name then
            throwCheck (.nonExhaustiveMatch v.name)
        -- Linearity across arms: snapshot env, check each arm, ensure all agree
        let envBefore ← getEnv
        let mut firstArmVars : Option (List (String × VarInfo)) := none
        for arm in arms do
          setEnv envBefore
          match arm with
          | .mk _ _armEnum armVariant bindings body =>
            -- Bind variant fields in scope (substitute generic type args)
            let ev := (ed.variants.find? fun v => v.name == armVariant).get!
            let typeMapping := ed.typeParams.zip enumTypeArgs
            for (binding, sf) in bindings.zip ev.fields do
              addVar binding (substTy typeMapping sf.ty)
            let curEnv ← getEnv
            checkStmts body curEnv.currentRetTy
          | .litArm _ _val body =>
            checkStmts body envBefore.currentRetTy
          | .varArm _ binding body =>
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
                throwCheck (.matchConsumptionDisagreement name)
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
      | none => throwCheck (.unknownEnumType enumName)
    else
      -- Value-pattern match (integer/bool literals, variable bindings)
      match scrutinee with
      | .ident _ varName => useVar varName
      | _ => pure ()
      let envBefore ← getEnv
      let mut resultTy := scrTy
      for arm in arms do
        setEnv envBefore
        match arm with
        | .litArm _ _val body =>
          checkStmts body envBefore.currentRetTy
        | .varArm _ binding body =>
          addVar binding scrTy
          checkStmts body envBefore.currentRetTy
        | .mk _ _ _ _ body =>
          checkStmts body envBefore.currentRetTy
      setEnv envBefore
      return resultTy
  | .borrow _ inner =>
    let innerTy ← checkExpr inner
    -- Check the variable is not moved or already mutably borrowed
    match inner with
    | .ident _ varName =>
      match ← lookupVarInfo varName with
      | some info =>
        if !info.isCopy && info.state == .consumed then
          throwCheck (.cannotBorrowMoved varName)
        let env ← getEnv
        let activeRefs := activeBorrowRefs env varName
        if info.mutBorrowed || activeRefs.any (fun refInfo => match refInfo.ty with | .refMut _ => true | _ => false) then
          throwCheck (.cannotBorrowMutablyBorrowed varName)
      | none => throwCheck (.undeclaredVariable varName)
    | _ => pure ()
    return .ref innerTy
  | .borrowMut _ inner =>
    let innerTy ← checkExpr inner
    match inner with
    | .ident _ varName =>
      match ← lookupVarInfo varName with
      | some info =>
        if !info.isCopy && info.state == .consumed then
          throwCheck (.cannotBorrowMoved varName)
        let env ← getEnv
        let activeRefs := activeBorrowRefs env varName
        if info.borrowCount > 0 || activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
          throwCheck (.cannotMutBorrowAlreadyBorrowed varName)
        if info.mutBorrowed then
          throwCheck (.cannotMutBorrowAlreadyMutBorrowed varName)
        if !info.mutable then
          throwCheck (.cannotMutBorrowImmutable varName)
      | none => throwCheck (.undeclaredVariable varName)
    | _ => pure ()
    return .refMut innerTy
  | .deref _ inner =>
    let innerTy ← checkExpr inner
    match innerTy with
    | .ref t => return t
    | .refMut t => return t
    | .ptrMut t =>
      checkCapabilities "*raw_ptr" (.concrete ["Unsafe"])
      return t
    | .ptrConst t =>
      checkCapabilities "*raw_ptr" (.concrete ["Unsafe"])
      return t
    | .heap t =>
      -- *heap_ptr: loads value from heap, frees memory, consumes the Heap<T>
      -- Requires Alloc capability (heap deallocation)
      checkCapabilities "*heap_ptr" (.concrete ["Alloc"])
      match inner with
      | .ident _ varName => consumeVar varName
      | _ => pure ()
      return t
    | _ => throwCheck .cannotDerefNonRef
  | .try_ _ inner =>
    let innerTy ← checkExpr inner
    -- Consume the inner expression if it's a variable
    match inner with
    | .ident _ name => consumeVar name
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
          | none => throwCheck (.tryOkNoField enumName)
        | _, _ => throwCheck .tryRequiresOkErrVariants
      | none => throwCheck (.unknownEnumType enumName)
    | _ => throwCheck .tryRequiresResult
  | .arrayLit _ elems =>
    match elems with
    | [] => throwCheck .arrayLiteralEmpty
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
  | .arrayIndex _ arr index =>
    let arrTy ← checkExpr arr
    let idxTy ← checkExpr index
    if !isIntegerType idxTy then
      throwCheck (.arrayIndexNotInteger (some (tyToString idxTy)))
    match arrTy with
    | .array elemTy _ => return elemTy
    | _ => throwCheck (.indexingNonArray (some (tyToString arrTy)))
  | .cast _ inner targetTy =>
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
    if !valid then throwCheck (.cannotCast (tyToString innerTy) (tyToString targetTy))
    -- Unsafe capability check for pointer-involving casts (except safe ref-to-ptr)
    let isRefToPtr := isReferenceType innerTy && isPointerType targetTy
    let involvesPointer := isPointerType innerTy || isPointerType targetTy ||
                           (match innerTy with | .array _ _ => isPointerType targetTy | _ => false)
    if involvesPointer && !isRefToPtr then
      checkCapabilities "unsafe_cast" (.concrete ["Unsafe"])
    return targetTy
  | .methodCall _ obj methodName typeArgs args =>
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
        | none => throwCheck (.noMethodOnTypeVar methodName n)
        | some sig =>
          -- Check capabilities from trait method
          checkCapabilities (n ++ "." ++ methodName) sig.capSet
          -- Type check arguments (params in FnSigDef excludes self)
          if args.length != sig.params.length then
            throwCheck (.wrongArgCount s!"method '{methodName}'" sig.params.length args.length)
          for (arg, p) in args.zip sig.params do
            let argTy ← checkExpr arg (some p.ty)
            expectTy p.ty argTy s!"argument '{p.name}' of '{methodName}'"
            match arg with
            | .ident _ varName => consumeVarIfExists varName
            | _ => pure ()
          return sig.retTy
      | _ => throwCheck .methodCallOnNonNamedType
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
        throwCheck (.wrongArgCount s!"method '{methodName}'" methodParams.length args.length)
      for (arg, (pName, pTy)) in args.zip methodParams do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{methodName}'"
        match arg with
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
      return retTy
    | none => throwCheck (.noMethodOnType methodName typeName)
  | .staticMethodCall _ typeName methodName typeArgs args =>
    let mangledName := typeName ++ "_" ++ methodName
    match ← lookupFn mangledName with
    | some sig =>
      -- Check capabilities
      checkCapabilities (typeName ++ "::" ++ methodName) sig.capSet
      let mapping := sig.typeParams.zip typeArgs
      let paramTypes := sig.params.map fun (n, t) => (n, substTy mapping t)
      let retTy := substTy mapping sig.retTy
      if args.length != paramTypes.length then
        throwCheck (.wrongArgCount s!"static method '{methodName}'" paramTypes.length args.length)
      for (arg, (pName, pTy)) in args.zip paramTypes do
        let argTy ← checkExpr arg (some pTy)
        expectTy pTy argTy s!"argument '{pName}' of '{typeName}::{methodName}'"
        match arg with
        | .ident _ varName => consumeVarIfExists varName
        | _ => pure ()
      return retTy
    | none => throwCheck (.noMethodOnType methodName typeName)
  | .fnRef _ fnName =>
    -- Look up the function signature to build the fn pointer type
    let env ← getEnv
    match env.allFnSigs.lookup fnName with
    | some sig =>
      let paramTys := sig.params.map Prod.snd
      return .fn_ paramTys sig.capSet sig.retTy
    | none => throwCheck (.unknownFunctionRef fnName)

partial def checkStmt (stmt : Stmt) (retTy : Ty) : CheckM Unit := do
  match stmt with
  | .letDecl _ name mutable ty value =>
    -- Escape analysis: prevent storing a borrow ref into a new binding
    let env ← getEnv
    match value with
    | .ident _ vn =>
      if env.borrowRefs.contains vn then
        throwCheck (.referenceEscapesBorrowBlock vn)
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
    | .borrow _ (.ident _ sourceName) =>
      modify fun env =>
        { env with vars := env.vars.map fun (n, info) =>
            if n == name then (n, { info with borrowedFrom := some sourceName }) else (n, info) }
    | .borrowMut _ (.ident _ sourceName) =>
      modify fun env =>
        { env with vars := env.vars.map fun (n, info) =>
            if n == name then (n, { info with borrowedFrom := some sourceName }) else (n, info) }
    | _ => pure ()
  | .assign _ name value =>
    -- Escape analysis: prevent storing a borrow ref into an outer variable
    let env ← getEnv
    match value with
    | .ident _ vn =>
      if env.borrowRefs.contains vn then
        throwCheck (.referenceEscapesBorrowBlock vn)
    | _ => pure ()
    match ← lookupVarInfo name with
    | some info =>
      if !info.mutable then
        throwCheck (.assignToImmutable name)
      if info.state == .frozen then
        throwCheck (.assignToFrozen name)
      let env ← getEnv
      let activeRefs := activeBorrowRefs env name
      if activeRefs.any (fun refInfo => match refInfo.ty with | .ref _ | .refMut _ => true | _ => false) then
        throwCheck (.assignToBorrowed name)
      let valTy ← checkExpr value (some info.ty)
      expectTy info.ty valTy s!"assignment to '{name}'"
    | none => throwCheck (.assignToUndeclaredVariable name)
  | .return_ _ (some value) =>
    -- Escape analysis: prevent returning a borrow ref
    let env ← getEnv
    match value with
    | .ident _ vn =>
      if env.borrowRefs.contains vn then
        throwCheck (.referenceEscapesBorrowBlock vn)
    | _ => pure ()
    let valTy ← checkExpr value (some retTy)
    expectTy retTy valTy "return value"
    -- Returning a linear variable consumes it
    match value with
    | .ident _ varName => consumeVar varName
    | _ => pure ()
  | .return_ _ none =>
    expectTy .unit retTy "return (void)"
  | .expr _ e =>
    let _ ← checkExpr e
    pure ()
  | .ifElse _ cond thenBody elseBody =>
    let condTy ← checkExpr cond
    -- Allow bool or integer types as conditions
    if condTy != .bool && !isIntegerType condTy then
      throwCheck (.conditionNotBool "if" (tyToString condTy))
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
  | .while_ _ cond body lbl =>
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throwCheck (.conditionNotBool "while" (tyToString condTy))
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
  | .forLoop _ init cond step body lbl =>
    -- Init
    match init with
    | some initStmt => checkStmt initStmt retTy
    | none => pure ()
    -- Condition
    let condTy ← checkExpr cond
    if condTy != .bool && !isIntegerType condTy then
      throwCheck (.conditionNotBool "for" (tyToString condTy))
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
  | .fieldAssign _ obj field value =>
    -- Escape analysis: prevent storing a borrow ref into a struct field
    let env ← getEnv
    match value with
    | .ident _ vn =>
      if env.borrowRefs.contains vn then
        throwCheck (.referenceEscapesBorrowBlock vn)
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
      | none => throwCheck (.structHasNoField structName field)
    | _ => throwCheck .fieldAccessNonStruct
  | .derefAssign _ target value =>
    let targetTy ← checkExpr target
    match targetTy with
    | .refMut inner =>
      let valTy ← checkExpr value (some inner)
      expectTy inner valTy "deref assignment"
    | .ptrMut inner =>
      checkCapabilities "*raw_ptr=" (.concrete ["Unsafe"])
      let valTy ← checkExpr value (some inner)
      expectTy inner valTy "deref assignment"
    | _ => throwCheck .cannotAssignThroughNonMutRef
  | .arrayIndexAssign _ arr index value =>
    let arrTy ← checkExpr arr
    let idxTy ← checkExpr index
    if !isIntegerType idxTy then
      throwCheck (.arrayIndexNotInteger none)
    match arrTy with
    | .array elemTy _ =>
      let valTy ← checkExpr value (some elemTy)
      expectTy elemTy valTy "array element assignment"
    | _ => throwCheck (.indexingNonArray none)
  | .defer _ body =>
    -- Verify body is a call expression
    match body with
    | .call _ _ _ _ => pure ()
    | _ => throwCheck .deferBodyNotCall
    let _ ← checkExpr body
    -- If it's destroy(varName), mark varName as reserved
    match body with
    | .call _ "destroy" _ args =>
      match args.head? with
      | some (.ident _ varName) =>
        let env ← getEnv
        let vars' := env.vars.map fun (n, vi) =>
          if n == varName then (n, { vi with state := .reserved })
          else (n, vi)
        setEnv { env with vars := vars' }
      | _ => pure ()
    | _ => pure ()
  | .borrowIn _ var ref region isMut body =>
    -- Check that var exists
    match ← lookupVarInfo var with
    | none => throwCheck (.undeclaredVariable var)
    | some varInfo =>
      -- Check no shadowing of ref and region names
      let env ← getEnv
      if (env.vars.lookup ref).isSome then
        throwCheck (.borrowRefShadows ref)
      if (env.vars.lookup region).isSome then
        throwCheck (.borrowRegionShadows region)
      -- Check if variable is frozen (already inside another borrow block)
      if varInfo.state == .frozen then
        throwCheck (.variableFrozenByBorrow var)
      -- Check for mutable borrow conflict: if var is already mutably borrowed, error
      if isMut && varInfo.mutBorrowed then
        throwCheck (.variableAlreadyMutBorrowed var)
      if isMut && varInfo.borrowCount > 0 then
        throwCheck (.cannotMutBorrowImmBorrowed var)
      if !isMut && varInfo.mutBorrowed then
        throwCheck (.cannotImmBorrowMutBorrowed var)
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
  | .arrowAssign _ obj field value =>
    let objTy ← checkExpr obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | .ref (.heap t) | .refMut (.heap t) => t
      | _ => .placeholder
    if innerTy == .placeholder then
      throwCheck (.arrowAssignNotHeap (tyToString objTy))
    let structName := match innerTy with
      | .named n => n
      | _ => ""
    if structName == "" then throwCheck .arrowAssignNonStruct
    match ← lookupStructField structName field with
    | some fieldTy =>
      let valTy ← checkExpr value (some fieldTy)
      expectTy fieldTy valTy s!"arrow field assignment '{structName}->{field}'"
    | none => throwCheck (.structHasNoField structName field)
  | .break_ _ value lbl =>
    let env ← getEnv
    if env.inDeferBody then
      throwCheck .breakInDefer
    if env.loopDepth == 0 then
      throwCheck .breakOutsideLoop
    -- Validate label if present
    match lbl with
    | some l =>
      if !env.loopLabels.contains l then
        throwCheck (.unknownLoopLabel l)
    | none => pure ()
    -- Check all linear variables declared in the loop body are consumed
    for (name, info) in env.vars do
      if !info.isCopy && info.state != .consumed && info.loopDepth >= env.loopDepth then
        throwCheck (.breakSkipsUnconsumedLinear name)
    -- Check break value if present (for while-as-expression)
    match value with
    | some expr =>
      let valTy ← checkExpr expr
      let env2 ← getEnv
      match env2.loopBreakTy with
      | none => setEnv { env2 with loopBreakTy := some valTy }
      | some prevTy =>
        if prevTy != valTy then
          throwCheck (.breakTypeMismatch (tyToString valTy) (tyToString prevTy))
    | none => pure ()
  | .continue_ _ lbl =>
    let env ← getEnv
    if env.inDeferBody then
      throwCheck .continueInDefer
    if env.loopDepth == 0 then
      throwCheck .continueOutsideLoop
    -- Validate label if present
    match lbl with
    | some l =>
      if !env.loopLabels.contains l then
        throwCheck (.unknownLoopLabel l)
    | none => pure ()
    -- Check all linear variables declared in the loop body are consumed
    for (name, info) in env.vars do
      if !info.isCopy && info.state != .consumed && info.loopDepth >= env.loopDepth then
        throwCheck (.continueSkipsUnconsumedLinear name)

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
      throwCheck (.linearConsumedOneBranchNotOther name)
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
      throwCheck (.linearConsumedNoBranch name ctx)

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
    { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy,
      capSet := .concrete ["Unsafe"] }
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
    { params := [("s", .ref .string)], retTy := .string },
    -- 23: tcp_connect
    { params := [("host", .ref .string), ("port", .int)], retTy := .int, capSet := .concrete ["Network"] },
    -- 24: tcp_listen
    { params := [("port", .int), ("backlog", .int)], retTy := .int, capSet := .concrete ["Network"] },
    -- 25: tcp_accept
    { params := [("sockfd", .int)], retTy := .int, capSet := .concrete ["Network"] },
    -- 26: socket_send
    { params := [("sockfd", .int), ("data", .ref .string)], retTy := .int, capSet := .concrete ["Network"] },
    -- 27: socket_recv
    { params := [("sockfd", .int), ("bufsize", .int)], retTy := .string, capSet := .concrete ["Network"] },
    -- 28: socket_close
    { params := [("sockfd", .int)], retTy := .unit, capSet := .concrete ["Network"] }
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
    ("string_trim", builtinOffset + 22),
    ("tcp_connect", builtinOffset + 23),
    ("tcp_listen", builtinOffset + 24),
    ("tcp_accept", builtinOffset + 25),
    ("socket_send", builtinOffset + 26),
    ("socket_recv", builtinOffset + 27),
    ("socket_close", builtinOffset + 28)
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
  -- Collect newtypes from module and submodules
  let allNewtypes := m.newtypes ++ m.submodules.foldl (fun acc sub => acc ++ sub.newtypes) []
  let initEnv : TypeEnv :=
    { vars := [], structs := allStructs, enums := allEnums, functions := allSigs,
      fnNames := allNames, loopDepth := 0, typeAliases := typeAliasMap, constants := constantsMap,
      traitImpls := traitImplPairs, allFnSigs := fnSigPairs, newtypes := allNewtypes }
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
          .error (CheckError.message (.copyDestroyConflict sd.name))
        else
          -- Check all fields are copy types
          match sd.fields.find? fun f => !isCopyTyPure f.ty with
          | some f => .error (CheckError.message (.copyFieldNotCopy sd.name f.name))
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
        .error (CheckError.message (.copyDestroyConflict ed.name))
      else .ok ()
  match copyEnumCheck with
  | .error e => .error e
  | .ok () =>
  -- FFI safety: isFFISafe predicate (uses allStructs to include imported structs)
  let isFFISafe : Ty → Bool := fun ty =>
    match ty with
    | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
    | .float32 | .float64 => true
    | .bool | .char | .unit => true
    | .ptrMut _ | .ptrConst _ => true
    | .named name => (allStructs.find? fun sd => sd.name == name).any fun sd => sd.isReprC
    | _ => false
  -- Validate repr(C) structs: no generics, all fields FFI-safe
  let reprCCheck := m.structs.foldl (init := (Except.ok () : Except String Unit)) fun acc sd =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if sd.isReprC then
        if !sd.typeParams.isEmpty then
          .error (CheckError.message (.reprCHasGenerics sd.name))
        else
          match sd.fields.find? fun f => !isFFISafe f.ty with
          | some f => .error (CheckError.message (.reprCFieldNotFFISafe sd.name f.name (tyToString f.ty)))
          | none => .ok ()
      else .ok ()
  match reprCCheck with
  | .error e => .error e
  | .ok () =>
  -- Validate repr(packed) + repr(align) conflict and align power-of-2
  let reprAttrCheck := m.structs.foldl (init := (Except.ok () : Except String Unit)) fun acc sd =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if sd.isPacked && sd.reprAlign.isSome then
        .error (CheckError.message (.reprPackedAndAlignConflict sd.name))
      else match sd.reprAlign with
        | some n =>
          if n == 0 || (n &&& (n - 1)) != 0 then
            .error (CheckError.message (.reprAlignNotPowerOfTwo sd.name n))
          else .ok ()
        | none => .ok ()
  match reprAttrCheck with
  | .error e => .error e
  | .ok () =>
  -- Validate extern fn params and return types are FFI-safe
  let externFnCheck := m.externFns.foldl (init := (Except.ok () : Except String Unit)) fun acc ef =>
    match acc with
    | .error e => .error e
    | .ok () =>
      match ef.params.find? fun (p : Param) => !isFFISafe p.ty with
      | some p => .error (CheckError.message (.externFnParamNotFFISafe ef.name p.name (tyToString p.ty)))
      | none =>
        if !isFFISafe ef.retTy && ef.retTy != .unit then
          .error (CheckError.message (.externFnReturnNotFFISafe ef.name (tyToString ef.retTy)))
        else .ok ()
  match externFnCheck with
  | .error e => .error e
  | .ok () =>
  -- Check user doesn't declare trait Destroy
  let destroyTraitCheck := m.traits.foldl (init := (Except.ok () : Except String Unit)) fun acc td =>
    match acc with
    | .error e => .error e
    | .ok () =>
      if td.name == "Destroy" then .error (CheckError.message .builtinTraitRedeclared)
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
        .error (CheckError.message (.reservedName f.name))
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
    | none => Except.error (CheckError.message (.unknownTrait tb.traitName))
    | some td =>
      td.methods.foldlM (init := ()) fun () (sig : FnSigDef) =>
        match tb.methods.find? fun (f : FnDef) => f.name == sig.name with
        | none => Except.error (CheckError.message (.missingTraitMethod tb.typeName sig.name))
        | some f =>
          if sig.retTy != f.retTy then
            Except.error (CheckError.message (.traitMethodRetTyMismatch sig.name (tyToString sig.retTy) (tyToString f.retTy)))
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
    | none => .error (CheckError.message (.unknownModule imp.moduleName))
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
            | none => .error (CheckError.message (.notPublicInModule sym imp.moduleName))

/-- Check a multi-module program. Processes modules in order, building export tables. -/
def checkProgram (modules : List Module) (summaryTable : List (String × FileSummary) := []) : Except String Unit :=
  -- Build export table from summaryTable
  let exportTable : List (String × ExportEntry) := summaryTable.map fun (name, summary) =>
    let fnSigs := summary.functions.map fun (n, fs) =>
      (n, { params := fs.params, retTy := fs.retTy, typeParams := fs.typeParams,
            typeBounds := fs.typeBounds, capParams := fs.capParams, capSet := fs.capSet : FnSig })
    let externSigs := summary.externFns.map fun ef =>
      (ef.name, { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy : FnSig })
    let fnSigs := fnSigs ++ externSigs
    (name, (fnSigs, summary.structs, summary.enums, summary.implBlocks, summary.traitImpls))
  -- Second pass: resolve imports and type-check each module
  let go := modules.foldlM (init := ()) fun () m => do
    let (impFns, impStructs, impEnums, impImpls, impTraitImpls) ← resolveImports m exportTable
    checkModule m impFns impStructs impEnums impImpls impTraitImpls
  go

end Concrete
