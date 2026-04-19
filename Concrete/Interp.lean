import Concrete.Core

namespace Concrete.Interp

open Concrete

/-! ## Source-level interpreter for the predictable/core subset

    First landing: targets `parse_validate` (integer/bool, structs, enums,
    arrays, match, bounded loops, calls). Unsupported constructs fail
    with explicit "interp: ..." diagnostics.

    Limitations:
    - No I/O (print/println), no capabilities
    - No borrow/deref/pointer operations
    - No float, char, string values
    - No overflow/truncation (arbitrary-precision integers)
    - Match arm mutations do not propagate to outer scope
-/

-- ============================================================
-- Interpreter values
-- ============================================================

inductive IVal where
  | int (val : Int) (ty : Ty)
  | bool (val : Bool)
  | struct_ (name : String) (fields : List (String × IVal))
  | enum_ (enumName variant : String) (fields : List (String × IVal))
  | array (elems : Array IVal) (elemTy : Ty) (size : Nat)
  | unit
  deriving Repr, Inhabited

-- ============================================================
-- Control flow signals
-- ============================================================

inductive Flow where
  | val (v : IVal)
  | ret (v : IVal)
  | brk
  | cont
  deriving Repr

-- ============================================================
-- Environment (flat list, latest binding wins)
-- ============================================================

abbrev Env := List (String × IVal)

partial def envGet (env : Env) (name : String) : Option IVal :=
  match env with
  | [] => none
  | (n, v) :: rest => if n == name then some v else envGet rest name

def envBind (env : Env) (name : String) (val : IVal) : Env :=
  (name, val) :: env

partial def envSet (env : Env) (name : String) (val : IVal) : Env :=
  match env with
  | [] => []
  | (n, v) :: rest =>
    if n == name then (n, val) :: rest
    else (n, v) :: envSet rest name val

-- ============================================================
-- Collect all function definitions from module tree
-- ============================================================

partial def collectFns : List CModule → List CFnDef
  | [] => []
  | m :: ms => m.functions ++ collectFns m.submodules ++ collectFns ms

def findFn (fns : List CFnDef) (name : String) : Option CFnDef :=
  fns.find? (fun f => f.name == name)

-- ============================================================
-- Array safe access
-- ============================================================

private def listGet (xs : List IVal) (n : Nat) : Option IVal :=
  match xs, n with
  | [], _ => none
  | x :: _, 0 => some x
  | _ :: rest, n + 1 => listGet rest n

private def arrayGet (elems : Array IVal) (n : Nat) : Option IVal :=
  listGet elems.toList n

-- ============================================================
-- Binary operations
-- ============================================================

private def intXor (a b : Int) : Int :=
  Int.ofNat (Nat.xor a.toNat b.toNat)

private def intAnd (a b : Int) : Int :=
  Int.ofNat (Nat.land a.toNat b.toNat)

private def intOr (a b : Int) : Int :=
  Int.ofNat (Nat.lor a.toNat b.toNat)

def evalBinOp (op : BinOp) (lhs rhs : IVal) : Except String IVal :=
  match op, lhs, rhs with
  | .add, .int a _, .int b ty => .ok (.int (a + b) ty)
  | .sub, .int a _, .int b ty => .ok (.int (a - b) ty)
  | .mul, .int a _, .int b ty => .ok (.int (a * b) ty)
  | .div, .int _ _, .int 0 _ => .error "interp: division by zero"
  | .div, .int a _, .int b ty => .ok (.int (a / b) ty)
  | .mod, .int _ _, .int 0 _ => .error "interp: modulo by zero"
  | .mod, .int a _, .int b ty => .ok (.int (a % b) ty)
  | .eq, .int a _, .int b _ => .ok (.bool (a == b))
  | .neq, .int a _, .int b _ => .ok (.bool (a != b))
  | .lt, .int a _, .int b _ => .ok (.bool (a < b))
  | .gt, .int a _, .int b _ => .ok (.bool (a > b))
  | .leq, .int a _, .int b _ => .ok (.bool (a <= b))
  | .geq, .int a _, .int b _ => .ok (.bool (a >= b))
  | .and_, .bool a, .bool b => .ok (.bool (a && b))
  | .or_, .bool a, .bool b => .ok (.bool (a || b))
  | .eq, .bool a, .bool b => .ok (.bool (a == b))
  | .neq, .bool a, .bool b => .ok (.bool (a != b))
  | .bitxor, .int a _, .int b ty => .ok (.int (intXor a b) ty)
  | .bitand, .int a _, .int b ty => .ok (.int (intAnd a b) ty)
  | .bitor, .int a _, .int b ty => .ok (.int (intOr a b) ty)
  | .shl, .int a _, .int b ty => .ok (.int (a * (2 ^ b.toNat)) ty)
  | .shr, .int a _, .int b ty => .ok (.int (a / (2 ^ b.toNat)) ty)
  | _, _, _ => .error "interp: unsupported binop on given value types"

