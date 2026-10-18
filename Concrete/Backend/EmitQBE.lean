import Concrete.IR.SSA

/-!
Experimental Concrete consumer of standard QBE IL. The backend is a separate,
general-purpose project: https://github.com/unbalancedparentheses/lean-compiler-backend.
Only the explicitly supported semantics are admitted. In particular, Concrete's
ordinary arithmetic is checked; it must never silently become wrapping QBE code.
This is an integration experiment, not a semantic-preservation theorem.
-/
namespace Concrete.EmitQBE

private def encode (name : String) : String :=
  "n" ++ String.intercalate "_" (name.toList.map (fun c => toString c.toNat))

private def width : Ty → Except String String
  | .int | .uint => .ok "l"
  | .i32 | .u32 | .bool => .ok "w"
  | _ => .error "experimental QBE adapter supports only Int/Uint, i32/u32 and Bool; narrow integers, memory and floating point are not supported"

private def signed : Ty → Bool
  | .int | .i32 => true
  | _ => false

private def operand (value : SVal) : Except String String := do
  discard (width value.ty)
  match value with
  | .reg name _ => pure ("%" ++ encode name)
  | .intConst n _ =>
    if n < -(2 ^ 63 : Int) || n > (2 ^ 64 : Int) - 1 then
      throw "integer literal exceeds the QBE adapter's 64-bit domain"
    pure (toString n)
  | .boolConst value => pure (if value then "1" else "0")
  | _ => throw "unsupported QBE operand: runtime values, strings and function pointers are not admitted"

private def binaryName (op : BinOp) (ty : Ty) : Except String (String × Bool) := do
  let suffix ← width ty
  match op with
  | .wrappingAdd => pure ("add", false)
  | .wrappingSub => pure ("sub", false)
  | .wrappingMul => pure ("mul", false)
  | .bitand | .and_ => pure ("and", false)
  | .bitor | .or_ => pure ("or", false)
  | .bitxor => pure ("xor", false)
  | .eq => pure ("ceq" ++ suffix, true)
  | .neq => pure ("cne" ++ suffix, true)
  | .lt => pure ((if signed ty then "cslt" else "cult") ++ suffix, true)
  | .gt => pure ((if signed ty then "csgt" else "cugt") ++ suffix, true)
  | .leq => pure ((if signed ty then "csle" else "cule") ++ suffix, true)
  | .geq => pure ((if signed ty then "csge" else "cuge") ++ suffix, true)
  | _ => throw "checked/saturating arithmetic and shifts are not supported by the experimental QBE adapter; explicit wrapping_add/wrapping_sub/wrapping_mul are supported"

private def instruction : SInst → Except String String
  | .binOp destination op lhs rhs ty => do
    let operandWidth ← width lhs.ty
    if (← width rhs.ty) != operandWidth then throw "mixed-width QBE binary operands are not supported"
    let (name, comparison) ← binaryName op lhs.ty
    let resultWidth ← if comparison then pure "w" else width ty
    pure s!"    %{encode destination} ={resultWidth} {name} {← operand lhs}, {← operand rhs}"
  | .unaryOp destination op value ty => do
    let resultWidth ← width ty
    let rhs ← operand value
    match op with
    | .not_ => pure s!"    %{encode destination} =w xor {rhs}, 1"
    | .bitnot => pure s!"    %{encode destination} ={resultWidth} xor {rhs}, -1"
    | .neg => throw "checked negation is not supported by the experimental QBE adapter"
  | .phi destination incoming ty => do
    let resultWidth ← width ty
    let values ← incoming.mapM fun (value, label) => do
      pure s!"@{encode label} {← operand value}"
    pure s!"    %{encode destination} ={resultWidth} phi {String.intercalate ", " values}"
  | .cast destination value ty => do
    let targetWidth ← width ty
    let sourceWidth ← width value.ty
    if ty == .bool || value.ty == .bool then
      throw "casts to/from Bool are outside the experimental QBE adapter's domain"
    let name := if sourceWidth == targetWidth || targetWidth == "w" then "copy"
      else if signed value.ty then "extsw" else "extuw"
    pure s!"    %{encode destination} ={targetWidth} {name} {← operand value}"
  | .call .. => .error "function/runtime calls are not supported by the experimental QBE adapter"
  | _ => .error "memory, allocation and address operations are not supported by the experimental QBE adapter"

private def terminator : STerm → Except String String
  | .ret (some value) => do pure s!"    ret {← operand value}"
  | .ret none => .error "Unit-returning functions are not supported by the experimental QBE adapter"
  | .br label => .ok s!"    jmp @{encode label}"
  | .condBr condition yes no => do
    if condition.ty != .bool then throw "QBE adapter requires Boolean branch conditions"
    pure s!"    jnz {← operand condition}, @{encode yes}, @{encode no}"
  | .unreachable => .ok "    hlt"

private def block (value : SBlock) : Except String String := do
  if !value.params.isEmpty then throw "block parameters must be lowered to phi nodes before QBE emission"
  let instructions ← value.insts.mapM instruction
  let last ← terminator value.term
  pure (String.intercalate "\n" (["@" ++ encode value.label] ++ instructions ++ [last]))

def functionSymbol (f : SFnDef) : String :=
  if f.isEntryPoint then "concrete_lcb_entry"
  else s!"concrete_lcb_fn_{f.modulePath.length}_{encode f.modulePath}_{encode f.name}"

private def function (f : SFnDef) : Except String String := do
  let resultWidth ← width f.retTy
  if f.isEntryPoint && (!f.params.isEmpty || resultWidth != "l") then
    throw "experimental native entry point must take no parameters and return Int/Uint"
  let parameters ← f.params.mapM fun (name, ty) => do pure s!"{← width ty} %{encode name}"
  let blocks ← f.blocks.mapM block
  pure ("export function " ++ resultWidth ++ " $" ++ functionSymbol f ++ "("
    ++ String.intercalate ", " parameters ++ ") {\n" ++ String.intercalate "\n" blocks ++ "\n}\n")

def emit (modules : List SModule) : Except String String := do
  let mut result := "# Concrete experimental QBE adapter; semantics restricted explicitly\n"
  let mut symbols : List String := []
  for m in modules do
    if !m.globals.isEmpty || !m.externFns.isEmpty then
      throw "global data and extern declarations are not supported by the experimental QBE adapter"
    for f in m.functions do
      let symbol := functionSymbol f
      if symbols.contains symbol then throw "duplicate function symbol in experimental QBE adapter"
      symbols := symbol :: symbols
      let text ← function f
      result := result ++ text
  if symbols.isEmpty then throw "no functions to emit in experimental QBE adapter"
  pure result

end Concrete.EmitQBE
