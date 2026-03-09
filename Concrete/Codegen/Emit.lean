import Concrete.Codegen.Types
import Concrete.Check

namespace Concrete

mutual

/-- Generate an expression, returning the LLVM register holding the value.
    An optional type hint is used for integer/float literals to emit the correct LLVM type. -/
partial def genExpr (s : CodegenState) (e : Expr) (hintTy : Option Ty := none) : CodegenState × String :=
  match e with
  | .intLit _ v =>
    let ty := match hintTy with
      | some t => if isIntegerType t || t == .char then t else Ty.int
      | none => Ty.int
    let llTy := intTyToLLVM ty
    let (s, reg) := s.freshLocal
    let s := s.emit ("  " ++ reg ++ " = add " ++ llTy ++ " 0, " ++ toString v)
    (s, reg)
  | .floatLit _ v =>
    let ty := match hintTy with
      | some t => if isFloatType t then t else Ty.float64
      | none => Ty.float64
    if ty == Ty.float32 then
      -- For f32, emit as double first then fptrunc to float (avoids hex format issues)
      let (s, dblReg) := s.freshLocal
      let s := s.emit ("  " ++ dblReg ++ " = fadd double 0.0, " ++ floatToLLVM v)
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = fptrunc double " ++ dblReg ++ " to float")
      (s, reg)
    else
      let llTy := floatTyToLLVM ty
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = fadd " ++ llTy ++ " 0.0, " ++ floatToLLVM v)
      (s, reg)
  | .boolLit _ v =>
    let (s, reg) := s.freshLocal
    let val := if v then "1" else "0"
    let s := s.emit ("  " ++ reg ++ " = add i1 0, " ++ val)
    (s, reg)
  | .strLit _ v =>
    let globalName := "@.str." ++ toString s.stringLitCounter
    let len := v.length
    let escaped := escapeStringForLLVM v
    let globalDef := globalName ++ " = private constant [" ++ toString len ++ " x i8] c\"" ++ escaped ++ "\"\n"
    let s := { s with stringLitCounter := s.stringLitCounter + 1, stringGlobals := s.stringGlobals ++ globalDef }
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca %struct.String")
    let (s, dataMem) := s.freshLocal
    let s := s.emit ("  " ++ dataMem ++ " = call ptr @malloc(i64 " ++ toString len ++ ")")
    let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ dataMem ++ ", ptr " ++ globalName ++ ", i64 " ++ toString len ++ ", i1 false)")
    let (s, dataPtrField) := s.freshLocal
    let s := s.emit ("  " ++ dataPtrField ++ " = getelementptr inbounds %struct.String, ptr " ++ alloca ++ ", i32 0, i32 0")
    let s := s.emit ("  store ptr " ++ dataMem ++ ", ptr " ++ dataPtrField)
    let (s, lenField) := s.freshLocal
    let s := s.emit ("  " ++ lenField ++ " = getelementptr inbounds %struct.String, ptr " ++ alloca ++ ", i32 0, i32 1")
    let s := s.emit ("  store i64 " ++ toString len ++ ", ptr " ++ lenField)
    (s, alloca)
  | .charLit _ v =>
    let (s, reg) := s.freshLocal
    let s := s.emit ("  " ++ reg ++ " = add i8 0, " ++ toString v.toNat)
    (s, reg)
  | .ident _ name =>
    -- Check constants first
    match s.constants.lookup name with
    | some (ty, constExpr) =>
      -- Inline the constant value with its declared type as hint
      genExpr s constExpr (hintTy.orElse fun _ => some ty)
    | none =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      if isPassByPtr s ty then
        (s, alloca)
      else
        let (s, loaded) := s.freshLocal
        let llTy := tyToLLVM s ty
        let s := s.emit ("  " ++ loaded ++ " = load " ++ llTy ++ ", ptr " ++ alloca)
        (s, loaded)
    | none =>
      -- Check if this is a function reference (function name used as value)
      if (s.fnRetTypes.lookup name).isSome then
        -- Return function pointer directly — @fnName is a valid ptr in LLVM IR
        (s, "@" ++ name)
      else
        (s, "%" ++ name)
  | .binOp _ op lhs rhs =>
    let lhsTy := inferExprTy s lhs hintTy
    let (s, lReg) := genExpr s lhs hintTy
    let (s, rReg) := genExpr s rhs (some lhsTy)
    let (s, result) := s.freshLocal
    -- Determine operation type
    let isFloat := match lhsTy with | .float32 | .float64 => true | _ => false
    let isPtr := match lhsTy with | .ptrMut _ | .ptrConst _ => true | _ => false
    let llTy := if isFloat then floatTyToLLVM lhsTy
                else if isPtr then "ptr"
                else intTyToLLVM lhsTy
    let isSigned := isSignedInt lhsTy
    if isFloat then
      let instr := match op with
        | .add => "fadd " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .sub => "fsub " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mul => "fmul " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .div => "fdiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mod => "frem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .eq => "fcmp oeq " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .neq => "fcmp one " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .lt => "fcmp olt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .gt => "fcmp ogt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .leq => "fcmp ole " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .geq => "fcmp oge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .and_ => "and i1 " ++ lReg ++ ", " ++ rReg
        | .or_ => "or i1 " ++ lReg ++ ", " ++ rReg
        | .bitand | .bitor | .bitxor | .shl | .shr =>
          -- Bitwise on float: shouldn't happen (checker rejects), fallback
          "fadd " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
      let s := s.emit ("  " ++ result ++ " = " ++ instr)
      (s, result)
    else if isPtr then
      -- Pointer arithmetic: getelementptr
      let pointeeTy := match lhsTy with
        | .ptrMut t => tyToLLVM s t
        | .ptrConst t => tyToLLVM s t
        | _ => "i8"
      let s := s.emit ("  " ++ result ++ " = getelementptr " ++ pointeeTy ++ ", ptr " ++ lReg ++ ", i64 " ++ rReg)
      (s, result)
    else
      let instr := match op with
        | .add => "add " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .sub => "sub " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mul => "mul " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .div => if isSigned then "sdiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "udiv " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .mod => if isSigned then "srem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "urem " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .eq => "icmp eq " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .neq => "icmp ne " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .lt => if isSigned then "icmp slt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                 else "icmp ult " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .gt => if isSigned then "icmp sgt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                 else "icmp ugt " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .leq => if isSigned then "icmp sle " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "icmp ule " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .geq => if isSigned then "icmp sge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "icmp uge " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .and_ => "and i1 " ++ lReg ++ ", " ++ rReg
        | .or_ => "or i1 " ++ lReg ++ ", " ++ rReg
        | .bitand => "and " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .bitor => "or " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .bitxor => "xor " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .shl => "shl " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
        | .shr => if isSigned then "ashr " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
                  else "lshr " ++ llTy ++ " " ++ lReg ++ ", " ++ rReg
      let s := s.emit ("  " ++ result ++ " = " ++ instr)
      (s, result)
  | .unaryOp _ op operand =>
    let opTy := inferExprTy s operand hintTy
    let (s, reg) := genExpr s operand hintTy
    let (s, result) := s.freshLocal
    match op with
    | .neg =>
      let isFloat := match opTy with | .float32 | .float64 => true | _ => false
      if isFloat then
        let llTy := floatTyToLLVM opTy
        let s := s.emit ("  " ++ result ++ " = fneg " ++ llTy ++ " " ++ reg)
        (s, result)
      else
        let llTy := intTyToLLVM opTy
        let s := s.emit ("  " ++ result ++ " = sub " ++ llTy ++ " 0, " ++ reg)
        (s, result)
    | .not_ =>
      let s := s.emit ("  " ++ result ++ " = xor i1 " ++ reg ++ ", 1")
      (s, result)
    | .bitnot =>
      let llTy := intTyToLLVM opTy
      let s := s.emit ("  " ++ result ++ " = xor " ++ llTy ++ " " ++ reg ++ ", -1")
      (s, result)
  | .call _ fnName typeArgs args =>
    -- Intercept abort()
    if fnName == "abort" then
      let s := s.emit "  call void @abort()"
      let s := s.emit "  unreachable"
      let (s, deadLabel) := s.freshLabel "abort.dead"
      let s := s.emit (deadLabel ++ ":")
      let (s, dummy) := s.freshLocal
      let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
      (s, dummy)
    -- Intercept destroy(x)
    else if fnName == "destroy" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let typeName := match argTy with
          | .named n => n
          | .generic n _ => n
          | _ => ""
        let mangledName := typeName ++ "_destroy"
        let (s, argReg) := genExpr s arg
        let argLLTy := paramTyToLLVM s argTy
        let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argLLTy ++ " " ++ argReg ++ ")")
        (s, "0")
      | none => (s, "0")
    -- Intercept alloc(val)
    else if fnName == "alloc" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let szVal := tySizeOf s argTy
        -- Malloc the heap memory
        let (s, heapPtr) := s.freshLocal
        let s := s.emit ("  " ++ heapPtr ++ " = call ptr @malloc(i64 " ++ toString szVal ++ ")")
        -- Generate the value and store it at the heap location
        -- For pass-by-ptr types (structs), genExpr returns a ptr to the alloca
        -- We load the full value from the alloca and store it to the heap
        if isPassByPtr s argTy then
          let (s, valPtr) := genExpr s arg
          let argLLTy := tyToLLVM s argTy
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ argLLTy ++ ", ptr " ++ valPtr)
          let s := s.emit ("  store " ++ argLLTy ++ " " ++ loaded ++ ", ptr " ++ heapPtr)
          (s, heapPtr)
        else
          let (s, valReg) := genExpr s arg
          let argLLTy := tyToLLVM s argTy
          let s := s.emit ("  store " ++ argLLTy ++ " " ++ valReg ++ ", ptr " ++ heapPtr)
          (s, heapPtr)
      | none => (s, "0")
    -- Intercept free(ptr)
    else if fnName == "free" then
      match args.head? with
      | some arg =>
        let argTy := inferExprTy s arg
        let innerTy := match argTy with
          | .heap t => t
          | _ => argTy
        let innerLLTy := tyToLLVM s innerTy
        -- Get the heap pointer
        let (s, heapPtr) := genExpr s arg
        if isPassByPtr s innerTy then
          -- Load the struct value from heap, free, return via alloca
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ heapPtr)
          let s := s.emit ("  call void @free(ptr " ++ heapPtr ++ ")")
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ innerLLTy)
          let s := s.emit ("  store " ++ innerLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          (s, alloca)
        else
          -- Load the scalar value from heap, free, return value
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ heapPtr)
          let s := s.emit ("  call void @free(ptr " ++ heapPtr ++ ")")
          (s, loaded)
      | none => (s, "0")
    -- Intercept vec_* calls
    else if fnName == "vec_new" || fnName == "vec_push" || fnName == "vec_get" ||
            fnName == "vec_set" || fnName == "vec_len" || fnName == "vec_pop" ||
            fnName == "vec_free" then
      genVecBuiltinCall s fnName typeArgs args hintTy
    -- Intercept map_* calls
    else if fnName == "map_new" || fnName == "map_insert" || fnName == "map_get" ||
            fnName == "map_contains" || fnName == "map_remove" || fnName == "map_len" ||
            fnName == "map_free" then
      genHashMapBuiltinCall s fnName typeArgs args hintTy
    else
    -- Check if this is a function pointer call (variable with fn_ type)
    let isFnPtrCall := match s.lookupVarType fnName with
      | some (.fn_ _ _ _) => true
      | _ => false
    if isFnPtrCall then
      -- Function pointer call: load the ptr and call indirectly
      let fnPtrVar := (s.lookupVar fnName).getD "%undef"
      let (s, fnPtr) := s.freshLocal
      let s := s.emit ("  " ++ fnPtr ++ " = load ptr, ptr " ++ fnPtrVar)
      -- Generate args
      let (s, argRegs) := genExprList s args
      let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
      let argPairs := argTys.zip argRegs
      let normalArgs := argPairs.map fun (ty, r) => ty ++ " " ++ r
      let argStr := ", ".intercalate normalArgs
      -- Determine return type
      let retTy := match s.lookupVarType fnName with
        | some (.fn_ _ _ ret) => ret
        | _ => .int
      let retLLTy := tyToLLVM s retTy
      if retLLTy == "void" then
        let s := s.emit ("  call void " ++ fnPtr ++ "(" ++ argStr ++ ")")
        (s, "0")
      else
        let (s, result) := s.freshLocal
        let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " " ++ fnPtr ++ "(" ++ argStr ++ ")")
        (s, result)
    else
    -- sizeof intrinsic: emit compile-time constant
    if (fnName == "sizeof" || fnName.endsWith "_sizeof") && !typeArgs.isEmpty then
      let ty := typeArgs.headD .int
      let sz := tySize ty
      let (s, reg) := s.freshLocal
      let retLLTy := match hintTy with
        | some t => tyToLLVM s t
        | none => "i64"
      let s := s.emit ("  " ++ reg ++ " = add " ++ retLLTy ++ " 0, " ++ toString sz)
      (s, reg)
    else
    -- Monomorphization: redirect calls to generic functions with trait bounds
    let fnBounds := (s.fnTypeBounds.lookup fnName).getD []
    let (s, effectiveName) := if !fnBounds.isEmpty then
      let fnTyParams := (s.fnTypeParams.lookup fnName).getD []
      -- Infer type var mapping from arguments
      let origParamTys := (s.fnParamTypes.lookup fnName).getD []
      let argTypes := args.map fun arg => inferExprTy s arg
      let inferredMapping := origParamTys.zip argTypes |>.foldl (fun acc (paramTy, argTy) =>
        let paramName := match paramTy with
          | .named n => if fnTyParams.contains n then some n else none
          | _ => none
        match paramName with
        | some n =>
          let concreteName := match argTy with
            | .named name => some name
            | .generic name _ => some name
            | _ => none
          match concreteName with
          | some cn => if acc.any fun (k, _) => k == n then acc else acc ++ [(n, cn)]
          | none => acc
        | none => acc
      ) ([] : List (String × String))
      -- Also use explicit typeArgs if provided
      let mapping := if !typeArgs.isEmpty then
        fnTyParams.zip typeArgs |>.foldl (fun acc (param, ty) =>
          let concreteName := match ty with
            | .named name => some name
            | .generic name _ => some name
            | _ => none
          match concreteName with
          | some cn => if acc.any fun (k, _) => k == param then acc else acc ++ [(param, cn)]
          | none => acc
        ) inferredMapping
      else inferredMapping
      -- Compute monomorphized name
      let typeNames := fnTyParams.map fun p => (mapping.lookup p).getD "unknown"
      let monoName := fnName ++ "_for_" ++ "_".intercalate typeNames
      -- Register monomorphized function if not already generated
      let s := if s.monoGenerated.contains monoName then s
        else
          match s.allFnDefs.find? fun f => f.name == fnName with
          | some origFn =>
            let tyMapping := mapping.map fun (k, v) => (k, Ty.named v)
            let monoFn := monoFnDef origFn monoName tyMapping
            let monoRetTy := normalizeFieldTy monoFn.retTy
            let monoParamTys := monoFn.params.map fun p => normalizeFieldTy p.ty
            { s with
              monoQueue := s.monoQueue ++ [(monoName, monoFn)]
              monoGenerated := monoName :: s.monoGenerated
              fnRetTypes := (monoName, monoRetTy) :: s.fnRetTypes
              fnParamTypes := (monoName, monoParamTys) :: s.fnParamTypes }
          | none => s
      (s, monoName)
    else (s, fnName)
    -- Use the raw (un-substituted) param types for generating argument values
    let rawParamTys := (s.fnParamTypes.lookup effectiveName).getD []
    -- But use hinted types for actually generating argument code
    let (s, argRegs) := genExprListWithHints s args rawParamTys
    -- For LLVM call, use the function's declared param types (i64 for type vars)
    let argTys := rawParamTys.map fun pty => paramTyToLLVM s pty
    -- Pad with inferred types if args > rawParamTys
    let argTys := if argTys.length < args.length then
      argTys ++ (args.drop argTys.length).map fun arg => paramTyToLLVM s (inferExprTy s arg)
    else argTys
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup effectiveName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ effectiveName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .paren _ inner => genExpr s inner hintTy
  | .structLit _ name typeArgs fields =>
    match s.lookupStruct name with
    | some si =>
      let mapping : List (String × Ty) := si.typeParams.zip typeArgs
      let structTy := "%struct." ++ name
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ structTy)
      let s := fields.foldl (fun s (fieldName, fieldExpr) =>
        match si.fields.find? fun fi => fi.name == fieldName with
        | some fi =>
          -- Substitute type vars with concrete types
          let fieldTy := List.foldl (fun (ty : Ty) (pair : String × Ty) =>
            match ty with
            | .typeVar n => if n == pair.1 then pair.2 else ty
            | _ => ty) fi.ty mapping
          let (s, valReg) := genExpr s fieldExpr (some fieldTy)
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s fieldTy
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
            ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString fi.index)
          -- For pass-by-ptr field types (enums, structs), load value from pointer before storing
          if isPassByPtr s fieldTy && fieldLLTy != "ptr" then
            let resolvedFieldLLTy := tyToLLVM s fieldTy
            let (s, loaded) := s.freshLocal
            let s := s.emit ("  " ++ loaded ++ " = load " ++ resolvedFieldLLTy ++ ", ptr " ++ valReg)
            s.emit ("  store " ++ resolvedFieldLLTy ++ " " ++ loaded ++ ", ptr " ++ gepReg)
          else
            s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
        | none => s
      ) s
      (s, alloca)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown struct " ++ name)
      (s, reg)
  | .fieldAccess _ obj field =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let (structName, typeArgs) := match innerTy with
      | .named n => (n, ([] : List Ty))
      | .generic n args => (n, args)
      | .string => ("String", [])
      | _ => ("", [])
    if structName != "" then
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        -- For generic types, substitute type params with concrete type args
        let fieldTy := if !typeArgs.isEmpty then
          match s.lookupStruct structName with
          | some si =>
            let mapping : List (String × Ty) := si.typeParams.zip typeArgs
            List.foldl (fun (ty : Ty) (pair : String × Ty) =>
              match ty with
              | .typeVar n => if n == pair.1 then pair.2 else ty
              | _ => ty) fieldTy mapping
          | none => fieldTy
        else fieldTy
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        if isPassByPtr s fieldTy then
          (s, gepReg)
        else
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          (s, loaded)
      | none =>
        let (s, reg) := s.freshLocal
        let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown field " ++ field)
        (s, reg)
    else
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; field access on non-struct")
      (s, reg)
  | .borrow _ inner =>
    genExprAsPtr s inner
  | .borrowMut _ inner =>
    genExprAsPtr s inner
  | .deref _ inner =>
    let (s, ptr) := genExpr s inner
    let innerTy := inferExprTy s inner
    match innerTy with
    | .heap t =>
      -- *heap_ptr: load value from heap, then free the allocation
      let innerLLTy := tyToLLVM s t
      if isPassByPtr s t then
        -- Struct/enum: load full value, free heap, store to new stack alloc
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ ptr)
        let s := s.emit ("  call void @free(ptr " ++ ptr ++ ")")
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca " ++ innerLLTy)
        let s := s.emit ("  store " ++ innerLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
        (s, alloca)
      else
        -- Scalar: load value, free heap, return value
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ innerLLTy ++ ", ptr " ++ ptr)
        let s := s.emit ("  call void @free(ptr " ++ ptr ++ ")")
        (s, loaded)
    | _ =>
      let pointeeTy := match innerTy with
        | .ref t => t
        | .refMut t => t
        | .ptrMut t => t
        | .ptrConst t => t
        | _ => .int
      let llTy := tyToLLVM s pointeeTy
      if llTy == "ptr" || isPassByPtr s pointeeTy then
        (s, ptr)
      else
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ llTy ++ ", ptr " ++ ptr)
        (s, loaded)
  | .enumLit _ enumName variant typeArgs fields =>
    match s.lookupEnum enumName with
    | some ei =>
      match ei.variants.find? fun v => v.name == variant with
      | some vi =>
        -- Build type substitution for generic enums
        -- If typeArgs empty but enum is generic, infer from hint
        let effectiveTypeArgs := if typeArgs.isEmpty && !ei.typeParams.isEmpty then
          match hintTy with
          | some (.generic n args) => if n == enumName then args else []
          | _ => []
        else typeArgs
        let enumTypeMapping := ei.typeParams.zip effectiveTypeArgs
        let enumTy := "%enum." ++ enumName
        let (s, alloca) := s.freshLocal
        let s := s.emit ("  " ++ alloca ++ " = alloca " ++ enumTy)
        let (s, tagPtr) := s.freshLocal
        let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
          ++ ", ptr " ++ alloca ++ ", i32 0, i32 0")
        let s := s.emit ("  store i32 " ++ toString vi.tag ++ ", ptr " ++ tagPtr)
        if !fields.isEmpty then
          let (s, payloadPtr) := s.freshLocal
          let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
            ++ ", ptr " ++ alloca ++ ", i32 0, i32 1")
          let variantTy := "%variant." ++ enumName ++ "." ++ variant
          let s := fields.foldl (fun s (fieldName, fieldExpr) =>
            match vi.fields.find? fun fi => fi.name == fieldName with
            | some fi =>
              let resolvedTy := normalizeFieldTy (substTyCodegen enumTypeMapping fi.ty)
              let (s, valReg) := genExpr s fieldExpr (some resolvedTy)
              let (s, gepReg) := s.freshLocal
              let fieldLLTy := fieldTyToLLVM s resolvedTy
              let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
                ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
              s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
            | none => s
          ) s
          (s, alloca)
        else
          (s, alloca)
      | none =>
        let (s, reg) := s.freshLocal
        let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown variant " ++ variant)
        (s, reg)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown enum " ++ enumName)
      (s, reg)
  | .match_ _ scrutinee arms =>
    let (s, scrReg) := genExpr s scrutinee
    let scrTy := inferExprTy s scrutinee
    let innerScrTy := match scrTy with
      | .ref t => t | .refMut t => t | t => t
    let enumName := match innerScrTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    -- Check if this is a value-pattern match (litArm/varArm) vs enum match
    let isValueMatch := arms.any fun arm => match arm with
      | .litArm _ _ _ | .varArm _ _ _ => true | _ => false
    if isValueMatch then
      -- Value-pattern match: emit if/else chain
      let scrLLTy := tyToLLVM s innerScrTy
      let (s, mergeLabel) := s.freshLabel "match.merge"
      let (s, armLabels) := arms.foldl (fun (acc : CodegenState × List String) _arm =>
        let (s, labels) := acc
        let (s, label) := s.freshLabel "match.arm"
        (s, labels ++ [label])
      ) (s, [])
      -- Build chain of conditional branches
      let (s, _) := (arms.zip armLabels).foldl (fun (acc : CodegenState × Nat) (arm, label) =>
        let (s, idx) := acc
        match arm with
        | .litArm _ val _ =>
          let (s, valReg) := genExpr s val (some innerScrTy)
          let (s, cmpReg) := s.freshLocal
          let s := s.emit ("  " ++ cmpReg ++ " = icmp eq " ++ scrLLTy ++ " " ++ scrReg ++ ", " ++ valReg)
          let nextLabel := if idx + 1 < armLabels.length then
            (armLabels.getD (idx + 1) mergeLabel) ++ ".check"
          else mergeLabel
          let s := s.emit ("  br i1 " ++ cmpReg ++ ", label %" ++ label ++ ", label %" ++ nextLabel)
          if idx + 1 < armLabels.length then
            let s := s.emit (nextLabel ++ ":")
            (s, idx + 1)
          else
            (s, idx + 1)
        | .varArm _ _ _ =>
          -- Catch-all: unconditional branch
          let s := s.emit ("  br label %" ++ label)
          (s, idx + 1)
        | _ => (s, idx + 1)
      ) (s, 0)
      -- Emit arm bodies
      let s := (arms.zip armLabels).foldl (fun s (arm, label) =>
        match arm with
        | .litArm _ _ body =>
          let s := s.emit (label ++ ":")
          let s := genStmts s body
          if stmtListHasReturn body then s else s.emit ("  br label %" ++ mergeLabel)
        | .varArm _ binding body =>
          let s := s.emit (label ++ ":")
          -- Bind the scrutinee value to the variable
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ scrLLTy)
          let s := s.emit ("  store " ++ scrLLTy ++ " " ++ scrReg ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          let s := s.addVarType binding innerScrTy
          let s := genStmts s body
          if stmtListHasReturn body then s else s.emit ("  br label %" ++ mergeLabel)
        | _ => s
      ) s
      let allReturn := arms.all fun arm => match arm with
        | .litArm _ _ body | .varArm _ _ body | .mk _ _ _ _ body => stmtListHasReturn body
      if allReturn then
        (s, "0")
      else
        let s := s.emit (mergeLabel ++ ":")
        let (s, dummy) := s.freshLocal
        let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
        (s, dummy)
    else
    -- Enum match
    let enumName := if enumName == "" then "unknown" else enumName
    let enumTy := "%enum." ++ enumName
    -- For references, genExpr already returns the pointer to the target
    let (s, scrPtr) := (s, scrReg)
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    let (s, mergeLabel) := s.freshLabel "match.merge"
    let (s, defaultLabel) := s.freshLabel "match.default"
    let (s, armLabels) := arms.foldl (fun (acc : CodegenState × List String) _arm =>
      let (s, labels) := acc
      let (s, label) := s.freshLabel "match.arm"
      (s, labels ++ [label])
    ) (s, [])
    let ei := (s.lookupEnum enumName).get!
    -- Build type substitution for generic enums (e.g., Option<Heap<Node>>)
    let enumTypeArgs := match innerScrTy with
      | .generic _ args => args
      | _ => []
    let enumTypeMapping : List (String × Ty) :=
      ei.typeParams.zip enumTypeArgs
    let cases := arms.zip armLabels |>.filterMap fun (arm, label) =>
      match arm with
      | .mk _ _ variant _ _ =>
        match ei.variants.find? fun v => v.name == variant with
        | some vi => some ("    i32 " ++ toString vi.tag ++ ", label %" ++ label)
        | none => none
      | _ => none
    let switchCases := "\n".intercalate cases
    let s := s.emit ("  switch i32 " ++ tag ++ ", label %" ++ defaultLabel ++ " [\n" ++ switchCases ++ "\n  ]")
    let s := (arms.zip armLabels).foldl (fun s (arm, label) =>
      match arm with
      | .mk _ _ variant bindings body =>
        let s := s.emit (label ++ ":")
        let variantTy := "%variant." ++ enumName ++ "." ++ variant
        let vi := (ei.variants.find? fun v => v.name == variant).get!
        let s := (bindings.zip vi.fields).foldl (fun s (binding, fi) =>
          -- Substitute generic type args for the field type
          let resolvedTy := normalizeFieldTy (substTyCodegen enumTypeMapping fi.ty)
          let (s, gepReg) := s.freshLocal
          let fieldLLTy := fieldTyToLLVM s resolvedTy
          let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ variantTy
            ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 " ++ toString fi.index)
          let (s, loaded) := s.freshLocal
          let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
          let (s, alloca) := s.freshLocal
          let s := s.emit ("  " ++ alloca ++ " = alloca " ++ fieldLLTy)
          let s := s.emit ("  store " ++ fieldLLTy ++ " " ++ loaded ++ ", ptr " ++ alloca)
          let s := s.addVar binding alloca
          s.addVarType binding resolvedTy
        ) s
        let s := genStmts s body
        let hasRet := stmtListHasReturn body
        if hasRet then s else s.emit ("  br label %" ++ mergeLabel)
      | _ => s
    ) s
    let s := s.emit (defaultLabel ++ ":")
    let s := s.emit "  unreachable"
    let allReturn := arms.all fun arm => match arm with
      | .mk _ _ _ _ body | .litArm _ _ body | .varArm _ _ body => stmtListHasReturn body
    if allReturn then
      (s, "0")
    else
      let s := s.emit (mergeLabel ++ ":")
      let (s, dummy) := s.freshLocal
      let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
      (s, dummy)
  | .try_ _ inner =>
    let (s, scrPtr) := genExpr s inner
    let innerTy := inferExprTy s inner
    let enumName := match innerTy with
      | .named n => n
      | _ => "unknown"
    let enumTy := "%enum." ++ enumName
    let ei := (s.lookupEnum enumName).get!
    let okVi := (ei.variants.find? fun v => v.name == "Ok").get!
    let okFieldTy := match okVi.fields.head? with
      | some fi => fi.ty
      | none => Ty.int
    let okFieldLLTy := tyToLLVM s okFieldTy
    let (s, tagPtr) := s.freshLocal
    let s := s.emit ("  " ++ tagPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 0")
    let (s, tag) := s.freshLocal
    let s := s.emit ("  " ++ tag ++ " = load i32, ptr " ++ tagPtr)
    let (s, okLabel) := s.freshLabel "try.ok"
    let (s, errLabel) := s.freshLabel "try.err"
    let (s, isOk) := s.freshLocal
    let s := s.emit ("  " ++ isOk ++ " = icmp eq i32 " ++ tag ++ ", " ++ toString okVi.tag)
    let s := s.emit ("  br i1 " ++ isOk ++ ", label %" ++ okLabel ++ ", label %" ++ errLabel)
    let s := s.emit (errLabel ++ ":")
    let (s, errVal) := s.freshLocal
    let s := s.emit ("  " ++ errVal ++ " = load " ++ enumTy ++ ", ptr " ++ scrPtr)
    let s := s.emit ("  ret " ++ enumTy ++ " " ++ errVal)
    let s := s.emit (okLabel ++ ":")
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr inbounds " ++ enumTy
      ++ ", ptr " ++ scrPtr ++ ", i32 0, i32 1")
    let variantTy := "%variant." ++ enumName ++ ".Ok"
    let (s, valueGep) := s.freshLocal
    let s := s.emit ("  " ++ valueGep ++ " = getelementptr inbounds " ++ variantTy
      ++ ", ptr " ++ payloadPtr ++ ", i32 0, i32 0")
    if isPassByPtr s okFieldTy then
      (s, valueGep)
    else
      let (s, value) := s.freshLocal
      let s := s.emit ("  " ++ value ++ " = load " ++ okFieldLLTy ++ ", ptr " ++ valueGep)
      (s, value)
  | .arrayLit _ elems =>
    let elemTy := match hintTy with
      | some (.array t _) => t
      | _ => match elems.head? with
        | some e => inferExprTy s e hintTy
        | none => Ty.int
    let n := elems.length
    let arrTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca " ++ arrTy)
    let elemLLTy := tyToLLVM s elemTy
    let elemPassByPtr := isPassByPtr s elemTy
    let (s, _) := elems.foldl (fun (acc : CodegenState × Nat) e =>
      let s := acc.1
      let idx := acc.2
      let (s, valReg) := genExpr s e (some elemTy)
      let (s, gepReg) := s.freshLocal
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrTy
        ++ ", ptr " ++ alloca ++ ", i32 0, i32 " ++ toString idx)
      let s := if elemPassByPtr then
        -- For nested arrays/structs, use memcpy instead of store
        let elemSize := tySize elemTy
        s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ gepReg ++ ", ptr " ++ valReg
          ++ ", i64 " ++ toString elemSize ++ ", i1 false)")
      else
        s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      (s, idx + 1)
    ) (s, 0)
    (s, alloca)
  | .arrayIndex _ arr index =>
    let arrTy := inferExprTy s arr
    let (elemTy, n) := match arrTy with
      | .array t sz => (t, sz)
      | _ => (.int, 0)
    let arrLLTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, arrPtr) := genExprAsPtr s arr
    let (s, idxReg) := genExpr s index
    -- Widen index to i64 if necessary
    let idxTy := inferExprTy s index
    let (s, idx64) := if intTyToLLVM idxTy != "i64" then
      let (s, widened) := s.freshLocal
      if isSignedInt idxTy then
        let s := s.emit ("  " ++ widened ++ " = sext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
      else
        let s := s.emit ("  " ++ widened ++ " = zext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
    else
      (s, idxReg)
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idx64)
    if isPassByPtr s elemTy then
      (s, gepReg)
    else
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ gepReg)
      (s, loaded)
  | .cast _ inner targetTy =>
    let (s, reg) := genExpr s inner
    let innerTy := inferExprTy s inner
    genCast s reg innerTy targetTy
  | .methodCall _ obj methodName _typeArgs args =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let typeName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | .typeVar n => (s.typeVarMapping.lookup n).getD ""
      | _ => ""
    let mangledName := typeName ++ "_" ++ methodName
    let (s, selfPtr) := genExprAsPtr s obj
    let (s, argRegs) := genExprList s args
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let allArgRegs := selfPtr :: argRegs
    let allArgTys := "ptr" :: argTys
    let argPairs := allArgTys.zip allArgRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .staticMethodCall _ typeName methodName _typeArgs args =>
    let mangledName := typeName ++ "_" ++ methodName
    let (s, argRegs) := genExprList s args
    let argTys := args.map fun arg => paramTyToLLVM s (inferExprTy s arg)
    let argPairs := argTys.zip argRegs
    let argStr := ", ".intercalate (argPairs.map fun (ty, r) => ty ++ " " ++ r)
    let retTy := normalizeTy ((s.fnRetTypes.lookup mangledName).getD .int)
    let retLLTy := tyToLLVM s retTy
    if retLLTy == "void" then
      let s := s.emit ("  call void @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, "0")
    else if isPassByPtr s retTy then
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ retLLTy)
      let s := s.emit ("  store " ++ retLLTy ++ " " ++ result ++ ", ptr " ++ alloca)
      (s, alloca)
    else
      let (s, result) := s.freshLocal
      let s := s.emit ("  " ++ result ++ " = call " ++ retLLTy ++ " @" ++ mangledName ++ "(" ++ argStr ++ ")")
      (s, result)
  | .arrowAccess _ obj field =>
    -- p->x: load pointer from variable, GEP to field, load
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | _ => objTy
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    match s.lookupFieldIndex structName field with
    | some (idx, fieldTy) =>
      let structTy := "%struct." ++ structName
      -- Get the heap pointer (ptr value stored in the variable)
      let (s, heapPtr) := genExpr s obj
      let (s, gepReg) := s.freshLocal
      let fieldLLTy := fieldTyToLLVM s fieldTy
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
        ++ ", ptr " ++ heapPtr ++ ", i32 0, i32 " ++ toString idx)
      if isPassByPtr s fieldTy then
        (s, gepReg)
      else
        let (s, loaded) := s.freshLocal
        let s := s.emit ("  " ++ loaded ++ " = load " ++ fieldLLTy ++ ", ptr " ++ gepReg)
        (s, loaded)
    | none =>
      let (s, reg) := s.freshLocal
      let s := s.emit ("  " ++ reg ++ " = add i64 0, 0 ; unknown field " ++ field)
      (s, reg)
  | .allocCall _ inner _allocExpr =>
    -- For now, just generate the inner call
    genExpr s inner hintTy
  | .whileExpr _ cond body elseBody =>
    -- while-as-expression: alloca result slot, loop with break storing value, else stores default
    let resultTy := inferExprTy s (.whileExpr default cond body elseBody) hintTy
    let resultLLTy := tyToLLVM s resultTy
    let (s, resultSlot) := s.freshLocal
    let s := s.emit ("  " ++ resultSlot ++ " = alloca " ++ resultLLTy)
    let (s, condLabel) := s.freshLabel "wexpr.cond"
    let (s, bodyLabel) := s.freshLabel "wexpr.body"
    let (s, elseLabel) := s.freshLabel "wexpr.else"
    let (s, exitLabel) := s.freshLabel "wexpr.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedSlot := s.loopResultSlot
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some condLabel, loopResultSlot := some resultSlot }
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ elseLabel)
    -- Body
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ condLabel)
    -- Else: generate all stmts except the last (which is the value expression)
    let s := s.emit (elseLabel ++ ":")
    let elseInit := elseBody.dropLast
    let s := genStmts s elseInit
    -- Get the value from the last expression in else body
    let (s, elseVal) := match elseBody.getLast? with
      | some (.expr _ e) => genExpr s e (some resultTy)
      | _ =>
        let (s, dummy) := s.freshLocal
        let s := s.emit ("  " ++ dummy ++ " = add i64 0, 0")
        (s, dummy)
    let s := s.emit ("  store " ++ resultLLTy ++ " " ++ elseVal ++ ", ptr " ++ resultSlot)
    let s := s.emit ("  br label %" ++ exitLabel)
    -- Exit
    let s := s.emit (exitLabel ++ ":")
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = load " ++ resultLLTy ++ ", ptr " ++ resultSlot)
    let s := { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopResultSlot := savedSlot }
    (s, result)
  | .fnRef _ fnName =>
    -- Function reference: just store the function pointer
    let (s, alloca) := s.freshLocal
    let s := s.emit ("  " ++ alloca ++ " = alloca ptr")
    let s := s.emit ("  store ptr @" ++ fnName ++ ", ptr " ++ alloca)
    (s, alloca)

