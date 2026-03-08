import Concrete.AST

namespace Concrete

structure FieldInfo where
  name : String
  ty : Ty
  index : Nat
  deriving Repr

structure StructInfo where
  name : String
  fields : List FieldInfo
  typeParams : List String := []
  deriving Repr

structure EnumVariantInfo where
  name : String
  tag : Nat
  fields : List FieldInfo
  deriving Repr, Inhabited

structure EnumInfo where
  name : String
  variants : List EnumVariantInfo
  payloadSize : Nat  -- size in bytes of largest variant payload
  typeParams : List String := []
  deriving Repr, Inhabited

structure CodegenState where
  output : String
  labelCounter : Nat
  localCounter : Nat
  vars : List (String × String)
  varTypes : List (String × Ty)
  structDefs : List StructInfo
  enumDefs : List EnumInfo
  fnRetTypes : List (String × Ty)
  stringLitCounter : Nat
  stringGlobals : String
  constants : List (String × (Ty × Expr))
  currentRetTy : Ty := .unit
  fnParamTypes : List (String × List Ty) := []
  loopExitLabel : Option String := none
  loopContLabel : Option String := none
  -- (closure fields removed: no closures in Concrete)
  deferStack : List (List Expr) := [[]]  -- stack of deferred expressions per scope
  loopResultSlot : Option String := none  -- alloca slot for while-as-expression result
  loopLabelMap : List (String × String × String) := []  -- label → (exitLabel, contLabel)
  typeVarMapping : List (String × String) := []  -- type var → concrete type name (for monomorphization)
  fnTypeParams : List (String × List String) := []  -- fn name → type param names
  fnTypeBounds : List (String × List (String × List String)) := []  -- fn name → type bounds
  allFnDefs : List FnDef := []  -- all function definitions (for monomorphization lookup)
  monoQueue : List (String × FnDef) := []  -- (monoName, substituted FnDef) to generate
  monoGenerated : List String := []  -- already-generated monomorphized function names
  hashMapInstantiations : List String := []  -- already-generated HashMap helper sets (e.g. "Int_Int")

instance : Inhabited CodegenState where
  default := {
    output := ""
    labelCounter := 0
    localCounter := 0
    vars := []
    varTypes := []
    structDefs := []
    enumDefs := []
    fnRetTypes := []
    stringLitCounter := 0
    stringGlobals := ""
    constants := []
    currentRetTy := Ty.unit
    fnParamTypes := []
  }

def CodegenState.init : CodegenState :=
  { output := "", labelCounter := 0, localCounter := 0,
    vars := [], varTypes := [], structDefs := [], enumDefs := [], fnRetTypes := [],
    stringLitCounter := 0, stringGlobals := "", constants := [] }

def CodegenState.emit (s : CodegenState) (line : String) : CodegenState :=
  { s with output := s.output ++ line ++ "\n" }

def CodegenState.freshLabel (s : CodegenState) (pfx : String := "L") : CodegenState × String :=
  let name := pfx ++ toString s.labelCounter
  ({ s with labelCounter := s.labelCounter + 1 }, name)

def CodegenState.freshLocal (s : CodegenState) : CodegenState × String :=
  let name := "%t" ++ toString s.localCounter
  ({ s with localCounter := s.localCounter + 1 }, name)

def CodegenState.lookupVar (s : CodegenState) (name : String) : Option String :=
  s.vars.lookup name

def CodegenState.addVar (s : CodegenState) (name : String) (reg : String) : CodegenState :=
  { s with vars := (name, reg) :: s.vars }

def CodegenState.addVarType (s : CodegenState) (name : String) (ty : Ty) : CodegenState :=
  { s with varTypes := (name, ty) :: s.varTypes }

def CodegenState.lookupVarType (s : CodegenState) (name : String) : Option Ty :=
  s.varTypes.lookup name

def CodegenState.lookupStruct (s : CodegenState) (name : String) : Option StructInfo :=
  s.structDefs.find? fun si => si.name == name

def CodegenState.lookupEnum (s : CodegenState) (name : String) : Option EnumInfo :=
  s.enumDefs.find? fun ei => ei.name == name

def CodegenState.lookupEnumVariant (s : CodegenState) (enumName variantName : String) : Option EnumVariantInfo :=
  match s.lookupEnum enumName with
  | some ei => ei.variants.find? fun v => v.name == variantName
  | none => none

def CodegenState.lookupFieldIndex (s : CodegenState) (structName : String) (fieldName : String) : Option (Nat × Ty) :=
  match s.lookupStruct structName with
  | some si =>
    match si.fields.find? fun fi => fi.name == fieldName with
    | some fi => some (fi.index, fi.ty)
    | none => none
  | none => none

private def escapeCharForLLVM (c : Char) : String :=
  if c == '\n' then "\\0A"
  else if c == '\t' then "\\09"
  else if c == '\\' then "\\5C"
  else if c == '"' then "\\22"
  else if c.toNat == 0 then "\\00"
  else if c.toNat >= 32 && c.toNat <= 126 then String.singleton c
  else
    let n := c.toNat
    let hi := n / 16
    let lo := n % 16
    let hexDigit (d : Nat) : Char :=
      if d < 10 then Char.ofNat (d + '0'.toNat)
      else Char.ofNat (d - 10 + 'A'.toNat)
    "\\" ++ String.ofList [hexDigit hi, hexDigit lo]

private def escapeStringForLLVM (s : String) : String :=
  s.foldl (fun acc c => acc ++ escapeCharForLLVM c) ""

/-- Normalize Ty.generic "Heap"/"HeapArray" to Ty.heap/Ty.heapArray. -/
private def normalizeTy : Ty → Ty
  | .generic "Heap" args => match args with
    | [inner] => .heap (normalizeTy inner)
    | _ => .generic "Heap" args
  | .generic "HeapArray" args => match args with
    | [inner] => .heapArray (normalizeTy inner)
    | _ => .generic "HeapArray" args
  | t => t

/-- Map a Concrete type to its LLVM IR type string. -/
def tyToLLVM (s : CodegenState) : Ty → String
  | .int => "i64"
  | .uint => "i64"
  | .i8 => "i8"
  | .i16 => "i16"
  | .i32 => "i32"
  | .u8 => "i8"
  | .u16 => "i16"
  | .u32 => "i32"
  | .bool => "i1"
  | .float64 => "double"
  | .float32 => "float"
  | .char => "i8"
  | .unit => "void"
  | .string => "%struct.String"
  | .ref _ => "ptr"
  | .refMut _ => "ptr"
  | .ptrMut _ => "ptr"
  | .ptrConst _ => "ptr"
  | .generic "Heap" _ => "ptr"
  | .generic "HeapArray" _ => "ptr"
  | .generic "Vec" _ => "%struct.Vec"
  | .generic "HashMap" _ => "%struct.HashMap"
  | .generic name _ =>
    match s.lookupEnum name with
    | some _ => "%enum." ++ name
    | none => "%struct." ++ name
  | .typeVar _ => "i64"
  | .array elem n => "[" ++ toString n ++ " x " ++ tyToLLVM s elem ++ "]"
  | .fn_ _ _ _ => "ptr"  -- Function pointers are just code addresses
  | .never => "void"
  | .heap _ => "ptr"
  | .heapArray _ => "ptr"
  | .placeholder => "i64"  -- Should not appear after checking
  | .named name =>
    match s.lookupStruct name with
    | some _ => "%struct." ++ name
    | none =>
      match s.lookupEnum name with
      | some _ => "%enum." ++ name
      | none => "i64"

def fieldTyToLLVM (s : CodegenState) (ty : Ty) : String :=
  tyToLLVM s ty

/-- LLVM type for function parameters and call arguments.
    Structs are passed as ptr (by pointer). -/
def paramTyToLLVM (s : CodegenState) : Ty → String
  | .string => "ptr"
  | .ref _ => "ptr"
  | .refMut _ => "ptr"
  | .ptrMut _ => "ptr"
  | .ptrConst _ => "ptr"
  | .fn_ _ _ _ => "ptr"  -- Function pointers are just ptr
  | .heap _ => "ptr"
  | .heapArray _ => "ptr"
  | .named name =>
    if (s.lookupStruct name).isSome || (s.lookupEnum name).isSome then "ptr"
    else "i64"
  | .generic "Heap" _ => "ptr"
  | .generic "HeapArray" _ => "ptr"
  | .generic "Vec" _ => "ptr"
  | .generic "HashMap" _ => "ptr"
  | .generic name _ =>
    if (s.lookupStruct name).isSome || (s.lookupEnum name).isSome then "ptr"
    else "i64"
  | ty => tyToLLVM s ty

def isStructTy (s : CodegenState) : Ty → Bool
  | .string => true
  | .named name => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | .generic name _ => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | .ref _ | .refMut _ => true
  | _ => false

/-- Is this type passed by pointer in function calls and stored as ptr? -/
def isPassByPtr (s : CodegenState) (ty : Ty) : Bool :=
  match ty with
  | .string => true
  | .ref _ | .refMut _ => true
  | .array _ _ => true
  | .fn_ _ _ _ => false  -- Function pointers are plain ptrs, not pass by ptr
  | .heap _ => false     -- Heap pointers are simple ptrs, not passed by ptr
  | .heapArray _ => false
  | .named name => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | .generic "Vec" _ => true
  | .generic "HashMap" _ => true
  | .generic name _ => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | _ => false

private partial def stmtListHasReturn (stmts : List Stmt) : Bool :=
  stmts.any fun s => match s with
    | .return_ _ => true
    | .ifElse _ thenBody (some elseBody) =>
      stmtListHasReturn thenBody && stmtListHasReturn elseBody
    | .expr (.match_ _ arms) =>
      arms.all fun arm => match arm with
        | .mk _ _ _ body | .litArm _ body | .varArm _ body => stmtListHasReturn body
    | _ => false

/-- Get the LLVM integer type name for the given Concrete type (for arithmetic). -/
private def intTyToLLVM : Ty → String
  | .int | .uint => "i64"
  | .i8 | .u8 => "i8"
  | .i16 | .u16 => "i16"
  | .i32 | .u32 => "i32"
  | .char => "i8"
  | .bool => "i1"
  | _ => "i64"

/-- Get the LLVM float type name. -/
private def floatTyToLLVM : Ty → String
  | .float32 => "float"
  | .float64 => "double"
  | _ => "double"

/-- Is this a signed integer type? -/
private def isSignedInt : Ty → Bool
  | .int | .i8 | .i16 | .i32 => true
  | _ => false

/-- Get bit width of a type. -/
private def tyBitWidth : Ty → Nat
  | .i8 | .u8 | .char => 8
  | .i16 | .u16 => 16
  | .i32 | .u32 | .float32 => 32
  | .int | .uint | .float64 => 64
  | .bool => 1
  | _ => 64

/-- Is this an integer type? (for codegen, used by inferExprTy) -/
private def isIntegerType : Ty → Bool
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
  | _ => false

/-- Is this a float type? (for codegen, used by inferExprTy) -/
private def isFloatType : Ty → Bool
  | .float32 | .float64 => true
  | _ => false

/-- Infer the type of an expression from codegen state, optionally using a type hint. -/
private def inferExprTy (s : CodegenState) (e : Expr) (hint : Option Ty := none) : Ty :=
  match e with
  | .intLit _ => match hint with
    | some t => if isIntegerType t || t == .char then t else .int
    | none => .int
  | .floatLit _ => match hint with
    | some t => if isFloatType t then t else .float64
    | none => .float64
  | .boolLit _ => .bool
  | .strLit _ => .string
  | .charLit _ => .char
  | .ident name =>
    -- Check constants first
    match s.constants.lookup name with
    | some (ty, _) => normalizeTy ty
    | none =>
      match s.lookupVarType name with
      | some ty => normalizeTy ty
      | none =>
        -- Check if it's a function reference
        match s.fnRetTypes.lookup name with
        | some retTy =>
          let paramTys := (s.fnParamTypes.lookup name).getD []
          .fn_ paramTys .empty retTy
        | none => .int
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj hint
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let (structName, typeArgs) := match innerTy with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | .string => ("String", [])
      | _ => ("", [])
    if structName != "" then
      match s.lookupFieldIndex structName field with
      | some (_, ty) =>
        -- Substitute type vars with concrete type args
        match s.lookupStruct structName with
        | some si =>
          let mapping : List (String × Ty) := si.typeParams.zip typeArgs
          List.foldl (fun (t : Ty) (pair : String × Ty) =>
            match t with
            | .typeVar n => if n == pair.1 then pair.2 else t
            | _ => t) ty mapping
        | none => ty
      | none => .int
    else .int
  | .structLit name _ _ => .named name
  | .enumLit name _ typeArgs _ =>
    if typeArgs.isEmpty then .named name else .generic name typeArgs
  | .match_ _ _ => .int
  | .call fnName _typeArgs args =>
    if fnName == "sizeof" then match hint with
      | some t => t
      | none => .uint
    else if fnName == "alloc" then
      -- Infer arg type without recursion to avoid termination issues
      match args.head? with
      | some (Expr.structLit name _ _) => Ty.heap (Ty.named name)
      | some (Expr.enumLit name _ _ _) => Ty.heap (Ty.named name)
      | some (Expr.ident name) => Ty.heap ((s.lookupVarType name).getD Ty.int)
      | some (Expr.intLit _) => Ty.heap Ty.int
      | _ => match hint with
        | some t => t
        | none => Ty.heap Ty.int
    else if fnName == "free" then
      match args.head? with
      | some (Expr.ident name) =>
        match s.lookupVarType name with
        | some (Ty.heap inner) => inner
        | _ => Ty.int
      | _ => Ty.int
    else if fnName == "vec_new" then
      match _typeArgs.head? with
      | some elemTy => .generic "Vec" [elemTy]
      | none => match hint with | some t => t | none => .generic "Vec" [.int]
    else if fnName == "vec_push" || fnName == "vec_set" || fnName == "vec_free" then .unit
    else if fnName == "vec_get" then
      match args.head? with
      | some (Expr.ident name) =>
        match s.lookupVarType name with
        | some (.refMut (.generic "Vec" [et])) => et
        | some (.ref (.generic "Vec" [et])) => et
        | some (.generic "Vec" [et]) => et
        | _ => match hint with | some t => t | none => .int
      | _ => match hint with | some t => t | none => .int
    else if fnName == "vec_len" then .int
    else if fnName == "vec_pop" then
      match args.head? with
      | some (Expr.ident name) =>
        match s.lookupVarType name with
        | some (.refMut (.generic "Vec" [et])) => .generic "Option" [et]
        | some (.generic "Vec" [et]) => .generic "Option" [et]
        | _ => match hint with | some t => t | none => .int
      | _ => match hint with | some t => t | none => .int
    else if fnName == "map_new" then
      match _typeArgs with
      | [kTy, vTy] => .generic "HashMap" [kTy, vTy]
      | _ => match hint with | some t => t | none => .generic "HashMap" [.int, .int]
    else if fnName == "map_insert" || fnName == "map_free" then .unit
    else if fnName == "map_get" || fnName == "map_remove" then
      match args.head? with
      | some (Expr.ident name) =>
        match s.lookupVarType name with
        | some (.ref (.generic "HashMap" [_, vt])) => .generic "Option" [vt]
        | some (.refMut (.generic "HashMap" [_, vt])) => .generic "Option" [vt]
        | some (.generic "HashMap" [_, vt]) => .generic "Option" [vt]
        | _ => match hint with | some t => t | none => .int
      | _ => match hint with | some t => t | none => .int
    else if fnName == "map_contains" then .bool
    else if fnName == "map_len" then .int
    else normalizeTy ((s.fnRetTypes.lookup fnName).getD .int)
  | .binOp op lhs _ =>
    match op with
    | .eq | .neq | .lt | .gt | .leq | .geq | .and_ | .or_ => .bool
    | _ => inferExprTy s lhs
  | .unaryOp .not_ _ => .bool
  | .unaryOp .neg operand => inferExprTy s operand
  | .unaryOp .bitnot operand => inferExprTy s operand
  | .paren inner => inferExprTy s inner
  | .borrow inner => .ref (inferExprTy s inner)
  | .borrowMut inner => .refMut (inferExprTy s inner)
  | .deref inner =>
    match inferExprTy s inner with
    | .ref t => t
    | .refMut t => t
    | .ptrMut t => t
    | .ptrConst t => t
    | .heap t => t
    | _ => .int
  | .try_ inner =>
    match inferExprTy s inner with
    | .named enumName =>
      match s.lookupEnum enumName with
      | some ei =>
        match ei.variants.find? fun v => v.name == "Ok" with
        | some vi =>
          match vi.fields.head? with
          | some fi => fi.ty
          | none => .int
        | none => .int
      | none => .int
    | _ => .int
  | .arrayLit elems =>
    match elems with
    | first :: _ => .array (inferExprTy s first) elems.length
    | [] => .array .int 0
  | .arrayIndex arr _ =>
    match inferExprTy s arr with
    | .array elemTy _ => elemTy
    | _ => .int
  | .cast _ targetTy => targetTy
  | .methodCall obj methodName _ _ =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | .typeVar n => (s.typeVarMapping.lookup n).getD ""
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
  | .staticMethodCall typeName methodName _ _ =>
    let mangledName := typeName ++ "_" ++ methodName
    normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
  | .fnRef fnName =>
    -- Look up the function's type to build the fn pointer type
    (s.fnRetTypes.lookup fnName).map (fun retTy =>
      let paramTys := (s.fnParamTypes.lookup fnName).getD []
      .fn_ paramTys .empty retTy) |>.getD .int
  | .arrowAccess obj field =>
    let objTy := inferExprTy s obj hint
    let innerTy := match objTy with
      | .heap t | .heapArray t => t
      | _ => objTy
    let structName := match innerTy with
      | .named n | .generic n _ => n
      | _ => ""
    match s.lookupFieldIndex structName field with
    | some (_, ty) => ty
    | none => .int
  | .allocCall inner _ => inferExprTy s inner hint
  | .whileExpr _cond _body _elseBody =>
    -- Result type comes from hint (set by checker) or defaults to Int
    match hint with
    | some t => t
    | none => .int

/-- Convert a float to LLVM literal format. -/
private def floatToLLVM (f : Float) : String :=
  let s := toString f
  if s.any (· == '.') || s.any (· == 'e') || s.any (· == 'E') || s.any (· == 'i') || s.any (· == 'n') then
    s
  else
    s ++ ".0"

/-- Get byte size of a type. -/
private def tySize : Ty → Nat
  | .int | .uint | .float64 => 8
  | .i32 | .u32 | .float32 => 4
  | .i16 | .u16 => 2
  | .i8 | .u8 | .char => 1
  | .bool => 1
  | .unit => 0
  | .string => 16
  | .named _ => 8
  | .ref _ | .refMut _ => 8
  | .ptrMut _ | .ptrConst _ => 8
  | .generic "Vec" _ => 24      -- ptr + i64 + i64
  | .generic "HashMap" _ => 40  -- ptr + ptr + ptr + i64 + i64
  | .generic _ _ | .typeVar _ => 8
  | .fn_ _ _ _ => 8   -- Function pointer: single ptr
  | .never => 0
  | .heap _ => 8
  | .heapArray _ => 8
  | .placeholder => 8
  | .array elem n => tySize elem * n

/-- Compute type size with access to struct/enum definitions. -/
private partial def tySizeOf (s : CodegenState) : Ty → Nat
  | .named name =>
    match s.lookupStruct name with
    | some si => si.fields.foldl (fun acc fi => acc + tySizeOf s fi.ty) 0
    | none => match s.lookupEnum name with
      | some ei =>
        -- Enum: tag (i32=4) + max variant size
        let maxPayload := ei.variants.foldl (fun acc vi =>
          let sz := vi.fields.foldl (fun a fi => a + tySizeOf s fi.ty) 0
          Nat.max acc sz) 0
        4 + maxPayload
      | none => 8
  | .generic "Heap" _ => 8    -- pointer
  | .generic "HeapArray" _ => 8  -- pointer
  | .generic "Vec" _ => 24      -- ptr + i64 + i64
  | .generic "HashMap" _ => 40  -- ptr + ptr + ptr + i64 + i64
  | .generic name _ =>
    -- Generic struct/enum: look up base definition
    match s.lookupStruct name with
    | some si => si.fields.foldl (fun acc fi => acc + tySizeOf s fi.ty) 0
    | none => match s.lookupEnum name with
      | some ei =>
        let maxPayload := ei.variants.foldl (fun acc vi =>
          let sz := vi.fields.foldl (fun a fi => a + tySizeOf s fi.ty) 0
          Nat.max acc sz) 0
        4 + maxPayload
      | none => 8
  | .array elem n => tySizeOf s elem * n
  | other => tySize other

/-- Substitute type variables using a mapping (for generic enum/struct instantiation). -/
private def substTyCodegen (mapping : List (String × Ty)) : Ty → Ty
  | .typeVar name => match mapping.lookup name with
    | some t => t
    | none => .typeVar name
  | .ref t => .ref (substTyCodegen mapping t)
  | .refMut t => .refMut (substTyCodegen mapping t)
  | .heap t => .heap (substTyCodegen mapping t)
  | .heapArray t => .heapArray (substTyCodegen mapping t)
  | .array t n => .array (substTyCodegen mapping t) n
  | .generic name args => .generic name (args.map (substTyCodegen mapping))
  | t => t

/-- Normalize Ty.generic "Heap"/"HeapArray" to Ty.heap/Ty.heapArray in field types. -/
private def normalizeFieldTy : Ty → Ty
  | .generic "Heap" [t] => .heap (normalizeFieldTy t)
  | .generic "HeapArray" [t] => .heapArray (normalizeFieldTy t)
  | .ref t => .ref (normalizeFieldTy t)
  | .refMut t => .refMut (normalizeFieldTy t)
  | .heap t => .heap (normalizeFieldTy t)
  | .heapArray t => .heapArray (normalizeFieldTy t)
  | .array t n => .array (normalizeFieldTy t) n
  | .generic name args => .generic name (args.map normalizeFieldTy)
  | t => t

/-- Substitute type variables for monomorphization. Handles both .named and .typeVar since
    the parser produces .named "T" for type params. -/
private def substTyMono (typeParams : List String) (mapping : List (String × Ty)) : Ty → Ty
  | .named n => if typeParams.contains n then
      match mapping.lookup n with
      | some t => t
      | none => .named n
    else .named n
  | .typeVar n => match mapping.lookup n with
    | some t => t
    | none => .typeVar n
  | .ref t => .ref (substTyMono typeParams mapping t)
  | .refMut t => .refMut (substTyMono typeParams mapping t)
  | .heap t => .heap (substTyMono typeParams mapping t)
  | .heapArray t => .heapArray (substTyMono typeParams mapping t)
  | .array t n => .array (substTyMono typeParams mapping t) n
  | .generic name args => .generic name (args.map (substTyMono typeParams mapping))
  | t => t

/-- Create a monomorphized copy of a FnDef by substituting type params with concrete types. -/
private def monoFnDef (origFn : FnDef) (monoName : String) (mapping : List (String × Ty)) : FnDef :=
  let subst := substTyMono origFn.typeParams mapping
  { origFn with
    name := monoName
    params := origFn.params.map fun p => { p with ty := subst p.ty }
    retTy := subst origFn.retTy
    typeParams := []
    typeBounds := [] }

mutual

/-- Generate an expression, returning the LLVM register holding the value.
    An optional type hint is used for integer/float literals to emit the correct LLVM type. -/
