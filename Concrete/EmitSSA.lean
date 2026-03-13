import Concrete.SSA
import Concrete.Core
import Concrete.Layout
import Concrete.Codegen.Builtins
import Concrete.Intrinsic
import Concrete.LLVM
import Concrete.EmitLLVM

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
  /-- Instructions for the current block being built. -/
  currentInstrs : Array LLVMInstr := #[]
  /-- Completed blocks for the current function being built. -/
  currentBlocks : Array LLVMBlock := #[]
  /-- Completed function definitions. -/
  moduleFunctions : Array LLVMFnDef := #[]
  /-- Module header comment lines. -/
  moduleHeader : Array String := #[]
  /-- Structured type definitions (%struct.Foo, %enum.Bar, etc.). -/
  moduleTypeDefs : Array LLVMTypeDef := #[]
  /-- Structured global constants (string literals, format strings). -/
  moduleGlobals : Array LLVMGlobal := #[]
  /-- Structured extern function declarations. -/
  moduleDeclarations : Array LLVMFnDecl := #[]
  /-- Raw sections escape hatch (builtins only). -/
  rawSections : Array String := #[]
  structDefs : List CStructDef := []
  enumDefs : List CEnumDef := []
  stringLitCounter : Nat := 0
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

/-- Append a structured instruction to the current block. -/
private def emitStructured (s : EmitSSAState) (instr : LLVMInstr) : EmitSSAState :=
  { s with currentInstrs := s.currentInstrs.push instr }

/-- Append a type definition to the module. -/
private def emitTypeDef (s : EmitSSAState) (line : String) : EmitSSAState :=
  { s with moduleTypeDefs := s.moduleTypeDefs.push { line := line } }

/-- Append a global constant to the module. -/
private def emitGlobal (s : EmitSSAState) (g : LLVMGlobal) : EmitSSAState :=
  { s with moduleGlobals := s.moduleGlobals.push g }

/-- Append an extern function declaration to the module. -/
private def emitDecl (s : EmitSSAState) (d : LLVMFnDecl) : EmitSSAState :=
  { s with moduleDeclarations := s.moduleDeclarations.push d }

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

/-- Is this type passed by pointer in function calls? Delegates to Layout.isPassByPtr. -/
private def ssaIsPassByPtr (s : EmitSSAState) (ty : Ty) : Bool :=
  Layout.isPassByPtr (layoutCtxOf s) ty


/-- Map a Concrete type to a structured LLVMTy. Mirrors Layout.tyToLLVM. -/
partial def tyToLLVMTy (s : EmitSSAState) : Ty → LLVMTy
  | .int | .uint => .i64
  | .i8 | .u8 => .i8
  | .i16 | .u16 => .i16
  | .i32 | .u32 => .i32
  | .bool => .i1
  | .float64 => .double
  | .float32 => .float_
  | .char => .i8
  | .unit | .never => .void
  | .string => .struct_ "String"
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => .ptr
  | .generic "Heap" _ | .heap _ => .ptr
  | .generic "HeapArray" _ | .heapArray _ => .ptr
  | .generic "Vec" _ => .struct_ "Vec"
  | .generic "HashMap" _ => .struct_ "HashMap"
  | .generic name _ =>
    match ssaLookupEnum s name with
    | some _ => .enum_ name
    | none => .struct_ name
  | .typeVar _ => .i64
  | .array elem n => .array n (tyToLLVMTy s elem)
  | .fn_ _ _ _ => .ptr
  | .placeholder => .i64
  | .named name =>
    match ssaLookupStruct s name with
    | some _ => .struct_ name
    | none =>
      match ssaLookupEnum s name with
      | some _ => .enum_ name
      | none => .i64

/-- Map integer Concrete type to structured LLVM type. -/
private def intTyToLLVMTy : Ty → LLVMTy
  | .int | .uint => .i64
  | .i8 | .u8 | .char => .i8
  | .i16 | .u16 => .i16
  | .i32 | .u32 => .i32
  | .bool => .i1
  | _ => .i64

/-- Map float Concrete type to structured LLVM type. -/
private def floatTyToLLVMTy : Ty → LLVMTy
  | .float32 => .float_
  | _ => .double

/-- Convert an SVal to a structured LLVM operand. -/
private def svalToOperand (_s : EmitSSAState) (v : SVal) : LLVMOperand :=
  match v with
  | .reg name _ =>
    if name.startsWith "@fnref." then .global (name.drop 7).toString
    else .reg name
  | .intConst val _ => .intLit val
  | .floatConst val _ => .floatLit val
  | .boolConst b => .boolLit b
  | .strConst name => .global name
  | .unit => .undef

/-- LLVM type for function parameters (pass-by-ptr types → ptr). -/
private def paramTyToLLVMTy (s : EmitSSAState) (ty : Ty) : LLVMTy :=
  if ssaIsPassByPtr s ty then .ptr else tyToLLVMTy s ty

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
-- Materialize string constants and ensure pointers
-- ============================================================

/-- Materialize a string constant as a %struct.String pointer.
    Allocates a %struct.String, stores {ptr to chars, length}, returns ptr. -/
