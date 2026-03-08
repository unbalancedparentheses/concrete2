import Concrete.SSA
import Concrete.Core
import Concrete.Codegen.Builtins

namespace Concrete

/-! ## EmitSSA — SSA→LLVM IR codegen

New codegen that walks SModule / SFnDef / SBlock / SInst / STerm and emits LLVM IR text.
Fundamentally simpler than the AST-based codegen because:
- No structured control flow to lower (already done by Lower.lean)
- No type inference needed (every SVal carries its Ty)
- No monomorphization (already done by Mono.lean)
- Direct 1:1 mapping from SSA instructions to LLVM IR
-/

-- ============================================================
-- Emit state
-- ============================================================

structure EmitSSAState where
  output : String := ""
  structDefs : List CStructDef := []
  enumDefs : List CEnumDef := []
  stringLitCounter : Nat := 0
  stringGlobals : String := ""
  localCounter : Nat := 0
  /-- Registers known to be LLVM pointers (alloca/gep/struct params). -/
  ptrRegs : List String := []
  /-- Type names already emitted (for dedup across modules). -/
  emittedTypes : List String := []
  /-- String literal name → length (for building %struct.String at use sites). -/
  stringLengths : List (String × Nat) := []
  /-- Parameter names of the current function (for indirect call detection). -/
  fnParams : List (String × Ty) := []

private def emit (s : EmitSSAState) (line : String) : EmitSSAState :=
  { s with output := s.output ++ line ++ "\n" }

private def freshLocal (s : EmitSSAState) : EmitSSAState × String :=
  let name := "%ssa.t" ++ toString s.localCounter
  ({ s with localCounter := s.localCounter + 1 }, name)

private def markPtr (s : EmitSSAState) (name : String) : EmitSSAState :=
  { s with ptrRegs := name :: s.ptrRegs }

private def isKnownPtr (s : EmitSSAState) (v : SVal) : Bool :=
  match v with
  | .reg name _ => s.ptrRegs.contains name
  | _ => false

-- ============================================================
-- Ty → LLVM type string
-- ============================================================

private def ssaLookupStruct (s : EmitSSAState) (name : String) : Option CStructDef :=
  s.structDefs.find? fun sd => sd.name == name

private def ssaLookupEnum (s : EmitSSAState) (name : String) : Option CEnumDef :=
  s.enumDefs.find? fun ed => ed.name == name

/-- Map a Concrete type to its LLVM IR type string. -/
def ssaTyToLLVM (s : EmitSSAState) : Ty → String
  | .int => "i64"
  | .uint => "i64"
  | .i8 | .u8 => "i8"
  | .i16 | .u16 => "i16"
  | .i32 | .u32 => "i32"
  | .bool => "i1"
  | .float64 => "double"
  | .float32 => "float"
  | .char => "i8"
  | .unit => "void"
  | .string => "%struct.String"
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => "ptr"
  | .generic "Heap" _ | .heap _ => "ptr"
  | .generic "HeapArray" _ | .heapArray _ => "ptr"
  | .generic "Vec" _ => "%struct.Vec"
  | .generic "HashMap" _ => "%struct.HashMap"
  | .generic name _ =>
    match ssaLookupEnum s name with
    | some _ => "%enum." ++ name
    | none => "%struct." ++ name
  | .typeVar _ => "i64"
  | .array elem n => "[" ++ toString n ++ " x " ++ ssaTyToLLVM s elem ++ "]"
  | .fn_ _ _ _ => "ptr"
  | .never => "void"
  | .placeholder => "i64"
  | .named name =>
    match ssaLookupStruct s name with
    | some _ => "%struct." ++ name
    | none =>
      match ssaLookupEnum s name with
      | some _ => "%enum." ++ name
      | none => "i64"

/-- Is this type passed by pointer in function calls? -/
private def ssaIsPassByPtr (s : EmitSSAState) (ty : Ty) : Bool :=
  match ty with
  | .string => true
  | .ref _ | .refMut _ => true
  | .array _ _ => true
  | .fn_ _ _ _ | .heap _ | .heapArray _ => false
  | .named name => (ssaLookupStruct s name).isSome || (ssaLookupEnum s name).isSome
  | .generic "Vec" _ | .generic "HashMap" _ => true
  | .generic name _ => (ssaLookupStruct s name).isSome || (ssaLookupEnum s name).isSome
  | _ => false

/-- LLVM type for function parameters (structs passed as ptr). -/
private def ssaParamTyToLLVM (s : EmitSSAState) (ty : Ty) : String :=
  if ssaIsPassByPtr s ty then "ptr"
  else ssaTyToLLVM s ty

/-- Integer LLVM type for arithmetic. -/
private def ssaIntTyToLLVM : Ty → String
  | .int | .uint => "i64"
  | .i8 | .u8 => "i8"
  | .i16 | .u16 => "i16"
  | .i32 | .u32 => "i32"
  | .char => "i8"
  | .bool => "i1"
  | _ => "i64"

/-- Float LLVM type. -/
private def ssaFloatTyToLLVM : Ty → String
  | .float32 => "float"
  | _ => "double"

private def ssaIsSignedInt : Ty → Bool
  | .int | .i8 | .i16 | .i32 => true
  | _ => false

private def isIntegerTy : Ty → Bool
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
  | _ => false

private def isFloatTy : Ty → Bool
  | .float32 | .float64 => true
  | _ => false

