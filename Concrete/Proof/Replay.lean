/-
  Kernel replay as a typed service (R-0004 package 3).

  "Did the Lean kernel accept this?" is the question every replay-backed receipt rests on, and until
  now it had no answerer — only a rendering. The check lived INLINE in `compileAndReport`, tangled
  with that function's `reportJson` parameter, and its failure paths PRINTED and returned an exit
  code. Nothing else could ask the question: not `concrete check`, not a report, not the link
  migration, not a test. A second caller would have had to re-implement it, which is how two answers
  to one question get born.

  So replay is extracted here as ONE producer:

      ReplayRequest -> IO (Except ReplayRefusal ReplayResult)

  with the properties that make it usable as evidence rather than as output:

  * TYPED INPUTS. No JSON flag, no rendering parameter, no exit code. The request says what to check
    and where; it does not say how to say it.
  * EVERY FAILURE CLASS IS RETURNED. A missing workspace, an unwritable scratch file, an absent
    checker are values, not printed lines. A caller that must fail closed can pattern-match; a caller
    that renders can render. Neither can silently skip one.
  * THE ENVIRONMENT IS RETAINED. Workspace, toolchain and import closure travel with the result,
    because a verdict that cannot say which checker produced it cannot be audited later — and a
    receipt minted from it would be recording an anonymous claim.
  * NO SIDE EFFECTS ON EVIDENCE. This function mints nothing and writes no receipt. Minting is a
    separate authority that CONSUMES a successful result; keeping them apart is what makes
    "unchecked facts -> receipt" unconstructible.

  WHAT IT DELIBERATELY DOES NOT DO: decide policy. Whether an unbound-but-type-checking theorem is
  acceptable, whether a rejection should fail the build, what exit code any of it maps to — all of
  that belongs to the caller. This function reports what the kernel did.
-/

namespace Concrete.Proof

/-- Which kind of obligation a replay target discharges. -/
inductive ReplayKind where
  | refinement   -- a `#[proof_by]` link from a claim to a Lean theorem
  | ensures      -- an `#[ensures_proof]` discharge of a source contract
  deriving BEq, Repr, DecidableEq

def ReplayKind.canonical : ReplayKind → String
  | .refinement => "refinement"
  | .ensures    => "ensures"

/-- How the link being replayed was established. -/
inductive ReplayOrigin where
  | sourceLinked  -- synthesized from an in-source proof link
  | hardcoded     -- from the compiler's own `provedFunctions` table
  deriving BEq, Repr, DecidableEq

def ReplayOrigin.canonical : ReplayOrigin → String
  | .sourceLinked => "source_linked"
  | .hardcoded    => "hardcoded"

/-- Whether the claim has a stored proof-subject digest.

    This is NOT a detail of rendering. A theorem can type-check perfectly while the claim it is
    attached to has no stored subject, in which case the freshness comparison has nothing to compare
    against and a changed body would go undetected. Such a target is `unbound`: the kernel accepted
    it, and it is still not proved. Carrying the distinction in the TYPE is what stops a caller from
    adding the two counts together — which is exactly what happened on `examples/hmac_sha256`, where
    a summary read "11 verified" while ProofCore was concurrently emitting 11 "this claim is unbound,
    not proved" errors.

    Modelled as an inductive rather than a `Bool` on purpose: a positional boolean in a record of
    strings is the shape that lets an argument slide into the wrong slot. -/
inductive ReplayBinding where
  | bound     -- a stored proof-subject digest exists, so freshness is decidable
  | unbound   -- no stored subject; acceptance means type-checked, not proved
  deriving BEq, Repr, DecidableEq

/-- One theorem the kernel is being asked to accept, with everything needed to identify it
    afterwards. `subject` is the claim; `theoremName` is the artifact. -/
structure ReplayTarget where
  subject     : String   -- qualified name of the function whose claim this discharges
  theoremName : String   -- fully-qualified Lean theorem — the artifact identity
  kind        : ReplayKind
  origin      : ReplayOrigin
  binding     : ReplayBinding
  deriving BEq, Repr

/-- What to replay, and where.

    `inputPath` and `fallbackDir` are the two workspace candidates, in that order (see
    `resolveWorkspace`). `imports` is the closure the generated file declares — an input rather than
    a constant, so a migration or test can replay against a narrower environment without a second
    copy of this producer. -/
structure ReplayRequest where
  inputPath   : String
  fallbackDir : String := "."
  imports     : List String
  targets     : List ReplayTarget
  deriving Repr

/-- Everything that can stop a replay from producing a verdict.

    Each of these was previously an `IO.println` followed by `return 1`, which meant a caller could
    not distinguish "the kernel rejected a theorem" from "no kernel ever ran". Those are opposite
    facts: the first is evidence, the second is the absence of it, and a receipt minted without the
    distinction would record a refusal as a pass. -/