-- ============================================================
-- Unary operations
-- ============================================================

def evalUnaryOp (op : UnaryOp) (v : IVal) : Except String IVal :=
  match op, v with
  | .neg, .int n ty => .ok (.int (-n) ty)
  | .not_, .bool b => .ok (.bool (!b))
  | .bitnot, .int n ty => .ok (.int (-(n + 1)) ty)
  | _, _ => .error "interp: unsupported unary op"

-- ============================================================
-- Type coercion (integer type conversions only)
-- ============================================================

def evalCast (v : IVal) (targetTy : Ty) : Except String IVal :=
  match v with
  | .int n _ => .ok (.int n targetTy)
  | .bool true => .ok (.int 1 targetTy)
  | .bool false => .ok (.int 0 targetTy)
  | _ => .error "interp: unsupported cast"

-- ============================================================
-- Helpers (must precede mutual block — no forward refs in Lean 4)
-- ============================================================

private def bindParams (env : Env) (params : List (String × Ty)) (args : List IVal) : Env :=
  match params, args with
  | [], _ => env
  | _, [] => env
  | (name, _) :: ps, v :: vs => bindParams (envBind env name v) ps vs

private def bindEnumFields (env : Env) (bindings : List (String × Ty)) (fields : List (String × IVal)) : Env :=
  match bindings with
  | [] => env
  | (name, _) :: rest =>
    let val := match fields.find? (fun (n, _) => n == name) with
      | some (_, v) => v
      | none => .unit
    bindEnumFields (envBind env name val) rest fields

private def matchLit (scrutinee : IVal) (lit : IVal) : Bool :=
  match scrutinee, lit with
  | .int a _, .int b _ => a == b
  | .bool a, .bool b => a == b
  | _, _ => false

-- ============================================================
-- Core evaluator (partial, mutually recursive)
-- ============================================================

mutual

partial def evalExpr (fns : List CFnDef) (env : Env) (e : CExpr) : Except String Flow := do
  match e with
  | .intLit val ty => return .val (.int val ty)
  | .boolLit val => return .val (.bool val)
  | .strLit _ => .error "interp: string literals not yet supported"
  | .charLit _ => .error "interp: char literals not yet supported"
  | .floatLit _ _ => .error "interp: float literals not yet supported"

  | .ident name _ =>
    match envGet env name with
    | some v => return .val v
    | none => .error s!"interp: undefined variable '{name}'"

  | .binOp op lhs rhs _ => do
    let lv ← evalExprVal fns env lhs
    let rv ← evalExprVal fns env rhs
    let result ← evalBinOp op lv rv
    return .val result

  | .unaryOp op operand _ => do
    let v ← evalExprVal fns env operand
    let result ← evalUnaryOp op v
    return .val result

  | .call fnName _ args _ => do
    let argVals ← evalCallArgs fns env args
    match findFn fns fnName with
    | none => .error s!"interp: undefined function '{fnName}'"
    | some fdef =>
      if fdef.params.length != argVals.length then
        .error s!"interp: arity mismatch calling '{fnName}': expected {fdef.params.length}, got {argVals.length}"
      else
        let callEnv := bindParams [] fdef.params argVals
        let (_, flow) ← evalStmts fns callEnv fdef.body
        match flow with
        | .ret v => return .val v
        | .val v => return .val v
        | _ => return .val .unit

  | .structLit name _ fields _ => do
    let fieldVals ← evalFields fns env fields
    return .val (.struct_ name fieldVals)

  | .fieldAccess obj field _ => do
    let v ← evalExprVal fns env obj
    match v with
    | .struct_ _ fields =>
      match fields.find? (fun (n, _) => n == field) with
      | some (_, fv) => return .val fv
      | none => .error s!"interp: field '{field}' not found in struct"
    | _ => .error "interp: field access on non-struct value"

  | .enumLit enumName variant _ fields _ => do
    let fieldVals ← evalFields fns env fields
    return .val (.enum_ enumName variant fieldVals)

  | .match_ scrutinee arms _ => do
    let sv ← evalExprVal fns env scrutinee
    evalMatch fns env sv arms

  | .arrayLit elems ty => do
    let vals ← evalCallArgs fns env elems
    let elemTy := match ty with
      | .array t _ => t
      | _ => .unit
    return .val (.array vals.toArray elemTy vals.length)

  | .arrayIndex arr idx _ => do
    let av ← evalExprVal fns env arr
    match av with
    | .array elems _ _ => do
      let iv ← evalExprVal fns env idx
      match iv with
      | .int i _ =>
        if i < 0 then .error s!"interp: negative array index {i}"
        else
          let n := i.toNat
          match arrayGet elems n with
          | some v => return .val v
          | none => .error s!"interp: array index {i} out of bounds (size {elems.size})"
      | _ => .error "interp: array index is not an integer"
    | _ => .error "interp: array index on non-array value"

  | .cast inner targetTy => do
    let v ← evalExprVal fns env inner
    let result ← evalCast v targetTy
    return .val result

  | .ifExpr cond thenStmts elseStmts _ => do
    let cv ← evalExprVal fns env cond
    match cv with
    | .bool true =>
      let (_, flow) ← evalStmts fns env thenStmts
      return flow
    | .bool false =>
      let (_, flow) ← evalStmts fns env elseStmts
      return flow
    | _ => .error "interp: if condition is not a boolean"

  | .borrow _ _ => .error "interp: borrow expressions not yet supported"
  | .borrowMut _ _ => .error "interp: borrow-mut expressions not yet supported"
  | .deref _ _ => .error "interp: deref expressions not yet supported"
  | .fnRef _ _ => .error "interp: function references not yet supported"
  | .try_ _ _ => .error "interp: try expressions not yet supported"
  | .allocCall _ _ _ => .error "interp: alloc expressions not yet supported"
  | .whileExpr _ _ _ _ => .error "interp: while expressions not yet supported"

