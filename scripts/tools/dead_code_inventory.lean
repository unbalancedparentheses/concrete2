/-
Dead-code inventory of the compiler (scripts/tests/check_dead_code_ratchet.sh).

Imports the given modules and walks the ELABORATED environment, like
scripts/tools/totality_inventory.lean: the reference graph is the constants each declaration's
type and value mention (`Expr.getUsedConstants`), so a reference produced by a macro, a
`deriving` handler, a `match` compilation or a coercion is an edge here even when no line of
source names it. Every declaration whose defining module is a COMPILER module (`Concrete`,
`Concrete.*`, `Main`, `Browser`) is a candidate; the tool prints one row per candidate with
whether it is reachable from the roots.

ROOTS (live by definition):
  * `main` of an executable root (Main, Concrete.Pipeline.PipelineTest);
  * every user-written theorem, in any imported module (aux theorems such as `foo.eq_1` or
    `S.mk.injEq` are not roots: they exist for every definition);
  * every declaration of a non-compiler imported module: the proof libraries `Examples` and
    `DesignExamples` are checked as a whole, so whatever they reference is live;
  * `@[export]`, `@[extern]`, `initialize` / `builtin_initialize` declarations and their init
    functions, members of the default simp set, and declarations whose type is a parser, macro or
    elaborator (`syntax` / `macro` / `elab` produce those);
  * the names in `--roots FILE` (one identifier per line): the identifiers the gate extracted from
    commands the environment does not keep (`#guard`, `#eval`, `example`, `#check`) and from the
    Lean files outside the libraries; a name matches every declaration whose last component is it;
  * every declaration of a module named by `--root-module M` (generated data modules:
    Concrete.BuildIdentity, the classification table, the generated attestations; their content
    is written by scripts/gen, not by hand, so whatever they reference is live);
  * every declaration whose type is a constant named by `--root-type T`: a tool that enumerates the
    environment by type (scripts/gen/classifications.lean reads every `PFnDef` and `SpecDecl`
    with `evalConst`) reaches them without naming them;
  * the names in `--allow FILE` (one full declaration name per line): the string-referenced
    allowlist (docs/compiler/dead_code_allowlist.tsv), reached in a SECOND pass only, so the tool
    can tell which allowlist rows are needed.

AUXILIARY DECLARATIONS are folded into the declaration they belong to and never reported:
  constructors, recursors, projections, `casesOn`/`below`/`noConfusion`/... of an inductive;
  `_unsafe_rec` twins, `match_N`, `proof_N`, `eq_N`, `eq_def`, `induct`, `_private`/macro-scoped
  internals of a definition; the helper definitions a (derived) instance carries. Reaching an aux
  declaration reaches its parent (a theorem that uses `foo.eq_1` keeps `foo`), and reaching a
  definition reaches its internal children (a `partial def`'s body lives in its `_unsafe_rec`
  twin, which nothing references by name).

INSTANCES are CONDITIONAL roots: an instance is reached once every compiler declaration its type
mentions is reached (a derived `Repr Foo` stays live as long as `Foo` does, and dies with it).
Instance uses the elaborator resolved are already ordinary edges.

Output (stdout), one row per candidate, sorted:
  decl  kind  module  line  reached-without-allowlist(0/1)  reached-with-allowlist(0/1)
`decl` is the user name (private and macro-scoped names shown as their user name).

Usage: lake env lean --run scripts/tools/dead_code_inventory.lean [--roots F] [--allow F] [--root-module M]... [--root-type T]... <Module>...
       lake env lean --run scripts/tools/dead_code_inventory.lean --control
-/
import Lean
open Lean

def userName (n : Name) : Name :=
  let n := (privateToUserName? n).getD n
  if n.hasMacroScopes then n.eraseMacroScopes else n

def isCompilerModule (m : Name) : Bool :=
  m == `Concrete || (`Concrete).isPrefixOf m || m == `Main || m == `Browser

def lineOf (env : Environment) (n : Name) : Nat :=
  match declRangeExt.find? env n with
  | some r => r.range.pos.line
  | none => 0

