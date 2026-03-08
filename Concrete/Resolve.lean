import Concrete.AST
import Concrete.Diagnostic

namespace Concrete

/-! ## Resolve — name resolution pass

Runs after Parse, before Check. Builds symbol tables and validates that all
referenced names (variables, functions, types) are defined.

Approach: side-table symbol resolution — AST types are not modified.
-/

-- ============================================================
-- Symbol tables
-- ============================================================

inductive SymKind where
  | fn (params : List Param) (retTy : Ty)
  | struct (def_ : StructDef)
  | enum (def_ : EnumDef)
  | trait (def_ : TraitDef)
  | var (ty : Option Ty) (mutable : Bool)
  | typeAlias (target : Ty)
  | externFn (params : List Param) (retTy : Ty)
  | const (ty : Ty)
  | implMethod (typeName : String) (params : List Param) (retTy : Ty)

structure Scope where
  symbols : List (String × SymKind)

structure ResolvedModule where
  module : Module
  globalScope : Scope

-- ============================================================
-- Resolution state
-- ============================================================

structure ResolveCtx where
  globalScope : Scope
  localScopes : List (List (String × SymKind))  -- stack of local scopes
  errors : Diagnostics
  /-- Known type names (structs, enums, type aliases, traits, type params). -/
  knownTypes : List String

private def addError (ctx : ResolveCtx) (msg : String) : ResolveCtx :=
  { ctx with errors := ctx.errors ++ [{ severity := .error, message := msg, pass := "resolve", span := none, hint := none }] }

private def pushScope (ctx : ResolveCtx) : ResolveCtx :=
  { ctx with localScopes := [] :: ctx.localScopes }

private def popScope (ctx : ResolveCtx) : ResolveCtx :=
  { ctx with localScopes := ctx.localScopes.drop 1 }

private def addLocal (ctx : ResolveCtx) (name : String) (kind : SymKind) : ResolveCtx :=
  match ctx.localScopes with
  | scope :: rest => { ctx with localScopes := ((name, kind) :: scope) :: rest }
  | [] => ctx  -- should not happen

private def lookupName (ctx : ResolveCtx) (name : String) : Bool :=
  -- Check local scopes (innermost first)
  ctx.localScopes.any (fun scope => scope.any fun (n, _) => n == name) ||
  -- Check global scope
  ctx.globalScope.symbols.any fun (n, _) => n == name

private def isKnownType (ctx : ResolveCtx) (name : String) : Bool :=
  ctx.knownTypes.contains name

-- ============================================================
-- Builtin names
-- ============================================================

/-- Built-in function names that don't require explicit definitions. -/
private def builtinFns : List String :=
  [ "print", "println", "to_string", "abort",
    "alloc", "free", "deref", "deref_mut",
    "drop_string", "string_len", "string_concat", "string_eq",
    "vec_new", "vec_push", "vec_get", "vec_pop", "vec_free", "vec_len",
    "Vec_new", "Vec_push", "Vec_get", "Vec_pop", "Vec_free", "Vec_len",
    "map_new", "map_insert", "map_get", "map_contains", "map_remove", "map_free", "map_len",
    "HashMap_new", "HashMap_insert", "HashMap_get", "HashMap_contains",
    "HashMap_remove", "HashMap_free", "HashMap_len",
    "String_len", "String_concat", "String_eq",
    "HeapArray_new", "HeapArray_get", "HeapArray_set", "HeapArray_len", "HeapArray_free",
    "heap_array_new", "heap_array_get", "heap_array_set", "heap_array_len", "heap_array_free",
    "read_file", "write_file", "append_file",
    "tcp_connect", "tcp_listen", "tcp_accept", "tcp_read", "tcp_write", "tcp_close",
    "clock_now", "env_get", "env_set", "random_int", "random_float",
    "process_exec", "process_exit",
    "char_to_int", "int_to_char", "string_from_char",
    "sqrt", "sin", "cos", "tan", "pow", "log", "exp", "floor", "ceil", "abs",
    "int_to_string", "string_to_int", "string_length", "string_char_at",
    "string_contains", "string_slice", "string_trim",
    "print_int", "print_bool", "print_char",
    "socket_close", "add" ]

/-- Built-in type names. -/
private def builtinTypes : List String :=
  [ "Int", "Uint", "Bool", "String", "Float64", "Float32", "Char",
    "i8", "i16", "i32", "u8", "u16", "u32",
    "Heap", "HeapArray", "Vec", "HashMap", "Option", "Result" ]

-- ============================================================
-- Walk expressions and statements
-- ============================================================

/-- Check that a type name is known. -/
private def checkTyName (ctx : ResolveCtx) (ty : Ty) : ResolveCtx :=
  match ty with
  | .named name =>
    if isKnownType ctx name then ctx
    else addError ctx s!"unknown type '{name}'"
  | .generic name _ =>
    if isKnownType ctx name then ctx
    else addError ctx s!"unknown type '{name}'"
  | _ => ctx