/-- Generate a type cast in LLVM IR. -/
partial def genCast (s : CodegenState) (reg : String) (fromTy : Ty) (toTy : Ty) : CodegenState × String :=
  let (s, result) := s.freshLocal
  let fromLLTy := tyToLLVM s fromTy
  let toLLTy := tyToLLVM s toTy
  let fromBits := tyBitWidth fromTy
  let toBits := tyBitWidth toTy
  -- Same type? No-op (for pointers, use bitcast; for integers, use add)
  if fromLLTy == toLLTy then
    if fromLLTy == "ptr" then
      -- Pointer-to-pointer no-op: just reuse the register
      (s, reg)
    else
      let s := s.emit ("  " ++ result ++ " = add " ++ fromLLTy ++ " 0, " ++ reg)
      (s, result)
  -- Pointer <-> Pointer, or Pointer <-> Integer
  else if (match fromTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false) &&
          (match toTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false) then
    -- Pointer to pointer: both are `ptr` in opaque pointer mode, no-op
    (s, reg)
  else if (match fromTy with | .ptrMut _ | .ptrConst _ => true | _ => false) && isIntegerType toTy then
    let s := s.emit ("  " ++ result ++ " = ptrtoint ptr " ++ reg ++ " to " ++ toLLTy)
    (s, result)
  else if isIntegerType fromTy && (match toTy with | .ptrMut _ | .ptrConst _ => true | _ => false) then
    let s := s.emit ("  " ++ result ++ " = inttoptr " ++ fromLLTy ++ " " ++ reg ++ " to ptr")
    (s, result)
  -- Array to pointer: get pointer to first element
  else if (match fromTy with | .array _ _ => true | _ => false) &&
          (match toTy with | .ptrMut _ | .ptrConst _ => true | _ => false) then
    -- Array decays to pointer
    let s := s.emit ("  " ++ result ++ " = getelementptr " ++ fromLLTy ++ ", ptr " ++ reg ++ ", i32 0, i32 0")
    (s, result)
  -- Bool to integer
  else if fromTy == .bool && isIntegerType toTy then
    let s := s.emit ("  " ++ result ++ " = zext i1 " ++ reg ++ " to " ++ toLLTy)
    (s, result)
  -- Integer to Bool
  else if isIntegerType fromTy && toTy == .bool then
    let s := s.emit ("  " ++ result ++ " = icmp ne " ++ fromLLTy ++ " " ++ reg ++ ", 0")
    (s, result)
  -- Integer widening/narrowing
  else if isIntegerType fromTy && isIntegerType toTy then
    if fromBits < toBits then
      if isSignedInt fromTy then
        let s := s.emit ("  " ++ result ++ " = sext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
        (s, result)
      else
        let s := s.emit ("  " ++ result ++ " = zext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
        (s, result)
    else if fromBits > toBits then
      let s := s.emit ("  " ++ result ++ " = trunc " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      -- Same bit width, different signedness: no-op
      let s := s.emit ("  " ++ result ++ " = add " ++ toLLTy ++ " 0, " ++ reg)
      (s, result)
  -- Integer to float
  else if isIntegerType fromTy && isFloatType toTy then
    if isSignedInt fromTy then
      let s := s.emit ("  " ++ result ++ " = sitofp " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = uitofp " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Float to integer
  else if isFloatType fromTy && isIntegerType toTy then
    if isSignedInt toTy then
      let s := s.emit ("  " ++ result ++ " = fptosi " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = fptoui " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Float to float
  else if isFloatType fromTy && isFloatType toTy then
    if fromBits < toBits then
      let s := s.emit ("  " ++ result ++ " = fpext " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = fptrunc " ++ fromLLTy ++ " " ++ reg ++ " to " ++ toLLTy)
      (s, result)
  -- Char to integer
  else if fromTy == .char && isIntegerType toTy then
    if toBits > 8 then
      let s := s.emit ("  " ++ result ++ " = zext i8 " ++ reg ++ " to " ++ toLLTy)
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = add i8 0, " ++ reg)
      (s, result)
  -- Integer to char
  else if isIntegerType fromTy && toTy == .char then
    if fromBits > 8 then
      let s := s.emit ("  " ++ result ++ " = trunc " ++ fromLLTy ++ " " ++ reg ++ " to i8")
      (s, result)
    else
      let s := s.emit ("  " ++ result ++ " = add i8 0, " ++ reg)
      (s, result)
  -- Fallback: identity
  else
    let s := s.emit ("  " ++ result ++ " = add i64 0, " ++ reg ++ " ; fallback cast")
    (s, result)

/-- Get a pointer to an expression's storage (for struct GEP). -/
partial def genExprAsPtr (s : CodegenState) (e : Expr) : CodegenState × String :=
  match e with
  | .ident _ name =>
    match s.lookupVar name with
    | some alloca => (s, alloca)
    | none => (s, "%" ++ name)
  | .fieldAccess _ obj field =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | .string => "String"
      | _ => ""
    if structName != "" then
      match s.lookupFieldIndex structName field with
      | some (idx, _) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        (s, gepReg)
      | none => (s, "%undef")
    else (s, "%undef")
  | .strLit _ _ =>
    genExpr s e
  | .borrow _ _ | .borrowMut _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .deref _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .enumLit _ _ _ _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .match_ _ _ _ =>
    let (s, reg) := genExpr s e
    (s, reg)
  | .arrayLit _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .arrayIndex _ _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | .methodCall _ _ _ _ _ | .staticMethodCall _ _ _ _ _ | .cast _ _ _ | .arrowAccess _ _ _ | .allocCall _ _ _ =>
    let (s, ptr) := genExpr s e
    (s, ptr)
  | _ =>
    let (s, reg) := genExpr s e
    let ty := inferExprTy s e
    let llTy := tyToLLVM s ty
    let (s, tmp) := s.freshLocal
    let s := s.emit ("  " ++ tmp ++ " = alloca " ++ llTy)
    let s := s.emit ("  store " ++ llTy ++ " " ++ reg ++ ", ptr " ++ tmp)
    (s, tmp)

partial def genExprList (s : CodegenState) (args : List Expr) : CodegenState × List String :=
  match args with
  | [] => (s, [])
  | e :: rest =>
    let (s, reg) := genExpr s e
    let (s, regs) := genExprList s rest
    (s, reg :: regs)

/-- Generate expressions with type hints from parameter types. -/
partial def genExprListWithHints (s : CodegenState) (args : List Expr) (hints : List Ty) : CodegenState × List String :=
  match args, hints with
  | [], _ => (s, [])
  | e :: rest, h :: hRest =>
    let (s, reg) := genExpr s e (some h)
    let (s, regs) := genExprListWithHints s rest hRest
    (s, reg :: regs)
  | e :: rest, [] =>
    let (s, reg) := genExpr s e
    let (s, regs) := genExprListWithHints s rest []
    (s, reg :: regs)

/-- Generate LLVM IR for Vec<T> builtin calls. Returns (state, result_register). -/
partial def genVecBuiltinCall (s : CodegenState) (fnName : String) (typeArgs : List Ty) (args : List Expr) (hintTy : Option Ty := none) : CodegenState × String :=
  if fnName == "vec_new" then
    let elemTy := match typeArgs.head? with | some t => t | none => Ty.int
    let elemSize := tySizeOf s elemTy
    let initCap := 8
    let initBytes := initCap * elemSize
    -- Allocate initial buffer
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = call ptr @malloc(i64 " ++ toString initBytes ++ ")")
    -- Build Vec struct on stack: { buf, 0, 8 }
    let (s, vecAlloca) := s.freshLocal
    let s := s.emit ("  " ++ vecAlloca ++ " = alloca %struct.Vec")
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 0")
    let s := s.emit ("  store ptr " ++ buf ++ ", ptr " ++ bufPtr)
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 1")
    let s := s.emit ("  store i64 0, ptr " ++ lenPtr)
    let (s, capPtr) := s.freshLocal
    let s := s.emit ("  " ++ capPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecAlloca ++ ", i32 0, i32 2")
    let s := s.emit ("  store i64 " ++ toString initCap ++ ", ptr " ++ capPtr)
    (s, vecAlloca)
  else if fnName == "vec_push" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let valArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    -- Determine element type from vec arg
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    -- Get vec pointer (it's &mut Vec<T> so genExpr gives a ptr)
    let (s, vecPtr) := genExpr s vecArg
    -- Load len and cap
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    let (s, capPtr) := s.freshLocal
    let s := s.emit ("  " ++ capPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 2")
    let (s, cap) := s.freshLocal
    let s := s.emit ("  " ++ cap ++ " = load i64, ptr " ++ capPtr)
    -- Check if we need to grow: len >= cap
    let (s, needGrow) := s.freshLocal
    let s := s.emit ("  " ++ needGrow ++ " = icmp uge i64 " ++ len ++ ", " ++ cap)
    let (s, growLabel) := s.freshLabel "vec.grow"
    let (s, doneLabel) := s.freshLabel "vec.grow.done"
    let s := s.emit ("  br i1 " ++ needGrow ++ ", label %" ++ growLabel ++ ", label %" ++ doneLabel)
    -- Grow path: realloc to 2x capacity
    let s := s.emit (growLabel ++ ":")
    let (s, newCap) := s.freshLocal
    let s := s.emit ("  " ++ newCap ++ " = mul i64 " ++ cap ++ ", 2")
    let (s, newBytes) := s.freshLocal
    let s := s.emit ("  " ++ newBytes ++ " = mul i64 " ++ newCap ++ ", " ++ toString elemSize)
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, oldBuf) := s.freshLocal
    let s := s.emit ("  " ++ oldBuf ++ " = load ptr, ptr " ++ bufPtr)
    let (s, newBuf) := s.freshLocal
    let s := s.emit ("  " ++ newBuf ++ " = call ptr @realloc(ptr " ++ oldBuf ++ ", i64 " ++ newBytes ++ ")")
    let s := s.emit ("  store ptr " ++ newBuf ++ ", ptr " ++ bufPtr)
    let s := s.emit ("  store i64 " ++ newCap ++ ", ptr " ++ capPtr)
    let s := s.emit ("  br label %" ++ doneLabel)
    -- Done path: store value at buf[len]
    let s := s.emit (doneLabel ++ ":")
    let (s, bufPtr2) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr2 ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, curBuf) := s.freshLocal
    let s := s.emit ("  " ++ curBuf ++ " = load ptr, ptr " ++ bufPtr2)
    -- Reload len (same register is valid due to SSA dominance since both paths converge)
    let (s, curLen) := s.freshLocal
    let s := s.emit ("  " ++ curLen ++ " = load i64, ptr " ++ lenPtr)
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ curLen ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ curBuf ++ ", i64 " ++ offset)
    -- Generate value and store
    if isPassByPtr s elemTy then
      let (s, valPtr) := genExpr s valArg (some elemTy)
      let elemLLTy := tyToLLVM s elemTy
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ valPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ elemPtr)
      -- Increment len
      let (s, newLen) := s.freshLocal
      let s := s.emit ("  " ++ newLen ++ " = add i64 " ++ curLen ++ ", 1")
      let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
      (s, "0")
    else
      let (s, valReg) := genExpr s valArg (some elemTy)
      let elemLLTy := tyToLLVM s elemTy
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ elemPtr)
      -- Increment len
      let (s, newLen) := s.freshLocal
      let s := s.emit ("  " ++ newLen ++ " = add i64 " ++ curLen ++ ", 1")
      let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
      (s, "0")
  else if fnName == "vec_get" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .ref (.generic "Vec" [et]) => et
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    let (s, vecPtr) := genExpr s vecArg
    let (s, idxReg) := genExpr s idxArg (some .int)
    -- Load data buffer
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    -- Compute offset
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ idxReg ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    if isPassByPtr s elemTy then
      -- Return pointer to element (caller will load if needed)
      (s, elemPtr)
    else
      let (s, loaded) := s.freshLocal
      let s := s.emit ("  " ++ loaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ elemPtr)
      (s, loaded)
  else if fnName == "vec_set" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let idxArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit default 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    let (s, vecPtr) := genExpr s vecArg
    let (s, idxReg) := genExpr s idxArg (some .int)
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ idxReg ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    if isPassByPtr s elemTy then
      let (s, valPtr) := genExpr s valArg (some elemTy)
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ valPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ elemPtr)
      (s, "0")
    else
      let (s, valReg) := genExpr s valArg (some elemTy)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ elemPtr)
      (s, "0")
  else if fnName == "vec_len" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let (s, vecPtr) := genExpr s vecArg
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    (s, len)
  else if fnName == "vec_pop" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let vecArgTy := inferExprTy s vecArg
    let elemTy := match vecArgTy with
      | .refMut (.generic "Vec" [et]) => et
      | .generic "Vec" [et] => et
      | _ => .int
    let elemSize := tySizeOf s elemTy
    let elemLLTy := tyToLLVM s elemTy
    -- Look up Option enum info for payload size
    let optPayloadSize := match s.lookupEnum "Option" with
      | some ei => ei.payloadSize
      | none => 8
    let actualPayloadSize := if tySizeOf s elemTy > optPayloadSize then tySizeOf s elemTy else optPayloadSize
    let optTotalSize := 4 + actualPayloadSize
    let (s, vecPtr) := genExpr s vecArg
    -- Load len
    let (s, lenPtr) := s.freshLocal
    let s := s.emit ("  " ++ lenPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 1")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenPtr)
    -- Alloca for result Option
    let (s, optAlloca) := s.freshLocal
    let s := s.emit ("  " ++ optAlloca ++ " = alloca [" ++ toString optTotalSize ++ " x i8]")
    -- Check if len == 0
    let (s, isEmpty) := s.freshLocal
    let s := s.emit ("  " ++ isEmpty ++ " = icmp eq i64 " ++ len ++ ", 0")
    let (s, emptyLabel) := s.freshLabel "vec.pop.empty"
    let (s, someLabel) := s.freshLabel "vec.pop.some"
    let (s, doneLabel) := s.freshLabel "vec.pop.done"
    let s := s.emit ("  br i1 " ++ isEmpty ++ ", label %" ++ emptyLabel ++ ", label %" ++ someLabel)
    -- Empty: return None (tag=1)
    let s := s.emit (emptyLabel ++ ":")
    let s := s.emit ("  store i32 1, ptr " ++ optAlloca)
    let s := s.emit ("  br label %" ++ doneLabel)
    -- Some: decrement len, load last element, return Some
    let s := s.emit (someLabel ++ ":")
    let (s, newLen) := s.freshLocal
    let s := s.emit ("  " ++ newLen ++ " = sub i64 " ++ len ++ ", 1")
    let s := s.emit ("  store i64 " ++ newLen ++ ", ptr " ++ lenPtr)
    -- Load data buf
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    -- Load element at newLen offset
    let (s, offset) := s.freshLocal
    let s := s.emit ("  " ++ offset ++ " = mul i64 " ++ newLen ++ ", " ++ toString elemSize)
    let (s, elemPtr) := s.freshLocal
    let s := s.emit ("  " ++ elemPtr ++ " = getelementptr i8, ptr " ++ buf ++ ", i64 " ++ offset)
    -- Write tag=0 (Some)
    let s := s.emit ("  store i32 0, ptr " ++ optAlloca)
    -- Write payload at offset 4
    let (s, payloadPtr) := s.freshLocal
    let s := s.emit ("  " ++ payloadPtr ++ " = getelementptr i8, ptr " ++ optAlloca ++ ", i64 4")
    if isPassByPtr s elemTy then
      let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ payloadPtr ++ ", ptr " ++ elemPtr ++ ", i64 " ++ toString elemSize ++ ", i1 false)")
      let s := s.emit ("  br label %" ++ doneLabel)
      let s := s.emit (doneLabel ++ ":")
      (s, optAlloca)
    else
      let (s, valLoaded) := s.freshLocal
      let s := s.emit ("  " ++ valLoaded ++ " = load " ++ elemLLTy ++ ", ptr " ++ elemPtr)
      let s := s.emit ("  store " ++ elemLLTy ++ " " ++ valLoaded ++ ", ptr " ++ payloadPtr)
      let s := s.emit ("  br label %" ++ doneLabel)
      let s := s.emit (doneLabel ++ ":")
      (s, optAlloca)
  else if fnName == "vec_free" then
    let vecArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let (s, vecPtr) := genExpr s vecArg
    -- Load data buf and free it
    let (s, bufPtr) := s.freshLocal
    let s := s.emit ("  " ++ bufPtr ++ " = getelementptr inbounds %struct.Vec, ptr " ++ vecPtr ++ ", i32 0, i32 0")
    let (s, buf) := s.freshLocal
    let s := s.emit ("  " ++ buf ++ " = load ptr, ptr " ++ bufPtr)
    let s := s.emit ("  call void @free(ptr " ++ buf ++ ")")
    (s, "0")
  else
    (s, "0")

/-- Generate LLVM IR for HashMap<K,V> builtin calls.
    Calls pre-emitted helper functions __hashmap_int_* or __hashmap_str_*. -/
partial def genHashMapBuiltinCall (s : CodegenState) (fnName : String) (typeArgs : List Ty) (args : List Expr) (_hintTy : Option Ty := none) : CodegenState × String :=
  if fnName == "map_new" then
    let kTy := match typeArgs with | t :: _ => t | [] => Ty.int
    let vTy := match typeArgs with | _ :: t :: _ => t | _ => Ty.int
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    -- Call __hashmap_<pfx>_new(kSize, vSize) → returns ptr to HashMap on heap
    let (s, mapAlloca) := s.freshLocal
    let s := s.emit ("  " ++ mapAlloca ++ " = alloca %struct.HashMap")
    let (s, _ret) := s.freshLocal
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_new(ptr " ++ mapAlloca ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, mapAlloca)
  else if fnName == "map_insert" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    let valArg := match args with | _ :: _ :: c :: _ => c | _ => Expr.intLit default 0
    let mapArgTy := inferExprTy s mapArg
    let (kTy, vTy) := match mapArgTy with
      | .refMut (.generic "HashMap" [k, v]) => (k, v)
      | _ => (.int, .int)
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, valReg) := genExpr s valArg (some vTy)
    -- For scalar keys, store to temp alloca so we can pass ptr
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let (s, valPtr) := if isPassByPtr s vTy then (s, valReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s vTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s vTy ++ " " ++ valReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_insert(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", ptr " ++ valPtr ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, "0")
  else if fnName == "map_get" || fnName == "map_remove" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    let mapArgTy := inferExprTy s mapArg
    let (kTy, vTy) := match mapArgTy with
      | .ref (.generic "HashMap" [k, v]) => (k, v)
      | .refMut (.generic "HashMap" [k, v]) => (k, v)
      | _ => (.int, .int)
    let kSize := tySizeOf s kTy
    let vSize := tySizeOf s vTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    -- Allocate result Option (tag + payload)
    let optPayloadSize := match s.lookupEnum "Option" with
      | some ei => ei.payloadSize
      | none => 8
    let actualPSize := if vSize > optPayloadSize then vSize else optPayloadSize
    let optSize := 4 + actualPSize
    let (s, optAlloca) := s.freshLocal
    let s := s.emit ("  " ++ optAlloca ++ " = alloca [" ++ toString optSize ++ " x i8]")
    let opName := if fnName == "map_remove" then "remove" else "get"
    let s := s.emit ("  call void @__hashmap_" ++ pfx ++ "_" ++ opName ++ "(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", ptr " ++ optAlloca ++ ", i64 " ++ toString kSize ++ ", i64 " ++ toString vSize ++ ")")
    (s, optAlloca)
  else if fnName == "map_contains" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let keyArg := match args with | _ :: b :: _ => b | _ => Expr.intLit default 0
    let mapArgTy := inferExprTy s mapArg
    let kTy := match mapArgTy with
      | .ref (.generic "HashMap" [k, _]) => k
      | .refMut (.generic "HashMap" [k, _]) => k
      | _ => .int
    let kSize := tySizeOf s kTy
    let pfx := match kTy with | .string => "str" | _ => "int"
    let (s, mapPtr) := genExpr s mapArg
    let (s, keyReg) := genExpr s keyArg (some kTy)
    let (s, keyPtr) := if isPassByPtr s kTy then (s, keyReg) else
      let (s2, tmp) := s.freshLocal
      let s2 := s2.emit ("  " ++ tmp ++ " = alloca " ++ tyToLLVM s kTy)
      let s2 := s2.emit ("  store " ++ tyToLLVM s kTy ++ " " ++ keyReg ++ ", ptr " ++ tmp)
      (s2, tmp)
    let (s, result) := s.freshLocal
    let s := s.emit ("  " ++ result ++ " = call i1 @__hashmap_" ++ pfx ++ "_contains(ptr " ++ mapPtr ++ ", ptr " ++ keyPtr ++ ", i64 " ++ toString kSize ++ ")")
    (s, result)
  else if fnName == "map_len" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let (s, mapPtr) := genExpr s mapArg
    let (s, lenFld) := s.freshLocal
    let s := s.emit ("  " ++ lenFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 3")
    let (s, len) := s.freshLocal
    let s := s.emit ("  " ++ len ++ " = load i64, ptr " ++ lenFld)
    (s, len)
  else if fnName == "map_free" then
    let mapArg := match args with | a :: _ => a | [] => Expr.intLit default 0
    let (s, mapPtr) := genExpr s mapArg
    let (s, kFld) := s.freshLocal
    let s := s.emit ("  " ++ kFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 0")
    let (s, kBuf) := s.freshLocal
    let s := s.emit ("  " ++ kBuf ++ " = load ptr, ptr " ++ kFld)
    let s := s.emit ("  call void @free(ptr " ++ kBuf ++ ")")
    let (s, vFld) := s.freshLocal
    let s := s.emit ("  " ++ vFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 1")
    let (s, vBuf) := s.freshLocal
    let s := s.emit ("  " ++ vBuf ++ " = load ptr, ptr " ++ vFld)
    let s := s.emit ("  call void @free(ptr " ++ vBuf ++ ")")
    let (s, fFld) := s.freshLocal
    let s := s.emit ("  " ++ fFld ++ " = getelementptr inbounds %struct.HashMap, ptr " ++ mapPtr ++ ", i32 0, i32 2")
    let (s, fBuf) := s.freshLocal
    let s := s.emit ("  " ++ fBuf ++ " = load ptr, ptr " ++ fFld)
    let s := s.emit ("  call void @free(ptr " ++ fBuf ++ ")")
    (s, "0")
  else
    (s, "0")

partial def genStmts (s : CodegenState) (stmts : List Stmt) : CodegenState :=
  match stmts with
  | [] => s
  | stmt :: rest => genStmts (genStmt s stmt) rest

partial def genStmt (s : CodegenState) (stmt : Stmt) : CodegenState :=
  match stmt with
  | .letDecl _ name _mutable ty value =>
    let exprTy := normalizeTy (match ty with
      | some t => t
      | none => inferExprTy s value)
    if isPassByPtr s exprTy then
      let (s, valPtr) := genExpr s value (some exprTy)
      let s := s.addVar name valPtr
      s.addVarType name exprTy
    else
      let llTy := tyToLLVM s exprTy
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
      let (s, valReg) := genExpr s value (some exprTy)
      -- Check if the generated value's type differs from expected (e.g. generic fn returning i64 but we want i32)
      let actualTy := inferExprTy s value (some exprTy)
      let actualLLTy := tyToLLVM s actualTy
      let (s, finalReg) := if actualLLTy != llTy && actualLLTy != "void" && llTy != "void" then
        -- Direct trunc/ext for integer type mismatches (avoids genCast issues)
        let fromBits := tyBitWidth (match actualTy with | .typeVar _ => Ty.int | t => t)
        let toBits := tyBitWidth exprTy
        if fromBits > toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = trunc " ++ actualLLTy ++ " " ++ valReg ++ " to " ++ llTy)
          (s, r)
        else if fromBits < toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = zext " ++ actualLLTy ++ " " ++ valReg ++ " to " ++ llTy)
          (s, r)
        else
          (s, valReg)
      else
        (s, valReg)
      let s := s.emit ("  store " ++ llTy ++ " " ++ finalReg ++ ", ptr " ++ alloca)
      let s := s.addVar name alloca
      s.addVarType name exprTy
  | .assign _ name value =>
    match s.lookupVar name with
    | some alloca =>
      let ty := (s.lookupVarType name).getD .int
      if isPassByPtr s ty then
        let (s, valPtr) := genExpr s value (some ty)
        let s := { s with vars := s.vars.map fun (n, v) =>
          if n == name then (n, valPtr) else (n, v) }
        s
      else
        let llTy := tyToLLVM s ty
        let (s, valReg) := genExpr s value (some ty)
        s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ alloca)
    | none => s.emit ("; ERROR: unknown variable " ++ name)
  | .return_ _ (some value) =>
    let retTy := s.currentRetTy
    let (s, reg) := genExpr s value (some retTy)
    -- Emit all deferred expressions before returning
    let s := emitAllDeferred s
    if isPassByPtr s retTy then
      let llTy := tyToLLVM s retTy
      let (s, val) := s.freshLocal
      let s := s.emit ("  " ++ val ++ " = load " ++ llTy ++ ", ptr " ++ reg)
      s.emit ("  ret " ++ llTy ++ " " ++ val)
    else
      let llTy := tyToLLVM s retTy
      -- Check if the value type differs (e.g. generic returning i64 but ret is i32)
      let valTy := inferExprTy s value (some retTy)
      let valLLTy := tyToLLVM s valTy
      let (s, finalReg) := if valLLTy != llTy && valLLTy != "void" && llTy != "void" then
        let fromBits := tyBitWidth valTy
        let toBits := tyBitWidth retTy
        if fromBits > toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = trunc " ++ valLLTy ++ " " ++ reg ++ " to " ++ llTy)
          (s, r)
        else if fromBits < toBits then
          let (s, r) := s.freshLocal
          let s := s.emit ("  " ++ r ++ " = sext " ++ valLLTy ++ " " ++ reg ++ " to " ++ llTy)
          (s, r)
        else (s, reg)
      else (s, reg)
      s.emit ("  ret " ++ llTy ++ " " ++ finalReg)
  | .return_ _ none =>
    let s := emitAllDeferred s
    s.emit "  ret void"
  | .expr _ e =>
    let (s, _) := genExpr s e
    s
  | .ifElse _ cond thenBody elseBody =>
    let (s, condReg) := genExpr s cond
    -- If condition is not i1, convert to i1
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let (s, thenLabel) := s.freshLabel "then"
    let (s, elseLabel) := s.freshLabel "else"
    let (s, mergeLabel) := s.freshLabel "merge"
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ thenLabel ++ ", label %" ++ elseLabel)
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
    if thenReturns && elseReturns then s
    else s.emit (mergeLabel ++ ":")
  | .fieldAssign _ obj field value =>
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .ref t => t
      | .refMut t => t
      | t => t
    match innerTy with
    | .named structName =>
      match s.lookupFieldIndex structName field with
      | some (idx, fieldTy) =>
        let structTy := "%struct." ++ structName
        let (s, objPtr) := match objTy with
          | .ref _ | .refMut _ => genExpr s obj
          | _ => genExprAsPtr s obj
        let (s, gepReg) := s.freshLocal
        let fieldLLTy := fieldTyToLLVM s fieldTy
        let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
          ++ ", ptr " ++ objPtr ++ ", i32 0, i32 " ++ toString idx)
        let (s, valReg) := genExpr s value (some fieldTy)
        s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
      | none => s.emit ("; ERROR: unknown field " ++ field)
    | _ => s.emit ("; ERROR: field assign on non-struct")
  | .derefAssign _ target value =>
    let (s, ptr) := genExpr s target
    let targetTy := inferExprTy s target
    let pointeeTy := match targetTy with
      | .refMut t => t
      | .ref t => t
      | .ptrMut t => t
      | .ptrConst t => t
      | t => t
    let (s, valReg) := genExpr s value (some pointeeTy)
    let llTy := tyToLLVM s pointeeTy
    s.emit ("  store " ++ llTy ++ " " ++ valReg ++ ", ptr " ++ ptr)
  | .arrayIndexAssign _ arr index value =>
    let arrTy := inferExprTy s arr
    let (elemTy, n) := match arrTy with
      | .array t sz => (t, sz)
      | _ => (.int, 0)
    let arrLLTy := "[" ++ toString n ++ " x " ++ tyToLLVM s elemTy ++ "]"
    let (s, arrPtr) := genExprAsPtr s arr
    let (s, idxReg) := genExpr s index
    let idxTy := inferExprTy s index
    let (s, idx64) := if intTyToLLVM idxTy != "i64" then
      let (s, widened) := s.freshLocal
      if isSignedInt idxTy then
        let s := s.emit ("  " ++ widened ++ " = sext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
      else
        let s := s.emit ("  " ++ widened ++ " = zext " ++ intTyToLLVM idxTy ++ " " ++ idxReg ++ " to i64")
        (s, widened)
    else
      (s, idxReg)
    let (s, gepReg) := s.freshLocal
    let elemLLTy := tyToLLVM s elemTy
    let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ arrLLTy
      ++ ", ptr " ++ arrPtr ++ ", i32 0, i64 " ++ idx64)
    if isPassByPtr s elemTy then
      -- For arrays of arrays, need to memcpy
      let (s, valPtr) := genExpr s value (some elemTy)
      let tySz := tySize elemTy
      let s := s.emit ("  call void @llvm.memcpy.p0.p0.i64(ptr " ++ gepReg ++ ", ptr " ++ valPtr ++ ", i64 " ++ toString tySz ++ ", i1 false)")
      s
    else
      let (s, valReg) := genExpr s value (some elemTy)
      s.emit ("  store " ++ elemLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
  | .while_ _ cond body lbl =>
    let (s, condLabel) := s.freshLabel "while.cond"
    let (s, bodyLabel) := s.freshLabel "while.body"
    let (s, exitLabel) := s.freshLabel "while.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedLabelMap := s.loopLabelMap
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some condLabel }
    let s := match lbl with
      | some l => { s with loopLabelMap := (l, exitLabel, condLabel) :: s.loopLabelMap }
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ exitLabel)
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (exitLabel ++ ":")
    { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopLabelMap := savedLabelMap }
  | .forLoop _ init cond step body lbl =>
    -- Generate init
    let s := match init with
      | some initStmt => genStmt s initStmt
      | none => s
    -- for loop = while with step
    let (s, condLabel) := s.freshLabel "for.cond"
    let (s, bodyLabel) := s.freshLabel "for.body"
    let (s, stepLabel) := s.freshLabel "for.step"
    let (s, exitLabel) := s.freshLabel "for.exit"
    let savedExit := s.loopExitLabel
    let savedCont := s.loopContLabel
    let savedLabelMap := s.loopLabelMap
    let s := { s with loopExitLabel := some exitLabel, loopContLabel := some stepLabel }
    let s := match lbl with
      | some l => { s with loopLabelMap := (l, exitLabel, stepLabel) :: s.loopLabelMap }
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (condLabel ++ ":")
    let (s, condReg) := genExpr s cond
    let condTy := inferExprTy s cond
    let (s, condBool) := if condTy != .bool then
      let (s, cmp) := s.freshLocal
      let llTy := intTyToLLVM condTy
      let s := s.emit ("  " ++ cmp ++ " = icmp ne " ++ llTy ++ " " ++ condReg ++ ", 0")
      (s, cmp)
    else
      (s, condReg)
    let s := s.emit ("  br i1 " ++ condBool ++ ", label %" ++ bodyLabel ++ ", label %" ++ exitLabel)
    let s := s.emit (bodyLabel ++ ":")
    let s := genStmts s body
    let s := s.emit ("  br label %" ++ stepLabel)
    -- Generate step
    let s := s.emit (stepLabel ++ ":")
    let s := match step with
      | some stepStmt => genStmt s stepStmt
      | none => s
    let s := s.emit ("  br label %" ++ condLabel)
    let s := s.emit (exitLabel ++ ":")
    { s with loopExitLabel := savedExit, loopContLabel := savedCont, loopLabelMap := savedLabelMap }
  | .break_ _ value lbl =>
    -- Store break value to result slot if present (while-as-expression)
    let s := match value, s.loopResultSlot with
    | some expr, some slot =>
      let resultTy := inferExprTy s expr
      let resultLLTy := tyToLLVM s resultTy
      let (s, valReg) := genExpr s expr
      s.emit ("  store " ++ resultLLTy ++ " " ++ valReg ++ ", ptr " ++ slot)
    | _, _ => s
    -- Find the target label: if labeled, look up in loopLabelMap; otherwise use current loop
    let targetExit := match lbl with
    | some l => match s.loopLabelMap.find? fun (name, _, _) => name == l with
      | some (_, exit, _) => some exit
      | none => s.loopExitLabel
    | none => s.loopExitLabel
    match targetExit with
    | some target =>
      let s := s.emit ("  br label %" ++ target)
      let (s, deadLabel) := s.freshLabel "break.dead"
      s.emit (deadLabel ++ ":")
    | none => s
  | .continue_ _ lbl =>
    let targetCont := match lbl with
    | some l => match s.loopLabelMap.find? fun (name, _, _) => name == l with
      | some (_, _, cont) => some cont
      | none => s.loopContLabel
    | none => s.loopContLabel
    match targetCont with
    | some target =>
      let s := s.emit ("  br label %" ++ target)
      let (s, deadLabel) := s.freshLabel "cont.dead"
      s.emit (deadLabel ++ ":")
    | none => s
  | .defer _ body =>
    -- Push deferred expression onto current scope's defer list
    let deferStack := s.deferStack
    match deferStack with
    | current :: rest =>
      { s with deferStack := (body :: current) :: rest }
    | [] =>
      { s with deferStack := [[body]] }
  | .borrowIn _ _var ref _region _isMut body =>
    -- Regions are erased at codegen — ref = pointer to var's alloca
    -- The var name is in _var, but we need to find the ref source
    -- For stack values: ref = pointer to var's alloca
    let varName := _var
    let refPtr := match s.lookupVar varName with
      | some alloca => alloca
      | none => "%undef"
    -- Map ref to the same alloca
    let s := s.addVar ref refPtr
    let varTy := (s.lookupVarType varName).getD .int
    let refTy := if _isMut then Ty.refMut varTy else Ty.ref varTy
    let s := s.addVarType ref refTy
    genStmts s body
  | .arrowAssign _ obj field value =>
    -- p->x = val: load heap ptr, GEP to field, store
    let objTy := inferExprTy s obj
    let innerTy := match objTy with
      | .heap t => t
      | .heapArray t => t
      | _ => objTy
    let structName := match innerTy with
      | .named n => n
      | .generic n _ => n
      | _ => ""
    match s.lookupFieldIndex structName field with
    | some (idx, fieldTy) =>
      let structTy := "%struct." ++ structName
      let (s, heapPtr) := genExpr s obj
      let (s, gepReg) := s.freshLocal
      let fieldLLTy := fieldTyToLLVM s fieldTy
      let s := s.emit ("  " ++ gepReg ++ " = getelementptr inbounds " ++ structTy
        ++ ", ptr " ++ heapPtr ++ ", i32 0, i32 " ++ toString idx)
      let (s, valReg) := genExpr s value (some fieldTy)
      s.emit ("  store " ++ fieldLLTy ++ " " ++ valReg ++ ", ptr " ++ gepReg)
    | none => s.emit ("; ERROR: unknown field " ++ field)

/-- Emit all deferred expressions in the current scope (LIFO order). -/
partial def emitDeferred (s : CodegenState) (deferred : List Expr) : CodegenState :=
  match deferred with
  | [] => s
  | e :: rest =>
    let (s, _) := genExpr s e
    emitDeferred s rest

/-- Emit all deferred expressions from ALL scope levels, innermost first. -/
partial def emitAllDeferred (s : CodegenState) : CodegenState :=
  s.deferStack.foldl (fun s scope => emitDeferred s scope) s

end

def genFnParams (s : CodegenState) (params : List Param) : CodegenState :=
  match params with
  | [] => s
  | p :: rest =>
    let pty := normalizeTy p.ty
    if isPassByPtr s pty then
      let s := s.addVar p.name ("%" ++ p.name)
      let s := s.addVarType p.name pty
      genFnParams s rest
    else
      let llTy := tyToLLVM s pty
      let (s, alloca) := s.freshLocal
      let s := s.emit ("  " ++ alloca ++ " = alloca " ++ llTy)
      let s := s.emit ("  store " ++ llTy ++ " %" ++ p.name ++ ", ptr " ++ alloca)
      let s := s.addVar p.name alloca
      let s := s.addVarType p.name pty
      genFnParams s rest

def genFn (s : CodegenState) (f : FnDef) (hasMainWrapper : Bool := false) : CodegenState :=
  let normalizedRetTy := normalizeTy f.retTy
  let retTy := tyToLLVM s normalizedRetTy
  let fnName := if f.name == "main" && hasMainWrapper then "concrete_main" else f.name
  let paramStr := ", ".intercalate (f.params.map fun p => paramTyToLLVM s (normalizeTy p.ty) ++ " %" ++ p.name)
  let s := s.emit ("define " ++ retTy ++ " @" ++ fnName ++ "(" ++ paramStr ++ ") {")
  let savedDeferStack := s.deferStack
  let s := { s with currentRetTy := normalizedRetTy, deferStack := [[]] }
  let s := genFnParams s f.params
  let s := genStmts s f.body
  let s := if !stmtListHasReturn f.body then
    let s := emitAllDeferred s
    if retTy == "void" then s.emit "  ret void"
    else s.emit ("  ret " ++ retTy ++ " 0")
  else s
  let s := { s with deferStack := savedDeferStack }
  s.emit "}\n"

/-- Substitute type variables using a mapping (for generic enum/struct instantiation). -/
private def enumerateFields (fields : List StructField) (idx : Nat := 0) : List FieldInfo :=
  match fields with
  | [] => []
  | f :: rest => { name := f.name, ty := normalizeFieldTy f.ty, index := idx } :: enumerateFields rest (idx + 1)

def buildStructDefs (structs : List StructDef) : List StructInfo :=
  structs.map fun sd =>
    { name := sd.name, fields := enumerateFields sd.fields, typeParams := sd.typeParams }

private def variantPayloadSize (fields : List StructField) : Nat :=
  fields.foldl (fun acc f => acc + tySize f.ty) 0

private def enumerateVariants (variants : List EnumVariant) (tag : Nat := 0) : List EnumVariantInfo :=
  match variants with
  | [] => []
  | v :: rest =>
    { name := v.name, tag, fields := enumerateFields v.fields } :: enumerateVariants rest (tag + 1)

def buildEnumDefs (enums : List EnumDef) : List EnumInfo :=
  enums.map fun ed =>
    let variants := enumerateVariants ed.variants
    let maxPayload := variants.foldl (fun (acc : Nat) v =>
      let sz := v.fields.foldl (fun (a : Nat) f => a + tySize f.ty) 0
      if sz > acc then sz else acc
    ) (0 : Nat)
    { name := ed.name, variants, payloadSize := maxPayload, typeParams := ed.typeParams }

def genStructTypes (s : CodegenState) (structs : List StructDef) : CodegenState :=
  structs.foldl (fun s sd =>
    let fieldTypes := ", ".intercalate (sd.fields.map fun f => tyToLLVM s f.ty)
    s.emit ("%struct." ++ sd.name ++ " = type { " ++ fieldTypes ++ " }")
  ) s

def genEnumTypes (s : CodegenState) (enums : List EnumDef) : CodegenState :=
  enums.foldl (fun s ed =>
    let ei := (s.lookupEnum ed.name).get!
    let s := ed.variants.foldl (fun s v =>
      let vi := (ei.variants.find? fun vi => vi.name == v.name).get!
      if vi.fields.isEmpty then
        -- Fieldless variant: emit empty type
        s.emit ("%variant." ++ ed.name ++ "." ++ v.name ++ " = type {}")
      else
        let fieldTypes := ", ".intercalate (vi.fields.map fun fi => fieldTyToLLVM s fi.ty)
        s.emit ("%variant." ++ ed.name ++ "." ++ v.name ++ " = type { " ++ fieldTypes ++ " }")
    ) s
    let payloadBytes := if ei.payloadSize == 0 then 1 else ei.payloadSize
    s.emit ("%enum." ++ ed.name ++ " = type { i32, [" ++ toString payloadBytes ++ " x i8] }")
  ) s

end Concrete
