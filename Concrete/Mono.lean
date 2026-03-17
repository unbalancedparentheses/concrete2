import Concrete.Core
import Concrete.Shared

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
  | .ifExpr cond then_ else_ ty =>
    .ifExpr (substExpr sub cond) (substStmts sub then_) (substStmts sub else_) (sub ty)

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
-- Rewrite trait-method call names after type substitution
-- ============================================================

-- Given a mapping from type-parameter names to concrete types, rewrite
-- function names like "T_method" to "Point_method" in all call nodes.
-- This is needed because the elaborator emits `TypeVar_method` for
-- trait method calls on generic type parameters.
mutual
private partial def rewriteCallNames (nameMap : List (String × String)) : CExpr → CExpr
  | .call fn targs args ty =>
    let fn' := nameMap.foldl (fun acc (paramName, concreteName) =>
      let pfx := paramName ++ "_"
      if acc.startsWith pfx then concreteName ++ "_" ++ acc.drop pfx.length
      else acc
    ) fn
    .call fn' targs (args.map (rewriteCallNames nameMap)) ty
  | .binOp op l r ty => .binOp op (rewriteCallNames nameMap l) (rewriteCallNames nameMap r) ty
  | .unaryOp op e ty => .unaryOp op (rewriteCallNames nameMap e) ty
  | .structLit n ta fs ty => .structLit n ta (fs.map fun (n, e) => (n, rewriteCallNames nameMap e)) ty
  | .fieldAccess obj f ty => .fieldAccess (rewriteCallNames nameMap obj) f ty
  | .enumLit en v ta fs ty => .enumLit en v ta (fs.map fun (n, e) => (n, rewriteCallNames nameMap e)) ty
  | .match_ scrut arms ty => .match_ (rewriteCallNames nameMap scrut) (arms.map (rewriteCallNamesArm nameMap)) ty
  | .borrow inner ty => .borrow (rewriteCallNames nameMap inner) ty
  | .borrowMut inner ty => .borrowMut (rewriteCallNames nameMap inner) ty
  | .deref inner ty => .deref (rewriteCallNames nameMap inner) ty
  | .arrayLit elems ty => .arrayLit (elems.map (rewriteCallNames nameMap)) ty
  | .arrayIndex arr idx ty => .arrayIndex (rewriteCallNames nameMap arr) (rewriteCallNames nameMap idx) ty
  | .cast inner t => .cast (rewriteCallNames nameMap inner) t
  | .try_ inner ty => .try_ (rewriteCallNames nameMap inner) ty
  | .allocCall inner alloc ty => .allocCall (rewriteCallNames nameMap inner) (rewriteCallNames nameMap alloc) ty
  | .whileExpr cond body elseBody ty =>
    .whileExpr (rewriteCallNames nameMap cond) (rewriteCallNamesStmts nameMap body) (rewriteCallNamesStmts nameMap elseBody) ty
  | .ifExpr cond then_ else_ ty =>
    .ifExpr (rewriteCallNames nameMap cond) (rewriteCallNamesStmts nameMap then_) (rewriteCallNamesStmts nameMap else_) ty
  | e => e

private partial def rewriteCallNamesArm (nameMap : List (String × String)) : CMatchArm → CMatchArm
  | .enumArm en v binds body => .enumArm en v binds (rewriteCallNamesStmts nameMap body)
  | .litArm val body => .litArm (rewriteCallNames nameMap val) (rewriteCallNamesStmts nameMap body)
  | .varArm b ty body => .varArm b ty (rewriteCallNamesStmts nameMap body)

