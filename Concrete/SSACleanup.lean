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

/-- Remove phi entries that reference labels in the given dead set. -/
private def stripDeadPhiEntries (blocks : List SBlock) (deadLabels : List String) : List SBlock :=
  if deadLabels.isEmpty then blocks
  else blocks.map fun b =>
    { b with insts := b.insts.map fun inst =>
      match inst with
      | .phi dst incoming ty =>
        .phi dst (incoming.filter fun (_, lbl) => !deadLabels.contains lbl) ty
      | other => other }

/-- Remove blocks with no predecessors (except the entry block).
    Also strips phi entries referencing removed blocks. -/
private def eliminateDeadBlocks (blocks : List SBlock) : List SBlock :=
  match blocks with
  | [] => []
  | entry :: rest =>
    let reachable := findReachable [entry.label] [] (entry :: rest)
    let deadLabels := (entry :: rest).filter (fun b => !reachable.contains b.label) |>.map (·.label)
    let live := (entry :: rest).filter fun b => reachable.contains b.label
    stripDeadPhiEntries live deadLabels

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

/-- Check if a label is referenced in any phi incoming of a block. -/
private def isPhiSource (b : SBlock) (label : String) : Bool :=
  b.insts.any fun inst =>
    match inst with
    | .phi _ incoming _ => incoming.any fun (_, lbl) => lbl == label
    | _ => false

/-- Find blocks that only contain a br (no instructions, just jump).
    Returns list of (emptyLabel, targetLabel).
    Skips the entry block and blocks whose target has phis referencing them
    (folding those requires complex phi predecessor updates). -/
private def findEmptyBlocks (blocks : List SBlock) : List (String × String) :=
  let nonEntry := blocks.drop 1
  nonEntry.filterMap fun b =>
    match b.insts, b.term with
    | [], .br target =>
      -- Skip folding if the target block has phis that reference this block
      let targetBlock := blocks.find? fun tb => tb.label == target
      match targetBlock with
      | some tb => if isPhiSource tb b.label then none else some (b.label, target)
      | none => some (b.label, target)
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
-- Pass 4: Dead instruction elimination
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

/-- Collect all register uses in an SVal. -/
private def svalUses : SVal → List String
  | .reg name _ => [name]
  | _ => []

/-- Collect all register uses in an instruction. -/
private def instUses : SInst → List String
  | .binOp _ _ lhs rhs _ => svalUses lhs ++ svalUses rhs
  | .unaryOp _ _ operand _ => svalUses operand
  | .call _ _ args _ => args.foldl (fun acc a => acc ++ svalUses a) []
  | .alloca _ _ => []
  | .load _ ptr _ => svalUses ptr
  | .store val ptr => svalUses val ++ svalUses ptr
  | .gep _ base indices _ => svalUses base ++ indices.foldl (fun acc i => acc ++ svalUses i) []
  | .phi _ incoming _ => incoming.foldl (fun acc (v, _) => acc ++ svalUses v) []
  | .cast _ val _ => svalUses val
  | .memcpy dst src _ => svalUses dst ++ svalUses src

/-- Collect register uses in a terminator. -/
private def termUses : STerm → List String
  | .ret (some v) => svalUses v
  | .ret none => []
  | .br _ => []
  | .condBr cond _ _ => svalUses cond
  | .unreachable => []

/-- Collect all used registers across all blocks. -/
private def collectAllUses (blocks : List SBlock) : List String :=
  blocks.foldl (fun acc b =>
    let instU := b.insts.foldl (fun acc i => acc ++ instUses i) []
    let termU := termUses b.term
    acc ++ instU ++ termU) []

/-- Is an instruction side-effecting (must be kept even if result unused)? -/
private def isSideEffecting : SInst → Bool
  | .call _ _ _ _ => true
  | .store _ _ => true
  | .memcpy _ _ _ => true
  | _ => false

/-- Eliminate instructions whose dst is never used. Iterate until fixpoint. -/
private partial def eliminateDeadInstsFixpoint (blocks : List SBlock) : List SBlock :=
  let allUses := collectAllUses blocks
  let changed := blocks.any fun b =>
    b.insts.any fun inst =>
      match instDst inst with
      | some dst => !allUses.contains dst && !isSideEffecting inst
      | none => false
  if !changed then blocks
  else
    let blocks := blocks.map fun b =>
      { b with insts := b.insts.filter fun inst =>
        match instDst inst with
        | some dst => allUses.contains dst || isSideEffecting inst
        | none => true }
    eliminateDeadInstsFixpoint blocks

