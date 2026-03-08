import Concrete.AST
import Concrete.Core

namespace Concrete

/-! ## Elaboration: surface AST → Core IR

Type-annotates and desugars the surface AST into Core IR.
No linearity checking, no borrow checking, no capability validation.
-/

-- ============================================================
-- Elaboration function signature (reused from Check.lean's FnSig)
-- ============================================================

structure ElabFnSig where
  params : List (String × Ty)
  retTy : Ty
  typeParams : List String := []
  typeBounds : List (String × List String) := []
  capParams : List String := []
  capSet : CapSet := .empty

-- ============================================================
-- Elaboration environment
-- ============================================================

structure ElabEnv where
  vars : List (String × Ty)
  structs : List StructDef
  enums : List EnumDef
  fnSigs : List (String × ElabFnSig)
  typeAliases : List (String × Ty)
  constants : List (String × Ty)
  currentTypeParams : List String := []
  currentTypeBounds : List (String × List String) := []
  currentRetTy : Ty := .unit
  currentImplType : Option Ty := none
  traits : List TraitDef := []

abbrev ElabM := ExceptT String (StateM ElabEnv)

private def getEnv : ElabM ElabEnv := do
  return (← get)

private def setEnv (env : ElabEnv) : ElabM Unit :=
  set env

private def throwElab (msg : String) : ElabM α :=
  throw msg

-- ============================================================
-- Stub functions (Phase 1 — all return "not yet implemented")
-- ============================================================

partial def elabExpr (e : Expr) (hint : Option Ty := none) : ElabM CExpr := do
  throwElab "elabExpr not yet implemented"

partial def elabStmt (_stmt : Stmt) : ElabM (List CStmt) := do
  throwElab "elabStmt not yet implemented"

partial def elabStmts (stmts : List Stmt) : ElabM (List CStmt) := do
  let mut result : List CStmt := []
  for s in stmts do
    let cs ← elabStmt s
    result := result ++ cs
  return result

def elabFn (_f : FnDef) (_implTy : Option Ty := none) : ElabM CFnDef := do
  throwElab "elabFn not yet implemented"

def elabModule (_m : Module)
    (_importedFnSigs : List (String × ElabFnSig) := [])
    (_importedStructs : List StructDef := [])
    (_importedEnums : List EnumDef := [])
    (_importedImplBlocks : List ImplBlock := [])
    (_importedTraitImpls : List ImplTraitBlock := [])
    : Except String CModule :=
  .error "elabModule not yet implemented"

def elabProgram (_modules : List Module) : Except String (List CModule) :=
  .error "elabProgram not yet implemented"

end Concrete
