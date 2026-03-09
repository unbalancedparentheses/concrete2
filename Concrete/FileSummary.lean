import Concrete.AST

namespace Concrete

/-! ## FileSummary — stable cross-file interface artifact

Built once by `buildSummaryTable`, consumed by Resolve, Check, and Elab.
Each module's summary is computed exactly once; submodule summaries are reused
from the parent's `submoduleSummaries` field (no redundant rebuilds).
-/

structure ConstSummary where
  name : String
  ty : Ty
  isPublic : Bool := false

structure FnSummary where
  params : List (String × Ty)
  retTy : Ty
  typeParams : List String := []
  typeBounds : List (String × List String) := []
  capParams : List String := []
  capSet : CapSet := .empty
  deriving Repr

structure FileSummary where
  name : String
  functions : List (String × FnSummary)
  structs : List StructDef
  enums : List EnumDef
  implBlocks : List ImplBlock
  traitImpls : List ImplTraitBlock
  publicNames : List String
  traits : List TraitDef := []
  constants : List ConstSummary := []
  typeAliases : List TypeAlias := []
  newtypes : List NewtypeDef := []
  externFns : List ExternFnDecl := []
  imports : List ImportDecl := []
  submoduleSummaries : List (String × FileSummary) := []

instance : Inhabited FileSummary where
  default := { name := "", functions := [], structs := [], enums := [],
                implBlocks := [], traitImpls := [], publicNames := [] }

private def fnDefToSummary (f : FnDef) : String × FnSummary :=
  (f.name, { params := f.params.map fun p => (p.name, p.ty)
             retTy := f.retTy
             typeParams := f.typeParams
             typeBounds := f.typeBounds
             capParams := f.capParams
             capSet := f.capSet })

partial def buildFileSummary (m : Module) : FileSummary :=
  let functions := m.functions.map fnDefToSummary
  let pubFns := m.functions.filter (·.isPublic) |>.map (·.name)
  let pubStructs := m.structs.filter (·.isPublic) |>.map (·.name)
  let pubEnums := m.enums.filter (·.isPublic) |>.map (·.name)
  let pubTraits := m.traits.filter (·.isPublic) |>.map (·.name)
  let pubExterns := m.externFns.filter (·.isPublic) |>.map (·.name)
  let pubConstants := m.constants.filter (·.isPublic) |>.map (·.name)
  let pubAliases := m.typeAliases.filter (·.isPublic) |>.map (·.name)
  let pubImplMethods := m.implBlocks.foldl (fun acc ib =>
    acc ++ ib.methods.map (·.name)) []
  let pubTraitImplMethods := m.traitImpls.foldl (fun acc ti =>
    acc ++ ti.methods.map (·.name)) []
  let publicNames := pubFns ++ pubStructs ++ pubEnums ++ pubTraits ++ pubExterns
                     ++ pubConstants ++ pubAliases ++ pubImplMethods ++ pubTraitImplMethods
  { name := m.name
    functions := functions
    structs := m.structs
    enums := m.enums
    implBlocks := m.implBlocks
    traitImpls := m.traitImpls
    publicNames := publicNames
    traits := m.traits
    constants := m.constants.map fun c => { name := c.name, ty := c.ty, isPublic := c.isPublic }
    typeAliases := m.typeAliases
    newtypes := m.newtypes
    externFns := m.externFns
    imports := m.imports
    submoduleSummaries := m.submodules.map fun sub => (sub.name, buildFileSummary sub) }

def buildSummaryTable (modules : List Module) : List (String × FileSummary) :=
  modules.foldl (fun acc m =>
    let summary := buildFileSummary m
    let subEntries := summary.submoduleSummaries.foldl (fun acc2 (subName, subSummary) =>
      acc2 ++ [(m.name ++ "." ++ subName, subSummary), (subName, subSummary)]
    ) []
    acc ++ [(m.name, summary)] ++ subEntries
  ) []

-- ============================================================
-- Export table: shared across Check and Elab
-- ============================================================

abbrev ExportEntry := List (String × FnSummary) × List StructDef × List EnumDef × List ImplBlock × List ImplTraitBlock

/-- Build export table from summary table. Each module's public functions,
    structs, enums, impl blocks, and trait impls are collected once. -/
def buildExportTable (summaryTable : List (String × FileSummary)) : List (String × ExportEntry) :=
  summaryTable.map fun (name, summary) =>
    let fnSigs := summary.functions
    let externSigs := summary.externFns.map fun ef =>
      (ef.name, { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy : FnSummary })
    (name, (fnSigs ++ externSigs, summary.structs, summary.enums, summary.implBlocks, summary.traitImpls))

/-- Resolve imports for a module by looking up symbols in a pre-built export table.
    Used by both Check and Elab. -/
def resolveImportsFromExports (imports : List ImportDecl)
    (exportTable : List (String × ExportEntry))
    (unknownModuleMsg : String → String)
    (notPublicMsg : String → String → String)
    : Except String (List (String × FnSummary) × List StructDef × List EnumDef × List ImplBlock × List ImplTraitBlock) :=
  imports.foldlM (init := ([], [], [], [], [])) fun (fns, structs, enums, impls, trImpls) imp =>
    match exportTable.lookup imp.moduleName with
    | none => .error (unknownModuleMsg imp.moduleName)
    | some (pubFns, pubStructs, pubEnums, pubImpls, pubTraitImpls) =>
      imp.symbols.foldlM (init := (fns, structs, enums, impls, trImpls)) fun (fns, structs, enums, impls, trImpls) sym =>
        match pubFns.find? fun (n, _) => n == sym with
        | some pair => .ok (fns ++ [pair], structs, enums, impls, trImpls)
        | none =>
          match pubStructs.find? fun sd => sd.name == sym with
          | some sd =>
            let structImpls := pubImpls.filter fun ib => ib.typeName == sym
            let structTraitImpls := pubTraitImpls.filter fun tb => tb.typeName == sym
            .ok (fns, structs ++ [sd], enums, impls ++ structImpls, trImpls ++ structTraitImpls)
          | none =>
            match pubEnums.find? fun ed => ed.name == sym with
            | some ed => .ok (fns, structs, enums ++ [ed], impls, trImpls)
            | none => .error (notPublicMsg sym imp.moduleName)

end Concrete