private def materializeStrConst (s : EmitSSAState) (name : String) : EmitSSAState × String :=
  let strLen := (s.stringLengths.find? fun (n, _) => n == name).map (·.2) |>.getD 0
  let arrLen := strLen + 1  -- includes null terminator in the global
  -- GEP into the global char array
  let (s, gepTmp) := freshLocal s
  let gepName := (gepTmp.drop 1).toString
  let s := emitStructured s (.gep gepName (.array arrLen .i8) (.global name) [(.i32, .intLit 0), (.i32, .intLit 0)])
  -- Heap-allocate a copy so drop_string can safely free it
  let (s, heapBuf) := freshLocal s
  let heapName := (heapBuf.drop 1).toString
  let s := emitStructured s (.call (some heapName) .ptr (.global "malloc") [(.i64, .intLit arrLen)])
  let s := emitStructured s (.memcpy (.reg heapName) (.reg gepName) arrLen)
  -- Allocate %struct.String on stack
  let (s, strTmp) := freshLocal s
  let strName := (strTmp.drop 1).toString
  let s := emitStructured s (.alloca strName (.struct_ "String"))
  -- Store ptr field (index 0)
  let (s, ptrField) := freshLocal s
  let ptrFieldName := (ptrField.drop 1).toString
  let s := emitStructured s (.gep ptrFieldName (.struct_ "String") (.reg strName) [(.i32, .intLit 0), (.i32, .intLit 0)])
  let s := emitStructured s (.store .ptr (.reg heapName) (.reg ptrFieldName))
  -- Store len field (index 1)
  let (s, lenField) := freshLocal s
  let lenFieldName := (lenField.drop 1).toString
  let s := emitStructured s (.gep lenFieldName (.struct_ "String") (.reg strName) [(.i32, .intLit 0), (.i32, .intLit 1)])
  let s := emitStructured s (.store .i64 (.intLit strLen) (.reg lenFieldName))
  -- Store cap field (index 2)
  let (s, capField) := freshLocal s
  let capFieldName := (capField.drop 1).toString
  let s := emitStructured s (.gep capFieldName (.struct_ "String") (.reg strName) [(.i32, .intLit 0), (.i32, .intLit 2)])
  let s := emitStructured s (.store .i64 (.intLit arrLen) (.reg capFieldName))
  (s, strTmp)

/-- If the SVal is not known to be a ptr but has a pass-by-ptr type,
    emit alloca+store to convert it. Returns (state, ptrString). -/
private def isRefOrPtrTy : Ty → Bool
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => true
  | _ => false

/-- If the SVal is not known to be a ptr but has a pass-by-ptr type,
    emit alloca+store to convert it. Returns (state, LLVMOperand). -/
