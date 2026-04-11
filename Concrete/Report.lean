import Concrete.Core
import Concrete.Layout
import Concrete.FileSummary
import Concrete.AST
import Concrete.Intrinsic
import Concrete.Proof
import Concrete.ProofCore
import Concrete.SSA
import Concrete.Diagnostic

namespace Concrete
namespace Report

-- ============================================================
-- Proof registry: artifact-backed proof attachment
-- ============================================================

/-- A single proof registry entry linking a Concrete function to its proof. -/
structure ProofRegistryEntry where
  function        : String  -- qualified name, e.g. "main.parse_byte"
  bodyFingerprint : String  -- expected body fingerprint
  proof           : String  -- Lean proof name, e.g. "Concrete.Proof.parse_byte_correct"
  spec            : String  -- spec name, e.g. "parse_byte_adds_offset"
  deriving Repr, Inhabited

/-- A proof registry is a list of proof attachment entries. -/
abbrev ProofRegistry := List ProofRegistryEntry

/-- Parse a proof registry from a JSON string.
    Expected format:
    { "version": 1, "proofs": [ { "function": "...", "body_fingerprint": "...", "proof": "...", "spec": "..." }, ... ] }
    Minimal parser: extracts string fields from each object in the "proofs" array.
    Returns empty list on any parse error. -/
def parseRegistryJson (input : String) : ProofRegistry :=
  -- Tiny targeted extractor: find all {...} blocks inside "proofs": [...]
  -- Strategy: split by "function" key occurrences, extract fields from each block
  let extractStr (block : String) (key : String) : String :=
    let needle := s!"\"{key}\":"
    match block.splitOn needle with
    | [_, rest] =>
      let rest := rest.trimAsciiStart
      if rest.startsWith "\"" then
        let inner := (rest.drop 1).toString.splitOn "\"" |>.head!
        inner
      else ""
    | _ => ""
  -- Split into proof entry blocks by looking for "function" key occurrences
  let blocks := input.splitOn "\"function\":"
  -- Skip the first part (everything before first entry)
  let entryBlocks := blocks.drop 1
  entryBlocks.filterMap fun block =>
    let fn := extractStr ("\"function\":" ++ block) "function"
    let fp := extractStr block "body_fingerprint"
    let pr := extractStr block "proof"
    let sp := extractStr block "spec"
    if fn.isEmpty then none
    else some { function := fn, bodyFingerprint := fp, proof := pr, spec := sp }

-- ============================================================
-- Source location lookup
-- ============================================================

/-- Structured source location: (file, line). -/
abbrev SourceLoc := String × Nat

/-- Per-function parsed AST info for span lookups. -/
structure FnLocEntry where
  qualName : String
  file     : String
  fnSpan   : Span
  body     : List Stmt      -- parsed AST body (carries spans on every node)

/-- Map from qualified function name to location + parsed body. -/
abbrev FnLocMap := List FnLocEntry

/-- Collect function locations from a parsed AST module tree. -/
partial def buildFnLocMap (modules : List Module) (file : String) (pfx : String := "") : FnLocMap :=
  modules.foldl (fun acc m =>
    let qualPrefix := if pfx == "" then m.name else pfx ++ "." ++ m.name
    let fnLocs := m.functions.map fun f =>
      { qualName := qualPrefix ++ "." ++ f.name, file, fnSpan := f.span, body := f.body }
    let implLocs := m.implBlocks.foldl (fun acc2 ib =>
      acc2 ++ ib.methods.map fun f =>
        { qualName := qualPrefix ++ "." ++ f.name, file, fnSpan := f.span, body := f.body }) []
    let traitImplLocs := m.traitImpls.foldl (fun acc2 ti =>
      acc2 ++ ti.methods.map fun f =>
        { qualName := qualPrefix ++ "." ++ f.name, file, fnSpan := f.span, body := f.body }) []
    let subLocs := buildFnLocMap m.submodules file qualPrefix
    acc ++ fnLocs ++ implLocs ++ traitImplLocs ++ subLocs) []

/-- Look up a function's source location. -/
def lookupLoc (locMap : FnLocMap) (qualName : String) : Option SourceLoc :=
  match locMap.find? fun e => e.qualName == qualName with
  | some e => some (e.file, e.fnSpan.line)
  | none => none

/-- Look up a function's parsed body for violation-span extraction. -/
def lookupBody (locMap : FnLocMap) (qualName : String) : Option FnLocEntry :=
  locMap.find? fun e => e.qualName == qualName

/-- Format a source location as "file:line". -/
def fmtLoc : Option SourceLoc → String
  | some (file, line) => s!"{file}:{line}"
  | none => ""

-- ============================================================
-- Violation-span extraction from parsed AST
-- ============================================================

/-- Find the first while/for loop span in a parsed statement list. -/
partial def findLoopSpan : List Stmt → Option Span
  | [] => none
  | s :: rest =>
    match s with
    | .while_ sp _ _ _ => some sp
    | .forLoop sp _ _ _ _ _ => some sp
    | .ifElse _ _ thenB (some elseB) =>
      findLoopSpan thenB |>.orElse fun _ => findLoopSpan elseB |>.orElse fun _ => findLoopSpan rest
    | .ifElse _ _ thenB none =>
      findLoopSpan thenB |>.orElse fun _ => findLoopSpan rest
    | .borrowIn _ _ _ _ _ body =>
      findLoopSpan body |>.orElse fun _ => findLoopSpan rest
    | _ => findLoopSpan rest

/-- Find the span of the first call to any of the given function names. -/
partial def findCallSpan (targets : List String) : List Stmt → Option Span
  | [] => none
  | s :: rest =>
    let fromExprs := findCallSpanExpr targets s
    match fromExprs with
    | some sp => some sp
    | none => findCallSpan targets rest
where
  findCallSpanExpr (targets : List String) : Stmt → Option Span
    | .expr _ e => findCallSpanInExpr targets e
    | .letDecl _ _ _ _ e => findCallSpanInExpr targets e
    | .assign _ _ e => findCallSpanInExpr targets e
    | .return_ _ (some e) => findCallSpanInExpr targets e
    | .ifElse _ cond thenB (some elseB) =>
      findCallSpanInExpr targets cond
      |>.orElse fun _ => findCallSpan targets thenB
      |>.orElse fun _ => findCallSpan targets elseB
    | .ifElse _ cond thenB none =>
      findCallSpanInExpr targets cond
      |>.orElse fun _ => findCallSpan targets thenB
    | .while_ _ cond body _ =>
      findCallSpanInExpr targets cond
      |>.orElse fun _ => findCallSpan targets body
    | .forLoop _ _ cond _ body _ =>
      findCallSpanInExpr targets cond
      |>.orElse fun _ => findCallSpan targets body
    | .borrowIn _ _ _ _ _ body => findCallSpan targets body
    | _ => none
  findCallSpanInExpr (targets : List String) : Expr → Option Span
    | .call sp fn _ args => if targets.contains fn then some sp
      else args.foldl (fun acc a => acc.orElse fun _ => findCallSpanInExpr targets a) none
    | .methodCall _ _ _ _ args => args.foldl (fun acc a => acc.orElse fun _ => findCallSpanInExpr targets a) none
    | .binOp _ _ l r => (findCallSpanInExpr targets l).orElse fun _ => findCallSpanInExpr targets r
    | .unaryOp _ _ e => findCallSpanInExpr targets e
    | .ifExpr _ cond thenB elseB => (findCallSpanInExpr targets cond).orElse fun _ =>
        (findCallSpan targets thenB).orElse fun _ => findCallSpan targets elseB
    | _ => none

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
-- Body fingerprinting (proof identity verification)
-- ============================================================
-- Produces a canonical string from CExpr/CStmt structure.
-- Used to verify that a function's body matches the PExpr
-- encoding in Proof.lean. If the body changes, the fingerprint
-- changes, and "proved" evidence is revoked.

private partial def fingerprintExpr : CExpr → String
  | .intLit v _ => s!"(int {v})"
  | .floatLit v _ => s!"(float {v})"
  | .boolLit v => s!"(bool {v})"
  | .strLit v => s!"(str {repr v})"
  | .charLit v => s!"(char {repr v})"
  | .ident name _ => s!"(var {name})"
  | .binOp op lhs rhs _ => s!"(binop {repr op} {fingerprintExpr lhs} {fingerprintExpr rhs})"
  | .unaryOp op inner _ => s!"(unary {repr op} {fingerprintExpr inner})"
  | .call fn _ args _ => s!"(call {fn} {fingerprintExprs args})"
  | .structLit name _ fields _ =>
    let fs := fields.map fun (n, e) => s!"{n}={fingerprintExpr e}"
    s!"(struct {name} {" ".intercalate fs})"
  | .fieldAccess obj field _ => s!"(field {fingerprintExpr obj} {field})"
  | .enumLit en v _ fields _ =>
    let fs := fields.map fun (n, e) => s!"{n}={fingerprintExpr e}"
    s!"(enum {en}::{v} {" ".intercalate fs})"
  | .match_ scr arms _ =>
    let as_ := arms.map fingerprintArm
    s!"(match {fingerprintExpr scr} {" ".intercalate as_})"
  | .borrow inner _ => s!"(borrow {fingerprintExpr inner})"
  | .borrowMut inner _ => s!"(borrowmut {fingerprintExpr inner})"
  | .deref inner _ => s!"(deref {fingerprintExpr inner})"
  | .arrayLit elems _ => s!"(array {fingerprintExprs elems})"
  | .arrayIndex arr idx _ => s!"(index {fingerprintExpr arr} {fingerprintExpr idx})"
  | .cast inner ty => s!"(cast {fingerprintExpr inner} {repr ty})"
  | .fnRef name _ => s!"(fnref {name})"
  | .try_ inner _ => s!"(try {fingerprintExpr inner})"
  | .allocCall inner alloc _ => s!"(alloc {fingerprintExpr inner} {fingerprintExpr alloc})"
  | .whileExpr cond body els _ => s!"(while {fingerprintExpr cond} {fingerprintStmts body} {fingerprintStmts els})"
  | .ifExpr cond th el _ => s!"(if {fingerprintExpr cond} {fingerprintStmts th} {fingerprintStmts el})"
where
  fingerprintExprs (es : List CExpr) : String :=
    " ".intercalate (es.map fingerprintExpr)
  fingerprintArm : CMatchArm → String
    | .enumArm en v binds body => s!"(arm {en}::{v} [{" ".intercalate (binds.map Prod.fst)}] {fingerprintStmts body})"
    | .litArm val body => s!"(lit {fingerprintExpr val} {fingerprintStmts body})"
    | .varArm b _ body => s!"(var {b} {fingerprintStmts body})"
  fingerprintStmt : CStmt → String
    | .letDecl name _ _ val => s!"(let {name} {fingerprintExpr val})"
    | .assign name val => s!"(set {name} {fingerprintExpr val})"
    | .return_ (some val) _ => s!"(ret {fingerprintExpr val})"
    | .return_ none _ => "(ret)"
    | .expr e => fingerprintExpr e
    | .ifElse cond th (some el) => s!"(if {fingerprintExpr cond} {fingerprintStmts th} {fingerprintStmts el})"
    | .ifElse cond th none => s!"(if {fingerprintExpr cond} {fingerprintStmts th})"
    | .while_ cond body _ step => s!"(while {fingerprintExpr cond} {fingerprintStmts body} {fingerprintStmts step})"
    | .fieldAssign obj f val => s!"(setfield {fingerprintExpr obj} {f} {fingerprintExpr val})"
    | .derefAssign tgt val => s!"(setderef {fingerprintExpr tgt} {fingerprintExpr val})"
    | .arrayIndexAssign arr idx val => s!"(setindex {fingerprintExpr arr} {fingerprintExpr idx} {fingerprintExpr val})"
    | .break_ _ lbl => s!"(break {lbl})"
    | .continue_ lbl => s!"(continue {lbl})"
    | .defer body => s!"(defer {fingerprintExpr body})"
    | .borrowIn v r rg m _ body => s!"(borrowin {v} {r} {rg} {m} {fingerprintStmts body})"
  fingerprintStmts (ss : List CStmt) : String :=
    "[" ++ " ".intercalate (ss.map fingerprintStmt) ++ "]"

/-- Compute a body fingerprint for proof identity verification. -/
def bodyFingerprint (body : List CStmt) : String :=
  fingerprintStmts body
where
  fingerprintStmts (ss : List CStmt) : String :=
    "[" ++ " ".intercalate (ss.map fingerprintStmt) ++ "]"
  fingerprintStmt := fingerprintExpr.fingerprintStmt
  fingerprintExpr := Report.fingerprintExpr

/-- Print body fingerprints for all functions (development tool). -/
partial def fingerprintReport (modules : List CModule) : String :=
  let allFns := modules.foldl (fun acc m => acc ++ collectQualFns "" m) []
  let lines := allFns.map fun (qn, f) =>
    let fp := bodyFingerprint f.body
    s!"  {qn}: \"{fp}\""
  "=== Body Fingerprints ===\n" ++ "\n".intercalate lines ++ "\n"
where
  collectQualFns (pfx : String) (m : CModule) : List (String × CFnDef) :=
    let qp := if pfx == "" then m.name else pfx ++ "." ++ m.name
    let fns := m.functions.map fun f => (qp ++ "." ++ f.name, f)
    fns ++ m.submodules.foldl (fun acc sub => acc ++ collectQualFns qp sub) []

-- ============================================================
-- Body-walking infrastructure
-- ============================================================
-- Shared recursive traversal of Core IR (CExpr/CStmt/CMatchArm)
-- for collecting call sites, defer nodes, pointer ops, etc.

/-- A call site found in a function body. -/
structure CallSite where
  callee : String
  deriving BEq

/-- Info about allocation-related activity in a function body. -/
structure AllocInfo where
  allocCalls : List String   -- intrinsic names: alloc, vec_new, etc.
  freeCalls  : List String   -- intrinsic names: free, destroy, vec_free, etc.
  deferExprs : List String   -- descriptions of deferred expressions
  hasAllocCall : Bool        -- CExpr.allocCall node (with(Alloc = ...))

mutual
partial def collectCallsExpr (e : CExpr) : List String :=
  match e with
  | .call fn _ args _ => [fn] ++ args.foldl (fun acc a => acc ++ collectCallsExpr a) []
  | .binOp _ l r _ => collectCallsExpr l ++ collectCallsExpr r
  | .unaryOp _ e _ => collectCallsExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectCallsExpr v) []
  | .fieldAccess obj _ _ => collectCallsExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectCallsExpr v) []
  | .match_ scrut arms _ => collectCallsExpr scrut ++ arms.foldl (fun acc a => acc ++ collectCallsArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectCallsExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectCallsExpr e) []
  | .arrayIndex arr idx _ => collectCallsExpr arr ++ collectCallsExpr idx
  | .cast inner _ | .try_ inner _ => collectCallsExpr inner
  | .allocCall inner alloc _ => collectCallsExpr inner ++ collectCallsExpr alloc
  | .whileExpr cond body elseBody _ =>
    collectCallsExpr cond ++ collectCallsStmts body ++ collectCallsStmts elseBody
  | _ => []  -- intLit, floatLit, boolLit, strLit, charLit, ident, fnRef

partial def collectCallsArm (arm : CMatchArm) : List String :=
  match arm with
  | .enumArm _ _ _ body => collectCallsStmts body
  | .litArm v body => collectCallsExpr v ++ collectCallsStmts body
  | .varArm _ _ body => collectCallsStmts body

partial def collectCallsStmt (s : CStmt) : List String :=
  match s with
  | .letDecl _ _ _ v => collectCallsExpr v
  | .assign _ v => collectCallsExpr v
  | .return_ (some v) _ => collectCallsExpr v
  | .return_ none _ => []
  | .expr e => collectCallsExpr e
  | .ifElse c t el =>
    collectCallsExpr c ++ collectCallsStmts t ++
    match el with | some stmts => collectCallsStmts stmts | none => []
  | .while_ c body _ step =>
    collectCallsExpr c ++ collectCallsStmts body ++ collectCallsStmts step
  | .fieldAssign obj _ v => collectCallsExpr obj ++ collectCallsExpr v
  | .derefAssign t v => collectCallsExpr t ++ collectCallsExpr v
  | .arrayIndexAssign arr idx v =>
    collectCallsExpr arr ++ collectCallsExpr idx ++ collectCallsExpr v
  | .break_ (some v) _ => collectCallsExpr v
  | .break_ none _ | .continue_ _ => []
  | .defer body => collectCallsExpr body
  | .borrowIn _ _ _ _ _ body => collectCallsStmts body

partial def collectCallsStmts (ss : List CStmt) : List String :=
  ss.foldl (fun acc s => acc ++ collectCallsStmt s) []

-- Defer collection

partial def collectDefersExpr (e : CExpr) : List String :=
  match e with
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ collectDefersExpr a) []
  | .binOp _ l r _ => collectDefersExpr l ++ collectDefersExpr r
  | .unaryOp _ e _ => collectDefersExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectDefersExpr v) []
  | .fieldAccess obj _ _ => collectDefersExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectDefersExpr v) []
  | .match_ scrut arms _ =>
    collectDefersExpr scrut ++ arms.foldl (fun acc a => acc ++ collectDefersArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectDefersExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectDefersExpr e) []
  | .arrayIndex arr idx _ => collectDefersExpr arr ++ collectDefersExpr idx
  | .cast inner _ | .try_ inner _ => collectDefersExpr inner
  | .allocCall inner alloc _ => collectDefersExpr inner ++ collectDefersExpr alloc
  | .whileExpr cond body elseBody _ =>
    collectDefersExpr cond ++ collectDefersStmts body ++ collectDefersStmts elseBody
  | _ => []

partial def collectDefersArm (arm : CMatchArm) : List String :=
  match arm with
  | .enumArm _ _ _ body => collectDefersStmts body
  | .litArm v body => collectDefersExpr v ++ collectDefersStmts body
  | .varArm _ _ body => collectDefersStmts body

partial def collectDefersStmt (s : CStmt) : List String :=
  match s with
  | .defer body =>
    -- Describe the deferred expression
    let desc := match body with
      | .call fn _ _ _ => s!"defer {fn}(...)"
      | _ => "defer <expr>"
    [desc] ++ collectDefersExpr body
  | .letDecl _ _ _ v => collectDefersExpr v
  | .assign _ v => collectDefersExpr v
  | .return_ (some v) _ => collectDefersExpr v
  | .return_ none _ => []
  | .expr e => collectDefersExpr e
  | .ifElse c t el =>
    collectDefersExpr c ++ collectDefersStmts t ++
    match el with | some stmts => collectDefersStmts stmts | none => []
  | .while_ c body _ step =>
    collectDefersExpr c ++ collectDefersStmts body ++ collectDefersStmts step
  | .fieldAssign obj _ v => collectDefersExpr obj ++ collectDefersExpr v
  | .derefAssign t v => collectDefersExpr t ++ collectDefersExpr v
  | .arrayIndexAssign arr idx v =>
    collectDefersExpr arr ++ collectDefersExpr idx ++ collectDefersExpr v
  | .break_ (some v) _ => collectDefersExpr v
  | .break_ none _ | .continue_ _ => []
  | .borrowIn _ _ _ _ _ body => collectDefersStmts body

