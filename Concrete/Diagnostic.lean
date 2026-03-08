import Concrete.Token

namespace Concrete

/-! ## Diagnostic — structured compiler diagnostics

Provides a uniform error/warning reporting infrastructure across all compiler passes.
-/

-- ============================================================
-- Diagnostic types
-- ============================================================

inductive Severity where
  | error
  | warning
  | note
  deriving BEq

structure Diagnostic where
  severity : Severity
  message  : String
  pass     : String         -- "check", "elab", "ssa-verify", etc.
  span     : Option Span    -- line/col from Token.lean
  hint     : Option String  -- suggested fix

abbrev Diagnostics := List Diagnostic

-- ============================================================
-- Rendering
-- ============================================================

private def severityStr : Severity → String
  | .error   => "error"
  | .warning => "warning"
  | .note    => "note"

def Diagnostic.render (d : Diagnostic) : String :=
  let locStr := match d.span with
    | some sp => s!"{sp.line}:{sp.col}: "
    | none => ""
  let hintStr := match d.hint with
    | some h => s!"\n  hint: {h}"
    | none => ""
  s!"{locStr}{severityStr d.severity}[{d.pass}]: {d.message}{hintStr}"

def renderDiagnostics (ds : Diagnostics) : String :=
  "\n".intercalate (ds.map Diagnostic.render)

-- ============================================================
-- Queries
-- ============================================================

def hasErrors (ds : Diagnostics) : Bool :=
  ds.any fun d => d.severity == .error

-- ============================================================
-- Lift helpers
-- ============================================================

/-- Convert an `Except String α` into `Except Diagnostics α`. -/
def liftStringError (pass : String) : Except String α → Except Diagnostics α
  | .ok a => .ok a
  | .error msg => .error [{ severity := .error, message := msg, pass := pass, span := none, hint := none }]

end Concrete