private def ensurePtrOp (s : EmitSSAState) (v : SVal) : EmitSSAState × LLVMOperand :=
  match v with
  | .strConst name =>
    let (s, strTmp) := materializeStrConst s name
    (s, .reg (strTmp.drop 1).toString)
  | _ =>
  if isKnownPtr s v then
    (s, svalToOperand s v)
  else if isRefOrPtrTy v.ty then
    (s, svalToOperand s v)
  else if ssaIsPassByPtr s v.ty then
    let llTy := tyToLLVMTy s v.ty
    let (s, tmp) := freshLocal s
    let tmpName := (tmp.drop 1).toString
    let s := emitStructured s (.alloca tmpName llTy)
    let s := emitStructured s (.store llTy (svalToOperand s v) (.reg tmpName))
    (s, .reg tmpName)
  else
    (s, svalToOperand s v)

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
  let operandTy := lhs.ty
  -- Pointer arithmetic: ptr + int → getelementptr <pointee>, ptr %p, i64 %n
  -- GEP scales the offset by the pointee element size automatically
  if isPointerTy operandTy && (op == .add || op == .sub) then
    let lOp := svalToOperand s lhs
    let rOp := svalToOperand s rhs
    let pointeeTy := match operandTy with
      | .ptrMut t | .ptrConst t => tyToLLVMTy s t
      | _ => .i8
    let (s, idxOp) := if op == .sub then
      let negReg := s!"{dst}.neg"
      let s := emitStructured s (.binOp negReg .sub .i64 (.intLit 0) rOp)
      (s, LLVMOperand.reg negReg)
    else (s, rOp)
    emitStructured s (.gep dst pointeeTy lOp [(.i64, idxOp)])
  else if isFloatTy operandTy then
    let fTy := floatTyToLLVMTy operandTy
    let lOp := svalToOperand s lhs
    let rOp := svalToOperand s rhs
    let llOp := match op with
      | .add => LLVMBinOp.fadd | .sub => .fsub | .mul => .fmul | .div => .fdiv | .mod => .frem
      | .eq => .fcmpOeq | .neq => .fcmpUne
      | .lt => .fcmpOlt | .gt => .fcmpOgt | .leq => .fcmpOle | .geq => .fcmpOge
      | _ => .fadd
    emitStructured s (.binOp dst llOp fTy lOp rOp)
  else
    let isPtrTy := match operandTy with | .ptrMut _ | .ptrConst _ | .ref _ | .refMut _ => true | _ => false
    let iTy := if isPtrTy then LLVMTy.ptr else intTyToLLVMTy operandTy
    let lOp := svalToOperand s lhs
    let rOp := svalToOperand s rhs
    match op with
    | .add => emitStructured s (.binOp dst .add iTy lOp rOp)
    | .sub => emitStructured s (.binOp dst .sub iTy lOp rOp)
    | .mul => emitStructured s (.binOp dst .mul iTy lOp rOp)
    | .div =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .sdiv iTy lOp rOp)
      else emitStructured s (.binOp dst .udiv iTy lOp rOp)
    | .mod =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .srem iTy lOp rOp)
      else emitStructured s (.binOp dst .urem iTy lOp rOp)
    | .eq => emitStructured s (.binOp dst .icmpEq iTy lOp rOp)
    | .neq => emitStructured s (.binOp dst .icmpNe iTy lOp rOp)
    | .lt =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .icmpSlt iTy lOp rOp)
      else emitStructured s (.binOp dst .icmpUlt iTy lOp rOp)
    | .gt =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .icmpSgt iTy lOp rOp)
      else emitStructured s (.binOp dst .icmpUgt iTy lOp rOp)
    | .leq =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .icmpSle iTy lOp rOp)
      else emitStructured s (.binOp dst .icmpUle iTy lOp rOp)
    | .geq =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .icmpSge iTy lOp rOp)
      else emitStructured s (.binOp dst .icmpUge iTy lOp rOp)
    | .and_ => emitStructured s (.binOp dst .and_ .i1 lOp rOp)
    | .or_ => emitStructured s (.binOp dst .or_ .i1 lOp rOp)
    | .bitand => emitStructured s (.binOp dst .and_ iTy lOp rOp)
    | .bitor => emitStructured s (.binOp dst .or_ iTy lOp rOp)
    | .bitxor => emitStructured s (.binOp dst .xor_ iTy lOp rOp)
    | .shl => emitStructured s (.binOp dst .shl iTy lOp rOp)
    | .shr =>
      if ssaIsSignedInt operandTy then emitStructured s (.binOp dst .ashr iTy lOp rOp)
      else emitStructured s (.binOp dst .lshr iTy lOp rOp)

