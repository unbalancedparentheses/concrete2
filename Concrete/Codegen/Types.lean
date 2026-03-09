import Concrete.Codegen.Helpers

namespace Concrete

def escapeCharForLLVM (c : Char) : String :=
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

def escapeStringForLLVM (s : String) : String :=
  s.foldl (fun acc c => acc ++ escapeCharForLLVM c) ""

/-- Normalize Ty.generic "Heap"/"HeapArray" to Ty.heap/Ty.heapArray. -/
def normalizeTy : Ty → Ty
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

partial def stmtListHasReturn (stmts : List Stmt) : Bool :=
  stmts.any fun s => match s with
    | .return_ _ _ => true
    | .ifElse _ _ thenBody (some elseBody) =>
      stmtListHasReturn thenBody && stmtListHasReturn elseBody
    | .expr _ (.match_ _ _ arms) =>
      arms.all fun arm => match arm with
        | .mk _ _ _ _ body | .litArm _ _ body | .varArm _ _ body => stmtListHasReturn body
    | _ => false

/-- Get the LLVM integer type name for the given Concrete type (for arithmetic). -/
def intTyToLLVM : Ty → String
  | .int | .uint => "i64"
  | .i8 | .u8 => "i8"
  | .i16 | .u16 => "i16"
  | .i32 | .u32 => "i32"
  | .char => "i8"
  | .bool => "i1"
  | _ => "i64"

/-- Get the LLVM float type name. -/
def floatTyToLLVM : Ty → String
  | .float32 => "float"
  | .float64 => "double"
  | _ => "double"

/-- Is this a signed integer type? -/
private def isSignedInt : Ty → Bool
  | .int | .i8 | .i16 | .i32 => true
  | _ => false

/-- Get bit width of a type. -/
def tyBitWidth : Ty → Nat
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
def inferExprTy (s : CodegenState) (e : Expr) (hint : Option Ty := none) : Ty :=
  match e with
  | .intLit _ _ => match hint with
    | some t => if isIntegerType t || t == .char then t else .int
    | none => .int
  | .floatLit _ _ => match hint with
    | some t => if isFloatType t then t else .float64
    | none => .float64
  | .boolLit _ _ => .bool
  | .strLit _ _ => .string
  | .charLit _ _ => .char
  | .ident _ name =>
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
  | .fieldAccess _ obj field =>
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
  | .structLit _ name _ _ => .named name
  | .enumLit _ name _ typeArgs _ =>
    if typeArgs.isEmpty then .named name else .generic name typeArgs
  | .match_ _ _ _ => .int
  | .call _ fnName _typeArgs args =>
    if fnName == "sizeof" then match hint with
      | some t => t
      | none => .uint
    else if fnName == "alloc" then
      -- Infer arg type without recursion to avoid termination issues
      match args.head? with
      | some (Expr.structLit _ name _ _) => Ty.heap (Ty.named name)
      | some (Expr.enumLit _ name _ _ _) => Ty.heap (Ty.named name)
      | some (Expr.ident _ name) => Ty.heap ((s.lookupVarType name).getD Ty.int)
      | some (Expr.intLit _ _) => Ty.heap Ty.int
      | _ => match hint with
        | some t => t
        | none => Ty.heap Ty.int
    else if fnName == "free" then
      match args.head? with
      | some (Expr.ident _ name) =>
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
      | some (Expr.ident _ name) =>
        match s.lookupVarType name with
        | some (.refMut (.generic "Vec" [et])) => et
        | some (.ref (.generic "Vec" [et])) => et
        | some (.generic "Vec" [et]) => et
        | _ => match hint with | some t => t | none => .int
      | _ => match hint with | some t => t | none => .int
    else if fnName == "vec_len" then .int
    else if fnName == "vec_pop" then
      match args.head? with
      | some (Expr.ident _ name) =>
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
      | some (Expr.ident _ name) =>
        match s.lookupVarType name with
        | some (.ref (.generic "HashMap" [_, vt])) => .generic "Option" [vt]
        | some (.refMut (.generic "HashMap" [_, vt])) => .generic "Option" [vt]
        | some (.generic "HashMap" [_, vt]) => .generic "Option" [vt]
        | _ => match hint with | some t => t | none => .int
      | _ => match hint with | some t => t | none => .int
    else if fnName == "map_contains" then .bool
    else if fnName == "map_len" then .int
    else normalizeTy ((s.fnRetTypes.lookup fnName).getD .int)
  | .binOp _ op lhs _ =>
    match op with
    | .eq | .neq | .lt | .gt | .leq | .geq | .and_ | .or_ => .bool
    | _ => inferExprTy s lhs
  | .unaryOp _ .not_ _ => .bool
  | .unaryOp _ .neg operand => inferExprTy s operand
  | .unaryOp _ .bitnot operand => inferExprTy s operand
  | .paren _ inner => inferExprTy s inner
  | .borrow _ inner => .ref (inferExprTy s inner)
  | .borrowMut _ inner => .refMut (inferExprTy s inner)
  | .deref _ inner =>
    match inferExprTy s inner with
    | .ref t => t
    | .refMut t => t
    | .ptrMut t => t
    | .ptrConst t => t
    | .heap t => t
    | _ => .int
  | .try_ _ inner =>
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
  | .arrayLit _ elems =>
    match elems with
    | first :: _ => .array (inferExprTy s first) elems.length
    | [] => .array .int 0
  | .arrayIndex _ arr _ =>
    match inferExprTy s arr with
    | .array elemTy _ => elemTy
    | _ => .int
  | .cast _ _ targetTy => targetTy
  | .methodCall _ obj methodName _ _ =>
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
  | .staticMethodCall _ typeName methodName _ _ =>
    let mangledName := typeName ++ "_" ++ methodName
    normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
  | .fnRef _ fnName =>
    -- Look up the function's type to build the fn pointer type
    (s.fnRetTypes.lookup fnName).map (fun retTy =>
      let paramTys := (s.fnParamTypes.lookup fnName).getD []
      .fn_ paramTys .empty retTy) |>.getD .int
  | .arrowAccess _ obj field =>
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
  | .allocCall _ inner _ => inferExprTy s inner hint
  | .whileExpr _ _cond _body _elseBody =>
    -- Result type comes from hint (set by checker) or defaults to Int
    match hint with
    | some t => t
    | none => .int

/-- Convert a float to LLVM literal format. -/
def floatToLLVM (f : Float) : String :=
  let s := toString f
  if s.any (· == '.') || s.any (· == 'e') || s.any (· == 'E') || s.any (· == 'i') || s.any (· == 'n') then
    s
  else
    s ++ ".0"

/-- Get byte size of a type. -/
def tySize : Ty → Nat
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
partial def tySizeOf (s : CodegenState) : Ty → Nat
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
def substTyCodegen (mapping : List (String × Ty)) : Ty → Ty
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
def normalizeFieldTy : Ty → Ty
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
def substTyMono (typeParams : List String) (mapping : List (String × Ty)) : Ty → Ty
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
def monoFnDef (origFn : FnDef) (monoName : String) (mapping : List (String × Ty)) : FnDef :=
  let subst := substTyMono origFn.typeParams mapping
  { origFn with
    name := monoName
    params := origFn.params.map fun p => { p with ty := subst p.ty }
    retTy := subst origFn.retTy
    typeParams := []
    typeBounds := [] }


end Concrete
