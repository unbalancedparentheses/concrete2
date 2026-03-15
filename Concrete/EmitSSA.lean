import Concrete.SSA
import Concrete.Core
import Concrete.Layout
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
  /-- Distinct Vec element specs (elemSize, optionPayloadOffset) used in the program.
      Used to generate per-size vec builtin implementations. -/
  vecElemSpecs : List (Nat × Nat) := []

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
      | none =>
        dbg_trace s!"WARNING: EmitSSA.tyToLLVMTy: unknown named type '{name}', defaulting to i64"
        .i64

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

/-- Get byte alignment of a type. -/
private def ssaTyAlign (s : EmitSSAState) (ty : Ty) : Nat :=
  Layout.tyAlign (layoutCtxOf s) ty

/-- Extract the Vec element type from a type like `Vec<T>`, `&Vec<T>`, or `&mut Vec<T>`. -/
private def vecElemTy : Ty → Option Ty
  | .generic "Vec" (t :: _) => some t
  | .ref (.generic "Vec" (t :: _)) => some t
  | .refMut (.generic "Vec" (t :: _)) => some t
  | _ => none

/-- The set of vec intrinsic names that need per-size specialization.
    vec_len and vec_free are size-independent and stay unspecialized. -/
private def vecSizedOps : List String :=
  ["vec_new", "vec_push", "vec_get", "vec_set", "vec_pop"]

/-- Resolve the Vec element size for a call to a vec intrinsic.
    Returns `(specializedName, elemSize, optionPayloadOffset)` or none if not a vec op.
    The payload offset is needed for vec_pop's Option construction. -/
private def resolveVecCall (s : EmitSSAState) (fn : String) (args : List SVal) (retTy : Ty) : Option (String × Nat × Nat) :=
  if !vecSizedOps.contains fn then none
  else
    -- Extract element type from args or return type
    let elemTy? : Option Ty :=
      if fn == "vec_new" then vecElemTy retTy
      else if fn == "vec_get" then some retTy
      else if fn == "vec_pop" then
        match retTy with
        | .generic _ (t :: _) => some t  -- Option<T> → T
        | _ => none
      else
        -- vec_push, vec_set: get from first arg (the Vec ref)
        match args.head? with
        | some v => vecElemTy v.ty
        | none => none
    match elemTy? with
    | some elemTy =>
      let sz := ssaTySize s elemTy
      let al := ssaTyAlign s elemTy
      let payOff := Layout.alignUp 4 al
      -- vec_pop is named by size_payoff (different alignments need different Option layouts)
      let name := if fn == "vec_pop" then s!"{fn}_{sz}_{payOff}" else s!"{fn}_{sz}"
      some (name, sz, payOff)
    | none => none

/-- Record a Vec element spec as used (for builtin generation). -/
private def recordVecElemSpec (s : EmitSSAState) (sz : Nat) (payOff : Nat) : EmitSSAState :=
  if s.vecElemSpecs.any fun (s, p) => s == sz && p == payOff then s
  else { s with vecElemSpecs := s.vecElemSpecs ++ [(sz, payOff)] }

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

/-- Ensure any value is available as a pointer.
    Unlike ensurePtrOp, this also wraps scalars via alloca+store. -/
