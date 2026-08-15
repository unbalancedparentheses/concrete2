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

/-- Why a package identity could not be formed. -/
inductive PackageIdentityRefusal where
  /-- A component is empty. `""` must never represent "not supplied": two unrelated packages would
      both bind as `""` and compare EQUAL, which is the collision the whole type exists to prevent. -/
  | emptyComponent (which : String)
  /-- A checkout path or other mutable location was offered as identity. Rejected on principle
      rather than sanitized: an identity that varies by where the code sits cannot be reproducible,
      and legitimate package reuse in two locations must yield the SAME identity. -/
  | locationDependent (found : String)
deriving Repr, BEq

def PackageIdentityRefusal.explain : PackageIdentityRefusal → String
  | .emptyComponent w   => s!"package identity component '{w}' is empty"
  | .locationDependent f => s!"'{f}' looks location-dependent — an identity must not vary by checkout"

/-- Stable semantic package identity.

    THE MANIFEST NAME ALONE IS NOT SUFFICIENT, which is the correction that produced this type: two
    unrelated packages can choose the same name, so `declaredName` is a claim rather than an
    identity. It is bound together with an origin/namespace and a canonical content root, and the
    result is deterministic and checkout-independent.

    Private constructor. An identity missing a component has no representation, and in particular
    there is no empty-string sentinel for "not supplied" — a caller without an identity must take a
    typed refusal, not a value that compares equal to every other absent one. -/
structure PackageIdentity where
  private mk ::
  /-- The name the package declares for itself. A claim, not an identity. -/
  declaredName : String
  /-- Stable namespace or origin identity — what distinguishes two packages that chose one name. -/
  originIdentity : String
  /-- Canonical module/content root, so a package whose contents change is not silently the same
      package for evidence purposes. -/
  contentRoot : String
deriving Repr, BEq

/-- Reject identities that vary by where the code happens to sit. Heuristic and deliberately
    conservative: it refuses rather than sanitizes, because a sanitized path is still a path. -/
private def looksLocationDependent (v : String) : Bool :=
  v.startsWith "/" || v.startsWith "./" || v.startsWith "../" || v.contains '\\'
    || (v.splitOn "://").length > 1

/-- Build a package identity, or refuse. -/
def PackageIdentity.of? (declaredName originIdentity contentRoot : String)
    : Except PackageIdentityRefusal PackageIdentity :=
  if declaredName.isEmpty then .error (.emptyComponent "declaredName")
  else if originIdentity.isEmpty then .error (.emptyComponent "originIdentity")
  else if contentRoot.isEmpty then .error (.emptyComponent "contentRoot")
  else if looksLocationDependent declaredName then .error (.locationDependent declaredName)
  else if looksLocationDependent originIdentity then .error (.locationDependent originIdentity)
  else .ok (PackageIdentity.mk declaredName originIdentity contentRoot)

/-- The identity for a STANDALONE single-file compilation, derived from canonical content.

    Explicit rather than implicit, and derived from the module/content material rather than from a
    path or a generic `main`. Two different single files must not share an identity — which a
    constant `"main"` would guarantee they do — and the same file compiled in two locations must
    share one, which a path would guarantee it does not. `contentDigest` is the canonical content
    material; the caller computes it once and it is bound here. -/
def PackageIdentity.synthetic (contentDigest : String)
    : Except PackageIdentityRefusal PackageIdentity :=
  if contentDigest.isEmpty then .error (.emptyComponent "contentDigest")
  else PackageIdentity.of? "«standalone»" ("synthetic:" ++ contentDigest) contentDigest

/-- The synthetic identity for a standalone compilation, from its MODULE INVENTORY.

    ONE producer for the four standalone `extractProofCore` paths. Each deriving its own content
    digest would be four answers to "which package is this", and they would drift — the defect class
    this codebase gates for. Callers supply the module names; the canonical ordering and the digest
    formula live here.

    Refuses an empty inventory: a compilation with no modules has no content to identify, and a
    constant fallback would make every such compilation the same package. -/
def PackageIdentity.syntheticForModules (moduleNames : List String)
    (moduleSources : List String := [])
    : Except PackageIdentityRefusal PackageIdentity :=
  if moduleNames.isEmpty then .error (.emptyComponent "moduleInventory")
  else
    -- CONTENT, not just names, for the same reason `packageIdentityOf` binds it: measured on the
    -- corpus, `composition` and `composition_trusted_helper` are different programs whose module
    -- INVENTORY is identical (`calls`), so a name-only synthetic identity assigned them one package.
    -- Sources are digested and sorted by CONTENT, never by path, so ordering cannot reintroduce
    -- checkout dependence.
    let mods := (moduleNames.mergeSort (· ≤ ·)).foldl (fun a m => a ++ s!"|M{m.length}:{m}") ""
    let srcs := (moduleSources.map Concrete.shortHash).mergeSort (· ≤ ·)
    let srcPart := srcs.foldl (fun a d => a ++ "|S" ++ d) ""
    PackageIdentity.synthetic (Concrete.shortHash ("pkgSyntheticV1:" ++ mods ++ srcPart))

