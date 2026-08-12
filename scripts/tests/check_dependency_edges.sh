#!/usr/bin/env bash
# R-0004 step 6 — typed dependency edges, DERIVED from the theorem.
#
# The edge kind must come from what a proof actually uses, never from an author's
# declaration: a mode flag would let someone claim `contract` while the proof
# unfolds a concrete table, and an implementation change that preserved the
# contract would then fail to stale a caller that really depends on the body.
set -uo pipefail
# An unexpected command failure must not sit beside a green total. A backtick in a
# probe label once executed `missing` as a command and the gate still reported
# 26/0 — the error was visible and the verdict said otherwise.
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

probe() {
  local label="$1" want="$2" body="$3"
  cat > "$TMP/p.lean" <<LEAN
import Concrete
import Examples
open Lean Meta Concrete Concrete.Proof
$body
LEAN
  local out; out="$(lake env lean "$TMP/p.lean" 2>&1 || true)"
  # An error is a failure whatever the text says — a probe that cannot elaborate
  # must not pass on a digit inside "line:col" (that happened in the migration gate).
  # Match a LEAN DIAGNOSTIC, not the bare word: `Except.error` is a legitimate
  # value and matching "error" made every probe of a refusal a false negative —
  # the vacuity guard corrupting the measurement it exists to protect.
  if grep -qE "error:|error\(lean" <<<"$out"; then
    no "$label — probe did not elaborate: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"
  elif grep -qF -- "$want" <<<"$out"; then ok "$label"
  else no "$label — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"; fi
}

echo "=== the vocabulary is complete and cannot launder trust ==="
# COMPLETENESS IS A THEOREM (`DependencyEdge.mem_all`), not this length check. A count protects
# nothing against a sixth constructor whose author also updates the 5 to a 6 — the list and the
# number are edited in the same breath, so the test agrees with whatever was written. The theorem
# leaves an unsolved case instead; verified by deleting a constructor from `all` and watching the
# build fail with `case unclassified ⊢ False`.
#
# What stays here is what a theorem cannot state: that the canonical TAGS are distinct, since two
# kinds sharing a tag would be indistinguishable in a receipt.
probe "canonical edge tags are distinct" "true" \
'#eval (DependencyEdge.all.map DependencyEdge.canonical).eraseDups.length == DependencyEdge.all.length'
# `missing` is the only kind that is never current. `trusted` IS current — but
# only with its trust carried forward, which is a separate question and must stay
# a separate function, or an unqualified `proved_by_lean` gets minted over a trust
# boundary.
# TWO kinds are not current, and `unclassified` joining `missing` is the point: "nobody has
# classified this" must not read as "this is fine". The predicate is exhaustive with no
# wildcard, so a future edge kind is a compile error rather than silently born current — which
# is what happened when `unclassified` was added under a `| _ => true` catch-all.
probe "missing AND unclassified are not current for dependents" "true" \
'#eval (DependencyEdge.all.filter (fun e => !e.isCurrentForDependents))
        == [DependencyEdge.missing, DependencyEdge.unclassified]'
# The distinction must survive: both fail closed, and they are still different states with
# different repairs — a proof versus running the classification hand-back.
probe "unclassified is DISTINCT from missing" "true" \
'#eval DependencyEdge.unclassified != DependencyEdge.missing
  && DependencyEdge.unclassified.canonical != DependencyEdge.missing.canonical'
# And the root must refuse it, not traverse it as validated.
probe "a root refuses an UNCLASSIFIED edge" "true" \
'#eval (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.unclassified, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }] (CallableId.ofUser "m" "a")) matches Except.error _'
probe "only trusted propagates trust" "true" \
'#eval (DependencyEdge.all.filter DependencyEdge.propagatesTrust) == [DependencyEdge.trusted]'
probe "trusted is current AND propagates — both, not either" "true" \
'#eval DependencyEdge.trusted.isCurrentForDependents && DependencyEdge.trusted.propagatesTrust'
# A body change stales a body edge and not a contract edge. That IS the modular
# vs closed-subject distinction, as data rather than prose.
probe "a body change invalidates body but not contract" "true" \
'#eval DependencyEdge.body.invalidatedByBodyChange && !DependencyEdge.contract.invalidatedByBodyChange'

echo ""
echo "=== the edge is DERIVED from the theorem, on the roadmap's own exemplars ==="
# `unary_call` quantifies over `fns` and takes the callee's behaviour as a
# hypothesis; `combine_correct` names `combineFns` and unfolds helper bodies.
probe "unary_call derives a contract edge" "contract" \
'#eval show MetaM Unit from do
   let r ← classifyTheorem ``Concrete.Proof.unary_call
   IO.println (repr (r.map (·.edge)))'
probe "combine_correct derives a body edge" "body" \
'#eval show MetaM Unit from do
   let r ← classifyTheorem ``Examples.ProofPatterns.Proofs.combine_correct
   IO.println (repr (r.map (·.edge)))'
# A body edge must say WHICH tables it binds; "body" alone does not let a consumer
# decide whether a given change stales it.
probe "a body edge names the table it binds" "combineFns" \
'#eval show MetaM Unit from do
   let r ← classifyTheorem ``Examples.ProofPatterns.Proofs.combine_correct
   IO.println (repr (r.map (·.tables)))'
# No table dependency is NOT `missing`. Collapsing them would let "irrelevant"
# read as "unvalidated" and contain claims that are fine.
probe "a theorem with no table dependency classifies as none, not missing" "none" \
'#eval show MetaM Unit from do
   let r ← classifyTheorem ``Concrete.ProofSoundness.spec_total
   IO.println (repr (r.map (·.edge)))'

echo ""
echo "=== table-valued combinators: the fail-OPEN gap is closed ==="
# A naive "constant whose TYPE is FnTable" test misses `eval (FnTable.ofGlobals g)`
# — the constant has FUNCTION type — and answers `contract` for a theorem that
# depends on concrete entries. That is the unsafe direction. Measured: widening to
# "returns FnTable" moved 8 theorems from contract to body.
probe "FnTable.ofGlobals counts as table-valued" "true" \
'#eval show MetaM Unit from do
   let ci ← getConstInfo ``Concrete.Proof.FnTable.ofGlobals
   IO.println (toString (← isTableValued ci))'
probe "a plain table definition counts as table-valued" "true" \
'#eval show MetaM Unit from do
   let ci ← getConstInfo ``Concrete.Proof.ctTagFns
   IO.println (toString (← isTableValued ci))'
probe "a non-table constant does not" "false" \
'#eval show MetaM Unit from do
   let ci ← getConstInfo ``Concrete.Proof.pexprCanonical
   IO.println (toString (← isTableValued ci))'

echo ""
echo "=== corpus split, pinned ==="
# Pinned so a change in how theorems are written, or in the classifier, has to be
# looked at rather than absorbed. 0 of these are ambiguous, which is why no
# tie-break rule exists: none is needed.
probe "the corpus splits 113 contract / 166 body" "113/166" \
'#eval show MetaM Unit from do
   let env ← getEnv
   let mut nc := 0; let mut nb := 0
   for (n, ci) in env.constants.toList do
     unless (ci matches .thmInfo _) do continue
     let s := n.toString
     unless s.startsWith "Examples." || s.startsWith "Concrete.Proof" do continue
     if (s.splitOn "_proof_").length > 1 then continue
     match ← classifyTheorem n with
     | none => pure ()
     | some e => if e.edge == .body then nb := nb + 1 else nc := nc + 1
   IO.println s!"{nc}/{nb}"'

echo ""
echo "=== dependency roots: fail closed on every incomplete input ==="
GRAPH='def g : List DepNode :=
  [ { id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] }
  , { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [(DependencyEdge.body, CallableId.ofUser "m" "c")] }
  , { id := CallableId.ofUser "m" "c", digest := some "DC", edges := [] }
  , { id := CallableId.ofUser "m" "d", digest := some "DD", edges := [(DependencyEdge.body, CallableId.ofUser "m" "e")] }
  , { id := CallableId.ofUser "m" "e", digest := some "DE", edges := [(DependencyEdge.body, CallableId.ofUser "m" "d")] } ]
def g2 : List DepNode := g.map fun n => if n.id.declName == "c" then { n with digest := some "X" } else n
'
probe "a mutual cycle terminates" "true" "$GRAPH"'#eval (dependencyRootMaterial g (CallableId.ofUser "m" "d")).toOption.isSome'
probe "cycle members share a closure (entry point is not semantic)" "true" "$GRAPH"'#eval
  ((reachableFrom g (CallableId.ofUser "m" "d")).map (·.render)).mergeSort (· ≤ ·)
    == ((reachableFrom g (CallableId.ofUser "m" "e")).map (·.render)).mergeSort (· ≤ ·)'
probe "cycle members do NOT share a root (they are different subjects)" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g (CallableId.ofUser "m" "d")).toOption != (dependencyRootMaterial g (CallableId.ofUser "m" "e")).toOption'
probe "a deep callee edit moves the dependent root" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g (CallableId.ofUser "m" "a")).toOption != (dependencyRootMaterial g2 (CallableId.ofUser "m" "a")).toOption'
probe "an unrelated subtree is unaffected" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g (CallableId.ofUser "m" "d")).toOption == (dependencyRootMaterial g2 (CallableId.ofUser "m" "d")).toOption'