partial def collectDefersStmts (ss : List CStmt) : List String :=
  ss.foldl (fun acc s => acc ++ collectDefersStmt s) []

-- Raw pointer operation detection

partial def hasRawPtrOpsExpr (e : CExpr) : Bool :=
  match e with
  | .deref inner ty =>
    match ty with
    | .ptrMut _ | .ptrConst _ => true
    | _ => hasRawPtrOpsExpr inner
  | .call _ _ args _ => args.any hasRawPtrOpsExpr
  | .binOp _ l r _ => hasRawPtrOpsExpr l || hasRawPtrOpsExpr r
  | .unaryOp _ e _ => hasRawPtrOpsExpr e
  | .structLit _ _ fields _ => fields.any (fun (_, v) => hasRawPtrOpsExpr v)
  | .fieldAccess obj _ _ => hasRawPtrOpsExpr obj
  | .enumLit _ _ _ fields _ => fields.any (fun (_, v) => hasRawPtrOpsExpr v)
  | .match_ scrut arms _ =>
    hasRawPtrOpsExpr scrut || arms.any hasRawPtrOpsArm
  | .borrow inner _ | .borrowMut inner _ => hasRawPtrOpsExpr inner
  | .arrayLit elems _ => elems.any hasRawPtrOpsExpr
  | .arrayIndex arr idx _ => hasRawPtrOpsExpr arr || hasRawPtrOpsExpr idx
  | .cast inner _ | .try_ inner _ => hasRawPtrOpsExpr inner
  | .allocCall inner alloc _ => hasRawPtrOpsExpr inner || hasRawPtrOpsExpr alloc
  | .whileExpr cond body elseBody _ =>
    hasRawPtrOpsExpr cond || hasRawPtrOpsStmts body || hasRawPtrOpsStmts elseBody
  | _ => false

partial def hasRawPtrOpsArm (arm : CMatchArm) : Bool :=
  match arm with
  | .enumArm _ _ _ body => hasRawPtrOpsStmts body
  | .litArm v body => hasRawPtrOpsExpr v || hasRawPtrOpsStmts body
  | .varArm _ _ body => hasRawPtrOpsStmts body

partial def hasRawPtrOpsStmt (s : CStmt) : Bool :=
  match s with
  | .derefAssign _ _ => true
  | .letDecl _ _ _ v => hasRawPtrOpsExpr v
  | .assign _ v => hasRawPtrOpsExpr v
  | .return_ (some v) _ => hasRawPtrOpsExpr v
  | .return_ none _ => false
  | .expr e => hasRawPtrOpsExpr e
  | .ifElse c t el =>
    hasRawPtrOpsExpr c || hasRawPtrOpsStmts t ||
    match el with | some stmts => hasRawPtrOpsStmts stmts | none => false
  | .while_ c body _ step =>
    hasRawPtrOpsExpr c || hasRawPtrOpsStmts body || hasRawPtrOpsStmts step
  | .fieldAssign obj _ v => hasRawPtrOpsExpr obj || hasRawPtrOpsExpr v
  | .arrayIndexAssign arr idx v =>
    hasRawPtrOpsExpr arr || hasRawPtrOpsExpr idx || hasRawPtrOpsExpr v
  | .break_ (some v) _ => hasRawPtrOpsExpr v
  | .break_ none _ | .continue_ _ => false
  | .defer body => hasRawPtrOpsExpr body
  | .borrowIn _ _ _ _ _ body => hasRawPtrOpsStmts body

partial def hasRawPtrOpsStmts (ss : List CStmt) : Bool :=
  ss.any hasRawPtrOpsStmt
end

-- ============================================================
-- Callee CapSet lookup
-- ============================================================

/-- A flat map of function/extern names → CapSet, built once per report. -/
abbrev CapLookup := List (String × CapSet)

private partial def buildCapLookupModule (m : CModule) : CapLookup :=
  let fnEntries := m.functions.map fun f => (f.name, f.capSet)
  let externEntries := m.externFns.map fun (n, _, _, trusted) =>
    (n, if trusted then .empty else .concrete [unsafeCapName])
  fnEntries ++ externEntries ++ m.submodules.foldl (fun acc sub =>
    acc ++ buildCapLookupModule sub) []

private def buildCapLookup (modules : List CModule) : CapLookup :=
  modules.foldl (fun acc m => acc ++ buildCapLookupModule m) []

/-- Look up a callee's capability set. Checks user fns, externs, then intrinsics. -/
private def lookupCalleeCap (lookup : CapLookup) (name : String) : Option CapSet :=
  match lookup.find? (fun (n, _) => n == name) with
  | some (_, cs) => some cs
  | none =>
    match resolveIntrinsic name with
    | some iid =>
      match iid.capability with
      | some cap => some (.concrete [cap])
      | none => some .empty
    | none => none

/-- Classify a callee for display purposes. -/
private def calleeTag (lookup : CapLookup) (name : String) : String :=
  match lookup.find? (fun (n, _) => n == name) with
  | some _ => ""
  | none =>
    if (resolveIntrinsic name).isSome then " (intrinsic)"
    else " (unknown)"

-- ============================================================
-- Extern name lookup (for unsafe body analysis)
-- ============================================================

private partial def collectExternNames (m : CModule) : List String :=
  m.externFns.map (fun (n, _, _, _) => n) ++
  m.submodules.foldl (fun acc sub => acc ++ collectExternNames sub) []

-- ============================================================
-- Report 1: Capability Summary with "why" traces (--report caps)
-- ============================================================

/-- Count functions across module tree. -/
private partial def countModuleFns (m : CModule) : Nat :=
  m.functions.length + m.submodules.foldl (fun acc sub => acc + countModuleFns sub) 0

private partial def countModulePure (m : CModule) : Nat :=
  let local_ := (m.functions.filter fun f => f.capSet == .empty).length
  local_ + m.submodules.foldl (fun acc sub => acc + countModulePure sub) 0

private partial def countModuleExterns (m : CModule) : Nat :=
  m.externFns.length + m.submodules.foldl (fun acc sub => acc + countModuleExterns sub) 0

/-- Build capability "why" trace lines for a function.
    For each concrete cap the function requires, find which direct callees
    contribute that cap. -/
private def capWhyTrace (lookup : CapLookup) (f : CFnDef) (indent : String) : List String :=
  let (concreteCaps, _) := f.capSet.normalize
  if concreteCaps.isEmpty then []
  else
    let callees := collectCallsStmts f.body |>.eraseDups
    concreteCaps.filterMap fun cap =>
      -- Find callees that require this cap
      let contributors := callees.filter fun callee =>
        match lookupCalleeCap lookup callee with
        | some cs =>
          let (calleeCaps, _) := cs.normalize
          calleeCaps.contains cap
        | none => false
      let contribStr := if contributors.isEmpty then "<- declared"
        else
          let tagged := contributors.map fun c => s!"{c}{calleeTag lookup c}"
          s!"<- calls {", ".intercalate tagged}"
      some s!"{indent}    {padRight cap 10} {contribStr}"

private partial def capReportModule (lookup : CapLookup) (m : CModule) (indent : String) : String :=
  let header := s!"{indent}module {m.name}:"
  let fnLines := m.functions.foldl (fun acc f =>
    let pubStr := if f.isPublic then "pub " else "    "
    let capsStr := ppCapSet f.capSet
    let mainLine := s!"{indent}  {pubStr}{f.name} : {capsStr}"
    let traceLines := capWhyTrace lookup f indent
    acc ++ [mainLine] ++ traceLines) []
  let trustedExterns := m.externFns.filter fun (_, _, _, t) => t
  let untrustedExterns := m.externFns.filter fun (_, _, _, t) => !t
  let externLines := if untrustedExterns.isEmpty then []
    else [s!"{indent}  extern:"] ++ untrustedExterns.map fun (n, _, _, _) =>
      s!"{indent}      {n} : Unsafe"
  let externLines := externLines ++ (if trustedExterns.isEmpty then []
    else [s!"{indent}  trusted extern:"] ++ trustedExterns.map fun (n, _, _, _) =>
      s!"{indent}      {n} : (none)")
  let subLines := m.submodules.map (capReportModule lookup · (indent ++ "  "))
  let body := fnLines ++ externLines ++ subLines
  if body.isEmpty then header
  else s!"{header}\n{"\n".intercalate body}"

def capabilityReport (modules : List CModule) : String :=
  let header := "=== Capability Summary ==="
  let lookup := buildCapLookup modules
  let body := modules.map (capReportModule lookup · "")
  let totalFns := modules.foldl (fun acc m => acc + countModuleFns m) 0
  let pureFns := modules.foldl (fun acc m => acc + countModulePure m) 0
  let externCount := modules.foldl (fun acc m => acc + countModuleExterns m) 0
  let summary := s!"\nTotals: {totalFns} functions ({pureFns} pure), {externCount} externs"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 2: Unsafe Signature Summary with trust boundary
--           analysis (--report unsafe)
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

/-- Analyze what a trusted function wraps — scan its body for unsafe operations. -/
private def trustBoundaryAnalysis (externNames : List String) (f : CFnDef) : List String :=
  let callees := collectCallsStmts f.body |>.eraseDups
  let ops : List String := []
  -- Check for raw pointer operations in body
  let ops := if hasRawPtrOpsStmts f.body then ops ++ ["pointer dereference"] else ops
  -- Check for calls to extern functions
  let externCalls := callees.filter fun c => externNames.contains c
  let ops := if externCalls.isEmpty then ops
    else ops ++ externCalls.map fun c => s!"extern {c}"
  -- Check for calls to functions with Unsafe capability
  -- (this is approximate — we check if callee name contains known unsafe patterns)
  let ops := if callees.any (fun c => c == "alloc" || c == "free") then
    ops ++ ["memory management"]
  else ops
  if ops.isEmpty then ["(safe body — no raw ops detected)"]
  else ops

private partial def unsafeReportModule (externNames : List String)
    (m : CModule) (indent : String) : Option String :=
  let unsafeFns := m.functions.filter fun f => hasUnsafeCap f.capSet
  let externFns := m.externFns.filter fun (_, _, _, t) => !t
  let trustedExternFns := m.externFns.filter fun (_, _, _, t) => t
  let ptrFns := m.functions.filter fnUsesRawPtrs
  let trustedFns := m.functions.filter fun f => f.isTrusted
  let subReports := m.submodules.filterMap (unsafeReportModule externNames · (indent ++ "  "))
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
    -- Trusted boundaries with body analysis
    let trustedStandalone := trustedFns.filter fun f => f.trustedImplOrigin.isNone
    let trustedImplFns := trustedFns.filter fun f => f.trustedImplOrigin.isSome
    let trustedImplNames := (trustedImplFns.filterMap (·.trustedImplOrigin)).eraseDups
    let lines := if trustedStandalone.isEmpty && trustedImplFns.isEmpty then lines
      else
        let lines := lines ++ [s!"{indent}  Trust boundary analysis:"]
        let lines := if trustedStandalone.isEmpty then lines
          else trustedStandalone.foldl (fun lines f =>
            let ops := trustBoundaryAnalysis externNames f
            lines ++ [s!"{indent}    trusted fn {f.name}:"] ++
              ops.map fun op => s!"{indent}      wraps: {op}"
          ) lines
        let lines := trustedImplNames.foldl (fun lines implName =>
          let methods := trustedImplFns.filter fun f => f.trustedImplOrigin == some implName
          let methodLines := methods.foldl (fun acc f =>
            let shortName := if f.name.startsWith (implName ++ "_") then
              f.name.drop (implName.length + 1) else f.name
            let ops := trustBoundaryAnalysis externNames f
            acc ++ [s!"{indent}      fn {shortName}:"] ++
              ops.map fun op => s!"{indent}        wraps: {op}"
          ) []
          lines ++ [s!"{indent}    trusted impl {implName}:"] ++ methodLines
        ) lines
        lines
    let lines := lines ++ subReports
    some ("\n".intercalate lines)

def unsafeReport (modules : List CModule) : String :=
  let header := "=== Unsafe Signature Summary ==="
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let body := modules.filterMap (unsafeReportModule externNames · "")
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

-- ============================================================
-- Report 6: Allocation/Cleanup Summary (--report alloc)
-- ============================================================

/-- Intrinsic names that represent allocation. -/
private def allocIntrinsics : List String :=
  ["alloc", "vec_new", "Vec_new"]

/-- Intrinsic names that represent deallocation/cleanup. -/
private def freeIntrinsics : List String :=
  ["free", "destroy", "vec_free", "Vec_free", "drop_string", "String_drop"]

/-- Is this call name an alloc-family intrinsic? -/
private def isAllocCall (name : String) : Bool :=
  allocIntrinsics.contains name ||
  -- Also catch Type_destroy patterns as not-alloc
  match resolveIntrinsic name with
  | some .alloc | some .vecNew => true
  | _ => false

/-- Is this call name a free/cleanup-family intrinsic? -/
private def isFreeCall (name : String) : Bool :=
  freeIntrinsics.contains name ||
  name.endsWith "_destroy" ||
  match resolveIntrinsic name with
  | some .free | some .destroy | some .vecFree | some .dropString => true
  | _ => false

/-- Check if a return type suggests the allocation is returned to the caller. -/
private def returnsAllocation : Ty → Bool
  | .heap _ | .heapArray _ => true
  | .generic "Vec" _ => true
  | _ => false

/-- Analyze allocation patterns in a single function. -/
private def analyzeFnAlloc (f : CFnDef) : Option String :=
  let callees := collectCallsStmts f.body |>.eraseDups
  let allocs := callees.filter isAllocCall
  let frees := callees.filter isFreeCall
  let defers := collectDefersStmts f.body
  -- Skip functions with no allocation activity
  if allocs.isEmpty && frees.isEmpty && defers.isEmpty then none
  else
    let lines : List String := [s!"  fn {f.name}:"]
    let lines := if allocs.isEmpty then lines
      else lines ++ [s!"    allocates: {", ".intercalate allocs}"]
    let lines := if frees.isEmpty then lines
      else lines ++ [s!"    frees: {", ".intercalate frees}"]
    let lines := if defers.isEmpty then lines
      else lines ++ defers.map fun d => s!"    cleanup: {d}"
    -- Warn if allocates but no free or defer
    let lines := if !allocs.isEmpty && frees.isEmpty && defers.isEmpty then
      if returnsAllocation f.retTy then
        lines ++ [s!"    note: allocates and returns — caller responsible for cleanup"]
      else
        lines ++ [s!"    WARNING: allocates but has no matching free/defer"]
    else lines
    some ("\n".intercalate lines)

private partial def allocReportModule (m : CModule) (indent : String) : Option String :=
  let fnReports := m.functions.filterMap analyzeFnAlloc
  let subReports := m.submodules.filterMap (allocReportModule · (indent ++ "  "))
  if fnReports.isEmpty && subReports.isEmpty then none
  else
    let header := s!"{indent}module {m.name}:"
    let body := fnReports ++ subReports
    some (s!"{header}\n{"\n".intercalate body}")

