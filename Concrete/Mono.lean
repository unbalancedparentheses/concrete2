import Concrete.Core

namespace Concrete

/-! ## Mono — Monomorphization pass (Core→Core)

Walks all `CExpr.call` with non-empty `typeArgs`, instantiates concrete
versions of generic functions with type variables substituted, and replaces
call sites with the monomorphized name.

Runs after CoreCanonicalize, before Lower.
-/

-- ============================================================
-- Type substitution
-- ============================================================

/-- Substitute type variables in a type using a mapping.
    Handles both .typeVar and .named (parser sometimes produces .named "T" for type params). -/
private def substTy (typeParams : List String) (mapping : List (String × Ty)) : Ty → Ty
  | .typeVar n => (mapping.lookup n).getD (.typeVar n)
  | .named n => if typeParams.contains n then (mapping.lookup n).getD (.named n) else .named n
  | .ref t => .ref (substTy typeParams mapping t)
  | .refMut t => .refMut (substTy typeParams mapping t)
  | .heap t => .heap (substTy typeParams mapping t)
  | .heapArray t => .heapArray (substTy typeParams mapping t)
  | .array t n => .array (substTy typeParams mapping t) n
  | .generic name args => .generic name (args.map (substTy typeParams mapping))
  | .ptrMut t => .ptrMut (substTy typeParams mapping t)
  | .ptrConst t => .ptrConst (substTy typeParams mapping t)
  | .fn_ ps cs ret => .fn_ (ps.map (substTy typeParams mapping)) cs (substTy typeParams mapping ret)
  | t => t

-- ============================================================
-- Body-level type substitution (substitute types in CExpr/CStmt)
-- ============================================================

mutual
private partial def substExpr (sub : Ty → Ty) : CExpr → CExpr
  | .intLit v ty => .intLit v (sub ty)
  | .floatLit v ty => .floatLit v (sub ty)
  | .boolLit b => .boolLit b
  | .strLit s => .strLit s
  | .charLit c => .charLit c
  | .ident n ty => .ident n (sub ty)
  | .binOp op l r ty => .binOp op (substExpr sub l) (substExpr sub r) (sub ty)
  | .unaryOp op e ty => .unaryOp op (substExpr sub e) (sub ty)
  | .call fn targs args ty =>
    .call fn (targs.map sub) (args.map (substExpr sub)) (sub ty)
  | .structLit n targs fields ty =>
    .structLit n (targs.map sub) (fields.map fun (fn, fe) => (fn, substExpr sub fe)) (sub ty)
  | .fieldAccess obj f ty => .fieldAccess (substExpr sub obj) f (sub ty)
  | .enumLit en v targs fields ty =>
    .enumLit en v (targs.map sub) (fields.map fun (fn, fe) => (fn, substExpr sub fe)) (sub ty)
  | .match_ scrut arms ty =>
    .match_ (substExpr sub scrut) (arms.map (substArm sub)) (sub ty)
  | .borrow inner ty => .borrow (substExpr sub inner) (sub ty)
  | .borrowMut inner ty => .borrowMut (substExpr sub inner) (sub ty)
  | .deref inner ty => .deref (substExpr sub inner) (sub ty)
  | .arrayLit elems ty => .arrayLit (elems.map (substExpr sub)) (sub ty)
  | .arrayIndex arr idx ty => .arrayIndex (substExpr sub arr) (substExpr sub idx) (sub ty)
  | .cast inner t => .cast (substExpr sub inner) (sub t)
  | .fnRef n ty => .fnRef n (sub ty)
  | .try_ inner ty => .try_ (substExpr sub inner) (sub ty)
  | .allocCall inner alloc ty => .allocCall (substExpr sub inner) (substExpr sub alloc) (sub ty)
  | .whileExpr cond body elseBody ty =>
    .whileExpr (substExpr sub cond) (substStmts sub body) (substStmts sub elseBody) (sub ty)

private partial def substArm (sub : Ty → Ty) : CMatchArm → CMatchArm
  | .enumArm en v binds body =>
    .enumArm en v (binds.map fun (n, t) => (n, sub t)) (substStmts sub body)
  | .litArm val body => .litArm (substExpr sub val) (substStmts sub body)
  | .varArm b ty body => .varArm b (sub ty) (substStmts sub body)

