import Concrete.Core
import Concrete.Layout
import Concrete.FileSummary
import Concrete.AST
import Concrete.Intrinsic

namespace Concrete
namespace Report

-- ============================================================
-- Helpers
-- ============================================================

def ppCapSet : CapSet → String
  | .empty => "(pure)"
  | .concrete caps => ", ".intercalate caps
  | .var name => name
  | .union a b => s!"{ppCapSet a}, {ppCapSet b}"

private def ppTyList (tys : List (String × Ty)) : String :=
  ", ".intercalate (tys.map fun (n, t) => s!"{n}: {tyToStr t}")

/-- Right-pad a string to the given width. -/
private def padRight (s : String) (w : Nat) : String :=
  if s.length >= w then s
  else s ++ String.ofList (List.replicate (w - s.length) ' ')

/-- Left-pad a number string to the given width. -/
private def padNum (n : Nat) (w : Nat) : String :=
  let s := toString n
  if s.length >= w then s
  else String.ofList (List.replicate (w - s.length) ' ') ++ s

-- ============================================================
-- Report 1: Capability Summary (--report caps)
-- ============================================================

/-- Count functions across module tree. -/
private partial def countModuleFns (m : CModule) : Nat :=
  m.functions.length + m.submodules.foldl (fun acc sub => acc + countModuleFns sub) 0

private partial def countModulePure (m : CModule) : Nat :=
  let local_ := (m.functions.filter fun f => f.capSet == .empty).length
  local_ + m.submodules.foldl (fun acc sub => acc + countModulePure sub) 0

private partial def countModuleExterns (m : CModule) : Nat :=
  m.externFns.length + m.submodules.foldl (fun acc sub => acc + countModuleExterns sub) 0

private partial def capReportModule (m : CModule) (indent : String) : String :=
  let header := s!"{indent}module {m.name}:"
  let fnLines := m.functions.map fun f =>
    let pubStr := if f.isPublic then "pub " else "    "
    let capsStr := ppCapSet f.capSet
    s!"{indent}  {pubStr}{f.name} : {capsStr}"
  let trustedExterns := m.externFns.filter fun (_, _, _, t) => t
  let untrustedExterns := m.externFns.filter fun (_, _, _, t) => !t
  let externLines := if untrustedExterns.isEmpty then []
    else [s!"{indent}  extern:"] ++ untrustedExterns.map fun (n, _, _, _) =>
      s!"{indent}      {n} : Unsafe"
  let externLines := externLines ++ (if trustedExterns.isEmpty then []
    else [s!"{indent}  trusted extern:"] ++ trustedExterns.map fun (n, _, _, _) =>
      s!"{indent}      {n} : (none)")
  let subLines := m.submodules.map (capReportModule · (indent ++ "  "))
  let body := fnLines ++ externLines ++ subLines
  if body.isEmpty then header
  else s!"{header}\n{"\n".intercalate body}"

def capabilityReport (modules : List CModule) : String :=
  let header := "=== Capability Summary ==="
  let body := modules.map (capReportModule · "")
  let totalFns := modules.foldl (fun acc m => acc + countModuleFns m) 0
  let pureFns := modules.foldl (fun acc m => acc + countModulePure m) 0
  let externCount := modules.foldl (fun acc m => acc + countModuleExterns m) 0
  let summary := s!"\nTotals: {totalFns} functions ({pureFns} pure), {externCount} externs"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 2: Unsafe Signature Summary (--report unsafe)
--
-- Reports functions whose *signatures* involve Unsafe:
--   - declared Unsafe capability
--   - extern functions (implicit Unsafe)
--   - raw pointer parameter/return types
-- Does not inspect function bodies for unsafe operations.
-- ============================================================

private def hasUnsafeCap (cs : CapSet) : Bool :=
  cs.concreteCaps.contains unsafeCapName

private def usesRawPtr : Ty → Bool
  | .ptrMut _ | .ptrConst _ => true
  | _ => false

private def fnUsesRawPtrs (f : CFnDef) : Bool :=
  f.params.any (fun (_, t) => usesRawPtr t) || usesRawPtr f.retTy