partial def evalExprVal (fns : List CFnDef) (env : Env) (e : CExpr) : Except String IVal := do
  let f ← evalExpr fns env e
  match f with
  | .val v => return v
  | .ret _ => .error "interp: unexpected return in value position"
  | .brk => .error "interp: unexpected break in value position"
  | .cont => .error "interp: unexpected continue in value position"

partial def evalCallArgs (fns : List CFnDef) (env : Env) (args : List CExpr) : Except String (List IVal) :=
  match args with
  | [] => .ok []
  | e :: rest => do
    let v ← evalExprVal fns env e
    let vs ← evalCallArgs fns env rest
    return v :: vs

partial def evalFields (fns : List CFnDef) (env : Env) (fields : List (String × CExpr)) : Except String (List (String × IVal)) :=
  match fields with
  | [] => .ok []
  | (name, expr) :: rest => do
    let v ← evalExprVal fns env expr
    let vs ← evalFields fns env rest
    return (name, v) :: vs

partial def evalMatch (fns : List CFnDef) (env : Env) (scrutinee : IVal) (arms : List CMatchArm) : Except String Flow :=
  match arms with
  | [] => .error "interp: no matching arm in match expression"
  | arm :: rest =>
    match arm with
    | .enumArm enumName variant bindings body =>
      match scrutinee with
      | .enum_ sEnum sVariant sFields =>
        if sEnum == enumName && sVariant == variant then
          let armEnv := bindEnumFields env bindings sFields
          evalMatchBody fns armEnv body
        else
          evalMatch fns env scrutinee rest
      | _ => evalMatch fns env scrutinee rest
    | .litArm value body => do
      let litVal ← evalExprVal fns env value
      if matchLit scrutinee litVal then
        evalMatchBody fns env body
      else
        evalMatch fns env scrutinee rest
    | .varArm binding _ body =>
      let armEnv := envBind env binding scrutinee
      evalMatchBody fns armEnv body

partial def evalMatchBody (fns : List CFnDef) (env : Env) (body : List CStmt) : Except String Flow := do
  let (_, flow) ← evalStmts fns env body
  return flow

