import Concrete.Report.ProofStatus

/-! Lean theorem stubs (--report lean-stubs) and the `concrete prove` scaffold. Split out of Report.lean by report kind; `Concrete.Report.Report`
    imports every report module. -/

namespace Concrete
namespace Report

-- ============================================================
-- Lean theorem stubs (--report lean-stubs)
-- ============================================================

/-- Render a PExpr as Lean constructor syntax (Concrete.Proof.PExpr). -/
partial def renderPExprAsLean : Proof.PExpr → String
  | .lit (.int n) =>
    if n < 0 then s!".lit (.int ({n}))"
    else s!".lit (.int {n})"
  | .lit (.bool b) => s!".lit (.bool {b})"
  | .lit (.struct_ name _) =>
    -- Struct literals as raw Lean constructor syntax are noisy; the
    -- canonical surface for proof attachment is the source-level
    -- fingerprint, not the Lean stub. Emit a placeholder.
    s!"/- struct value of {name} (raw form) -/"
  | .lit (.enum_ enumName variant _) =>
    s!"/- enum value {enumName}::{variant} (raw form) -/"
  | .lit (.array_ _) =>
    s!"/- array value (raw form) -/"
  | .var name => s!".var \"{name}\""
  | .binOp op lhs rhs =>
    let opStr := match op with
      | .add => ".add" | .sub => ".sub" | .mul => ".mul"
      | .addw w s => s!"(.addw {w} {s})"
      | .mod w s => s!"(.mod {w} {s})"
      | .div w s => s!"(.div {w} {s})"
      | .bitxor w s => s!"(.bitxor {w} {s})"
      | .bitor w s => s!"(.bitor {w} {s})"
      | .bitand w s => s!"(.bitand {w} {s})"
      | .shr w s => s!"(.shr {w} {s})"
      | .shl w s => s!"(.shl {w} {s})"
      | .addsat w s => s!"(.addsat {w} {s})"
      | .subsat w s => s!"(.subsat {w} {s})"
      | .eq => ".eq" | .ne => ".ne" | .lt => ".lt"
      | .le => ".le" | .gt => ".gt" | .ge => ".ge"
    s!".binOp {opStr}\n      ({renderPExprAsLean lhs})\n      ({renderPExprAsLean rhs})"
  | .letIn name val body =>
    s!".letIn \"{name}\"\n      ({renderPExprAsLean val})\n      ({renderPExprAsLean body})"
  | .ifThenElse cond t e =>
    s!".ifThenElse\n      ({renderPExprAsLean cond})\n      ({renderPExprAsLean t})\n      ({renderPExprAsLean e})"
  | .call fn args =>
    let argsLean := args.map fun a => s!"({renderPExprAsLean a})"
    s!".call \"{fn}\" [{", ".intercalate argsLean}]"
  | .applyVar binding args =>
    let argsLean := args.map fun a => s!"({renderPExprAsLean a})"
    s!".applyVar \"{binding}\" [{", ".intercalate argsLean}]"
  | .structLit name fields =>
    let fieldsLean := fields.map fun (fname, fexpr) =>
      s!"(\"{fname}\", {renderPExprAsLean fexpr})"
    s!".structLit \"{name}\" [{", ".intercalate fieldsLean}]"
  | .enumLit enumName variant fields =>
    let fieldsLean := fields.map fun (fname, fexpr) =>
      s!"(\"{fname}\", {renderPExprAsLean fexpr})"
    s!".enumLit \"{enumName}\" \"{variant}\" [{", ".intercalate fieldsLean}]"
  | .fieldAccess obj field =>
    s!".fieldAccess ({renderPExprAsLean obj}) \"{field}\""
  | .arrayIndex arr idx =>
    s!".arrayIndex ({renderPExprAsLean arr}) ({renderPExprAsLean idx})"
  | .match_ scrutinee arms =>
    let armsLean := arms.map fun (pat, body) =>
      let patLean := match pat with
        | .enumPat eName variant bindings =>
          let bs := bindings.map fun b => s!"\"{b}\""
          s!".enumPat \"{eName}\" \"{variant}\" [{", ".intercalate bs}]"
        | .litPat (.int n) =>
          if n < 0 then s!".litPat (.int ({n}))" else s!".litPat (.int {n})"
        | .litPat (.bool b) => s!".litPat (.bool {b})"
        | .litPat _ => "/- non-int/bool litPat (raw form) -/"
        | .varPat name => s!".varPat \"{name}\""
      s!"({patLean}, {renderPExprAsLean body})"
    s!".match_\n      ({renderPExprAsLean scrutinee})\n      [{", ".intercalate armsLean}]"
  | .cast inner => s!".cast ({renderPExprAsLean inner})"
  | .wrapCast w sg inner => s!".wrapCast {w} {sg} ({renderPExprAsLean inner})"
  | .arrayLit elems =>
    let elemsLean := elems.map fun e => s!"({renderPExprAsLean e})"
    s!".arrayLit [{", ".intercalate elemsLean}]"
  | .arraySet arr idx val =>
    s!".arraySet\n      ({renderPExprAsLean arr})\n      ({renderPExprAsLean idx})\n      ({renderPExprAsLean val})"
  | .while_ cond assigns cont =>
    let assignsLean := assigns.map fun (n, e) =>
      s!"(\"{n}\", {renderPExprAsLean e})"
    s!".while_\n      ({renderPExprAsLean cond})\n      [{", ".intercalate assignsLean}]\n      ({renderPExprAsLean cont})"
  | .while_step cond carried step cont =>
    let carriedLean := carried.map fun n => s!"\"{n}\""
    s!".while_step\n      ({renderPExprAsLean cond})\n      [{", ".intercalate carriedLean}]\n      ({renderPExprAsLean step})\n      ({renderPExprAsLean cont})"

/-- Convert a function's bare name to a Lean-safe identifier. -/
def leanIdent (name : String) : String :=
  name.map fun c => if c == '-' then '_' else c

/-- A COLLISION-PROOF Lean identifier for a generated symbol.

    Derived from the FULL qualified name, not the last segment. A program with
    `Alpha.compute`, `Beta.compute` and `Gamma.compute` previously generated three
    `computeExpr` / `computeId` / `computeFn` declarations — invalid Lean, and
    three entries all keyed `"compute"`, which is also an ambiguous operational
    key. Measured before fixing.

    Every character outside `[A-Za-z0-9_]` becomes `_`, so a module separator and
    any punctuation collapse; the qualified name is unique per callable, so the
    result is too. -/
def leanSymbol (qualName : String) : String :=
  -- INJECTIVE. A plain "map every non-alphanumeric to `_`" is NOT: `A.b_c` and
  -- `A_b.c` both become `A_b_c`, so two callables would share a declaration name
  -- and generate invalid Lean — the very defect the qualification was added to
  -- fix. Escaping `_` as `__` first means a literal underscore always appears
  -- doubled, so a single underscore can only be a separator.
  String.join (qualName.toList.map fun c =>
    if c == '_' then "__"
    else if ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') then
      String.singleton c
    else "_")

/-- Emit a `CallableId` literal that preserves the COMPLETE carried value.

    An earlier version hardcoded `ns := .user` and omitted `schemaVersion` and
    `typeArgs`, so a builtin, intrinsic, extern or specialization would have been
    emitted as a plain user callable with no type arguments — silently a different
    identity from the one the compiler minted. `none` renders nothing and lets the
    caller fail closed. -/
def renderCallableId (cid : Concrete.CallableId) : String :=
  let nsLit := match cid.ns with
    | .user => ".user" | .builtin => ".builtin"
    | .intrinsic => ".intrinsic" | .extern => ".extern"
    | .spec => ".spec"
  let argsLit :=
    if cid.typeArgs.isEmpty then ""
    else ", typeArgs := [" ++ ", ".intercalate (cid.typeArgs.map reprStr) ++ "]"
  -- The type-parameter ARITY is part of the identity: emitted whenever non-zero,
  -- so a generic extracted with its instantiation erased is not indistinguishable
  -- from a non-generic callable. Dropping it here would hand the kernel a
  -- complete-looking identity for an incomplete one.
  let paramsLit :=
    if cid.typeParams == 0 then "" else s!", typeParams := {cid.typeParams}"
  s!"\{ schemaVersion := {cid.schemaVersion}, ns := {nsLit}, defModule := \"{cid.defModule}\", declName := \"{cid.declName}\"{argsLit}{paramsLit} }"

/-- Render a `sourceBodyDigestV1` literal for one extracted body.

    Computed over `pexprCanonical` of the EXTRACTED body, hashed with the same
    truncated SHA-256 (`Concrete.shortHash`) the in-source
    `#[proof_fingerprint]` uses — a spec already in the repo, so no new trusted
    code. `pexprCanonical` is length-prefixed and tagged, so the digest inherits
    its injectivity: two structurally different bodies cannot hash alike by
    rendering alike.

    DELIBERATELY NOT the legacy `bodyFingerprint`. That hashes Core statements
    and is the proof-freshness fingerprint that bugs 058-060 are filed against;
    reusing its VALUE here would put one string in two roles, and the next reader
    would be free to treat a body-only digest as the authoritative subject digest.
    Different input domain means the two can never be silently substituted.

    WHAT THIS CATCHES: a generated table whose body literal no longer matches
    what the compiler extracts — a hand-edited generated file, or a stale one
    after a source change. The digest is bound into the table root, so drift
    moves the root.

    WHAT IT DOES NOT CATCH, stated rather than implied: a consistent generator
    bug. A generator emitting a wrong body AND a digest computed from that same
    wrong body agrees with itself. This is `receiptEligible := false` and
    `scope := "body_only"` for exactly that reason — it is a comparison key for
    step 5, not evidence, and it covers no signature, capability or contract. -/