mutual
/-- Walk an expression, checking all name references. -/
partial def resolveExpr (ctx : ResolveCtx) (e : Expr) : ResolveCtx :=
  match e with
  | .ident name =>
    -- Only flag identifiers that aren't in any scope and aren't known functions
    if lookupName ctx name || builtinFns.contains name then ctx
    else addError ctx s!"undeclared variable '{name}'"
  | .intLit _ | .floatLit _ | .boolLit _ | .strLit _ | .charLit _ => ctx
  | .binOp _ lhs rhs => resolveExpr (resolveExpr ctx lhs) rhs
  | .unaryOp _ operand => resolveExpr ctx operand
  | .call _fn _typeArgs args =>
    -- Don't check function names — Check/Elab handle full resolution
    -- including impl method desugaring, cross-module imports, extern fns.
    args.foldl resolveExpr ctx
  | .paren inner => resolveExpr ctx inner
  | .structLit _name _typeArgs fields =>
    -- Don't check struct name — Check handles type lookup
    fields.foldl (fun ctx (_, e) => resolveExpr ctx e) ctx
  | .fieldAccess obj _ => resolveExpr ctx obj
  | .enumLit _enumName _variant _typeArgs fields =>
    -- Don't check enum name — Check handles type lookup
    fields.foldl (fun ctx (_, e) => resolveExpr ctx e) ctx
  | .match_ scrutinee arms =>
    let ctx := resolveExpr ctx scrutinee
    arms.foldl (fun ctx arm =>
      match arm with
      | .mk _ _ bindings body =>
        let ctx := pushScope ctx
        let ctx := bindings.foldl (fun ctx b => addLocal ctx b (.var none false)) ctx
        let ctx := resolveStmts ctx body
        popScope ctx
      | .litArm val body =>
        let ctx := resolveExpr ctx val
        resolveStmts ctx body
      | .varArm binding body =>
        let ctx := pushScope ctx
        let ctx := addLocal ctx binding (.var none false)
        let ctx := resolveStmts ctx body
        popScope ctx
    ) ctx
  | .borrow inner | .borrowMut inner | .deref inner | .try_ inner =>
    resolveExpr ctx inner
  | .arrayLit elems => elems.foldl resolveExpr ctx
  | .arrayIndex arr idx => resolveExpr (resolveExpr ctx arr) idx
  | .cast inner _ => resolveExpr ctx inner
  | .methodCall obj _ _ args =>
    let ctx := resolveExpr ctx obj
    args.foldl resolveExpr ctx
  | .staticMethodCall _ _ _ args =>
    args.foldl resolveExpr ctx
  | .fnRef _name =>
    -- Don't check function name — Check handles resolution
    ctx
  | .arrowAccess obj _ => resolveExpr ctx obj
  | .allocCall inner allocExpr =>
    resolveExpr (resolveExpr ctx inner) allocExpr
  | .whileExpr cond body elseBody =>
    let ctx := resolveExpr ctx cond
    let ctx := resolveStmts ctx body
    resolveStmts ctx elseBody

/-- Walk a list of statements, updating the context with let bindings. -/
partial def resolveStmts (ctx : ResolveCtx) (stmts : List Stmt) : ResolveCtx :=
  stmts.foldl resolveStmt ctx

/-- Walk a single statement. -/
partial def resolveStmt (ctx : ResolveCtx) (stmt : Stmt) : ResolveCtx :=
  match stmt with
  | .letDecl name _mutable ty value =>
    let ctx := resolveExpr ctx value
    let ctx := match ty with
      | some t => checkTyName ctx t
      | none => ctx
    addLocal ctx name (.var ty _mutable)
  | .assign name value =>
    let ctx := if lookupName ctx name then ctx
               else addError ctx s!"undeclared variable '{name}'"
    resolveExpr ctx value
  | .return_ (some e) => resolveExpr ctx e
  | .return_ none => ctx
  | .expr e => resolveExpr ctx e
  | .ifElse cond then_ else_ =>
    let ctx := resolveExpr ctx cond
    let ctx := pushScope ctx
    let ctx := resolveStmts ctx then_
    let ctx := popScope ctx
    match else_ with
    | some elseStmts =>
      let ctx := pushScope ctx
      let ctx := resolveStmts ctx elseStmts
      popScope ctx
    | none => ctx
  | .while_ cond body _ =>
    let ctx := resolveExpr ctx cond
    let ctx := pushScope ctx
    let ctx := resolveStmts ctx body
    popScope ctx
  | .forLoop init cond step body _ =>
    let ctx := pushScope ctx
    let ctx := match init with
      | some s => resolveStmt ctx s
      | none => ctx
    let ctx := resolveExpr ctx cond
    let ctx := match step with
      | some s => resolveStmt ctx s
      | none => ctx
    let ctx := resolveStmts ctx body
    popScope ctx
  | .fieldAssign obj _ value =>
    resolveExpr (resolveExpr ctx obj) value
  | .derefAssign target value =>
    resolveExpr (resolveExpr ctx target) value
  | .arrayIndexAssign arr idx value =>
    resolveExpr (resolveExpr (resolveExpr ctx arr) idx) value
  | .break_ (some e) _ => resolveExpr ctx e
  | .break_ none _ => ctx
  | .continue_ _ => ctx
  | .defer body => resolveExpr ctx body
  | .borrowIn var ref _region _isMut body =>
    let ctx := addLocal ctx var (.var none false)
    let ctx := addLocal ctx ref (.var none false)
    resolveStmts ctx body
  | .arrowAssign obj _ value =>
    resolveExpr (resolveExpr ctx obj) value
