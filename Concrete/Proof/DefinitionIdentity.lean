import Concrete.Resolve.CallableId
import Concrete.Proof.Digest

/-!
# Scoped definition identity — the identity evidence boundaries must use

`CallableId` carries `defModule` and `declName`. That is a SOURCE NAME, and measurement showed it
is not a sufficient proof identity: `elf_header` and `proof_pressure` both define
`main.validate_header`, both render as `v1:user:main.validate_header`, and they are different
functions. Proof tables live on the Lean side and are shared across programs, so a table describing
one program's implementation could match another program's edge purely because the names agree.

The observed case refuses for an unrelated reason — the callee is absent from the table — so no
false justification exists in the corpus today. The collision is structurally possible, which is
enough: an exact join over an identity that is too weak formalizes the collision the moment it
becomes authoritative.

**Four components, and each is load-bearing:**

- `packageIdentity` — stable SEMANTIC package identity from the manifest. Deliberately not a
  checkout path or a mutable workspace id: those would break reproducibility and legitimate package
  reuse, so the same package built in two locations must yield the same identity.
- `moduleIdentity` — the resolved module.
- `declarationIdentity` — the declaration within that module.
- `implementationIdentity` — binds typed signature, capabilities, generics, contracts and canonical
  body (this is `implementationDigest`). Package identity alone is insufficient because
  implementations change within a package; a body digest alone is insufficient because contracts,
  signature and capabilities matter.

`CallableId` REMAINS the compiler-local name. Rewriting every use would be churn without benefit —
inside one compilation a source name is unambiguous. What must use the stronger identity is the
evidence boundary: correspondence, proof-table entries, receipts, and package artifacts.
-/

namespace Concrete.Proof

/-- Why a definition identity could not be formed. -/
inductive DefinitionIdentityRefusal where
  /-- A component is empty. `""` is a value, not an absence: two unknown packages would both bind
      as `""` and compare EQUAL, which is the collision this type exists to prevent. -/
  | emptyComponent (which : String)
  /-- The implementation digest is not canonical 32-hex, so it cannot have come from
      `implementationDigest`. -/
  | implementationNotCanonical (found : String)
  /-- Evidence carrying only a source name, with no package or implementation scope. Legacy
      material: it cannot be upgraded by inspection, because the missing scope is exactly what
      would distinguish two same-named definitions. It must be re-derived, which is why the
      disposition is `needs_recheck` rather than a refusal to be argued with. -/
  | legacyNameOnly (rendered : String)
deriving Repr, BEq

def DefinitionIdentityRefusal.explain : DefinitionIdentityRefusal → String
  | .emptyComponent w            => s!"definition identity component '{w}' is empty"
  | .implementationNotCanonical f => s!"implementation identity '{f}' is not canonical 32-hex"
  | .legacyNameOnly r             => s!"'{r}' carries a source name only — no package or implementation scope"

/-- The identity used at evidence boundaries. Private constructor: an identity missing a component
    has no representation, rather than being checked wherever someone remembers to. -/
structure DefinitionIdentity where
  private mk ::
  packageIdentity        : String
  moduleIdentity         : String
  declarationIdentity    : String
  implementationIdentity : String
deriving Repr, BEq

/-- Build a scoped identity, or refuse. -/
def DefinitionIdentity.of? (packageIdentity moduleIdentity declarationIdentity
    implementationIdentity : String) : Except DefinitionIdentityRefusal DefinitionIdentity :=
  let isHex := fun (d : String) => d.length == 32 && d.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')
  if packageIdentity.isEmpty then .error (.emptyComponent "packageIdentity")
  else if moduleIdentity.isEmpty then .error (.emptyComponent "moduleIdentity")
  else if declarationIdentity.isEmpty then .error (.emptyComponent "declarationIdentity")
  else if !isHex implementationIdentity then
    .error (.implementationNotCanonical implementationIdentity)
  else .ok (DefinitionIdentity.mk packageIdentity moduleIdentity declarationIdentity
              implementationIdentity)

/-- Canonical rendering, length-prefixed per component so no two component splits collide. -/
def DefinitionIdentity.canonical (d : DefinitionIdentity) : String :=
  s!"defIdV1:P{d.packageIdentity.length}:{d.packageIdentity}"
    ++ s!"|M{d.moduleIdentity.length}:{d.moduleIdentity}"
    ++ s!"|D{d.declarationIdentity.length}:{d.declarationIdentity}"
    ++ s!"|I{d.implementationIdentity.length}:{d.implementationIdentity}"

/-- Domain-separated digest of the whole identity. -/
def DefinitionIdentity.digest (d : DefinitionIdentity) : String :=
  Concrete.shortHash d.canonical

/-- Do two identities denote the same definition?

    ALL FOUR components, and this is the point of the type. Matching on module and declaration only
    is what let a proof table about one program's `main.validate_header` line up with another
    program's edge of the same name. A helper that compared three would be a weaker join wearing
    this type's name, so there is exactly one comparison and it is total. -/
def DefinitionIdentity.sameDefinition (a b : DefinitionIdentity) : Bool :=
  a.packageIdentity == b.packageIdentity
    && a.moduleIdentity == b.moduleIdentity
    && a.declarationIdentity == b.declarationIdentity
    && a.implementationIdentity == b.implementationIdentity

/-- The compiler-local name, for diagnostics. NOT an identity — it is the value whose insufficiency
    this module exists to correct, and it is rendered here only so a refusal can name what failed. -/
def DefinitionIdentity.localName (d : DefinitionIdentity) : String :=
  s!"{d.moduleIdentity}.{d.declarationIdentity}"

end Concrete.Proof
