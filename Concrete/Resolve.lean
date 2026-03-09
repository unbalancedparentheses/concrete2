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
  /-- Current impl type name, for Self resolution. -/
  currentImplType : Option String := none
  /-- Trait name → list of method names. -/
  traitMethods : List (String × List String) := []
  /-- (typeName, traitName) pairs from trait impl blocks. -/
  traitImpls : List (String × String) := []

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

private def lookupSymKind (ctx : ResolveCtx) (name : String) : Option SymKind :=
  (ctx.localScopes.findSome? (fun scope => scope.find? (fun (n, _) => n == name) |>.map (·.2)))
  <|> (ctx.globalScope.symbols.find? (fun (n, _) => n == name) |>.map (·.2))

private def isKnownType (ctx : ResolveCtx) (name : String) : Bool :=
  ctx.knownTypes.contains name

-- ============================================================
-- Builtin names
-- ============================================================

/-- Built-in function names that don't require explicit definitions. -/
private def builtinFns : List String :=
  [ "print", "println", "to_string", "abort", "destroy",
    "alloc", "free", "deref", "deref_mut",
    "drop_string", "string_len", "string_concat", "string_eq",
    "vec_new", "vec_push", "vec_get", "vec_set", "vec_pop", "vec_free", "vec_len",
    "Vec_new", "Vec_push", "Vec_get", "Vec_set", "Vec_pop", "Vec_free", "Vec_len",
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
    "socket_close", "add",
    -- Additional builtins registered by Check
    "print_string", "eprint_string", "read_line",
    "bool_to_string", "float_to_string",
    "get_env", "get_args", "exit_process",
    "socket_send", "socket_recv" ]

/-- Built-in type names. -/
private def builtinTypes : List String :=
  [ "Int", "Uint", "Bool", "String", "Float64", "Float32", "Char",
    "i8", "i16", "i32", "u8", "u16", "u32",
    "Heap", "HeapArray", "Vec", "HashMap", "Option", "Result" ]

-- ============================================================
-- Deep type validation
-- ============================================================

/-- Recursively check that all type names in a Ty are known. -/
private def checkTyDeep (ctx : ResolveCtx) (ty : Ty) : ResolveCtx :=
  match ty with
  | .named name =>
    if name == "Self" then
      match ctx.currentImplType with
      | some _ => ctx
      | none => addError ctx s!"Self can only be used inside impl blocks"
    else if isKnownType ctx name then ctx
    else addError ctx s!"unknown type '{name}'"
  | .generic name args =>
    let ctx := if isKnownType ctx name then ctx
               else addError ctx s!"unknown type '{name}'"
    args.foldl checkTyDeep ctx
  | .ref inner | .refMut inner | .ptrMut inner | .ptrConst inner
  | .heap inner | .heapArray inner => checkTyDeep ctx inner
  | .array elem _ => checkTyDeep ctx elem
  | .fn_ params _capSet retTy =>
    let ctx := params.foldl checkTyDeep ctx
    checkTyDeep ctx retTy
  | _ => ctx

