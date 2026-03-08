import Concrete.SSA

namespace Concrete

/-! ## SSAVerify — SSA invariant validation

Runs after Lower, before SSACleanup. Validates:
- Every block has exactly one terminator
- Every register used is defined before use (simplified dominance)
- Branch targets reference existing block labels
- Phi nodes have entries for all predecessor blocks
- No duplicate register definitions in same block
-/

-- ============================================================
-- Verification state
-- ============================================================

structure VerifyCtx where
  fnName : String
  /-- All block labels in the current function. -/
  blockLabels : List String
  /-- Map from block label to its predecessor labels. -/
  predecessors : List (String × List String)
  /-- All defined registers across all blocks (for use-before-def). -/
  allDefs : List String
  /-- Function parameter names. -/
  paramNames : List String
  /-- Dominator map: label → list of labels that dominate it. -/
  dominators : List (String × List String)
  /-- All blocks in the current function. -/
  blocks : List SBlock
  errors : List String

private def addError (ctx : VerifyCtx) (msg : String) : VerifyCtx :=
  { ctx with errors := ctx.errors ++ [s!"{ctx.fnName}: {msg}"] }

-- ============================================================
-- Collect defined registers
-- ============================================================

/-- Get the destination register of an instruction, if any. -/
private def instDst : SInst → Option String
  | .binOp dst _ _ _ _ => some dst
  | .unaryOp dst _ _ _ => some dst
  | .call dst _ _ _ => dst
  | .alloca dst _ => some dst
  | .load dst _ _ => some dst
  | .store _ _ => none
  | .gep dst _ _ _ => some dst
  | .phi dst _ _ => some dst
  | .cast dst _ _ => some dst
  | .memcpy _ _ _ => none

/-- Collect all registers defined in a block's instructions (including phis). -/
private def blockDefs (b : SBlock) : List String :=
  b.insts.filterMap instDst

/-- Collect all registers used in an SVal. -/
private def svalRegs : SVal → List String
  | .reg name _ => [name]
  | _ => []

/-- Collect all register uses in an instruction. -/
private def instUses : SInst → List String
  | .binOp _ _ lhs rhs _ => svalRegs lhs ++ svalRegs rhs
  | .unaryOp _ _ operand _ => svalRegs operand
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ svalRegs a) []
  | .alloca _ _ => []
  | .load _ ptr _ => svalRegs ptr
  | .store val ptr => svalRegs val ++ svalRegs ptr
  | .gep _ base indices _ => svalRegs base ++ indices.foldl (fun acc i => acc ++ svalRegs i) []
  | .phi _ incoming _ => incoming.foldl (fun acc (v, _) => acc ++ svalRegs v) []
  | .cast _ val _ => svalRegs val
  | .memcpy dst src _ => svalRegs dst ++ svalRegs src

/-- Collect register uses in a terminator. -/
private def termUses : STerm → List String
  | .ret (some v) => svalRegs v
  | .ret none => []
  | .br _ => []
  | .condBr cond _ _ => svalRegs cond
  | .unreachable => []

-- ============================================================
-- Build predecessor map
-- ============================================================

/-- Get successor labels from a terminator. -/
private def termSuccessors : STerm → List String
  | .br lbl => [lbl]
  | .condBr _ tl el => [tl, el]
  | .ret _ => []
  | .unreachable => []

/-- Build predecessor map: label → list of predecessor labels. -/
private def buildPredecessors (blocks : List SBlock) : List (String × List String) :=
  let allLabels := blocks.map (·.label)
  allLabels.map fun lbl =>
    let preds := blocks.filter (fun b => (termSuccessors b.term).contains lbl)
    (lbl, preds.map (·.label))

-- ============================================================
-- Dominator computation
-- ============================================================

/-- Compute dominators using iterative dataflow.
    Returns map: label → set of labels that dominate it.
    A block B dominates C if every path from entry to C goes through B. -/
private partial def computeDominators (blocks : List SBlock) (predecessors : List (String × List String)) : List (String × List String) :=
  match blocks with
  | [] => []
  | entry :: _ =>
    let allLabels := blocks.map (·.label)
    -- Initialize: entry dominates only itself, others dominated by all blocks
    let init := allLabels.map fun lbl =>
      if lbl == entry.label then (lbl, [lbl])
      else (lbl, allLabels)
    -- Iteratively refine until fixpoint
    let rec iterate (doms : List (String × List String)) (fuel : Nat) : List (String × List String) :=
      match fuel with
      | 0 => doms
      | fuel + 1 =>
        let newDoms := allLabels.map fun lbl =>
          if lbl == entry.label then (lbl, [lbl])
          else
            let preds := (predecessors.find? fun (l, _) => l == lbl).map (·.2) |>.getD []
            let predDomSets := preds.filterMap fun p =>
              (doms.find? fun (l, _) => l == p).map (·.2)
            -- Intersection of all predecessor dom sets
            let intersection := match predDomSets with
              | [] => []
              | first :: rest => rest.foldl (fun acc s => acc.filter (s.contains ·)) first
            (lbl, lbl :: intersection)
        if newDoms == doms then doms
        else iterate newDoms fuel
    iterate init (allLabels.length * 2 + 10)

/-- Look up which blocks a given block dominates. -/
private def dominatedBy (doms : List (String × List String)) (block : String) : List String :=
  (doms.find? fun (l, _) => l == block).map (·.2) |>.getD []