/-- Count allocation-related functions across module tree. -/
private partial def allocCounts (m : CModule) : Nat × Nat × Nat :=
  let fnResults := m.functions.map fun f =>
    let callees := collectCallsStmts f.body |>.eraseDups
    let allocs := callees.filter isAllocCall
    let frees := callees.filter isFreeCall
    let defers := collectDefersStmts f.body
    (allocs.isEmpty, frees.isEmpty, defers.isEmpty)
  let allocating := (fnResults.filter fun (a, _, _) => !a).length
  let freeing := (fnResults.filter fun (_, f, _) => !f).length
  let deferring := (fnResults.filter fun (_, _, d) => !d).length
  m.submodules.foldl (fun (a, f, d) sub =>
    let (a', f', d') := allocCounts sub
    (a + a', f + f', d + d')) (allocating, freeing, deferring)

def allocReport (modules : List CModule) : String :=
  let header := "=== Allocation/Cleanup Summary ==="
  let body := modules.filterMap (allocReportModule · "")
  let (allocCount, freeCount, deferCount) :=
    modules.foldl (fun (a, f, d) m =>
      let (a', f', d') := allocCounts m
      (a + a', f + f', d + d')) (0, 0, 0)
  if body.isEmpty then s!"{header}\n\nNo allocation activity found.\n"
  else
    let summary := s!"\nTotals: {allocCount} functions allocate, {freeCount} free, {deferCount} use defer"
    s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 7: Authority Budget (--report authority)
-- ============================================================
-- For each capability, show which functions require it and
-- compute the transitive call chain that introduces it.

/-- A flat map of function name → list of direct callees. -/
abbrev CallGraph := List (String × List String)

/-- Build a call graph from all modules. -/
private partial def buildCallGraphModule (m : CModule) : CallGraph :=
  let fnEntries := m.functions.map fun f =>
    (f.name, collectCallsStmts f.body |>.eraseDups)
  fnEntries ++ m.submodules.foldl (fun acc sub => acc ++ buildCallGraphModule sub) []

private def buildCallGraph (modules : List CModule) : CallGraph :=
  modules.foldl (fun acc m => acc ++ buildCallGraphModule m) []

/-- All function defs across modules (flat). -/
private partial def collectAllFnDefs (m : CModule) : List CFnDef :=
  m.functions ++ m.submodules.foldl (fun acc sub => acc ++ collectAllFnDefs sub) []

/-- Find one call chain from `fn` to any function that directly declares `cap`.
    Returns the chain as a list of function names, or empty if no chain found.
    Uses BFS with visited set to avoid cycles. -/
private def findCapChain (callGraph : CallGraph) (lookup : CapLookup)
    (fnName : String) (cap : String) (maxDepth : Nat := 20) : List String :=
  let rec bfs (queue : List (String × List String)) (visited : List String)
      (fuel : Nat) : List String :=
    match fuel, queue with
    | 0, _ => []
    | _, [] => []
    | fuel + 1, (current, path) :: rest =>
      -- Check if current function directly has this cap
      let directCaps := match lookup.find? (fun (n, _) => n == current) with
        | some (_, cs) => cs.concreteCaps
        | none =>
          match resolveIntrinsic current with
          | some iid => match iid.capability with
            | some c => [c]
            | none => []
          | none => []
      if directCaps.contains cap && path.length > 0 then
        path ++ [current]
      else
        let callees := match callGraph.find? (fun (n, _) => n == current) with
          | some (_, cs) => cs
          | none => []
        let newVisited := visited ++ [current]
        let newEntries := callees.filter (fun c => !visited.contains c) |>.map fun c =>
          (c, path ++ [current])
        bfs (rest ++ newEntries) newVisited fuel
  bfs [(fnName, [])] [] maxDepth

/-- Group functions by capability for the authority report. -/
private partial def collectFnsWithCap (m : CModule) (cap : String) : List CFnDef :=
  let matching := m.functions.filter fun f =>
    let (caps, _) := f.capSet.normalize
    caps.contains cap
  matching ++ m.submodules.foldl (fun acc sub => acc ++ collectFnsWithCap sub cap) []

def authorityReport (modules : List CModule) : String :=
  let header := "=== Authority Report ==="
  let lookup := buildCapLookup modules
  let callGraph := buildCallGraph modules
  let allCaps := validCaps  -- all 9 capabilities
  let sections := allCaps.filterMap fun cap =>
    let fns := modules.foldl (fun acc m => acc ++ collectFnsWithCap m cap) []
    if fns.isEmpty then none
    else
      let capHeader := s!"capability {cap} ({fns.length} functions):"
      let fnLines := fns.map fun f =>
        let pubStr := if f.isPublic then "pub " else "    "
        let chain := findCapChain callGraph lookup f.name cap
        let chainStr := if chain.length <= 1 then "  <- declared"
          else s!"  <- {" -> ".intercalate chain}"
        s!"  {pubStr}{f.name}{chainStr}"
      some (s!"{capHeader}\n{"\n".intercalate fnLines}")
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let pureFns := (allFns.filter fun f => f.capSet.isEmpty).length
  let totalFns := allFns.length
  let externCount := modules.foldl (fun acc m => acc + countModuleExterns m) 0
  let summary := s!"\nTotals: {totalFns} functions ({pureFns} pure, {totalFns - pureFns} with capabilities), {externCount} externs"
  if sections.isEmpty then s!"{header}\n\nAll functions are pure — no capabilities required.\n"
  else s!"{header}\n\n{"\n\n".intercalate sections}\n{summary}\n"

-- ============================================================
-- Report 8: Proof Eligibility (--report proof)
-- ============================================================
-- Determines which functions could be extracted for ProofCore
-- (pure, no trusted, no extern calls, no raw pointer ops).

/-- Reasons a function is excluded from ProofCore. -/
private def proofExclusionReasons (externNames : List String) (f : CFnDef) : List String :=
  let reasons : List String := []
  -- 1. Has capabilities
  let reasons := if !f.capSet.isEmpty then
    let (caps, _) := f.capSet.normalize
    reasons ++ [s!"requires capabilities: {", ".intercalate caps}"]
  else reasons
  -- 2. Is trusted
  let reasons := if f.isTrusted then reasons ++ ["trusted boundary"] else reasons
  -- 3. Calls extern functions
  let callees := collectCallsStmts f.body |>.eraseDups
  let externCalls := callees.filter fun c => externNames.contains c
  let reasons := if !externCalls.isEmpty then
    reasons ++ [s!"calls extern: {", ".intercalate externCalls}"]
  else reasons
  -- 4. Raw pointer operations
  let reasons := if hasRawPtrOpsStmts f.body then
    reasons ++ ["raw pointer operations"]
  else reasons
  reasons

private partial def proofReportModule (externNames : List String) (m : CModule) (indent : String)
    : String :=
  let header := s!"{indent}module {m.name}:"
  let fnLines := m.functions.map fun f =>
    let reasons := proofExclusionReasons externNames f
    if reasons.isEmpty then
      s!"{indent}  ✓ {f.name}"
    else
      let reasonStr := ", ".intercalate reasons
      s!"{indent}  ✗ {f.name}  ({reasonStr})"
  let subLines := m.submodules.map (proofReportModule externNames · (indent ++ "  "))
  let body := fnLines ++ subLines
  s!"{header}\n{"\n".intercalate body}"

def proofReport (modules : List CModule) : String :=
  let header := "=== Proof Eligibility Report ==="
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let body := modules.map (proofReportModule externNames · "")
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let eligible := allFns.filter fun f =>
    (proofExclusionReasons externNames f).isEmpty
  let excluded := allFns.length - eligible.length
  let summary := s!"\nTotals: {allFns.length} functions, {eligible.length} eligible for ProofCore, {excluded} excluded"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

-- ============================================================
-- Report 9: Recursion / Call-Cycle Detection (--report recursion)
-- ============================================================
-- Detects direct recursion (self-calls) and mutual recursion
-- (call cycles) using Tarjan's SCC algorithm on the call graph.
-- This is the foundation for the predictable-execution profile:
-- functions in cycles cannot be proven to terminate statically.

/-- Mutable state for Tarjan's SCC algorithm. -/
private structure TarjanState where
  index    : Nat                           -- next index to assign
  stack    : List String                   -- DFS stack
  onStack  : List String                   -- fast membership check
  indices  : List (String × Nat)           -- node → discovery index
  lowlinks : List (String × Nat)           -- node → lowlink
  sccs     : List (List String)            -- completed SCCs

private def TarjanState.empty : TarjanState :=
  { index := 0, stack := [], onStack := [], indices := [], lowlinks := [], sccs := [] }

private def lookupNat (assoc : List (String × Nat)) (key : String) : Nat :=
  match assoc.find? (fun (k, _) => k == key) with
  | some (_, v) => v
  | none => 0

private def setNat (assoc : List (String × Nat)) (key : String) (val : Nat) : List (String × Nat) :=
  match assoc.findIdx? (fun (k, _) => k == key) with
  | some idx => assoc.set idx (key, val)
  | none => assoc ++ [(key, val)]

/-- Tarjan's SCC — iterative with an explicit work stack to avoid Lean stack overflow
    on large call graphs.  Each frame records the node being visited and where we are
    in its adjacency list.  When we finish all successors we pop the frame and propagate
    lowlinks exactly as in the recursive version. -/
private def tarjanSCC (graph : CallGraph) : List (List String) :=
  -- Collect all nodes that appear as keys OR as callees
  let allNodes := graph.foldl (fun acc (fn, callees) =>
    let acc := if acc.contains fn then acc else acc ++ [fn]
    callees.foldl (fun a c => if a.contains c then a else a ++ [c]) acc) []
  -- Work-stack frame: (node, remaining-successors, lowlink-so-far)
  let rec processStack
    (work : List (String × List String × Nat))
    (st : TarjanState)
    (fuel : Nat) : TarjanState :=
    match fuel with
    | 0 => st
    | fuel + 1 =>
      match work with
      | [] => st
      | (v, [], _vLow) :: rest =>
        -- All successors of v processed.  Finalise v.
        let vLow := lookupNat st.lowlinks v
        let vIdx := lookupNat st.indices v
        -- If v is a root, pop its SCC from the stack
        let st := if vLow == vIdx then
          let rec popScc (stk : List String) (scc : List String) :=
            match stk with
            | [] => (scc, [])
            | w :: stk' =>
              let scc := scc ++ [w]
              if w == v then (scc, stk')
              else popScc stk' scc
          let (scc, newStack) := popScc st.stack []
          let newOnStack := st.onStack.filter (fun n => !scc.contains n)
          { st with stack := newStack, onStack := newOnStack, sccs := st.sccs ++ [scc] }
        else st
        -- Propagate lowlink to parent frame
        match rest with
        | [] => processStack [] st fuel
        | (pv, pRemain, _pLow) :: grandRest =>
          let pLow := lookupNat st.lowlinks pv
          let newPLow := if vLow < pLow then vLow else pLow
          let st := { st with lowlinks := setNat st.lowlinks pv newPLow }
          processStack ((pv, pRemain, newPLow) :: grandRest) st fuel
      | (v, w :: ws, _vLow) :: rest =>
        -- Next successor w of v
        if (st.indices.find? (fun (k, _) => k == w)).isNone then
          -- w not yet visited — "recurse" by pushing a new frame
          let wIdx := st.index
          let st := { st with
            index := st.index + 1
            indices := st.indices ++ [(w, wIdx)]
            lowlinks := st.lowlinks ++ [(w, wIdx)]
            stack := [w] ++ st.stack
            onStack := [w] ++ st.onStack }
          let wCallees := match graph.find? (fun (n, _) => n == w) with
            | some (_, cs) => cs
            | none => []
          processStack ((w, wCallees, wIdx) :: (v, ws, lookupNat st.lowlinks v) :: rest) st fuel
        else if st.onStack.contains w then
          -- w on stack — update lowlink
          let vLow := lookupNat st.lowlinks v
          let wIdx := lookupNat st.indices w
          let newLow := if wIdx < vLow then wIdx else vLow
          let st := { st with lowlinks := setNat st.lowlinks v newLow }
          processStack ((v, ws, newLow) :: rest) st fuel
        else
          -- w already completed — skip
          processStack ((v, ws, lookupNat st.lowlinks v) :: rest) st fuel
  -- Kick off: visit each unvisited node
  let st := allNodes.foldl (fun st v =>
    if (st.indices.find? (fun (k, _) => k == v)).isSome then st
    else
      let vIdx := st.index
      let st := { st with
        index := st.index + 1
        indices := st.indices ++ [(v, vIdx)]
        lowlinks := st.lowlinks ++ [(v, vIdx)]
        stack := [v] ++ st.stack
        onStack := [v] ++ st.onStack }
      let vCallees := match graph.find? (fun (n, _) => n == v) with
        | some (_, cs) => cs
        | none => []
      processStack [(v, vCallees, vIdx)] st (allNodes.length * allNodes.length + allNodes.length)
  ) TarjanState.empty
  st.sccs

/-- Recursion classification for a function. -/
inductive RecursionKind where
  | none          -- not in any cycle
  | direct        -- calls itself
  | mutual        -- in a cycle with other functions
  deriving BEq

/-- Classify each function given the SCCs and the call graph. -/
private def classifyRecursion (graph : CallGraph) (sccs : List (List String))
    : List (String × RecursionKind × List String) :=
  sccs.foldl (fun acc scc =>
    match scc with
    | [single] =>
      -- Check for self-call
      let callees := match graph.find? (fun (n, _) => n == single) with
        | some (_, cs) => cs
        | none => []
      if callees.contains single then
        acc ++ [(single, .direct, [single])]
      else
        acc ++ [(single, .none, [])]
    | members =>
      -- All members of a multi-node SCC are mutually recursive
      let entries := members.map fun m => (m, RecursionKind.mutual, members)
      acc ++ entries
  ) []

-- ============================================================
-- Loop-boundedness classification
-- ============================================================
-- Classifies each loop in a function as bounded or unbounded.
-- A loop is considered structurally bounded when it has:
--   1. A comparison condition (var < expr, var >= expr, etc.)
--   2. A non-empty step (from for-loop desugaring)
-- This is conservative: anything not structurally recognizable
-- as bounded is classified as unbounded.

/-- Is this condition a comparison that suggests a bounded loop? -/
private def isBoundedCond (cond : CExpr) : Bool :=
  match cond with
  | .binOp op _ _ _ =>
    op == .lt || op == .gt || op == .leq || op == .geq || op == .neq
  | _ => false

/-- Loop boundedness for a single loop. -/
inductive LoopBound where
  | bounded    -- structurally recognizable bound
  | unbounded  -- cannot determine bound statically
  deriving BEq

mutual
/-- Collect loop-boundedness classifications from an expression. -/
partial def collectLoopBoundsExpr (e : CExpr) : List LoopBound :=
  match e with
  | .whileExpr cond body elseBody _ =>
    let thisBound := if isBoundedCond cond then .bounded else .unbounded
    [thisBound] ++ collectLoopBoundsStmts body ++ collectLoopBoundsStmts elseBody
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ collectLoopBoundsExpr a) []
  | .binOp _ l r _ => collectLoopBoundsExpr l ++ collectLoopBoundsExpr r
  | .unaryOp _ e _ => collectLoopBoundsExpr e
  | .structLit _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectLoopBoundsExpr v) []
  | .fieldAccess obj _ _ => collectLoopBoundsExpr obj
  | .enumLit _ _ _ fields _ => fields.foldl (fun acc (_, v) => acc ++ collectLoopBoundsExpr v) []
  | .match_ scrut arms _ =>
    collectLoopBoundsExpr scrut ++ arms.foldl (fun acc a => acc ++ collectLoopBoundsArm a) []
  | .borrow inner _ | .borrowMut inner _ | .deref inner _ => collectLoopBoundsExpr inner
  | .arrayLit elems _ => elems.foldl (fun acc e => acc ++ collectLoopBoundsExpr e) []
  | .arrayIndex arr idx _ => collectLoopBoundsExpr arr ++ collectLoopBoundsExpr idx
  | .cast inner _ | .try_ inner _ => collectLoopBoundsExpr inner
  | .allocCall inner alloc _ => collectLoopBoundsExpr inner ++ collectLoopBoundsExpr alloc
  | .ifExpr c t e _ => collectLoopBoundsExpr c ++ collectLoopBoundsStmts t ++ collectLoopBoundsStmts e
  | _ => []

partial def collectLoopBoundsArm (arm : CMatchArm) : List LoopBound :=
  match arm with
  | .enumArm _ _ _ body => collectLoopBoundsStmts body
  | .litArm v body => collectLoopBoundsExpr v ++ collectLoopBoundsStmts body
  | .varArm _ _ body => collectLoopBoundsStmts body

partial def collectLoopBoundsStmt (s : CStmt) : List LoopBound :=
  match s with
  | .while_ cond body _ step =>
    let hasStep := !step.isEmpty
    let thisBound := if isBoundedCond cond && hasStep then .bounded else .unbounded
    [thisBound] ++ collectLoopBoundsStmts body
  | .letDecl _ _ _ v => collectLoopBoundsExpr v
  | .assign _ v => collectLoopBoundsExpr v
  | .return_ (some v) _ => collectLoopBoundsExpr v
  | .return_ none _ => []
  | .expr e => collectLoopBoundsExpr e
  | .ifElse c t el =>
    collectLoopBoundsExpr c ++ collectLoopBoundsStmts t ++
    match el with | some stmts => collectLoopBoundsStmts stmts | none => []
  | .fieldAssign obj _ v => collectLoopBoundsExpr obj ++ collectLoopBoundsExpr v
  | .derefAssign t v => collectLoopBoundsExpr t ++ collectLoopBoundsExpr v
  | .arrayIndexAssign arr idx v =>
    collectLoopBoundsExpr arr ++ collectLoopBoundsExpr idx ++ collectLoopBoundsExpr v
  | .break_ (some v) _ => collectLoopBoundsExpr v
  | .break_ none _ | .continue_ _ => []
  | .defer body => collectLoopBoundsExpr body
  | .borrowIn _ _ _ _ _ body => collectLoopBoundsStmts body

partial def collectLoopBoundsStmts (ss : List CStmt) : List LoopBound :=
  ss.foldl (fun acc s => acc ++ collectLoopBoundsStmt s) []
end

/-- Classify a function's loop boundedness. -/
private def classifyLoops (body : List CStmt) : String :=
  let bounds := collectLoopBoundsStmts body
  if bounds.isEmpty then "no loops"
  else if bounds.all (· == .bounded) then "bounded"
  else if bounds.all (· == .unbounded) then "unbounded"
  else "mixed"

-- ============================================================
-- Report 10: Combined Effects Summary (--report effects)
-- ============================================================
-- Per-function view unifying: capabilities, allocation class,
-- recursion/cycle status, loop boundedness, crosses FFI, uses trusted.

/-- Per-function effects summary record. -/
private structure FnEffects where
  name       : String
  capSet     : CapSet
  allocates  : Bool
  frees      : Bool
  defers     : Bool
  recursion  : String       -- "none", "direct", or "mutual: a, b, c"
  loops      : String       -- "no loops", "bounded", "unbounded", or "mixed"
  crossesFfi : Bool         -- calls any extern function
  isTrusted  : Bool
  isPublic   : Bool
  evidence   : String       -- "enforced", "reported", or "trusted-assumption"
  loc        : Option SourceLoc  -- structured (file, line), not pre-formatted

private def fmtEffectsRow (e : FnEffects) : String :=
  let pub := if e.isPublic then "pub " else "    "
  let caps := ppCapSet e.capSet
  let allocClass :=
    if e.allocates && e.defers then "alloc+defer"
    else if e.allocates && e.frees then "alloc+free"
    else if e.allocates then "alloc"
    else if e.frees then "free-only"
    else if e.defers then "defer-only"
    else "none"
  let trusted := if e.isTrusted then "yes" else "no"
  let ffi := if e.crossesFfi then "yes" else "no"
  let locSuffix := match e.loc with | some l => s!"  @ {fmtLoc (some l)}" | none => ""
  s!"  {pub}{e.name}\n    caps: {caps}  alloc: {allocClass}  recursion: {e.recursion}  loops: {e.loops}  ffi: {ffi}  trusted: {trusted}  evidence: {e.evidence}{locSuffix}"

private partial def effectsForModule
    (externNames : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "") : List FnEffects :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fns := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.name
    let callees := collectCallsStmts f.body |>.eraseDups
    let allocs := callees.filter isAllocCall
    let frees := callees.filter isFreeCall
    let defs := collectDefersStmts f.body
    let rec_ := match recMap.find? (fun (n, _, _) => n == f.name) with
      | some (_, .direct, _) => "direct"
      | some (_, .mutual, members) =>
        let others := members.filter (· != f.name)
        s!"mutual: {", ".intercalate others}"
      | _ => "none"
    let crossesFfi := callees.any fun c => externNames.contains c
    let loopClass := classifyLoops f.body
    -- Evidence level: enforced if passes all 5 predictable gates
    let (concreteCaps, _) := f.capSet.normalize
    let hasRecursion := rec_ != "none"
    let hasUnboundedLoops := loopClass == "unbounded" || loopClass == "mixed"
    let hasAllocEvidence := !allocs.isEmpty || concreteCaps.any (· == "Alloc")
    let hasFfi := crossesFfi
    let hasBlocking := concreteCaps.any fun c =>
      c == "File" || c == "Network" || c == "Process"
    let passesProfile := !hasRecursion && !hasUnboundedLoops && !hasAllocEvidence && !hasFfi && !hasBlocking
    let fp := bodyFingerprint f.body
    let hasProof := Proof.provedFunctions.any fun (name, expectedFp) =>
      name == qualName && expectedFp == fp
    let proofStale := !hasProof && Proof.provedFunctions.any fun (name, _) =>
      name == qualName
    let evidenceLevel :=
      if f.isTrusted then "trusted-assumption"
      else if hasProof && passesProfile then "proved"
      else if proofStale && passesProfile then "enforced (proof stale: body changed)"
      else if passesProfile then "enforced"
      else "reported"
    { name := f.name
      capSet := f.capSet
      allocates := !allocs.isEmpty
      frees := !frees.isEmpty
      defers := !defs.isEmpty
      recursion := rec_
      loops := loopClass
      crossesFfi := crossesFfi
      isTrusted := f.isTrusted
      isPublic := f.isPublic
      evidence := evidenceLevel
      loc := lookupLoc locMap qualName }
  fns ++ m.submodules.foldl (fun acc sub =>
    acc ++ effectsForModule externNames recMap locMap sub qualPrefix) []

def effectsReport (modules : List CModule) (locMap : FnLocMap := []) : String :=
  let header := "=== Combined Effects Report ==="
  -- Build shared analysis results
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  -- Collect per-function effects
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule externNames recMap locMap m) []
  -- Format per-module
  let body := modules.map fun m =>
    let modEffects := effectsForModule externNames recMap locMap m
    let fnLines := modEffects.map fmtEffectsRow
    s!"module {m.name}:\n{"\n".intercalate fnLines}"
  -- Summary counts
  let total := allEffects.length
  let pure := (allEffects.filter fun e => e.capSet == .empty).length
  let allocating := (allEffects.filter (·.allocates)).length
  let recursive := (allEffects.filter fun e => e.recursion != "none").length
  let unboundedLoops := (allEffects.filter fun e => e.loops == "unbounded" || e.loops == "mixed").length
  let ffi := (allEffects.filter (·.crossesFfi)).length
  let trusted := (allEffects.filter (·.isTrusted)).length
  let proved := (allEffects.filter fun e => e.evidence == "proved").length
  let enforced := (allEffects.filter fun e => e.evidence.startsWith "enforced").length
  let trustedAssumption := (allEffects.filter fun e => e.evidence == "trusted-assumption").length
  let reported := (allEffects.filter fun e => e.evidence == "reported").length
  let summary := s!"\nTotals: {total} functions, {pure} pure, {allocating} allocating, {recursive} recursive, {unboundedLoops} unbounded loops, {ffi} cross FFI, {trusted} trusted\nEvidence: {proved} proved, {enforced} enforced, {trustedAssumption} trusted-assumption, {reported} reported"
  s!"{header}\n\n{"\n\n".intercalate body}\n{summary}\n"

/-- Format the recursion report. -/
def recursionReport (modules : List CModule) : String :=
  let header := "=== Recursion / Call-Cycle Report ==="
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let classifications := classifyRecursion graph sccs
  -- Separate into categories
  let directRec := classifications.filter fun (_, k, _) => k == .direct
  let mutualRec := classifications.filter fun (_, k, _) => k == .mutual
  let nonRec := classifications.filter fun (_, k, _) => k == .none
  -- Group mutual recursion by cycle (deduplicate SCC listings)
  let mutualCycles := sccs.filter (fun scc => scc.length > 1)
  -- Build output
  let directSection :=
    if directRec.isEmpty then []
    else
      [s!"Direct recursion ({directRec.length} functions):"] ++
      directRec.map (fun (fn, _, _) => s!"  {fn} -> {fn}") ++ [""]
  let mutualSection :=
    if mutualCycles.isEmpty then []
    else
      [s!"Mutual recursion ({mutualCycles.length} cycles):"] ++
      mutualCycles.map (fun cycle =>
        let cycleStr := " -> ".intercalate cycle
        match cycle.head? with
        | some h => s!"  cycle: {cycleStr} -> {h}"
        | none => s!"  cycle: {cycleStr}") ++ [""]
  let totalFns := classifications.length
  let recursiveFns := directRec.length + mutualRec.length
  let summaryLine := s!"Totals: {totalFns} functions, {nonRec.length} non-recursive, {directRec.length} direct recursion, {mutualRec.length} in mutual cycles"
  let acyclicNote :=
    if recursiveFns == 0 then ["", "No recursion detected — all call paths are acyclic."]
    else []
  let allLines := [header, ""] ++ directSection ++ mutualSection ++ [summaryLine] ++ acyclicNote
  "\n".intercalate allLines ++ "\n"

-- ============================================================
-- Profile checks (--check predictable)
-- ============================================================
-- Enforces the predictable-execution profile gate:
--   1. No recursion / call cycles
--   2. No unbounded or mixed loop classifications
--   3. No allocation (alloc/vec_new intrinsic calls)
--   4. No FFI (extern function calls)
--   5. No blocking (File/Network/Process capabilities)
-- Returns a list of violation strings (empty = pass).

/-- Capabilities that imply potentially blocking I/O. -/
private def blockingCaps : List String :=
  ["File", "Network", "Process"]

/-- A single profile violation. -/
structure ProfileViolation where
  fnName        : String
  reason        : String
  hint          : String := ""                -- suggested fix
  loc           : Option SourceLoc := none    -- function definition
  violationLoc  : Option SourceLoc := none    -- offending construct (loop, call, etc.)
  violationSpan : Option Span := none         -- full span for caret rendering

private partial def checkPredictableModule
    (recMap : List (String × RecursionKind × List String))
    (externNames : List String)
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "") : List ProfileViolation :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let fnViolations := m.functions.foldl (fun acc f =>
    let qualName := qualPrefix ++ "." ++ f.name
    let fnLoc := lookupLoc locMap qualName
    let entry := lookupBody locMap qualName
    let astBody := match entry with | some e => e.body | none => []
    let fileStr := match entry with | some e => e.file | none => ""
    let mkViolLoc (sp : Option Span) : Option SourceLoc :=
      sp.bind fun s => if fileStr == "" then none else some (fileStr, s.line)
    -- 1. Recursion (function-level only for now)
    let recViolations := match recMap.find? (fun (n, _, _) => n == f.name) with
      | some (_, .direct, _) =>
        [{ fnName := f.name, reason := "direct recursion"
         , hint := "Use a loop or iterative approach instead of self-calls."
         , loc := fnLoc }]
      | some (_, .mutual, members) =>
        let others := members.filter (· != f.name)
        [{ fnName := f.name, reason := s!"mutual recursion with {", ".intercalate others}"
         , hint := "Break the cycle by restructuring into a loop or state machine."
         , loc := fnLoc }]
      | _ => []
    -- 2. Loop boundedness — point at the offending loop
    let loopClass := classifyLoops f.body
    let loopSpan := findLoopSpan astBody
    let loopViolLoc := mkViolLoc loopSpan
    let loopViolations :=
      if loopClass == "unbounded" then
        [{ fnName := f.name, reason := "unbounded loops"
         , hint := "Use a for loop with an explicit bound: for (let mut i = 0; i < n; i = i + 1)"
         , loc := fnLoc, violationLoc := loopViolLoc, violationSpan := loopSpan }]
      else if loopClass == "mixed" then
        [{ fnName := f.name, reason := "mixed loop boundedness (some loops are unbounded)"
         , hint := "Replace while(true) or while(flag) with a bounded for loop."
         , loc := fnLoc, violationLoc := loopViolLoc, violationSpan := loopSpan }]
      else []
    -- 3. Allocation — point at the allocating call
    let callees := collectCallsStmts f.body |>.eraseDups
    let allocs := callees.filter isAllocCall
    let (fnCaps, _) := f.capSet.normalize
    let hasAllocCap := fnCaps.any (· == "Alloc")
    let allocSpan := findCallSpan allocs astBody
    let allocViolLoc := mkViolLoc allocSpan
    let allocViolations :=
      if !allocs.isEmpty then
        [{ fnName := f.name, reason := s!"allocates ({", ".intercalate allocs})"
         , hint := "Use a fixed-size array or stack buffer instead of heap allocation."
         , loc := fnLoc, violationLoc := allocViolLoc, violationSpan := allocSpan }]
      else if hasAllocCap then
        [{ fnName := f.name, reason := "has Alloc capability"
         , hint := "Remove Alloc from the with(...) clause if this function does not need heap allocation."
         , loc := fnLoc, violationSpan := match entry with | some e => some e.fnSpan | none => none }]
      else []
    -- 4. FFI — point at the extern call
    let externCalls := callees.filter fun c => externNames.contains c
    let ffiSpan := findCallSpan externCalls astBody
    let ffiViolLoc := mkViolLoc ffiSpan
    let ffiViolations := if externCalls.isEmpty then []
      else [{ fnName := f.name, reason := s!"calls extern ({", ".intercalate externCalls})"
            , hint := "Move the extern call to a non-predictable wrapper and call that instead."
            , loc := fnLoc, violationLoc := ffiViolLoc, violationSpan := ffiSpan }]
    -- 5. Blocking — points at function signature (with-clause has no separate span)
    let (concreteCaps, _) := f.capSet.normalize
    let blockingUsed := concreteCaps.filter fun c => blockingCaps.contains c
    let blockViolations := if blockingUsed.isEmpty then []
      else [{ fnName := f.name, reason := s!"may block ({", ".intercalate blockingUsed})"
            , hint := s!"Remove {", ".intercalate blockingUsed} from with(...) or move I/O to a non-predictable caller."
            , loc := fnLoc, violationSpan := match entry with | some e => some e.fnSpan | none => none }]
    acc ++ recViolations ++ loopViolations ++ allocViolations ++ ffiViolations ++ blockViolations) []
  fnViolations ++ m.submodules.foldl (fun acc sub =>
    acc ++ checkPredictableModule recMap externNames locMap sub qualPrefix) []

/-- Extract a 1-indexed line from source text. Returns "" if out of bounds. -/
private def getSourceLine (source : String) (lineNum : Nat) : String :=
  let lines := source.splitOn "\n"
  if lineNum == 0 then ""
  else match lines[lineNum - 1]? with
    | some l => l
    | none => ""

/-- Render a violation with Elm-style snippet formatting. -/
private def renderViolation (v : ProfileViolation) (sourceMap : SourceMap) : String :=
  -- Header: location + label
  let locStr := match v.loc with | some l => s!"{fmtLoc (some l)}: " | none => ""
  let header := s!"-- {locStr}{v.fnName} — {v.reason}"
  -- Source snippet at the violation point (or function if no violation span)
  let snippetSpan := v.violationSpan.orElse fun _ =>
    match v.loc with | some (_, line) => some { line, col := 1 } | none => none
  let snippetFile := match v.violationLoc with
    | some (f, _) => f
    | none => match v.loc with | some (f, _) => f | none => ""
  let source := sourceMap.lookup snippetFile
  let snippet := match snippetSpan, source with
    | some sp, some src =>
      let line := getSourceLine src sp.line
      if line.isEmpty then ""
      else
        let lineNumStr := toString sp.line
        let pad := lineNumStr.length
        let gutter := String.ofList (List.replicate pad ' ')
        let caretStart := if sp.col > 1 then sp.col - 1 else 0
        let caretLen := if sp.endCol > sp.col then sp.endCol - sp.col else line.length - caretStart
        let spaces := String.ofList (List.replicate caretStart ' ')
        let carets := String.ofList (List.replicate caretLen '^')
        s!"\n\n {lineNumStr} | {line}\n {gutter} | {spaces}{carets}"
    | _, _ => ""
  -- Hint
  let hintStr := if v.hint.isEmpty then "" else s!"\n\n  hint: {v.hint}"
  s!"{header}{snippet}{hintStr}"

/-- Check the predictable-execution profile. Returns (pass, report string). -/
def checkPredictable (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) : Bool × String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap externNames locMap m) []
  let allFns := modules.foldl (fun acc m => acc ++ collectAllFnDefs m) []
  let violatingFns := (violations.map (·.fnName)).eraseDups
  let passingFns := allFns.length - violatingFns.length
  if violations.isEmpty then
    (true, s!"predictable profile: pass ({allFns.length} functions checked)\n")
  else
    let header := "predictable profile: FAIL"
    let lines := violations.map fun v => renderViolation v sourceMap
    let summary := s!"{violatingFns.length} function(s) failed, {passingFns} passed"
    (false, s!"{header}\n\n{"\n\n".intercalate lines}\n\n{summary}\n")

-- ============================================================
-- Proof Eligibility Assessment (first-class, shared by all
-- proof pipeline consumers: proof-status, extraction,
-- obligations, traceability, effects evidence)
-- ============================================================
-- This is the single authoritative source for "is this function
-- in the provable subset?" It runs BEFORE extraction or proof
-- matching, and every downstream consumer reads it.

/-- Why a function is excluded from the provable subset. -/
inductive ExclusionKind where
  | source    -- structural: capabilities, trusted, entry point
  | profile   -- runtime: recursion, loops, alloc, FFI, I/O
  | both      -- fails both source and profile checks
  deriving Repr

/-- Per-function eligibility assessment. -/
structure EligibilityEntry where
  qualName       : String
  eligible       : Bool           -- in the provable subset?
  sourceReasons  : List String    -- source-level exclusion reasons
  profileReasons : List String    -- predictable-profile gate failures
  exclusionKind  : Option ExclusionKind  -- none if eligible
  isTrusted      : Bool           -- marked trusted (separate from eligible)
  loc            : Option SourceLoc

/-- Compute eligibility for one function. Combines source-level checks
    (capabilities, trusted, entry point) with profile gates (recursion,
    loops, allocation, FFI, blocking I/O) into a single assessment. -/
private def assessEligibility
    (f : CFnDef) (qualName : String)
    (externNames : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : FnLocMap) : EligibilityEntry :=
  let fnLoc := lookupLoc locMap qualName
  -- Source-level check (structural)
  let (concreteCaps, _) := f.capSet.normalize
  let callees := collectCallsStmts f.body |>.eraseDups
  let sourceReasons : List String :=
    (if !f.capSet.isEmpty then
      [s!"has capabilities: {", ".intercalate concreteCaps}"] else []) ++
    (if f.isTrusted then ["marked trusted"] else []) ++
    (if f.isEntryPoint then ["is entry point (main)"] else []) ++
    (if f.trustedImplOrigin.isSome then ["from trusted impl"] else [])
  -- Profile gates (runtime characteristics)
  let allocs := callees.filter isAllocCall
  let rec_ := match recMap.find? (fun (n, _, _) => n == f.name) with
    | some (_, .direct, _) => "direct"
    | some (_, .mutual, _) => "mutual"
    | _ => "none"
  let crossesFfi := callees.any fun c => externNames.contains c
  let loopClass := classifyLoops f.body
  let profileReasons : List String :=
    (if rec_ != "none" then [s!"recursion ({rec_})"] else []) ++
    (if loopClass == "unbounded" || loopClass == "mixed" then ["unbounded loops"] else []) ++
    (if !allocs.isEmpty || concreteCaps.any (· == "Alloc") then ["allocation"] else []) ++
    (if crossesFfi then ["FFI"] else []) ++
    (if concreteCaps.any fun c => c == "File" || c == "Network" || c == "Process"
     then ["blocking I/O"] else [])
  let passesSource := sourceReasons.isEmpty
  let passesProfile := profileReasons.isEmpty
  let eligible := passesSource && passesProfile
  let exclusionKind := if eligible then none
    else if !passesSource && !passesProfile then some .both
    else if !passesSource then some .source
    else some .profile
  { qualName, eligible, sourceReasons, profileReasons, exclusionKind
  , isTrusted := f.isTrusted, loc := fnLoc }

/-- Collect eligibility for all functions in a module tree. -/
private partial def collectEligibility
    (externNames : List String)
    (recMap : List (String × RecursionKind × List String))
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "") : List EligibilityEntry :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let entries := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.name
    assessEligibility f qualName externNames recMap locMap
  entries ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectEligibility externNames recMap locMap sub qualPrefix) []

