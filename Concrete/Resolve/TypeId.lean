import Concrete.Frontend.AST

/-! # Semantic identity for type declarations (R-0004 V2 input)

`TypeId` names the declaration a type reference resolved to. It is separate
from the spelling visible at the use site: an import alias does not create a
new type, and two same-spelled declarations in different modules are different
types.

This module deliberately does not reuse `CallableId`. Types and callables have
different identity domains, and sharing their representation would make a
same-spelled type and function interchangeable. Compiler-provided enums also
have a typed builtin namespace because they have no defining source module.

Rendered forms are for evidence bytes and diagnostics only. Resolution and
equality use the typed values directly; there is no inverse parser.
-/

namespace Concrete

/-- Identity of a type declaration. Invalid user/builtin field combinations
    are unrepresentable. -/
inductive TypeId where
  | user (defModule declName : String)
  | builtin (id : BuiltinEnumId)
deriving BEq, Repr

namespace TypeId

def ofUser (defModule declName : String) : TypeId := .user defModule declName

/-- Only a compiler-owned `BuiltinEnumId` can mint a builtin type identity. -/
def ofBuiltin (id : BuiltinEnumId) : TypeId := .builtin id

private def builtinCanonical : BuiltinEnumId → String
  | .option => "option"
  | .result => "result"

private def lp (tag payload : String) : String :=
  tag ++ ":" ++ toString payload.length ++ ":" ++ payload

/-- Versioned, injective serialization for evidence bytes and diagnostics. -/
def render : TypeId → String
  | .user defModule declName =>
      "v1:type:user:" ++ lp "module" defModule ++ lp "decl" declName
  | .builtin id =>
      "v1:type:builtin:" ++ builtinCanonical id

end TypeId

/-- A field is identified relative to the declaration that owns it. -/
structure FieldId where
  owner : TypeId
  field : String
deriving BEq, Repr

def FieldId.render (f : FieldId) : String :=
  "v1:field:owner:" ++ toString f.owner.render.length ++ ":" ++ f.owner.render
    ++ "name:" ++ toString f.field.length ++ ":" ++ f.field

/-- An enum variant is identified relative to the declaration that owns it. -/
structure VariantId where
  owner   : TypeId
  variant : String
deriving BEq, Repr

def VariantId.render (v : VariantId) : String :=
  "v1:variant:owner:" ++ toString v.owner.render.length ++ ":" ++ v.owner.render
    ++ "name:" ++ toString v.variant.length ++ ":" ++ v.variant

/-- A parsed or manually constructed declaration has no semantic identity until
    resolution stamps both definition-site components. Absence fails closed. -/
def StructDef.typeId? (sd : StructDef) : Option TypeId :=
  if sd.definedIn.isEmpty || sd.definitionName.isEmpty then none
  else some (.user sd.definedIn sd.definitionName)

/-- Builtin identity comes from `builtinId`; user identity comes from the
    definition site. Local spelling is never consulted. -/
def EnumDef.typeId? (ed : EnumDef) : Option TypeId :=
  match ed.builtinId with
  | some id => some (.builtin id)
  | none =>
      if ed.definedIn.isEmpty || ed.definitionName.isEmpty then none
      else some (.user ed.definedIn ed.definitionName)

end Concrete