private partial def substStmt (sub : Ty → Ty) : CStmt → CStmt
  | .letDecl n m ty val => .letDecl n m (sub ty) (substExpr sub val)
  | .assign n val => .assign n (substExpr sub val)
  | .return_ (some v) ty => .return_ (some (substExpr sub v)) (sub ty)
  | .return_ none ty => .return_ none (sub ty)
  | .expr e => .expr (substExpr sub e)
  | .ifElse c t el =>
    .ifElse (substExpr sub c) (substStmts sub t) (el.map (substStmts sub))
  | .while_ c body lbl step => .while_ (substExpr sub c) (substStmts sub body) lbl (substStmts sub step)
  | .fieldAssign obj f val => .fieldAssign (substExpr sub obj) f (substExpr sub val)
  | .derefAssign target val => .derefAssign (substExpr sub target) (substExpr sub val)
  | .arrayIndexAssign arr idx val =>
    .arrayIndexAssign (substExpr sub arr) (substExpr sub idx) (substExpr sub val)
  | .break_ (some v) lbl => .break_ (some (substExpr sub v)) lbl
  | .break_ none lbl => .break_ none lbl
  | .continue_ lbl => .continue_ lbl
  | .defer body => .defer (substExpr sub body)
  | .borrowIn v r reg isMut ty body =>
    .borrowIn v r reg isMut (sub ty) (substStmts sub body)

private partial def substStmts (sub : Ty → Ty) : List CStmt → List CStmt :=
  List.map (substStmt sub)
end

-- ============================================================
-- Monomorphized name computation
-- ============================================================

/-- Produce a human-readable type suffix for mono name. -/
private def tyToSuffix : Ty → String
  | .int => "Int"
  | .uint => "Uint"
  | .i8 => "i8"
  | .i16 => "i16"
  | .i32 => "i32"
  | .u8 => "u8"
  | .u16 => "u16"
  | .u32 => "u32"
  | .bool => "Bool"
  | .float64 => "Float64"
  | .float32 => "Float32"
  | .char => "Char"
  | .string => "String"
  | .named n => n
  | .generic n _ => n
  | .heap t => "Heap_" ++ tyToSuffix t
  | .heapArray t => "HeapArray_" ++ tyToSuffix t
  | _ => "unknown"

/-- Compute monomorphized function name: `fnName_for_T1_T2`. -/
private def monoNameFor (fnName : String) (typeArgs : List Ty) : String :=
  fnName ++ "_for_" ++ "_".intercalate (typeArgs.map tyToSuffix)

-- ============================================================
-- Monomorphization state
-- ============================================================

structure MonoState where
  /-- All original function definitions (for lookup). -/
  allFns : List CFnDef
  /-- Queue of monomorphized functions to process. -/
  queue : List (String × CFnDef) := []
  /-- Already-generated mono names (avoid duplicates). -/
  generated : List String := []

abbrev MonoM := ExceptT String (StateM MonoState)

private def lookupFn (name : String) : MonoM (Option CFnDef) := do
  let st ← get
  return st.allFns.find? fun f => f.name == name

private def enqueueMono (monoName : String) (monoFn : CFnDef) : MonoM Unit := do
  let st ← get
  if st.generated.contains monoName then return
  set { st with
    queue := st.queue ++ [(monoName, monoFn)]
    generated := monoName :: st.generated }

-- ============================================================
-- Core expression/statement rewriting
-- ============================================================

mutual
partial def monoExpr (e : CExpr) : MonoM CExpr := do
  match e with
  | .call fn typeArgs args ty =>
    let args' ← args.mapM monoExpr
    if typeArgs.isEmpty then
      return .call fn [] args' ty
    -- Look up the generic function
    let fnDef? ← lookupFn fn
    match fnDef? with
    | none => return .call fn typeArgs args' ty  -- extern or unknown, leave as-is
    | some fnDef =>
      if fnDef.typeParams.isEmpty then
        return .call fn typeArgs args' ty  -- not actually generic
      let name := monoNameFor fn typeArgs
      let mapping := fnDef.typeParams.zip typeArgs
      let sub := substTy fnDef.typeParams mapping
      let monoFn : CFnDef := {
        name := name
        typeParams := []
        params := fnDef.params.map fun (n, t) => (n, sub t)
        retTy := sub fnDef.retTy
        body := substStmts sub fnDef.body
        isPublic := false
        capSet := fnDef.capSet
      }
      enqueueMono name monoFn
      return .call name [] args' (sub ty)
  | .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | .charLit _ => return e
  | .ident n ty => return .ident n ty
  | .binOp op l r ty => return .binOp op (← monoExpr l) (← monoExpr r) ty
  | .unaryOp op inner ty => return .unaryOp op (← monoExpr inner) ty
  | .structLit n targs fields ty =>
    let fields' ← fields.mapM fun (n, e) => return (n, ← monoExpr e)
    return .structLit n targs fields' ty
  | .fieldAccess obj f ty => return .fieldAccess (← monoExpr obj) f ty
  | .enumLit en v targs fields ty =>
    let fields' ← fields.mapM fun (n, e) => return (n, ← monoExpr e)
    return .enumLit en v targs fields' ty
  | .match_ scrut arms ty =>
    let scrut' ← monoExpr scrut
    let arms' ← arms.mapM monoArm
    return .match_ scrut' arms' ty
  | .borrow inner ty => return .borrow (← monoExpr inner) ty
  | .borrowMut inner ty => return .borrowMut (← monoExpr inner) ty
  | .deref inner ty => return .deref (← monoExpr inner) ty
  | .arrayLit elems ty =>
    let elems' ← elems.mapM monoExpr
    return .arrayLit elems' ty
  | .arrayIndex arr idx ty => return .arrayIndex (← monoExpr arr) (← monoExpr idx) ty
  | .cast inner t => return .cast (← monoExpr inner) t
  | .fnRef n ty => return .fnRef n ty
  | .try_ inner ty => return .try_ (← monoExpr inner) ty
  | .allocCall inner alloc ty => return .allocCall (← monoExpr inner) (← monoExpr alloc) ty
  | .whileExpr cond body elseBody ty =>
    return .whileExpr (← monoExpr cond) (← monoStmts body) (← monoStmts elseBody) ty