/-- Render the eligibility report (--report eligibility). -/
def eligibilityReport (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) : String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let header := "=== Proof Eligibility Assessment ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    if e.isTrusted then
      s!"  trusted    `{e.qualName}`  @ {locStr}\n             proof bypassed (trusted assumption)"
    else if e.eligible then
      s!"  eligible   `{e.qualName}`  @ {locStr}\n             in provable subset: pure, bounded, no FFI"
    else
      let srcStr := if e.sourceReasons.isEmpty then "" else
        s!"\n             source: {", ".intercalate e.sourceReasons}"
      let profStr := if e.profileReasons.isEmpty then "" else
        s!"\n             profile: {", ".intercalate e.profileReasons}"
      s!"  excluded   `{e.qualName}`  @ {locStr}{srcStr}{profStr}"
  -- Summary
  let eligible := (entries.filter (·.eligible)).length
  let excluded := (entries.filter fun e => !e.eligible && !e.isTrusted).length
  let trusted := (entries.filter (·.isTrusted)).length
  let sourceOnly := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && !e.sourceReasons.isEmpty && e.profileReasons.isEmpty).length
  let profileOnly := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && e.sourceReasons.isEmpty && !e.profileReasons.isEmpty).length
  let bothReasons := (entries.filter fun e =>
    !e.eligible && !e.isTrusted && !e.sourceReasons.isEmpty && !e.profileReasons.isEmpty).length
  let summary := s!"Totals: {entries.length} functions — {eligible} eligible, {excluded} excluded ({sourceOnly} source, {profileOnly} profile, {bothReasons} both), {trusted} trusted"
  s!"{header}\n\n{"\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Report: Proof Status (--report proof-status)
-- ============================================================
-- Per-function proof evidence with Elm-clear diagnostics for
-- stale, missing, and ineligible states.

/-- Proof status for a single function. -/
inductive ProofState where
  | proved          -- name + fingerprint match, passes profile
  | stale           -- name matches but fingerprint changed
  | notProved       -- passes profile, no registered proof
  | notEligible     -- fails profile gates (recursion, alloc, etc.)
  | trusted         -- marked trusted (bypasses proof)

/-- Per-function proof status record. -/
structure ProofStatusEntry where
  qualName      : String
  bareName      : String
  state         : ProofState
  currentFp     : String       -- current body fingerprint
  expectedFp    : String       -- registered fingerprint (empty if no proof)
  profileGates  : List String  -- reasons the function fails profile (empty if passes)
  specName      : String       -- spec name (from registry or derived)
  proofName     : String       -- proof/theorem name (from registry or derived)
  proofSource   : String       -- "registry" | "hardcoded" | "none"
  loc           : Option SourceLoc
  fnSpan        : Option Span

private partial def collectProofStatus
    (eligibility : List EligibilityEntry)
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "")
    (registry : ProofRegistry := []) : List ProofStatusEntry :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let entries := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.name
    let fp := bodyFingerprint f.body
    let entry := lookupBody locMap qualName
    let fnLoc := lookupLoc locMap qualName
    let fnSp := entry.map (·.fnSpan)
    -- Look up pre-computed eligibility
    let elig := eligibility.find? fun e => e.qualName == qualName
    let gates := match elig with
      | some e => e.sourceReasons ++ e.profileReasons
      | none => []
    let passesProfile := match elig with
      | some e => e.eligible
      | none => false
    -- Determine proof state: check both hardcoded table and registry
    let matchedProof := Proof.provedFunctions.find? fun (name, expectedFp) =>
      name == qualName && expectedFp == fp
    let matchedRegistry := registry.find? fun re =>
      re.function == qualName && re.bodyFingerprint == fp
    let hasMatch := matchedProof.isSome || matchedRegistry.isSome
    let staleProof := Proof.provedFunctions.find? fun (name, _) =>
      name == qualName
    let staleRegistry := registry.find? fun re =>
      re.function == qualName
    let hasStale := staleProof.isSome || staleRegistry.isSome
    let state :=
      if f.isTrusted then .trusted
      else if hasMatch && passesProfile then .proved
      else if !hasMatch && hasStale then .stale
      else if !passesProfile then .notEligible
      else .notProved
    let expectedFp := match staleProof with
      | some (_, efp) => efp
      | none => match staleRegistry with
        | some re => re.bodyFingerprint
        | none => ""
    -- Spec and proof identity
    let regEntry := registry.find? fun re => re.function == qualName
    let (sName, pName, pSrc) := match regEntry with
      | some re => (re.spec, re.proof, "registry")
      | none => match staleProof with
        | some (name, _) => (name ++ ".spec", name ++ ".proof", "hardcoded")
        | none => ("", "", "none")
    { qualName, bareName := f.name, state, currentFp := fp, expectedFp
    , profileGates := gates, specName := sName, proofName := pName
    , proofSource := pSrc, loc := fnLoc, fnSpan := fnSp }
  entries ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectProofStatus eligibility locMap sub qualPrefix registry) []

