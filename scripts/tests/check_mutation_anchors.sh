#!/usr/bin/env bash
# MUTATION ANCHORS — every mutation's target text still exists in its file.
#
# The mutation harness is what establishes that the other gates are load-bearing, so an
# inert mutation costs more than an ordinary test: it removes the evidence that some gate
# does any work, and removes it silently.
#
# A mutation whose MUT_OLD no longer appears in MUT_FILE cannot be applied. The harness
# prints "SKIPPED (pattern not found in file)" and, until 2026-08-06, still exited 0. Two
# things made that invisible for a long time:
#
#   1. the harness rebuilds the compiler twice per mutation, so it is expensive and is NOT
#      run in CI — nothing was checking;
#   2. anchors rot from ordinary refactors. Measured 2026-08-06: 4 of 77 were stale. Three
#      broke when the V2 producer cutover changed `return .call ...` into
#      `return ElaboratedExprV2.mk (CExpr.call ...)`; a fourth broke when R-0455 turned a
#      literal Rocq proof template into an interpolated one.
#
# This gate is the cheap half of that: pure string presence, no builds, no mutations, runs
# in seconds on every push. It cannot tell you a mutation is KILLED — only that it is still
# capable of being applied at all. That is the property that was silently lost.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fresh.sh"
require_fresh_binary || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
fatal() { local rc=$?; echo "FATAL: check_mutation_anchors stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2; exit "$rc"; }
trap fatal ERR

HARNESS="scripts/tests/test_mutation.sh"
[ -f "$HARNESS" ] || { echo "FATAL: $HARNESS not found" >&2; exit 1; }

# `|| rc=$?` because the ERR trap would otherwise fire on the python exit and kill the
# gate before it can print its own verdict — the failure mode this gate exists to notice,
# reproduced in the gate itself on its first run.
rc=0
python3 - "$HARNESS" <<'PY' || rc=$?
import re, sys, os
harness = sys.argv[1]
src = open(harness).read()

files = re.findall(r'MUT_FILE\+=\("([^"]+)"\)', src)
olds  = re.findall(r'MUT_OLD\+=\("(.*?)"\)\n', src, re.S)

fail = 0
# Pairing by ORDER is how the harness itself indexes these arrays, so a count mismatch
# means some entry is malformed and every mutation after it is paired with the wrong file.
if len(files) != len(olds):
    print(f"  FAIL MUT_FILE ({len(files)}) and MUT_OLD ({len(olds)}) counts differ — the arrays are index-paired, so a mismatch mis-pairs every entry after it")
    fail += 1
    sys.exit(1)

stale = []
for i, (f, o) in enumerate(zip(files, olds), 1):
    # BASH HONOURS EXACTLY FOUR ESCAPES inside double quotes: \" \$ \\ and \` — and this mirrored
    # only three. An anchor containing a backtick therefore could never match its file, so the gate
    # reported "cannot be applied" for a mutation whose target text was present and correct. That is
    # the worst shape of failure for this particular gate: it exists to detect inert mutations, and a
    # false report here sends someone to re-anchor source that was never stale. Lean comments quote
    # identifiers in backticks constantly, so any anchor spanning a doc comment hit it.
    o = (o.replace('\\"', '"').replace('\\$', '$')
          .replace('\\`', '`').replace('\\\\', '\\'))
    if not os.path.exists(f):
        stale.append((i, f, "the FILE no longer exists")); continue
    if o not in open(f).read():
        stale.append((i, f, o.strip().split('\n')[0][:70]))

for i, f, why in stale:
    print(f"  FAIL mutation #{i} cannot be applied to {f}")
    print(f"       anchor: {why}")

# MUTATION COVERAGE PER GATE. "Every leg is mutation-verified" is a discipline nobody can
# enforce by reading, and I applied it inconsistently across this arc — several legs turned
# out to pass for the wrong reason, and three gates could not fail at all. This is the
# mechanical approximation: the gates that carry the evidence claims must each be the
# target of a minimum number of mutations. It cannot prove a specific leg is covered; it
# does stop a gate accumulating legs while its mutation count stays flat.
FLOORS = {
    'scripts/tests/check_shadow_body_v2.sh': 12,
    'scripts/tests/check_binder_refs.sh': 3,
}
gates = re.findall(r'gate_for_last "([^"]+)"', src)
from collections import Counter
counts = Counter(gates)
for gate, floor in sorted(FLOORS.items()):
    got = counts.get(gate, 0)
    if got < floor:
        print(f"  FAIL {gate} is the target of only {got} mutation(s), floor {floor}")
        print("       A gate accumulating legs without mutations is accumulating assertions")
        print("       nobody has shown can fail. Add mutations, or lower the floor and say why.")
        fail += 1
    else:
        print(f"  ok   {gate}: {got} mutations (floor {floor})")

if fail:
    sys.exit(1)

if stale:
    print()
    print(f"  {len(stale)} of {len(files)} mutations are inert. Re-anchor each on the current")
    print("  code shape. Do NOT delete them and do NOT leave them skipped: a mutation is the")
    print("  evidence that some gate is load-bearing, and an inert one withdraws that evidence")
    print("  without saying so.")
    sys.exit(1)

print(f"  ok   all {len(files)} mutation anchors still exist in their files")
PY

# BOTH MUTATION CORPORA, and it was one. This gate checked `test_mutation.sh`'s 77 anchors and
# nothing else, while `check_gate_mutation_coverage.sh` carries 78 more with no integrity check at
# all. NINE of those had gone inert — four guarding check_attestation_manifest, two
# check_atomic_flip_entrance, two check_dependency_edges, one check_proof_freshness — and the only
# thing that would have reported it was a multi-hour campaign nobody runs on a change.
#
# Worse, a verified claim about one corpus was reported as a claim about both, in the R-0004 closure
# record. Checking one population and describing two is the failure this pair of checks now prevents.
#
# Delegated to that harness's own ANCHORS_ONLY mode rather than re-parsed here: it already holds the
# arrays, and a second parser for the `add` format would drift from the harness it describes.
COV_RC=0
if [ -x scripts/tests/check_gate_mutation_coverage.sh ] || [ -f scripts/tests/check_gate_mutation_coverage.sh ]; then
  if ANCHORS_ONLY=1 bash scripts/tests/check_gate_mutation_coverage.sh > /tmp/.anchors_cov.$$ 2>&1; then
    echo "  ok   $(grep -oE 'all [0-9]+ anchors still match their targets' /tmp/.anchors_cov.$$ | head -1) (check_gate_mutation_coverage)"
  else
    COV_RC=1
    echo "  FAIL check_gate_mutation_coverage has inert mutation families:"
    grep -E '^  FAIL' /tmp/.anchors_cov.$$ | sed 's/^/    /' | head -12
  fi
  rm -f /tmp/.anchors_cov.$$
else
  COV_RC=1
  echo "  FAIL scripts/tests/check_gate_mutation_coverage.sh is missing — its 78 families are unchecked"
fi

if [ "$rc" -eq 0 ] && [ "$COV_RC" -eq 0 ]; then
  echo "MUTATION-ANCHORS: PASS=2 FAIL=0 (both corpora)"
else
  echo "MUTATION-ANCHORS: PASS=$(( (rc == 0 ? 1 : 0) + (COV_RC == 0 ? 1 : 0) )) FAIL=$(( (rc != 0 ? 1 : 0) + (COV_RC != 0 ? 1 : 0) ))"
  exit 1
fi