/-- Get which block defines a register. -/
private def regDefBlock (blocks : List SBlock) (reg : String) : Option String :=
  blocks.find? (fun b => (blockDefs b).contains reg) |>.map (·.label)

-- ============================================================
-- Per-block validation
-- ============================================================

/-- Check for duplicate register definitions in a block. -/
private def checkDuplicateDefs (ctx : VerifyCtx) (b : SBlock) : VerifyCtx :=
  let defs := blockDefs b
  defs.foldl (fun (ctx, seen) d =>
    if seen.contains d then
      (addError ctx s!"block '{b.label}': duplicate definition of %{d}", seen)
    else
      (ctx, d :: seen)
  ) (ctx, ([] : List String)) |>.1

/-- Check that all used registers are defined in a dominating block (or as params).
    Phi nodes are special: their operands come from predecessor blocks, not the current block. -/
private def checkUsesAreDefined (ctx : VerifyCtx) (b : SBlock) : VerifyCtx :=
  let doms := dominatedBy ctx.dominators b.label
  -- Check non-phi instruction uses
  let nonPhiInsts := b.insts.filter fun inst => match inst with | .phi _ _ _ => false | _ => true
  let uses := nonPhiInsts.foldl (fun acc i => acc ++ instUses i) [] ++ termUses b.term
  let ctx := uses.foldl (fun ctx u =>
    if ctx.paramNames.contains u then ctx
    else
      -- Register must be defined in a block that dominates this one
      match regDefBlock ctx.blocks u with
      | some defBlock =>
        if doms.contains defBlock then ctx
        else addError ctx s!"block '{b.label}': use of %{u} defined in non-dominating block '{defBlock}'"
      | none => addError ctx s!"block '{b.label}': use of undefined register %{u}"
  ) ctx
  -- Check phi node uses: each operand must be defined in or dominating its source block
  b.insts.foldl (fun ctx inst =>
    match inst with
    | .phi _ incoming _ =>
      incoming.foldl (fun ctx (v, srcLabel) =>
        match v with
        | .reg name _ =>
          if ctx.paramNames.contains name then ctx
          else
            let srcDoms := dominatedBy ctx.dominators srcLabel
            match regDefBlock ctx.blocks name with
            | some defBlock =>
              if srcDoms.contains defBlock then ctx
              else addError ctx s!"block '{b.label}': phi operand %{name} from '{srcLabel}' not dominated by def block '{defBlock}'"
            | none => addError ctx s!"block '{b.label}': phi uses undefined register %{name}"
        | _ => ctx
      ) ctx
    | _ => ctx
  ) ctx

/-- Check that branch targets reference existing block labels. -/
private def checkBranchTargets (ctx : VerifyCtx) (b : SBlock) : VerifyCtx :=
  let successors := termSuccessors b.term
  successors.foldl (fun ctx lbl =>
    if ctx.blockLabels.contains lbl then ctx
    else addError ctx s!"block '{b.label}': branch to unknown label '{lbl}'"
  ) ctx

/-- Check phi node predecessors. Each phi should have entries for all predecessor blocks. -/
private def checkPhiNodes (ctx : VerifyCtx) (b : SBlock) : VerifyCtx :=
  let preds := (ctx.predecessors.find? fun (l, _) => l == b.label).map (·.2) |>.getD []
  b.insts.foldl (fun ctx inst =>
    match inst with
    | .phi _ incoming _ =>
      let phiLabels := incoming.map (·.2)
      -- Check that each predecessor has an entry
      preds.foldl (fun ctx p =>
        if phiLabels.contains p then ctx
        else addError ctx s!"block '{b.label}': phi missing entry for predecessor '{p}'"
      ) ctx
    | _ => ctx
  ) ctx

-- ============================================================
-- Function and module validation
-- ============================================================

private def verifyFn (f : SFnDef) : List String :=
  if f.blocks.isEmpty then
    [s!"{f.name}: function has no blocks"]
  else
    let blockLabels := f.blocks.map (·.label)
    let predecessors := buildPredecessors f.blocks
    let allDefs := f.blocks.foldl (fun acc b => acc ++ blockDefs b) []
    let paramNames := f.params.map (·.1)
    let dominators := computeDominators f.blocks predecessors
    let ctx : VerifyCtx := {
      fnName := f.name
      blockLabels := blockLabels
      predecessors := predecessors
      allDefs := allDefs
      paramNames := paramNames
      dominators := dominators
      blocks := f.blocks
      errors := []
    }
    let ctx := f.blocks.foldl (fun ctx b =>
      let ctx := checkDuplicateDefs ctx b
      let ctx := checkUsesAreDefined ctx b
      let ctx := checkBranchTargets ctx b
      let ctx := checkPhiNodes ctx b
      ctx
    ) ctx
    ctx.errors

private def verifyModule (m : SModule) : List String :=
  m.functions.foldl (fun acc f => acc ++ verifyFn f) []

def ssaVerifyProgram (modules : List SModule) : Except String Unit :=
  let errors := modules.foldl (fun acc m => acc ++ verifyModule m) []
  if errors.isEmpty then .ok ()
  else .error ("SSA verification errors:\n" ++ "\n".intercalate errors)

end Concrete