def renderSourceBodyDigest (pexpr : Proof.PExpr) : String :=
  -- NORMALIZE FIRST, so the digest is invariant under commutative reordering.
  -- Two bodies differing only in the order of `+`'s operands denote the SAME
  -- subject, and a digest that separates them would report drift where there is
  -- none. Extraction already normalizes, so this changes no generated value — it
  -- makes the property hold BY CONSTRUCTION rather than by coincidence, which
  -- matters because the other side of the comparison is a hand-written spec
  -- written in source order.
  --
  -- Measured while migrating: `crypto_verify.compute_tag` is `key * message +
  -- nonce` in source and normalizes to `nonce + key * message`. Its committed
  -- spec looked like a mismatch against the generated digest and was not one.
  -- DELEGATES to the one producer. This computed the formula itself, so the manifest's
  -- authoritative body component and this rendering were independent copies of one intent — and
  -- the comparison between them only means anything if they cannot drift.
  let v := Concrete.sourceBodyDigestV1Of pexpr
  s!"some \{ value := \"{v}\" }"

/-- The structural-body shadow line. Three outcomes, kept distinct because collapsing
    them would hide which one occurred: no body was threaded at all, a body was threaded
    but has gaps, or a complete body digested.

    The gap reasons are RENDERED, not counted. "3 gaps" says a subject was refused;
    naming the codes says which constructs the producer still cannot describe, which is
    the list that drives the remaining work. -/
private def shadowBodyV2Line : Option Proof.EvidenceBodyDraftV2 → String
  | none => "ABSENT (no structural body threaded)"
  | some d =>
    match Proof.validate d with
    | .ok complete => shortHash (Proof.bodyBytesV2 complete)
    | .error gaps =>
      -- DETAILS, not codes. The nine codes are stable and few, so a tally of them says
      -- only "statements and expressions" — true and useless. The detail names the
      -- construct, and that list IS the remaining producer work.
      -- Joined with " | ", not ", ": at least one detail contains a comma, so a
      -- comma-joined list cannot be split back into the constructs it names.
      let details := (gaps.map (·.detail)).eraseDups
      s!"REFUSED ({gaps.length} gap(s): {" | ".intercalate details})"

/-- Per-edge correspondence for one subject — SHADOW, decides nothing.

    Reported separately from `depRoot` on purpose: root coverage says the dependency closure could
    be computed, correspondence says every edge in it has exactly one validated justification. A
    subject can root while corresponding badly, and conflating the two is how a weaker fact gets
    reported as a stronger one. -/
private def shadowCorrespondenceLine (pc : Concrete.ProofCore) (id : CallableId) : String :=
  match Concrete.correspondenceInputOf pc pc.callGraph id with
  -- A SUBJECT WITHOUT A SCOPED IDENTITY CANNOT BE CORRESPONDED, and that is reported as its own
  -- state rather than as a correspondence failure: nothing about its edges or witnesses was ever
  -- examined, so `usable=no` with empty sets would describe an operation that did not happen.
  | .error w => s!"REFUSED (subject has no scoped identity: {w.explain})"
  | .ok inp =>
  let r := Proof.correspond inp
  let qual := (pc.entries.find? (fun e => e.callableId == id)).map (·.qualName) |>.getD ""
  if inp.requestedEdges.isEmpty && inp.unscopedEdges.isEmpty && inp.keyRefusals.isEmpty then "none (no outgoing edge)"
  -- NO CLAIM is not an unjustified claim. A subject with no linked theorem asserts nothing about
  -- its dependencies, so there is nothing for correspondence to justify, and reporting `usable=no`
  -- would count "nobody proved this" as "this proof is unsound". `fixed_capacity.validate_message`
  -- is exactly that: eligible, 11 outgoing edges, no `#[proof_by]` anywhere.
  --
  -- This must NOT become a way to hide failures. A subject WITH a linked theorem whose
  -- classification is unusable still corresponds badly and still reports `usable=no` — only the
  -- total absence of a theorem is "no claim", and that absence is owned by proof linkage, not by
  -- this layer.
  else if (Concrete.theoremNameOf pc qual).isEmpty then
    s!"no claim (no linked proof; {inp.requestedEdges.length} edge(s) unjustified by construction)"
  else
    let refusals := r.resolverRefusals.map (·.explain)
    let refusalNote := if refusals.isEmpty then "" else s!" | table refusals: {" ; ".intercalate refusals}"
    -- UNSCOPED EDGES ARE REPORTED SEPARATELY. They are inside `malformed` for the verdict, and
    -- named here because "this edge could not be keyed" sends a reader somewhere entirely different
    -- from "this edge has no witness".
    let unscopedNote := if inp.unscopedEdges.isEmpty then ""
                        else s!" unscoped={inp.unscopedEdges.length}"
    let sets := s!"matched={r.matched.length} missing={r.missing.length} " ++
                s!"ambiguous={r.ambiguous.length} surplus={r.surplus.length} malformed={r.malformed.length}{unscopedNote}"
    let keyNote := if inp.keyRefusals.isEmpty then ""
                   else s!" | callee keys: {" ; ".intercalate (inp.keyRefusals.map (·.explain))}"
    s!"{sets} usable={if r.usable inp.requestedEdges.length then "yes" else "no"}{refusalNote}{keyNote}"

/-- The CALL-GRAPH view of a subject's outgoing edges — the source `dependencyRootMaterial`
    actually reads, printed so it can be compared against `shadow edgeKinds`, which reads the
    evidence body instead.

    Diagnostic only. It decides nothing; it exists so a disagreement between the two sources is
    observable rather than inferred from the fact that a root succeeded when it should not have. -/
private def shadowGraphEdgesLine (pc : Concrete.ProofCore) (qn : String) : String :=
  match pc.callGraph.find? (fun g => g.1 == qn) with
  | none => "none (no call-graph entry)"
  | some (_, callees) =>
    if callees.isEmpty then "none (call-graph entry with no callees)"
    else s!"{callees.length}: " ++ ", ".intercalate callees.eraseDups.mergeSort

/-- The dependency-ROOT shadow line: what a validated root would say, computed but not acted on.

    R-0004 slice 6 step 4. Both consumers read `ProofCore.dependencyNodesOf`, so there is one set
    of nodes rather than a Report-local rebuild — two builders is how a second, weaker answer
    appears.

    **REFUSED is the expected answer today, and it is evidence rather than a defect.** The
    compiler cannot mint `contract` or `body` (that needs `classifyTheorem` in `MetaM`), so every
    unclassifiable edge is `unclassified`, and `dependencyRootMaterial` refuses any edge that is
    not current for dependents. Coverage recovers when the hand-back classifies more
    dependencies — never by weakening what a root requires.

    The refusal REASON is rendered, not counted. "12 refused" says a wall exists; naming the
    cause says which wall, and that list is the remaining work. -/
private def shadowDepRootLine (pc : Concrete.ProofCore) (id : CallableId) : String :=
  let nodes := Concrete.dependencyNodesOf pc pc.callGraph
  -- THE ROOT IS KEYED BY THE SCOPED IDENTITY. A subject without one has no node and therefore no
  -- root — reported as its own refusal rather than as a computation that failed, because nothing
  -- about its closure was ever examined.
  match (pc.entries.find? (fun e => e.callableId == id)).map (·.definitionIdentity) with
  | none => "REFUSED (no entry for this subject)"
  | some (Except.error w) => s!"REFUSED (subject has no scoped identity: {w.explain})"
  | some (Except.ok sid) =>
  match Proof.dependencyRootMaterial nodes sid with
  | .error e => s!"REFUSED ({e.explain})"
  | .ok m =>
    let trust := if m.requiresTrustQualification then " [carries trust]" else ""
    s!"{shortHash m.preimage}{trust}"

/-- The subject-FRESHNESS shadow line: what the v2 comparison WOULD say, computed but not
    acted on.

    The live verdict still compares the body-only fingerprint. Switching it makes all 53
    stored `#[proof_fingerprint]` values non-comparable at once — they are v1 — turning 19
    currently-`proved` links into `needs_recheck` in a single commit. That verdict is
    correct, but issuing it IS the migration, and migration is step 7, gated on the FINAL
    digest. So this observes what would happen while the authoritative path stays put,
    which is the same shadow discipline the other four axes are under.

    Four outcomes, kept distinct for the reason the other lines are:

      NO-SUBJECT       the entry has no v2 digest — facts absent or incomplete. Cannot be
                       compared, and must not read as agreement.
      UNPINNED         no stored fingerprint. Nothing to compare against; not a mismatch.
      WOULD-RECHECK    a fingerprint is stored WITHOUT the `v2:` prefix, so it is a v1
                       value by construction. It answers a weaker question and cannot
                       establish v2 freshness — this is the `needs_recheck` case.
      WOULD-MATCH /    a v2 value is stored and does or does not equal the current digest.
      WOULD-DIFFER     Only these two are an actual comparison.

    The `v2:` prefix is the discriminator, and it is what makes the v1 case DECIDABLE
    rather than guessed: both digests are 16 hex characters, so nothing about the value's
    shape distinguishes them. -/
private def storedFpFor (pc : Concrete.ProofCore) (qualName : String) : String :=
  -- The stored `#[proof_fingerprint]` lives on the obligation's spec attachment, not on the
  -- entry: `ProofCoreEntry` describes the SUBJECT, and what a proof was pinned against is a
  -- property of the claim. Missing attachment and missing hash are both "" here, and
  -- `shadowSubjectFreshnessLine` renders that as UNPINNED rather than as a mismatch.
  match pc.obligations.find? (fun o => o.functionId.qualName == qualName) with
  | some o => match o.spec with
    | some a => a.expectedHash.getD ""
    | none => ""
  | none => ""

