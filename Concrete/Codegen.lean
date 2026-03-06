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
  | .generic name _ => "%struct." ++ name
  | .typeVar _ => "i64"
  | .array elem n => "[" ++ toString n ++ " x " ++ tyToLLVM s elem ++ "]"
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
  | .named name =>
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
  | .named name => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
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
    | some (ty, _) => ty
    | none => (s.lookupVarType name).getD .int
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
  | .enumLit name _ _ _ => .named name
  | .match_ _ _ => .int
  | .call fnName _typeArgs _ =>
    if fnName == "sizeof" then match hint with
      | some t => t
      | none => .uint
    else (s.fnRetTypes.lookup fnName).getD .int
  | .binOp op lhs _ =>
    match op with
    | .eq | .neq | .lt | .gt | .leq | .geq | .and_ | .or_ => .bool
    | _ => inferExprTy s lhs
  | .unaryOp .not_ _ => .bool
  | .unaryOp .neg operand => inferExprTy s operand
  | .paren inner => inferExprTy s inner
  | .borrow inner => .ref (inferExprTy s inner)
  | .borrowMut inner => .refMut (inferExprTy s inner)
  | .deref inner =>
    match inferExprTy s inner with
    | .ref t => t
    | .refMut t => t
    | .ptrMut t => t
    | .ptrConst t => t
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
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    (s.fnRetTypes.lookup mangledName).getD .int
  | .staticMethodCall typeName methodName _ _ =>
    let mangledName := typeName ++ "_" ++ methodName
    (s.fnRetTypes.lookup mangledName).getD .int

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
  | .generic _ _ | .typeVar _ => 8
  | .array elem n => tySize elem * n

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
    | none => (s, "%" ++ name)
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
  | .call fnName typeArgs args =>
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
    -- Use the raw (un-substituted) param types for generating argument values
    let rawParamTys := (s.fnParamTypes.lookup fnName).getD []
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
    let retTy := (s.fnRetTypes.lookup fnName).getD .int
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ fnName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ fnName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ fnName ++ "(" ++ argStr ++ ")")
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
  | .enumLit enumName variant _typeArgs fields =>
    match s.lookupEnum enumName with
    | some ei =>
      match ei.variants.find? fun v => v.name == variant with
      | some vi =>
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
              let (s, valReg) := genExpr s fieldExpr (some fi.ty)
              let (s, gepReg) := s.freshLocal
              let fieldLLTy := fieldTyToLLVM s fi.ty
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
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s fi.ty
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
            ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ fieldLLTy)
          let s := s.emit ("  store " ++ fieldLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          s.addVarType binding fi.ty
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
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    let (s, selfPtr) := genExprAsPtr s obj
    let (s, argRegs) := genExprList s args
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let allArgRegs := selfPtr :: argRegs
    let allArgTys := "ptr" :: argTys
    let argPairs := allArgTys.zip allArgRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := (s.fnRetTypes.lookup mangledName).getD .int
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
    let retTy := (s.fnRetTypes.lookup mangledName).getD .int
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
  | .methodCall _ _ _ _ | .staticMethodCall _ _ _ _ | .cast _ _ =>
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

partial def genStmts (s : CodegenState) (stmts : List Stmt) : CodegenState :=
  match stmts with
  | [] => s
  | stmt :: rest => genStmts (genStmt s stmt) rest

partial def genStmt (s : CodegenState) (stmt : Stmt) : CodegenState :=
  match stmt with
  | .letDecl name _mutable ty value =>
    let exprTy := match ty with
      | some t => t
      | none => inferExprTy s value
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
  | .while_ cond body =>
    let (s, condLabel) := s.freshLabel "while.cond"
    let (s, bodyLabel) := s.freshLabel "while.body"
    let (s, exitLabel) := s.freshLabel "while.exit"
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
    s.emit (exitLabel ++ ":")
  | .forLoop init cond step body =>
    -- Generate init
    let s := match init with
      | some initStmt => genStmt s initStmt
      | none => s
    -- for loop = while with step
    let (s, condLabel) := s.freshLabel "for.cond"
    let (s, bodyLabel) := s.freshLabel "for.body"
    let (s, exitLabel) := s.freshLabel "for.exit"
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
    -- Generate step
    let s := match step with
      | some stepStmt => genStmt s stepStmt
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    s.emit (exitLabel ++ ":")

end

def genFnParams (s : CodegenState) (params : List Param) : CodegenState :=
  match params with
  | [] => s
  | p :: rest =>
    if isPassByPtr s p.ty then
      let s := s.addVar p.name ("%" ++ p.name)
      let s := s.addVarType p.name p.ty
      genFnParams s rest
    else
      let llTy := tyToLLVM s p.ty
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
      let s := s.emit ("  store " ++ llTy ++ " %" ++ p.name ++ ", ptr " ++ alloca)
      let s := s.addVar p.name alloca
      let s := s.addVarType p.name p.ty
      genFnParams s rest

def genFn (s : CodegenState) (f : FnDef) (hasMainWrapper : Bool := false) : CodegenState :=
  let retTy := tyToLLVM s f.retTy
  let fnName := if f.name == "main" && hasMainWrapper then "concrete_main" else f.name
  let paramStr := ", ".intercalate (f.params.map fun p => paramTyToLLVM s p.ty ++ " %" ++ p.name)
  let s := s.emit ("define " ++ retTy ++ " @" ++ fnName ++ "(" ++ paramStr ++ ") {")
  let s := { s with currentRetTy := f.retTy }
  let s := genFnParams s f.params
  let s := genStmts s f.body
  let s := if !stmtListHasReturn f.body then
    if retTy == "void" then s.emit "  ret void"
    else s.emit ("  ret " ++ retTy ++ " 0")
  else s
  s.emit "}\n"

private def enumerateFields (fields : List StructField) (idx : Nat := 0) : List FieldInfo :=
  match fields with
  | [] => []
  | f :: rest => { name := f.name, ty := f.ty, index := idx } :: enumerateFields rest (idx + 1)

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
    { name := ed.name, variants, payloadSize := maxPayload }

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

def genModule (m : Module) : String :=
  let structInfos := buildStructDefs m.structs
  let enumInfos := buildEnumDefs m.enums
  let builtinRetTypes := [
    ("string_length", Ty.int),
    ("drop_string", Ty.unit),
    ("print_string", Ty.unit),
    ("string_concat", Ty.string)
  ]
  let implRetTypes := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let traitImplRetTypes := m.traitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let externRetTypes := m.externFns.map fun ef => (ef.name, ef.retTy)
  let fnRetTypes := (m.functions.map fun f => (f.name, f.retTy)) ++ builtinRetTypes ++ implRetTypes ++ traitImplRetTypes ++ externRetTypes
  let fnParamTypes : List (String × List Ty) := (m.functions.map fun f =>
    (f.name, f.params.map fun p => p.ty)) ++
    (m.implBlocks.foldl (fun acc ib =>
      acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, f.params.map fun p => p.ty)
    ) []) ++
    (m.traitImpls.foldl (fun acc tb =>
      acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, f.params.map fun p => p.ty)
    ) []) ++
    (m.externFns.map fun ef => (ef.name, ef.params.map fun p => p.ty))
  let constList := m.constants.map fun c => (c.name, (c.ty, c.value))
  let s := { CodegenState.init with structDefs := structInfos, enumDefs := enumInfos, fnRetTypes, fnParamTypes, constants := constList }
  let s := s.emit "; Generated by Concrete compiler"
  let s := s.emit ("; Module: " ++ m.name)
  let s := s.emit ""
  -- Only emit built-in String type if user hasn't defined one
  let hasUserString := m.structs.any fun sd => sd.name == "String"
  let s := if !hasUserString then
    let s := s.emit "%struct.String = type { ptr, i64 }"
    s.emit ""
  else s
  let s := genStructTypes s m.structs
  let s := if m.structs.isEmpty then s else s.emit ""
  let s := genEnumTypes s m.enums
  let s := if m.enums.isEmpty then s else s.emit ""
  -- External declarations
  let s := s.emit "declare ptr @malloc(i64)"
  let s := s.emit "declare void @free(ptr)"
  let s := s.emit "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)"
  let s := s.emit "declare i64 @write(i32, ptr, i64)"
  -- Extern function declarations from the source
  let s := m.externFns.foldl (fun s ef =>
    let retLLTy := tyToLLVM s ef.retTy
    let paramStr := ", ".intercalate (ef.params.map fun p => paramTyToLLVM s p.ty)
    -- Skip if already declared (malloc, free, etc.)
    if ef.name == "malloc" || ef.name == "free" then s
    else s.emit ("declare " ++ retLLTy ++ " @" ++ ef.name ++ "(" ++ paramStr ++ ")")
  ) s
  let s := s.emit ""
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
  -- User functions
  let hasMain := m.functions.any (fun f => f.name == "main")
  let s := m.functions.foldl (fun s f => genFn s f hasMain) s
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
    let s := s.emit "declare i32 @printf(ptr, ...)"
    let s := s.emit ""
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

def genProgram (modules : List Module) : String :=
  -- Build qualified name → original name aliases from submodules
  let aliases : List (String × String) := modules.foldl (fun acc m =>
    acc ++ m.submodules.foldl (fun acc2 (sub : Module) =>
      acc2 ++ (sub.functions.map fun f => (sub.name ++ "_" ++ f.name, f.name))
      ++ (sub.externFns.map fun ef => (sub.name ++ "_" ++ ef.name, ef.name))
    ) ([] : List (String × String))
  ) []
  let flatModules := modules.map flattenModule
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
