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
  deriving Repr, Inhabited

def CodegenState.init : CodegenState :=
  { output := "", labelCounter := 0, localCounter := 0,
    vars := [], varTypes := [], structDefs := [], enumDefs := [], fnRetTypes := [],
    stringLitCounter := 0, stringGlobals := "" }

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
  else if c.toNat >= 32 && c.toNat <= 126 then String.singleton c
  else
    let n := c.toNat
    let hi := n / 16
    let lo := n % 16
    let hexDigit (d : Nat) : Char :=
      if d < 10 then Char.ofNat (d + '0'.toNat)
      else Char.ofNat (d - 10 + 'A'.toNat)
    "\\" ++ String.mk [hexDigit hi, hexDigit lo]

private def escapeStringForLLVM (s : String) : String :=
  s.foldl (fun acc c => acc ++ escapeCharForLLVM c) ""

def tyToLLVM (s : CodegenState) : Ty → String
  | .int => "i64"
  | .uint => "i64"
  | .bool => "i1"
  | .float64 => "double"
  | .unit => "void"
  | .string => "%struct.String"
  | .ref _ => "ptr"
  | .refMut _ => "ptr"
  | .generic name _ => "%struct." ++ name  -- monomorphized name
  | .typeVar _ => "i64"  -- shouldn't happen after monomorphization
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
  | .named name =>
    if (s.lookupStruct name).isSome || (s.lookupEnum name).isSome then "ptr"
    else "i64"
  | ty => tyToLLVM s ty

def isStructTy (s : CodegenState) : Ty → Bool
  | .string => true
  | .named name => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | .ref _ | .refMut _ => true
  | _ => false

/-- Is this type passed by pointer in function calls and stored as ptr? -/
def isPassByPtr (s : CodegenState) (ty : Ty) : Bool :=
  match ty with
  | .string => true
  | .ref _ | .refMut _ => true
  | .array _ _ => true
  | .named name => (s.lookupStruct name).isSome || (s.lookupEnum name).isSome
  | _ => false

private partial def stmtListHasReturn (stmts : List Stmt) : Bool :=
  stmts.any fun s => match s with
    | .return_ _ => true
    | .ifElse _ thenBody (some elseBody) =>
      stmtListHasReturn thenBody && stmtListHasReturn elseBody
    | _ => false

/-- Infer the type of an expression from codegen state. -/
private def inferExprTy (s : CodegenState) (e : Expr) : Ty :=
  match e with
  | .intLit _ => .int
  | .boolLit _ => .bool
  | .strLit _ => .string
  | .ident name => (s.lookupVarType name).getD .int
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    match objTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (_, ty) => ty
      | none => .int
    | _ => .int
  | .structLit name _ _ => .named name
  | .enumLit name _ _ _ => .named name
  | .match_ _ _ => .int  -- match returns from arms via return stmt
  | .call fnName _ _ => (s.fnRetTypes.lookup fnName).getD .int
  | .binOp op _ _ =>
    match op with
    | .eq | .neq | .lt | .gt | .leq | .geq | .and_ | .or_ => .bool
    | _ => .int
  | .unaryOp .not_ _ => .bool
  | .unaryOp .neg _ => .int
  | .paren inner => inferExprTy s inner
  | .borrow inner => .ref (inferExprTy s inner)
  | .borrowMut inner => .refMut (inferExprTy s inner)
  | .deref inner =>
    match inferExprTy s inner with
    | .ref t => t
    | .refMut t => t
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
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    (s.fnRetTypes.lookup mangledName).getD .int
  | .staticMethodCall typeName methodName _ _ =>
    let mangledName := typeName ++ "_" ++ methodName
    (s.fnRetTypes.lookup mangledName).getD .int

mutual

/-- Generate an expression, returning the LLVM register holding the value.
    For struct values, this loads the whole struct (not useful for GEP).
    Use genExprAsPtr for struct pointer access. -/