/-- Count unsafe-related items across module tree. -/
private partial def unsafeCounts (m : CModule)
    : Nat × Nat × Nat × Nat × Nat :=
  let unsafeFns := (m.functions.filter fun f => hasUnsafeCap f.capSet).length
  let ptrFns := (m.functions.filter fnUsesRawPtrs).length
  let externFns := (m.externFns.filter fun (_, _, _, t) => !t).length
  let trustedExterns := (m.externFns.filter fun (_, _, _, t) => t).length
  let trustedFns := (m.functions.filter fun f => f.isTrusted).length
  m.submodules.foldl (fun (a, b, c, d, e) sub =>
    let (a', b', c', d', e') := unsafeCounts sub
    (a + a', b + b', c + c', d + d', e + e'))
    (unsafeFns, ptrFns, externFns, trustedExterns, trustedFns)

private partial def unsafeReportModule (m : CModule) (indent : String) : Option String :=
  let unsafeFns := m.functions.filter fun f => hasUnsafeCap f.capSet
  let externFns := m.externFns.filter fun (_, _, _, t) => !t
  let trustedExternFns := m.externFns.filter fun (_, _, _, t) => t
  let ptrFns := m.functions.filter fnUsesRawPtrs
  let trustedFns := m.functions.filter fun f => f.isTrusted
  let subReports := m.submodules.filterMap (unsafeReportModule · (indent ++ "  "))
  if unsafeFns.isEmpty && externFns.isEmpty && trustedExternFns.isEmpty && ptrFns.isEmpty && trustedFns.isEmpty && subReports.isEmpty then
    none
  else
    let lines : List String := [s!"{indent}module {m.name}:"]
    let lines := if unsafeFns.isEmpty then lines
      else lines ++ [s!"{indent}  Functions with Unsafe capability:"] ++
        unsafeFns.map fun f =>
          s!"{indent}    fn {f.name}({ppTyList f.params}) -> {tyToStr f.retTy}"
    let lines := if externFns.isEmpty then lines
      else lines ++ [s!"{indent}  Extern functions:"] ++
        externFns.map fun (n, ps, rt, _) =>
          s!"{indent}    extern fn {n}({ppTyList ps}) -> {tyToStr rt}"
    let lines := if trustedExternFns.isEmpty then lines
      else lines ++ [s!"{indent}  Trusted extern functions:"] ++
        trustedExternFns.map fun (n, ps, rt, _) =>
          s!"{indent}    trusted extern fn {n}({ppTyList ps}) -> {tyToStr rt}"
    let lines := if ptrFns.isEmpty then lines
      else lines ++ [s!"{indent}  Functions with raw pointer signatures:"] ++
        ptrFns.map fun f =>
          s!"{indent}    fn {f.name}({ppTyList f.params}) -> {tyToStr f.retTy}"
    -- Split trusted functions into standalone fns vs impl methods
    let trustedStandalone := trustedFns.filter fun f => f.trustedImplOrigin.isNone
    let trustedImplFns := trustedFns.filter fun f => f.trustedImplOrigin.isSome
    -- Group impl methods by origin type name
    let trustedImplNames := (trustedImplFns.filterMap (·.trustedImplOrigin)).eraseDups
    let lines := if trustedStandalone.isEmpty && trustedImplFns.isEmpty then lines
      else
        let lines := lines ++ [s!"{indent}  Trusted boundaries:"]
        let lines := if trustedStandalone.isEmpty then lines
          else lines ++ trustedStandalone.map fun f =>
            s!"{indent}    trusted fn {f.name}({ppTyList f.params}) -> {tyToStr f.retTy}"
        let lines := trustedImplNames.foldl (fun lines implName =>
          let methods := trustedImplFns.filter fun f => f.trustedImplOrigin == some implName
          let methodLines := methods.map fun f =>
            -- Strip "TypeName_" prefix from method name for display
            let shortName := if f.name.startsWith (implName ++ "_") then
              f.name.drop (implName.length + 1) else f.name
            s!"{indent}      fn {shortName}({ppTyList f.params}) -> {tyToStr f.retTy}"
          lines ++ [s!"{indent}    trusted impl {implName}:"] ++ methodLines
        ) lines
        lines
    let lines := lines ++ subReports
    some ("\n".intercalate lines)

def unsafeReport (modules : List CModule) : String :=
  let header := "=== Unsafe Signature Summary ==="
  let body := modules.filterMap (unsafeReportModule · "")
  let (unsafeCount, ptrCount, externCount, trustedExternCount, trustedCount) :=
    modules.foldl (fun (a, b, c, d, e) m =>
      let (a', b', c', d', e') := unsafeCounts m
      (a + a', b + b', c + c', d + d', e + e')) (0, 0, 0, 0, 0)
  let total := unsafeCount + externCount + trustedExternCount + ptrCount + trustedCount
  if body.isEmpty then s!"{header}\n\nNo unsafe signatures found.\n"
  else
    let parts : List String := []
    let parts := if unsafeCount > 0 then parts ++ [s!"{unsafeCount} unsafe"] else parts
    let parts := if externCount > 0 then parts ++ [s!"{externCount} extern"] else parts
    let parts := if trustedExternCount > 0 then parts ++ [s!"{trustedExternCount} trusted extern"] else parts
    let parts := if ptrCount > 0 then parts ++ [s!"{ptrCount} raw-pointer"] else parts
    let parts := if trustedCount > 0 then parts ++ [s!"{trustedCount} trusted"] else parts
    let summary := s!"\nTotals: {total} unsafe-related signatures ({", ".intercalate parts})"
    s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 3: Layout Report (--report layout)
-- ============================================================

private partial def collectSubStructs (m : CModule) : List CStructDef :=
  m.submodules.foldl (fun acc sub => acc ++ sub.structs ++ collectSubStructs sub) []

private partial def collectSubEnums (m : CModule) : List CEnumDef :=
  m.submodules.foldl (fun acc sub => acc ++ sub.enums ++ collectSubEnums sub) []

private def buildLayoutCtx (modules : List CModule) : Layout.Ctx :=
  let structs := modules.foldl (fun acc m => acc ++ m.structs ++ collectSubStructs m) []
  let enums := modules.foldl (fun acc m => acc ++ m.enums ++ collectSubEnums m) []
  { structDefs := structs, enumDefs := enums }

private def layoutStructReport (ctx : Layout.Ctx) (sd : CStructDef) : Option String :=
  if !sd.typeParams.isEmpty then none
  else
    let size := Layout.tySize ctx (.named sd.name)
    let align := Layout.tyAlign ctx (.named sd.name)
    let reprStr := if sd.isReprC then "  #[repr(C)]" else ""
    let packedStr := if sd.isPacked then "  #[packed]" else ""
    let header := s!"struct {sd.name}{reprStr}{packedStr}  (size: {size}, align: {align})"
    -- Compute max widths for aligned columns
    let fieldData := sd.fields.map fun (fname, fty) =>
      let off := Layout.fieldOffset ctx sd.name fname
      let fsz := Layout.tySize ctx fty
      let falign := Layout.tyAlign ctx fty
      (fname, fty, off, fsz, falign)
    let maxOffW := fieldData.foldl (fun acc (_, _, off, _, _) => max acc (toString off).length) 1
    let maxSzW := fieldData.foldl (fun acc (_, _, _, fsz, _) => max acc (toString fsz).length) 1
    let maxAlW := fieldData.foldl (fun acc (_, _, _, _, fa) => max acc (toString fa).length) 1
    let fieldLines := fieldData.map fun (fname, fty, off, fsz, falign) =>
      s!"    offset {padNum off (maxOffW + 1)}  size {padNum fsz (maxSzW + 1)}  align {padNum falign (maxAlW + 1)}  {fname}: {tyToStr fty}"
    some (s!"{header}\n{"\n".intercalate fieldLines}")

private def layoutEnumReport (ctx : Layout.Ctx) (ed : CEnumDef) : Option String :=
  if !ed.typeParams.isEmpty then none
  else
    let size := Layout.tySize ctx (.named ed.name)
    let align := Layout.tyAlign ctx (.named ed.name)
    let tagSize := 4
    let payloadOff := Layout.enumPayloadOffset ctx ed
    let maxPayload := Layout.enumPayloadSize ctx ed
    let header := s!"enum {ed.name}  (size: {size}, align: {align}, tag: {tagSize}, payload_offset: {payloadOff}, max_payload: {maxPayload})"
    let variantLines := ed.variants.map fun (vn, fields) =>
      if fields.isEmpty then s!"    {vn}"
      else
        let fs := fields.map fun (fn, ft) => s!"{fn}: {tyToStr ft}"
        s!"    {vn} \{ {", ".intercalate fs} }"
    some (s!"{header}\n{"\n".intercalate variantLines}")

/-- Collect all structs and enums from a module including submodules. -/
private partial def collectAllStructs (m : CModule) : List CStructDef :=
  m.structs ++ m.submodules.foldl (fun acc sub => acc ++ collectAllStructs sub) []

private partial def collectAllEnums (m : CModule) : List CEnumDef :=
  m.enums ++ m.submodules.foldl (fun acc sub => acc ++ collectAllEnums sub) []

def layoutReport (modules : List CModule) : String :=
  let ctx := buildLayoutCtx modules
  let header := "=== Type Layout Report ==="
  let allStructs := modules.foldl (fun acc m => acc ++ collectAllStructs m) []
  let allEnums := modules.foldl (fun acc m => acc ++ collectAllEnums m) []
  let structReports := allStructs.filterMap (layoutStructReport ctx)
  let enumReports := allEnums.filterMap (layoutEnumReport ctx)
  let body := structReports ++ enumReports
  if body.isEmpty then s!"{header}\n\nNo concrete types found.\n"
  else
    let sPlural := if structReports.length == 1 then "struct" else "structs"
    let ePlural := if enumReports.length == 1 then "enum" else "enums"
    let summary := s!"\nTotals: {structReports.length} {sPlural}, {enumReports.length} {ePlural}"
    s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 4: Interface Summary (--report interface)
-- ============================================================

private def interfaceModule (name : String) (fs : FileSummary) : String :=
  let pubFns := fs.functions.filter fun (n, _) => fs.publicNames.contains n
  let pubExternFns := fs.externFns.filter (·.isPublic)
  let pubStructs := fs.structs.filter (·.isPublic)
  let pubEnums := fs.enums.filter (·.isPublic)
  let pubTraits := fs.traits.filter (·.isPublic)
  let pubConstants := fs.constants.filter (·.isPublic)
  let pubAliases := fs.typeAliases.filter (·.isPublic)
  let pubNewtypes := fs.newtypes.filter (·.isPublic)
  let exportCount := pubFns.length + pubExternFns.length + pubStructs.length +
    pubEnums.length + pubTraits.length + pubConstants.length +
    pubAliases.length + pubNewtypes.length
  let header := if exportCount == 0 then s!"module {name} (no exports)"
    else s!"module {name} ({exportCount} exports):"
  let lines : List String := []
  let lines := if fs.imports.isEmpty then lines
    else lines ++ ["  imports:"] ++
      fs.imports.map fun imp =>
        let symStrs := imp.symbols.map fun s =>
          match s.alias with
          | some a => s!"{s.name} as {a}"
          | none => s.name
        s!"    use {imp.moduleName} \{ {", ".intercalate symStrs} }"
  let lines := if exportCount == 0 then lines
    else
      let lines := lines ++ ["  public API:"]
      let lines := lines ++ pubFns.map fun (n, sig) =>
        let params := sig.params.map fun (pn, pt) => s!"{pn}: {tyToStr pt}"
        let capsStr := ppCapSet sig.capSet
        s!"    fn {n}({", ".intercalate params}) -> {tyToStr sig.retTy}  [{capsStr}]"
      let lines := lines ++ pubExternFns.map fun ef =>
        let params := ef.params.map fun p => s!"{p.name}: {tyToStr p.ty}"
        let kw := if ef.isTrusted then "trusted extern fn" else "extern fn"
        s!"    {kw} {ef.name}({", ".intercalate params}) -> {tyToStr ef.retTy}"
      let lines := lines ++ pubStructs.map fun sd =>
        let fields := sd.fields.map fun sf => s!"{sf.name}: {tyToStr sf.ty}"
        s!"    struct {sd.name} \{ {", ".intercalate fields} }"
      let lines := lines ++ pubEnums.map fun ed =>
        let variants := ed.variants.map (·.name)
        s!"    enum {ed.name} \{ {", ".intercalate variants} }"
      let lines := lines ++ pubTraits.map fun td =>
        let methods := td.methods.map (·.name)
        s!"    trait {td.name} \{ {", ".intercalate methods} }"
      let lines := lines ++ pubConstants.map fun c =>
        s!"    const {c.name}: {tyToStr c.ty}"
      let lines := lines ++ pubAliases.map fun a =>
        s!"    type {a.name} = {tyToStr a.targetTy}"
      let lines := lines ++ pubNewtypes.map fun nt =>
        s!"    newtype {nt.name}({tyToStr nt.innerTy})"
      lines
  s!"{header}\n{"\n".intercalate lines}"

def interfaceReport (summaryTable : List (String × FileSummary)) : String :=
  let header := "=== Interface Summary ==="
  let body := summaryTable.map fun (name, fs) => interfaceModule name fs
  let totalExports := summaryTable.foldl (fun acc (_, fs) =>
    let pubCount := (fs.functions.filter fun (n, _) => fs.publicNames.contains n).length +
      (fs.externFns.filter (·.isPublic)).length +
      (fs.structs.filter (·.isPublic)).length +
      (fs.enums.filter (·.isPublic)).length +
      (fs.traits.filter (·.isPublic)).length +
      (fs.constants.filter (·.isPublic)).length +
      (fs.typeAliases.filter (·.isPublic)).length +
      (fs.newtypes.filter (·.isPublic)).length
    acc + pubCount) 0
  let summary := s!"\nTotals: {summaryTable.length} modules, {totalExports} public exports"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 5: Monomorphization Report (--report mono)
-- ============================================================

private partial def collectSubFnNames (m : CModule) : List String :=
  m.submodules.foldl (fun acc sub =>
    acc ++ sub.functions.map (·.name) ++ collectSubFnNames sub) []

private def collectFnNames (modules : List CModule) : List String :=
  modules.foldl (fun acc m =>
    acc ++ m.functions.map (·.name) ++ collectSubFnNames m) []

/-- Count generic functions across all modules including submodules. -/
private partial def countGenericFns (m : CModule) : Nat :=
  let local_ := (m.functions.filter fun f => !f.typeParams.isEmpty).length
  local_ + m.submodules.foldl (fun acc sub => acc + countGenericFns sub) 0

/-- Count all functions across module tree. -/
private partial def countAllFns (m : CModule) : Nat :=
  m.functions.length + m.submodules.foldl (fun acc sub => acc + countAllFns sub) 0

def monoReport (preMono postMono : List CModule) : String :=
  let header := "=== Monomorphization Report ==="
  let preNames := collectFnNames preMono
  let postNames := collectFnNames postMono
  let specializations := postNames.filter fun n =>
    (n.splitOn "_for_").length > 1 && !preNames.contains n
  let genericCount := preMono.foldl (fun acc m => acc + countGenericFns m) 0
  let preFnCount := preMono.foldl (fun acc m => acc + countAllFns m) 0
  let postFnCount := postMono.foldl (fun acc m => acc + countAllFns m) 0
  let statsLines := [
    s!"Functions before mono: {preFnCount}",
    s!"Functions after mono:  {postFnCount}",
    s!"Generic functions:     {genericCount}",
    s!"Specializations:       {specializations.length}"
  ]
  let specLines := if specializations.isEmpty then []
    else ["", "Specializations:"] ++ specializations.map fun n =>
      let parts := n.splitOn "_for_"
      match parts with
      | [base, suffix] =>
        let typeArgs := suffix.splitOn "_"
        s!"  {base}<{", ".intercalate typeArgs}> -> {n}"
      | _ => s!"  {n}"
  let body := statsLines ++ specLines
  s!"{header}\n\n{"\n".intercalate body}\n"

end Report
end Concrete