inductive ReplayRefusal where
  /-- No Lake workspace was found from the input or the fallback directory. The theorems were never
      looked at; blaming them would send the reader to the wrong place. -/
  | noWorkspace (inputPath : String) (fallbackDir : String)
  /-- The request named nothing to check. Deliberately a REFUSAL rather than an empty success: a
      vacuous "all accepted" is exactly the answer a minting path must never receive, because
      `checks.all accepted` is `true` over an empty list. Callers that legitimately have nothing to
      do (the CLI, when a program carries no proof links) match this case and say so. -/
  | noTargets
  /-- Two targets named the same theorem. The per-theorem verdict is read out of one transcript by
      searching for the theorem's name, so duplicates cannot be told apart and would both inherit
      whichever verdict the other produced. -/
  | duplicateTheorem (theoremName : String)
  /-- A target carried an empty subject or theorem name. Such a target cannot be searched for in the
      transcript — the empty needle matches everywhere — so it would silently report as accepted. -/
  | unnamedTarget (subject : String) (theoremName : String)
  /-- The scratch file could not be created or written. -/
  | scratchUnavailable (detail : String)
  /-- The checker could not be invoked at all (no `lake` on PATH, permission denied). Distinct from
      a non-zero exit: this is "no kernel ran", not "the kernel said no". -/
  | checkerUnavailable (detail : String)
  deriving BEq, Repr

/-- A one-line explanation naming what is wrong, for callers that render. The message names the
    OBSTACLE rather than the targets, because reporting N missing theorems for one missing workspace
    is what sent readers looking for the wrong thing. -/
def ReplayRefusal.explain : ReplayRefusal → String
  | .noWorkspace inp fb =>
      s!"cannot locate a Lake workspace for '{inp}' (no lakefile.toml or lakefile.lean in any parent "
      ++ s!"directory of it or of '{fb}'), so the Lean theorems it references cannot be replayed"
  | .noTargets =>
      "no proved, stale, or unbound obligations with proof names to check"
  | .duplicateTheorem t =>
      s!"theorem '{t}' appears twice in one replay request; per-theorem verdicts are read by name "
      ++ "and duplicates cannot be told apart"
  | .unnamedTarget s t =>
      s!"replay target has an empty name (subject='{s}', theorem='{t}'); it cannot be located in the "
      ++ "checker transcript and would report as accepted without being checked"
  | .scratchUnavailable d => s!"could not write the generated replay file: {d}"
  | .checkerUnavailable d => s!"could not invoke the Lean checker: {d}"

/-- A short stable tag per refusal, for structured surfaces that must not parse prose. -/
def ReplayRefusal.canonical : ReplayRefusal → String
  | .noWorkspace ..       => "no_workspace"
  | .noTargets            => "no_targets"
  | .duplicateTheorem _   => "duplicate_theorem"
  | .unnamedTarget ..     => "unnamed_target"
  | .scratchUnavailable _ => "scratch_unavailable"
  | .checkerUnavailable _ => "checker_unavailable"

/-- What the kernel did with one target. -/
inductive ReplayVerdict where
  /-- The kernel accepted it AND the claim has a stored subject. This is the only verdict that may
      support a receipt. -/
  | accepted
  /-- The kernel accepted it, but the claim is unbound: type-checked, NOT proved. Separated from
      `accepted` so no caller can sum them into a coverage number. -/
  | acceptedUnbound
  /-- The kernel reported an error mentioning this theorem. -/
  | rejected
  /-- The run failed as a whole, so this target has no individual verdict. NOT the same as
      `rejected`: nothing is known about this theorem, and saying it failed would blame an artifact
      that was very likely fine. -/
  | notAttempted
  deriving BEq, Repr, DecidableEq

def ReplayVerdict.canonical : ReplayVerdict → String
  | .accepted        => "accepted"
  | .acceptedUnbound => "accepted_unbound"
  | .rejected        => "rejected"
  | .notAttempted    => "not_attempted"

/-- A verdict paired with the target it belongs to. -/
structure ReplayCheck where
  target  : ReplayTarget
  verdict : ReplayVerdict
  deriving BEq, Repr

/-- The checker that produced a result, identified well enough to be re-examined later.

    A verdict with no environment is anonymous, and an anonymous verdict cannot be invalidated: when
    the toolchain moves or the import closure changes, nothing knows the old answer is stale. Slice 4
    found this the hard way — the same file gave "3 verified" from one directory and "0 verified, 3
    failed" from another, and the report said neither where it had looked nor with what. -/