partial def genExpr (s : CodegenState) (e : Expr) : CodegenState × String :=
  match e with
  | .intLit v =>
    let (s, reg) := s.freshLocal
    let s := s.emit ("  " ++ reg ++ " = add i64 0, " ++ toString v)
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
  | .ident name =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      if isPassByPtr s ty then
        -- For struct/enum/ref variables, return the pointer directly
        (s, alloca)
      else
        let (s, loaded) := s.freshLocal
        let llTy := tyToLLVM s ty
        let s := s.emit ("  " ++ loaded ++ " = load " ++ llTy ++ ", ptr " ++ alloca)
        (s, loaded)
    | none => (s, "%" ++ name)
  | .binOp op lhs rhs =>
    let (s, lReg) := genExpr s lhs
    let (s, rReg) := genExpr s rhs
    let (s, result) := s.freshLocal
    let instr := match op with
      | .add => "add i64 " ++ lReg ++ ", " ++ rReg
      | .sub => "sub i64 " ++ lReg ++ ", " ++ rReg
      | .mul => "mul i64 " ++ lReg ++ ", " ++ rReg
      | .div => "sdiv i64 " ++ lReg ++ ", " ++ rReg
      | .mod => "srem i64 " ++ lReg ++ ", " ++ rReg
      | .eq => "icmp eq i64 " ++ lReg ++ ", " ++ rReg
      | .neq => "icmp ne i64 " ++ lReg ++ ", " ++ rReg
      | .lt => "icmp slt i64 " ++ lReg ++ ", " ++ rReg
      | .gt => "icmp sgt i64 " ++ lReg ++ ", " ++ rReg
      | .leq => "icmp sle i64 " ++ lReg ++ ", " ++ rReg
      | .geq => "icmp sge i64 " ++ lReg ++ ", " ++ rReg
      | .and_ => "and i1 " ++ lReg ++ ", " ++ rReg
      | .or_ => "or i1 " ++ lReg ++ ", " ++ rReg
    let s := s.emit ("  " ++ result ++ " = " ++ instr)
    (s, result)
  | .unaryOp op operand =>
    let (s, reg) := genExpr s operand
    let (s, result) := s.freshLocal
    match op with
    | .neg =>
      let s := s.emit ("  " ++ result ++ " = sub i64 0, " ++ reg)
      (s, result)
    | .not_ =>
      let s := s.emit ("  " ++ result ++ " = xor i1 " ++ reg ++ ", 1")
      (s, result)
  | .call fnName _typeArgs args =>
    let (s, argRegs) := genExprList s args
    -- Figure out the LLVM type for each argument
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := (s.fnRetTypes.lookup fnName).getD .int
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ fnName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      -- Struct/enum return: call returns value, store to alloca
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
  | .paren inner => genExpr s inner
  | .structLit name _typeArgs fields =>
    match s.lookupStruct name with
    | some si =>
      let structTy := "%struct." ++ name
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ structTy)
      -- Store each field via GEP
      let s := fields.foldl (fun s (fieldName, fieldExpr) =>
        match si.fields.find? fun fi => fi.name == fieldName with
        | some fi =>
          let (s, valReg) := genExpr s fieldExpr
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s fi.ty
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
            ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString fi.index)
          s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
        | none => s
      ) s
      (s, alloca)
    | none =>
      -- Fallback: treat as i64
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown struct " ++ name)
      (s, reg)
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    -- Auto-deref through references
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    match innerTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        let structTy := "%struct." ++ structName
        -- For refs, genExpr gives us the pointer; for direct structs, genExprAsPtr
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
        (s, loaded)
      | none =>
        let (s, reg) := s.freshLocal
        let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown field " ++ field)
        (s, reg)
    | _ =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; field access on non-struct")
      (s, reg)
  | .borrow inner =>
    -- &expr: get pointer to the expression
    genExprAsPtr s inner
  | .borrowMut inner =>
    -- &mut expr: get pointer to the expression
    genExprAsPtr s inner
  | .deref inner =>
    -- *expr: load through the pointer
    let (s, ptr) := genExpr s inner
    let innerTy := inferExprTy s inner
    let pointeeTy := match innerTy with
      | .ref t => t
      | .refMut t => t
      | _ => .int
    let llTy := tyToLLVM s pointeeTy
    if llTy == "ptr" then
      -- For struct/enum types, just return the pointer
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
        -- Store tag
        let (s, tagPtr) := s.freshLocal
        let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
          ++ ", ptr " ++ alloca ++ ", i32 0, i32 0")
        let s := s.emit ("  store i32 " ++ toString vi.tag ++ ", ptr " ++ tagPtr)
        -- Store fields into payload
        let (s, payloadPtr) := s.freshLocal
        let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
          ++ ", ptr " ++ alloca ++ ", i32 0, i32 1")
        -- Cast payload to variant struct type
        let variantTy := "%variant." ++ enumName ++ "." ++ variant
        let s := fields.foldl (fun s (fieldName, fieldExpr) =>
          match vi.fields.find? fun fi => fi.name == fieldName with
          | some fi =>
            let (s, valReg) := genExpr s fieldExpr
            let (s, gepReg) := s.freshLocal
            let fieldLLTy := fieldTyToLLVM s fi.ty
            let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
              ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
            s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
          | none => s
        ) s
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
    -- Generate scrutinee (get pointer to enum)
    let (s, scrPtr) := genExpr s scrutinee
    -- Load tag
    let scrTy := inferExprTy s scrutinee
    let enumName := match scrTy with
      | .named n => n
      | _ => "unknown"
    let enumTy := "%enum." ++ enumName
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    -- Get payload pointer
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    -- Create merge label
    let (s, mergeLabel) := s.freshLabel "match.merge"
    let (s, defaultLabel) := s.freshLabel "match.default"
    -- Generate arm labels
    let (s, armLabels) := arms.foldl (fun (acc : CodegenState × List String) _arm =>
      let (s, labels) := acc
      let (s, label) := s.freshLabel "match.arm"
      (s, labels ++ [label])
    ) (s, [])
    -- Build switch instruction
    let ei := (s.lookupEnum enumName).get!
    let cases := arms.zip armLabels |>.filterMap fun (arm, label) =>
      match arm with
      | .mk _ variant _ _ =>
        match ei.variants.find? fun v => v.name == variant with
        | some vi => some ("    i32 " ++ toString vi.tag ++ ", label %" ++ label)
        | none => none
    let switchCases := "\n".intercalate cases
    let s := s.emit ("  switch i32 " ++ tag ++ ", label %" ++ defaultLabel ++ " [\n" ++ switchCases ++ "\n  ]")
    -- Generate each arm
    let s := (arms.zip armLabels).foldl (fun s (arm, label) =>
      match arm with
      | .mk _ variant bindings body =>
        let s := s.emit (label ++ ":")
        let variantTy := "%variant." ++ enumName ++ "." ++ variant
        -- Extract fields from payload
        let vi := (ei.variants.find? fun v => v.name == variant).get!
        let s := (bindings.zip vi.fields).foldl (fun s (binding, fi) =>
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s fi.ty
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
            ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          -- Store binding as a local variable
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ fieldLLTy)
          let s := s.emit ("  store " ++ fieldLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          s.addVarType binding fi.ty
        ) s
        -- Generate arm body
        let s := genStmts s body
        -- Branch to merge (if body didn't return)
        let hasRet := stmtListHasReturn body
        if hasRet then s else s.emit ("  br label %" ++ mergeLabel)
    ) s
    -- Default label (unreachable)
    let s := s.emit (defaultLabel ++ ":")
    let s := s.emit "  unreachable"
    -- Check if all arms return
    let allReturn := arms.all fun arm => match arm with
      | .mk _ _ _ body => stmtListHasReturn body
    if allReturn then
      -- All arms return, no merge block needed. Emit dummy for LLVM.
      (s, "0")
    else
      -- Merge label
      let s := s.emit (mergeLabel ++ ":")
      let (s, dummy) := s.freshLocal
      let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
      (s, dummy)
  | .try_ inner =>
    -- ? operator: unwrap Ok or early-return Err
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
    -- Load tag
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    -- Branch
    let (s, okLabel) := s.freshLabel "try.ok"
    let (s, errLabel) := s.freshLabel "try.err"
    let (s, isOk) := s.freshLocal
    let s := s.emit ("  " ++ isOk ++ " = icmp eq i32 " ++ tag ++ ", " ++ toString okVi.tag)
    let s := s.emit ("  br i1 " ++ isOk ++ ", label %" ++ okLabel ++ ", label %" ++ errLabel)
    -- Err case: return the enum as-is
    let s := s.emit (errLabel ++ ":")
    let (s, errVal) := s.freshLocal
    let s := s.emit ("  " ++ errVal ++ " = load " ++ enumTy ++ ", ptr " ++ scrPtr)
    let s := s.emit ("  ret " ++ enumTy ++ " " ++ errVal)
    -- Ok case: extract the value field
    let s := s.emit (okLabel ++ ":")
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    let variantTy := "%variant." ++ enumName ++ ".Ok"
    let (s, valueGep) := s.freshLocal
    let s := s.emit ("  " ++ valueGep ++ " = getelementptr inbounds " ++ variantTy
      ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 0")
    if isPassByPtr s okFieldTy then
      -- Struct/enum value: return pointer to field
      (s, valueGep)
    else
      let (s, value) := s.freshLocal
      let s := s.emit ("  " ++ value ++ " = load " ++ okFieldLLTy ++ ", ptr " ++ valueGep)
      (s, value)
  | .arrayLit elems =>
    let elemTy := match elems.head? with
      | some e => inferExprTy s e
      | none => Ty.int
    let n := elems.length
    let arrTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca " ++ arrTy)
    let elemLLTy := tyToLLVM s elemTy
    let (s, _) := elems.foldl (fun (acc : CodegenState × Nat) e =>
      let s := acc.1
      let idx := acc.2
      let (s, valReg) := genExpr s e
      let (s, gepReg) := s.freshLocal
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrTy
        ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString idx)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
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
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idxReg)
    if isPassByPtr s elemTy then
      (s, gepReg)
    else
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ gepReg)
      (s, loaded)
  | .cast inner targetTy =>
    let (s, reg) := genExpr s inner
    let innerTy := inferExprTy s inner
    let (s, result) := s.freshLocal
    match innerTy, targetTy with
    | .int, .uint | .uint, .int =>
      -- No-op: both are i64
      let s := s.emit ("  " ++ result ++ " = add i64 0, " ++ reg)
      (s, result)
    | .int, .bool =>
      let s := s.emit ("  " ++ result ++ " = icmp ne i64 " ++ reg ++ ", 0")
      (s, result)
    | .bool, .int =>
      let s := s.emit ("  " ++ result ++ " = zext i1 " ++ reg ++ " to i64")
      (s, result)
    | .int, .float64 =>
      let s := s.emit ("  " ++ result ++ " = sitofp i64 " ++ reg ++ " to double")
      (s, result)
    | .float64, .int =>
      let s := s.emit ("  " ++ result ++ " = fptosi double " ++ reg ++ " to i64")
      (s, result)
    | .uint, .float64 =>
      let s := s.emit ("  " ++ result ++ " = uitofp i64 " ++ reg ++ " to double")
      (s, result)
    | .float64, .uint =>
      let s := s.emit ("  " ++ result ++ " = fptoui double " ++ reg ++ " to i64")
      (s, result)
    | .bool, .uint =>
      let s := s.emit ("  " ++ result ++ " = zext i1 " ++ reg ++ " to i64")
      (s, result)
    | .uint, .bool =>
      let s := s.emit ("  " ++ result ++ " = icmp ne i64 " ++ reg ++ ", 0")
      (s, result)
    | _, _ =>
      -- Fallback: identity
      let s := s.emit ("  " ++ result ++ " = add i64 0, " ++ reg)
      (s, result)
  | .methodCall obj methodName _typeArgs args =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    -- Generate receiver as pointer (for &self/&mut self methods)
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