partial def genExpr (s : CodegenState) (e : Expr) (hintTy : Option Ty := none) : CodegenState × String :=
  match e with
  | .intLit v =>
    let ty := match hintTy with
      | some t => if isIntegerType t || t == .char then t else Ty.int
      | none => Ty.int
    let llTy := intTyToLLVM ty
    let (s, reg) := s.freshLocal
    let s := s.emit ("  " ++ reg ++ " = add " ++ llTy ++ " 0, " ++ toString v)
    (s, reg)
  | .floatLit v =>
    let ty := match hintTy with
      | some t => if isFloatType t then t else Ty.float64
      | none => Ty.float64
    if ty == Ty.float32 then
      -- For f32, emit as double first then fptrunc to float (avoids hex format issues)
      let (s, dblReg) := s.freshLocal
      let s := s.emit ("  " ++ dblReg ++ " = fadd double 0.0, " ++ floatToLLVM v)
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = fptrunc double " ++ dblReg ++ " to float")
      (s, reg)
    else
      let llTy := floatTyToLLVM ty
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = fadd " ++ llTy ++ " 0.0, " ++ floatToLLVM v)
      (s, reg)
  | .boolLit v =>
    let (s, reg) := s.freshLocal
    let val := if v then "1" else "0"
    let s := s.emit ("  " ++ reg ++ " = add i1 0, " ++ val)
    (s, reg)
  | .strLit v =>
    let globalName := "@.str." ++ toString s.stringLitCounter
    let len := v.length
    let escaped := escapeStringForLLVM v
    let globalDef := globalName ++ " = private constant [" ++ toString len ++ " x i8] c\"" ++ escaped ++ "\"\n"
    let s := { s with stringLitCounter := s.stringLitCounter + 1, stringGlobals := s.stringGlobals ++ globalDef }
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca %struct.String")
    let (s, dataMem) := s.freshLocal
    let s := s.emit ("  " ++ dataMem ++ " = call ptr @malloc(i64 " ++ toString len ++ ")")
    let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ dataMem ++ ", ptr " ++ globalName ++ ", i64 " ++ toString len ++ ", i1 false)")
    let (s, dataPtrField) := s.freshLocal
    let s := s.emit ("  " ++ dataPtrField ++ " = getelementptr inbounds %struct.String, ptr " ++ alloca ++ ", i32 0, i32 0")
    let s := s.emit ("  store ptr " ++ dataMem ++ ", ptr " ++ dataPtrField)
    let (s, lenField) := s.freshLocal
    let s := s.emit ("  " ++ lenField ++ " = getelementptr inbounds %struct.String, ptr " ++ alloca ++ ", i32 0, i32 1")
    let s := s.emit ("  store i64 " ++ toString len ++ ", ptr " ++ lenField)
    (s, alloca)
  | .charLit v =>
    let (s, reg) := s.freshLocal
    let s := s.emit ("  " ++ reg ++ " = add i8 0, " ++ toString v.toNat)
    (s, reg)
  | .ident name =>
    -- Check constants first
    match s.constants.lookup name with
    | some (ty, constExpr) =>
      -- Inline the constant value with its declared type as hint
      genExpr s constExpr (hintTy.orElse fun _ => some ty)
    | none =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      if isPassByPtr s ty then
        (s, alloca)
      else
        let (s, loaded) := s.freshLocal
        let llTy := tyToLLVM s ty
        let s := s.emit ("  " ++ loaded ++ " = load " ++ llTy ++ ", ptr " ++ alloca)
        (s, loaded)
    | none =>
      -- Check if this is a function reference (function name used as value)
      if (s.fnRetTypes.lookup name).isSome then
        -- Return function pointer directly — @fnName is a valid ptr in LLVM IR
        (s, "@" ++ name)
      else
        (s, "%" ++ name)
  | .binOp op lhs rhs =>
    let lhsTy := inferExprTy s lhs hintTy
    let (s, lReg) := genExpr s lhs hintTy
    let (s, rReg) := genExpr s rhs (some lhsTy)
    let (s, result) := s.freshLocal
    -- Determine operation type
    let isFloat := match lhsTy with | .float32 | .float64 => true | _ => false
    let isPtr := match lhsTy with | .ptrMut _ | .ptrConst _ => true | _ => false
    let llTy := if isFloat then floatTyToLLVM lhsTy
                else if isPtr then "ptr"
                else intTyToLLVM lhsTy
    let isSigned := isSignedInt lhsTy
    if isFloat then
      let instr := match op with
        | .add => "fadd " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .sub => "fsub " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mul => "fmul " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .div => "fdiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mod => "frem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .eq => "fcmp oeq " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .neq => "fcmp one " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .lt => "fcmp olt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .gt => "fcmp ogt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .leq => "fcmp ole " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .geq => "fcmp oge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .and_ => "and i1 " ++ lReg ++ ", " ++ rReg
        | .or_ => "or i1 " ++ lReg ++ ", " ++ rReg
        | .bitand | .bitor | .bitxor | .shl | .shr =>
          -- Bitwise on float: shouldn't happen (checker rejects), fallback
          "fadd " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
      let s := s.emit ("  " ++ result ++ " = " ++ instr)
      (s, result)
    else if isPtr then
      -- Pointer arithmetic: getelementptr
      let pointeeTy := match lhsTy with
        | .ptrMut t => tyToLLVM s t
        | .ptrConst t => tyToLLVM s t
        | _ => "i8"
      let s := s.emit ("  " ++ result ++ " = getelementptr " ++ pointeeTy ++ ", ptr " ++ lReg ++ ", i64 " ++ rReg)
      (s, result)
    else
      let instr := match op with
        | .add => "add " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .sub => "sub " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mul => "mul " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .div => if isSigned then "sdiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "udiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mod => if isSigned then "srem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "urem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .eq => "icmp eq " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .neq => "icmp ne " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .lt => if isSigned then "icmp slt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                 else "icmp ult " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .gt => if isSigned then "icmp sgt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                 else "icmp ugt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .leq => if isSigned then "icmp sle " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "icmp ule " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .geq => if isSigned then "icmp sge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "icmp uge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .and_ => "and i1 " ++ lReg ++ ", " ++ rReg
        | .or_ => "or i1 " ++ lReg ++ ", " ++ rReg
        | .bitand => "and " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .bitor => "or " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .bitxor => "xor " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .shl => "shl " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .shr => if isSigned then "ashr " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "lshr " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
      let s := s.emit ("  " ++ result ++ " = " ++ instr)
      (s, result)
  | .unaryOp op operand =>
    let opTy := inferExprTy s operand hintTy
    let (s, reg) := genExpr s operand hintTy
    let (s, result) := s.freshLocal
    match op with
    | .neg =>
      let isFloat := match opTy with | .float32 | .float64 => true | _ => false
      if isFloat then
        let llTy := floatTyToLLVM opTy
        let s := s.emit ("  " ++ result ++ " = fneg " ++ llTy ++ " " ++ reg)
        (s, result)
      else
        let llTy := intTyToLLVM opTy
        let s := s.emit ("  " ++ result ++ " = sub " ++ llTy ++ " 0, " ++ reg)
        (s, result)
    | .not_ =>
      let s := s.emit ("  " ++ result ++ " = xor i1 " ++ reg ++ ", 1")
      (s, result)
    | .bitnot =>
      let llTy := intTyToLLVM opTy
      let s := s.emit ("  " ++ result ++ " = xor " ++ llTy ++ " " ++ reg ++ ", -1")
      (s, result)
  | .call fnName typeArgs args =>
    -- Intercept abort()
    if fnName == "abort" then
      let s := s.emit "  call void @abort()"
      let s := s.emit "  unreachable"
      let (s, deadLabel) := s.freshLabel "abort.dead"
      let s := s.emit (deadLabel ++ ":")
      let (s, dummy) := s.freshLocal
      let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
      (s, dummy)
    -- Intercept destroy(x)
    else if fnName == "destroy" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let typeName := match argTy with
          | .named n => n
          | .generic n _ => n
          | _ => ""
        let mangledName := typeName ++ "_destroy"
        let (s, argReg) := genExpr s arg
        let argLLTy := paramTyToLLVM s argTy
        let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argLLTy ++ " " ++ argReg ++ ")")
        (s, "0")
      | none => (s, "0")
    -- Intercept alloc(val)
    else if fnName == "alloc" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let szVal := tySizeOf s argTy
        -- Malloc the heap memory
        let (s, heapPtr) := s.freshLocal
        let s := s.emit ("  " ++ heapPtr ++ " = call ptr @malloc(i64 " ++ toString szVal ++ ")")
        -- Generate the value and store it at the heap location
        -- For pass-by-ptr types (structs), genExpr returns a ptr to the alloca
        -- We load the full value from the alloca and store it to the heap
        if isPassByPtr s argTy then
          let (s, valPtr) := genExpr s arg
          let argLLTy := tyToLLVM s argTy
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ argLLTy ++ ", ptr " ++ valPtr)
          let s := s.emit ("  store " ++ argLLTy ++ " " ++ loaded ++ ", ptr " ++ heapPtr)
          (s, heapPtr)
        else
          let (s, valReg) := genExpr s arg
          let argLLTy := tyToLLVM s argTy
          let s := s.emit ("  store " ++ argLLTy ++ " " ++ valReg ++ ", ptr " ++ heapPtr)
          (s, heapPtr)
      | none => (s, "0")
    -- Intercept free(ptr)
    else if fnName == "free" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let innerTy := match argTy with
          | .heap t => t
          | _ => argTy
        let innerLLTy := tyToLLVM s innerTy
        -- Get the heap pointer
        let (s, heapPtr) := genExpr s arg
        if isPassByPtr s innerTy then
          -- Load the struct value from heap, free, return via alloca
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ heapPtr)
          let s := s.emit ("  call void @free(ptr " ++ heapPtr ++ ")")
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ innerLLTy)
          let s := s.emit ("  store " ++ innerLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          (s, alloca)
        else
          -- Load the scalar value from heap, free, return value
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ heapPtr)
          let s := s.emit ("  call void @free(ptr " ++ heapPtr ++ ")")
          (s, loaded)
      | none => (s, "0")
    -- Intercept vec_* calls
    else if fnName == "vec_new" || fnName == "vec_push" || fnName == "vec_get" ||
            fnName == "vec_set" || fnName == "vec_len" || fnName == "vec_pop" ||
            fnName == "vec_free" then
      genVecBuiltinCall s fnName typeArgs args hintTy
    -- Intercept map_* calls
    else if fnName == "map_new" || fnName == "map_insert" || fnName == "map_get" ||
            fnName == "map_contains" || fnName == "map_remove" || fnName == "map_len" ||
            fnName == "map_free" then
      genHashMapBuiltinCall s fnName typeArgs args hintTy
    else
    -- Check if this is a function pointer call (variable with fn_ type)
    let isFnPtrCall := match s.lookupVarType fnName with
      | some (.fn_ _ _ _) => true
      | _ => false
    if isFnPtrCall then
      -- Function pointer call: load the ptr and call indirectly
      let fnPtrVar := (s.lookupVar fnName).getD "%undef"
      let (s, fnPtr) := s.freshLocal
      let s := s.emit ("  " ++ fnPtr ++ " = load ptr, ptr " ++ fnPtrVar)
      -- Generate args
      let (s, argRegs) := genExprList s args
      let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
      let argPairs := argTys.zip argRegs
      let normalArgs := argPairs.map fun (ty, r) => ty ++ " " ++ r
      let argStr := ", ".intercalate normalArgs
      -- Determine return type
      let retTy := match s.lookupVarType fnName with
        | some (.fn_ _ _ ret) => ret
        | _ => .int
      let retLLTy := tyToLLVM s retTy
      if retLLTy == "void" then
        let s := s.emit ("  call void " ++ fnPtr ++ "(" ++ argStr ++ ")")
        (s, "0")
      else
        let (s, result) := s.freshLocal
        let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " " ++ fnPtr ++ "(" ++ argStr ++ ")")
        (s, result)
    else
    -- sizeof intrinsic: emit compile-time constant
    if (fnName == "sizeof" || fnName.endsWith "_sizeof") && !typeArgs.isEmpty then
      let ty := typeArgs.headD .int
      let sz := tySize ty
      let (s, reg) := s.freshLocal
      let retLLTy := match hintTy with
        | some t => tyToLLVM s t
        | none => "i64"
      let s := s.emit ("  " ++ reg ++ " = add " ++ retLLTy ++ " 0, " ++ toString sz)
      (s, reg)
    else
    -- Monomorphization: redirect calls to generic functions with trait bounds
    let fnBounds := (s.fnTypeBounds.lookup fnName).getD []
    let (s, effectiveName) := if !fnBounds.isEmpty then
      let fnTyParams := (s.fnTypeParams.lookup fnName).getD []
      -- Infer type var mapping from arguments
      let origParamTys := (s.fnParamTypes.lookup fnName).getD []
      let argTypes := args.map fun arg => inferExprTy s arg
      let inferredMapping := origParamTys.zip argTypes |>.foldl (fun acc (paramTy, argTy) =>
        let paramName := match paramTy with
          | .named n => if fnTyParams.contains n then some n else none
          | _ => none
        match paramName with
        | some n =>
          let concreteName := match argTy with
            | .named name => some name
            | .generic name _ => some name
            | _ => none
          match concreteName with
          | some cn => if acc.any fun (k, _) => k == n then acc else acc ++ [(n, cn)]
          | none => acc
        | none => acc
      ) ([] : List (String × String))
      -- Also use explicit typeArgs if provided
      let mapping := if !typeArgs.isEmpty then
        fnTyParams.zip typeArgs |>.foldl (fun acc (param, ty) =>
          let concreteName := match ty with
            | .named name => some name
            | .generic name _ => some name
            | _ => none
          match concreteName with
          | some cn => if acc.any fun (k, _) => k == param then acc else acc ++ [(param, cn)]
          | none => acc
        ) inferredMapping
      else inferredMapping
      -- Compute monomorphized name
      let typeNames := fnTyParams.map fun p => (mapping.lookup p).getD "unknown"
      let monoName := fnName ++ "_for_" ++ "_".intercalate typeNames
      -- Register monomorphized function if not already generated
      let s := if s.monoGenerated.contains monoName then s
        else
          match s.allFnDefs.find? fun f => f.name == fnName with
          | some origFn =>
            let tyMapping := mapping.map fun (k, v) => (k, Ty.named v)
            let monoFn := monoFnDef origFn monoName tyMapping
            let monoRetTy := normalizeFieldTy monoFn.retTy
            let monoParamTys := monoFn.params.map fun p => normalizeFieldTy p.ty
            { s with
              monoQueue := s.monoQueue ++ [(monoName, monoFn)]
              monoGenerated := monoName :: s.monoGenerated
              fnRetTypes := (monoName, monoRetTy) :: s.fnRetTypes
              fnParamTypes := (monoName, monoParamTys) :: s.fnParamTypes }
          | none => s
      (s, monoName)
    else (s, fnName)
    -- Use the raw (un-substituted) param types for generating argument values
    let rawParamTys := (s.fnParamTypes.lookup effectiveName).getD []
    -- But use hinted types for actually generating argument code
    let (s, argRegs) := genExprListWithHints s args rawParamTys
    -- For LLVM call, use the function's declared param types (i64 for type vars)
    let argTys := rawParamTys.map fun pty => paramTyToLLVM s pty
    -- Pad with inferred types if args > rawParamTys
    let argTys := if argTys.length < args.length then
      argTys ++ (args.drop argTys.length).map fun arg => paramTyToLLVM s (inferExprTy s arg)
    else argTys
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup effectiveName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .paren inner => genExpr s inner hintTy
  | .structLit name typeArgs fields =>
    match s.lookupStruct name with
    | some si =>
      let mapping : List (String × Ty) := si.typeParams.zip typeArgs
      let structTy := "%struct." ++ name
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ structTy)
      let s := fields.foldl (fun s (fieldName, fieldExpr) =>
        match si.fields.find? fun fi => fi.name == fieldName with
        | some fi =>
          -- Substitute type vars with concrete types
          let fieldTy := List.foldl (fun (ty : Ty) (pair : String × Ty) =>
            match ty with
            | .typeVar n => if n == pair.1 then pair.2 else ty
            | _ => ty) fi.ty mapping
          let (s, valReg) := genExpr s fieldExpr (some fieldTy)
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s fieldTy
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
            ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString fi.index)
          -- For pass-by-ptr field types (enums, structs), load value from pointer before storing
          if isPassByPtr s fieldTy && fieldLLTy != "ptr" then
            let resolvedFieldLLTy := tyToLLVM s fieldTy
            let (s, loaded) := s.freshLocal
            let s := s.emit ("  " ++ loaded ++ " = load " ++ resolvedFieldLLTy ++ ", ptr " ++ valReg)
            s.emit ("  store " ++ resolvedFieldLLTy ++ " " ++ loaded ++ ", ptr " ++ gepReg)
          else
            s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
        | none => s
      ) s
      (s, alloca)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown struct " ++ name)
      (s, reg)
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let (structName, typeArgs) := match innerTy with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | .string => ("String", [])
      | _ => ("", [])
    if structName != "" then
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        -- For generic types, substitute type params with concrete type args
        let fieldTy := if !typeArgs.isEmpty then
          match s.lookupStruct structName with
          | some si =>
            let mapping : List (String × Ty) := si.typeParams.zip typeArgs
            List.foldl (fun (ty : Ty) (pair : String × Ty) =>
              match ty with
              | .typeVar n => if n == pair.1 then pair.2 else ty
              | _ => ty) fieldTy mapping
          | none => fieldTy
        else fieldTy
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        if isPassByPtr s fieldTy then
          (s, gepReg)
        else
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          (s, loaded)
      | none =>
        let (s, reg) := s.freshLocal
        let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown field " ++ field)
        (s, reg)
    else
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; field access on non-struct")
      (s, reg)
  | .borrow inner =>
    genExprAsPtr s inner
  | .borrowMut inner =>
    genExprAsPtr s inner
  | .deref inner =>
    let (s, ptr) := genExpr s inner
    let innerTy := inferExprTy s inner
    match innerTy with
    | .heap t =>
      -- *heap_ptr: load value from heap, then free the allocation
      let innerLLTy := tyToLLVM s t
      if isPassByPtr s t then
        -- Struct/enum: load full value, free heap, store to new stack alloc
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ ptr)
        let s := s.emit ("  call void @free(ptr " ++ ptr ++ ")")
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca " ++ innerLLTy)
        let s := s.emit ("  store " ++ innerLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
        (s, alloca)
      else
        -- Scalar: load value, free heap, return value
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ ptr)
        let s := s.emit ("  call void @free(ptr " ++ ptr ++ ")")
        (s, loaded)
    | _ =>
      let pointeeTy := match innerTy with
        | .ref t => t
        | .refMut t => t
        | .ptrMut t => t
        | .ptrConst t => t
        | _ => .int
      let llTy := tyToLLVM s pointeeTy
      if llTy == "ptr" || isPassByPtr s pointeeTy then
        (s, ptr)
      else
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ llTy ++ ", ptr " ++ ptr)
        (s, loaded)
  | .enumLit enumName variant typeArgs fields =>
    match s.lookupEnum enumName with
    | some ei =>
      match ei.variants.find? fun v => v.name == variant with
      | some vi =>
        -- Build type substitution for generic enums
        -- If typeArgs empty but enum is generic, infer from hint
        let effectiveTypeArgs := if typeArgs.isEmpty && !ei.typeParams.isEmpty then
          match hintTy with
          | some (.generic n args) => if n == enumName then args else []
          | _ => []
        else typeArgs
        let enumTypeMapping := ei.typeParams.zip effectiveTypeArgs
        let enumTy := "%enum." ++ enumName
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca " ++ enumTy)
        let (s, tagPtr) := s.freshLocal
        let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
          ++ ", ptr " ++ alloca ++ ", i32 0, i32 0")
        let s := s.emit ("  store i32 " ++ toString vi.tag ++ ", ptr " ++ tagPtr)
        if !fields.isEmpty then
          let (s, payloadPtr) := s.freshLocal
          let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
            ++ ", ptr " ++ alloca ++ ", i32 0, i32 1")
          let variantTy := "%variant." ++ enumName ++ "." ++ variant
          let s := fields.foldl (fun s (fieldName, fieldExpr) =>
            match vi.fields.find? fun fi => fi.name == fieldName with
            | some fi =>
              let resolvedTy := normalizeFieldTy (substTyCodegen enumTypeMapping fi.ty)
              let (s, valReg) := genExpr s fieldExpr (some resolvedTy)
              let (s, gepReg) := s.freshLocal
              let fieldLLTy := fieldTyToLLVM s resolvedTy
              let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
                ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
              s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
            | none => s
          ) s
          (s, alloca)
        else
          (s, alloca)
      | none =>
        let (s, reg) := s.freshLocal
        let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown variant " ++ variant)
        (s, reg)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown enum " ++ enumName)
      (s, reg)
  | .match_ scrutinee arms =>
    let (s, scrReg) := genExpr s scrutinee
    let scrTy := inferExprTy s scrutinee
    let innerScrTy := match scrTy with
      | .ref t => t | .refMut t => t | t => t
    let enumName := match innerScrTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    -- Check if this is a value-pattern match (litArm/varArm) vs enum match
    let isValueMatch := arms.any fun arm => match arm with
      | .litArm _ _ | .varArm _ _ => true | _ => false
    if isValueMatch then
      -- Value-pattern match: emit if/else chain
      let scrLLTy := tyToLLVM s innerScrTy
      let (s, mergeLabel) := s.freshLabel "match.merge"
      let (s, armLabels) := arms.foldl (fun (acc : CodegenState × List String) _arm =>
        let (s, labels) := acc
        let (s, label) := s.freshLabel "match.arm"
        (s, labels ++ [label])
      ) (s, [])
      -- Build chain of conditional branches
      let (s, _) := (arms.zip armLabels).foldl (fun (acc : CodegenState × Nat) (arm, label) =>
        let (s, idx) := acc
        match arm with
        | .litArm val _ =>
          let (s, valReg) := genExpr s val (some innerScrTy)
          let (s, cmpReg) := s.freshLocal
          let s := s.emit ("  " ++ cmpReg ++ " = icmp eq " ++ scrLLTy ++ " " ++ scrReg ++ ", " ++ valReg)
          let nextLabel := if idx + 1 < armLabels.length then
            (armLabels.getD (idx + 1) mergeLabel) ++ ".check"
          else mergeLabel
          let s := s.emit ("  br i1 " ++ cmpReg ++ ", label %" ++ label ++ ", label %" ++ nextLabel)
          if idx + 1 < armLabels.length then
            let s := s.emit (nextLabel ++ ":")
            (s, idx + 1)
          else
            (s, idx + 1)
        | .varArm _ _ =>
          -- Catch-all: unconditional branch
          let s := s.emit ("  br label %" ++ label)
          (s, idx + 1)
        | _ => (s, idx + 1)
      ) (s, 0)
      -- Emit arm bodies
      let s := (arms.zip armLabels).foldl (fun s (arm, label) =>
        match arm with
        | .litArm _ body =>
          let s := s.emit (label ++ ":")
          let s := genStmts s body
          if stmtListHasReturn body then s else s.emit ("  br label %" ++ mergeLabel)
        | .varArm binding body =>
          let s := s.emit (label ++ ":")
          -- Bind the scrutinee value to the variable
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ scrLLTy)
          let s := s.emit ("  store " ++ scrLLTy ++ " " ++ scrReg ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          let s := s.addVarType binding innerScrTy
          let s := genStmts s body
          if stmtListHasReturn body then s else s.emit ("  br label %" ++ mergeLabel)
        | _ => s
      ) s
      let allReturn := arms.all fun arm => match arm with
        | .litArm _ body | .varArm _ body | .mk _ _ _ body => stmtListHasReturn body
      if allReturn then
        (s, "0")
      else
        let s := s.emit (mergeLabel ++ ":")
        let (s, dummy) := s.freshLocal
        let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
        (s, dummy)
    else
    -- Enum match
    let enumName := if enumName == "" then "unknown" else enumName
    let enumTy := "%enum." ++ enumName
    -- For references, genExpr already returns the pointer to the target
    let (s, scrPtr) := (s, scrReg)
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    let (s, mergeLabel) := s.freshLabel "match.merge"
    let (s, defaultLabel) := s.freshLabel "match.default"
    let (s, armLabels) := arms.foldl (fun (acc : CodegenState × List String) _arm =>
      let (s, labels) := acc
      let (s, label) := s.freshLabel "match.arm"
      (s, labels ++ [label])
    ) (s, [])
    let ei := (s.lookupEnum enumName).get!
    -- Build type substitution for generic enums (e.g., Option<Heap<Node>>)
    let enumTypeArgs := match innerScrTy with
      | .generic _ args => args
      | _ => []
    let enumTypeMapping : List (String × Ty) :=
      ei.typeParams.zip enumTypeArgs
    let cases := arms.zip armLabels |>.filterMap fun (arm, label) =>
      match arm with
      | .mk _ variant _ _ =>
        match ei.variants.find? fun v => v.name == variant with
        | some vi => some ("    i32 " ++ toString vi.tag ++ ", label %" ++ label)
        | none => none
      | _ => none
    let switchCases := "\n".intercalate cases
    let s := s.emit ("  switch i32 " ++ tag ++ ", label %" ++ defaultLabel ++ " [\n" ++ switchCases ++ "\n  ]")
    let s := (arms.zip armLabels).foldl (fun s (arm, label) =>
      match arm with
      | .mk _ variant bindings body =>
        let s := s.emit (label ++ ":")
        let variantTy := "%variant." ++ enumName ++ "." ++ variant
        let vi := (ei.variants.find? fun v => v.name == variant).get!
        let s := (bindings.zip vi.fields).foldl (fun s (binding, fi) =>
          -- Substitute generic type args for the field type
          let resolvedTy := normalizeFieldTy (substTyCodegen enumTypeMapping fi.ty)
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s resolvedTy
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
            ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ fieldLLTy)
          let s := s.emit ("  store " ++ fieldLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          s.addVarType binding resolvedTy
        ) s
        let s := genStmts s body
        let hasRet := stmtListHasReturn body
        if hasRet then s else s.emit ("  br label %" ++ mergeLabel)
      | _ => s
    ) s
    let s := s.emit (defaultLabel ++ ":")
    let s := s.emit "  unreachable"
    let allReturn := arms.all fun arm => match arm with
      | .mk _ _ _ body | .litArm _ body | .varArm _ body => stmtListHasReturn body
    if allReturn then
      (s, "0")
    else
      let s := s.emit (mergeLabel ++ ":")
      let (s, dummy) := s.freshLocal
      let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
      (s, dummy)
  | .try_ inner =>
    let (s, scrPtr) := genExpr s inner
    let innerTy := inferExprTy s inner
    let enumName := match innerTy with
      | .named n => n
      | _ => "unknown"
    let enumTy := "%enum." ++ enumName
    let ei := (s.lookupEnum enumName).get!
    let okVi := (ei.variants.find? fun v => v.name == "Ok").get!
    let okFieldTy := match okVi.fields.head? with
      | some fi => fi.ty
      | none => Ty.int
    let okFieldLLTy := tyToLLVM s okFieldTy
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    let (s, okLabel) := s.freshLabel "try.ok"
    let (s, errLabel) := s.freshLabel "try.err"
    let (s, isOk) := s.freshLocal
    let s := s.emit ("  " ++ isOk ++ " = icmp eq i32 " ++ tag ++ ", " ++ toString okVi.tag)
    let s := s.emit ("  br i1 " ++ isOk ++ ", label %" ++ okLabel ++ ", label %" ++ errLabel)
    let s := s.emit (errLabel ++ ":")
    let (s, errVal) := s.freshLocal
    let s := s.emit ("  " ++ errVal ++ " = load " ++ enumTy ++ ", ptr " ++ scrPtr)
    let s := s.emit ("  ret " ++ enumTy ++ " " ++ errVal)
    let s := s.emit (okLabel ++ ":")
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    let variantTy := "%variant." ++ enumName ++ ".Ok"
    let (s, valueGep) := s.freshLocal
    let s := s.emit ("  " ++ valueGep ++ " = getelementptr inbounds " ++ variantTy
      ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 0")
    if isPassByPtr s okFieldTy then
      (s, valueGep)
    else
      let (s, value) := s.freshLocal
      let s := s.emit ("  " ++ value ++ " = load " ++ okFieldLLTy ++ ", ptr " ++ valueGep)
      (s, value)
  | .arrayLit elems =>
    let elemTy := match hintTy with
      | some (.array t _) => t
      | _ => match elems.head? with
        | some e => inferExprTy s e hintTy
        | none => Ty.int
    let n := elems.length
    let arrTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca " ++ arrTy)
    let elemLLTy := tyToLLVM s elemTy
    let elemPassByPtr := isPassByPtr s elemTy
    let (s, _) := elems.foldl (fun (acc : CodegenState × Nat) e =>
      let s := acc.1
      let idx := acc.2
      let (s, valReg) := genExpr s e (some elemTy)
      let (s, gepReg) := s.freshLocal
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrTy
        ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString idx)
      let s := if elemPassByPtr then
        -- For nested arrays/structs, use memcpy instead of store
        let elemSize := tySize elemTy
        s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ gepReg ++ ", ptr " ++ valReg
          ++ ", i64 " ++ toString elemSize ++ ", i1 false)")
      else
        s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      (s, idx + 1)
    ) (s, 0)
    (s, alloca)
  | .arrayIndex arr index =>
    let arrTy := inferExprTy s arr
    let (elemTy, n) := match arrTy with
      | .array t sz => (t, sz)
      | _ => (.int, 0)
    let arrLLTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, arrPtr) := genExprAsPtr s arr
    let (s, idxReg) := genExpr s index
    -- Widen index to i64 if necessary
    let idxTy := inferExprTy s index
    let (s, idx64) := if intTyToLLVM idxTy != "i64" then
      let (s, widened) := s.freshLocal
      if isSignedInt idxTy then
        let s := s.emit ("  " ++ widened ++ " = sext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
      else
        let s := s.emit ("  " ++ widened ++ " = zext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
    else
      (s, idxReg)
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idx64)
    if isPassByPtr s elemTy then
      (s, gepReg)
    else
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ gepReg)
      (s, loaded)
  | .cast inner targetTy =>
    let (s, reg) := genExpr s inner
    let innerTy := inferExprTy s inner
    genCast s reg innerTy targetTy
  | .methodCall obj methodName _typeArgs args =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | .typeVar n => (s.typeVarMapping.lookup n).getD ""
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    let (s, selfPtr) := genExprAsPtr s obj
    let (s, argRegs) := genExprList s args
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let allArgRegs := selfPtr :: argRegs
    let allArgTys := "ptr" :: argTys
    let argPairs := allArgTys.zip allArgRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .staticMethodCall typeName methodName _typeArgs args =>
    let mangledName := typeName ++ "_" ++ methodName
    let (s, argRegs) := genExprList s args
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .arrowAccess obj field =>
    -- p->x: load pointer from variable, GEP to field, load
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | _ => objTy
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    match s.lookupFieldIndex structName field with
    | some (idx, fieldTy) =>
      let structTy := "%struct." ++ structName
      -- Get the heap pointer (ptr value stored in the variable)
      let (s, heapPtr) := genExpr s obj
      let (s, gepReg) := s.freshLocal
      let fieldLLTy := fieldTyToLLVM s fieldTy
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
        ++ ", ptr " ++ heapPtr ++ ", i32 0, i32 " ++ toString idx)
      if isPassByPtr s fieldTy then
        (s, gepReg)
      else
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
        (s, loaded)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown field " ++ field)
      (s, reg)
  | .allocCall inner _allocExpr =>
    -- For now, just generate the inner call
    genExpr s inner hintTy
  | .whileExpr cond body elseBody =>
    -- while-as-expression: alloca result slot, loop with break storing value, else stores default
    let resultTy := inferExprTy s (.whileExpr cond body elseBody) hintTy
    let resultLLTy := tyToLLVM s resultTy
    let (s, resultSlot) := s.freshLocal
    let s := s.emit ("  " ++ resultSlot ++ " = alloca " ++ resultLLTy)
    let (s, condLabel) := s.freshLabel "wexpr.cond"
    let (s, bodyLabel) := s.freshLabel "wexpr.body"
    let (s, elseLabel) := s.freshLabel "wexpr.else"
    let (s, exitLabel) := s.freshLabel "wexpr.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedSlot := s.loopResultSlot
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some condLabel, loopResultSlot := some resultSlot }
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ elseLabel)
    -- Body
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ condLabel)
    -- Else: generate all stmts except the last (which is the value expression)
    let s := s.emit (elseLabel ++ ":")
    let elseInit := elseBody.dropLast
    let s := genStmts s elseInit
    -- Get the value from the last expression in else body
    let (s, elseVal) := match elseBody.getLast? with
      | some (.expr e) => genExpr s e (some resultTy)
      | _ =>
        let (s, dummy) := s.freshLocal
        let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
        (s, dummy)
    let s := s.emit ("  store " ++ resultLLTy ++ " " ++ elseVal ++ ", ptr " ++ resultSlot)
    let s := s.emit ("  br label %" ++ exitLabel)
    -- Exit
    let s := s.emit (exitLabel ++ ":")
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = load " ++ resultLLTy ++ ", ptr " ++ resultSlot)
    let s := { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopResultSlot := savedSlot }
    (s, result)
  | .fnRef fnName =>
    -- Function reference: just store the function pointer
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca ptr")
    let s := s.emit ("  store ptr @" ++ fnName ++ ", ptr " ++ alloca)
    (s, alloca)