end

-- ============================================================
-- Build global scope from a module
-- ============================================================

/-- Register all top-level definitions from a module into a scope. -/
private def buildGlobalScope (m : Module) : Scope × List String :=
  let symbols : List (String × SymKind) := []
  let types : List String := builtinTypes
  -- Functions
  let symbols := symbols ++ m.functions.map fun f => (f.name, SymKind.fn f.params f.retTy)
  -- Structs
  let symbols := symbols ++ m.structs.map fun s => (s.name, SymKind.struct s)
  let types := types ++ m.structs.map (·.name)
  -- Enums
  let symbols := symbols ++ m.enums.map fun e => (e.name, SymKind.enum e)
  let symbols := symbols ++ m.enums.foldl (fun acc e =>
    acc ++ e.variants.map fun v => (s!"{e.name}::{v.name}", SymKind.fn [] .unit)) []
  let types := types ++ m.enums.map (·.name)
  -- Traits
  let symbols := symbols ++ m.traits.map fun t => (t.name, SymKind.trait t)
  let types := types ++ m.traits.map (·.name)
  -- Constants
  let symbols := symbols ++ m.constants.map fun c => (c.name, SymKind.const c.ty)
  -- Type aliases
  let symbols := symbols ++ m.typeAliases.map fun ta => (ta.name, SymKind.typeAlias ta.targetTy)
  let types := types ++ m.typeAliases.map (·.name)
  -- Extern functions
  let symbols := symbols ++ m.externFns.map fun ef => (ef.name, SymKind.externFn ef.params ef.retTy)
  -- Impl block methods
  let symbols := symbols ++ m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.foldl (fun acc method =>
      acc ++ [(s!"{ib.typeName}_{method.name}", SymKind.implMethod ib.typeName method.params method.retTy),
              (method.name, SymKind.implMethod ib.typeName method.params method.retTy)]
    ) []) []
  -- Trait impl methods
  let symbols := symbols ++ m.traitImpls.foldl (fun acc ti =>
    acc ++ ti.methods.foldl (fun acc method =>
      acc ++ [(s!"{ti.typeName}_{method.name}", SymKind.implMethod ti.typeName method.params method.retTy),
              (method.name, SymKind.implMethod ti.typeName method.params method.retTy)]
    ) []) []
  ({ symbols := symbols }, types)

-- ============================================================
-- Resolve a module
-- ============================================================

/-- Resolve a single function body. -/
private def resolveFnBody (globalScope : Scope) (knownTypes : List String) (f : FnDef) : Diagnostics :=
  let ctx : ResolveCtx := {
    globalScope := globalScope
    localScopes := [[]]
    errors := []
    knownTypes := knownTypes ++ f.typeParams
  }
  let ctx := f.params.foldl (fun ctx p => addLocal ctx p.name (.var (some p.ty) false)) ctx
  let ctx := resolveStmts ctx f.body
  ctx.errors

/-- Resolve all names in a module's function bodies. -/
private def resolveModule (m : Module) (globalScope : Scope) (knownTypes : List String) : ResolvedModule × Diagnostics :=
  -- Check top-level functions
  let fnErrors := m.functions.foldl (fun acc f =>
    acc ++ resolveFnBody globalScope knownTypes f) []
  -- Check impl block methods
  let implErrors := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.foldl (fun acc method =>
      acc ++ resolveFnBody globalScope knownTypes method) []) []
  -- Check trait impl methods
  let traitImplErrors := m.traitImpls.foldl (fun acc ti =>
    acc ++ ti.methods.foldl (fun acc method =>
      acc ++ resolveFnBody globalScope knownTypes method) []) []
  let allErrors := fnErrors ++ implErrors ++ traitImplErrors
  ({ module := m, globalScope := globalScope }, allErrors)

-- ============================================================
-- Entry point
-- ============================================================

/-- Resolve all modules. Returns resolved modules or diagnostics on failure. -/
def resolveProgram (modules : List Module) : Except String (List ResolvedModule) :=
  -- Build combined global scope from all modules
  let (combinedScope, combinedTypes) := modules.foldl (fun (scope, types) m =>
    let (mScope, mTypes) := buildGlobalScope m
    ({ symbols := scope.symbols ++ mScope.symbols }, types ++ mTypes)
  ) ({ symbols := [] : Scope }, ([] : List String))
  -- Resolve each module
  let (resolved, allErrors) := modules.foldl (fun (acc, errs) m =>
    let (rm, mErrs) := resolveModule m combinedScope combinedTypes
    (acc ++ [rm], errs ++ mErrs)
  ) ([], [])
  if hasErrors allErrors then
    .error (renderDiagnostics allErrors)
  else
    .ok resolved

end Concrete