private def shadowSubjectFreshnessLine
    (subjectDigest : Option String) (storedFp : String) : String :=
  match subjectDigest with
  | none => "NO-SUBJECT (facts absent or incomplete — not comparable)"
  | some d =>
    let cur := "v2:" ++ shortHash d
    if storedFp.isEmpty then s!"UNPINNED (current would be {cur})"
    else if !("v2:".isPrefixOf storedFp) then
      s!"WOULD-RECHECK (stored is v1, not comparable; current would be {cur})"
    else if storedFp == cur then s!"WOULD-MATCH ({cur})"
    else s!"WOULD-DIFFER (stored {storedFp}, current {cur})"

/-- The dependency shadow line: which constants a body REACHES, and whether each is bound
    to a meaning.

    A `constRef` names a constant and says nothing about its value, so a proof over a body
    reading `LIMIT` stays valid-looking when `LIMIT` changes from 10 to 99. This line
    digests the initializer encodings of exactly the constants the body references, in
    identity order, so the digest moves when any of their values does.

    ORDERED BY IDENTITY, not by encounter: the same body reaching the same constants must
    produce the same material regardless of the order it happens to mention them, or a
    statement reordering that changes nothing would move the dependency digest.

    REFUSED when a referenced constant has no binding. An imported constant has neither a
    defining module nor an initializer available here, and digesting the ones that happen
    to be bound would report a complete dependency root over an incomplete one.

    SHADOW, like `bodyV2`: `subjectDigest` already drives freshness verdicts, so making a
    constant's value move it before the step-5 migration would strand every stored proof
    link. -/
private def shadowDepsLine (body? : Option Proof.EvidenceBodyDraftV2)
    (bindings : List (ConstId × String)) : String :=
  match body? with
  | none => "ABSENT (no structural body threaded)"
  | some body =>
    let referenced := (body.statements.flatMap Proof.stmtConstRefs).eraseDups
    if referenced.isEmpty then "none (body references no constants)"
    else
      let sorted := referenced.map (·.render) |>.mergeSort (· ≤ ·)
      let resolved := sorted.map fun r =>
        match bindings.find? (fun b => b.1.render == r) with
        | some (_, enc) => some (r, enc)
        | none => none
      match resolved.find? (·.isNone) with
      | some _ =>
        let unbound := (sorted.zip resolved).filterMap fun (r, o) => if o.isNone then some r else none
        s!"REFUSED ({unbound.length} unbound: {", ".intercalate unbound})"
      | none =>
        let payload := String.join (resolved.filterMap id |>.map fun (r, enc) =>
          "c:" ++ toString r.length ++ ":" ++ r ++ "=" ++ toString enc.length ++ ":" ++ enc)
        s!"{shortHash ("depsV1:n" ++ toString sorted.length ++ ":" ++ payload)} ({sorted.length} const)"

/-- The assumption shadow line: what a claim over this body would be RELYING ON.

    An assumption does not make a body incomplete — it QUALIFIES any claim about it. A body
    full of `assume` can be perfectly complete and perfectly serialized; what must not
    happen is a proof over it surfacing as unqualified. That is why this is a third line
    rather than folded into completeness: they are different questions with different
    remedies.

    The predicates are digested in SOURCE ORDER, with multiplicity kept. Two `assume`s are
    not one, and reordering them changes the body — so this is not a set.

    `unqualified` is stated positively rather than left as an empty digest, because "no
    assumptions" is the fact a consumer actually needs, and an empty-string digest would be
    indistinguishable from a failure to compute one. -/
private def shadowAssumesLine (body? : Option Proof.EvidenceBodyDraftV2) : String :=
  match body? with
  | none => "ABSENT (no structural body threaded)"
  | some body =>
    let q := Proof.SubjectQualificationV2.of body
    if q.isUnqualified then "unqualified (nothing assumed)"
    else
      let payload := String.join (q.assumptions.map Proof.exprBytes)
      s!"{shortHash ("assumesV1:n" ++ toString q.assumptionCount ++ ":" ++ payload)} " ++
        s!"({q.assumptionCount} assumed — a claim over this body CANNOT be reported unqualified)"

/-- The dependency EDGE SET: which callables this body reaches directly.

    The material `DependencyRoot` consumes and has never been given — `DepNode`, its typed
    edges and its fail-closed root have had zero producers.

    Derived from the EVIDENCE BODY, not from `buildCallGraph`. That graph keys on qualified
    NAME STRINGS, which `DepNode`'s own comment calls the defect class R-0004 exists to
    close appearing inside the dependency material itself. Every `call` and `fnRef` node
    already carries a resolver-minted `CallableId`, so taking edges from there is
    identity-native and keeps one producer.

    The EDGE KIND (contract / body / trusted / missing) is deliberately absent for now: it
    depends on each callee's proof status, and inventing one here would put an unearned
    classification into material a root will later be built from. Listing the reached
    identities is the honest half. -/
private def shadowEdgesLine (body? : Option Proof.EvidenceBodyDraftV2) : String :=
  match body? with
  | none => "ABSENT (no structural body threaded)"
  | some body =>
    let cs := Proof.bodyCallees body
    if cs.isEmpty then "none (body reaches no callable)"
    else s!"{shortHash ("edgesV1:n" ++ toString cs.length ++ ":" ++ String.join (cs.map (·.render)))}" ++
         s!" ({cs.length}: {", ".intercalate (cs.map (·.render))})"

/-- INHERITED assumptions: what a claim rests on once the callees are taken into account.

    An assumption in a callee qualifies the CALLER's claim just as much as one written
    locally — if `f` calls `g` and `g` assumes `n > 0`, a proof about `f` rests on that
    assumption whether or not `f` mentions it. Reporting only local assumptions would let a
    caller look unqualified while depending on something assumed one hop away, which is the
    same shape as the trust that `DependencyRoot` already propagates.

    Walks the CallableId edge set, not the name-keyed call graph, so the closure is
    identity-native.

    FUEL-BOUNDED, and the bound is the entry count: each step either marks a new node or
    drops one, so a recursive or mutually-recursive chain terminates instead of diverging.
    Exhausting the fuel is reported as INCOMPLETE rather than treated as "nothing more
    found" — a closure that stopped early has not proven the absence of assumptions.

    AN UNKNOWN CALLEE MAKES THE ANSWER INCOMPLETE. A callee with no entry — an extern, a
    builtin, a function outside this ProofCore — has an unknowable assumption set, and
    treating it as assumption-free is the unsafe direction: it reports "nothing assumed"
    about a body that might rest on anything. Named, not silently skipped. -/
private def inheritedAssumptions (entries : List Concrete.ProofCoreEntry)
    (start : Concrete.ProofCoreEntry) : String :=
  match start.evidenceBody with
  | none => "ABSENT (no structural body threaded)"
  | some _ =>
    let findEntry := fun (id : CallableId) =>
      entries.find? fun x => x.callableId.render == id.render
    let rec go (fuel : Nat) (frontier : List CallableId) (seen : List String)
               (acc : Nat) (unknown : List String) : (Nat × List String × Bool) :=
      match fuel, frontier with
      | 0, _ => (acc, unknown, false)          -- fuel exhausted: INCOMPLETE, not "done"
      | _, [] => (acc, unknown, true)
      | fuel + 1, id :: rest =>
        let r := id.render
        if seen.contains r then go fuel rest seen acc unknown
        else
          match findEntry id with
          | none => go fuel rest (r :: seen) acc (r :: unknown)
          | some e =>
            match e.evidenceBody with
            | none => go fuel rest (r :: seen) acc (r :: unknown)
            | some b =>
              let q := Proof.SubjectQualificationV2.of b
              go fuel (rest ++ Proof.bodyCallees b) (r :: seen)
                 (acc + q.assumptionCount) unknown
    -- Start from the CALLEES: the subject's own assumptions are reported on its own line,
    -- and counting them here too would double them.
    let startCallees := (start.evidenceBody.map Proof.bodyCallees).getD []
    let fuel := entries.length * entries.length + entries.length + 1
    let (inherited, unknown, complete) := go fuel startCallees [] 0 []
    let u := unknown.eraseDups
    if !complete then
      s!"INCOMPLETE (closure exhausted its bound before settling)"
    else if !u.isEmpty then
      s!"INCOMPLETE ({inherited} from known callees; {u.length} callee(s) unknowable: {", ".intercalate (u.take 3)})"
    else if inherited == 0 then "none inherited (every reachable callee assumes nothing)"
    else s!"{inherited} inherited from callees — a claim here rests on them too"

/-- Edge KINDS for the callees a body reaches, as far as this layer can answer.

    `DependencyEdge` is four-way and only three are answerable in the compiler:

      * `trusted`  — the callee is a declared trust boundary. Known from `CFnDef.isTrusted`.
      * `missing`  — the callee has no ProofCore entry: extern, builtin, or outside this
                     compilation. Nothing validated, and nothing CAN be validated from
                     here, which is what `missing` means.
      * `contract` / `body` — NOT derivable here. `DependencyEdges.classifyTheorem` reads a
                     linked theorem's ELABORATED TYPE and runs in `MetaM`, which exists only
                     while Lean is elaborating. A known, untrusted callee is `unclassified`.

    Saying `unclassified` instead of guessing `body` is the fail-closed choice. `body` is
    the conservative EDGE — any change to the callee stales the caller — but asserting it
    would claim a proof EXISTS and depends on the implementation, when the truth is that
    this layer cannot see whether any proof exists. A wrong kind in dependency material is
    worse than an absent one: a root gets built on it. -/