/-- Get byte size of a type for enum layout. -/
private def ssaTySize : Ty → Nat
  | .int | .uint | .float64 => 8
  | .i32 | .u32 | .float32 => 4
  | .i16 | .u16 => 2
  | .i8 | .u8 | .char | .bool => 1
  | .unit => 0
  | .string => 16
  | .named _ => 8
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => 8
  | .generic "Vec" _ => 24
  | .generic "HashMap" _ => 40
  | .generic _ _ | .typeVar _ => 8
  | .fn_ _ _ _ | .heap _ | .heapArray _ => 8
  | .never | .placeholder => 0
  | .array elem n => ssaTySize elem * n

private def ssaEscapeCharForLLVM (c : Char) : String :=
  if c == '\n' then "\\0A"
  else if c == '\t' then "\\09"
  else if c == '\\' then "\\5C"
  else if c == '"' then "\\22"
  else if c.toNat == 0 then "\\00"
  else if c.toNat >= 32 && c.toNat <= 126 then String.singleton c
  else
    let n := c.toNat
    let hi := n / 16
    let lo := n % 16
    let hexDigit (d : Nat) : Char :=
      if d < 10 then Char.ofNat (d + '0'.toNat)
      else Char.ofNat (d - 10 + 'A'.toNat)
    "\\" ++ String.ofList [hexDigit hi, hexDigit lo]

private def ssaEscapeStringForLLVM (str : String) : String :=
  str.foldl (fun acc c => acc ++ ssaEscapeCharForLLVM c) ""

-- ============================================================
-- Emit SVal
-- ============================================================

private def emitSVal (_s : EmitSSAState) (v : SVal) : String :=
  match v with
  | .reg name _ => "%" ++ name
  | .intConst val _ => toString val
  | .floatConst val _ =>
    let str := toString val
    if str.any (· == '.') || str.any (· == 'e') || str.any (· == 'E') then str else str ++ ".0"
  | .boolConst b => if b then "1" else "0"
  | .strConst name => "@" ++ name
  | .unit => "void"

-- ============================================================
-- Materialize string constants and ensure pointers
-- ============================================================

/-- Materialize a string constant as a %struct.String pointer.
    Allocates a %struct.String, stores {ptr to chars, length}, returns ptr. -/
private def materializeStrConst (s : EmitSSAState) (name : String) : EmitSSAState × String :=
  let strLen := (s.stringLengths.find? fun (n, _) => n == name).map (·.2) |>.getD 0
  let arrLen := strLen + 1  -- includes null terminator in the global
  let (s, gepTmp) := freshLocal s
  let s := emit s s!"  {gepTmp} = getelementptr [{arrLen} x i8], ptr @{name}, i32 0, i32 0"
  -- Heap-allocate a copy so drop_string can safely free it
  let (s, heapBuf) := freshLocal s
  let s := emit s s!"  {heapBuf} = call ptr @malloc(i64 {arrLen})"
  let s := emit s s!"  call void @llvm.memcpy.p0.p0.i64(ptr {heapBuf}, ptr {gepTmp}, i64 {arrLen}, i1 false)"
  let (s, strTmp) := freshLocal s
  let s := emit s s!"  {strTmp} = alloca %struct.String"
  let (s, ptrField) := freshLocal s
  let s := emit s s!"  {ptrField} = getelementptr %struct.String, ptr {strTmp}, i32 0, i32 0"
  let s := emit s s!"  store ptr {heapBuf}, ptr {ptrField}"
  let (s, lenField) := freshLocal s
  let s := emit s s!"  {lenField} = getelementptr %struct.String, ptr {strTmp}, i32 0, i32 1"
  let s := emit s s!"  store i64 {strLen}, ptr {lenField}"
  (s, strTmp)

/-- If the SVal is not known to be a ptr but has a pass-by-ptr type,
    emit alloca+store to convert it. Returns (state, ptrString). -/
private def ensurePtr (s : EmitSSAState) (v : SVal) : EmitSSAState × String :=
  match v with
  | .strConst name => materializeStrConst s name
  | _ =>
  if isKnownPtr s v then
    (s, emitSVal s v)
  else if ssaIsPassByPtr s v.ty then
    let llTy := ssaTyToLLVM s v.ty
    let (s, tmp) := freshLocal s
    let s := emit s s!"  {tmp} = alloca {llTy}"
    let s := emit s s!"  store {llTy} {emitSVal s v}, ptr {tmp}"
    (s, tmp)
  else
    (s, emitSVal s v)

-- ============================================================
-- Emit SInst
-- ============================================================

/-- Emit a binary operation. Uses operand type (lhs.ty) for type annotations,
    since comparison results are i1 but operate on the operand type. -/
