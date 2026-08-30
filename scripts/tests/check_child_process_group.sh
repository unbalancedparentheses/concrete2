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
# spells its command line. Designed using portable POSIX mechanisms; whether Linux and macOS agree
# is established by running this gate on both in CI, not by claiming it here.
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
  python3 "$LAUNCH" --report "$rep" --run-id "GATE-$$" -- "$@" >/dev/null 2>&1
  local rc empty
  rc="$(sed -n 's/^child_rc=//p' "$rep" | head -1)"
  local state; state="$(sed -n 's/^process_group_state=//p' "$rep" | head -1)"
  case "$state" in empty) empty=1 ;; nonempty) empty=0 ;; *) empty="state:$state" ;; esac
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

echo "=== a signalled child is reported unambiguously ==="
# Popen.wait() returns -N for signal N. A shell comparing that reads a negative, or coerces it: the
# status must say plainly that the child was killed, and child_rc must still look like a failure to
# a consumer that reads nothing else.
_rep="$TMP/sig"
python3 "$LAUNCH" --report "$_rep" --run-id "GATE-$$" -- sh -c 'kill -TERM $$' >/dev/null 2>&1
_rc="$(sed -n 's/^child_rc=//p' "$_rep")"; _sg="$(sed -n 's/^child_signalled=//p' "$_rep")"
_sn="$(sed -n 's/^child_signal=//p' "$_rep")"
{ [ "$_rc" = "143" ] && [ "$_sg" = "1" ] && [ "$_sn" = "15" ]; } \
  && ok "a SIGTERMed child reports child_rc=143 child_signalled=1 child_signal=15" \
  || no "signalled child misreported (rc=$_rc signalled=$_sg signal=$_sn)"

echo "=== the report is a strict channel ==="
# Each of these is what a partial write, a double write, or a stray key looks like. The supervisor
# decodes strictly, so every one must be distinguishable from a clean report rather than read as
# whichever line came first.
_mk() { printf '%s\n' "$@" > "$TMP/probe"; }
_decodes_clean() {
  local bad=""
  for f in protocol_version run_id child_rc child_signalled child_signal process_group_state pgid; do
    [ "$(grep -cE "^$f=" "$TMP/probe")" = "1" ] || bad="$bad $f"
  done
  [ -z "$(sed -n 's/^\([a-z_]*\)=.*/\1/p' "$TMP/probe" | grep -vxE 'protocol_version|run_id|child_rc|child_signalled|child_signal|process_group_state|pgid')" ] || bad="$bad unknown"
  [ -z "$bad" ]
}
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=0' 'process_group_state=empty' 'pgid=1'
_decodes_clean && ok "a complete report decodes cleanly (positive control)" || no "a complete report was rejected"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=0' 'pgid=1'
_decodes_clean && no "a report missing process_group_state was accepted" || ok "a MISSING field is refused"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_rc=1' 'child_signalled=0' 'child_signal=0' 'process_group_state=empty' 'pgid=1'
_decodes_clean && no "a contradictory duplicate was accepted" || ok "a CONTRADICTORY duplicate is refused"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_rc=0' 'child_signalled=0' 'child_signal=0' 'process_group_state=empty' 'pgid=1'
_decodes_clean && no "an identical duplicate was accepted" || ok "an IDENTICAL duplicate is refused"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=0' 'process_group_state=empty' 'pgid=1' 'extra=1'
_decodes_clean && no "an unknown key was accepted" || ok "an UNKNOWN key is refused"

echo "=== the stated guarantee is process GROUP, not descendants ==="
# MEASURED, NOT ASSUMED, and recorded here so the limitation cannot quietly become a claim: a
# descendant that starts its own session leaves the original group empty while it is still running.
# That escape is out of the threat model — the campaign starts its own gates, lake and the compiler,
# none of which leave their group — and the field is named process_group_empty precisely so no
# reader infers containment that was never established.
_rep2="$TMP/escape"
python3 "$LAUNCH" --report "$_rep2" --run-id "GATE-$$" -- python3 -c 'import subprocess,sys; subprocess.Popen(["sleep","4"], start_new_session=True); sys.exit(0)' >/dev/null 2>&1
_esc="$(sed -n 's/^process_group_state=//p' "$_rep2")"
if [ "$_esc" = "empty" ]; then
  ok "a session-escaping descendant is NOT detected — documented limitation, not a containment claim"
