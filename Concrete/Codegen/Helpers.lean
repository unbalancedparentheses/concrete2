import Concrete.Codegen.State

namespace Concrete

def CodegenState.init : CodegenState :=
  { output := "", labelCounter := 0, localCounter := 0,
    vars := [], varTypes := [], structDefs := [], enumDefs := [], fnRetTypes := [],
    stringLitCounter := 0, stringGlobals := "", constants := [] }

def CodegenState.emit (s : CodegenState) (line : String) : CodegenState :=
  { s with output := s.output ++ line ++ "\n" }

def CodegenState.freshLabel (s : CodegenState) (pfx : String := "L") : CodegenState × String :=
  let name := pfx ++ toString s.labelCounter
  ({ s with labelCounter := s.labelCounter + 1 }, name)

def CodegenState.freshLocal (s : CodegenState) : CodegenState × String :=
  let name := "%t" ++ toString s.localCounter
  ({ s with localCounter := s.localCounter + 1 }, name)

def CodegenState.lookupVar (s : CodegenState) (name : String) : Option String :=
  s.vars.lookup name

def CodegenState.addVar (s : CodegenState) (name : String) (reg : String) : CodegenState :=
  { s with vars := (name, reg) :: s.vars }

def CodegenState.addVarType (s : CodegenState) (name : String) (ty : Ty) : CodegenState :=
  { s with varTypes := (name, ty) :: s.varTypes }

def CodegenState.lookupVarType (s : CodegenState) (name : String) : Option Ty :=
  s.varTypes.lookup name

def CodegenState.lookupStruct (s : CodegenState) (name : String) : Option StructInfo :=
  s.structDefs.find? fun si => si.name == name

def CodegenState.lookupEnum (s : CodegenState) (name : String) : Option EnumInfo :=
  s.enumDefs.find? fun ei => ei.name == name

def CodegenState.lookupEnumVariant (s : CodegenState) (enumName variantName : String) : Option EnumVariantInfo :=
  match s.lookupEnum enumName with
  | some ei => ei.variants.find? fun v => v.name == variantName
  | none => none

def CodegenState.lookupFieldIndex (s : CodegenState) (structName : String) (fieldName : String) : Option (Nat × Ty) :=
  match s.lookupStruct structName with
  | some si =>
    match si.fields.find? fun fi => fi.name == fieldName with
    | some fi => some (fi.index, fi.ty)
    | none => none
  | none => none

end Concrete