# FAIL-CLOSED CONDITIONS. Each previously produced a confident value from
# incomplete information; each must now REFUSE, with the reason carried.
probe "a missing start is refused" "missingStart" \
'#eval repr (dependencyRootMaterial [] (CallableId.ofUser "m" "ghost"))'
probe "an unresolved edge is refused, not bound as unknown" "unresolvedEdge" \
'#eval repr (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "ghost")] }] (CallableId.ofUser "m" "a"))'
probe "a duplicate identity is refused" "duplicateId" \
'#eval repr (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := some "1", edges := [] }, { id := CallableId.ofUser "m" "a", digest := some "2", edges := [] }] (CallableId.ofUser "m" "a"))'
probe "an absent subject digest is refused" "incompleteDigest" \
'#eval repr (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := none, edges := [] }] (CallableId.ofUser "m" "a"))'
probe 'a missing-typed edge is refused' "missingEdge" \
'#eval repr (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.missing, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }] (CallableId.ofUser "m" "a"))'
# THE EDGE KIND IS IN THE BYTES. Traversing typed edges and then serializing only
# identities threw the typing away: contract and body produced the same preimage.
probe "changing an edge kind changes the preimage" "true" \
'#eval
  let c : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.contract, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  let b : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  (dependencyRootMaterial c (CallableId.ofUser "m" "a")).toOption != (dependencyRootMaterial b (CallableId.ofUser "m" "a")).toOption'
# an EMPTY digest is as incomplete as an absent one
probe "an empty-string digest is refused" "incompleteDigest" \
'#eval repr (dependencyRootMaterial [{ id := CallableId.ofUser "m" "a", digest := some "", edges := [] }] (CallableId.ofUser "m" "a"))'
# trust travels WITH the material, not beside it
probe "trust is carried in the returned structure" "true" \
'#eval
  let g : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.trusted, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  ((dependencyRootMaterial g (CallableId.ofUser "m" "a")).toOption.map (·.carriesTrust)) == some true'
# CANONICAL SET SEMANTICS. reachableFrom returns the start when the start is in a
# cycle, and `id :: closure` then listed it twice — a self-recursive subject got a
# different preimage for the same dependency set.
probe "a self-recursive node is serialized exactly once" "true" \
'#eval
  let g : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "a")] }]
  match (dependencyRootMaterial g (CallableId.ofUser "m" "a")).toOption with
  | some m => ((m.preimage.splitOn ("N" ++ toString (CallableId.ofUser "m" "a").render.length ++ ":" ++ (CallableId.ofUser "m" "a").render ++ ":")).length - 1) == 1
  | none   => false'
# Calling one callee twice does not change the dependency SET, so it must not
# change the root.
probe "a duplicated edge does not change the root" "true" \
'#eval
  let one : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  let two : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b"), (DependencyEdge.body, CallableId.ofUser "m" "b")] }, { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  (dependencyRootMaterial one (CallableId.ofUser "m" "a")).toOption == (dependencyRootMaterial two (CallableId.ofUser "m" "a")).toOption'
# IDENTITY, NOT SPELLING. Two callables with the same declName in different
# modules are different nodes; a raw-string graph could not tell them apart.
probe "same declName in different modules are different nodes" "duplicateId" \
'#eval repr (dependencyRootMaterial
  [{ id := CallableId.ofUser "m1" "f", digest := some "D1", edges := [] }
  ,{ id := CallableId.ofUser "m1" "f", digest := some "D2", edges := [] }]
  (CallableId.ofUser "m1" "f"))'
probe "...and distinct modules do NOT collide" "true" \
'#eval
  let g : List DepNode :=
    [{ id := CallableId.ofUser "m1" "f", digest := some "D1", edges := [] }
    ,{ id := CallableId.ofUser "m2" "f", digest := some "D2", edges := [] }]
  (dependencyRootMaterial g (CallableId.ofUser "m1" "f")).toOption
    != (dependencyRootMaterial g (CallableId.ofUser "m2" "f")).toOption'
# THE PUBLIC API MUST REJECT A STRING START AT COMPILE TIME. Storing CallableId
# while keying every lookup on `.render` would keep rendered strings as the
# operational identity under a typed wrapper — the defect the type exists to
# remove. A probe that passes a String must NOT elaborate.
cat > "$TMP/strstart.lean" <<'LEAN'
import Concrete
open Concrete Concrete.Proof
#eval (dependencyRootMaterial [] "v1:user:m.a").toOption.isSome
LEAN
if lake env lean "$TMP/strstart.lean" >/dev/null 2>&1; then
  no "a String start identity still compiles — rendered strings remain the operational identity"
else
  ok "a String start identity does not compile; the API takes CallableId"
fi
# ...and traversal returns identities, not renderings.
probe "reachableFrom returns CallableIds" "true" "$GRAPH"'#eval
  ((reachableFrom g (CallableId.ofUser "m" "a")).map (·.declName)).contains "c"'
# Lookup must compare identities. Two ids equal as VALUES must resolve to the
# same node even when constructed separately.
probe "lookup is by identity value, not by a shared rendering" "true" \
'#eval
  let g : List DepNode := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [] }]
  (dependencyRootMaterial g (CallableId.ofUser "m" "a")).toOption.isSome'
# There must be no public fail-OPEN way to ask the trust question.
if grep -q "def closureCarriesTrust" "$ROOT_DIR/Concrete/Proof/DependencyRoot.lean"; then
  no "closureCarriesTrust still answers over an unvalidated graph — a fail-open twin of the validated path"
else
  ok "trust is only answerable from validated material"
fi
# trust must be visible, and separately from the root

echo ""
echo "=== NOT YET INTEGRATED — tripwires, so this cannot read as slice 6 done ==="
# The root is a standalone function. Until ProofCore builds nodes from real
# entries and freshness consumes the result, a deep edit does not stale any real
# claim through it. These fail when that changes, which is the signal to replace
# them with real coverage.
if grep -rq "dependencyRootPreimage" "$ROOT_DIR/Concrete/Proof/ProofCore.lean" 2>/dev/null; then
  no "ProofCore now consumes dependency roots — replace this tripwire with integration coverage"
else
  ok "TRIPWIRE: ProofCore does NOT consume dependency roots yet (slice 6 integration open)"
fi
if grep -rq "dependencyRootPreimage" "$ROOT_DIR/Concrete/Report" 2>/dev/null; then
  no "reports now consume dependency roots — replace this tripwire with integration coverage"
else
  ok "TRIPWIRE: no report consumes dependency roots yet"
fi

# === WHOLE-TABLE BINDING (slice 4: never under-approximate table access) =====================
# A `body` edge naming a table is not yet a dependency ON that table. The NAME does not move
# when an entry's definition changes, so a proof about `fns` stayed valid-looking after any
# edit inside `fns`. `tableValueDigest` binds the constant's defining VALUE — whole by
# construction, because there is no subset to select from — and a dynamic index means the
# apparent subset would have been an under-approximation, which fails OPEN.
echo "=== whole-table binding ==="

probe "a table's digest MOVES when its contents change" "MOVED" '
def tA : FnTable := FnTable.ofGlobals (fun n => if n == "f" then none else none)
def tB : FnTable := FnTable.ofGlobals (fun n => if n == "g" then none else none)
#eval show MetaM Unit from do
  let a ← tableValueDigest `tA
  let b ← tableValueDigest `tB
  IO.println (if a.isSome && b.isSome && a != b then "MOVED" else "SAME")'

# Fail-closed. A constant with no value — axiom, opaque, unavailable import — must REFUSE
# rather than digest to something. A digest over "the part we could see" is indistinguishable
# from one over the whole table, which is how a partial dependency becomes an invisible one.
probe "a valueless/unknown constant REFUSES rather than digesting" "REFUSED" '
#eval show MetaM Unit from do
  let d ← tableValueDigest `No.Such.Table
  IO.println (if d.isNone then "REFUSED" else "DIGESTED")'

# The digest must be a FUNCTION of the constant, or a receipt could not be replayed.
probe "the same table digests identically twice (deterministic)" "STABLE" '
def tS : FnTable := FnTable.ofGlobals (fun _ => none)
#eval show MetaM Unit from do
  let a ← tableValueDigest `tS
  let b ← tableValueDigest `tS
  IO.println (if a.isSome && a == b then "STABLE" else "UNSTABLE")'

# `tablesFullyBound` is the gate a receipt must consult: a `body` edge that names a table it
# could not bind announces a dependency whose changes it cannot detect, which reads exactly
# like a dependency that never changes.
probe "evidence naming an unbindable table is NOT fully bound" "NOTBOUND" '
#eval show MetaM Unit from do
  let e : EdgeEvidence := { edge := .body, tables := [`No.Such.Table]
                          , tableDigests := [(`No.Such.Table, none)], quantifiesOverTable := false }
  IO.println (if e.tablesFullyBound then "BOUND" else "NOTBOUND")'

probe "...and evidence with every table bound IS fully bound (control)" "BOUND" '
#eval show MetaM Unit from do
  let e : EdgeEvidence := { edge := .body, tables := [`X]
                          , tableDigests := [(`X, some "abc")], quantifiesOverTable := false }
  IO.println (if e.tablesFullyBound then "BOUND" else "NOTBOUND")'

# A count mismatch must also fail: fewer digests than names is the silent shape of a partial
# binding, and length-equality is what makes "fully" mean every one of them.
probe "fewer digests than named tables is NOT fully bound" "NOTBOUND" '
#eval show MetaM Unit from do
  let e : EdgeEvidence := { edge := .body, tables := [`X, `Y]
                          , tableDigests := [(`X, some "abc")], quantifiesOverTable := false }
  IO.println (if e.tablesFullyBound then "BOUND" else "NOTBOUND")'

