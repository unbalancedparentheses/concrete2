import Concrete

open Concrete

def usage : String :=
  "Usage: concrete <file.con> [-o output] [--emit-llvm] [--emit-core] [--emit-ssa] [--report caps|unsafe|layout|interface|mono]"

def writeFile (path : String) (content : String) : IO Unit := do
  IO.FS.writeFile ⟨path⟩ content

def readFile (path : String) : IO String := do
  IO.FS.readFile ⟨path⟩

def runCmd (cmd : String) (args : Array String) : IO UInt32 := do
  let child ← IO.Process.spawn {
    cmd := cmd
    args := args
    stdout := .piped
    stderr := .piped
  }
  let exitCode ← child.wait
  if exitCode != 0 then
    let stderr ← child.stderr.readToEnd
    IO.eprintln stderr
  return exitCode

/-- Check if a module is an empty stub from `mod X;` declaration. -/
def isModuleStub (m : Module) : Bool :=
  m.functions.isEmpty && m.structs.isEmpty && m.enums.isEmpty &&
  m.imports.isEmpty && m.implBlocks.isEmpty && m.traits.isEmpty &&
  m.traitImpls.isEmpty && m.constants.isEmpty && m.typeAliases.isEmpty &&
  m.externFns.isEmpty && m.newtypes.isEmpty && m.submodules.isEmpty

/-- Get directory of a file path. -/
def dirOf (path : String) : String :=
  let parts := path.splitOn "/"
  match parts.reverse with
  | _ :: rest => "/".intercalate rest.reverse
  | [] => "."

/-- Resolve `mod X;` declarations by reading X.con files from the same directory.
    Detects circular imports via parsedPaths. -/
partial def resolveModules (baseDir : String) (m : Module) (parsedPaths : List String)
    : IO (Except String (Module × List String)) := do
  let mut resolvedSubs : List Module := []
  let mut paths := parsedPaths
  for sub in m.submodules do
    if isModuleStub sub then
      let filePath := if baseDir == "" then sub.name ++ ".con"
                      else baseDir ++ "/" ++ sub.name ++ ".con"
      if paths.contains filePath then
        return .error s!"circular module import: {filePath}"
      let source ← try
        readFile filePath
      catch _ =>
        return .error s!"module file not found: {filePath}"
      match parse source with
      | .error e => return .error s!"error in module '{sub.name}': {e}"
      | .ok subModules =>
        match subModules with
        | [subMod] =>
          paths := paths ++ [filePath]
          match ← resolveModules baseDir { subMod with name := sub.name } paths with
          | .ok (resolved, newPaths) =>
            paths := newPaths
            resolvedSubs := resolvedSubs ++ [resolved]
          | .error e => return .error e
        | _ => return .error s!"module file '{filePath}' must contain exactly one module"
    else
      -- Inline module (mod X { ... }), recurse to resolve nested stubs
      match ← resolveModules baseDir sub paths with
      | .ok (resolved, newPaths) =>
        paths := newPaths
        resolvedSubs := resolvedSubs ++ [resolved]
      | .error e => return .error e
  return .ok ({ m with submodules := resolvedSubs }, paths)

/-- Resolve all modules in a program. -/
def resolveAllModules (baseDir : String) (modules : List Module) (inputPath : String)
    : IO (Except String (List Module)) := do
  let mut resolved : List Module := []
  let mut paths : List String := [inputPath]
  for m in modules do
    match ← resolveModules baseDir m paths with
    | .ok (rm, newPaths) =>
      paths := newPaths
      resolved := resolved ++ [rm]
    | .error e => return .error e
  return .ok resolved

