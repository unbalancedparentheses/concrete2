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
    o = o.replace('\\"', '"').replace('\\$', '$').replace('\\\\', '\\')
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

if [ "$rc" -eq 0 ]; then
  echo "MUTATION-ANCHORS: PASS=1 FAIL=0"
else
  echo "MUTATION-ANCHORS: PASS=0 FAIL=1"
  exit 1
fi