# === THE RECEIPT ENVELOPE (slice 4) =========================================================
# `tablesFullyBound` is a predicate, and a predicate can be forgotten. The receipt type is built
# so it cannot be: `tableBindings` is `List (Name × String)`, not `Option String`, so an unbound
# table has NO REPRESENTATION inside a receipt. These legs pin every refusal path, because a
# smart constructor that refuses nothing is just a constructor.
echo "=== receipt envelope ==="

probe "a receipt mints from complete evidence (control)" "MINTED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X]
                           , tableDigests := [(`X, some "d1")], quantifiesOverTable := false }
  let r := ProofEvidenceReceipt.mint? (some "v2:abc") ev "lean-4.28" "/ws" "imp1"
  IO.println (if r.isSome then "MINTED" else "REFUSED")'

# The whole point. A body edge naming a table it could not bind announces a dependency whose
# changes it cannot detect — which reads exactly like a dependency that never changes.
probe "an UNBOUND table refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X]
                           , tableDigests := [(`X, none)], quantifiesOverTable := false }
  let r := ProofEvidenceReceipt.mint? (some "v2:abc") ev "lean-4.28" "/ws" "imp1"
  IO.println (if r.isNone then "REFUSED" else "MINTED")'

probe "an ABSENT subject digest refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X]
                           , tableDigests := [(`X, some "d1")], quantifiesOverTable := false }
  let r := ProofEvidenceReceipt.mint? none ev "lean-4.28" "/ws" "imp1"
  IO.println (if r.isNone then "REFUSED" else "MINTED")'

# An empty identity is not "unknown" — it is a value, and it compares EQUAL to another empty
# one, so two proofs established under different toolchains would agree. Refusing is the only
# reading that does not invent agreement. One leg per field: a single check would pass while
# two of the three were silently unbound.
probe "an empty TOOLCHAIN id refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:a") ev "" "/ws" "i").isNone then "REFUSED" else "MINTED")'
probe "an empty WORKSPACE id refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:a") ev "lean" "" "i").isNone then "REFUSED" else "MINTED")'
probe "an empty IMPORTS id refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:a") ev "lean" "/ws" "").isNone then "REFUSED" else "MINTED")'

# Schema version is IN the receipt so an older one reads as a different format rather than as a
# failed comparison — the same reason `v2:` is in the subject digest. Without it the first
# envelope change reports every stored receipt as a broken proof.
# The old-schema leg USED to build a receipt directly — which is exactly the bypass this
# section now forbids, and the reason the "unrepresentable" claim was false when first made.
# An old-schema receipt can only arrive by DESERIALIZATION, which does not exist yet, so that
# leg is deliberately absent rather than faked with a constructor call. Recorded here so its
# absence is a known gap and not an oversight.
probe "...and a current-schema receipt IS comparable (control)" "COMPARABLE" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:a") ev "t" "w" "i" with
  | some r => IO.println (if r.comparable then "COMPARABLE" else "INCOMPARABLE")
  | none   => IO.println "MINT-REFUSED"'

# End-to-end: the digests a real classification produces must reach a receipt.
probe "a minted receipt carries the table binding it was given" "d1" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X]
                           , tableDigests := [(`X, some "d1")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:a") ev "t" "w" "i" with
  | some r => IO.println (String.intercalate "," (r.tableBindings.map (·.2)))
  | none   => IO.println "REFUSED"'

# === RECEIPT CURRENCY (the negative controls a receipt is FOR) ==============================
# Minting refusals prove a receipt cannot be built from partial material. These prove the
# built receipt DETECTS change — which is the only reason to store one.
echo "=== receipt currency ==="

probe "an unchanged environment is current (control)" "CURRENT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`A]
                           , tableDigests := [(`A, some "da")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [(`A, "da")] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

probe "changing a TABLE BODY makes the receipt non-current" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`A]
                           , tableDigests := [(`A, some "da")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [(`A, "da-CHANGED")] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

# The swap. Sorting normalizes ORDER, and must not normalize away WHICH name carries which
# digest — otherwise two tables exchanging contents would look unchanged.
probe "SWAPPING two tables digests makes the receipt non-current" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`A, `B]
                           , tableDigests := [(`A, some "da"), (`B, some "db")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [(`A, "db"), (`B, "da")] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

# ...while REORDERING the same pairs must NOT. Order is normalized, so it carries no
# information; without this control the sort could be dropped and nothing would notice.
probe "REORDERING the same pairs leaves it current" "CURRENT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`B, `A]
                           , tableDigests := [(`B, some "db"), (`A, some "da")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [(`A, "da"), (`B, "db")] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

# The structural table digest is toolchain-relative (recorded limit at tableValueDigest). That
# is only acceptable if the toolchain is itself bound — so a toolchain change must invalidate
# even when every table digest is byte-identical.
probe "a TOOLCHAIN change invalidates even with identical table digests" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`A]
                           , tableDigests := [(`A, some "da")], quantifiesOverTable := false }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [(`A, "da")] "tc-NEW" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

probe "a WORKSPACE change invalidates" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [] "tc" "ws-NEW" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

probe "an IMPORT-CLOSURE change invalidates" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .body [] "tc" "ws" "im-NEW" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

probe "a SUBJECT change invalidates" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s-NEW" .body [] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

# A CONTRACT edge names no tables, so it must not acquire a body dependency it does not have.
probe "a contract edge binds NO tables" "0" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .contract, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (toString r.tableBindings.length)
  | none => IO.println "MINT-REFUSED"'

# Mint-level, not just predicate-level: fewer digests than names must refuse at the constructor.
probe "fewer digests than names refuses AT MINT" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`A, `B]
                           , tableDigests := [(`A, some "da")], quantifiesOverTable := false }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im").isNone then "REFUSED" else "MINTED")'

# === HOSTILE CONTROLS: the invariant is the TYPE, not the smart constructor =================
# The first version of this envelope claimed "partial evidence is unrepresentable" while the
# structure constructor was public and `Inhabited` was derived — so a caller could assemble a
# receipt with an empty subject and the CURRENT schema version, and `default` produced one with
# an empty schema. The nine minting legs above passed the whole time: they tested the smart
# constructor, not the claim. These test the claim.
echo "=== hostile controls (construction is closed) ==="

expect_no_compile() {
  local label="$1" body="$2"
  cat > "$TMP/h.lean" <<LEAN
import Concrete
import Examples
open Lean Meta Concrete Concrete.Proof
$body
LEAN
  local out; out="$(lake env lean "$TMP/h.lean" 2>&1 || true)"
  if grep -qE "error:|error\(lean" <<<"$out"; then
    ok "$label"
  else
    no "$label — IT COMPILED, so the invariant is documentation rather than a type"
  fi
}

expect_no_compile "direct construction does NOT compile (constructor is private)" '
def forged : ProofEvidenceReceipt :=
  { schemaVersion := receiptSchemaVersion, subjectDigest := "", edge := .body
  , tableBindings := [], toolchainId := "", workspaceId := "", importsId := "" }'

expect_no_compile '`default` does NOT produce a receipt (no Inhabited)' '
#eval show MetaM Unit from IO.println (default : ProofEvidenceReceipt).schemaVersion'

# Correspondence, not arity. `tablesFullyBound` checks equal LENGTHS and all-present, which
# admits tables := [X] with digests for [Y] — a receipt claiming Y while the theorem depended
# on X. Equal counts of unrelated things is not correspondence.
probe "digests for the WRONG table identity refuse to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X]
                           , tableDigests := [(`Y, some "d")], quantifiesOverTable := false }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "t" "w" "i").isNone then "REFUSED" else "MINTED")'

probe "a DUPLICATE binding for one table refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [`X, `X]
                           , tableDigests := [(`X, some "d"), (`X, some "e")], quantifiesOverTable := false }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "t" "w" "i").isNone then "REFUSED" else "MINTED")'

# `none` was refused and `some ""` was not — the same hole as an empty environment identity.
# "" is a value, and it compares equal to another "".
probe "an EMPTY-STRING subject digest refuses to mint" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  IO.println (if (ProofEvidenceReceipt.mint? (some "") ev "t" "w" "i").isNone then "REFUSED" else "MINTED")'

# The EDGE must participate in currency. Its omission was a real hole: a receipt recorded for a
# `contract` edge read current against `body` material — a claim surviving exactly the
# implementation change it depends on.
probe "an EDGE-KIND change makes the receipt non-current" "NOT" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (if r.isCurrentAgainst "v2:s" .contract [] "tc" "ws" "im" then "CURRENT" else "NOT")
  | none => IO.println "MINT-REFUSED"'