-- ============================================================
-- Walk expressions and statements
-- ============================================================

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
  | .call fn _typeArgs args =>
    let ctx := if lookupName ctx fn || builtinFns.contains fn then ctx
               else addError ctx s!"unknown function '{fn}'"
    args.foldl resolveExpr ctx
  | .paren inner => resolveExpr ctx inner
  | .structLit name _typeArgs fields =>
    let ctx := if isKnownType ctx name then ctx
               else addError ctx s!"unknown struct type '{name}'"
    fields.foldl (fun ctx (_, e) => resolveExpr ctx e) ctx
  | .fieldAccess obj _ => resolveExpr ctx obj
  | .enumLit enumName variant _typeArgs fields =>
    let ctx := match lookupSymKind ctx enumName with
      | some (.enum def_) =>
        if def_.variants.any (fun v => v.name == variant) then ctx
        else addError ctx s!"unknown variant '{variant}' in enum '{enumName}'"
      | some _ => addError ctx s!"'{enumName}' is not an enum"
      | none => if isKnownType ctx enumName then ctx
                else addError ctx s!"unknown enum '{enumName}'"
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
    -- Keep skipping method name validation (needs type info to resolve receiver)
    let ctx := resolveExpr ctx obj
    args.foldl resolveExpr ctx
  | .staticMethodCall typeName method _ args =>
    let mangledName := s!"{typeName}_{method}"
    let ctx := if lookupName ctx mangledName then ctx
               else addError ctx s!"unknown static method '{typeName}::{method}'"
    args.foldl resolveExpr ctx
  | .fnRef name =>
    if lookupName ctx name || builtinFns.contains name then ctx
    else addError ctx s!"unknown function reference '{name}'"
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
      | some t => checkTyDeep ctx t
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
  -- Impl block methods (mangled name only: TypeName_methodName)
  let symbols := symbols ++ m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun method =>
      (s!"{ib.typeName}_{method.name}", SymKind.implMethod ib.typeName method.params method.retTy)
    ) []
  -- Trait impl methods (mangled name only: TypeName_methodName)
  let symbols := symbols ++ m.traitImpls.foldl (fun acc ti =>
    acc ++ ti.methods.map fun method =>
      (s!"{ti.typeName}_{method.name}", SymKind.implMethod ti.typeName method.params method.retTy)
    ) []
  -- Submodule definitions (mangled as submodName_fnName)
  let symbols := symbols ++ m.submodules.foldl (fun acc sub =>
    acc
    ++ (sub.functions.map fun f => (s!"{sub.name}_{f.name}", SymKind.fn f.params f.retTy))
    ++ (sub.structs.map fun s => (s.name, SymKind.struct s))
    ++ (sub.enums.map fun e => (e.name, SymKind.enum e))
    ++ (sub.externFns.map fun ef => (ef.name, SymKind.externFn ef.params ef.retTy))
    ++ (sub.constants.map fun c => (c.name, SymKind.const c.ty))
    ++ (sub.implBlocks.foldl (fun acc2 ib =>
      acc2 ++ ib.methods.map fun method =>
        (s!"{ib.typeName}_{method.name}", SymKind.implMethod ib.typeName method.params method.retTy)
    ) [])
    ++ (sub.traitImpls.foldl (fun acc2 ti =>
      acc2 ++ ti.methods.map fun method =>
        (s!"{ti.typeName}_{method.name}", SymKind.implMethod ti.typeName method.params method.retTy)
    ) [])
  ) []
  let types := types ++ m.submodules.foldl (fun acc sub =>
    acc
    ++ (sub.structs.map (·.name))
    ++ (sub.enums.map (·.name))
    ++ (sub.typeAliases.map (·.name))
    ++ (sub.traits.map (·.name))
  ) []
  ({ symbols := symbols }, types)

-- ============================================================
-- Trait impl validation
-- ============================================================

/-- Built-in trait names (Destroy is the only one). -/
private def builtinTraits : List String := ["Destroy"]

/-- Check that trait impls reference known traits and provide all required methods. -/
private def checkTraitImpls (ctx : ResolveCtx) (m : Module) : ResolveCtx :=
  m.traitImpls.foldl (fun ctx ti =>
    match ctx.traitMethods.find? (fun (n, _) => n == ti.traitName) with
    | none =>
      if builtinTraits.contains ti.traitName then ctx
      else addError ctx s!"impl references unknown trait '{ti.traitName}'"
    | some (_, expectedMethods) =>
      let providedMethods := ti.methods.map (·.name)
      expectedMethods.foldl (fun ctx methodName =>
        if providedMethods.contains methodName then ctx
        else addError ctx s!"impl {ti.traitName} for {ti.typeName}: missing method '{methodName}'"
      ) ctx
  ) ctx

-- ============================================================
-- Resolve a module
-- ============================================================

/-- Resolve a single function body. -/
private def resolveFnBody (globalScope : Scope) (knownTypes : List String) (f : FnDef)
    (implType : Option String := none)
    (traitMethods : List (String × List String) := [])
    (traitImpls : List (String × String) := []) : Diagnostics :=
  let ctx : ResolveCtx := {
    globalScope := globalScope
    localScopes := [[]]
    errors := []
    knownTypes := knownTypes ++ f.typeParams
    currentImplType := implType
    traitMethods := traitMethods
    traitImpls := traitImpls
  }
  -- Validate parameter types and add params to scope
  let ctx := f.params.foldl (fun ctx p =>
    let ctx := addLocal ctx p.name (.var (some p.ty) false)
    checkTyDeep ctx p.ty) ctx
  -- Validate return type
  let ctx := checkTyDeep ctx f.retTy
  -- Walk body
  let ctx := resolveStmts ctx f.body
  ctx.errors

