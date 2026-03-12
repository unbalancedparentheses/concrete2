import Concrete.AST
import Concrete.Shared

namespace Concrete

/-! ## FileSummary — the declaration-level cross-file interface artifact

`FileSummary` is the single source of cross-file information. All passes
consume signatures and type declarations from it rather than rebuilding
their own views from raw ASTs.

Built once by `buildSummaryTable`, consumed by Resolve (shallow phase), Check, and Elab.
Each module's summary is computed exactly once; submodule summaries are reused
from the parent's `submoduleSummaries` field (no redundant rebuilds).

`ResolvedImports` is the single import artifact consumed by Check and Elab.
It is built once from the summary table (via `resolveImportsFromTable`) and shared,
not rebuilt ad hoc in each pass.

Artifact flow:
  ParsedModule → FileSummary → ResolvedImports → checked/elaborated module

Interface data (safe to cache/serialize):
  functions, externFnSigs, implMethodSigs, structs, enums, publicNames,
  traits, constants, typeAliases, newtypes, imports, submoduleSummaries

Implementation data (needed by Check/Elab for whole-program body compilation):
  implBlocks, traitImpls — these carry full method bodies, not just signatures.
  Check and Elab read imported impl/trait-impl bodies through ResolvedImports
  to type-check and elaborate cross-module method implementations.

TODO: For future incremental compilation, split into interface-only and body portions
so that downstream passes can consume cached interface summaries without method bodies.
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
  externFnSigs : List (String × FnSummary) := []
  implMethodSigs : List (String × FnSummary) := []  -- Self preserved (unresolved)
  imports : List ImportDecl := []
  submoduleSummaries : List (String × FileSummary) := []

instance : Inhabited FileSummary where
  default := { name := "", functions := [], structs := [], enums := [],
                implBlocks := [], traitImpls := [], publicNames := [] }

/-- All data imported into a module, resolved from the summary table.
    Single import artifact consumed by Check and Elab. -/
structure ResolvedImports where
  functions      : List (String × FnSummary) := []
  structs        : List StructDef := []
  enums          : List EnumDef := []
  implBlocks     : List ImplBlock := []
  traitImpls     : List ImplTraitBlock := []
  implMethodSigs : List (String × FnSummary) := []  -- pre-computed, Self preserved
  /-- Maps local alias name → original linker symbol for aliased imports. -/
  linkerAliases  : List (String × String) := []

private def fnDefToSummary (f : FnDef) : String × FnSummary :=
  (f.name, { params := f.params.map fun p => (p.name, p.ty)
             retTy := f.retTy
             typeParams := f.typeParams
             typeBounds := f.typeBounds
             capParams := f.capParams
             capSet := f.capSet })

/-- Extract impl method summaries from impl blocks with Self preserved (unresolved). -/
def implBlocksToMethodSummaries (blocks : List ImplBlock) : List (String × FnSummary) :=
  blocks.foldl (fun acc ib =>
    acc ++ ib.methods.map fun f =>
      (ib.typeName ++ "_" ++ f.name,
       { params := f.params.map fun p => (p.name, p.ty)
         retTy := f.retTy
         typeParams := ib.typeParams ++ f.typeParams
         typeBounds := f.typeBounds
         capParams := f.capParams
         capSet := f.capSet })
  ) []

/-- Extract impl method summaries from trait impl blocks with Self preserved (unresolved). -/
def traitImplBlocksToMethodSummaries (blocks : List ImplTraitBlock) : List (String × FnSummary) :=
  blocks.foldl (fun acc tb =>
    acc ++ tb.methods.map fun f =>
      (tb.typeName ++ "_" ++ f.name,
       { params := f.params.map fun p => (p.name, p.ty)
         retTy := f.retTy
         typeParams := tb.typeParams ++ f.typeParams
         typeBounds := f.typeBounds
         capParams := f.capParams
         capSet := f.capSet })
  ) []