private def ensureValAsPtr (s : EmitSSAState) (v : SVal) : EmitSSAState × LLVMOperand :=
  if isKnownPtr s v then
    (s, svalToOperand s v)
  else if isRefOrPtrTy v.ty then
    (s, svalToOperand s v)
  else
    let llTy := tyToLLVMTy s v.ty
    let (s, tmp) := freshLocal s
    let tmpName := (tmp.drop 1).toString
    let s := emitStructured s (.alloca tmpName llTy)
    let s := emitStructured s (.store llTy (svalToOperand s v) (.reg tmpName))
    (s, .reg tmpName)

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
    -- Intercept vec sized operations for per-element-size dispatch
    match resolveVecCall s fn args retTy with
    | some (specFn, es, payOff) =>
      let s := recordVecElemSpec s es payOff
      if fn == "vec_new" then
        emitStructured s (.call dst (.struct_ "Vec") (.global specFn) [])
      else if fn == "vec_get" then
        match args with
        | [vecArg, idxArg] =>
          let (s, vecPtr) := ensurePtrOp s vecArg
          let idxOp := svalToOperand s idxArg
          let (s, slotTmp) := freshLocal s
          let slotName := (slotTmp.drop 1).toString
          let s := emitStructured s (.call (some slotName) .ptr (.global specFn) [(.ptr, vecPtr), (.i64, idxOp)])
          let s := markPtr s slotName
          match dst with
          | some d => emitStructured s (.load d (tyToLLVMTy s retTy) (.reg slotName))
          | none => s
        | _ => s
      else if fn == "vec_push" then
        match args with
        | [vecArg, valArg] =>
          let (s, vecPtr) := ensurePtrOp s vecArg
          let (s, valPtr) := ensureValAsPtr s valArg
          emitStructured s (.call none .void (.global specFn) [(.ptr, vecPtr), (.ptr, valPtr)])
        | _ => s
      else if fn == "vec_set" then
        match args with
        | [vecArg, idxArg, valArg] =>
          let (s, vecPtr) := ensurePtrOp s vecArg
          let idxOp := svalToOperand s idxArg
          let (s, valPtr) := ensureValAsPtr s valArg
          emitStructured s (.call none .void (.global specFn) [(.ptr, vecPtr), (.i64, idxOp), (.ptr, valPtr)])
        | _ => s
      else if fn == "vec_pop" then
        -- vec_pop returns %enum.Option by value, same calling convention as before
        match args with
        | [vecArg] =>
          let (s, vecPtr) := ensurePtrOp s vecArg
          let retLLTy := tyToLLVMTy s retTy
          emitStructured s (.call dst retLLTy (.global specFn) [(.ptr, vecPtr)])
        | _ => s
      else s
    | none =>
    -- General call path (non-vec or unspecialized vec ops like vec_len/vec_free)
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
  -- LLVM requires all PHI nodes at the top of a basic block.
  -- Lower.lean can interleave PHIs with other instructions (e.g. when multiple
  -- if-statements appear in a match arm), so partition and reorder here.
  let isPhi : LLVMInstr → Bool
    | .phi .. => true
    | _ => false
  let allInstrs := s.currentInstrs.toList
  let phis := allInstrs.filter isPhi
  let nonPhis := allInstrs.filter (fun i => !isPhi i)
  -- Create the block with PHIs first, then other instructions
  let block : LLVMBlock := {
    label := b.label
    instrs := phis ++ nonPhis
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
  let retLLTy := tyToLLVMTy s retTy
  let ret0 : LLVMTerm := .ret .i32 (some (.intLit 0))
  let printfTarget : LLVMOperand := .global "printf"
  let mkMainFn (blk : LLVMBlock) : LLVMFnDef :=
    { name := "main", retTy := .i32, params := [], blocks := [blk] }
  if retLLTy == .void then
    -- Unit/void return: just call, no print
    let instrs : List LLVMInstr := [.call none .void (.global "user_main") []]
    let mainFn := mkMainFn ⟨"entry", instrs, ret0⟩
    { s with moduleFunctions := s.moduleFunctions.push mainFn }
  else if retLLTy == .i1 then
    -- Bool return: print "true" or "false"
    let s := emitGlobal s { name := "fmt.true", ty := .array 5 .i8, value := "c\"true\\00\"" }
    let s := emitGlobal s { name := "fmt.false", ty := .array 6 .i8, value := "c\"false\\00\"" }
    let s := emitGlobal s { name := "fmt.main.s", ty := .array 4 .i8, value := "c\"%s\\0A\\00\"" }
    let instrs : List LLVMInstr := [
      .call (some "result") .i1 (.global "user_main") [],
      .gep "true_str" (.array 5 .i8) (.global "fmt.true") [(.i32, .intLit 0), (.i32, .intLit 0)],
      .gep "false_str" (.array 6 .i8) (.global "fmt.false") [(.i32, .intLit 0), (.i32, .intLit 0)],
      .select "str" (.reg "result") .ptr (.reg "true_str") (.reg "false_str"),
      .gep "fmt" (.array 4 .i8) (.global "fmt.main.s") [(.i32, .intLit 0), (.i32, .intLit 0)],
      .callVariadic none .i32 printfTarget [(.ptr, .reg "fmt"), (.ptr, .reg "str")]
    ]
    let mainFn := mkMainFn ⟨"entry", instrs, ret0⟩
    { s with moduleFunctions := s.moduleFunctions.push mainFn }
  else if retLLTy == .i64 then
    -- i64 return: print with %lld
    let s := emitGlobal s { name := "fmt.main", ty := .array 6 .i8, value := "c\"%lld\\0A\\00\"" }
    let instrs : List LLVMInstr := [
      .call (some "result") .i64 (.global "user_main") [],
      .gep "fmt" (.array 6 .i8) (.global "fmt.main") [(.i32, .intLit 0), (.i32, .intLit 0)],
      .callVariadic none .i32 printfTarget [(.ptr, .reg "fmt"), (.i64, .reg "result")]
    ]
    let mainFn := mkMainFn ⟨"entry", instrs, ret0⟩
    { s with moduleFunctions := s.moduleFunctions.push mainFn }
  else if retLLTy == .i32 || retLLTy == .i16 || retLLTy == .i8 then
    -- Smaller integer return: widen to i64, then print
    let castOp : LLVMCastOp := if ssaIsSignedInt retTy then .sext else .zext
    let s := emitGlobal s { name := "fmt.main", ty := .array 6 .i8, value := "c\"%lld\\0A\\00\"" }
    let instrs : List LLVMInstr := [
      .call (some "result") retLLTy (.global "user_main") [],
      .cast "result64" castOp retLLTy (.reg "result") .i64,
      .gep "fmt" (.array 6 .i8) (.global "fmt.main") [(.i32, .intLit 0), (.i32, .intLit 0)],
      .callVariadic none .i32 printfTarget [(.ptr, .reg "fmt"), (.i64, .reg "result64")]
    ]
    let mainFn := mkMainFn ⟨"entry", instrs, ret0⟩
    { s with moduleFunctions := s.moduleFunctions.push mainFn }
  else
    -- For other types (structs, strings, etc.), just call and return 0
    let instrs : List LLVMInstr := [.call (some "result") retLLTy (.global "user_main") []]
    let mainFn := mkMainFn ⟨"entry", instrs, ret0⟩
    { s with moduleFunctions := s.moduleFunctions.push mainFn }

-- ============================================================
-- Emit string literal globals
-- ============================================================

/-- Generate structured builtin function definitions, globals, and declarations
    for the string and conversion builtins. Replaces the old raw-string getBuiltinsIR. -/
private def getBuiltinFns : List LLVMFnDef × List LLVMGlobal × List LLVMFnDecl :=
  let strTy := LLVMTy.struct_ "String"
  let resTy := LLVMTy.enum_ "Result"
  -- Helper: getelementptr %struct.String, ptr %base, i32 0, i32 N
  let strGep (dst base : String) (fieldIdx : Int) : LLVMInstr :=
    .gep dst strTy (.reg base) [(.i32, .intLit 0), (.i32, .intLit fieldIdx)]
  -- Helper: dynamic memcpy as raw line (structured .memcpy only supports Nat size)
  let dynMemcpy (dst src len : String) : LLVMInstr :=
    .raw s!"  call void @llvm.memcpy.p0.p0.i64(ptr %{dst}, ptr %{src}, i64 %{len}, i1 false)"

  -- -------------------------------------------------------
  -- string_length
  -- -------------------------------------------------------
  let strLenBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr" "s" 1,
      .load "len" .i64 (.reg "len_ptr")
    ], .ret .i64 (some (.reg "len"))⟩]
  let fnStringLength : LLVMFnDef :=
    { name := "string_length", retTy := .i64, params := [("s", .ptr)], blocks := strLenBlocks }

  -- -------------------------------------------------------
  -- drop_string
  -- -------------------------------------------------------
  let dropStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "data_ptr" "s" 0,
      .load "data" .ptr (.reg "data_ptr"),
      .call none .void (.global "free") [(.ptr, .reg "data")]
    ], .ret .void none⟩]
  let fnDropString : LLVMFnDef :=
    { name := "drop_string", retTy := .void, params := [("s", .ptr)], blocks := dropStrBlocks }

  -- -------------------------------------------------------
  -- string_concat
  -- -------------------------------------------------------
  let strConcatBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "a_data_ptr" "a" 0,
      .load "a_data" .ptr (.reg "a_data_ptr"),
      strGep "a_len_ptr" "a" 1,
      .load "a_len" .i64 (.reg "a_len_ptr"),
      strGep "b_data_ptr" "b" 0,
      .load "b_data" .ptr (.reg "b_data_ptr"),
      strGep "b_len_ptr" "b" 1,
      .load "b_len" .i64 (.reg "b_len_ptr"),
      .binOp "total_len" .add .i64 (.reg "a_len") (.reg "b_len"),
      .call (some "buf") .ptr (.global "malloc") [(.i64, .reg "total_len")],
      dynMemcpy "buf" "a_data" "a_len",
      .gep "dst" .i8 (.reg "buf") [(.i64, .reg "a_len")],
      dynMemcpy "dst" "b_data" "b_len",
      .call none .void (.global "free") [(.ptr, .reg "a_data")],
      .call none .void (.global "free") [(.ptr, .reg "b_data")],
      .alloca "sc_alloca" strTy,
      strGep "sc_data_ptr" "sc_alloca" 0,
      .store .ptr (.reg "buf") (.reg "sc_data_ptr"),
      strGep "sc_len_ptr" "sc_alloca" 1,
      .store .i64 (.reg "total_len") (.reg "sc_len_ptr"),
      strGep "sc_cap_ptr" "sc_alloca" 2,
      .store .i64 (.reg "total_len") (.reg "sc_cap_ptr"),
      .load "sc_result" strTy (.reg "sc_alloca")
    ], .ret strTy (some (.reg "sc_result"))⟩]
  let fnStringConcat : LLVMFnDef :=
    { name := "string_concat", retTy := strTy, params := [("a", .ptr), ("b", .ptr)], blocks := strConcatBlocks }

  -- -------------------------------------------------------
  -- string_slice
  -- -------------------------------------------------------
  let strSliceBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr.ss" "s" 1,
      .load "len.ss" .i64 (.reg "len_ptr.ss"),
      .call (some "s_clamped") .i64 (.global "llvm.smax.i64") [(.i64, .reg "start"), (.i64, .intLit 0)],
      .call (some "s_min") .i64 (.global "llvm.smin.i64") [(.i64, .reg "s_clamped"), (.i64, .reg "len.ss")],
      .call (some "e_clamped") .i64 (.global "llvm.smax.i64") [(.i64, .reg "end_"), (.i64, .intLit 0)],
      .call (some "e_min") .i64 (.global "llvm.smin.i64") [(.i64, .reg "e_clamped"), (.i64, .reg "len.ss")],
      .call (some "e_final") .i64 (.global "llvm.smax.i64") [(.i64, .reg "e_min"), (.i64, .reg "s_min")],
      .binOp "slice_len" .sub .i64 (.reg "e_final") (.reg "s_min"),
      .call (some "slice_buf") .ptr (.global "malloc") [(.i64, .reg "slice_len")],
      strGep "data_ptr.ss" "s" 0,
      .load "data.ss" .ptr (.reg "data_ptr.ss"),
      .gep "src" .i8 (.reg "data.ss") [(.i64, .reg "s_min")],
      dynMemcpy "slice_buf" "src" "slice_len",
      .alloca "res.ss" strTy,
      strGep "res_d.ss" "res.ss" 0,
      .store .ptr (.reg "slice_buf") (.reg "res_d.ss"),
      strGep "res_l.ss" "res.ss" 1,
      .store .i64 (.reg "slice_len") (.reg "res_l.ss"),
      strGep "res_c.ss" "res.ss" 2,
      .store .i64 (.reg "slice_len") (.reg "res_c.ss"),
      .load "result.ss" strTy (.reg "res.ss")
    ], .ret strTy (some (.reg "result.ss"))⟩]
  let fnStringSlice : LLVMFnDef :=
    { name := "string_slice", retTy := strTy, params := [("s", .ptr), ("start", .i64), ("end_", .i64)], blocks := strSliceBlocks }

  -- -------------------------------------------------------
  -- string_char_at
  -- -------------------------------------------------------
  let strCharAtBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr.sca" "s" 1,
      .load "len.sca" .i64 (.reg "len_ptr.sca"),
      .binOp "neg" .icmpSlt .i64 (.reg "index") (.intLit 0),
      .binOp "oob" .icmpSge .i64 (.reg "index") (.reg "len.sca"),
      .binOp "bad" .or_ .i1 (.reg "neg") (.reg "oob")
    ], .condBr (.reg "bad") "ret_neg" "ok_idx"⟩,
    ⟨"ret_neg", []
    , .ret .i64 (some (.intLit (-1)))⟩,
    ⟨"ok_idx", [
      strGep "data_ptr.sca" "s" 0,
      .load "data.sca" .ptr (.reg "data_ptr.sca"),
      .gep "char_ptr" .i8 (.reg "data.sca") [(.i64, .reg "index")],
      .load "byte" .i8 (.reg "char_ptr"),
      .cast "char" .zext .i8 (.reg "byte") .i64
    ], .ret .i64 (some (.reg "char"))⟩]
  let fnStringCharAt : LLVMFnDef :=
    { name := "string_char_at", retTy := .i64, params := [("s", .ptr), ("index", .i64)], blocks := strCharAtBlocks }

  -- -------------------------------------------------------
  -- string_contains
  -- -------------------------------------------------------
  let strContainsBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "h_data_ptr" "haystack" 0,
      .load "h_data" .ptr (.reg "h_data_ptr"),
      strGep "h_len_ptr" "haystack" 1,
      .load "h_len" .i64 (.reg "h_len_ptr"),
      strGep "n_data_ptr" "needle" 0,
      .load "n_data" .ptr (.reg "n_data_ptr"),
      strGep "n_len_ptr" "needle" 1,
      .load "n_len" .i64 (.reg "n_len_ptr"),
      .binOp "n_empty" .icmpEq .i64 (.reg "n_len") (.intLit 0)
    ], .condBr (.reg "n_empty") "found" "check_len"⟩,
    ⟨"check_len", [
      .binOp "too_long" .icmpUgt .i64 (.reg "n_len") (.reg "h_len")
    ], .condBr (.reg "too_long") "not_found" "loop_start"⟩,
    ⟨"loop_start", [
      .binOp "max_i" .sub .i64 (.reg "h_len") (.reg "n_len")
    ], .br "loop"⟩,
    ⟨"loop", [
      .phi "i" .i64 [(.intLit 0, "loop_start"), (.reg "i_next", "loop_cont")],
      .gep "h_ptr" .i8 (.reg "h_data") [(.i64, .reg "i")],
      .call (some "cmp") .i32 (.global "memcmp") [(.ptr, .reg "h_ptr"), (.ptr, .reg "n_data"), (.i64, .reg "n_len")],
      .binOp "match" .icmpEq .i32 (.reg "cmp") (.intLit 0)
    ], .condBr (.reg "match") "found" "loop_cont"⟩,
    ⟨"loop_cont", [
      .binOp "i_next" .add .i64 (.reg "i") (.intLit 1),
      .binOp "done" .icmpUgt .i64 (.reg "i_next") (.reg "max_i")
    ], .condBr (.reg "done") "not_found" "loop"⟩,
    ⟨"found", [], .ret .i1 (some (.boolLit true))⟩,
    ⟨"not_found", [], .ret .i1 (some (.boolLit false))⟩]
  let fnStringContains : LLVMFnDef :=
    { name := "string_contains", retTy := .i1, params := [("haystack", .ptr), ("needle", .ptr)], blocks := strContainsBlocks }

  -- -------------------------------------------------------
  -- string_eq
  -- -------------------------------------------------------
  let strEqBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "a_len_ptr" "a" 1,
      .load "a_len" .i64 (.reg "a_len_ptr"),
      strGep "b_len_ptr" "b" 1,
      .load "b_len" .i64 (.reg "b_len_ptr"),
      .binOp "len_eq" .icmpEq .i64 (.reg "a_len") (.reg "b_len")
    ], .condBr (.reg "len_eq") "cmp_data" "not_eq"⟩,
    ⟨"cmp_data", [
      .binOp "zero_len" .icmpEq .i64 (.reg "a_len") (.intLit 0)
    ], .condBr (.reg "zero_len") "eq" "do_cmp"⟩,
    ⟨"do_cmp", [
      strGep "a_data_ptr" "a" 0,
      .load "a_data" .ptr (.reg "a_data_ptr"),
      strGep "b_data_ptr" "b" 0,
      .load "b_data" .ptr (.reg "b_data_ptr"),
      .call (some "cmp_res") .i32 (.global "memcmp") [(.ptr, .reg "a_data"), (.ptr, .reg "b_data"), (.i64, .reg "a_len")],
      .binOp "eq_data" .icmpEq .i32 (.reg "cmp_res") (.intLit 0)
    ], .condBr (.reg "eq_data") "eq" "not_eq"⟩,
    ⟨"eq", [], .ret .i1 (some (.boolLit true))⟩,
    ⟨"not_eq", [], .ret .i1 (some (.boolLit false))⟩]
  let fnStringEq : LLVMFnDef :=
    { name := "string_eq", retTy := .i1, params := [("a", .ptr), ("b", .ptr)], blocks := strEqBlocks }

  -- -------------------------------------------------------
  -- int_to_string
  -- -------------------------------------------------------
  let intToStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      .call (some "buf") .ptr (.global "malloc") [(.i64, .intLit 32)],
      .gep "fmt_its" (.array 4 .i8) (.global ".fmt_ld") [(.i64, .intLit 0), (.i64, .intLit 0)],
      .callVariadic (some "written") .i32 (.global "snprintf") [(.ptr, .reg "buf"), (.i64, .intLit 32), (.ptr, .reg "fmt_its"), (.i64, .reg "n")] [.ptr, .i64, .ptr],
      .cast "wext" .sext .i32 (.reg "written") .i64,
      .alloca "res.its" strTy,
      strGep "res_d.its" "res.its" 0,
      .store .ptr (.reg "buf") (.reg "res_d.its"),
      strGep "res_l.its" "res.its" 1,
      .store .i64 (.reg "wext") (.reg "res_l.its"),
      strGep "res_c.its" "res.its" 2,
      .store .i64 (.intLit 32) (.reg "res_c.its"),
      .load "result.its" strTy (.reg "res.its")
    ], .ret strTy (some (.reg "result.its"))⟩]
  let fnIntToString : LLVMFnDef :=
    { name := "int_to_string", retTy := strTy, params := [("n", .i64)], blocks := intToStrBlocks }

  -- -------------------------------------------------------
  -- string_to_int
  -- -------------------------------------------------------
  let strToIntBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "sti_data_ptr" "s" 0,
      .load "sti_data" .ptr (.reg "sti_data_ptr"),
      strGep "sti_len_ptr" "s" 1,
      .load "sti_len" .i64 (.reg "sti_len_ptr"),
      .binOp "sti_buf_sz" .add .i64 (.reg "sti_len") (.intLit 1),
      .call (some "sti_buf") .ptr (.global "malloc") [(.i64, .reg "sti_buf_sz")],
      dynMemcpy "sti_buf" "sti_data" "sti_len",
      .gep "sti_null" .i8 (.reg "sti_buf") [(.i64, .reg "sti_len")],
      .store .i8 (.intLit 0) (.reg "sti_null"),
      .alloca "endptr_alloca" .ptr,
      .call (some "sti_val") .i64 (.global "strtol") [(.ptr, .reg "sti_buf"), (.ptr, .reg "endptr_alloca"), (.i32, .intLit 10)],
      .load "endptr" .ptr (.reg "endptr_alloca"),
      .gep "end_expected" .i8 (.reg "sti_buf") [(.i64, .reg "sti_len")],
      .binOp "valid" .icmpEq .ptr (.reg "endptr") (.reg "end_expected"),
      .binOp "empty_input" .icmpEq .i64 (.reg "sti_len") (.intLit 0),
      .binOp "not_empty" .xor_ .i1 (.reg "empty_input") (.boolLit true),
      .binOp "final_ok" .and_ .i1 (.reg "valid") (.reg "not_empty"),
      .call none .void (.global "free") [(.ptr, .reg "sti_buf")],
      .alloca "res.sti" resTy
    ], .condBr (.reg "final_ok") "sti_ok" "sti_err"⟩,
    ⟨"sti_ok", [
      .store .i32 (.intLit 0) (.reg "res.sti"),
      .gep "data_ptr.sti_ok" .i8 (.reg "res.sti") [(.i64, .intLit 8)],
      .store .i64 (.reg "sti_val") (.reg "data_ptr.sti_ok")
    ], .br "sti_done"⟩,
    ⟨"sti_err", [
      .store .i32 (.intLit 1) (.reg "res.sti"),
      .gep "data_ptr.sti_err" .i8 (.reg "res.sti") [(.i64, .intLit 8)],
      .store .i64 (.intLit 1) (.reg "data_ptr.sti_err")
    ], .br "sti_done"⟩,
    ⟨"sti_done", [
      .load "result.sti" resTy (.reg "res.sti")
    ], .ret resTy (some (.reg "result.sti"))⟩]
  let fnStringToInt : LLVMFnDef :=
    { name := "string_to_int", retTy := resTy, params := [("s", .ptr)], blocks := strToIntBlocks }

  -- -------------------------------------------------------
  -- bool_to_string
  -- -------------------------------------------------------
  let boolToStrBlocks : List LLVMBlock := [
    ⟨"entry", [], .condBr (.reg "b") "bts_true" "bts_false"⟩,
    ⟨"bts_true", [
      .call (some "tbuf") .ptr (.global "malloc") [(.i64, .intLit 4)],
      .memcpy (.reg "tbuf") (.global ".str_true") 4,
      .alloca "tres" strTy,
      strGep "td" "tres" 0,
      .store .ptr (.reg "tbuf") (.reg "td"),
      strGep "tl" "tres" 1,
      .store .i64 (.intLit 4) (.reg "tl"),
      strGep "tc" "tres" 2,
      .store .i64 (.intLit 4) (.reg "tc"),
      .load "tresult" strTy (.reg "tres")
    ], .ret strTy (some (.reg "tresult"))⟩,
    ⟨"bts_false", [
      .call (some "fbuf") .ptr (.global "malloc") [(.i64, .intLit 5)],
      .memcpy (.reg "fbuf") (.global ".str_false") 5,
      .alloca "fres" strTy,
      strGep "fd" "fres" 0,
      .store .ptr (.reg "fbuf") (.reg "fd"),
      strGep "fl" "fres" 1,
      .store .i64 (.intLit 5) (.reg "fl"),
      strGep "fc" "fres" 2,
      .store .i64 (.intLit 5) (.reg "fc"),
      .load "fresult" strTy (.reg "fres")
    ], .ret strTy (some (.reg "fresult"))⟩]
  let fnBoolToString : LLVMFnDef :=
    { name := "bool_to_string", retTy := strTy, params := [("b", .i1)], blocks := boolToStrBlocks }

  -- -------------------------------------------------------
  -- float_to_string
  -- -------------------------------------------------------
  let floatToStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      .call (some "fbuf.fts") .ptr (.global "malloc") [(.i64, .intLit 64)],
      .gep "fmt.fts" (.array 3 .i8) (.global ".fmt_f") [(.i64, .intLit 0), (.i64, .intLit 0)],
      .callVariadic (some "written.fts") .i32 (.global "snprintf") [(.ptr, .reg "fbuf.fts"), (.i64, .intLit 64), (.ptr, .reg "fmt.fts"), (.double, .reg "f")] [.ptr, .i64, .ptr],
      .cast "wext.fts" .sext .i32 (.reg "written.fts") .i64,
      .alloca "res.fts" strTy,
      strGep "res_d.fts" "res.fts" 0,
      .store .ptr (.reg "fbuf.fts") (.reg "res_d.fts"),
      strGep "res_l.fts" "res.fts" 1,
      .store .i64 (.reg "wext.fts") (.reg "res_l.fts"),
      strGep "res_c.fts" "res.fts" 2,
      .store .i64 (.intLit 64) (.reg "res_c.fts"),
      .load "result.fts" strTy (.reg "res.fts")
    ], .ret strTy (some (.reg "result.fts"))⟩]
  let fnFloatToString : LLVMFnDef :=
    { name := "float_to_string", retTy := strTy, params := [("f", .double)], blocks := floatToStrBlocks }

  -- -------------------------------------------------------
  -- string_trim
  -- -------------------------------------------------------
  let strTrimBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "st_data_ptr" "s" 0,
      .load "st_data" .ptr (.reg "st_data_ptr"),
      strGep "st_len_ptr" "s" 1,
      .load "st_len" .i64 (.reg "st_len_ptr")
    ], .br "trim_left"⟩,
    ⟨"trim_left", [
      .phi "tl_i" .i64 [(.intLit 0, "entry"), (.reg "tl_next", "tl_ws")],
      .binOp "tl_done" .icmpUge .i64 (.reg "tl_i") (.reg "st_len")
    ], .condBr (.reg "tl_done") "trim_result" "tl_check"⟩,
    ⟨"tl_check", [
      .gep "tl_ptr" .i8 (.reg "st_data") [(.i64, .reg "tl_i")],
      .load "tl_ch" .i8 (.reg "tl_ptr"),
      .binOp "tl_is_sp" .icmpEq .i8 (.reg "tl_ch") (.intLit 32),
      .binOp "tl_is_tab" .icmpEq .i8 (.reg "tl_ch") (.intLit 9),
      .binOp "tl_is_nl" .icmpEq .i8 (.reg "tl_ch") (.intLit 10),
      .binOp "tl_is_cr" .icmpEq .i8 (.reg "tl_ch") (.intLit 13),
      .binOp "tl_w1" .or_ .i1 (.reg "tl_is_sp") (.reg "tl_is_tab"),
      .binOp "tl_w2" .or_ .i1 (.reg "tl_is_nl") (.reg "tl_is_cr"),
      .binOp "tl_is_ws" .or_ .i1 (.reg "tl_w1") (.reg "tl_w2")
    ], .condBr (.reg "tl_is_ws") "tl_ws" "trim_right_init"⟩,
    ⟨"tl_ws", [
      .binOp "tl_next" .add .i64 (.reg "tl_i") (.intLit 1)
    ], .br "trim_left"⟩,
    ⟨"trim_right_init", [
      .binOp "tr_start" .sub .i64 (.reg "st_len") (.intLit 1)
    ], .br "trim_right"⟩,
    ⟨"trim_right", [
      .phi "tr_i" .i64 [(.reg "tr_start", "trim_right_init"), (.reg "tr_prev", "tr_ws")],
      .binOp "tr_done" .icmpUlt .i64 (.reg "tr_i") (.reg "tl_i")
    ], .condBr (.reg "tr_done") "trim_result" "tr_check"⟩,
    ⟨"tr_check", [
      .gep "tr_ptr" .i8 (.reg "st_data") [(.i64, .reg "tr_i")],
      .load "tr_ch" .i8 (.reg "tr_ptr"),
      .binOp "tr_is_sp" .icmpEq .i8 (.reg "tr_ch") (.intLit 32),
      .binOp "tr_is_tab" .icmpEq .i8 (.reg "tr_ch") (.intLit 9),
      .binOp "tr_is_nl" .icmpEq .i8 (.reg "tr_ch") (.intLit 10),
      .binOp "tr_is_cr" .icmpEq .i8 (.reg "tr_ch") (.intLit 13),
      .binOp "tr_w1" .or_ .i1 (.reg "tr_is_sp") (.reg "tr_is_tab"),
      .binOp "tr_w2" .or_ .i1 (.reg "tr_is_nl") (.reg "tr_is_cr"),
      .binOp "tr_is_ws" .or_ .i1 (.reg "tr_w1") (.reg "tr_w2")
    ], .condBr (.reg "tr_is_ws") "tr_ws" "trim_result"⟩,
    ⟨"tr_ws", [
      .binOp "tr_prev" .sub .i64 (.reg "tr_i") (.intLit 1)
    ], .br "trim_right"⟩,
    ⟨"trim_result", [
      .phi "tr_left" .i64 [(.reg "tl_i", "trim_left"), (.reg "tl_i", "trim_right"), (.reg "tl_i", "tr_check")],
      .phi "tr_right_raw" .i64 [(.intLit 0, "trim_left"), (.reg "tl_i", "trim_right"), (.reg "tr_i", "tr_check")],
      .binOp "tr_right" .add .i64 (.reg "tr_right_raw") (.intLit 1),
      .binOp "tr_empty" .icmpUge .i64 (.reg "tr_left") (.reg "tr_right")
    ], .condBr (.reg "tr_empty") "trim_empty" "trim_copy"⟩,
    ⟨"trim_empty", [
      .call (some "te_buf") .ptr (.global "malloc") [(.i64, .intLit 1)],
      .alloca "te_res" strTy,
      strGep "te_d" "te_res" 0,
      .store .ptr (.reg "te_buf") (.reg "te_d"),
      strGep "te_l" "te_res" 1,
      .store .i64 (.intLit 0) (.reg "te_l"),
      strGep "te_c" "te_res" 2,
      .store .i64 (.intLit 1) (.reg "te_c"),
      .load "te_result" strTy (.reg "te_res")
    ], .ret strTy (some (.reg "te_result"))⟩,
    ⟨"trim_copy", [
      .binOp "tc_len" .sub .i64 (.reg "tr_right") (.reg "tr_left"),
      .call (some "tc_buf") .ptr (.global "malloc") [(.i64, .reg "tc_len")],
      .gep "tc_src" .i8 (.reg "st_data") [(.i64, .reg "tr_left")],
      dynMemcpy "tc_buf" "tc_src" "tc_len",
      .alloca "tc_res" strTy,
      strGep "tc_d" "tc_res" 0,
      .store .ptr (.reg "tc_buf") (.reg "tc_d"),
      strGep "tc_l" "tc_res" 1,
      .store .i64 (.reg "tc_len") (.reg "tc_l"),
      strGep "tc_c" "tc_res" 2,
      .store .i64 (.reg "tc_len") (.reg "tc_c"),
      .load "tc_result" strTy (.reg "tc_res")
    ], .ret strTy (some (.reg "tc_result"))⟩]
  let fnStringTrim : LLVMFnDef :=
    { name := "string_trim", retTy := strTy, params := [("s", .ptr)], blocks := strTrimBlocks }

  -- -------------------------------------------------------
  -- Globals
  -- -------------------------------------------------------
  let globals : List LLVMGlobal := [
    { name := ".fmt_ld", ty := .array 4 .i8, value := "c\"%ld\\00\"" },
    { name := ".str_true", ty := .array 4 .i8, value := "c\"true\"" },
    { name := ".str_false", ty := .array 5 .i8, value := "c\"false\"" },
    { name := ".fmt_f", ty := .array 3 .i8, value := "c\"%g\\00\"" }
  ]

  -- -------------------------------------------------------
  -- Declarations
  -- Note: memcmp, strtol, snprintf are already declared in emitExternDecls,
  -- so we only add the intrinsics that are not declared there.
  -- -------------------------------------------------------
  let decls : List LLVMFnDecl := [
    { name := "llvm.smax.i64", retTy := .i64, params := [.i64, .i64] },
    { name := "llvm.smin.i64", retTy := .i64, params := [.i64, .i64] }
  ]

  let fns : List LLVMFnDef := [
    fnStringLength, fnDropString, fnStringConcat, fnStringSlice, fnStringCharAt,
    fnStringContains, fnStringEq, fnIntToString, fnStringToInt, fnBoolToString,
    fnFloatToString, fnStringTrim
  ]
  (fns, globals, decls)