/-- Resolve all names in a module's function bodies. -/
private def resolveModule (m : Module) (globalScope : Scope) (knownTypes : List String)
    (traitMethods : List (String × List String))
    (traitImpls_ : List (String × String)) : ResolvedModule × Diagnostics :=
  -- Check top-level functions
  let fnErrors := m.functions.foldl (fun acc f =>
    acc ++ resolveFnBody globalScope knownTypes f none traitMethods traitImpls_) []
  -- Check impl block methods (with Self)
  let implErrors := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.foldl (fun acc method =>
      acc ++ resolveFnBody globalScope (knownTypes ++ ib.typeParams) method (some ib.typeName) traitMethods traitImpls_) []) []
  -- Check trait impl methods (with Self)
  let traitImplErrors := m.traitImpls.foldl (fun acc ti =>
    acc ++ ti.methods.foldl (fun acc method =>
      acc ++ resolveFnBody globalScope (knownTypes ++ ti.typeParams) method (some ti.typeName) traitMethods traitImpls_) []) []
  -- Check trait impls completeness
  let traitCtx : ResolveCtx := {
    globalScope := globalScope, localScopes := [[]], errors := [],
    knownTypes := knownTypes, traitMethods := traitMethods, traitImpls := traitImpls_
  }
  let traitCtx := checkTraitImpls traitCtx m
  let allErrors := fnErrors ++ implErrors ++ traitImplErrors ++ traitCtx.errors
  ({ module := m, globalScope := globalScope }, allErrors)

-- ============================================================
-- Entry point
-- ============================================================

/-- Resolve all modules. Returns resolved modules or diagnostics on failure. -/
def resolveProgram (modules : List Module) : Except Diagnostics (List ResolvedModule) :=
  -- Build combined global scope from all modules
  let (combinedScope, combinedTypes) := modules.foldl (fun (scope, types) m =>
    let (mScope, mTypes) := buildGlobalScope m
    ({ symbols := scope.symbols ++ mScope.symbols }, types ++ mTypes)
  ) ({ symbols := [] : Scope }, ([] : List String))
  -- Collect trait methods and trait impls from all modules
  let traitMethods := modules.foldl (fun acc m =>
    acc ++ m.traits.map fun t => (t.name, t.methods.map (·.name))) []
  let traitImpls_ := modules.foldl (fun acc m =>
    acc ++ m.traitImpls.map fun ti => (ti.typeName, ti.traitName)) []
  -- Build per-module export tables (public symbols only)
  let exportTable := modules.map fun m =>
    let pubFns := m.functions.filter (·.isPublic) |>.map (·.name)
    let pubStructs := m.structs.filter (·.isPublic) |>.map (·.name)
    let pubEnums := m.enums.filter (·.isPublic) |>.map (·.name)
    let pubTraits := m.traits.filter (·.isPublic) |>.map (·.name)
    let pubExterns := m.externFns.filter (·.isPublic) |>.map (·.name)
    let pubConstants := m.constants.filter (·.isPublic) |>.map (·.name)
    let pubAliases := m.typeAliases.filter (·.isPublic) |>.map (·.name)
    -- Include impl method names for public types
    let pubImplMethods := m.implBlocks.foldl (fun acc ib =>
      acc ++ ib.methods.map (·.name)) []
    let pubTraitImplMethods := m.traitImpls.foldl (fun acc ti =>
      acc ++ ti.methods.map (·.name)) []
    (m.name, pubFns ++ pubStructs ++ pubEnums ++ pubTraits ++ pubExterns
             ++ pubConstants ++ pubAliases ++ pubImplMethods ++ pubTraitImplMethods)
  -- Also add submodule export entries
  let subExportTable := modules.foldl (fun acc m =>
    acc ++ m.submodules.map fun sub =>
      let pubFns := sub.functions.filter (·.isPublic) |>.map (·.name)
      let pubStructs := sub.structs.filter (·.isPublic) |>.map (·.name)
      let pubEnums := sub.enums.filter (·.isPublic) |>.map (·.name)
      let pubTraits := sub.traits.filter (·.isPublic) |>.map (·.name)
      let pubExterns := sub.externFns.filter (·.isPublic) |>.map (·.name)
      (sub.name, pubFns ++ pubStructs ++ pubEnums ++ pubTraits ++ pubExterns)
  ) []
  let fullExportTable := exportTable ++ subExportTable
  -- Validate imports
  let importErrors := modules.foldl (fun errs m =>
    m.imports.foldl (fun errs imp =>
      match fullExportTable.find? (fun (n, _) => n == imp.moduleName) with
      | none => errs ++ [{ severity := .error, message := s!"unknown module '{imp.moduleName}'", pass := "resolve", span := none, hint := none }]
      | some (_, pubNames) =>
        imp.symbols.foldl (fun errs sym =>
          if pubNames.contains sym then errs
          else errs ++ [{ severity := .error, message := s!"'{sym}' is not public in module '{imp.moduleName}'", pass := "resolve", span := none, hint := none }]
        ) errs
    ) errs
  ) []
  -- Resolve each module
  let (resolved, allErrors) := modules.foldl (fun (acc, errs) m =>
    let (rm, mErrs) := resolveModule m combinedScope combinedTypes traitMethods traitImpls_
    (acc ++ [rm], errs ++ mErrs)
  ) ([], [])
  let allErrors := importErrors ++ allErrors
  if hasErrors allErrors then
    .error allErrors
  else
    .ok resolved

end Concrete