/-- Generate a type cast in LLVM IR. -/
partial def genCast (s : CodegenState) (reg : String) (fromTy : Ty) (toTy : Ty) : CodegenState × String :=
  let (s, result) := s.freshLocal
  let fromLLTy := tyToLLVM s fromTy
  let toLLTy := tyToLLVM s toTy
  let fromBits := tyBitWidth fromTy
  let toBits := tyBitWidth toTy
  -- Same type? No-op (for pointers, use bitcast; for integers, use add)
  if fromLLTy == toLLTy then
    if fromLLTy == "ptr" then
      -- Pointer-to-pointer no-op: just reuse the register
      (s, reg)
    else
      let s := s.emit ("  " ++ result ++ " = add " ++ fromLLTy ++ " 0, " ++ reg)
      (s, result)
  -- Pointer <-> Pointer, or Pointer <-> Integer
  else if (match fromTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false) &&
          (match toTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false) then
    -- Pointer to pointer: both are `ptr` in opaque pointer mode, no-op
    (s, reg)
  else if (match fromTy with | .ptrMut _ | .ptrConst _ => true | _ => false) && isIntegerType toTy then
    let s := s.emit ("  " ++ result ++ " = ptrtoint ptr " ++ reg ++ " to " ++ toLLTy)
    (s, result)
  else if isIntegerType fromTy && (match toTy with | .ptrMut _ | .ptrConst _ => true | _ => false) then
    let s := s.emit ("  " ++ result ++ " = inttoptr " ++ fromLLTy ++ " " ++ reg ++ " to ptr")
    (s, result)
  -- Array to pointer: get pointer to first element
  else if (match fromTy with | .array _ _ => true | _ => false) &&
          (match toTy with | .ptrMut _ | .ptrConst _ => true | _ => false) then
    -- Array decays to pointer
    let s := s.emit ("  " ++ result ++ " = getelementptr " ++ fromLLTy ++ ", ptr " ++ reg ++ ", i32 0, i32 0")
    (s, result)
  -- Bool to integer
  else if fromTy == .bool && isIntegerType toTy then
    let s := s.emit ("  " ++ result ++ " = zext i1 " ++ reg ++ " to " ++ toLLTy)
    (s, result)
  -- Integer to Bool
  else if isIntegerType fromTy && toTy == .bool then
    let s := s.emit ("  " ++ result ++ " = icmp ne " ++ fromLLTy ++ " " ++ reg ++ ", 0")
    (s, result)
  -- Integer widening/narrowing
  else if isIntegerType fromTy && isIntegerType toTy then
    if fromBits < toBits then
      if isSignedInt fromTy then
        let s := s.emit ("  " ++ result ++ " = sext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
        (s, result)
      else
        let s := s.emit ("  " ++ result ++ " = zext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
        (s, result)
    else if fromBits > toBits then
      let s := s.emit ("  " ++ result ++ " = trunc " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      -- Same bit width, different signedness: no-op
      let s := s.emit ("  " ++ result ++ " = add " ++ toLLTy ++ " 0, " ++ reg)
      (s, result)
  -- Integer to float
  else if isIntegerType fromTy && isFloatType toTy then
    if isSignedInt fromTy then
      let s := s.emit ("  " ++ result ++ " = sitofp " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = uitofp " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Float to integer
  else if isFloatType fromTy && isIntegerType toTy then
    if isSignedInt toTy then
      let s := s.emit ("  " ++ result ++ " = fptosi " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = fptoui " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Float to float
  else if isFloatType fromTy && isFloatType toTy then
    if fromBits < toBits then
      let s := s.emit ("  " ++ result ++ " = fpext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = fptrunc " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Char to integer
  else if fromTy == .char && isIntegerType toTy then
    if toBits > 8 then
      let s := s.emit ("  " ++ result ++ " = zext i8 " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = add i8 0, " ++ reg)
      (s, result)
  -- Integer to char
  else if isIntegerType fromTy && toTy == .char then
    if fromBits > 8 then
      let s := s.emit ("  " ++ result ++ " = trunc " ++ fromLLTy ++ " " ++ reg ++ " to i8")
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = add i8 0, " ++ reg)
      (s, result)
  -- Fallback: identity
  else
    let s := s.emit ("  " ++ result ++ " = add i64 0, " ++ reg ++ " ; fallback cast")
    (s, result)

/-- Get a pointer to an expression's storage (for struct GEP). -/
partial def genExprAsPtr (s : CodegenState) (e : Expr) : CodegenState × String :=
  match e with
  | .ident name =>
    match s.lookupVar name with
    | some alloca => (s, alloca)
    | none => (s, "%" ++ name)
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | .string => "String"
      | _ => ""
    if structName != "" then
      match s.lookupFieldIndex structName field with
      | some (idx, _) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        (s, gepReg)
      | none => (s, "%undef")
    else (s, "%undef")
  | .strLit _ =>
    genExpr s e
  | .borrow _ | .borrowMut _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .deref _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .enumLit _ _ _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .match_ _ _ =>
    let (s, reg) := genExpr s e
    (s, reg)
  | .arrayLit _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .arrayIndex _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .methodCall _ _ _ _ | .staticMethodCall _ _ _ _ | .cast _ _ | .arrowAccess _ _ | .allocCall _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | _ =>
    let (s, reg) := genExpr s e
    let ty := inferExprTy s e
    let llTy := tyToLLVM s ty
    let (s, tmp) := s.freshLocal
    let s := s.emit ("  " ++ tmp ++ " = alloca " ++ llTy)
    let s := s.emit ("  store " ++ llTy ++ " " ++ reg ++ ", ptr " ++ tmp)
    (s, tmp)

partial def genExprList (s : CodegenState) (args : List Expr) : CodegenState × List String :=
  match args with
  | [] => (s, [])
  | e :: rest =>
    let (s, reg) := genExpr s e
    let (s, regs) := genExprList s rest
    (s, reg :: regs)

/-- Generate expressions with type hints from parameter types. -/
partial def genExprListWithHints (s : CodegenState) (args : List Expr) (hints : List Ty) : CodegenState × List String :=
  match args, hints with
  | [], _ => (s, [])
  | e :: rest, h :: hRest =>
    let (s, reg) := genExpr s e (some h)
    let (s, regs) := genExprListWithHints s rest hRest
    (s, reg :: regs)
  | e :: rest, [] =>
    let (s, reg) := genExpr s e
    let (s, regs) := genExprListWithHints s rest []
    (s, reg :: regs)

/-- Generate LLVM IR for Vec<T> builtin calls. Returns (state, result_register). -/
partial def genVecBuiltinCall (s : CodegenState) (fnName : String) (typeArgs : List Ty) (args : List Expr) (hintTy : Option Ty := none) : CodegenState × String :=
  if fnName == "vec_new" then
    let elemTy := match typeArgs.head? with | some t => t | none => Ty.int
    let elemSize := tySizeOf s elemTy
    let initCap := 8
    let initBytes := initCap * elemSize
    -- Allocate initial buffer
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = call ptr @malloc(i64 " ++ toString initBytes ++ ")")
    -- Build Vec struct on stack: { buf, 0, 8 }
    let (s, vecAlloca) := s.freshLocal
    let s := s.emit ("  " ++ vecAlloca ++ " = alloca %struct.Vec")
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 0")
    let s := s.emit ("  store ptr " ++ buf ++ ", ptr " ++ bufPtr)
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 1")
    let s := s.emit ("  store i64 0, ptr " ++ lenPtr)
    let (s, capPtr) := s.freshLocal
    let s := s.emit ("  " ++ capPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 2")
    let s := s.emit ("  store i64 " ++ toString initCap ++ ", ptr " ++ capPtr)
    (s, vecAlloca)
  else if fnName == "vec_push" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let valArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    -- Determine element type from vec arg
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    -- Get vec pointer (it's &mut Vec<T> so genExpr gives a ptr)
    let (s, vecPtr) := genExpr s vecArg
    -- Load len and cap
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    let (s, capPtr) := s.freshLocal
    let s := s.emit ("  " ++ capPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 2")
    let (s, cap) := s.freshLocal
    let s := s.emit ("  " ++ cap ++ " = load i64, ptr " ++ capPtr)
    -- Check if we need to grow: len >= cap
    let (s, needGrow) := s.freshLocal
    let s := s.emit ("  " ++ needGrow ++ " = icmp uge i64 " ++ len ++ ", " ++ cap)
    let (s, growLabel) := s.freshLabel "vec.grow"
    let (s, doneLabel) := s.freshLabel "vec.grow.done"
    let s := s.emit ("  br i1 " ++ needGrow ++ ", label %" ++ growLabel ++ ", label %" ++ doneLabel)
    -- Grow path: realloc to 2x capacity
    let s := s.emit (growLabel ++ ":")
    let (s, newCap) := s.freshLocal
    let s := s.emit ("  " ++ newCap ++ " = mul i64 " ++ cap ++ ", 2")
    let (s, newBytes) := s.freshLocal
    let s := s.emit ("  " ++ newBytes ++ " = mul i64 " ++ newCap ++ ", " ++ toString elemSize)
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, oldBuf) := s.freshLocal
    let s := s.emit ("  " ++ oldBuf ++ " = load ptr, ptr " ++ bufPtr)
    let (s, newBuf) := s.freshLocal
    let s := s.emit ("  " ++ newBuf ++ " = call ptr @realloc(ptr " ++ oldBuf ++ ", i64 " ++ newBytes ++ ")")
    let s := s.emit ("  store ptr " ++ newBuf ++ ", ptr " ++ bufPtr)
    let s := s.emit ("  store i64 " ++ newCap ++ ", ptr " ++ capPtr)
    let s := s.emit ("  br label %" ++ doneLabel)
    -- Done path: store value at buf[len]
    let s := s.emit (doneLabel ++ ":")
    let (s, bufPtr2) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr2 ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, curBuf) := s.freshLocal
    let s := s.emit ("  " ++ curBuf ++ " = load ptr, ptr " ++ bufPtr2)
    -- Reload len (same register is valid due to SSA dominance since both paths converge)
    let (s, curLen) := s.freshLocal
    let s := s.emit ("  " ++ curLen ++ " = load i64, ptr " ++ lenPtr)
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ curLen ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ curBuf ++ ", i64 " ++ offset)
    -- Generate value and store
    if isPassByPtr s elemTy then
      let (s, valPtr) := genExpr s valArg (some elemTy)
      let elemLLTy := tyToLLVM s elemTy
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ valPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ elemPtr)
      -- Increment len
      let (s, newLen) := s.freshLocal
      let s := s.emit ("  " ++ newLen ++ " = add i64 " ++ curLen ++ ", 1")
      let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
      (s, "0")
    else
      let (s, valReg) := genExpr s valArg (some elemTy)
      let elemLLTy := tyToLLVM s elemTy
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ elemPtr)
      -- Increment len
      let (s, newLen) := s.freshLocal
      let s := s.emit ("  " ++ newLen ++ " = add i64 " ++ curLen ++ ", 1")
      let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
      (s, "0")
  else if fnName == "vec_get" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .ref (.generic "Vec" [et]) => et
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    let (s, vecPtr) := genExpr s vecArg
    let (s, idxReg) := genExpr s idxArg (some .int)
    -- Load data buffer
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    -- Compute offset
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ idxReg ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    if isPassByPtr s elemTy then
      -- Return pointer to element (caller will load if needed)
      (s, elemPtr)
    else
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ elemPtr)
      (s, loaded)
  else if fnName == "vec_set" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    let (s, vecPtr) := genExpr s vecArg
    let (s, idxReg) := genExpr s idxArg (some .int)
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ idxReg ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    if isPassByPtr s elemTy then
      let (s, valPtr) := genExpr s valArg (some elemTy)
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ valPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ elemPtr)
      (s, "0")
    else
      let (s, valReg) := genExpr s valArg (some elemTy)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ elemPtr)
      (s, "0")
  else if fnName == "vec_len" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let (s, vecPtr) := genExpr s vecArg
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    (s, len)
  else if fnName == "vec_pop" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    -- Look up Option enum info for payload size
    let optPayloadSize := match s.lookupEnum "Option" with
      | some ei => ei.payloadSize
      | none => 8
    let actualPayloadSize := if tySizeOf s elemTy > optPayloadSize then tySizeOf s elemTy else optPayloadSize
    let optTotalSize := 4 + actualPayloadSize
    let (s, vecPtr) := genExpr s vecArg
    -- Load len
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    -- Alloca for result Option
    let (s, optAlloca) := s.freshLocal
    let s := s.emit ("  " ++ optAlloca ++ " = alloca [" ++ toString optTotalSize ++ " x i8]")
    -- Check if len == 0
    let (s, isEmpty) := s.freshLocal
    let s := s.emit ("  " ++ isEmpty ++ " = icmp eq i64 " ++ len ++ ", 0")
    let (s, emptyLabel) := s.freshLabel "vec.pop.empty"
    let (s, someLabel) := s.freshLabel "vec.pop.some"
    let (s, doneLabel) := s.freshLabel "vec.pop.done"
    let s := s.emit ("  br i1 " ++ isEmpty ++ ", label %" ++ emptyLabel ++ ", label %" ++ someLabel)
    -- Empty: return None (tag=1)
    let s := s.emit (emptyLabel ++ ":")
    let s := s.emit ("  store i32 1, ptr " ++ optAlloca)
    let s := s.emit ("  br label %" ++ doneLabel)
    -- Some: decrement len, load last element, return Some
    let s := s.emit (someLabel ++ ":")
    let (s, newLen) := s.freshLocal
    let s := s.emit ("  " ++ newLen ++ " = sub i64 " ++ len ++ ", 1")
    let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
    -- Load data buf
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    -- Load element at newLen offset
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ newLen ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    -- Write tag=0 (Some)
    let s := s.emit ("  store i32 0, ptr " ++ optAlloca)
    -- Write payload at offset 4
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr i8, ptr " ++ optAlloca ++ ", i64 4")
    if isPassByPtr s elemTy then
      let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ payloadPtr ++ ", ptr " ++ elemPtr ++ ", i64 " ++ toString elemSize ++ ", i1 false)")
      let s := s.emit ("  br label %" ++ doneLabel)
      let s := s.emit (doneLabel ++ ":")
      (s, optAlloca)
    else
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ elemPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ payloadPtr)
      let s := s.emit ("  br label %" ++ doneLabel)
      let s := s.emit (doneLabel ++ ":")
      (s, optAlloca)
  else if fnName == "vec_free" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let (s, vecPtr) := genExpr s vecArg
    -- Load data buf and free it
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    let s := s.emit ("  call void @free(ptr " ++ buf ++ ")")
    (s, "0")
  else
    (s, "0")

/-- Generate LLVM IR for HashMap<K,V> builtin calls.
    Calls pre-emitted helper functions __hashmap_int_* or __hashmap_str_*. -/