private def emitSInst (s : EmitSSAState) (inst : SInst) : EmitSSAState :=
  match inst with
  | .binOp dst op lhs rhs ty => emitBinOp s dst op lhs rhs ty
  | .unaryOp dst op operand ty =>
    let valOp := svalToOperand s operand
    match op with
    | .neg =>
      if isFloatTy ty then
        emitStructured s (.fneg dst (floatTyToLLVMTy ty) valOp)
      else
        emitStructured s (.binOp dst .sub (intTyToLLVMTy ty) (.intLit 0) valOp)
    | .not_ => emitStructured s (.binOp dst .xor_ .i1 valOp (.intLit 1))
    | .bitnot => emitStructured s (.binOp dst .xor_ (intTyToLLVMTy ty) valOp (.intLit (-1)))
  | .call dst fn args retTy =>
    -- Build typed argument list
    let (s, argOps) := args.foldl (fun (s, ops) a =>
      let paramTy := paramTyToLLVMTy s a.ty
      match a with
      | .strConst name =>
        -- String constants always passed as ptr to %struct.String
        let (s, strPtr) := materializeStrConst s name
        (s, ops ++ [(.ptr, .reg (strPtr.drop 1).toString)])
      | _ =>
      let valTy := tyToLLVMTy s a.ty
      if paramTy == .ptr && valTy != .ptr then
        -- If the register is already known to be a pointer (e.g. a struct
        -- parameter passed by ptr), pass it directly instead of
        -- alloca+store which would misuse the ptr as a struct value.
        if isKnownPtr s a then
          (s, ops ++ [(.ptr, svalToOperand s a)])
        else
          let (s, tmp) := freshLocal s
          let tmpName := (tmp.drop 1).toString
          let s := emitStructured s (.alloca tmpName valTy)
          let s := emitStructured s (.store valTy (svalToOperand s a) (.reg tmpName))
          (s, ops ++ [(.ptr, .reg tmpName)])
      else
        (s, ops ++ [(paramTy, svalToOperand s a)])
    ) (s, ([] : List (LLVMTy × LLVMOperand)))
    let retLLTy := tyToLLVMTy s retTy
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
    let callTarget : LLVMOperand := if isIndirect then
      if fn.startsWith "%" then .reg (fn.drop 1).toString
      else .reg fn
    else .global linkerFn
    emitStructured s (.call dst retLLTy callTarget argOps)
  | .alloca dst ty =>
    let s := emitStructured s (.alloca dst (tyToLLVMTy s ty))
    markPtr s dst
  | .load dst ptr ty =>
    let (s, ptrOp) := ensurePtrOp s ptr
    let s := emitStructured s (.load dst (tyToLLVMTy s ty) ptrOp)
    -- Track registers that hold function pointers (loaded from struct fields etc.)
    match ty with
    | .fn_ _ _ _ => { s with fnTypeRegs := s.fnTypeRegs ++ [dst] }
    | _ => s
  | .store val ptr =>
    let (s, ptrOp) := ensurePtrOp s ptr
    match val with
    | .strConst name =>
      -- Copy string struct from materialized temp to destination
      let (s, srcPtr) := materializeStrConst s name
      let sz := ssaTySize s .string
      emitStructured s (.memcpy ptrOp (.reg (srcPtr.drop 1).toString) sz)
    | _ =>
    -- If the value is a known pointer but typed as a struct, it is
    -- actually a pointer to the struct (e.g. a pass-by-ptr param).
    -- Use memcpy rather than a store that would misinterpret ptr as struct.
    if isKnownPtr s val && ssaIsPassByPtr s val.ty then
      let sz := ssaTySize s val.ty
      emitStructured s (.memcpy ptrOp (svalToOperand s val) sz)
    else
      emitStructured s (.store (tyToLLVMTy s val.ty) (svalToOperand s val) ptrOp)
  | .gep dst base indices ty =>
    let (s, basePtrOp) := ensurePtrOp s base
    let idxOps := indices.map fun i => (tyToLLVMTy s i.ty, svalToOperand s i)
    let s := emitStructured s (.gep dst (tyToLLVMTy s ty) basePtrOp idxOps)
    markPtr s dst
  | .phi dst incoming ty =>
    let pairs := incoming.map fun (v, lbl) => (svalToOperand s v, lbl)
    emitStructured s (.phi dst (tyToLLVMTy s ty) pairs)
  | .cast dst val targetTy =>
    match val with
    | .strConst name =>
      -- String constant → ptr: materialize the %struct.String and return ptr
      let (s, strPtr) := materializeStrConst s name
      let s := emitStructured s (.gep dst .i8 (.reg (strPtr.drop 1).toString) [(.i32, .intLit 0)])
      markPtr s dst
    | _ =>
    let srcTy := val.ty
    let srcLLTy := tyToLLVMTy s srcTy
    let dstLLTy := tyToLLVMTy s targetTy
    let valOp := svalToOperand s val
    if srcLLTy == dstLLTy then
      -- Same type, just alias
      if srcLLTy == .ptr then emitStructured s (.gep dst .i8 valOp [(.i32, .intLit 0)])
      else emitStructured s (.binOp dst .add srcLLTy valOp (.intLit 0))
    else if srcLLTy == .ptr || dstLLTy == .ptr then
      if srcLLTy == .ptr && isIntegerTy targetTy then
        emitStructured s (.cast dst .ptrtoint .ptr valOp dstLLTy)
      else if dstLLTy == .ptr && isIntegerTy srcTy then
        emitStructured s (.cast dst .inttoptr srcLLTy valOp .ptr)
      else if srcLLTy == .ptr then
        -- ptr → non-int (e.g. ptr → struct): ptrtoint
        emitStructured s (.cast dst .ptrtoint .ptr valOp dstLLTy)
      else
        -- non-ptr → ptr: use inttoptr for ints, alloca+store for structs
        if ssaIsPassByPtr s srcTy then
          let (s, tmp) := freshLocal s
          let tmpName := (tmp.drop 1).toString
          let s := emitStructured s (.alloca tmpName srcLLTy)
          let s := emitStructured s (.store srcLLTy valOp (.reg tmpName))
          let s := emitStructured s (.gep dst .i8 (.reg tmpName) [(.i32, .intLit 0)])
          markPtr s dst
        else
          emitStructured s (.cast dst .inttoptr srcLLTy valOp .ptr)
    else if isIntegerTy srcTy && isIntegerTy targetTy then
      let srcBits := match srcTy with
        | .i8 | .u8 | .char => 8 | .i16 | .u16 => 16 | .i32 | .u32 => 32 | _ => 64
      let dstBits := match targetTy with
        | .i8 | .u8 | .char => 8 | .i16 | .u16 => 16 | .i32 | .u32 => 32 | _ => 64
      if srcBits < dstBits then
        if ssaIsSignedInt srcTy then emitStructured s (.cast dst .sext srcLLTy valOp dstLLTy)
        else emitStructured s (.cast dst .zext srcLLTy valOp dstLLTy)
      else if srcBits > dstBits then
        emitStructured s (.cast dst .trunc srcLLTy valOp dstLLTy)
      else
        emitStructured s (.cast dst .bitcast srcLLTy valOp dstLLTy)
    else if isIntegerTy srcTy && isFloatTy targetTy then
      if ssaIsSignedInt srcTy then emitStructured s (.cast dst .sitofp srcLLTy valOp dstLLTy)
      else emitStructured s (.cast dst .uitofp srcLLTy valOp dstLLTy)
    else if isFloatTy srcTy && isIntegerTy targetTy then
      if ssaIsSignedInt targetTy then emitStructured s (.cast dst .fptosi srcLLTy valOp dstLLTy)
      else emitStructured s (.cast dst .fptoui srcLLTy valOp dstLLTy)
    else if isFloatTy srcTy && isFloatTy targetTy then
      let srcBits := if srcTy == .float32 then 32 else 64
      let dstBits := if targetTy == .float32 then 32 else 64
      if srcBits < dstBits then emitStructured s (.cast dst .fpext srcLLTy valOp dstLLTy)
      else emitStructured s (.cast dst .fptrunc srcLLTy valOp dstLLTy)
    else
      -- Fallback: alloca+store+load to "bitcast"
      let (s, tmp) := freshLocal s
      let tmpName := (tmp.drop 1).toString
      let s := emitStructured s (.alloca tmpName srcLLTy)
      let s := emitStructured s (.store srcLLTy valOp (.reg tmpName))
      emitStructured s (.load dst dstLLTy (.reg tmpName))
  | .memcpy dst src size =>
    emitStructured s (.memcpy (svalToOperand s dst) (svalToOperand s src) size)