/-- Get a pointer to an expression's storage (for struct GEP). -/
partial def genExprAsPtr (s : CodegenState) (e : Expr) : CodegenState × String :=
  match e with
  | .ident name =>
    match s.lookupVar name with
    | some alloca => (s, alloca)
    | none => (s, "%" ++ name)
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    match objTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, _) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        (s, gepReg)
      | none => (s, "%undef")
    | _ => (s, "%undef")
  | .strLit _ =>
    genExpr s e
  | .borrow _ | .borrowMut _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .deref _ =>
    -- *expr as lvalue: the pointer itself
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
    -- For array index as ptr, do GEP without loading
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .methodCall _ _ _ _ | .staticMethodCall _ _ _ _ | .cast _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | _ =>
    -- For non-lvalue expressions, generate and store to a temp
    let (s, reg) := genExpr s e
    let (s, tmp) := s.freshLocal
    let s := s.emit ("  " ++ tmp ++ " = alloca i64")
    let s := s.emit ("  store i64 " ++ reg ++ ", ptr " ++ tmp)
    (s, tmp)

partial def genExprList (s : CodegenState) (args : List Expr) : CodegenState × List String :=
  match args with
  | [] => (s, [])
  | e :: rest =>
    let (s, reg) := genExpr s e
    let (s, regs) := genExprList s rest
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
    match exprTy with
    | _ =>
      if isPassByPtr s exprTy then
        -- Struct/Enum/Ref: generate the value (which returns a pointer)
        let (s, valPtr) := genExpr s value
        let s := s.addVar name valPtr
        s.addVarType name exprTy
      else
        let llTy := tyToLLVM s exprTy
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
        let (s, valReg) := genExpr s value
        let s := s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ alloca)
        let s := s.addVar name alloca
        s.addVarType name exprTy
  | .assign name value =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      let llTy := tyToLLVM s ty
      let (s, valReg) := genExpr s value
      s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ alloca)
    | none => s.emit ("; ERROR: unknown variable " ++ name)
  | .return_ (some value) =>
    let (s, reg) := genExpr s value
    let retTy := inferExprTy s value
    if isPassByPtr s retTy then
      let llTy := tyToLLVM s retTy
      let (s, val) := s.freshLocal
      let s := s.emit ("  " ++ val ++ " = load " ++ llTy ++ ", ptr " ++ reg)
      s.emit ("  ret " ++ llTy ++ " " ++ val)
    else
      let llTy := tyToLLVM s retTy
      s.emit ("  ret " ++ llTy ++ " " ++ reg)
  | .return_ none =>
    s.emit "  ret void"
  | .expr e =>
    let (s, _) := genExpr s e
    s
  | .ifElse cond thenBody elseBody =>
    let (s, condReg) := genExpr s cond
    let (s, thenLabel) := s.freshLabel "then"
    let (s, elseLabel) := s.freshLabel "else"
    let (s, mergeLabel) := s.freshLabel "merge"
    let s := s.emit ("  br i1 " ++ condReg ++ ", label %" ++ thenLabel ++ ", label %" ++ elseLabel)
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
    -- Auto-deref through references
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
        let (s, valReg) := genExpr s value
        s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      | none => s.emit ("; ERROR: unknown field " ++ field)
    | _ => s.emit ("; ERROR: field assign on non-struct")
  | .derefAssign target value =>
    -- *ptr = value: get the pointer, store value through it
    let (s, ptr) := genExpr s target
    let (s, valReg) := genExpr s value
    let targetTy := inferExprTy s target
    let pointeeTy := match targetTy with
      | .refMut t => t
      | .ref t => t
      | t => t
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
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idxReg)
    let (s, valReg) := genExpr s value
    s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
  | .while_ cond body =>
    let (s, condLabel) := s.freshLabel "while.cond"
    let (s, bodyLabel) := s.freshLabel "while.body"
    let (s, exitLabel) := s.freshLabel "while.exit"
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let s := s.emit ("  br i1 " ++ condReg ++ ", label %" ++ bodyLabel ++ ", label %" ++ exitLabel)
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ condLabel)
    s.emit (exitLabel ++ ":")