private partial def rewriteCallNamesStmt (nameMap : List (String × String)) : CStmt → CStmt
  | .letDecl n m ty val => .letDecl n m ty (rewriteCallNames nameMap val)
  | .assign n val => .assign n (rewriteCallNames nameMap val)
  | .return_ (some v) ty => .return_ (some (rewriteCallNames nameMap v)) ty
  | .expr e => .expr (rewriteCallNames nameMap e)
  | .ifElse c t el =>
    .ifElse (rewriteCallNames nameMap c) (rewriteCallNamesStmts nameMap t) (el.map (rewriteCallNamesStmts nameMap))
  | .while_ c body lbl step =>
    .while_ (rewriteCallNames nameMap c) (rewriteCallNamesStmts nameMap body) lbl (rewriteCallNamesStmts nameMap step)
  | .fieldAssign obj f val => .fieldAssign (rewriteCallNames nameMap obj) f (rewriteCallNames nameMap val)
  | .derefAssign target val => .derefAssign (rewriteCallNames nameMap target) (rewriteCallNames nameMap val)
  | .arrayIndexAssign arr idx val =>
    .arrayIndexAssign (rewriteCallNames nameMap arr) (rewriteCallNames nameMap idx) (rewriteCallNames nameMap val)
  | .break_ (some v) lbl => .break_ (some (rewriteCallNames nameMap v)) lbl
  | .defer body => .defer (rewriteCallNames nameMap body)
  | .borrowIn v r reg isMut ty body =>
    .borrowIn v r reg isMut ty (rewriteCallNamesStmts nameMap body)
  | s => s

private partial def rewriteCallNamesStmts (nameMap : List (String × String)) : List CStmt → List CStmt :=
  List.map (rewriteCallNamesStmt nameMap)
end

mutual
/-- Given a set of known generic function names and type args to inject,
    walk the body and add typeArgs to any call targeting these functions
    that currently has empty typeArgs. -/
partial def injectTypeArgsExpr (genericNames : List String) (typeArgs : List Ty) : CExpr → CExpr
  | .call fn [] args ty =>
    let args' := args.map (injectTypeArgsExpr genericNames typeArgs)
    if genericNames.contains fn then .call fn typeArgs args' ty
    else .call fn [] args' ty
  | .call fn ta args ty => .call fn ta (args.map (injectTypeArgsExpr genericNames typeArgs)) ty
  | .binOp op l r ty => .binOp op (injectTypeArgsExpr genericNames typeArgs l) (injectTypeArgsExpr genericNames typeArgs r) ty
  | .unaryOp op inner ty => .unaryOp op (injectTypeArgsExpr genericNames typeArgs inner) ty
  | .structLit n ta fields ty => .structLit n ta (fields.map fun (n, e) => (n, injectTypeArgsExpr genericNames typeArgs e)) ty
  | .fieldAccess obj f ty => .fieldAccess (injectTypeArgsExpr genericNames typeArgs obj) f ty
  | .enumLit en v ta fields ty => .enumLit en v ta (fields.map fun (n, e) => (n, injectTypeArgsExpr genericNames typeArgs e)) ty
  | .match_ scrut arms ty => .match_ (injectTypeArgsExpr genericNames typeArgs scrut) (arms.map (injectTypeArgsArm genericNames typeArgs)) ty
  | .borrow inner ty => .borrow (injectTypeArgsExpr genericNames typeArgs inner) ty
  | .borrowMut inner ty => .borrowMut (injectTypeArgsExpr genericNames typeArgs inner) ty
  | .deref inner ty => .deref (injectTypeArgsExpr genericNames typeArgs inner) ty
  | .arrayLit elems ty => .arrayLit (elems.map (injectTypeArgsExpr genericNames typeArgs)) ty
  | .arrayIndex arr idx ty => .arrayIndex (injectTypeArgsExpr genericNames typeArgs arr) (injectTypeArgsExpr genericNames typeArgs idx) ty
  | .cast inner t => .cast (injectTypeArgsExpr genericNames typeArgs inner) t
  | .try_ inner ty => .try_ (injectTypeArgsExpr genericNames typeArgs inner) ty
  | .allocCall inner alloc ty => .allocCall (injectTypeArgsExpr genericNames typeArgs inner) (injectTypeArgsExpr genericNames typeArgs alloc) ty
  | .whileExpr cond body elseBody ty =>
    .whileExpr (injectTypeArgsExpr genericNames typeArgs cond) (injectTypeArgsStmts genericNames typeArgs body) (injectTypeArgsStmts genericNames typeArgs elseBody) ty
  | .ifExpr cond then_ else_ ty =>
    .ifExpr (injectTypeArgsExpr genericNames typeArgs cond) (injectTypeArgsStmts genericNames typeArgs then_) (injectTypeArgsStmts genericNames typeArgs else_) ty
  | e => e