/-- Render a single proof status entry with Elm-clear formatting. -/
private def renderProofStatusEntry (e : ProofStatusEntry) (sourceMap : SourceMap) : String :=
  let locStr := fmtLoc e.loc
  let fileStr := match e.loc with | some (f, _) => f | none => ""
  let source := sourceMap.lookup fileStr
  -- Source snippet
  let snippet := match e.fnSpan, source with
    | some sp, some src =>
      let line := getSourceLine src sp.line
      if line.isEmpty then ""
      else
        let lineNumStr := toString sp.line
        let pad := lineNumStr.length
        let gutter := String.ofList (List.replicate pad ' ')
        let caretLen := line.length
        let carets := String.ofList (List.replicate caretLen '^')
        s!"\n\n {lineNumStr} | {line}\n {gutter} | {carets}"
    | _, _ => ""
  match e.state with
  | .proved =>
    s!"-- proved {String.ofList (List.replicate 48 '-')} {locStr}\n\n  ✓ `{e.qualName}` — proof matches current body.{snippet}"
  | .stale =>
    s!"-- proof stale {String.ofList (List.replicate 44 '-')} {locStr}\n\n  Function `{e.qualName}` has a registered proof, but the body changed.{snippet}\n\n  expected fingerprint:\n    {e.expectedFp}\n\n  current fingerprint:\n    {e.currentFp}\n\n  hint: Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
  | .notProved =>
    s!"-- no proof {String.ofList (List.replicate 47 '-')} {locStr}\n\n  `{e.qualName}` passes the predictable profile but has no registered proof.{snippet}\n\n  current fingerprint:\n    {e.currentFp}\n\n  hint: Add a Lean proof for this function in Concrete/Proof.lean with the fingerprint above."
  | .notEligible =>
    let gateStr := ", ".intercalate e.profileGates
    s!"-- not eligible {String.ofList (List.replicate 43 '-')} {locStr}\n\n  `{e.qualName}` cannot be proved: fails predictable profile ({gateStr}).{snippet}\n\n  hint: Remove {gateStr} to make this function eligible for proof."
  | .trusted =>
    s!"-- trusted {String.ofList (List.replicate 48 '-')} {locStr}\n\n  `{e.qualName}` is marked trusted — proof is bypassed (trusted assumption).{snippet}"

/-- Proof status report with Elm-clear diagnostics. -/
def proofStatusReport (modules : List CModule) (locMap : FnLocMap := [])
    (sourceMap : SourceMap := []) (registry : ProofRegistry := []) : String :=
  let header := "=== Proof Status Report ==="
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  -- Compute eligibility first, then pass to proof-status
  let eligibility := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  let body := entries.map fun e => renderProofStatusEntry e sourceMap
  -- Summary
  let proved := (entries.filter fun e => e.state matches .proved).length
  let stale := (entries.filter fun e => e.state matches .stale).length
  let notProved := (entries.filter fun e => e.state matches .notProved).length
  let notEligible := (entries.filter fun e => e.state matches .notEligible).length
  let trusted := (entries.filter fun e => e.state matches .trusted).length
  let summary := s!"Totals: {entries.length} functions — {proved} proved, {stale} stale, {notProved} unproved (eligible), {notEligible} ineligible, {trusted} trusted"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Proof obligations report (--report obligations)
-- ============================================================

/-- A single proof obligation entry. -/
structure ObligationEntry where
  function     : String       -- qualified name
  spec         : String       -- spec name (from registry, or empty)
  proof        : String       -- proof name (from registry/hardcoded, or empty)
  status       : String       -- proved | stale | missing_proof | not_eligible | trusted
  dependencies : List String  -- qualified names of proved helpers this function calls
  fingerprint  : String       -- current body fingerprint
  source       : String       -- "registry" | "hardcoded" | "none"
  loc          : Option SourceLoc

/-- Find the callees of a named function in a module. -/
private partial def findFunctionCallees (m : CModule) (name : String) : List String :=
  match m.functions.find? (fun f => f.name == name) with
  | some f => collectCallsStmts f.body |>.eraseDups
  | none => m.submodules.foldl (fun acc sub => acc ++ findFunctionCallees sub name) []

/-- Build obligation entries from proof status + registry. -/
private partial def collectObligations
    (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List ObligationEntry :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let eligibility := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let proofEntries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  -- Build set of proved function names for dependency tracking
  let provedNames := proofEntries.filterMap fun e =>
    if e.state matches .proved then some e.qualName else none
  proofEntries.map fun e =>
    let regEntry := registry.find? fun re => re.function == e.qualName
    let hardcoded := Proof.provedFunctions.find? fun (name, _) => name == e.qualName
    let specName := match regEntry with
      | some re => re.spec
      | none => ""
    let proofName := match regEntry with
      | some re => re.proof
      | none => match hardcoded with
        | some (name, _) => name ++ ".proof"
        | none => ""
    let src := match regEntry, hardcoded with
      | some _, _ => "registry"
      | none, some _ => "hardcoded"
      | none, none => "none"
    let statusStr := match e.state with
      | .proved => "proved"
      | .stale => "stale"
      | .notProved => "missing_proof"
      | .notEligible => "not_eligible"
      | .trusted => "trusted"
    -- Dependencies: which proved helpers does this function call?
    let callees := match modules.foldl (fun acc m =>
      acc ++ findFunctionCallees m e.bareName) [] with
      | cs => cs.filter fun c => provedNames.any fun p => p.endsWith ("." ++ c)
    { function := e.qualName, spec := specName, proof := proofName
    , status := statusStr, dependencies := callees
    , fingerprint := e.currentFp, source := src, loc := e.loc }

/-- Render the obligations report as human-readable output. -/
def obligationsReport (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : String :=
  let entries := collectObligations modules locMap registry
  let header := "=== Proof Obligations ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let depsStr := if e.dependencies.isEmpty then "none"
      else ", ".intercalate e.dependencies
    let specStr := if e.spec.isEmpty then "(none)" else e.spec
    let proofStr := if e.proof.isEmpty then "(none)" else e.proof
    s!"  {e.function}\n    status:       {e.status}\n    spec:         {specStr}\n    proof:        {proofStr}\n    source:       {e.source}\n    fingerprint:  {e.fingerprint}\n    dependencies: {depsStr}\n    loc:          {locStr}"
  let proved := (entries.filter fun e => e.status == "proved").length
  let stale := (entries.filter fun e => e.status == "stale").length
  let missing := (entries.filter fun e => e.status == "missing_proof").length
  let notElig := (entries.filter fun e => e.status == "not_eligible").length
  let trusted := (entries.filter fun e => e.status == "trusted").length
  let summary := s!"Totals: {entries.length} obligations — {proved} proved, {stale} stale, {missing} missing, {notElig} not eligible, {trusted} trusted"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Source-to-ProofCore extraction report (--report extraction)
-- ============================================================

/-- Map a Core BinOp to the proof-fragment PBinOp. Returns none for operators
    not yet modeled in the proof fragment (div, mod, bitwise, logical). -/
private def binOpToPBinOp : BinOp → Option Proof.PBinOp
  | .add => some .add
  | .sub => some .sub
  | .mul => some .mul
  | .eq  => some .eq
  | .neq => some .ne
  | .lt  => some .lt
  | .leq => some .le
  | .gt  => some .gt
  | .geq => some .ge
  | _    => none

mutual
/-- Translate a Core expression to proof-fragment PExpr.
    Returns none for constructs not yet in the proof fragment. -/
partial def cExprToPExpr : CExpr → Option Proof.PExpr
  | .intLit n _ => some (.lit (.int n))
  | .boolLit b => some (.lit (.bool b))
  | .ident name _ => some (.var name)
  | .binOp op lhs rhs _ => do
    let pop ← binOpToPBinOp op
    let pl ← cExprToPExpr lhs
    let pr ← cExprToPExpr rhs
    some (.binOp pop pl pr)
  | .call fn _ args _ => do
    let pargs ← args.mapM cExprToPExpr
    some (.call fn pargs)
  | .ifExpr cond thenBranch elseBranch _ => do
    let pc ← cExprToPExpr cond
    let pt ← cStmtsToPExpr thenBranch
    let pe ← cStmtsToPExpr elseBranch
    some (.ifThenElse pc pt pe)
  | _ => none

/-- Translate a Core statement list to a single proof-fragment PExpr.
    Handles: return, let+rest, if/else, expression statements. -/
partial def cStmtsToPExpr : List CStmt → Option Proof.PExpr
  | [] => none
  | [.return_ (some e) _] => cExprToPExpr e
  | [.expr e] => cExprToPExpr e
  | (.letDecl name _ _ val) :: rest => do
    let pv ← cExprToPExpr val
    let pb ← cStmtsToPExpr rest
    some (.letIn name pv pb)
  | [.ifElse cond thenBranch (some elseBranch)] => do
    let pc ← cExprToPExpr cond
    let pt ← cStmtsToPExpr thenBranch
    let pe ← cStmtsToPExpr elseBranch
    some (.ifThenElse pc pt pe)
  | _ => none
end

/-- Pretty-print a PExpr as a readable S-expression. -/
private def renderPExpr : Proof.PExpr → String
  | .lit (.int n) => toString n
  | .lit (.bool b) => toString b
  | .var name => name
  | .binOp op lhs rhs =>
    let opStr := match op with
      | .add => "+" | .sub => "-" | .mul => "*"
      | .eq => "==" | .ne => "!=" | .lt => "<"
      | .le => "<=" | .gt => ">" | .ge => ">="
    s!"({renderPExpr lhs} {opStr} {renderPExpr rhs})"
  | .letIn name val body =>
    s!"let {name} = {renderPExpr val}; {renderPExpr body}"
  | .ifThenElse cond t e =>
    s!"if {renderPExpr cond} then {renderPExpr t} else {renderPExpr e}"
  | .call fn args =>
    let argsStr := ", ".intercalate (args.map renderPExpr)
    s!"{fn}({argsStr})"

/-- Identify why a function was excluded from ProofCore. -/
private def exclusionReasons (f : CFnDef) (externNames : List String) : List String :=
  let (concreteCaps, _) := f.capSet.normalize
  let callees := collectCallsStmts f.body |>.eraseDups
  (if !f.capSet.isEmpty then
    [s!"has capabilities: {", ".intercalate concreteCaps}"] else []) ++
  (if f.isTrusted then ["marked trusted"] else []) ++
  (if f.isEntryPoint then ["is entry point (main)"] else []) ++
  (if f.trustedImplOrigin.isSome then ["from trusted impl"] else []) ++
  (if callees.any (fun c => externNames.contains c) then ["calls extern/FFI"] else [])

/-- Extraction entry for one function. -/
structure ExtractionEntry where
  qualName    : String
  eligible    : Bool
  extracted   : Option Proof.PExpr
  excluded    : List String  -- reasons if not eligible
  unsupported : List String  -- constructs that blocked extraction
  fingerprint : String
  params      : List String
  specName    : String       -- spec name (from registry or derived)
  proofName   : String       -- proof name (from registry or derived)
  loc         : Option SourceLoc

/-- Identify unsupported expression constructs. -/
private partial def identifyUnsupportedExpr : CExpr → List String
  | .floatLit .. => ["float literal"]
  | .strLit .. => ["string literal"]
  | .charLit .. => ["char literal"]
  | .structLit .. => ["struct literal"]
  | .fieldAccess .. => ["field access"]
  | .enumLit .. => ["enum literal"]
  | .match_ .. => ["match expression"]
  | .borrow .. => ["borrow"]
  | .borrowMut .. => ["mutable borrow"]
  | .deref .. => ["deref"]
  | .arrayLit .. => ["array literal"]
  | .arrayIndex .. => ["array index"]
  | .cast .. => ["cast"]
  | .fnRef .. => ["function reference"]
  | .try_ .. => ["try expression"]
  | .allocCall .. => ["alloc call"]
  | .whileExpr .. => ["while expression"]
  | .unaryOp .. => ["unary operator"]
  | .binOp op _ _ _ => match binOpToPBinOp op with
    | none => [s!"unsupported operator: {repr op}"]
    | some _ => []
  | _ => []

/-- Identify unsupported constructs in expressions within a statement. -/
private partial def identifyUnsupportedStmt : CStmt → List String
  | .letDecl _ _ _ val => identifyUnsupportedExpr val
  | .return_ (some e) _ => identifyUnsupportedExpr e
  | .expr e => identifyUnsupportedExpr e
  | .ifElse cond thenBr elseBr =>
    identifyUnsupportedExpr cond ++
    thenBr.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) [] ++
    match elseBr with
    | some stmts => stmts.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) []
    | none => ["if without else"]
  | _ => []

/-- Identify unsupported constructs in a function body that prevent extraction. -/
private partial def identifyUnsupported (body : List CStmt) : List String :=
  let stmtKinds := body.filterMap fun s => match s with
    | .while_ .. => some "while loop"
    | .fieldAssign .. => some "field assignment"
    | .derefAssign .. => some "deref assignment"
    | .arrayIndexAssign .. => some "array index assignment"
    | .break_ .. => some "break"
    | .continue_ .. => some "continue"
    | .defer .. => some "defer"
    | .borrowIn .. => some "borrow region"
    | .assign .. => some "mutable assignment"
    | _ => none
  let exprKinds := body.foldl (fun acc s => acc ++ identifyUnsupportedStmt s) []
  (stmtKinds ++ exprKinds).eraseDups

/-- Collect extraction entries for all functions in a module. -/
private partial def collectExtractionEntries
    (externNames : List String)
    (locMap : FnLocMap)
    (m : CModule) (modulePath : String := "")
    (registry : ProofRegistry := []) : List ExtractionEntry :=
  let qualPrefix := if modulePath == "" then m.name else modulePath ++ "." ++ m.name
  let entries := m.functions.map fun f =>
    let qualName := qualPrefix ++ "." ++ f.name
    let fp := bodyFingerprint f.body
    let fnLoc := lookupLoc locMap qualName
    let paramNames := f.params.map (·.1)
    let regEntry := registry.find? fun re => re.function == qualName
    let (sName, pName) := match regEntry with
      | some re => (re.spec, re.proof)
      | none =>
        let hardcoded := Proof.provedFunctions.find? fun (name, _) => name == qualName
        match hardcoded with
        | some (name, _) => (name ++ ".spec", name ++ ".proof")
        | none => ("", "")
    if f.isProofEligible then
      let extracted := cStmtsToPExpr f.body
      let unsup := if extracted.isNone then
        identifyUnsupported f.body
      else []
      { qualName, eligible := true, extracted, excluded := []
      , unsupported := unsup, fingerprint := fp, params := paramNames
      , specName := sName, proofName := pName, loc := fnLoc }
    else
      let reasons := exclusionReasons f externNames
      { qualName, eligible := false, extracted := none, excluded := reasons
      , unsupported := [], fingerprint := fp, params := paramNames
      , specName := sName, proofName := pName, loc := fnLoc }
  entries ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectExtractionEntries externNames locMap sub qualPrefix registry) []

/-- Render the source-to-ProofCore extraction report. -/
def extractionReport (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : String :=
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectExtractionEntries externNames locMap m "" registry) []
  let header := "=== Source-to-ProofCore Extraction ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let statusStr := if e.eligible then
      match e.extracted with
      | some pexpr => s!"extracted\n    ProofCore: {renderPExpr pexpr}"
      | none => s!"eligible (extraction failed)\n    unsupported: {", ".intercalate e.unsupported}"
    else
      s!"excluded\n    reasons: {", ".intercalate e.excluded}"
    let paramStr := if e.params.isEmpty then "()" else "(" ++ ", ".intercalate e.params ++ ")"
    let specStr := if e.specName.isEmpty then "" else s!"\n    spec: {e.specName}"
    let proofStr := if e.proofName.isEmpty then "" else s!"\n    proof: {e.proofName}"
    s!"  {e.qualName}{paramStr}\n    status: {statusStr}{specStr}{proofStr}\n    fingerprint: {e.fingerprint}\n    loc: {locStr}"
  let extracted := (entries.filter fun e => e.eligible && e.extracted.isSome).length
  let eligFailed := (entries.filter fun e => e.eligible && e.extracted.isNone).length
  let excluded := (entries.filter fun e => !e.eligible).length
  let summary := s!"Totals: {entries.length} functions — {extracted} extracted, {eligFailed} eligible but not extractable, {excluded} excluded"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Source/Core/SSA/LLVM traceability (--report traceability)
-- ============================================================

/-- A traceability entry for one function through the pipeline. -/
structure TraceEntry where
  sourceFunction : String       -- qualified source name
  fingerprint    : String       -- body fingerprint at Core
  extractionStatus : String     -- extracted | eligible_not_extractable | excluded
  proofCoreForm  : String       -- readable PExpr if extracted, else ""
  evidenceLevel  : String       -- proved | enforced | reported | trusted-assumption
  specName       : String       -- spec name (from registry or derived)
  proofName      : String       -- proof name (from registry or derived)
  coreNames      : List String  -- Core function names (pre-mono)
  monoNames      : List String  -- monomorphized specialization names
  ssaNames       : List String  -- SSA function names
  llvmNames      : List String  -- LLVM symbol names
  claimBoundary  : String       -- where the claim stops being guaranteed
  loc            : Option SourceLoc

/-- Collect all function names from SSA modules. -/
private partial def collectSSANames (sm : SModule) (pfx : String := "") : List (String × String) :=
  let modPfx := if pfx.isEmpty then sm.name else pfx ++ "." ++ sm.name
  let fns := sm.functions.map fun f => (f.name, modPfx)
  fns

/-- Collect all function names from monomorphized Core modules. -/
private partial def collectMonoFnNames (m : CModule) (pfx : String := "") : List String :=
  let modPfx := if pfx.isEmpty then m.name else pfx ++ "." ++ m.name
  let fns := m.functions.map fun f => modPfx ++ "." ++ f.name
  fns ++ m.submodules.foldl (fun acc sub => acc ++ collectMonoFnNames sub modPfx) []

/-- Determine the LLVM symbol name for a function. -/
private def llvmSymbol (name : String) (isEntry : Bool) : String :=
  if isEntry then "user_main" else name

/-- Determine the claim boundary for a function. -/
private def claimBoundaryFor (evidence : String) (extracted : Bool) : String :=
  match evidence with
  | "proved" =>
    if extracted then "ProofCore (source-level proof, not preserved past Core)"
    else "source (proof not extractable to ProofCore)"
  | "enforced" => "source (passes predictable profile, no proof)"
  | "trusted-assumption" => "source (trusted, no verification)"
  | "reported" => "source (fails predictable profile)"
  | _ => "source"

