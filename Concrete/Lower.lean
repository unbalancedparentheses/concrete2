import Concrete.Core
import Concrete.SSA

namespace Concrete

/-! ## Lowering: Core IR → SSA IR

Converts structured Core IR into SSA form with basic blocks,
conditional branches, and phi nodes.
-/

-- ============================================================
-- Lowering state
-- ============================================================

structure LowerState where
  blocks : List SBlock
  currentLabel : String
  currentInsts : List SInst
  labelCounter : Nat
  regCounter : Nat
  vars : List (String × String)
  stringLits : List (String × String)

abbrev LowerM := ExceptT String (StateM LowerState)

-- ============================================================
-- Stub (Phase 1)
-- ============================================================

def lowerModule (m : CModule) : SModule :=
  { name := m.name
    structs := m.structs
    enums := m.enums
    functions := []
    externFns := m.externFns
    globals := [] }

end Concrete