partial def injectTypeArgsArm (genericNames : List String) (typeArgs : List Ty) : CMatchArm → CMatchArm
  | .enumArm en v binds body => .enumArm en v binds (injectTypeArgsStmts genericNames typeArgs body)
  | .litArm val body => .litArm (injectTypeArgsExpr genericNames typeArgs val) (injectTypeArgsStmts genericNames typeArgs body)
  | .varArm b ty body => .varArm b ty (injectTypeArgsStmts genericNames typeArgs body)

partial def injectTypeArgsStmt (genericNames : List String) (typeArgs : List Ty) : CStmt → CStmt
  | .letDecl n m ty val => .letDecl n m ty (injectTypeArgsExpr genericNames typeArgs val)
  | .assign n val => .assign n (injectTypeArgsExpr genericNames typeArgs val)
  | .return_ (some v) ty => .return_ (some (injectTypeArgsExpr genericNames typeArgs v)) ty
  | .expr e => .expr (injectTypeArgsExpr genericNames typeArgs e)
  | .ifElse c t el =>
    .ifElse (injectTypeArgsExpr genericNames typeArgs c) (injectTypeArgsStmts genericNames typeArgs t) (el.map (injectTypeArgsStmts genericNames typeArgs))
  | .while_ c body lbl step =>
    .while_ (injectTypeArgsExpr genericNames typeArgs c) (injectTypeArgsStmts genericNames typeArgs body) lbl (injectTypeArgsStmts genericNames typeArgs step)
  | .fieldAssign obj f val => .fieldAssign (injectTypeArgsExpr genericNames typeArgs obj) f (injectTypeArgsExpr genericNames typeArgs val)
  | .derefAssign target val => .derefAssign (injectTypeArgsExpr genericNames typeArgs target) (injectTypeArgsExpr genericNames typeArgs val)
  | .break_ (some v) lbl => .break_ (some (injectTypeArgsExpr genericNames typeArgs v)) lbl
  | .defer body => .defer (injectTypeArgsExpr genericNames typeArgs body)
  | .borrowIn v r reg isMut ty body =>
    .borrowIn v r reg isMut ty (injectTypeArgsStmts genericNames typeArgs body)
  | s => s

partial def injectTypeArgsStmts (genericNames : List String) (typeArgs : List Ty) : List CStmt → List CStmt :=
  List.map (injectTypeArgsStmt genericNames typeArgs)
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

/-- Infer type arguments by matching formal parameter types against concrete argument types.
    For a generic fn like `push(self: &mut BinaryHeap<T>, value: T)` called with
    concrete args of types `(&mut BinaryHeap<i32>, i32)`, infer `T = i32`. -/
private partial def cexprTy (e : CExpr) : Ty := match e with
  | .intLit _ ty | .floatLit _ ty | .ident _ ty | .binOp _ _ _ ty
  | .unaryOp _ _ ty | .call _ _ _ ty | .structLit _ _ _ ty
  | .fieldAccess _ _ ty | .enumLit _ _ _ _ ty | .match_ _ _ ty
  | .borrow _ ty | .borrowMut _ ty | .deref _ ty | .arrayLit _ ty
  | .arrayIndex _ _ ty | .fnRef _ ty | .try_ _ ty
  | .allocCall _ _ ty | .whileExpr _ _ _ ty | .ifExpr _ _ _ ty => ty
  | .cast _ t => t
  | .boolLit _ => .bool
  | .strLit _ => .string
  | .charLit _ => .char