private def shadowEdgeKinds (pc : Concrete.ProofCore) (e : Concrete.ProofCoreEntry) : String :=
  -- ONE SOURCE FOR EDGE KINDS, and this used to be two. The previous version derived callees from
  -- `e.evidenceBody` and then assigned the kind by
  --     `if e.fn.isTrusted then "trusted" else "unclassified"`
  -- which consults no classification table at all: every non-trusted edge was reported
  -- `unclassified` no matter what the hand-back said. Meanwhile `dependencyRootMaterial` reads
  -- `dependencyNodesOf`, which classifies via `classifiedEdgeOf`.
  --
  -- So the two lines disagreed for 9 of 64 subjects, and the disagreement was DIAGNOSED WRONG on
  -- first look: it appeared that roots were being computed over a smaller edge set — a coverage
  -- fail-open — because a subject reporting `unclassified` edges still rooted. It was the opposite.
  -- The root was right and the report was stale: those edges are genuinely classified, and
  -- `dependencyRootMaterial` refuses any non-current edge, so a subject with edges that roots has
  -- current edges by construction.
  --
  -- Reading the node set fixes the class of bug rather than the instance: a hand-coded second
  -- opinion about a kind cannot drift from the real one if there is no second opinion.
  let nodes := Concrete.dependencyNodesOf pc pc.callGraph
  match nodes.find? (fun n => n.label == e.callableId) with
  | none => "ABSENT (no dependency node)"
  | some n =>
    if n.edges.isEmpty && n.unscoped.isEmpty then "none (no outgoing edge)"
    else
      let sorted := n.edges.eraseDups.mergeSort
        (fun a b => (a.2.canonical ++ a.1.canonical) ≤ (b.2.canonical ++ b.1.canonical))
      -- Rendered by LOCAL NAME, which is what a reader recognises; the identity is what the node
      -- compares. An unkeyable edge is listed too, marked, because a diagnostic that omits it
      -- reports a shorter edge set than the compiler actually has.
      let parts := sorted.map (fun (k, tgt) => s!"{tgt.localName}={k.canonical}")
        ++ n.unscoped.map (fun (c, k) => s!"{c.render}={k.canonical}«unscoped»")
      let nonCurrent := (sorted.filter (fun (k, _) => !k.isCurrentForDependents)).length
      let trustedN := (sorted.filter (fun (k, _) => k == Proof.DependencyEdge.trusted)).length
      s!"{", ".intercalate parts}"
        ++ s!" [{nonCurrent} non-current, {trustedN} trusted, {sorted.length} total]"

/-- Raw canonical body bytes per subject — the digest's INPUT, not its hash.

    Added while diagnosing a determinism defect that a hash cannot localise: two compilations of
    an identical `return x + 1;` produced different `bodyBytesV2` digests, and a hash says only
    THAT they differ. The bytes say WHERE, which is the difference between a bounded diff and an
    open investigation.

    Kept rather than deleted after the diagnosis: any future disagreement in this digest — and it
    is the value receipts will bind — is diagnosed the same way, and rebuilding this each time is
    how a one-off debugging session becomes a recurring one. -/
def bodyBytesReport (pc : Concrete.ProofCore) : String :=
  let rows := pc.entries.map fun e =>
    let hdr := e.callableId.render
    match e.evidenceBody with
    | none => s!"{hdr}\n  ABSENT (no structural body threaded)"
    | some d => match Proof.validate d with
      | .error gaps => s!"{hdr}\n  REFUSED ({gaps.length} gap(s))"
      | .ok complete => s!"{hdr}\n  {Proof.bodyBytesV2 complete}"
  s!"=== Canonical body bytes ({pc.entries.length} entries) ===\n" ++ "\n".intercalate rows ++ "\n"

/-- The AUTHORITATIVE join material for attestation, one row per claiming subject.

    The compiler emits this; the manifest generator JOINS it. That division is the point. A shell
    generator that derived package identity from directory layout would be a SECOND producer of
    implementation identity — reintroducing two answers at the moment R-0004 exists to eliminate
    them — and it would answer a different question from the one the `ProofCore` boundary already
    answers.

    So package scope comes from the compiler-produced proof SUBJECT, never from a theorem's
    filesystem location. An in-repo theorem does not need a package of its own: the attestation
    target is the implementation subject CONSUMING that theorem and table, and that subject has a
    package because every subject does.

    One row per subject with a scoped identity, carrying its selected theorem and the tables that
    theorem names. Subjects WITHOUT a scoped identity are emitted too, as `NO-IDENTITY`, because a
    silently shorter file makes a missing subject indistinguishable from an absent one.

    TWO POPULATIONS, AND THE ROLE COLUMN KEEPS THEM APART. `subject` rows are the ones above: a
    declaration some fixture links a proof to. `dependency` rows are the requested BODY-edge callees
    of those subjects — the population correspondence actually joins over, which is not the same set.
    A callee with no proof link of its own has no subject row, so nothing could attest a table entry
    to it, while the `CallableId` join matched it on NAME and reported `usable=yes`.

    A DEPENDENCY ROW IS AN IDENTITY, NOT A JUSTIFICATION. It says exactly which implementation an
    edge points at. It does not claim proof linkage, model faithfulness, or root availability, which
    is why its theorem column is `-` and why the role must never be inferred from the row's shape:
    giving an unlinked helper an exact reference must not make its missing proof node usable.

    Only `body` edges qualify. A `contract` edge holds for any table meeting its hypotheses and a
    `trusted` edge is witnessed by the declared boundary, so neither needs an exact implementation. -/
def attestationJoinReport (pc : Concrete.ProofCore) : String :=
  let tablesOf : String → List String := fun qn =>
    let thm := Concrete.theoremNameOf pc qn
    match Proof.validatedRowOf thm with
    | .error _ => []
    | .ok row  => row.tables.map (·.1)
  -- Requested body-edge callees, from the SAME producer the root and correspondence read
  -- (`dependencyNodesOf`). Deriving them a second way here is how two answers appear.
  --
  -- ONE ROW PER REQUEST, and the request is keyed by (CONSUMING SUBJECT, TABLE, CALLEE). Keying by
  -- (fixture, callee) is not strong enough and hides the exact defect this work exists to catch:
  -- `proof_pressure.check_nonce` has a perfectly good identity under `cryptoFns`, while the theorem
  -- claiming `validate_header` requests `elfFns` — a row elsewhere cannot satisfy this request.
  --
  -- THE WHOLE POPULATION IS EMITTED, not the subset that lacks a subject row. A callee gaining a
  -- proof link would otherwise make its dependency request DISAPPEAR, which is a denominator that
  -- shrinks when the corpus improves — the shape that makes coverage unfalsifiable.
  let depRows := (Concrete.dependencyNodesOf pc pc.callGraph).flatMap (fun n =>
    match pc.entries.find? (fun e => e.callableId == n.label) with
    | none => []
    | some subj =>
      let tables := tablesOf subj.qualName
      if tables.isEmpty then [] else
      let consumer := match subj.definitionIdentity with
        | .ok d  => d.digest
        | .error _ => "NO-IDENTITY"
      let consumerName := s!"{subj.callableId.defModule}.{subj.callableId.declName}"
      tables.flatMap (fun tbl =>
        n.edges.filterMap (fun (kind, d) =>
          if kind != Proof.DependencyEdge.body then none else
          let hdr := s!"dependency\tbinding_role=dependency\t{consumer}\t{consumerName}\t{tbl}"
          -- THE NODE ALREADY CARRIES THE SCOPED IDENTITY. It used to be re-resolved here from a
          -- `CallableId`, which was a second answer to a question `dependencyNodesOf` had already
          -- answered — and it searched one population, so an excluded callee that HAS an identity
          -- was reported as having none.
          let calleeName := d.localName
          let idFields := s!"{d.digest}\t{d.scope}\t{d.moduleIdentity}\t{d.declarationIdentity}\t{d.implementationIdentity}"
          match Proof.entryEvidenceWithProvenance tbl with
          | .error w =>
              some (hdr ++ s!"\tattested\tmodel=unresolved:{w.explain}\t{idFields}\n")
          | .ok (prov, rows) =>
              if rows.any (fun r => r.callee.declName == d.declarationIdentity
                                     && r.callee.defModule == d.moduleIdentity) then
                some (hdr ++ s!"\tattested\tmodel=present:{prov.render}\t{idFields}\n")
              else
                some (hdr ++ s!"\trefused\ttableModelMissing\t{idFields}\t{calleeName}\n"))
        ++ n.unscoped.filterMap (fun (c, kind) =>
          -- AN UNKEYABLE EDGE IS STILL A REQUEST. Omitting it would shrink the denominator by
          -- exactly the edges that cannot be satisfied.
          if kind != Proof.DependencyEdge.body then none else
          some (s!"dependency\tbinding_role=dependency\t{consumer}\t{consumerName}\t{tbl}" ++
                s!"\trefused\tcalleeWithoutIdentity\tNO-IDENTITY\t-\t{c.defModule}\t{c.declName}\t-\n")))
  )
  let rows := pc.entries.map (fun e =>
    let thm := Concrete.theoremNameOf pc e.qualName
    let tables := match Proof.validatedRowOf thm with
      | .error _ => []
      | .ok row  => row.tables.map (·.1)
    let tableStr := if tables.isEmpty then "-" else ",".intercalate tables
    let thmStr := if thm.isEmpty then "-" else thm
    match e.definitionIdentity with
    | .ok d =>
      s!"subject\t{d.digest}\t{d.scope}\t{d.moduleIdentity}\t{d.declarationIdentity}" ++
      s!"\t{d.implementationIdentity}\t{thmStr}\t{tableStr}\n"
    | .error w =>
      s!"subject\tNO-IDENTITY\t-\t{e.callableId.defModule}\t{e.callableId.declName}\t-" ++
      s!"\t{thmStr}\t{tableStr}\t{w.explain}\n")
  "# role<TAB>identity<TAB>scope<TAB>module<TAB>decl<TAB>implementation<TAB>theorem<TAB>tables\n"
    ++ "# role is `subject` (proof-linked declaration) or `dependency` (requested body-edge callee).\n"
    ++ "# A dependency row states WHICH implementation an edge points at. It is not proof linkage.\n"
    ++ String.join rows
    ++ String.join depRows
    ++ s!"# subjects={pc.entries.length} dependency_rows={depRows.length}\n"

