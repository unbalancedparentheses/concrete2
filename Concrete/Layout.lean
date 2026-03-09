import Concrete.Core

namespace Concrete
namespace Layout

/-! ## Layout — unified type layout and ABI helpers

Single source of truth for type sizes, field offsets, pass-by-pointer decisions,
and Ty→LLVM type mappings. Used by both Lower.lean and EmitSSA.lean.
-/

-- ============================================================
-- Layout context
-- ============================================================

structure Ctx where
  structDefs : List CStructDef
  enumDefs   : List CEnumDef

def lookupStruct (ctx : Ctx) (name : String) : Option CStructDef :=
  ctx.structDefs.find? fun sd => sd.name == name

def lookupEnum (ctx : Ctx) (name : String) : Option CEnumDef :=
  ctx.enumDefs.find? fun ed => ed.name == name

-- ============================================================
-- Type size (bytes)
-- ============================================================

/-- Natural alignment of a type in bytes. -/
partial def tyAlign (ctx : Ctx) : Ty → Nat
  | .int | .uint | .float64 => 8
  | .i32 | .u32 | .float32 => 4
  | .i16 | .u16 => 2
  | .i8 | .u8 | .char | .bool => 1
  | .unit => 1
  | .string => 8  -- contains ptr and i64, both align 8
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => 8
  | .fn_ _ _ _ | .heap _ | .heapArray _ => 8
  | .generic "Heap" _ | .generic "HeapArray" _ => 8
  | .generic "Vec" _ => 8
  | .generic "HashMap" _ => 8
  | .named name | .generic name _ =>
    match lookupStruct ctx name with
    | some sd =>
      if sd.isPacked then 1
      else
        let natural := sd.fields.foldl (fun maxA (_, ft) => Nat.max maxA (tyAlign ctx ft)) 1
        match sd.reprAlign with
        | some a => Nat.max natural a
        | none => natural
    | none =>
      match lookupEnum ctx name with
      | some ed => Nat.max 4 (ed.variants.foldl (fun maxA (_, vfields) =>
          vfields.foldl (fun a (_, ft) => Nat.max a (tyAlign ctx ft)) maxA) 1)
      | none => 8
  | .array elem _ => tyAlign ctx elem
  | .never | .placeholder => 1
  | .typeVar _ => 8

/-- Round `n` up to the next multiple of `align`. -/
def alignUp (n : Nat) (align : Nat) : Nat :=
  if align <= 1 then n
  else ((n + align - 1) / align) * align

/-- Byte size of a type. Used for malloc/alloca sizing and enum layout. -/
partial def tySize (ctx : Ctx) : Ty → Nat
  | .int | .uint | .float64 => 8
  | .i32 | .u32 | .float32 => 4
  | .i16 | .u16 => 2
  | .i8 | .u8 | .char | .bool => 1
  | .unit => 0
  | .string => 16  -- ptr + i64
  | .ref _ | .refMut _ | .ptrMut _ | .ptrConst _ => 8
  | .fn_ _ _ _ | .heap _ | .heapArray _ => 8
  | .generic "Heap" _ | .generic "HeapArray" _ => 8
  | .generic "Vec" _ => 24
  | .generic "HashMap" _ => 40
  | .named name | .generic name _ =>
    match lookupStruct ctx name with
    | some sd =>
      if sd.isPacked then
        -- Packed: no padding between fields, alignment = 1
        sd.fields.foldl (fun acc (_, ft) => acc + tySize ctx ft) 0
      else
        let (sz, _) := sd.fields.foldl (fun (acc, _) (_, ft) =>
          let aligned := alignUp acc (tyAlign ctx ft)
          (aligned + tySize ctx ft, ())) (0, ())
        let structAlign := match sd.reprAlign with
          | some a => Nat.max (sd.fields.foldl (fun maxA (_, ft) => Nat.max maxA (tyAlign ctx ft)) 1) a
          | none => sd.fields.foldl (fun maxA (_, ft) => Nat.max maxA (tyAlign ctx ft)) 1
        alignUp sz structAlign
    | none =>
      match lookupEnum ctx name with
      | some ed =>
        let maxPayload := ed.variants.foldl (fun maxSz (_, vfields) =>
          let sz := vfields.foldl (fun (acc, _) (_, ft) =>
            let aligned := alignUp acc (tyAlign ctx ft)
            (aligned + tySize ctx ft, ())) (0, ())
          Nat.max maxSz sz.1) 0
        let payloadAlign := ed.variants.foldl (fun maxA (_, vfields) =>
          vfields.foldl (fun a (_, ft) => Nat.max a (tyAlign ctx ft)) maxA) 1
        let payloadStart := alignUp 4 payloadAlign
        alignUp (payloadStart + maxPayload) (Nat.max 4 payloadAlign)
      | none => 8
  | .array elem n => tySize ctx elem * n
  | .never | .placeholder => 0
  | .typeVar _ => 8

