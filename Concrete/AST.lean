namespace Concrete

-- ============================================================
-- Capability Sets
-- ============================================================

inductive CapSet where
  | empty                              -- no capabilities (pure)
  | concrete (caps : List String)      -- concrete set, e.g., ["File", "Network"]
  | var (name : String)                -- capability variable, e.g., "C"
  | union (a b : CapSet)               -- union of two sets
  deriving Repr, BEq

/-- The standard capability set (Std = everything except Unsafe). -/
def stdCaps : List String :=
  ["File", "Network", "Clock", "Env", "Random", "Process", "Console", "Alloc"]

/-- All valid capability names. -/
def validCaps : List String :=
  ["File", "Network", "Clock", "Env", "Random", "Process", "Console", "Alloc", "Unsafe"]

/-- Normalize a CapSet to a flat sorted list of concrete caps + list of cap variables. -/
def CapSet.normalize : CapSet → List String × List String
  | .empty => ([], [])
  | .concrete caps => (caps.mergeSort (· < ·), [])
  | .var name => ([], [name])
  | .union a b =>
    let (ac, av) := a.normalize
    let (bc, bv) := b.normalize
    ((ac ++ bc).mergeSort (· < ·) |>.eraseDups, (av ++ bv).eraseDups)

/-- Get the concrete capabilities from a CapSet (ignoring variables). -/
def CapSet.concreteCaps : CapSet → List String
  | .empty => []
  | .concrete caps => caps
  | .var _ => []
  | .union a b => a.concreteCaps ++ b.concreteCaps

/-- Check if a CapSet is empty (pure). -/
def CapSet.isEmpty : CapSet → Bool
  | .empty => true
  | .concrete caps => caps.isEmpty
  | _ => false

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
  | fn_ (params : List Ty) (capSet : CapSet) (retTy : Ty)  -- fn(T, U) with(C) -> R
  | never     -- bottom type (abort, unreachable)
  | heap (inner : Ty)       -- Heap<T> (pointer to heap-allocated T)
  | heapArray (inner : Ty)  -- HeapArray<T>
  | unknown  -- placeholder for untyped closure params, resolved by checker
  deriving Repr, BEq

inductive CaptureMode where
  | copy    -- value is copied, original stays live
  | move    -- value is moved, original is consumed
  deriving Repr, BEq

inductive BinOp where
  | add | sub | mul | div | mod
  | eq | neq | lt | gt | leq | geq
  | and_ | or_
  | bitand | bitor | bitxor | shl | shr
  deriving Repr, BEq

inductive UnaryOp where
  | neg | not_ | bitnot
  deriving Repr, BEq

structure Param where
  name : String
  ty : Ty
  deriving Repr

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
  | closure (params : List Param) (capSet : CapSet) (retTy : Option Ty) (body : List Stmt)
            (captures : List (String × CaptureMode)) (isLinear : Bool)
  | arrowAccess (obj : Expr) (field : String)   -- p->x
  | allocCall (inner : Expr) (allocExpr : Expr)  -- call() with(Alloc = expr)
  | whileExpr (cond : Expr) (body : List Stmt) (elseBody : List Stmt)  -- while cond { body } else { elseBody }

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
  | while_ (cond : Expr) (body : List Stmt) (label : Option String)
  | forLoop (init : Option Stmt) (cond : Expr) (step : Option Stmt) (body : List Stmt) (label : Option String)
  | fieldAssign (obj : Expr) (field : String) (value : Expr)
  | derefAssign (target : Expr) (value : Expr)  -- *expr = expr
  | arrayIndexAssign (arr : Expr) (index : Expr) (value : Expr)  -- arr[i] = val
  | break_ (value : Option Expr) (label : Option String)  -- break; or break 'label; or break expr;
  | continue_ (label : Option String)                    -- continue; or continue 'label;
  | defer (body : Expr)           -- defer expr;
  | borrowIn (var : String) (ref : String) (region : String) (isMut : Bool) (body : List Stmt)
  | arrowAssign (obj : Expr) (field : String) (value : Expr)  -- p->x = val
end

structure ImportDecl where
  moduleName : String
  symbols : List String
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
  typeBounds : List (String × List String) := []  -- type param bounds
  variants : List EnumVariant
  isPublic : Bool := false
  isCopy : Bool := false
  deriving Repr

structure StructDef where
  name : String
  typeParams : List String := []
  typeBounds : List (String × List String) := []  -- type param bounds: T -> [Trait1, Trait2]
  fields : List StructField
  isPublic : Bool := false
  isUnion : Bool := false
  isCopy : Bool := false
  deriving Repr

structure FnDef where
  name : String
  typeParams : List String := []
  typeBounds : List (String × List String) := []  -- type param bounds: T -> [Trait1, Trait2]
  capParams : List String := []    -- capability variables: cap C, cap D
  params : List Param
  retTy : Ty
  body : List Stmt
  isPublic : Bool := false
  capSet : CapSet := .empty        -- with(File, Network, ...)
  hasBang : Bool := false          -- fn main!() sugar

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
  capSet : CapSet := .empty
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
  capSet : CapSet := .empty        -- capabilities on the impl (used by Destroy in Phase 3)

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

-- ============================================================
-- Free Variable Analysis (used by both Check and Codegen)
-- ============================================================

