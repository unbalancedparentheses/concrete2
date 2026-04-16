import Concrete.Pipeline
import Concrete.Report
import Concrete.ProofCore
import Concrete.Verify

namespace Concrete.DebugBundle

/-! ## DebugBundle — stable bundle format for reproducing compiler failures

A debug bundle captures everything needed to reproduce a compilation failure:
source files, compiler state at each pipeline stage, diagnostics, and metadata.

Bundle layout:
```
bundle/
  manifest.json        — compiler version, source path, flags, failure stage
  source/              — original source files (main + submodules)
  diagnostics.txt      — rendered diagnostics at failure point
  core.txt             — Core IR dump (if elaboration succeeded)
  ssa.txt              — SSA IR dump (if lowering succeeded)
  llvm.ll              — LLVM IR (if emission succeeded)
  consistency.txt      — ProofCore self-check results (if available)
  verify.txt           — Verifier pass results (if available)
```
-/

/-- Which pipeline stage the bundle was captured at. -/
inductive CaptureStage where
  | parse
  | resolve
  | check
  | elaborate
  | coreCheck
  | mono
  | lower
  | emit
  | complete
  deriving BEq

def CaptureStage.toString : CaptureStage → String
  | .parse     => "parse"
  | .resolve   => "resolve"
  | .check     => "check"
  | .elaborate => "elaborate"
  | .coreCheck => "coreCheck"
  | .mono      => "mono"
  | .lower     => "lower"
  | .emit      => "emit"
  | .complete  => "complete"

instance : ToString CaptureStage := ⟨CaptureStage.toString⟩

/-- Accumulated pipeline state for the debug bundle. -/
structure BundleState where
  inputPath    : String
  source       : String
  sourceMap    : SourceMap := []
  failStage    : Option CaptureStage := none
  diagnostics  : Diagnostics := []
  coreModules  : Option (List CModule) := none
  monoModules  : Option (List CModule) := none
  ssaModules   : Option (List SModule) := none
  llvmIR       : Option String := none
  proofCore    : Option ProofCore := none
  verifyDs     : Diagnostics := []

/-- Escape a string for JSON output. -/
private def jsonEscape (s : String) : String :=
  s.foldl (fun acc c =>
    acc ++ match c with
    | '"'  => "\\\""
    | '\\' => "\\\\"
    | '\n' => "\\n"
    | '\t' => "\\t"
    | c    => c.toString
  ) ""

/-- Generate the manifest.json content. -/
def renderManifest (st : BundleState) (compilerVersion : String) : String :=
  let stage := match st.failStage with
    | some s => s!"\"failed_at\": \"{s}\""
    | none   => "\"failed_at\": null"
  let diagCount := st.diagnostics.length
  let hasCore := st.coreModules.isSome
  let hasMono := st.monoModules.isSome
  let hasSSA  := st.ssaModules.isSome
  let hasLLVM := st.llvmIR.isSome
  let hasPC   := st.proofCore.isSome
  s!"\{
  \"version\": 1,
  \"compiler\": \"{jsonEscape compilerVersion}\",
  \"source_path\": \"{jsonEscape st.inputPath}\",
  {stage},
  \"diagnostic_count\": {diagCount},
  \"artifacts\": \{
    \"core_ir\": {hasCore},
    \"mono_ir\": {hasMono},
    \"ssa_ir\": {hasSSA},
    \"llvm_ir\": {hasLLVM},
    \"proof_core\": {hasPC}
  }
}"

/-- Write the debug bundle to a directory. -/
def writeBundle (bundleDir : String) (st : BundleState) (compilerVersion : String) : IO Unit := do
  -- Create directories
  IO.FS.createDirAll ⟨bundleDir⟩
  IO.FS.createDirAll ⟨bundleDir ++ "/source"⟩

  -- manifest.json
  IO.FS.writeFile ⟨bundleDir ++ "/manifest.json"⟩ (renderManifest st compilerVersion)

  -- Source files
  IO.FS.writeFile ⟨bundleDir ++ "/source/" ++ baseName st.inputPath⟩ st.source
  for (path, content) in st.sourceMap do
    let name := baseName path
    if !name.isEmpty then
      IO.FS.writeFile ⟨bundleDir ++ "/source/" ++ name⟩ content

  -- Diagnostics
  if !st.diagnostics.isEmpty then
    let rendered := renderDiagnostics st.diagnostics (sourceMap := st.sourceMap)
    IO.FS.writeFile ⟨bundleDir ++ "/diagnostics.txt"⟩ rendered

  -- Core IR
  if let some modules := st.coreModules then
    let coreStr := modules.foldl (fun acc m => acc ++ ppCModule m ++ "\n") ""
    IO.FS.writeFile ⟨bundleDir ++ "/core.txt"⟩ coreStr

  -- SSA IR
  if let some modules := st.ssaModules then
    let ssaStr := modules.foldl (fun acc m => acc ++ ppSModule m ++ "\n") ""
    IO.FS.writeFile ⟨bundleDir ++ "/ssa.txt"⟩ ssaStr

  -- LLVM IR
  if let some ir := st.llvmIR then
    IO.FS.writeFile ⟨bundleDir ++ "/llvm.ll"⟩ ir

  -- ProofCore consistency
  if let some pc := st.proofCore then
    let violations := pc.selfCheck
    IO.FS.writeFile ⟨bundleDir ++ "/consistency.txt"⟩ (ConsistencyViolation.render violations)

  -- Verifier results
  if !st.verifyDs.isEmpty then
    IO.FS.writeFile ⟨bundleDir ++ "/verify.txt"⟩ (renderVerifyDiagnostics st.verifyDs)