partial def genHashMapBuiltinCall (s : CodegenState) (fnName : String) (typeArgs : List Ty) (args : List Expr) (_hintTy : Option Ty := none) : CodegenState × String :=
  if fnName == "map_new" then
    let kTy := match typeArgs with | t :: _ => t | [] => Ty.int
    let vTy := match typeArgs with | _ :: t :: _ => t | _ => Ty.int
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    -- Call __hashmap_<pfx>_new(kSize, vSize) → returns ptr to HashMap on heap
    let (s, mapAlloca) := s.freshLocal
    let s := s.emit ("  " ++ mapAlloca ++ " = alloca %struct.HashMap")
    let (s, _ret) := s.freshLocal
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_new(ptr " ++ mapAlloca ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, mapAlloca)
  else if fnName == "map_insert" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit 0
    let mapArgTy := inferExprTy s mapArg
    let (kTy, vTy) := match mapArgTy with
      | .refMut (.generic "HashMap" [k, v]) => (k, v)
      | _ => (.int, .int)
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, valReg) := genExpr s valArg (some vTy)
    -- For scalar keys, store to temp alloca so we can pass ptr
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let (s, valPtr) := if isPassByPtr s vTy then (s, valReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s vTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s vTy ++ " " ++ valReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_insert(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", ptr " ++ valPtr ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, "0")
  else if fnName == "map_get" || fnName == "map_remove" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    let mapArgTy := inferExprTy s mapArg
    let (kTy, vTy) := match mapArgTy with
      | .ref (.generic "HashMap" [k, v]) => (k, v)
      | .refMut (.generic "HashMap" [k, v]) => (k, v)
      | _ => (.int, .int)
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    -- Allocate result Option (tag + payload)
    let optPayloadSize := match s.lookupEnum "Option" with
      | some ei => ei.payloadSize
      | none => 8
    let actualPSize := if vSize > optPayloadSize then vSize else optPayloadSize
    let optSize := 4 + actualPSize
    let (s, optAlloca) := s.freshLocal
    let s := s.emit ("  " ++ optAlloca ++ " = alloca [" ++ toString optSize ++ " x i8]")
    let opName := if fnName == "map_remove" then "remove" else "get"
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_" ++ opName ++ "(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", ptr " ++ optAlloca ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, optAlloca)
  else if fnName == "map_contains" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit 0
    let mapArgTy := inferExprTy s mapArg
    let kTy := match mapArgTy with
      | .ref (.generic "HashMap" [k, _]) => k
      | .refMut (.generic "HashMap" [k, _]) => k
      | _ => .int
    let kSize := tySizeOf s kTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = call i1 @__hashmap_" ++ pfx ++ "_contains(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", i64 " ++ toString kSize ++ ")")
    (s, result)
  else if fnName == "map_len" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let (s, mapPtr) := genExpr s mapArg
    let (s, lenFld) := s.freshLocal
    let s := s.emit ("  " ++ lenFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 3")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenFld)
    (s, len)
  else if fnName == "map_free" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit 0
    let (s, mapPtr) := genExpr s mapArg
    let (s, kFld) := s.freshLocal
    let s := s.emit ("  " ++ kFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 0")
    let (s, kBuf) := s.freshLocal
    let s := s.emit ("  " ++ kBuf ++ " = load ptr, ptr " ++ kFld)
    let s := s.emit ("  call void @free(ptr " ++ kBuf ++ ")")
    let (s, vFld) := s.freshLocal
    let s := s.emit ("  " ++ vFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 1")
    let (s, vBuf) := s.freshLocal
    let s := s.emit ("  " ++ vBuf ++ " = load ptr, ptr " ++ vFld)
    let s := s.emit ("  call void @free(ptr " ++ vBuf ++ ")")
    let (s, fFld) := s.freshLocal
    let s := s.emit ("  " ++ fFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 2")
    let (s, fBuf) := s.freshLocal
    let s := s.emit ("  " ++ fBuf ++ " = load ptr, ptr " ++ fFld)
    let s := s.emit ("  call void @free(ptr " ++ fBuf ++ ")")
    (s, "0")
  else
    (s, "0")

partial def genStmts (s : CodegenState) (stmts : List Stmt) : CodegenState :=
  match stmts with
  | [] => s
  | stmt :: rest => genStmts (genStmt s stmt) rest

partial def genStmt (s : CodegenState) (stmt : Stmt) : CodegenState :=
  match stmt with
  | .letDecl name _mutable ty value =>
    let exprTy := normalizeTy (match ty with
      | some t => t
      | none => inferExprTy s value)
    if isPassByPtr s exprTy then
      let (s, valPtr) := genExpr s value (some exprTy)
      let s := s.addVar name valPtr
      s.addVarType name exprTy
    else
      let llTy := tyToLLVM s exprTy
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
      let (s, valReg) := genExpr s value (some exprTy)
      -- Check if the generated value's type differs from expected (e.g. generic fn returning i64 but we want i32)
      let actualTy := inferExprTy s value (some exprTy)
      let actualLLTy := tyToLLVM s actualTy
      let (s, finalReg) := if actualLLTy != llTy && actualLLTy != "void" && llTy != "void" then
        -- Direct trunc/ext for integer type mismatches (avoids genCast issues)
        let fromBits := tyBitWidth (match actualTy with | .typeVar _ => Ty.int | t => t)
        let toBits := tyBitWidth exprTy
        if fromBits > toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = trunc " ++ actualLLTy ++ " " ++ valReg ++ " to " ++ llTy)
          (s, r)
        else if fromBits < toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = zext " ++ actualLLTy ++ " " ++ valReg ++ " to " ++ llTy)
          (s, r)
        else
          (s, valReg)
      else
        (s, valReg)
      let s := s.emit ("  store " ++ llTy ++ " " ++ finalReg ++ ", ptr " ++ alloca)
      let s := s.addVar name alloca
      s.addVarType name exprTy
  | .assign name value =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      if isPassByPtr s ty then
        let (s, valPtr) := genExpr s value (some ty)
        let s := { s with vars := s.vars.map fun (n, v) =>
          if n == name then (n, valPtr) else (n, v) }
        s
      else
        let llTy := tyToLLVM s ty
        let (s, valReg) := genExpr s value (some ty)
        s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ alloca)
    | none => s.emit ("; ERROR: unknown variable " ++ name)
  | .return_ (some value) =>
    let retTy := s.currentRetTy
    let (s, reg) := genExpr s value (some retTy)
    -- Emit all deferred expressions before returning
    let s := emitAllDeferred s
    if isPassByPtr s retTy then
      let llTy := tyToLLVM s retTy
      let (s, val) := s.freshLocal
      let s := s.emit ("  " ++ val ++ " = load " ++ llTy ++ ", ptr " ++ reg)
      s.emit ("  ret " ++ llTy ++ " " ++ val)
    else
      let llTy := tyToLLVM s retTy
      -- Check if the value type differs (e.g. generic returning i64 but ret is i32)
      let valTy := inferExprTy s value (some retTy)
      let valLLTy := tyToLLVM s valTy
      let (s, finalReg) := if valLLTy != llTy && valLLTy != "void" && llTy != "void" then
        let fromBits := tyBitWidth valTy
        let toBits := tyBitWidth retTy
        if fromBits > toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = trunc " ++ valLLTy ++ " " ++ reg ++ " to " ++ llTy)
          (s, r)
        else if fromBits < toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = sext " ++ valLLTy ++ " " ++ reg ++ " to " ++ llTy)
          (s, r)
        else (s, reg)
      else (s, reg)
      s.emit ("  ret " ++ llTy ++ " " ++ finalReg)
  | .return_ none =>
    let s := emitAllDeferred s
    s.emit "  ret void"
  | .expr e =>
    let (s, _) := genExpr s e
    s
  | .ifElse cond thenBody elseBody =>
    let (s, condReg) := genExpr s cond
    -- If condition is not i1, convert to i1
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let (s, thenLabel) := s.freshLabel "then"
    let (s, elseLabel) := s.freshLabel "else"
    let (s, mergeLabel) := s.freshLabel "merge"
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ thenLabel ++ ", label %" ++ elseLabel)
    let s := s.emit (thenLabel ++ ":")
    let s := genStmts s thenBody
    let thenReturns := stmtListHasReturn thenBody
    let s := if thenReturns then s
             else s.emit ("  br label %" ++ mergeLabel)
    let s := s.emit (elseLabel ++ ":")
    let elseReturns := match elseBody with
      | some stmts => stmtListHasReturn stmts
      | none => false
    let s := match elseBody with
      | some stmts =>
        let s := genStmts s stmts
        if elseReturns then s
        else s.emit ("  br label %" ++ mergeLabel)
      | none => s.emit ("  br label %" ++ mergeLabel)
    if thenReturns && elseReturns then s
    else s.emit (mergeLabel ++ ":")
  | .fieldAssign obj field value =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    match innerTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        let (s, valReg) := genExpr s value (some fieldTy)
        s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      | none => s.emit ("; ERROR: unknown field " ++ field)
    | _ => s.emit ("; ERROR: field assign on non-struct")
  | .derefAssign target value =>
    let (s, ptr) := genExpr s target
    let targetTy := inferExprTy s target
    let pointeeTy := match targetTy with
      | .refMut t => t
      | .ref t => t
      | .ptrMut t => t
      | .ptrConst t => t
      | t => t
    let (s, valReg) := genExpr s value (some pointeeTy)
    let llTy := tyToLLVM s pointeeTy
    s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ ptr)
  | .arrayIndexAssign arr index value =>
    let arrTy := inferExprTy s arr
    let (elemTy, n) := match arrTy with
      | .array t sz => (t, sz)
      | _ => (.int, 0)
    let arrLLTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, arrPtr) := genExprAsPtr s arr
    let (s, idxReg) := genExpr s index
    let idxTy := inferExprTy s index
    let (s, idx64) := if intTyToLLVM idxTy != "i64" then
      let (s, widened) := s.freshLocal
      if isSignedInt idxTy then
        let s := s.emit ("  " ++ widened ++ " = sext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
      else
        let s := s.emit ("  " ++ widened ++ " = zext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
    else
      (s, idxReg)
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idx64)
    if isPassByPtr s elemTy then
      -- For arrays of arrays, need to memcpy
      let (s, valPtr) := genExpr s value (some elemTy)
      let tySz := tySize elemTy
      let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ gepReg ++ ", ptr " ++ valPtr ++ ", i64 " ++ toString tySz ++ ", i1 false)")
      s
    else
      let (s, valReg) := genExpr s value (some elemTy)
      s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
  | .while_ cond body lbl =>
    let (s, condLabel) := s.freshLabel "while.cond"
    let (s, bodyLabel) := s.freshLabel "while.body"
    let (s, exitLabel) := s.freshLabel "while.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedLabelMap := s.loopLabelMap
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some condLabel }
    let s := match lbl with
      | some l => { s with loopLabelMap := (l, exitLabel, condLabel) :: s.loopLabelMap }
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ exitLabel)
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (exitLabel ++ ":")
    { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopLabelMap := savedLabelMap }
  | .forLoop init cond step body lbl =>
    -- Generate init
    let s := match init with
      | some initStmt => genStmt s initStmt
      | none => s
    -- for loop = while with step
    let (s, condLabel) := s.freshLabel "for.cond"
    let (s, bodyLabel) := s.freshLabel "for.body"
    let (s, stepLabel) := s.freshLabel "for.step"
    let (s, exitLabel) := s.freshLabel "for.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedLabelMap := s.loopLabelMap
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some stepLabel }
    let s := match lbl with
      | some l => { s with loopLabelMap := (l, exitLabel, stepLabel) :: s.loopLabelMap }
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ exitLabel)
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ stepLabel)
    -- Generate step
    let s := s.emit (stepLabel ++ ":")
    let s := match step with
      | some stepStmt => genStmt s stepStmt
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (exitLabel ++ ":")
    { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopLabelMap := savedLabelMap }
  | .break_ value lbl =>
    -- Store break value to result slot if present (while-as-expression)
    let s := match value, s.loopResultSlot with
    | some expr, some slot =>
      let resultTy := inferExprTy s expr
      let resultLLTy := tyToLLVM s resultTy
      let (s, valReg) := genExpr s expr
      s.emit ("  store " ++ resultLLTy ++ " " ++ valReg ++ ", ptr " ++ slot)
    | _, _ => s
    -- Find the target label: if labeled, look up in loopLabelMap; otherwise use current loop
    let targetExit := match lbl with
    | some l => match s.loopLabelMap.find? fun (name, _, _) => name == l with
      | some (_, exit, _) => some exit
      | none => s.loopExitLabel
    | none => s.loopExitLabel
    match targetExit with
    | some target =>
      let s := s.emit ("  br label %" ++ target)
      let (s, deadLabel) := s.freshLabel "break.dead"
      s.emit (deadLabel ++ ":")
    | none => s
  | .continue_ lbl =>
    let targetCont := match lbl with
    | some l => match s.loopLabelMap.find? fun (name, _, _) => name == l with
      | some (_, _, cont) => some cont
      | none => s.loopContLabel
    | none => s.loopContLabel
    match targetCont with
    | some target =>
      let s := s.emit ("  br label %" ++ target)
      let (s, deadLabel) := s.freshLabel "cont.dead"
      s.emit (deadLabel ++ ":")
    | none => s
  | .defer body =>
    -- Push deferred expression onto current scope's defer list
    let deferStack := s.deferStack
    match deferStack with
    | current :: rest =>
      { s with deferStack := (body :: current) :: rest }
    | [] =>
      { s with deferStack := [[body]] }
  | .borrowIn _var ref _region _isMut body =>
    -- Regions are erased at codegen — ref = pointer to var's alloca
    -- The var name is in _var, but we need to find the ref source
    -- For stack values: ref = pointer to var's alloca
    let varName := _var
    let refPtr := match s.lookupVar varName with
      | some alloca => alloca
      | none => "%undef"
    -- Map ref to the same alloca
    let s := s.addVar ref refPtr
    let varTy := (s.lookupVarType varName).getD .int
    let refTy := if _isMut then Ty.refMut varTy else Ty.ref varTy
    let s := s.addVarType ref refTy
    genStmts s body
  | .arrowAssign obj field value =>
    -- p->x = val: load heap ptr, GEP to field, store
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | _ => objTy
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    match s.lookupFieldIndex structName field with
    | some (idx, fieldTy) =>
      let structTy := "%struct." ++ structName
      let (s, heapPtr) := genExpr s obj
      let (s, gepReg) := s.freshLocal
      let fieldLLTy := fieldTyToLLVM s fieldTy
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
        ++ ", ptr " ++ heapPtr ++ ", i32 0, i32 " ++ toString idx)
      let (s, valReg) := genExpr s value (some fieldTy)
      s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
    | none => s.emit ("; ERROR: unknown field " ++ field)

/-- Emit all deferred expressions in the current scope (LIFO order). -/
partial def emitDeferred (s : CodegenState) (deferred : List Expr) : CodegenState :=
  match deferred with
  | [] => s
  | e :: rest =>
    let (s, _) := genExpr s e
    emitDeferred s rest

/-- Emit all deferred expressions from ALL scope levels, innermost first. -/
partial def emitAllDeferred (s : CodegenState) : CodegenState :=
  s.deferStack.foldl (fun s scope => emitDeferred s scope) s

end

def genFnParams (s : CodegenState) (params : List Param) : CodegenState :=
  match params with
  | [] => s
  | p :: rest =>
    let pty := normalizeTy p.ty
    if isPassByPtr s pty then
      let s := s.addVar p.name ("%" ++ p.name)
      let s := s.addVarType p.name pty
      genFnParams s rest
    else
      let llTy := tyToLLVM s pty
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
      let s := s.emit ("  store " ++ llTy ++ " %" ++ p.name ++ ", ptr " ++ alloca)
      let s := s.addVar p.name alloca
      let s := s.addVarType p.name pty
      genFnParams s rest

def genFn (s : CodegenState) (f : FnDef) (hasMainWrapper : Bool := false) : CodegenState :=
  let normalizedRetTy := normalizeTy f.retTy
  let retTy := tyToLLVM s normalizedRetTy
  let fnName := if f.name == "main" && hasMainWrapper then "concrete_main" else f.name
  let paramStr := ", ".intercalate (f.params.map fun p => paramTyToLLVM s (normalizeTy p.ty) ++ " %" ++ p.name)
  let s := s.emit ("define " ++ retTy ++ " @" ++ fnName ++ "(" ++ paramStr ++ ") {")
  let savedDeferStack := s.deferStack
  let s := { s with currentRetTy := normalizedRetTy, deferStack := [[]] }
  let s := genFnParams s f.params
  let s := genStmts s f.body
  let s := if !stmtListHasReturn f.body then
    let s := emitAllDeferred s
    if retTy == "void" then s.emit "  ret void"
    else s.emit ("  ret " ++ retTy ++ " 0")
  else s
  let s := { s with deferStack := savedDeferStack }
  s.emit "}\n"

/-- Substitute type variables using a mapping (for generic enum/struct instantiation). -/
private def enumerateFields (fields : List StructField) (idx : Nat := 0) : List FieldInfo :=
  match fields with
  | [] => []
  | f :: rest => { name := f.name, ty := normalizeFieldTy f.ty, index := idx } :: enumerateFields rest (idx + 1)

def buildStructDefs (structs : List StructDef) : List StructInfo :=
  structs.map fun sd =>
    { name := sd.name, fields := enumerateFields sd.fields, typeParams := sd.typeParams }

private def variantPayloadSize (fields : List StructField) : Nat :=
  fields.foldl (fun acc f => acc + tySize f.ty) 0

private def enumerateVariants (variants : List EnumVariant) (tag : Nat := 0) : List EnumVariantInfo :=
  match variants with
  | [] => []
  | v :: rest =>
    { name := v.name, tag, fields := enumerateFields v.fields } :: enumerateVariants rest (tag + 1)

def buildEnumDefs (enums : List EnumDef) : List EnumInfo :=
  enums.map fun ed =>
    let variants := enumerateVariants ed.variants
    let maxPayload := variants.foldl (fun (acc : Nat) v =>
      let sz := v.fields.foldl (fun (a : Nat) f => a + tySize f.ty) 0
      if sz > acc then sz else acc
    ) (0 : Nat)
    { name := ed.name, variants, payloadSize := maxPayload, typeParams := ed.typeParams }

def genStructTypes (s : CodegenState) (structs : List StructDef) : CodegenState :=
  structs.foldl (fun s sd =>
    let fieldTypes := ", ".intercalate (sd.fields.map fun f => tyToLLVM s f.ty)
    s.emit ("%struct." ++ sd.name ++ " = type { " ++ fieldTypes ++ " }")
  ) s

def genEnumTypes (s : CodegenState) (enums : List EnumDef) : CodegenState :=
  enums.foldl (fun s ed =>
    let ei := (s.lookupEnum ed.name).get!
    let s := ed.variants.foldl (fun s v =>
      let vi := (ei.variants.find? fun vi => vi.name == v.name).get!
      if vi.fields.isEmpty then
        -- Fieldless variant: emit empty type
        s.emit ("%variant." ++ ed.name ++ "." ++ v.name ++ " = type {}")
      else
        let fieldTypes := ", ".intercalate (vi.fields.map fun fi => fieldTyToLLVM s fi.ty)
        s.emit ("%variant." ++ ed.name ++ "." ++ v.name ++ " = type { " ++ fieldTypes ++ " }")
    ) s
    let payloadBytes := if ei.payloadSize == 0 then 1 else ei.payloadSize
    s.emit ("%enum." ++ ed.name ++ " = type { i32, [" ++ toString payloadBytes ++ " x i8] }")
  ) s