mutual
partial def collectFreeVarsExpr (e : Expr) (bound : List String) : List String :=
  match e with
  | .ident name => if bound.contains name then [] else [name]
  | .intLit _ | .floatLit _ | .boolLit _ | .strLit _ | .charLit _ => []
  | .binOp _ lhs rhs =>
    collectFreeVarsExpr lhs bound ++ collectFreeVarsExpr rhs bound
  | .unaryOp _ operand => collectFreeVarsExpr operand bound
  | .call fn _typeArgs args =>
    let fnFree := if bound.contains fn then [fn] else []
    fnFree ++ args.flatMap (fun a => collectFreeVarsExpr a bound)
  | .paren inner => collectFreeVarsExpr inner bound
  | .structLit _ _ fields =>
    fields.flatMap (fun (_, e) => collectFreeVarsExpr e bound)
  | .fieldAccess obj _ => collectFreeVarsExpr obj bound
  | .enumLit _ _ _ fields =>
    fields.flatMap (fun (_, e) => collectFreeVarsExpr e bound)
  | .match_ scrutinee arms =>
    collectFreeVarsExpr scrutinee bound ++
    arms.flatMap (fun arm => match arm with
      | .mk _ _ bindings body =>
        let newBound := bound ++ bindings
        collectFreeVarsStmts body newBound
      | .litArm _ body => collectFreeVarsStmts body bound
      | .varArm binding body => collectFreeVarsStmts body (binding :: bound))
  | .borrow inner | .borrowMut inner | .deref inner | .try_ inner =>
    collectFreeVarsExpr inner bound
  | .arrayLit elems => elems.flatMap (fun e => collectFreeVarsExpr e bound)
  | .arrayIndex arr idx =>
    collectFreeVarsExpr arr bound ++ collectFreeVarsExpr idx bound
  | .cast inner _ => collectFreeVarsExpr inner bound
  | .methodCall obj _ _ args =>
    collectFreeVarsExpr obj bound ++ args.flatMap (fun a => collectFreeVarsExpr a bound)
  | .staticMethodCall _ _ _ args =>
    args.flatMap (fun a => collectFreeVarsExpr a bound)
  | .closure params _ _ body _ _ =>
    let closureBound := bound ++ params.map (fun p => p.name)
    collectFreeVarsStmts body closureBound
  | .arrowAccess obj _ => collectFreeVarsExpr obj bound
  | .allocCall inner allocExpr =>
    collectFreeVarsExpr inner bound ++ collectFreeVarsExpr allocExpr bound
  | .whileExpr cond body elseBody =>
    collectFreeVarsExpr cond bound ++
    collectFreeVarsStmts body bound ++
    collectFreeVarsStmts elseBody bound

partial def collectFreeVarsStmts (stmts : List Stmt) (bound : List String) : List String :=
  match stmts with
  | [] => []
  | stmt :: rest =>
    let (freeVars, newBound) := match stmt with
      | .letDecl name _ _ value =>
        (collectFreeVarsExpr value bound, name :: bound)
      | .assign name value =>
        (collectFreeVarsExpr value bound ++ (if bound.contains name then [] else [name]), bound)
      | .return_ (some value) => (collectFreeVarsExpr value bound, bound)
      | .return_ none => ([], bound)
      | .expr e => (collectFreeVarsExpr e bound, bound)
      | .ifElse cond thenBody elseBody =>
        let condFree := collectFreeVarsExpr cond bound
        let thenFree := collectFreeVarsStmts thenBody bound
        let elseFree := match elseBody with
          | some body => collectFreeVarsStmts body bound
          | none => []
        (condFree ++ thenFree ++ elseFree, bound)
      | .while_ cond body _ =>
        (collectFreeVarsExpr cond bound ++ collectFreeVarsStmts body bound, bound)
      | .forLoop init cond step body _ =>
        let initFree := match init with
          | some s => collectFreeVarsStmts [s] bound
          | none => []
        let condFree := collectFreeVarsExpr cond bound
        let stepFree := match step with
          | some s => collectFreeVarsStmts [s] bound
          | none => []
        (initFree ++ condFree ++ stepFree ++ collectFreeVarsStmts body bound, bound)
      | .fieldAssign obj _ value =>
        (collectFreeVarsExpr obj bound ++ collectFreeVarsExpr value bound, bound)
      | .derefAssign target value =>
        (collectFreeVarsExpr target bound ++ collectFreeVarsExpr value bound, bound)
      | .arrayIndexAssign arr idx value =>
        (collectFreeVarsExpr arr bound ++ collectFreeVarsExpr idx bound ++
         collectFreeVarsExpr value bound, bound)
      | .break_ (some e) _ => (collectFreeVarsExpr e bound, bound)
      | .break_ none _ => ([], bound)
      | .continue_ _ => ([], bound)
      | .defer body => (collectFreeVarsExpr body bound, bound)
      | .borrowIn var _ref _region _isMut body =>
        (collectFreeVarsExpr (.ident var) bound ++ collectFreeVarsStmts body bound, bound)
      | .arrowAssign obj _ value =>
        (collectFreeVarsExpr obj bound ++ collectFreeVarsExpr value bound, bound)
    freeVars ++ collectFreeVarsStmts rest newBound
end

def collectFreeVars (stmts : List Stmt) (paramNames : List String) : List String :=
  (collectFreeVarsStmts stmts paramNames).eraseDups

end Concrete