private def emitBinOp (s : EmitSSAState) (dst : String) (op : BinOp) (lhs rhs : SVal) (_ty : Ty) : EmitSSAState :=
  let lhsStr := emitSVal s lhs
  let rhsStr := emitSVal s rhs
  let operandTy := lhs.ty
  if isFloatTy operandTy then
    let fTy := ssaFloatTyToLLVM operandTy
    let opStr := match op with
      | .add => "fadd" | .sub => "fsub" | .mul => "fmul" | .div => "fdiv" | .mod => "frem"
      | .eq => "fcmp oeq" | .neq => "fcmp une"
      | .lt => "fcmp olt" | .gt => "fcmp ogt" | .leq => "fcmp ole" | .geq => "fcmp oge"
      | _ => "fadd"
    emit s (s!"  %{dst} = {opStr} {fTy} {lhsStr}, {rhsStr}")
  else
    let iTy := ssaIntTyToLLVM operandTy
    match op with
    | .add => emit s s!"  %{dst} = add {iTy} {lhsStr}, {rhsStr}"
    | .sub => emit s s!"  %{dst} = sub {iTy} {lhsStr}, {rhsStr}"
    | .mul => emit s s!"  %{dst} = mul {iTy} {lhsStr}, {rhsStr}"
    | .div =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = sdiv {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = udiv {iTy} {lhsStr}, {rhsStr}"
    | .mod =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = srem {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = urem {iTy} {lhsStr}, {rhsStr}"
    | .eq => emit s s!"  %{dst} = icmp eq {iTy} {lhsStr}, {rhsStr}"
    | .neq => emit s s!"  %{dst} = icmp ne {iTy} {lhsStr}, {rhsStr}"
    | .lt =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = icmp slt {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = icmp ult {iTy} {lhsStr}, {rhsStr}"
    | .gt =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = icmp sgt {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = icmp ugt {iTy} {lhsStr}, {rhsStr}"
    | .leq =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = icmp sle {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = icmp ule {iTy} {lhsStr}, {rhsStr}"
    | .geq =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = icmp sge {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = icmp uge {iTy} {lhsStr}, {rhsStr}"
    | .and_ => emit s s!"  %{dst} = and i1 {lhsStr}, {rhsStr}"
    | .or_ => emit s s!"  %{dst} = or i1 {lhsStr}, {rhsStr}"
    | .bitand => emit s s!"  %{dst} = and {iTy} {lhsStr}, {rhsStr}"
    | .bitor => emit s s!"  %{dst} = or {iTy} {lhsStr}, {rhsStr}"
    | .bitxor => emit s s!"  %{dst} = xor {iTy} {lhsStr}, {rhsStr}"
    | .shl => emit s s!"  %{dst} = shl {iTy} {lhsStr}, {rhsStr}"
    | .shr =>
      if ssaIsSignedInt operandTy then emit s s!"  %{dst} = ashr {iTy} {lhsStr}, {rhsStr}"
      else emit s s!"  %{dst} = lshr {iTy} {lhsStr}, {rhsStr}"

private def emitSInst (s : EmitSSAState) (inst : SInst) : EmitSSAState :=
  match inst with
  | .binOp dst op lhs rhs ty => emitBinOp s dst op lhs rhs ty
  | .unaryOp dst op operand ty =>
    let opStr := emitSVal s operand
    let iTy := ssaIntTyToLLVM ty
    match op with
    | .neg =>
      if isFloatTy ty then
        emit s s!"  %{dst} = fneg {ssaFloatTyToLLVM ty} {opStr}"
      else
        emit s s!"  %{dst} = sub {iTy} 0, {opStr}"
    | .not_ => emit s s!"  %{dst} = xor i1 {opStr}, 1"
    | .bitnot => emit s s!"  %{dst} = xor {iTy} {opStr}, -1"
  | .call dst fn args retTy =>
    -- For pass-by-ptr args: convert struct values to pointers
    let (s, argParts) := args.foldl (fun (s, parts) a =>
      let paramLLTy := ssaParamTyToLLVM s a.ty
      match a with
      | .strConst name =>
        -- String constants always passed as ptr to %struct.String
        let (s, strPtr) := materializeStrConst s name
        (s, parts ++ [s!"ptr {strPtr}"])
      | _ =>
      let valLLTy := ssaTyToLLVM s a.ty
      if paramLLTy == "ptr" && valLLTy != "ptr" then
        -- If the register is already known to be a pointer (e.g. a struct
        -- parameter passed by ptr), pass it directly instead of
        -- alloca+store which would misuse the ptr as a struct value.
        if isKnownPtr s a then
          (s, parts ++ [s!"ptr {emitSVal s a}"])
        else
          let (s, tmp) := freshLocal s
          let s := emit s s!"  {tmp} = alloca {valLLTy}"
          let s := emit s s!"  store {valLLTy} {emitSVal s a}, ptr {tmp}"
          (s, parts ++ [s!"ptr {tmp}"])
      else
        (s, parts ++ [s!"{paramLLTy} {emitSVal s a}"])
    ) (s, ([] : List String))
    let argStr := ", ".intercalate argParts
    let retLLTy := ssaTyToLLVM s retTy
    -- Indirect call: function is a parameter with fn type
    let isIndirect := s.fnParams.any fun (n, t) =>
      n == fn && match t with | .fn_ _ _ _ => true | _ => false
    let callTarget := if isIndirect then "%" ++ fn else "@" ++ fn
    match dst with
    | some d =>
      let s := emit s s!"  %{d} = call {retLLTy} {callTarget}({argStr})"
      -- If return type is pass-by-ptr, the result is actually a value, not ptr
      s
    | none =>
      emit s s!"  call {retLLTy} {callTarget}({argStr})"
  | .alloca dst ty =>
    let s := emit s s!"  %{dst} = alloca {ssaTyToLLVM s ty}"
    markPtr s dst
  | .load dst ptr ty =>
    let (s, ptrStr) := ensurePtr s ptr
    emit s s!"  %{dst} = load {ssaTyToLLVM s ty}, ptr {ptrStr}"
  | .store val ptr =>
    let (s, ptrStr) := ensurePtr s ptr
    match val with
    | .strConst name =>
      -- Copy string struct from materialized temp to destination
      let (s, srcPtr) := materializeStrConst s name
      let s := emit s s!"  call void @llvm.memcpy.p0.p0.i64(ptr {ptrStr}, ptr {srcPtr}, i64 16, i1 false)"
      s
    | _ =>
    -- If the value is a known pointer but typed as a struct, it is
    -- actually a pointer to the struct (e.g. a pass-by-ptr param).
    -- Use memcpy rather than a store that would misinterpret ptr as struct.
    if isKnownPtr s val && ssaIsPassByPtr s val.ty then
      let sz := ssaTySize val.ty
      emit s s!"  call void @llvm.memcpy.p0.p0.i64(ptr {ptrStr}, ptr {emitSVal s val}, i64 {sz}, i1 false)"
    else
      emit s s!"  store {ssaTyToLLVM s val.ty} {emitSVal s val}, ptr {ptrStr}"
  | .gep dst base indices ty =>
    let (s, basePtr) := ensurePtr s base
    let idxStr := ", ".intercalate (indices.map fun i => ssaTyToLLVM s i.ty ++ " " ++ emitSVal s i)
    let elemTy := ssaTyToLLVM s ty
    let s := emit s s!"  %{dst} = getelementptr {elemTy}, ptr {basePtr}, {idxStr}"
    markPtr s dst
  | .phi dst incoming ty =>
    let pairs := incoming.map fun (v, lbl) => s!"[{emitSVal s v}, %{lbl}]"
    emit s s!"  %{dst} = phi {ssaTyToLLVM s ty} {", ".intercalate pairs}"
  | .cast dst val targetTy =>
    match val with
    | .strConst name =>
      -- String constant → ptr: materialize the %struct.String and return ptr
      let (s, strPtr) := materializeStrConst s name
      let s := emit s s!"  %{dst} = getelementptr i8, ptr {strPtr}, i32 0"
      markPtr s dst
    | _ =>
    let srcTy := val.ty
    let srcLLTy := ssaTyToLLVM s srcTy
    let dstLLTy := ssaTyToLLVM s targetTy
    let valStr := emitSVal s val
    if srcLLTy == dstLLTy then
      -- Same type, just alias
      if srcLLTy == "ptr" then emit s s!"  %{dst} = getelementptr i8, ptr {valStr}, i32 0"
      else emit s s!"  %{dst} = add {srcLLTy} {valStr}, 0"
    else if srcLLTy == "ptr" || dstLLTy == "ptr" then
      if srcLLTy == "ptr" && isIntegerTy targetTy then
        emit s s!"  %{dst} = ptrtoint ptr {valStr} to {dstLLTy}"
      else if dstLLTy == "ptr" && isIntegerTy srcTy then
        emit s s!"  %{dst} = inttoptr {srcLLTy} {valStr} to ptr"
      else if srcLLTy == "ptr" then
        -- ptr → ptr (already handled by same type), or ptr → non-ptr
        emit s s!"  %{dst} = ptrtoint ptr {valStr} to {dstLLTy}"
      else
        -- non-ptr → ptr: use inttoptr for ints, alloca+store for structs
        if ssaIsPassByPtr s srcTy then
          let (s, tmp) := freshLocal s
          let s := emit s s!"  {tmp} = alloca {srcLLTy}"
          let s := emit s s!"  store {srcLLTy} {valStr}, ptr {tmp}"
          let s := emit s s!"  %{dst} = getelementptr i8, ptr {tmp}, i32 0"
          markPtr s dst
        else
          emit s s!"  %{dst} = inttoptr {srcLLTy} {valStr} to ptr"
    else if isIntegerTy srcTy && isIntegerTy targetTy then
      let srcBits := match srcTy with
        | .i8 | .u8 | .char => 8 | .i16 | .u16 => 16 | .i32 | .u32 => 32 | _ => 64
      let dstBits := match targetTy with
        | .i8 | .u8 | .char => 8 | .i16 | .u16 => 16 | .i32 | .u32 => 32 | _ => 64
      if srcBits < dstBits then
        if ssaIsSignedInt srcTy then emit s s!"  %{dst} = sext {srcLLTy} {valStr} to {dstLLTy}"
        else emit s s!"  %{dst} = zext {srcLLTy} {valStr} to {dstLLTy}"
      else if srcBits > dstBits then
        emit s s!"  %{dst} = trunc {srcLLTy} {valStr} to {dstLLTy}"
      else
        emit s s!"  %{dst} = bitcast {srcLLTy} {valStr} to {dstLLTy}"
    else if isIntegerTy srcTy && isFloatTy targetTy then
      if ssaIsSignedInt srcTy then emit s s!"  %{dst} = sitofp {srcLLTy} {valStr} to {dstLLTy}"
      else emit s s!"  %{dst} = uitofp {srcLLTy} {valStr} to {dstLLTy}"
    else if isFloatTy srcTy && isIntegerTy targetTy then
      if ssaIsSignedInt targetTy then emit s s!"  %{dst} = fptosi {srcLLTy} {valStr} to {dstLLTy}"
      else emit s s!"  %{dst} = fptoui {srcLLTy} {valStr} to {dstLLTy}"
    else if isFloatTy srcTy && isFloatTy targetTy then
      let srcBits := if srcTy == .float32 then 32 else 64
      let dstBits := if targetTy == .float32 then 32 else 64
      if srcBits < dstBits then emit s s!"  %{dst} = fpext {srcLLTy} {valStr} to {dstLLTy}"
      else emit s s!"  %{dst} = fptrunc {srcLLTy} {valStr} to {dstLLTy}"
    else
      -- Fallback: alloca+store+load to "bitcast"
      let (s, tmp) := freshLocal s
      let s := emit s s!"  {tmp} = alloca {srcLLTy}"
      let s := emit s s!"  store {srcLLTy} {valStr}, ptr {tmp}"
      emit s s!"  %{dst} = load {dstLLTy}, ptr {tmp}"
  | .memcpy dst src size =>
    let dstStr := emitSVal s dst
    let srcStr := emitSVal s src
    emit s s!"  call void @llvm.memcpy.p0.p0.i64(ptr {dstStr}, ptr {srcStr}, i64 {size}, i1 false)"

-- ============================================================
-- Emit STerm
-- ============================================================

private def emitSTerm (s : EmitSSAState) (t : STerm) : EmitSSAState :=
  match t with
  | .ret (some v) =>
    let tyStr := ssaTyToLLVM s v.ty
    if tyStr == "void" then emit s "  ret void"
    else if isKnownPtr s v && ssaIsPassByPtr s v.ty then
      -- Value is a pointer to a struct (e.g. pass-by-ptr param); load it
      -- so we return the struct by value as the LLVM signature expects.
      let (s, tmp) := freshLocal s
      let s := emit s s!"  {tmp} = load {tyStr}, ptr {emitSVal s v}"
      emit s s!"  ret {tyStr} {tmp}"
    else emit s s!"  ret {tyStr} {emitSVal s v}"
  | .ret none => emit s "  ret void"
  | .br lbl => emit s s!"  br label %{lbl}"
  | .condBr cond tl el =>
    emit s s!"  br i1 {emitSVal s cond}, label %{tl}, label %{el}"
  | .unreachable => emit s "  unreachable"

-- ============================================================
-- Emit SBlock / SFnDef
-- ============================================================

private def emitSBlock (s : EmitSSAState) (b : SBlock) : EmitSSAState :=
  let s := emit s s!"{b.label}:"
  let s := b.insts.foldl emitSInst s
  emitSTerm s b.term

private def emitSFnDef (s : EmitSSAState) (f : SFnDef) (isUserMain : Bool) : EmitSSAState :=
  let retTy := ssaTyToLLVM s f.retTy
  let fnName := if isUserMain then "user_main" else f.name
  let paramStr := ", ".intercalate (f.params.map fun (n, t) => ssaParamTyToLLVM s t ++ " %" ++ n)
  let s := emit s s!"define {retTy} @{fnName}({paramStr}) \{"
  -- Mark struct-type params as pointers, track fn params for indirect calls
  let s := { s with fnParams := f.params }
  let s := f.params.foldl (fun s (n, t) =>
    if ssaIsPassByPtr s t then markPtr s n else s
  ) s
  let s := f.blocks.foldl emitSBlock s
  let s := emit s "}\n"
  -- Reset per-function state
  { s with ptrRegs := [], fnParams := [] }

-- ============================================================
-- Emit struct/enum type definitions
-- ============================================================

private def emitStructTypes (s : EmitSSAState) : EmitSSAState :=
  s.structDefs.foldl (fun s sd =>
    let fieldTypes := ", ".intercalate (sd.fields.map fun (_, t) => ssaTyToLLVM s t)
    emit s s!"%struct.{sd.name} = type \{ {fieldTypes} }"
  ) s

private def emitEnumTypes (s : EmitSSAState) : EmitSSAState :=
  s.enumDefs.foldl (fun s ed =>
    -- Compute max payload size
    let maxPayload := ed.variants.foldl (fun (acc : Nat) (_, fields) =>
      let sz := fields.foldl (fun (a : Nat) (_, ft) => a + ssaTySize ft) 0
      if sz > acc then sz else acc
    ) (0 : Nat)
    -- Emit variant types
    let s := ed.variants.foldl (fun s (vn, fields) =>
      if fields.isEmpty then
        emit s s!"%variant.{ed.name}.{vn} = type \{}"
      else
        let fieldTypes := ", ".intercalate (fields.map fun (_, t) => ssaTyToLLVM s t)
        emit s s!"%variant.{ed.name}.{vn} = type \{ {fieldTypes} }"
    ) s
    let payloadBytes := if maxPayload == 0 then 1 else maxPayload
    emit s s!"%enum.{ed.name} = type \{ i32, [{payloadBytes} x i8] }"
  ) s

-- ============================================================
-- Emit external declarations and builtins
-- ============================================================

private def emitExternDecls (s : EmitSSAState) (externFns : List (String × List (String × Ty) × Ty)) : EmitSSAState :=
  -- Standard C runtime declarations
  let s := emit s "declare ptr @malloc(i64)"
  let s := emit s "declare void @free(ptr)"
  let s := emit s "declare ptr @realloc(ptr, i64)"
  let s := emit s "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)"
  let s := emit s "declare i64 @write(i32, ptr, i64)"
  let s := emit s "declare void @abort()"
  let s := emit s "declare i32 @printf(ptr, ...)"
  let s := emit s "declare i64 @strlen(ptr)"
  let s := emit s "declare ptr @fopen(ptr, ptr)"
  let s := emit s "declare i64 @fread(ptr, i64, i64, ptr)"
  let s := emit s "declare i64 @fwrite(ptr, i64, i64, ptr)"
  let s := emit s "declare i32 @fclose(ptr)"
  let s := emit s "declare i32 @fseek(ptr, i64, i32)"
  let s := emit s "declare i64 @ftell(ptr)"
  let s := emit s "declare ptr @memset(ptr, i32, i64)"
  let s := emit s "declare i32 @memcmp(ptr, ptr, i64)"
  -- Conversion builtin dependencies
  let s := emit s "declare i32 @snprintf(ptr, i64, ptr, ...)"
  let s := emit s "declare i64 @strtol(ptr, ptr, i32)"
  let s := emit s "declare i64 @read(i32, ptr, i64)"
  let s := emit s "declare i32 @putchar(i32)"
  let s := emit s "declare ptr @getenv(ptr)"
  let s := emit s "declare void @exit(i32)"
  -- Network builtin dependencies
  let s := emit s "declare i32 @socket(i32, i32, i32)"
  let s := emit s "declare i32 @connect(i32, ptr, i32)"
  let s := emit s "declare i32 @bind(i32, ptr, i32)"
  let s := emit s "declare i32 @listen(i32, i32)"
  let s := emit s "declare i32 @accept(i32, ptr, ptr)"
  let s := emit s "declare i64 @send(i32, ptr, i64, i32)"
  let s := emit s "declare i64 @recv(i32, ptr, i64, i32)"
  let s := emit s "declare i32 @close(i32)"
  let s := emit s "declare i32 @getaddrinfo(ptr, ptr, ptr, ptr)"
  let s := emit s "declare void @freeaddrinfo(ptr)"
  let s := emit s "declare i16 @htons(i16)"
  let s := emit s "declare i32 @setsockopt(i32, i32, i32, ptr, i32)"
  let s := emit s ""
  -- User extern function declarations
  externFns.foldl (fun s (name, params, retTy) =>
    if name == "malloc" || name == "free" || name == "realloc" then s
    else
      let retLLTy := ssaTyToLLVM s retTy
      let paramStr := ", ".intercalate (params.map fun (_, t) => ssaParamTyToLLVM s t)
      emit s s!"declare {retLLTy} @{name}({paramStr})"
  ) s

/-- Emit the main wrapper that calls user_main and prints the result.
    For void/unit return types, the wrapper just calls user_main without printing.
    For int/bool/other scalar types, it prints the result. -/
private def emitMainWrapper (s : EmitSSAState) (retTy : Ty) : EmitSSAState :=
  let retLLTy := ssaTyToLLVM s retTy
  if retLLTy == "void" then
    -- Unit/void return: just call, no print
    let s := emit s "define i32 @main() {"
    let s := emit s "  call void @user_main()"
    let s := emit s "  ret i32 0"
    emit s "}\n"
  else if retLLTy == "i1" then
    -- Bool return: print "true" or "false"
    let s := emit s "@fmt.true = private constant [5 x i8] c\"true\\00\""
    let s := emit s "@fmt.false = private constant [6 x i8] c\"false\\00\""
    let s := emit s "@fmt.main.s = private constant [4 x i8] c\"%s\\0A\\00\""
    let s := emit s ""
    let s := emit s "define i32 @main() {"
    let s := emit s "  %result = call i1 @user_main()"
    let s := emit s "  %true_str = getelementptr [5 x i8], ptr @fmt.true, i32 0, i32 0"
    let s := emit s "  %false_str = getelementptr [6 x i8], ptr @fmt.false, i32 0, i32 0"
    let s := emit s "  %str = select i1 %result, ptr %true_str, ptr %false_str"
    let s := emit s "  %fmt = getelementptr [4 x i8], ptr @fmt.main.s, i32 0, i32 0"
    let s := emit s "  call i32 (ptr, ...) @printf(ptr %fmt, ptr %str)"
    let s := emit s "  ret i32 0"
    emit s "}\n"
  else if retLLTy == "i64" then
    -- i64 return: print with %lld
    let s := emit s "@fmt.main = private constant [6 x i8] c\"%lld\\0A\\00\""
    let s := emit s ""
    let s := emit s "define i32 @main() {"
    let s := emit s "  %result = call i64 @user_main()"
    let s := emit s "  %fmt = getelementptr [6 x i8], ptr @fmt.main, i32 0, i32 0"
    let s := emit s "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %result)"
    let s := emit s "  ret i32 0"
    emit s "}\n"
  else if retLLTy == "i32" || retLLTy == "i16" || retLLTy == "i8" then
    -- Smaller integer return: widen to i64, then print
    let s := emit s "@fmt.main = private constant [6 x i8] c\"%lld\\0A\\00\""
    let s := emit s ""
    let s := emit s "define i32 @main() {"
    let s := emit s s!"  %result = call {retLLTy} @user_main()"
    let ext := if ssaIsSignedInt retTy then "sext" else "zext"
    let s := emit s s!"  %result64 = {ext} {retLLTy} %result to i64"
    let s := emit s "  %fmt = getelementptr [6 x i8], ptr @fmt.main, i32 0, i32 0"
    let s := emit s "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %result64)"
    let s := emit s "  ret i32 0"
    emit s "}\n"
  else
    -- For other types (structs, strings, etc.), just call and return 0
    let s := emit s s!"define i32 @main() \{"
    let s := emit s s!"  %result = call {retLLTy} @user_main()"
    let s := emit s "  ret i32 0"
    emit s "}\n"

-- ============================================================
-- Emit string literal globals
-- ============================================================

/-- Generate all builtin function implementations by reusing the old codegen's Builtins. -/
private def getBuiltinsIR : String :=
  let initState : CodegenState := default
  let s := genBuiltinFunctions initState
  let s := genConversionBuiltins s
  let s := genNetworkBuiltins s
  let s := genHashMapFunctions s
  s.output

/-- Generate standalone Vec builtin function definitions for the SSA path.
    The old codegen inlines vec operations at each call site, but the SSA path
    lowers them to function calls that need actual definitions. -/
private def getVecBuiltinsIR : String :=
  let es := 8  -- element size (i64 = 8 bytes)
  let ic := 8  -- initial capacity
  let ib := ic * es  -- initial buffer bytes
  let ir := s!"define %struct.Vec @vec_new() \{\n"
    ++ s!"  %buf = call ptr @malloc(i64 {ib})\n"
    ++ s!"  %v = alloca %struct.Vec\n"
    ++ s!"  %bp = getelementptr inbounds %struct.Vec, ptr %v, i32 0, i32 0\n"
    ++ s!"  store ptr %buf, ptr %bp\n"
    ++ s!"  %lp = getelementptr inbounds %struct.Vec, ptr %v, i32 0, i32 1\n"
    ++ s!"  store i64 0, ptr %lp\n"
    ++ s!"  %cp = getelementptr inbounds %struct.Vec, ptr %v, i32 0, i32 2\n"
    ++ s!"  store i64 {ic}, ptr %cp\n"
    ++ s!"  %r = load %struct.Vec, ptr %v\n"
    ++ s!"  ret %struct.Vec %r\n"
    ++ s!"}\n\n"
    -- vec_push
    ++ s!"define void @vec_push(ptr %vec, i64 %val) \{\n"
    ++ s!"  %lp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 1\n"
    ++ s!"  %len = load i64, ptr %lp\n"
    ++ s!"  %cp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 2\n"
    ++ s!"  %cap = load i64, ptr %cp\n"
    ++ s!"  %full = icmp eq i64 %len, %cap\n"
    ++ s!"  br i1 %full, label %grow, label %store\n"
    ++ s!"grow:\n"
    ++ s!"  %newcap = mul i64 %cap, 2\n"
    ++ s!"  %newbytes = mul i64 %newcap, {es}\n"
    ++ s!"  %dp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data = load ptr, ptr %dp\n"
    ++ s!"  %newbuf = call ptr @realloc(ptr %data, i64 %newbytes)\n"
    ++ s!"  store ptr %newbuf, ptr %dp\n"
    ++ s!"  store i64 %newcap, ptr %cp\n"
    ++ s!"  br label %store\n"
    ++ s!"store:\n"
    ++ s!"  %dp2 = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data2 = load ptr, ptr %dp2\n"
    ++ s!"  %offset = mul i64 %len, {es}\n"
    ++ s!"  %slot = getelementptr i8, ptr %data2, i64 %offset\n"
    ++ s!"  store i64 %val, ptr %slot\n"
    ++ s!"  %newlen = add i64 %len, 1\n"
    ++ s!"  store i64 %newlen, ptr %lp\n"
    ++ s!"  ret void\n"
    ++ s!"}\n\n"
    -- vec_get
    ++ s!"define i64 @vec_get(ptr %vec, i64 %idx) \{\n"
    ++ s!"  %dp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data = load ptr, ptr %dp\n"
    ++ s!"  %offset = mul i64 %idx, {es}\n"
    ++ s!"  %slot = getelementptr i8, ptr %data, i64 %offset\n"
    ++ s!"  %val = load i64, ptr %slot\n"
    ++ s!"  ret i64 %val\n"
    ++ s!"}\n\n"
    -- vec_len
    ++ s!"define i64 @vec_len(ptr %vec) \{\n"
    ++ s!"  %lp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 1\n"
    ++ s!"  %len = load i64, ptr %lp\n"
    ++ s!"  ret i64 %len\n"
    ++ s!"}\n\n"
    -- vec_free
    ++ s!"define void @vec_free(ptr %vec) \{\n"
    ++ s!"  %dp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data = load ptr, ptr %dp\n"
    ++ s!"  call void @free(ptr %data)\n"
    ++ s!"  ret void\n"
    ++ s!"}\n\n"
    -- vec_pop
    ++ s!"define %enum.Option @vec_pop(ptr %vec) \{\n"
    ++ s!"  %lp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 1\n"
    ++ s!"  %len = load i64, ptr %lp\n"
    ++ s!"  %empty = icmp eq i64 %len, 0\n"
    ++ s!"  br i1 %empty, label %none, label %some\n"
    ++ s!"some:\n"
    ++ s!"  %newlen = sub i64 %len, 1\n"
    ++ s!"  store i64 %newlen, ptr %lp\n"
    ++ s!"  %dp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data = load ptr, ptr %dp\n"
    ++ s!"  %offset = mul i64 %newlen, {es}\n"
    ++ s!"  %slot = getelementptr i8, ptr %data, i64 %offset\n"
    ++ s!"  %val = load i64, ptr %slot\n"
    ++ s!"  %res = alloca %enum.Option\n"
    ++ s!"  %tag = getelementptr inbounds %enum.Option, ptr %res, i32 0, i32 0\n"
    ++ s!"  store i32 0, ptr %tag\n"
    ++ s!"  %payload = getelementptr inbounds %enum.Option, ptr %res, i32 0, i32 1\n"
    ++ s!"  store i64 %val, ptr %payload\n"
    ++ s!"  %r = load %enum.Option, ptr %res\n"
    ++ s!"  ret %enum.Option %r\n"
    ++ s!"none:\n"
    ++ s!"  %res2 = alloca %enum.Option\n"
    ++ s!"  %tag2 = getelementptr inbounds %enum.Option, ptr %res2, i32 0, i32 0\n"
    ++ s!"  store i32 1, ptr %tag2\n"
    ++ s!"  %r2 = load %enum.Option, ptr %res2\n"
    ++ s!"  ret %enum.Option %r2\n"
    ++ s!"}\n\n"
    -- vec_set
    ++ s!"define void @vec_set(ptr %vec, i64 %idx, i64 %val) \{\n"
    ++ s!"  %dp = getelementptr inbounds %struct.Vec, ptr %vec, i32 0, i32 0\n"
    ++ s!"  %data = load ptr, ptr %dp\n"
    ++ s!"  %offset = mul i64 %idx, {es}\n"
    ++ s!"  %slot = getelementptr i8, ptr %data, i64 %offset\n"
    ++ s!"  store i64 %val, ptr %slot\n"
    ++ s!"  ret void\n"
    ++ s!"}\n"
  ir

/-- Emit builtin implementations needed by the program. -/
private def emitBuiltins (s : EmitSSAState) : EmitSSAState :=
  { s with output := s.output ++ getBuiltinsIR ++ getVecBuiltinsIR }

-- ============================================================
-- Entry point: emit full SSA program as LLVM IR
-- ============================================================

def emitSModule (s : EmitSSAState) (m : SModule) : EmitSSAState :=
  let s := { s with structDefs := s.structDefs ++ m.structs, enumDefs := s.enumDefs ++ m.enums }
  -- User types (dedup across modules)
  let s := m.structs.foldl (fun s sd =>
    if s.emittedTypes.contains sd.name then s
    else
      let s := { s with emittedTypes := sd.name :: s.emittedTypes }
      let fieldTypes := ", ".intercalate (sd.fields.map fun (_, t) => ssaTyToLLVM s t)
      emit s s!"%struct.{sd.name} = type \{ {fieldTypes} }"
  ) s
  let s := m.enums.foldl (fun s ed =>
    if s.emittedTypes.contains ed.name then s
    else
      let s := { s with emittedTypes := ed.name :: s.emittedTypes }
      let maxPayload := ed.variants.foldl (fun (acc : Nat) (_, fields) =>
        let sz := fields.foldl (fun (a : Nat) (_, ft) => a + ssaTySize ft) 0
        if sz > acc then sz else acc
      ) (0 : Nat)
      let s := ed.variants.foldl (fun s (vn, fields) =>
        if fields.isEmpty then
          emit s s!"%variant.{ed.name}.{vn} = type \{}"
        else
          let fieldTypes := ", ".intercalate (fields.map fun (_, t) => ssaTyToLLVM s t)
          emit s s!"%variant.{ed.name}.{vn} = type \{ {fieldTypes} }"
      ) s
      let payloadBytes := if maxPayload == 0 then 1 else maxPayload
      emit s s!"%enum.{ed.name} = type \{ i32, [{payloadBytes} x i8] }"
  ) s
  -- String literal globals
  let s := m.globals.foldl (fun s (name, val) =>
    let escaped := ssaEscapeStringForLLVM val
    let len := val.length + 1
    let s := emit s s!"@{name} = private constant [{len} x i8] c\"{escaped}\\00\""
    { s with stringLengths := s.stringLengths ++ [(name, val.length)] }
  ) s
  -- Functions
  let hasMain := m.functions.any fun f => f.name == "main"
  let s := m.functions.foldl (fun s f =>
    let isUserMain := f.name == "main" && hasMain
    emitSFnDef s f isUserMain
  ) s
  -- Main wrapper
  if hasMain then
    match m.functions.find? fun f => f.name == "main" with
    | some mainFn => emitMainWrapper s mainFn.retTy
    | none => s
  else s

def emitSSAProgram (modules : List SModule) : String :=
  let s : EmitSSAState := {}
  -- Header
  let s := emit s "; Generated by Concrete compiler (SSA path)"
  let s := emit s ""
  -- Collect all structs and enums for type resolution
  let allStructs := modules.foldl (fun acc m => acc ++ m.structs) []
  let allEnums := modules.foldl (fun acc m => acc ++ m.enums) []
  -- Add builtin enums (Option, Result) so ssaLookupEnum resolves them to %enum.X
  let builtinEnums : List CEnumDef := [
    { name := "Option", variants := [("Some", [("value", .int)]), ("None", [])] },
    { name := "Result", variants := [("Ok", [("value", .int)]), ("Err", [("value", .int)])] }
  ]
  let s := { s with structDefs := allStructs, enumDefs := builtinEnums ++ allEnums }
  -- Well-known types
  let s := emit s "%struct.String = type { ptr, i64 }"
  let s := emit s "%struct.Vec = type { ptr, i64, i64 }"
  let s := emit s "%struct.HashMap = type { ptr, ptr, ptr, i64, i64 }"
  -- Builtin enum types used by string_to_int, get_env, etc.
  let s := emit s "%variant.Result.Ok = type { i64 }"
  let s := emit s "%variant.Result.Err = type { i64 }"
  let s := emit s "%enum.Result = type { i32, [8 x i8] }"
  let s := emit s "%variant.Option.Some = type { i64 }"
  let s := emit s "%variant.Option.None = type {}"
  let s := emit s "%enum.Option = type { i32, [8 x i8] }"
  -- Mark these as emitted so user enums with the same names won't duplicate
  let s := { s with emittedTypes := ["Result", "Option"] ++ s.emittedTypes }
  let s := emit s ""
  -- External declarations
  let allExternFns := modules.foldl (fun acc m => acc ++ m.externFns) []
  let s := emitExternDecls s allExternFns
  let s := emit s ""
  -- Emit each module
  let s := modules.foldl emitSModule s
  -- Emit builtin function implementations
  let s := emitBuiltins s
  s.output

end Concrete
