import Concrete.SSA
import Concrete.Core
import Concrete.Layout
import Concrete.Codegen.Builtins
import Concrete.Intrinsic

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
  /-- Registers holding function-pointer values loaded from memory (e.g. struct fields). -/
  fnTypeRegs : List String := []
  /-- Maps local alias name → original linker symbol for aliased imports. -/
  linkerAliases : List (String × String) := []

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

/-- Build a Layout.Ctx from the current emit state. -/
private def layoutCtxOf (s : EmitSSAState) : Layout.Ctx :=
  { structDefs := s.structDefs, enumDefs := s.enumDefs }

private def ssaLookupStruct (s : EmitSSAState) (name : String) : Option CStructDef :=
  Layout.lookupStruct (layoutCtxOf s) name

private def ssaLookupEnum (s : EmitSSAState) (name : String) : Option CEnumDef :=
  Layout.lookupEnum (layoutCtxOf s) name

/-- Map a Concrete type to its LLVM IR type string. Delegates to Layout.tyToLLVM. -/
def ssaTyToLLVM (s : EmitSSAState) (ty : Ty) : String :=
  Layout.tyToLLVM (layoutCtxOf s) ty

/-- Is this type passed by pointer in function calls? Delegates to Layout.isPassByPtr. -/
private def ssaIsPassByPtr (s : EmitSSAState) (ty : Ty) : Bool :=
  Layout.isPassByPtr (layoutCtxOf s) ty

/-- LLVM type for function parameters (structs passed as ptr). Delegates to Layout.paramTyToLLVM. -/
private def ssaParamTyToLLVM (s : EmitSSAState) (ty : Ty) : String :=
  Layout.paramTyToLLVM (layoutCtxOf s) ty

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
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 | .char | .bool => true
  | _ => false

private def isFloatTy : Ty → Bool
  | .float32 | .float64 => true
  | _ => false

/-- Get byte size of a type. Delegates to Layout.tySize with current state's defs. -/
private def ssaTySize (s : EmitSSAState) (ty : Ty) : Nat :=
  Layout.tySize (layoutCtxOf s) ty

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
  | .reg name _ =>
    if name.startsWith "@fnref." then "@" ++ name.drop 7
    else "%" ++ name
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
private def isRefOrPtrTy : Ty → Bool
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => true
  | _ => false

private def ensurePtr (s : EmitSSAState) (v : SVal) : EmitSSAState × String :=
  match v with
  | .strConst name => materializeStrConst s name
  | _ =>
  if isKnownPtr s v then
    (s, emitSVal s v)
  else if isRefOrPtrTy v.ty then
    -- References and raw pointers are already pointer-sized values in LLVM IR;
    -- they must NOT be spilled to an alloca (which would add an extra indirection).
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

/-- Is this type a raw pointer? -/
private def isPointerTy : Ty → Bool
  | .ptrMut _ | .ptrConst _ => true
  | _ => false

/-- Emit a binary operation. Uses operand type (lhs.ty) for type annotations,
    since comparison results are i1 but operate on the operand type. -/
