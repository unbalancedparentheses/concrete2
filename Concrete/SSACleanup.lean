import Concrete.SSA

namespace Concrete

/-! ## SSACleanup — SSA optimization passes

Runs after SSAVerify. Simple cleanup passes:
- Dead block elimination (blocks with no predecessors except entry)
- Trivial phi elimination (phi with one incoming value → replace with that value)
- Empty block folding (block that just branches → redirect predecessors)
-/

-- ============================================================
-- Helpers
-- ============================================================

/-- Get successor labels from a terminator. -/
private def termSuccessors : STerm → List String
  | .br lbl => [lbl]
  | .condBr _ tl el => [tl, el]
  | .ret _ => []
  | .unreachable => []

/-- Replace a label in a terminator. -/
private def replaceLabelInTerm (t : STerm) (oldLabel newLabel : String) : STerm :=
  match t with
  | .br lbl => .br (if lbl == oldLabel then newLabel else lbl)
  | .condBr cond tl el =>
    .condBr cond
      (if tl == oldLabel then newLabel else tl)
      (if el == oldLabel then newLabel else el)
  | other => other

/-- Replace a label in phi node incoming entries. -/
private def replaceLabelInInst (inst : SInst) (oldLabel newLabel : String) : SInst :=
  match inst with
  | .phi dst incoming ty =>
    .phi dst (incoming.map fun (v, lbl) =>
      (v, if lbl == oldLabel then newLabel else lbl)) ty
  | other => other

/-- Replace an SVal in an instruction (for trivial phi elimination). -/
private def replaceRegInSVal (v : SVal) (oldReg : String) (replacement : SVal) : SVal :=
  match v with
  | .reg name _ => if name == oldReg then replacement else v
  | other => other

private def replaceRegInInst (inst : SInst) (oldReg : String) (replacement : SVal) : SInst :=
  let r := fun v => replaceRegInSVal v oldReg replacement
  match inst with
  | .binOp dst op lhs rhs ty => .binOp dst op (r lhs) (r rhs) ty
  | .unaryOp dst op operand ty => .unaryOp dst op (r operand) ty
  | .call dst fn args retTy => .call dst fn (args.map r) retTy
  | .alloca dst ty => .alloca dst ty
  | .load dst ptr ty => .load dst (r ptr) ty
  | .store val ptr => .store (r val) (r ptr)
  | .gep dst base indices ty => .gep dst (r base) (indices.map r) ty
  | .phi dst incoming ty => .phi dst (incoming.map fun (v, lbl) => (r v, lbl)) ty
  | .cast dst val tgt => .cast dst (r val) tgt
  | .memcpy dst src size => .memcpy (r dst) (r src) size

private def replaceRegInTerm (t : STerm) (oldReg : String) (replacement : SVal) : STerm :=
  let r := fun v => replaceRegInSVal v oldReg replacement
  match t with
  | .ret (some v) => .ret (some (r v))
  | .condBr cond tl el => .condBr (r cond) tl el
  | other => other

-- ============================================================
-- Pass 1: Dead block elimination
-- ============================================================

/-- Find reachable blocks via BFS from an entry label. -/
private partial def findReachable (worklist : List String) (visited : List String) (blocks : List SBlock) : List String :=
  match worklist with
  | [] => visited
  | lbl :: wl =>
    if visited.contains lbl then findReachable wl visited blocks
    else
      let visited := lbl :: visited
      let succs := match blocks.find? fun b => b.label == lbl with
        | some b => termSuccessors b.term
        | none => []
      findReachable (wl ++ succs) visited blocks

/-- Remove blocks with no predecessors (except the entry block). -/
private def eliminateDeadBlocks (blocks : List SBlock) : List SBlock :=
  match blocks with
  | [] => []
  | entry :: rest =>
    let reachable := findReachable [entry.label] [] (entry :: rest)
    (entry :: rest).filter fun b => reachable.contains b.label