structure ReplayEnvironment where
  workspace         : String
  /-- `true` when the workspace came from the input, `false` when it came from the fallback
      directory. The distinction is the difference between a location-independent verdict and one
      that depended on where the caller happened to stand. -/
  workspaceFromInput : Bool
  toolchain         : String
  imports           : List String
  deriving BEq, Repr

/-- What a completed replay produced. Construction is unrestricted here because this structure is a
    REPORT, not evidence: it records what happened, including failure. The constraint that matters —
    that only a successful replay can support a receipt — belongs on the minting side, which consumes
    this. Making the report itself refuse to describe a failed run would just hide failures. -/
structure ReplayResult where
  environment    : ReplayEnvironment
  checks         : List ReplayCheck
  exitCode       : UInt32
  /-- The checker exited non-zero without naming any individual theorem: the file did not compile as
      a whole. Every target is `notAttempted`, and the transcript is the only diagnosis available.

      Computed BEFORE the per-target fallback that marks targets, which is where the previous inline
      version went wrong: it derived this flag from `failed.isEmpty` AFTER filling `failed` with
      every target, so the flag was unreachably false and a whole-file compile error was reported as
      every theorem individually "not found". -/
  generalFailure : Bool
  /-- Combined stdout and stderr, retained verbatim. The only diagnosis available for a general
      failure, and the material every per-target verdict was read out of. -/
  transcript     : String
  deriving BEq, Repr

namespace ReplayResult

def accepted (r : ReplayResult) : List ReplayCheck :=
  r.checks.filter (·.verdict == .accepted)

def acceptedUnbound (r : ReplayResult) : List ReplayCheck :=
  r.checks.filter (·.verdict == .acceptedUnbound)

def rejected (r : ReplayResult) : List ReplayCheck :=
  r.checks.filter (·.verdict == .rejected)

def notAttempted (r : ReplayResult) : List ReplayCheck :=
  r.checks.filter (·.verdict == .notAttempted)

/-- Did every target reach a verdict the kernel is happy with?

    `acceptedUnbound` counts as accepted HERE because the kernel genuinely accepted the theorem —
    this predicate answers "did the checker complain", not "is this proved". Receipt minting must not
    use it for the second question; that is what `fullyBound` is for. -/
def allAccepted (r : ReplayResult) : Bool :=
  !r.generalFailure
    && r.checks.all (fun c => c.verdict == .accepted || c.verdict == .acceptedUnbound)

/-- Every target was accepted AND bound — the only shape from which proof-backed receipts may be
    minted for the whole request. Vacuously true on an empty check list, which is why an empty
    request is refused rather than returned as a result. -/
def fullyBound (r : ReplayResult) : Bool :=
  !r.generalFailure && r.checks.all (·.verdict == .accepted)

/-- The verdict for one theorem, by artifact name. -/
def verdictFor (r : ReplayResult) (theoremName : String) : Option ReplayVerdict :=
  (r.checks.find? (·.target.theoremName == theoremName)).map (·.verdict)

end ReplayResult

/-! ### The producer -/

/-- Walk up from `path` for the directory holding a Lake workspace.

    Returns `none` rather than guessing: a wrong workspace replays against the wrong library and
    reports confident nonsense. A path that does not exist is `none` too, not an exception — the
    caller's refusal for "no workspace" is the right report for it. -/
partial def findLakeWorkspace (path : String) : IO (Option System.FilePath) := do
  try
    let abs ← IO.FS.realPath (System.FilePath.mk path)
    let rec up (dir : System.FilePath) (fuel : Nat) : IO (Option System.FilePath) := do
      match fuel with
      | 0 => return none
      | fuel + 1 =>
        if (← (dir / "lakefile.toml").pathExists) || (← (dir / "lakefile.lean").pathExists) then
          return some dir
        match dir.parent with
        | some p => if p == dir then return none else up p fuel
        | none => return none
    let start := if (← abs.isDir) then abs else (abs.parent.getD abs)
    up start 64
  catch _ => return none

/-- Resolve the workspace from the INPUT first, then the caller's directory.

    Resolving ONLY from the input was tried and was too strict: a tool that copies sources to a temp
    directory and replays them from inside the repo (which is how `check_purecore_proofs.sh`
    exercises std) gives an input with no workspace of its own, and refusing it reported 12 real,
    kernel-verified proofs as unreachable. The cwd-independence property is preserved where it means
    something — an input that HAS a workspace always resolves to that one, so the same file gives the
    same verdict from anywhere. Only an input with none falls back, and the result records which case
    applied so the answer is never anonymous. -/