-- ============================================================
-- Emit SBlock / SFnDef
-- ============================================================

/-- Emit a block terminator. Returns the (possibly modified) state and a structured LLVMTerm.
    May add pre-terminator instructions (e.g. loads for struct return values). -/
private def emitSTerm (s : EmitSSAState) (t : STerm) : EmitSSAState × LLVMTerm :=
  match t with
  | .ret (some v) =>
    let llTy := tyToLLVMTy s v.ty
    if llTy == .void then (s, .ret .void none)
    else match v with
    | .strConst _ =>
      -- String constant: materialize as struct, load, return by value
      let (s, ptr) := materializeStrConst s (match v with | .strConst n => n | _ => "")
      let (s, tmp) := freshLocal s
      let tmpName := (tmp.drop 1).toString
      let s := emitStructured s (.load tmpName llTy (.reg (ptr.drop 1).toString))
      (s, .ret llTy (some (.reg tmpName)))
    | _ =>
    if isKnownPtr s v && ssaIsPassByPtr s v.ty then
      -- Value is a pointer to a struct (e.g. pass-by-ptr param); load it
      -- so we return the struct by value as the LLVM signature expects.
      let (s, tmp) := freshLocal s
      let tmpName := (tmp.drop 1).toString
      let s := emitStructured s (.load tmpName llTy (svalToOperand s v))
      (s, .ret llTy (some (.reg tmpName)))
    else (s, .ret llTy (some (svalToOperand s v)))
  | .ret none => (s, .ret .void none)
  | .br lbl => (s, .br lbl)
  | .condBr cond tl el =>
    (s, .condBr (svalToOperand s cond) tl el)
  | .unreachable => (s, .unreachable)