private def emitBinOp (s : EmitSSAState) (dst : String) (op : BinOp) (lhs rhs : SVal) (_ty : Ty) : EmitSSAState :=
  let lhsStr := emitSVal s lhs
  let rhsStr := emitSVal s rhs
  let operandTy := lhs.ty
  -- Pointer arithmetic: ptr + int → getelementptr <pointee>, ptr %p, i64 %n
  -- GEP scales the offset by the pointee element size automatically
  if isPointerTy operandTy && (op == .add || op == .sub) then
    let pointeeTy := match operandTy with
      | .ptrMut t | .ptrConst t => ssaTyToLLVM s t
      | _ => "i8"
    let rhsIdx := if op == .sub then
      let negReg := s!"{dst}.neg"
      let s := emit s s!"  %{negReg} = sub i64 0, {rhsStr}"
      (s, s!"%{negReg}")
    else (s, rhsStr)
    emit rhsIdx.1 s!"  %{dst} = getelementptr {pointeeTy}, ptr {lhsStr}, i64 {rhsIdx.2}"
  else if isFloatTy operandTy then
    let fTy := ssaFloatTyToLLVM operandTy
    let opStr := match op with
      | .add => "fadd" | .sub => "fsub" | .mul => "fmul" | .div => "fdiv" | .mod => "frem"
      | .eq => "fcmp oeq" | .neq => "fcmp une"
      | .lt => "fcmp olt" | .gt => "fcmp ogt" | .leq => "fcmp ole" | .geq => "fcmp oge"
      | _ => "fadd"
    emit s (s!"  %{dst} = {opStr} {fTy} {lhsStr}, {rhsStr}")
  else
    let isPtrTy := match operandTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false
    let iTy := if isPtrTy then "ptr" else ssaIntTyToLLVM operandTy
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
    -- Indirect call: function is a parameter with fn type, a register loaded
    -- from memory (fnTypeRegs), or a %-prefixed register from the Lower pass.
    let isIndirect := fn.startsWith "%"
      || (s.fnParams.any fun (n, t) =>
        n == fn && match t with | .fn_ _ _ _ => true | _ => false)
      || s.fnTypeRegs.contains fn
    -- Resolve aliased imports to their real linker symbol
    let linkerFn := match s.linkerAliases.lookup fn with
      | some orig => orig
      | none => fn
    let callTarget := if isIndirect then
      if fn.startsWith "%" then fn  -- already has % prefix
      else "%" ++ fn
    else "@" ++ linkerFn
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
    let s := emit s s!"  %{dst} = load {ssaTyToLLVM s ty}, ptr {ptrStr}"
    -- Track registers that hold function pointers (loaded from struct fields etc.)
    match ty with
    | .fn_ _ _ _ => { s with fnTypeRegs := s.fnTypeRegs ++ [dst] }
    | _ => s
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
      let sz := ssaTySize s val.ty
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
    else match v with
    | .strConst _ =>
      -- String constant: materialize as struct, load, return by value
      let (s, ptr) := materializeStrConst s (match v with | .strConst n => n | _ => "")
      let (s, tmp) := freshLocal s
      let s := emit s s!"  {tmp} = load {tyStr}, ptr {ptr}"
      emit s s!"  ret {tyStr} {tmp}"
    | _ =>
    if isKnownPtr s v && ssaIsPassByPtr s v.ty then
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
    match t with
    | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => markPtr s n
    | _ => if ssaIsPassByPtr s t then markPtr s n else s
  ) s
  let s := f.blocks.foldl emitSBlock s
  let s := emit s "}\n"
  -- Reset per-function state
  { s with ptrRegs := [], fnParams := [], fnTypeRegs := [] }

-- ============================================================
-- Emit struct/enum type definitions
-- ============================================================

-- ============================================================
-- Emit external declarations and builtins
-- ============================================================