/-- Canonical rendering, length-prefixed per component. -/
def PackageIdentity.canonical (p : PackageIdentity) : String :=
  s!"pkgIdV1:N{p.declaredName.length}:{p.declaredName}"
    ++ s!"|O{p.originIdentity.length}:{p.originIdentity}"
    ++ s!"|R{p.contentRoot.length}:{p.contentRoot}"

/-- Domain-separated digest — the value `DefinitionIdentity.packageIdentity` carries. -/
def PackageIdentity.digest (p : PackageIdentity) : String :=
  Concrete.shortHash p.canonical

/-- Read a scalar field from the `[package]` section, or `none`.

    Section-aware: a `name` under `[dependencies]` is not the package's name, and a parser that
    grepped the whole file would silently take whichever came first. -/
def packageField (content : String) (field : String) : Option String :=
  let lines := content.splitOn "\n" |>.map (·.trimAscii.toString)
  let rec go : List String → Bool → Option String
    | [], _ => none
    | l :: rest, inPkg =>
      if l.startsWith "[package]" then go rest true
      else if l.startsWith "[" then go rest false
      else if inPkg && l.startsWith field then
        match (l.splitOn "=").getLast? with
        | some v =>
          let t := v.trimAscii.toString
          -- strip surrounding quotes without a regex; an unquoted value is taken as-is
          let t := if t.startsWith "\"" then (t.drop 1).toString else t
          let t := if t.endsWith "\"" then (t.dropEnd 1).toString else t
          if t.isEmpty then none else some t
        | none => none
      else go rest inPkg
  go lines false

/-- The package identity for this project, or a typed refusal.

    DERIVED FROM DECLARED MATERIAL AND CONTENT, never from a path. `projectRoot` is deliberately not
    an input: the same package built in two checkouts must yield ONE identity, and
    `PackageIdentity.of?` refuses location-dependent components outright.

    LIMITATION, stated because it is the residual collision rather than a closed one: the manifest
    has no origin or namespace field — only `name` and `version` exist across the corpus — so
    `originIdentity` is derived from the declared coordinate plus the dependency inventory, and
    `contentRoot` from the module inventory. Two UNRELATED packages sharing name, version,
    dependency names and module names would still collide. Fully closing that needs a declared
    origin in `Concrete.toml`, which is a manifest surface change and therefore a decision rather
    than an implementation detail. -/
def packageIdentityOf (tomlContent : String) (moduleNames : List String)
    (depNames : List String) (moduleSources : List String := [])
    : Except PackageIdentityRefusal PackageIdentity :=
  match packageField tomlContent "name" with
  | none =>
    -- A project with no declared name gets no identity, and therefore no scoped evidence. Refusing
    -- is the point: a default would make every unnamed project the same package.
    .error (.emptyComponent "declaredName")
  | some declared =>
    let version := (packageField tomlContent "version").getD "«unversioned»"
    let deps := (depNames.mergeSort (· ≤ ·)).foldl (fun a d => a ++ s!"|D{d.length}:{d}") ""
    let mods := (moduleNames.mergeSort (· ≤ ·)).foldl (fun a m => a ++ s!"|M{m.length}:{m}") ""
    let origin := Concrete.shortHash s!"pkgOriginV1:N{declared.length}:{declared}|V{version.length}:{version}{deps}"
    -- CONTENT, not just names. `contentRoot` used module NAMES alone, and the corpus showed what
    -- that costs: `composition` and `composition_trusted_helper` are DIFFERENT PROGRAMS declaring
    -- the same package name and the same module inventory, so they collapsed to ONE package
    -- identity. Their implementations differ, so `DefinitionIdentity` still separated them — but a
    -- package identity that cannot tell two programs apart is not a package identity.
    --
    -- Sources are digested by CONTENT and sorted by content, never by path: sorting by path would
    -- reintroduce checkout dependence through the ordering, which is the same defect the
    -- location-dependence refusal exists to prevent.
    let srcs := (moduleSources.map Concrete.shortHash).mergeSort (· ≤ ·)
    let srcPart := srcs.foldl (fun a d => a ++ "|S" ++ d) ""
    let root := Concrete.shortHash s!"pkgRootV1:{mods}{srcPart}"
    PackageIdentity.of? declared origin root

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
