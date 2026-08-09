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
probe "all five edge kinds are enumerated with distinct tags" "true" \
'#eval DependencyEdge.all.length == 5
  && (DependencyEdge.all.map DependencyEdge.canonical).eraseDups.length == 5'
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

GATE_DONE=1
echo ""
echo "DEPENDENCY-EDGES: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