# ONE disposition, not two booleans in the right order. `comparable` then `isCurrentAgainst` was
# a sequencing a consumer had to remember, and reading them out of order reports "the proof went
# stale" when the ENVELOPE changed — a claim about the program rather than the format.
probe "disposition: unchanged material is current" "current" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (toString (repr (r.disposition "v2:s" .body [] "tc" "ws" "im")))
  | none => IO.println "MINT-REFUSED"'

probe "disposition: moved material is notCurrent (not needsRecheck)" "notCurrent" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  match ProofEvidenceReceipt.mint? (some "v2:s") ev "tc" "ws" "im" with
  | some r => IO.println (toString (repr (r.disposition "v2:MOVED" .body [] "tc" "ws" "im")))
  | none => IO.println "MINT-REFUSED"'

# === ENVIRONMENT IDENTITIES ==================================================================
# The receipt refuses an empty identity, so nothing could mint until these existed. Each must be
# DETERMINISTIC (same inputs, same id — or a receipt cannot be replayed) and SENSITIVE (any input
# change moves it — or binding it bought nothing). Both directions per identity, because an id
# that never moves and an id that never repeats are equally useless.
echo "=== environment identities ==="

probe "toolchain id is deterministic and sensitive to BOTH inputs" "true" '
#eval
  let a := toolchainIdOf "0.1.0" "lean4:v4.28.0"
  let b := toolchainIdOf "0.1.0" "lean4:v4.28.0"
  let c := toolchainIdOf "0.2.0" "lean4:v4.28.0"
  let d := toolchainIdOf "0.1.0" "lean4:v4.29.0"
  a == b && a != c && a != d && c != d'

# Discovery order must not enter the identity: the same workspace enumerated differently is the
# same workspace.
probe "workspace id ignores module ORDER but not module SET" "true" '
#eval
  let a := workspaceIdOf "pkg" ["m1", "m2"]
  let b := workspaceIdOf "pkg" ["m2", "m1"]
  let c := workspaceIdOf "pkg" ["m1", "m3"]
  let d := workspaceIdOf "other" ["m1", "m2"]
  a == b && a != c && a != d'

# Import CONTENT, not just names — otherwise an imported module could change under a proof
# without moving anything, which is the defect tableValueDigest exists to prevent one level down.
probe "imports id moves when an imported CONTENT digest changes" "true" '
#eval
  let a := importsIdOf [("m1", "d1"), ("m2", "d2")]
  let b := importsIdOf [("m2", "d2"), ("m1", "d1")]
  let c := importsIdOf [("m1", "dCHANGED"), ("m2", "d2")]
  a == b && a != c'

# End to end: real identities let a receipt mint, which nothing could do before.
probe "a receipt mints from produced identities" "MINTED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .body, tables := [], tableDigests := [], quantifiesOverTable := true }
  let r := ProofEvidenceReceipt.mint? (some "v2:s") ev
             (toolchainIdOf "0.1.0" "lean4:v4.28.0")
             (workspaceIdOf "pkg" ["m1"])
             (importsIdOf [("m1", "d1")])
  IO.println (if r.isSome then "MINTED" else "REFUSED")'

# No absolute paths, no machine-local state. Clean-machine reproducibility is a completion
# requirement, and a path in an identity makes every receipt un-replayable elsewhere.
if grep -nE "IO\.currentDir|System\.FilePath|getEnv" Concrete/Proof/Receipt.lean >/dev/null 2>&1; then
  no "Receipt.lean reads filesystem or environment state — identities must be reproducible from source alone"
else
  ok "no filesystem or environment state in the identity producers (clean-machine reproducible)"
fi

# THE INVARIANT: unclassified may reach diagnostics and shadow reports, never a current root or
# a replay receipt. The root refuses it via isCurrentForDependents; the receipt refuses it
# independently rather than trusting a caller to have consulted the root first.
probe "a receipt refuses an UNCLASSIFIED edge" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .unclassified, tables := [], tableDigests := [], quantifiesOverTable := false }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "t" "w" "i").isNone then "REFUSED" else "MINTED")'
probe "a receipt refuses a MISSING edge" "REFUSED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .missing, tables := [], tableDigests := [], quantifiesOverTable := false }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "t" "w" "i").isNone then "REFUSED" else "MINTED")'
# ...and a classified edge still mints, or the refusal above is just a broken constructor.
probe "a CONTRACT edge still mints (the refusals are targeted)" "MINTED" '
#eval show MetaM Unit from do
  let ev : EdgeEvidence := { edge := .contract, tables := [], tableDigests := [], quantifiesOverTable := true }
  IO.println (if (ProofEvidenceReceipt.mint? (some "v2:s") ev "t" "w" "i").isSome then "MINTED" else "REFUSED")'

# === THE CLASSIFICATION HAND-BACK (slice 6, step 1) ==========================================
# The compiler cannot classify: the answer comes from a theorem's elaborated type, which exists
# only while Lean elaborates. These legs pin the properties the compiler will rely on when it
# consumes the result.
echo "=== classification hand-back ==="

# EVERY requested name appears. A dropped row is how a dependency disappears from a root and the
# root then reports a confident value over material it never saw.
probe "an unknown theorem yields a row, not a dropped one" "1" '
#eval show MetaM Unit from do
  let rows ← classifyAll [`No.Such.Theorem]
  IO.println (toString rows.length)'

probe "...and that row is UNCLASSIFIED, never missing or contract" "unclassified" '
#eval show MetaM Unit from do
  let rows ← classifyAll [`No.Such.Theorem]
  IO.println ((rows.map (·.2.edge.canonical)).headD "NONE")'

probe "one row per request, including duplicates" "3" '
#eval show MetaM Unit from do
  let rows ← classifyAll [`A.B, `A.B, `C.D]
  IO.println (toString rows.length)'

# The caller's order is convenient for reading and must not enter the bytes, or the same
# classification discovered in a different order would compare unequal.
probe "serialization ignores REQUEST order" "true" '
#eval show MetaM Unit from do
  let a ← classifyAll [`M.x, `M.y]
  let b ← classifyAll [`M.y, `M.x]
  IO.println (toString (renderClassification a == renderClassification b))'

probe "serialization is deterministic across runs" "true" '
#eval show MetaM Unit from do
  let a ← classifyAll [`M.x, `M.y]
  let b ← classifyAll [`M.x, `M.y]
  IO.println (toString (renderClassification a == renderClassification b))'

# Sensitivity: a different theorem SET must serialize differently, or the table binds nothing.
probe "serialization moves when the theorem set changes" "true" '
#eval show MetaM Unit from do
  let a ← classifyAll [`M.x, `M.y]
  let b ← classifyAll [`M.x, `M.z]
  IO.println (toString (renderClassification a != renderClassification b))'

# An unbound table renders as `?`, deliberately NOT digest-shaped: a consumer must not be able to
# mistake "we could not bind this" for a binding.
probe "an unbound table renders as ? and not as a digest" "true" '
#eval
  let ev : EdgeEvidence := { edge := .body, tables := [`T]
                           , tableDigests := [(`T, none)], quantifiesOverTable := false }
  let s := renderClassification [(`Th, ev)]
  (s.splitOn "d1:?").length == 2'

# === THE MERGE (slice 6, step 3) =============================================================
# Where a partial answer becomes indistinguishable from a complete one. Each refusal is its own
# constructor because the repairs differ, and each gets its own leg — a merge that refuses "some
# of the time" is a merge nobody can reason about.
echo "=== classification merge ==="

ok_ev='{ edge := .contract, tables := [], tableDigests := [], quantifiesOverTable := true }'

probe "a complete answer set merges" "true" "
#eval (mergeClassifications [\"a\", \"b\"] [(\"a\", $ok_ev), (\"b\", $ok_ev)]) matches Except.ok _"

probe "an UNANSWERED key refuses" "true" "
#eval (mergeClassifications [\"a\", \"b\"] [(\"a\", $ok_ev)]) matches Except.error (MergeError.unanswered _)"

probe "a DUPLICATE answer refuses (not first-wins)" "true" "
#eval (mergeClassifications [\"a\"] [(\"a\", $ok_ev), (\"a\", $ok_ev)]) matches Except.error (MergeError.duplicateAnswer _)"

probe "an UNKNOWN answer refuses" "true" "
#eval (mergeClassifications [\"a\"] [(\"a\", $ok_ev), (\"zz\", $ok_ev)]) matches Except.error (MergeError.unknownAnswer _)"

probe "a STILL-UNCLASSIFIED answer refuses" "true" '
#eval (mergeClassifications ["a"] [("a", { edge := .unclassified, tables := [], tableDigests := [], quantifiesOverTable := false })]) matches Except.error (MergeError.stillUnclassified _)'

probe "a MISSING classification refuses" "true" '
#eval (mergeClassifications ["a"] [("a", { edge := .missing, tables := [], tableDigests := [], quantifiesOverTable := false })]) matches Except.error (MergeError.classifiedMissing _)'