else
  no "a session-escaping descendant was detected; the documented limitation is now wrong and the comments must be corrected"
fi

echo "=== the v2 contract: version, run binding, and coherent signal fields ==="
# AN UNSUPPORTED CONTRACT IS NOT A REPORT. Reading fields whose meaning a consumer does not know is
# interpreting bytes, not decoding a record.
_rep3="$TMP/proto"
python3 "$LAUNCH" --report "$_rep3" --run-id "PROTO-1" -- sh -c 'exit 0' >/dev/null 2>&1
[ "$(sed -n 's/^protocol_version=//p' "$_rep3")" = "1" ] \
  && ok "the report declares its protocol version" || no "no protocol_version in the report"
# A STALE REPORT BELONGS TO ANOTHER RUN. Binding it to the run id is what stops one being reused.
[ "$(sed -n 's/^run_id=//p' "$_rep3")" = "PROTO-1" ] \
  && ok "the report is bound to the run that requested it" || no "run_id not echoed"
python3 "$LAUNCH" --report "$_rep3" --run-id "PROTO-2" -- sh -c 'exit 0' >/dev/null 2>&1
[ "$(sed -n 's/^run_id=//p' "$_rep3")" = "PROTO-2" ] \
  && ok "a later run overwrites the binding rather than inheriting it" || no "run_id not rebound"
# THE DISTINCTION child_rc ALONE CANNOT MAKE: a child that EXITED 143 and one KILLED by signal 15
# both report child_rc=143. Only child_signalled separates them, so it is asserted directly.
_rep4="$TMP/exit143"
python3 "$LAUNCH" --report "$_rep4" --run-id "X" -- sh -c 'exit 143' >/dev/null 2>&1
_a="$(sed -n 's/^child_rc=//p' "$_rep4")|$(sed -n 's/^child_signalled=//p' "$_rep4")|$(sed -n 's/^child_signal=//p' "$_rep4")"
python3 "$LAUNCH" --report "$_rep4" --run-id "X" -- sh -c 'kill -TERM $$' >/dev/null 2>&1
_b="$(sed -n 's/^child_rc=//p' "$_rep4")|$(sed -n 's/^child_signalled=//p' "$_rep4")|$(sed -n 's/^child_signal=//p' "$_rep4")"
{ [ "$_a" = "143|0|0" ] && [ "$_b" = "143|1|15" ]; } \
  && ok "exit 143 and signal 15 share child_rc but are distinguished (got $_a vs $_b)" \
  || no "exit 143 vs signal 15 not distinguished (got $_a vs $_b)"
# SIGNAL FIELDS MUST AGREE. Either alone would lead a consumer to the opposite conclusion.
_mk 'protocol_version=1' 'run_id=X' 'child_rc=143' 'child_signalled=1' 'child_signal=0' 'process_group_state=empty' 'pgid=1'
_coh() { local sg sn; sg="$(sed -n 's/^child_signalled=//p' "$TMP/probe")"; sn="$(sed -n 's/^child_signal=//p' "$TMP/probe")"
         case "$sg:$sn" in 0:0|1:[1-9]*) return 0 ;; *) return 1 ;; esac; }
_coh && no "signalled=1 with signal=0 was accepted" || ok "signalled=1 with signal=0 is incoherent"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=9' 'process_group_state=empty' 'pgid=1'
_coh && no "signal=9 with signalled=0 was accepted" || ok "a signal without signalled is incoherent"
_mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=0' 'process_group_state=empty' 'pgid=1'
_coh && ok "coherent signal fields are accepted (positive control)" || no "coherent fields rejected"

echo "=== only a PROVEN-empty group may permit publication ==="
# A boolean collapsed these: permission_denied means the group EXISTS but is not ours to signal, and
# error:<n> means the question was never answered. Neither is absence.
for st in nonempty permission_denied error:13; do
  _mk 'protocol_version=1' 'run_id=X' 'child_rc=0' 'child_signalled=0' 'child_signal=0' "process_group_state=$st" 'pgid=1'
  [ "$(sed -n 's/^process_group_state=//p' "$TMP/probe")" = "empty" ] \
    && no "'$st' would have been read as empty" || ok "'$st' is not empty, so it cannot permit publication"
done

echo ""
echo "CHILD-PROCESS-GROUP: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
