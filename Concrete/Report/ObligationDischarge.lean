import Concrete.Report.ObligationDiscovery

/-! Discharging obligations outside omega: the external SMT path, the Lean replay artifact, the multi-kernel path, the bridge differential check, the reference evaluator, artifact fuzzing and the lowering-agreement check. Split out of ReportObligations.lean;
    `Concrete.Report.ReportObligations` imports all three. -/

namespace Concrete
namespace Report

/-! ## External-SMT path (Phase 2 #8) — narrow first slice

The kernel-checked tiers (constant fold → omega → `bv_decide`) are exhausted
first. What genuinely remains outside them is *nonlinear* integer arithmetic —
a product of two program variables that interval analysis cannot bound. For that
one narrow VC class we can emit a standard SMT-LIB query and hand it to an
external solver. The result is NEVER a kernel-checked class: it is
`solver_trusted` / `proved_by_smt` (the solver enters the TCB), kept distinct
from `proved_by_kernel_decision`, and only ever produced behind an explicit flag.
The translation targets structured `Expr`s (not the Lean-syntax strings), so the
emitted SMT-LIB is well-formed by construction. -/

/-- Lower a contract `Expr` to an SMT-LIB (QF_NIA) s-expression. Same fragment as
    `toLeanProp`: integer literals/vars, add/sub/mul, comparisons, and/or/not. -/
def exprToSmt : Expr → Option String
  | .intLit _ v => some (if v < 0 then s!"(- {-v})" else s!"{v}")
  | .ident _ n => some n
  | .paren _ e => exprToSmt e
  | .unaryOp _ op e => do
    let E ← exprToSmt e
    match op with
    | .neg  => some s!"(- {E})"
    | .not_ => some s!"(not {E})"
    | _     => none
  | .binOp _ op l r => do
    let L ← exprToSmt l
    let R ← exprToSmt r
    match op with
    | .neq => some s!"(not (= {L} {R}))"
    | _ => (obBinOpSmt op).map fun s => s!"({s} {L} {R})"
  | _ => none

/-- True when `e` contains a multiplication of two non-constant operands — the
    genuinely nonlinear shape `omega` cannot own and interval `bv_decide` may miss. -/
def exprHasNonlinMul : Expr → Bool
  | .binOp _ .mul l r => (cEvalInt l).isNone && (cEvalInt r).isNone
      || exprHasNonlinMul l || exprHasNonlinMul r
  | .binOp _ _ l r => exprHasNonlinMul l || exprHasNonlinMul r
  | .paren _ e => exprHasNonlinMul e
  | _ => false

/-- The SMT-eligible VC class (v1): `#[overflow_checked]` obligations whose operand
    is genuinely nonlinear (a product of variables), not constant, and not already
    closed by the interval `bv_decide` path. Returns `(vcKey, smtlibScript)`. The
    script asserts the in-scope hypotheses and the NEGATION of the range goal:
    `unsat` ⇒ no overflow (solver-proved); `sat` ⇒ a counterexample exists. -/
def overflowSmtGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in overflowObligations modules do
    if o.closedVerdict.isSome then continue          -- constant tier owns it
    if o.bvGoal.isSome then continue                 -- interval bv_decide owns it
    if !exprHasNonlinMul o.opExpr then continue      -- omega owns the linear case
    -- soundness: require the operand AND every hypothesis to lower. If any
    -- #[requires]/guard falls outside the SMT fragment, DROP the whole query
    -- rather than emit one missing a constraint (which could read as a spurious
    -- counterexample). Never emit an unsound query.
    match exprToSmt o.opExpr, o.hyps.mapM exprToSmt with
    | some eSmt, some hypSmts =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      let decls := vars.map (fun v => s!"(declare-const {v} Int)")
      let hypAsserts := hypSmts.map (fun s => s!"(assert {s})")
      let neg := s!"(assert (not (and (<= {o.lo} {eSmt}) (<= {eSmt} {o.hi}))))"
      let script := "\n".intercalate
        (["; VC " ++ o.key, "; no-overflow of an operand in [" ++ toString o.lo ++ ", " ++ toString o.hi ++ "]",
          "(set-logic QF_NIA)"] ++ decls ++ hypAsserts ++ [neg, "(check-sat)", "(get-model)"])
      out := out ++ [(o.key, script)]
    | _, _ => pure ()
  return out

/-! ## Lean replay artifact (Phase 2 #12)

For each SMT VC we also emit a standalone Lean theorem that states the SAME
obligation — hypotheses as binders, the range goal as the conclusion — with an
in-toolchain proof attempt (`by omega`). If a kernel-checked tactic closes it, the
claim no longer depends on the external solver and graduates `solver_trusted` →
`proved_by_lean_replay` (a Lean/kernel class, no solver in the TCB). The bounded
*nonlinear* fragment we route to SMT is, by construction, outside `omega`'s reach
(and `nlinarith` is Mathlib, which is deliberately NOT a dependency), so today the
attempt does not close and the VC honestly stays `solver_trusted`. The artifact is
still emitted so a reviewer — or a Mathlib-enabled build that swaps `omega` for
`nlinarith` — can check it and graduate the evidence. -/


/-! ## Prover-neutral multi-kernel path — the `proved_by_two_kernels` beachhead

The evidence thesis says independence is the trust value: an obligation a
Lean-hosted compiler discharges with `omega` should ALSO be dischargeable by
OTHER, independently-implemented kernels. We lower the SAME structured obligation
`Expr` through a prover-neutral DRIVER (`ProverLowering`) and hand the script to
that kernel's linear-arithmetic decision procedure:

  * Rocq / `coqc`  — `lia`        (CIC kernel; certification lineage)
  * Isabelle / HOL — `presburger` (HOL kernel; FOUNDATIONAL independence from CIC)

A VC that Lean's `omega` AND ≥1 external kernel independently close on the same
subject graduates `proved_by_kernel_decision` → `proved_by_two_kernels` (or, with
≥2 externals, `proved_by_multi_kernel`). If a kernel is absent, the honest verdict
is "it did not run" — the VC keeps its class, never a fabricated upgrade. Adding a
new prover ("any useful cool language") is a new `ProverLowering` value plus its
binop column in `ReportVC`, not new plumbing. -/