/-- Emit GENERATED implementation references for a program's proof-linked definitions.

    The proof-author surface. A `PFnDef` cannot derive an implementation identity — it has no typed
    signature, capabilities, generics or contracts — so the binding is generated from the compiler's
    own facts and an author selects the typed symbol. They never transcribe a package identity or a
    digest: hand-copied digests go stale silently and a hand-written package name is the collision
    the scoped identity removes.

    Emits `Except`-typed values, deliberately. `DefinitionIdentity`'s constructor is private and
    `of?` validates, so a generated reference that fails validation stays a REFUSAL rather than
    becoming a value — the `needs_recheck` disposition, not a default.

    Only entries with a scoped identity are emitted, and the count of those WITHOUT one is reported,
    because a silently shorter file is how a missing reference becomes an author's puzzle rather than
    a stated gap. -/
def generatedImplementationsReport (pc : Concrete.ProofCore) : String :=
  let named := pc.entries.filterMap (fun e =>
    match e.definitionIdentity with
    | .error _ => none
    | .ok d =>
      -- Symbol name from module and declaration, sanitized to a Lean identifier. Collisions are
      -- impossible within one package because the declaration names are already unique there.
      let sym := (e.callableId.defModule ++ "_" ++ e.callableId.declName).map
                   (fun c => if c.isAlphanum then c else '_')
      some (sym, d))
  let rows := named.map (fun (sym, d) =>
    s!"/-- Generated: do not edit. Binds `{d.moduleIdentity}.{d.declarationIdentity}` to its
" ++
    s!"    authoritative implementation identity. -/
" ++
    s!"def {sym} : Except DefinitionIdentityRefusal DefinitionIdentity :=
" ++
    s!"  DefinitionIdentity.of? \"{d.scope}\" \"{d.moduleIdentity}\" " ++
    s!"\"{d.declarationIdentity}\" \"{d.implementationIdentity}\"
")
  let unscoped := pc.entries.length - named.length
  "-- GENERATED by `concrete <file> --report generated-implementations`. Do not edit.
" ++
  "namespace GeneratedImplementations
open Concrete.Proof

" ++
  String.join (rows.intersperse "
") ++
  s!"
end GeneratedImplementations
" ++
  s!"-- emitted={named.length} unscoped={unscoped}
"

/-- The implementation-manifest accounting for a real program — SHADOW, decides nothing.

    This exists because `implementationManifestResultOf` had no consumers and therefore no gate: the
    completeness conditions were pinned only by synthetic results, so nothing measured whether real
    production is actually complete. The old `filterMap` producer could not have told us — it
    returned the subset it managed to build, which is indistinguishable from a complete manifest.

    Prints the stored denominator, the rows built, and each refusal WITH ITS REASON, so an
    incompleteness shows up as a named cause rather than a smaller number. `usable=` is the verdict
    `ManifestResult.usable?` gives, reported rather than acted on: nothing consumes this manifest yet
    and this line must not be read as connecting it to anything. -/
def implementationManifestReport (pc : Concrete.ProofCore) : String :=
  let r := Concrete.implementationManifestResultOf pc
  let refusalLines := r.refusals.map fun (cid, why) =>
    s!"refused {cid.render} | {Proof.ManifestRefusal.render why}\n"
  let byReason := (r.refusals.map (fun rf => Proof.ManifestRefusal.render rf.2)).eraseDups.map
    fun name => s!"{name}={((r.refusals.filter (fun rf => Proof.ManifestRefusal.render rf.2 == name)).length)}"
  String.join refusalLines
    ++ s!"IMPL-MANIFEST expected={r.expected.length} rows={r.impls.length} "
    ++ s!"refused={r.refusals.length} accounted={r.accounted} "
    ++ s!"usable={if r.usable?.isSome then "yes" else "no"}\n"
    ++ (if byReason.isEmpty then "" else s!"IMPL-MANIFEST-REASONS {" ".intercalate byReason}\n")

/-- The migration manifest: ONE ROW PER STORED PROOF LINK, joined to the callable it belongs to.

    `check_migration_manifest.sh` could only prove CO-OCCURRENCE — that 44 links live in files
    containing N digestible subjects. That admits a link which is dangling, duplicated, or
    attached to the wrong function, because nothing associated a link with an owner. This is the
    join, produced by the compiler, which is the only layer that knows both.

    One row per link, not per subject: a subject may carry several links, and collapsing them
    would hide a duplicate. The row is deliberately wide enough to be the authoritative input to
    the step-7 migration rather than a summary of it —

      callable-id | stored-v1 | selected-spec | claim-scope | current-v2 | disposition

    `disposition` is derived, not stored: `needs_recheck` when the stored value is a v1 (no
    `v2:` prefix) and therefore not comparable; `current`/`stale` only when it is. An UNOWNED
    row — a stored link whose function is not in ProofCore — is emitted with `owner=NONE` rather
    than dropped. Dropping it is precisely how a dangling link survives a migration: it would
    disappear from the manifest and be counted nowhere. -/
def migrationManifestReport (pc : Concrete.ProofCore) (registry : ProofRegistry) : String :=
  let stored := registry.filter (fun re => re.expectedHash.isSome)
  let rowsWithOwned := stored.map fun re =>
    let entry? := pc.entries.find? fun e => e.qualName == re.function
    let owner := match entry? with
      | some e => e.callableId.render
      | none   => "NONE"
    let curV2 := match entry?.bind (·.subjectDigest) with
      | some d => "v2:" ++ shortHash d
      | none   => "NO-SUBJECT"
    let storedV1 := re.expectedHash.getD ""
    let disp :=
      if owner == "NONE" then "unowned"
      else if !("v2:".isPrefixOf storedV1) then "needs_recheck"
      else if curV2 == "NO-SUBJECT" then "no_subject"
      else if storedV1 == curV2 then "current" else "stale"
    (s!"{re.function} | owner={owner} | stored={storedV1} | spec={re.spec} | scope={re.coverage} | current={curV2} | {disp}", owner != "NONE")
  let rows := rowsWithOwned.map (·.1)
  let owned := (rowsWithOwned.filter (·.2)).length
  let subjects := (stored.filterMap fun re =>
      (pc.entries.find? fun e => e.qualName == re.function).map (·.callableId.render)).eraseDups
  String.join
    [ s!"=== Migration manifest ({rows.length} stored links) ===\n"
    , s!"links: {rows.length}  owned: {owned}  unique subjects: {subjects.length}\n\n"
    , "\n".intercalate rows, "\n" ]

/-- INSPECTION surface for captured declaration facts. Deliberately not evidence:
    it renders what was captured so a gate can check the producer against real
    programs, which is otherwise unobservable outside Lean.

    One line per entry, identity first, then whether a complete subject digest
    could be minted. An entry whose facts are absent or incomplete says so rather
    than printing a plausible-looking row. -/
def subjectFactsReport (pc : Concrete.ProofCore) : String :=
  let rows := pc.entries.map fun e =>
    let idr := e.callableId.render
    match e.declFacts with
    | none => s!"{idr}\n  facts: ABSENT"
    | some fx =>
      let dig := match e.subjectDigest with
        | some d => d
        | none   => "INCOMPLETE (no digest minted)"
      String.join
        [ s!"{idr}\n"
        , s!"  params: {fx.params}\n"
        , s!"  ret: {fx.retTy}\n"
        , s!"  typeParams: {fx.typeParams.length} bounds: {fx.typeBounds}\n"
        , s!"  caps: {fx.capSet} capParams: {fx.capParams.length}\n"
        , s!"  contracts covered: {fx.contracts.covered} "
        , s!"reqs: {fx.contracts.requires.length} ens: {fx.contracts.ensures.length} loopClauses: {fx.contracts.loops.length}\n"
        , s!"  trusted: {fx.isTrusted}\n"
        , s!"  subject digest: {dig}\n"
        -- SHADOW. Reported so V1 and V2 can be compared on the real corpus before
        -- either is trusted, and deliberately NOT part of `dig` above: the
        -- authoritative digest stays V1-frozen while this is observed.
        --
        -- Two lines, because they answer different questions and the flat one was
        -- being read as though it answered both. `identityUses` digests the flat list
        -- of identity references; measured on the corpus, `p + 1`, `p * 2` and `p - 9`
        -- all hash the same there, so it is a reference inventory and NOT a body
        -- representation. `bodyV2` digests the structural body, where they differ.
        , s!"  shadow identityUses: {(Proof.shadowIdentityUseDigest fx.bodyIdentityInputs shortHash).getD "REFUSED (uncovered)"}\n"
        -- A body with any gap is REFUSED with its reasons rather than digested: the
        -- type makes that unrepresentable, and printing a digest over a partial body
        -- would offer something comparable that describes less than the program.
        , s!"  shadow bodyV2: {shadowBodyV2Line e.evidenceBody}\n"
        -- The DEPENDENCY axis, separate from the body axis. A body can be completely
        -- described and still rest on a constant whose meaning is unrecorded; reporting
        -- them on one line would let a complete body imply a complete subject.
        , s!"  shadow deps: {shadowDepsLine e.evidenceBody e.constBindings}\n"
        -- The third axis. Completeness asks whether the subject DESCRIBES the body;
        -- dependency asks whether what it reaches is BOUND; this asks what a claim over
        -- it would be RESTING ON. A subject can be complete and fully bound and still
        -- carry assumptions, and reporting fewer than three lines would let one imply
        -- another.
        , s!"  shadow assumes: {shadowAssumesLine e.evidenceBody}\n"
        , s!"  shadow edges: {shadowEdgesLine e.evidenceBody}\n"
        , s!"  shadow inherited: {inheritedAssumptions pc.entries e}\n"
        , s!"  shadow edgeKinds: {shadowEdgeKinds pc e}\n"
        -- The FIFTH axis, and the one step 5 turns on. The four above describe the
        -- subject; this one says what COMPARING it would decide. Separate because a
        -- complete, bound, assumption-free subject can still be pinned against a v1
        -- value — completeness of the subject and comparability of the claim are
        -- different questions, and one line for both would let the first imply the
        -- second.
        , s!"  shadow subjectFreshness: {shadowSubjectFreshnessLine e.subjectDigest (storedFpFor pc e.qualName)}\n"
        -- The SIXTH axis. The five above describe this subject and what comparing it decides;
        -- this says what a claim over it would REST ON transitively. Separate because a fresh,
        -- fully-described subject can still reach a dependency nothing has classified.
        -- THE SEVENTH AXIS, added 2026-08-13, and it exists because two axes above were silently
        -- describing DIFFERENT edge sets. `shadow edgeKinds` derives from `e.evidenceBody`;
        -- `shadow depRoot` derives from `pc.callGraph`. For 9 of 64 subjects the first reported a
        -- non-current edge while the second rooted anyway, because the graph it read had no such
        -- edge to refuse. Neither line was wrong about its own source, and that is precisely why the
        -- disagreement was invisible: it needed a line showing the OTHER source to become a fact
        -- rather than an inference. Printing the call-graph view makes both observable side by side.
        , s!"  shadow graphEdges: {shadowGraphEdgesLine pc e.qualName}\n"
        -- The SCOPED identity for this subject, or why it has none. Reported so coverage is
        -- measurable before the join is migrated to use it.
        , s!"  shadow defIdentity: {match e.definitionIdentity with
              | .ok d => d.digest
              | .error w => s!"NONE ({w.explain})"}\n"
        , s!"  shadow correspondence: {shadowCorrespondenceLine pc e.callableId}\n"
        , s!"  shadow depRoot: {shadowDepRootLine pc e.callableId}"
        ]
  s!"=== Subject facts ({pc.entries.length} entries) ===\n" ++ "\n".intercalate rows ++ "\n"

/-- Generate Lean theorem stubs for all extracted functions. -/
def leanStubsReport (pc : Concrete.ProofCore)
    (registry : ProofRegistry := []) : String :=
  let entries := extractionEntriesFromPC pc registry
  let extracted := entries.filter fun e => e.eligible && e.extracted.isSome
  if extracted.isEmpty then "-- No extractable functions found.\n"
  else
  let header := "import Concrete.Proof.Proof\n\nnamespace Concrete.Proof.Generated\n\nopen Concrete.Proof"
  -- Build function table entries
  let fnDefs := extracted.map fun e =>
    let name := leanSymbol e.qualName
    -- The operational key is the BARE name; the Lean symbol is qualified. These
    -- are different jobs and must not be conflated (see below).
    let key := leanIdent (e.qualName.splitOn "." |>.getLast!)
    let pexpr := match e.extracted with | some p => renderPExprAsLean p | none => "sorry"
    -- `none` when extraction produced no body: an entry with no body has no body
    -- digest, and emitting one over a `sorry` placeholder would be a digest of
    -- nothing wearing the name of a digest of something.
    let sbd := match e.extracted with
      | some p => renderSourceBodyDigest p
      | none   => "none"
    let paramsLean := e.params.map fun p => s!"\"{p}\""
    let paramsList := "[" ++ ", ".intercalate paramsLean ++ "]"
    -- The entry carries a SEMANTIC IDENTITY, split at the last dot so the
    -- defining module and the declaration name come from the qualified name
    -- rather than being reconstructed later from a display string (R-0004 step 4).
    -- READ the identity that ProofCore minted from resolved compiler facts.
    -- Splitting `qualName` here is what this replaces: it re-derived identity
    -- from a rendering, one layer away from the facts.
    -- The COMPLETE carried identity, not a reconstructed subset.
    let idLit := match e.callableId with
      | some cid => renderCallableId cid
      | none     => "sorry  -- UNMAPPABLE: no CallableId carried from ProofCore"
    s!"/-- Extracted from `{e.qualName}`. -/\ndef {name}Expr : PExpr :=\n    {pexpr}\n\n" ++
    s!"/-- Semantic identity of `{e.qualName}`. Generated, not hand-written: an\n" ++
    s!"    identity an author can type is an identity an author can get wrong.\n" ++
    s!"    Every field is carried from the compiler — namespace, schema version and\n" ++
    s!"    type arguments included, since a partial identity is a different one. -/\n" ++
    s!"def {name}Id : CallableId :=\n  {idLit}\n\n" ++
    -- `displayName` is the OPERATIONAL KEY — the bare name `PExpr.call` selects
    -- by — NOT the Lean symbol. Emitting the qualified symbol here made the
    -- table's keyIndex record `calls_inc -> id` while evaluation resolved `"inc"`,
    -- so the ROOT committed to a key map that was not the one in use, defeating
    -- the point of binding the index at all.
    s!"def {name}Fn : PFnDef :=\n  \{ identity := .semantic {name}Id, operationalKey := \"{key}\",\n    sourceBodyDigest := {sbd},\n    displayName := \"{key}\", params := {paramsList}, body := {name}Expr }"
  -- Build function table
  -- DEDUPLICATED arms. Emitting one arm per entry produced two `| "compute" =>`
  -- alternatives and Lean rejected the file outright, so the artifact was invalid
  -- rather than merely refused. First-wins keeps it well-formed; the AMBIGUITY is
  -- then caught by `isEvidenceBearing` (via keyIndexUnique and dispatchResolves),
  -- which is a typed refusal rather than a parse error.
  let seenKeys := extracted.foldl (fun acc e =>
    let k := leanIdent (e.qualName.splitOn "." |>.getLast!)
    if acc.contains k then acc else acc ++ [k]) []
  let firstForKey := fun (k : String) =>
    extracted.find? fun e => leanIdent (e.qualName.splitOn "." |>.getLast!) == k
  let tableCases := seenKeys.filterMap fun k => (firstForKey k).map fun e =>
    -- The operational KEY stays the bare name (that is what `PExpr.call`
    -- selects by), but the SYMBOL is qualified so declarations cannot collide.
    let name := leanSymbol e.qualName
    let key := leanIdent (e.qualName.splitOn "." |>.getLast!)
    s!"  | \"{key}\" => some {name}Fn"
  -- Emitted as an equation-compiled function wrapped in `FnTable.ofGlobals`, not
  -- as a `def _ : FnTable | …` literal: `FnTable` is a two-namespace structure
  -- since R-0442, and a bare pattern match no longer typechecks against it. The
  -- wrapper also keeps `simp`'s equation lemmas available, which a structure
  -- instance built from an anonymous match would not.
  -- Emitted in strict CallableId order. `isEvidenceBearing` kernel-checks the
  -- ordering, so a generator emitting source order fails the BUILD — which is
  -- how this omission was caught rather than shipping an unsortable table. The
  -- key mirrors `CallableId.render` exactly; sorting by anything else would be a
  -- second, drifting notion of order.
  -- Sorted by the RENDERED carried identity, so the order the generator emits and
  -- the order the table asserts come from the same function.
  let identityKeyOf := fun (e : ExtractionEntry) =>
    match e.callableId with
    | some cid => cid.render
    | none     => ""
  let sortedEntries := extracted.toArray.qsort
    (fun a b => identityKeyOf a < identityKeyOf b) |>.toList
  let entryNames := sortedEntries.map fun e => leanSymbol e.qualName ++ "Fn"
  -- Per-entry `[simp]` LOOKUP LEMMAS. An `Array` has no equation lemmas, so the
  -- `simp [XFnsGlobals]` idiom that every existing proof relies on has nothing to
  -- rewrite with. These restore that behaviour, and they are GENERATED with the
  -- table so the lemma set cannot drift from the entries it describes.
  let lookupLemmas := extracted.map fun e =>
    let name := leanSymbol e.qualName
    s!"@[proofTable] theorem generatedFns_lookup_{name} :\n" ++
    -- `rfl`, not `decide`: `IdentifiedPFnDef` contains a `PExpr`, which
    -- deliberately has no `DecidableEq` (see PVal's note), so `decide` cannot
    -- synthesize an instance. Lookup reduces to the entry definitionally, which
    -- is the stronger statement anyway.
    s!"    generatedFns.lookupById {name}Id = ({name}Fn).identified? := by\n  rfl"
  -- Ambiguous operational keys make the table unable to bear evidence, and a
  -- dispatch with two arms for one key is invalid Lean besides. FAIL CLOSED: say
  -- so, and do not emit the integrity assertion — a partial table must not appear
  -- complete. Measured on a program with Alpha.compute / Beta.compute /
  -- Gamma.compute, which previously produced three redundant match arms.
  let opKeys := extracted.map fun e => leanIdent (e.qualName.splitOn "." |>.getLast!)
  let dupKeys := (opKeys.filter fun k => (opKeys.filter (· == k)).length > 1).eraseDups
  let keysAmbiguous := !dupKeys.isEmpty
  -- Generic declarations extracted with the instantiation erased. Reported by
  -- NAME so the author knows which ones to specialize, and detected from the
  -- carried identity rather than by re-inspecting the source.
  let erasedGenerics := extracted.filterMap fun e =>
    match e.callableId with
    | some cid => if cid.isComplete then none else some e.qualName
    | none     => none
  let tableStr :=
    -- CANONICAL entries — the evidence-bearing form. The legacy string dispatch
    -- is still emitted because `PExpr.call` selects by name, and it is labelled
    -- as operational lookup rather than as identity.
    s!"/-- Canonical entries: the evidence-bearing form. Ordered by the table\n" ++
    s!"    itself, never by emission order. -/\n" ++
    s!"def generatedEntries : Array PFnDef := #[{", ".intercalate entryNames}]\n\n" ++
    s!"/-- LEGACY OPERATIONAL LOOKUP. `PExpr.call \"f\"` still selects by name, so\n" ++
    s!"    this mapping survives; it is not identity, and the table root binds it. -/\n" ++
    s!"def generatedFnsGlobals : String → Option PFnDef\n{"\n".intercalate tableCases}\n  | _ => none\n\n" ++
    s!"/-- Locally bound callables (fn-typed parameters). Applications of these\n" ++
    s!"    extract to `.applyVar` and are answered ONLY here — a definition of the\n" ++
    s!"    same name cannot satisfy them (R-0442). -/\n" ++
    s!"def generatedFnsCallables : String → Option PFnDef := fun _ => none\n\n" ++
    s!"def generatedFns : FnTable :=\n" ++
    s!"  \{ entries := generatedEntries,\n" ++
    s!"    globals := generatedFnsGlobals, callables := generatedFnsCallables }\n\n" ++
    s!"/-- The table must be able to bear evidence: every entry identified, no\n" ++
    s!"    duplicate identity, and no string key reaching two entries. Checked by\n" ++
    s!"    the kernel at build time, so a generator bug fails the build. -/\n" ++
    (if !erasedGenerics.isEmpty then
       s!"-- TYPE-ERASED GENERICS: these are declared with type parameters but were\n" ++
       s!"-- extracted with no instantiation recorded:\n" ++
       s!"--   {", ".intercalate erasedGenerics}\n" ++
       s!"-- One erased entry cannot answer for every monomorphization, because the\n" ++
       s!"-- monomorphizations disagree: extracted arithmetic is width-free and the\n" ++
       s!"-- parameters are typed as unbounded `Int`, so a kernel-true proof here\n" ++
       s!"-- would be FALSE of an `i8` instance where `100 + 100` wraps.\n" ++
       s!"-- The assertion below is emitted ANYWAY and will FAIL: an incomplete\n" ++
       s!"-- identity invalidates `isEvidenceBearing` itself. Covering all\n" ++
       s!"-- instantiations from one erased entry would be an under-approximation,\n" ++
       s!"-- so it is refused rather than assumed.\n"
     else "") ++
    (if keysAmbiguous then
       s!"-- AMBIGUOUS OPERATIONAL KEYS: these reach more than one entry, so\n" ++
       s!"-- `PExpr.call` by name would select arbitrarily:\n" ++
       s!"--   {", ".intercalate dupKeys}\n" ++
       s!"-- Migrate those calls to CallableId, or disambiguate the names.\n" ++
       s!"-- The assertion below is emitted ANYWAY and will FAIL: ambiguity\n" ++
       s!"-- invalidates `isEvidenceBearing` itself, so this is a typed refusal,\n" ++
       s!"-- not a comment. Omitting the assertion was cosmetic — the table could\n" ++
       s!"-- still bear evidence.\n"
     else "") ++
    s!"example : generatedFns.isEvidenceBearing := by decide\n\n" ++
    s!"{"\n\n".intercalate lookupLemmas}"
  -- Build eval helpers
  let evalHelpers := extracted.map fun e =>
    let name := leanSymbol e.qualName
    let paramBinds := e.params.foldl (fun acc p =>
      if acc.isEmpty then s!"(Env.empty.bind \"{p}\" (.int {p}))"
      else s!"({acc}.bind \"{p}\" (.int {p}))"
    ) ""
    let paramSig := " ".intercalate (e.params.map fun p => s!"({p} : Int)")
    s!"def eval_{name} {paramSig} (fuel : Nat := 20) : Option PVal :=\n  eval generatedFns {paramBinds} fuel {name}Expr"
  -- Build theorem stubs
  let theoremStubs := extracted.map fun e =>
    let name := leanSymbol e.qualName
    let paramSig := " ".intercalate (e.params.map fun p => s!"({p} : Int)")
    let paramBinds := e.params.foldl (fun acc p =>
      if acc.isEmpty then s!"(Env.empty.bind \"{p}\" (.int {p}))"
      else s!"({acc}.bind \"{p}\" (.int {p}))"
    ) ""
    let specName := if e.specName.isEmpty then s!"{name}_correct" else
      s!"{name}_correct"
    let pcStr := match e.extracted with | some p => renderPExpr p | none => "?"
    s!"/-- TODO: State the correctness property for `{e.qualName}`.\n    Current ProofCore: {pcStr} -/\ntheorem {specName} {paramSig} (fuel : Nat) :\n    eval generatedFns {paramBinds}\n      (fuel + 1) {name}Expr\n    = sorry := by\n  sorry"
  -- Assemble
  let body := [
    header,
    "\n" ++ "\n\n".intercalate fnDefs,
    "\n\n" ++ tableStr,
    "\n\n" ++ "\n\n".intercalate evalHelpers,
    "\n\n-- ============================================================",
    "-- Theorem stubs — fill in the specification and proof",
    "-- ============================================================",
    "\n" ++ "\n\n".intercalate theoremStubs,
    "\nend Concrete.Proof.Generated"
  ]
  "\n".intercalate body ++ "\n"

-- ============================================================
-- `concrete prove <function>` — per-function proof scaffold
-- ============================================================
-- Read-only generator: given a function, print the imports, fingerprint,
-- extracted PExpr, contract/VC list with current discharge, a theorem
-- skeleton, ProofKit hints from detected features, and the next obligation.
-- It writes nothing (the CLI's --out is opt-in) and never auto-proves.

mutual
/-- Detected proof-relevant features in a Core expression, as tags
    ("loop", "array", "bitvec", "call") — drives ProofKit hints. -/
private partial def proveExprFeatures : CExpr → List String
  | .binOp op l r _ =>
    (match op with | .bitand | .bitor | .bitxor | .shl | .shr => ["bitvec"] | _ => [])
      ++ proveExprFeatures l ++ proveExprFeatures r
  | .call _ _ args _ => "call" :: args.flatMap proveExprFeatures
  | .arrayIndex a i _ => "array" :: (proveExprFeatures a ++ proveExprFeatures i)
  | .arrayLit es _ => "array" :: es.flatMap proveExprFeatures
  | .unaryOp _ e _ | .cast e _ | .fieldAccess e _ _
  | .borrow e _ | .borrowMut e _ | .deref e _ => proveExprFeatures e
  | .structLit _ _ fs _ | .enumLit _ _ _ fs _ => fs.flatMap (fun (_, e) => proveExprFeatures e)
  | .match_ s arms _ => proveExprFeatures s ++ arms.flatMap proveArmFeatures
  | .ifExpr c t e _ =>
    proveExprFeatures c ++ t.flatMap proveStmtFeatures ++ e.flatMap proveStmtFeatures
  | .allocCall a b _ => proveExprFeatures a ++ proveExprFeatures b
  | _ => []

private partial def proveArmFeatures : CMatchArm → List String
  | .enumArm _ _ _ _ body | .litArm _ _ body | .varArm _ _ _ body | .rangeArm _ _ _ _ body => body.flatMap proveStmtFeatures

partial def proveStmtFeatures : CStmt → List String
  | .letDecl _ _ _ v | .assign _ v | .expr v _ => proveExprFeatures v
  | .return_ (some v) _ => proveExprFeatures v
  | .return_ none _ => []
  | .ifElse c t e =>
    proveExprFeatures c ++ t.flatMap proveStmtFeatures ++ (e.getD []).flatMap proveStmtFeatures
  | .while_ c b _ step =>
    "loop" :: (proveExprFeatures c ++ b.flatMap proveStmtFeatures ++ step.flatMap proveStmtFeatures)
  | _ => []
end

/-- Render the `concrete prove` scaffold for one resolved function entry.
    `e` (Core) carries the extracted PExpr / fingerprint / params; `astFn` (AST)
    carries the source contracts (`requires`/`ensures`/`loopContracts`) since the
    Core `CFnDef` does not. `provedVCs` are the loop-VC keys the caller's omega
    pass discharged. -/
def proveReportEntry (registry : ProofRegistry) (e : ProofCoreEntry)
    (astFn : FnDef) (provedVCs : List String) : String := Id.run do
  let f := astFn  -- contracts + loop VC generation operate on the AST function
  let leanName := leanIdent (e.qualName.splitOn "." |>.getLast!)
  -- (1) imports
  let imports := "import Concrete.ProofKit\nimport Concrete.Proof.Proof"
  -- (2) fingerprint, (3) extracted PExpr
  let pcStr := match e.extracted with | some p => renderPExpr p | none => "(not extracted)"
  -- (4) contract / VC list
  -- A COVERAGE LABEL IS NOT EVIDENCE (bug 079 follow-up). This used to discharge the loop's
  -- invariant-preservation step whenever the link said `coverage: invariant` and named a proof —
  -- `loop_invariant.count_up` read `proved_by_lean` here while its claim was `spec_unbound`. A loop
  -- step is discharged by a theorem only once a loop-step binding ties that theorem to this loop;
  -- none exists yet (ROADMAP soundness track), so no label discharges anything.
  let preserveProof : Option String := none
  let mut vcLines : List String := []
  -- requires / ensures
  for r in f.requires do
    vcLines := vcLines ++ [s!"  requires {Concrete.fmtExpr r}    assumed_at_entry"]
  -- THE ensures verdict (bug 089): no link discharges a clause until a checked matcher confirms the
  -- theorem's conclusion is that clause. This used to print `proved_by_lean (full iff)` from the
  -- `#[proof_coverage(iff)]` label.
  let ensV := ensuresVerdictOf registry e.qualName
  for ens in f.ensures do
    let st := match ensV with
      | .noLink => "missing (no registered ensures_proof)"
      | .unmatched ts => s!"unproven — linked to {", ".intercalate ts}; conclusion not checked against this clause"
    vcLines := vcLines ++ [s!"  ensures {Concrete.fmtExpr ens}    {st}"]
  -- loop obligations
  let extraLets := letConstMap f.body
  let retExpr := loopExitReturn f.body
  let mut nextOb : Option (String × String) := none  -- (id, reason)
  -- The function postcondition IS the contract; completing it takes priority
  -- over the loop's operational step (which the literal-bound proof can bypass).
  if !f.ensures.isEmpty then
    match ensV with
    | .noLink =>
      nextOb := some ("#[ensures] postcondition",
        "state the spec and prove the postcondition; no registered theorem discharges it yet")
    | .unmatched _ =>
      nextOb := some ("#[ensures] postcondition", ensV.reason)
  for lc in f.loopContracts do
    let omegaSt := fun (obl : String) =>
      if provedVCs.contains (loopVCKey e.qualName lc.line obl) then "discharged by omega" else "PLANNED"
    if (genInitVC lc extraLets).isSome then
      vcLines := vcLines ++ [s!"  O1 invariant_init          {omegaSt "O1"}"]
    -- O2 split: arithmetic (omega) + operational (Lean)
    let o2arith := omegaSt "O2"
    let o2op := match preserveProof with
      | some thm => s!"linked to Lean theorem {thm}"
      | none => "needs Lean (operational realization)"
    vcLines := vcLines ++ [s!"  O2 invariant_preservation  arithmetic: {o2arith}; operational: {o2op}"]
    if preserveProof.isNone && nextOb.isNone then
      nextOb := some ("O2 invariant_preservation",
        "operational step: the extracted loop body realizes the state transition; this is an eval-level Lean proof, not pure linear arithmetic")
    if (genExitVC lc f.ensures retExpr).isSome then
      vcLines := vcLines ++ [s!"  O3 loop_exit_post_link     {omegaSt "O3"}"]
    if lc.variant.isSome then
      vcLines := vcLines ++ [s!"  O4 variant_nonnegative     {omegaSt "O4"}"]
      vcLines := vcLines ++ [s!"  O5 variant_decreases       {omegaSt "O5"}"]
  -- function-level status fallback for the "next" pointer
  if nextOb.isNone then
    if e.extracted.isNone then
      nextOb := some ("extraction", s!"function is not extractable: {", ".intercalate e.unsupported}")
    else if !f.ensures.isEmpty then
      nextOb := some ("ensures", "state the refinement spec and prove `<fn> refines spec`; no registered theorem yet")
  let vcSection := if vcLines.isEmpty then "  (no source contracts or loop obligations on this function)"
                   else "\n".intercalate vcLines
  -- (5) theorem skeleton
  let paramSig := " ".intercalate (e.params.map fun p => s!"({p} : Int)")
  let nextTodo := match nextOb with | some (id, _) => s!"-- TODO: {id}" | none => "-- TODO: state and prove the property"
  let skeleton :=
    s!"theorem {leanName}_refines_spec {paramSig} (fuel : Nat) : True := by\n  {nextTodo}\n  trivial"
  -- (6) ProofKit hints from detected features (scanned over the Core body)
  let feats := (e.fn.body.flatMap proveStmtFeatures).eraseDups
  let hasLoop := feats.contains "loop" || !f.loopContracts.isEmpty
  let mut hints : List String := []
  if hasLoop then hints := hints ++ ["  loops    → Concrete.ProofKit.Loops: eval_while_count, counter-loop invariants"]
  if feats.contains "array" then hints := hints ++ ["  arrays   → Concrete.ProofKit.Array: lookupIndex_set_self/ne, length_set"]
  if feats.contains "bitvec" then hints := hints ++ ["  bitvecs  → bv_decide for closed bitvector goals; Concrete.ProofKit.BitVec bridges"]
  if feats.contains "call" then hints := hints ++ ["  calls    → Concrete.ProofKit.Calls: FnTable skeleton + call wrappers"]
  let hintSection := if hints.isEmpty then "  (no loop/array/bitvec/call features detected)" else "\n".intercalate hints
  -- (7) next obligation
  let nextSection := match nextOb with
    | some (id, reason) => s!"next: {id}\nreason: {reason}"
    | none => "next: nothing outstanding from generated obligations (a full refinement spec may still be unstated)"
  -- assemble
  return String.join [
    s!"=== concrete prove: {e.qualName} ===\n\n",
    s!"-- (1) suggested imports\n{imports}\n\n",
    s!"-- (2) body fingerprint\n{e.fingerprint}\n\n",
    s!"-- (3) extracted ProofCore body\n{pcStr}\n\n",
    s!"-- (4) contracts / verification conditions\n{vcSection}\n\n",
    s!"-- (5) theorem skeleton (fill in the spec; replace `True`/`trivial`)\n{skeleton}\n\n",
    s!"-- (6) ProofKit hints\n{hintSection}\n\n",
    s!"-- (7) {nextSection}\n" ]

/-- Resolve a `concrete prove` target to a single entry/excluded function.
    Accepts a fully-qualified name, or a bare name if it is unique. Returns the
    resolved `qualName`, or an error message listing candidates. -/
def proveResolve (pc : Concrete.ProofCore) (target : String) : Except String String :=
  let allNames := pc.entries.map (·.qualName) ++ pc.excluded.map (·.qualName)
  match allNames.find? (· == target) with
  | some q => .ok q
  | none =>
    let byBare := allNames.filter fun q => (q.splitOn ".").getLast! == target
    match byBare with
    | [q] => .ok q
    | [] => .error s!"no function '{target}'. Known functions:\n  {"\n  ".intercalate allNames}"
    | many => .error s!"'{target}' is ambiguous; qualify it:\n  {"\n  ".intercalate many}"

/-- Top-level `concrete prove` report for a resolved `qualName`. Looks up the
    AST function (for source contracts) and the Core entry (for the extracted
    body); handles the excluded case (prints why, no stub). -/
def proveReport (pc : Concrete.ProofCore) (registry : ProofRegistry)
    (modules : List Module) (qualName : String) (provedVCs : List String) : String :=
  let astFn? := (modules.flatMap allFunctions).find? (fun (pfx, fn) => pfx ++ fn.name == qualName)
    |>.map Prod.snd
  match pc.entries.find? (·.qualName == qualName), astFn? with
  | some e, some astFn => proveReportEntry registry e astFn provedVCs
  | some e, none =>
    -- Extracted but no AST match (shouldn't happen): fall back without contracts.
    proveReportEntry registry e { name := e.bareName, params := [], retTy := .unit, body := [] } provedVCs
  | none, _ =>
    match pc.excluded.find? (·.qualName == qualName) with
    | some x =>
      let reasons := x.eligibility.sourceReasons ++ x.eligibility.profileReasons
      s!"=== concrete prove: {qualName} ===\n\nThis function is NOT in the provable subset, so there is no proof to scaffold.\n  reasons: {", ".intercalate reasons}\n\nMake it eligible (remove the listed constraints) or prove it as a trusted boundary."
    | none => s!"no function '{qualName}' in ProofCore."

/-- Single source of truth for one loop obligation's identity and content.
    Returns `(kind, hypotheses, conclusion, status)` for `oblId` ∈ O1..O5, or
    `none` when that obligation does not exist on this loop (gating: O1 needs a
    groundable init, O3 a groundable exit postcondition, O4/O5 a variant).
    `status` is `proved_by_kernel_decision` (omega closed), `arithmetic_proved`
    (O2 arithmetic half closed, operational pending), or `planned`. Used by both
    `--show-obligation` and `--json` so ids/kinds/hypotheses never drift. -/
def loopObInfo (lc : LoopContract) (oblId qualName : String) (posts₀ : List Expr)
    (extraLets : List (String × Expr)) (retExpr : Option Expr) (provedVCs : List String)
    (outer : List Expr := []) :
    Option (String × List String × String × String) :=
  let invs := lc.invariants.filterMap toLeanProp
  -- Phase 3 #9: the function's `#[requires]` are in scope for every loop
  -- obligation; surface them in the hypotheses (monotonic — see `loopVCGoals`).
  let outerStrs := outer.filterMap toLeanProp
  let guardStr := (lc.guard.bind toLeanProp).getD "<guard>"
  let variantStr := (lc.variant.bind toLeanProp).getD "<variant>"
  let variantBody := (lc.variant.map (substContract lc.body)).bind toLeanProp |>.getD "<variant'>"
  let omegaDone := provedVCs.contains (loopVCKey qualName lc.line oblId)
  let status := fun (leanOp : Bool) =>
    if omegaDone && !leanOp then "proved_by_kernel_decision"
    else if omegaDone && leanOp then "arithmetic_proved"
    else "planned"
  match oblId with
  | "O1" => (genInitVC lc extraLets outer).map fun g =>
      ("invariant_init", outerStrs ++ ["loop-entry state (counter at its initializer)"], g, status false)
  | "O2" => some ("invariant_preservation", outerStrs ++ invs ++ [guardStr],
      " ∧ ".intercalate ((lc.invariants.map (substContract lc.body)).filterMap toLeanProp), status true)
  | "O3" => (genExitVC lc posts₀ retExpr outer).map fun g =>
      ("loop_exit_post_link", outerStrs ++ invs ++ [s!"¬({guardStr})"], g, status false)
  | "O4" => if lc.variant.isSome then
      some ("variant_nonnegative", outerStrs ++ invs ++ [guardStr], s!"0 ≤ {variantStr}", status false) else none
  | "O5" => if lc.variant.isSome then
      some ("variant_decreases", outerStrs ++ invs ++ [guardStr], s!"{variantBody} < {variantStr}", status false) else none
  | _ => none


end Report
end Concrete
