import Concrete.AST

namespace Concrete

structure CodegenState where
  output : String
  labelCounter : Nat
  localCounter : Nat
  vars : List (String × String)
  deriving Repr, Inhabited

def CodegenState.init : CodegenState :=
  { output := "", labelCounter := 0, localCounter := 0, vars := [] }

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

def tyToLLVM : Ty → String
  | .int => "i64"
  | .uint => "i64"
  | .bool => "i1"
  | .float64 => "double"
  | .unit => "void"
  | .named _ => "i64"

private partial def stmtListHasReturn (stmts : List Stmt) : Bool :=
  stmts.any fun s => match s with
    | .return_ _ => true
    | .ifElse _ thenBody (some elseBody) =>
      stmtListHasReturn thenBody && stmtListHasReturn elseBody
    | _ => false

mutual

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
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load i64, ptr " ++ alloca)
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
    let argStr := ", ".intercalate (argRegs.map fun r => "i64 " ++ r)
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = call i64 @" ++ fnName ++ "(" ++ argStr ++ ")")
    (s, result)
  | .paren inner => genExpr s inner

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
  | .letDecl name _mutable _ty value =>
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca i64")
    let (s, valReg) := genExpr s value
    let s := s.emit ("  store i64 " ++ valReg ++ ", ptr " ++ alloca)
    s.addVar name alloca
  | .assign name value =>
    match s.lookupVar name with
    | some alloca =>
      let (s, valReg) := genExpr s value
      s.emit ("  store i64 " ++ valReg ++ ", ptr " ++ alloca)
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
    -- Only emit merge block if at least one branch doesn't return
    if thenReturns && elseReturns then s
    else s.emit (mergeLabel ++ ":")
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
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca i64")
    let s := s.emit ("  store i64 %" ++ p.name ++ ", ptr " ++ alloca)
    let s := s.addVar p.name alloca
    genFnParams s rest

def genFn (s : CodegenState) (f : FnDef) (hasMainWrapper : Bool := false) : CodegenState :=
  let retTy := tyToLLVM f.retTy
  let fnName := if f.name == "main" && hasMainWrapper then "concrete_main" else f.name
  let paramStr := ", ".intercalate (f.params.map fun p => "i64 %" ++ p.name)
  let s := s.emit ("define " ++ retTy ++ " @" ++ fnName ++ "(" ++ paramStr ++ ") {")
  let s := genFnParams s f.params
  let s := genStmts s f.body
  s.emit "}\n"

def genModule (m : Module) : String :=
  let s := CodegenState.init
  let s := s.emit "; Generated by Concrete compiler"
  let s := s.emit ("; Module: " ++ m.name)
  let s := s.emit ""
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
