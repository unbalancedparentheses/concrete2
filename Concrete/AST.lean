namespace Concrete

inductive Ty where
  | int          -- Int or i64
  | uint         -- Uint or u64
  | i8 | i16 | i32   -- smaller signed integers
  | u8 | u16 | u32   -- smaller unsigned integers
  | bool
  | float64      -- f64 or Float64
  | float32      -- f32
  | char         -- char (i8 in LLVM)
  | unit
  | named (name : String)
  | string                -- String type
  | ref (inner : Ty)      -- &T
  | refMut (inner : Ty)   -- &mut T
  | generic (name : String) (args : List Ty)  -- e.g. Pair<Int, Bool>
  | typeVar (name : String)                   -- e.g. T
  | array (elem : Ty) (size : Nat)            -- [T; N]
  | ptrMut (inner : Ty)   -- *mut T
  | ptrConst (inner : Ty) -- *const T
  deriving Repr, BEq

inductive BinOp where
  | add | sub | mul | div | mod
  | eq | neq | lt | gt | leq | geq
  | and_ | or_
  deriving Repr, BEq

inductive UnaryOp where
  | neg | not_
  deriving Repr, BEq

mutual
inductive Expr where
  | intLit (val : Int)
  | floatLit (val : Float)
  | boolLit (val : Bool)
  | strLit (val : String)
  | charLit (val : Char)
  | ident (name : String)
  | binOp (op : BinOp) (lhs rhs : Expr)
  | unaryOp (op : UnaryOp) (operand : Expr)
  | call (fn : String) (typeArgs : List Ty) (args : List Expr)
  | paren (inner : Expr)
  | structLit (name : String) (typeArgs : List Ty) (fields : List (String × Expr))
  | fieldAccess (obj : Expr) (field : String)
  | enumLit (enumName variant : String) (typeArgs : List Ty) (fields : List (String × Expr))
  | match_ (scrutinee : Expr) (arms : List MatchArm)
  | borrow (inner : Expr)      -- &expr
  | borrowMut (inner : Expr)   -- &mut expr
  | deref (inner : Expr)       -- *expr
  | try_ (inner : Expr)       -- expr?
  | arrayLit (elems : List Expr)              -- [1, 2, 3]
  | arrayIndex (arr : Expr) (index : Expr)    -- arr[i]
  | cast (inner : Expr) (targetTy : Ty)       -- expr as Type
  | methodCall (obj : Expr) (method : String) (typeArgs : List Ty) (args : List Expr)
  | staticMethodCall (typeName method : String) (typeArgs : List Ty) (args : List Expr)

inductive MatchArm where
  | mk (enumName : String) (variant : String) (bindings : List String) (body : List Stmt)
  | litArm (value : Expr) (body : List Stmt)           -- literal pattern: 0 -> ...
  | varArm (binding : String) (body : List Stmt)        -- variable pattern: n -> ...

inductive Stmt where
  | letDecl (name : String) (mutable : Bool) (ty : Option Ty) (value : Expr)
  | assign (name : String) (value : Expr)
  | return_ (value : Option Expr)
  | expr (e : Expr)
  | ifElse (cond : Expr) (then_ : List Stmt) (else_ : Option (List Stmt))
  | while_ (cond : Expr) (body : List Stmt)
  | forLoop (init : Option Stmt) (cond : Expr) (step : Option Stmt) (body : List Stmt)
  | fieldAssign (obj : Expr) (field : String) (value : Expr)
  | derefAssign (target : Expr) (value : Expr)  -- *expr = expr
  | arrayIndexAssign (arr : Expr) (index : Expr) (value : Expr)  -- arr[i] = val
end

structure ImportDecl where
  moduleName : String
  symbols : List String
  deriving Repr

structure Param where
  name : String
  ty : Ty
  deriving Repr

structure StructField where
  name : String
  ty : Ty
  deriving Repr

structure EnumVariant where
  name : String
  fields : List StructField
  deriving Repr, Inhabited

structure EnumDef where
  name : String
  typeParams : List String := []
  variants : List EnumVariant
  isPublic : Bool := false
  deriving Repr

structure StructDef where
  name : String
  typeParams : List String := []
  fields : List StructField
  isPublic : Bool := false
  isUnion : Bool := false
  deriving Repr

structure FnDef where
  name : String
  typeParams : List String := []
  params : List Param
  retTy : Ty
  body : List Stmt
  isPublic : Bool := false

structure ConstDef where
  name : String
  ty : Ty
  value : Expr
  isPublic : Bool := false

structure TypeAlias where
  name : String
  targetTy : Ty
  isPublic : Bool := false
  deriving Repr

structure ExternFnDecl where
  name : String
  params : List Param
  retTy : Ty
  isPublic : Bool := false
  deriving Repr

inductive SelfKind where
  | value    -- self
  | ref      -- &self
  | refMut   -- &mut self
  deriving Repr, BEq

structure FnSigDef where
  name : String
  params : List Param
  retTy : Ty
  selfKind : Option SelfKind := none
  deriving Repr

structure ImplBlock where
  typeName : String
  typeParams : List String := []
  methods : List FnDef

structure TraitDef where
  name : String
  typeParams : List String := []
  methods : List FnSigDef
  isPublic : Bool := false
  deriving Repr

structure ImplTraitBlock where
  traitName : String
  typeName : String
  typeParams : List String := []
  methods : List FnDef

structure Module where
  name : String
  structs : List StructDef
  enums : List EnumDef
  functions : List FnDef
  imports : List ImportDecl := []
  implBlocks : List ImplBlock := []
  traits : List TraitDef := []
  traitImpls : List ImplTraitBlock := []
  constants : List ConstDef := []
  typeAliases : List TypeAlias := []
  externFns : List ExternFnDecl := []
  submodules : List Module := []

end Concrete