/-- Generate standalone Vec builtin function definitions for the SSA path.
    Size-independent ops (vec_len, vec_free) are emitted once.
    Size-dependent ops (vec_new, vec_push, vec_get, vec_set) are emitted per
    distinct element size. vec_pop is emitted per (size, payloadOffset) pair
    because the Option enum payload offset depends on element alignment.
    All per-size ops use ptr-based value passing with memcpy for correctness.
    Note: GEPs omit `inbounds` — semantically identical, slightly less optimizable. -/
private def getVecBuiltinFns (specs : List (Nat × Nat)) : List LLVMFnDef :=
  let vecTy := LLVMTy.struct_ "Vec"
  let optTy := LLVMTy.enum_ "Option"
  let ic : Int := 8   -- initial capacity
  -- Helper: getelementptr %struct.Vec, ptr %base, i32 0, i32 N
  let vecGep (dst base : String) (fieldIdx : Int) : LLVMInstr :=
    .gep dst vecTy (.reg base) [(.i32, .intLit 0), (.i32, .intLit fieldIdx)]
  -- -------------------------------------------------------
  -- Size-independent: vec_len
  -- -------------------------------------------------------
  let vecLen : LLVMFnDef := { name := "vec_len", retTy := .i64, params := [("vec", .ptr)], blocks := [
    ⟨"entry", [
      vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp")
    ], .ret .i64 (some (.reg "len"))⟩] }
  -- -------------------------------------------------------
  -- Size-independent: vec_free
  -- -------------------------------------------------------
  let vecFree : LLVMFnDef := { name := "vec_free", retTy := .void, params := [("vec", .ptr)], blocks := [
    ⟨"entry", [
      vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
      .call none .void (.global "free") [(.ptr, .reg "data")]
    ], .ret .void none⟩] }
  -- -------------------------------------------------------
  -- Deduplicate sizes for push/get/set/new (only need elem size)
  -- -------------------------------------------------------
  let uniqueSizes := specs.foldl (fun (acc : List Nat) (sz, _) =>
    if acc.contains sz then acc else acc ++ [sz]) []
  -- -------------------------------------------------------
  -- Per-size: vec_new_{es}, vec_push_{es}, vec_get_{es}, vec_set_{es}
  -- All use ptr-based value passing with memcpy.
  -- -------------------------------------------------------
  let sizedFns := uniqueSizes.foldl (fun (acc : List LLVMFnDef) (esNat : Nat) =>
    let es : Int := esNat
    let ib : Int := ic * es
    let newName := s!"vec_new_{esNat}"
    let pushName := s!"vec_push_{esNat}"
    let getName := s!"vec_get_{esNat}"
    let setName := s!"vec_set_{esNat}"
    -- vec_new_{es}() -> %struct.Vec
    let vecNewBlocks : List LLVMBlock := [
      ⟨"entry", [
        .call (some "buf") .ptr (.global "malloc") [(.i64, .intLit ib)],
        .alloca "v" vecTy,
        vecGep "bp" "v" 0, .store .ptr (.reg "buf") (.reg "bp"),
        vecGep "lp" "v" 1, .store .i64 (.intLit 0) (.reg "lp"),
        vecGep "cp" "v" 2, .store .i64 (.intLit ic) (.reg "cp"),
        .load "r" vecTy (.reg "v")
      ], .ret vecTy (some (.reg "r"))⟩]
    let vecNew : LLVMFnDef := { name := newName, retTy := vecTy, params := [], blocks := vecNewBlocks }
    -- vec_push_{es}(vec: ptr, val: ptr) -> void
    let vecPushBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp"),
        vecGep "cp" "vec" 2, .load "cap" .i64 (.reg "cp"),
        .binOp "full" .icmpEq .i64 (.reg "len") (.reg "cap")
      ], .condBr (.reg "full") "grow" "store"⟩,
      ⟨"grow", [
        .binOp "newcap" .mul .i64 (.reg "cap") (.intLit 2),
        .binOp "newbytes" .mul .i64 (.reg "newcap") (.intLit es),
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .call (some "newbuf") .ptr (.global "realloc") [(.ptr, .reg "data"), (.i64, .reg "newbytes")],
        .store .ptr (.reg "newbuf") (.reg "dp"),
        .store .i64 (.reg "newcap") (.reg "cp")
      ], .br "store"⟩,
      ⟨"store", [
        vecGep "dp2" "vec" 0, .load "data2" .ptr (.reg "dp2"),
        .binOp "offset" .mul .i64 (.reg "len") (.intLit es),
        .gep "slot" .i8 (.reg "data2") [(.i64, .reg "offset")],
        .memcpy (.reg "slot") (.reg "val") esNat,
        .binOp "newlen" .add .i64 (.reg "len") (.intLit 1),
        .store .i64 (.reg "newlen") (.reg "lp")
      ], .ret .void none⟩]
    let vecPush : LLVMFnDef := { name := pushName, retTy := .void, params := [("vec", .ptr), ("val", .ptr)], blocks := vecPushBlocks }
    -- vec_get_{es}(vec: ptr, idx: i64) -> ptr
    let vecGetBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "idx") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")]
      ], .ret .ptr (some (.reg "slot"))⟩]
    let vecGet : LLVMFnDef := { name := getName, retTy := .ptr, params := [("vec", .ptr), ("idx", .i64)], blocks := vecGetBlocks }
    -- vec_set_{es}(vec: ptr, idx: i64, val: ptr) -> void
    let vecSetBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "idx") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")],
        .memcpy (.reg "slot") (.reg "val") esNat
      ], .ret .void none⟩]
    let vecSet : LLVMFnDef := { name := setName, retTy := .void, params := [("vec", .ptr), ("idx", .i64), ("val", .ptr)], blocks := vecSetBlocks }
    acc ++ [vecNew, vecPush, vecGet, vecSet]
  ) ([] : List LLVMFnDef)
  -- -------------------------------------------------------
  -- Per-spec: vec_pop_{es}_{payOff} (needs both size and payload offset)
  -- Uses memcpy for buffer read and correct Option payload placement.
  -- -------------------------------------------------------
  let popFns := specs.foldl (fun (acc : List LLVMFnDef) ((esNat, payOff) : Nat × Nat) =>
    let es : Int := esNat
    let popName := s!"vec_pop_{esNat}_{payOff}"
    let vecPopBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp"),
        .binOp "empty" .icmpEq .i64 (.reg "len") (.intLit 0)
      ], .condBr (.reg "empty") "none" "some"⟩,
      ⟨"some", [
        .binOp "newlen" .sub .i64 (.reg "len") (.intLit 1),
        .store .i64 (.reg "newlen") (.reg "lp"),
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "newlen") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")],
        -- Zero-initialize the Option, then copy element into payload
        .alloca "res" optTy,
        .call none .void (.global "memset") [(.ptr, .reg "res"), (.i32, .intLit 0), (.i64, .intLit (Layout.alignUp (payOff + esNat) (Nat.max 4 (Nat.min esNat 8))))],
        .store .i32 (.intLit 0) (.reg "res"),
        .gep "payload" .i8 (.reg "res") [(.i64, .intLit payOff)],
        .memcpy (.reg "payload") (.reg "slot") esNat,
        .load "r" optTy (.reg "res")
      ], .ret optTy (some (.reg "r"))⟩,
      ⟨"none", [
        .alloca "res2" optTy,
        .call none .void (.global "memset") [(.ptr, .reg "res2"), (.i32, .intLit 0), (.i64, .intLit (Layout.alignUp (payOff + esNat) (Nat.max 4 (Nat.min esNat 8))))],
        .store .i32 (.intLit 1) (.reg "res2"),
        .load "r2" optTy (.reg "res2")
      ], .ret optTy (some (.reg "r2"))⟩]
    let vecPop : LLVMFnDef := { name := popName, retTy := optTy, params := [("vec", .ptr)], blocks := vecPopBlocks }
    acc ++ [vecPop]
  ) ([] : List LLVMFnDef)
  [vecLen, vecFree] ++ sizedFns ++ popFns