/-- Emit LLVM IR for all built-in standard library functions. -/
def genBuiltinFunctions (s : CodegenState) : CodegenState :=
  -- Built-in string functions
  let s := s.emit "define i64 @string_length(ptr %s) {"
  let s := s.emit "  %len_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %len = load i64, ptr %len_ptr"
  let s := s.emit "  ret i64 %len"
  let s := s.emit "}"
  let s := s.emit ""
  let s := s.emit "define void @drop_string(ptr %s) {"
  let s := s.emit "  %data_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %data = load ptr, ptr %data_ptr"
  let s := s.emit "  call void @free(ptr %data)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  let s := s.emit "define void @print_string(ptr %s) {"
  let s := s.emit "  %data_ptr.ps = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %data.ps = load ptr, ptr %data_ptr.ps"
  let s := s.emit "  %len_ptr.ps = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %len.ps = load i64, ptr %len_ptr.ps"
  let s := s.emit "  %unused = call i64 @write(i32 1, ptr %data.ps, i64 %len.ps)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_concat: takes two Strings by value, returns a new String
  let s := s.emit "define %struct.String @string_concat(ptr %a, ptr %b) {"
  let s := s.emit "  %a_data_ptr = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 0"
  let s := s.emit "  %a_data = load ptr, ptr %a_data_ptr"
  let s := s.emit "  %a_len_ptr = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 1"
  let s := s.emit "  %a_len = load i64, ptr %a_len_ptr"
  let s := s.emit "  %b_data_ptr = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 0"
  let s := s.emit "  %b_data = load ptr, ptr %b_data_ptr"
  let s := s.emit "  %b_len_ptr = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 1"
  let s := s.emit "  %b_len = load i64, ptr %b_len_ptr"
  let s := s.emit "  %total_len = add i64 %a_len, %b_len"
  let s := s.emit "  %buf = call ptr @malloc(i64 %total_len)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %buf, ptr %a_data, i64 %a_len, i1 false)"
  let s := s.emit "  %dst = getelementptr i8, ptr %buf, i64 %a_len"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %b_data, i64 %b_len, i1 false)"
  let s := s.emit "  ; Free the input strings"
  let s := s.emit "  call void @free(ptr %a_data)"
  let s := s.emit "  call void @free(ptr %b_data)"
  let s := s.emit "  %sc_alloca = alloca %struct.String"
  let s := s.emit "  %sc_data_ptr = getelementptr inbounds %struct.String, ptr %sc_alloca, i32 0, i32 0"
  let s := s.emit "  store ptr %buf, ptr %sc_data_ptr"
  let s := s.emit "  %sc_len_ptr = getelementptr inbounds %struct.String, ptr %sc_alloca, i32 0, i32 1"
  let s := s.emit "  store i64 %total_len, ptr %sc_len_ptr"
  let s := s.emit "  %sc_result = load %struct.String, ptr %sc_alloca"
  let s := s.emit "  ret %struct.String %sc_result"
  let s := s.emit "}"
  let s := s.emit ""
  let s := s.emit "@.fmt_int = private constant [5 x i8] c\"%ld\\0A\\00\""
  let s := s.emit "@.fmt_true = private constant [6 x i8] c\"true\\0A\\00\""
  let s := s.emit "@.fmt_false = private constant [7 x i8] c\"false\\0A\\00\""
  let s := s.emit ""
  let s := s.emit "define void @print_int(i64 %x) {"
  let s := s.emit "  %fmt = getelementptr [5 x i8], ptr @.fmt_int, i64 0, i64 0"
  let s := s.emit "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %x)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  let s := s.emit "define void @print_bool(i1 %x) {"
  let s := s.emit "  br i1 %x, label %true_br, label %false_br"
  let s := s.emit "true_br:"
  let s := s.emit "  %fmt_t = getelementptr [6 x i8], ptr @.fmt_true, i64 0, i64 0"
  let s := s.emit "  call i32 (ptr, ...) @printf(ptr %fmt_t)"
  let s := s.emit "  br label %done_br"
  let s := s.emit "false_br:"
  let s := s.emit "  %fmt_f = getelementptr [7 x i8], ptr @.fmt_false, i64 0, i64 0"
  let s := s.emit "  call i32 (ptr, ...) @printf(ptr %fmt_f)"
  let s := s.emit "  br label %done_br"
  let s := s.emit "done_br:"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- read_file / write_file
  let s := s.emit "@.read_mode = private constant [2 x i8] c\"r\\00\""
  let s := s.emit "@.write_mode = private constant [2 x i8] c\"w\\00\""
  let s := s.emit ""
  let s := s.emit "define %struct.String @read_file(ptr %path) {"
  let s := s.emit "  %path_data_ptr = getelementptr inbounds %struct.String, ptr %path, i32 0, i32 0"
  let s := s.emit "  %path_data = load ptr, ptr %path_data_ptr"
  let s := s.emit "  %path_len_ptr = getelementptr inbounds %struct.String, ptr %path, i32 0, i32 1"
  let s := s.emit "  %path_len = load i64, ptr %path_len_ptr"
  let s := s.emit "  %path_buf_sz = add i64 %path_len, 1"
  let s := s.emit "  %path_buf = call ptr @malloc(i64 %path_buf_sz)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %path_buf, ptr %path_data, i64 %path_len, i1 false)"
  let s := s.emit "  %null_pos = getelementptr i8, ptr %path_buf, i64 %path_len"
  let s := s.emit "  store i8 0, ptr %null_pos"
  let s := s.emit "  %mode_r = getelementptr [2 x i8], ptr @.read_mode, i64 0, i64 0"
  let s := s.emit "  %fp = call ptr @fopen(ptr %path_buf, ptr %mode_r)"
  let s := s.emit "  call void @free(ptr %path_buf)"
  let s := s.emit "  %seek1 = call i32 @fseek(ptr %fp, i64 0, i32 2)"
  let s := s.emit "  %size = call i64 @ftell(ptr %fp)"
  let s := s.emit "  %seek2 = call i32 @fseek(ptr %fp, i64 0, i32 0)"
  let s := s.emit "  %buf = call ptr @malloc(i64 %size)"
  let s := s.emit "  %bytes_read = call i64 @fread(ptr %buf, i64 1, i64 %size, ptr %fp)"
  let s := s.emit "  %unused_close = call i32 @fclose(ptr %fp)"
  let s := s.emit "  %str_alloca = alloca %struct.String"
  let s := s.emit "  %str_data_ptr = getelementptr inbounds %struct.String, ptr %str_alloca, i32 0, i32 0"
  let s := s.emit "  store ptr %buf, ptr %str_data_ptr"
  let s := s.emit "  %str_len_ptr = getelementptr inbounds %struct.String, ptr %str_alloca, i32 0, i32 1"
  let s := s.emit "  store i64 %bytes_read, ptr %str_len_ptr"
  let s := s.emit "  %result = load %struct.String, ptr %str_alloca"
  let s := s.emit "  ret %struct.String %result"
  let s := s.emit "}"
  let s := s.emit ""
  let s := s.emit "define i64 @write_file(ptr %path, ptr %data) {"
  let s := s.emit "  %wf_path_data_ptr = getelementptr inbounds %struct.String, ptr %path, i32 0, i32 0"
  let s := s.emit "  %wf_path_data = load ptr, ptr %wf_path_data_ptr"
  let s := s.emit "  %wf_path_len_ptr = getelementptr inbounds %struct.String, ptr %path, i32 0, i32 1"
  let s := s.emit "  %wf_path_len = load i64, ptr %wf_path_len_ptr"
  let s := s.emit "  %wf_buf_sz = add i64 %wf_path_len, 1"
  let s := s.emit "  %wf_buf = call ptr @malloc(i64 %wf_buf_sz)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %wf_buf, ptr %wf_path_data, i64 %wf_path_len, i1 false)"
  let s := s.emit "  %wf_null_pos = getelementptr i8, ptr %wf_buf, i64 %wf_path_len"
  let s := s.emit "  store i8 0, ptr %wf_null_pos"
  let s := s.emit "  %mode_w = getelementptr [2 x i8], ptr @.write_mode, i64 0, i64 0"
  let s := s.emit "  %wf_fp = call ptr @fopen(ptr %wf_buf, ptr %mode_w)"
  let s := s.emit "  call void @free(ptr %wf_buf)"
  let s := s.emit "  %wf_data_ptr = getelementptr inbounds %struct.String, ptr %data, i32 0, i32 0"
  let s := s.emit "  %wf_data_buf = load ptr, ptr %wf_data_ptr"
  let s := s.emit "  %wf_data_len_ptr = getelementptr inbounds %struct.String, ptr %data, i32 0, i32 1"
  let s := s.emit "  %wf_data_len = load i64, ptr %wf_data_len_ptr"
  let s := s.emit "  %wf_written = call i64 @fwrite(ptr %wf_data_buf, i64 1, i64 %wf_data_len, ptr %wf_fp)"
  let s := s.emit "  %wf_unused = call i32 @fclose(ptr %wf_fp)"
  let s := s.emit "  ret i64 %wf_written"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_slice
  let s := s.emit "define %struct.String @string_slice(ptr %s, i64 %start, i64 %end_) {"
  let s := s.emit "  %len_ptr.ss = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %len.ss = load i64, ptr %len_ptr.ss"
  let s := s.emit "  %s_clamped = call i64 @llvm.smax.i64(i64 %start, i64 0)"
  let s := s.emit "  %s_min = call i64 @llvm.smin.i64(i64 %s_clamped, i64 %len.ss)"
  let s := s.emit "  %e_clamped = call i64 @llvm.smax.i64(i64 %end_, i64 0)"
  let s := s.emit "  %e_min = call i64 @llvm.smin.i64(i64 %e_clamped, i64 %len.ss)"
  let s := s.emit "  %e_final = call i64 @llvm.smax.i64(i64 %e_min, i64 %s_min)"
  let s := s.emit "  %slice_len = sub i64 %e_final, %s_min"
  let s := s.emit "  %slice_buf = call ptr @malloc(i64 %slice_len)"
  let s := s.emit "  %data_ptr.ss = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %data.ss = load ptr, ptr %data_ptr.ss"
  let s := s.emit "  %src = getelementptr i8, ptr %data.ss, i64 %s_min"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %slice_buf, ptr %src, i64 %slice_len, i1 false)"
  let s := s.emit "  %res.ss = alloca %struct.String"
  let s := s.emit "  %res_d.ss = getelementptr inbounds %struct.String, ptr %res.ss, i32 0, i32 0"
  let s := s.emit "  store ptr %slice_buf, ptr %res_d.ss"
  let s := s.emit "  %res_l.ss = getelementptr inbounds %struct.String, ptr %res.ss, i32 0, i32 1"
  let s := s.emit "  store i64 %slice_len, ptr %res_l.ss"
  let s := s.emit "  %result.ss = load %struct.String, ptr %res.ss"
  let s := s.emit "  ret %struct.String %result.ss"
  let s := s.emit "}"
  let s := s.emit "declare i64 @llvm.smax.i64(i64, i64)"
  let s := s.emit "declare i64 @llvm.smin.i64(i64, i64)"
  let s := s.emit ""
  -- string_char_at
  let s := s.emit "define i64 @string_char_at(ptr %s, i64 %index) {"
  let s := s.emit "  %len_ptr.sca = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %len.sca = load i64, ptr %len_ptr.sca"
  let s := s.emit "  %neg = icmp slt i64 %index, 0"
  let s := s.emit "  %oob = icmp sge i64 %index, %len.sca"
  let s := s.emit "  %bad = or i1 %neg, %oob"
  let s := s.emit "  br i1 %bad, label %ret_neg, label %ok_idx"
  let s := s.emit "ret_neg:"
  let s := s.emit "  ret i64 -1"
  let s := s.emit "ok_idx:"
  let s := s.emit "  %data_ptr.sca = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %data.sca = load ptr, ptr %data_ptr.sca"
  let s := s.emit "  %char_ptr = getelementptr i8, ptr %data.sca, i64 %index"
  let s := s.emit "  %byte = load i8, ptr %char_ptr"
  let s := s.emit "  %char = zext i8 %byte to i64"
  let s := s.emit "  ret i64 %char"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_contains
  let s := s.emit "define i1 @string_contains(ptr %haystack, ptr %needle) {"
  let s := s.emit "  %h_data_ptr = getelementptr inbounds %struct.String, ptr %haystack, i32 0, i32 0"
  let s := s.emit "  %h_data = load ptr, ptr %h_data_ptr"
  let s := s.emit "  %h_len_ptr = getelementptr inbounds %struct.String, ptr %haystack, i32 0, i32 1"
  let s := s.emit "  %h_len = load i64, ptr %h_len_ptr"
  let s := s.emit "  %n_data_ptr = getelementptr inbounds %struct.String, ptr %needle, i32 0, i32 0"
  let s := s.emit "  %n_data = load ptr, ptr %n_data_ptr"
  let s := s.emit "  %n_len_ptr = getelementptr inbounds %struct.String, ptr %needle, i32 0, i32 1"
  let s := s.emit "  %n_len = load i64, ptr %n_len_ptr"
  let s := s.emit "  %n_empty = icmp eq i64 %n_len, 0"
  let s := s.emit "  br i1 %n_empty, label %found, label %check_len"
  let s := s.emit "check_len:"
  let s := s.emit "  %too_long = icmp ugt i64 %n_len, %h_len"
  let s := s.emit "  br i1 %too_long, label %not_found, label %loop_start"
  let s := s.emit "loop_start:"
  let s := s.emit "  %max_i = sub i64 %h_len, %n_len"
  let s := s.emit "  br label %loop"
  let s := s.emit "loop:"
  let s := s.emit "  %i = phi i64 [0, %loop_start], [%i_next, %loop_cont]"
  let s := s.emit "  %h_ptr = getelementptr i8, ptr %h_data, i64 %i"
  let s := s.emit "  %cmp = call i32 @memcmp(ptr %h_ptr, ptr %n_data, i64 %n_len)"
  let s := s.emit "  %match = icmp eq i32 %cmp, 0"
  let s := s.emit "  br i1 %match, label %found, label %loop_cont"
  let s := s.emit "loop_cont:"
  let s := s.emit "  %i_next = add i64 %i, 1"
  let s := s.emit "  %done = icmp ugt i64 %i_next, %max_i"
  let s := s.emit "  br i1 %done, label %not_found, label %loop"
  let s := s.emit "found:"
  let s := s.emit "  ret i1 true"
  let s := s.emit "not_found:"
  let s := s.emit "  ret i1 false"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_eq
  let s := s.emit "define i1 @string_eq(ptr %a, ptr %b) {"
  let s := s.emit "  %a_len_ptr = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 1"
  let s := s.emit "  %a_len = load i64, ptr %a_len_ptr"
  let s := s.emit "  %b_len_ptr = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 1"
  let s := s.emit "  %b_len = load i64, ptr %b_len_ptr"
  let s := s.emit "  %len_eq = icmp eq i64 %a_len, %b_len"
  let s := s.emit "  br i1 %len_eq, label %cmp_data, label %not_eq"
  let s := s.emit "cmp_data:"
  let s := s.emit "  %zero_len = icmp eq i64 %a_len, 0"
  let s := s.emit "  br i1 %zero_len, label %eq, label %do_cmp"
  let s := s.emit "do_cmp:"
  let s := s.emit "  %a_data_ptr = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 0"
  let s := s.emit "  %a_data = load ptr, ptr %a_data_ptr"
  let s := s.emit "  %b_data_ptr = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 0"
  let s := s.emit "  %b_data = load ptr, ptr %b_data_ptr"
  let s := s.emit "  %cmp_res = call i32 @memcmp(ptr %a_data, ptr %b_data, i64 %a_len)"
  let s := s.emit "  %eq_data = icmp eq i32 %cmp_res, 0"
  let s := s.emit "  br i1 %eq_data, label %eq, label %not_eq"
  let s := s.emit "eq:"
  let s := s.emit "  ret i1 true"
  let s := s.emit "not_eq:"
  let s := s.emit "  ret i1 false"
  let s := s.emit "}"
  let s := s.emit ""
  s

/-- Emit LLVM IR for conversion and I/O builtins. -/
def genConversionBuiltins (s : CodegenState) : CodegenState :=
  -- int_to_string
  let s := s.emit "@.fmt_ld = private constant [4 x i8] c\"%ld\\00\""
  let s := s.emit "define %struct.String @int_to_string(i64 %n) {"
  let s := s.emit "  %buf = call ptr @malloc(i64 32)"
  let s := s.emit "  %fmt_its = getelementptr [4 x i8], ptr @.fmt_ld, i64 0, i64 0"
  let s := s.emit "  %written = call i32 (ptr, i64, ptr, ...) @snprintf(ptr %buf, i64 32, ptr %fmt_its, i64 %n)"
  let s := s.emit "  %wext = sext i32 %written to i64"
  let s := s.emit "  %res.its = alloca %struct.String"
  let s := s.emit "  %res_d.its = getelementptr inbounds %struct.String, ptr %res.its, i32 0, i32 0"
  let s := s.emit "  store ptr %buf, ptr %res_d.its"
  let s := s.emit "  %res_l.its = getelementptr inbounds %struct.String, ptr %res.its, i32 0, i32 1"
  let s := s.emit "  store i64 %wext, ptr %res_l.its"
  let s := s.emit "  %result.its = load %struct.String, ptr %res.its"
  let s := s.emit "  ret %struct.String %result.its"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_to_int — returns Result<Int, Int>
  let s := s.emit "define %enum.Result @string_to_int(ptr %s) {"
  let s := s.emit "  %sti_data_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %sti_data = load ptr, ptr %sti_data_ptr"
  let s := s.emit "  %sti_len_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %sti_len = load i64, ptr %sti_len_ptr"
  let s := s.emit "  %sti_buf_sz = add i64 %sti_len, 1"
  let s := s.emit "  %sti_buf = call ptr @malloc(i64 %sti_buf_sz)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %sti_buf, ptr %sti_data, i64 %sti_len, i1 false)"
  let s := s.emit "  %sti_null = getelementptr i8, ptr %sti_buf, i64 %sti_len"
  let s := s.emit "  store i8 0, ptr %sti_null"
  let s := s.emit "  %endptr_alloca = alloca ptr"
  let s := s.emit "  %sti_val = call i64 @strtol(ptr %sti_buf, ptr %endptr_alloca, i32 10)"
  let s := s.emit "  %endptr = load ptr, ptr %endptr_alloca"
  let s := s.emit "  %end_expected = getelementptr i8, ptr %sti_buf, i64 %sti_len"
  let s := s.emit "  %valid = icmp eq ptr %endptr, %end_expected"
  let s := s.emit "  %empty_input = icmp eq i64 %sti_len, 0"
  let s := s.emit "  %not_empty = xor i1 %empty_input, true"
  let s := s.emit "  %final_ok = and i1 %valid, %not_empty"
  let s := s.emit "  call void @free(ptr %sti_buf)"
  let s := s.emit "  %res.sti = alloca %enum.Result"
  let s := s.emit "  %tag_ptr.sti = getelementptr inbounds %enum.Result, ptr %res.sti, i32 0, i32 0"
  let s := s.emit "  br i1 %final_ok, label %sti_ok, label %sti_err"
  let s := s.emit "sti_ok:"
  let s := s.emit "  store i32 0, ptr %tag_ptr.sti"
  let s := s.emit "  %data_ptr.sti_ok = getelementptr inbounds %enum.Result, ptr %res.sti, i32 0, i32 1"
  let s := s.emit "  store i64 %sti_val, ptr %data_ptr.sti_ok"
  let s := s.emit "  br label %sti_done"
  let s := s.emit "sti_err:"
  let s := s.emit "  store i32 1, ptr %tag_ptr.sti"
  let s := s.emit "  %data_ptr.sti_err = getelementptr inbounds %enum.Result, ptr %res.sti, i32 0, i32 1"
  let s := s.emit "  store i64 1, ptr %data_ptr.sti_err"
  let s := s.emit "  br label %sti_done"
  let s := s.emit "sti_done:"
  let s := s.emit "  %result.sti = load %enum.Result, ptr %res.sti"
  let s := s.emit "  ret %enum.Result %result.sti"
  let s := s.emit "}"
  let s := s.emit ""
  -- bool_to_string
  let s := s.emit "@.str_true = private constant [4 x i8] c\"true\""
  let s := s.emit "@.str_false = private constant [5 x i8] c\"false\""
  let s := s.emit "define %struct.String @bool_to_string(i1 %b) {"
  let s := s.emit "  br i1 %b, label %bts_true, label %bts_false"
  let s := s.emit "bts_true:"
  let s := s.emit "  %tbuf = call ptr @malloc(i64 4)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %tbuf, ptr @.str_true, i64 4, i1 false)"
  let s := s.emit "  %tres = alloca %struct.String"
  let s := s.emit "  %td = getelementptr inbounds %struct.String, ptr %tres, i32 0, i32 0"
  let s := s.emit "  store ptr %tbuf, ptr %td"
  let s := s.emit "  %tl = getelementptr inbounds %struct.String, ptr %tres, i32 0, i32 1"
  let s := s.emit "  store i64 4, ptr %tl"
  let s := s.emit "  %tresult = load %struct.String, ptr %tres"
  let s := s.emit "  ret %struct.String %tresult"
  let s := s.emit "bts_false:"
  let s := s.emit "  %fbuf = call ptr @malloc(i64 5)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %fbuf, ptr @.str_false, i64 5, i1 false)"
  let s := s.emit "  %fres = alloca %struct.String"
  let s := s.emit "  %fd = getelementptr inbounds %struct.String, ptr %fres, i32 0, i32 0"
  let s := s.emit "  store ptr %fbuf, ptr %fd"
  let s := s.emit "  %fl = getelementptr inbounds %struct.String, ptr %fres, i32 0, i32 1"
  let s := s.emit "  store i64 5, ptr %fl"
  let s := s.emit "  %fresult = load %struct.String, ptr %fres"
  let s := s.emit "  ret %struct.String %fresult"
  let s := s.emit "}"
  let s := s.emit ""
  -- float_to_string
  let s := s.emit "@.fmt_f = private constant [3 x i8] c\"%g\\00\""
  let s := s.emit "define %struct.String @float_to_string(double %f) {"
  let s := s.emit "  %fbuf.fts = call ptr @malloc(i64 64)"
  let s := s.emit "  %fmt.fts = getelementptr [3 x i8], ptr @.fmt_f, i64 0, i64 0"
  let s := s.emit "  %written.fts = call i32 (ptr, i64, ptr, ...) @snprintf(ptr %fbuf.fts, i64 64, ptr %fmt.fts, double %f)"
  let s := s.emit "  %wext.fts = sext i32 %written.fts to i64"
  let s := s.emit "  %res.fts = alloca %struct.String"
  let s := s.emit "  %res_d.fts = getelementptr inbounds %struct.String, ptr %res.fts, i32 0, i32 0"
  let s := s.emit "  store ptr %fbuf.fts, ptr %res_d.fts"
  let s := s.emit "  %res_l.fts = getelementptr inbounds %struct.String, ptr %res.fts, i32 0, i32 1"
  let s := s.emit "  store i64 %wext.fts, ptr %res_l.fts"
  let s := s.emit "  %result.fts = load %struct.String, ptr %res.fts"
  let s := s.emit "  ret %struct.String %result.fts"
  let s := s.emit "}"
  let s := s.emit ""
  -- read_line
  let s := s.emit "define %struct.String @read_line() {"
  let s := s.emit "  %rl_buf = call ptr @malloc(i64 128)"
  let s := s.emit "  br label %rl_loop"
  let s := s.emit "rl_loop:"
  let s := s.emit "  %rl_pos = phi i64 [0, %0], [%rl_pos_next, %rl_store]"
  let s := s.emit "  %rl_cur_buf = phi ptr [%rl_buf, %0], [%rl_new_buf, %rl_store]"
  let s := s.emit "  %rl_cur_cap = phi i64 [128, %0], [%rl_new_cap, %rl_store]"
  let s := s.emit "  %rl_one = alloca i8"
  let s := s.emit "  %rl_n = call i64 @read(i32 0, ptr %rl_one, i64 1)"
  let s := s.emit "  %rl_eof = icmp sle i64 %rl_n, 0"
  let s := s.emit "  br i1 %rl_eof, label %rl_done, label %rl_got_char"
  let s := s.emit "rl_got_char:"
  let s := s.emit "  %rl_ch = load i8, ptr %rl_one"
  let s := s.emit "  %rl_is_nl = icmp eq i8 %rl_ch, 10"
  let s := s.emit "  br i1 %rl_is_nl, label %rl_done, label %rl_store"
  let s := s.emit "rl_store:"
  let s := s.emit "  %rl_need_grow = icmp uge i64 %rl_pos, %rl_cur_cap"
  let s := s.emit "  %rl_double_cap = mul i64 %rl_cur_cap, 2"
  let s := s.emit "  %rl_new_cap = select i1 %rl_need_grow, i64 %rl_double_cap, i64 %rl_cur_cap"
  let s := s.emit "  %rl_new_buf = call ptr @realloc(ptr %rl_cur_buf, i64 %rl_new_cap)"
  let s := s.emit "  %rl_dst = getelementptr i8, ptr %rl_new_buf, i64 %rl_pos"
  let s := s.emit "  store i8 %rl_ch, ptr %rl_dst"
  let s := s.emit "  %rl_pos_next = add i64 %rl_pos, 1"
  let s := s.emit "  br label %rl_loop"
  let s := s.emit "rl_done:"
  let s := s.emit "  %rl_final_buf = phi ptr [%rl_cur_buf, %rl_loop], [%rl_cur_buf, %rl_got_char]"
  let s := s.emit "  %rl_final_len = phi i64 [%rl_pos, %rl_loop], [%rl_pos, %rl_got_char]"
  let s := s.emit "  %rl_res = alloca %struct.String"
  let s := s.emit "  %rl_res_d = getelementptr inbounds %struct.String, ptr %rl_res, i32 0, i32 0"
  let s := s.emit "  store ptr %rl_final_buf, ptr %rl_res_d"
  let s := s.emit "  %rl_res_l = getelementptr inbounds %struct.String, ptr %rl_res, i32 0, i32 1"
  let s := s.emit "  store i64 %rl_final_len, ptr %rl_res_l"
  let s := s.emit "  %rl_result = load %struct.String, ptr %rl_res"
  let s := s.emit "  ret %struct.String %rl_result"
  let s := s.emit "}"
  let s := s.emit ""
  -- print_char
  let s := s.emit "define void @print_char(i64 %c) {"
  let s := s.emit "  %c32 = trunc i64 %c to i32"
  let s := s.emit "  %unused.pc = call i32 @putchar(i32 %c32)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- eprint_string
  let s := s.emit "define void @eprint_string(ptr %s) {"
  let s := s.emit "  %ep_data_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %ep_data = load ptr, ptr %ep_data_ptr"
  let s := s.emit "  %ep_len_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %ep_len = load i64, ptr %ep_len_ptr"
  let s := s.emit "  %unused.ep = call i64 @write(i32 2, ptr %ep_data, i64 %ep_len)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- get_env — returns Option<String>
  let s := s.emit "define %enum.Option @get_env(ptr %name) {"
  let s := s.emit "  %ge_data_ptr = getelementptr inbounds %struct.String, ptr %name, i32 0, i32 0"
  let s := s.emit "  %ge_data = load ptr, ptr %ge_data_ptr"
  let s := s.emit "  %ge_len_ptr = getelementptr inbounds %struct.String, ptr %name, i32 0, i32 1"
  let s := s.emit "  %ge_len = load i64, ptr %ge_len_ptr"
  let s := s.emit "  %ge_buf_sz = add i64 %ge_len, 1"
  let s := s.emit "  %ge_buf = call ptr @malloc(i64 %ge_buf_sz)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %ge_buf, ptr %ge_data, i64 %ge_len, i1 false)"
  let s := s.emit "  %ge_null = getelementptr i8, ptr %ge_buf, i64 %ge_len"
  let s := s.emit "  store i8 0, ptr %ge_null"
  let s := s.emit "  %ge_val = call ptr @getenv(ptr %ge_buf)"
  let s := s.emit "  call void @free(ptr %ge_buf)"
  let s := s.emit "  %ge_is_null = icmp eq ptr %ge_val, null"
  let s := s.emit "  %res.ge = alloca %enum.Option"
  let s := s.emit "  %tag_ptr.ge = getelementptr inbounds %enum.Option, ptr %res.ge, i32 0, i32 0"
  let s := s.emit "  br i1 %ge_is_null, label %ge_none, label %ge_some"
  let s := s.emit "ge_some:"
  let s := s.emit "  store i32 0, ptr %tag_ptr.ge"
  let s := s.emit "  %ge_vlen = call i64 @strlen(ptr %ge_val)"
  let s := s.emit "  %ge_vbuf = call ptr @malloc(i64 %ge_vlen)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %ge_vbuf, ptr %ge_val, i64 %ge_vlen, i1 false)"
  let s := s.emit "  %ge_data_area = getelementptr inbounds %enum.Option, ptr %res.ge, i32 0, i32 1"
  let s := s.emit "  store ptr %ge_vbuf, ptr %ge_data_area"
  let s := s.emit "  %ge_len_area = getelementptr i8, ptr %ge_data_area, i64 8"
  let s := s.emit "  store i64 %ge_vlen, ptr %ge_len_area"
  let s := s.emit "  br label %ge_done"
  let s := s.emit "ge_none:"
  let s := s.emit "  store i32 1, ptr %tag_ptr.ge"
  let s := s.emit "  br label %ge_done"
  let s := s.emit "ge_done:"
  let s := s.emit "  %result.ge = load %enum.Option, ptr %res.ge"
  let s := s.emit "  ret %enum.Option %result.ge"
  let s := s.emit "}"
  let s := s.emit ""
  -- exit_process
  let s := s.emit "define void @exit_process(i64 %code) {"
  let s := s.emit "  %code32 = trunc i64 %code to i32"
  let s := s.emit "  call void @exit(i32 %code32)"
  let s := s.emit "  unreachable"
  let s := s.emit "}"
  let s := s.emit ""
  -- string_trim
  let s := s.emit "define %struct.String @string_trim(ptr %s) {"
  let s := s.emit "  %st_data_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 0"
  let s := s.emit "  %st_data = load ptr, ptr %st_data_ptr"
  let s := s.emit "  %st_len_ptr = getelementptr inbounds %struct.String, ptr %s, i32 0, i32 1"
  let s := s.emit "  %st_len = load i64, ptr %st_len_ptr"
  let s := s.emit "  br label %trim_left"
  let s := s.emit "trim_left:"
  let s := s.emit "  %tl_i = phi i64 [0, %0], [%tl_next, %tl_ws]"
  let s := s.emit "  %tl_done = icmp uge i64 %tl_i, %st_len"
  let s := s.emit "  br i1 %tl_done, label %trim_result, label %tl_check"
  let s := s.emit "tl_check:"
  let s := s.emit "  %tl_ptr = getelementptr i8, ptr %st_data, i64 %tl_i"
  let s := s.emit "  %tl_ch = load i8, ptr %tl_ptr"
  let s := s.emit "  %tl_is_sp = icmp eq i8 %tl_ch, 32"
  let s := s.emit "  %tl_is_tab = icmp eq i8 %tl_ch, 9"
  let s := s.emit "  %tl_is_nl = icmp eq i8 %tl_ch, 10"
  let s := s.emit "  %tl_is_cr = icmp eq i8 %tl_ch, 13"
  let s := s.emit "  %tl_w1 = or i1 %tl_is_sp, %tl_is_tab"
  let s := s.emit "  %tl_w2 = or i1 %tl_is_nl, %tl_is_cr"
  let s := s.emit "  %tl_is_ws = or i1 %tl_w1, %tl_w2"
  let s := s.emit "  br i1 %tl_is_ws, label %tl_ws, label %trim_right_init"
  let s := s.emit "tl_ws:"
  let s := s.emit "  %tl_next = add i64 %tl_i, 1"
  let s := s.emit "  br label %trim_left"
  let s := s.emit "trim_right_init:"
  let s := s.emit "  %tr_start = sub i64 %st_len, 1"
  let s := s.emit "  br label %trim_right"
  let s := s.emit "trim_right:"
  let s := s.emit "  %tr_i = phi i64 [%tr_start, %trim_right_init], [%tr_prev, %tr_ws]"
  let s := s.emit "  %tr_done = icmp ult i64 %tr_i, %tl_i"
  let s := s.emit "  br i1 %tr_done, label %trim_result, label %tr_check"
  let s := s.emit "tr_check:"
  let s := s.emit "  %tr_ptr = getelementptr i8, ptr %st_data, i64 %tr_i"
  let s := s.emit "  %tr_ch = load i8, ptr %tr_ptr"
  let s := s.emit "  %tr_is_sp = icmp eq i8 %tr_ch, 32"
  let s := s.emit "  %tr_is_tab = icmp eq i8 %tr_ch, 9"
  let s := s.emit "  %tr_is_nl = icmp eq i8 %tr_ch, 10"
  let s := s.emit "  %tr_is_cr = icmp eq i8 %tr_ch, 13"
  let s := s.emit "  %tr_w1 = or i1 %tr_is_sp, %tr_is_tab"
  let s := s.emit "  %tr_w2 = or i1 %tr_is_nl, %tr_is_cr"
  let s := s.emit "  %tr_is_ws = or i1 %tr_w1, %tr_w2"
  let s := s.emit "  br i1 %tr_is_ws, label %tr_ws, label %trim_result"
  let s := s.emit "tr_ws:"
  let s := s.emit "  %tr_prev = sub i64 %tr_i, 1"
  let s := s.emit "  br label %trim_right"
  let s := s.emit "trim_result:"
  let s := s.emit "  %tr_left = phi i64 [%tl_i, %trim_left], [%tl_i, %trim_right], [%tl_i, %tr_check]"
  let s := s.emit "  %tr_right_raw = phi i64 [0, %trim_left], [%tl_i, %trim_right], [%tr_i, %tr_check]"
  let s := s.emit "  %tr_right = add i64 %tr_right_raw, 1"
  let s := s.emit "  %tr_empty = icmp uge i64 %tr_left, %tr_right"
  let s := s.emit "  br i1 %tr_empty, label %trim_empty, label %trim_copy"
  let s := s.emit "trim_empty:"
  let s := s.emit "  %te_buf = call ptr @malloc(i64 1)"
  let s := s.emit "  %te_res = alloca %struct.String"
  let s := s.emit "  %te_d = getelementptr inbounds %struct.String, ptr %te_res, i32 0, i32 0"
  let s := s.emit "  store ptr %te_buf, ptr %te_d"
  let s := s.emit "  %te_l = getelementptr inbounds %struct.String, ptr %te_res, i32 0, i32 1"
  let s := s.emit "  store i64 0, ptr %te_l"
  let s := s.emit "  %te_result = load %struct.String, ptr %te_res"
  let s := s.emit "  ret %struct.String %te_result"
  let s := s.emit "trim_copy:"
  let s := s.emit "  %tc_len = sub i64 %tr_right, %tr_left"
  let s := s.emit "  %tc_buf = call ptr @malloc(i64 %tc_len)"
  let s := s.emit "  %tc_src = getelementptr i8, ptr %st_data, i64 %tr_left"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %tc_buf, ptr %tc_src, i64 %tc_len, i1 false)"
  let s := s.emit "  %tc_res = alloca %struct.String"
  let s := s.emit "  %tc_d = getelementptr inbounds %struct.String, ptr %tc_res, i32 0, i32 0"
  let s := s.emit "  store ptr %tc_buf, ptr %tc_d"
  let s := s.emit "  %tc_l = getelementptr inbounds %struct.String, ptr %tc_res, i32 0, i32 1"
  let s := s.emit "  store i64 %tc_len, ptr %tc_l"
  let s := s.emit "  %tc_result = load %struct.String, ptr %tc_res"
  let s := s.emit "  ret %struct.String %tc_result"
  let s := s.emit "}"
  let s := s.emit ""
  s

