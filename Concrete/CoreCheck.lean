import Concrete.Core
import Concrete.AST
import Concrete.Diagnostic
import Concrete.Shared

namespace Concrete

/-! ## Core IR Validation

Runs after elaboration, before lowering. Validates:
- Capability discipline: caller's capSet ⊇ callee's capSet
- Type consistency: operand types match operators, arguments match parameters
- Structural invariants: break/continue inside loops, match coverage
-/

-- ============================================================
-- Validation environment
-- ============================================================

structure CoreCheckEnv where
  fnSigs : List (String × CapSet × List (String × Ty) × Ty)
  structDefs : List CStructDef
  enumDefs : List CEnumDef
  vars : List (String × Ty)
  currentCapSet : CapSet
  currentRetTy : Ty
  inLoop : Bool
  errors : Diagnostics

abbrev CoreCheckM := StateM CoreCheckEnv Unit

inductive CoreCheckError where
  -- Type consistency
  | typeMismatchVariable (name : String) (declared : String) (used : String)
  | arithmeticOnNonNumeric (ty : String)
  | binaryOperandMismatch (lTy : String) (rTy : String)
  | comparisonOperandMismatch (lTy : String) (rTy : String)
  | comparisonResultNotBool (ty : String)
  | logicalOnNonBool (lTy : String) (rTy : String)
  | bitwiseOnNonInteger (ty : String)
  | negationOnNonNumeric (ty : String)
  | logicalNotOnNonBool (ty : String)
  | bitwiseNotOnNonInteger (ty : String)
  -- Capability discipline
  | insufficientCapabilities (fn : String)
  | missingCapability (callee : String) (cap : String) (caller : String)
  | argCountMismatch (fn : String) (expected : Nat) (got : Nat)
  -- Match coverage
  | matchMissingVariant (enumName : String) (variant : String)
  | matchArmWrongEnum (armEnum : String) (scrutineeEnum : String)
  | duplicateMatchArm (variant : String)
  | variantFieldCountMismatch (variant : String) (expected : Nat) (actual : Nat)
  -- Control flow
  | whileCondNotBool (ty : String)
  | ifCondNotBool (ty : String)
  | breakOutsideLoop
  | continueOutsideLoop
  -- Type legality
  | arrayLiteralEmpty
  | arrayIndexNotInteger (ty : String)
  | indexingNonArray (ty : String)
  | cannotCast (fromTy : String) (toTy : String)
  | cannotDerefNonRef (ty : String)
  | cannotAssignThroughNonMutRef (ty : String)
  -- Return type
  | returnTypeMismatch (expected : String) (got : String)

def CoreCheckError.message : CoreCheckError → String
  | .typeMismatchVariable name declared used => s!"type mismatch for variable '{name}': declared {declared}, used as {used}"
  | .arithmeticOnNonNumeric ty => s!"arithmetic operator on non-numeric type: {ty}"
  | .binaryOperandMismatch lTy rTy => s!"binary operand type mismatch: {lTy} vs {rTy}"
  | .comparisonOperandMismatch lTy rTy => s!"comparison operand type mismatch: {lTy} vs {rTy}"
  | .comparisonResultNotBool ty => s!"comparison result should be Bool, got {ty}"
  | .logicalOnNonBool lTy rTy => s!"logical operator on non-Bool types: {lTy}, {rTy}"
  | .bitwiseOnNonInteger ty => s!"type mismatch in bitwise op: expected integer type, got {ty}"
  | .negationOnNonNumeric ty => s!"negation on non-numeric type: {ty}"
  | .logicalNotOnNonBool ty => s!"logical not on non-Bool type: {ty}"
  | .bitwiseNotOnNonInteger ty => s!"type mismatch in bitwise not: expected integer type, got {ty}"
  | .insufficientCapabilities fn => s!"function '{fn}' requires capability not available in caller"
  | .missingCapability callee cap _caller => s!"function '{callee}' requires capability '{cap}' but caller does not declare it"
  | .argCountMismatch fn expected got => s!"function '{fn}' expects {expected} args, got {got}"
  | .matchMissingVariant enumName variant => s!"non-exhaustive match: missing variant '{variant}' in enum '{enumName}'"
  | .matchArmWrongEnum armEnum scrutineeEnum => s!"match arm has enum '{armEnum}' but scrutinee is '{scrutineeEnum}'"
  | .duplicateMatchArm variant => s!"duplicate match arm for variant '{variant}'"
  | .variantFieldCountMismatch variant expected actual => s!"variant '{variant}' has {expected} fields but arm binds {actual}"
  | .whileCondNotBool ty => s!"while condition must be Bool, got {ty}"
  | .ifCondNotBool ty => s!"if condition must be Bool, got {ty}"
  | .breakOutsideLoop => "break outside of loop"
  | .continueOutsideLoop => "continue outside of loop"
  | .arrayLiteralEmpty => "array literal cannot be empty"
  | .arrayIndexNotInteger ty => s!"type mismatch: array index must be an integer type, got {ty}"
  | .indexingNonArray ty => s!"type mismatch: indexing into non-array type {ty}"
  | .cannotCast fromTy toTy => s!"cannot cast {fromTy} to {toTy}"
  | .cannotDerefNonRef ty => s!"cannot dereference non-reference type {ty}"
  | .cannotAssignThroughNonMutRef ty => s!"cannot assign through non-mutable reference type {ty}"
  | .returnTypeMismatch expected got => s!"return type mismatch: expected {expected}, got {got}"