/-- A prover-neutral lowering DRIVER (the Why3 "driver" idea): everything needed to
    turn a structured obligation into a self-contained proof script for one external
    kernel. `binop` is the prover's row of the shared lowering table; `render vars
    hyps concl` wraps the lowered pieces in that prover's goal/quantifier/proof
    syntax. Adding a prover is a new value of this record, not new code paths. -/
structure ProverLowering where
  name  : String
  binop : BinOp → String → String → Option String
  /-- `render quantifiedVars loweredHyps loweredConclusion → full source file`. -/
  render : List String → List String → String → String
  /-- This prover's implication arrow (Rocq `->`, Isabelle `-->`). Needed to build a
      GROUND implication for the lowering-agreement check, which cannot reuse
      `render`'s hypothesis handling because it must also negate the whole thing. -/
  arrow : String := "->"
  /-- This prover's typed quantifier prefix for `vars` (Rocq `forall (a b : Z), `,
      Isabelle `ALL a b::int. `). The agreement check MUST keep this even though its
      instances are ground: Isabelle infers a fresh free type variable per numeral in
      an unquantified proposition (`0 ≤ (100::'b)`), so the lemma stops being about
      integers and `presburger` cannot prove it. Variables are therefore pinned by
      equality hypotheses rather than substituted away. -/
  binder : List String → String := fun _ => ""
  /-- Wrap a proposition in this prover's negation. Both Rocq and Isabelle spell it
      `~`, matching `exprToProver`'s `.not_` case. -/
  negate : String → String := fun p => s!"~ ({p})"
  /-- **R-0455: the tactic is DATA, not a template literal.**

      Ordered attempts, tried in sequence. Measured cost of not having this field:
      `rocqNiaLowering` existed as a full clone of `rocqLowering` — a duplicated
      `ProverLowering` record whose only substantive difference was the word `lia` becoming
      `nia`. Reaching a different tactic cost a whole driver, which is the argument R-0455
      makes for `tactics` being a field.

      Ordered rather than a single value because a real pipeline tries cheap-then-expensive;
      budgeting them is future work and is why this is a list now rather than a `String`. -/
  tactics : List String := []
  /-- This prover's spelling of negation INSIDE an expression (`.not_`). Distinct from
      `negate`, which wraps a whole proposition. Rocq and Isabelle both use `~`; Lean uses
      `¬`, and that single character was what kept Lean's lowering from being a driver —
      and therefore what kept the agreement machinery from being pointable at it. -/
  notSym : String := "~"
  /-- `batchRender closedPropositions → one source file asserting ALL of them`.
      Batching matters: the agreement check emits one lemma per grid assignment, and
      a fresh Isabelle session build per lemma would cost ~30s each. -/
  batchRender : List String → String := fun _ => ""

/-- Lower a contract `Expr` through an arbitrary prover's binop column. Same linear
    fragment as `exprToLeanProp` (int literals/vars, `+`/`-`/`*`, comparisons,
    connectives, unary `-`/`~`); `div`/`mod` dropped as in `toLeanProp`. Structured
    (not a string rewrite), so the emitted script is well-formed by construction.
    Coq and Isabelle share this: both spell unary neg `(- e)`, `not` `~`, and a
    negative literal `(-k)`; only the binary-op column and wrapper differ. -/
def exprToProverU (binop : BinOp → String → String → Option String)
    (notSym : String) : Expr → Option String
  | .intLit _ v => some (if v < 0 then s!"({v})" else s!"{v}")
  | .ident _ n => some n
  | .paren _ e => exprToProverU binop notSym e
  | .unaryOp _ op e => do
    let E ← exprToProverU binop notSym e
    match op with
    | .neg  => some s!"(- {E})"
    | .not_ => some s!"({notSym} {E})"
    | _ => none
  | .binOp _ op l r => do
    let L ← exprToProverU binop notSym l; let R ← exprToProverU binop notSym r
    match op with
    | .div | .mod => none
    | _ => binop op L R
  | _ => none

/-- The linear fragment, lowered for a driver. `~` is the default because Rocq and Isabelle
    both spell negation that way; Lean passes `¬`.

    R-0450 (partial): negation used to be HARD-CODED to `~` here, which is the one thing that
    stopped this function from also being Lean's lowering — so `exprToLeanProp` existed as a
    near-copy, and the fragment was defined twice in two functions that had to agree. It is
    now defined once and `exprToLeanProp` delegates. -/
def exprToProver (binop : BinOp → String → String → Option String) : Expr → Option String :=
  exprToProverU binop "~"

/-- Lean's lowering of the linear fragment, for the replay theorem. Handles unary negation
    (`-30000`) — the signed bounds that make a VC SMT-eligible in the first place.

    **R-0450 (partial): this is now the SAME function as every other driver's**, specialised
    to `leanBinOp` and Lean's negation. It used to be an independent recursion that happened
    to match `exprToProver` case for case, differing only in negative-literal parentheses,
    a space, and `¬` versus `~` — which is exactly the "fragment defined twice, in two
    functions that must agree" that R-0450 exists to remove. Two of those three differences
    were cosmetic; the third is now a parameter.

    Why this matters beyond tidiness: the lowering-agreement check validates a rendering
    against the reference EVALUATOR (`safeOn`/`evalBoolEnv` on the AST), not against Lean.
    The standing justification for Lean being the one kernel whose rendering is unvalidated —
    "its rendering IS the reference, so there is nothing to validate it with" — was therefore
    wrong. The real obstacle was that Lean's lowering was not expressible as a driver, so the
    machinery could not be pointed at it. That obstacle is what this removes. -/
def exprToLeanProp (e : Expr) : Option String :=
  exprToProverU leanBinOp "¬" e

/-! ### Bridge differential-check (feature #1)

An INDEPENDENT concrete evaluator for the contract fragment, used to fuzz proved
obligations: sample variable assignments, and check that no hypothesis-satisfying
assignment refutes the obligation's safety conclusion. A counterexample under a
*proved* obligation would mean the Core→VC bridge (or the discharge) claimed
something concretely false — the one thing "proved" must never do. Independent of
`exprToProver`/omega: it evaluates the arithmetic directly (truncating `/`,`%`,
matching Concrete's `IntArith`), so agreement is a real cross-check, not a tautology. -/

/-! ### The reference evaluator (R-0455: no longer `partial`)

`evalIntEnv`/`evalBoolEnv` are what EVERY lowering-agreement check measures a rendering
against — Rocq's, Isabelle's, the SMT column's and Lean's own. They used to be `partial def`s,
which meant the kernel could not reduce them: the yardstick for every rendering was itself
outside the reach of proof, and no `rfl` example or theorem could say anything about it. That
limitation was hit three times while writing locks elsewhere in this arc.

They are now thin wrappers over `ofExpr` + `TermIR.eval*`, both structural. The behaviour is
the same fragment plus two gains that fall out of the IR:

* **casts evaluate** (as the reference's wrap) where they previously yielded `none`, so
  obligations like `arr[(a / b) as Int]` now have a reference value instead of being skipped;
* `geq`/`gt`/`neq` are canonicalised rather than special-cased, so the relation set is
  minimal without narrowing what can be evaluated.

Spec-function calls still evaluate to `none`: `noSyms` gives uninterpreted symbols no meaning,
which is the honest default — the agreement machinery must not invent a value for a function
it knows nothing about. -/

/-- No oracle for uninterpreted symbols. A spec call has no reference value, so an agreement
    instance mentioning one is SKIPPED rather than answered — the fail-closed direction. -/
def noSyms : TermIR.SymEnv := fun _ _ => none

/-- Integer-valued reference evaluation of a contract expression. -/
def evalIntEnv (env : List (String × Int)) (e : Expr) : Option Int :=
  (ofExpr e).bind (TermIR.evalInt env noSyms)

/-- Boolean-valued reference evaluation of a contract expression. -/
def evalBoolEnv (env : List (String × Int)) (e : Expr)
    (benv : TermIR.BoolEnv := []) : Option Bool :=
  (ofExpr e).bind (TermIR.evalBool env noSyms benv)

/-! #### Behavioural locks on the reference evaluator — **newly possible**

None of these could exist while `evalIntEnv` was `partial`: the kernel could not reduce it, so
its behaviour was only ever assertable by grep. `check_vc_bridge_register.sh` said so in its
own comment. These are the locks that grep stood in for.

The division convention is the one that matters. Lean's `.tdiv`, `/` and `.fdiv` agree on
positives and diverge on negatives, so a plausible "cleanup" would pass every positive test
and silently re-point the reference every rendering is validated against. -/

-- The three spellings, distinguished where they actually differ. Restored here after the
-- evaluator rewrite removed them along with the old `partial` definition: they pin the
-- CONVENTION, while the `evalIntEnv` examples below pin which convention this code uses, and
-- both halves are needed. A swap from `.tdiv` to `/` passes every positive test.
example : (-7 : Int).tdiv 2 = -3 := rfl   -- truncate toward zero — what Concrete means
example : (-7 : Int).fdiv 2 = -4 := rfl   -- floor — a DIFFERENT answer
example : (-7 : Int).tmod 2 = -1 := rfl   -- remainder follows the dividend's sign
example : (-7 : Int).emod 2 =  1 := rfl   -- Euclidean — also different

private def spR : Span := default

-- TRUNCATING division and remainder, pinned on the negative case where the spellings differ.
example : evalIntEnv [("a", -7), ("b", 2)]
    (.binOp spR .div (.ident spR "a") (.ident spR "b")) = some (-3) := rfl
example : evalIntEnv [("a", -7), ("b", 2)]
    (.binOp spR .mod (.ident spR "a") (.ident spR "b")) = some (-1) := rfl
-- Division by zero has NO reference value; it is never guessed.
example : evalIntEnv [("a", -7), ("b", 0)]
    (.binOp spR .div (.ident spR "a") (.ident spR "b")) = none := rfl
-- An unbound variable propagates `none` rather than defaulting to 0.
example : evalIntEnv [] (.binOp spR .add (.ident spR "x") (.intLit spR 1)) = none := rfl
-- A spec-function call has no reference value: `noSyms` refuses to invent one.
example : evalIntEnv [] (.call spR "f" [] [.intLit spR 1]) = none := rfl

-- Relations the old evaluator special-cased are canonicalised, and still evaluate the same.
example : evalBoolEnv [("a", 3), ("b", 5)]
    (.binOp spR .geq (.ident spR "a") (.ident spR "b")) = some false := rfl
example : evalBoolEnv [("a", 5), ("b", 3)]
    (.binOp spR .gt (.ident spR "a") (.ident spR "b")) = some true := rfl
example : evalBoolEnv [("a", 3), ("b", 3)]
    (.binOp spR .neq (.ident spR "a") (.ident spR "b")) = some false := rfl

-- GAINED by going through the IR: a cast now has a reference value, where the old evaluator
-- returned `none` and the agreement instance was skipped. 200 at i8 wraps to -56.
example : evalIntEnv [("x", 200)] (.cast spR (.ident spR "x") .i8) = some (-56) := rfl
example : evalBoolEnv [("x", 200)]
    (.binOp spR .lt (.cast spR (.ident spR "x") .i8) (.intLit spR 0)) = some true := rfl

/-- A family-neutral view of one linear obligation, so every runtime-safety family
    (overflow / array-bounds / div-nonzero, and any future family) flows through the
    SAME prover-neutral lowering instead of each re-implementing it. `mainExpr` is the
    operand/index/divisor to lower; `mkConcl` builds the obligation's conclusion from
    the driver's binop column and the lowered `mainExpr` — so each family states its
    own shape (`lo<=e<=hi`, `0<=i<n`, `d<>0`) in the prover's syntax. `desc` is the
    human display; `hyps` are the in-scope assumptions. Selection is the omega domain:
    non-constant obligations carrying a linear `leanGoal`, matched to omega by `key`. -/
structure MultiKernelObl where
  key      : String
  desc     : String
  hyps     : List Expr
  mainExpr : Expr
  mkConcl  : (BinOp → String → String → Option String) → String → Option String
  -- concrete safety check for the bridge fuzzer (feature #1): does the obligation's
  -- conclusion hold under this environment? `none` if it can't be evaluated.
  safeOn   : List (String × Int) → Option Bool
  -- The obligation's OWN boundary values — the type range for overflow, `0` and the
  -- length for bounds, `0` for a divisor. These are where a comparison-operator error
  -- lives: `<=` rendered as `<` differs from the reference ONLY at a boundary, and
  -- nowhere else. They were previously captured inside `mkConcl`/`safeOn` and invisible
  -- to the grid, so whether the mutation was detected depended on the boundary happening
  -- to appear as a literal in the hypotheses. Measured: `fuzzGrid` contains 3 and 100 but
  -- not 4, so a `[i32; 4]` bounds obligation caught it only incidentally.
  boundaryVals : List Int := []

/-- Collect the linear runtime-safety obligations of every family into the neutral
    view. Adding a family is a new block here, not a new lowering. -/
def multiKernelObligations (modules : List Module) (requireLeanGoal : Bool := true)
    : List MultiKernelObl := Id.run do
  let mut out : List MultiKernelObl := []
  for o in overflowObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => do let lo ← bop .leq (toString o.lo) e; let hi ← bop .leq e (toString o.hi); bop .and_ lo hi
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.opExpr).map (fun v => o.lo ≤ v && v ≤ o.hi)
      out := out ++ [{ boundaryVals := [o.lo, o.hi], key := o.key, desc := s!"{Concrete.fmtExpr o.opExpr} ∈ [{o.lo}, {o.hi}]", hyps := o.hyps, mainExpr := o.opExpr, mkConcl := mk, safeOn := safe }]
  for o in boundsObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => do let lo ← bop .leq "0" e; let hi ← bop .lt e (toString o.size); bop .and_ lo hi
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.idxExpr).map (fun v => 0 ≤ v && v < (Int.ofNat o.size))
      out := out ++ [{ boundaryVals := [0, Int.ofNat o.size], key := o.key, desc := s!"0 ≤ {Concrete.fmtExpr o.idxExpr} < {o.size} (bounds of {o.arrName})", hyps := o.hyps, mainExpr := o.idxExpr, mkConcl := mk, safeOn := safe }]
  for o in divObligations modules do
    if o.closedVerdict.isNone && (!requireLeanGoal || o.leanGoal.isSome) then
      let mk : (BinOp → String → String → Option String) → String → Option String :=
        fun bop e => bop .neq e "0"
      let safe : List (String × Int) → Option Bool :=
        fun env => (evalIntEnv env o.divExpr).map (fun v => v != 0)
      out := out ++ [{ boundaryVals := [0], key := o.key, desc := s!"{Concrete.fmtExpr o.divExpr} ≠ 0 (divisor)", hyps := o.hyps, mainExpr := o.divExpr, mkConcl := mk, safeOn := safe }]
  return out

/-- Result of fuzzing one obligation against the concrete evaluator (feature #1). -/
structure BridgeFuzzResult where
  key            : String
  desc           : String
  hypSat         : Nat                              -- assignments satisfying every hypothesis
  counterexample : Option (List (String × Int))     -- a hyp-satisfying assignment that REFUTES safety

/-- Integer probes, including i32 extremes and 46341 (≈√(2^31), where `a*a`
    overflows i32) so the fuzzer actually finds real violations. -/
def fuzzGrid : List Int := [-2147483648, -100, -3, -1, 0, 1, 3, 100, 46341, 2147483647]

/-- Cartesian product of `vals` over `vars` (all assignments). Callers bound `vars`
    and shrink `vals` to keep this finite. -/
def cartesianEnvs (vars : List String) (vals : List Int) : List (List (String × Int)) :=
  match vars with
  | [] => [[]]
  | v :: rest =>
    let restEnvs := cartesianEnvs rest vals
    vals.flatMap (fun x => restEnvs.map (fun e => (v, x) :: e))

/-- Cartesian product over a PER-VARIABLE grid. `cartesianEnvs` shares one value list across
    every variable, which is wrong whenever the variables have different domains — a `u32`
    parameter and an `i32` parameter do not accept the same literals. -/
def cartesianEnvsPer : List (String × List Int) → List (List (String × Int))
  | [] => [[]]
  | (v, vals) :: rest =>
    let restEnvs := cartesianEnvsPer rest
    vals.flatMap (fun x => restEnvs.map (fun e => (v, x) :: e))

/-- Fuzz every linear obligation against the INDEPENDENT concrete evaluator: over a
    grid of assignments, keep those satisfying all hypotheses, and look for one that
    refutes the safety conclusion. A counterexample under a *proved* obligation is a
    bridge/discharge unsoundness; a counterexample under an *unproved* one validates
    that the fuzzer has teeth. Assignments where a hypothesis can't be evaluated are
    conservatively excluded (never tested against). -/
def bridgeFuzz (modules : List Module) : List BridgeFuzzResult := Id.run do
  let mut out : List BridgeFuzzResult := []
  for o in multiKernelObligations modules do
    let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
    -- keep the grid finite: shrink to extremes when there are many variables.
    let grid := if vars.length ≥ 4 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647] else fuzzGrid
    let mut hypSat := 0
    let mut cex : Option (List (String × Int)) := none
    for env in cartesianEnvs vars grid do
      if o.hyps.all (fun h => evalBoolEnv env h == some true) then
        hypSat := hypSat + 1
        if o.safeOn env == some false && cex.isNone then cex := some env
    out := out ++ [{ key := o.key, desc := o.desc, hypSat, counterexample := cex }]
  return out

/-! ### R-0462: fuzz the compiled ARTIFACT against the safety claims

Register A asserts *if the obligation holds, the runtime property holds*. R-0460 discharges
that row by row as theorems. This is the empirical shadow of the same statement, and it tests
something no theorem here reaches: for a function whose runtime-safety obligations all read
`proved`, generate inputs satisfying its `#[requires]`, run the **compiled binary**, and
assert it does not trap.

Distinct from `bridge-check`, and the distinction is the point. `bridge-check` evaluates the
*obligation* on sampled inputs and looks for one that refutes it — obligation against a
model. This runs the *artifact*, so it also crosses surface → Core → SSA → LLVM, which no
register row covers at all.

H23 is the existence proof: a bounds obligation read `proved_by_multi_kernel` and the binary
aborted on its first run. Every kernel-side surface reported success; a fuzzer pointed at the
binary would have caught it in seconds.

This module produces the PLAN — candidate functions and hypothesis-satisfying argument
tuples — and emits a driver program that exercises them. Compiling and running that driver is
the gate's job (`check_artifact_fuzz.sh`), because the compiler cannot re-invoke itself.
Keeping the split here means the plan is deterministic and testable on its own. -/

/-- Can the driver pass a literal of this type? Integers, and fixed-size arrays of them.

    Arrays matter specifically: H23 — the hole this whole task cites as its existence proof —
    lives in `pub fn bad(a: [i32; 4]) -> i32`. An int-only fuzzer excludes the one function it
    most needed to reach, which is how a coverage limit becomes a blind spot. -/
private def fuzzablePassableTy : Ty → Bool
  | .array elem _ => (IntArith.intBitWidth elem).isSome
  | ty            => (IntArith.intBitWidth ty).isSome

/-- Argument spellings for one parameter. An integer contributes its grid; a fixed-size array
    contributes a few UNIFORM fills rather than the cartesian product over its elements —
    `[i32; 4]` over a 12-value grid would be 20736 arrays for one parameter alone. Uniform
    fills at the extremes and zero are what expose an index/bounds fault, which is what the
    array case is here for. -/
private def fuzzArgSpellings (ty : Ty) (grid : List Int) : List String :=
  let lit := fun (v : Int) => if v < 0 then s!"({v})" else s!"{v}"
  match ty with
  | .array elem n =>
    let evs := match IntArith.intRange elem with
      | some (lo, hi) => ([lo, 0, 1, hi].filter (fun v => lo ≤ v && v ≤ hi)).eraseDups
      | none => [0]
    evs.map fun v => "[" ++ ", ".intercalate (List.replicate n (lit v)) ++ "]"
  | _ => grid.map lit

/-- One function the artifact fuzzer can exercise, with the argument rows to try. -/
structure ArtifactFuzzCase where
  /-- How the driver spells the call, e.g. `tg::d`. -/
  callPath : String
  /-- Dotted name, matching obligation keys' `fnQual`. -/
  fnQual   : String
  /-- Argument rows, already rendered as source literals. Strings rather than `Int`s because
      an array argument has no `Int` spelling. -/
  argRows  : List (List String)
  /-- What the obligation layer CLAIMS about this function's runtime safety, which decides
      what a trap means:

      * `"claimed"`  — it has runtime-safety obligations and they all read proved. A trap is a
        counterexample to Register A, to the obligation generator, or to the lowering. This is
        the case the task exists to find.
      * `"unclaimed"` — it has NO runtime-safety obligations at all. A trap means an obligation
        should have existed and did not: the *applicability* half of H24, where the shift family
        was simply absent and the binary aborted with nothing having been stated.
      * `"unproved"`  — at least one obligation is unproved or capped. A trap is EXPECTED and
        is not a finding; the compiler never claimed otherwise.

      Fuzzing without this distinction makes every trap ambiguous. Measured: `sum_all` in
      `examples/error_conventions/` traps on four `i32::MIN`s, and its bounds obligation reads
      `unproven` — reporting that as a Register A counterexample would be a false alarm in the
      first run of the tool. -/
  claim    : String
  deriving Repr

/-- Candidate functions for artifact fuzzing, with contract-satisfying argument rows.

    The filter is narrow, and every clause is a callability requirement rather than a taste:
    * `isPublic` — a private function cannot be called from a generated driver;
    * in the SCOPE of the file the driver is appended to (`scopedValidCore`) — `parsed.modules`
      includes the resolved standard library, and a driver calling into std does not resolve;
    * params are integers or fixed-size integer arrays — the driver passes literals;
    * return type an integer — so the driver can bind and accumulate the result;
    * `capSet` empty and no capability params — a function needing `with(Std)` would force the
      driver to hold capabilities it may not be able to grant;
    * no type params — no instantiation to choose here.

    **A `#[requires]` this layer cannot evaluate excludes the function.** Preconditions are
    checked with `evalBoolEnv` over the integer parameters; if a precondition mentions anything
    else (an array element, a field), it cannot be verified here, and calling anyway would feed
    the function inputs it never promised to handle and then blame the compiler for the trap.
    Fail closed: skip it.

    Every exclusion is counted and printed by `--report artifact-fuzz`, because a fuzzer that
    reports "no traps" while silently testing nothing is worse than no fuzzer. -/
def artifactFuzzCases (modules : List Module) (ownFns : List String)
    (claimOf : String → String) : List ArtifactFuzzCase := Id.run do
  let mut out : List ArtifactFuzzCase := []
  for (pfx, f) in modules.flatMap allFunctions do
    if !f.isPublic then continue
    if f.isTest || f.isEntryPoint then continue
    if !f.typeParams.isEmpty || !f.capParams.isEmpty then continue
    if f.capSet != .empty then continue
    if f.params.isEmpty then continue
    if !(ownFns.contains (pfx ++ f.name)) then continue
    if !f.params.all (fun p => fuzzablePassableTy p.ty) then continue
    if (IntArith.intBitWidth f.retTy).isNone then continue
    let intNames := f.params.filterMap (fun p =>
      if (IntArith.intBitWidth p.ty).isSome then some p.name else none)
    -- Contract must be checkable over the integer params alone, or we do not fuzz it.
    let reqIdents := (f.requires.flatMap collectIdents).eraseDups
    if !reqIdents.all (fun n => intNames.contains n) then continue
    let baseGrid := if f.params.length ≥ 3 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647]
                    else fuzzGrid
    -- PER-PARAMETER grids, clamped to each parameter's own type range plus that type's own
    -- boundaries. Not an optimisation: a `u32` parameter handed `-1` produces a driver that
    -- does not COMPILE, so a shared grid yielded a fuzzer that could never run. Seeding each
    -- type's `lo`/`hi` also puts the boundary in the grid by construction rather than by luck.
    let intGrids : List (String × List Int) := f.params.filterMap fun p =>
      match IntArith.intRange p.ty with
      | some (lo, hi) =>
        some (p.name, ((baseGrid ++ [lo, hi]).filter (fun v => lo ≤ v && v ≤ hi)).eraseDups)
      | none => none
    let satEnvs := (cartesianEnvsPer intGrids).filter (fun env =>
      f.requires.all (fun h => evalBoolEnv env h == some true))
    if satEnvs.isEmpty then continue
    -- Build one row per (satisfying integer assignment × array fill), rendering each argument
    -- in parameter order.
    let mut rows : List (List String) := []
    for env in satEnvs do
      let mut acc : List (List String) := [[]]
      for p in f.params do
        let spellings :=
          if (IntArith.intBitWidth p.ty).isSome then
            match env.lookup p.name with
            | some v => [if v < 0 then s!"({v})" else s!"{v}"]
            | none => []
          else fuzzArgSpellings p.ty baseGrid
        acc := acc.flatMap (fun pre => spellings.map (fun sp => pre ++ [sp]))
      rows := rows ++ acc
    if rows.isEmpty then continue
    let fq := pfx ++ f.name
    let callPath := (fq.splitOn ".").intersperse "::" |>.foldl (· ++ ·) ""
    out := out ++ [{ callPath, fnQual := fq, argRows := rows, claim := claimOf fq }]
  return out

/-- Emit a driver for the given cases under the given test-function name.

    Results are accumulated into a value the driver returns, so nothing is dead-code
    eliminated: a call whose result is discarded could in principle be optimized away, and
    then the fuzzer would run a program that never performs the operation it is testing. -/
def artifactFuzzDriverFor (cases : List ArtifactFuzzCase) (fnName : String) : String :=
  -- `unproved` functions are NOT called. A trap there is expected and would drown the signal
  -- the tool exists to produce; the compiler never claimed they were safe.
  let lines := cases.flatMap fun c =>
    c.argRows.zipIdx.map fun (r, i) =>
      s!"    acc = acc + (({c.callPath}({", ".intercalate r})) as Int);   // {c.claim} {c.fnQual}#{i}"
  let body := "\n".intercalate lines
  -- A `#[test]` function inside a module, because that is the shape `--test` accepts and
  -- `--test` COMPILES and runs (via clang) rather than interpreting — which is the whole
  -- point: an interpreted driver would test a model again, not the artifact that ships.
  --
  -- `acc` is returned (as `acc - acc`, so the result is always 0 and the test passes unless
  -- the program TRAPS) specifically so no call can be dead-code eliminated. A driver whose
  -- calls are optimized away runs a program that never performs the operation under test.
  "// GENERATED by `--report artifact-fuzz` (R-0462). Do not edit.\n" ++
  "// Appended to the file under test and run with `--test`, which COMPILES and executes.\n" ++
  "// A TRAP here is a counterexample to Register A, to the obligation generator, or to the\n" ++
  "// lowering — the binary did what no kernel-side surface reported.\n" ++
  -- TOP LEVEL, not inside a wrapper module. A `mod artifact_fuzz { … }` cannot see sibling
  -- top-level modules — `tg::d` fails to resolve from inside it with "call to undeclared
  -- function 'tg_d'" — whereas the file's own `main` calls exactly that path successfully.
  -- The driver therefore lives where the callers it imitates live.
  "#[test]\n" ++
  s!"fn {fnName}() -> i32 \{\n" ++
  "    let mut acc: Int = 0;\n" ++
  body ++ "\n" ++
  "    return (acc - acc) as i32;\n" ++
  "}\n"

/-- The driver that MATTERS: functions the obligation layer claims are safe, plus functions it
    stated nothing about. A trap in the first group is a Register A counterexample; a trap in
    the second means an obligation should have existed and did not. -/
def artifactFuzzDriver (cases : List ArtifactFuzzCase) : String :=
  artifactFuzzDriverFor (cases.filter (fun c => c.claim != "unproved")) "artifact_fuzz_all"

/-- A driver over the `unproved` functions, emitted separately and for ONE purpose: proving the
    harness can detect a trap at all.

    Needed because of an outcome that is good news read carelessly: after R-0461 and R-0464 no
    fixture in this repo claims a proved obligation on a function that traps — which is exactly
    what those fixes accomplished. So the soundness check finds nothing, and a check that finds
    nothing is indistinguishable from a check that cannot find anything. This driver is the
    distinguishing experiment: these functions are KNOWN to trap, the compiler never claimed
    otherwise, and the harness must report it. A trap here is not a defect; its ABSENCE is. -/
def artifactFuzzMechanismDriver (cases : List ArtifactFuzzCase) : String :=
  artifactFuzzDriverFor (cases.filter (fun c => c.claim == "unproved")) "artifact_fuzz_mechanism"

/-! ### Lowering-agreement check — closing the "same proposition?" hole

`proved_by_two_kernels` matches kernels on the obligation KEY, and each driver
re-spells the obligation in its own syntax. Nothing so far checks that those
spellings mean the SAME thing, which the multi-kernel report states outright as a
non-attestation. So two kernels could each close a DIFFERENT (possibly weaker)
proposition and the report would still read `proved_by_two_kernels` — the badge
would be measuring agreement it never established.

This closes that hole without writing a parser per prover syntax: use each prover
as the evaluator of its OWN output. We take the driver's rendering of the obligation
verbatim — the same string the multi-kernel path sends the kernel — and PIN its
variables to one grid assignment with equality hypotheses, giving a proposition
whose truth value is decided (`lia`/`presburger` both decide ground linear
arithmetic either way). We compare that against the reference truth value from
`evalBoolEnv`, the independent concrete evaluator already used by the bridge fuzzer:

  * reference TRUE  → the prover must prove the ground implication
  * reference FALSE → the prover must prove its NEGATION

If every instance checks, the driver's rendering has the same truth table as the
reference on the grid — so precedence bugs, a wrong operator column (`~=` vs `<>`),
and mangled hypotheses all surface. Mapping onto `KernelVerdict` is exact: a
malformed rendering is a syntax `error`, while a well-formed rendering that means
something else is a `refused` — a real DISAGREEMENT.

Honest limits. This is a differential test, not a proof of equivalence: it certifies
agreement on the SAMPLED assignments only. A rendering that differs only at values
the hypotheses make unreachable will (correctly) read as agreeing, and one that
differs only outside the grid will be missed — hence `agreementGrid` seeds the
literals appearing in the obligation and their ±1 neighbours, which is where
comparison-operator errors live. -/

/-- How many ground instances to check per obligation. Bounded because each instance
    is a lemma in the emitted script; hypothesis-satisfying assignments are taken
    first since they are the informative ones (a vacuous instance is trivially true
    for the prover, though it still catches a hypothesis rendered too weakly). -/
def agreementInstanceCap : Nat := 24

/-- Every integer literal occurring in an expression. Used to derive BOUNDARY probe
    values, because an off-by-one operator bug (`<=` rendered as `<`) only shows up
    at a value where the two differ — a fixed grid can miss it entirely. -/
def collectIntLits : Expr → List Int
  | .intLit _ v => [v]
  | .paren _ e => collectIntLits e
  | .unaryOp _ _ e => collectIntLits e
  | .binOp _ _ l r => collectIntLits l ++ collectIntLits r
  | _ => []

/-- Probe values for one obligation: the shared grid plus each literal appearing in
    the obligation or its hypotheses, and each literal ±1. Those neighbours are what
    make a comparison-operator error observable. -/
def agreementGrid (o : MultiKernelObl) (base : List Int) : List Int :=
  -- Seed from the literals appearing in the obligation AND from the obligation's own
  -- boundary values, each with its ±1 neighbours. The boundaries are the load-bearing
  -- addition: a comparison-operator error differs from the reference only there, so a grid
  -- that does not reach them cannot detect one. Relying on the boundary appearing as a
  -- literal made detection incidental.
  let lits := (o.hyps.flatMap collectIntLits ++ collectIntLits o.mainExpr ++ o.boundaryVals)
  let withNeighbours := lits.flatMap (fun v => [v - 1, v, v + 1])
  (base ++ withNeighbours).eraseDups

/-- One `(vcKey, proofScript)` per obligation: a single batched script whose lemmas
    are the ground instances described above. A `refused` verdict on that script
    means this obligation's lowering DISAGREES with the reference evaluator.
    Obligations whose lowering is outside the fragment are skipped (never asked). -/
def loweringAgreementProps (pl : ProverLowering) (modules : List Module)
    : List (String × List String) := Id.run do
  let mut out : List (String × List String) := []
  for o in multiKernelObligations modules do
    let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
    -- Boundary-aware grid. With ≥3 variables the cartesian product explodes, so use
    -- the bare extremes there and reserve the literal-derived neighbours (which is
    -- what catches an off-by-one operator column) for the small-arity cases.
    let base := if vars.length ≥ 4 then [(-2147483648 : Int), -1, 0, 1, 46341, 2147483647]
                else fuzzGrid
    let grid := if vars.length ≥ 3 then base else agreementGrid o base
    -- partition the grid by whether the hypotheses hold, preferring the informative
    -- (hypothesis-satisfying) assignments up to the cap.
    let envs := cartesianEnvs vars grid
    let sat := envs.filter (fun e => o.hyps.all (fun h => evalBoolEnv e h == some true))
    let unsat := envs.filter (fun e => !(o.hyps.all (fun h => evalBoolEnv e h == some true)))
    -- Implication instances want hypothesis-SATISFYING assignments: those are where
    -- the implication is not vacuous.
    let implEnvs := (sat.take agreementInstanceCap)
                    ++ (unsat.take (agreementInstanceCap - min agreementInstanceCap sat.length))
    -- Conclusion-only instances must span the WHOLE grid, hypotheses or not. Taking
    -- only hypothesis-satisfying points here would defeat the purpose: a weakened
    -- conclusion is invisible on the domain the hypotheses carve out (see below), so
    -- half the budget is spent on assignments the hypotheses reject.
    let half := agreementInstanceCap / 2
    let conclEnvs := (sat.take half) ++ (unsat.take half)
    -- The driver's rendering of the obligation itself, rendered ONCE: this is the
    -- very string the multi-kernel path sends the kernel, so we are checking the
    -- production lowering, not a special variant of it.
    let concl := (exprToProverU pl.binop pl.notSym o.mainExpr).bind (o.mkConcl pl.binop)
    let loweredHyps := o.hyps.mapM (exprToProverU pl.binop pl.notSym)
    match concl, loweredHyps with
    | some c, some hs =>
      let body := String.join (hs.map (fun h => s!"({h}) {pl.arrow} ")) ++ c
      -- Pin each variable to an assignment with an equality hypothesis instead of
      -- substituting a literal, so the prover's TYPED binder is retained. Returns
      -- `none` if some variable has no value in this environment.
      let pinnedClaim := fun (env : List (String × Int)) (claim : String) (truth : Bool) =>
        let pins := vars.filterMap (fun v => do
          let value ← env.lookup v
          let lit := if value < 0 then s!"({value})" else s!"{value}"
          pl.binop .eq v lit)
        if pins.length != vars.length then none
        else
          let pinArrows := String.join (pins.map (fun p => s!"({p}) {pl.arrow} "))
          some s!"{pl.binder vars}{pinArrows}{if truth then claim else pl.negate claim}"
      let mut props : List String := []
      -- (a) the WHOLE implication, which exercises the hypothesis rendering.
      for env in implEnvs do
        match o.safeOn env with
        | none => pure ()   -- no reference obtainable; never guess
        | some cv =>
          let hypsHold := o.hyps.all (fun h => evalBoolEnv env h == some true)
          match pinnedClaim env body (!hypsHold || cv) with
          | some p => props := props ++ [p]
          | none => pure ()
      -- (b) the CONCLUSION alone, over a spread of the grid and ignoring whether the
      -- hypotheses hold. This is what catches a WEAKENED conclusion: rendering
      -- `A ∧ B` as `A ∨ B` has the same truth value everywhere the hypotheses hold
      -- (both conjuncts are true there), so (a) alone provably cannot see it. The two
      -- differ only where exactly one side holds — assignments the hypotheses reject,
      -- but still perfectly good tests of the RENDERING itself.
      for env in conclEnvs do
        match o.safeOn env with
        | none => pure ()
        | some cv =>
          match pinnedClaim env c cv with
          | some p => props := props ++ [p]
          | none => pure ()
      if !props.isEmpty then
        out := out ++ [(o.key, props)]
    | _, _ => pure ()   -- outside the fragment: never asked
  return out

/-- One batched source file per obligation, for the drivers that shell out to a prover
    binary. Batching matters: a fresh Isabelle session per lemma costs ~30s. -/
def loweringAgreementScripts (pl : ProverLowering) (modules : List Module)
    : List (String × String) :=
  (loweringAgreementProps pl modules).map (fun (k, ps) => (k, pl.batchRender ps))

/-- `(vcKey, proofScript)` for each linear obligation (ALL families), lowered through
    the given driver. The conclusion is built via the driver's binop column, so `<=` /
    `<` / `<>` / conjunction are spelled the prover's way. Soundness: if the main expr,
    ANY hypothesis, or the conclusion falls outside the fragment we DROP the whole goal
    (never emit a partial one — a dropped goal reads `not-asked`, never a false verdict). -/
def proverReplayGoals (pl : ProverLowering) (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in multiKernelObligations modules do
    let concl : Option String := (exprToProverU pl.binop pl.notSym o.mainExpr).bind (o.mkConcl pl.binop)
    match concl, o.hyps.mapM (exprToProverU pl.binop pl.notSym) with
    | some c, some hyps =>
      let vars := (collectIdents o.mainExpr ++ o.hyps.flatMap collectIdents).eraseDups
      out := out ++ [(o.key, pl.render vars hyps c)]
    | _, _ => pure ()
  return out

/-- **Lean driver — R-0450: the reference kernel's OWN rendering, made checkable.**

    Lean was the one kernel whose lowering was never validated, and the reason on record was
    that its rendering *is* the reference the others are measured against. That was false.
    The agreement check measures a rendering against the reference EVALUATOR
    (`safeOn`/`evalBoolEnv`, which walk the AST and know nothing about Lean); Rocq and
    Isabelle are compared to what the expression MEANS, not to Lean. Lean's rendering was
    simply never put on the same scale, because it was not expressible as a driver.

    It is now. `binop := leanBinOp` and `notSym := "¬"` are exactly what `exprToLeanProp`
    uses — the same function, since `exprToLeanProp` delegates to `exprToProverU` — so this
    validates the PRODUCTION lowering rather than a special variant built for the check.
    That property is the whole point; a driver that rendered differently would prove
    something true about a string nobody sends to a kernel.

    `batchRender` emits a CONJUNCTION rather than a source file: the other drivers shell out
    to `coqc`/`isabelle`, while Lean's instances are discharged in-process by the existing
    omega path (`kernelDischargeLoopVCs`), which wraps a goal string in
    `theorem … := by intros; omega`. One conjunction per obligation means one closed goal
    answers "does this rendering agree with the evaluator on every sampled assignment". -/
def leanLowering : ProverLowering where
  name := "lean"
  binop := leanBinOp
  notSym := "¬"
  arrow := "→"
  negate := fun p => s!"¬ ({p})"
  binder := fun vars => if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"∀ ({" ".intercalate vars} : Int), "
    let arrows := String.join (hyps.map (fun h => s!"({h}) → "))
    s!"theorem vc : {binder}{arrows}{concl} := by intros; omega"
  batchRender := fun props => " ∧ ".intercalate (props.map (fun p => s!"({p})"))

/-- `(obligationKey, goal)` validating that **Lean's own** rendering denotes the obligation.

    Discharged by the ordinary omega path; a key that closes is an obligation whose Lean
    rendering agreed with the reference evaluator on every sampled assignment, and is
    therefore eligible to mint a `LoweringValidated` witness — the same standard every
    external kernel has had to meet since the witness change. -/
def leanAgreementGoals (modules : List Module) : List (String × String) :=
  -- LINEAR obligations only, and the restriction is a soundness point rather than a
  -- convenience. The other drivers get a three-valued answer from their prover — closed,
  -- refused, error — so `refused` genuinely means "this rendering has a different truth
  -- table". The in-process Lean path returns only the CLOSED set, so a goal that fails to
  -- close is indistinguishable from one omega cannot decide. omega decides linear integer
  -- arithmetic; handed a pinned instance of `a * b` it fails on both counts at once.
  --
  -- Measured before this filter existed: 48 of 96 instances "DISAGREED" on
  -- `two_kernel_demo`, all of them the nonlinear `mul_unbounded`, none of them an actual
  -- rendering fault. Reporting those as disagreement would be a false alarm in the one
  -- check whose entire job is to be believed when it cries wolf.
  --
  -- This is not a coverage hole in disguise: the linear fragment is exactly where omega is
  -- the discharging kernel, so it is exactly where Lean's rendering is load-bearing.
  -- Nonlinear obligations are answered by bv_decide or SMT, whose renderings have their own
  -- agreement checks. Widening this needs a Lean discharge that reports refusal distinctly.
  let linearKeys := (multiKernelObligations modules).filterMap (fun o =>
    if exprHasNonlinMul o.mainExpr then none else some o.key)
  (loweringAgreementProps leanLowering modules).flatMap fun (k, ps) =>
    if !linearKeys.contains k then [] else
    ps.zipIdx.map fun (p, i) => (s!"{k}#leanagree{i}", p)

/-- Obligations whose Lean rendering agreed with the reference evaluator on EVERY sampled
    assignment. Mirrors `smtValidatedObligations`: all instances must close, and an
    obligation with no instances is not validated — "we never checked" is not "it agreed". -/
def leanValidatedObligations (goals : List (String × String)) (closed : List String)
    : List String :=
  let keyOf := fun (k : String) => (k.splitOn "#leanagree").headD k
  let obligations := (goals.map (fun (k, _) => keyOf k)).eraseDups
  obligations.filter fun ob =>
    let mine := goals.filter (fun (k, _) => keyOf k == ob)
    !mine.isEmpty && mine.all (fun (k, _) => closed.contains k)

/-- The one Rocq script shape, parameterised by tactic and header comment. Both Rocq drivers
    are now this function plus two fields, instead of two records that had to be kept in step.

    The `Print Assumptions` line is emitted here, once, and that placement is deliberate:
    `coqc` exits 0 on `Admitted.` too, so the exit code cannot distinguish a closed proof from
    a stated one. A per-driver template made this an attestation each clone had to remember —
    both happened to keep it, but "happened to" is the property this removes. -/
def rocqScript (tactic hdr : String) (vars hyps : List String) (concl : String) : String :=
  let binder := if vars.isEmpty then "" else s!"forall ({" ".intercalate vars} : Z), "
  let arrows := String.join (hyps.map (fun h => s!"({h}) -> "))
  "\n".intercalate
    [ hdr,
      "From Stdlib Require Import ZArith.", "From Stdlib Require Import Lia.",
      "Open Scope Z_scope.", s!"Lemma vc : {binder}{arrows}{concl}.",
      s!"Proof. {tactic}. Qed.",
      -- ATTEST: see `rocqScript`'s docstring — the exit code alone cannot tell a Qed-closed
      -- proof from an `Admitted.` one, so the script asserts its own integrity.
      "Print Assumptions vc." ]

/-- Rocq/`coqc` driver: `lia` is Coq's linear-integer-arithmetic decision procedure
    (CIC kernel). -/
def rocqLowering : ProverLowering where
  name := "rocq"
  binop := rocqBinOp
  tactics := ["lia"]
  render := rocqScript "lia"
    "(* second-kernel (Rocq/lia) check of a linear runtime-safety obligation *)"
  arrow := "->"
  binder := fun vars =>
    if vars.isEmpty then "" else s!"forall ({" ".intercalate vars} : Z), "
  -- The AGREEMENT script, and it is a different shape from `render`: N pinned instances of
  -- ONE obligation, each its own lemma with its own `Print Assumptions`. Dropping this field
  -- does not fail the build and does not stop `coqc` closing the proof — it makes the
  -- agreement check have nothing to check, so every Rocq cell reads
  -- "LOWERING DISAGREES" and the badge silently vanishes. Which is exactly what happened
  -- when this refactor first landed: 78/78 became three failures with `rocq:lia = closed`
  -- sitting next to a refused attestation.
  batchRender := fun props =>
    "\n".intercalate
      ([ "(* lowering-agreement check: pinned instances of ONE obligation *)",
         "From Stdlib Require Import ZArith.", "From Stdlib Require Import Lia.",
         "Open Scope Z_scope." ]
       ++ props.zipIdx.map (fun (p, i) =>
            s!"Lemma agree{i} : {p}.\nProof. lia. Qed.\nPrint Assumptions agree{i}."))

/-- Isabelle/HOL driver: `lemma "ALL vars::int. h1 --> ... --> concl" by presburger`.
    `presburger` decides linear integer arithmetic in a HOL kernel — independent of
    CIC, so agreement with Lean/Rocq is FOUNDATIONAL cross-logic independence.

    `tactics` carries `presburger` as data for the same reason the Rocq drivers do; the
    Isabelle scripts are not yet derived from a shared builder because the batch form
    (one theory, N indexed lemmas) differs structurally from the single form, and collapsing
    them without changing emitted output needs the batch/single split handled first. Recorded
    rather than half-done. -/
def isabelleLowering : ProverLowering where
  name := "isabelle"
  binop := isabelleBinOp
  tactics := ["presburger"]
  render := fun vars hyps concl =>
    let binder := if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "
    let arrows := String.join (hyps.map (fun h => s!"({h}) --> "))
    "\n".intercalate
      [ "theory VC imports Main begin",
        s!"lemma \"{binder}{arrows}{concl}\"", "  by presburger", "end" ]
  arrow := "-->"
  binder := fun vars =>
    if vars.isEmpty then "" else s!"ALL {" ".intercalate vars}::int. "
  batchRender := fun props =>
    -- each lemma needs a distinct name, hence the index
    "\n".intercalate
      ([ "theory VC imports Main begin" ]
       ++ (props.zipIdx.map (fun (p, i) => s!"lemma agree{i}: \"{p}\"\n  by presburger"))
       ++ [ "end" ])

/-- Rocq driver using `nia` (nonlinear integer arithmetic) instead of `lia`. Used to
    CERTIFICATE-CHECK the solver: a nonlinear VC an external SMT solver reports `unsat`
    (`solver_trusted`, solver in the TCB) that Rocq's `nia` ALSO closes graduates to
    `solver_checked` — an independent kernel corroborated the solver, so the solver drops out
    of the trusted base. `nia` ships with `Require Import Lia` (micromega).

    **This is now a two-field override of `rocqLowering`, not a cloned record.** That is the
    whole point of `tactics` being data: before R-0455's slice, reaching `nia` cost a
    duplicated driver that had to be kept in step with its twin. -/
def rocqNiaLowering : ProverLowering :=
  { rocqLowering with
    name := "rocq-nia"
    tactics := ["nia"]
    render := rocqScript "nia"
      "(* certificate-check (Rocq/nia) of a solver-trusted nonlinear obligation *)" }

/-- SMT-eligible overflow obligations (the genuinely NONLINEAR ones the kernel tiers
    left open — same selection as `overflowSmtGoals`), as structured obligations so
    they can be lowered to Rocq `nia` for certificate-checking. -/
def smtEligibleOverflow (modules : List Module) : List OverflowObl :=
  (overflowObligations modules).filter fun o =>
    o.closedVerdict.isNone && o.bvGoal.isNone && exprHasNonlinMul o.opExpr

/-- `(vcKey, coqSource)` lowering each SMT-eligible nonlinear overflow obligation to a
    Rocq `nia` goal — the certificate-check of the solver's `unsat` verdict. -/
def rocqNiaGoals (modules : List Module) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  for o in smtEligibleOverflow modules do
    let concl : Option String := do
      let e ← exprToProver rocqBinOp o.opExpr
      let lo ← rocqBinOp .leq (toString o.lo) e
      let hi ← rocqBinOp .leq e (toString o.hi)
      rocqBinOp .and_ lo hi
    match concl, o.hyps.mapM (exprToProver rocqBinOp) with
    | some c, some hyps =>
      let vars := (collectIdents o.opExpr ++ o.hyps.flatMap collectIdents).eraseDups
      out := out ++ [(o.key, rocqNiaLowering.render vars hyps c)]
    | _, _ => pure ()
  return out


end Report
end Concrete