set_option maxRecDepth 8192 in
/-- Emit LLVM IR for HashMap helper functions (Int and String key variants). -/
def genHashMapFunctions (s : CodegenState) : CodegenState :=
  -- Helper: __hashmap_int_new(ptr map_out, i64 ksize, i64 vsize)
  -- Initializes a HashMap struct at map_out with capacity 16
  let s := s.emit "define void @__hashmap_int_new(ptr %mo, i64 %ks, i64 %vs) {"
  let s := s.emit "  %kb = mul i64 16, %ks"
  let s := s.emit "  %kbuf = call ptr @malloc(i64 %kb)"
  let s := s.emit "  %vb = mul i64 16, %vs"
  let s := s.emit "  %vbuf = call ptr @malloc(i64 %vb)"
  let s := s.emit "  %fbuf = call ptr @malloc(i64 16)"
  -- Zero flags
  let s := s.emit "  br label %zl"
  let s := s.emit "zl:"
  let s := s.emit "  %zi = phi i64 [ 0, %0 ], [ %zi1, %zl ]"
  let s := s.emit "  %zp = getelementptr i8, ptr %fbuf, i64 %zi"
  let s := s.emit "  store i8 0, ptr %zp"
  let s := s.emit "  %zi1 = add i64 %zi, 1"
  let s := s.emit "  %zd = icmp uge i64 %zi1, 16"
  let s := s.emit "  br i1 %zd, label %zx, label %zl"
  let s := s.emit "zx:"
  let s := s.emit "  %f0 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 0"
  let s := s.emit "  store ptr %kbuf, ptr %f0"
  let s := s.emit "  %f1 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 1"
  let s := s.emit "  store ptr %vbuf, ptr %f1"
  let s := s.emit "  %f2 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 2"
  let s := s.emit "  store ptr %fbuf, ptr %f2"
  let s := s.emit "  %f3 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 3"
  let s := s.emit "  store i64 0, ptr %f3"
  let s := s.emit "  %f4 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 4"
  let s := s.emit "  store i64 16, ptr %f4"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_str_new: same implementation as int (structure is identical)
  let s := s.emit "define void @__hashmap_str_new(ptr %mo, i64 %ks, i64 %vs) {"
  let s := s.emit "  %kb = mul i64 16, %ks"
  let s := s.emit "  %kbuf = call ptr @malloc(i64 %kb)"
  let s := s.emit "  %vb = mul i64 16, %vs"
  let s := s.emit "  %vbuf = call ptr @malloc(i64 %vb)"
  let s := s.emit "  %fbuf = call ptr @malloc(i64 16)"
  let s := s.emit "  br label %zl"
  let s := s.emit "zl:"
  let s := s.emit "  %zi = phi i64 [ 0, %0 ], [ %zi1, %zl ]"
  let s := s.emit "  %zp = getelementptr i8, ptr %fbuf, i64 %zi"
  let s := s.emit "  store i8 0, ptr %zp"
  let s := s.emit "  %zi1 = add i64 %zi, 1"
  let s := s.emit "  %zd = icmp uge i64 %zi1, 16"
  let s := s.emit "  br i1 %zd, label %zx, label %zl"
  let s := s.emit "zx:"
  let s := s.emit "  %f0 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 0"
  let s := s.emit "  store ptr %kbuf, ptr %f0"
  let s := s.emit "  %f1 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 1"
  let s := s.emit "  store ptr %vbuf, ptr %f1"
  let s := s.emit "  %f2 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 2"
  let s := s.emit "  store ptr %fbuf, ptr %f2"
  let s := s.emit "  %f3 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 3"
  let s := s.emit "  store i64 0, ptr %f3"
  let s := s.emit "  %f4 = getelementptr inbounds %struct.HashMap, ptr %mo, i32 0, i32 4"
  let s := s.emit "  store i64 16, ptr %f4"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- Int hash function: multiplicative hash with xorshift
  let s := s.emit "define i64 @__hash_int(i64 %k) {"
  let s := s.emit "  %m = mul i64 %k, -7046029254386353131"
  let s := s.emit "  %s = lshr i64 %m, 33"
  let s := s.emit "  %h = xor i64 %m, %s"
  let s := s.emit "  ret i64 %h"
  let s := s.emit "}"
  let s := s.emit ""
  -- String hash function: FNV-1a
  let s := s.emit "define i64 @__hash_str(ptr %sp) {"
  let s := s.emit "  %dp = getelementptr inbounds %struct.String, ptr %sp, i32 0, i32 0"
  let s := s.emit "  %d = load ptr, ptr %dp"
  let s := s.emit "  %lp = getelementptr inbounds %struct.String, ptr %sp, i32 0, i32 1"
  let s := s.emit "  %l = load i64, ptr %lp"
  let s := s.emit "  %empty = icmp eq i64 %l, 0"
  let s := s.emit "  br i1 %empty, label %done, label %loop"
  let s := s.emit "loop:"
  let s := s.emit "  %i = phi i64 [ 0, %0 ], [ %i1, %loop ]"
  let s := s.emit "  %h = phi i64 [ -3750763034362895579, %0 ], [ %h3, %loop ]"
  let s := s.emit "  %bp = getelementptr i8, ptr %d, i64 %i"
  let s := s.emit "  %b = load i8, ptr %bp"
  let s := s.emit "  %bx = zext i8 %b to i64"
  let s := s.emit "  %h2 = xor i64 %h, %bx"
  let s := s.emit "  %h3 = mul i64 %h2, 1099511628211"
  let s := s.emit "  %i1 = add i64 %i, 1"
  let s := s.emit "  %c = icmp uge i64 %i1, %l"
  let s := s.emit "  br i1 %c, label %done, label %loop"
  let s := s.emit "done:"
  let s := s.emit "  %r = phi i64 [ -3750763034362895579, %0 ], [ %h3, %loop ]"
  let s := s.emit "  ret i64 %r"
  let s := s.emit "}"
  let s := s.emit ""
  -- Int key equality
  let s := s.emit "define i1 @__keq_int(ptr %a, ptr %b, i64 %ks) {"
  let s := s.emit "  %av = load i64, ptr %a"
  let s := s.emit "  %bv = load i64, ptr %b"
  let s := s.emit "  %eq = icmp eq i64 %av, %bv"
  let s := s.emit "  ret i1 %eq"
  let s := s.emit "}"
  let s := s.emit ""
  -- String key equality (compare length then memcmp)
  let s := s.emit "define i1 @__keq_str(ptr %a, ptr %b, i64 %ks) {"
  let s := s.emit "  %alp = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 1"
  let s := s.emit "  %al = load i64, ptr %alp"
  let s := s.emit "  %blp = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 1"
  let s := s.emit "  %bl = load i64, ptr %blp"
  let s := s.emit "  %le = icmp eq i64 %al, %bl"
  let s := s.emit "  br i1 %le, label %cmp, label %ne"
  let s := s.emit "cmp:"
  let s := s.emit "  %adp = getelementptr inbounds %struct.String, ptr %a, i32 0, i32 0"
  let s := s.emit "  %ad = load ptr, ptr %adp"
  let s := s.emit "  %bdp = getelementptr inbounds %struct.String, ptr %b, i32 0, i32 0"
  let s := s.emit "  %bd = load ptr, ptr %bdp"
  let s := s.emit "  %mc = call i32 @memcmp(ptr %ad, ptr %bd, i64 %al)"
  let s := s.emit "  %eq = icmp eq i32 %mc, 0"
  let s := s.emit "  br label %done"
  let s := s.emit "ne:"
  let s := s.emit "  br label %done"
  let s := s.emit "done:"
  let s := s.emit "  %r = phi i1 [ %eq, %cmp ], [ false, %ne ]"
  let s := s.emit "  ret i1 %r"
  let s := s.emit "}"
  let s := s.emit ""
  -- Generic insert: __hashmap_int_insert(ptr map, ptr key, ptr val, i64 ksize, i64 vsize)
  -- Uses __hash_int for hashing, __keq_int for comparison
  let s := s.emit "define void @__hashmap_int_insert(ptr %m, ptr %key, ptr %val, i64 %ks, i64 %vs) {"
  let s := s.emit "  %lenp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 3"
  let s := s.emit "  %len = load i64, ptr %lenp"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  -- Check load factor: len*4 > cap*3
  let s := s.emit "  %l4 = mul i64 %len, 4"
  let s := s.emit "  %c3 = mul i64 %cap, 3"
  let s := s.emit "  %ng = icmp ugt i64 %l4, %c3"
  let s := s.emit "  br i1 %ng, label %grow, label %ins"
  let s := s.emit "grow:"
  let s := s.emit "  %nc = mul i64 %cap, 2"
  let s := s.emit "  %nkb = mul i64 %nc, %ks"
  let s := s.emit "  %nkbuf = call ptr @malloc(i64 %nkb)"
  let s := s.emit "  %nvb = mul i64 %nc, %vs"
  let s := s.emit "  %nvbuf = call ptr @malloc(i64 %nvb)"
  let s := s.emit "  %nfbuf = call ptr @malloc(i64 %nc)"
  -- Zero new flags
  let s := s.emit "  br label %gz"
  let s := s.emit "gz:"
  let s := s.emit "  %gi = phi i64 [ 0, %grow ], [ %gi1, %gz ]"
  let s := s.emit "  %gp = getelementptr i8, ptr %nfbuf, i64 %gi"
  let s := s.emit "  store i8 0, ptr %gp"
  let s := s.emit "  %gi1 = add i64 %gi, 1"
  let s := s.emit "  %gd = icmp uge i64 %gi1, %nc"
  let s := s.emit "  br i1 %gd, label %rehash, label %gz"
  -- Rehash old entries into new buffers
  let s := s.emit "rehash:"
  let s := s.emit "  %okp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %okb = load ptr, ptr %okp"
  let s := s.emit "  %ovp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %ovb = load ptr, ptr %ovp"
  let s := s.emit "  %ofp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %ofb = load ptr, ptr %ofp"
  let s := s.emit "  %nm = sub i64 %nc, 1"
  let s := s.emit "  br label %rl"
  let s := s.emit "rl:"
  let s := s.emit "  %ri = phi i64 [ 0, %rehash ], [ %ri1, %rnext ]"
  let s := s.emit "  %rfp = getelementptr i8, ptr %ofb, i64 %ri"
  let s := s.emit "  %rf = load i8, ptr %rfp"
  let s := s.emit "  %rocc = icmp eq i8 %rf, 1"
  let s := s.emit "  br i1 %rocc, label %rins, label %rnext"
  let s := s.emit "rins:"
  let s := s.emit "  %rko = mul i64 %ri, %ks"
  let s := s.emit "  %rkp = getelementptr i8, ptr %okb, i64 %rko"
  let s := s.emit "  %rkv = load i64, ptr %rkp"
  let s := s.emit "  %rh = call i64 @__hash_int(i64 %rkv)"
  let s := s.emit "  %rs = and i64 %rh, %nm"
  let s := s.emit "  br label %rpl"
  let s := s.emit "rpl:"
  let s := s.emit "  %rj = phi i64 [ %rs, %rins ], [ %rj1w, %rpl ]"
  let s := s.emit "  %rpfp = getelementptr i8, ptr %nfbuf, i64 %rj"
  let s := s.emit "  %rpf = load i8, ptr %rpfp"
  let s := s.emit "  %rpe = icmp eq i8 %rpf, 0"
  let s := s.emit "  %rj1 = add i64 %rj, 1"
  let s := s.emit "  %rj1w = and i64 %rj1, %nm"
  let s := s.emit "  br i1 %rpe, label %rstore, label %rpl"
  let s := s.emit "rstore:"
  let s := s.emit "  %nko = mul i64 %rj, %ks"
  let s := s.emit "  %nkp = getelementptr i8, ptr %nkbuf, i64 %nko"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %nkp, ptr %rkp, i64 %ks, i1 false)"
  let s := s.emit "  %rvo = mul i64 %ri, %vs"
  let s := s.emit "  %rvp = getelementptr i8, ptr %ovb, i64 %rvo"
  let s := s.emit "  %nvo = mul i64 %rj, %vs"
  let s := s.emit "  %nvp = getelementptr i8, ptr %nvbuf, i64 %nvo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %nvp, ptr %rvp, i64 %vs, i1 false)"
  let s := s.emit "  store i8 1, ptr %rpfp"
  let s := s.emit "  br label %rnext"
  let s := s.emit "rnext:"
  let s := s.emit "  %ri1 = add i64 %ri, 1"
  let s := s.emit "  %rd = icmp uge i64 %ri1, %cap"
  let s := s.emit "  br i1 %rd, label %rdone, label %rl"
  let s := s.emit "rdone:"
  let s := s.emit "  call void @free(ptr %okb)"
  let s := s.emit "  call void @free(ptr %ovb)"
  let s := s.emit "  call void @free(ptr %ofb)"
  let s := s.emit "  store ptr %nkbuf, ptr %okp"
  let s := s.emit "  store ptr %nvbuf, ptr %ovp"
  let s := s.emit "  store ptr %nfbuf, ptr %ofp"
  let s := s.emit "  store i64 %nc, ptr %capp"
  let s := s.emit "  br label %ins"
  -- Insert the actual key/value
  let s := s.emit "ins:"
  let s := s.emit "  %ic = load i64, ptr %capp"
  let s := s.emit "  %im = sub i64 %ic, 1"
  let s := s.emit "  %ikp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %ikb = load ptr, ptr %ikp2"
  let s := s.emit "  %ivp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %ivb = load ptr, ptr %ivp2"
  let s := s.emit "  %ifp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %ifb = load ptr, ptr %ifp2"
  let s := s.emit "  %ikv = load i64, ptr %key"
  let s := s.emit "  %ih = call i64 @__hash_int(i64 %ikv)"
  let s := s.emit "  %is = and i64 %ih, %im"
  let s := s.emit "  br label %ipl"
  let s := s.emit "ipl:"
  let s := s.emit "  %ij = phi i64 [ %is, %ins ], [ %ij1w, %ipc ]"
  let s := s.emit "  %ipfp = getelementptr i8, ptr %ifb, i64 %ij"
  let s := s.emit "  %ipf = load i8, ptr %ipfp"
  let s := s.emit "  %ipe = icmp ne i8 %ipf, 1"
  let s := s.emit "  br i1 %ipe, label %istore, label %imatch"
  let s := s.emit "imatch:"
  let s := s.emit "  %iko = mul i64 %ij, %ks"
  let s := s.emit "  %ikpp = getelementptr i8, ptr %ikb, i64 %iko"
  let s := s.emit "  %ieq = call i1 @__keq_int(ptr %ikpp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %ieq, label %istore, label %ipc"
  let s := s.emit "ipc:"
  let s := s.emit "  %ij1 = add i64 %ij, 1"
  let s := s.emit "  %ij1w = and i64 %ij1, %im"
  let s := s.emit "  br label %ipl"
  let s := s.emit "istore:"
  let s := s.emit "  %wo = icmp eq i8 %ipf, 1"
  let s := s.emit "  %sko = mul i64 %ij, %ks"
  let s := s.emit "  %skp = getelementptr i8, ptr %ikb, i64 %sko"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %skp, ptr %key, i64 %ks, i1 false)"
  let s := s.emit "  %svo = mul i64 %ij, %vs"
  let s := s.emit "  %svp = getelementptr i8, ptr %ivb, i64 %svo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %svp, ptr %val, i64 %vs, i1 false)"
  let s := s.emit "  store i8 1, ptr %ipfp"
  let s := s.emit "  %cl = load i64, ptr %lenp"
  let s := s.emit "  %nl = add i64 %cl, 1"
  let s := s.emit "  %sl = select i1 %wo, i64 %cl, i64 %nl"
  let s := s.emit "  store i64 %sl, ptr %lenp"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_str_insert: same structure but uses __hash_str and __keq_str
  let s := s.emit "define void @__hashmap_str_insert(ptr %m, ptr %key, ptr %val, i64 %ks, i64 %vs) {"
  let s := s.emit "  %lenp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 3"
  let s := s.emit "  %len = load i64, ptr %lenp"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %l4 = mul i64 %len, 4"
  let s := s.emit "  %c3 = mul i64 %cap, 3"
  let s := s.emit "  %ng = icmp ugt i64 %l4, %c3"
  let s := s.emit "  br i1 %ng, label %grow, label %ins"
  let s := s.emit "grow:"
  let s := s.emit "  %nc = mul i64 %cap, 2"
  let s := s.emit "  %nkb = mul i64 %nc, %ks"
  let s := s.emit "  %nkbuf = call ptr @malloc(i64 %nkb)"
  let s := s.emit "  %nvb = mul i64 %nc, %vs"
  let s := s.emit "  %nvbuf = call ptr @malloc(i64 %nvb)"
  let s := s.emit "  %nfbuf = call ptr @malloc(i64 %nc)"
  let s := s.emit "  br label %gz"
  let s := s.emit "gz:"
  let s := s.emit "  %gi = phi i64 [ 0, %grow ], [ %gi1, %gz ]"
  let s := s.emit "  %gp = getelementptr i8, ptr %nfbuf, i64 %gi"
  let s := s.emit "  store i8 0, ptr %gp"
  let s := s.emit "  %gi1 = add i64 %gi, 1"
  let s := s.emit "  %gd = icmp uge i64 %gi1, %nc"
  let s := s.emit "  br i1 %gd, label %rehash, label %gz"
  let s := s.emit "rehash:"
  let s := s.emit "  %okp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %okb = load ptr, ptr %okp"
  let s := s.emit "  %ovp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %ovb = load ptr, ptr %ovp"
  let s := s.emit "  %ofp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %ofb = load ptr, ptr %ofp"
  let s := s.emit "  %nm = sub i64 %nc, 1"
  let s := s.emit "  br label %rl"
  let s := s.emit "rl:"
  let s := s.emit "  %ri = phi i64 [ 0, %rehash ], [ %ri1, %rnext ]"
  let s := s.emit "  %rfp = getelementptr i8, ptr %ofb, i64 %ri"
  let s := s.emit "  %rf = load i8, ptr %rfp"
  let s := s.emit "  %rocc = icmp eq i8 %rf, 1"
  let s := s.emit "  br i1 %rocc, label %rins, label %rnext"
  let s := s.emit "rins:"
  let s := s.emit "  %rko = mul i64 %ri, %ks"
  let s := s.emit "  %rkp = getelementptr i8, ptr %okb, i64 %rko"
  let s := s.emit "  %rh = call i64 @__hash_str(ptr %rkp)"
  let s := s.emit "  %rs = and i64 %rh, %nm"
  let s := s.emit "  br label %rpl"
  let s := s.emit "rpl:"
  let s := s.emit "  %rj = phi i64 [ %rs, %rins ], [ %rj1w, %rpl ]"
  let s := s.emit "  %rpfp = getelementptr i8, ptr %nfbuf, i64 %rj"
  let s := s.emit "  %rpf = load i8, ptr %rpfp"
  let s := s.emit "  %rpe = icmp eq i8 %rpf, 0"
  let s := s.emit "  %rj1 = add i64 %rj, 1"
  let s := s.emit "  %rj1w = and i64 %rj1, %nm"
  let s := s.emit "  br i1 %rpe, label %rstore, label %rpl"
  let s := s.emit "rstore:"
  let s := s.emit "  %nko = mul i64 %rj, %ks"
  let s := s.emit "  %nkp = getelementptr i8, ptr %nkbuf, i64 %nko"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %nkp, ptr %rkp, i64 %ks, i1 false)"
  let s := s.emit "  %rvo = mul i64 %ri, %vs"
  let s := s.emit "  %rvp = getelementptr i8, ptr %ovb, i64 %rvo"
  let s := s.emit "  %nvo = mul i64 %rj, %vs"
  let s := s.emit "  %nvp = getelementptr i8, ptr %nvbuf, i64 %nvo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %nvp, ptr %rvp, i64 %vs, i1 false)"
  let s := s.emit "  store i8 1, ptr %rpfp"
  let s := s.emit "  br label %rnext"
  let s := s.emit "rnext:"
  let s := s.emit "  %ri1 = add i64 %ri, 1"
  let s := s.emit "  %rd = icmp uge i64 %ri1, %cap"
  let s := s.emit "  br i1 %rd, label %rdone, label %rl"
  let s := s.emit "rdone:"
  let s := s.emit "  call void @free(ptr %okb)"
  let s := s.emit "  call void @free(ptr %ovb)"
  let s := s.emit "  call void @free(ptr %ofb)"
  let s := s.emit "  store ptr %nkbuf, ptr %okp"
  let s := s.emit "  store ptr %nvbuf, ptr %ovp"
  let s := s.emit "  store ptr %nfbuf, ptr %ofp"
  let s := s.emit "  store i64 %nc, ptr %capp"
  let s := s.emit "  br label %ins"
  let s := s.emit "ins:"
  let s := s.emit "  %ic = load i64, ptr %capp"
  let s := s.emit "  %im = sub i64 %ic, 1"
  let s := s.emit "  %ikp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %ikb = load ptr, ptr %ikp2"
  let s := s.emit "  %ivp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %ivb = load ptr, ptr %ivp2"
  let s := s.emit "  %ifp2 = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %ifb = load ptr, ptr %ifp2"
  let s := s.emit "  %ih = call i64 @__hash_str(ptr %key)"
  let s := s.emit "  %is = and i64 %ih, %im"
  let s := s.emit "  br label %ipl"
  let s := s.emit "ipl:"
  let s := s.emit "  %ij = phi i64 [ %is, %ins ], [ %ij1w, %ipc ]"
  let s := s.emit "  %ipfp = getelementptr i8, ptr %ifb, i64 %ij"
  let s := s.emit "  %ipf = load i8, ptr %ipfp"
  let s := s.emit "  %ipe = icmp ne i8 %ipf, 1"
  let s := s.emit "  br i1 %ipe, label %istore, label %imatch"
  let s := s.emit "imatch:"
  let s := s.emit "  %iko = mul i64 %ij, %ks"
  let s := s.emit "  %ikpp = getelementptr i8, ptr %ikb, i64 %iko"
  let s := s.emit "  %ieq = call i1 @__keq_str(ptr %ikpp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %ieq, label %istore, label %ipc"
  let s := s.emit "ipc:"
  let s := s.emit "  %ij1 = add i64 %ij, 1"
  let s := s.emit "  %ij1w = and i64 %ij1, %im"
  let s := s.emit "  br label %ipl"
  let s := s.emit "istore:"
  let s := s.emit "  %wo = icmp eq i8 %ipf, 1"
  let s := s.emit "  %sko = mul i64 %ij, %ks"
  let s := s.emit "  %skp = getelementptr i8, ptr %ikb, i64 %sko"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %skp, ptr %key, i64 %ks, i1 false)"
  let s := s.emit "  %svo = mul i64 %ij, %vs"
  let s := s.emit "  %svp = getelementptr i8, ptr %ivb, i64 %svo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %svp, ptr %val, i64 %vs, i1 false)"
  let s := s.emit "  store i8 1, ptr %ipfp"
  let s := s.emit "  %cl = load i64, ptr %lenp"
  let s := s.emit "  %nl = add i64 %cl, 1"
  let s := s.emit "  %sl = select i1 %wo, i64 %cl, i64 %nl"
  let s := s.emit "  store i64 %sl, ptr %lenp"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_int_get(ptr map, ptr key, ptr result_opt, i64 ks, i64 vs)
  -- Writes Option to result_opt: tag=0 (Some) + payload, or tag=1 (None)
  let s := s.emit "define void @__hashmap_int_get(ptr %m, ptr %key, ptr %opt, i64 %ks, i64 %vs) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %vbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %vb = load ptr, ptr %vbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %kv = load i64, ptr %key"
  let s := s.emit "  %h = call i64 @__hash_int(i64 %kv)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_int(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  store i32 1, ptr %opt"
  let s := s.emit "  ret void"
  let s := s.emit "found:"
  let s := s.emit "  store i32 0, ptr %opt"
  let s := s.emit "  %pp = getelementptr i8, ptr %opt, i64 4"
  let s := s.emit "  %vo = mul i64 %j, %vs"
  let s := s.emit "  %vp = getelementptr i8, ptr %vb, i64 %vo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %pp, ptr %vp, i64 %vs, i1 false)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_str_get: same but with __hash_str / __keq_str
  let s := s.emit "define void @__hashmap_str_get(ptr %m, ptr %key, ptr %opt, i64 %ks, i64 %vs) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %vbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %vb = load ptr, ptr %vbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %h = call i64 @__hash_str(ptr %key)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_str(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  store i32 1, ptr %opt"
  let s := s.emit "  ret void"
  let s := s.emit "found:"
  let s := s.emit "  store i32 0, ptr %opt"
  let s := s.emit "  %pp = getelementptr i8, ptr %opt, i64 4"
  let s := s.emit "  %vo = mul i64 %j, %vs"
  let s := s.emit "  %vp = getelementptr i8, ptr %vb, i64 %vo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %pp, ptr %vp, i64 %vs, i1 false)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_int_contains(ptr map, ptr key, i64 ks) -> i1
  let s := s.emit "define i1 @__hashmap_int_contains(ptr %m, ptr %key, i64 %ks) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %kv = load i64, ptr %key"
  let s := s.emit "  %h = call i64 @__hash_int(i64 %kv)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_int(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  ret i1 false"
  let s := s.emit "found:"
  let s := s.emit "  ret i1 true"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_str_contains
  let s := s.emit "define i1 @__hashmap_str_contains(ptr %m, ptr %key, i64 %ks) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %h = call i64 @__hash_str(ptr %key)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_str(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  ret i1 false"
  let s := s.emit "found:"
  let s := s.emit "  ret i1 true"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_int_remove: like get but sets flag to tombstone and decrements len
  let s := s.emit "define void @__hashmap_int_remove(ptr %m, ptr %key, ptr %opt, i64 %ks, i64 %vs) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %vbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %vb = load ptr, ptr %vbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %kv = load i64, ptr %key"
  let s := s.emit "  %h = call i64 @__hash_int(i64 %kv)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_int(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  store i32 1, ptr %opt"
  let s := s.emit "  ret void"
  let s := s.emit "found:"
  let s := s.emit "  store i32 0, ptr %opt"
  let s := s.emit "  %pp = getelementptr i8, ptr %opt, i64 4"
  let s := s.emit "  %vo = mul i64 %j, %vs"
  let s := s.emit "  %vp = getelementptr i8, ptr %vb, i64 %vo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %pp, ptr %vp, i64 %vs, i1 false)"
  let s := s.emit "  store i8 2, ptr %fp"
  let s := s.emit "  %lp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 3"
  let s := s.emit "  %l = load i64, ptr %lp"
  let s := s.emit "  %l1 = sub i64 %l, 1"
  let s := s.emit "  store i64 %l1, ptr %lp"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  -- __hashmap_str_remove
  let s := s.emit "define void @__hashmap_str_remove(ptr %m, ptr %key, ptr %opt, i64 %ks, i64 %vs) {"
  let s := s.emit "  %capp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 4"
  let s := s.emit "  %cap = load i64, ptr %capp"
  let s := s.emit "  %mask = sub i64 %cap, 1"
  let s := s.emit "  %kbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0"
  let s := s.emit "  %kb = load ptr, ptr %kbp"
  let s := s.emit "  %vbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1"
  let s := s.emit "  %vb = load ptr, ptr %vbp"
  let s := s.emit "  %fbp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2"
  let s := s.emit "  %fb = load ptr, ptr %fbp"
  let s := s.emit "  %h = call i64 @__hash_str(ptr %key)"
  let s := s.emit "  %s = and i64 %h, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "pl:"
  let s := s.emit "  %j = phi i64 [ %s, %0 ], [ %j1w, %pc ]"
  let s := s.emit "  %fp = getelementptr i8, ptr %fb, i64 %j"
  let s := s.emit "  %f = load i8, ptr %fp"
  let s := s.emit "  %empty = icmp eq i8 %f, 0"
  let s := s.emit "  br i1 %empty, label %nf, label %occ"
  let s := s.emit "occ:"
  let s := s.emit "  %isocc = icmp eq i8 %f, 1"
  let s := s.emit "  br i1 %isocc, label %ck, label %pc"
  let s := s.emit "ck:"
  let s := s.emit "  %ko = mul i64 %j, %ks"
  let s := s.emit "  %kp = getelementptr i8, ptr %kb, i64 %ko"
  let s := s.emit "  %eq = call i1 @__keq_str(ptr %kp, ptr %key, i64 %ks)"
  let s := s.emit "  br i1 %eq, label %found, label %pc"
  let s := s.emit "pc:"
  let s := s.emit "  %j1 = add i64 %j, 1"
  let s := s.emit "  %j1w = and i64 %j1, %mask"
  let s := s.emit "  br label %pl"
  let s := s.emit "nf:"
  let s := s.emit "  store i32 1, ptr %opt"
  let s := s.emit "  ret void"
  let s := s.emit "found:"
  let s := s.emit "  store i32 0, ptr %opt"
  let s := s.emit "  %pp = getelementptr i8, ptr %opt, i64 4"
  let s := s.emit "  %vo = mul i64 %j, %vs"
  let s := s.emit "  %vp = getelementptr i8, ptr %vb, i64 %vo"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %pp, ptr %vp, i64 %vs, i1 false)"
  let s := s.emit "  store i8 2, ptr %fp"
  let s := s.emit "  %lp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 3"
  let s := s.emit "  %l = load i64, ptr %lp"
  let s := s.emit "  %l1 = sub i64 %l, 1"
  let s := s.emit "  store i64 %l1, ptr %lp"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  s