private def getEnv : StateM CoreCheckEnv CoreCheckEnv := get
private def setEnv (env : CoreCheckEnv) : StateM CoreCheckEnv Unit := set env

private def addError (msg : String) : StateM CoreCheckEnv Unit := do
  let env ← getEnv
  setEnv { env with errors := env.errors ++ [{ severity := .error, message := msg, pass := "core-check", span := none, hint := none }] }

private def addCCError (e : CoreCheckError) : StateM CoreCheckEnv Unit :=
  addError e.message

private def addVar (name : String) (ty : Ty) : StateM CoreCheckEnv Unit := do
  let env ← getEnv
  setEnv { env with vars := env.vars ++ [(name, ty)] }

private def lookupVar (name : String) : StateM CoreCheckEnv (Option Ty) := do
  let env ← getEnv
  return env.vars.lookup name

/-- Builtin functions and their required capabilities. -/
private def builtinCapTable : List (String × CapSet) := [
  ("print_int", .concrete ["Console"]),
  ("print_bool", .concrete ["Console"]),
  ("print_string", .concrete ["Console"]),
  ("print_char", .concrete ["Console"]),
  ("eprint_string", .concrete ["Console"]),
  ("read_line", .concrete ["Console"]),
  ("read_file", .concrete ["File"]),
  ("write_file", .concrete ["File"]),
  ("get_env", .concrete ["Env"]),
  ("get_args", .concrete ["Process"]),
  ("exit_process", .concrete ["Process"]),
  ("alloc", .concrete ["Alloc"]),
  ("free", .concrete ["Alloc"]),
  ("vec_new", .concrete ["Alloc"]),
  ("vec_push", .concrete ["Alloc"]),
  ("vec_pop", .concrete ["Alloc"]),
  ("vec_free", .concrete ["Alloc"]),
  ("map_new", .concrete ["Alloc"]),
  ("map_insert", .concrete ["Alloc"]),
  ("map_remove", .concrete ["Alloc"]),
  ("map_free", .concrete ["Alloc"]),
  ("tcp_connect", .concrete ["Network"]),
  ("tcp_listen", .concrete ["Network"]),
  ("tcp_accept", .concrete ["Network"]),
  ("socket_send", .concrete ["Network"]),
  ("socket_recv", .concrete ["Network"]),
  ("socket_close", .concrete ["Network"])
]

private def lookupFnCaps (name : String) : StateM CoreCheckEnv (Option CapSet) := do
  let env ← getEnv
  match env.fnSigs.find? fun (n, _, _, _) => n == name with
  | some (_, caps, _, _) => return some caps
  | none =>
    -- Fall back to builtin capability table
    match builtinCapTable.lookup name with
    | some caps => return some caps
    | none => return none

private def lookupFnSig (name : String) : StateM CoreCheckEnv (Option (List (String × Ty) × Ty)) := do
  let env ← getEnv
  match env.fnSigs.find? fun (n, _, _, _) => n == name with
  | some (_, _, params, retTy) => return some (params, retTy)
  | none => return none

private def lookupStruct (name : String) : StateM CoreCheckEnv (Option CStructDef) := do
  let env ← getEnv
  return env.structDefs.find? fun sd => sd.name == name

private def lookupEnum (name : String) : StateM CoreCheckEnv (Option CEnumDef) := do
  let env ← getEnv
  return env.enumDefs.find? fun ed => ed.name == name


-- ============================================================
-- Expression validation
-- ============================================================

mutual

