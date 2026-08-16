#!/usr/bin/env bash
# KERNEL REPLAY AS A TYPED SERVICE (R-0004 package 3).
#
# "Did the Lean kernel accept this?" is the question every replay-backed receipt rests on. Until
# 2026-08-16 it had no answerer, only a rendering: the check lived INLINE in `compileAndReport`,
# entangled with that function's `reportJson` parameter, and every failure path PRINTED and returned
# an exit code. Nothing else could ask — not receipt minting, not the link migration, not a test —
# so a second caller would have had to write a second answer to the same question.
#
# This gate holds the extracted producer to the properties that make its answer usable as evidence
# rather than as output. Two of them are the whole point and are asserted in both directions:
#
#   * A REFUSAL IS A VALUE. "No kernel ran" and "the kernel said no" are opposite facts, and a
#     minting path that cannot tell them apart records a refusal as a pass.
#   * AN EMPTY REQUEST IS REFUSED, NOT SATISFIED. `checks.all accepted` is TRUE over an empty list.
#     A vacuous "all accepted" is precisely the answer a minting authority must never receive.
#
# Every negative below is paired with a live positive control, because a producer that refused
# everything would satisfy the negatives alone.
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$ROOT_DIR/.lake/build/bin/concrete"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# probe <expected-substring> <label> <lean-body>
probe() {
  cat > "$TMP/p.lean" <<LEAN
import Concrete
open Concrete.Proof
def tgt : ReplayTarget :=
  { subject := "elf.parse", theoremName := "Concrete.Proof.parse_byte_correct"
  , kind := .refinement, origin := .sourceLinked, binding := .bound }
$3
LEAN
  local out; out="$(lake env lean "$TMP/p.lean" 2>&1 || true)"
  if grep -qE "error:|error\(lean" <<<"$out"; then
    no "$2 — probe did not elaborate: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  elif grep -qF -- "$1" <<<"$out"; then ok "$2"
  else no "$2 — got: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; fi
}

echo "=== the producer answers, and the answer is not vacuous ==="

# THE POSITIVE CONTROL FOR EVERYTHING BELOW. Without it, a producer that refused every request would
# satisfy every refusal assertion in this file.
probe "CONTROL accepted general=false" "a real request is ACCEPTED (the control the refusals are measured against)" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [tgt] } with
  | .error e => IO.println s!"CONTROL-REFUSED {e.canonical}"
  | .ok r =>
    let v := ((r.verdictFor tgt.theoremName).map (·.canonical)).getD "?"
    IO.println s!"CONTROL {v} general={r.generalFailure}"'

# THE ENVIRONMENT TRAVELS WITH THE VERDICT. A verdict that cannot say which checker produced it
# cannot be invalidated later: when the toolchain moves, nothing knows the old answer is stale.
probe "ENV ok" "the result retains workspace, toolchain and import closure" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [tgt] } with
  | .error _ => IO.println "ENV refused"
  | .ok r =>
    let e := r.environment
    IO.println (if !e.workspace.isEmpty && !e.toolchain.isEmpty && e.toolchain != "unknown"
                   && e.imports == ["Concrete"] && e.workspaceFromInput
                then "ENV ok" else s!"ENV incomplete: {e.workspace}|{e.toolchain}|{e.imports}")'

echo "=== a whole-file failure is NOT reported as every theorem failing ==="

# THE DEFECT THIS EXTRACTION FIXED. The inline version computed
#     generalFailure := exitCode != 0 && failed.isEmpty
# AFTER a fallback that filled `failed` with every target — so the flag was unreachably false, the
# "Lean check failed (exit code N)" disclosure and the `env_failure` JSON status were dead code, and
# a file that did not compile was reported as every theorem individually "not found". That is the
# same misdiagnosis the workspace-resolution fix exists to prevent: blaming artifacts that were fine.
#
# An import that does not exist makes the FILE fail while naming no theorem. Only reachable as a test
# because `imports` is a request FIELD rather than a constant.
probe "BADIMPORT general=true verdict=not_attempted rejected=0" \
  "a file that does not compile yields generalFailure and NOT-ATTEMPTED, blaming no theorem" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["NoSuchModule"], targets := [tgt] } with
  | .error e => IO.println s!"BADIMPORT-REFUSED {e.canonical}"
  | .ok r =>
    let v := ((r.verdictFor tgt.theoremName).map (·.canonical)).getD "?"
    IO.println s!"BADIMPORT general={r.generalFailure} verdict={v} rejected={r.rejected.length}"'