private partial def matchFormalActual (typeParams : List String) (formal : Ty) (actual : Ty) (acc : List (String × Ty)) : List (String × Ty) :=
  match formal with
  | .typeVar n =>
    if typeParams.contains n && !acc.any (·.1 == n) then acc ++ [(n, actual)]
    else acc
  | .named n =>
    if typeParams.contains n && !acc.any (·.1 == n) then acc ++ [(n, actual)]
    else acc
  | .ref f => match actual with
    | .ref a | .ptrConst a => matchFormalActual typeParams f a acc
    | _ => acc
  | .refMut f => match actual with
    | .refMut a | .ptrMut a => matchFormalActual typeParams f a acc
    | _ => acc
  | .ptrMut f => match actual with
    | .ptrMut a | .refMut a => matchFormalActual typeParams f a acc
    | _ => acc
  | .ptrConst f => match actual with
    | .ptrConst a | .ref a => matchFormalActual typeParams f a acc
    | _ => acc
  | .generic _ fArgs => match actual with
    | .generic _ aArgs =>
      fArgs.zip aArgs |>.foldl (fun acc (f, a) => matchFormalActual typeParams f a acc) acc
    | _ => acc
  | _ => acc

private def inferTypeArgs (typeParams : List String) (formalParams : List (String × Ty))
    (args : List CExpr) : List Ty :=
  -- Build a mapping from type param name → concrete type by matching formal/actual
  let mapping := formalParams.zip args |>.foldl (fun (acc : List (String × Ty)) ((_, formalTy), argExpr) =>
    let argTy := cexprTy argExpr
    matchFormalActual typeParams formalTy argTy acc
  ) []
  -- Return the type args in order of typeParams
  typeParams.filterMap fun p => mapping.lookup p

-- ============================================================
-- Monomorphization state
-- ============================================================

structure MonoState where
  /-- All original function definitions (for lookup). -/
  allFns : List CFnDef
  /-- Linker aliases from all modules (local name → prefixed definition name). -/
  linkerAliases : List (String × String) := []
  /-- Queue of monomorphized functions to process. -/
  queue : List (String × CFnDef) := []
  /-- Already-generated mono names (avoid duplicates). -/
  generated : List String := []

abbrev MonoM := ExceptT String (StateM MonoState)

private def lookupFn (name : String) : MonoM (Option CFnDef) := do
  let st ← get
  -- Try direct lookup first
  match st.allFns.find? fun f => f.name == name with
  | some f => return some f
  | none =>
    -- Try resolving through linker aliases (e.g., HashMap_contains → map_HashMap_contains)
    match st.linkerAliases.lookup name with
    | some resolvedName => return st.allFns.find? fun f => f.name == resolvedName
    | none => return none