-- ============================================================
-- Pass 2: Trivial phi elimination
-- ============================================================

/-- Find trivial phis: phi with all incoming values being the same (ignoring self-references).
    Returns list of (dst_reg, replacement_val). -/
private def findTrivialPhis (blocks : List SBlock) : List (String × SVal) :=
  blocks.foldl (fun acc b =>
    b.insts.foldl (fun acc inst =>
      match inst with
      | .phi dst incoming _ =>
        -- Filter out self-references
        let nonSelf := incoming.filter fun (v, _) =>
          match v with
          | .reg name _ => name != dst
          | _ => true
        -- Check if all remaining values are the same
        match nonSelf with
        | [] => acc
        | (v, _) :: rest =>
          let allSame := rest.all fun (v', _) =>
            match v, v' with
            | .reg n1 _, .reg n2 _ => n1 == n2
            | .intConst v1 _, .intConst v2 _ => v1 == v2
            | .boolConst b1, .boolConst b2 => b1 == b2
            | _, _ => false
          if allSame then (dst, v) :: acc else acc
      | _ => acc
    ) acc
  ) []

/-- Apply register replacements across all blocks. -/
private def applyReplacements (blocks : List SBlock)
    (replacements : List (String × SVal)) : List SBlock :=
  if replacements.isEmpty then blocks
  else
    blocks.map fun b =>
      let insts := b.insts.filter fun inst =>
        match inst with
        | .phi dst _ _ => !(replacements.any fun (d, _) => d == dst)
        | _ => true
      let insts := replacements.foldl (fun insts (oldReg, newVal) =>
        insts.map fun inst => replaceRegInInst inst oldReg newVal
      ) insts
      let term := replacements.foldl (fun t (oldReg, newVal) =>
        replaceRegInTerm t oldReg newVal
      ) b.term
      { b with insts := insts, term := term }

/-- Repeatedly eliminate trivial phis until fixpoint. -/
private partial def eliminateTrivialPhis (blocks : List SBlock) : List SBlock :=
  let trivials := findTrivialPhis blocks
  if trivials.isEmpty then blocks
  else eliminateTrivialPhis (applyReplacements blocks trivials)

-- ============================================================
-- Pass 3: Empty block folding
-- ============================================================

/-- Find blocks that only contain a br (no instructions, just jump).
    Returns list of (emptyLabel, targetLabel).
    Skips the entry block (first block) — folding it corrupts phi node semantics. -/
private def findEmptyBlocks (blocks : List SBlock) : List (String × String) :=
  let nonEntry := blocks.drop 1
  nonEntry.filterMap fun b =>
    match b.insts, b.term with
    | [], .br target => some (b.label, target)
    | _, _ => none

/-- Redirect branches from empty blocks to their targets. -/
private def foldEmptyBlocks (blocks : List SBlock) : List SBlock :=
  let empties := findEmptyBlocks blocks
  if empties.isEmpty then blocks
  else
    -- For each empty block, redirect predecessors
    let blocks := empties.foldl (fun blocks (emptyLabel, targetLabel) =>
      blocks.map fun b =>
        let term := replaceLabelInTerm b.term emptyLabel targetLabel
        let insts := b.insts.map fun inst => replaceLabelInInst inst emptyLabel targetLabel
        { b with term := term, insts := insts }
    ) blocks
    -- Remove the now-unreferenced empty blocks
    eliminateDeadBlocks blocks

-- ============================================================
-- Combined cleanup
-- ============================================================

private def cleanupFn (f : SFnDef) : SFnDef :=
  let blocks := eliminateDeadBlocks f.blocks
  let blocks := eliminateTrivialPhis blocks
  let blocks := foldEmptyBlocks blocks
  { f with blocks := blocks }

def ssaCleanupModule (m : SModule) : SModule :=
  { m with functions := m.functions.map cleanupFn }

def ssaCleanupProgram (modules : List SModule) : List SModule :=
  modules.map ssaCleanupModule

end Concrete