def resolveWorkspace (req : ReplayRequest) : IO (Option (System.FilePath × Bool)) := do
  match ← findLakeWorkspace req.inputPath with
  | some w => return some (w, true)
  | none   => return (← findLakeWorkspace req.fallbackDir).map (·, false)

/-- The generated Lean file for a request. Pure, so a test can assert what would be checked without
    running a kernel, and so the same bytes are reproducible from the request alone. -/
def ReplayRequest.source (req : ReplayRequest) : String := Id.run do
  let mut s := ""
  for i in req.imports do
    s := s ++ s!"import {i}\n"
  s := s ++ "\n-- Auto-generated kernel replay. Verifies that the referenced Lean theorems exist\n"
  s := s ++ "-- and type-check. Generated from a ReplayRequest; do not edit.\n\n"
  for t in req.targets do
    let tag := match t.kind with | .refinement => "" | .ensures => " (ensures)"
    s := s ++ s!"-- {t.subject}{tag}\n#check @{t.theoremName}\n\n"
  return s

/-- Structural checks that must hold before a kernel is invoked at all.

    Each of these would otherwise produce a WRONG verdict rather than an error: an unnamed target
    matches the transcript everywhere, and duplicate theorem names cannot be told apart by a
    name-keyed read of one transcript. -/
def ReplayRequest.validate (req : ReplayRequest) : Except ReplayRefusal Unit := do
  if req.targets.isEmpty then throw .noTargets
  for t in req.targets do
    if t.subject.trimAscii.isEmpty || t.theoremName.trimAscii.isEmpty then
      throw (.unnamedTarget t.subject t.theoremName)
  let mut seen : List String := []
  for t in req.targets do
    if seen.contains t.theoremName then throw (.duplicateTheorem t.theoremName)
    seen := t.theoremName :: seen
  return ()

/-- Run the kernel over a request and report what it did.

    ONE producer. `concrete --report check-proofs`, receipt minting, the link migration and the test
    gates all ask this function; none of them re-derives the answer, and none of them can obtain a
    verdict without also obtaining the environment that produced it. -/
def replay (req : ReplayRequest) : IO (Except ReplayRefusal ReplayResult) := do
  match req.validate with
  | .error e => return .error e
  | .ok () =>
  let some (ws, fromInput) ← resolveWorkspace req
    | return .error (.noWorkspace req.inputPath req.fallbackDir)
  -- Scratch file. Failure here is a refusal: nothing was checked.
  let scratchDir ← try
      let d ← IO.Process.output { cmd := "mktemp", args := #["-d"] }
      if d.exitCode != 0 then throw (IO.userError d.stderr)
      pure d.stdout.trimAscii.toString
    catch e => return .error (.scratchUnavailable (toString e))
  let scratch := scratchDir ++ "/kernel_replay.lean"
  try
    IO.FS.writeFile ⟨scratch⟩ req.source
  catch e =>
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }
    return .error (.scratchUnavailable (toString e))
  let outcome ← try
      pure (Except.ok (← IO.Process.output
        { cmd := "lake", args := #["env", "lean", scratch], cwd := ws
        , env := #[("LAKE_TERM_ANSI", "0")] }))
    catch e => pure (Except.error (toString e))
  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", scratchDir] }
  let result ← match outcome with
    | .error e => return .error (.checkerUnavailable e)
    | .ok r => pure r
  -- The toolchain identity, read from the resolved WORKSPACE rather than the process directory: it
  -- describes the checker that just ran, and reading it from elsewhere would name a different one.
  let toolchain ← try
      let c ← IO.FS.readFile (ws / "lean-toolchain")
      pure c.trimAscii.toString
    catch _ => pure "unknown"
  -- Lean puts errors on either stream.
  let transcript := result.stdout.trimAscii.toString ++ "\n" ++ result.stderr.trimAscii.toString
  let mentions (needle : String) : Bool := (transcript.splitOn needle).length != 1
  -- A per-target verdict is only readable when the checker named the theorems it disliked. When it
  -- exits non-zero having named NONE of them, the file did not compile as a whole and no target has
  -- an individual verdict.
  let named := req.targets.filter (fun t => mentions s!"`{t.theoremName}`")
  let generalFailure := result.exitCode != 0 && named.isEmpty
  let checks := req.targets.map fun t =>
    let verdict :=
      if generalFailure then ReplayVerdict.notAttempted
      else if mentions s!"`{t.theoremName}`" then .rejected
      else match t.binding with
        | .unbound => .acceptedUnbound
        | .bound   => .accepted
    { target := t, verdict }
  return .ok
    { environment :=
        { workspace := ws.toString, workspaceFromInput := fromInput
        , toolchain := toolchain, imports := req.imports }
    , checks, exitCode := result.exitCode, generalFailure, transcript }

end Concrete.Proof