partial def evalStmt (fns : List CFnDef) (env : Env) (s : CStmt) : Except String (Env × Flow) := do
  match s with
  | .letDecl name _ _ value => do
    let f ← evalExpr fns env value
    match f with
    | .val v => return (envBind env name v, .val .unit)
    | .ret v => return (env, .ret v)
    | .brk => return (env, .brk)
    | .cont => return (env, .cont)

  | .assign name value => do
    let f ← evalExpr fns env value
    match f with
    | .val v => return (envSet env name v, .val .unit)
    | .ret v => return (env, .ret v)
    | .brk => return (env, .brk)
    | .cont => return (env, .cont)

  | .return_ (some expr) _ => do
    let f ← evalExpr fns env expr
    match f with
    | .val v => return (env, .ret v)
    | other => return (env, other)

  | .return_ none _ =>
    return (env, .ret .unit)

  | .expr e => do
    let f ← evalExpr fns env e
    match f with
    | .val _ => return (env, .val .unit)
    | .ret v => return (env, .ret v)
    | .brk => return (env, .brk)
    | .cont => return (env, .cont)

  | .ifElse cond thenBody elseBody => do
    let cf ← evalExpr fns env cond
    match cf with
    | .val (.bool true) => evalStmts fns env thenBody
    | .val (.bool false) =>
      match elseBody with
      | some body => evalStmts fns env body
      | none => return (env, .val .unit)
    | .val _ => .error "interp: if condition is not a boolean"
    | .ret v => return (env, .ret v)
    | .brk => return (env, .brk)
    | .cont => return (env, .cont)

  | .while_ cond body _label step =>
    evalWhile fns env cond body step 10000000

  | .fieldAssign obj field value => do
    let newVal ← evalExprVal fns env value
    match obj with
    | .ident name _ =>
      match envGet env name with
      | some (.struct_ sname fields) =>
        let newFields := fields.map fun (n, v) =>
          if n == field then (n, newVal) else (n, v)
        return (envSet env name (.struct_ sname newFields), .val .unit)
      | _ => .error s!"interp: field assign on non-struct variable '{name}'"
    | _ => .error "interp: field assign on non-ident expression"

  | .arrayIndexAssign arr idx value => do
    let newVal ← evalExprVal fns env value
    let idxVal ← evalExprVal fns env idx
    match idxVal with
    | .int i _ =>
      match arr with
      | .ident name _ =>
        match envGet env name with
        | some (.array elems elemTy size) =>
          let n := i.toNat
          if n < elems.size then
            let newElems := elems.set! n newVal
            return (envSet env name (.array newElems elemTy size), .val .unit)
          else .error s!"interp: array index {i} out of bounds (size {elems.size})"
        | _ => .error s!"interp: array index assign on non-array variable '{name}'"
      | _ => .error "interp: array index assign on non-ident expression"
    | _ => .error "interp: array index is not an integer"

  | .break_ _ _ => return (env, .brk)
  | .continue_ _ => return (env, .cont)
  | .defer _ => .error "interp: defer not yet supported"
  | .derefAssign _ _ => .error "interp: deref assign not yet supported"
  | .borrowIn _ _ _ _ _ _ => .error "interp: borrowIn not yet supported"

partial def evalStmts (fns : List CFnDef) (env : Env) (stmts : List CStmt) : Except String (Env × Flow) :=
  match stmts with
  | [] => .ok (env, .val .unit)
  | s :: rest => do
    let (env', flow) ← evalStmt fns env s
    match flow with
    | .ret v => return (env', .ret v)
    | .brk => return (env', .brk)
    | .cont => return (env', .cont)
    | .val _ => evalStmts fns env' rest

partial def evalWhile (fns : List CFnDef) (env : Env) (cond : CExpr) (body : List CStmt) (step : List CStmt) (fuel : Nat) : Except String (Env × Flow) := do
  if fuel == 0 then .error "interp: loop exceeded maximum iterations (10000000)"
  else
    let cv ← evalExprVal fns env cond
    match cv with
    | .bool false => return (env, .val .unit)
    | .bool true =>
      let (bodyEnv, flow) ← evalStmts fns env body
      match flow with
      | .ret v => return (bodyEnv, .ret v)
      | .brk => return (bodyEnv, .val .unit)
      | .val _ =>
        -- Step is already included in body (for-loop desugaring appends it).
        -- Only run step explicitly on continue (where body was cut short).
        evalWhile fns bodyEnv cond body step (fuel - 1)
      | .cont =>
        -- Continue skips the rest of body, so run step before looping.
        let (stepEnv, _) ← evalStmts fns bodyEnv step
        evalWhile fns stepEnv cond body step (fuel - 1)
    | _ => .error "interp: while condition is not a boolean"

end -- mutual

-- ============================================================
-- Entry point
-- ============================================================

/-- Interpret a program from its validated Core modules.
    Finds and runs `main`, returns exit code. -/
def interpret (modules : List CModule) : Except String Int := do
  let fns := collectFns modules
  match fns.find? (fun f => f.name == "main") with
  | none => .error "interp: no 'main' function found"
  | some mainFn =>
    let (_, flow) ← evalStmts fns [] mainFn.body
    match flow with
    | .ret (.int n _) => return n
    | .ret _ => return 0
    | .val _ => return 0
    | _ => .error "interp: main did not return normally"

-- ============================================================
-- Display
-- ============================================================

partial def IVal.toString : IVal → String
  | .int n _ => s!"{n}"
  | .bool b => s!"{b}"
  | .struct_ name fields =>
    let fs := ", ".intercalate (fields.map fun (n, v) => s!"{n}: {v.toString}")
    name ++ " { " ++ fs ++ " }"
  | .enum_ ename variant fields =>
    if fields.isEmpty then ename ++ "#" ++ variant
    else
      let fs := ", ".intercalate (fields.map fun (n, v) => s!"{n}: {v.toString}")
      ename ++ "#" ++ variant ++ " { " ++ fs ++ " }"
  | .array elems _ _ =>
    let es := ", ".intercalate (elems.toList.map IVal.toString)
    "[" ++ es ++ "]"
  | .unit => "()"

instance : ToString IVal := ⟨IVal.toString⟩

end Concrete.Interp