partial def monoArm (arm : CMatchArm) : MonoM CMatchArm := do
  match arm with
  | .enumArm en v binds body => return .enumArm en v binds (← monoStmts body)
  | .litArm val body => return .litArm (← monoExpr val) (← monoStmts body)
  | .varArm b ty body => return .varArm b ty (← monoStmts body)

partial def monoStmt (s : CStmt) : MonoM CStmt := do
  match s with
  | .letDecl n m ty val => return .letDecl n m ty (← monoExpr val)
  | .assign n val => return .assign n (← monoExpr val)
  | .return_ (some v) ty => return .return_ (some (← monoExpr v)) ty
  | .return_ none ty => return .return_ none ty
  | .expr e => return .expr (← monoExpr e)
  | .ifElse c t el =>
    let el' ← match el with
      | none => pure none
      | some stmts => do pure (some (← monoStmts stmts))
    return .ifElse (← monoExpr c) (← monoStmts t) el'
  | .while_ c body lbl step => return .while_ (← monoExpr c) (← monoStmts body) lbl (← monoStmts step)
  | .fieldAssign obj f val => return .fieldAssign (← monoExpr obj) f (← monoExpr val)
  | .derefAssign target val => return .derefAssign (← monoExpr target) (← monoExpr val)
  | .arrayIndexAssign arr idx val =>
    return .arrayIndexAssign (← monoExpr arr) (← monoExpr idx) (← monoExpr val)
  | .break_ (some v) lbl => return .break_ (some (← monoExpr v)) lbl
  | .break_ none lbl => return .break_ none lbl
  | .continue_ lbl => return .continue_ lbl
  | .defer body => return .defer (← monoExpr body)
  | .borrowIn v r reg isMut ty body =>
    return .borrowIn v r reg isMut ty (← monoStmts body)

partial def monoStmts (stmts : List CStmt) : MonoM (List CStmt) :=
  stmts.mapM monoStmt
end

-- ============================================================
-- Function and module monomorphization
-- ============================================================

private def monoFn (f : CFnDef) : MonoM CFnDef := do
  let body' ← monoStmts f.body
  return { f with body := body' }

/-- Process the mono queue until empty. Each mono'd function may enqueue more. -/
private partial def drainQueue : MonoM (List CFnDef) := do
  let st ← get
  if st.queue.isEmpty then return []
  -- Take the current queue and clear it
  let batch := st.queue
  set { st with queue := [] }
  let mut result : List CFnDef := []
  for (_, fn) in batch do
    let fn' ← monoFn fn
    result := result ++ [fn']
  -- Recurse to handle any new entries added during processing
  let rest ← drainQueue
  return result ++ rest

def monoModule (m : CModule) : MonoM CModule := do
  -- Mono all existing functions
  let fns' ← m.functions.mapM monoFn
  -- Drain mono queue to get all generated specializations
  let monoFns ← drainQueue
  return { m with functions := fns' ++ monoFns }

def monoProgram (modules : List CModule) : Except String (List CModule) :=
  let allFns := modules.foldl (fun acc m => acc ++ m.functions) []
  let initState : MonoState := { allFns := allFns }
  let (result, _) := (modules.mapM monoModule).run initState |>.run
  match result with
  | .ok ms => .ok ms
  | .error e => .error e

end Concrete