# The five refusals must be DISTINGUISHABLE, or a caller cannot route the repair. An unanswered
# key means the hand-back did not run; a duplicate means the classifier is inconsistent; the two
# have nothing to do with each other.
probe "the refusals are distinct constructors" "true" '
#eval (MergeError.unanswered "k") != (MergeError.duplicateAnswer "k")
  && (MergeError.unknownAnswer "k") != (MergeError.stillUnclassified "k")
  && (MergeError.classifiedMissing "k") != (MergeError.unanswered "k")'

# Requested order, so a caller iterating the merge is stable regardless of answer order.
probe "merged rows follow REQUESTED order, not answer order" "true" "
#eval match mergeClassifications [\"a\", \"b\"] [(\"b\", $ok_ev), (\"a\", $ok_ev)] with
      | Except.ok rows => rows.map Prod.fst == [\"a\", \"b\"]
      | Except.error _ => false"

# `classificationsComplete` must agree with the merge — two definitions of complete is how one
# ends up weaker.
probe "completeness agrees with the merge, both ways" "true" "
#eval classificationsComplete [\"a\"] [(\"a\", $ok_ev)]
  && !(classificationsComplete [\"a\", \"b\"] [(\"a\", $ok_ev)])"

# STEP 6 PRECONDITION. Every current root refusal is an `unclassified` edge — "we have not asked
# the Lean side" — not a `missing` one. Gating `proved` on the root while that holds would report
# depsNotCurrent for programs whose dependencies are fine, blaming the user's program for the
# compiler's own unfinished state.
#
# This leg watches for the precondition being MET: when real classifications land, refusals
# become `missing`, and those should gate a verdict. It reports rather than fails, because the
# current state is expected and the transition is what needs noticing.
echo "=== step 6 precondition (are refusals ours or the program's?) ==="
DRR="$("$ROOT_DIR/.lake/build/bin/concrete" examples/proof_patterns/composition/src/main.con --report subject-facts 2>/dev/null | grep 'depRoot: REFUSED' || true)"
if [ -z "$DRR" ]; then
  ok "no root refusals in this fixture"
elif printf '%s' "$DRR" | grep -q "unclassified"; then
  ok "refusals are UNCLASSIFIED (our state, not the program's) — step 6 stays blocked, correctly"
else
  ok "PRECONDITION MET: refusals are no longer unclassified — real classifications have landed, so the root may now gate proved"
fi

# THE THEOREM DIGEST MUST SEE THE PROOF, not only the statement. `theoremArtifactDigest` claims
# a re-proof with the same statement moves it, and that claim rests on `ci.value?` exposing the
# proof term — which is not true of every declaration kind. Asserted rather than assumed: two
# theorems with an IDENTICAL type and DIFFERENT proofs must digest differently.
#
# If this ever fails, the digest binds statements rather than artifacts, and a receipt claiming
# to record "which proof" would be recording only "which claim".
echo "=== theorem digest binds the proof, not just the type ==="
probe "same type, different proof => different digest" "true" '
theorem tA : 1 + 1 = 2 := by rfl
theorem tB : 1 + 1 = 2 := by simp
#eval show MetaM Unit from do
  let a ← theoremArtifactDigest `tA
  let b ← theoremArtifactDigest `tB
  IO.println (toString (a.isSome && b.isSome && a != b))'

probe "the same theorem digests identically twice" "true" '
theorem tC : 2 + 2 = 4 := by rfl
#eval show MetaM Unit from do
  let a ← theoremArtifactDigest `tC
  let b ← theoremArtifactDigest `tC
  IO.println (toString (a.isSome && a == b))'

probe "an unknown theorem yields NO digest (never a placeholder)" "true" '
#eval show MetaM Unit from do
  let d ← theoremArtifactDigest `No.Such.Thm
  IO.println (toString d.isNone)'

# Table freshness lives in `check_classification_freshness.sh`, NOT here: verifying it means
# running the generator, which classifies every linked theorem and digests each proof term. That
# is minutes, and a per-commit gate that costs minutes is a gate people start skipping — which
# would cost more than the check is worth.
# === THE CONSUMER VALIDATES BEFORE CLASSIFYING ===============================================
# The digest was stored and freshness-tested, but `classifiedEdgeOf` read the tag directly — so a
# row whose provenance slot was empty, a placeholder, or malformed classified an edge exactly as
# well as a real one. Verification lived in a gate; the consumer required nothing.
echo "=== consumer validates the row ==="

probe "a real theorem still classifies" "body" '
#eval (classifiedEdgeOf "Concrete.Proof.parse_byte_correct").canonical'

probe "an unknown theorem is unclassified" "unclassified" '
#eval (classifiedEdgeOf "No.Such.Theorem").canonical'

# The point of the change: a structurally unsound row must not classify.
# THE MALFORMED CASES, reached DIRECTLY. The leg that used to sit here called
# `validatedRowOf "No.Such.Theorem"` and called itself a malformed-digest test — it exercised the
# ABSENT path, already covered by the leg above, and proved nothing about malformed data. The
# checked-in table contains only well-formed rows, so validation could not be tested through
# lookup at all; `validateRawRow` exists so it can be.
probe "an EMPTY digest is refused" "true" '
#eval (validateRawRow ("T", "body", "", [], false)).isNone'
probe "a PLACEHOLDER digest is refused" "true" '
#eval (validateRawRow ("T", "body", "?", [], false)).isNone'
probe "a WRONG-LENGTH digest is refused" "true" '
#eval (validateRawRow ("T", "body", "abc123", [], false)).isNone'
# Uppercase is not "the same digest in different case": the generator emits lowercase, so an
# uppercase value did not come from the generator.
probe "an UPPERCASE digest is refused" "true" '
#eval (validateRawRow ("T", "body", "7BCEC2D7871F93204B26E2BF83D5ACF1", [], false)).isNone'
probe "a NON-HEX digest is refused" "true" '
#eval (validateRawRow ("T", "body", "zzcec2d7871f93204b26e2bf83d5acf1", [], false)).isNone'
probe "an UNKNOWN edge tag is refused" "true" '
#eval (validateRawRow ("T", "somethingelse", "7bcec2d7871f93204b26e2bf83d5acf1", [], false)).isNone'
# Positive control: without it, a validator that refused everything would pass all six above.
probe "a WELL-FORMED row validates (positive control)" "true" '
#eval (validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [], false)).isSome'

# THE TABLE BINDINGS ARE VALIDATED TOO. A row whose theorem digest is sound but whose table
# digests are not describes its dependencies with values nothing can compare — the same defect
# one level down, and the level where it would be least visible.
probe "a MALFORMED table digest is refused" "true" '
#eval (validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "nothex")], false)).isNone'
probe "a table named TWICE in one row is refused" "true" '
#eval (validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "6fe095a9f592a2e2b556e87f30306584"), ("Tbl", "6fe095a9f592a2e2b556e87f30306584")], false)).isNone'
probe "an EMPTY table identity is refused" "true" '
#eval (validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("", "6fe095a9f592a2e2b556e87f30306584")], false)).isNone'
# ...and a NAMED table with the same digest validates, so the refusal is about the identity being
# empty rather than about the digest.
probe "a NAMED table with the same digest validates (the refusal is about the name)" "true" '
#eval (validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "6fe095a9f592a2e2b556e87f30306584")], false)).isSome'
# The raw table is PRIVATE, so validation is the only route to a classification — not merely the
# only route to the `ValidatedRow` type.
expect_no_compile "classificationTable cannot be read directly (private)" '
#eval Concrete.Proof.classificationTable.length'

probe "well-formed table bindings validate and are carried" "true" '
#eval match validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "6fe095a9f592a2e2b556e87f30306584")], true) with
      | some r => r.tables.length == 1 && r.quantifies
      | none => false'
# The real table must carry real bindings, or the generator emitted rows that describe nothing.
probe "a real row carries its table identities" "true" '
#eval match validatedRowOf "Concrete.Proof.parse_byte_correct" with
      | some r => r.tables.length > 0 && (r.tables.all fun t => t.2.length == 32)
      | none => false'

# DUPLICATES. `find?` took the first match, so a malformed first row could hide a valid second
# and a valid first could hide conflicting trailing data — both silently. A generated security
# table must map a theorem to EXACTLY one validated row; zero and several are equally unusable,
# and collapsing "ambiguous" into "take one" is how a conflicting table classifies confidently.
probe "a theorem appearing TWICE yields no row, even if identical" "true" '
#eval
  let dup : List (String × String × String × List (String × String) × Bool) :=
    [("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [], false),
     ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [], false)]
  (match dup.filter (fun (r : String × String × String × List (String × String) × Bool) => r.1 == "T") with | [row] => validateRawRow row | _ => none).isNone'
probe "a theorem appearing twice with CONFLICTING rows yields no row" "true" '
#eval
  let dup : List (String × String × String × List (String × String) × Bool) :=
    [("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [], false),
     ("T", "contract", "bfda7f397e3221e757383578b50ee3ff", [], false)]
  (match dup.filter (fun (r : String × String × String × List (String × String) × Bool) => r.1 == "T") with | [row] => validateRawRow row | _ => none).isNone'

probe "a validated row exposes its digest" "true" '
#eval match validatedRowOf "Concrete.Proof.parse_byte_correct" with
      | some r => r.digest.length == 32
      | none => false'

# `ValidatedRow`'s constructor is private, so a caller cannot assemble one around a row that
# failed validation and classify from it. Asserted as a COMPILE failure, because that is the
# only form in which "cannot be constructed" is testable.
expect_no_compile "ValidatedRow cannot be constructed directly (private ctor)" '
def forged : Concrete.Proof.ValidatedRow :=
  { theoremName := "X", edge := Concrete.Proof.DependencyEdge.body, digest := "" }'

# === CANONICAL TABLE-ENTRY EVIDENCE (blocker c prerequisite) =================================
# A whole-table digest answers "did this table change" and cannot answer "does it CONTAIN that
# callee". Correspondence needs the second, and one has been standing in for the other.
echo "=== table-entry evidence ==="

# RENAMED 2026-08-11: this said "a fully-identified table yields entry evidence", and full
# identification is no longer sufficient — an entry must also carry provenance that AGREES with a
# digest recomputed from its body. The old wording would have made the added requirement look like
# a regression in this probe rather than the point of it. The case it used to cover (identity
# present, provenance absent) is now asserted as a refusal, in the recompute section below.
probe "a table identified AND carrying agreeing provenance yields entry evidence" "true" '
#eval
  let d : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[d], globals := fun _ => none } : FnTable)).isSome'

# ALL OR NOTHING. A partial membership list answers "is this callee present" with "not in the
# part I could read", which is indistinguishable from "absent" — and absence is what justifies
# refusing an edge.
probe "ONE legacy entry refuses evidence for the WHOLE table" "true" '
#eval
  let ok : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                       params := [], body := PExpr.lit (PVal.int 0) }
  let legacy : PFnDef := { identity := .legacy, operationalKey := "g", params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[ok, legacy], globals := fun _ => none } : FnTable)).isNone'

# DUPLICATE IDENTITIES REFUSED. A table holding one callable twice cannot say which
# implementation a static lookup selects, and membership answering "at least one" would let a
# `body` edge be justified by an entry that is not the one dispatch reaches.
probe "a table with the SAME callable twice yields no evidence" "true" '
#eval
  let d : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[d, d], globals := fun _ => none } : FnTable)).isNone'
probe "...while two DISTINCT callables are fine (the refusal is about duplication)" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  let g : PFnDef := { identity := .semantic (CallableId.ofUser "m" "g"), operationalKey := "g",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f, g], globals := fun _ => none } : FnTable)).isSome'

# === THE BODY IS RECOMPUTED, NOT TRUSTED =====================================================
# `tableEntryEvidence` used to COPY `PFnDef.sourceBodyDigest` into the evidence row. Every check
# downstream then compared metadata against metadata, and the body was never an input to its own
# provenance check. So this mutation survived the entire join:
#
#     replace `PFnDef.body`, keep `PFnDef.identity`, keep `PFnDef.sourceBodyDigest`
#
# -- a substituted implementation wearing correct-looking provenance, binding to the authoritative
# implementation digest of the body it no longer holds. The digests below are MEASURED values of
# `sourceBodyDigestV1Of`, not invented hex: a fabricated constant would make the positive control
# refuse and the whole section would then pass vacuously on refusals alone.
echo "=== entry provenance is recomputed from the body ==="

# POSITIVE CONTROL FIRST. If this refuses, every refusal below is vacuous -- they would all hold
# because nothing can ever produce evidence, which is indistinguishable from a working check.
probe "a stored digest AGREEING with the recomputed body yields evidence" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f], globals := fun _ => none } : FnTable)).isSome'

# THE ACCEPTANCE MUTATION. Identity retained, stored digest retained, BODY replaced. This is the
# exact state the old code accepted, and the reason the producer had to move below `DependencyEdge`
# in the import order at all.
probe "a REPLACED body keeping its identity AND its stored digest is refused" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  let mutated : PFnDef := { f with body := PExpr.lit (PVal.int 1) }
  (tableEntryEvidence ({ entries := #[mutated], globals := fun _ => none } : FnTable)).isNone'

# The converse direction: body untouched, stored digest edited. Both directions of disagreement
# must refuse, or the check is only sensitive to one side of the comparison.
probe "a stored digest edited away from the body is refused" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "7afedf51e742f4ce04201459a3965bc8" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f], globals := fun _ => none } : FnTable)).isNone'

probe "an entry with NO recorded provenance is refused" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f], globals := fun _ => none } : FnTable)).isNone'

# SWAPPED BODIES between two identities. Each digest is individually a real digest of a real body
# in the table, and the multiset of bodies is unchanged -- only the pairing is wrong. A check that
# validated digests against "some body present" rather than against THIS entry's body would pass
# this, so it distinguishes a per-entry check from a whole-table one.
probe "bodies SWAPPED between two callable identities are refused" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 1) }
  let g : PFnDef := { identity := .semantic (CallableId.ofUser "m" "g"), operationalKey := "g",
                      sourceBodyDigest := some { value := "7afedf51e742f4ce04201459a3965bc8" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f, g], globals := fun _ => none } : FnTable)).isNone'

# ...and the same two entries paired CORRECTLY must bind, or the swap test above would pass for the
# uninteresting reason that two-entry tables never yield evidence.
probe "...and the same two bodies paired CORRECTLY yield evidence" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { value := "7afedf51e742f4ce04201459a3965bc8" },
                      params := [], body := PExpr.lit (PVal.int 1) }
  let g : PFnDef := { identity := .semantic (CallableId.ofUser "m" "g"), operationalKey := "g",
                      sourceBodyDigest := some { value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f, g], globals := fun _ => none } : FnTable)).isSome'

# SCHEMA AND SCOPE. `sourceBodyDigestV1Of` implements exactly `sourceBodyDigestV1`/`body_only`.
# A digest recorded under a different schema or scope is a DIFFERENT FORMULA, so comparing it to
# this producer's output would report body drift where there is a formula difference. Refusing what
# cannot be verified is the fail-closed reading; silently comparing anyway is not.
probe "a digest recorded under another SCHEMA is refused, not compared" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { schema := "sourceBodyDigestV2",
                                                 value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f], globals := fun _ => none } : FnTable)).isNone'

probe "a digest recorded under another SCOPE is refused, not compared" "true" '
#eval
  let f : PFnDef := { identity := .semantic (CallableId.ofUser "m" "f"), operationalKey := "f",
                      sourceBodyDigest := some { scope := "body_and_contracts",
                                                 value := "496808fdd594d5047f23e823bc26b69c" },
                      params := [], body := PExpr.lit (PVal.int 0) }
  (tableEntryEvidence ({ entries := #[f], globals := fun _ => none } : FnTable)).isNone'

probe "membership is decided by IDENTITY and finds a present callee" "true" '
#eval
  let rows := [{ callee := CallableId.ofUser "m" "f", sourceBodyDigestV1 := "496808fdd594d5047f23e823bc26b69c" : TableEntryEvidence }]
  entryEvidenceContains rows (CallableId.ofUser "m" "f")'

probe "...and does NOT find an absent one" "true" '
#eval
  let rows := [{ callee := CallableId.ofUser "m" "f", sourceBodyDigestV1 := "496808fdd594d5047f23e823bc26b69c" : TableEntryEvidence }]
  !(entryEvidenceContains rows (CallableId.ofUser "m" "g"))'

# Same display name, different module: membership must not be decided on a rendering.
probe "a same-NAMED callable from another module is not a member" "true" '
#eval
  let rows := [{ callee := CallableId.ofUser "modA" "f", sourceBodyDigestV1 := "496808fdd594d5047f23e823bc26b69c" : TableEntryEvidence }]
  !(entryEvidenceContains rows (CallableId.ofUser "modB" "f"))'

# === AUTHORITATIVE IMPLEMENTATION BINDING ====================================================
# Two things this fixes, both found by review.
#
# 1. The previous `bindEntryImplementations` took a CALLBACK, so any caller could mint a "bound" entry
#    from any non-empty string — the private constructor required non-emptiness, not provenance.
#    The old tests passed "v2:abc" and proved exactly that. A private constructor guarding a
#    value the caller supplies is not a guard.
# 2. It keyed on the V2 PROOF SUBJECT, which includes selected specification and claim scope. One
#    callable can carry several proof links, so `CallableId -> SubjectDigest` is not a function
#    and the join was ill-defined. The IMPLEMENTATION digest excludes spec and scope, so it is
#    one per callable — which is what a table entry needs.
echo "=== authoritative implementation binding ==="

HEXA='"7bcec2d7871f93204b26e2bf83d5acf1"'
HEXBODY='"6fe095a9f592a2e2b556e87f30306584"'
HEXB='"bfda7f397e3221e757383578b50ee3ff"'

probe "distinct callables with canonical digests are well-formed" "true" "
#eval ImplementationManifest.rowsWellFormed [(CallableId.ofUser \"m\" \"f\", $HEXBODY, $HEXA)]"

# The manifest CLAIMS to be a function; two rows for one callable means it is not.
probe "a DUPLICATE callable is not well-formed" "true" "
#eval !(ImplementationManifest.rowsWellFormed [(CallableId.ofUser \"m\" \"f\", $HEXBODY, $HEXA), (CallableId.ofUser \"m\" \"f\", $HEXBODY, $HEXB)])"

probe "a NON-CANONICAL digest is not well-formed" "true" '
#eval !(ImplementationManifest.rowsWellFormed [(CallableId.ofUser "m" "f", "v2:abc", "v2:abc")])'

# The exact string the old tests used. It is not a digest, and the old API accepted it.
probe "the old bypass value \"v2:abc\" is rejected outright" "true" '
#eval !(ImplementationManifest.rowsWellFormed [(CallableId.ofUser "m" "f", "v2:abc", "v2:abc")])'

# These probes now build the manifest the way production does — from a `CompleteImplementation`,
# with the digests COMPUTED — because `ofRows` is private and chosen digests are no longer
# constructible. That is a strictly better test: the entry digest and the manifest digest agree
# because both derive from the SAME `PExpr`, rather than because two literals were typed to match.
# `MF` is the shared setup; each probe supplies the final expression over `ci` and `mf`.
MF='
  let cid := CallableId.ofUser "m" "f"
  let pe := PExpr.lit (PVal.int 0)
  let fx : Proof.CheckedDeclFacts := { id := cid }
  match Proof.validate ({} : Proof.EvidenceBodyDraftV2) with
  | .error _ => false
  | .ok bd =>
  match CompleteImplementation.of? cid fx bd pe with
  | none => false
  | some ci =>
  match ImplementationManifest.ofImplementations [ci] with
  | none => false
  | some mf =>'

probe "entries bind through a computed manifest" "true" "
#eval$MF
  let rows := [{ callee := cid, sourceBodyDigestV1 := ci.sourceBodyComponent : TableEntryEvidence }]
  (bindEntryImplementations rows mf).isSome"

probe "ONE entry missing from the manifest refuses the whole list" "true" "
#eval$MF
  let rows := [{ callee := cid, sourceBodyDigestV1 := ci.sourceBodyComponent : TableEntryEvidence },
               { callee := CallableId.ofUser \"m\" \"g\", sourceBodyDigestV1 := ci.sourceBodyComponent : TableEntryEvidence }]
  (bindEntryImplementations rows mf).isNone"

# Returns the digest, not a Bool, so a caller can record WHICH implementation justified an edge.
# Asserted against `ci.implementationComponent` rather than a literal: with digests computed, a
# hard-coded expectation would pin today's hash rather than the property that the value the join
# hands back is the one the manifest computed.
probe "membership returns the manifest's computed implementation digest" "true" "
#eval$MF
  let rows := [{ callee := cid, sourceBodyDigestV1 := ci.sourceBodyComponent : TableEntryEvidence }]
  match bindEntryImplementations rows mf with
  | some b => (boundEntryImplementationOf b cid) == some ci.implementationComponent
  | none => false"

# THE ACCEPTANCE MUTATIONS for the misattachment hole. Identity alone used to bind; now the
# entry's body digest must EQUAL the authoritative one.
probe "a STALE body digest refuses to bind (identity alone is not enough)" "true" "
#eval$MF
  let rows := [{ callee := cid, sourceBodyDigestV1 := \"00000000000000000000000000000000\" : TableEntryEvidence }]
  (bindEntryImplementations rows mf).isNone"

# A digest that is a REAL digest of a DIFFERENT body — well-formed, computed by the right producer,
# and still wrong for this entry. Thirty-two zeros could be refused by a format check; this cannot.
probe "a real digest of ANOTHER body refuses to bind" "true" "
#eval$MF
  let rows := [{ callee := cid, sourceBodyDigestV1 := sourceBodyDigestV1Of (PExpr.lit (PVal.int 1)) : TableEntryEvidence }]
  (bindEntryImplementations rows mf).isNone"

# WAS a runtime refusal; is now UNREPRESENTABLE. `TableEntryEvidence.sourceBodyDigestV1` is a
# `String`, so "entry with no provenance" has no value to construct -- the check moved from
# `bindEntryImplementations` to the type, and the refusal moved up to `tableEntryEvidence`, where a
# `PFnDef` lacking `sourceBodyDigest` is rejected (asserted in the recompute section below).
expect_no_compile "an entry with NO body digest has no representation (absence is not agreement)" '
#eval
  let rows := [{ callee := Concrete.CallableId.ofUser "m" "f",
                 sourceBodyDigestV1 := none : Concrete.Proof.TableEntryEvidence }]
  rows.length'

# CONTAINMENT: the format-only door is closed. `rowsWellFormed` answers the format question as a
# Bool; there is no public way to turn chosen digests into a manifest.
# PAIRED CONTROL for the no-compile below, and it is not optional. An `expect_no_compile` passes
# when the snippet fails to elaborate FOR ANY REASON — a misqualified name, a renamed type, a typo —
# so on its own it cannot distinguish "private" from "misspelled", and would silently rot into a
# tautology the day the path changes. This asserts the SAME fully-qualified path with the PUBLIC
# predicate: it must compile. Only then does the failure below mean privacy.
probe "the qualified manifest path resolves (so the no-compile below is about PRIVACY)" "true" '
#eval Concrete.Proof.ImplementationManifest.rowsWellFormed
        [(Concrete.CallableId.ofUser "m" "f",
          "496808fdd594d5047f23e823bc26b69c", "496808fdd594d5047f23e823bc26b69c")]'

expect_no_compile "ofRows is private — chosen digests cannot become a manifest" '
#eval (Concrete.Proof.ImplementationManifest.ofRows
        [(Concrete.CallableId.ofUser "m" "f",
          "496808fdd594d5047f23e823bc26b69c", "496808fdd594d5047f23e823bc26b69c")]).isSome'

# === MANIFEST PROVENANCE: DIGESTS ARE COMPUTED, NOT SUPPLIED ==================================
# `ofRows` validates that thirty-two hex characters are thirty-two hex characters. It cannot tell a
# computed digest from a well-formed invented one, so `ofImplementations` takes INPUTS and computes
# both digests itself, and the authoritative producer now goes through it.
#
# WHAT IS AND IS NOT COVERED, stated here so the section cannot be misread as more than it proves.
# `CompleteImplementation.of?` refuses a `facts`/`callable` mispairing and incomplete facts. It
# CANNOT refuse a `body` or `extracted` belonging to a different entry, because neither
# `CompleteEvidenceBodyV2` nor `PExpr` carries identity. That swap is a NAMED GAP in the roadmap and
# has deliberately NOT been registered as a mutation, because the mutation would survive and a
# surviving control recorded as coverage is worse than no control.
echo "=== manifest provenance: inputs in, digests computed ==="

expect_no_compile "CompleteImplementation cannot be constructed directly" '
#eval fun (fx : Concrete.Proof.CheckedDeclFacts) (b : Concrete.Proof.CompleteEvidenceBodyV2) =>
  (Concrete.CompleteImplementation.mk (Concrete.CallableId.ofUser "m" "f") fx b
    (Concrete.Proof.PExpr.lit (Concrete.Proof.PVal.int 0))).callable'

# FACTS MUST DESCRIBE THE CALLABLE CLAIMED. Facts for `g`, offered as `f`: this is the mispairing
# the record exists to prevent, and the one it can actually see.
probe "facts describing ANOTHER callable are refused" "true" '
#eval
  let fx : Proof.CheckedDeclFacts := { id := CallableId.ofUser "m" "g" }
  match Proof.validate ({} : Proof.EvidenceBodyDraftV2) with
  | .ok body => (CompleteImplementation.of? (CallableId.ofUser "m" "f") fx body (PExpr.lit (PVal.int 0))).isNone
  | .error _ => false'

# INCOMPLETE FACTS. A digest over incomplete facts is a digest over an unknown, so it must not be
# mintable at all -- refusing later would mean the value existed in the meantime.
probe "INCOMPLETE facts are refused" "true" '
#eval
  -- `covered := false` is what makes these facts incomplete: default facts ARE complete
  -- (`isComplete = id.isComplete && contracts.covered`, both true by default), so an id alone
  -- would have tested the id check a second time rather than completeness.
  let fx : Proof.CheckedDeclFacts :=
    { id := CallableId.ofUser "m" "f", contracts := { covered := false } }
  match Proof.validate ({} : Proof.EvidenceBodyDraftV2) with
  -- The `!fx.isComplete` conjunct keeps this from passing for the wrong reason.
  | .ok body => (!fx.isComplete)
      && (CompleteImplementation.of? (CallableId.ofUser "m" "f") fx body (PExpr.lit (PVal.int 0))).isNone
  | .error _ => false'

expect_no_compile "the manifest cannot be constructed directly" '
#eval (Concrete.Proof.ImplementationManifest.mk []).find? (Concrete.CallableId.ofUser "m" "f")'
expect_no_compile "BoundTableEntry cannot be constructed directly" '
#eval (Concrete.Proof.BoundTableEntry.mk (Concrete.CallableId.ofUser "m" "f") "").implDigest'

# === THEOREM-TO-EDGE CORRESPONDENCE (slice 6, blocker c) =====================================
# A row says a theorem implies `contract` or `body`. Using that to type an edge is a FURTHER
# claim — this dependency is covered that way — and the two can come apart. `contract` is the
# direction that matters: it asserts the caller survives any implementation preserving the
# contract, so typing it from a theorem that quantifies over nothing UNDER-binds, letting an
# implementation change the proof actually depends on pass without staling the caller.
echo "=== theorem-to-edge correspondence ==="

mkrow() { echo "validateRawRow (\"T\", \"$1\", \"7bcec2d7871f93204b26e2bf83d5acf1\", $2, $3)"; }

probe "contract WITHOUT quantification is not justified" "true" '
#eval match validateRawRow ("T", "contract", "7bcec2d7871f93204b26e2bf83d5acf1", [], false) with
      | some r => !(rowJustifies r DependencyEdge.contract)
      | none => false'
probe "contract WITH quantification is justified" "true" '
#eval match validateRawRow ("T", "contract", "7bcec2d7871f93204b26e2bf83d5acf1", [], true) with
      | some r => rowJustifies r DependencyEdge.contract
      | none => false'
probe "body with NO bound table is not justified" "true" '
#eval match validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [], false) with
      | some r => !(rowJustifies r DependencyEdge.body)
      | none => false'
probe "body WITH a bound table is justified" "true" '
#eval match validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "6fe095a9f592a2e2b556e87f30306584")], false) with
      | some r => rowJustifies r DependencyEdge.body
      | none => false'
probe "unclassified justifies nothing" "true" '
#eval match validateRawRow ("T", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Tbl", "6fe095a9f592a2e2b556e87f30306584")], true) with
      | some r => !(rowJustifies r DependencyEdge.unclassified)
      | none => false'

# The consumer must ACT on it: an unjustified row downgrades to `unclassified` rather than being
# trusted. Without this the check would be a function nobody consults.
probe "an unjustifiable row would not classify" "unclassified" '
#eval match validateRawRow ("T", "contract", "7bcec2d7871f93204b26e2bf83d5acf1", [], false) with
      | some r => (if rowJustifies r r.edge then r.edge else DependencyEdge.unclassified).canonical
      | none => "no-row"'
# ...and real rows still classify, so the check is not simply refusing everything.
probe "a real row still classifies after the correspondence check" "body" '
#eval (classifiedEdgeOf "Concrete.Proof.parse_byte_correct").canonical'

# === ROOT DETERMINISM AND SENSITIVITY (slice 6, step 5) ======================================
# The acceptance boundary in two halves: discovery ARTEFACTS must not move the root, and any
# dependency SEMANTIC change must. A root that moves on order is unusable as a stored value; one
# that does not move on content binds nothing. Sensitivity and duplicate-edge stability are
# already covered above; these are the remaining properties.
echo "=== root determinism and sensitivity ==="

# EDGE order is discovery order, not meaning. Two traversals finding the same dependencies in a
# different sequence describe the same program.
probe "EDGE order does not change the root" "true" '
#eval
  let n := fun (es) => [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := es },
                        { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] },
                        { id := CallableId.ofUser "m" "c", digest := some "DC", edges := [] }]
  let e1 := [(DependencyEdge.body, CallableId.ofUser "m" "b"), (DependencyEdge.body, CallableId.ofUser "m" "c")]
  let e2 := [(DependencyEdge.body, CallableId.ofUser "m" "c"), (DependencyEdge.body, CallableId.ofUser "m" "b")]
  match dependencyRootMaterial (n e1) (CallableId.ofUser "m" "a"),
        dependencyRootMaterial (n e2) (CallableId.ofUser "m" "a") with
  | Except.ok x, Except.ok y => x.preimage == y.preimage
  | _, _ => false'

# NODE-LIST order is enumeration order — how the compiler happened to walk its own entries.
probe "NODE-LIST order does not change the root" "true" '
#eval
  let a := { id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] }
  let b := { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }
  match dependencyRootMaterial [a, b] (CallableId.ofUser "m" "a"),
        dependencyRootMaterial [b, a] (CallableId.ofUser "m" "a") with
  | Except.ok x, Except.ok y => x.preimage == y.preimage
  | _, _ => false'

# TRUST PROPAGATES MONOTONICALLY: a trusted edge anywhere in the closure qualifies the root, and
# nothing downstream can unset it. Non-monotone trust would let a claim be laundered clean by
# adding a dependency.
probe "trust propagates from a DEEP dependency, not just a direct one" "true" '
#eval
  let ns := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] },
             { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [(DependencyEdge.trusted, CallableId.ofUser "m" "c")] },
             { id := CallableId.ofUser "m" "c", digest := some "DC", edges := [] }]
  match dependencyRootMaterial ns (CallableId.ofUser "m" "a") with
  | Except.ok m => m.requiresTrustQualification
  | Except.error _ => false'

probe "an untrusted closure does NOT acquire trust qualification" "true" '
#eval
  let ns := [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(DependencyEdge.body, CallableId.ofUser "m" "b")] },
             { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  match dependencyRootMaterial ns (CallableId.ofUser "m" "a") with
  | Except.ok m => !m.requiresTrustQualification
  | Except.error _ => false'

# The EDGE KIND is in the bytes: swapping contract for body over the same targets must move the
# root, or typing the edges bought nothing.
probe "changing an edge KIND moves the root" "true" '
#eval
  let n := fun (k) => [{ id := CallableId.ofUser "m" "a", digest := some "DA", edges := [(k, CallableId.ofUser "m" "b")] },
                       { id := CallableId.ofUser "m" "b", digest := some "DB", edges := [] }]
  match dependencyRootMaterial (n DependencyEdge.body) (CallableId.ofUser "m" "a"),
        dependencyRootMaterial (n DependencyEdge.contract) (CallableId.ofUser "m" "a") with
  | Except.ok x, Except.ok y => x.preimage != y.preimage
  | _, _ => false'

# === SHADOW INTEGRATION (slice 6, step 4) ====================================================
# Both consumers read ONE set of nodes (`ProofCore.dependencyNodesOf`). The root is computed and
# REPORTED; it decides nothing yet.
echo "=== dependency-root shadow integration ==="

DR="$("$ROOT_DIR/.lake/build/bin/concrete" examples/proof_patterns/composition/src/main.con --report subject-facts 2>/dev/null | grep 'shadow depRoot:' || true)"
[ -n "$DR" ] \
  && ok "subject-facts carries a depRoot line (both consumers read ProofCore's nodes)" \
  || no "no depRoot line — the shadow integration is not wired"

# A leaf must ROOT: if everything refused, the integration would be indistinguishable from not
# having run, and "0 roots" would look like success.
printf '%s' "$DR" | grep -qE "shadow depRoot: [0-9a-f]{8}" \
  && ok "a leaf subject produces a root (the builder is actually reachable)" \
  || no "no subject produced a root — refusal is expected for unclassified edges, but a leaf with no edges must succeed"

# ...and a subject reaching an unclassified dependency must REFUSE, with the reason named.
# RESTATED 2026-08-09. This asserted that THIS fixture contains a refusal, which stopped being
# true when the classification table covered both attachment paths and composition's subjects all
# rooted. A gate pinned to "some fixture still fails" gets falsified by success, which is the
# wrong shape: the property is that a refusal, IF one occurs, names its edge — and the fail-closed
# behaviour itself is unit-tested above ("a root refuses an UNCLASSIFIED edge").
CORPUS_FILES="$(grep -rlE '#\[proof_fingerprint\("[a-f0-9]+"\)\]' examples/ | sort -u)"
CORPUS_REF="$(for f in $CORPUS_FILES; do
  "$ROOT_DIR/.lake/build/bin/concrete" "$f" --report subject-facts 2>/dev/null | grep 'depRoot: REFUSED' || true
done)"
NFILES="$(printf '%s\n' "$CORPUS_FILES" | grep -c . || true)"
NREF="$(printf '%s' "$CORPUS_REF" | grep -c 'REFUSED' || true)"
NNAMED="$(printf '%s' "$CORPUS_REF" | grep -cE "REFUSED \((no node for start identity|'[^']+' has no subject digest|duplicate node identity|'[^']+' depends on '[^']+', which has no node|'[^']+' has a non-current edge .* to '[^']+')" || true)"
if [ "$NFILES" = "0" ]; then
  no "dependency-root corpus is empty — a zero-refusal result would be vacuous"
elif [ "$NREF" = "0" ]; then
  ok "no root refusals remain in the corpus — every subject roots"
elif [ "$NNAMED" = "$NREF" ]; then
  ok "$NREF root refusal(s) remain, all $NNAMED name the identity/edge responsible"
else
  no "$NREF root refusal(s), but only $NNAMED name the identity/edge responsible"
fi

# The root must NOT reach any verdict yet. This is the step-4 containment, and it is the same
# check the subject digest has: shadow means computed, not consulted.
if grep -A2 "deriveObligationStatus e.eligibility" "$ROOT_DIR/Concrete/Proof/ProofCore.lean" | grep -qE "dependencyRootMaterial|dependencyNodesOf"; then
  no "a dependency root reaches deriveObligationStatus — step 6 has begun without steps 5 and 7"
else
  ok "no dependency root reaches status derivation — still shadow"
fi

GATE_DONE=1
echo ""
echo "DEPENDENCY-EDGES: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
