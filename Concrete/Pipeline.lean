import Concrete.AST
import Concrete.Diagnostic
import Concrete.FileSummary
import Concrete.Resolve
import Concrete.Parser
import Concrete.Check
import Concrete.Core
import Concrete.Elab
import Concrete.CoreCanonicalize
import Concrete.CoreCheck
import Concrete.Mono
import Concrete.SSA
import Concrete.Lower
import Concrete.SSAVerify
import Concrete.SSACleanup
import Concrete.EmitSSA

namespace Concrete

/-! ## Pipeline — cacheable compiler artifacts

Each pipeline stage produces a named artifact type.
Runner functions wrap the underlying pass with `liftStringError` / diagnostic handling.
No serialization yet — these types are the prerequisite for future `ToJson`/`FromJson` instances.
-/

-- ============================================================
-- Artifact types
-- ============================================================

structure ParsedProgram where
  modules : List Module

structure SummaryTable where
  entries : List (String × FileSummary)

structure ResolvedProgram where
  modules : List ResolvedModule

structure ElaboratedProgram where
  coreModules : List CModule

structure MonomorphizedProgram where
  coreModules : List CModule

structure SSAProgram where
  ssaModules : List SModule

-- ============================================================
-- Pipeline runner functions
-- ============================================================

namespace Pipeline

/-- Parse source code into a `ParsedProgram`. -/
def parse (source : String) : Except Diagnostics ParsedProgram :=
  match liftStringError "parse" (Concrete.parse source) with
  | .ok modules => .ok { modules }
  | .error ds => .error ds

/-- Resolve `mod X;` declarations by reading sub-module files from disk.
    Wraps `resolveAllModules` (IO because it reads files). -/
def resolveFiles (baseDir : String) (prog : ParsedProgram) (inputPath : String)
    (resolveAllModules : String → List Module → String → IO (Except String (List Module)))
    : IO (Except Diagnostics ParsedProgram) := do
  match ← resolveAllModules baseDir prog.modules inputPath with
  | .error e =>
    return .error [{ severity := .error, message := e, pass := "resolve", span := none, hint := none }]
  | .ok modules =>
    return .ok { modules }

/-- Build the cross-file summary table from parsed modules. -/
def buildSummary (prog : ParsedProgram) : SummaryTable :=
  { entries := buildSummaryTable prog.modules }

/-- Name-resolution pass: validates all identifiers and imports. -/
def resolve (prog : ParsedProgram) (summary : SummaryTable) : Except Diagnostics ResolvedProgram :=
  match resolveProgram prog.modules summary.entries with
  | .ok resolved => .ok { modules := resolved }
  | .error ds => .error ds

/-- Type-checking pass. -/
def check (prog : ParsedProgram) (summary : SummaryTable) : Except Diagnostics Unit :=
  liftStringError "check" (checkProgram prog.modules summary.entries)

/-- Elaborate, canonicalize, and core-check in one step. -/
def elaborate (prog : ParsedProgram) (summary : SummaryTable) : Except Diagnostics ElaboratedProgram :=
  match liftStringError "elab" (elabProgram prog.modules summary.entries) with
  | .error ds => .error ds
  | .ok coreModules =>
    let coreModules := canonicalizeProgram coreModules
    match liftStringError "core-check" (coreCheckProgram coreModules) with
    | .error ds => .error ds
    | .ok () => .ok { coreModules }

/-- Monomorphize generic functions. -/
def monomorphize (elabProg : ElaboratedProgram) : Except Diagnostics MonomorphizedProgram :=
  match liftStringError "mono" (monoProgram elabProg.coreModules) with
  | .ok modules => .ok { coreModules := modules }
  | .error ds => .error ds

/-- Lower to SSA, verify, and clean up. -/
def lower (mono : MonomorphizedProgram) : Except Diagnostics SSAProgram :=
  let ssaModules := mono.coreModules.map lowerModule
  match liftStringError "ssa-verify" (ssaVerifyProgram ssaModules) with
  | .error ds => .error ds
  | .ok () =>
    let ssaModules := ssaCleanupProgram ssaModules
    .ok { ssaModules }

/-- Emit LLVM IR from SSA modules. -/
def emit (ssa : SSAProgram) : String :=
  emitSSAProgram ssa.ssaModules

-- ============================================================
-- Shared frontend helper
-- ============================================================

/-- Run the shared frontend: parse → resolveFiles → buildSummary → resolve → check → elaborate.
    This is the common prefix of all three CLI entry points (except interface report). -/
def runFrontend (inputPath source : String)
    (resolveAllModules : String → List Module → String → IO (Except String (List Module)))
    : IO (Except Diagnostics (ParsedProgram × SummaryTable × ElaboratedProgram)) := do
  match Pipeline.parse source with
  | .error ds => return .error ds
  | .ok parsed =>
  let baseDir := let parts := inputPath.splitOn "/"
    match parts.reverse with
    | _ :: rest => "/".intercalate rest.reverse
    | [] => "."
  match ← Pipeline.resolveFiles baseDir parsed inputPath resolveAllModules with
  | .error ds => return .error ds
  | .ok resolved =>
    let summary := Pipeline.buildSummary resolved
    match Pipeline.resolve resolved summary with
    | .error ds => return .error ds
    | .ok _ =>
    match Pipeline.check resolved summary with
    | .error ds => return .error ds
    | .ok () =>
    match Pipeline.elaborate resolved summary with
    | .error ds => return .error ds
    | .ok elabProg => return .ok (resolved, summary, elabProg)

end Pipeline
end Concrete