/-- Compile via SSA pipeline: Parse → Resolve → Check → Elab → CoreCanonicalize → CoreCheck → Mono → Lower → SSAVerify → SSACleanup → EmitSSA → clang -/
def compileSSA (inputPath : String) (outputPath : String) (emitLLVM : Bool) : IO UInt32 := do
  let source ← readFile inputPath
  match ← Pipeline.runFrontend inputPath source resolveAllModules with
  | .error ds =>
    IO.eprintln (renderDiagnostics ds)
    return 1
  | .ok (_, _, elabProg) =>
  match Pipeline.monomorphize elabProg with
  | .error ds =>
    IO.eprintln (renderDiagnostics ds)
    return 1
  | .ok mono =>
  match Pipeline.lower mono with
  | .error ds =>
    IO.eprintln (renderDiagnostics ds)
    return 1
  | .ok ssa =>
    let llvmIR := Pipeline.emit ssa
    let llPath := inputPath ++ ".ll"
    writeFile llPath llvmIR
    if emitLLVM then
      IO.println llvmIR
      return 0
    -- Compile with clang
    let exitCode ← runCmd "clang" #[llPath, "-o", outputPath, "-Wno-override-module"]
    if exitCode != 0 then
      IO.eprintln "clang compilation failed"
      return exitCode
    -- Clean up .ll file
    IO.FS.removeFile ⟨llPath⟩
    IO.println s!"Compiled {inputPath} -> {outputPath}"
    return 0

/-- Emit Core or SSA IR for inspection. Runs full pipeline including new passes. -/
def compileAndEmit (inputPath : String) (mode : String) : IO UInt32 := do
  let source ← readFile inputPath
  match ← Pipeline.runFrontend inputPath source resolveAllModules with
  | .error ds =>
    IO.eprintln (renderDiagnostics ds)
    return 1
  | .ok (_, _, elabProg) =>
    if mode == "core" then
      for cm in elabProg.coreModules do
        IO.println (ppCModule cm)
      return 0
    match Pipeline.monomorphize elabProg with
    | .error ds =>
      IO.eprintln (renderDiagnostics ds)
      return 1
    | .ok mono =>
    match Pipeline.lower mono with
    | .error ds =>
      IO.eprintln (renderDiagnostics ds)
      return 1
    | .ok ssa =>
      for sm in ssa.ssaModules do
        IO.println (ppSModule sm)
      return 0

/-- Run pipeline to needed depth and produce a report. -/
def compileAndReport (inputPath : String) (reportType : String) : IO UInt32 := do
  let source ← readFile inputPath
  -- Interface report only needs parse + resolveFiles + summary
  if reportType == "interface" then
    match Pipeline.parse source with
    | .error ds =>
      IO.eprintln (renderDiagnostics ds)
      return 1
    | .ok parsed =>
    match ← Pipeline.resolveFiles (dirOf inputPath) parsed inputPath resolveAllModules with
    | .error ds =>
      IO.eprintln (renderDiagnostics ds)
      return 1
    | .ok resolved =>
      let summary := Pipeline.buildSummary resolved
      IO.println (Report.interfaceReport summary.entries)
      return 0
  -- All other reports need the full frontend
  match ← Pipeline.runFrontend inputPath source resolveAllModules with
  | .error ds =>
    IO.eprintln (renderDiagnostics ds)
    return 1
  | .ok (_, _, elabProg) =>
    if reportType == "caps" then
      IO.println (Report.capabilityReport elabProg.coreModules)
      return 0
    if reportType == "unsafe" then
      IO.println (Report.unsafeReport elabProg.coreModules)
      return 0
    if reportType == "layout" then
      IO.println (Report.layoutReport elabProg.coreModules)
      return 0
    if reportType == "mono" then
      match Pipeline.monomorphize elabProg with
      | .error ds =>
        IO.eprintln (renderDiagnostics ds)
        return 1
      | .ok mono =>
        IO.println (Report.monoReport elabProg.coreModules mono.coreModules)
        return 0
    IO.eprintln s!"Unknown report type: {reportType}. Use: caps, unsafe, layout, interface, mono"
    return 1

def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    IO.eprintln usage
    return 1
  | [inputPath] =>
    let outputPath := if inputPath.endsWith ".con" then String.ofList (inputPath.toList.take (inputPath.length - 4)) else inputPath ++ ".out"
    compileSSA inputPath outputPath false
  | [inputPath, "--emit-llvm"] =>
    compileSSA inputPath "" true
  | [inputPath, "--emit-core"] =>
    compileAndEmit inputPath "core"
  | [inputPath, "--emit-ssa"] =>
    compileAndEmit inputPath "ssa"
  | [inputPath, "-o", outputPath] =>
    compileSSA inputPath outputPath false
  | [inputPath, "--report", reportType] =>
    compileAndReport inputPath reportType
  | _ =>
    IO.eprintln usage
    return 1