/-- Emit LLVM IR for networking builtin functions. -/
def genNetworkBuiltins (s : CodegenState) : CodegenState :=
  -- tcp_connect(host: &String, port: Int) -> Int
  -- Uses getaddrinfo for DNS resolution, then connects
  let s := s.emit "@.port_fmt = private constant [5 x i8] c\"%lld\\00\""
  let s := s.emit "define i64 @tcp_connect(ptr %host, i64 %port) {"
  -- Extract C-string from host String
  let s := s.emit "  %h_data_ptr = getelementptr inbounds %struct.String, ptr %host, i32 0, i32 0"
  let s := s.emit "  %h_data = load ptr, ptr %h_data_ptr"
  let s := s.emit "  %h_len_ptr = getelementptr inbounds %struct.String, ptr %host, i32 0, i32 1"
  let s := s.emit "  %h_len = load i64, ptr %h_len_ptr"
  let s := s.emit "  %h_clen = add i64 %h_len, 1"
  let s := s.emit "  %h_cstr = call ptr @malloc(i64 %h_clen)"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %h_cstr, ptr %h_data, i64 %h_len, i1 false)"
  let s := s.emit "  %h_null = getelementptr i8, ptr %h_cstr, i64 %h_len"
  let s := s.emit "  store i8 0, ptr %h_null"
  -- Convert port to C-string
  let s := s.emit "  %port_buf = alloca [16 x i8]"
  let s := s.emit "  %port_fmt = getelementptr [5 x i8], ptr @.port_fmt, i64 0, i64 0"
  let s := s.emit "  %port_written = call i32 (ptr, i64, ptr, ...) @snprintf(ptr %port_buf, i64 16, ptr %port_fmt, i64 %port)"
  -- Setup hints for getaddrinfo: AF_INET=2, SOCK_STREAM=1
  let s := s.emit "  %hints = alloca [48 x i8]"
  let s := s.emit "  call void @llvm.memcpy.p0.p0.i64(ptr %hints, ptr %hints, i64 0, i1 false)"
  -- zero out hints
  let s := s.emit "  %h_i0 = getelementptr i8, ptr %hints, i64 0"
  let s := s.emit "  store i64 0, ptr %h_i0"
  let s := s.emit "  %h_i8 = getelementptr i8, ptr %hints, i64 8"
  let s := s.emit "  store i64 0, ptr %h_i8"
  let s := s.emit "  %h_i16 = getelementptr i8, ptr %hints, i64 16"
  let s := s.emit "  store i64 0, ptr %h_i16"
  let s := s.emit "  %h_i24 = getelementptr i8, ptr %hints, i64 24"
  let s := s.emit "  store i64 0, ptr %h_i24"
  let s := s.emit "  %h_i32 = getelementptr i8, ptr %hints, i64 32"
  let s := s.emit "  store i64 0, ptr %h_i32"
  let s := s.emit "  %h_i40 = getelementptr i8, ptr %hints, i64 40"
  let s := s.emit "  store i64 0, ptr %h_i40"
  -- ai_family = AF_INET (2) at offset 4, ai_socktype = SOCK_STREAM (1) at offset 8
  let s := s.emit "  %hint_family = getelementptr i8, ptr %hints, i64 4"
  let s := s.emit "  store i32 2, ptr %hint_family"
  let s := s.emit "  %hint_socktype = getelementptr i8, ptr %hints, i64 8"
  let s := s.emit "  store i32 1, ptr %hint_socktype"
  -- Call getaddrinfo
  let s := s.emit "  %res_ptr = alloca ptr"
  let s := s.emit "  %gai_ret = call i32 @getaddrinfo(ptr %h_cstr, ptr %port_buf, ptr %hints, ptr %res_ptr)"
  let s := s.emit "  call void @free(ptr %h_cstr)"
  let s := s.emit "  %gai_fail = icmp ne i32 %gai_ret, 0"
  let s := s.emit "  br i1 %gai_fail, label %tc_err, label %tc_ok"
  let s := s.emit "tc_err:"
  let s := s.emit "  ret i64 -1"
  let s := s.emit "tc_ok:"
  let s := s.emit "  %res = load ptr, ptr %res_ptr"
  -- res->ai_family at offset 4 (i32), res->ai_socktype at offset 8 (i32), res->ai_protocol at offset 12 (i32)
  -- res->ai_addrlen at offset 16 (i32), res->ai_addr at offset 32 (ptr on macOS 64-bit)
  let s := s.emit "  %ai_family = getelementptr i8, ptr %res, i64 4"
  let s := s.emit "  %fam = load i32, ptr %ai_family"
  let s := s.emit "  %ai_socktype = getelementptr i8, ptr %res, i64 8"
  let s := s.emit "  %styp = load i32, ptr %ai_socktype"
  let s := s.emit "  %ai_protocol = getelementptr i8, ptr %res, i64 12"
  let s := s.emit "  %proto = load i32, ptr %ai_protocol"
  let s := s.emit "  %sockfd = call i32 @socket(i32 %fam, i32 %styp, i32 %proto)"
  let s := s.emit "  %ai_addrlen = getelementptr i8, ptr %res, i64 16"
  let s := s.emit "  %addrlen = load i32, ptr %ai_addrlen"
  let s := s.emit "  %ai_addr = getelementptr i8, ptr %res, i64 32"
  let s := s.emit "  %addr = load ptr, ptr %ai_addr"
  let s := s.emit "  %conn_ret = call i32 @connect(i32 %sockfd, ptr %addr, i32 %addrlen)"
  let s := s.emit "  call void @freeaddrinfo(ptr %res)"
  let s := s.emit "  %conn_fail = icmp slt i32 %conn_ret, 0"
  let s := s.emit "  br i1 %conn_fail, label %tc_conn_err, label %tc_conn_ok"
  let s := s.emit "tc_conn_err:"
  let s := s.emit "  %sockfd_close = call i32 @close(i32 %sockfd)"
  let s := s.emit "  ret i64 -1"
  let s := s.emit "tc_conn_ok:"
  let s := s.emit "  %sockfd64 = sext i32 %sockfd to i64"
  let s := s.emit "  ret i64 %sockfd64"
  let s := s.emit "}"
  let s := s.emit ""
  -- tcp_listen(port: Int, backlog: Int) -> Int
  let s := s.emit "define i64 @tcp_listen(i64 %port, i64 %backlog) {"
  -- socket(AF_INET=2, SOCK_STREAM=1, 0)
  let s := s.emit "  %lsock = call i32 @socket(i32 2, i32 1, i32 0)"
  -- setsockopt SO_REUSEADDR: SOL_SOCKET=0xFFFF, SO_REUSEADDR=4 on macOS
  let s := s.emit "  %reuse = alloca i32"
  let s := s.emit "  store i32 1, ptr %reuse"
  let s := s.emit "  %sso_ret = call i32 @setsockopt(i32 %lsock, i32 65535, i32 4, ptr %reuse, i32 4)"
  -- Build sockaddr_in on stack (macOS: 16 bytes)
  -- { u8 sin_len=16, u8 sin_family=2, u16 sin_port, u32 sin_addr=0, u8[8] zero }
  let s := s.emit "  %saddr = alloca [16 x i8]"
  -- Zero it out
  let s := s.emit "  %sa0 = getelementptr i8, ptr %saddr, i64 0"
  let s := s.emit "  store i64 0, ptr %sa0"
  let s := s.emit "  %sa8 = getelementptr i8, ptr %saddr, i64 8"
  let s := s.emit "  store i64 0, ptr %sa8"
  -- sin_len = 16
  let s := s.emit "  store i8 16, ptr %saddr"
  -- sin_family = AF_INET (2)
  let s := s.emit "  %sf = getelementptr i8, ptr %saddr, i64 1"
  let s := s.emit "  store i8 2, ptr %sf"
  -- sin_port = htons(port)
  let s := s.emit "  %port16 = trunc i64 %port to i16"
  let s := s.emit "  %port_n = call i16 @htons(i16 %port16)"
  let s := s.emit "  %sp = getelementptr i8, ptr %saddr, i64 2"
  let s := s.emit "  store i16 %port_n, ptr %sp"
  -- sin_addr = INADDR_ANY (0) — already zeroed
  -- bind
  let s := s.emit "  %bind_ret = call i32 @bind(i32 %lsock, ptr %saddr, i32 16)"
  let s := s.emit "  %bind_fail = icmp slt i32 %bind_ret, 0"
  let s := s.emit "  br i1 %bind_fail, label %tl_err, label %tl_listen"
  let s := s.emit "tl_err:"
  let s := s.emit "  %cl_ret = call i32 @close(i32 %lsock)"
  let s := s.emit "  ret i64 -1"
  let s := s.emit "tl_listen:"
  let s := s.emit "  %backlog32 = trunc i64 %backlog to i32"
  let s := s.emit "  %listen_ret = call i32 @listen(i32 %lsock, i32 %backlog32)"
  let s := s.emit "  %listen_fail = icmp slt i32 %listen_ret, 0"
  let s := s.emit "  br i1 %listen_fail, label %tl_err2, label %tl_ok"
  let s := s.emit "tl_err2:"
  let s := s.emit "  %cl2 = call i32 @close(i32 %lsock)"
  let s := s.emit "  ret i64 -1"
  let s := s.emit "tl_ok:"
  let s := s.emit "  %lsock64 = sext i32 %lsock to i64"
  let s := s.emit "  ret i64 %lsock64"
  let s := s.emit "}"
  let s := s.emit ""
  -- tcp_accept(sockfd: Int) -> Int
  let s := s.emit "define i64 @tcp_accept(i64 %sockfd) {"
  let s := s.emit "  %fd32 = trunc i64 %sockfd to i32"
  let s := s.emit "  %newfd = call i32 @accept(i32 %fd32, ptr null, ptr null)"
  let s := s.emit "  %newfd64 = sext i32 %newfd to i64"
  let s := s.emit "  ret i64 %newfd64"
  let s := s.emit "}"
  let s := s.emit ""
  -- socket_send(sockfd: Int, data: &String) -> Int
  let s := s.emit "define i64 @socket_send(i64 %sockfd, ptr %data) {"
  let s := s.emit "  %fd32s = trunc i64 %sockfd to i32"
  let s := s.emit "  %sd_ptr = getelementptr inbounds %struct.String, ptr %data, i32 0, i32 0"
  let s := s.emit "  %sd_data = load ptr, ptr %sd_ptr"
  let s := s.emit "  %sl_ptr = getelementptr inbounds %struct.String, ptr %data, i32 0, i32 1"
  let s := s.emit "  %sd_len = load i64, ptr %sl_ptr"
  let s := s.emit "  %sent = call i64 @send(i32 %fd32s, ptr %sd_data, i64 %sd_len, i32 0)"
  let s := s.emit "  ret i64 %sent"
  let s := s.emit "}"
  let s := s.emit ""
  -- socket_recv(sockfd: Int, bufsize: Int) -> String
  let s := s.emit "define %struct.String @socket_recv(i64 %sockfd, i64 %bufsize) {"
  let s := s.emit "  %fd32r = trunc i64 %sockfd to i32"
  let s := s.emit "  %rbuf = call ptr @malloc(i64 %bufsize)"
  let s := s.emit "  %recvd = call i64 @recv(i32 %fd32r, ptr %rbuf, i64 %bufsize, i32 0)"
  let s := s.emit "  %recv_fail = icmp sle i64 %recvd, 0"
  let s := s.emit "  br i1 %recv_fail, label %sr_empty, label %sr_ok"
  let s := s.emit "sr_empty:"
  let s := s.emit "  call void @free(ptr %rbuf)"
  let s := s.emit "  %empty_buf = call ptr @malloc(i64 1)"
  let s := s.emit "  %sr_e = alloca %struct.String"
  let s := s.emit "  %sr_ed = getelementptr inbounds %struct.String, ptr %sr_e, i32 0, i32 0"
  let s := s.emit "  store ptr %empty_buf, ptr %sr_ed"
  let s := s.emit "  %sr_el = getelementptr inbounds %struct.String, ptr %sr_e, i32 0, i32 1"
  let s := s.emit "  store i64 0, ptr %sr_el"
  let s := s.emit "  %sr_er = load %struct.String, ptr %sr_e"
  let s := s.emit "  ret %struct.String %sr_er"
  let s := s.emit "sr_ok:"
  let s := s.emit "  %sr_a = alloca %struct.String"
  let s := s.emit "  %sr_ad = getelementptr inbounds %struct.String, ptr %sr_a, i32 0, i32 0"
  let s := s.emit "  store ptr %rbuf, ptr %sr_ad"
  let s := s.emit "  %sr_al = getelementptr inbounds %struct.String, ptr %sr_a, i32 0, i32 1"
  let s := s.emit "  store i64 %recvd, ptr %sr_al"
  let s := s.emit "  %sr_ar = load %struct.String, ptr %sr_a"
  let s := s.emit "  ret %struct.String %sr_ar"
  let s := s.emit "}"
  let s := s.emit ""
  -- socket_close(sockfd: Int) -> ()
  let s := s.emit "define void @socket_close(i64 %sockfd) {"
  let s := s.emit "  %fd32c = trunc i64 %sockfd to i32"
  let s := s.emit "  %cl_ret2 = call i32 @close(i32 %fd32c)"
  let s := s.emit "  ret void"
  let s := s.emit "}"
  let s := s.emit ""
  s

