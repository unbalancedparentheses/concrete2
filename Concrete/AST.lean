namespace Concrete

inductive Ty where
  | int
  | uint
  | bool
  | float64
  | unit
  | named (name : String)
  deriving Repr, BEq

inductive BinOp where
  | add | sub | mul | div | mod
  | eq | neq | lt | gt | leq | geq
  | and_ | or_
  deriving Repr, BEq

inductive UnaryOp where
  | neg | not_
  deriving Repr, BEq

inductive Expr where
  | intLit (val : Int)
  | boolLit (val : Bool)
  | ident (name : String)
  | binOp (op : BinOp) (lhs rhs : Expr)
  | unaryOp (op : UnaryOp) (operand : Expr)
  | call (fn : String) (args : List Expr)
  | paren (inner : Expr)
  | structLit (name : String) (fields : List (String × Expr))
  | fieldAccess (obj : Expr) (field : String)
  deriving Repr

inductive Stmt where
  | letDecl (name : String) (mutable : Bool) (ty : Option Ty) (value : Expr)
  | assign (name : String) (value : Expr)
  | return_ (value : Option Expr)
  | expr (e : Expr)
  | ifElse (cond : Expr) (then_ : List Stmt) (else_ : Option (List Stmt))
  | while_ (cond : Expr) (body : List Stmt)
  | fieldAssign (obj : Expr) (field : String) (value : Expr)
  deriving Repr

structure Param where
  name : String
  ty : Ty
  deriving Repr

structure StructField where
  name : String
  ty : Ty
  deriving Repr

structure StructDef where
  name : String
  fields : List StructField
  deriving Repr

structure FnDef where
  name : String
  params : List Param
  retTy : Ty
  body : List Stmt
  deriving Repr

structure Module where
  name : String
  structs : List StructDef
  functions : List FnDef
  deriving Repr

end Concrete