/-- Get names of all generic functions (non-empty typeParams). -/
private def getGenericFnNames : MonoM (List String) := do
  let st ← get
  return st.allFns.filter (fun f => !f.typeParams.isEmpty) |>.map (·.name)

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
      -- Even with no explicit typeArgs, the callee might be generic.
      -- Check if it's a generic function we need to monomorphize.
      let fnDef? ← lookupFn fn
      match fnDef? with
      | some fnDef =>
        if fnDef.typeParams.isEmpty then
          return .call fn [] args' ty  -- truly non-generic
        else
          -- Generic function called without type args (e.g., sibling method call).
          -- Try to infer type args from concrete argument types.
          let inferredArgs := inferTypeArgs fnDef.typeParams fnDef.params args'
          if inferredArgs.isEmpty then
            return .call fn [] args' ty  -- couldn't infer, leave as-is
          else
            -- Re-process as a generic call with inferred type args
            let genericNames ← getGenericFnNames
            let name := monoNameFor fn inferredArgs
            let mapping := fnDef.typeParams.zip inferredArgs
            let sub := substTy fnDef.typeParams mapping
            let callNameMap := mapping.filterMap fun (paramName, ty) =>
              let concreteName := tyName ty
              if concreteName == "" then none else some (paramName, concreteName)
            -- Inject type args into calls to sibling generic functions before type subst
            let bodyWithTypeArgs := injectTypeArgsStmts genericNames inferredArgs fnDef.body
            let monoFn : CFnDef := {
              name := name
              typeParams := []
              params := fnDef.params.map fun (n, t) => (n, sub t)
              retTy := sub fnDef.retTy
              body := rewriteCallNamesStmts callNameMap (substStmts sub bodyWithTypeArgs)
              isPublic := false
              isTest := false
              capSet := fnDef.capSet
            }
            enqueueMono name monoFn
            return .call name [] args' (sub ty)
      | none => return .call fn [] args' ty
    -- Look up the generic function
    let fnDef? ← lookupFn fn
    match fnDef? with
    | none => return .call fn typeArgs args' ty  -- extern or unknown, leave as-is
    | some fnDef =>
      if fnDef.typeParams.isEmpty then
        return .call fn typeArgs args' ty  -- not actually generic
      let genericNames ← getGenericFnNames
      let name := monoNameFor fn typeArgs
      let mapping := fnDef.typeParams.zip typeArgs
      let sub := substTy fnDef.typeParams mapping
      -- Build a name map for rewriting trait method calls like T_describe → Point_describe
      let callNameMap := mapping.filterMap fun (paramName, ty) =>
        let concreteName := tyName ty
        if concreteName == "" then none else some (paramName, concreteName)
      -- Inject type args into calls to sibling generic functions before type subst
      let bodyWithTypeArgs := injectTypeArgsStmts genericNames typeArgs fnDef.body
      let monoFn : CFnDef := {
        name := name
        typeParams := []
        params := fnDef.params.map fun (n, t) => (n, sub t)
        retTy := sub fnDef.retTy
        body := rewriteCallNamesStmts callNameMap (substStmts sub bodyWithTypeArgs)
        isPublic := false
        isTest := false
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
  | .ifExpr cond then_ else_ ty =>
    return .ifExpr (← monoExpr cond) (← monoStmts then_) (← monoStmts else_) ty

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
  -- Skip generic functions; they are templates, not concrete code.
  -- Only their monomorphized specializations should be processed.
  if !f.typeParams.isEmpty then return f
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

partial def monoModule (m : CModule) : MonoM CModule := do
  -- Mono all existing functions
  let fns' ← m.functions.mapM monoFn
  -- Drain mono queue to get all generated specializations
  let monoFns ← drainQueue
  -- Recursively process submodules
  let subs' ← m.submodules.mapM monoModule
  let subMonoFns ← drainQueue
  return { m with functions := fns' ++ monoFns ++ subMonoFns, submodules := subs' }

/-- Recursively collect all functions from a module and its submodules. -/
private partial def collectAllModuleFns (m : CModule) : List CFnDef :=
  let own := m.functions
  let sub := m.submodules.foldl (fun acc s => acc ++ collectAllModuleFns s) []
  own ++ sub

private partial def collectAllModuleAliases (m : CModule) : List (String × String) :=
  let own := m.linkerAliases
  let sub := m.submodules.foldl (fun acc s => acc ++ collectAllModuleAliases s) []
  own ++ sub

def monoProgram (modules : List CModule) : Except String (List CModule) :=
  let allFns := modules.foldl (fun acc m => acc ++ collectAllModuleFns m) []
  let allAliases := modules.foldl (fun acc m => acc ++ collectAllModuleAliases m) []
  let initState : MonoState := { allFns := allFns, linkerAliases := allAliases }
  let (result, _) := (modules.mapM monoModule).run initState |>.run
  match result with
  | .ok ms => .ok ms
  | .error e => .error e

end Concrete