end

def genFnParams (s : CodegenState) (params : List Param) : CodegenState :=
  match params with
  | [] => s
  | p :: rest =>
    if isPassByPtr s p.ty then
      -- Ptr params — use directly, no alloca needed
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
  let s := genFnParams s f.params
  let s := genStmts s f.body
  -- Add implicit ret void for void functions without explicit return
  let s := if retTy == "void" && !stmtListHasReturn f.body then
    s.emit "  ret void"
  else s
  s.emit "}\n"

private def enumerateFields (fields : List StructField) (idx : Nat := 0) : List FieldInfo :=
  match fields with
  | [] => []
  | f :: rest => { name := f.name, ty := f.ty, index := idx } :: enumerateFields rest (idx + 1)

def buildStructDefs (structs : List StructDef) : List StructInfo :=
  structs.map fun sd =>
    { name := sd.name, fields := enumerateFields sd.fields }

private def tySize : Ty → Nat
  | .int | .uint | .float64 => 8
  | .bool => 1
  | .unit => 0
  | .string => 16  -- ptr + i64
  | .named _ => 8  -- pointer-sized
  | .ref _ | .refMut _ => 8  -- pointer-sized
  | .generic _ _ | .typeVar _ => 8
  | .array elem n => tySize elem * n

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
    -- Emit variant struct types
    let s := ed.variants.foldl (fun s v =>
      let vi := (ei.variants.find? fun vi => vi.name == v.name).get!
      let fieldTypes := ", ".intercalate (vi.fields.map fun fi => fieldTyToLLVM s fi.ty)
      s.emit ("%variant." ++ ed.name ++ "." ++ v.name ++ " = type { " ++ fieldTypes ++ " }")
    ) s
    -- Emit enum type: { i32, [payloadSize x i8] }
    -- But we use the max variant struct size as payload
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
  -- Collect impl method return types with mangled names
  let implRetTypes := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let traitImplRetTypes := m.traitImpls.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, f.retTy)
  ) ([] : List (String × Ty))
  let fnRetTypes := (m.functions.map fun f => (f.name, f.retTy)) ++ builtinRetTypes ++ implRetTypes ++ traitImplRetTypes
  let s := { CodegenState.init with structDefs := structInfos, enumDefs := enumInfos, fnRetTypes }
  let s := s.emit "; Generated by Concrete compiler"
  let s := s.emit ("; Module: " ++ m.name)
  let s := s.emit ""
  -- String type definition
  let s := s.emit "%struct.String = type { ptr, i64 }"
  let s := s.emit ""
  -- Emit struct type definitions
  let s := genStructTypes s m.structs
  let s := if m.structs.isEmpty then s else s.emit ""
  -- Emit enum type definitions
  let s := genEnumTypes s m.enums
  let s := if m.enums.isEmpty then s else s.emit ""
  -- External declarations
  let s := s.emit "declare ptr @malloc(i64)"
  let s := s.emit "declare void @free(ptr)"
  let s := s.emit "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)"
  let s := s.emit "declare i64 @write(i32, ptr, i64)"
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
  -- Impl block methods (mangled names, self param is ptr)
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
  -- String literal globals (accumulated during codegen)
  let s := if s.stringGlobals.isEmpty then s
    else { s with output := s.output ++ s.stringGlobals ++ "\n" }
  if hasMain then
    let s := s.emit "declare i32 @printf(ptr, ...)"
    let s := s.emit ""
    let s := s.emit "@.fmt = private constant [5 x i8] c\"%ld\\0A\\00\""
    let s := s.emit ""
    let s := s.emit "define i32 @main() {"
    let s := s.emit "  %result = call i64 @concrete_main()"
    let s := s.emit "  %fmt = getelementptr [5 x i8], ptr @.fmt, i64 0, i64 0"
    let s := s.emit "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %result)"
    let s := s.emit "  ret i32 0"
    let s := s.emit "}"
    s.output
  else
    s.output

def genProgram (modules : List Module) : String :=
  let combined : Module := {
    name := "combined",
    structs := modules.foldl (fun acc m => acc ++ m.structs) [],
    enums := modules.foldl (fun acc m => acc ++ m.enums) [],
    functions := modules.foldl (fun acc m => acc ++ m.functions) [],
    imports := [],
    implBlocks := modules.foldl (fun acc m => acc ++ m.implBlocks) [],
    traits := modules.foldl (fun acc m => acc ++ m.traits) [],
    traitImpls := modules.foldl (fun acc m => acc ++ m.traitImpls) []
  }
  genModule combined

end Concrete