# ...and such a run is NOT acceptable to a minting authority. `allAccepted` must fail closed on a
# general failure even though no individual target was rejected.
probe "BADIMPORT allAccepted=false fullyBound=false" \
  "a general failure is not acceptable and not fully bound (fail closed)" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["NoSuchModule"], targets := [tgt] } with
  | .error _ => IO.println "refused"
  | .ok r => IO.println s!"BADIMPORT allAccepted={r.allAccepted} fullyBound={r.fullyBound}"'

# THE DISCRIMINATION THAT MAKES THE ABOVE MEAN SOMETHING: a theorem that genuinely does not exist IS
# individually rejected, and the run is NOT a general failure. Without this, "everything becomes
# notAttempted" would also pass.
probe "MISSING general=false verdict=rejected" \
  "a theorem that does not exist is REJECTED individually, not swept into a general failure" \
'#eval show IO Unit from do
  let bad : ReplayTarget := { tgt with theoremName := "Concrete.Proof.no_such_theorem_at_all" }
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [bad] } with
  | .error e => IO.println s!"MISSING-REFUSED {e.canonical}"
  | .ok r =>
    let v := ((r.verdictFor bad.theoremName).map (·.canonical)).getD "?"
    IO.println s!"MISSING general={r.generalFailure} verdict={v}"'

echo "=== accepted-but-unbound is not accepted ==="

# A theorem can type-check perfectly while the claim it is attached to has no stored subject digest,
# in which case the freshness comparison has nothing to compare against and a changed body goes
# undetected. On examples/hmac_sha256 this once read "11 verified" while ProofCore was concurrently
# emitting 11 "this claim is unbound, not proved" errors. The distinction is in the TYPE so the two
# cannot be summed.
probe "UNBOUND verdict=accepted_unbound allAccepted=true fullyBound=false" \
  "an unbound claim whose theorem type-checks is accepted_unbound — never accepted" \
'#eval show IO Unit from do
  let u : ReplayTarget := { tgt with binding := .unbound }
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [u] } with
  | .error e => IO.println s!"UNBOUND-REFUSED {e.canonical}"
  | .ok r =>
    let v := ((r.verdictFor u.theoremName).map (·.canonical)).getD "?"
    IO.println s!"UNBOUND verdict={v} allAccepted={r.allAccepted} fullyBound={r.fullyBound}"'

echo "=== every failure class is a VALUE, not a printed line ==="

# AN EMPTY REQUEST IS REFUSED. This is the load-bearing one: `List.all` is TRUE over an empty list,
# so a producer that returned an empty success would hand a minting authority a vacuous "everything
# was accepted". Refusing forces every caller to decide what nothing-to-check means.
probe "EMPTY-REFUSED no_targets" "an empty request REFUSES rather than reporting vacuous success" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [] } with
  | .error e => IO.println s!"EMPTY-REFUSED {e.canonical}"
  | .ok r => IO.println s!"EMPTY-ACCEPTED allAccepted={r.allAccepted} (vacuous)"'

# Duplicate theorem names cannot be told apart by a name-keyed read of one transcript: both would
# inherit whichever verdict the other produced.
probe "DUP-REFUSED duplicate_theorem" "two targets naming one theorem are refused, not silently merged" \
'#eval show IO Unit from do
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [tgt, tgt] } with
  | .error e => IO.println s!"DUP-REFUSED {e.canonical}"
  | .ok _ => IO.println "DUP-ACCEPTED"'

