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

structure CodegenState where
  output : String
  labelCounter : Nat
  localCounter : Nat
  vars : List (String × String)
  varTypes : List (String × Ty)
  structDefs : List StructInfo
  deriving Repr, Inhabited

def CodegenState.init : CodegenState :=
  { output := "", labelCounter := 0, localCounter := 0,
    vars := [], varTypes := [], structDefs := [] }

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

def CodegenState.lookupFieldIndex (s : CodegenState) (structName : String) (fieldName : String) : Option (Nat × Ty) :=
  match s.lookupStruct structName with
  | some si =>
    match si.fields.find? fun fi => fi.name == fieldName with
    | some fi => some (fi.index, fi.ty)
    | none => none
  | none => none

def tyToLLVM (s : CodegenState) : Ty → String
  | .int => "i64"
  | .uint => "i64"
  | .bool => "i1"
  | .float64 => "double"
  | .unit => "void"
  | .named name =>
    match s.lookupStruct name with
    | some _ => "%struct." ++ name
    | none => "i64"

def fieldTyToLLVM (s : CodegenState) (ty : Ty) : String :=
  tyToLLVM s ty

/-- LLVM type for function parameters and call arguments.
    Structs are passed as ptr (by pointer). -/
def paramTyToLLVM (s : CodegenState) : Ty → String
  | .named name =>
    match s.lookupStruct name with
    | some _ => "ptr"
    | none => "i64"
  | ty => tyToLLVM s ty

def isStructTy (s : CodegenState) : Ty → Bool
  | .named name => (s.lookupStruct name).isSome
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
  | .ident name => (s.lookupVarType name).getD .int
  | .fieldAccess obj field =>
    let objTy := inferExprTy s obj
    match objTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (_, ty) => ty
      | none => .int
    | _ => .int
  | .structLit name _ => .named name
  | .call _ _ => .int  -- TODO: track function return types
  | .binOp op _ _ =>
    match op with
    | .eq | .neq | .lt | .gt | .leq | .geq | .and_ | .or_ => .bool
    | _ => .int
  | .unaryOp .not_ _ => .bool
  | .unaryOp .neg _ => .int
  | .paren inner => inferExprTy s inner

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
  | .ident name =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      match ty with
      | .named structName =>
        match s.lookupStruct structName with
        | some _ =>
          -- For struct variables, return the pointer (alloca) directly
          (s, alloca)
        | none =>
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load i64, ptr " ++ alloca)
          (s, loaded)
      | _ =>
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
  | .call fnName args =>
    let (s, argRegs) := genExprList s args
    -- Figure out the LLVM type for each argument
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = call i64 @" ++ fnName ++ "(" ++ argStr ++ ")")
    (s, result)
  | .paren inner => genExpr s inner
  | .structLit name fields =>
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
    match objTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := genExprAsPtr s obj
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
    | .named structName =>
      match s.lookupStruct structName with
      | some _ =>
        -- Struct: generate the value (which returns a pointer to alloca'd struct)
        let (s, valPtr) := genExpr s value
        -- The struct literal already created an alloca, just use that pointer
        let s := s.addVar name valPtr
        s.addVarType name (.named structName)
      | none =>
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca i64")
        let (s, valReg) := genExpr s value
        let s := s.emit ("  store i64 " ++ valReg ++ ", ptr " ++ alloca)
        let s := s.addVar name alloca
        s.addVarType name exprTy
    | _ =>
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
    s.emit ("  ret i64 " ++ reg)
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
    match objTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        let (s, valReg) := genExpr s value
        s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      | none => s.emit ("; ERROR: unknown field " ++ field)
    | _ => s.emit ("; ERROR: field assign on non-struct")
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
    if isStructTy s p.ty then
      -- Struct params are passed as ptr — use directly, no alloca needed
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
  s.emit "}\n"

private def enumerateFields (fields : List StructField) (idx : Nat := 0) : List FieldInfo :=
  match fields with
  | [] => []
  | f :: rest => { name := f.name, ty := f.ty, index := idx } :: enumerateFields rest (idx + 1)

def buildStructDefs (structs : List StructDef) : List StructInfo :=
  structs.map fun sd =>
    { name := sd.name, fields := enumerateFields sd.fields }

def genStructTypes (s : CodegenState) (structs : List StructDef) : CodegenState :=
  structs.foldl (fun s sd =>
    let fieldTypes := ", ".intercalate (sd.fields.map fun f => tyToLLVM s f.ty)
    s.emit ("%struct." ++ sd.name ++ " = type { " ++ fieldTypes ++ " }")
  ) s

def genModule (m : Module) : String :=
  let structInfos := buildStructDefs m.structs
  let s := { CodegenState.init with structDefs := structInfos }
  let s := s.emit "; Generated by Concrete compiler"
  let s := s.emit ("; Module: " ++ m.name)
  let s := s.emit ""
  -- Emit struct type definitions
  let s := genStructTypes s m.structs
  let s := if m.structs.isEmpty then s else s.emit ""
  let hasMain := m.functions.any (fun f => f.name == "main")
  let s := m.functions.foldl (fun s f => genFn s f hasMain) s
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

end Concrete