private def emitExternDecls (s : EmitSSAState) (externFns : List (String × List (String × Ty) × Ty))
    (definedFns : List String := []) : EmitSSAState :=
  -- Standard C runtime declarations (used by remaining builtins)
  let s := emit s "declare ptr @malloc(i64)"
  let s := emit s "declare void @free(ptr)"
  let s := emit s "declare ptr @realloc(ptr, i64)"
  let s := emit s "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)"
  let s := emit s "declare i64 @write(i32, ptr, i64)"
  let s := emit s "declare void @abort()"
  let s := emit s "declare i32 @printf(ptr, ...)"
  let s := emit s "declare i64 @strlen(ptr)"
  let s := emit s "declare ptr @memset(ptr, i32, i64)"
  let s := emit s "declare i32 @memcmp(ptr, ptr, i64)"
  -- Conversion builtin dependencies
  let s := emit s "declare i32 @snprintf(ptr, i64, ptr, ...)"
  let s := emit s "declare i64 @strtol(ptr, ptr, i32)"
  let s := emit s ""
  -- Names already declared above — skip duplicates from user extern fns
  let builtinNames : List String := [
    "malloc", "free", "realloc", "write", "abort", "printf", "strlen",
    "memset", "memcmp", "snprintf", "strtol"
  ]
  -- User extern function declarations (skip if already defined as a concrete function)
  externFns.foldl (fun s (name, params, retTy) =>
    if builtinNames.contains name || definedFns.contains name then s
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
    ++ s!"  store i32 0, ptr %res\n"
    ++ s!"  %payload = getelementptr i8, ptr %res, i64 8\n"
    ++ s!"  store i64 %val, ptr %payload\n"
    ++ s!"  %r = load %enum.Option, ptr %res\n"
    ++ s!"  ret %enum.Option %r\n"
    ++ s!"none:\n"
    ++ s!"  %res2 = alloca %enum.Option\n"
    ++ s!"  store i32 1, ptr %res2\n"
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

/-- HashMap wrapper functions that delegate to __hashmap_int_* / __hashmap_str_* builtins. -/
private def getMapBuiltinsIR : String :=
  -- map_new() -> HashMap (int keys, 8-byte values)
  "define %struct.HashMap @map_new() {\n"
  ++ "  %m = alloca %struct.HashMap\n"
  ++ "  call void @__hashmap_int_new(ptr %m, i64 8, i64 8)\n"
  ++ "  %r = load %struct.HashMap, ptr %m\n"
  ++ "  ret %struct.HashMap %r\n"
  ++ "}\n\n"
  ++ "define void @map_insert(ptr %m, i64 %key, i64 %val) {\n"
  ++ "  %kp = alloca i64\n"
  ++ "  store i64 %key, ptr %kp\n"
  ++ "  %vp = alloca i64\n"
  ++ "  store i64 %val, ptr %vp\n"
  ++ "  call void @__hashmap_int_insert(ptr %m, ptr %kp, ptr %vp, i64 8, i64 8)\n"
  ++ "  ret void\n"
  ++ "}\n\n"
  ++ "define %enum.Option @map_get(ptr %m, i64 %key) {\n"
  ++ "  %kp = alloca i64\n"
  ++ "  store i64 %key, ptr %kp\n"
  ++ "  %opt = alloca %enum.Option\n"
  ++ "  call void @__hashmap_int_get(ptr %m, ptr %kp, ptr %opt, i64 8, i64 8)\n"
  ++ "  %r = load %enum.Option, ptr %opt\n"
  ++ "  ret %enum.Option %r\n"
  ++ "}\n\n"
  ++ "define void @map_free(ptr %m) {\n"
  ++ "  %kf = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 0\n"
  ++ "  %kb = load ptr, ptr %kf\n"
  ++ "  call void @free(ptr %kb)\n"
  ++ "  %vf = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 1\n"
  ++ "  %vb = load ptr, ptr %vf\n"
  ++ "  call void @free(ptr %vb)\n"
  ++ "  %ff = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 2\n"
  ++ "  %fb = load ptr, ptr %ff\n"
  ++ "  call void @free(ptr %fb)\n"
  ++ "  ret void\n"
  ++ "}\n\n"
  ++ "define i64 @map_len(ptr %m) {\n"
  ++ "  %lp = getelementptr inbounds %struct.HashMap, ptr %m, i32 0, i32 3\n"
  ++ "  %r = load i64, ptr %lp\n"
  ++ "  ret i64 %r\n"
  ++ "}\n\n"
  ++ "define i1 @map_contains(ptr %m, i64 %key) {\n"
  ++ "  %kp = alloca i64\n"
  ++ "  store i64 %key, ptr %kp\n"
  ++ "  %r = call i1 @__hashmap_int_contains(ptr %m, ptr %kp, i64 8)\n"
  ++ "  ret i1 %r\n"
  ++ "}\n\n"
  ++ "define %enum.Option @map_remove(ptr %m, i64 %key) {\n"
  ++ "  %kp = alloca i64\n"
  ++ "  store i64 %key, ptr %kp\n"
  ++ "  %opt = alloca %enum.Option\n"
  ++ "  call void @__hashmap_int_remove(ptr %m, ptr %kp, ptr %opt, i64 8, i64 8)\n"
  ++ "  %r = load %enum.Option, ptr %opt\n"
  ++ "  ret %enum.Option %r\n"
  ++ "}\n\n"
  -- String-keyed variants
  ++ "define %struct.HashMap @map_new_str() {\n"
  ++ "  %m = alloca %struct.HashMap\n"
  ++ "  call void @__hashmap_str_new(ptr %m, i64 16, i64 8)\n"
  ++ "  %r = load %struct.HashMap, ptr %m\n"
  ++ "  ret %struct.HashMap %r\n"
  ++ "}\n\n"
  ++ "define void @map_insert_str(ptr %m, ptr %key, i64 %val) {\n"
  ++ "  %vp = alloca i64\n"
  ++ "  store i64 %val, ptr %vp\n"
  ++ "  call void @__hashmap_str_insert(ptr %m, ptr %key, ptr %vp, i64 16, i64 8)\n"
  ++ "  ret void\n"
  ++ "}\n\n"
  ++ "define %enum.Option @map_get_str(ptr %m, ptr %key) {\n"
  ++ "  %opt = alloca %enum.Option\n"
  ++ "  call void @__hashmap_str_get(ptr %m, ptr %key, ptr %opt, i64 16, i64 8)\n"
  ++ "  %r = load %enum.Option, ptr %opt\n"
  ++ "  ret %enum.Option %r\n"
  ++ "}\n\n"

/-- Emit builtin implementations needed by the program. -/
private def emitBuiltins (s : EmitSSAState) : EmitSSAState :=
  { s with output := s.output ++ getBuiltinsIR ++ getVecBuiltinsIR ++ getMapBuiltinsIR }

-- ============================================================
-- Entry point: emit full SSA program as LLVM IR
-- ============================================================

def emitSModule (s : EmitSSAState) (m : SModule) (testMode : Bool := false) : EmitSSAState :=
  let s := { s with structDefs := s.structDefs ++ m.structs, enumDefs := s.enumDefs ++ m.enums,
                     linkerAliases := s.linkerAliases ++ m.linkerAliases }
  -- User types (dedup across modules)
  let s := m.structs.foldl (fun s sd =>
    if s.emittedTypes.contains sd.name then s
    else
      let s := { s with emittedTypes := sd.name :: s.emittedTypes }
      emit s (Layout.structTypeDef (layoutCtxOf s) sd)
  ) s
  let ctx := layoutCtxOf s
  let s := m.enums.foldl (fun s ed =>
    if s.emittedTypes.contains ed.name then s
    else
      let s := { s with emittedTypes := ed.name :: s.emittedTypes }
      (Layout.enumTypeDefs ctx ed).foldl (fun s line => emit s line) s
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
  -- Main wrapper (skip in test mode — test runner provides main)
  if testMode then s
  else if hasMain then
    match m.functions.find? fun f => f.name == "main" with
    | some mainFn => emitMainWrapper s mainFn.retTy
    | none => s
  else s

/-- Collect all types referenced in an SVal. -/
private def collectSValTys (v : SVal) : List Ty :=
  match v with
  | .reg _ t => [t]
  | .intConst _ t => [t]
  | .floatConst _ t => [t]
  | _ => []

/-- Collect all types referenced in an SInst. -/
private def collectSInstTys (inst : SInst) : List Ty :=
  match inst with
  | .binOp _ _ lhs rhs ty => collectSValTys lhs ++ collectSValTys rhs ++ [ty]
  | .unaryOp _ _ operand ty => collectSValTys operand ++ [ty]
  | .call _ _ args retTy => args.foldl (fun acc a => acc ++ collectSValTys a) [] ++ [retTy]
  | .alloca _ ty => [ty]
  | .load _ ptr ty => collectSValTys ptr ++ [ty]
  | .store val ptr => collectSValTys val ++ collectSValTys ptr
  | .gep _ base indices ty => collectSValTys base ++ indices.foldl (fun acc i => acc ++ collectSValTys i) [] ++ [ty]
  | .phi _ incoming ty => incoming.foldl (fun acc (v, _) => acc ++ collectSValTys v) [] ++ [ty]
  | .cast _ val targetTy => collectSValTys val ++ [targetTy]
  | .memcpy dst src _ => collectSValTys dst ++ collectSValTys src

/-- Scan all SSA modules for concrete type arguments used with Option and Result.
    Returns (largest Option payload type, largest Result payload types (ok, err)). -/
private def scanBuiltinEnumArgs (ctx : Layout.Ctx) (modules : List SModule) : (Option Ty) × (Option (Ty × Ty)) :=
  let allTys := modules.foldl (fun acc m =>
    m.functions.foldl (fun acc f =>
      f.blocks.foldl (fun acc b =>
        b.insts.foldl (fun acc inst => acc ++ collectSInstTys inst) acc
      ) acc
    ) acc
  ) ([] : List Ty)
  -- Find all Option<T> and Result<T, E> instantiations
  let optPayloads := allTys.filterMap fun t =>
    match t with
    | .generic "Option" [arg] => some arg
    | _ => none
  let resPayloads := allTys.filterMap fun t =>
    match t with
    | .generic "Result" [ok, err] => some (ok, err)
    | _ => none
  -- Pick the largest payload type for Option
  let bestOpt := optPayloads.foldl (fun best t =>
    match best with
    | none => some t
    | some prev => if Layout.tySize ctx t > Layout.tySize ctx prev then some t else best
  ) none
  -- Pick the largest ok/err payload types for Result
  let bestRes := resPayloads.foldl (fun best (ok, err) =>
    match best with
    | none => some (ok, err)
    | some (prevOk, prevErr) =>
      let newOk := if Layout.tySize ctx ok > Layout.tySize ctx prevOk then ok else prevOk
      let newErr := if Layout.tySize ctx err > Layout.tySize ctx prevErr then err else prevErr
      some (newOk, newErr)
  ) none
  (bestOpt, bestRes)

private def emitTestRunner (s : EmitSSAState) (modules : List SModule) : EmitSSAState :=
  -- Collect all test functions across all modules
  let testFns := modules.foldl (fun acc m =>
    acc ++ (m.functions.filter fun f => f.isTest)
  ) []
  if testFns.isEmpty then
    -- No tests found: emit a main that prints a message and returns 0
    let s := emit s "@fmt.test.none = private constant [15 x i8] c\"No tests found\\00\""
    let s := emit s "@fmt.test.nl = private constant [2 x i8] c\"\\0A\\00\""
    let s := emit s ""
    let s := emit s "define i32 @main() {"
    let s := emit s "  %fmt = getelementptr [15 x i8], ptr @fmt.test.none, i32 0, i32 0"
    let s := emit s "  call i32 (ptr, ...) @printf(ptr %fmt)"
    let s := emit s "  %nl = getelementptr [2 x i8], ptr @fmt.test.nl, i32 0, i32 0"
    let s := emit s "  call i32 (ptr, ...) @printf(ptr %nl)"
    let s := emit s "  ret i32 0"
    emit s "}\n"
  else
    -- Emit string constants for each test name
    let s := testFns.foldl (fun s f =>
      let nameLen := f.name.length + 1
      let escaped := ssaEscapeStringForLLVM f.name
      emit s s!"@test.name.{f.name} = private constant [{nameLen} x i8] c\"{escaped}\\00\""
    ) s
    -- Emit format strings
    let s := emit s "@fmt.test.pass = private constant [10 x i8] c\"PASS: %s\\0A\\00\""
    let s := emit s "@fmt.test.fail = private constant [10 x i8] c\"FAIL: %s\\0A\\00\""
    let s := emit s ""
    -- Generate main()
    let s := emit s "define i32 @main() {"
    let s := emit s "  %failures = alloca i32"
    let s := emit s "  store i32 0, ptr %failures"
    let s := emit s ""
    -- Call each test function
    let (s, _) := testFns.foldl (fun (s, idx) f =>
      let i := toString idx
      let s := emit s s!"  ; Test: {f.name}"
      let s := emit s s!"  %result.{i} = call i32 @{f.name}()"
      let s := emit s s!"  %is_pass.{i} = icmp eq i32 %result.{i}, 0"
      let nameLen := f.name.length + 1
      let s := emit s s!"  %name.{i} = getelementptr [{nameLen} x i8], ptr @test.name.{f.name}, i32 0, i32 0"
      let s := emit s s!"  br i1 %is_pass.{i}, label %pass.{i}, label %fail.{i}"
      let s := emit s ""
      let s := emit s s!"pass.{i}:"
      let s := emit s s!"  %pfmt.{i} = getelementptr [10 x i8], ptr @fmt.test.pass, i32 0, i32 0"
      let s := emit s s!"  call i32 (ptr, ...) @printf(ptr %pfmt.{i}, ptr %name.{i})"
      let s := emit s s!"  br label %next.{i}"
      let s := emit s ""
      let s := emit s s!"fail.{i}:"
      let s := emit s s!"  %ffmt.{i} = getelementptr [10 x i8], ptr @fmt.test.fail, i32 0, i32 0"
      let s := emit s s!"  call i32 (ptr, ...) @printf(ptr %ffmt.{i}, ptr %name.{i})"
      -- Increment failures
      let s := emit s s!"  %old_fail.{i} = load i32, ptr %failures"
      let s := emit s s!"  %new_fail.{i} = add i32 %old_fail.{i}, 1"
      let s := emit s s!"  store i32 %new_fail.{i}, ptr %failures"
      let s := emit s s!"  br label %next.{i}"
      let s := emit s ""
      let s := emit s s!"next.{i}:"
      (s, idx + 1)
    ) (s, 0)
    -- Return: 1 if any failed, 0 if all passed
    let s := emit s "  %total_fail = load i32, ptr %failures"
    let s := emit s "  %any_fail = icmp sgt i32 %total_fail, 0"
    let s := emit s "  %exit = select i1 %any_fail, i32 1, i32 0"
    let s := emit s "  ret i32 %exit"
    emit s "}\n"

def emitSSAProgram (modules : List SModule) (testMode : Bool := false) : String :=
  let s : EmitSSAState := {}
  -- Header
  let s := emit s "; Generated by Concrete compiler (SSA path)"
  let s := emit s ""
  -- Collect all structs and enums for type resolution
  let allStructs := modules.foldl (fun acc m => acc ++ m.structs) []
  let allEnums := modules.foldl (fun acc m => acc ++ m.enums) []
  -- Canonical builtin enum definitions with type parameters
  let optionDef : CEnumDef :=
    { name := "Option", typeParams := ["T"],
      variants := [("Some", [("value", .typeVar "T")]), ("None", [])] }
  let resultDef : CEnumDef :=
    { name := "Result", typeParams := ["T", "E"],
      variants := [("Ok", [("value", .typeVar "T")]), ("Err", [("value", .typeVar "E")])] }
  let builtinEnums : List CEnumDef := [optionDef, resultDef]
  let s := { s with structDefs := allStructs, enumDefs := builtinEnums ++ allEnums }
  -- Well-known struct types (String, Vec, HashMap)
  let s := Layout.builtinTypeDefs.foldl (fun s line => emit s line) s
  -- Mark builtins as emitted so user-defined versions don't duplicate them
  let s := { s with emittedTypes := ["String", "Vec", "HashMap"] ++ s.emittedTypes }
  -- Whole-program monomorphic ABI for builtin generic enums:
  -- Scan all SSA modules for concrete type arguments, then emit a single LLVM type
  -- definition sized to the largest payload across all instantiations.
  -- Smaller payloads under-fill the slot (wasted padding) but are correct.
  -- Builtin functions (vec_pop, map_get, etc.) store i64 payloads, which always fit.
  -- NOTE: GEP offsets in Lower.lean assume tyAlign(.typeVar "T") = 8, which is correct
  -- only because all current Concrete types have alignment ≤ 8. If larger-aligned types
  -- are added, Lower.lean will need to thread concrete type args through offset computation.
  let ctx := layoutCtxOf s
  let (bestOpt, bestRes) := scanBuiltinEnumArgs ctx modules
  -- Generate dynamic Option type def
  let optTypeArgs := match bestOpt with
    | some t => [t]
    | none => [Ty.int]  -- fallback: i64 payload
  let optTypeDefs := Layout.enumTypeDefs ctx optionDef optTypeArgs
  let s := optTypeDefs.foldl (fun s line => emit s line) s
  -- Generate dynamic Result type def
  let resTypeArgs := match bestRes with
    | some (ok, err) => [ok, err]
    | none => [Ty.int, Ty.int]  -- fallback: i64 payloads
  let resTypeDefs := Layout.enumTypeDefs ctx resultDef resTypeArgs
  let s := resTypeDefs.foldl (fun s line => emit s line) s
  -- Mark these as emitted so user enums with the same names won't duplicate
  let s := { s with emittedTypes := ["Result", "Option"] ++ s.emittedTypes }
  let s := emit s ""
  -- External declarations (skip externs that shadow defined functions)
  let allExternFns := modules.foldl (fun acc m => acc ++ m.externFns) []
  let allDefinedFns := modules.foldl (fun acc m => acc ++ m.functions.map (·.name)) []
  let s := emitExternDecls s allExternFns allDefinedFns
  let s := emit s ""
  -- Emit each module
  let s := modules.foldl (fun s m => emitSModule s m testMode) s
  -- In test mode, emit the test runner instead of the normal main wrapper
  let s := if testMode then emitTestRunner s modules else s
  -- Emit builtin function implementations
  let s := emitBuiltins s
  s.output

end Concrete