/-- Resolve Self in impl method signatures using the concrete impl type from blocks. -/
def resolveImplMethodSigs
    (sigs : List (String × FnSummary))
    (implBlocks : List ImplBlock)
    (traitImpls : List ImplTraitBlock)
    : List (String × FnSummary) :=
  let tyMap := implBlocks.foldl (fun acc ib =>
    let implTy := if ib.typeParams.isEmpty then Ty.named ib.typeName
                  else Ty.generic ib.typeName (ib.typeParams.map Ty.typeVar)
    acc ++ ib.methods.map fun f => (ib.typeName ++ "_" ++ f.name, implTy)
  ) []
  let tyMap := traitImpls.foldl (fun acc tb =>
    let implTy := if tb.typeParams.isEmpty then Ty.named tb.typeName
                  else Ty.generic tb.typeName (tb.typeParams.map Ty.typeVar)
    acc ++ tb.methods.map fun f => (tb.typeName ++ "_" ++ f.name, implTy)
  ) tyMap
  sigs.map fun (name, sig) =>
    match tyMap.lookup name with
    | some implTy =>
      (name, { sig with
        params := sig.params.map fun (n, t) => (n, resolveSelfTy t implTy)
        retTy := resolveSelfTy sig.retTy implTy })
    | none => (name, sig)

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
  let externFnSigs := m.externFns.map fun ef =>
    let capSet := if ef.isTrusted then CapSet.empty else CapSet.concrete ["Unsafe"]
    (ef.name, { params := ef.params.map fun p => (p.name, p.ty), retTy := ef.retTy,
                capSet := capSet : FnSummary })
  let implMethodSigs := implBlocksToMethodSummaries m.implBlocks
                     ++ traitImplBlocksToMethodSummaries m.traitImpls
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
    externFnSigs := externFnSigs
    implMethodSigs := implMethodSigs
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

/-- Resolve imports for a module by looking up symbols directly in the summary table.
    Pre-computes imported impl method sigs from the exporting module's summary.
    Used by both Check and Elab. -/
def resolveImports (imports : List ImportDecl)
    (summaryTable : List (String × FileSummary))
    (unknownModuleMsg : String → String)
    (notPublicMsg : String → String → String)
    : Except String ResolvedImports :=
  imports.foldlM (init := {}) fun acc imp =>
    match summaryTable.lookup imp.moduleName with
    | none => .error (unknownModuleMsg imp.moduleName)
    | some summary =>
      let pubFns := summary.functions ++ summary.externFnSigs
      imp.symbols.foldlM (init := acc) fun acc sym =>
        let origName := sym.name
        let localName := sym.effectiveName
        match pubFns.find? fun (n, _) => n == origName with
        | some (_, sig) =>
          let newAliases := if localName != origName
            then acc.linkerAliases ++ [(localName, origName)]
            else acc.linkerAliases
          .ok { acc with functions := acc.functions ++ [(localName, sig)],
                         linkerAliases := newAliases }
        | none =>
          match summary.structs.find? fun sd => sd.name == origName with
          | some sd =>
            let structImpls := summary.implBlocks.filter fun ib => ib.typeName == origName
            let structTraitImpls := summary.traitImpls.filter fun tb => tb.typeName == origName
            let mangledNames := structImpls.foldl (fun ns ib =>
              ns ++ ib.methods.map fun f => ib.typeName ++ "_" ++ f.name) []
              ++ structTraitImpls.foldl (fun ns tb =>
              ns ++ tb.methods.map fun f => tb.typeName ++ "_" ++ f.name) []
            let matchingSigs := summary.implMethodSigs.filter fun (name, _) =>
              mangledNames.contains name
            .ok { acc with structs := acc.structs ++ [sd],
                           implBlocks := acc.implBlocks ++ structImpls,
                           traitImpls := acc.traitImpls ++ structTraitImpls,
                           implMethodSigs := acc.implMethodSigs ++ matchingSigs }
          | none =>
            match summary.enums.find? fun ed => ed.name == origName with
            | some ed => .ok { acc with enums := acc.enums ++ [ed] }
            | none => .error (notPublicMsg origName imp.moduleName)

end Concrete