/-- Emit builtin implementations needed by the program. -/
private def emitBuiltins (s : EmitSSAState) : EmitSSAState :=
  let (builtinFns, builtinGlobals, builtinDecls) := getBuiltinFns
  let vecFns := getVecBuiltinFns s.vecElemSpecs
  let allFns := builtinFns ++ vecFns
  { s with
    moduleFunctions := s.moduleFunctions ++ allFns.toArray,
    moduleGlobals := s.moduleGlobals ++ builtinGlobals.toArray,
    moduleDeclarations := s.moduleDeclarations ++ builtinDecls.toArray }

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
  let printfOp : LLVMOperand := .global "printf"
  let gep32 (dst : String) (arrTy : LLVMTy) (base : LLVMOperand) : LLVMInstr :=
    .gep dst arrTy base [(.i32, .intLit 0), (.i32, .intLit 0)]
  if testFns.isEmpty then
    -- No tests found: emit a main that prints a message and returns 0
    let s := emitGlobal s { name := "fmt.test.none", ty := .array 15 .i8, value := "c\"No tests found\\00\"" }
    let s := emitGlobal s { name := "fmt.test.nl", ty := .array 2 .i8, value := "c\"\\0A\\00\"" }
    let instrs : List LLVMInstr := [
      gep32 "fmt" (.array 15 .i8) (.global "fmt.test.none"),
      .callVariadic none .i32 printfOp [(.ptr, .reg "fmt")],
      gep32 "nl" (.array 2 .i8) (.global "fmt.test.nl"),
      .callVariadic none .i32 printfOp [(.ptr, .reg "nl")]
    ]
    let blk : LLVMBlock := ⟨"entry", instrs, .ret .i32 (some (.intLit 0))⟩
    let mainFn : LLVMFnDef := { name := "main", retTy := .i32, params := [], blocks := [blk] }
    { s with moduleFunctions := s.moduleFunctions.push mainFn }
  else
    -- Emit globals for test name strings
    let s := testFns.foldl (fun s f =>
      let nameLen := f.name.length + 1
      let escaped := ssaEscapeStringForLLVM f.name
      emitGlobal s { name := s!"test.name.{f.name}", ty := .array nameLen .i8, value := s!"c\"{escaped}\\00\"" }
    ) s
    -- Emit format string globals
    let s := emitGlobal s { name := "fmt.test.pass", ty := .array 10 .i8, value := "c\"PASS: %s\\0A\\00\"" }
    let s := emitGlobal s { name := "fmt.test.fail", ty := .array 10 .i8, value := "c\"FAIL: %s\\0A\\00\"" }
    -- Helper: build test dispatch instructions for a given test at index i
    let mkTestDispatch (f : SFnDef) (i : String) : List LLVMInstr :=
      let nameLen := f.name.length + 1
      [ .comment s!"Test: {f.name}",
        .call (some s!"result.{i}") .i32 (.global f.name) [],
        .binOp s!"is_pass.{i}" .icmpEq .i32 (.reg s!"result.{i}") (.intLit 0),
        gep32 s!"name.{i}" (.array nameLen .i8) (.global s!"test.name.{f.name}") ]
    -- Build all blocks via fold over (remaining tests, index, accumulated blocks)
    -- Entry block gets alloca + store + first test dispatch
    let (blocks, _, _) := testFns.foldl (fun (acc, idx, rest) _f =>
      let i := toString idx
      -- pass.i: print PASS, branch to next.i
      let passInstrs : List LLVMInstr := [
        gep32 s!"pfmt.{i}" (.array 10 .i8) (.global "fmt.test.pass"),
        .callVariadic none .i32 printfOp [(.ptr, .reg s!"pfmt.{i}"), (.ptr, .reg s!"name.{i}")]
      ]
      let passBlock : LLVMBlock := ⟨s!"pass.{i}", passInstrs, .br s!"next.{i}"⟩
      -- fail.i: print FAIL, increment failures, branch to next.i
      let failInstrs : List LLVMInstr := [
        gep32 s!"ffmt.{i}" (.array 10 .i8) (.global "fmt.test.fail"),
        .callVariadic none .i32 printfOp [(.ptr, .reg s!"ffmt.{i}"), (.ptr, .reg s!"name.{i}")],
        .load s!"old_fail.{i}" .i32 (.reg "failures"),
        .binOp s!"new_fail.{i}" .add .i32 (.reg s!"old_fail.{i}") (.intLit 1),
        .store .i32 (.reg s!"new_fail.{i}") (.reg "failures")
      ]
      let failBlock : LLVMBlock := ⟨s!"fail.{i}", failInstrs, .br s!"next.{i}"⟩
      -- next.i: dispatch next test, or return exit code if last
      let tail := rest.drop 1
      let nextBlock : LLVMBlock := match tail with
        | nextF :: _ =>
          let nextI := toString (idx + 1)
          ⟨s!"next.{i}", mkTestDispatch nextF nextI,
           .condBr (.reg s!"is_pass.{nextI}") s!"pass.{nextI}" s!"fail.{nextI}"⟩
        | [] =>
          let footerInstrs : List LLVMInstr := [
            .load "total_fail" .i32 (.reg "failures"),
            .binOp "any_fail" .icmpSgt .i32 (.reg "total_fail") (.intLit 0),
            .select "exit" (.reg "any_fail") .i32 (.intLit 1) (.intLit 0)
          ]
          ⟨s!"next.{i}", footerInstrs, .ret .i32 (some (.reg "exit"))⟩
      (acc ++ [passBlock, failBlock, nextBlock], idx + 1, tail)
    ) ([], 0, testFns)
    -- Entry block: alloca failures + first test dispatch
    let entryBlock : LLVMBlock := match testFns with
      | f0 :: _ =>
        let entryInstrs : List LLVMInstr :=
          [.alloca "failures" .i32, .store .i32 (.intLit 0) (.reg "failures")]
          ++ mkTestDispatch f0 "0"
        ⟨"entry", entryInstrs, .condBr (.reg "is_pass.0") "pass.0" "fail.0"⟩
      | [] => ⟨"entry", [], .ret .i32 (some (.intLit 0))⟩  -- unreachable
    let allBlocks := [entryBlock] ++ blocks
    let mainFn : LLVMFnDef := { name := "main", retTy := .i32, params := [], blocks := allBlocks }
    { s with moduleFunctions := s.moduleFunctions.push mainFn }

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
  }
  printLLVMModule llvmModule

end Concrete