-- ============================================================
-- Pass 5: Constant folding
-- ============================================================

/-- Try to fold a binary operation on two integer constants. -/
private def foldBinOp (op : BinOp) (lhs rhs : SVal) (ty : Ty) : Option SVal :=
  match lhs, rhs with
  | .intConst a _, .intConst b _ =>
    match op with
    | .add => some (.intConst (a + b) ty)
    | .sub => some (.intConst (a - b) ty)
    | .mul => some (.intConst (a * b) ty)
    | .div => if b != 0 then some (.intConst (a / b) ty) else none
    | .mod => if b != 0 then some (.intConst (a % b) ty) else none
    | .eq => some (.boolConst (a == b))
    | .neq => some (.boolConst (a != b))
    | .lt => some (.boolConst (a < b))
    | .gt => some (.boolConst (a > b))
    | .leq => some (.boolConst (a <= b))
    | .geq => some (.boolConst (a >= b))
    | _ => none
  | .boolConst a, .boolConst b =>
    match op with
    | .and_ => some (.boolConst (a && b))
    | .or_ => some (.boolConst (a || b))
    | .eq => some (.boolConst (a == b))
    | .neq => some (.boolConst (a != b))
    | _ => none
  | _, _ => none

/-- Fold constant expressions in all blocks. Returns (blocks, replacements). -/
private def foldConstants (blocks : List SBlock) : List SBlock :=
  -- Find all foldable binops
  let replacements := blocks.foldl (fun acc b =>
    b.insts.foldl (fun acc inst =>
      match inst with
      | .binOp dst op lhs rhs ty =>
        match foldBinOp op lhs rhs ty with
        | some val => (dst, val) :: acc
        | none => acc
      | _ => acc
    ) acc) []
  if replacements.isEmpty then blocks
  else applyReplacements blocks replacements

-- ============================================================
-- Pass 6: Constant branch elimination
-- ============================================================

/-- Replace `condBr (boolConst true) t e` → `br t` and
    `condBr (boolConst false) t e` → `br e`. -/
private def eliminateConstantBranches (blocks : List SBlock) : List SBlock :=
  blocks.map fun b =>
    match b.term with
    | .condBr (.boolConst true) thenLabel _ =>
      { b with term := .br thenLabel }
    | .condBr (.boolConst false) _ elseLabel =>
      { b with term := .br elseLabel }
    | _ => b

-- ============================================================
-- Pass 7: Stale PHI entry cleanup
-- ============================================================

/-- For each block, remove PHI incoming entries whose source label is not
    an actual predecessor (i.e., no block with that label has a terminator
    targeting this block). This is needed after constant branch elimination
    removes edges without updating PHIs in the target blocks. -/
private def stripStalePhiEntries (blocks : List SBlock) : List SBlock :=
  blocks.map fun b =>
    let predLabels := blocks.filter (fun pred =>
      (termSuccessors pred.term).contains b.label) |>.map (·.label)
    { b with insts := b.insts.map fun inst =>
      match inst with
      | .phi dst incoming ty =>
        .phi dst (incoming.filter fun (_, lbl) => predLabels.contains lbl) ty
      | other => other }

-- ============================================================
-- Combined cleanup
-- ============================================================

private def cleanupFn (f : SFnDef) : SFnDef :=
  let blocks := eliminateDeadBlocks f.blocks
  let blocks := eliminateTrivialPhis blocks
  let blocks := foldConstants blocks
  let blocks := eliminateConstantBranches blocks
  let blocks := stripStalePhiEntries blocks
  let blocks := eliminateTrivialPhis blocks
  let blocks := eliminateDeadInstsFixpoint blocks
  let blocks := foldEmptyBlocks blocks
  let blocks := eliminateDeadBlocks blocks  -- re-run after branch elimination
  { f with blocks := blocks }

def ssaCleanupModule (m : SModule) : SModule :=
  { m with functions := m.functions.map cleanupFn }

def ssaCleanupProgram (modules : List SModule) : List SModule :=
  modules.map ssaCleanupModule

end Concrete