# An empty needle matches the transcript everywhere, so an unnamed target would report as accepted
# WITHOUT BEING CHECKED — a false pass, which is the worst available failure mode.
probe "UNNAMED-REFUSED unnamed_target" "a target with an empty name is refused (an empty needle matches everywhere)" \
'#eval show IO Unit from do
  let anon : ReplayTarget := { tgt with theoremName := "  " }
  match ← replay { inputPath := "Main.lean", imports := ["Concrete"], targets := [anon] } with
  | .error e => IO.println s!"UNNAMED-REFUSED {e.canonical}"
  | .ok r =>
    let v := ((r.verdictFor anon.theoremName).map (·.canonical)).getD "?"
    IO.println s!"UNNAMED-ACCEPTED {v}"'

# NO WORKSPACE: both candidates outside any Lake tree. The theorems were never looked at, so the
# refusal must name the workspace rather than the theorems.
probe "NOWS-REFUSED no_workspace" "no workspace anywhere refuses by NAME, blaming no theorem" \
'#eval show IO Unit from do
  match ← replay { inputPath := "/tmp", fallbackDir := "/tmp", imports := ["Concrete"], targets := [tgt] } with
  | .error e => IO.println s!"NOWS-REFUSED {e.canonical}"
  | .ok _ => IO.println "NOWS-ACCEPTED"'

# ...and the refusal SAYS SO in the words the freshness gate reads.
probe "cannot locate a Lake workspace" "the no-workspace refusal explains itself" \
'#eval IO.println (ReplayRefusal.noWorkspace "/tmp/x" "/tmp").explain'

echo "=== the generated source is a pure function of the request ==="

# Reproducibility: the same request must produce the same bytes, and a DIFFERENT request must not.
# Without the second half, a constant generator would pass the first.
probe "SRC stable=true distinct=true" "the generated file is reproducible from the request, and varies with it" \
'#eval do
  let a : ReplayRequest := { inputPath := "x", imports := ["Concrete"], targets := [tgt] }
  let b : ReplayRequest := { a with targets := [{ tgt with theoremName := "Other.thm" }] }
  IO.println s!"SRC stable={a.source == a.source} distinct={a.source != b.source}"'

echo "=== the CLI renders the producer's answer and derives none of it ==="

# The extraction must not have moved any verdict. These are the numbers the report gave before it.
CP="$("$BIN" examples/elf_header/src/main.con --report check-proofs 2>&1 || true)"
if grep -q '5 verified, 0 failed' <<<"$CP"; then
  ok "elf_header still reports 5 verified, 0 failed through the producer"
else
  no "elf_header moved: $(grep -o 'Summary:.*' <<<"$CP" | head -1)"
fi
if grep -q 'Workspace: .*(from input)' <<<"$CP" && grep -q 'Toolchain: leanprover' <<<"$CP"; then
  ok "the report still names the workspace and toolchain that produced the verdict"
else
  no "the report no longer names its environment — the verdict is anonymous again"
fi
# The unbound population still reports separately from the verified one.
HM="$("$BIN" examples/hmac_sha256/src/main.con --report check-proofs 2>&1 || true)"
if grep -q '0 verified, 0 failed; 11 unbound (type-checked, NOT proved)' <<<"$HM"; then
  ok "hmac_sha256 still separates 11 unbound from verified"
else
  no "hmac_sha256 unbound accounting moved: $(grep -o 'Summary:.*' <<<"$HM" | head -1)"
fi
# ONE PRODUCER: the CLI must not carry its own workspace walker any more.
if grep -q 'partial def findLakeWorkspace' Main.lean; then
  no "Main.lean still defines its own findLakeWorkspace — two answers to 'where does this replay'"
else
  ok "the CLI has no second workspace resolver"
fi

GATE_DONE=1
echo "REPLAY-PRODUCER: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
