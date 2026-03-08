import Concrete.AST

namespace Concrete

structure FieldInfo where
  name : String
  ty : Ty
  index : Nat
  deriving Repr

structure StructInfo where
  name : String
  fields : List FieldInfo
  typeParams : List String := []
  deriving Repr

structure EnumVariantInfo where
  name : String
  tag : Nat
  fields : List FieldInfo
  deriving Repr, Inhabited

structure EnumInfo where
  name : String
  variants : List EnumVariantInfo
  payloadSize : Nat  -- size in bytes of largest variant payload
  typeParams : List String := []
  deriving Repr, Inhabited

structure CodegenState where
  output : String
  labelCounter : Nat
  localCounter : Nat
  vars : List (String × String)
  varTypes : List (String × Ty)
  structDefs : List StructInfo
  enumDefs : List EnumInfo
  fnRetTypes : List (String × Ty)
  stringLitCounter : Nat
  stringGlobals : String
  constants : List (String × (Ty × Expr))
  currentRetTy : Ty := .unit
  fnParamTypes : List (String × List Ty) := []
  loopExitLabel : Option String := none
  loopContLabel : Option String := none
  -- (closure fields removed: no closures in Concrete)
  deferStack : List (List Expr) := [[]]  -- stack of deferred expressions per scope
  loopResultSlot : Option String := none  -- alloca slot for while-as-expression result
  loopLabelMap : List (String × String × String) := []  -- label → (exitLabel, contLabel)
  typeVarMapping : List (String × String) := []  -- type var → concrete type name (for monomorphization)
  fnTypeParams : List (String × List String) := []  -- fn name → type param names
  fnTypeBounds : List (String × List (String × List String)) := []  -- fn name → type bounds
  allFnDefs : List FnDef := []  -- all function definitions (for monomorphization lookup)
  monoQueue : List (String × FnDef) := []  -- (monoName, substituted FnDef) to generate
  monoGenerated : List String := []  -- already-generated monomorphized function names
  hashMapInstantiations : List String := []  -- already-generated HashMap helper sets (e.g. "Int_Int")

instance : Inhabited CodegenState where
  default := {
    output := ""
    labelCounter := 0
    localCounter := 0
    vars := []
    varTypes := []
    structDefs := []
    enumDefs := []
    fnRetTypes := []
    stringLitCounter := 0
    stringGlobals := ""
    constants := []
    currentRetTy := Ty.unit
    fnParamTypes := []
  }

end Concrete