private def emitSBlock (s : EmitSSAState) (b : SBlock) : EmitSSAState :=
  -- Start fresh instruction list for this block
  let s := { s with currentInstrs := #[] }
  -- Emit all instructions
  let s := b.insts.foldl emitSInst s
  -- Emit terminator (may add pre-terminator instructions to currentInstrs)
  let (s, term) := emitSTerm s b.term
  -- Create the block with structured instructions and terminator
  let block : LLVMBlock := {
    label := b.label
    instrs := s.currentInstrs.toList
    term := term
  }
  { s with
    currentBlocks := s.currentBlocks.push block
    currentInstrs := #[]
  }

private def emitSFnDef (s : EmitSSAState) (f : SFnDef) (isUserMain : Bool) : EmitSSAState :=
  let retTy := tyToLLVMTy s f.retTy
  let fnName := if isUserMain then "user_main" else f.name
  let params := f.params.map fun (n, t) => (n, paramTyToLLVMTy s t)
  -- Reset per-function state
  let s := { s with currentBlocks := #[], fnParams := f.params }
  -- Mark struct-type params as pointers, track fn params for indirect calls
  let s := f.params.foldl (fun s (n, t) =>
    match t with
    | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => markPtr s n
    | _ => if ssaIsPassByPtr s t then markPtr s n else s
  ) s
  -- Emit all blocks
  let s := f.blocks.foldl emitSBlock s
  -- Build structured function definition
  let fnDef : LLVMFnDef := {
    name := fnName
    retTy := retTy
    params := params
    blocks := s.currentBlocks.toList
  }
  let s := { s with moduleFunctions := s.moduleFunctions.push fnDef }
  -- Reset per-function state
  { s with ptrRegs := [], fnParams := [], fnTypeRegs := [], currentBlocks := #[], currentInstrs := #[] }

-- ============================================================
-- Emit struct/enum type definitions
-- ============================================================

-- ============================================================
-- Emit external declarations and builtins
-- ============================================================

private def emitExternDecls (s : EmitSSAState) (externFns : List (String × List (String × Ty) × Ty))
    (definedFns : List String := []) : EmitSSAState :=
  -- Standard C runtime declarations (used by remaining builtins)
  let s := emitDecl s { name := "malloc", retTy := .ptr, params := [.i64] }
  let s := emitDecl s { name := "free", retTy := .void, params := [.ptr] }
  let s := emitDecl s { name := "realloc", retTy := .ptr, params := [.ptr, .i64] }
  let s := emitDecl s { name := "llvm.memcpy.p0.p0.i64", retTy := .void, params := [.ptr, .ptr, .i64, .i1] }
  let s := emitDecl s { name := "write", retTy := .i64, params := [.i32, .ptr, .i64] }
  let s := emitDecl s { name := "abort", retTy := .void, params := [] }
  let s := emitDecl s { name := "printf", retTy := .i32, params := [.ptr], variadic := true }
  let s := emitDecl s { name := "strlen", retTy := .i64, params := [.ptr] }
  let s := emitDecl s { name := "memset", retTy := .ptr, params := [.ptr, .i32, .i64] }
  let s := emitDecl s { name := "memcmp", retTy := .i32, params := [.ptr, .ptr, .i64] }
  -- Conversion builtin dependencies
  let s := emitDecl s { name := "snprintf", retTy := .i32, params := [.ptr, .i64, .ptr], variadic := true }
  let s := emitDecl s { name := "strtol", retTy := .i64, params := [.ptr, .ptr, .i32] }
  -- Names already declared above — skip duplicates from user extern fns
  let builtinNames : List String := [
    "malloc", "free", "realloc", "write", "abort", "printf", "strlen",
    "memset", "memcmp", "snprintf", "strtol"
  ]
  -- User extern function declarations (skip if already defined as a concrete function)
  externFns.foldl (fun s (name, params, retTy) =>
    if builtinNames.contains name || definedFns.contains name then s
    else
      let retLLTy := tyToLLVMTy s retTy
      let paramTys := params.map fun (_, t) => paramTyToLLVMTy s t
      emitDecl s { name := name, retTy := retLLTy, params := paramTys }
  ) s

/-- Emit the main wrapper that calls user_main and prints the result.
    For void/unit return types, the wrapper just calls user_main without printing.
    For int/bool/other scalar types, it prints the result. -/
private def emitMainWrapper (s : EmitSSAState) (retTy : Ty) : EmitSSAState :=
  let retLLTyS := tyToLLVMTy s retTy
  let retLLTy := printLLVMTy retLLTyS
  let wrapperText := if retLLTyS == .void then
    -- Unit/void return: just call, no print
    "define i32 @main() {\n" ++
    "  call void @user_main()\n" ++
    "  ret i32 0\n" ++
    "}\n\n"
  else if retLLTyS == .i1 then
    -- Bool return: print "true" or "false"
    "@fmt.true = private constant [5 x i8] c\"true\\00\"\n" ++
    "@fmt.false = private constant [6 x i8] c\"false\\00\"\n" ++
    "@fmt.main.s = private constant [4 x i8] c\"%s\\0A\\00\"\n" ++
    "\n" ++
    "define i32 @main() {\n" ++
    "  %result = call i1 @user_main()\n" ++
    "  %true_str = getelementptr [5 x i8], ptr @fmt.true, i32 0, i32 0\n" ++
    "  %false_str = getelementptr [6 x i8], ptr @fmt.false, i32 0, i32 0\n" ++
    "  %str = select i1 %result, ptr %true_str, ptr %false_str\n" ++
    "  %fmt = getelementptr [4 x i8], ptr @fmt.main.s, i32 0, i32 0\n" ++
    "  call i32 (ptr, ...) @printf(ptr %fmt, ptr %str)\n" ++
    "  ret i32 0\n" ++
    "}\n\n"
  else if retLLTyS == .i64 then
    -- i64 return: print with %lld
    "@fmt.main = private constant [6 x i8] c\"%lld\\0A\\00\"\n" ++
    "\n" ++
    "define i32 @main() {\n" ++
    "  %result = call i64 @user_main()\n" ++
    "  %fmt = getelementptr [6 x i8], ptr @fmt.main, i32 0, i32 0\n" ++
    "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %result)\n" ++
    "  ret i32 0\n" ++
    "}\n\n"
  else if retLLTyS == .i32 || retLLTyS == .i16 || retLLTyS == .i8 then
    -- Smaller integer return: widen to i64, then print
    let ext := if ssaIsSignedInt retTy then "sext" else "zext"
    "@fmt.main = private constant [6 x i8] c\"%lld\\0A\\00\"\n" ++
    "\n" ++
    "define i32 @main() {\n" ++
    s!"  %result = call {retLLTy} @user_main()\n" ++
    s!"  %result64 = {ext} {retLLTy} %result to i64\n" ++
    "  %fmt = getelementptr [6 x i8], ptr @fmt.main, i32 0, i32 0\n" ++
    "  call i32 (ptr, ...) @printf(ptr %fmt, i64 %result64)\n" ++
    "  ret i32 0\n" ++
    "}\n\n"
  else
    -- For other types (structs, strings, etc.), just call and return 0
    s!"define i32 @main() \{\n" ++
    s!"  %result = call {retLLTy} @user_main()\n" ++
    "  ret i32 0\n" ++
    "}\n\n"
  { s with rawSections := s.rawSections.push wrapperText }

-- ============================================================
-- Emit string literal globals
-- ============================================================

/-- Generate all builtin function implementations by reusing the old codegen's Builtins. -/
private def getBuiltinsIR : String :=
  let initState : CodegenState := default
  let s := genBuiltinFunctions initState
  let s := genConversionBuiltins s
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

/-- Emit builtin implementations needed by the program. -/
private def emitBuiltins (s : EmitSSAState) : EmitSSAState :=
  { s with rawSections := s.rawSections.push (getBuiltinsIR ++ getVecBuiltinsIR) }

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
      emitTypeDef s (Layout.structTypeDef (layoutCtxOf s) sd)
  ) s
  let ctx := layoutCtxOf s
  let s := m.enums.foldl (fun s ed =>
    if s.emittedTypes.contains ed.name then s
    else
      let s := { s with emittedTypes := ed.name :: s.emittedTypes }
      (Layout.enumTypeDefs ctx ed).foldl (fun s line => emitTypeDef s line) s
  ) s
  -- String literal globals
  let s := m.globals.foldl (fun s (name, val) =>
    let escaped := ssaEscapeStringForLLVM val
    let len := val.length + 1
    let s := emitGlobal s { name := name, ty := .array len .i8, value := s!"c\"{escaped}\\00\"" }
    { s with stringLengths := s.stringLengths ++ [(name, val.length)] }
  ) s
  -- Functions
  let hasMain := m.functions.any fun f => f.isEntryPoint
  let s := m.functions.foldl (fun s f =>
    emitSFnDef s f f.isEntryPoint
  ) s
  -- Main wrapper (skip in test mode — test runner provides main)
  if testMode then s
  else if hasMain then
    match m.functions.find? fun f => f.isEntryPoint with
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
    | .generic n [arg] => if n == optionEnumName then some arg else none
    | _ => none
  let resPayloads := allTys.filterMap fun t =>
    match t with
    | .generic n [ok, err] => if n == resultEnumName then some (ok, err) else none
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

private def emitTestRunner (s : EmitSSAState) (modules : List SModule) (moduleFilter : Option String := none) : EmitSSAState :=
  -- Collect all test functions across all modules
  let testFns := modules.foldl (fun acc m =>
    acc ++ (m.functions.filter fun f => f.isTest)
  ) []
  -- If a module filter is given, only keep tests whose modulePath starts with the filter
  let testFns := match moduleFilter with
    | none => testFns
    | some modPrefix => testFns.filter fun f =>
        f.modulePath == modPrefix || f.modulePath.startsWith (modPrefix ++ ".")
  if testFns.isEmpty then
    -- No tests found: emit a main that prints a message and returns 0
    let runnerText :=
      "@fmt.test.none = private constant [15 x i8] c\"No tests found\\00\"\n" ++
      "@fmt.test.nl = private constant [2 x i8] c\"\\0A\\00\"\n" ++
      "\n" ++
      "define i32 @main() {\n" ++
      "  %fmt = getelementptr [15 x i8], ptr @fmt.test.none, i32 0, i32 0\n" ++
      "  call i32 (ptr, ...) @printf(ptr %fmt)\n" ++
      "  %nl = getelementptr [2 x i8], ptr @fmt.test.nl, i32 0, i32 0\n" ++
      "  call i32 (ptr, ...) @printf(ptr %nl)\n" ++
      "  ret i32 0\n" ++
      "}\n\n"
    { s with rawSections := s.rawSections.push runnerText }
  else
    -- Build the entire test runner as a raw section using foldl
    -- Emit string constants for each test name
    let nameConsts := testFns.foldl (fun acc f =>
      let nameLen := f.name.length + 1
      let escaped := ssaEscapeStringForLLVM f.name
      acc ++ s!"@test.name.{f.name} = private constant [{nameLen} x i8] c\"{escaped}\\00\"\n"
    ) ""
    -- Emit format strings
    let fmtConsts :=
      "@fmt.test.pass = private constant [10 x i8] c\"PASS: %s\\0A\\00\"\n" ++
      "@fmt.test.fail = private constant [10 x i8] c\"FAIL: %s\\0A\\00\"\n" ++
      "\n"
    -- Generate main() header
    let mainHeader :=
      "define i32 @main() {\n" ++
      "  %failures = alloca i32\n" ++
      "  store i32 0, ptr %failures\n" ++
      "\n"
    -- Call each test function
    let (testBody, _) := testFns.foldl (fun (acc, idx) f =>
      let i := toString idx
      let nameLen := f.name.length + 1
      let body := acc
        ++ s!"  ; Test: {f.name}\n"
        ++ s!"  %result.{i} = call i32 @{f.name}()\n"
        ++ s!"  %is_pass.{i} = icmp eq i32 %result.{i}, 0\n"
        ++ s!"  %name.{i} = getelementptr [{nameLen} x i8], ptr @test.name.{f.name}, i32 0, i32 0\n"
        ++ s!"  br i1 %is_pass.{i}, label %pass.{i}, label %fail.{i}\n"
        ++ "\n"
        ++ s!"pass.{i}:\n"
        ++ s!"  %pfmt.{i} = getelementptr [10 x i8], ptr @fmt.test.pass, i32 0, i32 0\n"
        ++ s!"  call i32 (ptr, ...) @printf(ptr %pfmt.{i}, ptr %name.{i})\n"
        ++ s!"  br label %next.{i}\n"
        ++ "\n"
        ++ s!"fail.{i}:\n"
        ++ s!"  %ffmt.{i} = getelementptr [10 x i8], ptr @fmt.test.fail, i32 0, i32 0\n"
        ++ s!"  call i32 (ptr, ...) @printf(ptr %ffmt.{i}, ptr %name.{i})\n"
        -- Increment failures
        ++ s!"  %old_fail.{i} = load i32, ptr %failures\n"
        ++ s!"  %new_fail.{i} = add i32 %old_fail.{i}, 1\n"
        ++ s!"  store i32 %new_fail.{i}, ptr %failures\n"
        ++ s!"  br label %next.{i}\n"
        ++ "\n"
        ++ s!"next.{i}:\n"
      (body, idx + 1)
    ) ("", 0)
    -- Return: 1 if any failed, 0 if all passed
    let mainFooter :=
      "  %total_fail = load i32, ptr %failures\n" ++
      "  %any_fail = icmp sgt i32 %total_fail, 0\n" ++
      "  %exit = select i1 %any_fail, i32 1, i32 0\n" ++
      "  ret i32 %exit\n" ++
      "}\n\n"
    let runnerText := nameConsts ++ fmtConsts ++ mainHeader ++ testBody ++ mainFooter
    { s with rawSections := s.rawSections.push runnerText }

def emitSSAProgram (modules : List SModule) (testMode : Bool := false) (moduleFilter : Option String := none) : String :=
  let s : EmitSSAState := {}
  -- Collect all structs and enums for type resolution
  let allStructs := modules.foldl (fun acc m => acc ++ m.structs) []
  let allEnums := modules.foldl (fun acc m => acc ++ m.enums) []
  -- Canonical builtin enum definitions with type parameters
  let optionDef : CEnumDef :=
    { name := optionEnumName, typeParams := ["T"],
      variants := [("Some", [("value", .typeVar "T")]), ("None", [])],
      builtinId := some .option }
  let resultDef : CEnumDef :=
    { name := resultEnumName, typeParams := ["T", "E"],
      variants := [(okVariantName, [("value", .typeVar "T")]), (errVariantName, [("value", .typeVar "E")])],
      builtinId := some .result }
  let builtinEnums : List CEnumDef := [optionDef, resultDef]
  let s := { s with structDefs := allStructs, enumDefs := builtinEnums ++ allEnums }
  -- Header
  let s := { s with moduleHeader := s.moduleHeader.push "; Generated by Concrete compiler (SSA path)" }
  -- Well-known struct types (String, Vec)
  let s := Layout.builtinTypeDefs.foldl (fun s line => emitTypeDef s line) s
  -- Mark builtins as emitted so user-defined versions don't duplicate them
  let s := { s with emittedTypes := ["String", "Vec"] ++ s.emittedTypes }
  -- Whole-program monomorphic ABI for builtin generic enums:
  -- Scan all SSA modules for concrete type arguments, then emit a single LLVM type
  -- definition sized to the largest payload across all instantiations.
  -- Smaller payloads under-fill the slot (wasted padding) but are correct.
  -- Builtin functions (vec_pop, etc.) store i64 payloads, which always fit.
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
  let s := optTypeDefs.foldl (fun s line => emitTypeDef s line) s
  -- Generate dynamic Result type def
  let resTypeArgs := match bestRes with
    | some (ok, err) => [ok, err]
    | none => [Ty.int, Ty.int]  -- fallback: i64 payloads
  let resTypeDefs := Layout.enumTypeDefs ctx resultDef resTypeArgs
  let s := resTypeDefs.foldl (fun s line => emitTypeDef s line) s
  -- Mark these as emitted so user enums with the same names won't duplicate
  let s := { s with emittedTypes := [resultEnumName, optionEnumName] ++ s.emittedTypes }
  -- External declarations (skip externs that shadow defined functions)
  let allExternFns := modules.foldl (fun acc m => acc ++ m.externFns) []
  let allDefinedFns := modules.foldl (fun acc m => acc ++ m.functions.map (·.name)) []
  let s := emitExternDecls s allExternFns allDefinedFns
  -- Emit each module
  let s := modules.foldl (fun s m => emitSModule s m testMode) s
  -- In test mode, emit the test runner instead of the normal main wrapper
  let s := if testMode then emitTestRunner s modules moduleFilter else s
  -- Emit builtin function implementations
  let s := emitBuiltins s
  -- Assemble the final LLVMModule and print it
  let llvmModule : LLVMModule := {
    header := s.moduleHeader.toList
    typeDefs := s.moduleTypeDefs.toList
    globals := s.moduleGlobals.toList
    declarations := s.moduleDeclarations.toList
    functions := s.moduleFunctions.toList
    rawSections := s.rawSections.toList
  }
  printLLVMModule llvmModule

end Concrete