/-- Build traceability entries by walking Core functions and looking up
    their counterparts in mono/SSA stages. -/
private def collectTraceEntries
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List TraceEntry :=
  -- Build extraction entries
  let externNames := coreModules.foldl (fun acc m => acc ++ collectExternNames m) []
  let extractionEntries := coreModules.foldl (fun acc m =>
    acc ++ collectExtractionEntries externNames locMap m (registry := registry)) []
  -- Build proof status entries
  let graph := buildCallGraph coreModules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let eligibility := coreModules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let proofEntries := coreModules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  -- Collect mono names
  let allMonoNames := monoModules.foldl (fun acc m => acc ++ collectMonoFnNames m) []
  -- Collect SSA names
  let allSSAFns := ssaModules.foldl (fun acc sm =>
    acc ++ sm.functions.map fun f => (f.name, f.isEntryPoint)) []
  -- Build entries
  extractionEntries.map fun ext =>
    let bareName := match ext.qualName.splitOn "." with
      | parts => parts.getLast!
    -- Find proof status
    let proofEntry := proofEntries.find? fun e => e.qualName == ext.qualName
    let evidence := match proofEntry with
      | some e => match e.state with
        | .proved => "proved"
        | .stale => "stale"
        | .notProved => "enforced"
        | .notEligible => "reported"
        | .trusted => "trusted-assumption"
      | none => "unknown"
    let extStatus := if ext.eligible then
      (if ext.extracted.isSome then "extracted" else "eligible_not_extractable")
    else "excluded"
    let pcForm := match ext.extracted with
      | some pexpr => renderPExpr pexpr
      | none => ""
    -- Mono names: find specializations that start with the bare name
    let specPrefix := bareName ++ "_for_"
    let matchesMono (mn : String) : Bool :=
      if mn.endsWith ("." ++ bareName) then true
      else
        let parts := mn.splitOn specPrefix
        parts.length != 1
    let monoMatches := allMonoNames.filter matchesMono
    -- SSA names: find matching functions
    let ssaMatches := allSSAFns.filter fun (sn, _) =>
      sn == bareName || sn.startsWith (bareName ++ "_for_")
    let ssaNames := ssaMatches.map (·.1)
    let llvmNames := ssaMatches.map fun (sn, isEntry) => llvmSymbol sn isEntry
    let boundary := claimBoundaryFor evidence ext.extracted.isSome
    { sourceFunction := ext.qualName
    , fingerprint := ext.fingerprint
    , extractionStatus := extStatus
    , proofCoreForm := pcForm
    , evidenceLevel := evidence
    , coreNames := [ext.qualName]
    , monoNames := monoMatches
    , ssaNames := ssaNames
    , llvmNames := llvmNames
    , specName := ext.specName
    , proofName := ext.proofName
    , claimBoundary := boundary
    , loc := ext.loc }

/-- Render the traceability report. -/
def traceabilityReport
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : String :=
  let entries := collectTraceEntries coreModules monoModules ssaModules locMap registry
  let header := "=== Source/Core/SSA/LLVM Traceability ==="
  let body := entries.map fun e =>
    let locStr := fmtLoc e.loc
    let monoStr := if e.monoNames.isEmpty then "(not monomorphized)"
      else ", ".intercalate e.monoNames
    let ssaStr := if e.ssaNames.isEmpty then "(not lowered)"
      else ", ".intercalate e.ssaNames
    let llvmStr := if e.llvmNames.isEmpty then "(not emitted)"
      else ", ".intercalate e.llvmNames
    let pcStr := if e.proofCoreForm.isEmpty then ""
      else s!"\n    proof_core:   {e.proofCoreForm}"
    let specStr := if e.specName.isEmpty then "" else s!"\n    spec:         {e.specName}"
    let proofStr := if e.proofName.isEmpty then "" else s!"\n    proof:        {e.proofName}"
    s!"  {e.sourceFunction}\n    evidence:     {e.evidenceLevel}\n    extraction:   {e.extractionStatus}{pcStr}{specStr}{proofStr}\n    core:         {", ".intercalate e.coreNames}\n    mono:         {monoStr}\n    ssa:          {ssaStr}\n    llvm:         {llvmStr}\n    boundary:     {e.claimBoundary}\n    fingerprint:  {e.fingerprint}\n    loc:          {locStr}"
  let evidenceCounts := entries.foldl (fun acc e =>
    match e.evidenceLevel with
    | "proved" => { acc with fst := acc.fst + 1 }
    | "enforced" => { acc with snd := { acc.snd with fst := acc.snd.fst + 1 } }
    | "reported" => { acc with snd := { acc.snd with snd := { acc.snd.snd with fst := acc.snd.snd.fst + 1 } } }
    | _ => { acc with snd := { acc.snd with snd := { acc.snd.snd with snd := acc.snd.snd.snd + 1 } } }
    ) (0, (0, (0, 0)))
  let (proved, (enforced, (reported, other))) := evidenceCounts
  let summary := s!"Totals: {entries.length} functions — {proved} proved, {enforced} enforced, {reported} reported, {other} other"
  s!"{header}\n\n{"\n\n".intercalate body}\n\n{summary}\n"

-- ============================================================
-- Machine-readable facts (--report diagnostics-json)
-- ============================================================
-- Structured diagnostic records for predictable violations and
-- proof-status entries. JSON output, no external dependencies.

namespace Json

/-- Escape a string for JSON output. -/
private def escapeStr (s : String) : String :=
  s.foldl (fun acc c =>
    acc ++ match c with
    | '"' => "\\\""
    | '\\' => "\\\\"
    | '\n' => "\\n"
    | '\t' => "\\t"
    | c => c.toString) ""

/-- A minimal JSON value. -/
inductive Val where
  | str : String → Val
  | num : Int → Val
  | bool : Bool → Val
  | null : Val
  | arr : List Val → Val
  | obj : List (String × Val) → Val

/-- Render a JSON value. -/
partial def Val.render : Val → String
  | .str s => s!"\"{escapeStr s}\""
  | .num n => toString n
  | .bool b => if b then "true" else "false"
  | .null => "null"
  | .arr vs => s!"[{", ".intercalate (vs.map Val.render)}]"
  | .obj kvs =>
    let fields := kvs.map fun (k, v) => s!"\"{escapeStr k}\": {v.render}"
    s!"\{{", ".intercalate fields}}"

end Json

-- ============================================================
-- Minimal JSON parser (reads back our own diagnostics output)
-- ============================================================

namespace JsonParser

/-- Work on an Array of characters with Nat indices to avoid String.Pos issues. -/
private def skipWS (cs : Array Char) (pos : Nat) : Nat :=
  if h : pos < cs.size then
    let c := cs[pos]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' then skipWS cs (pos + 1)
    else pos
  else pos

private partial def parseString (cs : Array Char) (pos : Nat) : Option (String × Nat) :=
  if pos >= cs.size || cs[pos]! != '"' then none
  else
    let rec go (i : Nat) (acc : String) : Option (String × Nat) :=
      if i >= cs.size then none
      else
        let c := cs[i]!
        if c == '"' then some (acc, i + 1)
        else if c == '\\' then
          if i + 1 >= cs.size then none
          else
            let esc := cs[i + 1]!
            let ch := match esc with
              | '"' => '"'
              | '\\' => '\\'
              | 'n' => '\n'
              | 't' => '\t'
              | '/' => '/'
              | _ => esc
            go (i + 2) (acc.push ch)
        else go (i + 1) (acc.push c)
    go (pos + 1) ""

private partial def parseNumber (cs : Array Char) (pos : Nat) : Option (Int × Nat) :=
  let neg := pos < cs.size && cs[pos]! == '-'
  let start := if neg then pos + 1 else pos
  let rec go (i : Nat) (acc : Nat) : (Nat × Nat) :=
    if i >= cs.size then (acc, i)
    else
      let c := cs[i]!
      if c.isDigit then go (i + 1) (acc * 10 + (c.toNat - '0'.toNat))
      else (acc, i)
  let (n, endPos) := go start 0
  if endPos == start then none
  else some (if neg then -↑n else ↑n, endPos)

private partial def matchWord (cs : Array Char) (pos : Nat) (word : String) : Bool :=
  let wcs := word.toList
  let rec go (i : Nat) (ws : List Char) : Bool :=
    match ws with
    | [] => true
    | w :: rest =>
      if pos + i >= cs.size then false
      else if cs[pos + i]! == w then go (i + 1) rest
      else false
  go 0 wcs

partial def parseValue (cs : Array Char) (pos : Nat) : Option (Json.Val × Nat) :=
  let p := skipWS cs pos
  if p >= cs.size then none
  else
    let c := cs[p]!
    if c == '"' then
      match parseString cs p with
      | some (str, next) => some (.str str, next)
      | none => none
    else if c == '[' then
      parseArray cs (p + 1)
    else if c == '{' then
      parseObject cs (p + 1)
    else if c == 't' && matchWord cs p "true" then
      some (.bool true, p + 4)
    else if c == 'f' && matchWord cs p "false" then
      some (.bool false, p + 5)
    else if c == 'n' && matchWord cs p "null" then
      some (.null, p + 4)
    else if c == '-' || c.isDigit then
      match parseNumber cs p with
      | some (n, next) => some (.num n, next)
      | none => none
    else none

where
  parseArray (cs : Array Char) (pos : Nat) : Option (Json.Val × Nat) :=
    let p := skipWS cs pos
    if p < cs.size && cs[p]! == ']' then some (.arr [], p + 1)
    else
      let rec go (i : Nat) (acc : List Json.Val) : Option (Json.Val × Nat) :=
        match parseValue cs i with
        | none => none
        | some (v, next) =>
          let next := skipWS cs next
          if next >= cs.size then none
          else if cs[next]! == ']' then some (.arr (acc ++ [v]), next + 1)
          else if cs[next]! == ',' then go (next + 1) (acc ++ [v])
          else none
      go p []

  parseObject (cs : Array Char) (pos : Nat) : Option (Json.Val × Nat) :=
    let p := skipWS cs pos
    if p < cs.size && cs[p]! == '}' then some (.obj [], p + 1)
    else
      let rec go (i : Nat) (acc : List (String × Json.Val)) : Option (Json.Val × Nat) :=
        let i := skipWS cs i
        match parseString cs i with
        | none => none
        | some (key, next) =>
          let next := skipWS cs next
          if next >= cs.size || cs[next]! != ':' then none
          else
            match parseValue cs (next + 1) with
            | none => none
            | some (v, next) =>
              let next := skipWS cs next
              if next >= cs.size then none
              else if cs[next]! == '}' then some (.obj (acc ++ [(key, v)]), next + 1)
              else if cs[next]! == ',' then go (next + 1) (acc ++ [(key, v)])
              else none
      go p []

def parse (s : String) : Option Json.Val :=
  let cs := s.toList.toArray
  match parseValue cs 0 with
  | some (v, _) => some v
  | none => none

end JsonParser

open Json in
/-- Convert a SourceLoc to a JSON object. -/
private def locToJson : Option SourceLoc → Val
  | some (file, line) => .obj [("file", .str file), ("line", .num line)]
  | none => .null

open Json in
/-- Convert a ProfileViolation to a JSON fact. -/
private def violationToFact (v : ProfileViolation) : Val :=
  .obj [
    ("kind", .str "predictable_violation"),
    ("function", .str v.fnName),
    ("state", .str "failed"),
    ("reason", .str v.reason),
    ("hint", .str v.hint),
    ("loc", locToJson v.loc),
    ("violation_loc", locToJson v.violationLoc)
  ]

open Json in
/-- Convert a ProofStatusEntry to a JSON fact. -/
private def proofStatusToFact (e : ProofStatusEntry) : Val :=
  let stateStr := match e.state with
    | .proved => "proved"
    | .stale => "stale"
    | .notProved => "no_proof"
    | .notEligible => "not_eligible"
    | .trusted => "trusted"
  let hintStr := match e.state with
    | .stale => "Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
    | .notProved => "Add a Lean proof for this function in Concrete/Proof.lean with the current fingerprint."
    | .notEligible => s!"Remove {", ".intercalate e.profileGates} to make this function eligible for proof."
    | _ => ""
  .obj ([
    ("kind", .str "proof_status"),
    ("function", .str e.qualName),
    ("state", .str stateStr),
    ("loc", locToJson e.loc),
    ("current_fingerprint", .str e.currentFp)
  ] ++ (if e.expectedFp.isEmpty then [] else [("expected_fingerprint", .str e.expectedFp)])
    ++ (if e.specName.isEmpty then [] else [("spec", .str e.specName)])
    ++ (if e.proofName.isEmpty then [] else [("proof", .str e.proofName)])
    ++ (if e.proofSource == "none" then [] else [("source", .str e.proofSource)])
    ++ (if e.profileGates.isEmpty then [] else [("profile_gates", .arr (e.profileGates.map .str))])
    ++ (if hintStr.isEmpty then [] else [("hint", .str hintStr)]))

open Json in
/-- Collect predictable violations as structured facts. -/
def collectPredictableFacts (modules : List CModule) (locMap : FnLocMap := []) : List Val :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap externNames locMap m) []
  violations.map violationToFact

open Json in
/-- Convert an eligibility entry to a JSON fact. -/
private def eligibilityToFact (e : EligibilityEntry) : Val :=
  let statusStr := if e.isTrusted then "trusted"
    else if e.eligible then "eligible"
    else "excluded"
  let exclusionStr := match e.exclusionKind with
    | some .source => "source"
    | some .profile => "profile"
    | some .both => "both"
    | none => "none"
  .obj ([
    ("kind", .str "eligibility"),
    ("function", .str e.qualName),
    ("status", .str statusStr),
    ("exclusion_kind", .str exclusionStr),
    ("source_reasons", .arr (e.sourceReasons.map .str)),
    ("profile_reasons", .arr (e.profileReasons.map .str)),
    ("loc", locToJson e.loc)
  ])

open Json in
/-- Collect eligibility facts for all functions. -/
def collectEligibilityFacts (modules : List CModule) (locMap : FnLocMap := []) : List Val :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  entries.map eligibilityToFact

open Json in
/-- Collect proof-status entries as structured facts. -/
def collectProofStatusFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List Val :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let eligibility := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  entries.map proofStatusToFact

open Json in
/-- Convert an obligation entry to a JSON fact. -/
private def obligationToFact (e : ObligationEntry) : Val :=
  .obj ([
    ("kind", .str "obligation"),
    ("function", .str e.function),
    ("status", .str e.status),
    ("spec", .str e.spec),
    ("proof", .str e.proof),
    ("source", .str e.source),
    ("fingerprint", .str e.fingerprint),
    ("dependencies", .arr (e.dependencies.map .str)),
    ("loc", locToJson e.loc)
  ])

open Json in
/-- Collect obligation facts for all functions. -/
def collectObligationFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List Val :=
  let entries := collectObligations modules locMap registry
  entries.map obligationToFact

open Json in
/-- Convert an extraction entry to a JSON fact. -/
private def extractionToFact (e : ExtractionEntry) : Val :=
  let statusStr := if e.eligible then
    match e.extracted with
    | some _ => "extracted"
    | none => "eligible_not_extractable"
  else "excluded"
  let proofCoreStr := match e.extracted with
    | some pexpr => renderPExpr pexpr
    | none => ""
  .obj ([
    ("kind", .str "extraction"),
    ("function", .str e.qualName),
    ("status", .str statusStr),
    ("eligible", .bool e.eligible),
    ("fingerprint", .str e.fingerprint),
    ("params", .arr (e.params.map .str)),
    ("loc", locToJson e.loc)
  ] ++ (if proofCoreStr.isEmpty then [] else [("proof_core", .str proofCoreStr)])
    ++ (if e.specName.isEmpty then [] else [("spec", .str e.specName)])
    ++ (if e.proofName.isEmpty then [] else [("proof", .str e.proofName)])
    ++ (if e.excluded.isEmpty then [] else [("excluded_reasons", .arr (e.excluded.map .str))])
    ++ (if e.unsupported.isEmpty then [] else [("unsupported", .arr (e.unsupported.map .str))]))

open Json in
/-- Collect extraction facts for all functions. -/
def collectExtractionFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List Val :=
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectExtractionEntries externNames locMap m "" registry) []
  entries.map extractionToFact

open Json in
/-- Convert a traceability entry to a JSON fact. -/
private def traceToFact (e : TraceEntry) : Val :=
  .obj ([
    ("kind", .str "traceability"),
    ("function", .str e.sourceFunction),
    ("evidence", .str e.evidenceLevel),
    ("extraction", .str e.extractionStatus),
    ("core", .arr (e.coreNames.map .str)),
    ("mono", .arr (e.monoNames.map .str)),
    ("ssa", .arr (e.ssaNames.map .str)),
    ("llvm", .arr (e.llvmNames.map .str)),
    ("boundary", .str e.claimBoundary),
    ("fingerprint", .str e.fingerprint),
    ("spec", .str e.specName),
    ("proof", .str e.proofName),
    ("loc", locToJson e.loc)
  ] ++ (if e.proofCoreForm.isEmpty then [] else [("proof_core", .str e.proofCoreForm)]))

open Json in
/-- Collect traceability facts for all functions. -/
def collectTraceabilityFacts
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List Val :=
  let entries := collectTraceEntries coreModules monoModules ssaModules locMap registry
  entries.map traceToFact

open Json in
/-- Query traceability facts, optionally filtered by function name. -/
def queryTraceability
    (coreModules : List CModule)
    (monoModules : List CModule)
    (ssaModules : List SModule)
    (locMap : FnLocMap := [])
    (fnFilter : Option String := none)
    (registry : ProofRegistry := []) : String :=
  let allFacts := collectTraceabilityFacts coreModules monoModules ssaModules locMap registry
  let getStr (v : Val) (key : String) : Option String :=
    match v with
    | .obj kvs =>
      match kvs.find? (fun (k, _) => k == key) with
      | some (_, .str s) => some s
      | _ => none
    | _ => none
  let filtered := match fnFilter with
    | none => allFacts
    | some fnName => allFacts.filter fun v =>
      match getStr v "function" with
      | some f => f == fnName || f.endsWith ("." ++ fnName)
      | none => false
  (Val.arr filtered).render

open Json in
/-- Convert an FnEffects record to a JSON fact. -/
private def effectsToFact (e : FnEffects) : Val :=
  let (concreteCaps, _) := e.capSet.normalize
  .obj [
    ("kind", .str "effects"),
    ("function", .str e.name),
    ("capabilities", .arr (concreteCaps.map .str)),
    ("is_pure", .bool (e.capSet == .empty)),
    ("allocates", .bool e.allocates),
    ("frees", .bool e.frees),
    ("defers", .bool e.defers),
    ("recursion", .str e.recursion),
    ("loops", .str e.loops),
    ("crosses_ffi", .bool e.crossesFfi),
    ("is_trusted", .bool e.isTrusted),
    ("is_public", .bool e.isPublic),
    ("evidence", .str e.evidence),
    ("loc", locToJson e.loc)
  ]

