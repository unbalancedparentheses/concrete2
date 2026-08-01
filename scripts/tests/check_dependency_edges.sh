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
open Lean Meta Concrete.Proof
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
probe "all four edge kinds are enumerated" "true" \
'#eval DependencyEdge.all.length == 4
  && (DependencyEdge.all.map DependencyEdge.canonical).eraseDups.length == 4'
# `missing` is the only kind that is never current. `trusted` IS current — but
# only with its trust carried forward, which is a separate question and must stay
# a separate function, or an unqualified `proved_by_lean` gets minted over a trust
# boundary.
probe "only missing is not current for dependents" "true" \
'#eval (DependencyEdge.all.filter (fun e => !e.isCurrentForDependents)) == [DependencyEdge.missing]'
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
  [ { id := "a", digest := some "DA", edges := [(DependencyEdge.body, "b")] }
  , { id := "b", digest := some "DB", edges := [(DependencyEdge.body, "c")] }
  , { id := "c", digest := some "DC", edges := [] }
  , { id := "d", digest := some "DD", edges := [(DependencyEdge.body, "e")] }
  , { id := "e", digest := some "DE", edges := [(DependencyEdge.body, "d")] } ]
def g2 : List DepNode := g.map fun n => if n.id == "c" then { n with digest := some "X" } else n
'
probe "a mutual cycle terminates" "true" "$GRAPH"'#eval (dependencyRootMaterial g "d").toOption.isSome'
probe "cycle members share a closure (entry point is not semantic)" "true" "$GRAPH"'#eval
  (reachableFrom g "d").mergeSort (· ≤ ·) == (reachableFrom g "e").mergeSort (· ≤ ·)'
probe "cycle members do NOT share a root (they are different subjects)" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g "d").toOption != (dependencyRootMaterial g "e").toOption'
probe "a deep callee edit moves the dependent root" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g "a").toOption != (dependencyRootMaterial g2 "a").toOption'
probe "an unrelated subtree is unaffected" "true" "$GRAPH"'#eval
  (dependencyRootMaterial g "d").toOption == (dependencyRootMaterial g2 "d").toOption'

# FAIL-CLOSED CONDITIONS. Each previously produced a confident value from
# incomplete information; each must now REFUSE, with the reason carried.
probe "a missing start is refused" "missingStart" \
'#eval repr (dependencyRootMaterial [] "ghost")'
probe "an unresolved edge is refused, not bound as unknown" "unresolvedEdge" \
'#eval repr (dependencyRootMaterial [{ id := "a", digest := some "DA", edges := [(DependencyEdge.body, "ghost")] }] "a")'
probe "a duplicate identity is refused" "duplicateId" \
'#eval repr (dependencyRootMaterial [{ id := "a", digest := some "1", edges := [] }, { id := "a", digest := some "2", edges := [] }] "a")'
probe "an absent subject digest is refused" "incompleteDigest" \
'#eval repr (dependencyRootMaterial [{ id := "a", digest := none, edges := [] }] "a")'
probe 'a missing-typed edge is refused' "missingEdge" \
'#eval repr (dependencyRootMaterial [{ id := "a", digest := some "DA", edges := [(DependencyEdge.missing, "b")] }, { id := "b", digest := some "DB", edges := [] }] "a")'
# THE EDGE KIND IS IN THE BYTES. Traversing typed edges and then serializing only
# identities threw the typing away: contract and body produced the same preimage.
probe "changing an edge kind changes the preimage" "true" \
'#eval
  let c : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.contract, "b")] }, { id := "b", digest := some "DB", edges := [] }]
  let b : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.body, "b")] }, { id := "b", digest := some "DB", edges := [] }]
  (dependencyRootMaterial c "a").toOption != (dependencyRootMaterial b "a").toOption'
# an EMPTY digest is as incomplete as an absent one
probe "an empty-string digest is refused" "incompleteDigest" \
'#eval repr (dependencyRootMaterial [{ id := "a", digest := some "", edges := [] }] "a")'
# trust travels WITH the material, not beside it
probe "trust is carried in the returned structure" "true" \
'#eval
  let g : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.trusted, "b")] }, { id := "b", digest := some "DB", edges := [] }]
  ((dependencyRootMaterial g "a").toOption.map (·.carriesTrust)) == some true'
# CANONICAL SET SEMANTICS. reachableFrom returns the start when the start is in a
# cycle, and `id :: closure` then listed it twice — a self-recursive subject got a
# different preimage for the same dependency set.
probe "a self-recursive node is serialized exactly once" "true" \
'#eval
  let g : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.body, "a")] }]
  match (dependencyRootMaterial g "a").toOption with
  | some m => ((m.preimage.splitOn "N1:a:").length - 1) == 1
  | none   => false'
# Calling one callee twice does not change the dependency SET, so it must not
# change the root.
probe "a duplicated edge does not change the root" "true" \
'#eval
  let one : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.body, "b")] }, { id := "b", digest := some "DB", edges := [] }]
  let two : List DepNode := [{ id := "a", digest := some "DA", edges := [(DependencyEdge.body, "b"), (DependencyEdge.body, "b")] }, { id := "b", digest := some "DB", edges := [] }]
  (dependencyRootMaterial one "a").toOption == (dependencyRootMaterial two "a").toOption'
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

GATE_DONE=1
echo ""
echo "DEPENDENCY-EDGES: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