where
  baseName (path : String) : String :=
    match path.splitOn "/" |>.reverse with
    | name :: _ => name
    | [] => path

/-- Load proof registry, returning empty list on failure. -/
private def loadProofRegistry (inputPath : String) : IO ProofRegistry := do
  let dir := match inputPath.splitOn "/" |>.reverse with
    | _ :: rest => "/".intercalate rest.reverse
    | [] => "."
  let regPath := dir ++ "/proof-registry.json"
  try
    let content ← IO.FS.readFile ⟨regPath⟩
    let (registry, _warnings) := parseRegistryJson content
    return registry
  catch _ => return []

/-- Run the full pipeline, capturing state at each stage.
    Returns the bundle state (which may represent a failure at any point). -/
partial def capturePipeline (inputPath source : String)
    (resolveAllModules : String → List Module → String → IO (Except String (List Module × SourceMap)))
    : IO BundleState := do
  let srcMap0 : SourceMap := [(inputPath, source)]
  let mk (stage : CaptureStage) (ds : Diagnostics) (extras : BundleState → BundleState := id) : BundleState :=
    extras { inputPath, source, sourceMap := srcMap0, failStage := some stage, diagnostics := ds }

  -- Parse
  match Pipeline.parse source with
  | .error ds => return mk .parse ds
  | .ok parsed =>

  -- Resolve files
  let baseDir := match inputPath.splitOn "/" |>.reverse with
    | _ :: rest => "/".intercalate rest.reverse
    | [] => "."
  match ← Pipeline.resolveFiles baseDir parsed inputPath resolveAllModules with
  | .error ds => return mk .resolve ds
  | .ok (resolved, subSrcMap) =>

  let srcMap := srcMap0 ++ subSrcMap
  let summary := Pipeline.buildSummary resolved

  -- Resolve names
  match Pipeline.resolve resolved summary with
  | .error ds => return mk .resolve ds (fun s => { s with sourceMap := srcMap })
  | .ok resolvedProg =>

  -- Check
  match Pipeline.check resolvedProg summary with
  | .error ds => return mk .check ds (fun s => { s with sourceMap := srcMap })
  | .ok () =>

  -- Elaborate
  match Pipeline.elaborate resolvedProg summary with
  | .error ds => return mk .elaborate ds (fun s => { s with sourceMap := srcMap })
  | .ok elabProg =>

  -- CoreCheck
  match Pipeline.coreCheck elabProg with
  | .error ds => return mk .coreCheck ds (fun s => { s with sourceMap := srcMap })
  | .ok validCore =>

  -- ProofCore (non-blocking)
  let locMap := Report.buildFnLocMap resolved.modules inputPath
  let simpleLocMap := locMap.map fun e => (e.qualName, (e.file, e.fnSpan.line))
  let registry ← loadProofRegistry inputPath
  let pc := extractProofCore validCore simpleLocMap registry

  -- Verifier (non-blocking)
  let elabDs := Pipeline.verifyPostElab validCore.coreModules

  let base : BundleState :=
    { inputPath := inputPath
      source := source
      sourceMap := srcMap
      coreModules := some validCore.coreModules
      proofCore := some pc
      verifyDs := elabDs }

  -- Monomorphize
  match Pipeline.monomorphize validCore with
  | .error ds => return { base with failStage := some .mono, diagnostics := ds }
  | .ok mono =>

  -- Lower
  match Pipeline.lower mono with
  | .error ds =>
      return { base with
        failStage := some .lower
        monoModules := some mono.coreModules
        diagnostics := ds }
  | .ok ssa =>

  -- Emit
  let llvmIR := Pipeline.emit ssa

  -- Complete (no failure)
  return { base with
    monoModules := some mono.coreModules
    ssaModules := some ssa.ssaModules
    llvmIR := some llvmIR }

end Concrete.DebugBundle
