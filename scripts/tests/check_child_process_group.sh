#!/usr/bin/env bash
# PROCESS IDENTITY BY CONSTRUCTION, ATTACKED DIRECTLY.
#
# The campaign supervisor may publish only when nothing from the run is still executing: evidence
# written after the census would be described by an artifact that never saw it. Four attempts at
# that check shipped broken, and every one of them was found by RUNNING a campaign, not by reading:
#
#   1. `pgrep -P $$` sees one generation, and the campaign child is already reaped by then, so a
#      surviving grandchild is reparented away and never appears.
#   2. matching command lines for the repository path also matched the LAUNCHER of the run.
#   3. matching them for the workspace path matched the supervisor itself, which runs
#      `bash /tmp/concrete-mut.<pid>.../driver.sh`, and any shell whose command line merely
#      CONTAINED the search string.
#   4. /proc ancestry is correct on Linux and ABSENT on macOS — and this repository has already
#      taken a macOS outage from depending on /proc.
#
# Attempts 2, 3 and 4 refused clean runs. A check that always fires carries no more information than
# one that never does; both are indistinguishable from an absent check to anything reading results.
#
# The rule is now structural: the child is launched into its own session, so its process-group id is
# its pid, the supervisor and every ancestor are outside that group, and liveness is whatever the
# kernel says about that group. No patterns, no exclusion lists, nothing depending on how a worker
# spells its command line. POSIX, so Linux and macOS decide qualification identically.
set -uEo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
LAUNCH="$ROOT_DIR/scripts/tests/lib/run_campaign_child.py"
[ -f "$LAUNCH" ] || { echo "error: $LAUNCH missing" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# run_case <label> <expected-rc> <expected-group-empty> <command...>
run_case() {
  local label="$1" want_rc="$2" want_empty="$3"; shift 3
  local rep="$TMP/report.$$.$RANDOM"
  python3 "$LAUNCH" --report "$rep" -- "$@" >/dev/null 2>&1
  local rc empty
  rc="$(sed -n 's/^child_rc=//p' "$rep" | head -1)"
  empty="$(sed -n 's/^group_empty=//p' "$rep" | head -1)"
  if [ "$rc" = "$want_rc" ] && [ "$empty" = "$want_empty" ]; then
    ok "$label"
  else
    no "$label — expected rc=$want_rc group_empty=$want_empty, got rc=${rc:-<none>} group_empty=${empty:-<none>}"
  fi
  rm -f "$rep"
}

echo "=== a clean child leaves an empty group, and its status is preserved ==="
run_case "a child exiting 0 leaves no group members"      0  1 sh -c 'exit 0'
run_case "a nonzero exit is reported, group still empty"   7  1 sh -c 'exit 7'

echo "=== a survivor keeps the group alive, whatever it is called ==="
# THE CHILD EXITS FIRST while its own child keeps running: this is the case `pgrep -P $$` could never
# see, because by the time the supervisor looks, the campaign child has been reaped and the survivor
# has been reparented away from it.
run_case "a grandchild outliving the child is detected"    0  0 sh -c 'sleep 5 & exit 0'
# NAME-INDEPENDENCE, asserted directly rather than by trying to rewrite argv: the check never
# consults a name, so a survivor with an entirely unrelated one is still a member of the group.
run_case "a survivor with an unrelated name is detected"   0  0 sh -c 'exec -a totally-unrelated sleep 5 & exit 0'

echo "=== processes outside the group are not the supervisor's concern ==="
# A decoy that looks exactly like campaign work but was never in this group. Under the command-line
# matching this replaced, this is precisely what produced false refusals.
sh -c 'exec -a concrete-mut.99999.decoy sleep 4' >/dev/null 2>&1 &
_decoy=$!
sleep 0.3
run_case "an unrelated similarly-named process is ignored" 0  1 sh -c 'exit 0'
kill "$_decoy" 2>/dev/null || true
wait "$_decoy" 2>/dev/null || true

echo "=== the launcher never reports on itself or its caller ==="
# If the launcher counted its own process or this gate, every case above would have said non-empty.
# That it does not is the property the previous three attempts lacked.
run_case "the launcher and this gate are outside the group" 0 1 sh -c 'true'

echo "=== the rule is the kernel's, so it is the same rule everywhere ==="
if python3 - <<'PY'
import os, sys
# killpg on a group that cannot exist must raise ProcessLookupError on any POSIX system; if this
# platform reported something else, the emptiness answer would not mean what the supervisor thinks.
try:
    os.killpg(0x7FFFFFFF, 0)
except ProcessLookupError:
    sys.exit(0)
except Exception:
    sys.exit(1)
sys.exit(1)
PY
then ok "an absent process group reports absent (POSIX semantics available here)"
else no "this platform does not report an absent process group as absent"
fi

echo ""
echo "CHILD-PROCESS-GROUP: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