/-- The nearest proper prefix of `n` that is a declaration (a private prefix resolved to its user
name when only that exists), if any. -/
partial def declaredPrefix (env : Environment) (n : Name) : Option Name :=
  match n with
  | .anonymous => none
  | .str pre _ | .num pre _ =>
    if pre.isAnonymous then none
    else if env.contains pre then some pre
    else if env.contains (userName pre) then some (userName pre)
    else declaredPrefix env pre

/-- The declaration an auxiliary belongs to, or `none` when `n` is a unit of its own.

PROVENANCE, NOT NAME: a declaration Lean generated (`match_N`, `eq_N`, `_unsafe_rec`, `proof_N`,
`T.ofNat_ctorIdx`, `T.c.elim`, a `deriving` handler's helpers, ...) has no source range, so a
declaration WITH a range is user-written and is its own unit whatever its name (`Foo.ofNat`,
`Foo.ext`), and one without a range belongs to its nearest declared prefix. Constructors,
recursors and structure projections belong to their inductive, and a declaration nested under an
instance is that instance's helper. -/
def parentOf (env : Environment) (n : Name) : Option Name :=
  match env.find? n with
  | some (.ctorInfo c) => some c.induct
  | some (.recInfo r) => r.all.head?
  | _ =>
    if let some p := env.getProjectionFnInfo? n then
      match env.find? p.ctorName with
      | some (.ctorInfo c) => some c.induct
      | _ => declaredPrefix env n
    else if lineOf env n == 0 then declaredPrefix env n
    else match declaredPrefix env n with
      | some pre => if Meta.isInstanceCore env pre then some pre else none
      | none => none

/-- The unit an auxiliary ultimately belongs to. -/
partial def unitOf (env : Environment) (n : Name) (fuel : Nat := 16) : Name :=
  match fuel, parentOf env n with
  | 0, _ => n
  | _, none => n
  | f + 1, some p => if p == n then n else unitOf env p f

def isRootType (ty : Expr) : Bool :=
  let heads := [``ParserDescr, ``TrailingParserDescr, ``Macro, ``Lean.Parser.Parser,
    ``Lean.Parser.TrailingParser, ``Lean.Elab.Command.CommandElab, ``Lean.Elab.Term.TermElab,
    ``Lean.Elab.Tactic.Tactic, ``Lean.PrettyPrinter.Delaborator.Delab,
    ``Lean.PrettyPrinter.Unexpander, ``Lean.PrettyPrinter.Parenthesizer,
    ``Lean.PrettyPrinter.Formatter]
  match ty.getForallBody.getAppFn with
  | .const c _ => heads.contains c
  | _ => false

def kindOf (env : Environment) (ci : ConstantInfo) : String :=
  if Meta.isInstanceCore env ci.name then "instance" else
  match ci with
  | .defnInfo d => if d.safety == .unsafe then "unsafe" else if d.safety == .partial then "partial" else "def"
  | .opaqueInfo _ => if env.contains (.str ci.name "_unsafe_rec") then "partial" else "opaque"
  | .thmInfo _ => "theorem"
  | .axiomInfo _ => "axiom"
  | .inductInfo _ => if isStructure env ci.name then "structure" else "inductive"
  | .quotInfo _ => "quot"
  | .ctorInfo _ => "ctor"
  | .recInfo _ => "rec"

structure Graph where
  /-- Edges out of each constant: what its type and value use, plus its internal children, its
  constructors (an inductive), and its `@[implemented_by]` target. -/
  succ : Std.HashMap Name (Array Name) := {}

def buildGraph (env : Environment) : Graph := Id.run do
  let mut succ : Std.HashMap Name (Array Name) := {}
  -- children: a declaration ↦ the auxiliaries that belong to it (its `_unsafe_rec` twin, which
  -- nothing names, is reached this way)
  let mut children : Std.HashMap Name (Array Name) := {}
  for (n, _) in env.constants.toList do
    if let some p := parentOf env n then children := children.insert p ((children.getD p #[]).push n)
  for (n, ci) in env.constants.toList do
    let mut out := ci.type.getUsedConstants
    if let some v := ci.value? (allowOpaque := true) then out := out ++ v.getUsedConstants
    match ci with
    | .inductInfo iv => out := out ++ iv.ctors.toArray
    | _ => pure ()
    if let some impl := Compiler.implementedByAttr.getParam? env n then out := out.push impl
    out := out ++ children.getD n #[]
    succ := succ.insert n out
  return { succ }

/-- Reachability from `roots`: forward edges, plus aux → parent, plus conditional instances. -/
def reach (env : Environment) (g : Graph) (roots : Array Name) (instances : Array (Name × Array Name)) :
    NameSet := Id.run do
  let mut seen : NameSet := {}
  let mut todo : Array Name := roots
  let mut pending := instances
  while true do
    while !todo.isEmpty do
      let n := todo.back!
      todo := todo.pop
      if seen.contains n then continue
      seen := seen.insert n
      for m in g.succ.getD n #[] do
        if !seen.contains m then todo := todo.push m
      if let some p := parentOf env n then
        if !seen.contains p then todo := todo.push p
    -- an instance whose compiler-local type constants are all reached becomes reachable
    let (ready, rest) := pending.partition fun (i, deps) => !seen.contains i && deps.all seen.contains
    pending := rest.filter fun (i, _) => !seen.contains i
    if ready.isEmpty then break
    todo := ready.map (·.1)
  return seen

def readLines (path : Option String) : IO (Array String) := do
  match path with
  | none => return #[]
  | some p =>
    let s ← IO.FS.readFile p
    return (s.splitOn "\n").toArray.filterMap fun l =>
      let l := l.trimAscii.toString
      if l.isEmpty || l.startsWith "#" then none else some l

def lastComponent (n : Name) : String :=
  match n with
  | .str _ s => s
  | _ => ""

/-- One row per compiler unit. `moduleOf` returns the defining module of any constant. -/
def inventory (env : Environment) (moduleOf : Name → Option Name) (isFixedRoot : Name → Name → Bool)
    (rootWords : Array String) (allow : Array String) (rootTypes : Array Name := #[]) :
    Array String := Id.run do
  let g := buildGraph env
  let words : Std.HashSet String := Std.HashSet.ofArray rootWords
  let allowSet : Std.HashSet String := Std.HashSet.ofArray allow
  let simp := Meta.simpExtension.getState env
  let mut roots : Array Name := #[]
  let mut allowRoots : Array Name := #[]
  let mut instances : Array (Name × Array Name) := #[]
  for (n, ci) in env.constants.toList do
    let some m := moduleOf n | continue
    let compiler := isCompilerModule m
    let un := userName n
    let isUnit := parentOf env n |>.isNone
    if !compiler then roots := roots.push n; continue
    if isFixedRoot n m then roots := roots.push n
    if isUnit then
      if ci matches .thmInfo _ then roots := roots.push n
      if words.contains (lastComponent un) then roots := roots.push n
      if allowSet.contains un.toString then allowRoots := allowRoots.push n
    if isExtern env n || (getExportNameFor? env n).isSome then roots := roots.push n
    if isIOUnitInitFn env n || isIOUnitBuiltinInitFn env n || (getInitFnNameFor? env n).isSome then
      roots := roots.push n
      if let some i := getInitFnNameFor? env n then roots := roots.push i
    if isUnit && (simp.isLemma (.decl n) || simp.isDeclToUnfold n) then roots := roots.push n
    if isRootType ci.type then roots := roots.push n
    if let .const t _ := ci.type then
      if rootTypes.contains t then roots := roots.push n
    if Meta.isInstanceCore env n then
      let deps := ci.type.getUsedConstants.filter fun c =>
        match moduleOf c with
        | some cm => isCompilerModule cm
        | none => false
      instances := instances.push (n, deps.map (unitOf env ·))
  let r0 := reach env g roots instances
  let r1 := reach env g (roots ++ allowRoots) instances
  let mut rows : Array String := #[]
  for (n, ci) in env.constants.toList do
    let some m := moduleOf n | continue
    if !isCompilerModule m then continue
    if (parentOf env n).isSome then continue
    if ci matches .thmInfo _ then continue
    let b (s : NameSet) := if s.contains n then "1" else "0"
    rows := rows.push s!"{userName n}\t{kindOf env ci}\t{m}\t{lineOf env n}\t{b r0}\t{b r1}"
  return rows.qsort (· < ·)

/-- The finder's own controls, elaborated from source text into a module named
`Concrete.DeadCodeControl`. scripts/tests/check_dead_code_ratchet.sh holds the rows this must
print. -/
def controlSource : String := "
def liveLeaf (n : Nat) : Nat := n + 1
def deadLeaf (n : Nat) : Nat := n + 2
def deadCaller (n : Nat) : Nat := deadLeaf n
def usedByTheorem (n : Nat) : Nat := n * 2
theorem aboutIt : usedByTheorem 1 = 2 := rfl
def onlyEqLemma (n : Nat) : Nat := match n with | 0 => 1 | k + 1 => k
theorem viaEq : onlyEqLemma 0 = 1 := by simp [onlyEqLemma]
partial def partialLive (n : Nat) : Nat := if n == 0 then liveLeaf 0 else partialLive (n / 2) + twinOnly n
where twinOnly (n : Nat) : Nat := n
structure LiveS where
  a : Nat
  b : Nat
  deriving Repr
structure DeadS where
  a : Nat
  deriving Repr, BEq
inductive DeadT where
  | x | y
  deriving DecidableEq
def readsField (s : LiveS) : Nat := s.b
def usedByAllow (n : Nat) : Nat := n
def allowOnly (n : Nat) : Nat := usedByAllow n
def guardOnly (n : Nat) : Nat := n
def orphan (n : Nat) : Nat := n
def orphan.ofNat (n : Nat) : Nat := n
def orphan._helper (n : Nat) : Nat := n
#guard guardOnly 1 == 1
def main : IO Unit := IO.println (toString (partialLive 3 + readsField ⟨1, 2⟩))
"

unsafe def runControl : IO UInt32 := do
  let some env ← Elab.runFrontend controlSource {} "DeadCodeControl.lean" `Concrete.DeadCodeControl
    | IO.eprintln "error: the control source did not elaborate"; return 2
  let moduleOf (n : Name) : Option Name :=
    if (env.getModuleIdxFor? n).isNone then some `Concrete.DeadCodeControl else some `Init
  for r in inventory env moduleOf (fun n _ => n == `main) #["guardOnly"] #["allowOnly"] do
    IO.println r
  return 0

unsafe def main (args : List String) : IO UInt32 := do
  enableInitializersExecution
  initSearchPath (← findSysroot)
  if args == ["--control"] then return (← runControl)
  let mut rootsFile : Option String := none
  let mut allowFile : Option String := none
  let mut rootModules : Array Name := #[]
  let mut rootTypes : Array Name := #[]
  let mut mods : Array Import := #[]
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--roots" :: f :: r => rootsFile := some f; rest := r
    | "--allow" :: f :: r => allowFile := some f; rest := r
    | "--root-module" :: m :: r => rootModules := rootModules.push m.toName; rest := r
    | "--root-type" :: t :: r => rootTypes := rootTypes.push t.toName; rest := r
    | a :: r => mods := mods.push { module := a.toName }; rest := r
    | [] => break
  if mods.isEmpty then
    IO.eprintln "usage: dead_code_inventory.lean [--roots F] [--allow F] [--root-module M]... [--root-type T]... <Module.Name>... | --control"
    return 2
  let env ← importModules mods {} 0 (loadExts := true)
  let moduleOf (n : Name) : Option Name := do
    let idx ← env.getModuleIdxFor? n
    env.header.moduleNames[idx.toNat]?
  let isFixedRoot (n m : Name) : Bool :=
    rootModules.contains m ||
      (n == `main && (m == `Main || m == `Concrete.Pipeline.PipelineTest || m == `Browser))
  let rows := inventory env moduleOf isFixedRoot (← readLines rootsFile) (← readLines allowFile) rootTypes
  for r in rows do IO.println r
  -- which compiler modules contributed candidates, on stderr (the gate's not-vacuous check)
  let mut counts : NameMap Nat := {}
  for (n, _) in env.constants.toList do
    if let some m := moduleOf n then
      if isCompilerModule m then counts := counts.insert m ((counts.find? m).getD 0 + 1)
  for (m, c) in counts.toList do
    IO.eprintln s!"visited\t{m}\t{c}"
  return 0