def genModule (m : Module) : String :=
  -- Add built-in Option<T> enum if not user-defined
  let builtinOptionEnum : EnumDef := {
    name := "Option"
    typeParams := ["T"]
    variants := [
      { name := "Some", fields := [{ name := "value", ty := .typeVar "T" }] },
      { name := "None", fields := [] }
    ]
  }
  let builtinResultEnum : EnumDef := {
    name := "Result"
    typeParams := ["T", "E"]
    variants := [
      { name := "Ok", fields := [{ name := "value", ty := .typeVar "T" }] },
      { name := "Err", fields := [{ name := "value", ty := .typeVar "E" }] }
    ]
  }
  let hasUserOption := m.enums.any fun ed => ed.name == "Option"
  let hasUserResult := m.enums.any fun ed => ed.name == "Result"
  let builtinEnums := (if hasUserOption then [] else [builtinOptionEnum]) ++
                      (if hasUserResult then [] else [builtinResultEnum])
  let allEnums := builtinEnums ++ m.enums
  let structInfos := buildStructDefs m.structs
  let enumInfos := buildEnumDefs allEnums
  let builtinRetTypes := [
    ("string_length", Ty.int),
    ("drop_string", Ty.unit),
    ("print_string", Ty.unit),
    ("string_concat", Ty.string),
    ("print_int", Ty.unit),
    ("print_bool", Ty.unit),
    ("read_file", Ty.string),
    ("write_file", Ty.int),
    ("string_slice", Ty.string),
    ("string_char_at", Ty.int),
    ("string_contains", Ty.bool),
    ("string_eq", Ty.bool),
    ("int_to_string", Ty.string),
    ("string_to_int", Ty.generic "Result" [.int, .int]),
    ("bool_to_string", Ty.string),
    ("float_to_string", Ty.string),
    ("read_line", Ty.string),
    ("print_char", Ty.unit),
    ("eprint_string", Ty.unit),
    ("get_env", Ty.generic "Option" [.string]),
    ("get_args", Ty.heapArray .string),
    ("exit_process", Ty.unit),
    ("string_trim", Ty.string),
    ("tcp_connect", Ty.int),
    ("tcp_listen", Ty.int),
    ("tcp_accept", Ty.int),
    ("socket_send", Ty.int),
    ("socket_recv", Ty.string),
    ("socket_close", Ty.unit)
  ]
  let implRetTypes := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let traitImplRetTypes := m.traitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let externRetTypes := m.externFns.map fun ef => (ef.name, ef.retTy)
  let fnRetTypes := ((m.functions.map fun f => (f.name, normalizeFieldTy f.retTy)) ++ builtinRetTypes ++ implRetTypes ++ traitImplRetTypes ++ externRetTypes).map fun (n, t) => (n, normalizeFieldTy t)
  let fnParamTypes : List (String × List Ty) := (m.functions.map fun f =>
    (f.name, f.params.map fun p => normalizeFieldTy p.ty)) ++
    (m.implBlocks.foldl (fun acc ib =>
      acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, f.params.map fun p => normalizeFieldTy p.ty)
    ) []) ++
    (m.traitImpls.foldl (fun acc tb =>
      acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, f.params.map fun p => normalizeFieldTy p.ty)
    ) []) ++
    (m.externFns.map fun ef => (ef.name, ef.params.map fun p => normalizeFieldTy p.ty))
  let constList := m.constants.map fun c => (c.name, (c.ty, c.value))
  -- Build type param and type bound maps for monomorphization
  let fnTypeParams : List (String × List String) := m.functions.map fun f => (f.name, f.typeParams)
  let fnTypeBounds : List (String × List (String × List String)) := m.functions.filter (fun f => !f.typeBounds.isEmpty) |>.map fun f => (f.name, f.typeBounds)
  let s0 := { CodegenState.init with
    structDefs := structInfos, enumDefs := enumInfos,
    fnRetTypes := fnRetTypes, fnParamTypes := fnParamTypes,
    constants := constList }
  let s := { s0 with
    fnTypeParams := fnTypeParams,
    fnTypeBounds := fnTypeBounds,
    allFnDefs := m.functions }
  let s := s.emit "; Generated by Concrete compiler"
  let s := s.emit ("; Module: " ++ m.name)
  let s := s.emit ""
  -- Only emit built-in String type if user hasn't defined one
  let hasUserString := m.structs.any fun sd => sd.name == "String"
  let s := if !hasUserString then
    let s := s.emit "%struct.String = type { ptr, i64 }"
    s.emit ""
  else s
  let s := s.emit "%struct.Vec = type { ptr, i64, i64 }"
  let s := s.emit "%struct.HashMap = type { ptr, ptr, ptr, i64, i64 }"
  let s := s.emit ""
  let s := genStructTypes s m.structs
  let s := if m.structs.isEmpty then s else s.emit ""
  let s := genEnumTypes s allEnums
  let s := if allEnums.isEmpty then s else s.emit ""
  -- External declarations
  let s := s.emit "declare ptr @malloc(i64)"
  let s := s.emit "declare void @free(ptr)"
  let s := s.emit "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)"
  let s := s.emit "declare i64 @write(i32, ptr, i64)"
  let s := s.emit "declare void @abort()"
  let s := s.emit "declare i32 @printf(ptr, ...)"
  -- C file I/O declarations
  let s := s.emit "declare ptr @fopen(ptr, ptr)"
  let s := s.emit "declare i64 @fread(ptr, i64, i64, ptr)"
  let s := s.emit "declare i64 @fwrite(ptr, i64, i64, ptr)"
  let s := s.emit "declare i32 @fclose(ptr)"
  let s := s.emit "declare i32 @fseek(ptr, i64, i32)"
  let s := s.emit "declare i64 @ftell(ptr)"
  -- C stdlib declarations for new builtins
  let s := s.emit "declare i32 @snprintf(ptr, i64, ptr, ...)"
  let s := s.emit "declare i64 @strtol(ptr, ptr, i32)"
  let s := s.emit "declare i32 @memcmp(ptr, ptr, i64)"
  let s := s.emit "declare ptr @getenv(ptr)"
  let s := s.emit "declare i64 @strlen(ptr)"
  let s := s.emit "declare ptr @realloc(ptr, i64)"
  let s := s.emit "declare i64 @read(i32, ptr, i64)"
  let s := s.emit "declare i32 @putchar(i32)"
  let s := s.emit "declare void @exit(i32)"
  -- POSIX socket declarations
  let s := s.emit "declare i32 @socket(i32, i32, i32)"
  let s := s.emit "declare i32 @connect(i32, ptr, i32)"
  let s := s.emit "declare i32 @bind(i32, ptr, i32)"
  let s := s.emit "declare i32 @listen(i32, i32)"
  let s := s.emit "declare i32 @accept(i32, ptr, ptr)"
  let s := s.emit "declare i64 @send(i32, ptr, i64, i32)"
  let s := s.emit "declare i64 @recv(i32, ptr, i64, i32)"
  let s := s.emit "declare i32 @close(i32)"
  let s := s.emit "declare i32 @getaddrinfo(ptr, ptr, ptr, ptr)"
  let s := s.emit "declare void @freeaddrinfo(ptr)"
  let s := s.emit "declare i16 @htons(i16)"
  let s := s.emit "declare i32 @setsockopt(i32, i32, i32, ptr, i32)"
  -- Extern function declarations from the source
  let s := m.externFns.foldl (fun s ef =>
    let retLLTy := tyToLLVM s ef.retTy
    let paramStr := ", ".intercalate (ef.params.map fun p => paramTyToLLVM s p.ty)
    -- Skip if already declared (malloc, free, etc.)
    if ef.name == "malloc" || ef.name == "free" then s
    else s.emit ("declare " ++ retLLTy ++ " @" ++ ef.name ++ "(" ++ paramStr ++ ")")
  ) s
  let s := s.emit ""
  -- Emit all builtin function implementations
  let s := genBuiltinFunctions s
  let s := genConversionBuiltins s
  let s := genNetworkBuiltins s
  let s := genHashMapFunctions s
  -- Impl block methods
  let s := m.implBlocks.foldl (fun s ib =>
    ib.methods.foldl (fun s f =>
      let mangledF : FnDef := { f with name := ib.typeName ++ "_" ++ f.name }
      genFn s mangledF
    ) s
  ) s
  -- Trait impl methods
  let s := m.traitImpls.foldl (fun s tb =>
    tb.methods.foldl (fun s f =>
      let mangledF : FnDef := { f with name := tb.typeName ++ "_" ++ f.name }
      genFn s mangledF
    ) s
  ) s
  -- User functions (skip generic functions with trait bounds — they get monomorphized)
  let hasMain := m.functions.any (fun f => f.name == "main")
  let s := m.functions.foldl (fun s f =>
    if !f.typeBounds.isEmpty then s  -- skip: will be monomorphized at call sites
    else genFn s f hasMain
  ) s
  -- Process monomorphization queue: generate specialized copies of generic functions
  let s := Id.run do
    let mut s := s
    let mut processed : Nat := 0
    -- Iterate until queue is exhausted (mono fns may enqueue more)
    while processed < s.monoQueue.length do
      match s.monoQueue.drop processed with
      | (_, monoFn) :: _ =>
        s := genFn s monoFn
        processed := processed + 1
      | [] => break
    return s
  -- String literal globals
  let s := if s.stringGlobals.isEmpty then s
    else { s with output := s.output ++ s.stringGlobals ++ "\n" }
  if hasMain then
    -- Find main function signature
    let mainFn := m.functions.find? fun f => f.name == "main"
    let mainRetTy := match mainFn with
      | some f => f.retTy
      | none => .int
    let mainRetLLTy := tyToLLVM s mainRetTy
    let mainHasParams := match mainFn with
      | some f => !f.params.isEmpty
      | none => false
    let s := s.emit "@.fmt = private constant [5 x i8] c\"%ld\\0A\\00\""
    let s := s.emit ""
    if mainHasParams then
      -- Main with argc: fn main(argc: i64)
      let s := s.emit "define i32 @main(i32 %argc, ptr %argv) {"
      let s := s.emit "  %argc64 = sext i32 %argc to i64"
      let s := s.emit ("  %result = call " ++ mainRetLLTy ++ " @concrete_main(i64 %argc64)")
      -- Widen result to i64 for printf if needed
      let (s, resultI64) := if mainRetLLTy != "i64" then
        let line := "  %result64 = sext " ++ mainRetLLTy ++ " %result to i64"
        (s.emit line, "%result64")
      else
        (s, "%result")
      let s := s.emit "  %fmt = getelementptr [5 x i8], ptr @.fmt, i64 0, i64 0"
      let s := s.emit ("  call i32 (ptr, ...) @printf(ptr %fmt, i64 " ++ resultI64 ++ ")")
      -- Return exit code (truncated to i32)
      let (s, retVal) := if mainRetLLTy == "i32" then
        (s, "%result")
      else if mainRetLLTy == "i64" then
        (s.emit "  %exitcode = trunc i64 %result to i32", "%exitcode")
      else
        (s.emit ("  %exitcode = trunc i64 " ++ resultI64 ++ " to i32"), "%exitcode")
      let s := s.emit ("  ret i32 " ++ retVal)
      let s := s.emit "}"
      s.output
    else
      let s := s.emit "define i32 @main() {"
      let s := s.emit ("  %result = call " ++ mainRetLLTy ++ " @concrete_main()")
      -- Widen result to i64 for printf if needed
      let (s, resultI64) := if mainRetLLTy != "i64" then
        if mainRetLLTy == "i32" then
          (s.emit "  %result64 = sext i32 %result to i64", "%result64")
        else if mainRetLLTy == "i1" then
          (s.emit "  %result64 = zext i1 %result to i64", "%result64")
        else if mainRetLLTy == "i8" then
          (s.emit "  %result64 = zext i8 %result to i64", "%result64")
        else if mainRetLLTy == "i16" then
          (s.emit "  %result64 = sext i16 %result to i64", "%result64")
        else
          (s, "%result")
      else
        (s, "%result")
      let s := s.emit "  %fmt = getelementptr [5 x i8], ptr @.fmt, i64 0, i64 0"
      let s := s.emit ("  call i32 (ptr, ...) @printf(ptr %fmt, i64 " ++ resultI64 ++ ")")
      -- Return exit code
      let (s, retVal) := if mainRetLLTy == "i32" then
        (s, "%result")
      else if mainRetLLTy == "i64" then
        (s.emit "  %exitcode = trunc i64 %result to i32", "%exitcode")
      else
        (s.emit ("  %exitcode.tmp = zext " ++ mainRetLLTy ++ " %result to i32"), "%exitcode.tmp")
      let s := s.emit ("  ret i32 " ++ retVal)
      let s := s.emit "}"
      s.output
  else
    s.output

private def flattenModule (m : Module) : Module :=
  let subStructs := m.submodules.foldl (fun acc sub => acc ++ sub.structs) ([] : List StructDef)
  let subEnums := m.submodules.foldl (fun acc sub => acc ++ sub.enums) ([] : List EnumDef)
  let subFunctions := m.submodules.foldl (fun acc sub => acc ++ sub.functions) ([] : List FnDef)
  let subExternFns := m.submodules.foldl (fun acc sub => acc ++ sub.externFns) ([] : List ExternFnDecl)
  let subImpls := m.submodules.foldl (fun acc sub => acc ++ sub.implBlocks) ([] : List ImplBlock)
  let subTraitImpls := m.submodules.foldl (fun acc sub => acc ++ sub.traitImpls) ([] : List ImplTraitBlock)
  let subConstants := m.submodules.foldl (fun acc sub => acc ++ sub.constants) ([] : List ConstDef)
  let subTypeAliases := m.submodules.foldl (fun acc sub => acc ++ sub.typeAliases) ([] : List TypeAlias)
  { m with
    structs := m.structs ++ subStructs,
    enums := m.enums ++ subEnums,
    functions := m.functions ++ subFunctions,
    externFns := m.externFns ++ subExternFns,
    implBlocks := m.implBlocks ++ subImpls,
    traitImpls := m.traitImpls ++ subTraitImpls,
    constants := m.constants ++ subConstants,
    typeAliases := m.typeAliases ++ subTypeAliases,
    submodules := [] }

/-- Resolve Self to the concrete impl type in a Ty. -/
private def resolveSelfTy (ty : Ty) (implTy : Ty) : Ty :=
  match ty with
  | .named "Self" => implTy
  | .ref inner => .ref (resolveSelfTy inner implTy)
  | .refMut inner => .refMut (resolveSelfTy inner implTy)
  | .generic name args => .generic name (args.map fun a => resolveSelfTy a implTy)
  | .array elem n => .array (resolveSelfTy elem implTy) n
  | .heap inner => .heap (resolveSelfTy inner implTy)
  | .heapArray inner => .heapArray (resolveSelfTy inner implTy)
  | .ptrMut inner => .ptrMut (resolveSelfTy inner implTy)
  | .ptrConst inner => .ptrConst (resolveSelfTy inner implTy)
  | .fn_ params capSet retTy => .fn_ (params.map fun p => resolveSelfTy p implTy) capSet (resolveSelfTy retTy implTy)
  | other => other

mutual
private partial def resolveSelfExpr (e : Expr) (implTy : Ty) : Expr :=
  match e with
  | .structLit name targs fields =>
    .structLit name (targs.map fun t => resolveSelfTy t implTy)
      (fields.map fun (n, v) => (n, resolveSelfExpr v implTy))
  | .enumLit ename vname targs fields =>
    .enumLit ename vname (targs.map fun t => resolveSelfTy t implTy)
      (fields.map fun (n, v) => (n, resolveSelfExpr v implTy))
  | .cast inner targetTy => .cast (resolveSelfExpr inner implTy) (resolveSelfTy targetTy implTy)
  | .call fn targs args =>
    .call fn (targs.map fun t => resolveSelfTy t implTy)
      (args.map fun a => resolveSelfExpr a implTy)
  | .methodCall obj m targs args =>
    .methodCall (resolveSelfExpr obj implTy) m (targs.map fun t => resolveSelfTy t implTy)
      (args.map fun a => resolveSelfExpr a implTy)
  | .staticMethodCall tn m targs args =>
    .staticMethodCall tn m (targs.map fun t => resolveSelfTy t implTy)
      (args.map fun a => resolveSelfExpr a implTy)
  | .binOp op l r => .binOp op (resolveSelfExpr l implTy) (resolveSelfExpr r implTy)
  | .unaryOp op e => .unaryOp op (resolveSelfExpr e implTy)
  | .paren inner => .paren (resolveSelfExpr inner implTy)
  | .borrow inner => .borrow (resolveSelfExpr inner implTy)
  | .borrowMut inner => .borrowMut (resolveSelfExpr inner implTy)
  | .deref inner => .deref (resolveSelfExpr inner implTy)
  | .try_ inner => .try_ (resolveSelfExpr inner implTy)
  | .fieldAccess obj f => .fieldAccess (resolveSelfExpr obj implTy) f
  | .arrowAccess obj f => .arrowAccess (resolveSelfExpr obj implTy) f
  | .arrayLit elems => .arrayLit (elems.map fun e => resolveSelfExpr e implTy)
  | .arrayIndex arr idx => .arrayIndex (resolveSelfExpr arr implTy) (resolveSelfExpr idx implTy)
  | .allocCall inner alloc => .allocCall (resolveSelfExpr inner implTy) (resolveSelfExpr alloc implTy)
  | .match_ scrut arms => .match_ (resolveSelfExpr scrut implTy) (arms.map fun arm =>
      match arm with
      | .mk en vn bs body => .mk en vn bs (resolveSelfStmts body implTy)
      | .litArm v body => .litArm (resolveSelfExpr v implTy) (resolveSelfStmts body implTy)
      | .varArm b body => .varArm b (resolveSelfStmts body implTy))
  | .fnRef name => .fnRef name
  | .whileExpr cond body elseBody =>
    .whileExpr (resolveSelfExpr cond implTy) (resolveSelfStmts body implTy)
      (resolveSelfStmts elseBody implTy)
  | other => other

private partial def resolveSelfStmts (stmts : List Stmt) (implTy : Ty) : List Stmt :=
  stmts.map fun s => resolveSelfStmt s implTy

private partial def resolveSelfStmt (s : Stmt) (implTy : Ty) : Stmt :=
  match s with
  | .letDecl name isMut ty val =>
    .letDecl name isMut (ty.map fun t => resolveSelfTy t implTy) (resolveSelfExpr val implTy)
  | .assign name val => .assign name (resolveSelfExpr val implTy)
  | .return_ (some val) => .return_ (some (resolveSelfExpr val implTy))
  | .return_ none => .return_ none
  | .expr e => .expr (resolveSelfExpr e implTy)
  | .ifElse cond th el =>
    .ifElse (resolveSelfExpr cond implTy) (resolveSelfStmts th implTy)
      (el.map fun b => resolveSelfStmts b implTy)
  | .while_ cond body lbl => .while_ (resolveSelfExpr cond implTy) (resolveSelfStmts body implTy) lbl
  | .forLoop init cond step body lbl =>
    .forLoop (init.map fun s => resolveSelfStmt s implTy)
      (resolveSelfExpr cond implTy)
      (step.map fun s => resolveSelfStmt s implTy)
      (resolveSelfStmts body implTy) lbl
  | .fieldAssign obj f val =>
    .fieldAssign (resolveSelfExpr obj implTy) f (resolveSelfExpr val implTy)
  | .derefAssign target val =>
    .derefAssign (resolveSelfExpr target implTy) (resolveSelfExpr val implTy)
  | .arrayIndexAssign arr idx val =>
    .arrayIndexAssign (resolveSelfExpr arr implTy) (resolveSelfExpr idx implTy)
      (resolveSelfExpr val implTy)
  | .break_ (some e) lbl => .break_ (some (resolveSelfExpr e implTy)) lbl
  | .break_ none lbl => .break_ none lbl
  | .continue_ lbl => .continue_ lbl
  | .defer body => .defer (resolveSelfExpr body implTy)
  | .borrowIn v r reg isMut body =>
    .borrowIn v r reg isMut (resolveSelfStmts body implTy)
  | .arrowAssign obj f val =>
    .arrowAssign (resolveSelfExpr obj implTy) f (resolveSelfExpr val implTy)
end

/-- Resolve Self in a FnDef given the impl's type. -/
private def resolveSelfInFnDef (f : FnDef) (implTy : Ty) : FnDef :=
  { f with
    retTy := resolveSelfTy f.retTy implTy,
    params := f.params.map fun p => { p with ty := resolveSelfTy p.ty implTy },
    body := resolveSelfStmts f.body implTy }

/-- Resolve Self in all impl blocks and trait impls of a module. -/
private def resolveSelfInModule (m : Module) : Module :=
  { m with
    implBlocks := m.implBlocks.map fun ib =>
      let implTy := if ib.typeParams.isEmpty then Ty.named ib.typeName
                    else Ty.generic ib.typeName (ib.typeParams.map Ty.typeVar)
      { ib with methods := ib.methods.map fun f => resolveSelfInFnDef f implTy },
    traitImpls := m.traitImpls.map fun tb =>
      let implTy := if tb.typeParams.isEmpty then Ty.named tb.typeName
                    else Ty.generic tb.typeName (tb.typeParams.map Ty.typeVar)
      { tb with methods := tb.methods.map fun f => resolveSelfInFnDef f implTy } }

def genProgram (modules : List Module) : String :=
  -- Build qualified name → original name aliases from submodules
  let aliases : List (String × String) := modules.foldl (fun acc m =>
    acc ++ m.submodules.foldl (fun acc2 (sub : Module) =>
      acc2 ++ (sub.functions.map fun f => (sub.name ++ "_" ++ f.name, f.name))
      ++ (sub.externFns.map fun ef => (sub.name ++ "_" ++ ef.name, ef.name))
    ) ([] : List (String × String))
  ) []
  let flatModules := modules.map (resolveSelfInModule ∘ flattenModule)
  let combined : Module := {
    name := "combined",
    structs := flatModules.foldl (fun acc m => acc ++ m.structs) [],
    enums := flatModules.foldl (fun acc m => acc ++ m.enums) [],
    functions := flatModules.foldl (fun acc m => acc ++ m.functions) [],
    imports := [],
    implBlocks := flatModules.foldl (fun acc m => acc ++ m.implBlocks) [],
    traits := flatModules.foldl (fun acc m => acc ++ m.traits) [],
    traitImpls := flatModules.foldl (fun acc m => acc ++ m.traitImpls) [],
    constants := flatModules.foldl (fun acc m => acc ++ m.constants) [],
    typeAliases := flatModules.foldl (fun acc m => acc ++ m.typeAliases) [],
    externFns := flatModules.foldl (fun acc m => acc ++ m.externFns) [],
    submodules := []
  }
  -- Replace qualified call names with original function names
  let result := genModule combined
  aliases.foldl (fun (s : String) (qual, orig) =>
    s.replace ("@" ++ qual ++ "(") ("@" ++ orig ++ "(")
  ) result

end Concrete