open Json in
/-- Collect effects facts for all functions. -/
def collectEffectsFacts (modules : List CModule) (locMap : FnLocMap := []) : List Val :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule externNames recMap locMap m) []
  allEffects.map effectsToFact

open Json in
/-- Convert a per-function capability entry with why-traces to a JSON fact. -/
private def capToFact (lookup : CapLookup) (f : CFnDef) : Val :=
  let (concreteCaps, _) := f.capSet.normalize
  let callees := collectCallsStmts f.body |>.eraseDups
  let traces := concreteCaps.map fun cap =>
    let contributors := callees.filter fun callee =>
      match lookupCalleeCap lookup callee with
      | some cs => let (cc, _) := cs.normalize; cc.contains cap
      | none => false
    .obj [
      ("capability", .str cap),
      ("source", .str (if contributors.isEmpty then "declared"
        else ", ".intercalate contributors))
    ]
  .obj [
    ("kind", .str "capability"),
    ("function", .str f.name),
    ("capabilities", .arr (concreteCaps.map .str)),
    ("is_pure", .bool concreteCaps.isEmpty),
    ("is_public", .bool f.isPublic),
    ("why", .arr traces)
  ]

open Json in
/-- Collect capability facts with why-traces for all functions. -/
private partial def collectCapFactsModule (lookup : CapLookup) (m : CModule) : List Val :=
  let fnFacts := m.functions.map (capToFact lookup)
  let externFacts := m.externFns.map fun (n, _, _, trusted) =>
    .obj [
      ("kind", .str "capability"),
      ("function", .str n),
      ("capabilities", .arr (if trusted then [] else [Val.str unsafeCapName])),
      ("is_pure", .bool trusted),
      ("is_extern", .bool true),
      ("is_trusted", .bool trusted),
      ("why", .arr [])
    ]
  fnFacts ++ externFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectCapFactsModule lookup sub) []

open Json in
def collectCapFacts (modules : List CModule) : List Val :=
  let lookup := buildCapLookup modules
  modules.foldl (fun acc m => acc ++ collectCapFactsModule lookup m) []

open Json in
/-- Convert a function's unsafe/trust boundary info to a JSON fact. -/
private partial def collectUnsafeFactsModule (externNames : List String) (m : CModule) : List Val :=
  let fnFacts := m.functions.filterMap fun f =>
    let hasUnsafe := hasUnsafeCap f.capSet
    let hasRawPtrs := fnUsesRawPtrs f
    let trusted := f.isTrusted
    if !hasUnsafe && !hasRawPtrs && !trusted then none
    else
      let boundary := if trusted then trustBoundaryAnalysis externNames f else []
      some (.obj [
        ("kind", .str "unsafe"),
        ("function", .str f.name),
        ("has_unsafe_cap", .bool hasUnsafe),
        ("has_raw_pointers", .bool hasRawPtrs),
        ("is_trusted", .bool trusted),
        ("trust_boundary", .arr (boundary.map .str))
      ])
  let externFacts := m.externFns.map fun (n, _, _, trusted) =>
    .obj [
      ("kind", .str "unsafe"),
      ("function", .str n),
      ("is_extern", .bool true),
      ("is_trusted", .bool trusted)
    ]
  fnFacts ++ externFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectUnsafeFactsModule externNames sub) []

open Json in
def collectUnsafeFacts (modules : List CModule) : List Val :=
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  modules.foldl (fun acc m => acc ++ collectUnsafeFactsModule externNames m) []

open Json in
/-- Convert a function's allocation info to a JSON fact. -/
private def allocToFact (f : CFnDef) : Option Val :=
  let callees := collectCallsStmts f.body |>.eraseDups
  let allocs := callees.filter isAllocCall
  let frees := callees.filter isFreeCall
  let defers := collectDefersStmts f.body
  if allocs.isEmpty && frees.isEmpty && defers.isEmpty then none
  else
    let returnsAlloc := returnsAllocation f.retTy
    let leaks := !allocs.isEmpty && frees.isEmpty && defers.isEmpty && !returnsAlloc
    some (.obj [
      ("kind", .str "alloc"),
      ("function", .str f.name),
      ("allocates", .arr (allocs.map .str)),
      ("frees", .arr (frees.map .str)),
      ("defers", .arr (defers.map .str)),
      ("returns_allocation", .bool returnsAlloc),
      ("potential_leak", .bool leaks)
    ])

open Json in
private partial def collectAllocFactsModule (m : CModule) : List Val :=
  let fnFacts := m.functions.filterMap allocToFact
  fnFacts ++ m.submodules.foldl (fun acc sub =>
    acc ++ collectAllocFactsModule sub) []

open Json in
def collectAllocFacts (modules : List CModule) : List Val :=
  modules.foldl (fun acc m => acc ++ collectAllocFactsModule m) []

open Json in
/-- Collect all core facts (everything except traceability) into a flat list. -/
def collectCoreFacts (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : List Val :=
  let eligibility := collectEligibilityFacts modules locMap
  let predictable := collectPredictableFacts modules locMap
  let proofStatus := collectProofStatusFacts modules locMap registry
  let obligations := collectObligationFacts modules locMap registry
  let extraction := collectExtractionFacts modules locMap (registry := registry)
  let effects := collectEffectsFacts modules locMap
  let caps := collectCapFacts modules
  let unsafeFacts := collectUnsafeFacts modules
  let alloc := collectAllocFacts modules
  let base := eligibility ++ predictable ++ proofStatus ++ obligations ++ extraction
  base ++ effects ++ caps ++ unsafeFacts ++ alloc

open Json in
/-- Produce JSON diagnostics combining all fact types. -/
def diagnosticsJson (modules : List CModule) (locMap : FnLocMap := [])
    (registry : ProofRegistry := []) : String :=
  (Val.arr (collectCoreFacts modules locMap registry)).render

open Json in
/-- Extract a string field from a JSON object. -/
def jsonGetStr (v : Val) (key : String) : Option String :=
  match v with
  | .obj kvs =>
    match kvs.find? (fun (k, _) => k == key) with
    | some (_, .str s) => some s
    | _ => none
  | _ => none

-- ============================================================
-- Semantic query: why-capability trace
-- ============================================================

/-- Build a flat lookup of bare function names to CFnDef across module tree. -/
private partial def buildFnLookupModule (m : CModule) : List (String × CFnDef) :=
  let fns := m.functions.map fun f => (f.name, f)
  fns ++ m.submodules.foldl (fun acc sub => acc ++ buildFnLookupModule sub) []

private def buildFnLookup (modules : List CModule) : List (String × CFnDef) :=
  modules.foldl (fun acc m => acc ++ buildFnLookupModule m) []

/-- Build a flat extern name → trusted lookup. -/
private partial def buildExternLookupModule (m : CModule) : List (String × Bool) :=
  let exts := m.externFns.map fun (n, _, _, t) => (n, t)
  exts ++ m.submodules.foldl (fun acc sub => acc ++ buildExternLookupModule sub) []

private def buildExternLookup (modules : List CModule) : List (String × Bool) :=
  modules.foldl (fun acc m => acc ++ buildExternLookupModule m) []

open Json in
/-- Trace why a function requires a specific capability.
    Returns a list of trace steps from the queried function down to the origin.
    Stops at: declared (with clause), extern, intrinsic, or depth limit.
    visited prevents cycles. -/
private partial def traceCapability
    (fnLookup : List (String × CFnDef))
    (externLookup : List (String × Bool))
    (capLookup : CapLookup)
    (locMap : FnLocMap)
    (fnName : String) (cap : String)
    (visited : List String := []) (depth : Nat := 0) : List Val :=
  if depth > 20 then [.obj [("function", .str fnName), ("error", .str "depth limit")]]
  else if visited.contains fnName then [.obj [("function", .str fnName), ("error", .str "cycle")]]
  else
    -- Is it an intrinsic?
    match resolveIntrinsic fnName with
    | some iid =>
      match iid.capability with
      | some icap =>
        if icap == cap then [.obj [("function", .str fnName), ("origin", .str "intrinsic")]]
        else []
      | none => []
    | none =>
    -- Is it an extern?
    match externLookup.find? (fun (n, _) => n == fnName) with
    | some (_, trusted) =>
      if !trusted then
        -- Untrusted externs have Unsafe capability
        if cap == unsafeCapName then
          [.obj [("function", .str fnName), ("origin", .str "extern")]]
        else []
      else []  -- trusted externs have no capabilities
    | none =>
    -- Is it a user function?
    match fnLookup.find? (fun (n, _) => n == fnName) with
    | none => []
    | some (_, f) =>
      let (concreteCaps, _) := f.capSet.normalize
      -- Check if this function even has the cap
      if !concreteCaps.contains cap then []
      else
        let callees := collectCallsStmts f.body |>.eraseDups
        let visited' := fnName :: visited
        -- Find callees that contribute this cap
        let contributors := callees.filter fun callee =>
          match lookupCalleeCap capLookup callee with
          | some cs => let (cc, _) := cs.normalize; cc.contains cap
          | none => false
        if contributors.isEmpty then
          -- No callee contributes it → declared via with(...)
          let loc := locMap.find? (fun e => e.qualName.endsWith ("." ++ fnName) || e.qualName == fnName)
          let locVal := match loc with
            | some e => locToJson (some (e.file, e.fnSpan.line))
            | none => Val.null
          [.obj [("function", .str fnName), ("origin", .str "declared"), ("loc", locVal)]]
        else
          -- Trace through each contributor
          contributors.foldl (fun acc callee =>
            let subTrace := traceCapability fnLookup externLookup capLookup locMap
              callee cap visited' (depth + 1)
            if subTrace.isEmpty then acc
            else
              let step := Val.obj [("function", .str fnName), ("edge", .str "calls"), ("callee", .str callee)]
              acc ++ [step] ++ subTrace
          ) []

open Json in
/-- Handle a why-capability query. Returns answer-shaped JSON. -/
def whyCapabilityQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (cap : String) : String :=
  let fnLookup := buildFnLookup modules
  let externLookup := buildExternLookup modules
  let capLookup := buildCapLookup modules
  let trace := traceCapability fnLookup externLookup capLookup locMap fnName cap
  let answer :=
    if trace.isEmpty then "not_required"
    else
      -- Check if first trace step is a declaration (no transitive path)
      match trace with
      | [.obj kvs] =>
        match kvs.find? (fun (k, _) => k == "origin") with
        | some (_, .str "declared") => "declared"
        | some (_, .str "intrinsic") => "intrinsic"
        | some (_, .str "extern") => "extern"
        | _ => "transitive"
      | _ => "transitive"
  let result := Val.obj [
    ("kind", .str "query_answer"),
    ("query", .str s!"why-capability:{fnName}:{cap}"),
    ("function", .str fnName),
    ("capability", .str cap),
    ("answer", .str answer),
    ("trace", .arr trace)
  ]
  result.render

open Json in
/-- Handle a predictable query for a single function. Returns answer-shaped JSON. -/
def predictableQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) : String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap externNames locMap m) []
  let fnViolations := violations.filter fun v =>
    v.fnName == fnName
  let answer := if fnViolations.isEmpty then "pass" else "fail"
  let gates := fnViolations.map fun v =>
    .obj ([
      ("gate", .str v.reason),
      ("hint", .str v.hint)
    ] ++ match v.loc with
      | some l => [("loc", locToJson (some l))]
      | none => []
    ++ match v.violationLoc with
      | some l => [("violation_loc", locToJson (some l))]
      | none => [])
  let result := Val.obj [
    ("kind", .str "query_answer"),
    ("query", .str s!"predictable:{fnName}"),
    ("function", .str fnName),
    ("answer", .str answer),
    ("gates_failed", .num (Int.ofNat fnViolations.length)),
    ("violations", .arr gates)
  ]
  result.render