/-- Byte offset of a field within a struct. -/
def fieldOffset (ctx : Ctx) (structName fieldName : String) : Nat :=
  match lookupStruct ctx structName with
  | some sd =>
    if sd.isPacked then
      -- Packed: no alignment padding
      let (offset, _) := sd.fields.foldl (fun (acc : Nat × Bool) (n, t) =>
        let (off, found) := acc
        if found then (off, true)
        else if n == fieldName then (off, true)
        else (off + tySize ctx t, false)) (0, false)
      offset
    else
      let (offset, _) := sd.fields.foldl (fun (acc : Nat × Bool) (n, t) =>
        let (off, found) := acc
        if found then (off, true)
        else
          let aligned := alignUp off (tyAlign ctx t)
          if n == fieldName then (aligned, true)
          else (aligned + tySize ctx t, false)) (0, false)
      offset
  | none => 0

/-- Maximum payload size across all variants of an enum. -/
def enumPayloadSize (ctx : Ctx) (ed : CEnumDef) : Nat :=
  ed.variants.foldl (fun maxSz (_, vfields) =>
    let sz := vfields.foldl (fun (acc, _) (_, ft) =>
      let aligned := alignUp acc (tyAlign ctx ft)
      (aligned + tySize ctx ft, ())) (0, ())
    Nat.max maxSz sz.1) 0

/-- Byte offset from start of enum to payload (after i32 tag, aligned). -/
def enumPayloadOffset (ctx : Ctx) (ed : CEnumDef) : Nat :=
  let payloadAlign := ed.variants.foldl (fun maxA (_, vfields) =>
    vfields.foldl (fun a (_, ft) => Nat.max a (tyAlign ctx ft)) maxA) 1
  alignUp 4 payloadAlign

/-- Byte offset of a field within a variant's payload (aligned). -/
def variantFieldOffset (ctx : Ctx) (fields : List (String × Ty)) (idx : Nat) : Nat :=
  let (off, _, _) := fields.foldl (fun (acc, i, done) (_, ft) =>
    if done then (acc, i + 1, true)
    else
      let aligned := alignUp acc (tyAlign ctx ft)
      if i == idx then (aligned, i + 1, true)
      else (aligned + tySize ctx ft, i + 1, false)) (0, 0, false)
  off

-- ============================================================
-- Pass-by-pointer ABI
-- ============================================================

/-- Is this type passed by pointer in function calls? -/
def isPassByPtr (ctx : Ctx) (ty : Ty) : Bool :=
  match ty with
  | .string => true
  | .ref _ | .refMut _ => true
  | .array _ _ => true
  | .fn_ _ _ _ | .heap _ | .heapArray _ => false
  | .named name => (lookupStruct ctx name).isSome || (lookupEnum ctx name).isSome
  | .generic "Vec" _ | .generic "HashMap" _ => true
  | .generic name _ => (lookupStruct ctx name).isSome || (lookupEnum ctx name).isSome
  | _ => false

-- ============================================================
-- Ty → LLVM type string
-- ============================================================

/-- Map a Concrete type to its LLVM IR type string. -/
def tyToLLVM (ctx : Ctx) : Ty → String
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
    match lookupEnum ctx name with
    | some _ => "%enum." ++ name
    | none => "%struct." ++ name
  | .typeVar _ => "i64"
  | .array elem n => "[" ++ toString n ++ " x " ++ tyToLLVM ctx elem ++ "]"
  | .fn_ _ _ _ => "ptr"
  | .never => "void"
  | .placeholder => "i64"
  | .named name =>
    match lookupStruct ctx name with
    | some _ => "%struct." ++ name
    | none =>
      match lookupEnum ctx name with
      | some _ => "%enum." ++ name
      | none => "i64"

/-- LLVM type for function parameters (pass-by-ptr types become ptr). -/
def paramTyToLLVM (ctx : Ctx) (ty : Ty) : String :=
  if isPassByPtr ctx ty then "ptr"
  else tyToLLVM ctx ty

end Layout
end Concrete