partial def ccCheckExpr (e : CExpr) : StateM CoreCheckEnv Unit := do
  match e with
  | .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | .charLit _ => pure ()

  | .ident name ty =>
    match ← lookupVar name with
    | some varTy =>
      if !typesCompatible varTy ty then
        addCCError (.typeMismatchVariable name (toString (repr varTy)) (toString (repr ty)))
    | none => pure ()  -- may be a parameter or external

  | .binOp op lhs rhs ty =>
    ccCheckExpr lhs
    ccCheckExpr rhs
    let lTy := lhs.ty
    let rTy := rhs.ty
    match op with
    | .add | .sub | .mul | .div | .mod =>
      if !isNumeric lTy then
        addCCError (.arithmeticOnNonNumeric (toString (repr lTy)))
      if !typesCompatible lTy rTy then
        addCCError (.binaryOperandMismatch (toString (repr lTy)) (toString (repr rTy)))
    | .eq | .neq | .lt | .gt | .leq | .geq =>
      if !typesCompatible lTy rTy then
        addCCError (.comparisonOperandMismatch (toString (repr lTy)) (toString (repr rTy)))
      if ty != .bool then
        addCCError (.comparisonResultNotBool (toString (repr ty)))
    | .and_ | .or_ =>
      if lTy != .bool || rTy != .bool then
        addCCError (.logicalOnNonBool (toString (repr lTy)) (toString (repr rTy)))
    | .bitand | .bitor | .bitxor | .shl | .shr =>
      if !isInteger lTy then
        addCCError (.bitwiseOnNonInteger (toString (repr lTy)))

  | .unaryOp op operand _ty =>
    ccCheckExpr operand
    match op with
    | .neg =>
      if !isNumeric operand.ty then
        addCCError (.negationOnNonNumeric (toString (repr operand.ty)))
    | .not_ =>
      if operand.ty != .bool then
        addCCError (.logicalNotOnNonBool (toString (repr operand.ty)))
    | .bitnot =>
      if !isInteger operand.ty then
        addCCError (.bitwiseNotOnNonInteger (toString (repr operand.ty)))

  | .call fn _typeArgs args _ty =>
    -- Check capability discipline
    match ← lookupFnCaps fn with
    | some calleeCaps =>
      let env ← getEnv
      if !capsContain env.currentCapSet calleeCaps then
        addCCError (.insufficientCapabilities fn)
    | none => pure ()  -- builtin or extern, skip cap check
    -- Check argument types
    match ← lookupFnSig fn with
    | some (params, _retTy) =>
      if args.length != params.length then
        addCCError (.argCountMismatch fn params.length args.length)
    | none => pure ()
    for arg in args do
      ccCheckExpr arg

  | .structLit _name _typeArgs fields _ty =>
    for (_, fieldExpr) in fields do
      ccCheckExpr fieldExpr

  | .fieldAccess obj _field _ty =>
    ccCheckExpr obj

  | .enumLit _enumName _variant _typeArgs fields _ty =>
    for (_, fieldExpr) in fields do
      ccCheckExpr fieldExpr

  | .match_ scrutinee arms _ty =>
    ccCheckExpr scrutinee
    -- Check match arm coverage for enums
    let scrTy := scrutinee.ty
    let tyName := match scrTy with | .named n => some n | .generic n _ => some n | _ => none
    match tyName with
    | some name =>
      match ← lookupEnum name with
      | some ed =>
        let variantNames := ed.variants.map fun (vn, _) => vn
        let mut seenVariants : List String := []
        let hasWildcard := arms.any fun arm =>
          match arm with | .varArm _ _ _ => true | _ => false
        for arm in arms do
          match arm with
          | .enumArm armEnum variant bindings _ =>
            -- Check arm references the right enum
            if armEnum != name then
              addCCError (.matchArmWrongEnum armEnum name)
            -- Check for duplicate arms
            if seenVariants.contains variant then
              addCCError (.duplicateMatchArm variant)
            seenVariants := seenVariants ++ [variant]
            -- Check field count matches variant
            match ed.variants.find? fun (vn, _) => vn == variant with
            | some (_, vfields) =>
              if bindings.length != 0 && bindings.length != vfields.length then
                addCCError (.variantFieldCountMismatch variant vfields.length bindings.length)
            | none => pure ()
          | _ => pure ()
        if !hasWildcard then
          for vn in variantNames do
            if !seenVariants.contains vn then
              addCCError (.matchMissingVariant name vn)
      | none => pure ()
    | none => pure ()
    for arm in arms do
      ccCheckMatchArm arm

  | .borrow inner _ => ccCheckExpr inner
  | .borrowMut inner _ => ccCheckExpr inner
  | .deref inner _ =>
    ccCheckExpr inner
    -- Check that inner is a dereferenceable type
    let env ← getEnv
    match inner.ty with
    | .ref _ | .refMut _ => pure ()
    | .ptrMut _ | .ptrConst _ =>
      if !capsContain env.currentCapSet (.concrete ["Unsafe"]) then
        addCCError (.missingCapability "*raw_ptr" "Unsafe" "")
    | .heap _ =>
      if !capsContain env.currentCapSet (.concrete ["Alloc"]) then
        addCCError (.missingCapability "*heap_ptr" "Alloc" "")
    | _ => addCCError (.cannotDerefNonRef (toString (repr inner.ty)))
  | .arrayLit elems _ =>
    if elems.isEmpty then
      addCCError .arrayLiteralEmpty
    for elem in elems do ccCheckExpr elem
  | .arrayIndex arr index _ =>
    ccCheckExpr arr
    ccCheckExpr index
    if !isInteger index.ty then
      addCCError (.arrayIndexNotInteger (toString (repr index.ty)))
    match arr.ty with
    | .array _ _ => pure ()
    | _ => addCCError (.indexingNonArray (toString (repr arr.ty)))
  | .cast inner targetTy =>
    ccCheckExpr inner
    let innerTy := inner.ty
    let isPtr := fun (t : Ty) => match t with | .ptrMut _ | .ptrConst _ => true | _ => false
    let isRef := fun (t : Ty) => match t with | .ref _ | .refMut _ => true | _ => false
    let isFloat := fun (t : Ty) => match t with | .float32 | .float64 => true | _ => false
    -- Cast validity check
    let valid :=
      (isInteger innerTy && isInteger targetTy) ||
      (isInteger innerTy && targetTy == .bool) ||
      (innerTy == .bool && isInteger targetTy) ||
      (isInteger innerTy && isFloat targetTy) ||
      (isFloat innerTy && isInteger targetTy) ||
      (isFloat innerTy && isFloat targetTy) ||
      (isInteger innerTy && targetTy == .char) ||
      (innerTy == .char && isInteger targetTy) ||
      (isPtr innerTy && isPtr targetTy) ||
      (isPtr innerTy && isInteger targetTy) ||
      (isInteger innerTy && isPtr targetTy) ||
      (match innerTy with | .array _ _ => isPtr targetTy | _ => false) ||
      (isPtr innerTy && isRef targetTy) ||
      (isRef innerTy && isPtr targetTy) ||
      (innerTy == targetTy)
    if !valid then
      addCCError (.cannotCast (toString (repr innerTy)) (toString (repr targetTy)))
    -- Unsafe capability check for pointer-involving casts (except safe ref-to-ptr)
    let isRefToPtr := isRef innerTy && isPtr targetTy
    let involvesPointer := isPtr innerTy || isPtr targetTy
    if involvesPointer && !isRefToPtr then
      let env ← getEnv
      if !capsContain env.currentCapSet (.concrete ["Unsafe"]) then
        addCCError (.missingCapability "unsafe_cast" "Unsafe" "")
  | .fnRef _ _ => pure ()
  | .try_ inner _ => ccCheckExpr inner
  | .allocCall inner allocExpr _ =>
    -- Verify caller has Alloc capability
    let env ← getEnv
    if !capsContain env.currentCapSet (.concrete ["Alloc"]) then
      addCCError (.missingCapability "alloc" "Alloc" "")
    ccCheckExpr inner
    ccCheckExpr allocExpr
  | .whileExpr cond body elseBody _ =>
    ccCheckExpr cond
    if cond.ty != .bool && !isInteger cond.ty then
      addCCError (.whileCondNotBool (toString (repr cond.ty)))
    let env ← getEnv
    setEnv { env with inLoop := true }
    for s in body do ccCheckStmt s
    for s in elseBody do ccCheckStmt s
    let env' ← getEnv
    setEnv { env' with inLoop := env.inLoop }

partial def ccCheckMatchArm (arm : CMatchArm) : StateM CoreCheckEnv Unit := do
  match arm with
  | .enumArm _ _ bindings body =>
    for (bname, bty) in bindings do
      addVar bname bty
    for s in body do ccCheckStmt s
  | .litArm value body =>
    ccCheckExpr value
    for s in body do ccCheckStmt s
  | .varArm binding bindTy body =>
    addVar binding bindTy
    for s in body do ccCheckStmt s

partial def ccCheckStmt (stmt : CStmt) : StateM CoreCheckEnv Unit := do
  match stmt with
  | .letDecl name _mutable ty value =>
    ccCheckExpr value
    addVar name ty

  | .assign _name value =>
    ccCheckExpr value

  | .return_ (some value) _retTy =>
    ccCheckExpr value
    let env ← getEnv
    let valueTy := value.ty
    -- Skip check for named/generic/typeVar types (could be newtypes, aliases, or polymorphic)
    let isResolvable := fun (t : Ty) => match t with
      | .named _ | .generic _ _ | .typeVar _ | .unit | .placeholder => true
      | _ => false
    if !typesCompatible valueTy env.currentRetTy && !isResolvable valueTy && !isResolvable env.currentRetTy then
      addCCError (.returnTypeMismatch (toString (repr env.currentRetTy)) (toString (repr valueTy)))

  | .return_ none _ => pure ()

  | .expr e => ccCheckExpr e

  | .ifElse cond then_ else_ =>
    ccCheckExpr cond
    if cond.ty != .bool && !isInteger cond.ty then
      addCCError (.ifCondNotBool (toString (repr cond.ty)))
    for s in then_ do ccCheckStmt s
    match else_ with
    | some stmts => for s in stmts do ccCheckStmt s
    | none => pure ()

  | .while_ cond body _label _ =>
    ccCheckExpr cond
    if cond.ty != .bool && !isInteger cond.ty then
      addCCError (.whileCondNotBool (toString (repr cond.ty)))
    let env ← getEnv
    setEnv { env with inLoop := true }
    for s in body do ccCheckStmt s
    let env' ← getEnv
    setEnv { env' with inLoop := env.inLoop }

  | .fieldAssign obj _field value =>
    ccCheckExpr obj
    ccCheckExpr value

  | .derefAssign target value =>
    ccCheckExpr target
    ccCheckExpr value
    -- Check target is a mutable ref/pointer
    let env ← getEnv
    match target.ty with
    | .refMut _ => pure ()
    | .ptrMut _ =>
      if !capsContain env.currentCapSet (.concrete ["Unsafe"]) then
        addCCError (.missingCapability "*raw_ptr=" "Unsafe" "")
    | _ => addCCError (.cannotAssignThroughNonMutRef (toString (repr target.ty)))

  | .arrayIndexAssign arr index value =>
    ccCheckExpr arr
    ccCheckExpr index
    ccCheckExpr value
    if !isInteger index.ty then
      addCCError (.arrayIndexNotInteger (toString (repr index.ty)))
    match arr.ty with
    | .array _ _ => pure ()
    | _ => addCCError (.indexingNonArray (toString (repr arr.ty)))

  | .break_ _value _label =>
    let env ← getEnv
    if !env.inLoop then
      addCCError .breakOutsideLoop

  | .continue_ _label =>
    let env ← getEnv
    if !env.inLoop then
      addCCError .continueOutsideLoop

  | .defer body => ccCheckExpr body

  | .borrowIn _var _ref _region _isMut _refTy body =>
    for s in body do ccCheckStmt s

end

-- ============================================================
-- Function and module validation
-- ============================================================

def ccCheckFn (f : CFnDef) : StateM CoreCheckEnv Unit := do
  let env ← getEnv
  setEnv { env with
    vars := f.params
    currentCapSet := f.capSet
    currentRetTy := f.retTy
    inLoop := false
  }
  for s in f.body do
    ccCheckStmt s

def ccCheckModule (m : CModule) : Diagnostics :=
  let fnSigs := m.functions.map fun f =>
    (f.name, f.capSet, f.params, f.retTy)
  -- Extern functions require Unsafe capability
  let externSigs := m.externFns.map fun (name, params, retTy) =>
    (name, CapSet.concrete ["Unsafe"], params, retTy)
  let initEnv : CoreCheckEnv := {
    fnSigs := fnSigs ++ externSigs
    structDefs := m.structs
    enumDefs := m.enums
    vars := []
    currentCapSet := .empty
    currentRetTy := .unit
    inLoop := false
    errors := []
  }
  let finalEnv := m.functions.foldl (fun env f =>
    let ((), env') := (ccCheckFn f).run env
    env'
  ) initEnv
  finalEnv.errors

/-- Validate all Core modules. Returns the first error or Ok. -/
def coreCheckProgram (modules : List CModule) : Except String Unit :=
  let allErrors := modules.foldl (fun acc m =>
    acc ++ (ccCheckModule m).map fun d => { d with message := s!"[{m.name}] {d.message}" }
  ) ([] : Diagnostics)
  if allErrors.isEmpty then .ok ()
  else .error (renderDiagnostics allErrors)

end Concrete