open Json in
/-- Handle a proof query for a single function. Returns answer-shaped JSON. -/
def proofQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := []) : String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let eligibility := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  let fnEntry := entries.find? fun e =>
    e.bareName == fnName || e.qualName == fnName || e.qualName.endsWith ("." ++ fnName)
  match fnEntry with
  | none =>
    (Val.obj [
      ("kind", .str "query_answer"),
      ("query", .str s!"proof:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some e =>
    let stateStr := match e.state with
      | .proved => "proved" | .stale => "stale" | .notProved => "no_proof"
      | .notEligible => "not_eligible" | .trusted => "trusted"
    let hintStr := match e.state with
      | .stale => "Update the Lean proof in Concrete/Proof.lean, or restore the proved implementation."
      | .notProved => "Add a Lean proof for this function in Concrete/Proof.lean with the current fingerprint."
      | .notEligible => s!"Remove {", ".intercalate e.profileGates} to make this function eligible for proof."
      | _ => ""
    (Val.obj ([
      ("kind", .str "query_answer"),
      ("query", .str s!"proof:{fnName}"),
      ("function", .str e.qualName),
      ("answer", .str stateStr),
      ("current_fingerprint", .str e.currentFp)
    ] ++ (if e.expectedFp.isEmpty then [] else [("expected_fingerprint", .str e.expectedFp)])
      ++ (if e.profileGates.isEmpty then [] else [("profile_gates", .arr (e.profileGates.map .str))])
      ++ (if hintStr.isEmpty then [] else [("hint", .str hintStr)])
      ++ [("loc", locToJson e.loc)])).render

open Json in
/-- Handle an evidence query for a single function. Returns answer-shaped JSON
    combining predictable profile, proof status, and trust into one answer. -/
def evidenceQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := []) : String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  -- Get effects for evidence level
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule externNames recMap locMap m) []
  let fnEffects := allEffects.find? fun e => e.name == fnName
  -- Get violations
  let violations := modules.foldl (fun acc m =>
    acc ++ checkPredictableModule recMap externNames locMap m) []
  let fnViolations := violations.filter fun v => v.fnName == fnName
  -- Get proof status
  let eligibility := modules.foldl (fun acc m =>
    acc ++ collectEligibility externNames recMap locMap m) []
  let entries := modules.foldl (fun acc m =>
    acc ++ collectProofStatus eligibility locMap m "" registry) []
  let fnProof := entries.find? fun e =>
    e.bareName == fnName || e.qualName.endsWith ("." ++ fnName)
  match fnEffects with
  | none =>
    (Val.obj [
      ("kind", .str "query_answer"),
      ("query", .str s!"evidence:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some eff =>
    let proofState := match fnProof with
      | some e => match e.state with
        | .proved => "proved" | .stale => "stale" | .notProved => "no_proof"
        | .notEligible => "not_eligible" | .trusted => "trusted"
      | none => "unknown"
    let gatesFailed := fnViolations.map fun v => Val.str v.reason
    (Val.obj [
      ("kind", .str "query_answer"),
      ("query", .str s!"evidence:{fnName}"),
      ("function", .str fnName),
      ("answer", .str eff.evidence),
      ("is_trusted", .bool eff.isTrusted),
      ("passes_predictable", .bool fnViolations.isEmpty),
      ("proof_state", .str proofState),
      ("gates_failed", .arr gatesFailed),
      ("loc", locToJson eff.loc)
    ]).render

open Json in
/-- Handle an audit query for a single function. Bundles authority, predictable
    profile, proof status, evidence, trust, and allocation into one answer. -/
def auditQuery (modules : List CModule) (locMap : FnLocMap)
    (fnName : String) (registry : ProofRegistry := []) : String :=
  let graph := buildCallGraph modules
  let sccs := tarjanSCC graph
  let recMap := classifyRecursion graph sccs
  let externNames := modules.foldl (fun acc m => acc ++ collectExternNames m) []
  let capLookup := buildCapLookup modules
  let fnLookup := buildFnLookup modules
  let externLookup := buildExternLookup modules
  -- Effects
  let allEffects := modules.foldl (fun acc m =>
    acc ++ effectsForModule externNames recMap locMap m) []
  let fnEffects := allEffects.find? fun e => e.name == fnName
  match fnEffects with
  | none =>
    (Val.obj [
      ("kind", .str "query_answer"),
      ("query", .str s!"audit:{fnName}"),
      ("function", .str fnName),
      ("answer", .str "not_found")
    ]).render
  | some eff =>
    -- Capabilities with why traces
    let (concreteCaps, _) := eff.capSet.normalize
    let capTraces := concreteCaps.map fun cap =>
      let trace := traceCapability fnLookup externLookup capLookup locMap fnName cap
      let origin :=
        if trace.isEmpty then "not_required"
        else match trace with
          | [.obj kvs] =>
            match kvs.find? (fun (k, _) => k == "origin") with
            | some (_, .str o) => o
            | _ => "transitive"
          | _ => "transitive"
      .obj [("capability", .str cap), ("origin", .str origin), ("trace", .arr trace)]
    -- Predictable
    let violations := modules.foldl (fun acc m =>
      acc ++ checkPredictableModule recMap externNames locMap m) []
    let fnViolations := violations.filter fun v => v.fnName == fnName
    let violationFacts := fnViolations.map fun v =>
      .obj ([("gate", .str v.reason), ("hint", .str v.hint)]
        ++ match v.violationLoc with
          | some l => [("violation_loc", locToJson (some l))]
          | none => [])
    -- Proof
    let eligibility := modules.foldl (fun acc m =>
      acc ++ collectEligibility externNames recMap locMap m) []
    let entries := modules.foldl (fun acc m =>
      acc ++ collectProofStatus eligibility locMap m "" registry) []
    let fnProof := entries.find? fun e =>
      e.bareName == fnName || e.qualName.endsWith ("." ++ fnName)
    let proofState := match fnProof with
      | some e => match e.state with
        | .proved => "proved" | .stale => "stale" | .notProved => "no_proof"
        | .notEligible => "not_eligible" | .trusted => "trusted"
      | none => "unknown"
    let fingerprint := match fnProof with
      | some e => e.currentFp | none => ""
    -- Allocation
    let fnDef := fnLookup.find? (fun (n, _) => n == fnName)
    let allocInfo := match fnDef with
      | some (_, f) =>
        let callees := collectCallsStmts f.body |>.eraseDups
        let allocs := callees.filter isAllocCall
        let frees := callees.filter isFreeCall
        let defers := collectDefersStmts f.body
        .obj [
          ("allocates", .arr (allocs.map .str)),
          ("frees", .arr (frees.map .str)),
          ("defers", .arr (defers.map .str)),
          ("returns_allocation", .bool (returnsAllocation f.retTy))
        ]
      | none => .obj [("allocates", .arr []), ("frees", .arr []), ("defers", .arr []),
                       ("returns_allocation", .bool false)]
    (Val.obj [
      ("kind", .str "query_answer"),
      ("query", .str s!"audit:{fnName}"),
      ("function", .str fnName),
      ("loc", locToJson eff.loc),
      ("evidence", .str eff.evidence),
      ("is_public", .bool eff.isPublic),
      ("is_trusted", .bool eff.isTrusted),
      ("authority", .obj [
        ("capabilities", .arr (concreteCaps.map .str)),
        ("is_pure", .bool concreteCaps.isEmpty),
        ("traces", .arr capTraces)
      ]),
      ("predictable", .obj [
        ("passes", .bool fnViolations.isEmpty),
        ("violations", .arr violationFacts)
      ]),
      ("proof", .obj ([
        ("state", .str proofState),
        ("fingerprint", .str fingerprint)
      ] ++ match fnProof with
        | some e => if e.profileGates.isEmpty then []
          else [("profile_gates", .arr (e.profileGates.map .str))]
        | none => [])),
      ("allocation", allocInfo)
    ]).render

open Json in
/-- Query compiler facts by kind and optional function name.
    Query formats:
    - "KIND"                  — filter all facts by kind
    - "KIND:FUNCTION"         — filter by kind + function
    - "fn:FUNCTION"           — all facts for one function
    - "why-capability:FN:CAP" — trace why a function requires a capability
    - "predictable:FN"        — predictable profile answer for one function
    - "proof:FN"              — proof status answer for one function
    - "evidence:FN"           — combined evidence answer for one function -/
def queryFacts (modules : List CModule) (locMap : FnLocMap := [])
    (query : String) (registry : ProofRegistry := []) : String :=
  let parts := query.splitOn ":"
  -- Semantic queries: three-part (why-capability:fn:cap)
  if parts.length == 3 then
    match parts with
    | ["why-capability", fnName, cap] => whyCapabilityQuery modules locMap fnName cap
    | _ =>
      -- Fall through to kind:function filter
      let filterKind := parts[0]!
      let filterFn := parts[1]!
      let allFacts := collectCoreFacts modules locMap registry
      let byKind := allFacts.filter fun v => jsonGetStr v "kind" == some filterKind
      let filtered := byKind.filter fun v =>
        match jsonGetStr v "function" with
        | some f => f == filterFn || f.endsWith ("." ++ filterFn)
        | none => false
      (Val.arr filtered).render
  else
  -- Semantic queries: two-part (predictable:fn, proof:fn, evidence:fn)
  if parts.length == 2 then
    match parts with
    | ["predictable", fnName] => predictableQuery modules locMap fnName
    | ["proof", fnName] => proofQuery modules locMap fnName registry
    | ["evidence", fnName] => evidenceQuery modules locMap fnName registry
    | ["audit", fnName] => auditQuery modules locMap fnName registry
    | ["fn", fnName] =>
      let allFacts := collectCoreFacts modules locMap registry
      let filtered := allFacts.filter fun v =>
        match jsonGetStr v "function" with
        | some f => f == fnName || f.endsWith ("." ++ fnName)
        | none => false
      (Val.arr filtered).render
    | _ =>
      -- kind:function filter
      let filterKind := parts[0]!
      let filterFn := parts[1]!
      let allFacts := collectCoreFacts modules locMap registry
      let byKind := allFacts.filter fun v =>
        jsonGetStr v "kind" == some filterKind
      let filtered := byKind.filter fun v =>
        match jsonGetStr v "function" with
        | some f => f == filterFn || f.endsWith ("." ++ filterFn)
        | none => false
      (Val.arr filtered).render
  else
    -- Single-word filter: all facts of this kind
    let allFacts := collectCoreFacts modules locMap registry
    let filtered := allFacts.filter fun v =>
      jsonGetStr v "kind" == some query
    (Val.arr filtered).render

-- ============================================================
-- Semantic diff / trust drift
-- ============================================================
-- Compare two fact bundles (from diagnostics-json) and report
-- changes in capabilities, allocation, evidence, proof state,
-- spec/proof attachment, obligation status, etc.

open Json in
/-- Extract a string from a Val, returning "" for non-strings. -/
private def valStr : Val → String
  | .str s => s
  | .num n => toString n
  | .bool b => if b then "true" else "false"
  | .null => "null"
  | .arr vs => s!"[{", ".intercalate (vs.map valStr)}]"
  | .obj _ => "{...}"

open Json in
/-- Get a field value from a JSON object as a Val. -/
private def jsonGetVal (v : Val) (key : String) : Option Val :=
  match v with
  | .obj kvs => (kvs.find? fun (k, _) => k == key).map (·.2)
  | _ => none

open Json in
/-- Render a Val to a short display string. -/
private def valDisplay : Val → String
  | .str s => s
  | .num n => toString n
  | .bool b => if b then "true" else "false"
  | .null => "null"
  | .arr vs => s!"[{", ".intercalate (vs.map valDisplay)}]"
  | .obj _ => "{…}"

/-- A single field change in a diff entry. -/
structure FieldChange where
  field : String
  oldVal : String
  newVal : String

/-- A single diff entry for one (kind, function) pair. -/
structure DiffEntry where
  kind : String
  function : String
  category : String       -- "added" | "removed" | "changed"
  changes : List FieldChange
  drift : String          -- "weakened" | "strengthened" | "neutral"

/-- Fields to compare for trust-relevant changes per fact kind. -/
private def trustFields (kind : String) : List String :=
  match kind with
  | "proof_status" => ["state", "spec", "proof", "source", "current_fingerprint"]
  | "obligation" => ["status", "spec", "proof", "source", "fingerprint"]
  | "extraction" => ["status", "eligible", "spec", "proof", "proof_core", "fingerprint"]
  | "effects" => ["capabilities", "is_pure", "allocates", "frees", "recursion",
                   "loops", "crosses_ffi", "is_trusted", "evidence"]
  | "capability" => ["capabilities", "is_pure"]
  | "unsafe" => ["has_unsafe_cap", "has_raw_pointers", "is_trusted"]
  | "alloc" => ["allocates", "frees", "defers", "potential_leak"]
  | "predictable_violation" => ["state", "reason"]
  | "traceability" => ["evidence", "extraction", "boundary", "spec", "proof", "fingerprint"]
  | _ => []

/-- Evidence level ordering for drift detection (higher = stronger). -/
private def evidenceRank (s : String) : Nat :=
  match s with
  | "proved" => 5
  | "stale" => 4
  | "enforced" => 3
  | "trusted-assumption" => 2
  | "reported" => 1
  | _ => 0

/-- Proof state ordering (higher = stronger). -/
private def proofStateRank (s : String) : Nat :=
  match s with
  | "proved" => 4
  | "stale" => 3
  | "no_proof" => 2
  | "not_eligible" => 1
  | "trusted" => 2
  | _ => 0

/-- Determine if a field change represents trust weakening. -/
private def isWeakening (kind : String) (field : String) (oldV newV : String) : Bool :=
  match kind, field with
  | "proof_status", "state" => proofStateRank newV < proofStateRank oldV
  | "obligation", "status" => proofStateRank newV < proofStateRank oldV
  | "effects", "evidence" => evidenceRank newV < evidenceRank oldV
  | "effects", "is_pure" => oldV == "true" && newV == "false"
  | "effects", "is_trusted" => oldV == "false" && newV == "true"
  | "effects", "crosses_ffi" => oldV == "false" && newV == "true"
  | "capability", "is_pure" => oldV == "true" && newV == "false"
  | "alloc", "potential_leak" => oldV == "false" && newV == "true"
  | "traceability", "evidence" => evidenceRank newV < evidenceRank oldV
  | "extraction", "status" =>
    let oldRank := match oldV with | "extracted" => 3 | "eligible_not_extractable" => 2 | _ => 1
    let newRank := match newV with | "extracted" => 3 | "eligible_not_extractable" => 2 | _ => 1
    newRank < oldRank
  | _, _ => false

/-- Determine if a field change represents trust strengthening. -/
private def isStrengthening (kind : String) (field : String) (oldV newV : String) : Bool :=
  isWeakening kind field newV oldV

open Json in
/-- Compare two facts and return field changes. -/
private def compareFacts (kind : String) (oldFact newFact : Val) : List FieldChange :=
  let fields := trustFields kind
  fields.filterMap fun f =>
    let oldV := (jsonGetVal oldFact f).map valDisplay |>.getD ""
    let newV := (jsonGetVal newFact f).map valDisplay |>.getD ""
    if oldV == newV then none
    else some { field := f, oldVal := oldV, newVal := newV }

open Json in
/-- Build a keyed map: (kind, function) → Val for a list of facts.
    For fact kinds that allow multiple entries per function (e.g.,
    predictable_violation), the key includes a disambiguator. -/
private def keyFacts (facts : List Val) : List ((String × String) × Val) :=
  facts.filterMap fun v =>
    match jsonGetStr v "kind", jsonGetStr v "function" with
    | some k, some f =>
      -- Disambiguate multi-per-function fact kinds
      let suffix := match k with
        | "predictable_violation" => (jsonGetStr v "reason").getD ""
        | _ => ""
      let key := if suffix.isEmpty then (k, f) else (k, f ++ ":" ++ suffix)
      some (key, v)
    | _, _ => none

open Json in
/-- Classify a newly-added fact as weakened or neutral based on its content.
    New functions with weak evidence, non-pure capabilities, FFI, or trust
    markers are real drift and should be flagged. -/
private def classifyNewFact (kind : String) (v : Val) : String :=
  match kind with
  | "predictable_violation" => "weakened"
  | "unsafe" => "weakened"
  | "effects" =>
    let ev := (jsonGetVal v "evidence").map valDisplay |>.getD ""
    let pure := (jsonGetVal v "is_pure").map valDisplay |>.getD ""
    let ffi := (jsonGetVal v "crosses_ffi").map valDisplay |>.getD ""
    let trusted := (jsonGetVal v "is_trusted").map valDisplay |>.getD ""
    let caps := (jsonGetVal v "capabilities").map valDisplay |>.getD ""
    if ev == "reported" || ev == "trusted-assumption" then "weakened"
    else if pure == "false" then "weakened"
    else if ffi == "true" then "weakened"
    else if trusted == "true" then "weakened"
    else if caps != "[]" && caps != "" then "weakened"
    else "neutral"
  | "capability" =>
    let pure := (jsonGetVal v "is_pure").map valDisplay |>.getD ""
    if pure == "false" then "weakened" else "neutral"
  | "alloc" =>
    let leak := (jsonGetVal v "potential_leak").map valDisplay |>.getD ""
    if leak == "true" then "weakened" else "neutral"
  | "proof_status" =>
    let state := (jsonGetVal v "state").map valDisplay |>.getD ""
    if state == "no_proof" || state == "not_eligible" || state == "stale" then "weakened"
    else "neutral"
  | "obligation" =>
    let status := (jsonGetVal v "status").map valDisplay |>.getD ""
    if status == "missing_proof" || status == "stale" then "weakened"
    else "neutral"
  | "extraction" =>
    let status := (jsonGetVal v "status").map valDisplay |>.getD ""
    if status == "excluded" then "weakened" else "neutral"
  | "traceability" =>
    let ev := (jsonGetVal v "evidence").map valDisplay |>.getD ""
    if evidenceRank ev < 3 then "weakened" else "neutral"  -- below "enforced"
  | _ => "neutral"

open Json in
/-- Find duplicate (kind, function) keys in a keyed fact list. -/
private def findDuplicateKeys (keyed : List ((String × String) × Val))
    : List (String × String) :=
  let keys := keyed.map (·.1)
  keys.foldl (fun (seen, dupes) key =>
    if seen.contains key then
      if dupes.contains key then (seen, dupes)
      else (seen, dupes ++ [key])
    else (seen ++ [key], dupes)
  ) ([], []) |>.2

open Json in
/-- Diff two fact bundles and produce a list of DiffEntries.
    Returns an error if either bundle contains duplicate (kind, function) keys. -/
def diffFacts (oldFacts newFacts : List Val) : Except String (List DiffEntry) :=
  let oldKeyed := keyFacts oldFacts
  let newKeyed := keyFacts newFacts
  -- Reject duplicate keys
  let oldDupes := findDuplicateKeys oldKeyed
  let newDupes := findDuplicateKeys newKeyed
  if !oldDupes.isEmpty then
    let desc := oldDupes.map fun (k, f) => s!"({k}, {f})"
    .error s!"duplicate keys in old bundle: {", ".intercalate desc}"
  else if !newDupes.isEmpty then
    let desc := newDupes.map fun (k, f) => s!"({k}, {f})"
    .error s!"duplicate keys in new bundle: {", ".intercalate desc}"
  else
  -- Removed: in old but not new
  let removed := oldKeyed.filterMap fun ((k, f), _) =>
    if newKeyed.find? (fun (key, _) => key == (k, f)) |>.isNone then
      some { kind := k, function := f, category := "removed"
           , changes := [], drift := "weakened" : DiffEntry }
    else none
  -- Added: in new but not old
  let added := newKeyed.filterMap fun ((k, f), v) =>
    if oldKeyed.find? (fun (key, _) => key == (k, f)) |>.isNone then
      let drift := classifyNewFact k v
      some { kind := k, function := f, category := "added"
           , changes := [], drift := drift : DiffEntry }
    else none
  -- Changed: in both, fields differ
  let changed := oldKeyed.filterMap fun ((k, f), oldV) =>
    match newKeyed.find? (fun (key, _) => key == (k, f)) with
    | none => none
    | some (_, newV) =>
      let fieldChanges := compareFacts k oldV newV
      if fieldChanges.isEmpty then none
      else
        let hasWeakening := fieldChanges.any fun fc => isWeakening k fc.field fc.oldVal fc.newVal
        let hasStrengthening := fieldChanges.any fun fc => isStrengthening k fc.field fc.oldVal fc.newVal
        let drift := if hasWeakening then "weakened"
          else if hasStrengthening then "strengthened"
          else "neutral"
        some { kind := k, function := f, category := "changed"
             , changes := fieldChanges, drift := drift : DiffEntry }
  .ok (removed ++ added ++ changed)

/-- Render a diff report as human-readable text. -/
def renderDiffReport (entries : List DiffEntry) : String :=
  if entries.isEmpty then "No trust-relevant changes detected.\n"
  else
    let header := "=== Semantic Diff / Trust Drift ==="
    -- Group by drift direction
    let weakened := entries.filter (·.drift == "weakened")
    let strengthened := entries.filter (·.drift == "strengthened")
    let neutral := entries.filter (·.drift == "neutral")
    let renderEntry (e : DiffEntry) : String :=
      let tag := match e.category with
        | "added" => "[+]"
        | "removed" => "[-]"
        | _ => "[~]"
      let changesStr := if e.changes.isEmpty then ""
        else "\n" ++ (e.changes.map fun fc =>
          s!"      {fc.field}: {fc.oldVal} → {fc.newVal}").foldl (· ++ "\n" ++ ·) ""
      s!"    {tag} {e.kind} / {e.function}{changesStr}"
    let sections := []
    let sections := if weakened.isEmpty then sections
      else sections ++ [s!"  TRUST WEAKENED ({weakened.length}):\n{"\n".intercalate (weakened.map renderEntry)}"]
    let sections := if strengthened.isEmpty then sections
      else sections ++ [s!"  TRUST STRENGTHENED ({strengthened.length}):\n{"\n".intercalate (strengthened.map renderEntry)}"]
    let sections := if neutral.isEmpty then sections
      else sections ++ [s!"  OTHER CHANGES ({neutral.length}):\n{"\n".intercalate (neutral.map renderEntry)}"]
    let summary := s!"Summary: {entries.length} changes — {weakened.length} weakened, {strengthened.length} strengthened, {neutral.length} neutral"
    s!"{header}\n\n{"\n\n".intercalate sections}\n\n{summary}\n"

open Json in
/-- Render a diff as JSON for machine consumption. -/
def renderDiffJson (entries : List DiffEntry) : String :=
  let vals := entries.map fun e =>
    Val.obj [
      ("kind", .str e.kind),
      ("function", .str e.function),
      ("category", .str e.category),
      ("drift", .str e.drift),
      ("changes", .arr (e.changes.map fun fc =>
        Val.obj [("field", .str fc.field), ("old", .str fc.oldVal), ("new", .str fc.newVal)]))
    ]
  (Val.arr vals).render

open Json in
/-- Parse a JSON string into a list of fact Vals.
    Accepts either a raw JSON array or a snapshot object with a "facts" field. -/
def parseFacts (jsonStr : String) : Option (List Val) :=
  match JsonParser.parse jsonStr with
  | some (.arr vs) => some vs
  | some (.obj kvs) =>
    match kvs.find? (fun (k, _) => k == "facts") with
    | some (_, .arr vs) => some vs
    | _ => none
  | _ => none

-- ============================================================
-- Fact artifact snapshot
-- ============================================================

open Json in
/-- Build a summary object from a list of facts. -/
private def buildSummaryFact (facts : List Val) : Val :=
  let count (kind : String) := facts.filter (fun v => jsonGetStr v "kind" == some kind) |>.length
  let proofFacts := facts.filter fun v => jsonGetStr v "kind" == some "proof_status"
  let proofState (s : String) := proofFacts.filter (fun v => jsonGetStr v "state" == some s) |>.length
  let obFacts := facts.filter fun v => jsonGetStr v "kind" == some "obligation"
  let obStatus (s : String) := obFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  let extFacts := facts.filter fun v => jsonGetStr v "kind" == some "extraction"
  let extStatus (s : String) := extFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  let eligFacts := facts.filter fun v => jsonGetStr v "kind" == some "eligibility"
  let eligStatus (s : String) := eligFacts.filter (fun v => jsonGetStr v "status" == some s) |>.length
  .obj [
    ("total_functions", .num (proofFacts.length)),
    ("proved", .num (proofState "proved")),
    ("stale", .num (proofState "stale")),
    ("no_proof", .num (proofState "no_proof")),
    ("not_eligible", .num (proofState "not_eligible")),
    ("trusted", .num (proofState "trusted")),
    ("eligibility_eligible", .num (eligStatus "eligible")),
    ("eligibility_excluded", .num (eligStatus "excluded")),
    ("eligibility_trusted", .num (eligStatus "trusted")),
    ("predictable_violations", .num (count "predictable_violation")),
    ("obligations_proved", .num (obStatus "proved")),
    ("obligations_missing", .num (obStatus "missing_proof")),
    ("obligations_stale", .num (obStatus "stale")),
    ("extracted", .num (extStatus "extracted")),
    ("excluded", .num (extStatus "excluded")),
    ("effects_facts", .num (count "effects")),
    ("capability_facts", .num (count "capability")),
    ("unsafe_facts", .num (count "unsafe")),
    ("alloc_facts", .num (count "alloc")),
    ("traceability_facts", .num (count "traceability"))
  ]

open Json in
/-- Build the full snapshot JSON object with metadata, facts, and summary. -/
def snapshotJson
    (sourcePath : String)
    (timestamp : String)
    (coreFacts : List Val)
    (traceFacts : List Val := []) : String :=
  let allFacts := coreFacts ++ traceFacts
  let summary := buildSummaryFact allFacts
  let snapshot := Val.obj [
    ("version", .num 1),
    ("source", .str sourcePath),
    ("timestamp", .str timestamp),
    ("fact_count", .num allFacts.length),
    ("summary", summary),
    ("facts", .arr allFacts)
  ]
  snapshot.render

end Report
end Concrete
